import { describe, expect, test } from "bun:test";

import type { SpaceBlock } from "@hal-c2/contracts";

import { listItems, markdownFrame } from "./spaceMarkdown.ts";

const block = (fields: Partial<SpaceBlock>) =>
  ({ kind: "paragraph", text: "", ...fields }) as SpaceBlock;

// Each block's line as the MC writes it, its text after what is in front of it.
const leads = (blocks: SpaceBlock[]) =>
  listItems(blocks).map(
    (item, index) => `${markdownFrame(blocks[index]!, item).lead}${blocks[index]!.text}`,
  );

describe("list items", () => {
  test("count on within a list and start again in another", () => {
    const blocks = [
      block({ kind: "numbered", text: "One", start: 7 }),
      block({ kind: "numbered", text: "Two" }),
      block({ kind: "numbered", text: "Other", marker: ")" }),
      block({ kind: "bullet", text: "Dot" }),
      block({ kind: "numbered", text: "Again" }),
    ];
    expect(leads(blocks)).toEqual(["7. One", "8. Two", "1) Other", "- Dot", "1. Again"]);
  });

  test("nest at most one deeper than the item above, under its text", () => {
    const blocks = [
      block({ kind: "bullet", text: "Top", depth: 2 }),
      block({ kind: "numbered", text: "In", depth: 3 }),
      block({ kind: "checklist", text: "Done", depth: 2, checked: true }),
    ];
    expect(leads(blocks)).toEqual(["- Top", "  1. In", "     - [x] Done"]);
  });

  test("keep an indent the MC would keep and drop one it would not", () => {
    const blocks = [
      block({ kind: "bullet", text: "Top", indent: 2 }),
      block({ kind: "bullet", text: "Under", depth: 1, indent: 9 }),
      block({ kind: "bullet", text: "Beside", indent: 1 }),
    ];
    expect(leads(blocks)).toEqual(["  - Top", "    - Under", " - Beside"]);
  });

  test("end at any other block", () => {
    const blocks = [
      block({ kind: "numbered", text: "One" }),
      block({ kind: "paragraph", text: "Between" }),
      block({ kind: "numbered", text: "Two", depth: 1 }),
    ];
    expect(leads(blocks)).toEqual(["1. One", "Between", "1. Two"]);
  });
});

describe("math", () => {
  const frame = (fields: Partial<SpaceBlock>) =>
    markdownFrame(block({ kind: "code", language: "math", ...fields }), null);

  test("keeps its dollars unless a line would end them", () => {
    expect(frame({ text: "x^2", fence: "$$" })).toMatchObject({ above: "$$", below: "$$" });
    expect(frame({ text: "a\n\nb", fence: "$$" })).toMatchObject({
      above: "```math",
      below: "```",
    });
  });

  test("is fenced longer than any line that would close it", () => {
    expect(frame({ text: "```\nx", fence: "```", info: " {#e}" })).toMatchObject({
      above: "````math {#e}",
      below: "````",
    });
  });

  test("is the only code with fences", () => {
    expect(markdownFrame(block({ kind: "code", language: "ts", text: "x" }), null)).toEqual({
      above: "",
      lead: "",
      tail: "",
      below: "",
    });
  });
});
