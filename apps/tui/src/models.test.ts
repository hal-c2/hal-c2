import { describe, expect, it } from "bun:test";

import { ProviderInstanceId, type ServerProvider } from "@hal-c2/contracts";
import {
  currentModelIndex,
  defaultModelSlug,
  fallbackModelSlug,
  flattenModelOptions,
  modelSelectionForOption,
  promptEffort,
  providerReady,
  reasoningChoicesFor,
  reasoningChoicesForSelection,
  resolveModelSelection,
  steppedEffort,
  ultrathinkInWords,
  withModelSelectionOption,
  withoutUltrathinkPrefix,
} from "./models.ts";

const provider = (
  instanceId: string,
  displayName: string,
  models: Array<{ slug: string; name: string; shortName?: string }>,
): ServerProvider =>
  ({
    instanceId,
    driver: instanceId,
    displayName,
    models: models.map((m) => ({ ...m, isCustom: false, capabilities: null })),
  }) as unknown as ServerProvider;

describe("flattenModelOptions", () => {
  it("Given providers with models, then it flattens them with their full and short names", () => {
    const options = flattenModelOptions([
      provider("codex", "Codex", [{ slug: "gpt-5", name: "GPT-5", shortName: "5" }]),
      provider("claude", "Claude", [{ slug: "opus", name: "Opus 4" }]),
    ]);
    expect(options).toEqual([
      {
        instanceId: "codex",
        model: "gpt-5",
        label: "GPT-5",
        buttonLabel: "5",
        providerLabel: "Codex",
        capabilities: null,
      },
      {
        instanceId: "claude",
        model: "opus",
        label: "Opus 4",
        buttonLabel: "Opus 4",
        providerLabel: "Claude",
        capabilities: null,
      },
    ] as never);
  });

  it("Given a provider with no models, then it contributes nothing", () => {
    expect(flattenModelOptions([provider("empty", "Empty", [])])).toEqual([]);
  });

  it("excludes disabled and unavailable providers from the picker", () => {
    const enabled = provider("codex", "Codex", [{ slug: "gpt-5", name: "GPT-5" }]);
    const disabled = {
      ...provider("claude", "Claude", [{ slug: "opus", name: "Opus" }]),
      enabled: false,
    };
    const unavailable = {
      ...provider("cursor", "Cursor", [{ slug: "auto", name: "Auto" }]),
      availability: "unavailable",
    };
    expect(
      flattenModelOptions([enabled, disabled, unavailable] as never).map((item) => item.model),
    ).toEqual(["gpt-5"]);
  });
});

describe("currentModelIndex", () => {
  const options = flattenModelOptions([
    provider("codex", "Codex", [{ slug: "gpt-5", name: "GPT-5" }]),
    provider("claude", "Claude", [{ slug: "opus", name: "Opus" }]),
  ]);

  it("finds the index of the matching selection", () => {
    expect(currentModelIndex(options, { instanceId: "claude", model: "opus" })).toBe(1);
  });

  it("falls back to 0 when nothing matches or no selection", () => {
    expect(currentModelIndex(options, { instanceId: "x", model: "y" })).toBe(0);
    expect(currentModelIndex(options, null)).toBe(0);
  });
});

describe("reasoningChoicesFor", () => {
  const providers = [
    {
      instanceId: "codex",
      driver: "codex",
      models: [
        {
          slug: "gpt-5",
          name: "GPT-5",
          isCustom: false,
          capabilities: {
            optionDescriptors: [
              {
                type: "select",
                id: "reasoningEffort",
                label: "Reasoning",
                options: [
                  { id: "low", label: "Low", isDefault: true },
                  { id: "high", label: "High" },
                ],
              },
            ],
          },
        },
        { slug: "plain", name: "Plain", isCustom: false, capabilities: null },
      ],
    },
  ] as never;

  it("Given a model with a reasoning descriptor, then it returns its choices", () => {
    const result = reasoningChoicesFor(providers, "codex", "gpt-5");
    expect(result?.descriptorId).toBe("reasoningEffort");
    expect(result?.choices.map((c) => c.id)).toEqual(["low", "high"]);
    expect(result?.selectedId).toBe("low");
  });

  it("Given a model with no descriptors, then it returns null", () => {
    expect(reasoningChoicesFor(providers, "codex", "plain")).toBeNull();
  });
});

describe("model selection parity with the web composer", () => {
  const options = flattenModelOptions([
    {
      instanceId: "codex",
      driver: "codex",
      models: [
        {
          slug: "gpt-5",
          name: "GPT-5",
          isCustom: false,
          capabilities: {
            optionDescriptors: [
              {
                type: "select",
                id: "reasoningEffort",
                label: "Reasoning",
                options: [
                  { id: "low", label: "Low", isDefault: true },
                  { id: "high", label: "High" },
                ],
              },
              {
                type: "boolean",
                id: "fastMode",
                label: "Fast mode",
                currentValue: true,
              },
            ],
          },
        },
      ],
    },
  ] as never);

  it("Given a model is selected, then its effort and other option defaults are dispatched", () => {
    expect(modelSelectionForOption(options[0]!)).toEqual({
      instanceId: "codex",
      model: "gpt-5",
      options: [
        { id: "reasoningEffort", value: "low" },
        { id: "fastMode", value: true },
      ],
    } as never);
  });

  it("Given an explicit effort, then it overrides the default and remains selected in the picker", () => {
    const selection = resolveModelSelection(options, {
      instanceId: ProviderInstanceId.make("codex"),
      model: "gpt-5",
      options: [{ id: "reasoningEffort", value: "high" }],
    });
    expect(selection?.options).toEqual([
      { id: "reasoningEffort", value: "high" },
      { id: "fastMode", value: true },
    ]);
    expect(reasoningChoicesForSelection(options, selection)?.selectedId).toBe("high");
  });

  it("Given effort changes, then unrelated model options are preserved", () => {
    const selection = modelSelectionForOption(options[0]!);
    expect(withModelSelectionOption(selection, "reasoningEffort", "high").options).toEqual([
      { id: "fastMode", value: true },
      { id: "reasoningEffort", value: "high" },
    ]);
  });
});

