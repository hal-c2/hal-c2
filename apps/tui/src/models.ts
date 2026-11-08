import type {
  ModelCapabilities,
  ModelSelection,
  ProviderOptionDescriptor,
  ProviderOptionSelection,
  ServerProvider,
} from "@hal-c2/contracts";
import { isProviderAvailable } from "@hal-c2/contracts";
import {
  buildProviderOptionSelectionsFromDescriptors,
  createModelSelection,
  getProviderOptionCurrentValue,
  getProviderOptionDescriptors,
} from "@hal-c2/shared/model";

import { modelButtonName, modelFullName } from "./modelNames.ts";

// Flatten the server config's providers into a flat, selectable model list for the
// picker, at the level the TUI needs: provider + model slug + display labels. Pure.

export interface ModelOption {
  readonly instanceId: ServerProvider["instanceId"];
  /** The provider-specific model slug sent back as the selection. */
  readonly model: string;
  /** The full name, as the picker lists it. */
  readonly label: string;
  /** The name the user would say, as the composer's model control shows it. */
  readonly buttonLabel?: string;
  readonly providerLabel: string;
  readonly capabilities: ModelCapabilities | null;
  /** The provider cannot change models once a conversation has started. */
  readonly requiresNewThreadForModelChange?: boolean;
  /** An older model the picker keeps behind its provider's "Show more" row. */
  readonly isLegacy?: boolean;
}

export function flattenModelOptions(providers: ReadonlyArray<ServerProvider>): ModelOption[] {
  const options: ModelOption[] = [];
  for (const provider of providers) {
    if (provider.enabled === false || !isProviderAvailable(provider)) continue;
    const providerLabel = provider.displayName ?? provider.driver ?? provider.instanceId;
    for (const model of provider.models) {
      options.push({
        instanceId: provider.instanceId,
        model: model.slug,
        label: modelFullName(model),
        buttonLabel: modelButtonName(model, provider.driver),
        providerLabel,
        capabilities: model.capabilities,
        ...(provider.requiresNewThreadForModelChange === true
          ? { requiresNewThreadForModelChange: true }
          : {}),
        ...(model.isLegacy === true ? { isLegacy: true } : {}),
      });
    }
  }
  return options;
}

export interface ReasoningChoice {
  readonly id: string;
  readonly label: string;
  readonly description?: string;
}

export interface ReasoningChoices {
  readonly descriptorId: string;
  readonly choices: ReadonlyArray<ReasoningChoice>;
  readonly selectedId: string | null;
}

const REASONING_DESCRIPTOR_IDS = new Set(["reasoningEffort", "effort", "reasoning"]);

function reasoningChoicesFromDescriptors(
  descriptors: ReadonlyArray<ProviderOptionDescriptor>,
): ReasoningChoices | null {
  const selects = descriptors.filter((descriptor) => descriptor.type === "select");
  const reasoning =
    selects.find((descriptor) => REASONING_DESCRIPTOR_IDS.has(descriptor.id)) ?? selects[0];
  if (!reasoning || reasoning.type !== "select") return null;
  const selected = getProviderOptionCurrentValue(reasoning);
  // A level the prompt carries (Ultrathink) is typed, never picked.
  const injected = reasoning.promptInjectedValues ?? [];
  return {
    descriptorId: reasoning.id,
    choices: reasoning.options
      .filter((option) => !injected.includes(option.id))
      .map((option) => ({
        id: option.id,
        label: option.label,
        ...(option.description ? { description: option.description } : {}),
      })),
    selectedId: typeof selected === "string" ? selected : null,
  };
}

/**
 * The reasoning/effort choices for a model, from its capability descriptors — the
 * named reasoning select if present, else the first select descriptor. Null when
 * the model exposes no select options. Mirrors the web TraitsPicker's data.
 */
