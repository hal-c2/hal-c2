import { describe, expect, it } from "vite-plus/test";
import type { ProviderInstanceId, ProviderOptionDescriptor, RuntimeMode } from "@hal-c2/contracts";

import type { ProviderInstanceEntry } from "../providerInstances";
import {
  applyComposerOptionChange,
  buildShellComposerInstances,
  buildShellComposerState,
  toggleFavoriteModel,
} from "./shellComposerState";

const codexInstanceId = "codex" as ProviderInstanceId;

const effortDescriptor: ProviderOptionDescriptor = {
  id: "effort",
  label: "Effort",
  type: "select",
  options: [
    { id: "low", label: "Low" },
    { id: "high", label: "High" },
  ],
  currentValue: "low",
};
const thinkingDescriptor: ProviderOptionDescriptor = {
  id: "thinking",
  label: "Thinking",
  type: "boolean",
  currentValue: false,
};

const codexEntry = {
  instanceId: codexInstanceId,
  driverKind: "codex",
  displayName: "Codex",
  enabled: true,
  installed: true,
  isDefault: true,
  isAvailable: true,
  status: "ready",
  snapshot: {},
} as ProviderInstanceEntry;

const runtimeModes: ReadonlyArray<{ value: RuntimeMode; label: string; description: string }> = [
  { value: "approval-required", label: "Supervised", description: "Ask first." },
  { value: "full-access", label: "Full access", description: "Never ask." },
];

function baseInput() {
  return {
    target: "env:thread-1",
    routeKind: "server" as const,
    text: "hello",
    cursor: 5,
    triggerKind: null,
    suggestions: [],
    suggestionsEmptyText: null,
    attachments: [],
    terminalContexts: [],
    placeholder: "Ask anything",
    editorDisabled: false,
    hasSendableContent: true,
    sendDisabledReason: null,
    isRunning: false,
    followUpBehavior: "steer" as const,
    enterIntents: { singleLine: { "": "foreground" as const }, multiline: {} },
    isSendBusy: false,
    isConnecting: false,
    environmentUnavailable: false,
    noProviderAvailable: false,
    projectSelectionRequired: false,
    pendingApprovalCount: 0,
    pendingUserInputCount: 0,
    showPlanFollowUpPrompt: false,
    selectedInstanceId: codexInstanceId,
    selectedModel: "gpt-5.4",
    optionDescriptors: [effortDescriptor, thinkingDescriptor],
    runtimeMode: "approval-required" as RuntimeMode,
    runtimeModes,
    interactionMode: "default" as const,
    showInteractionModeToggle: true,
  };
}

describe("buildShellComposerState", () => {
  it("projects the option descriptors", () => {
    const state = buildShellComposerState(baseInput());
    expect(state.canSend).toBe(true);
    expect(state.options).toEqual([
      {
        id: "effort",
        label: "Effort",
        type: "select",
        value: "low",
        choices: [
          { id: "low", label: "Low" },
          { id: "high", label: "High" },
        ],
      },
      { id: "thinking", label: "Thinking", type: "boolean", value: false, choices: [] },
    ]);
    expect(state.runtimeModes).toHaveLength(2);
  });

  it("blocks sending and explains why", () => {
    expect(buildShellComposerState({ ...baseInput(), noProviderAvailable: true })).toMatchObject({
      canSend: false,
      sendDisabledReason: "No provider available",
    });
    expect(buildShellComposerState({ ...baseInput(), hasSendableContent: false })).toMatchObject({
      canSend: false,
      sendDisabledReason: null,
    });
    expect(
      buildShellComposerState({
        ...baseInput(),
        hasSendableContent: false,
        showPlanFollowUpPrompt: true,
      }).canSend,
    ).toBe(true);
    expect(
      buildShellComposerState({ ...baseInput(), sendDisabledReason: "Messages loading" })
        .sendDisabledReason,
    ).toBe("Messages loading");
  });
});

const claudeInstanceId = "claudeAgent" as ProviderInstanceId;
const claudeEntry = {
  ...codexEntry,
  instanceId: claudeInstanceId,
  driverKind: "claudeAgent",
  displayName: "Claude",
} as ProviderInstanceEntry;
const cursorEntry = {
  ...codexEntry,
  instanceId: "cursor" as ProviderInstanceId,
  driverKind: "cursor",
  displayName: "Cursor",
  status: "error",
  snapshot: { message: "Not installed." },
} as ProviderInstanceEntry;

