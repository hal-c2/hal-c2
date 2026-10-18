import { describe, expect, it } from "bun:test";

import { type TuiStatusRowInput, buildStatusRow } from "./statusState.ts";

const row = (overrides: Partial<TuiStatusRowInput>) =>
  buildStatusRow({
    mainWidth: 160,
    status: { kind: "info", text: "Ready." },
    imagePreview: false,
    addingProject: false,
    questionBanner: null,
    terminalOpen: false,
    threadHints: [],
    sourceControlOpen: false,
    working: false,
    draft: false,
    pinnedError: null,
    ...overrides,
  });

describe("status row beside a pinned error", () => {
  it("takes only the room the two messages need, leaving the rest to the key hints", () => {
    const state = row({
      mainWidth: 100,
      status: { kind: "success", text: "Pulled." },
      pinnedError: "Offline",
    });
    expect(state.pinned).toBe("✗ Offline · ");
    expect(state.label).toBe("✓ Pulled.");
    // Half of 100 columns would leave the hints 48 cells; two short messages need 32.
    expect(state.hint.length).toBeGreaterThan(60);
  });

  it("shares half the row at most, cutting the error before the newer message", () => {
    const state = row({
      status: { kind: "success", text: "Setting saved" },
      pinnedError: "x".repeat(300),
    });
    expect(state.label).toBe("✓ Setting saved");
    expect(state.pinned.length + state.label.length).toBeLessThanOrEqual(80);
    expect(state.pinned.length).toBeGreaterThan(" · ".length);
  });

  it("shows an error that is the status itself once, as the label", () => {
    const state = row({ status: { kind: "error", text: "Offline" }, pinnedError: "Offline" });
    expect(state.pinned).toBe("");
    expect(state.label).toBe("✗ Offline");
    expect(state.errorPinned).toBe(true);
  });

  it("shares at most half of a narrow row, below the 32-cell floor", () => {
    const state = row({
      mainWidth: 50,
      status: { kind: "success", text: "Setting saved" },
      pinnedError: "x".repeat(300),
    });
    // 50 columns: the status takes 25 cells, the key hints keep the rest of the 48.
    expect(Bun.stringWidth(state.pinned) + Bun.stringWidth(state.label)).toBeLessThanOrEqual(25);
    expect(Bun.stringWidth(state.hint)).toBeGreaterThanOrEqual(23);
    expect(state.pinned.length).toBeGreaterThan(" · ".length);
  });

  it("counts a wide-character error in terminal cells, not UTF-16 units", () => {
    const wide = "接続できません".repeat(10);
    const state = row({
      mainWidth: 100,
      status: { kind: "success", text: "Pulled." },
      pinnedError: wide,
    });
    // Half of 100 columns is 50 cells; the error is cut to what is left of that.
    expect(Bun.stringWidth(state.pinned) + Bun.stringWidth(state.label)).toBeLessThanOrEqual(50);
    expect(Bun.stringWidth(state.pinned)).toBeGreaterThan(30);
  });
});
