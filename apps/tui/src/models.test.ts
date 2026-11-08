import { describe, expect, it } from "bun:test";

import { ProviderInstanceId, type ServerProvider } from "@hal-c2/contracts";
import {
  currentModelIndex,
  flattenModelOptions,
  modelSelectionForOption,
  promptEffort,
  reasoningChoicesFor,
  reasoningChoicesForSelection,
  resolveModelSelection,
  steppedEffort,
  ultrathinkInWords,
  withModelSelectionOption,
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
