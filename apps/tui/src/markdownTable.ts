// A Markdown pipe table as data: its cells for drawing, and the two forms the
// clipboard takes (port of apps/web/src/markdown-clipboard.ts).

export type TableAlignment = "left" | "center" | "right" | null;

export interface MarkdownTable {
  readonly head: ReadonlyArray<string>;
  readonly alignments: ReadonlyArray<TableAlignment>;
  readonly body: ReadonlyArray<ReadonlyArray<string>>;
}

const DIVIDER = /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/;

/** A row's cells: split on pipes that are not escaped, `\|` read as a pipe. */
function rowCells(row: string): string[] {
  const trimmed = row
    .trim()
    .replace(/^\|/, "")
    .replace(/(?<!\\)\|$/, "");
  return trimmed.split(/(?<!\\)\|/).map((cell) => cell.trim().replace(/\\\|/g, "|"));
}

function alignment(cell: string): TableAlignment {
  const left = cell.startsWith(":");
  const right = cell.endsWith(":");
  return left && right ? "center" : right ? "right" : left ? "left" : null;
}

export function parseMarkdownTable(rows: ReadonlyArray<string>): MarkdownTable {
  const divider = rows.find((row) => DIVIDER.test(row));
  const [head = [], ...body] = rows.filter((row) => !DIVIDER.test(row)).map(rowCells);
  return { head, alignments: divider ? rowCells(divider).map(alignment) : [], body };
}

const DIVIDERS: Record<string, string> = { left: ":---", center: ":---:", right: "---:" };

export function tableToMarkdown(table: MarkdownTable): string {
  const row = (cells: ReadonlyArray<string>) =>
    `| ${cells.map((cell) => cell.replace(/\|/g, "\\|")).join(" | ")} |`;
  return [
    row(table.head),
    row(table.head.map((_, index) => DIVIDERS[table.alignments[index] ?? ""] ?? "---")),
    ...table.body.map(row),
  ].join("\n");
}

export function tableToCsv(table: MarkdownTable): string {
  const cell = (text: string) => (/[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text);
  return [table.head, ...table.body].map((cells) => cells.map(cell).join(",")).join("\n");
}
