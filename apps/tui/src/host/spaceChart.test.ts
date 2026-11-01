import { describe, expect, test } from "bun:test";

import { chartData, chartLines } from "./spaceChart.ts";

const data = (fields: Record<string, unknown> = {}) =>
  chartData({
    type: "bar",
    title: "Signups",
    source: "Numbers from this page",
    request: "signups",
    labels: ["May", "June"],
    series: [{ name: "Signups", values: [3, 6] }],
    ...fields,
  })!;

const texts = (chart: ReturnType<typeof data>, width: number) =>
  chartLines(chart, width).map((line) => `${line.words}${line.bar}${line.number}`);

describe("a bar chart", () => {
  test("draws bars in proportion and keeps the exact numbers beside them", () => {
    const [may, june] = chartLines(data(), 30);
    expect(june!.bar).toBe("█".repeat(30 - "June".length - "6".length - 4));
    expect(may!.bar.length).toBe(Math.ceil(june!.bar.length / 2));
    expect(may!.number.trim()).toBe("3");
    expect(june!.number.trim()).toBe("6");
  });

  test("gives a small number a sliver and zero nothing", () => {
    const [small, peak, zero] = chartLines(
      data({
        series: [
          { name: "s", values: [1, 0] },
          { name: "t", values: [1_000_000, 0] },
        ],
      }),
      30,
    );
    expect(small!.bar).toBe("▏");
    // 30 columns less "June", "s", "1000000" and the three gaps between them.
    expect(peak!.bar).toBe("█".repeat(12));
    expect(zero!.bar).toBe("");
  });

  test("names the series on each row when there are several", () => {
    const lines = texts(
      data({
        series: [
          { name: "Free", values: [1, 2] },
          { name: "Paid", values: [3, 4] },
        ],
      }),
      40,
    );
    expect(lines[0]).toStartWith("May   Free");
    expect(lines[1]).toStartWith("      Paid");
    expect(lines).toHaveLength(4);
  });

  test("gives way before the numbers do on a narrow terminal", () => {
    const lines = texts(data({ labels: ["A very long month name", "June"] }), 16);
    expect(lines[0]!.trimEnd().endsWith("3")).toBe(true);
    expect(lines[1]!.trimEnd().endsWith("6")).toBe(true);
    for (const line of lines) expect(Bun.stringWidth(line)).toBeLessThanOrEqual(16);
  });
});

describe("a line chart", () => {
  test("is a table with a column per series and no bars", () => {
    const lines = texts(
      data({
        type: "line",
        series: [
          { name: "Free", values: [1, 2] },
          { name: "Paid", values: [3, 4] },
        ],
      }),
      40,
    );
    expect(lines).toEqual(["      Free  Paid", "May      1     3", "June     2     4"]);
    expect(chartLines(data({ type: "line" }), 40)[0]!.header).toBe(true);
  });

  test("falls back to one number a row when the columns do not fit", () => {
    const lines = texts(
      data({
        type: "line",
        series: [
          { name: "Free", values: [1000001, 2] },
          { name: "Paid", values: [3000003, 4] },
          { name: "Team", values: [5000005, 6] },
        ],
      }),
      20,
    );
    expect(lines).toHaveLength(6);
    expect(lines.join("\n")).not.toContain("█");
    expect(lines[4]!.trimEnd().endsWith("5000005") || lines[2]!.trimEnd().endsWith("5000005")).toBe(
      true,
    );
  });
});

describe("the description is untrusted", () => {
  test("loses anything that could steer the terminal", () => {
    const chart = data({
      title: "\u001b]0;owned\u0007Signups",
      source: "from\u001b[2Jhere",
      labels: ["\u001b[31mMay", "Ju‮ne"],
    });
    const everything = [chart.title, chart.source, ...chart.labels].join("");
    expect(everything).not.toMatch(/\p{C}/u);
    expect(texts(chart, 40).join("")).not.toMatch(/\p{C}/u);
  });

  test("is capped as the MC caps it", () => {
    const labels = Array.from({ length: 100 }, (_, index) => `l${index}`);
    const values = labels.map((_, index) => index);
    const chart = data({
      labels,
      series: Array.from({ length: 10 }, () => ({ name: "s", values })),
    });
    expect(chart.labels).toHaveLength(24);
    expect(chart.series).toHaveLength(4);
    expect(chart.series[0]!.values).toHaveLength(24);
  });

  test("shows a value that is not a number as no number, with no bar", () => {
    const [may, june] = chartLines(
      data({ series: [{ name: "s", values: ["3", Number.POSITIVE_INFINITY] }] }),
      30,
    );
    expect(may!.bar).toBe("");
    expect(may!.number.trim()).toBe("–");
    expect(june!.number.trim()).toBe("–");
  });

  test("is no chart when it does not have the shape of one", () => {
    expect(chartData(null)).toBeNull();
    expect(chartData("chart")).toBeNull();
    expect(chartData({ labels: "May", series: [] })).toBeNull();
  });
});
