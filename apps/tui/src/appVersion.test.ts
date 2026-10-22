import { describe, expect, it } from "bun:test";

import { resolveAppVersion } from "./appVersion.ts";

describe("resolveAppVersion", () => {
  it("uses the version stamped into the bundle", () => {
    expect(resolveAppVersion({}, "0.0.42")).toBe("0.0.42");
  });

  it("lets the environment name another release", () => {
    expect(resolveAppVersion({ HAL_C2_TUI_APP_VERSION: " 0.0.43-nightly.1 " }, "0.0.42")).toBe(
      "0.0.43-nightly.1",
    );
  });

  it("is unknown from source with no environment", () => {
    expect(resolveAppVersion({}, undefined)).toBeNull();
    expect(resolveAppVersion({ HAL_C2_TUI_APP_VERSION: "  " }, undefined)).toBeNull();
  });
});
