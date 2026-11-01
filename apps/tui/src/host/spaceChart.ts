// A chart block as lines of text: bars with their numbers, or a small table for a line
// chart, which a terminal cannot draw well. The description is untrusted data from the
// stream, so its strings lose anything that could steer a terminal, its size is capped
// as the MC caps it, and a number is shown as it is or not at all.
import { SPACE_CHART_LIMITS } from "@hal-c2/contracts";

import { clip } from "../format.ts";

/** One line of a chart's plot: the words before the bar, the bar, the number after it. */
export interface TuiChartLine {
  readonly words: string;
  readonly bar: string;
  readonly number: string;
  /** A table's header. */
  readonly header?: boolean;
}

interface ChartData {
  readonly type: string;
  readonly title: string;
  readonly source: string;
  readonly request: string;
  readonly labels: ReadonlyArray<string>;
  readonly series: ReadonlyArray<{
    readonly name: string;
    readonly values: ReadonlyArray<unknown>;
  }>;
}

type SeriesData = { readonly name?: unknown; readonly values?: unknown };

const PARTIAL = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];
/** A label or series name gives way to the bar at these fractions of the row. */
const LABEL_SHARE = 1 / 3;
const NAME_SHARE = 1 / 5;
const MIN_WORDS = 4;
const GAP = "  ";

const plain = (text: unknown): string =>
  typeof text === "string" ? text.replace(/\p{C}/gu, " ").trim() : "";

const widthOf = (text: string) => Bun.stringWidth(text);
const widest = (texts: ReadonlyArray<string>) => Math.max(0, ...texts.map(widthOf));
const padEnd = (text: string, width: number) =>
  `${text}${" ".repeat(Math.max(0, width - widthOf(text)))}`;
const padStart = (text: string, width: number) =>
  `${" ".repeat(Math.max(0, width - widthOf(text)))}${text}`;

const isValue = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);
const numberText = (value: unknown) => (isValue(value) ? String(value) : "–");

/** The chart `value` describes, made safe to draw; null when it is not one. */
export function chartData(value: unknown): ChartData | null {
  const chart = value as Partial<Record<keyof ChartData, unknown>> | null | undefined;
  if (typeof chart !== "object" || chart === null) return null;
  if (!Array.isArray(chart.labels) || !Array.isArray(chart.series)) return null;
  return {
    type: plain(chart.type),
    title: plain(chart.title),
    source: plain(chart.source),
    request: plain(chart.request),
    labels: chart.labels.slice(0, SPACE_CHART_LIMITS.labels).map(plain),
    series: chart.series.slice(0, SPACE_CHART_LIMITS.series).map((one: SeriesData | null) => ({
      name: plain(one?.name),
      values: Array.isArray(one?.values) ? one.values.slice(0, SPACE_CHART_LIMITS.labels) : [],
    })),
  };
}

/** `value` of `peak` in `cells` columns, to the eighth; anything above zero shows. */
function barOf(value: unknown, peak: number, cells: number): string {
  if (!isValue(value) || value <= 0 || peak <= 0 || cells <= 0) return "";
  const eighths = Math.min(cells * 8, Math.max(1, Math.round((value / peak) * cells * 8)));
  return `${"█".repeat(Math.floor(eighths / 8))}${PARTIAL[eighths % 8]}`;
}

/** A row per value: label, series name when there are several, bar if there is room, number. */
function barLines(chart: ChartData, width: number, drawBars: boolean): TuiChartLine[] {
  const several = chart.series.length > 1;
  const values = chart.series.flatMap((one) => one.values);
  const numberWidth = widest(values.map(numberText));
  const labelWidth = Math.min(
    widest(chart.labels),
    Math.max(MIN_WORDS, Math.floor(width * LABEL_SHARE)),
  );
  const nameWidth = several
    ? Math.min(
        widest(chart.series.map((one) => one.name)),
        Math.max(MIN_WORDS, Math.floor(width * NAME_SHARE)),
      )
    : 0;
  const wordsWidth = labelWidth + (several ? GAP.length + nameWidth : 0);
  const cells = drawBars ? Math.max(0, width - wordsWidth - numberWidth - 2 * GAP.length) : 0;
  const peak = Math.max(0, ...values.filter(isValue));
  return chart.labels.flatMap((label, row) =>
    chart.series.map((one, column) => {
      const value = one.values[row];
      const shownLabel = padEnd(column === 0 ? clip(label, labelWidth) : "", labelWidth);
      const bar = barOf(value, peak, cells);
      const name = several ? `${GAP}${padEnd(clip(one.name, nameWidth), nameWidth)}` : "";
      return {
        words: `${shownLabel}${name}${GAP}`,
        bar,
        number: `${" ".repeat(cells - widthOf(bar))}${GAP}${padStart(numberText(value), numberWidth)}`,
      };
    }),
  );
}

/** The labels down the side and a column per series; null when the numbers would not fit. */
function tableLines(chart: ChartData, width: number): TuiChartLine[] | null {
  const labelWidth = Math.min(
    widest(chart.labels),
    Math.max(MIN_WORDS, Math.floor(width * LABEL_SHARE)),
  );
  const columns = chart.series.map((one) => {
    const numbers = one.values.map(numberText);
    return {
      name: one.name,
      numbers,
      width: Math.max(widest(numbers), Math.min(widthOf(one.name), MIN_WORDS * 3)),
    };
  });
  const total = labelWidth + columns.reduce((sum, one) => sum + GAP.length + one.width, 0);
  if (total > width) return null;
  const row = (label: string, cell: (column: (typeof columns)[number]) => string) =>
    `${padEnd(clip(label, labelWidth), labelWidth)}${columns
      .map((column) => `${GAP}${padStart(cell(column), column.width)}`)
      .join("")}`;
  return [
    {
      words: row("", (column) => clip(column.name, column.width)),
      bar: "",
      number: "",
      header: true,
    },
    ...chart.labels.map((label, index) => ({
      words: row(label, (column) => column.numbers[index] ?? "–"),
      bar: "",
      number: "",
    })),
  ];
}

/** The lines that show `chart`'s numbers in `width` columns. */
export function chartLines(chart: ChartData, width: number): TuiChartLine[] {
  if (chart.type === "line") {
    // Too narrow for columns, a table is one number a row; no number is cut.
    return tableLines(chart, width) ?? barLines(chart, width, false);
  }
  return barLines(chart, width, true);
}
