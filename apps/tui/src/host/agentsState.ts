// The agents panel's rows (`Shell.state.agents`): a thread's workers, what each
// is doing and for how long, drawn to the panel's width and windowed to its
// height. Pure; the desktop's AgentsModel is the reference for the words.
import { PROVIDER_DISPLAY_NAMES, type ProviderDriverKind } from "@hal-c2/contracts";

import { clip, padClip } from "../format.ts";
import type { TuiSubagent } from "../orchestrationV2Adapter.ts";

/** What a worker is doing, as the panel colours it. */
export type AgentState = "blocked" | "working" | "idle" | "completed" | "failed" | "stopped";

/** A worker's thread waits on the user: an approval, or an answer to a question. */
export interface AgentBlock {
  readonly approval: boolean;
  readonly question: boolean;
}

export interface TuiAgentRow {
  readonly id: string;
  readonly state: AgentState;
  readonly glyph: string;
  /** The title, clipped and padded so `elapsed` sits at the right edge. */
  readonly title: string;
  readonly elapsed: string;
  readonly stateLabel: string;
  /**
   * " · provider · model" after the state, clipped to what is left; in a
   * two-line row, " · " and the latest activity instead.
   */
  readonly meta: string;
  /** Its latest word: progress while it works, its answer once it ended. */
  readonly activity: string;
  /** A worker with its own thread can be opened and stopped. */
  readonly childThreadId: string | null;
  readonly selected: boolean;
  /** The row's place in `all`, for mouse selection. */
  readonly index: number;
  /** The lines it is drawn on: three, fewer in a panel too short for one whole worker. */
  readonly lines: number;
}

export interface TuiAgentsState {
  /** "1 blocked · 2 working · 3 done" ("!1 ●2 ✓3" when narrow), or "" with no workers. */
  readonly summary: string;
  readonly rows: ReadonlyArray<TuiAgentRow>;
  /** Every worker's id in the panel's order, the window's and the rest. */
  readonly ids: ReadonlyArray<string>;
  /** Rows above and below the window, for "↑ 2 more" / "↓ 1 more". */
  readonly above: number;
  readonly below: number;
  readonly selectedIndex: number;
  /** Something still works: the elapsed times move (`agents.tick` once a second). */
  readonly live: boolean;
  readonly blocked: number;
  /**
   * The panel is too short for its title, hint and one whole worker: it shows
   * only the selected worker, on the lines it has, without the title and hint.
   */
  readonly compact: boolean;
}

/** Lines one worker takes: title and time, state and model, latest activity. */
export const AGENT_ROW_LINES = 3;

const LIVE = new Set<TuiSubagent["status"]>(["pending", "running", "waiting"]);
const PLACEHOLDER = /^Child task ended with status\b/i;

const GLYPHS: Record<AgentState, string> = {
  blocked: "!",
  working: "●",
  idle: "○",
  completed: "✓",
  failed: "✗",
  stopped: "■",
};

