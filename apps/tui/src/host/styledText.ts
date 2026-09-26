import { TextAttributes, type RGBA, type TextChunk } from "@opentui/core";

import type { Palette } from "../theme.ts";

// Styled text for `Shell.state`: a QML `Text { text: line }` renders any
// object with a `chunks` array, so the host pre-styles timeline lines and the
// bricks stay dumb. Markdown goes through a small line formatter instead of
// OpenTUI's Markdown renderable, whose syntax style and async code highlighting
// cannot be driven from QML.

export interface StyledText {
  readonly chunks: ReadonlyArray<TextChunk>;
}

export interface ChunkStyle {
  readonly fg?: RGBA;
  readonly bg?: RGBA;
  readonly bold?: boolean;
  readonly italic?: boolean;
  readonly underline?: boolean;
  readonly link?: string;
}

export function chunk(text: string, style: ChunkStyle = {}): TextChunk {
  const attributes =
    (style.bold ? TextAttributes.BOLD : 0) |
    (style.italic ? TextAttributes.ITALIC : 0) |
    (style.underline ? TextAttributes.UNDERLINE : 0);
  return {
    __isChunk: true,
    text,
    ...(style.fg ? { fg: style.fg } : {}),
    ...(style.bg ? { bg: style.bg } : {}),
    ...(attributes ? { attributes } : {}),
    ...(style.link ? { link: { url: style.link } } : {}),
  };
}

export const styled = (...chunks: ReadonlyArray<TextChunk | null | false>): StyledText => ({
  chunks: chunks.filter((part): part is TextChunk => Boolean(part)),
});

/** The plain text of a styled line (steps and tests read it). */
export const plainText = (text: StyledText): string => text.chunks.map((c) => c.text).join("");

const INLINE =
  /(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)|\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\s][^*\n]*)\*|\[([^\]\n]+)\]\(([^)\s]+)\)|<(https?:\/\/[^>\s]+)>/g;

/** Inline Markdown: code spans, bold, italic, links and autolinks. */
export function inlineMarkdown(text: string, palette: Palette, base: ChunkStyle = {}): TextChunk[] {
  const chunks: TextChunk[] = [];
  let last = 0;
  const push = (value: string, style: ChunkStyle) => {
    if (value.length > 0) chunks.push(chunk(value, { fg: palette.text, ...base, ...style }));
  };
  for (const match of text.matchAll(INLINE)) {
    const index = match.index ?? 0;
    push(text.slice(last, index), {});
    last = index + match[0].length;
    if (match[2] !== undefined) push(match[2], { fg: palette.warning });
    else if (match[3] !== undefined || match[4] !== undefined) {
      push(match[3] ?? match[4]!, { bold: true });
    } else if (match[5] !== undefined) push(match[5], { italic: true });
    else if (match[6] !== undefined) {
      push(match[6], { fg: palette.accent, underline: true, link: match[7]! });
    } else if (match[8] !== undefined) {
      push(match[8], { fg: palette.accent, underline: true, link: match[8] });
    }
  }
  push(text.slice(last), {});
  return chunks;
}

