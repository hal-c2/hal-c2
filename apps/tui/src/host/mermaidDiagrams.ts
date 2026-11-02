import { WS_METHODS, type MermaidRenderResult } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";

// The terminal's Mermaid diagrams: the MC draws each one as text (`mermaid.render`,
// docs/internals/mermaid.md), and the answer is kept by the diagram's source, so a
// re-render, a scroll or another place showing the same diagram never asks again.
// Replies, pages and the file viewer share one of these.

/** Answers kept at once, beyond those on screen; the oldest goes first. */
const KEPT = 256;

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

export function createMermaidDiagrams(client: Pick<TuiClient, "mcCall">): MermaidDiagrams {
  const answers = new Map<string, MermaidRenderResult | undefined>();
  const listeners = new Set<() => void>();
  const inFlight = new Set<Promise<unknown>>();
  // Sources whose call the connection refused, rather than the MC answering.
  const refused = new Set<string>();
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
    }
  };

  const ask = (source: string) => {
    answers.set(source, undefined);
    evict();
    const promise = client
      .mcCall<MermaidRenderResult>(WS_METHODS.mermaidRender, { source, format: "text" })
      .catch(
        // Kept like the MC's own "failed", so a refusal is not asked again on every redraw,
        // until `retry`.
        (error: unknown): MermaidRenderResult => {
          refused.add(source);
          return {
            status: "failed",
            kind: null,
            reason: `Not drawn: ${error instanceof Error ? error.message : String(error)}`,
          };
        },
      )
      .then((result) => {
        if (!answers.has(source)) return;
        answers.set(source, result);
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
