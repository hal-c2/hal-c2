import { describe, expect, it } from "bun:test";

import { boundChords, KEYBINDING_GROUPS, KEYMAP_LAYERS, KEYMAP_PARITY } from "./keymap.ts";

describe("keymap reference", () => {
  it("documents non-empty groups, each with described bindings", () => {
    expect(KEYBINDING_GROUPS.length).toBeGreaterThan(0);
    for (const group of KEYBINDING_GROUPS) {
      expect(group.title.length).toBeGreaterThan(0);
      expect(group.bindings.length).toBeGreaterThan(0);
      for (const binding of group.bindings) {
        expect(binding.keys.length).toBeGreaterThan(0);
        expect(binding.description.length).toBeGreaterThan(0);
      }
    }
  });

  it("covers the headline shortcuts", () => {
    const all = KEYBINDING_GROUPS.flatMap((g) => g.bindings);
    expect(all.some((b) => b.keys === "^K")).toBe(true);
    expect(all.some((b) => b.description.includes("plan / build"))).toBe(true);
  });
});

describe("keymap layers", () => {
  it("lists every bound chord in the reference", () => {
    const documented = new Set(
      KEYBINDING_GROUPS.flatMap((group) =>
        group.bindings.flatMap((binding) => binding.chords ?? []),
      ),
    );
    expect(boundChords().filter((chord) => !documented.has(chord))).toEqual([]);
  });

  it("binds each parity row's chords in the conversation", () => {
    const compose: Record<string, string> = KEYMAP_LAYERS.compose;
    const bound = new Map<string, string>();
    for (const [chord, action] of Object.entries(compose)) {
      for (const part of chord.split(",")) bound.set(part.trim(), action);
    }
    for (const row of KEYMAP_PARITY) {
      expect(row.chords.every((chord) => bound.has(chord))).toBe(true);
    }
  });
});
