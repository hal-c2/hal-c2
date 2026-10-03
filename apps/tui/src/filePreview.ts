import { tableToMarkdown } from "./markdownTable.ts";

// Files the terminal can show rendered instead of as their text: Markdown as
// laid-out Markdown, delimited data as a table, HTML as the words on the page.
// Each becomes Markdown, which the timeline's renderer lays out.

export type RenderedFileKind = "markdown" | "table" | "html";

export function renderedFileKind(path: string): RenderedFileKind | null {
  const extension = /\.([a-z0-9]+)$/i.exec(path)?.[1]?.toLowerCase();
  if (extension === "md" || extension === "markdown" || extension === "mdx") return "markdown";
  if (extension === "csv" || extension === "tsv") return "table";
  if (extension === "html" || extension === "htm") return "html";
  return null;
}

/** One line of delimited data as its cells; quoted cells may hold the delimiter and `""`. */
function splitDelimited(line: string, delimiter: string): string[] {
  const cells: string[] = [];
  let cell = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index]!;
    if (quoted) {
      if (char === '"' && line[index + 1] === '"') {
        cell += '"';
        index += 1;
      } else if (char === '"') quoted = false;
      else cell += char;
    } else if (char === '"' && cell === "") quoted = true;
    else if (char === delimiter) {
      cells.push(cell);
      cell = "";
    } else cell += char;
  }
  cells.push(cell);
  return cells.map((value) => value.trim());
}

function tableMarkdown(contents: string, delimiter: string): string {
  const rows = contents
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .map((line) => splitDelimited(line, delimiter));
  if (rows.length === 0) return "";
  const [head, ...body] = rows;
  return tableToMarkdown({ head: head!, alignments: [], body });
}

const ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
};

/** The words of an HTML page as Markdown: headings, paragraphs, lists and links; no markup. */
function htmlMarkdown(contents: string): string {
  return contents
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<(script|style|head)\b[\s\S]*?<\/\1>/gi, "")
    .replace(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi, (_all, level: string, text: string) => {
      return `\n\n${"#".repeat(Number(level))} ${text.replace(/\s+/g, " ").trim()}\n\n`;
    })
    .replace(/<li\b[^>]*>/gi, "\n- ")
    .replace(/<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, "[$2]($1)")
    .replace(/<(br|\/p|\/div|\/tr|\/ul|\/ol|\/section|\/article)\b[^>]*>/gi, "\n\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&(#\d+|[a-z]+);/gi, (all, name: string) =>
      name.startsWith("#")
        ? String.fromCodePoint(Number(name.slice(1)))
        : (ENTITIES[name.toLowerCase()] ?? all),
    )
    .split("\n")
    .map((line) => line.replace(/[ \t]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** The Markdown a renderable file is shown as. */
export function renderedFileMarkdown(path: string, kind: RenderedFileKind, contents: string) {
  if (kind === "markdown") return contents;
  if (kind === "table")
    return tableMarkdown(contents, path.toLowerCase().endsWith(".tsv") ? "\t" : ",");
  return htmlMarkdown(contents);
}
