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
}

/**
 * Published under `statusRow`: the main column's bottom row, as ChatView.tsx
 * draws it. `hint` (dim) is cut to leave `label` (the status glyph and
 * message, in the status colour) its room of up to 32 cells.
 */
export interface TuiStatusRowState {
  readonly hint: string;
  readonly label: string;
  readonly kind: StatusKind;
}

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
  const statusWidth = Math.min(
    Math.max(0, input.mainWidth - 2),
    Math.max(8, Math.min(32, statusLabel.length)),
  );
  const hintWidth = Math.max(0, input.mainWidth - 2 - statusWidth);
  return {
    hint: clip(hint, hintWidth),
    label: clip(statusLabel, statusWidth),
    kind: input.status.kind,
  };
}