/** How long, as the desktop's agents tab says it: "12s", "3m 04s", "1h 02m". */
export function formatElapsed(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

/**
 * A model slug as people say it (the desktop's formatModelSlugName):
 * "claude-opus-4-7" → "Claude Opus 4.7", "gpt-5.5-codex" → "GPT-5.5-Codex";
 * an unknown slug stays as it is.
 */
export function formatModelSlug(slug: string): string {
  const cut = slug.lastIndexOf("/") + 1;
  const prefix = slug.slice(0, cut);
  const name = slug.slice(cut);
  if (/^gpt-\d/i.test(name)) {
    return (
      prefix +
      name.replace(/^gpt/i, "GPT").replace(/-([a-z])/g, (_, l: string) => `-${l.toUpperCase()}`)
    );
  }
  if (!/^(claude-(opus|sonnet|haiku|fable)|gemini|grok|composer)-\d/i.test(name)) return slug;
  const versioned = name.replace(/^(claude-[a-z]+-\d+)-(\d{1,2})(?=-|\[|$)/i, "$1.$2");
  return (
    prefix +
    versioned
      .split("-")
      .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
      .join(" ")
  );
}

/** "Claude · Opus 4.7": the model without the family its provider already names. */
function providerAndModel(driver: string, model: string | null): string {
  const provider = PROVIDER_DISPLAY_NAMES[driver as ProviderDriverKind] ?? driver;
  if (!model) return provider;
  const named = formatModelSlug(model);
  const family = `${provider} `;
  const short =
    named.startsWith(family) && named.length > family.length ? named.slice(family.length) : named;
  return `${provider} · ${short}`;
}

/** The title the user gave it, else its prompt's first line (formatSubagentDisplayTitle). */
export function agentTitle(agent: Pick<TuiSubagent, "title" | "prompt">): string {
  const given = agent.title?.trim().replace(/^Subagent:\s*/i, "") ?? "";
  const path = /^\/root\/(?:[^/]+\/)*([^/]+)\/?$/u.exec(given);
  const named = path
    ? path[1]!
        .replace(/[_\s]+/gu, " ")
        .trim()
        .replace(/(^|\s)\S/gu, (l) => l.toUpperCase())
    : given;
  if (named) return named;
  return agent.prompt.trim().split("\n")[0]?.trim() || "Subagent";
}

function agentState(agent: TuiSubagent, block: AgentBlock | undefined): AgentState {
  if (LIVE.has(agent.status)) {
    return block && (block.approval || block.question) ? "blocked" : "working";
  }
  switch (agent.status) {
    case "idle":
      return "idle";
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    default:
      return "stopped";
  }
}

/** The title line before the summary ("Agents · "), as AgentsPanel draws it. */
const SUMMARY_LEAD = "Agents · ";
const SUMMARY_WORDS: Record<AgentState, string> = {
  blocked: "blocked",
  working: "working",
  idle: "idle",
  completed: "done",
  failed: "failed",
  stopped: "stopped",
};

const STATE_LABELS: Record<Exclude<AgentState, "blocked">, string> = {
  working: "Working",
  idle: "Idle · resumable",
  completed: "Completed",
  failed: "Failed",
  stopped: "Stopped",
};

const stateLabel = (state: AgentState, block: AgentBlock | undefined) =>
  state === "blocked" ? (block?.approval ? "Needs approval" : "Needs answer") : STATE_LABELS[state];

/** Its latest word: a live worker's progress, an ended one's answer, never the MC's placeholder. */
function activity(agent: TuiSubagent, live: boolean): string {
  const words = (text: string | null) => {
    const trimmed = text?.replace(/\s+/g, " ").trim() ?? "";
    return PLACEHOLDER.test(trimmed) ? "" : trimmed;
  };
  return live
    ? words(agent.progress) || words(agent.result)
    : words(agent.result) || words(agent.progress);
}

const ms = (iso: string | null) => (iso === null ? Number.NaN : Date.parse(iso));
const ended = (agent: TuiSubagent) => ms(agent.completedAt ?? agent.updatedAt);

/**
 * Blocked first, then the rest still working (oldest first, as they started),
 * then idle, then what ended (latest first).
 */
function rank(state: AgentState): number {
  return state === "blocked" ? 0 : state === "working" ? 1 : state === "idle" ? 2 : 3;
}

export function buildTuiAgentsState(input: {
  readonly agents: ReadonlyArray<TuiSubagent>;
  /** Pending requests on each worker's own thread, by child thread id. */
  readonly blocks: ReadonlyMap<string, AgentBlock>;
  readonly selectedId: string | null;
  readonly nowMs: number;
  /** The panel's width in cells, border included. */
  readonly width: number;
  /** The rows the panel gives its title, hint and workers, border included. */
  readonly height: number;
}): TuiAgentsState {
  const ordered = input.agents
    .map((agent) => {
      const block = agent.childThreadId ? input.blocks.get(agent.childThreadId) : undefined;
      return { agent, block, state: agentState(agent, block) };
    })
    .toSorted((a, b) => {
      const byRank = rank(a.state) - rank(b.state);
      if (byRank !== 0) return byRank;
      if (rank(a.state) < 3) {
        return (ms(a.agent.startedAt) || 0) - (ms(b.agent.startedAt) || 0);
      }
      return (ended(b.agent) || 0) - (ended(a.agent) || 0);
    });

  const found = ordered.findIndex(({ agent }) => agent.id === input.selectedId);
  const selectedIndex = found >= 0 ? found : 0;

  // The border and paddingX take four columns; the title and hint lines, two of the rows.
  const inner = Math.max(1, input.width - 4);
  const fits = (rows: number) => Math.max(1, Math.floor(rows / AGENT_ROW_LINES));
  // Too short for the title, the hint and one worker: the selected worker alone,
  // on the lines inside the border (`lines`), so its state stays in the panel.
  const compact = input.height - 4 < AGENT_ROW_LINES;
  const lines = compact
    ? Math.max(0, Math.min(AGENT_ROW_LINES, input.height - 2))
    : AGENT_ROW_LINES;
  // An overflowing list gives a line each to "↑ 2 more" and "↓ 1 more".
  const windowRows = compact
    ? 1
    : ordered.length > fits(input.height - 4)
      ? fits(input.height - 6)
      : fits(input.height - 4);
  const start = Math.min(
    Math.max(0, selectedIndex - windowRows + 1),
    Math.max(0, ordered.length - windowRows),
  );
  const shown = ordered.slice(start, start + windowRows);
  // What the title, the hint and the workers leave of the lines inside the border: a
  // panel too short for the overflow labels drops them, never the selected worker.
  let spare = compact ? 0 : Math.max(0, input.height - 4 - shown.length * AGENT_ROW_LINES);
  const hiddenAbove = start;
  const hiddenBelow = Math.max(0, ordered.length - start - shown.length);
  const above = hiddenAbove > 0 && spare > 0 ? hiddenAbove : 0;
  if (above > 0) spare -= 1;
  const below = hiddenBelow > 0 && spare > 0 ? hiddenBelow : 0;

  const rows = shown.map(({ agent, block, state }, offset): TuiAgentRow => {
    const live = state === "blocked" || state === "working";
    const startedAt = ms(agent.startedAt);
    const until = live ? input.nowMs : ended(agent);
    const elapsed =
      Number.isFinite(startedAt) && Number.isFinite(until) ? formatElapsed(until - startedAt) : "";
    const label = stateLabel(state, block);
    const meta = providerAndModel(agent.driver, agent.model);
    const titleWidth = inner - 2 - (elapsed ? Bun.stringWidth(elapsed) + 1 : 0);
    const labelText = clip(label, inner - 2);
    const latest = activity(agent, live);
    return {
      id: agent.id,
      state,
      glyph: GLYPHS[state],
      title: padClip(agentTitle(agent), titleWidth),
      elapsed,
      stateLabel: labelText,
      // Two lines keep the state and the latest word; the model gives way.
      meta: clip(
        lines === 2 && latest ? ` · ${latest}` : ` · ${meta}`,
        inner - 2 - Bun.stringWidth(labelText),
      ),
      activity: clip(latest, inner - 2),
      childThreadId: agent.childThreadId,
      selected: start + offset === selectedIndex,
      index: start + offset,
      lines,
    };
  });

  const count = (state: AgentState) => ordered.filter((entry) => entry.state === state).length;
  // Blocked first: it is what the user has to act on.
  const counts = (["blocked", "working", "idle", "completed", "failed", "stopped"] as const)
    .map((state) => [state, count(state)] as const)
    .filter(([, n]) => n > 0);
  const words = counts.map(([state, n]) => `${n} ${SUMMARY_WORDS[state]}`).join(" · ");
  // A narrow panel counts by glyph, as the rows show them: "!1 ●2 ✓3".
  const summary =
    Bun.stringWidth(`${SUMMARY_LEAD}${words}`) <= inner
      ? words
      : counts.map(([state, n]) => `${GLYPHS[state]}${n}`).join(" ");

  return {
    summary,
    rows,
    ids: ordered.map(({ agent }) => agent.id),
    // A compact panel has no line to spare for "↑ 2 more".
    above,
    below,
    selectedIndex,
    live: ordered.some(({ state }) => state === "working" || state === "blocked"),
    blocked: count("blocked"),
    compact,
  };
}