const FENCE = /^[ \t]{0,3}(`{3,}|~{3,})/;
const HEADING = /^[ \t]{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
const LIST_ITEM = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const QUOTE = /^[ \t]{0,3}>\s?(.*)$/;
const RULE = /^[ \t]{0,3}([-*_])(?:\s*\1){2,}\s*$/;
const TABLE_ROW = /^\s*\|.*\|\s*$/;
const TABLE_DIVIDER = /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/;

const tableCells = (row: string): string[] =>
  row
    .trim()
    .replace(/^\||\|$/g, "")
    .split("|")
    .map((cell) => cell.trim());

/** A pipe table boxed across `width` in equal columns, header cells in the list style. */
function tableLines(rows: ReadonlyArray<string>, width: number, palette: Palette): StyledText[] {
  const [head = [], ...body] = rows.filter((row) => !TABLE_DIVIDER.test(row)).map(tableCells);
  const count = Math.max(1, head.length);
  const inner = Math.max(count, width - count - 1);
  const widths = Array.from(
    { length: count },
    (_, index) => Math.floor(inner / count) + (index < inner % count ? 1 : 0),
  );
  const border = (left: string, mid: string, right: string) =>
    styled(chunk(left + widths.map((w) => "─".repeat(w)).join(mid) + right, { fg: palette.faint }));
  const row = (cells: ReadonlyArray<string>, style: ChunkStyle) =>
    styled(
      ...widths.flatMap((w, index) => {
        const text = clipCells(cells[index] ?? "", w);
        return [
          chunk("│", { fg: palette.faint }),
          chunk(text, { fg: palette.text, ...style }),
          chunk(" ".repeat(Math.max(0, w - Bun.stringWidth(text)))),
        ];
      }),
      chunk("│", { fg: palette.faint }),
    );
  return [
    border("┌", "┬", "┐"),
    row(head, { fg: palette.accent, bold: true }),
    border("├", "┼", "┤"),
    ...body.map((cells) => row(cells, {})),
    border("└", "┴", "┘"),
  ];
}

function clipCells(text: string, width: number): string {
  if (Bun.stringWidth(text) <= width) return text;
  let out = "";
  for (const char of text) {
    if (Bun.stringWidth(out + char) > width) break;
    out += char;
  }
  return out;
}

/**
 * Markdown as styled lines, laid out like OpenTUI's Markdown renderable with
 * the TUI syntax style (theme.ts createTuiSyntaxStyle): headings bold in the
 * accent colour, list markers as written in bold accent, fenced code in the
 * code colour and set off by a blank line on each side, quotes behind a faint
 * bar, rules and tables across `width`, inline emphasis, code spans and links.
 */
export function markdownLines(markdown: string, palette: Palette, width = 24): StyledText[] {
  const lines: StyledText[] = [];
  const blankLast = () => lines.length === 0 || plainText(lines.at(-1)!) === "";
  const separate = () => {
    if (!blankLast()) lines.push(styled(chunk("")));
  };
  let fence: string | null = null;
  let afterBlock = false;
  let table: string[] = [];
  const flushTable = () => {
    if (table.length === 0) return;
    separate();
    lines.push(...tableLines(table, width, palette));
    table = [];
    afterBlock = true;
  };
  for (const raw of markdown.replace(/\r\n?/g, "\n").split("\n")) {
    const fenceMatch = raw.match(FENCE);
    if (fence !== null) {
      if (
        fenceMatch?.[1] &&
        fenceMatch[1][0] === fence[0] &&
        fenceMatch[1].length >= fence.length
      ) {
        fence = null;
        afterBlock = true;
        continue;
      }
      lines.push(styled(chunk(raw, { fg: palette.warning })));
      continue;
    }
    if (TABLE_ROW.test(raw)) {
      table.push(raw);
      continue;
    }
    flushTable();
    if (fenceMatch?.[1]) {
      fence = fenceMatch[1];
      separate();
      continue;
    }
    if (raw.trim().length === 0) {
      // One blank line between blocks; none leading.
      if (!blankLast()) lines.push(styled(chunk("")));
      afterBlock = false;
      continue;
    }
    if (afterBlock) separate();
    afterBlock = false;
    const heading = raw.match(HEADING);
    if (heading) {
      lines.push({
        chunks: inlineMarkdown(heading[2] ?? "", palette, { fg: palette.accent, bold: true }),
      });
      continue;
    }
    if (RULE.test(raw)) {
      lines.push(styled(chunk("─".repeat(Math.max(1, width)), { fg: palette.faint })));
      continue;
    }
    const item = raw.match(LIST_ITEM);
    if (item) {
      lines.push(
        styled(
          item[1] ? chunk(item[1]) : null,
          chunk(item[2]!, { fg: palette.accent, bold: true }),
          chunk(" "),
          ...inlineMarkdown(item[3] ?? "", palette),
        ),
      );
      continue;
    }
    const quote = raw.match(QUOTE);
    if (quote) {
      lines.push(
        styled(
          chunk("│ ", { fg: palette.faint }),
          ...inlineMarkdown(quote[1] ?? "", palette, { fg: palette.dim, italic: true }),
        ),
      );
      continue;
    }
    lines.push({ chunks: inlineMarkdown(raw, palette) });
  }
  flushTable();
  while (lines.length > 0 && plainText(lines.at(-1)!) === "") lines.pop();
  return lines;
}
