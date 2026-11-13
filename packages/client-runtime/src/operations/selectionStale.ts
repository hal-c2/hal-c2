import type { ModelSelection } from "@hal-c2/contracts";

/**
 * The MC's refusal of a choice made against an older `selectionRevision`: the
 * thread changed elsewhere first. It names what the thread runs now, when the
 * MC sent it.
 */
export interface SelectionStale {
  readonly selectionRevision: number | null;
  readonly modelSelection: ModelSelection | null;
}

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;

const selectionOf = (value: unknown): ModelSelection | null => {
  const selection = record(value);
  return selection &&
    typeof selection.instanceId === "string" &&
    typeof selection.model === "string"
    ? (selection as unknown as ModelSelection)
    : null;
};

/**
 * Finds a `selection-stale` refusal in a failed command, through the error's
 * causes and the MC's rpc.error detail (`{code, selectionRevision, modelSelection}`).
 */
export function selectionStaleRefusal(error: unknown): SelectionStale | null {
  const seen = new Set<unknown>();
  const queue: unknown[] = [error];
  while (queue.length > 0) {
    const current = record(queue.shift());
    if (current === null || seen.has(current)) continue;
    seen.add(current);
    if (current.code === "selection-stale") {
      const revision = current.selectionRevision;
      return {
        selectionRevision: typeof revision === "number" ? revision : null,
        modelSelection: selectionOf(current.modelSelection),
      };
    }
    queue.push(current.cause, current.detail, current.error);
  }
  return null;
}
