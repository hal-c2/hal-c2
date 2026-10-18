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
});
