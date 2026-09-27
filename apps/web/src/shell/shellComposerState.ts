import type {
  ModelSelection,
  ProviderDriverKind,
  ProviderInstanceId,
  ProviderOptionDescriptor,
  ProviderOptionSelection,
  RuntimeMode,
  ServerProviderModel,
} from "@hal-c2/contracts";
import type {
  ShellComposerInstance,
  ShellComposerOption,
  ShellComposerState,
  ShellComposerSuggestion,
} from "@hal-c2/contracts/shell";
import { providerInstanceInitials } from "@hal-c2/client-runtime/state/provider-instance-display";
import {
  buildProviderOptionSelectionsFromDescriptors,
  getProviderOptionDescriptors,
} from "@hal-c2/shared/model";

import { shouldIncludeModelPickerOption } from "../components/chat/ModelPickerContent";
import { describeUnavailableInstance } from "../components/chat/ModelPickerSidebar";
import { resolveProviderInstanceAcpRegistryIconUrl } from "../components/chat/ProviderInstanceIcon";
import type { AppModelOption } from "../modelSelection";
import { providerModelKey, sortModelsForProviderInstance } from "../modelOrdering";
import {
  isProviderInstancePickerReady,
  isProviderInstancePickerVisible,
  NO_PROVIDER_MODEL_SELECTION,
  shouldShowInstanceBadge,
  type ProviderInstanceEntry,
} from "../providerInstances";
import { getProviderModelCapabilities } from "../providerModels";

export interface ShellComposerStateInput {
  readonly target: string | null;
  readonly routeKind: "server" | "draft";
  readonly text: string;
  readonly cursor: number;
  readonly triggerKind: ShellComposerState["triggerKind"];
  readonly suggestions: ReadonlyArray<ShellComposerSuggestion>;
  readonly suggestionsEmptyText: string | null;
  readonly attachments: ShellComposerState["attachments"];
  readonly terminalContexts: ShellComposerState["terminalContexts"];
  readonly placeholder: string;
  readonly editorDisabled: boolean;
  readonly hasSendableContent: boolean;
  readonly sendDisabledReason: string | null;
  readonly isRunning: boolean;
  readonly followUpBehavior: "queue" | "steer";
  readonly isSendBusy: boolean;
  readonly isConnecting: boolean;
  readonly environmentUnavailable: boolean;
  readonly noProviderAvailable: boolean;
  readonly projectSelectionRequired: boolean;
  readonly pendingApprovalCount: number;
  readonly pendingUserInputCount: number;
  readonly showPlanFollowUpPrompt: boolean;
  readonly selectedInstanceId: ProviderInstanceId | null;
  readonly selectedModel: string | null;
  readonly optionDescriptors: ReadonlyArray<ProviderOptionDescriptor>;
  readonly runtimeMode: RuntimeMode;
  readonly runtimeModes: ReadonlyArray<{ value: RuntimeMode; label: string; description: string }>;
  readonly interactionMode: "default" | "plan";
  readonly showInteractionModeToggle: boolean;
}

export interface ShellModelPickerInput {
  readonly selectedInstanceId: ProviderInstanceId | null;
  readonly selectedModel: string | null;
  readonly instanceEntries: ReadonlyArray<ProviderInstanceEntry>;
  readonly modelOptionsByInstance: ReadonlyMap<ProviderInstanceId, ReadonlyArray<AppModelOption>>;
  readonly getModelDisabledReason: (instanceId: ProviderInstanceId, model: string) => string | null;
  /** Client setting `favorites`, keyed by instance id. */
  readonly favorites: ReadonlyArray<{
    readonly provider: ProviderInstanceId;
    readonly model: string;
  }>;
  /** Set once the thread has run: only this driver (and continuation group) can be chosen. */
  readonly lockedProvider: ProviderDriverKind | null;
  readonly lockedContinuationGroupKey: string | null;
}

/** The option descriptors for a model, with the draft's current selections applied. */
export function resolveComposerOptionDescriptors(input: {
  readonly provider: ProviderDriverKind;
  readonly model: string;
  readonly models: ReadonlyArray<ServerProviderModel>;
  readonly selections: ReadonlyArray<ProviderOptionSelection> | null | undefined;
  readonly planModeEnabled: boolean;
}): ReadonlyArray<ProviderOptionDescriptor> {
  const caps = getProviderModelCapabilities(
    input.models,
    input.model,
    input.provider,
    input.planModeEnabled,
  );
  return getProviderOptionDescriptors({ caps, selections: input.selections });
}

/** Applies one option change and returns the selections to persist on the draft. */
export function applyComposerOptionChange(
  descriptors: ReadonlyArray<ProviderOptionDescriptor>,
  id: string,
  value: string | boolean,
): ModelSelection["options"] {
  const next = descriptors.map((descriptor) => {
    if (descriptor.id !== id) return descriptor;
    if (descriptor.type === "select") {
      return typeof value === "string" && descriptor.options.some((choice) => choice.id === value)
        ? { ...descriptor, currentValue: value }
        : descriptor;
    }
    return typeof value === "boolean" ? { ...descriptor, currentValue: value } : descriptor;
  });
  return buildProviderOptionSelectionsFromDescriptors(next);
}

function toShellOption(descriptor: ProviderOptionDescriptor): ShellComposerOption {
  return descriptor.type === "select"
    ? {
        id: descriptor.id,
        label: descriptor.label,
        type: "select",
        value: descriptor.currentValue ?? null,
        choices: descriptor.options.map((choice) => ({ id: choice.id, label: choice.label })),
      }
    : {
        id: descriptor.id,
        label: descriptor.label,
        type: "boolean",
        value: descriptor.currentValue ?? null,
        choices: [],
      };
}

