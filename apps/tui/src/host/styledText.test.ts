import { describe, expect, it } from "bun:test";
import { TextAttributes } from "@opentui/core";

import { THEME } from "../theme.ts";
import { linkifyTimelineUrls } from "../timelineLinks.ts";
import type { MermaidRenderResult } from "@hal-c2/contracts";

import {
  chunk,
  inlineMarkdown,
  markdownBlockLines,
  markdownLines,
  mermaidFenceSource,
  plainText,
  wrapChunks,
} from "./styledText.ts";

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
      "- one",
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
    expect(lines.map(plainText)).toEqual(["const a = **b**; // https://example.com"]);
    expect(lines[0]!.chunks).toHaveLength(1);
    expect(lines[0]!.chunks[0]!.fg).toEqual(THEME.warning);
  });

  it("keeps list markers as written, bold in the accent colour", () => {
    const [star, number] = render("* star\n10. ten");
    expect([star, number].map((line) => plainText(line!))).toEqual(["* star", "10. ten"]);
    const marker = number!.chunks.find((part) => part.text === "10.")!;
    expect(marker.fg).toEqual(THEME.accent);
    expect((marker.attributes ?? 0) & TextAttributes.BOLD).toBe(TextAttributes.BOLD);
  });

  it("sets a fenced block off from the text around it", () => {
    expect(render("before\n```\ncode\n```\nafter").map(plainText)).toEqual([
      "before",
      "",
      "code",
      "",
      "after",
    ]);
  });

  it("boxes a pipe table across the width with its header in the accent colour", () => {
    const lines = markdownLines("| A | B |\n|---|---|\n| 1 | 2 |", THEME, 11);
    expect(lines.map(plainText)).toEqual([
      "┌────┬────┐",
      "│A   │B   │",
      "├────┼────┤",
      "│1   │2   │",
      "└────┴────┘",
    ]);
    expect(lines[1]!.chunks.find((part) => part.text === "A")!.fg).toEqual(THEME.accent);
  });

  it("aligns each column as its divider says and draws the cells' inline Markdown", () => {
    const lines = markdownLines(
      "| L | C | R |\n|:--|:-:|--:|\n| **a** | `b` | a \\| b |",
      THEME,
      22,
    );
    expect(lines.map(plainText)).toEqual([
      "┌──────┬──────┬──────┐",
      "│L     │  C   │     R│",
      "├──────┼──────┼──────┤",
      "│a     │  b   │ a | b│",
      "└──────┴──────┴──────┘",
    ]);
    const bold = lines[3]!.chunks.find((part) => part.text === "a")!;
    expect((bold.attributes ?? 0) & TextAttributes.BOLD).toBe(TextAttributes.BOLD);
    expect(lines[3]!.chunks.find((part) => part.text === "b")!.fg).toEqual(THEME.warning);
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

describe("Mermaid blocks", () => {
  const FLOW = "flowchart LR\n  Cart --> Paid";
  const DRAWN = "┌──────┐     ┌──────┐\n│ Cart │────►│ Paid │\n└──────┘     └──────┘";
  const diagrams = (answers: Record<string, MermaidRenderResult>) => {
    const asked: string[] = [];
    return {
      asked,
      get: (source: string) => {
        asked.push(source);
        return answers[source];
      },
    };
  };
  const shown = (markdown: string, answers: Record<string, MermaidRenderResult>, width = 80) =>
    markdownLines(markdown, THEME, width, diagrams(answers)).map(plainText);

  it("draws a closed block as the MC drew it, named by its type", () => {
    const lines = markdownBlockLines(
      `Before\n\n\`\`\`mermaid\n${FLOW}\n\`\`\``,
      THEME,
      80,
      undefined,
      diagrams({ [FLOW]: { status: "drawn", kind: "flowchart", text: `${DRAWN}\n` } }),
    );
    expect(lines.map((line) => plainText(line.text))).toEqual([
      "Before",
      "",
      "◇ flowchart diagram",
      ...DRAWN.split("\n"),
    ]);
    expect(lines.slice(2).every((line) => line.code?.source === FLOW)).toBe(true);
    expect(lines[2]!.diagram).toEqual({ index: 0, title: true, drawable: true });
  });

  it("does not ask while the block is still being written", () => {
    const writing = diagrams({});
    const lines = markdownLines("```mermaid\nflowchart LR\n  Cart -->", THEME, 80, writing);
    expect(lines.map(plainText)).toEqual(["flowchart LR", "  Cart -->"]);
    expect(writing.asked).toEqual([]);
  });

  it("says it is drawing until the MC answers", () => {
    expect(shown(`\`\`\`mermaid\n${FLOW}\n\`\`\``, {})).toEqual([
      "◇ flowchart diagram · drawing…",
      "flowchart LR",
      "  Cart --> Paid",
    ]);
  });

  it("shows the source under where the mistake is", () => {
    const broken = "flowchart LR\n  A[Cart --> B";
    expect(
      shown(`\`\`\`mermaid\n${broken}\n\`\`\``, {
        [broken]: {
          status: "invalid",
          kind: "flowchart",
          reason: "expected EOI",
          line: 2,
          column: 4,
        },
      }),
    ).toEqual([
      "◇ flowchart diagram",
      "Line 2, column 4: expected EOI",
      "flowchart LR",
      "  A[Cart --> B",
    ]);
  });

  it("shows the source of a type with no text drawing, with the MC's reason", () => {
    const gantt = "gantt\n  title Launch";
    expect(
      shown(`~~~mermaid\n${gantt}\n~~~`, {
        [gantt]: {
          status: "unsupported",
          kind: "gantt",
          reason: "gantt diagrams have no text drawing yet.",
        },
      }),
    ).toEqual([
      "◇ gantt diagram",
      "gantt diagrams have no text drawing yet.",
      "gantt",
      "  title Launch",
    ]);
  });

  it("shows the source of a drawing too wide for the pane", () => {
    const lines = shown(
      `\`\`\`mermaid\n${FLOW}\n\`\`\``,
      { [FLOW]: { status: "drawn", kind: "flowchart", text: DRAWN } },
      12,
    );
    expect(lines).toEqual([
      "◇ flowchart diagram",
      "Drawn 21",
      "columns",
      "wide, wider",
      "than the 12",
      "here: its",
      "source",
      "instead.",
      "flowchart LR",
      "  Cart --> Paid",
    ]);
  });

  it("switches a drawn diagram to its source and back", () => {
    const answers = { [FLOW]: { status: "drawn", kind: "flowchart", text: DRAWN } } as const;
    const markdown = `\`\`\`mermaid\n${FLOW}\n\`\`\``;
    const lines = (source: boolean) =>
      markdownLines(markdown, THEME, 80, {
        get: (text) => answers[text as typeof FLOW],
        showSource: () => source,
      }).map(plainText);
    expect(lines(true)).toEqual([
      "◇ flowchart diagram · source",
      "flowchart LR",
      "  Cart --> Paid",
    ]);
    expect(lines(false)[1]).toBe(DRAWN.split("\n")[0]);
  });

  it("leaves a mermaid block as code where diagrams are not drawn", () => {
    expect(markdownLines(`\`\`\`mermaid\n${FLOW}\n\`\`\``, THEME).map(plainText)).toEqual(
      FLOW.split("\n"),
    );
  });

  it("finds the source of text that is one Mermaid block", () => {
    expect(mermaidFenceSource(`\`\`\`mermaid\n${FLOW}\n\`\`\`\n`)).toBe(FLOW);
    expect(mermaidFenceSource(`\`\`\`\` mermaid\n${FLOW}\n\`\`\`\``)).toBe(FLOW);
    expect(mermaidFenceSource(`\`\`\`ts\n${FLOW}\n\`\`\``)).toBeNull();
    expect(mermaidFenceSource(`\`\`\`mermaid\n${FLOW}`)).toBeNull();
    expect(mermaidFenceSource(`\`\`\`mermaid\n${FLOW}\n\`\`\`\nafter`)).toBeNull();
  });
});

describe("inlineMarkdown", () => {
  const spans = (text: string) =>
    inlineMarkdown(text, THEME).map((part) => [part.text, part.attributes ?? 0, part.link?.url]);

  it("draws GitHub's struck text, underscored italic, link titles and www addresses", () => {
    expect(
      spans('~~gone~~ _so_ [a](https://example.com "Title") www.example.com/a, snake_case_name'),
    ).toEqual([
      ["gone", TextAttributes.STRIKETHROUGH, undefined],
      [" ", 0, undefined],
      ["so", TextAttributes.ITALIC, undefined],
      [" ", 0, undefined],
      ["a", TextAttributes.UNDERLINE, "https://example.com"],
      [" ", 0, undefined],
      ["www.example.com/a", TextAttributes.UNDERLINE, "http://www.example.com/a"],
      [", snake_case_name", 0, undefined],
    ]);
  });

  it("keeps a balanced paren in a www address and leaves an unbalanced one out", () => {
    expect(spans("see www.example.com/a_(b) ok (www.example.com/c).")).toEqual([
      ["see ", 0, undefined],
      ["www.example.com/a_(b)", TextAttributes.UNDERLINE, "http://www.example.com/a_(b)"],
      [" ok (", 0, undefined],
      ["www.example.com/c", TextAttributes.UNDERLINE, "http://www.example.com/c"],
      [").", 0, undefined],
    ]);
  });
});

describe("wrapChunks", () => {
  it("breaks styled text at spaces as wrapWords does, keeping each style", () => {
    const lines = wrapChunks(
      [chunk("one two "), chunk("three four", { bold: true }), chunk("\nfive")],
      8,
    );
    expect(lines.map((parts) => parts.map((part) => part.text))).toEqual([
      ["one two"],
      ["three"],
      ["four"],
      ["five"],
    ]);
    expect(lines[1]![0]!.attributes).toBe(TextAttributes.BOLD);
  });

  it("joins a word's styles on one line and cuts a word wider than a line", () => {
    const lines = wrapChunks([chunk("ab"), chunk("cd", { italic: true }), chunk("efghijk ok")], 8);
    expect(lines.map((parts) => parts.map((part) => part.text))).toEqual([
      ["ab", "cd", "efgh"],
      ["ijk ok"],
    ]);
  });
});