export function reasoningChoicesFor(
  providers: ReadonlyArray<ServerProvider>,
  instanceId: string,
  model: string,
  selections?: ReadonlyArray<ProviderOptionSelection>,
): ReasoningChoices | null {
  const provider = providers.find((entry) => entry.instanceId === instanceId);
  const found = provider?.models.find((entry) => entry.slug === model);
  const descriptors = found?.capabilities
    ? getProviderOptionDescriptors({ caps: found.capabilities, selections })
    : [];
  return reasoningChoicesFromDescriptors(descriptors);
}

/**
 * Resolve a model selection the same way the web composer does: capability
 * defaults and current values are materialized into the options sent with a
 * turn, while explicit draft selections win over those defaults.
 */
export function resolveModelSelection(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection | null | undefined,
): ModelSelection | null {
  if (!selection) return null;
  const option = options.find(
    (candidate) =>
      candidate.instanceId === selection.instanceId && candidate.model === selection.model,
  );
  const descriptors = option?.capabilities
    ? getProviderOptionDescriptors({
        caps: option.capabilities,
        selections: selection.options,
      })
    : [];
  return createModelSelection(
    selection.instanceId,
    selection.model,
    buildProviderOptionSelectionsFromDescriptors(descriptors) ?? selection.options,
  );
}

/**
 * A draft's pick is what the thread already runs: the same account and model
 * with the same options once both are resolved, Fast off counting as unset
 * (the desktop's pickMatchesThread). The pick has then been taken.
 */
export function pickMatchesThread(
  options: ReadonlyArray<ModelOption>,
  pick: ModelSelection,
  threadSelection: ModelSelection | null | undefined,
): boolean {
  const picked = resolveModelSelection(options, pick);
  const running = resolveModelSelection(options, threadSelection);
  if (!picked || !running) return false;
  if (picked.instanceId !== running.instanceId || picked.model !== running.model) return false;
  const values = (selection: ModelSelection) =>
    new Map(
      (selection.options ?? [])
        .filter((option) => !(option.id === "fastMode" && option.value === false))
        .map((option) => [option.id, option.value]),
    );
  const left = values(picked);
  const right = values(running);
  return left.size === right.size && [...left].every(([id, value]) => right.get(id) === value);
}

/** Create a complete selection for a newly chosen model, using its defaults. */
export function modelSelectionForOption(option: ModelOption): ModelSelection {
  const descriptors = option.capabilities
    ? getProviderOptionDescriptors({ caps: option.capabilities })
    : [];
  return createModelSelection(
    option.instanceId,
    option.model,
    buildProviderOptionSelectionsFromDescriptors(descriptors),
  );
}

/** Replace one provider option without dropping the rest of the model traits. */
export function withModelSelectionOption(
  selection: ModelSelection,
  descriptorId: string,
  value: string | boolean,
): ModelSelection {
  return createModelSelection(selection.instanceId, selection.model, [
    ...(selection.options ?? []).filter((option) => option.id !== descriptorId),
    { id: descriptorId, value },
  ]);
}

/** Effort choices and the resolved current/default value for a flattened model. */
export function reasoningChoicesForSelection(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection | null | undefined,
): ReasoningChoices | null {
  if (!selection) return null;
  const model = options.find(
    (option) => option.instanceId === selection.instanceId && option.model === selection.model,
  );
  const descriptors = model?.capabilities
    ? getProviderOptionDescriptors({
        caps: model.capabilities,
        selections: selection.options,
      })
    : [];
  return reasoningChoicesFromDescriptors(descriptors);
}

/** One row of the model picker: a model, or a provider's "Show more" / "Show less" row. */
export type ModelPickerRow =
  | { readonly kind: "model"; readonly option: ModelOption }
  | {
      readonly kind: "legacy";
      readonly instanceId: string;
      readonly providerLabel: string;
      readonly shown: boolean;
      readonly count: number;
    };

/**
 * The model picker's rows (upstream #28076): each provider's current models,
 * then a "Show more" row that lists its older ones in place, which then reads
 * "Show less". `shown` names the providers whose older models are listed.
 */
