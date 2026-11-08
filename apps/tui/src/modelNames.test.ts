import { describe, expect, it } from "bun:test";

import { modelButtonName, modelFullName, modelShortName } from "./modelNames.ts";

describe("modelShortName", () => {
  it("drops the family prefix its own provider already says", () => {
    expect(modelShortName("Claude Opus 5.5", "claudeAgent")).toBe("Opus 5.5");
    expect(modelShortName("GPT-5.5-Codex", "codex")).toBe("5.5 Codex");
  });

  it("keeps the family when the rest is only a version", () => {
    expect(modelShortName("GPT-5.5", "codex")).toBeNull();
  });

  it("elsewhere keeps the family unless the rest still names a model", () => {
    expect(modelShortName("Claude Sonnet 5", "opencode")).toBe("Sonnet 5");
    expect(modelShortName("GPT-5 Mini", "opencode")).toBeNull();
  });

  it("drops an aggregator's vendor prefix", () => {
    expect(modelShortName("NVIDIA: Nemotron 3 Super", "opencode")).toBe("Nemotron 3 Super");
  });
});

describe("modelButtonName", () => {
  it("prefers the manifest's short name, without the sub-provider", () => {
    expect(modelButtonName({ name: "Claude Opus 5.5", shortName: "Opus" }, "claudeAgent")).toBe(
      "Opus",
    );
    expect(
      modelButtonName({ name: "Moonshot / Kimi K3", subProvider: "Moonshot" }, "opencode"),
    ).toBe("Kimi K3");
    expect(modelFullName({ name: "Moonshot / Kimi K3", subProvider: "Moonshot" })).toBe("Kimi K3");
  });
});
