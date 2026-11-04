import {
  getTreeSitterClient,
  infoStringToFiletype,
  SyntaxStyle,
  treeSitterToTextChunks,
  type SimpleHighlight,
  type TextChunk,
} from "@opentui/core";

import type { Palette } from "../theme.ts";

// Code coloured by its fence's language with OpenTUI's tree-sitter, which reads it in a
// worker off the render loop. Until it has been read, code shows plain. What was read is
// kept as tree-sitter's scopes, by language and text, so a redraw, a scroll or a page
// showing the same code never reads it again, and a theme change only maps the scopes to
// the new palette. A block still being written is read up to its last finished line; the
// line being written waits, and while a longer read is under way the lines read before
// keep their colours. Languages OpenTUI ships no grammar for, and code past `MAX_CHARS`,
// stay plain. Replies, pages and the file viewer share one of these.

/** Code read at most; what follows shows plain (the desktop's CodeHighlighter::kMaxChars). */
export const MAX_CHARS = 512 * 1024;
/** Readings kept at once; the one used longest ago goes first. */
const KEPT = 256;
/** Text kept across all readings, in UTF-16 units: 32 MB, the desktop's codereader cache. */
const KEPT_CHARS = 16 * 1024 * 1024;

/** Reads `text` as `filetype`: its scopes, or null when there is no grammar for it. */
export type ReadCode = (text: string, filetype: string) => Promise<SimpleHighlight[] | null>;

export interface CodeColours {
  /**
   * The lines of a code block coloured as its fence's `info` string names, or null to show
   * it plain. Only the lines read so far come back: fewer than the block has while a line
   * is being written or still being read. The first ask for some code reads it.
   */
  readonly lines: (
    info: string,
    source: string,
    closed: boolean,
    palette: Palette,
  ) => ReadonlyArray<ReadonlyArray<TextChunk>> | null;
  /** `onChange` runs whenever a reading arrives; returns the unsubscribe. */
  readonly listen: (onChange: () => void) => () => void;
  /** Resolves once every reading asked for so far has arrived. */
  readonly settled: () => Promise<void>;
}

/** OpenTUI's tree-sitter worker, which knows the grammars OpenTUI ships. */
export const readWithTreeSitter: ReadCode = async (text, filetype) => {
  const client = getTreeSitterClient();
  // Only `highlightOnce` starts the worker by itself; asking for a parser first needs it
  // started, or there is no grammar yet to find.
  await client.initialize();
  if (!(await client.preloadParser(filetype))) return null;
  const result = await client.highlightOnce(text, filetype);
  return result.highlights ?? null;
};

/** The grammar a fence's info string names, or null for none (an empty fence, a diagram). */
export function fenceFiletype(info: string): string | null {
  const token = info.trim().split(/\s+/)[0]?.toLowerCase() ?? "";
  if (token === "" || token === "mermaid") return null;
  return infoStringToFiletype(token) ?? null;
}

interface Reading {
  readonly key: string;
  readonly filetype: string;
  readonly text: string;
  /** Undefined while it is read; null when it has no colours. */
  scopes: SimpleHighlight[] | null | undefined;
  /** Its lines as last coloured, and the style they were coloured with. */
  coloured?: { readonly style: SyntaxStyle; readonly lines: TextChunk[][] };
}

/** What of `source` is read: its finished lines, up to `MAX_CHARS`. */
function readable(source: string, closed: boolean): string {
  const finished = closed ? source : source.slice(0, source.lastIndexOf("\n") + 1);
  if (finished.length <= MAX_CHARS) return finished;
  // Cut by the cap: the line it cuts waits with the rest.
  return finished.slice(0, finished.lastIndexOf("\n", MAX_CHARS) + 1);
}

