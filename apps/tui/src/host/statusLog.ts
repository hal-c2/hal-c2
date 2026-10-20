import type { PropertyMap } from "opentui-qml";

import type { StatusKind } from "../store.ts";
import type { PaletteCommand } from "./paletteState.ts";
import type { PickRequest } from "./composerState.ts";

/** An error the status line showed, as the history lists it. */
export interface StatusErrorEntry {
  readonly text: string;
  /** ISO time it was raised. */
  readonly at: string;
}

/** Published under `statusError` as `TuiStatusErrorState | null`: the error the user has not acknowledged, or null. */
export interface TuiStatusErrorState {
  readonly text: string;
}

/** Errors kept for the history; older ones drop off. */
export const STATUS_HISTORY_LIMIT = 50;

/**
 * The status line holds one message and anything may replace it, so an error
 * would be gone before it was read. This keeps the latest error pinned until
 * the user acknowledges it (`status.dismiss`: clicking it, the palette, or
 * opening the history) or a newer error replaces it, and keeps the last
 * `STATUS_HISTORY_LIMIT` errors for the palette's "Show status history", where
 * choosing one copies it whole (the line and the picker both cut a long one).
 * Messages that follow an error show beside it (statusState.ts).
 */
export function createStatusLog(ctx: {
  readonly state: PropertyMap;
  readonly now: () => string;
  /** Takes the status line back to its resting message when the pinned error is still the current one. */
  readonly clearCurrent: (errorText: string) => void;
  readonly pick: (request: PickRequest) => void;
  /** Put text on the system clipboard; false when the terminal cannot. */
  readonly copy: (text: string) => boolean;
  /** Sets the status line (never an error: that would pin). */
  readonly say: (text: string, kind: "info" | "success") => void;
}) {
  let pinned: string | null = null;
  const history: StatusErrorEntry[] = [];
  ctx.state.set("statusError", null);

  const publish = () =>
    ctx.state.set(
      "statusError",
      pinned === null ? null : ({ text: pinned } satisfies TuiStatusErrorState),
    );

  const dismiss = (): boolean => {
    if (pinned === null) return false;
    const text = pinned;
    pinned = null;
    publish();
    ctx.clearCurrent(text);
    return true;
  };

  return {
    /** Every status the store reports, in order; only errors are kept. */
    note: (status: { readonly kind: StatusKind; readonly text: string }) => {
      if (status.kind !== "error" || status.text === pinned) return;
      pinned = status.text;
      history.unshift({ text: status.text, at: ctx.now() });
      history.length = Math.min(history.length, STATUS_HISTORY_LIMIT);
      publish();
    },
    commands: (): PaletteCommand[] => [
      ...(pinned === null
        ? []
        : [
            {
              id: "status.dismiss",
              title: "Dismiss the status error",
              keywords: "acknowledge clear failure message",
              action: "status.dismiss",
            },
          ]),
      // Nothing to list until the first error: an empty picker is a dead end.
      ...(history.length === 0
        ? []
        : [
            {
              id: "status.history",
              title: "Show status history",
              keywords: "errors failures messages log",
              action: "status.history",
            },
          ]),
    ],
    dispatch: (action: string): boolean => {
      if (action === "status.dismiss") {
        dismiss();
        return true;
      }
      if (action !== "status.history") return false;
      // Direct callers (shells, plugins) skip the palette's gating: an empty
      // history is a dead-end picker, so this stays a known no-op.
      if (history.length === 0) return true;
      // Opening the history is reading the error.
      dismiss();
      // The list as the picker showed it: errors arriving while it is open must not shift its values.
      const shown = history.slice();
      ctx.pick({
        title: "Status history",
        options: shown.map((entry, index) => ({
          label: entry.text,
          description: new Date(entry.at).toLocaleTimeString(),
          value: String(index),
        })),
        onChoose: (value) => {
          const entry = shown[Number(value)];
          if (!entry) return;
          if (ctx.copy(entry.text)) ctx.say("Error copied to clipboard.", "success");
          else ctx.say("Clipboard unavailable here.", "info");
        },
      });
      return true;
    },
  };
}
