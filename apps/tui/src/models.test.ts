import { describe, expect, it } from "bun:test";

import { ProviderInstanceId, type ServerProvider } from "@hal-c2/contracts";
import {
  defaultModelSlug,
  effortReadout,
  fallbackModelSlug,
  flattenModelOptions,
  modelPickerRows,
  modelSelectionForOption,
  nextPick,
  pickMatchesThread,
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
    expect(withoutUltrathinkPrefix("ultrathink: fix it")).toBe("ultrathink: fix it");
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
    expect(read("ultrathink: fix it")).toEqual({ value: "ultrathink", locked: true });
    expect(read("design the cache")).toBeNull();
    expect(ultrathinkInWords("Ultrathink: ultrathinking")).toBe(false);
  });
});

describe("pickMatchesThread", () => {
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
              { type: "boolean", id: "fastMode", label: "Fast mode" },
            ],
          },
        },
        { slug: "gpt-5-codex", name: "GPT-5 Codex", isCustom: false, capabilities: null },
      ],
    },
  ] as never);
  const codex = ProviderInstanceId.make("codex");

  it("counts a pick as taken once the thread runs it, defaults and Fast off included", () => {
    const pick = { instanceId: codex, model: "gpt-5", options: [{ id: "fastMode", value: false }] };
    expect(pickMatchesThread(options, pick, { instanceId: codex, model: "gpt-5" })).toBe(true);
  });

  it("keeps a pick the thread does not run yet", () => {
    const pick = {
      instanceId: codex,
      model: "gpt-5",
      options: [{ id: "reasoningEffort", value: "high" }],
    };
    expect(pickMatchesThread(options, pick, { instanceId: codex, model: "gpt-5" })).toBe(false);
    expect(pickMatchesThread(options, pick, { instanceId: codex, model: "gpt-5-codex" })).toBe(
      false,
    );
    expect(pickMatchesThread(options, pick, null)).toBe(false);
  });
});

describe("modelPickerRows", () => {
  const options = flattenModelOptions([
    {
      instanceId: "codex",
      driver: "codex",
      displayName: "Codex",
      models: [
        { slug: "gpt-6", name: "GPT-6", isCustom: false, capabilities: null },
        { slug: "o3", name: "o3", isCustom: false, isLegacy: true, capabilities: null },
        { slug: "gpt-4o", name: "GPT-4o", isCustom: false, isLegacy: true, capabilities: null },
      ],
    },
    provider("claude", "Claude", [{ slug: "opus", name: "Opus" }]),
  ] as never);
  const names = (shown: ReadonlySet<string>) =>
    modelPickerRows(options, shown).map((row) =>
      row.kind === "model" ? row.option.model : `${row.shown ? "less" : "more"}:${row.count}`,
    );

  it("folds a provider's older models behind a row at the end of its models", () => {
    expect(names(new Set())).toEqual(["gpt-6", "more:2", "opus"]);
  });

  it("lists them in place once shown, and the row then shows less", () => {
    expect(names(new Set(["codex"]))).toEqual(["gpt-6", "o3", "gpt-4o", "less:2", "opus"]);
  });
});

describe("effortReadout", () => {
  const model = (ids: string[], descriptorId = "effort") =>
    flattenModelOptions([
      {
        instanceId: "claude",
        driver: "claudeAgent",
        models: [
          {
            slug: "opus",
            name: "Opus",
            isCustom: false,
            capabilities: {
              optionDescriptors: [
                {
                  type: "select",
                  id: descriptorId,
                  label: "Effort",
                  options: ids.map((id) => ({ id, label: id === "xhigh" ? "Extra High" : id })),
                  promptInjectedValues: ["ultrathink"],
                },
              ],
            },
          },
        ],
      },
    ] as never);
  const selection = { instanceId: ProviderInstanceId.make("claude"), model: "opus" };
  const read = (ids: string[], value: string, descriptorId?: string) =>
    effortReadout(model(ids, descriptorId), selection, value);

  it("names the level by its label and fills a bar for each level up to it", () => {
    expect(read(["low", "medium", "high", "xhigh", "max", "ultrathink"], "xhigh")).toEqual({
      label: "Extra High",
      bars: { count: 4, filled: 4 },
    });
  });

  it("counts no bar for an off level the levels start at", () => {
    expect(read(["off", "low", "high"], "off").bars).toEqual({ count: 2, filled: 0 });
  });

  it("keeps a named level, a lone level and another select as words", () => {
    expect(read(["low", "high", "max"], "max").bars).toBeNull();
    expect(read(["low", "ultrathink"], "low").bars).toBeNull();
    expect(read(["low", "high"], "low", "verbosity").bars).toBeNull();
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

describe("nextPick", () => {
  const codex = ProviderInstanceId.make("codex");
  const picked = { instanceId: codex, model: "gpt-5-codex" };
  const running = { instanceId: codex, model: "gpt-5" };

  it("drops a pick once the thread changes elsewhere, even back to what was picked", () => {
    const pick = { selection: picked, base: 3, own: 0 };
    expect(nextPick([], pick, { modelSelection: running, selectionRevision: 3 })).toBe(pick);
    expect(nextPick([], pick, { modelSelection: running, selectionRevision: 4 })).toBeNull();
    expect(nextPick([], pick, { modelSelection: picked, selectionRevision: 4 })).toBeNull();
  });

  it("keeps a pick across this client's own mode changes, then gives way to the next", () => {
    const pick = { selection: picked, base: 3, own: 2 };
    expect(nextPick([], pick, { modelSelection: running, selectionRevision: 4 })).toBe(pick);
    const rebased = nextPick([], pick, { modelSelection: running, selectionRevision: 5 });
    expect(rebased).toEqual({ selection: picked, base: 5, own: 0 });
    expect(nextPick([], rebased!, { modelSelection: running, selectionRevision: 6 })).toBeNull();
  });

  it("drops a pick the thread runs when the MC sends no revision", () => {
    const pick = { selection: picked, base: null, own: 0 };
    expect(nextPick([], pick, { modelSelection: running })).toBe(pick);
    expect(nextPick([], pick, { modelSelection: picked })).toBeNull();
  });
});