export function createCodeColours(read: ReadCode = readWithTreeSitter): CodeColours {
  const readings = new Map<string, Reading>();
  const listeners = new Set<() => void>();
  const inFlight = new Set<Promise<unknown>>();
  const changed = () => {
    for (const listener of listeners) listener();
  };

  // Text held by the readings kept, against KEPT_CHARS.
  let held = 0;
  const forget = (reading: Reading) => {
    if (readings.get(reading.key) !== reading) return;
    readings.delete(reading.key);
    held -= reading.text.length;
  };

  const evict = () => {
    for (const reading of readings.values()) {
      if (readings.size <= KEPT && held <= KEPT_CHARS) return;
      if (reading.scopes !== undefined) forget(reading);
    }
  };

  const ask = (key: string, filetype: string, text: string) => {
    const reading: Reading = { key, filetype, text, scopes: undefined };
    readings.set(key, reading);
    held += text.length;
    evict();
    // A read that fails is forgotten rather than kept as "no grammar", so the code is
    // asked for again the next time it is drawn.
    const promise = read(text, filetype).then(
      (scopes) => {
        // A growing block's reading of fewer lines is not wanted once this one has landed,
        // so streaming a block keeps one copy of it rather than one per step. Other code
        // that this starts with goes too, and is read again if it is drawn again.
        const older = before(filetype, text, true);
        if (older) forget(older);
        reading.scopes = scopes;
        changed();
      },
      () => forget(reading),
    );
    inFlight.add(promise);
    void promise.finally(() => inFlight.delete(promise));
  };

  // The reading of the longest text `text` starts with: the lines read before it grew.
  // With `landed`, only readings that have arrived count.
  const before = (filetype: string, text: string, landed = false): Reading | null => {
    let best: Reading | null = null;
    for (const reading of readings.values()) {
      if (reading.filetype !== filetype || reading.text.length >= text.length) continue;
      if (landed && reading.scopes === undefined) continue;
      if (best && reading.text.length <= best.text.length) continue;
      if (text.startsWith(reading.text)) best = reading;
    }
    return best;
  };

  const colour = (reading: Reading, palette: Palette) => {
    if (!reading.scopes) return null;
    const style = styleFor(palette);
    if (reading.coloured?.style !== style) {
      const chunks = treeSitterToTextChunks(reading.text, matching(reading), style);
      reading.coloured = { style, lines: splitLines(chunks) };
    }
    return reading.coloured.lines;
  };

  return {
    lines: (info, source, closed, palette) => {
      const filetype = fenceFiletype(info);
      if (filetype === null) return null;
      const text = readable(source, closed);
      if (text === "") return null;
      const key = `${filetype}\0${text}`;
      const kept = readings.get(key);
      if (kept) {
        // Used now: the last to go.
        readings.delete(key);
        readings.set(key, kept);
        if (kept.scopes !== undefined) return colour(kept, palette);
      }
      // What is shown meanwhile: the longest of its lines read so far.
      const shown = before(filetype, text, true);
      // A language without a grammar stays plain, however the block grows.
      if (shown?.scopes === null) return null;
      // One reading at a time for a growing block: the next starts when the last lands.
      const last = before(filetype, text);
      if (!kept && (last === null || last.scopes !== undefined)) ask(key, filetype, text);
      return shown ? colour(shown, palette) : null;
    },
    listen: (onChange) => {
      listeners.add(onChange);
      return () => listeners.delete(onChange);
    },
    settled: async () => {
      while (inFlight.size > 0) await Promise.allSettled(inFlight);
    },
  };
}

/**
 * The scopes whose conditions hold. OpenTUI's queries test some captures with
 * `#lua-match?`, which its tree-sitter does not run, so every name would read as a type
 * and a constant: a type starts with a capital, a constant is all capitals.
 */
function matching(reading: Reading): SimpleHighlight[] {
  return reading.scopes!.filter(([start, end, scope]) => {
    if (scope === "type") return /^[A-Z]/.test(reading.text.slice(start, end));
    if (scope === "constant") return /^_*[A-Z][A-Z\d_]*$/.test(reading.text.slice(start, end));
    return true;
  });
}

const sameLook = (a: TextChunk, b: TextChunk) =>
  a.attributes === b.attributes &&
  a.link?.url === b.link?.url &&
  (a.fg === b.fg || (a.fg !== undefined && b.fg !== undefined && a.fg.equals(b.fg))) &&
  (a.bg === b.bg || (a.bg !== undefined && b.bg !== undefined && a.bg.equals(b.bg)));

/** Chunks spanning several lines, as each line's chunks; neighbours that look alike join. */
function splitLines(chunks: ReadonlyArray<TextChunk>): TextChunk[][] {
  const lines: TextChunk[][] = [[]];
  for (const part of chunks) {
    part.text.split("\n").forEach((piece, index) => {
      if (index > 0) lines.push([]);
      if (piece === "") return;
      const line = lines.at(-1)!;
      const last = line.at(-1);
      if (last && sameLook(last, part))
        line[line.length - 1] = { ...last, text: last.text + piece };
      else line.push({ ...part, text: piece });
    });
  }
  // The text read ends with a newline unless the block was closed: no line follows it.
  if (lines.length > 1 && lines.at(-1)!.length === 0) lines.pop();
  return lines;
}

// One style per palette, made again when the theme rewrites the palette's colours.
const styles = new WeakMap<Palette, { readonly from: Palette; readonly style: SyntaxStyle }>();

function styleFor(palette: Palette): SyntaxStyle {
  const kept = styles.get(palette);
  const from = { ...palette };
  if (kept && (Object.keys(from) as Array<keyof Palette>).every((k) => kept.from[k] === from[k])) {
    return kept.style;
  }
  kept?.style.destroy();
  const style = SyntaxStyle.fromStyles({
    default: { fg: palette.text },
    keyword: { fg: palette.keyword },
    "variable.builtin": { fg: palette.keyword },
    string: { fg: palette.string },
    character: { fg: palette.string },
    number: { fg: palette.number },
    float: { fg: palette.number },
    boolean: { fg: palette.number },
    constant: { fg: palette.number },
    function: { fg: palette.function },
    method: { fg: palette.function },
    constructor: { fg: palette.function },
    type: { fg: palette.type },
    attribute: { fg: palette.type },
    module: { fg: palette.type },
    tag: { fg: palette.keyword },
    label: { fg: palette.type },
    comment: { fg: palette.faint, italic: true },
    "markup.heading": { fg: palette.accent, bold: true },
    "markup.strong": { bold: true },
    "markup.italic": { italic: true },
    "markup.raw": { fg: palette.string },
    "markup.list": { fg: palette.accent },
    "markup.link": { fg: palette.accent, underline: true },
  });
  styles.set(palette, { from, style });
  return style;
}
