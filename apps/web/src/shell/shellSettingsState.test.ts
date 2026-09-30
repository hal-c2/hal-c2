import { describe, expect, it } from "vite-plus/test";

import { isSettingsPath, resolveActiveSettingsSection } from "./shellSettingsState";

describe("shellSettingsState", () => {
  it("rejects inherited object properties as settings destinations", () => {
    expect(isSettingsPath("/settings/general")).toBe(true);
    for (const path of ["constructor", "toString", "__proto__", "/settings/missing"]) {
      expect(isSettingsPath(path)).toBe(false);
    }
  });
  it("resolves nested settings paths to their section", () => {
    expect(resolveActiveSettingsSection("/settings/providers/codex")).toBe("/settings/providers");
    expect(resolveActiveSettingsSection("/settings")).toBeNull();
  });
});
