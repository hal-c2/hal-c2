import { describe, expect, it } from "bun:test";
import type { SimpleHighlight } from "@opentui/core";

import { THEME, type Palette } from "../theme.ts";
import { createCodeColours, fenceFiletype, MAX_CHARS, type ReadCode } from "./codeColours.ts";

// A reader that colours every `const` as a keyword, for typescript only, and holds each
// reading until the test lets it go.
function reader() {
  const reads: Array<{ text: string; filetype: string }> = [];
  const waiting: Array<() => void> = [];
  const read: ReadCode = (text, filetype) => {
    reads.push({ text, filetype });
    return new Promise((resolve) => {
      waiting.push(() => {
        if (filetype !== "typescript") return resolve(null);
        const scopes: SimpleHighlight[] = [];
        for (const match of text.matchAll(/const/g)) {
          scopes.push([match.index, match.index + 5, "keyword"]);
        }
        resolve(scopes);
      });
    });
  };
  return { read, reads, release: () => waiting.splice(0).forEach((go) => go()) };
}

const firstColour = (lines: ReturnType<ReturnType<typeof createCodeColours>["lines"]>, n: number) =>
  lines?.[n]?.[0]?.fg;

describe("fenceFiletype", () => {
  it("resolves a fence's short names and leaves an empty fence and a diagram plain", () => {
    expect(fenceFiletype("ts")).toBe("typescript");
    expect(fenceFiletype("TypeScript {.numbered}")).toBe("typescript");
    expect(fenceFiletype("py")).toBe("python");
    expect(fenceFiletype("exs")).toBe("elixir");
    expect(fenceFiletype("sh")).toBe("bash");
    expect(fenceFiletype("rs")).toBe("rust");
    expect(fenceFiletype("")).toBeNull();
    expect(fenceFiletype("mermaid")).toBeNull();
  });
});

describe("createCodeColours", () => {
  it("reads code once and colours it from the palette", async () => {
    const code = reader();
    const colours = createCodeColours(code.read);
    let changes = 0;
    colours.listen(() => changes++);
    expect(colours.lines("ts", "const a = 1;", true, THEME)).toBeNull();
    expect(colours.lines("ts", "const a = 1;", true, THEME)).toBeNull();
    code.release();
    await colours.settled();
    const lines = colours.lines("ts", "const a = 1;", true, THEME);
    expect(lines?.[0]?.map((part) => part.text)).toEqual(["const", " a = 1;"]);
    expect(firstColour(lines, 0)).toEqual(THEME.keyword);
    expect(code.reads).toEqual([{ text: "const a = 1;", filetype: "typescript" }]);
    expect(changes).toBe(1);
  });

  it("follows another palette without reading again", async () => {
    const code = reader();
    const colours = createCodeColours(code.read);
    colours.lines("ts", "const a = 1;", true, THEME);
    code.release();
    await colours.settled();
    const dark: Palette = { ...THEME, keyword: THEME.error };
    expect(firstColour(colours.lines("ts", "const a = 1;", true, dark), 0)).toEqual(THEME.error);
    expect(firstColour(colours.lines("ts", "const a = 1;", true, THEME), 0)).toEqual(THEME.keyword);
    expect(code.reads).toHaveLength(1);
  });

  it("reads only the finished lines of a block being written, keeping them while it grows", async () => {
    const code = reader();
    const colours = createCodeColours(code.read);
    colours.lines("ts", "const a = 1;\nconst b = 2;\nconst c", false, THEME);
    expect(code.reads.map((r) => r.text)).toEqual(["const a = 1;\nconst b = 2;\n"]);
    code.release();
    await colours.settled();
    const grown = "const a = 1;\nconst b = 2;\nconst c = 3;\nconst d";
    const meanwhile = colours.lines("ts", grown, false, THEME);
    // The lines read before keep their colours; the new one waits.
    expect(meanwhile).toHaveLength(2);
    expect(firstColour(meanwhile, 1)).toEqual(THEME.keyword);
    // While that reading is under way, a further line does not start another, and the
    // lines read before still keep their colours.
    const further = colours.lines("ts", `${grown} = 4;\nconst e`, false, THEME);
    expect(code.reads).toHaveLength(2);
    expect(further).toHaveLength(2);
    expect(firstColour(further, 1)).toEqual(THEME.keyword);
    code.release();
    await colours.settled();
    expect(colours.lines("ts", grown, false, THEME)).toHaveLength(3);
  });

  it("keeps a language without a grammar plain without asking again as it grows", async () => {
    const code = reader();
    const colours = createCodeColours(code.read);
    colours.lines("klingon", "Qapla'\n", false, THEME);
    code.release();
    await colours.settled();
    expect(colours.lines("klingon", "Qapla'\n", false, THEME)).toBeNull();
    expect(colours.lines("klingon", "Qapla'\nbatlh\n", false, THEME)).toBeNull();
    expect(code.reads).toHaveLength(1);
  });

  it("asks again for code whose reading failed, keeping the lines read before", async () => {
    const reads: string[] = [];
    let fail = false;
    const colours = createCodeColours(async (text) => {
      reads.push(text);
      if (fail) throw new Error("worker gone");
      return [...text.matchAll(/const/g)].map((match): SimpleHighlight => [
        match.index,
        match.index + 5,
        "keyword",
      ]);
    });
    colours.lines("ts", "const a = 1;\n", false, THEME);
    await colours.settled();
    fail = true;
    const grown = "const a = 1;\nconst b = 2;\n";
    colours.lines("ts", grown, true, THEME);
    await colours.settled();
    fail = false;
    // Drawn again: asked for again, the lines read before shown meanwhile.
    expect(colours.lines("ts", grown, true, THEME)).toHaveLength(1);
    await colours.settled();
    expect(colours.lines("ts", grown, true, THEME)).toHaveLength(2);
    expect(reads).toEqual(["const a = 1;\n", grown, grown]);
  });

  it("reads no code past the cap", () => {
    const code = reader();
    const colours = createCodeColours(code.read);
    const line = `${"x".repeat(1023)}\n`;
    colours.lines("ts", line.repeat(MAX_CHARS / line.length + 10), true, THEME);
    expect(code.reads[0]!.text.length).toBeLessThanOrEqual(MAX_CHARS);
    expect(code.reads[0]!.text.endsWith("\n")).toBe(true);
  });

  it("names a type only when it starts with a capital and a constant only in capitals", async () => {
    const colours = createCodeColours(async () => [
      [0, 4, "type"],
      [5, 9, "type"],
      [10, 13, "constant"],
      [14, 17, "constant"],
    ]);
    colours.lines("ts", "Cart cart MAX max", true, THEME);
    await colours.settled();
    const parts = colours.lines("ts", "Cart cart MAX max", true, THEME)![0]!;
    const colourOf = (text: string) => parts.find((part) => part.text === text)?.fg;
    expect(colourOf("Cart")).toEqual(THEME.type);
    expect(colourOf("MAX")).toEqual(THEME.number);
    expect(parts.map((part) => part.text).join("")).toBe("Cart cart MAX max");
    expect(
      parts
        .filter((part) => part.text.includes("cart") || part.text.includes("max"))
        .every((part) => part.fg === undefined || part.fg.equals(THEME.text)),
    ).toBe(true);
  });
});