/** Returns a new `favorites` setting with the model starred or unstarred, as the web picker does. */
export function toggleFavoriteModel<
  T extends { readonly provider: string; readonly model: string },
>(favorites: ReadonlyArray<T>, favorite: T): T[] {
  const index = favorites.findIndex(
    (entry) => entry.provider === favorite.provider && entry.model === favorite.model,
  );
  return index >= 0 ? favorites.filter((_, i) => i !== index) : [...favorites, favorite];
}

/**
 * The web picker's rail and lists (`ModelPickerContent`/`ModelPickerSidebar`),
 * resolved for the native picker: enabled instances with locked-out ones last,
 * only the models the web picker offers, favourites first in each instance.
 */
export function buildShellComposerInstances(input: ShellModelPickerInput): ShellComposerInstance[] {
  const favoriteKeys = new Set(
    input.favorites.map((favorite) => providerModelKey(favorite.provider, favorite.model)),
  );
  const matchesLock = (entry: ProviderInstanceEntry) =>
    input.lockedProvider === null ||
    (entry.driverKind === input.lockedProvider &&
      (!input.lockedContinuationGroupKey ||
        entry.continuationGroupKey === input.lockedContinuationGroupKey));
  const visible = input.instanceEntries.filter(isProviderInstancePickerVisible);
  const rail = [...visible.filter(matchesLock), ...visible.filter((entry) => !matchesLock(entry))];
  return rail.map((entry) => {
    const lockedOut = !matchesLock(entry);
    const ready = isProviderInstancePickerReady(entry);
    const offered = lockedOut
      ? []
      : (input.modelOptionsByInstance.get(entry.instanceId) ?? []).filter((option) =>
          shouldIncludeModelPickerOption({
            entry,
            option,
            activeInstanceId: input.selectedInstanceId ?? NO_PROVIDER_MODEL_SELECTION.instanceId,
            activeModel: input.selectedModel ?? "",
          }),
        );
    const isFavorite = (slug: string) => favoriteKeys.has(providerModelKey(entry.instanceId, slug));
    const models = sortModelsForProviderInstance(offered, {
      favoriteModels: offered.filter((option) => isFavorite(option.slug)).map((o) => o.slug),
      groupFavorites: true,
    });
    return {
      instanceId: entry.instanceId,
      driverKind: entry.driverKind,
      displayName: entry.displayName,
      accentColor: entry.accentColor ?? null,
      iconUrl: resolveProviderInstanceAcpRegistryIconUrl({
        driverKind: entry.driverKind,
        agentId: entry.acpRegistryAgentId,
        iconUrl: entry.acpRegistryIconUrl,
      }),
      initials: providerInstanceInitials(entry.displayName),
      showBadge: shouldShowInstanceBadge(entry, visible),
      status: entry.status,
      // The web rail keeps an unready instance reachable when it still offers
      // the thread's current model.
      isAvailable: !lockedOut && (ready || models.length > 0),
      unavailableReason: !ready
        ? describeUnavailableInstance(entry)
        : lockedOut
          ? `${entry.displayName} is unavailable in this thread. Start a new thread to switch providers.`
          : null,
      models: models.map((option) => ({
        slug: option.slug,
        name: option.name,
        shortName: option.shortName ?? null,
        subProvider: option.subProvider ?? null,
        isFavorite: isFavorite(option.slug),
        isCustom: option.isCustom,
        isNew: option.badge === "new",
        isLegacy: option.isLegacy === true,
        isUnavailable: option.isUnavailable === true,
        disabledReason: input.getModelDisabledReason(entry.instanceId, option.slug),
      })),
    };
  });
}

export function buildShellComposerState(input: ShellComposerStateInput): ShellComposerState {
  const blocked =
    input.isSendBusy ||
    input.isConnecting ||
    input.environmentUnavailable ||
    input.noProviderAvailable ||
    input.projectSelectionRequired ||
    input.sendDisabledReason !== null;
  return {
    target: input.target,
    routeKind: input.routeKind,
    text: input.text,
    cursor: input.cursor,
    triggerKind: input.triggerKind,
    suggestions: input.suggestions,
    suggestionsEmptyText: input.suggestionsEmptyText,
    attachments: input.attachments,
    terminalContexts: input.terminalContexts,
    placeholder: input.placeholder,
    editorDisabled: input.editorDisabled,
    canSend: !blocked && (input.hasSendableContent || input.showPlanFollowUpPrompt),
    sendDisabledReason:
      input.sendDisabledReason ??
      (input.environmentUnavailable
        ? "Not connected"
        : input.noProviderAvailable
          ? "No provider available"
          : input.projectSelectionRequired
            ? "Choose a project first"
            : null),
    isRunning: input.isRunning,
    followUpBehavior: input.followUpBehavior,
    isSendBusy: input.isSendBusy,
    isConnecting: input.isConnecting,
    pendingApprovalCount: input.pendingApprovalCount,
    pendingUserInputCount: input.pendingUserInputCount,
    showPlanFollowUpPrompt: input.showPlanFollowUpPrompt,
    selectedInstanceId: input.selectedInstanceId,
    selectedModel: input.selectedModel,
    options: input.optionDescriptors.map(toShellOption),
    runtimeMode: input.runtimeMode,
    runtimeModes: input.runtimeModes,
    interactionMode: input.interactionMode,
    showInteractionModeToggle: input.showInteractionModeToggle,
  };
}
