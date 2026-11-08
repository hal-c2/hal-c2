import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import type { EffortDisplay } from "@hal-c2/contracts";

/** How this device's composer names the effort; the other clients' setting of the same name. */
export interface EffortDisplayStore {
  readonly load: () => EffortDisplay;
  readonly save: (display: EffortDisplay) => void;
}

export const EFFORT_DISPLAYS: ReadonlyArray<EffortDisplay> = ["label", "bars"];
export const EFFORT_DISPLAY_LABELS: Readonly<Record<EffortDisplay, string>> = {
  label: "Word",
  bars: "Bars",
};

export const EFFORT_DISPLAY_FILE = "effort-display.json";

/** Kept only while the client runs (the default, and what tests use). */
export function memoryEffortDisplay(initial: EffortDisplay = "label"): EffortDisplayStore {
  let current = initial;
  return {
    load: () => current,
    save: (display) => {
      current = display;
    },
  };
}

/** Kept in a JSON file; a missing or unreadable one names the effort as a word. */
export function fileEffortDisplay(path: string): EffortDisplayStore {
  return {
    load: () => {
      try {
        const parsed: unknown = JSON.parse(NodeFS.readFileSync(path, "utf8"));
        return EFFORT_DISPLAYS.find((display) => display === parsed) ?? "label";
      } catch {
        return "label";
      }
    },
    save: (display) => {
      try {
        NodeFS.mkdirSync(NodePath.dirname(path), { recursive: true });
        NodeFS.writeFileSync(path, `${JSON.stringify(display)}\n`);
      } catch {
        // The display still holds for this run.
      }
    },
  };
}
