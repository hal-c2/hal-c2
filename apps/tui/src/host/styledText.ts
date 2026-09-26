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

/**
 * Markdown as styled lines: headings bold in the accent colour, list markers
 * in the accent colour, fenced code in the code colour (no inline styling or
 * links inside it), quotes dimmed, inline emphasis, code spans and links.
 */
export function markdownLines(markdown: string, palette: Palette): StyledText[] {
  const lines: StyledText[] = [];
  let fence: string | null = null;
  let blank = false;
  for (const raw of markdown.replace(/\r\n?/g, "\n").split("\n")) {
    const fenceMatch = raw.match(FENCE);
    if (fence !== null) {
      if (fenceMatch?.[1] && fenceMatch[1][0] === fence[0] && fenceMatch[1].length >= fence.length) {
        fence = null;
        continue;
      }
      lines.push(styled(chunk(`  ${raw}`, { fg: palette.warning })));
      blank = false;
      continue;
    }
    if (fenceMatch?.[1]) {
      fence = fenceMatch[1];
      continue;
    }
    if (raw.trim().length === 0) {
      // One blank line between blocks; none leading.
      if (!blank && lines.length > 0) lines.push(styled(chunk("")));
      blank = true;
      continue;
    }
    blank = false;
    const heading = raw.match(HEADING);
    if (heading) {
      lines.push({
        chunks: inlineMarkdown(heading[2] ?? "", palette, { fg: palette.accent, bold: true }),
      });
      continue;
    }
    if (RULE.test(raw)) {
      lines.push(styled(chunk("─".repeat(24), { fg: palette.faint })));
      continue;
    }
    const item = raw.match(LIST_ITEM);
    if (item) {
      const marker = /\d/.test(item[2]!) ? item[2]! : "•";
      lines.push(
        styled(
          chunk(`${item[1]}${marker} `, { fg: palette.accent }),
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
  while (lines.length > 0 && plainText(lines.at(-1)!) === "") lines.pop();
  return lines;
}