function pickerInput() {
  return {
    selectedInstanceId: codexInstanceId,
    selectedModel: "gpt-5.4",
    instanceEntries: [
      codexEntry,
      claudeEntry,
      cursorEntry,
      { ...codexEntry, instanceId: "off" as ProviderInstanceId, enabled: false },
    ],
    modelOptionsByInstance: new Map([
      [
        codexInstanceId,
        [
          { slug: "gpt-5.4", name: "GPT-5.4", isCustom: false },
          { slug: "gpt-5.4-mini", name: "GPT-5.4 mini", isCustom: false, badge: "new" as const },
        ],
      ],
      [
        claudeInstanceId,
        [
          { slug: "sonnet", name: "Claude Sonnet", isCustom: false },
          { slug: "opus", name: "Claude Opus", isCustom: false },
        ],
      ],
      ["cursor" as ProviderInstanceId, [{ slug: "auto", name: "Auto", isCustom: false }]],
    ]),
    getModelDisabledReason: (_instanceId: ProviderInstanceId, model: string) =>
      model === "gpt-5.4-mini" ? "Started with another model" : null,
    favorites: [{ provider: claudeInstanceId, model: "opus" }],
    lockedProvider: null,
    lockedContinuationGroupKey: null,
  };
}

describe("buildShellComposerInstances", () => {
  it("lists each enabled instance with its models, favourites first", () => {
    const instances = buildShellComposerInstances(pickerInput());
    expect(instances.map((instance) => instance.instanceId)).toEqual([
      "codex",
      "claudeAgent",
      "cursor",
    ]);
    expect(instances[0]).toEqual({
      instanceId: "codex",
      driverKind: "codex",
      displayName: "Codex",
      accentColor: null,
      iconUrl: null,
      initials: "CO",
      showBadge: false,
      status: "ready",
      isAvailable: true,
      unavailableReason: null,
      models: [
        {
          slug: "gpt-5.4",
          name: "GPT-5.4",
          shortName: null,
          subProvider: null,
          isFavorite: false,
          isCustom: false,
          isNew: false,
          isLegacy: false,
          isUnavailable: false,
          disabledReason: null,
        },
        {
          slug: "gpt-5.4-mini",
          name: "GPT-5.4 mini",
          shortName: null,
          subProvider: null,
          isFavorite: false,
          isCustom: false,
          isNew: true,
          isLegacy: false,
          isUnavailable: false,
          disabledReason: "Started with another model",
        },
      ],
    });
    expect(instances[1]!.models.map((model) => [model.slug, model.isFavorite])).toEqual([
      ["opus", true],
      ["sonnet", false],
    ]);
  });

  it("keeps an unavailable instance in the rail with the reason and no models", () => {
    const cursor = buildShellComposerInstances(pickerInput())[2]!;
    expect(cursor).toMatchObject({
      isAvailable: false,
      unavailableReason: "Cursor — Unavailable. Not installed.",
      models: [],
    });
  });

  it("moves instances a started thread cannot switch to last, explaining why", () => {
    const instances = buildShellComposerInstances({
      ...pickerInput(),
      lockedProvider: "claudeAgent" as ProviderInstanceEntry["driverKind"],
    });
    expect(instances.map((instance) => [instance.instanceId, instance.isAvailable])).toEqual([
      ["claudeAgent", true],
      ["codex", false],
      ["cursor", false],
    ]);
    expect(instances[1]).toMatchObject({
      unavailableReason:
        "Codex is unavailable in this thread. Start a new thread to switch providers.",
      models: [],
    });
  });
});

describe("toggleFavoriteModel", () => {
  it("stars a model once and unstars it again", () => {
    const opus = { provider: claudeInstanceId, model: "opus" };
    const starred = toggleFavoriteModel([], opus);
    expect(starred).toEqual([opus]);
    expect(toggleFavoriteModel(starred, { ...opus })).toEqual([]);
  });
});

describe("applyComposerOptionChange", () => {
  it("updates a select option to a valid choice only", () => {
    expect(
      applyComposerOptionChange([effortDescriptor, thinkingDescriptor], "effort", "high"),
    ).toEqual([
      { id: "effort", value: "high" },
      { id: "thinking", value: false },
    ]);
    expect(applyComposerOptionChange([effortDescriptor], "effort", "extreme")).toEqual([
      { id: "effort", value: "low" },
    ]);
  });

  it("updates a boolean option only with a boolean", () => {
    expect(applyComposerOptionChange([thinkingDescriptor], "thinking", true)).toEqual([
      { id: "thinking", value: true },
    ]);
    expect(applyComposerOptionChange([thinkingDescriptor], "thinking", "yes")).toEqual([
      { id: "thinking", value: false },
    ]);
  });
});
