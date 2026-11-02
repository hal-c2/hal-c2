import { WS_METHODS, type MermaidRenderResult } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";

// The terminal's Mermaid diagrams: the MC draws each one as text (`mermaid.render`,
// docs/internals/mermaid.md), and the answer is kept by the diagram's source, so a
// re-render, a scroll or another place showing the same diagram never asks again.
// Replies, pages and the file viewer share one of these. A "failed" answer is the MC's
// way of saying "not now" (busy, too slow, the helper crashed) and it keeps none, so
// neither does this past a wait.

/** Answers kept at once, beyond those on screen; the oldest goes first. */
const KEPT = 256;
/** The wait before asking again for a diagram the MC failed to draw; doubles each time. */
const RETRY_MS = 10_000;
const RETRY_MAX_MS = 5 * 60_000;

export interface MermaidDiagrams {
  /** What the MC said of `source`; undefined until it answers. Asks the first time. */
  readonly get: (source: string) => MermaidRenderResult | undefined;
  /** `onChange` runs whenever an answer arrives; returns the unsubscribe. */
  readonly listen: (onChange: () => void) => () => void;
  /** Resolves once every answer asked for so far has arrived. */
  readonly settled: () => Promise<void>;
  /** Forgets calls the connection refused, so a reconnected client asks again. */
  readonly retry: () => void;
}

export function createMermaidDiagrams(
  client: Pick<TuiClient, "mcCall">,
  later: (ms: number, run: () => void) => void = (ms, run) => setTimeout(run, ms).unref(),
): MermaidDiagrams {
  const answers = new Map<string, MermaidRenderResult | undefined>();
  const listeners = new Set<() => void>();
  const inFlight = new Set<Promise<unknown>>();
  // Sources whose call the connection refused, rather than the MC answering.
  const refused = new Set<string>();
  // How often in a row the MC failed to draw each source, for the wait before the next ask.
  const failures = new Map<string, number>();
  // What was shown since the answer before last: on screen, so never what makes room,
  // however many diagrams one render shows. A full redraw follows every answer.
  let shown = new Set<string>();
  let shownBefore = new Set<string>();
  const changed = () => {
    shownBefore = shown;
    shown = new Set();
    for (const listener of listeners) listener();
  };

  // The oldest answer not on screen goes; one still being drawn stays, so its answer lands.
  const evict = () => {
    for (const [source, answer] of answers) {
      if (answers.size <= KEPT) return;
      if (answer === undefined || shown.has(source) || shownBefore.has(source)) continue;
      answers.delete(source);
      refused.delete(source);
      failures.delete(source);
    }
  };

  // Forgets a "failed" answer once the wait is up, and redraws, which asks again.
  const tryLater = (source: string, result: MermaidRenderResult) => {
    const count = (failures.get(source) ?? 0) + 1;
    failures.set(source, count);
    later(Math.min(RETRY_MS * 2 ** (count - 1), RETRY_MAX_MS), () => {
      if (answers.get(source) !== result) return;
      answers.delete(source);
      changed();
    });
  };

  const ask = (source: string) => {
    answers.set(source, undefined);
    evict();
    const promise = client
      .mcCall<MermaidRenderResult>(WS_METHODS.mermaidRender, { source, format: "text" })
      .then(
        (result) => ({ result, wasRefused: false }),
        // Kept, so a refusal is not asked again on every redraw, until `retry`.
        (error: unknown) => ({
          result: {
            status: "failed",
            kind: null,
            reason: `Not drawn: ${error instanceof Error ? error.message : String(error)}`,
          } satisfies MermaidRenderResult,
          wasRefused: true,
        }),
      )
      .then(({ result, wasRefused }) => {
        if (!answers.has(source)) return;
        answers.set(source, result);
        if (wasRefused) refused.add(source);
        else if (result.status === "failed") tryLater(source, result);
        else failures.delete(source);
        changed();
      });
    inFlight.add(promise);
    void promise.finally(() => inFlight.delete(promise));
  };

  return {
    get: (source) => {
      shown.add(source);
      if (!answers.has(source)) ask(source);
      return answers.get(source);
    },
    listen: (onChange) => {
      listeners.add(onChange);
      return () => listeners.delete(onChange);
    },
    settled: async () => {
      while (inFlight.size > 0) await Promise.allSettled(inFlight);
    },
    retry: () => {
      if (refused.size === 0) return;
      for (const source of refused) answers.delete(source);
      refused.clear();
      changed();
    },
  };
}
