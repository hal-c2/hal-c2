import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import {
  DEFAULT_SERVER_SETTINGS,
  PROVIDER_SEND_TURN_MAX_ATTACHMENTS,
  type KnownComposerContextRecord,
  type ModelSelection,
  type OrchestrationThread,
  type ProviderInteractionMode,
  type RuntimeMode,
  type ServerProvider,
  type ServerSettings,
  type UsageLimitSourceSnapshots,
  type ThreadEnvMode,
  type VcsRef,
} from "@hal-c2/contracts";
import type { ImagePreview } from "@hal-c2/opentui-image";
import { formatComposerContextReference } from "@hal-c2/shared/composerContextReferences";
import { resolveProjectSettings } from "@hal-c2/shared/projectSettings";
import {
  collectLimitAccounts,
  collectLimitNotices,
  collectLimitPools,
  formatResetsIn,
  hasProviderUsageLimits,
  isUsageLimitsCommand,
  withUsageLimitsCommands,
} from "@hal-c2/shared/usageLimits";
import { truncate } from "@hal-c2/shared/String";
import type { PropertyMap } from "opentui-qml";

import { derivePendingApprovals } from "../approvals.ts";
import { readProjectFile } from "../projectActions.ts";
import {
  extractPastedImagePath,
  findPromptImagePathLines,
  imageExtensionForMimeType,
  imageMimeTypeForPath,
  prepareComposerImage,
  prepareComposerImageBytes,
  replacePromptLines,
  type ComposerImageAttachment,
} from "../composerAttachments.ts";
import {
  COMPOSER_MAX_EDITOR_ROWS,
  COMPOSER_MIN_EDITOR_ROWS,
  countWrappedComposerLines,
} from "../components/ChatView.layout.ts";
import type { TuiClient } from "../connection.ts";
import { clip } from "../format.ts";
import {
  interactionModeLabel,
  RUNTIME_MODE_META,
  RUNTIME_MODES,
  runtimeModeLabel,
} from "../controls.ts";
import {
  currentModelIndex,
  modelOptionStates,
  modelSelectionForOption,
  reasoningChoicesForSelection,
  resolveModelSelection,
  withModelSelectionOption,
  type ModelOption,
  type ModelOptionState,
} from "../models.ts";
import {
  newThreadValidationMessage,
  resolveInitialBranch,
  resolveNewThreadBranchSelection,
  resolveNewThreadContext,
  validateNewThread,
  type NewThreadWorkspaceMode,
} from "../newThread.logic.ts";
import {
  normalizeEditedPrompt,
  resolveEditorCommand,
  type EditorCommand,
} from "../promptEditor.ts";
import type { Selection } from "../components/Sidebar.logic.ts";
import type { Store } from "../store.ts";
import { THEME, type Palette } from "../theme.ts";
import { isWorking } from "../timeline.ts";
import { derivePendingUserInputs } from "../userInput.ts";
import { composerSurfaceWidth, type TuiMode } from "./layoutState.ts";
import { idFromKey, projectKey } from "./sidebarState.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

// The composer, its pickers and the new-thread flow. Owns the drafts (per
// target), the per-thread control overrides and the one select overlay, and
// publishes them as `composer`, `newThread` and `select`. Ported from
// ChatView's composer handlers; statuses read exactly as they did there.

export const IMAGE_ONLY_PROMPT =
  "[User attached one or more images without additional text. Respond using the conversation context and the attached image(s).]";

/** Below this composer width the footer keeps only the model and the primary action. */
const COMPACT_SURFACE_WIDTH = 64;
/** ChatComposer's attachment chip width (plus one cell between chips). */
const ATTACHMENT_CHIP_WIDTH = 14;

export type ImageDecoder = (encoded: Uint8Array) => Promise<ImagePreview>;

export interface ComposerOptions {
  readonly client: TuiClient;
  readonly store: Store;
  readonly state: PropertyMap;
  readonly mode: () => TuiMode;
  readonly setMode: (mode: TuiMode) => void;
  readonly chatWidth: () => number;
  /** `VISUAL` / `EDITOR` for Ctrl+G. */
  readonly env: { readonly VISUAL?: string | undefined; readonly EDITOR?: string | undefined };
  readonly homeDir: string;
  /** Run the editor on a file and resolve when it exits (the entry suspends the renderer). */
  readonly runEditor: (command: EditorCommand, file: string) => Promise<void>;
  /** Read an image the user pasted as an absolute local path. */
  readonly readLocalImage: (path: string) => Promise<Uint8Array>;
  readonly decodeImage?: ImageDecoder;
  /** The host completed the prompt's text (a picked command, skill or file): the cursor follows. */
  readonly onTextCompleted?: (text: string) => void;
  /** A new-thread draft opened or closed: the sidebar row and the page follow it. */
  readonly onDraftChange?: () => void;
  /** The editor's rows or the composer's other rows changed: the layout follows. */
  readonly onRowsChange?: (rows: number) => void;
  /** The user stopped this turn from here (its work stays open in the timeline). */
  readonly onInterrupt?: (turnId: string) => void;
  /** The host's clock, for when a limit window resets. */
  readonly nowMs?: () => number;
  /** The connection to the environment is lost: nothing can be sent. */
  readonly offline?: () => boolean;
  /** The popover's inner width and content rows; an open picker windows to them. */
  readonly popover?: () => { readonly width: number; readonly maxRows: number };
  /** The agent's open question (not set aside), which the composer answers. */
  readonly question?: () => { readonly visibleOptions: number } | null;
  /** Attachment chips carry an 8×3 preview (the terminal draws inline images). */
  readonly inlineImages?: boolean;
  readonly palette?: Palette;
}

/** One attachment chip: `id` is the path the image came from, `name` its file name. */
export interface TuiComposerAttachment {
  readonly id: string;
  readonly name: string;
  /** The chip's caption, clipped to the chip. */
  readonly label: string;
  /** The chip's preview when the terminal draws inline images. */
  readonly image: { readonly source: Uint8Array } | null;
}

/** The checkout under the composer (ComposerDock); `pickable` opens the pickers on click. */
export interface TuiComposerContext {
  readonly workspace: string;
  readonly branch: string;
  readonly pickable: boolean;
}

/** Published under `newThread` (null when no draft is open): the draft's project and workspace. */
export interface TuiNewThreadState {
  readonly draftId: string;
  /** Null when there is no project to start in yet. */
  readonly projectKey: string | null;
  readonly projectName: string | null;
  readonly workspaceMode: NewThreadWorkspaceMode;
  /** "New worktree", "Current worktree" or "Project workspace". */
  readonly workspaceLabel: string;
  /** The base branch (new worktree) or the branch the thread works on. */
  readonly branch: string | null;
  readonly worktreePath: string | null;
  readonly refsStatus: "loading" | "ready" | "empty" | "error";
  readonly refs: ReadonlyArray<{
    readonly name: string;
    readonly current: boolean;
    readonly worktreePath: string | null;
    readonly selected: boolean;
  }>;
  /** A branch switch or the create call is in flight. */
  readonly pending: boolean;
}

/** Published under `composer` (the desktop contract's names plus the terminal's extras). */
export interface TuiComposerState {
  readonly target: string | null;
  readonly routeKind: "server" | "draft";
  readonly text: string;
  readonly cursor: number;
  readonly attachments: ReadonlyArray<TuiComposerAttachment>;
  readonly placeholder: string;
  readonly canSend: boolean;
  readonly isRunning: boolean;
  readonly isSendBusy: boolean;
  readonly pendingApprovalCount: number;
  readonly pendingUserInputCount: number;
  readonly primaryAction: "Send" | "Stop" | "Submit answer";
  readonly selectedInstanceId: string | null;
  readonly selectedModel: string | null;
  readonly effort: string | null;
  /** The selected model's provider options (effort, toggles) with their values. */
  readonly options: ReadonlyArray<ModelOptionState>;
  readonly interactionMode: ProviderInteractionMode;
  readonly interactionModeLabel: string;
  readonly runtimeMode: RuntimeMode;
  readonly runtimeModeLabel: string;
  readonly runtimeModes: ReadonlyArray<{ value: string; label: string; description: string }>;
  /** The footer shows only the model and the primary action. */
  readonly compact: boolean;
  /** The composer box's width, centred in the conversation column. */
  readonly surfaceWidth: number;
  /** The editor has the keys; otherwise its row reads as `caption`. */
  readonly inputFocused: boolean;
  /** An open question sits in the composer and the primary action submits it. */
  readonly answering: boolean;
  /** The editor row while the editor does not have the keys. */
  readonly caption: StyledText;
  /** Files referenced with "@", as chips (a click removes one, and its `@path` from the text). */
  readonly references: ReadonlyArray<{ readonly path: string; readonly label: string }>;
  /** Context chips (terminal output, diff notes): a click removes one before sending. */
  readonly contexts: ReadonlyArray<{
    readonly id: string;
    readonly kind: string;
    readonly label: string;
  }>;
  /** The chips that fit, and "+N more" for the rest (or ""). */
  readonly visibleAttachments: ReadonlyArray<TuiComposerAttachment>;
  readonly moreAttachments: string;
  /** The footer's controls and primary action, styled like ComposerFooter's chips. */
  readonly footer: {
    readonly model: StyledText;
    readonly effort: StyledText;
    readonly access: StyledText;
    readonly mode: StyledText;
    readonly compactModel: StyledText;
    readonly showOptions: boolean;
    readonly primary: StyledText;
  };
  readonly context: TuiComposerContext | null;
  /** The selected provider is disabled or signed out: what is wrong and how to fix it. */
  readonly notice: string | null;
  /** The notice wrapped to the composer, one entry per row. */
  readonly noticeLines: ReadonlyArray<string>;
  /** What "/usage-limits" answered, until the next message is sent: one entry per row. */
  readonly limitLines: ReadonlyArray<string>;
  /** Rows besides the editor: borders, footer, question, attachments, context row. */
  readonly chromeRows: number;
  /** Editor height in rows: grows with the text from 3 to 8, or as set by Ctrl+Up / Ctrl+Down. */
  readonly rows: number;
}

export type TuiSelectKind =
  | "model"
  | "reasoning"
  | "runtime"
  | "workspace"
  | "branch"
  | "project-scope"
  | "menu";

