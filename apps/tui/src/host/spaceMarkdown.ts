import type { SpaceBlock } from "@hal-c2/contracts";

/** A list item where the MC writes it: its indent and its marker, `-` or `3.` and so on. */
export interface SpaceListItem {
  readonly depth: number;
  readonly indent: number;
  readonly marker: string;
  readonly number: number;
  readonly column: number;
  readonly list: string;
}

const LISTS = new Set(["bullet", "numbered", "checklist"]);

/**
 * Where each block sits as a list item, as `HalC2.Space.Markdown.list_items/1` places it:
 * null for a block that is not one. An item is under the open items above it, at most one
 * deeper than the deepest, and a numbered item counts on from the one before it at its
 * depth in the same list (the same delimiter), else from its `start` or 1. Any other
 * block ends the list.
 */
export function listItems(blocks: ReadonlyArray<SpaceBlock>): Array<SpaceListItem | null> {
  let open: SpaceListItem[] = []; // deepest first
  return blocks.map((block) => {
    if (!LISTS.has(block.kind)) {
      open = [];
      return null;
    }
    const depth = Math.min(Math.max(0, block.depth ?? 0), open.length);
    let closed = 0;
    while (closed < open.length && open[closed]!.depth >= depth) closed += 1;
    const sibling = closed > 0 ? open[closed - 1] : undefined;
    const parents = open.slice(closed);
    const floor = parents[0]?.column ?? 0;
    const numbered = block.kind === "numbered";
    const delimiter = block.marker === ")" ? ")" : ".";
    const bullet =
      block.kind === "bullet" && (block.marker === "*" || block.marker === "+")
        ? block.marker
        : "-";
    const list = numbered ? `numbered${delimiter}` : bullet;
    const start = block.start !== undefined && block.start >= 0 ? block.start : 1;
    const number = !numbered ? 0 : sibling?.list === list ? sibling.number + 1 : start;
    const marker = numbered ? `${number}${delimiter}` : bullet;
    const ceiling = sibling ? Math.min(floor + 3, sibling.column - 1) : floor + 3;
    const indent =
      block.indent !== undefined && block.indent >= floor && block.indent <= ceiling
        ? block.indent
        : floor;
    const item = { depth, indent, marker, number, column: indent + marker.length + 1, list };
    open = [item, ...parents];
    return item;
  });
}

/** What the MC writes above a block's text, before and after it on its line, and below it. */
export interface SpaceMarkdownFrame {
  readonly above: string;
  readonly lead: string;
  readonly tail: string;
  readonly below: string;
}

// A line that closes code fenced by `fence`, as the MC reads it.
const closesFence = (line: string, fence: string) => {
  const close = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line)?.[1];
  return close !== undefined && close[0] === fence[0] && close >= fence;
};

/**
 * What the MC writes around a block's text (`HalC2.Space.Markdown.render/2`), for the kinds
 * a page does not draw yet (#869, #877): a list item's indent and marker, an alert's kind,
 * a divider and a section's end (which have no text), a footnote's label, a section's
 * summary tags and math's fences. The text between stays the block's own.
 */
export function markdownFrame(block: SpaceBlock, item: SpaceListItem | null): SpaceMarkdownFrame {
  const none = { above: "", lead: "", tail: "", below: "" };
  if (item) {
    const tick = block.kind === "checklist" ? (block.checked ? " [x]" : " [ ]") : "";
    return { ...none, lead: `${" ".repeat(item.indent)}${item.marker}${tick} ` };
  }
  switch (block.kind) {
    case "callout":
      return block.alert ? { ...none, above: `[!${block.alert.toUpperCase()}]` } : none;
    case "divider":
      return { ...none, lead: "---" };
    case "footnote":
      return { ...none, lead: `[^${block.label ?? ""}]: ` };
    case "details":
      return { ...none, above: "<details>", lead: "<summary>", tail: "</summary>" };
    case "details_end":
      return { ...none, lead: "</details>" };
    case "code": {
      if (block.language !== "math") return none;
      const lines = block.text === "" ? [] : block.text.split("\n");
      // Math holding a `$$` line or a blank one is fenced instead, as the MC writes it.
      if (block.fence === "$$" && !lines.some((line) => ["$$", ""].includes(line.trim()))) {
        return { ...none, above: "$$", below: "$$" };
      }
      let fence = block.fence && block.fence !== "$$" ? block.fence : "```";
      while (lines.some((line) => closesFence(line, fence))) fence += fence[0];
      return { ...none, above: `${fence}math${block.info ?? ""}`, below: fence };
    }
    default:
      return none;
  }
}
