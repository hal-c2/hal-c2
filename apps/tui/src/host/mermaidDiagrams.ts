import { WS_METHODS, type MermaidRenderResult } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";

// The terminal's Mermaid diagrams: the MC draws each one as text (`mermaid.render`,
// docs/internals/mermaid.md), and the answer is kept by the diagram's source, so a
// re-render, a scroll or another place showing the same diagram never asks again.
// Replies, pages and the file viewer share one of these.

/** Answers kept at once; the oldest goes first. */
const KEPT = 256;

export interface MermaidDiagrams {
  /** What the MC said of `source`; undefined until it answers. Asks the first time. */
  readonly get: (source: string) => MermaidRenderResult | undefined;
  /** `onChange` runs whenever an answer arrives; returns the unsubscribe. */
  readonly listen: (onChange: () => void) => () => void;
  /** Resolves once every answer asked for so far has arrived. */
  readonly settled: () => Promise<void>;
}

export function createMermaidDiagrams(client: Pick<TuiClient, "mcCall">): MermaidDiagrams {
  const answers = new Map<string, MermaidRenderResult | undefined>();
  const listeners = new Set<() => void>();
  const inFlight = new Set<Promise<unknown>>();

  const ask = (source: string) => {
    answers.set(source, undefined);
    if (answers.size > KEPT) answers.delete(answers.keys().next().value!);
    const promise = client
      .mcCall<MermaidRenderResult>(WS_METHODS.mermaidRender, { source, format: "text" })
      .catch(
        // Kept like the MC's own "failed", so a refusal is not asked again on every redraw.
        (error: unknown): MermaidRenderResult => ({
          status: "failed",
          kind: null,
          reason: `Not drawn: ${error instanceof Error ? error.message : String(error)}`,
        }),
      )
      .then((result) => {
        if (!answers.has(source)) return;
        answers.set(source, result);
        for (const listener of listeners) listener();
      });
    inFlight.add(promise);
    void promise.finally(() => inFlight.delete(promise));
  };

  return {
    get: (source) => {
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
  };
}
