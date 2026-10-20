import { clip } from "../format.ts";
import type { StatusKind } from "../store.ts";
import { statusGlyphColor } from "../theme.ts";

/** What has the keys, and what the thread offers, as the key-hint row reads it. */
export interface TuiStatusRowInput {
  readonly mainWidth: number;
  readonly status: { readonly kind: StatusKind; readonly text: string };
  readonly imagePreview: boolean;
  readonly addingProject: boolean;
  /** A question set aside ("⚠ question pending — ^U to answer"), or null. */
  readonly questionBanner: string | null;
  /** The selected thread's terminal drawer is open. */
  readonly terminalOpen: boolean;
  /** The thread's own keys: ^Y with a plan, ^A/^R with approvals. */
  readonly threadHints: readonly string[];
  readonly sourceControlOpen: boolean;
  readonly working: boolean;
  readonly draft: boolean;
  /** The error the user has not acknowledged yet (statusLog.ts), or null. */
  readonly pinnedError: string | null;
}

/**
 * Published under `statusRow`: the main column's bottom row, as ChatView.tsx
 * draws it. `hint` (dim) is cut to leave `label` (the status glyph and
 * message, in the status colour) its room of up to 32 cells. While an error is
 * pinned and a newer message has come after it, `pinned` carries the error
 * (glyph included) ahead of `label`, and the two share up to half the row. Otherwise
 * `pinned` is empty and the error, if any, is `label` itself.
 */
export interface TuiStatusRowState {
  readonly hint: string;
  readonly label: string;
  readonly kind: StatusKind;
  readonly pinned: string;
  /** An error is pinned: a plugin's replacing contribution leaves the status in place. */
  readonly errorPinned: boolean;
}

/** The glue between a pinned error and the message that came after it. */
const PINNED_SEPARATOR = " · ";
/** How a pinned error says it is waiting to be dismissed, so it does not read as a stuck line. */
const DISMISS_HINT = "click error or ^K to dismiss";

export function buildStatusRow(input: TuiStatusRowInput): TuiStatusRowState {
  const composeHint = [
    "Alt+↑/↓ threads",
    "Enter send",
    "^G editor",
    "^↑/^↓ size",
    "^N new",
    "^E term",
    ...(input.draft ? [] : input.threadHints),
    "^K commands",
    "^F find",
    `^L panel ${input.sourceControlOpen ? "▾" : "▸"}`,
    ...(input.working ? ["Esc stop"] : input.draft ? ["Esc clear"] : []),
    "^C quit",
  ].join(" · ");
  const hint = input.imagePreview
    ? "image preview · Esc or click to close · ^C quit"
    : input.addingProject
      ? "↑/↓ navigate · Enter select · Ctrl+Enter action · Esc back · ^C quit"
      : !input.draft && input.questionBanner !== null
        ? `${input.questionBanner} · ^C quit`
        : input.terminalOpen
          ? "^P prompt · ^E close term · ^↑/^↓ size term · keys → shell"
          : composeHint;
  const statusLabel = `${statusGlyphColor(input.status.kind).glyph} ${input.status.text}`;
  const beside =
    input.pinnedError !== null &&
    !(input.status.kind === "error" && input.status.text === input.pinnedError);
  const pinnedLabel = beside ? `${statusGlyphColor("error").glyph} ${input.pinnedError}` : "";
  // A pinned error announces how to dismiss it at the head of the hints, which
  // `clip` keeps, instead of widening the status budget the layout promises.
  const hintWithDismiss = input.pinnedError !== null ? `${DISMISS_HINT} · ${hint}` : hint;
  const room = Math.max(0, input.mainWidth - 2);
  // Widths are terminal cells, as `clip` counts them: a wide character takes two.
  const statusCells = Bun.stringWidth(statusLabel);
  const pinnedCells = Bun.stringWidth(pinnedLabel);
  // Beside an error the two share what they need: at least 32 cells where half the row allows
  // it, and never more than half the row.
  const besideNeed = pinnedCells + PINNED_SEPARATOR.length + statusCells;
  const statusWidth = beside
    ? Math.min(room, Math.floor(input.mainWidth / 2), Math.max(32, besideNeed))
    : Math.min(room, Math.max(8, Math.min(32, statusCells)));
  const hintWidth = Math.max(0, room - statusWidth);
  if (!beside) {
    return {
      hint: clip(hintWithDismiss, hintWidth),
      label: clip(statusLabel, statusWidth),
      kind: input.status.kind,
      pinned: "",
      errorPinned: input.pinnedError !== null,
    };
  }
  // The newer message keeps what it needs up to a third of the shared width, or more
  // when the error is short enough to leave it room; the error takes the rest.
  const labelWidth = Math.min(
    statusCells,
    Math.max(Math.floor(statusWidth / 3), statusWidth - PINNED_SEPARATOR.length - pinnedCells),
  );
  const pinnedWidth = Math.max(0, statusWidth - PINNED_SEPARATOR.length - labelWidth);
  return {
    hint: clip(hintWithDismiss, hintWidth),
    pinned: pinnedWidth > 0 ? clip(pinnedLabel, pinnedWidth) + PINNED_SEPARATOR : "",
    label: clip(statusLabel, labelWidth),
    kind: input.status.kind,
    errorPinned: true,
  };
}
