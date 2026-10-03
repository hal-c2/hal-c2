import type { PropertyMap } from "opentui-qml";

import type { TuiMode } from "./layoutState.ts";

/**
 * Published under `ask` (null when closed): a one-line question in the
 * prompt's place (mode "ask"), like the rename and commit fields. Enter
 * answers (`ask.submit {text}`), Esc cancels (`ask.cancel`).
 */
export interface TuiAskState {
  /** What is asked for, before the field: "branch", "script name". */
  readonly label: string;
  readonly placeholder: string;
  /** The field's text when it opens. */
  readonly value: string;
  /** Bumped per question so the field resets even when the label repeats. */
  readonly seq: number;
}

export interface AskSpec {
  readonly label: string;
  readonly placeholder?: string;
  readonly value?: string;
  /** Runs with the trimmed answer after the field closed. */
  readonly onSubmit: (text: string) => void;
  /** The mode the keys go back to ("compose" unless given). */
  readonly returnMode?: TuiMode;
}

export function createAsk(ctx: {
  readonly state: PropertyMap;
  readonly mode: () => TuiMode;
  readonly setMode: (mode: TuiMode) => void;
}) {
  let open: AskSpec | null = null;
  let seq = 0;
  ctx.state.set("ask", null);
  const close = () => {
    const spec = open;
    if (!spec) return null;
    open = null;
    ctx.state.set("ask", null);
    if (ctx.mode() === "ask") ctx.setMode(spec.returnMode ?? "compose");
    return spec;
  };
  return {
    isOpen: () => open !== null,
    ask: (spec: AskSpec) => {
      open = spec;
      seq += 1;
      ctx.state.set("ask", {
        label: spec.label,
        placeholder: spec.placeholder ?? "",
        value: spec.value ?? "",
        seq,
      } satisfies TuiAskState);
      ctx.setMode("ask");
    },
    dispatch: (action: string, payload: unknown): boolean => {
      if (action === "ask.cancel") {
        close();
        return true;
      }
      if (action !== "ask.submit") return false;
      const raw =
        typeof payload === "object" && payload !== null
          ? (payload as { text?: unknown }).text
          : undefined;
      const spec = close();
      spec?.onSubmit(typeof raw === "string" ? raw.trim() : "");
      return true;
    },
  };
}