/** A list another controller opens in the picker (`Composer.openMenu`). */
export interface TuiMenuSpec {
  readonly title: string;
  readonly status?: TuiSelectState["status"];
  readonly options: ReadonlyArray<{
    readonly label: string;
    readonly description?: string;
    readonly value: string;
  }>;
  readonly index?: number;
  /** Runs with the chosen option's value after the menu closed. */
  readonly onChoose: (value: string) => void;
  /** The mode that has the keys while it is open ("select" unless given). */
  readonly mode?: TuiMode;
  /** The mode the keys go back to when it closes ("compose" unless given). */
  readonly returnMode?: TuiMode;
  /** A search field above the options: typing narrows them by label and description. */
  readonly searchable?: boolean;
}

/** Published under `select`: the one open picker (or `{ open: false }`). */
export interface TuiSelectState {
  readonly open: boolean;
  readonly kind: TuiSelectKind | null;
  readonly title: string;
  readonly status: "loading" | "ready" | "empty" | "error";
  readonly options: ReadonlyArray<{ readonly label: string; readonly description: string }>;
  readonly index: number;
  /** The picker has a search field; `query` is what was typed into it. */
  readonly searchable: boolean;
  readonly query: string;
  /**
   * The options in view, as SelectOverlay draws them: a window around the
   * highlighted one, each its marked name over its description (when that
   * says more than the name).
   */
  readonly rows: ReadonlyArray<{
    readonly index: number;
    readonly active: boolean;
    readonly name: StyledText;
    readonly description: StyledText | null;
  }>;
}

interface Draft {
  /** Files picked with "@": each shows as a chip while its `@path` is still in the text. */
  readonly references?: ReadonlyArray<string>;
  /** Context picked elsewhere (terminal output, a note on a diff line), sent with the reply. */
  readonly contexts?: ReadonlyArray<KnownComposerContextRecord>;
  readonly text: string;
  readonly images: ReadonlyArray<ComposerImageAttachment>;
}

interface NewDraft {
  readonly draftId: string;
  readonly originKey: string;
  readonly projectId: string | null;
  readonly modelSelection: ModelSelection | null;
  readonly runtimeMode: RuntimeMode;
  readonly interactionMode: ProviderInteractionMode;
  readonly workspaceMode: NewThreadWorkspaceMode;
  readonly branch: string | null;
  readonly worktreePath: string | null;
  /** The selected thread's worktree, restored when switching back to "current". */
  readonly contextWorktreePath: string | null;
  readonly refs: ReadonlyArray<VcsRef>;
  readonly refsStatus: TuiNewThreadState["refsStatus"];
  /** The user picked the workspace: the project file's default no longer applies. */
  readonly workspaceChosen?: boolean;
}

interface SelectOption {
  readonly label: string;
  readonly description: string;
  readonly value: string;
}

interface Picker {
  readonly menu?: TuiMenuSpec;
  readonly query?: string;
  readonly kind: TuiSelectKind;
  readonly title: string;
  readonly status: TuiSelectState["status"];
  readonly options: ReadonlyArray<SelectOption>;
  readonly index: number;
}

const EMPTY_DRAFT: Draft = { text: "", images: [] };
// The project-scope picker's "All projects" value.
const ALL_PROJECTS = "__all__";
const NEW_TARGET = "new";

const threadTarget = (threadId: string) => `thread:${threadId}`;

const selectionKey = (selection: Selection | null) =>
  selection ? `${selection.kind}:${selection.id}` : "none";

