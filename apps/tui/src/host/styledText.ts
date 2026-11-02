import type { MermaidRenderResult } from "@hal-c2/contracts";
import { TextAttributes, type RGBA, type TextChunk } from "@opentui/core";

import { parseMarkdownTable, type MarkdownTable } from "../markdownTable.ts";
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
  /(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)|\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\s][^*\n]*)\*|(!)?\[([^\]\n]*)\]\(((?:[^()\s]|\([^()\s]*\))+)\)|<(https?:\/\/[^>\s]+)>/g;

/**
 * A link the terminal may open: the web, mail, or a path. A message's text is
 * untrusted, so any other scheme (`javascript:`, `data:`, `file:`) is no link.
 */
export function isSafeLink(url: string): boolean {
  const scheme = /^\s*([a-z][a-z0-9+.-]*):/i.exec(url)?.[1]?.toLowerCase();
  return scheme === undefined || scheme === "http" || scheme === "https" || scheme === "mailto";
}

/**
 * Inline Markdown: code spans, bold, italic, links and autolinks. An image is
 * a link to its address (nothing is fetched); a link that is not safe to open
 * is just its text. HTML is not Markdown here: it shows as it was written.
 */
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
    else if (match[8] !== undefined) {
      const url = match[8];
      const label = match[7] !== "" ? match[7]! : match[6] ? url : "";
      if (label === "") push(match[0], {});
      else if (isSafeLink(url)) push(label, { fg: palette.accent, underline: true, link: url });
      else push(label, {});
    } else if (match[9] !== undefined) {
      push(match[9], { fg: palette.accent, underline: true, link: match[9] });
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

/**
 * A pipe table boxed across `width` in equal columns, header cells in the list
 * style. A cell longer than its column wraps onto more lines of its row, or is
 * cut to one line when the table's cells are `collapsed`.
 */
function tableLines(
  table: MarkdownTable,
  width: number,
  palette: Palette,
  collapsed: boolean,
): StyledText[] {
  const count = Math.max(1, table.head.length);
  const inner = Math.max(count, width - count - 1);
  const widths = Array.from(
    { length: count },
    (_, index) => Math.floor(inner / count) + (index < inner % count ? 1 : 0),
  );
  const border = (left: string, mid: string, right: string) =>
    styled(chunk(left + widths.map((w) => "─".repeat(w)).join(mid) + right, { fg: palette.faint }));
  const row = (cells: ReadonlyArray<string>, style: ChunkStyle): StyledText[] => {
    const wrapped = widths.map((w, index) =>
      collapsed ? [clipCells(cells[index] ?? "", w)] : wrapCell(cells[index] ?? "", w),
    );
    const height = Math.max(1, ...wrapped.map((lines) => lines.length));
    return Array.from({ length: height }, (_, line) =>
      styled(
        ...widths.flatMap((w, index) => {
          const text = wrapped[index]![line] ?? "";
          return [
            chunk("│", { fg: palette.faint }),
            chunk(text, { fg: palette.text, ...style }),
            chunk(" ".repeat(Math.max(0, w - Bun.stringWidth(text)))),
          ];
        }),
        chunk("│", { fg: palette.faint }),
      ),
    );
  };
  return [
    border("┌", "┬", "┐"),
    ...row(table.head, { fg: palette.accent, bold: true }),
    border("├", "┼", "┤"),
    ...table.body.flatMap((cells) => row(cells, {})),
    border("└", "┴", "┘"),
  ];
}

/** A cell's text on as many lines of `width` as it needs, broken at spaces where it can be. */
function wrapCell(text: string, width: number): string[] {
  const lines: string[] = [];
  let current = "";
  for (const word of text.split(/\s+/).filter((part) => part.length > 0)) {
    let rest = word;
    const joined = current === "" ? rest : `${current} ${rest}`;
    if (Bun.stringWidth(joined) <= width) {
      current = joined;
      continue;
    }
    if (current !== "") lines.push(current);
    // A word wider than the column is cut across lines.
    while (Bun.stringWidth(rest) > width) {
      const head = clipCells(rest, width);
      if (head === "") break;
      lines.push(head);
      rest = rest.slice(head.length);
    }
    current = rest;
  }
  if (current !== "" || lines.length === 0) lines.push(current);
  return lines;
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
export function markdownLines(
  markdown: string,
  palette: Palette,
  width = 24,
  diagrams?: MarkdownDiagrams,
): StyledText[] {
  return markdownBlockLines(markdown, palette, width, undefined, diagrams).map(
    (entry) => entry.text,
  );
}

/** How Markdown shows its `mermaid` code blocks; without it they are code blocks. */
export interface MarkdownDiagrams {
  /** What the MC said of a diagram's source; undefined until it answers (`mermaidDiagrams.ts`). */
  readonly get: (source: string) => MermaidRenderResult | undefined;
  /** The diagrams (counted from 0) the user switched to their source. */
  readonly showSource?: (index: number) => boolean;
}

/** A line of rendered Markdown, with the code block or table it belongs to. */
export interface MarkdownLine {
  readonly text: StyledText;
  /**
   * The fenced code block this line is in (counted from 0), its whole source, the
   * first word of its info string, and whether its closing fence was written.
   */
  readonly code?: {
    readonly index: number;
    readonly source: string;
    readonly language: string;
    readonly closed: boolean;
  };
  /** The table this line is in (counted from 0). */
  readonly table?: { readonly index: number; readonly table: MarkdownTable };
  /** The alert this line titles (`> [!NOTE]`). */
  readonly alert?: string;
  /**
   * The Mermaid diagram this line is part of (counted from 0); its lines carry `code`
   * too, with the diagram's source. `title` is its first line; `drawable` when the
   * user can switch between its drawing and its source.
   */
  readonly diagram?: {
    readonly index: number;
    readonly title: boolean;
    readonly drawable: boolean;
  };
}

const ALERT = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i;

/** `markdownLines` with each line's block; `collapsedTables` cuts those tables' cells to a line. */
export function markdownBlockLines(
  markdown: string,
  palette: Palette,
  width = 24,
  collapsedTables: (index: number) => boolean = () => false,
  diagrams?: MarkdownDiagrams,
): MarkdownLine[] {
  const lines: MarkdownLine[] = [];
  const blankLast = () => lines.length === 0 || plainText(lines.at(-1)!.text) === "";
  const push = (...texts: StyledText[]) => {
    for (const text of texts) lines.push({ text });
  };
  const separate = () => {
    if (!blankLast()) push(styled(chunk("")));
  };
  let fence: string | null = null;
  let afterBlock = false;
  let table: string[] = [];
  let tableCount = 0;
  let codeCount = 0;
  let diagramCount = 0;
  // The open code block's lines: each carries the whole source once the block ends.
  let codeStart = -1;
  // The open block is a `mermaid` one (and diagrams are drawn).
  let mermaid = false;
  let language = "";
  const closeCode = (closed = false) => {
    if (codeStart < 0) return;
    const block = lines.slice(codeStart);
    const code = {
      index: codeCount,
      source: block.map((entry) => plainText(entry.text)).join("\n"),
      language,
      closed,
    };
    if (mermaid && closed && diagrams) {
      // Drawn only once its fence closes: a diagram being written is code so far.
      const index = diagramCount;
      const shown = mermaidLines(
        code.source,
        diagrams.get(code.source),
        palette,
        width,
        diagrams.showSource?.(index) ?? false,
      );
      lines.length = codeStart;
      shown.lines.forEach((text, offset) => {
        lines.push({
          text,
          code,
          diagram: { index, title: offset === 0, drawable: shown.drawable },
        });
      });
      diagramCount += 1;
    } else {
      block.forEach((entry, offset) => {
        lines[codeStart + offset] = { text: entry.text, code };
      });
    }
    codeCount += 1;
    codeStart = -1;
    mermaid = false;
  };
  let quoteOpen = false;
  const flushTable = () => {
    if (table.length === 0) return;
    separate();
    const parsed = parseMarkdownTable(table);
    const block = { index: tableCount, table: parsed };
    for (const text of tableLines(parsed, width, palette, collapsedTables(tableCount))) {
      lines.push({ text, table: block });
    }
    tableCount += 1;
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
        closeCode(true);
        afterBlock = true;
        continue;
      }
      push(styled(chunk(raw, { fg: palette.warning })));
      continue;
    }
    const quoted = raw.match(QUOTE);
    const startsQuote = quoted !== null && !quoteOpen;
    quoteOpen = quoted !== null;
    if (TABLE_ROW.test(raw)) {
      table.push(raw);
      continue;
    }
    flushTable();
    if (fenceMatch?.[1]) {
      fence = fenceMatch[1];
      mermaid = isMermaidInfo(raw.slice(fenceMatch[0].length));
      language = raw.slice(fenceMatch[0].length).trim().split(/\s+/)[0] ?? "";
      separate();
      codeStart = lines.length;
      continue;
    }
    if (raw.trim().length === 0) {
      // One blank line between blocks; none leading.
      if (!blankLast()) push(styled(chunk("")));
      afterBlock = false;
      continue;
    }
    if (afterBlock) separate();
    afterBlock = false;
    const heading = raw.match(HEADING);
    if (heading) {
      push({
        chunks: inlineMarkdown(heading[2] ?? "", palette, { fg: palette.accent, bold: true }),
      });
      continue;
    }
    if (RULE.test(raw)) {
      push(styled(chunk("─".repeat(Math.max(1, width)), { fg: palette.faint })));
      continue;
    }
    const item = raw.match(LIST_ITEM);
    if (item) {
      push(
        styled(
          item[1] ? chunk(item[1]) : null,
          chunk(item[2]!, { fg: palette.accent, bold: true }),
          chunk(" "),
          ...inlineMarkdown(item[3] ?? "", palette),
        ),
      );
      continue;
    }
    if (quoted) {
      // GitHub's alerts: a quote that opens with `[!NOTE]` alone on its line is titled by its kind.
      const alert = startsQuote ? ALERT.exec(quoted[1] ?? "")?.[1] : undefined;
      if (alert) {
        const title = alert[0]!.toUpperCase() + alert.slice(1).toLowerCase();
        lines.push({
          text: styled(
            chunk("│ ", { fg: alertColor(title, palette) }),
            chunk(title, { fg: alertColor(title, palette), bold: true }),
          ),
          alert: title,
        });
        continue;
      }
      push(
        styled(
          chunk("│ ", { fg: palette.faint }),
          ...inlineMarkdown(quoted[1] ?? "", palette, { fg: palette.dim, italic: true }),
        ),
      );
      continue;
    }
    push({ chunks: inlineMarkdown(raw, palette) });
  }
  // A code block still being written is a code block already.
  closeCode();
  flushTable();
  while (lines.length > 0 && plainText(lines.at(-1)!.text) === "") lines.pop();
  return lines;
}

