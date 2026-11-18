import { describe, expect, it } from "bun:test";

import type { TuiSubagent } from "../orchestrationV2Adapter.ts";
import {
  agentTitle,
  buildTuiAgentsState,
  formatElapsed,
  formatModelSlug,
  type AgentBlock,
} from "./agentsState.ts";

const NOW = Date.parse("2026-07-14T01:00:00.000Z");
const at = (secondsAgo: number) => new Date(NOW - secondsAgo * 1000).toISOString();

const agent = (id: string, patch: Partial<TuiSubagent> = {}): TuiSubagent => ({
  id,
  childThreadId: `child-${id}`,
  title: `Task ${id}`,
  prompt: `Do ${id}`,
  driver: "codex",
  model: "gpt-5.5",
  status: "running",
  progress: null,
  result: null,
  startedAt: at(60),
  completedAt: null,
  updatedAt: at(10),
  ...patch,
});

const build = (
  agents: ReadonlyArray<TuiSubagent>,
  options: {
    blocks?: ReadonlyMap<string, AgentBlock>;
    selectedId?: string | null;
    width?: number;
    height?: number;
  } = {},
) =>
  buildTuiAgentsState({
    agents,
    blocks: options.blocks ?? new Map(),
    selectedId: options.selectedId ?? null,
    nowMs: NOW,
    width: options.width ?? 32,
    height: options.height ?? 40,
  });

describe("formatElapsed", () => {
  it("says seconds, then minutes and seconds, then hours and minutes", () => {
    expect(formatElapsed(12_400)).toBe("12s");
    expect(formatElapsed(184_000)).toBe("3m 04s");
    expect(formatElapsed(3_720_000)).toBe("1h 02m");
    expect(formatElapsed(-5)).toBe("0s");
  });
});

describe("formatModelSlug", () => {
  it("reads a slug as people say it, and leaves an unknown one alone", () => {
    expect(formatModelSlug("claude-opus-4-7")).toBe("Claude Opus 4.7");
    expect(formatModelSlug("gpt-5.5-codex")).toBe("GPT-5.5-Codex");
    expect(formatModelSlug("openrouter/gemini-3-pro")).toBe("openrouter/Gemini 3 Pro");
    expect(formatModelSlug("muse-glimmer")).toBe("muse-glimmer");
  });
});

describe("agentTitle", () => {
  it("drops the provider's prefix, reads a Codex task path, else the prompt's first line", () => {
    expect(agentTitle({ title: "Subagent: Review docs", prompt: "" })).toBe("Review docs");
    expect(agentTitle({ title: "/root/team/review_docs/", prompt: "" })).toBe("Review Docs");
    expect(agentTitle({ title: null, prompt: "Fix the build\nthen test" })).toBe("Fix the build");
    expect(agentTitle({ title: " ", prompt: "" })).toBe("Subagent");
  });
});