describe("steppedEffort", () => {
  const effortModel = (currentValue?: string) => ({
    instanceId: ProviderInstanceId.make("claude"),
    model: "opus",
    label: "Opus",
    providerLabel: "Claude",
    capabilities: {
      optionDescriptors: [
        {
          id: "effort",
          label: "Effort",
          type: "select" as const,
          options: ["low", "medium", "high", "ultrathink"].map((id) => ({
            id,
            label: id,
            ...(id === "medium" ? { isDefault: true } : {}),
          })),
          promptInjectedValues: ["ultrathink"],
          ...(currentValue ? { currentValue } : {}),
        },
      ],
    },
  });
  const at = (value: string | undefined, direction: 1 | -1, currentValue?: string) =>
    steppedEffort(
      [effortModel(currentValue)],
      {
        instanceId: ProviderInstanceId.make("claude"),
        model: "opus",
        ...(value ? { options: [{ id: "effort", value }] } : {}),
      },
      direction,
    )?.value;

  it("steps one level and wraps past the ends, never onto a level the prompt carries", () => {
    expect(at("medium", 1)).toBe("high");
    expect(at("high", 1)).toBe("low");
    expect(at("low", -1)).toBe("high");
  });

  it("steps from above the top level when the prompt carries Ultrathink", () => {
    const above = (direction: 1 | -1) =>
      steppedEffort(
        [effortModel()],
        {
          instanceId: ProviderInstanceId.make("claude"),
          model: "opus",
          options: [{ id: "effort", value: "low" }],
        },
        direction,
        true,
      )?.value;
    expect(above(1)).toBe("low");
    expect(above(-1)).toBe("high");
  });

  it("never offers a level the prompt carries among the effort choices", () => {
    const choices = reasoningChoicesForSelection([effortModel()], {
      instanceId: ProviderInstanceId.make("claude"),
      model: "opus",
    });
    expect(choices?.choices.map((choice) => choice.id)).toEqual(["low", "medium", "high"]);
    expect(withoutUltrathinkPrefix("Ultrathink: design the cache")).toBe("design the cache");
  });

  it("steps from the model's default when the current level is not one it lists", () => {
    expect(at(undefined, 1, "default")).toBe("high");
    expect(at(undefined, -1, "default")).toBe("low");
  });

  it("reads Ultrathink, locked, only while the prompt says it in its own words", () => {
    const selection = { instanceId: ProviderInstanceId.make("claude"), model: "opus" };
    const read = (text: string) => promptEffort([effortModel()], selection, text);
    expect(read("please ultrathink about it")).toEqual({ value: "ultrathink", locked: true });
    expect(read("Ultrathink: design the cache")).toEqual({ value: "ultrathink", locked: false });
    expect(read("design the cache")).toBeNull();
    expect(ultrathinkInWords("Ultrathink: ultrathinking")).toBe(false);
  });
});

describe("fallback accounts", () => {
  const codex = (models: ReadonlyArray<Record<string, unknown>>, extra = {}) =>
    ({
      instanceId: "codex_work",
      driver: "codex",
      enabled: true,
      status: "ready",
      models: models.map((model) => ({ isCustom: false, capabilities: null, ...model })),
      ...extra,
    }) as unknown as ServerProvider;
  const builtIn = { slug: "gpt-5.4", name: "GPT-5.4", aliases: ["5.4"] };
  const custom = { slug: "my-5.4", name: "5.4", isCustom: true };

  it("finds the model by its slug, else a built-in it names or is an alias of", () => {
    expect(fallbackModelSlug(codex([builtIn]), "gpt-5.4")).toBe("gpt-5.4");
    expect(fallbackModelSlug(codex([builtIn]), "5.4")).toBe("gpt-5.4");
    expect(fallbackModelSlug(codex([builtIn]), "GPT-5.4")).toBe("gpt-5.4");
    expect(fallbackModelSlug(codex([builtIn]), "gpt-6")).toBeNull();
  });

  it("never takes a custom model that only shares the name", () => {
    expect(fallbackModelSlug(codex([custom, builtIn]), "5.4")).toBe("gpt-5.4");
    expect(fallbackModelSlug(codex([custom]), "5.4")).toBeNull();
    expect(fallbackModelSlug(codex([custom]), "my-5.4")).toBe("my-5.4");
  });

  it("starts on the account's default, else its first built-in model", () => {
    expect(
      defaultModelSlug(codex([custom, builtIn, { slug: "b", name: "B", isDefault: true }])),
    ).toBe("b");
    expect(defaultModelSlug(codex([custom, builtIn]))).toBe("gpt-5.4");
    expect(defaultModelSlug(codex([custom]))).toBe("my-5.4");
    expect(defaultModelSlug(codex([]))).toBeNull();
  });

  it("runs only on an account that is on and whose last check passed", () => {
    expect(providerReady(codex([builtIn]))).toBe(true);
    expect(providerReady(codex([builtIn], { enabled: false }))).toBe(false);
    expect(providerReady(codex([builtIn], { status: "error" }))).toBe(false);
    expect(providerReady(codex([builtIn], { availability: "unavailable" }))).toBe(false);
  });
});