/** A fence's info string names Mermaid (` ```mermaid `). */
const isMermaidInfo = (info: string) => info.trim().split(/\s+/)[0]?.toLowerCase() === "mermaid";

/**
 * The source of a Markdown text that is one `mermaid` code block and nothing else (a
 * page keeps such a block as written), or null.
 */
export function mermaidFenceSource(markdown: string): string | null {
  const lines = markdown.replace(/\r\n?/g, "\n").replace(/\n+$/, "").split("\n");
  const open = lines[0]?.match(FENCE);
  if (!open?.[1] || lines.length < 2 || !isMermaidInfo(lines[0]!.slice(open[0].length))) {
    return null;
  }
  const fence = open[1];
  const closes = (line: string) => {
    const close = /^[ \t]{0,3}(`{3,}|~{3,})\s*$/.exec(line)?.[1];
    return close !== undefined && close[0] === fence[0] && close.length >= fence.length;
  };
  const end = lines.findIndex((line, index) => index > 0 && closes(line));
  return end === lines.length - 1 ? lines.slice(1, end).join("\n") : null;
}

/** The type a diagram's source names itself by: its first word past front matter and comments. */
function mermaidKind(source: string): string | null {
  let lines = source.split("\n").map((line) => line.trim());
  if (lines.find((line) => line !== "") === "---") {
    const start = lines.indexOf("---");
    const end = lines.indexOf("---", start + 1);
    lines = end < 0 ? [] : lines.slice(end + 1);
  }
  const first = lines.find((line) => line !== "" && !line.startsWith("%%"));
  return first?.split(/\s+/)[0] ?? null;
}

/** A Mermaid diagram as the terminal shows it: a title line, then its drawing or its source. */
export interface MermaidView {
  readonly lines: StyledText[];
  /** The MC drew it in characters that fit: the user may switch to the source and back. */
  readonly drawable: boolean;
}

/**
 * A Mermaid diagram from what the MC said of it (`result`, undefined while it is asked):
 * its title names its type, then comes its drawing in characters when there is one that
 * fits `width` and the user has not asked for the `source`, else the source under the
 * reason it is not drawn, wrapped to `width`. Drawing and source are never wrapped.
 */
export function mermaidLines(
  source: string,
  result: MermaidRenderResult | undefined,
  palette: Palette,
  width: number,
  showSource = false,
): MermaidView {
  const kind = result?.kind ?? mermaidKind(source) ?? "Mermaid";
  const drawing =
    result?.status === "drawn" && result.text !== undefined
      ? result.text
          .replace(/\s+$/, "")
          .split("\n")
          .map((line) => line.trimEnd())
      : null;
  const wide = drawing ? Math.max(0, ...drawing.map((line) => Bun.stringWidth(line))) : 0;
  const drawable = drawing !== null && wide <= width;
  const note = result === undefined ? " · drawing…" : drawable && showSource ? " · source" : "";
  const title = styled(
    chunk(`◇ ${kind} diagram`, { fg: palette.accent, bold: true }),
    note !== "" && chunk(note, { fg: palette.dim }),
  );
  const sourceLines = source
    .split("\n")
    .map((line) => styled(chunk(line, { fg: palette.warning })));
  if (drawable && !showSource) {
    return {
      drawable,
      lines: [title, ...drawing.map((line) => styled(chunk(line, { fg: palette.text })))],
    };
  }
  const reason =
    result === undefined || drawable
      ? null
      : drawing
        ? {
            text: `Drawn ${wide} columns wide, wider than the ${width} here: its source instead.`,
            fg: palette.dim,
          }
        : result.status === "drawn"
          ? null
          : {
              text:
                result.line != null
                  ? `Line ${result.line}${result.column != null ? `, column ${result.column}` : ""}: ${result.reason}`
                  : result.reason,
              fg: result.status === "unsupported" ? palette.dim : palette.error,
            };
  return {
    drawable,
    lines: [
      title,
      ...(reason
        ? wrapCell(reason.text, Math.max(8, width)).map((text) =>
            styled(chunk(text, { fg: reason.fg })),
          )
        : []),
      ...sourceLines,
    ],
  };
}

function alertColor(title: string, palette: Palette): RGBA {
  switch (title) {
    case "Tip":
      return palette.success;
    case "Warning":
      return palette.warning;
    case "Caution":
      return palette.error;
    default:
      return palette.accent;
  }
}