describe("buildTuiAgentsState", () => {
  it("puts a worker waiting on the user first, and says what it waits for", () => {
    const state = build(
      [
        agent("a", { startedAt: at(300) }),
        agent("b", { startedAt: at(100) }),
        agent("c", { status: "completed", completedAt: at(5), result: "All green" }),
      ],
      {
        blocks: new Map([
          ["child-b", { approval: true, question: false }],
          ["child-c", { approval: true, question: false }],
        ]),
      },
    );
    expect(state.ids).toEqual(["b", "a", "c"]);
    expect(state.rows.map((row) => [row.state, row.stateLabel, row.glyph])).toEqual([
      ["blocked", "Needs approval", "!"],
      ["working", "Working", "●"],
      // An ended worker is not blocked by a request it left behind.
      ["completed", "Completed", "✓"],
    ]);
    expect(state.summary).toBe("!1 ●1 ✓1");
    // Words where they fit, blocked first; glyph counts in a narrow panel.
    const wide = build([agent("a"), agent("b")], {
      blocks: new Map([["child-b", { approval: true, question: false }]]),
      width: 60,
    });
    expect(wide.summary).toBe("1 blocked · 1 working");
    expect(state.blocked).toBe(1);
    expect(state.live).toBe(true);
  });

  it("says a question needs an answer", () => {
    const state = build([agent("a")], {
      blocks: new Map([["child-a", { approval: false, question: true }]]),
    });
    expect(state.rows[0]!.stateLabel).toBe("Needs answer");
  });

  it("times live work to now and ended work to when it ended, latest ending first", () => {
    const state = build([
      agent("old", { status: "failed", startedAt: at(900), completedAt: at(600) }),
      agent("new", { status: "cancelled", startedAt: at(200), completedAt: at(20) }),
      agent("live", { startedAt: at(75) }),
    ]);
    expect(state.rows.map((row) => [row.id, row.stateLabel, row.elapsed])).toEqual([
      ["live", "Working", "1m 15s"],
      ["new", "Stopped", "3m 00s"],
      ["old", "Failed", "5m 00s"],
    ]);
    expect(state.live).toBe(true);
    expect(build([agent("x", { status: "completed" })]).live).toBe(false);
  });

  it("shows progress while it works and the answer once it ended, never the MC's placeholder", () => {
    const state = build([
      agent("live", { progress: "Reading\n  files", result: "old" }),
      agent("done", { status: "completed", progress: "Reading", result: "Fixed it" }),
      agent("blank", {
        status: "failed",
        progress: null,
        result: "Child task ended with status failed",
      }),
    ]);
    expect(state.rows.map((row) => row.activity)).toEqual(["Reading files", "Fixed it", ""]);
  });

  it("names the provider and model, and clips every line to the panel", () => {
    const state = build(
      [
        agent("a", {
          title: "A very long worker title that cannot fit",
          driver: "claudeAgent",
          model: "claude-opus-4-7",
          progress: "x".repeat(80),
          startedAt: at(184),
        }),
      ],
      { width: 32 },
    );
    const row = state.rows[0]!;
    expect(row.meta).toBe(" · Claude · Opus 4…");
    expect(build([agent("b")]).rows[0]!.meta).toBe(" · Codex · GPT-5.5");
    // Inside the border and padding: glyph and space, title, space, time.
    expect(Bun.stringWidth(`${row.glyph} ${row.title} ${row.elapsed}`)).toBe(28);
    expect(row.title.endsWith("…")).toBe(true);
    expect(Bun.stringWidth(`  ${row.stateLabel}${row.meta}`)).toBeLessThanOrEqual(28);
    expect(Bun.stringWidth(`  ${row.activity}`)).toBeLessThanOrEqual(28);
  });

  it("windows the rows to the panel's height, keeping the selected worker in view", () => {
    const agents = Array.from({ length: 8 }, (_, i) => agent(`w${i}`, { startedAt: at(100 - i) }));
    // 17 rows: the border and two header lines leave 13, two for "more", three workers.
    const top = build(agents, { height: 17 });
    expect(top.rows.map((row) => row.id)).toEqual(["w0", "w1", "w2"]);
    expect([top.above, top.below]).toEqual([0, 5]);
    expect(top.rows[0]!.selected).toBe(true);

    const down = build(agents, { height: 17, selectedId: "w6" });
    expect(down.selectedIndex).toBe(6);
    expect(down.rows.map((row) => row.id)).toEqual(["w4", "w5", "w6"]);
    expect(down.rows.find((row) => row.selected)?.index).toBe(6);
    expect([down.above, down.below]).toEqual([4, 1]);

    // Four fit when nothing overflows.
    expect(build(agents.slice(0, 4), { height: 17 }).rows).toHaveLength(4);
  });

  it("keeps the selected worker inside a panel too short for one whole worker", () => {
    const agents = [
      agent("a", { progress: "Reading the tests" }),
      agent("b", { progress: "Running bun test", startedAt: at(30) }),
    ];
    expect(build(agents, { height: 7 }).compact).toBe(false);

    // Four rows (80 by 24 with the terminal open): the border and two lines.
    const short = build(agents, { height: 4, selectedId: "b" });
    expect(short.compact).toBe(true);
    expect(short.rows.map((row) => [row.id, row.lines])).toEqual([["b", 2]]);
    // The state and the latest word share the second line; the model gives way.
    expect(short.rows[0]!.meta).toBe(" · Running bun test");
    expect([short.above, short.below]).toEqual([0, 0]);

    // Five or six: the whole worker, without the title and hint.
    expect(build(agents, { height: 5 }).rows.map((row) => row.lines)).toEqual([3]);
    // Three: its title line alone; two: nothing fits inside the border.
    expect(build(agents, { height: 3 }).rows.map((row) => row.lines)).toEqual([1]);
    expect(build(agents, { height: 2 }).rows.map((row) => row.lines)).toEqual([0]);
  });

  it("falls back to the first worker when the selected one is gone, and is empty with none", () => {
    expect(build([agent("a"), agent("b")], { selectedId: "gone" }).selectedIndex).toBe(0);
    const empty = build([]);
    expect(empty).toMatchObject({ summary: "", rows: [], ids: [], live: false, blocked: 0 });
  });
});
