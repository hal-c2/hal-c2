import { describe, expect, it } from "bun:test";
import { TextAttributes } from "@opentui/core";

import { THEME } from "../theme.ts";
import { linkifyTimelineUrls } from "../timelineLinks.ts";
import { markdownLines, plainText } from "./styledText.ts";

const render = (markdown: string) => markdownLines(linkifyTimelineUrls(markdown), THEME);
const links = (markdown: string) =>
  render(markdown).flatMap((line) =>
    line.chunks.filter((part) => part.link).map((part) => [part.text, part.link!.url]),
  );

describe("markdownLines", () => {
  it("drops the markup and keeps one blank line between blocks", () => {
    const lines = render("# Title\n\n\n\nSome **bold** text\n\n- one\n2. two\n\n---\n> quoted");
    expect(lines.map(plainText)).toEqual([
      "Title",
      "",
      "Some bold text",
      "",
      "• one",
      "2. two",
      "",
      "─".repeat(24),
      "│ quoted",
    ]);
    const bold = lines[2]!.chunks.find((part) => part.text === "bold")!;
    expect((bold.attributes ?? 0) & TextAttributes.BOLD).toBe(TextAttributes.BOLD);
  });

  it("keeps a fenced block verbatim in the code colour", () => {
    const lines = render("```ts\nconst a = **b**; // https://example.com\n```");
    expect(lines.map(plainText)).toEqual(["  const a = **b**; // https://example.com"]);
    expect(lines[0]!.chunks).toHaveLength(1);
    expect(lines[0]!.chunks[0]!.fg).toEqual(THEME.warning);
  });

  it("links bare URLs without their trailing punctuation", () => {
    expect(links("See https://example.com/docs.")).toEqual([
      ["https://example.com/docs", "https://example.com/docs"],
    ]);
    expect(links("[the docs](https://example.com/a) and <https://example.com/b>")).toEqual([
      ["the docs", "https://example.com/a"],
      ["https://example.com/b", "https://example.com/b"],
    ]);
  });

  it("never links inside inline code", () => {
    expect(links("Run `curl https://example.com/api` now")).toEqual([]);
  });
});