const field = (payload: unknown, name: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[name]
    : undefined;

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

const envMode = (mode: ThreadEnvMode | null | undefined): "local" | "worktree" | null =>
  mode === "worktree" ? "worktree" : mode === "local" ? "local" : null;

export interface Composer {
  /** Handle a `composer.*`, `select.*`, `thread.new` or `newThread.*` action. */
  readonly dispatch: (action: string, payload?: unknown) => boolean;
  /** Open (or replace) a list in the picker for another controller. */
  readonly openMenu: (spec: TuiMenuSpec) => void;
  /** Close the picker when a menu (with this title, if given) is open. */
  readonly closeMenu: (title?: string) => void;
  /** Attach a context record to the open thread's prompt; false without a thread to reply to. */
  readonly addContext: (record: KnownComposerContextRecord) => boolean;
  /** The open new-thread draft's id and project, for the sidebar row and the page. */
  readonly draft: () => {
    readonly draftId: string;
    readonly projectId: string | null;
    /** The draft holds text or an image (an empty one is not listed in the sidebar). */
    readonly hasContent: boolean;
  } | null;
  /** Re-derive after a store change (selection, detail, shell). */
  readonly sync: () => void;
  /** Re-derive after a layout change (compact footer). */
  readonly relayout: () => void;
  /**
   * The composer's rows besides the editor, for the layout's row split. A
   * one-line prompt (rename, commit, filter) drops the question, the
   * attachments and the compact footer; a popover drops the question.
   */
  readonly chromeRows: (overlay: {
    readonly oneLine: boolean;
    readonly popover: boolean;
  }) => number;
  /** The rows an open picker asks for above the prompt (ChatView's pickerWanted). */
  readonly pickerRows: () => number;
  /** Resolves when every request the composer started has settled. */
  readonly idle: () => Promise<void>;
  /** For the palette: what the composer can offer right now. */
  readonly context: () => {
    readonly newDraft: boolean;
    readonly workspaceMode: NewThreadWorkspaceMode | null;
    readonly threadId: string | null;
    readonly interactionMode: ProviderInteractionMode;
    readonly attachmentCount: number;
    readonly referenceCount: number;
  };
}

const OFFLINE_REASON = "not connected to the environment";

export function createComposer(options: ComposerOptions): Composer {
  const { client, store, state } = options;
  const palette = options.palette ?? THEME;
  const decode = options.decodeImage;

  const drafts = new Map<string, Draft>();
  const interactionOverrides = new Map<string, ProviderInteractionMode>();
  const modelOverrides = new Map<string, ModelSelection>();
  /** The model last sent with, per provider instance, newest last (this session). */
  const lastUsedModels = new Map<string, ModelSelection>();
  const rememberModel = (selection: ModelSelection | null | undefined) => {
    if (!selection) return;
    lastUsedModels.delete(selection.instanceId);
    lastUsedModels.set(selection.instanceId, selection);
  };
  let modelOptions: ReadonlyArray<ModelOption> = [];
  let settings: ServerSettings = DEFAULT_SERVER_SETTINGS;
  // Every configured provider (signed out and disabled ones too), for the composer's notice.
  let providers: ReadonlyArray<ServerProvider> = [];
  /** The accounts the MC's usage hubs report, as its config last said. */
  let usageSources: UsageLimitSourceSnapshots = [];
  /** "/usage-limits" was asked in this thread: the driver whose limits show above the prompt. */
  let limitsShown: { readonly key: string; readonly driver: ServerProvider["driver"] } | null =
    null;
  let stopLimits: (() => void) | null = null;
  const closeLimits = () => {
    stopLimits?.();
    stopLimits = null;
    limitsShown = null;
  };
  /** The provider behind the model the next turn runs on. */
  const activeProvider = () =>
    providers.find((candidate) => candidate.instanceId === activeModel()?.instanceId);
  /** The limits of one driver's accounts (this machine's and its hubs'), a row each. */
  const limitRows = (driver: ServerProvider["driver"]): string[] => {
    const now = options.nowMs?.() ?? Date.now();
    const shown = new Map([
      [
        "local" as never,
        {
          entry: { target: { label: "This machine" } },
          serverConfig: { providers, usageLimitSources: usageSources },
        },
      ],
    ]);
    const label = providers.find((provider) => provider.driver === driver)?.displayName ?? driver;
    const pool = collectLimitPools(collectLimitAccounts(shown as never), now).find(
      (candidate) => candidate.driver === driver,
    );
    const rows = [...collectLimitNotices(shown as never)];
    if (!pool) return [...rows, `${label}: no limits reported.`];
    for (const window of pool.windows) {
      const resets = window.members
        .map((member) => formatResetsIn(member.window, now))
        .find(Boolean);
      rows.push(
        [`${label} ${window.label}: ${window.remainingPercent}% left`, resets]
          .filter(Boolean)
          .join(" · "),
      );
    }
    return rows;
  };
  let newDraft: NewDraft | null = null;
  let picker: Picker | null = null;
  /** The chrome rows by source, so a one-line prompt or a popover can drop some (ChatView). */
  let chromeParts = {
    question: 0,
    attachments: 0,
    compact: 0,
    context: 0,
    notice: 0,
    references: 0,
  };
  /** Set by Ctrl+Up / Ctrl+Down; null follows the text. */
  let rowsOverride: number | null = null;
  let replyPending = false;
  /** Why the last send to a thread was refused, by draft key, until it is sent again. */
  const sendFailures = new Map<string, string>();
  let createPending = false;
  let switchPending = false;
  let draftCount = 0;
  let switchToken = 0;
  let imageLoads = 0;
  let clipboardSequence = 0;
  const inflight = new Set<Promise<unknown>>();

  const track = <T>(promise: Promise<T>): Promise<T> => {
    inflight.add(promise);
    void promise.finally(() => inflight.delete(promise)).catch(() => {});
    return promise;
  };

  // ── Derived context ──────────────────────────────────────────────────────

  const projects = () => store.getState().shell?.projects ?? [];
  const selectedDetail = (): OrchestrationThread | null => {
    const current = store.getState();
    const selection = current.selection;
    if (selection?.kind !== "thread") return null;
    return current.detail && current.detail.id === selection.id ? current.detail : null;
  };
  const target = (): string | null => {
    if (newDraft) return NEW_TARGET;
    const selection = store.getState().selection;
    return selection?.kind === "thread" ? threadTarget(selection.id) : null;
  };
  const draftFor = (key: string | null): Draft =>
    key ? (drafts.get(key) ?? EMPTY_DRAFT) : EMPTY_DRAFT;
  const setDraft = (key: string | null, update: (draft: Draft) => Draft) => {
    if (!key) return;
    const had = drafts.has(key);
    const next = update(draftFor(key));
    if (next.text.length === 0 && next.images.length === 0 && !next.contexts?.length) {
      drafts.delete(key);
    } else drafts.set(key, next);
    publish();
    // The new-thread draft's sidebar row follows whether it holds anything.
    if (key === NEW_TARGET && had !== drafts.has(key)) options.onDraftChange?.();
  };
  // Prompt recall: ↑ in an empty prompt walks back through the thread's sent
  // prompts, ↓ walks forward and past the newest clears the prompt. Recall
  // only continues while the prompt still holds the recalled text.
  let recall: { readonly key: string; readonly index: number; readonly text: string } | null = null;
  const recallPrompt = (direction: "previous" | "next"): boolean => {
    const key = target();
    const detail = selectedDetail();
    if (!key || newDraft || !detail) return false;
    const current = draftFor(key).text;
    const recalling = recall !== null && recall.key === key && recall.text === current;
    if (!recalling && (direction === "next" || current.length > 0)) return false;
    const sent = detail.messages
      .filter((message) => message.role === "user" && message.text.trim().length > 0)
      .map((message) => message.text);
    const index = (recalling ? recall!.index : sent.length) + (direction === "previous" ? -1 : 1);
    if (index < 0) return recalling;
    const text = sent[index] ?? "";
    recall = index < sent.length ? { key, index, text } : null;
    setDraft(key, (draft) => ({ ...draft, text }));
    return true;
  };
  const threadInteraction = (detail: OrchestrationThread) =>
    interactionOverrides.get(detail.id) ?? detail.interactionMode;
  const threadModel = (detail: OrchestrationThread): ModelSelection | null =>
    modelOverrides.get(detail.id) ??
    resolveModelSelection(modelOptions, detail.modelSelection) ??
    detail.modelSelection ??
    null;
  const newModel = (): ModelSelection | null =>
    newDraft
      ? (resolveModelSelection(modelOptions, newDraft.modelSelection) ?? newDraft.modelSelection)
      : null;
  const activeModel = () => {
    if (newDraft) return newModel();
    const detail = selectedDetail();
    return detail ? threadModel(detail) : null;
  };
  const newProject = () =>
    newDraft?.projectId
      ? (projects().find((project) => project.id === newDraft!.projectId) ?? null)
      : null;
  const composerCwd = () => {
    if (newDraft) {
      return (
        (newDraft.workspaceMode === "current" ? newDraft.worktreePath : null) ??
        newProject()?.workspaceRoot ??
        process.cwd()
      );
    }
    const detail = selectedDetail();
    if (!detail) return process.cwd();
    return (
      detail.worktreePath ??
      projects().find((project) => project.id === detail.projectId)?.workspaceRoot ??
      process.cwd()
    );
  };

  // ── Publishing ───────────────────────────────────────────────────────────

  const autoRows = (text: string) => {
    const surface = composerSurfaceWidth(options.chatWidth());
    return Math.min(
      COMPOSER_MAX_EDITOR_ROWS,
      Math.max(COMPOSER_MIN_EDITOR_ROWS, countWrappedComposerLines(text, Math.max(1, surface - 4))),
    );
  };

  const composerState = (): TuiComposerState => {
    const key = target();
    const draft = draftFor(key);
    const detail = newDraft ? null : selectedDetail();
    const working = !!detail && isWorking(detail);
    const pendingUserInputCount = detail ? derivePendingUserInputs(detail.activities).length : 0;
    const pendingApprovalCount = detail ? derivePendingApprovals(detail.activities).length : 0;
    const model = activeModel();
    const effort = reasoningChoicesForSelection(modelOptions, model)?.selectedId ?? null;
    const interactionMode: ProviderInteractionMode = newDraft
      ? newDraft.interactionMode
      : detail
        ? threadInteraction(detail)
        : "default";
    const runtimeMode: RuntimeMode = newDraft
      ? newDraft.runtimeMode
      : (detail?.runtimeMode ?? "full-access");
    const project = newProject();
    const placeholder = newDraft
      ? project
        ? `What should we build in ${project.title}?`
        : "What should we build?"
      : detail
        ? "Ask anything, @tag files/folders, $use skills, or / for commands"
        : store.getState().selection?.kind === "project"
          ? "Enter to expand · Alt+↑/↓ to pick a thread"
          : "Select a thread with Alt+↑/↓ or click";
    const surfaceWidth = composerSurfaceWidth(options.chatWidth());
    const compact = surfaceWidth < COMPACT_SURFACE_WIDTH;
    const question = newDraft ? null : (options.question?.() ?? null);
    const answering = question !== null;
    const mode = options.mode();
    // The OpenTUI client also drops the editor while a send is pending, which
    // loses what the user types meanwhile; only a checkout switch does here.
    const inputFocused =
      (mode === "compose" || mode === "newThread" || mode === "userInput") && !switchPending;
    const attachments = draft.images.map((image): TuiComposerAttachment => ({
      id: image.relativePath,
      name: image.upload.name,
      label: clip(image.upload.name, ATTACHMENT_CHIP_WIDTH - 2),
      image: options.inlineImages ? { source: image.preview.source } : null,
    }));
    const visibleCount = Math.max(
      1,
      Math.min(4, Math.floor(surfaceWidth / (ATTACHMENT_CHIP_WIDTH + 1))),
    );
    const hiddenCount = Math.max(0, attachments.length - visibleCount);
    const hasText = draft.text.length > 0 || draft.images.length > 0;
    const context = composerContext(detail);
    const references = referencesIn(draft).map((path) => ({
      path,
      label: clip(`@${path}`, 28),
    }));
    const contexts = (draft.contexts ?? []).map((record) => ({
      id: record.contextId as string,
      kind: record.kind as string,
      label: clip(record.label, 32),
    }));
    // Why the message is still in the prompt outranks the provider's standing notice.
    const refused = key === null ? undefined : sendFailures.get(key);
    // Being offline stops explaining itself once the connection is back.
    const failure = refused === OFFLINE_REASON && !options.offline?.() ? undefined : refused;
    const notice = failure !== undefined ? `Not sent: ${failure}` : providerNotice(model);
    // Wrapped to the box by word, so the way to fix it is never cut off.
    const noticeLines: string[] = [];
    if (notice) {
      const room = Math.max(8, surfaceWidth - 6);
      let line = "";
      for (const word of notice.split(" ")) {
        if (line !== "" && Bun.stringWidth(`${line} ${word}`) > room) {
          noticeLines.push(line);
          line = word;
        } else line = line === "" ? word : `${line} ${word}`;
      }
      noticeLines.push(line);
    }
    const limitLines =
      limitsShown !== null && limitsShown.key === key ? limitRows(limitsShown.driver) : [];
    chromeParts = {
      question: question ? question.visibleOptions + 4 : 0,
      attachments: attachments.length === 0 ? 0 : options.inlineImages ? 4 : 1,
      compact: compact ? 1 : 0,
      context: context ? 1 : 0,
      notice: noticeLines.length + limitLines.length,
      references: references.length + contexts.length > 0 ? 1 : 0,
    };
    const chromeRows =
      4 +
      chromeParts.question +
      chromeParts.attachments +
      chromeParts.compact +
      chromeParts.context +
      chromeParts.notice +
      chromeParts.references;
    const footerWidth = Math.max(1, surfaceWidth - 2);
    const showOptions = footerWidth >= 24;
    return {
      target: key,
      routeKind: newDraft ? "draft" : "server",
      text: draft.text,
      cursor: draft.text.length,
      attachments,
      placeholder,
      canSend:
        (newDraft !== null || detail !== null) &&
        !replyPending &&
        !createPending &&
        (draft.text.trim().length > 0 ||
          draft.images.length > 0 ||
          (draft.contexts?.length ?? 0) > 0),
      isRunning: working,
      isSendBusy: replyPending || createPending,
      pendingApprovalCount,
      pendingUserInputCount,
      // The legacy footer lets Stop win, which hides Submit answer behind a
      // running turn (a question always arrives mid-turn) and labels Esc as
      // stop while Esc defers the question; the open question wins here.
      primaryAction: answering ? "Submit answer" : working ? "Stop" : "Send",
      selectedInstanceId: model?.instanceId ?? null,
      selectedModel: model?.model ?? null,
      effort,
      options: modelOptionStates(modelOptions, model),
      interactionMode,
      interactionModeLabel: interactionModeLabel(interactionMode),
      runtimeMode,
      runtimeModeLabel: runtimeModeLabel(runtimeMode),
      runtimeModes: RUNTIME_MODES.map((mode) => ({
        value: mode,
        label: RUNTIME_MODE_META[mode].label,
        description: RUNTIME_MODE_META[mode].description,
      })),
      compact,
      rows: rowsOverride ?? autoRows(draft.text),
      surfaceWidth,
      inputFocused,
      answering,
      caption: answering
        ? styled(chunk("pick an option above, then Enter to submit", { fg: palette.dim }))
        : styled(
            chunk("^P prompt · ", { fg: palette.accent }),
            draft.text.length > 0
              ? chunk(draft.text, { fg: palette.text })
              : chunk(placeholder, { fg: palette.dim }),
          ),
      references,
      contexts,
      visibleAttachments: attachments.slice(0, visibleCount),
      moreAttachments: hiddenCount > 0 ? `+${hiddenCount} more` : "",
      footer: {
        model: footerChip("model", model?.model ?? "—", { muted: !model, dropdown: true }),
        effort: footerChip("effort", effort ?? "—", { muted: !effort, dropdown: true }),
        access: footerChip("^O", runtimeModeLabel(runtimeMode), { dropdown: true }),
        mode: footerChip("^B", interactionModeLabel(interactionMode), {
          active: interactionMode === "plan",
        }),
        compactModel: styled(
          chunk("model ", { fg: palette.dim }),
          chunk(clip(model?.model ?? "—", Math.max(1, footerWidth - (showOptions ? 18 : 8))), {
            fg: model ? palette.text : palette.dim,
          }),
          chunk(" ▾", { fg: palette.dim }),
        ),
        showOptions,
        primary: answering
          ? styled(
              chunk("▸ Submit answer", { fg: palette.accent }),
              chunk(" ⏎", { fg: palette.dim }),
            )
          : working
            ? styled(chunk("■ Stop", { fg: palette.error }), chunk(" Esc", { fg: palette.dim }))
            : styled(
                chunk("▸ Send", { fg: hasText ? palette.accent : palette.dim }),
                chunk(" ⏎", { fg: palette.dim }),
              ),
      },
      context,
      notice,
      noticeLines,
      limitLines,
      chromeRows,
    };
  };

  /** Why the selected model's provider cannot run a turn right now, and how to fix it. */
  const providerNotice = (model: ModelSelection | null): string | null => {
    const provider = model
      ? providers.find((candidate) => candidate.instanceId === model.instanceId)
      : undefined;
    if (!provider) return null;
    const name = provider.displayName ?? provider.driver ?? provider.instanceId;
    const then = "then ^K → Refresh providers";
    if (provider.enabled === false) {
      return `${name} is disabled: enable it in provider settings, ${then}.`;
    }
    if (provider.auth?.status === "unauthenticated") {
      return `${name} needs sign-in: ${provider.message ?? `sign in to ${name} on this machine`}, ${then}.`;
    }
    return null;
  };

  /** ComposerFooter's Chip: a dim (accent when active) key hint, then the label. */
  const footerChip = (
    keyHint: string,
    label: string,
    flags: { readonly active?: boolean; readonly muted?: boolean; readonly dropdown?: boolean },
  ): StyledText =>
    styled(
      chunk(`${keyHint} `, { fg: flags.active ? palette.accent : palette.dim }),
      chunk(`${label}${flags.dropdown ? " ▾" : ""}`, {
        fg: flags.active ? palette.accent : flags.muted ? palette.dim : palette.text,
      }),
    );

  /** ComposerDock's context: the draft's workspace and base, or the thread's checkout. */
  const composerContext = (detail: OrchestrationThread | null): TuiComposerContext | null => {
    const room = Math.max(1, Math.floor((composerSurfaceWidth(options.chatWidth()) - 1) / 2));
    const row = (workspace: string, branch: string, pickable: boolean): TuiComposerContext => ({
      workspace: clip(`${workspace}${pickable ? " ▾" : ""}`, room),
      branch: clip(`branch ${branch}${pickable ? " ▾" : ""}`, room),
      pickable,
    });
    if (newDraft) {
      return row(workspaceLabelFor(newDraft), newDraft.branch ?? "(current)", true);
    }
    const vcsStatus = store.getState().vcsStatus;
    if (!detail || !vcsStatus?.isRepo) return null;
    return row(
      detail.worktreePath ? "Worktree checkout" : "Local checkout",
      vcsStatus.refName ?? detail.branch ?? "(detached)",
      false,
    );
  };

  const workspaceLabelFor = (current: NewDraft) =>
    current.workspaceMode === "new-worktree"
      ? "New worktree"
      : current.worktreePath
        ? "Current worktree"
        : "Project workspace";

  const newThreadState = (): TuiNewThreadState | null => {
    if (!newDraft) return null;
    const current = newDraft;
    return {
      draftId: current.draftId,
      projectKey: current.projectId ? projectKey(current.projectId) : null,
      projectName: newProject()?.title ?? current.projectId,
      workspaceMode: current.workspaceMode,
      workspaceLabel: workspaceLabelFor(current),
      branch: current.branch,
      worktreePath: current.worktreePath,
      refsStatus: current.refsStatus,
      refs: current.refs.map((ref) => ({
        name: ref.name,
        current: ref.current,
        worktreePath: ref.worktreePath,
        selected: ref.name === current.branch,
      })),
      pending: switchPending || createPending,
    };
  };

  /** SelectOverlay's window: as many two-row options as the popover holds, around the highlighted one. */
  const selectRows = (current: Picker): TuiSelectState["rows"] => {
    if (current.status !== "ready") return [];
    const viewport = options.popover?.() ?? { width: 80, maxRows: 10 };
    const labelRoom = Math.max(8, viewport.width - 6);
    const window = Math.max(1, Math.floor(viewport.maxRows / 2));
    const start = Math.min(
      Math.max(0, current.index - Math.floor(window / 2)),
      Math.max(0, current.options.length - window),
    );
    return current.options.slice(start, start + window).map((option, offset) => {
      const index = start + offset;
      const active = index === current.index;
      const description =
        option.description && option.description !== option.label ? option.description : null;
      return {
        index,
        active,
        name: styled(
          chunk(active ? "▸ " : "  ", { fg: active ? palette.accent : palette.dim }),
          chunk(clip(option.label, labelRoom), { fg: active ? palette.text : palette.dim }),
        ),
        description: description
          ? styled(
              chunk(`    ${clip(description, labelRoom)}`, {
                fg: active ? palette.bg : palette.dim,
              }),
            )
          : null,
      };
    });
  };

  const selectState = (): TuiSelectState =>
    picker
      ? {
          open: true,
          kind: picker.kind,
          title: picker.title,
          status: picker.status,
          options: picker.options.map(({ label, description }) => ({ label, description })),
          index: picker.index,
          searchable: picker.menu?.searchable === true,
          query: picker.query ?? "",
          rows: selectRows(picker),
        }
      : {
          open: false,
          kind: null,
          title: "",
          status: "empty",
          options: [],
          index: 0,
          searchable: false,
          query: "",
          rows: [],
        };
  const pickerRows = () =>
    picker ? Math.max(picker.options.length, 1) * 2 + 3 + (picker.menu?.searchable ? 1 : 0) : 0;
  /** Narrow a searchable menu to the options whose label or description holds the query. */
  const searchMenu = (query: string) => {
    const spec = picker?.menu;
    if (!picker || !spec?.searchable) return;
    const needle = query.trim().toLowerCase();
    const matches = spec.options
      .filter(
        (option) =>
          needle === "" ||
          option.label.toLowerCase().includes(needle) ||
          (option.description ?? "").toLowerCase().includes(needle),
      )
      .map((option) => ({
        label: option.label,
        description: option.description ?? "",
        value: option.value,
      }));
    picker = {
      ...picker,
      query,
      options: matches,
      index: 0,
      status: matches.length > 0 ? "ready" : "empty",
    };
    publish();
  };

  let lastComposer = "";
  let lastNewThread = "";
  let lastRows = 0;
  let lastChrome = 0;
  let lastSelect = "";
  let lastPickerRows = 0;
  const publish = () => {
    const composer = composerState();
    // Previews compare by size: stringifying their bytes on every keystroke is costly.
    const composerJson = JSON.stringify(composer, (_key, value: unknown) =>
      value instanceof Uint8Array ? value.byteLength : value,
    );
    if (composerJson !== lastComposer) {
      lastComposer = composerJson;
      state.set("composer", composer);
    }
    if (composer.rows !== lastRows || composer.chromeRows !== lastChrome) {
      lastRows = composer.rows;
      lastChrome = composer.chromeRows;
      options.onRowsChange?.(composer.rows);
    }
    const newThread = newThreadState();
    const newThreadJson = JSON.stringify(newThread);
    if (newThreadJson !== lastNewThread) {
      lastNewThread = newThreadJson;
      state.set("newThread", newThread);
    }
    const select = selectState();
    const selectJson = JSON.stringify(select);
    if (selectJson !== lastSelect) {
      lastSelect = selectJson;
      state.set("select", select);
    }
    // A picker's options arrived or changed: the layout gives it its rows.
    if (pickerRows() !== lastPickerRows) {
      lastPickerRows = pickerRows();
      options.onRowsChange?.(composer.rows);
    }
  };

  // ── Pickers ──────────────────────────────────────────────────────────────

  const openPicker = (next: Picker) => {
    picker = next;
    options.setMode(next.menu?.mode ?? "select");
    publish();
  };
  const closePicker = () => {
    if (!picker) return;
    const menu = picker.menu;
    picker = null;
    if (options.mode() === (menu?.mode ?? "select")) options.setMode(menu?.returnMode ?? "compose");
    publish();
  };
  const openMenu = (spec: TuiMenuSpec) =>
    openPicker({
      menu: spec,
      kind: "menu",
      title: spec.title,
      status: spec.status ?? (spec.options.length > 0 ? "ready" : "empty"),
      options: spec.options.map((option) => ({
        label: option.label,
        description: option.description ?? "",
        value: option.value,
      })),
      index: Math.min(Math.max(0, spec.index ?? 0), Math.max(0, spec.options.length - 1)),
    });
  /** Opening the picker that is already open closes it (clicking a control twice). */
  const toggles = (kind: TuiSelectKind) => {
    if (picker?.kind !== kind) return false;
    closePicker();
    return true;
  };
  const updatePicker = (kind: TuiSelectKind, update: (current: Picker) => Picker) => {
    if (picker?.kind !== kind) return;
    picker = update(picker);
    publish();
  };

  const loadModels = () =>
    track(
      client.listModels().then((models) => {
        modelOptions = models;
        publish();
        return models;
      }),
    );

  const openModelPicker = () => {
    if (toggles("model")) return;
    if (!newDraft && !selectedDetail()) return;
    const selection = activeModel();
    openPicker({
      kind: "model",
      title: "model",
      status: "loading",
      options: [],
      index: 0,
    });
    // Reload on every open: the server's provider list may have changed.
    void loadModels().then(
      (models) =>
        updatePicker("model", (current) => ({
          ...current,
          status: models.length > 0 ? "ready" : "empty",
          options: models.map((model) => ({
            label: model.label,
            description: model.providerLabel,
            value: JSON.stringify({ instanceId: model.instanceId, model: model.model }),
          })),
          index: currentModelIndex(models, selection),
        })),
      () => updatePicker("model", (current) => ({ ...current, status: "error" })),
    );
  };

  const openReasoningPicker = () => {
    const selection = activeModel();
    if ((!newDraft && !selectedDetail()) || !selection) {
      store.setStatus("Select a model first.", "info");
      return;
    }
    if (toggles("reasoning")) return;
    openPicker({
      kind: "reasoning",
      title: "effort",
      status: "loading",
      options: [],
      index: 0,
    });
    void loadModels().then(
      (models) => {
        const resolved = resolveModelSelection(models, selection) ?? selection;
        const result = reasoningChoicesForSelection(models, resolved);
        updatePicker("reasoning", (current) =>
          !result || result.choices.length === 0
            ? { ...current, status: "empty" }
            : {
                ...current,
                status: "ready",
                options: result.choices.map((choice) => ({
                  label: choice.label,
                  description: choice.description ?? result.descriptorId,
                  value: JSON.stringify({ descriptorId: result.descriptorId, choiceId: choice.id }),
                })),
                index: Math.max(
                  0,
                  result.choices.findIndex((choice) => choice.id === result.selectedId),
                ),
              },
        );
      },
      () => updatePicker("reasoning", (current) => ({ ...current, status: "error" })),
    );
  };

  const openRuntimePicker = () => {
    const detail = selectedDetail();
    if (!newDraft && !detail) return;
    if (toggles("runtime")) return;
    const runtimeMode = newDraft ? newDraft.runtimeMode : (detail?.runtimeMode ?? "full-access");
    openPicker({
      kind: "runtime",
      title: "access",
      status: "ready",
      options: RUNTIME_MODES.map((mode) => ({
        label: RUNTIME_MODE_META[mode].label,
        description: RUNTIME_MODE_META[mode].description,
        value: mode,
      })),
      index: Math.max(0, RUNTIME_MODES.indexOf(runtimeMode)),
    });
  };

  const openWorkspacePicker = () => {
    if (!newDraft) return;
    if (toggles("workspace")) return;
    openPicker({
      kind: "workspace",
      title: "workspace",
      status: "ready",
      options: [
        {
          label: newDraft.worktreePath ? "Current worktree" : "Current checkout",
          description: newDraft.worktreePath
            ? "Reuse the selected existing worktree."
            : "Run in the project's current checkout.",
          value: "current",
        },
        {
          label: "New worktree",
          description: `Create an isolated worktree from ${newDraft.branch ?? "the selected base"}.`,
          value: "new-worktree",
        },
      ],
      index: newDraft.workspaceMode === "current" ? 0 : 1,
    });
  };

  const branchOptions = (refs: ReadonlyArray<VcsRef>): SelectOption[] =>
    refs.map((ref) => {
      const badges = [
        ref.current ? "current" : null,
        ref.isDefault ? "default" : null,
        ref.worktreePath ? "worktree" : null,
        ref.isRemote ? "remote" : null,
      ].filter((badge): badge is string => badge !== null);
      return {
        label: ref.name,
        description: badges.length > 0 ? badges.join(" · ") : "local branch",
        value: ref.name,
      };
    });

  const openBranchPicker = () => {
    if (!newDraft) return;
    if (toggles("branch")) return;
    const refs = newDraft.refs;
    openPicker({
      kind: "branch",
      title: newDraft.workspaceMode === "new-worktree" ? "base branch" : "branch",
      status: refs.length > 0 ? "ready" : "empty",
      options: branchOptions(refs),
      index: Math.max(
        0,
        refs.findIndex((ref) => ref.name === newDraft!.branch),
      ),
    });
  };

  /** The thread list's project row: every project, or all of them. */
  const openProjectScopePicker = () => {
    if (toggles("project-scope")) return;
    const current = store.getState();
    const options: SelectOption[] = [
      {
        label: "All projects",
        description: "Show threads from every project.",
        value: ALL_PROJECTS,
      },
      ...(current.shell?.projects ?? []).map((project) => ({
        label: project.title,
        description: project.workspaceRoot,
        value: project.id as string,
      })),
    ];
    openPicker({
      kind: "project-scope",
      title: "project",
      status: "ready",
      options,
      index: Math.max(
        0,
        current.projectScopeId === null
          ? 0
          : options.findIndex((option) => option.value === current.projectScopeId),
      ),
    });
  };

  const setProjectScope = (value: string) => {
    const projectScopeId = value === ALL_PROJECTS ? null : value;
    store.setProjectScope(projectScopeId);
    const title =
      store.getState().shell?.projects.find((project) => project.id === projectScopeId)?.title ??
      projectScopeId;
    store.setStatus(
      projectScopeId === null ? "Showing all projects." : `Project → ${title}`,
      "success",
    );
  };

  // ── Controls ─────────────────────────────────────────────────────────────

  const setModel = (instanceId: string, model: string) => {
    const option = modelOptions.find(
      (candidate) => candidate.instanceId === instanceId && candidate.model === model,
    );
    if (!option) return;
    const selection = modelSelectionForOption(option);
    if (newDraft) newDraft = { ...newDraft, modelSelection: selection };
    else {
      const detail = selectedDetail();
      if (!detail) return;
      // Some providers keep the model a conversation started with (the web's
      // getStartedThreadModelChangeBlockReason): say so instead of failing the turn.
      const current = threadModel(detail);
      const started = detail.messages.length > 0 || detail.latestTurn !== null;
      const changes =
        current !== null && (current.instanceId !== instanceId || current.model !== model);
      const locked = (candidate: ModelSelection | null) =>
        candidate !== null &&
        modelOptions.some(
          (entry) =>
            entry.instanceId === candidate.instanceId &&
            entry.requiresNewThreadForModelChange === true,
        );
      if (started && changes && (locked(current) || locked(selection))) {
        store.setStatus(
          `Start a new thread (^N) to use ${option.label}: ${option.providerLabel} cannot change models once a conversation has started.`,
          "error",
        );
        return;
      }
      modelOverrides.set(detail.id, selection);
    }
    store.setStatus(`Model → ${option.model} (next turn)`, "success");
    publish();
  };

  const setOption = (id: string, value: string | boolean) => {
    const selection = activeModel();
    if (!selection) {
      store.setStatus("Select a model first.", "info");
      return;
    }
    const next = withModelSelectionOption(selection, id, value);
    if (newDraft) newDraft = { ...newDraft, modelSelection: next };
    else {
      const detail = selectedDetail();
      if (!detail) return;
      modelOverrides.set(detail.id, next);
    }
    const label =
      modelOptionStates(modelOptions, selection).find((option) => option.id === id)?.label ??
      "Effort";
    const reasoning = reasoningChoicesForSelection(modelOptions, selection)?.descriptorId === id;
    store.setStatus(
      `${reasoning ? "Effort" : label} → ${typeof value === "boolean" ? (value ? "on" : "off") : value} (next turn)`,
      "success",
    );
    publish();
  };

  /**
   * Every option of the selected model in one list: a switch flips when
   * chosen, a choice opens its values. The compact footer has no room for the
   * controls themselves, so its effort chord opens this instead.
   */
  const openOptionsPicker = () => {
    const selection = activeModel();
    if ((!newDraft && !selectedDetail()) || !selection) {
      store.setStatus("Select a model first.", "info");
      return;
    }
    const traits = modelOptionStates(modelOptions, selection);
    if (traits.length === 0) {
      store.setStatus("This model has no options.", "info");
      return;
    }
    const shown = (trait: ModelOptionState) =>
      trait.type === "boolean"
        ? trait.value === true
          ? "on"
          : "off"
        : (trait.choices.find((choice) => choice.id === trait.value)?.label ?? "—");
    openMenu({
      title: "options",
      options: traits.map((trait) => ({
        label: `${trait.label}: ${shown(trait)}`,
        description: trait.type === "boolean" ? "Enter switches it." : "Enter picks a value.",
        value: trait.id,
      })),
      onChoose: (id) => {
        const trait = traits.find((candidate) => candidate.id === id);
        if (!trait) return;
        if (trait.type === "boolean") {
          setOption(trait.id, trait.value !== true);
          return;
        }
        openMenu({
          title: trait.label.toLowerCase(),
          options: trait.choices.map((choice) => ({ label: choice.label, value: choice.id })),
          index: Math.max(
            0,
            trait.choices.findIndex((choice) => choice.id === trait.value),
          ),
          onChoose: (choice) => setOption(trait.id, choice),
        });
      },
    });
  };

  const setRuntimeMode = (mode: RuntimeMode) => {
    if (!RUNTIME_MODES.includes(mode)) return;
    if (newDraft) {
      newDraft = { ...newDraft, runtimeMode: mode };
      store.setStatus(`Access → ${runtimeModeLabel(mode)}`, "success");
      publish();
      return;
    }
    const detail = selectedDetail();
    if (!detail) return;
    void track(
      client
        .setRuntimeMode(detail.id, mode)
        .catch((error) => store.setStatus(`access change failed: ${String(error)}`, "error")),
    );
    store.setStatus(`Access → ${runtimeModeLabel(mode)}`, "success");
  };

  const setInteractionMode = (next: ProviderInteractionMode) => {
    if (newDraft) {
      newDraft = { ...newDraft, interactionMode: next };
      store.setStatus(next === "plan" ? "Plan mode." : "Build mode.", "success");
      publish();
      return;
    }
    const detail = selectedDetail();
    if (!detail) return;
    const threadId = detail.id;
    interactionOverrides.set(threadId, next);
    store.setStatus(next === "plan" ? "Plan mode." : "Build mode.", "success");
    publish();
    void track(
      client.setInteractionMode(threadId, next).catch((error) => {
        if (interactionOverrides.get(threadId) === next) interactionOverrides.delete(threadId);
        store.setStatus(`mode change failed: ${String(error)}`, "error");
        publish();
      }),
    );
  };

  const toggleInteractionMode = () => {
    const current = newDraft
      ? newDraft.interactionMode
      : (() => {
          const detail = selectedDetail();
          return detail ? threadInteraction(detail) : null;
        })();
    if (current === null) return;
    setInteractionMode(current === "plan" ? "default" : "plan");
  };

  const setWorkspaceMode = (mode: NewThreadWorkspaceMode) => {
    if (!newDraft || switchPending) return;
    let branch = newDraft.branch;
    // Back on "current", the thread's own worktree (if any) is the workspace again.
    const worktreePath = mode === "new-worktree" ? null : newDraft.contextWorktreePath;
    if (mode === "current") {
      const project = newProject();
      const currentRef = worktreePath
        ? newDraft.refs.find((ref) => ref.worktreePath === worktreePath)
        : newDraft.refs.find(
            (ref) => ref.current || (!!project && ref.worktreePath === project.workspaceRoot),
          );
      if (currentRef) branch = currentRef.name;
    }
    newDraft = { ...newDraft, workspaceMode: mode, branch, worktreePath, workspaceChosen: true };
    store.setStatus(
      mode === "new-worktree" ? "Workspace → New worktree" : "Workspace → Current checkout",
      "success",
    );
    publish();
  };

  const selectBranch = (name: string) => {
    const draft = newDraft;
    const project = newProject();
    if (!draft || !project || switchPending) return;
    const ref = draft.refs.find((candidate) => candidate.name === name);
    if (!ref) return;
    const selection = resolveNewThreadBranchSelection({
      workspaceMode: draft.workspaceMode,
      projectCwd: project.workspaceRoot,
      currentWorktreePath: draft.worktreePath,
      ref,
    });
    if (selection.kind === "select-base") {
      newDraft = { ...draft, branch: selection.branch };
      store.setStatus(`Worktree base → ${selection.branch}`, "success");
      publish();
      return;
    }
    if (selection.kind === "reuse-worktree") {
      newDraft = { ...draft, branch: selection.branch, worktreePath: selection.worktreePath };
      store.setStatus(`Workspace → ${selection.branch}`, "success");
      publish();
      return;
    }
    switchPending = true;
    const token = ++switchToken;
    store.setStatus(`Switching checkout to ${ref.name}…`, "busy");
    publish();
    void track(
      client
        .switchRef(selection.checkoutCwd, ref.name)
        .then(
          (result) => {
            if (switchToken !== token || !newDraft) return;
            const branch = result.refName ?? selection.branch;
            newDraft = { ...newDraft, branch, worktreePath: selection.worktreePath };
            store.setStatus(`Branch → ${branch}`, "success");
          },
          (error) => {
            if (switchToken !== token) return;
            store.setStatus(`branch switch failed: ${String(error)}`, "error");
          },
        )
        .finally(() => {
          if (switchToken !== token) return;
          switchPending = false;
          publish();
        }),
    );
  };

  // ── New-thread drafts ────────────────────────────────────────────────────

  const loadRefs = (draftId: string, cwd: string) =>
    track(
      client.listRefs(cwd).then(
        (result) => {
          if (newDraft?.draftId !== draftId) return;
          newDraft = {
            ...newDraft,
            refs: result.refs,
            refsStatus: result.refs.length > 0 ? "ready" : "empty",
            branch: resolveInitialBranch(result.refs, newDraft.branch),
          };
          publish();
        },
        () => {
          if (newDraft?.draftId !== draftId) return;
          newDraft = { ...newDraft, refsStatus: "error" };
          publish();
        },
      ),
    );

  /**
   * A draft starts in the payload's project, else the selected project or
   * thread's, else the thread list's scope, inheriting the selected thread's
   * workspace (port of ChatView's `openNewThread`).
   */
  const openNewThread = (payload: unknown) => {
    if (newDraft) return;
    const current = store.getState();
    const selection = current.selection;
    const detail = selection?.kind === "thread" ? selectedDetail() : null;
    const thread =
      detail ??
      (selection?.kind === "thread"
        ? (current.shell?.threads.find((candidate) => candidate.id === selection.id) ?? null)
        : null);
    const key = field(payload, "projectKey");
    const selectedProjectId =
      typeof key === "string"
        ? idFromKey(key)
        : selection?.kind === "project"
          ? selection.id
          : (thread?.projectId ?? current.projectScopeId);
    const list = projects();
    const target = list.find((candidate) => candidate.id === selectedProjectId);
    // Null means inherit: the project's own default, then the server's, then
    // the checkout's hal-c2.json (read below), then local.
    const savedMode =
      envMode(target?.defaultThreadEnvMode) ?? envMode(settings.defaultThreadEnvMode);
    const contextFor = (defaultEnvironmentMode: "local" | "worktree") =>
      resolveNewThreadContext({
        projects: list,
        selectedProjectId,
        thread,
        defaultEnvironmentMode,
      });
    const context = contextFor(savedMode ?? "local");
    const project = list[context.projectIndex] ?? null;
    // As in the web client: the project's default (its own, else the environment's),
    // then what the open thread's composer shows, then the model last sent with.
    const defaults = resolveProjectSettings(
      settings,
      (project?.id ?? null) as never,
      project,
    ).settings;
    const carried = thread ? (modelOverrides.get(thread.id) ?? thread.modelSelection) : null;
    const modelSelection =
      defaults.defaultModelSelection ?? carried ?? [...lastUsedModels.values()].at(-1) ?? null;
    draftCount += 1;
    newDraft = {
      draftId: `draft-${draftCount}`,
      originKey: selectionKey(selection),
      projectId: project?.id ?? null,
      modelSelection: resolveModelSelection(modelOptions, modelSelection) ?? modelSelection,
      runtimeMode: defaults.defaultRuntimeMode,
      interactionMode: "default",
      workspaceMode: context.workspaceMode,
      branch: context.branch,
      worktreePath: context.worktreePath,
      contextWorktreePath: context.worktreePath,
      refs: [],
      refsStatus: project ? "loading" : "empty",
    };
    drafts.delete(NEW_TARGET);
    closePicker();
    options.setMode("newThread");
    publish();
    options.onDraftChange?.();
    if (project) void loadRefs(newDraft.draftId, project.workspaceRoot);
    if (project && savedMode === null) {
      const draftId = newDraft.draftId;
      void track(
        readProjectFile(client.readFile, project.workspaceRoot).then((file) => {
          const mode = envMode(file?.defaultThreadEnvMode);
          if (mode === null || newDraft?.draftId !== draftId || newDraft.workspaceChosen) return;
          const next = contextFor(mode);
          newDraft = {
            ...newDraft,
            workspaceMode: next.workspaceMode,
            branch: newDraft.branch ?? next.branch,
            worktreePath: next.worktreePath,
            contextWorktreePath: next.worktreePath,
          };
          publish();
        }),
      );
    }
  };

  const closeNewThread = () => {
    if (!newDraft) return;
    newDraft = null;
    switchToken += 1;
    switchPending = false;
    drafts.delete(NEW_TARGET);
    if (picker && ["workspace", "branch"].includes(picker.kind)) closePicker();
    if (options.mode() === "newThread") options.setMode("compose");
    publish();
    options.onDraftChange?.();
  };

  const submitNewThread = () => {
    const draft = newDraft;
    if (!draft || createPending) return;
    if (switchPending) {
      store.setStatus("Wait for the branch switch to finish.", "info");
      return;
    }
    const project = newProject();
    const { text, images } = draftFor(NEW_TARGET);
    const typed = text.trim();
    const message = typed.length > 0 ? typed : images.length > 0 ? IMAGE_ONLY_PROMPT : "";
    const modelSelection = newModel();
    const invalid = validateNewThread({
      hasProject: !!project,
      message,
      hasModelSelection: !!modelSelection,
      workspaceMode: draft.workspaceMode,
      branch: draft.branch,
    });
    if (invalid) {
      store.setStatus(newThreadValidationMessage(invalid), "error");
      return;
    }
    if (!project || !modelSelection) return;
    createPending = true;
    store.setStatus("Creating thread and starting its first turn…", "busy");
    publish();
    const createWorktree = draft.workspaceMode === "new-worktree";
    void track(
      client
        .createThread({
          projectId: project.id,
          projectCwd: project.workspaceRoot,
          title: typed.length > 0 ? truncate(typed) : "Image attachment",
          modelSelection,
          firstMessage: message,
          attachments: images.map((image) => image.upload),
          runtimeMode: draft.runtimeMode,
          interactionMode: draft.interactionMode,
          branch: draft.branch,
          worktreePath: createWorktree ? null : draft.worktreePath,
          createWorktree,
          startFromOrigin: createWorktree && settings.newWorktreesStartFromOrigin,
        })
        .then(
          (threadId) => {
            createPending = false;
            rememberModel(modelSelection);
            closeNewThread();
            const scope = store.getState().projectScopeId;
            if (scope !== null && scope !== project.id) store.setProjectScope(project.id);
            store.select({ kind: "thread", id: threadId });
            store.setStatus("Thread created.", "success");
            publish();
          },
          (error) => {
            createPending = false;
            store.setStatus(`create failed: ${String(error)}`, "error");
            publish();
          },
        ),
    );
  };

  // ── Replies ──────────────────────────────────────────────────────────────

  const sendReply = () => {
    if (replyPending) return;
    const detail = selectedDetail();
    const key = target();
    const draft = draftFor(key);
    const typed = draft.text.trim();
    const contexts = draft.contexts ?? [];
    if (typed.length === 0 && draft.images.length === 0 && contexts.length === 0) return;
    if (!detail || !key) {
      store.setStatus("Select a thread (Alt+↑/↓ or click) to send a message.");
      return;
    }
    // The draft stays as typed: it is sent when the user asks again, once connected.
    if (options.offline?.()) {
      sendFailures.set(key, OFFLINE_REASON);
      store.setStatus("Not sent: not connected.", "error");
      publish();
      return;
    }
    // Each context record is named in the text by its reference link, after what was typed;
    // the record itself (the terminal output, the diff lines and the note) rides on the message.
    const references = contexts.map((record) => formatComposerContextReference(record)).join(" ");
    const body = [typed, references].filter((part) => part.length > 0).join("\n\n");
    const text = body.length > 0 ? body : IMAGE_ONLY_PROMPT;
    // "/usage-limits" is answered here, from what the MC knows: no turn runs for it.
    const provider = activeProvider();
    if (
      contexts.length === 0 &&
      draft.images.length === 0 &&
      isUsageLimitsCommand(typed) &&
      provider &&
      hasProviderUsageLimits(provider.driver, providers, usageSources)
    ) {
      closeLimits();
      limitsShown = { key, driver: provider.driver };
      setDraft(key, (current) => ({ ...current, text: "" }));
      store.setStatus(`${provider.displayName ?? provider.driver} limits.`, "info");
      // Followed while they show, so a window that moves is not left stale.
      stopLimits = client.subscribeUsageLimits((snapshot) => {
        providers = snapshot.providers;
        usageSources = snapshot.sources;
        publish();
      });
      publish();
      return;
    }
    closeLimits();
    const submitted = draft;
    sendFailures.delete(key);
    replyPending = true;
    store.setStatus("Sending reply…", "busy");
    publish();
    void track(
      Promise.resolve()
        .then(() =>
          client.sendReply(
            { ...detail, interactionMode: threadInteraction(detail) },
            text,
            submitted.images.map((image) => image.upload),
            threadModel(detail) ?? undefined,
            ...(contexts.length > 0 ? [{ version: 1 as const, records: [...contexts] }] : []),
          ),
        )
        .then(
          () => {
            replyPending = false;
            rememberModel(threadModel(detail));
            // Clear only what was sent; text typed while sending stays.
            setDraft(key, (current) => ({
              text: current.text.startsWith(submitted.text)
                ? current.text.slice(submitted.text.length).replace(/^\s+/, "")
                : current.text,
              images: current.images.filter((image) => !submitted.images.includes(image)),
            }));
            store.setStatus("Reply sent.", "success");
            publish();
          },
          (error) => {
            replyPending = false;
            const reason = error instanceof Error ? error.message : String(error);
            // The status line has room for a few words; the composer says it in full.
            sendFailures.set(key, reason);
            store.setStatus(`send failed: ${reason}`, "error");
            publish();
          },
        ),
    );
  };

  const interrupt = () => {
    const detail = selectedDetail();
    if (!detail) return;
    void track(client.interrupt(detail.id).catch(() => {}));
    if (detail.latestTurn) options.onInterrupt?.(detail.latestTurn.turnId);
    store.setStatus("Interrupt sent.", "success");
  };

  const escape = () => {
    if (newDraft) {
      if (createPending) return;
      if (switchPending) {
        store.setStatus("Wait for the branch switch to finish.", "info");
        return;
      }
      const draft = draftFor(NEW_TARGET);
      // Esc clears the task first; an empty draft closes.
      if (draft.text.length > 0 || draft.images.length > 0) setDraft(NEW_TARGET, () => EMPTY_DRAFT);
      else closeNewThread();
      return;
    }
    const key = target();
    const draft = draftFor(key);
    if (draft.text.length > 0 || draft.images.length > 0) {
      setDraft(key, () => EMPTY_DRAFT);
      return;
    }
    const detail = selectedDetail();
    if (detail && isWorking(detail)) interrupt();
  };

  // ── Attachments ──────────────────────────────────────────────────────────

  const canAttach = (key: string | null): key is string => {
    if (!key) {
      store.setStatus("Select a thread before attaching an image.", "error");
      return false;
    }
    const detail = selectedDetail();
    if (!newDraft && detail && derivePendingUserInputs(detail.activities).length > 0) {
      store.setStatus("Answer the pending question before attaching an image.", "error");
      return false;
    }
    if (draftFor(key).images.length + imageLoads >= PROVIDER_SEND_TURN_MAX_ATTACHMENTS) {
      store.setStatus(
        `You can attach up to ${PROVIDER_SEND_TURN_MAX_ATTACHMENTS} images.`,
        "error",
      );
      return false;
    }
    return true;
  };

  const addImage = (key: string, image: ComposerImageAttachment) =>
    setDraft(key, (current) =>
      current.images.length >= PROVIDER_SEND_TURN_MAX_ATTACHMENTS ||
      current.images.some((entry) => entry.relativePath === image.relativePath)
        ? current
        : { ...current, images: [...current.images, image] },
    );

  const loadImage = async (key: string, imagePath: string): Promise<boolean> => {
    if (draftFor(key).images.some((image) => image.relativePath === imagePath)) {
      store.setStatus(`${NodePath.basename(imagePath)} is already attached.`, "info");
      return true;
    }
    if (!canAttach(key)) return false;
    imageLoads += 1;
    store.setStatus(`Adding ${NodePath.basename(imagePath)}…`, "busy");
    try {
      const platformPath = client.hostPlatform === "win32" ? NodePath.win32 : NodePath.posix;
      let image: ComposerImageAttachment;
      if (platformPath.isAbsolute(imagePath)) {
        const bytes = await options.readLocalImage(imagePath);
        const mimeType = imageMimeTypeForPath(imagePath);
        if (!mimeType) throw new Error("Select a supported image file.");
        image = await prepareComposerImageBytes(imagePath, mimeType, bytes, decode);
      } else {
        const file = await client.readFileBase64(composerCwd(), imagePath);
        if (!file) throw new Error("Could not read the pasted image path.");
        image = await prepareComposerImage(imagePath, file, decode);
      }
      addImage(key, image);
      store.setStatus(`Attached ${image.upload.name}.`, "success");
      return true;
    } catch (error) {
      store.setStatus(errorText(error), "error");
      return false;
    } finally {
      imageLoads = Math.max(0, imageLoads - 1);
    }
  };

  const attachPath = (rawPath: string) => {
    const key = target();
    if (!key) {
      store.setStatus("Select a thread before attaching an image.", "error");
      return;
    }
    void track(loadImage(key, rawPath));
  };

  const pasteBytes = (bytes: Uint8Array, mimeType: string) => {
    const key = target();
    if (!canAttach(key)) return;
    const extension = imageExtensionForMimeType(mimeType);
    if (!extension) {
      store.setStatus("Paste a supported image format.", "error");
      return;
    }
    clipboardSequence += 1;
    const name = `clipboard-image-${clipboardSequence}.${extension}`;
    imageLoads += 1;
    store.setStatus("Adding pasted image…", "busy");
    void track(
      prepareComposerImageBytes(name, mimeType, bytes, decode)
        .then(
          (image) => {
            addImage(key, image);
            store.setStatus(`Attached ${image.upload.name}.`, "success");
          },
          // A decoder failure means the bytes are not an image we can show.
          () => store.setStatus("Paste a supported image format.", "error"),
        )
        .finally(() => {
          imageLoads = Math.max(0, imageLoads - 1);
        }),
    );
  };

  /** A paste that names an image: attach it, then put the rest of the text in the prompt. */
  const pastePath = (text: string): boolean => {
    const key = target();
    if (!key) return false;
    const pasted = extractPastedImagePath(
      text,
      composerCwd(),
      options.homeDir,
      client.hostPlatform,
    );
    if (!pasted) return false;
    void track(
      loadImage(key, pasted.imagePath).then((attached) => {
        const insert = attached ? pasted.remainingText : text;
        if (insert.length > 0) setDraft(key, (draft) => ({ ...draft, text: draft.text + insert }));
      }),
    );
    return true;
  };

  const removeAttachment = (id: unknown) => {
    const key = target();
    setDraft(key, (draft) => {
      const images =
        typeof id === "string"
          ? draft.images.filter((image) => image.relativePath !== id)
          : draft.images.slice(0, -1);
      return { ...draft, images };
    });
  };

  // ── Context by trigger character ─────────────────────────────────────────

  const referencesIn = (draft: Draft) =>
    (draft.references ?? []).filter((path) => draft.text.includes(`@${path}`));

  /** The trigger just typed: "/" opening the prompt, "$" or "@" opening a word. */
  const typedTrigger = (before: string, text: string): "/" | "$" | "@" | null => {
    if (text.length !== before.length + 1 || !text.startsWith(before)) return null;
    const typed = text.at(-1);
    if (typed === "/") return before === "" ? "/" : null;
    if (typed !== "$" && typed !== "@") return null;
    return before === "" || /\s$/.test(before) ? typed : null;
  };

  /** Put `token` where the trigger character was typed (the end of the prompt). */
  const completeTrigger = (trigger: string, token: string, reference?: string) => {
    setDraft(target(), (draft) => ({
      ...draft,
      text: `${draft.text.endsWith(trigger) ? draft.text.slice(0, -1) : draft.text}${token} `,
      ...(reference ? { references: [...new Set([...(draft.references ?? []), reference])] } : {}),
    }));
    options.onTextCompleted?.(draftFor(target()).text);
  };

  /**
   * "/" lists the provider's commands, "$" its skills and "@" the workspace's
   * files, each in a searchable picker. Esc leaves the character as typed.
   */
  const openTriggerPicker = (trigger: "/" | "$" | "@") => {
    const model = activeModel();
    const provider = providers.find((candidate) => candidate.instanceId === model?.instanceId);
    if (trigger === "@") {
      const key = target();
      void track(
        client.listEntries(composerCwd()).then(
          (entries) => {
            // Nothing to offer, or the user typed on (or left) meanwhile: the "@" stays text.
            const listed = entries.filter((entry) => entry.ignored !== true);
            if (listed.length === 0 || target() !== key || !draftFor(key).text.endsWith("@")) {
              return;
            }
            if (picker !== null) return;
            openMenu({
              title: "files",
              searchable: true,
              options: entries
                .filter((entry) => entry.ignored !== true)
                .map((entry) => ({
                  label: entry.kind === "directory" ? `${entry.path}/` : entry.path,
                  value: entry.path,
                })),
              onChoose: (path) => completeTrigger("@", `@${path}`, path),
            });
          },
          () => {},
        ),
      );
      return;
    }
    // A provider with no commands (or skills) opens nothing: the character is just text.
    if (trigger === "/") {
      // A provider whose limits the MC knows also answers "/usage-limits" (here, not in a turn).
      const commands =
        withUsageLimitsCommands(provider ? [provider] : [], usageSources)[0]?.slashCommands ?? [];
      if (commands.length === 0) return;
      openMenu({
        title: "commands",
        searchable: true,
        options: commands.map((command) => ({
          label: `/${command.name}`,
          description: command.description ?? "",
          value: command.name,
        })),
        onChoose: (name) => completeTrigger("/", `/${name}`),
      });
      return;
    }
    if (!(provider?.skills ?? []).some((skill) => skill.enabled)) return;
    openMenu({
      title: "skills",
      searchable: true,
      options: (provider?.skills ?? [])
        .filter((skill) => skill.enabled)
        .map((skill) => ({
          label: `$${skill.name}`,
          description: skill.shortDescription ?? skill.description ?? "",
          value: skill.name,
        })),
      onChoose: (name) => completeTrigger("$", `$${name}`),
    });
  };

  /** Drop a reference chip and its `@path` from the text (the last one without a path). */
  const removeReference = (path: unknown) => {
    setDraft(target(), (draft) => {
      const shown = referencesIn(draft);
      const gone = typeof path === "string" ? path : shown.at(-1);
      if (gone === undefined) return draft;
      return {
        ...draft,
        references: (draft.references ?? []).filter((candidate) => candidate !== gone),
        text: draft.text.replace(`@${gone} `, "").replace(`@${gone}`, ""),
      };
    });
  };

  // ── $EDITOR ──────────────────────────────────────────────────────────────

  const editInEditor = () => {
    const key = target();
    if (!key) return;
    const original = draftFor(key).text;
    void track(
      (async () => {
        let dir: string | null = null;
        try {
          dir = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "hal-c2-prompt-"));
          const file = NodePath.join(dir, "prompt.md");
          await NodeFSP.writeFile(file, original, "utf8");
          await options.runEditor(resolveEditorCommand(options.env), file);
          const edited = normalizeEditedPrompt(await NodeFSP.readFile(file, "utf8"));
          const slots = Math.max(
            0,
            PROVIDER_SEND_TURN_MAX_ATTACHMENTS - draftFor(key).images.length,
          );
          const lines = findPromptImagePathLines(
            edited,
            composerCwd(),
            options.homeDir,
            client.hostPlatform,
          ).slice(0, slots);
          const replaced = new Map<number, string>();
          for (const line of lines) {
            const pasted = extractPastedImagePath(
              line.text,
              composerCwd(),
              options.homeDir,
              client.hostPlatform,
            );
            if (pasted && (await loadImage(key, pasted.imagePath))) {
              replaced.set(line.lineIndex, pasted.remainingText);
            }
          }
          const prompt = normalizeEditedPrompt(
            replacePromptLines(edited, replaced)
              .split("\n")
              .filter((line, index) => !(replaced.has(index) && line.trim().length === 0))
              .join("\n"),
          );
          setDraft(key, (draft) => ({ ...draft, text: prompt }));
          store.setStatus(
            replaced.size > 0
              ? `Prompt updated; attached ${replaced.size} image path${replaced.size === 1 ? "" : "s"}.`
              : "Prompt updated from $EDITOR.",
            "success",
          );
        } catch {
          store.setStatus("Could not open $EDITOR.", "error");
        } finally {
          if (dir) await NodeFSP.rm(dir, { recursive: true, force: true }).catch(() => {});
        }
      })(),
    );
  };

  // ── Select overlay ───────────────────────────────────────────────────────

  const choose = (index: number) => {
    const current = picker;
    if (!current) return;
    const value = current.options[index]?.value;
    if (value === undefined) return;
    if (current.kind === "branch") {
      closePicker();
      selectBranch(value);
      return;
    }
    closePicker();
    switch (current.kind) {
      case "menu":
        current.menu?.onChoose(value);
        return;
      case "model": {
        const parsed = JSON.parse(value) as { instanceId: string; model: string };
        setModel(parsed.instanceId, parsed.model);
        return;
      }
      case "reasoning": {
        const parsed = JSON.parse(value) as { descriptorId: string; choiceId: string };
        setOption(parsed.descriptorId, parsed.choiceId);
        return;
      }
      case "runtime":
        setRuntimeMode(value as RuntimeMode);
        return;
      case "workspace":
        setWorkspaceMode(value as NewThreadWorkspaceMode);
        return;
      case "project-scope":
        setProjectScope(value);
        return;
    }
  };

  const move = (delta: number) => {
    if (!picker || picker.options.length === 0) return;
    const count = picker.options.length;
    picker = { ...picker, index: (picker.index + delta + count) % count };
    publish();
  };

  // ── Store sync ───────────────────────────────────────────────────────────

  const sync = () => {
    const current = store.getState();
    const key = selectionKey(current.selection);
    if (newDraft && newDraft.originKey !== key) closeNewThread();
    // A draft's project was removed: the draft goes with it.
    if (
      newDraft?.projectId &&
      current.shell &&
      !current.shell.projects.some((project) => project.id === newDraft!.projectId)
    ) {
      closeNewThread();
    }
    const detail = selectedDetail();
    if (detail && interactionOverrides.get(detail.id) === detail.interactionMode) {
      interactionOverrides.delete(detail.id);
    }
    publish();
  };

  const dispatch = (action: string, payload?: unknown): boolean => {
    switch (action) {
      case "composer.text.set": {
        const text = field(payload, "text");
        if (typeof text !== "string") return true;
        const before = draftFor(target()).text;
        setDraft(target(), (draft) => ({ ...draft, text }));
        const trigger = typedTrigger(before, text);
        if (trigger) openTriggerPicker(trigger);
        return true;
      }
      case "composer.reference.remove":
        removeReference(field(payload, "path"));
        return true;
      case "composer.context.remove": {
        const id = field(payload, "id");
        setDraft(target(), (draft) => ({
          ...draft,
          contexts:
            typeof id === "string"
              ? (draft.contexts ?? []).filter((record) => record.contextId !== id)
              : (draft.contexts ?? []).slice(0, -1),
        }));
        return true;
      }
      case "composer.history.previous":
        return recallPrompt("previous");
      case "composer.history.next":
        return recallPrompt("next");
      case "composer.submit":
        if (newDraft) submitNewThread();
        else sendReply();
        return true;
      case "composer.escape":
        escape();
        return true;
      case "composer.interrupt":
        interrupt();
        return true;
      case "composer.paste": {
        const bytes = field(payload, "bytes");
        const mimeType = field(payload, "mimeType");
        if (
          bytes instanceof Uint8Array &&
          typeof mimeType === "string" &&
          mimeType.startsWith("image/")
        ) {
          pasteBytes(bytes, mimeType);
          return true;
        }
        const text = field(payload, "text");
        return typeof text === "string" && pastePath(text);
      }
      case "composer.attach": {
        const path = field(payload, "path");
        if (typeof path === "string") attachPath(path);
        return true;
      }
      case "composer.attachment.remove":
        removeAttachment(field(payload, "id"));
        return true;
      case "composer.grow":
      case "composer.shrink":
        rowsOverride = Math.min(
          COMPOSER_MAX_EDITOR_ROWS,
          Math.max(
            1,
            (rowsOverride ?? autoRows(draftFor(target()).text)) +
              (action === "composer.grow" ? 1 : -1),
          ),
        );
        publish();
        return true;
      case "composer.editor.open":
        editInEditor();
        return true;
      case "composer.interactionMode.toggle":
        toggleInteractionMode();
        return true;
      case "composer.interactionMode.set": {
        const mode = field(payload, "mode");
        if (mode === "plan" || mode === "default") setInteractionMode(mode);
        return true;
      }
      case "composer.runtimeMode.set":
        setRuntimeMode(field(payload, "mode") as RuntimeMode);
        return true;
      case "composer.model.select": {
        const instanceId = field(payload, "instanceId");
        const model = field(payload, "model");
        if (typeof instanceId === "string" && typeof model === "string") {
          const known = modelOptions.some(
            (option) => option.instanceId === instanceId && option.model === model,
          );
          if (known) setModel(instanceId, model);
          else
            void loadModels().then(
              () => setModel(instanceId, model),
              () => {},
            );
        }
        return true;
      }
      case "composer.option.set": {
        const id = field(payload, "id");
        const value = field(payload, "value");
        if (typeof id === "string" && (typeof value === "string" || typeof value === "boolean")) {
          setOption(id, value);
        }
        return true;
      }
      case "composer.modelPicker.toggle":
        openModelPicker();
        return true;
      case "composer.effortPicker.toggle":
        // The compact footer shows no option controls: one menu holds them all.
        if (composerSurfaceWidth(options.chatWidth()) < COMPACT_SURFACE_WIDTH) openOptionsPicker();
        else openReasoningPicker();
        return true;
      case "composer.optionsPicker.toggle":
        openOptionsPicker();
        return true;
      case "composer.providers.reload":
        void loadModels().catch(() => {});
        void track(
          client.getServerConfig().then(
            (config) => {
              settings = config.settings;
              providers = config.providers ?? [];
              usageSources = config.usageLimitSources ?? [];
              publish();
            },
            () => {},
          ),
        );
        return true;
      case "composer.runtimePicker.toggle":
        openRuntimePicker();
        return true;
      case "composer.workspacePicker.toggle":
        openWorkspacePicker();
        return true;
      case "composer.branchPicker.toggle":
        openBranchPicker();
        return true;
      case "sidebar.scopePicker.toggle":
        openProjectScopePicker();
        return true;
      case "newThread.workspaceMode": {
        const mode = field(payload, "mode");
        if (mode === "current" || mode === "new-worktree") setWorkspaceMode(mode);
        return true;
      }
      case "newThread.branch": {
        const name = field(payload, "name");
        if (typeof name === "string") selectBranch(name);
        return true;
      }
      case "thread.new":
        openNewThread(payload);
        return true;
      case "newThread.submit": {
        // The first message may come with the action (a form field) or from the prompt.
        const message = field(payload, "message");
        if (newDraft && typeof message === "string") {
          setDraft(NEW_TARGET, (draft) => ({ ...draft, text: message }));
        }
        submitNewThread();
        return true;
      }
      case "newThread.cancel":
        closeNewThread();
        return true;
      case "select.next":
        move(1);
        return true;
      case "select.previous":
        move(-1);
        return true;
      case "select.confirm":
        choose(picker?.index ?? 0);
        return true;
      case "select.choose": {
        const index = field(payload, "index");
        if (typeof index === "number") choose(index);
        return true;
      }

      case "select.close":
        closePicker();
        return true;
      case "select.query.set": {
        const query = field(payload, "query");
        if (typeof query === "string") searchMenu(query);
        return true;
      }
      default:
        return false;
    }
  };

  // Startup: models for the footer, settings for new-thread defaults.
  void loadModels().catch(() => {});
  void track(
    client.getServerConfig().then(
      (config) => {
        settings = config.settings;
        providers = config.providers ?? [];
        usageSources = config.usageLimitSources ?? [];
        publish();
      },
      () => {},
    ),
  );

  return {
    dispatch,
    openMenu,
    addContext: (record) => {
      if (newDraft || !selectedDetail()) return false;
      setDraft(target(), (draft) => ({
        ...draft,
        contexts: [...(draft.contexts ?? []), record],
      }));
      return true;
    },
    closeMenu: (title) => {
      if (picker?.kind === "menu" && (title === undefined || picker.title === title)) closePicker();
    },
    draft: () =>
      newDraft
        ? {
            draftId: newDraft.draftId,
            projectId: newDraft.projectId,
            hasContent: drafts.has(NEW_TARGET),
          }
        : null,
    sync,
    relayout: publish,
    chromeRows: (overlay) =>
      4 +
      (overlay.oneLine || overlay.popover ? 0 : chromeParts.question) +
      (overlay.oneLine ? 0 : chromeParts.attachments) +
      (overlay.oneLine ? 0 : chromeParts.compact) +
      (overlay.oneLine ? 0 : chromeParts.notice) +
      (overlay.oneLine ? 0 : chromeParts.references) +
      chromeParts.context,
    pickerRows,
    idle: async () => {
      while (inflight.size > 0) await Promise.allSettled([...inflight]);
    },
    context: () => {
      const detail = selectedDetail();
      return {
        newDraft: newDraft !== null,
        workspaceMode: newDraft?.workspaceMode ?? null,
        threadId: detail?.id ?? null,
        interactionMode: newDraft
          ? newDraft.interactionMode
          : detail
            ? threadInteraction(detail)
            : "default",
        attachmentCount: draftFor(target()).images.length,
        referenceCount: referencesIn(draftFor(target())).length,
      };
    },
  };
}