export function modelPickerRows(
  options: ReadonlyArray<ModelOption>,
  shown: ReadonlySet<string>,
): ModelPickerRow[] {
  const rows: ModelPickerRow[] = [];
  const instances = [...new Set(options.map((option) => option.instanceId))];
  for (const instanceId of instances) {
    const models = options.filter((option) => option.instanceId === instanceId);
    const legacy = models.filter((option) => option.isLegacy === true);
    for (const option of models) {
      if (option.isLegacy !== true) rows.push({ kind: "model", option });
    }
    if (legacy.length === 0) continue;
    const open = shown.has(instanceId);
    if (open) for (const option of legacy) rows.push({ kind: "model", option });
    rows.push({
      kind: "legacy",
      instanceId,
      providerLabel: legacy[0]!.providerLabel,
      shown: open,
      count: legacy.length,
    });
  }
  return rows;
}

/** One provider option of the selected model with its current value (desktop `ShellComposerOption`). */
export interface ModelOptionState {
  readonly id: string;
  readonly label: string;
  readonly type: "select" | "boolean";
  readonly value: string | boolean | null;
  readonly choices: ReadonlyArray<{ readonly id: string; readonly label: string }>;
}

/** Every provider option of the selected model, with the selection's values applied. */
export function modelOptionStates(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection | null | undefined,
): ModelOptionState[] {
  if (!selection) return [];
  const model = options.find(
    (option) => option.instanceId === selection.instanceId && option.model === selection.model,
  );
  if (!model?.capabilities) return [];
  return getProviderOptionDescriptors({
    caps: model.capabilities,
    selections: selection.options,
  }).map((descriptor) => ({
    id: descriptor.id,
    label: descriptor.label,
    type: descriptor.type,
    value: getProviderOptionCurrentValue(descriptor) ?? null,
    choices:
      descriptor.type === "select"
        ? descriptor.options
            .filter((choice) => !(descriptor.promptInjectedValues ?? []).includes(choice.id))
            .map((choice) => ({ id: choice.id, label: choice.label }))
        : [],
  }));
}

/** The select a model's effort is (the named reasoning select, else the first). */
function effortDescriptor(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection,
): Extract<ProviderOptionDescriptor, { type: "select" }> | null {
  const model = options.find(
    (option) => option.instanceId === selection.instanceId && option.model === selection.model,
  );
  const selects = (
    model?.capabilities
      ? getProviderOptionDescriptors({ caps: model.capabilities, selections: selection.options })
      : []
  ).filter((descriptor) => descriptor.type === "select");
  return (
    selects.find((descriptor) => REASONING_DESCRIPTOR_IDS.has(descriptor.id)) ?? selects[0] ?? null
  );
}

/**
 * The effort one level up (1) or down (-1) from the selection's, wrapping, as
 * composer.increaseEffort / decreaseEffort set it (the desktop's steppedChoice).
 * A level the prompt carries (Ultrathink) is typed, never stepped to, and a
 * current level the model does not list steps from the model's default.
 * `fromAbove` steps from above the top level, as a prompt that carries
 * Ultrathink does: up to the lowest level, down to the highest. Null when
 * there is nothing to step between.
 */
export function steppedEffort(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection,
  direction: 1 | -1,
  fromAbove = false,
): { readonly descriptorId: string; readonly value: string } | null {
  const descriptor = effortDescriptor(options, selection);
  if (!descriptor) return null;
  const injected = descriptor.promptInjectedValues ?? [];
  const choices = descriptor.options.filter((choice) => !injected.includes(choice.id));
  if (choices.length < 2) return null;
  const ids = choices.map((choice) => choice.id);
  const current = getProviderOptionCurrentValue(descriptor);
  if (fromAbove)
    return { descriptorId: descriptor.id, value: direction > 0 ? ids[0]! : ids.at(-1)! };
  let at = typeof current === "string" ? ids.indexOf(current) : -1;
  if (at < 0) at = choices.findIndex((choice) => choice.isDefault === true);
  const value =
    at < 0
      ? direction > 0
        ? ids[0]!
        : ids.at(-1)!
      : ids[(((at + direction) % ids.length) + ids.length) % ids.length]!;
  return { descriptorId: descriptor.id, value };
}

