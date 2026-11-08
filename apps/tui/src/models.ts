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

// Flatten the server config's providers into a flat, selectable model list for the
// picker, at the level the TUI needs: provider + model slug + display labels. Pure.

export interface ModelOption {
  readonly instanceId: ServerProvider["instanceId"];
  /** The provider-specific model slug sent back as the selection. */
  readonly model: string;
  readonly label: string;
  readonly providerLabel: string;
  readonly capabilities: ModelCapabilities | null;
  /** The provider cannot change models once a conversation has started. */
  readonly requiresNewThreadForModelChange?: boolean;
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
        label: model.shortName ?? model.name ?? model.slug,
        providerLabel,
        capabilities: model.capabilities,
        ...(provider.requiresNewThreadForModelChange === true
          ? { requiresNewThreadForModelChange: true }
          : {}),
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
  return {
    descriptorId: reasoning.id,
    choices: reasoning.options.map((option) => ({
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

/** Index of the option matching the current selection, or 0 when none matches. */
export function currentModelIndex(
  options: ReadonlyArray<ModelOption>,
  selection: { readonly instanceId: string; readonly model: string } | null | undefined,
): number {
  if (!selection) return 0;
  const index = options.findIndex(
    (option) => option.instanceId === selection.instanceId && option.model === selection.model,
  );
  return index >= 0 ? index : 0;
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
        ? descriptor.options.map((choice) => ({ id: choice.id, label: choice.label }))
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
 * current level the model does not list steps from the model's default. Null
 * when there is nothing to step between.
 */
export function steppedEffort(
  options: ReadonlyArray<ModelOption>,
  selection: ModelSelection,
  direction: 1 | -1,
): { readonly descriptorId: string; readonly value: string } | null {
  const descriptor = effortDescriptor(options, selection);
  if (!descriptor) return null;
  const injected = descriptor.promptInjectedValues ?? [];
  const choices = descriptor.options.filter((choice) => !injected.includes(choice.id));
  if (choices.length < 2) return null;
  const ids = choices.map((choice) => choice.id);
  const current = getProviderOptionCurrentValue(descriptor);
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

/** "please ultrathink about it": the prompt asks for Ultrathink in its own words, past any prefix. */
export function ultrathinkInWords(text: string): boolean {
  return /\bultrathink\b/i.test(text.replace(/^\s*Ultrathink:\s*/i, ""));
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
