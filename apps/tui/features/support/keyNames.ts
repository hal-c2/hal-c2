// tui/keymap.feature names actions the way the parity table does ("new
// thread"); a keymap.json names host actions and chords. These turn the one
// into the other.
import { KEYMAP_LAYERS } from "../../src/keymap.ts";

const ACTIONS: Record<string, string> = {
  "new thread": "thread.new",
  "command palette": "palette.open",
  "filter threads": "sidebar.filter.focus",
  "toggle terminal": "terminal.toggle",
};

/** The host action a feature file's action name stands for; null for anything else. */
export const actionNamed = (name: string): string | null => ACTIONS[name] ?? null;

/** The chord the prompt binds to `action` by default. */
export function defaultChord(action: string): string {
  const chord = Object.entries(KEYMAP_LAYERS.compose).find(([, bound]) => bound === action)?.[0];
  if (!chord) throw new Error(`"${action}" has no chord at the prompt`);
  return chord;
}

/** keymap.json entries that move a named action to `chord` (its old chord unbound). */
export function rebindingByName(name: string, chord: string): Record<string, unknown> | null {
  const action = actionNamed(name);
  return action === null ? null : { [chord]: action, [defaultChord(action)]: null };
}

/** keymap.json entries that unbind a named action's chord. */
export function unbindingByName(name: string): Record<string, unknown> | null {
  const action = actionNamed(name);
  return action === null ? null : { [defaultChord(action)]: null };
}
