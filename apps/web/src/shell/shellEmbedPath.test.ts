import { describe, expect, it } from "vite-plus/test";

import { buildTerminalEmbedPath } from "./shellEmbedPath";

describe("buildTerminalEmbedPath", () => {
  it("encodes path segments", () => {
    expect(buildTerminalEmbedPath("env/1", "thread 2")).toBe(
      "/embed/env%2F1/thread%202?surface=terminal",
    );
  });
});