/** How full the effort's rising bars are; `count` levels, the lowest `filled` lit. */
export interface EffortBars {
  readonly count: number;
  readonly filled: number;
}

/**
 * The effort as the composer names it (upstream #25869): the level's label,
 * and the bars Settings' effort display can show it as instead. Max, Ultracode
 * and a level the prompt carries keep their names, and an "off" at the bottom
 * is no bar (the desktop's effortBars). Bars are null for a word-only level or
 * a select that is not the model's reasoning.
 */
export function effortReadout(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection,
  value: string,
): { readonly label: string; readonly bars: EffortBars | null } {
  const descriptor = effortDescriptor(options, selection);
  const label = descriptor?.options.find((choice) => choice.id === value)?.label || value;
  if (!descriptor || !REASONING_DESCRIPTOR_IDS.has(descriptor.id)) return { label, bars: null };
  const named = new Set(["ultracode", "max", ...(descriptor.promptInjectedValues ?? [])]);
  const levels = descriptor.options.map((choice) => choice.id).filter((id) => !named.has(id));
  const at = levels.indexOf(value);
  if (levels.length < 2 || at < 0) return { label, bars: null };
  const startsAtOff = levels[0] === "off" || levels[0] === "none";
  return {
    label,
    bars: {
      count: startsAtOff ? levels.length - 1 : levels.length,
      filled: startsAtOff ? at : at + 1,
    },
  };
}

/** "please ultrathink about it": the prompt asks for Ultrathink in its own words, past any prefix. */
export function ultrathinkInWords(text: string): boolean {
  return /\bultrathink\b/i.test(withoutUltrathinkPrefix(text));
}

/** The prompt without its "Ultrathink:" prefix. */
export function withoutUltrathinkPrefix(text: string): string {
  return text.replace(/^\s*Ultrathink:\s*/, "");
}

/**
 * The level the prompt itself asks for (Ultrathink, by its prefix or in its
 * own words), which is the effort shown; `locked` when only editing the
 * prompt's words can change it. Null when the prompt asks for none.
 */
export function promptEffort(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection | null | undefined,
  text: string,
): { readonly value: string; readonly locked: boolean } | null {
  if (!selection) return null;
  const injected = effortDescriptor(options, selection)?.promptInjectedValues?.[0];
  if (injected === undefined) return null;
  const locked = ultrathinkInWords(text);
  return locked || /^\s*Ultrathink:/.test(text) ? { value: injected, locked } : null;
}

// ── Fallback accounts (upstream #23957, #27859, #29789) ─────────────────────

/** The account can run a turn: enabled, installed, and its last check passed. */
export function providerReady(provider: ServerProvider): boolean {
  return (
    provider.enabled !== false &&
    isProviderAvailable(provider) &&
    provider.status !== "error" &&
    provider.status !== "disabled"
  );
}

/** The model a thread starts on with this account: its default, else its first built-in. */
export function defaultModelSlug(provider: ServerProvider): string | null {
  const builtIn = provider.models.filter((model) => !model.isCustom);
  return (
    (builtIn.find((model) => model.isDefault === true) ?? builtIn[0] ?? provider.models[0])?.slug ??
    null
  );
}

/**
 * The slug another account lists `model` under: the same slug, else a built-in
 * model it names or is an alias of. Never a custom model that only shares the
 * name, so "5.4" finds GPT-5.4 and not a custom model called "5.4". Null when
 * the account has no such model.
 */
export function fallbackModelSlug(provider: ServerProvider, model: string): string | null {
  if (provider.models.some((entry) => entry.slug === model)) return model;
  const wanted = model.toLowerCase();
  return (
    provider.models.find(
      (entry) =>
        !entry.isCustom &&
        (entry.name.toLowerCase() === wanted || (entry.aliases ?? []).includes(model)),
    )?.slug ?? null
  );
}
