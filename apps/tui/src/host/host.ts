import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";

import { PROVIDER_SEND_TURN_MAX_IMAGE_BYTES } from "@hal-c2/contracts";
import { createComputed, createPropertyMap, createRoot, type PropertyMap } from "opentui-qml";

import type { TuiClient, TuiConnectionPhase } from "../connection.ts";
import { resolveSidebarListViewport } from "../components/ChatView.layout.ts";
import {
  buildRows,
  nextSidebarRefreshAt,
  SIDEBAR_SETTLED_SECTION_ID,
} from "../components/Sidebar.logic.ts";
import { KEYBINDING_GROUPS, KEYMAP_LAYERS, KEYMAP_PARITY } from "../keymap.ts";
import type { EditorCommand } from "../promptEditor.ts";
import { latestActionableProposedPlan } from "../proposedPlan.ts";
import { createStore, type StatusKind, type StoreState } from "../store.ts";
import { revertableCheckpoints } from "../timeline.ts";
import { createAddProjectController } from "./addProjectState.ts";
import { createClusterController, NO_CLUSTER_STATE } from "./clusterState.ts";
import { createComposer, type ImageDecoder } from "./composerState.ts";
import { detailCommands } from "./detailCommands.ts";
import type { MutedThreadsStore } from "./mutedThreads.ts";
import { createFilesController } from "./filesState.ts";
import {
  buildTuiLayoutState,
  composerSurfaceWidth,
  type TuiLayoutState,
  type TuiMode,
  type TuiSize,
} from "./layoutState.ts";
import { createPalette, type PaletteCommand } from "./paletteState.ts";
import type { PluginPort, TuiPluginsState } from "./plugins.ts";
import { registerSettingsSections } from "./sections/index.ts";
import {
  createSettingsSections,
  NO_SETTINGS_SECTION,
  type SettingsSections,
} from "./settingsSections.ts";
import { buildTuiSettingsState } from "./settingsState.ts";
import { buildTuiSidebarState, idFromKey, projectKey, threadKey } from "./sidebarState.ts";
import { createSourceControl, SOURCE_CONTROL_PANEL } from "./sourceControl.ts";
import { buildStatusRow } from "./statusState.ts";
import {
  createTerminalController,
  type TerminalScrollAction,
  type TerminalThread,
} from "./terminalState.ts";
import { createThreadActions } from "./threadActions.ts";
import { createTuiTheme, TUI_THEME_STATE, type TuiTheme } from "./theme.ts";
import { createThreadView } from "./threadView.ts";
import type { CellPixels } from "./timelineState.ts";
import type { InlineImageTransport } from "../terminalGraphics.ts";

/** Published under `status`: the one-line status message and its tone. */
export interface TuiStatusState {
  readonly kind: StatusKind;
  readonly text: string;
}

/** Published under `page`: what the main area shows. */
export type TuiPageState =
  | { readonly kind: "none" }
  | {
      /** A new-thread draft: the conversation pane is empty and the composer holds the draft. */
      readonly kind: "draft";
      readonly draftId: string;
      /** Null while there is no project to start the thread in. */
      readonly projectKey: string | null;
      readonly projectTitle: string | null;
    }
  | {
      readonly kind: "thread";
      readonly key: string;
      readonly threadId: string;
      readonly title: string;
      readonly projectTitle: string | null;
    };

/** Published under `connection`: how the client reaches its environment. */
export interface TuiConnectionState {
  readonly state: TuiConnectionPhase;
  /** The environments this client knows; the TUI has one, the local server it was launched for. */
  readonly environments: ReadonlyArray<{
    readonly id: string;
    readonly label: string;
    readonly kind: "local";
    readonly connected: boolean;
  }>;
  /** How to reach another environment; null while the TUI only knows its launcher's server. */
  readonly pairingHint: string | null;
}

/**
 * Published under `problems`: what the QML runtime reported (plugin load,
 * setup and render failures, bad keymap entries, config warnings), newest last.
 */
export interface TuiProblem {
  readonly level: "error" | "warning";
  readonly message: string;
  /** The runtime's context: `plugin "clock" (render, slot "statusbar")`, `plugin directory "…"`. */
  readonly where: string | null;
}

export interface TuiShellSingleton {
  readonly state: PropertyMap;
  /** True when the host handled the action (a paste the prompt must not insert). */
  readonly dispatch: (action: string, payload?: unknown) => boolean;
}

export interface HostOptions {
  readonly client: TuiClient;
  readonly size: TuiSize;
  /** `app.quit`: the entry tears the renderer down. */
  readonly onQuit?: () => void;
  /** Diagnostics (unknown actions); the entry writes them to the TUI log. */
  readonly log: (message: string) => void;
  /** Clock for snooze partitioning; tests pin it. */
  readonly now?: () => string;
  /** Put text on the system clipboard; false when the terminal cannot (OSC 52). */
  readonly copyToClipboard?: (text: string) => boolean;
  /** `VISUAL` / `EDITOR` for Ctrl+G (default: the process environment). */
  readonly env?: { readonly VISUAL?: string | undefined; readonly EDITOR?: string | undefined };
  /** Expands `~` in pasted image paths (default: the user's home). */
  readonly homeDir?: string;
  /** Ctrl+G: run the editor on a file; the entry suspends the renderer around it. */
  readonly runEditor?: (command: EditorCommand, file: string) => Promise<void>;
  /** Read an image pasted as an absolute path on this machine. */
  readonly readLocalImage?: (path: string) => Promise<Uint8Array>;
  /** Decode attached images for their preview (default: `@hal-c2/opentui-image`). */
  readonly decodeImage?: ImageDecoder;
  /**
   * How inline images reach the terminal ("direct", or "tmux" passthrough);
   * null or absent: the terminal draws none and attachments stay text lines.
   */
  readonly inlineImages?: InlineImageTransport | null;
  /** Pixel size of a terminal cell, when the terminal reported it (sizes images). */
  readonly cellPixels?: () => CellPixels | null;
  /** Where this device keeps the threads whose alerts it muted (default: this run only). */
  readonly mutedThreads?: MutedThreadsStore;
  /** Sees every action dispatched, from QML, keymaps or the palette (tests, debugging). */
  readonly trace?: (action: string, payload: unknown) => void;
}

/**
 * Published under `graphics`: the host's inline-image decision. Bricks draw
 * attachment previews with the Kitty protocol only when `inlineImages` is set;
 * "tmux" means the drawing goes through tmux passthrough to the outer terminal.
 */
export interface TuiGraphicsState {
  readonly inlineImages: InlineImageTransport | null;
}

/** Published under `clock`: when the sidebar's next time boundary (a snooze wake) is due. */
export interface TuiClockState {
  /** Milliseconds until `clock.tick` should run; 0 when nothing is time-bound. */
  readonly refreshInMs: number;
}

async function readLocalImageFile(path: string): Promise<Uint8Array> {
  const stat = await NodeFSP.stat(path).catch(() => null);
  if (!stat?.isFile()) throw new Error("The pasted image path is not a file.");
  if (stat.size > PROVIDER_SEND_TURN_MAX_IMAGE_BYTES) {
    throw new Error("Image exceeds the 10MB attachment limit.");
  }
  return new Uint8Array(await NodeFSP.readFile(path));
}

export interface Host {
  readonly state: PropertyMap;
  readonly dispatch: (action: string, payload?: unknown) => boolean;
  /** Move keyboard focus (the input mode); overlays owned elsewhere call this. */
  readonly setMode: (mode: TuiMode) => void;
  /** Resolves when every request an action started has settled (tests wait on it). */
  readonly idle: () => Promise<void>;
  /** The terminal size changed (renderer "resize"). */
  readonly resize: (size: TuiSize) => void;
  /** QML singletons: `Shell.state.<key>`, `Shell.dispatch(action, payload)`, `Theme.*`. */
  readonly Shell: TuiShellSingleton;
  readonly Theme: TuiTheme;
  /** Settles once the server config (settlement support, new-thread defaults) has loaded or failed. */
  readonly ready: Promise<void>;
  /**
   * Resolves once client calls and terminal writes in flight (files, add
   * project, terminal) have landed and their state is published: the receipt
   * tests wait on.
   */
  readonly settled: () => Promise<void>;
  /** The QML engine is up: list its plugins and let `plugin.*` actions reach it. */
  readonly attachPlugins: (port: PluginPort) => void;
  /** A QML runtime error (`onError`): logged and published under `problems`. */
  readonly reportError: (error: unknown, where?: string) => void;
  /** A QML runtime or config warning (`onWarning`): logged and published under `problems`. */
  readonly reportWarning: (message: string) => void;
  readonly destroy: () => void;
}

/** Problems kept for the user; older ones drop off. */
const MAX_PROBLEMS = 50;

/**
 * Actions that return false when they do not apply right now (an empty
 * recall, a chord for a panel that is not open): not unknown, not logged.
 */
const DECLINABLE_ACTIONS = new Set([
  "composer.history.previous",
  "composer.history.next",
  "approval.approve",
  "approval.decline",
  "approval.approveSession",
  "approval.cancel",
  "approval.previous",
  "approval.next",
  "plan.implement",
  "userInput.reopen",
  "userInput.toggle",
]);

const payloadField = (payload: unknown, field: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[field]
    : undefined;

/**
 * The app side of the QML shell. The store owns data and server
 * subscriptions; the host adds the view state the bricks need (mode, size,
 * collapse) and republishes both as `Shell.state` keys. Bricks never own
 * state: they read keys and call `dispatch`.
 */
export function createHost(options: HostOptions): Host {
  const { client, log } = options;
  const now = options.now ?? (() => new Date().toISOString());
  const store = createStore(client, { now });

  let mode: TuiMode = "compose";
  let size = options.size;
  let sidebarCollapsed = false;
  // The detail panel's kind ("sourceControl", …) or null when closed, and
  // whether it has the keys (a focused source-control panel is "panel" mode).
  let rightPanel: string | null = null;
  let rightPanelFocused = false;
  let settingsOpen = false;
  // The file browser takes the conversation pane's place (FilesView).
  let filesOpen = false;
  // The prompt's editor rows (the composer's 3–8, or as set by Ctrl+Up / Ctrl+Down).
  let editorRows: number | undefined;
  let popoverRows = 0;
  let settlementSupported = false;
  let scrollTop = 0;
  // PgUp / PgDn on a pane that scrolls itself (settings, the diff): the brick
  // named by `pane` scrolls by `by` rows each time `seq` changes.
  let paneScroll = { pane: "", seq: 0, by: 0 };
  const scrollPane = (pane: string, by: number) => {
    paneScroll = { pane, seq: paneScroll.seq + 1, by };
    state.set("paneScroll", paneScroll);
    return true;
  };

  const state = createPropertyMap({
    mode,
    size,
    theme: TUI_THEME_STATE,
    notifications: { items: [] },
    keybindings: { layers: KEYMAP_LAYERS, groups: KEYBINDING_GROUPS, parity: KEYMAP_PARITY },
    paneScroll,
    plugins: { items: [] } satisfies TuiPluginsState,
    problems: { items: [] },
    connection: connectionState("connecting"),
    graphics: { inlineImages: options.inlineImages ?? null } satisfies TuiGraphicsState,
    cluster: NO_CLUSTER_STATE,
    settingsSection: NO_SETTINGS_SECTION,
  });

  let pluginPort: PluginPort | null = null;
  const refreshPlugins = () => {
    if (pluginPort) state.set("plugins", { items: pluginPort.list() } satisfies TuiPluginsState);
  };
  let problems: ReadonlyArray<TuiProblem> = [];
  const addProblem = (problem: TuiProblem) => {
    log(`[qml ${problem.level}${problem.where ? ` ${problem.where}` : ""}] ${problem.message}`);
    problems = [...problems, problem].slice(-MAX_PROBLEMS);
    state.set("problems", { items: problems });
    // A plugin that failed may have left the registry.
    refreshPlugins();
  };

  const rowsNow = (next = store.getState()) =>
    buildRows(
      next.shell,
      next.expanded,
      next.loadedInFull,
      next.selection?.kind === "thread" ? next.selection.id : null,
      next.filter,
      next.projectScopeId,
      now(),
    );

  // Republish a key only when what it is derived from changed, so bindings
  // on other keys are not re-evaluated by every store emit.
  let last: StoreState | null = null;
  const threadView = createThreadView({
    store,
    client,
    state,
    mode: () => mode,
    setMode: (next) => setMode(next),
    nowMs: () => Date.parse(now()),
    inlineImages: (options.inlineImages ?? null) !== null,
    ...(options.cellPixels ? { cellPixels: options.cellPixels } : {}),
    // The image preview fills the conversation pane (ImageLightbox).
    size: () => ({ columns: layout.chatWidth, rows: layout.panesRows }),
    composerWidth: () => composerSurfaceWidth(layout.chatWidth),
    paneReplacedChanged: () => publishLayout(),
    onQuestionChange: () => composer?.sync(),
    copyToClipboard: options.copyToClipboard,
    mutedThreads: options.mutedThreads,
  });
  let layout: TuiLayoutState;
  // The rows each popover above the prompt asks for, as ChatView sums them.
  const wantedPopoverRows = () =>
    (addProject.isOpen() ? Math.floor(size.rows * 0.55) : 0) +
    (composer?.pickerRows() ?? 0) +
    (palette.isOpen() ? Math.floor(size.rows * 0.5) : 0) +
    (mode === "revert"
      ? Math.min(revertableCheckpoints(store.getState().detail?.checkpoints ?? []).length, 8) + 3
      : 0) +
    (mode === "confirmDelete" ? 4 : 0);
  const publishLayout = () => {
    const previous = layout;
    const popoverOpen = wantedPopoverRows() > 0 || mode === "contextMenu";
    // ChatView's rename, commit and filter focus: the prompt is one line.
    const oneLineComposer =
      mode === "rename" || mode === "commit" || mode === "filter" || mode === "join";
    layout = buildTuiLayoutState({
      size,
      sidebarCollapsed,
      // Like ChatView, the panel hides (without closing) while settings, the
      // files, diff or image view has the conversation pane.
      rightPanel:
        filesOpen || settingsOpen || sections?.isOpen() || threadView.paneReplaced()
          ? null
          : rightPanel,
      rightPanelFocused,
      mode,
      // The drawer slot follows the selected thread's terminal.
      drawerOpen: terminal.visible(),
      drawerRows: terminal.preferredRows(),
      editorRows: oneLineComposer ? 1 : editorRows,
      popoverRows: popoverRows + wantedPopoverRows(),
      oneLineEditor: popoverOpen || oneLineComposer,
      composerChromeRows: composer?.chromeRows({ oneLine: oneLineComposer, popover: popoverOpen }),
    });
    state.set("layout", layout);
    // The list's rows are drawn to its width and windowed to its height.
    if (JSON.stringify(sidebarSize()) !== sidebarSized) publishSidebar();
    threadView.setPaneWidth(layout.chatWidth);
    if (previous?.chatWidth !== layout.chatWidth || previous?.panesRows !== layout.panesRows) {
      threadView.resize();
      files?.sync();
      sections?.relayout();
    }
    sourceControl.resize();
    // The footer's compact form follows the conversation width.
    composer?.relayout();
    // The palette and the add-project list window to the rows they were given.
    if (previous?.chatWidth !== layout.chatWidth || previous?.popoverRows !== layout.popoverRows) {
      palette.sync();
      addProject.relayout();
    }
    if (settingsOpen && previous?.chatWidth !== layout.chatWidth) publishSettings();
  };
  /** The popover's inner width and content rows (ChatView's mainWidth - 4 and pickerContentRows). */
  const popoverViewport = () => {
    // Before the first layout (while the host is built) nothing is open.
    const current = layout as TuiLayoutState | undefined;
    return {
      width: Math.max(1, (current?.chatWidth ?? size.columns) - 4),
      maxRows: Math.max(2, (current?.popoverRows ?? 0) - 3),
    };
  };
  const publishSettings = () => {
    const current = store.getState();
    state.set(
      "settings",
      buildTuiSettingsState({
        active: settingsOpen,
        detail: current.detail,
        vcsStatus: current.vcsStatus,
        cluster: cluster.state(),
        // Before the first layout the pane is the whole terminal.
        width: (layout as TuiLayoutState | undefined)?.chatWidth ?? size.columns,
      }),
    );
  };
  // The thread list's width and height: the list pane, or the whole terminal
  // when it opens over the conversation.
  const sidebarSize = () => ({
    width: layout?.sidebarAsMain ? size.columns : (layout?.listWidth ?? 0),
    rows: size.rows,
  });
  let sidebarSized = "";
  /** `follow`: scroll the selection back into view (not after the mouse wheel). */
  const publishSidebar = (follow = true) => {
    const next = store.getState();
    const box = sidebarSize();
    sidebarSized = JSON.stringify(box);
    const selectedThreadId = next.selection?.kind === "thread" ? next.selection.id : null;
    const at = now();
    const sidebar = buildTuiSidebarState({
      shell: next.shell,
      rows: rowsNow(next),
      selectedThreadId,
      selection: next.selection,
      projectScopeId: next.projectScopeId,
      filter: next.filter,
      now: at,
      settlementSupported,
      draft: sidebarDraft(),
      viewportRows: resolveSidebarListViewport(box.rows),
      scrollTop,
      followSelection: follow,
      ...(box.width > 0 ? { width: box.width } : {}),
    });
    scrollTop = sidebar.scrollTop;
    state.set("sidebar", sidebar);
    const due = nextSidebarRefreshAt(next.shell, Date.parse(at));
    state.set("clock", {
      refreshInMs: due === null ? 0 : Math.max(1, due - Date.parse(at)),
    } satisfies TuiClockState);
  };
  const publishPage = () => {
    const next = store.getState();
    const draft = composer?.draft() ?? null;
    state.set(
      "page",
      draft
        ? {
            kind: "draft",
            draftId: draft.draftId,
            projectKey: draft.projectId === null ? null : projectKey(draft.projectId),
            projectTitle:
              next.shell?.projects.find((project) => project.id === draft.projectId)?.title ?? null,
          }
        : pageFor(next, next.selection?.kind === "thread" ? next.selection.id : null),
    );
  };
  const publish = () => {
    const next = store.getState();
    const prev = last;
    last = next;
    if (
      !prev ||
      prev.shell !== next.shell ||
      prev.expanded !== next.expanded ||
      prev.loadedInFull !== next.loadedInFull ||
      prev.selection !== next.selection ||
      prev.filter !== next.filter ||
      prev.projectScopeId !== next.projectScopeId
    ) {
      publishSidebar();
    }
    if (!prev || prev.status !== next.status || prev.statusKind !== next.statusKind) {
      state.set("status", { kind: next.statusKind, text: next.status } satisfies TuiStatusState);
    }
    if (
      !prev ||
      prev.selection !== next.selection ||
      prev.detail !== next.detail ||
      prev.shell !== next.shell
    ) {
      publishPage();
    }
    threadView.sync(next, prev);
    sourceControl.publish(prev, next);
    if (!prev || prev.detail !== next.detail || prev.vcsStatus !== next.vcsStatus) {
      publishSettings();
    }
    if (!prev || prev.selection !== next.selection || prev.detail !== next.detail) {
      terminal.sync();
    }
    if (prev && prev.selection !== next.selection) files.close();
    if (prev && prev.shell !== next.shell) addProject.sync();
  };

  /**
   * "compose" means the prompt has the keys: the new-thread draft's when one
   * is open, else an open question when one waits.
   */
  const setMode = (requested: TuiMode) => {
    const next =
      requested === "compose"
        ? composer?.draft()
          ? "newThread"
          : threadView.composeMode()
        : requested;
    if (next === mode) return;
    mode = next;
    state.set("mode", mode);
    publishLayout();
  };
  // Where keys go when a menu, prompt or palette closes (setMode resolves it).
  const restingMode = (): TuiMode => "compose";
  /** The draft's sidebar row: only a draft with a project is listed. */
  const sidebarDraft = () => {
    const draft = composer?.draft();
    return draft?.projectId ? { draftId: draft.draftId, projectId: draft.projectId } : null;
  };

  /** The mode a focused detail panel of `kind` takes. */
  const panelMode = (kind: string | null): TuiMode | null =>
    kind === SOURCE_CONTROL_PANEL ? sourceControl.focusMode() : null;

  /** Open `kind` in the detail panel (null closes it); a focused panel takes the keys. */
  const setRightPanel = (kind: string | null, focused: boolean) => {
    const previous = rightPanel;
    rightPanel = kind;
    rightPanelFocused = kind !== null && focused;
    const wasSourceControl = previous === SOURCE_CONTROL_PANEL;
    const isSourceControl = rightPanel === SOURCE_CONTROL_PANEL;
    if (isSourceControl !== wasSourceControl) sourceControl.panelChanged(isSourceControl);
    publishLayout();
    const focusMode = rightPanelFocused ? panelMode(rightPanel) : null;
    if (focusMode) setMode(focusMode);
    else if (mode === "panel" || mode === "commit") setMode(restingMode());
  };
  const sourceControl = createSourceControl({
    store,
    state,
    setMode: (next) => setMode(next),
    panel: () => ({
      open: rightPanel === SOURCE_CONTROL_PANEL,
      focused: rightPanel === SOURCE_CONTROL_PANEL && rightPanelFocused,
    }),
    width: () => (layout ? layout.rightPanel.width : 0),
    focusPanel: () => setRightPanel(SOURCE_CONTROL_PANEL, true),
    copyToClipboard: options.copyToClipboard,
  });

  /** The selected thread's terminal and file workspace: its worktree, else the project root. */
  const selectedWorkspace = (): TerminalThread | null => {
    const current = store.getState();
    if (current.selection?.kind !== "thread") return null;
    const threadId = current.selection.id;
    const shellThread = current.shell?.threads.find((thread) => thread.id === threadId);
    const detail = current.detail?.id === threadId ? current.detail : null;
    const projectId = detail?.projectId ?? shellThread?.projectId;
    const worktreePath = detail?.worktreePath ?? shellThread?.worktreePath ?? null;
    const workspaceRoot =
      current.shell?.projects.find((project) => project.id === projectId)?.workspaceRoot ??
      process.cwd();
    return {
      threadId,
      title: detail?.title ?? shellThread?.title ?? "",
      cwd: worktreePath ?? workspaceRoot,
      worktreePath,
    };
  };
  // The terminal fills the `layout.drawer` slot; the layout sizes it.
  const terminal = createTerminalController({
    client,
    store,
    thread: selectedWorkspace,
    width: () => layout.mainWidth,
    rows: () => layout.drawer.rows,
    layoutChanged: () => publishLayout(),
    isFocused: () => mode === "terminal",
    setFocused: (focused) => {
      if (focused) setMode("terminal");
      else if (mode === "terminal") setMode(restingMode());
    },
    copyToClipboard: options.copyToClipboard ?? (() => false),
    publish: (next) => state.set("terminal", next),
  });
  // The file browser and viewer take the conversation pane's place.
  const files = createFilesController({
    client,
    cwd: () => selectedWorkspace()?.cwd ?? null,
    height: () => layout.panesRows,
    width: () => layout.chatWidth,
    setOpen: (open) => {
      filesOpen = open;
      publishLayout();
      if (open) setMode("files");
      else if (mode === "files") setMode(restingMode());
    },
    publish: (next) => state.set("files", next),
  });
  // Adding a project is a page over the conversation (mode "project").
  const addProject = createAddProjectController({
    client,
    store,
    currentProjectCwd: () => {
      const current = store.getState();
      const selection = current.selection;
      const projectId =
        selection?.kind === "project"
          ? selection.id
          : selection?.kind === "thread"
            ? current.shell?.threads.find((thread) => thread.id === selection.id)?.projectId
            : current.projectScopeId;
      return (
        current.shell?.projects.find((project) => project.id === projectId)?.workspaceRoot ?? null
      );
    },
    // Pending the settings key: new paths start in the home folder.
    baseDirectory: () => null,
    viewport: () => {
      const { width, maxRows } = popoverViewport();
      return { width, maxRows: Math.max(4, maxRows) };
    },
    setOpen: (open) => setMode(open ? "project" : restingMode()),
    // The new project opens on a new-thread draft.
    openDraft: (projectId) => dispatch("thread.new", { projectKey: projectKey(projectId) }),
    publish: (next) => state.set("addProject", next),
  });
  // The cluster: status in settings, invite / join / remove from the palette.
  const cluster = createClusterController({
    client,
    store,
    setMode: (next) => setMode(next),
    restingMode,
    copyToClipboard: options.copyToClipboard,
    publish: (next) => {
      state.set("cluster", next);
      if (settingsOpen) publishSettings();
      palette.sync();
    },
  });
  // The settings pages (scheduled tasks, diagnostics, …) take the conversation's place.
  let sections: SettingsSections | null = null;
  sections = createSettingsSections({
    client,
    store,
    mode: () => mode,
    setMode: (next) => setMode(next),
    restingMode,
    pane: () => ({ width: layout.chatWidth, rows: layout.panesRows }),
    copyToClipboard: options.copyToClipboard,
    now: () => Date.parse(now()),
    publish: (next) => state.set("settingsSection", next),
    openChanged: () => publishLayout(),
  });
  registerSettingsSections(sections);
  /** The files, add-project and terminal entries, as palette commands. */
  const areaCommands = (): PaletteCommand[] =>
    [...addProject.commands(), ...files.commands(), ...terminal.commands()].map((command) => ({
      id: command.action,
      title: command.title,
      action: command.action,
    }));

  let composer: ReturnType<typeof createComposer> | null = null;
  composer = createComposer({
    client,
    store,
    state,
    mode: () => mode,
    setMode,
    chatWidth: () => layout.chatWidth,
    popover: () => popoverViewport(),
    question: () => threadView.question(),
    inlineImages: (options.inlineImages ?? null) !== null,
    env: options.env ?? { VISUAL: process.env.VISUAL, EDITOR: process.env.EDITOR },
    homeDir: options.homeDir ?? NodeOS.homedir(),
    runEditor: options.runEditor ?? (() => Promise.reject(new Error("no editor runner"))),
    readLocalImage: options.readLocalImage ?? readLocalImageFile,
    ...(options.decodeImage ? { decodeImage: options.decodeImage } : {}),
    onDraftChange: () => {
      publishSidebar();
      publishPage();
    },
    onInterrupt: (turnId) => threadView.turnInterrupted(turnId),
    onRowsChange: (rows) => {
      editorRows = rows;
      publishLayout();
      // A taller prompt can take rows from the drawer.
      terminal.sync();
    },
  });
  const palette = createPalette({
    state,
    viewport: () => popoverViewport(),
    mode: () => mode,
    setMode,
    context: () => {
      const context = composer!.context();
      const detail = store.getState().detail;
      return {
        ...context,
        hasProposedPlan:
          context.threadId !== null &&
          detail?.id === context.threadId &&
          latestActionableProposedPlan(detail) !== null,
      };
    },
    // After the composer's own entries: thread lifecycle and scope, then the
    // diff, source-control, settings, files, add-project, terminal and cluster entries.
    extraCommands: () => [
      ...threadActions.paletteCommands(),
      ...threadView.paletteCommands(),
      ...detailCommands({
        panelOpen: rightPanel === SOURCE_CONTROL_PANEL,
        hasCheckpoints:
          revertableCheckpoints(store.getState().detail?.checkpoints ?? []).length > 0,
      }),
      ...areaCommands(),
      ...cluster.commands(),
      ...sections!.commands(),
    ],
    run: (action, payload) => {
      dispatch(action, payload);
    },
  });

  const unknownActions = new Set<string>();
  const dispatch = (action: string, payload?: unknown): boolean => {
    options.trace?.(action, payload);
    return handle(action, payload);
  };
  /**
   * Keymap aliases: the keymap names what a chord does in its mode; these are
   * the host actions that do it. A chord whose action does not apply right
   * now returns false, and its key falls through to the focused input.
   */
  const handleAlias = (action: string): boolean | null => {
    const jump = /^thread\.jump\.([1-9])$/.exec(action);
    if (jump) return handle("thread.jump", { index: Number(jump[1]) });
    switch (action) {
      case "timeline.pageUp":
        return handle("timeline.scroll", { by: -10 });
      case "timeline.pageDown":
        return handle("timeline.scroll", { by: 10 });
      case "terminal.focus":
        // Ctrl+P in the prompt reaches the terminal only while it is open.
        if (!terminal.visible()) return false;
        return handle("terminal.focus.toggle");
      case "terminal.grow":
        return handle("terminal.resize", { delta: 2 });
      case "terminal.shrink":
        return handle("terminal.resize", { delta: -2 });
      case "terminal.scroll.pageUp":
        return handle("terminal.scroll", { action: "page-up" });
      case "terminal.scroll.pageDown":
        return handle("terminal.scroll", { action: "page-down" });
      case "terminal.scroll.lineUp":
        return handle("terminal.scroll", { action: "line-up" });
      case "terminal.scroll.lineDown":
        return handle("terminal.scroll", { action: "line-down" });
      case "contextMenu.previous":
        return handle("contextMenu.move", { delta: -1 });
      case "contextMenu.next":
        return handle("contextMenu.move", { delta: 1 });
      case "contextMenu.run":
      case "contextMenu.close": {
        const menu = state.get("contextMenu") as {
          requestId: string;
          items: ReadonlyArray<{ id: string }>;
          selectedIndex: number;
        } | null;
        if (!menu) return true;
        return handle("contextMenu.select", {
          requestId: menu.requestId,
          id: action === "contextMenu.run" ? (menu.items[menu.selectedIndex]?.id ?? null) : null,
        });
      }
      case "files.previous":
        return handle("files.move", { delta: -1 });
      case "files.next":
        return handle("files.move", { delta: 1 });
      case "files.scrollUp":
        return handle("files.page", { delta: -1 });
      case "files.scrollDown":
        return handle("files.page", { delta: 1 });
      case "rightPanel.previous":
        return handle("git.previous");
      case "rightPanel.next":
        return handle("git.next");
      case "rightPanel.activate":
        return handle("git.activate");
      case "userInput.previous":
        return handle("userInput.move", { delta: -1 });
      case "userInput.next":
        return handle("userInput.move", { delta: 1 });
      case "checkpoint.revert.previous":
        return handle("checkpoint.revert.move", { delta: -1 });
      case "checkpoint.revert.next":
        return handle("checkpoint.revert.move", { delta: 1 });
      case "settings.scrollUp":
      case "settings.scrollDown":
        // ChatView scrolls the settings pane by its SCROLL_STEP of 8 rows.
        return scrollPane("settings", action === "settings.scrollUp" ? -8 : 8);
      case "diff.scrollUp":
        return scrollPane("diff", -10);
      case "diff.scrollDown":
        return scrollPane("diff", 10);
      case "project.add.previous":
        return handle("project.add.move", { delta: -1 });
      case "project.add.next":
        return handle("project.add.move", { delta: 1 });
      default:
        return null;
    }
  };
  const handle = (action: string, payload?: unknown): boolean => {
    if (action === "palette.open") {
      threadActions.closeMenu();
      // Its remove entries follow the members.
      void cluster.refresh();
    }
    if (palette.dispatch(action, payload)) return true;
    // A paste the composer does not take (plain text) is inserted by the prompt.
    if (action === "composer.paste") return composer!.dispatch(action, payload);
    if (composer!.dispatch(action, payload)) return true;
    if (threadActions.dispatch(action, payload)) return true;
    // ↑/↓ walk the approvals only while the prompt is empty (then they edit it).
    if (
      (action === "approval.previous" || action === "approval.next") &&
      ((state.get("composer") as { text?: string } | undefined)?.text ?? "") !== ""
    ) {
      return false;
    }
    const alias = handleAlias(action);
    if (alias !== null) return alias;
    switch (action) {
      case "composer.focus":
        palette.dispatch("palette.close");
        composer!.dispatch("select.close");
        setMode("compose");
        return true;
      case "thread.open": {
        const key = payloadField(payload, "key");
        if (typeof key !== "string") return true;
        if (composer!.draft()) composer!.dispatch("newThread.cancel");
        sections!.close();
        setMode("compose");
        store.select({ kind: "thread", id: idFromKey(key) });
        return true;
      }
      case "thread.next":
        store.moveThreadSelection(1);
        return true;
      case "thread.previous":
        store.moveThreadSelection(-1);
        return true;
      case "thread.jump": {
        const index = Number(payloadField(payload, "index"));
        if (Number.isInteger(index) && index > 0) store.selectThreadByIndex(index);
        return true;
      }
      case "sidebar.toggle":
        sidebarCollapsed = !sidebarCollapsed;
        publishLayout();
        return true;
      case "sidebar.scope": {
        const key = payloadField(payload, "projectKey");
        store.setProjectScope(typeof key === "string" ? idFromKey(key) : null);
        return true;
      }
      case "sidebar.section.toggle": {
        const section = payloadField(payload, "section");
        if (section === "snoozed" || section === "settled") store.toggleSection(section);
        return true;
      }
      case "sidebar.more":
        store.loadMore(SIDEBAR_SETTLED_SECTION_ID);
        return true;
      case "sidebar.scroll": {
        // The mouse wheel scrolls the list without moving the selection.
        const by = Number(payloadField(payload, "by"));
        if (Number.isFinite(by)) {
          scrollTop = Math.max(0, scrollTop + Math.trunc(by));
          publishSidebar(false);
        }
        return true;
      }
      case "sidebar.filter.focus":
        setMode("filter");
        return true;
      case "sidebar.filter.set": {
        const query = payloadField(payload, "query");
        store.setFilter(typeof query === "string" ? query : "");
        return true;
      }
      case "sidebar.filter.commit":
        setMode(restingMode());
        return true;
      case "sidebar.filter.cancel":
        store.setFilter("");
        setMode(restingMode());
        return true;
      case "clock.tick":
        publishSidebar();
        return true;
      case "rightPanel.toggle": {
        const kind = payloadField(payload, "kind");
        const next = typeof kind === "string" ? kind : SOURCE_CONTROL_PANEL;
        if (rightPanel === next) setRightPanel(null, false);
        else setRightPanel(next, true);
        return true;
      }
      case "rightPanel.open": {
        const kind = payloadField(payload, "kind");
        setRightPanel(typeof kind === "string" ? kind : SOURCE_CONTROL_PANEL, true);
        return true;
      }
      case "rightPanel.focus":
        setRightPanel(rightPanel ?? SOURCE_CONTROL_PANEL, true);
        return true;
      case "rightPanel.blur":
        // A panel standing in for the conversation closes when it gives the keys back.
        if (layout.rightPanel.asMain) setRightPanel(null, false);
        else setRightPanel(rightPanel, false);
        return true;
      case "rightPanel.close":
        if (rightPanel === null) return true;
        setRightPanel(null, false);
        return true;
      case "section.open":
        // A settings page takes the pane from the overview, the diff and the files.
        if (settingsOpen) dispatch("settings.close");
        if (mode === "diff") dispatch("diff.close");
        files.close();
        return sections!.dispatch(action, payload);
      case "settings.open":
        if (mode === "diff") dispatch("diff.close");
        sections!.close();
        settingsOpen = true;
        publishSettings();
        void cluster.refresh();
        setMode("settings");
        return true;
      case "settings.close":
        settingsOpen = false;
        publishSettings();
        if (mode === "settings") setMode(restingMode());
        // The detail panel comes back.
        publishLayout();
        return true;
      case "terminal.toggle":
        terminal.toggle();
        return true;
      case "terminal.open":
        terminal.open();
        return true;
      case "terminal.focus.toggle":
        terminal.toggleFocus();
        return true;
      case "terminal.new":
        terminal.newTab();
        return true;
      case "terminal.next":
        terminal.cycle(1);
        return true;
      case "terminal.previous":
        terminal.cycle(-1);
        return true;
      case "terminal.select": {
        const id = payloadField(payload, "id");
        if (typeof id === "string") terminal.select(id);
        return true;
      }
      case "terminal.close": {
        const id = payloadField(payload, "id");
        terminal.close(typeof id === "string" ? id : undefined);
        return true;
      }
      case "terminal.clear":
        terminal.clear();
        return true;
      case "terminal.restart":
        terminal.restart();
        return true;
      case "terminal.copy":
        terminal.copy();
        return true;
      case "terminal.input": {
        const data = payloadField(payload, "data");
        if (typeof data === "string") terminal.input(data);
        return true;
      }
      case "terminal.paste": {
        const text = payloadField(payload, "text");
        if (typeof text === "string") terminal.paste(text);
        return true;
      }
      case "terminal.scroll": {
        const scroll = payloadField(payload, "action");
        if (typeof scroll === "string") terminal.scroll(scroll as TerminalScrollAction);
        return true;
      }
      case "terminal.resize": {
        const height = payloadField(payload, "height");
        const delta = payloadField(payload, "delta");
        if (typeof height === "number") terminal.setHeight(height);
        else if (typeof delta === "number") terminal.resizeBy(delta);
        return true;
      }
      case "layout.popover": {
        const rows = Number(payloadField(payload, "rows"));
        popoverRows = Number.isFinite(rows) ? Math.max(0, Math.floor(rows)) : 0;
        publishLayout();
        return true;
      }
      case "sidebar.list.focus":
        setMode("list");
        return true;
      case "sidebar.list.blur":
        if (mode === "list") setMode(restingMode());
        return true;
      case "plugins.refresh":
        refreshPlugins();
        return true;
      case "plugin.remove": {
        const id = payloadField(payload, "id");
        if (typeof id !== "string" || !pluginPort) return true;
        pluginPort.remove(id);
        refreshPlugins();
        return true;
      }
      case "plugin.load": {
        const file = payloadField(payload, "file");
        if (typeof file !== "string" || !pluginPort) return true;
        void pluginPort.load(file).then(refreshPlugins);
        return true;
      }
      case "quit":
      case "app.quit":
        options.onQuit?.();
        return true;
      default:
        if (threadView.dispatch(action, payload)) return true;
        if (sourceControl.dispatch(action, payload)) return true;
        if (files.dispatch(action, payload) || addProject.dispatch(action, payload)) return true;
        if (cluster.dispatch(action, payload)) return true;
        if (sections!.dispatch(action, payload)) return true;
        // Known actions that decline when they do not apply (the key falls through).
        if (DECLINABLE_ACTIONS.has(action)) return false;
        if (!unknownActions.has(action)) {
          unknownActions.add(action);
          log(`hal-c2 tui: unknown shell action "${action}"`);
        }
        return false;
    }
  };

  const threadActions = createThreadActions({
    client,
    store,
    state,
    size: () => size,
    rows: () => rowsNow(),
    setMode,
    restingMode,
    settlementSupported: () => settlementSupported,
    copyToClipboard: options.copyToClipboard,
  });

  // The composer loads the new-thread defaults itself; this is the settlement flag.
  const ready = client.getServerConfig().then(
    (config) => {
      settlementSupported = config.environment?.capabilities?.threadSettlement === true;
      publishSidebar();
    },
    () => {
      // Defaults stay usable while disconnected or on an older server.
    },
  );

  publishLayout();
  publish();
  composer.sync();
  // The key-hint and status row follows whatever it reads from the published state.
  const disposeStatusRow = createRoot((dispose) => {
    createComputed(() => {
      const current = state.get("layout") as TuiLayoutState;
      const hints = state.get("threadHints") as
        | { items: string[]; banner: string | null }
        | undefined;
      const page = state.get("page") as { kind: string } | undefined;
      state.set(
        "statusRow",
        buildStatusRow({
          mainWidth: current.mainWidth,
          status: state.get("status") as TuiStatusState,
          imagePreview: state.get("imageViewer") != null,
          addingProject: (state.get("addProject") as { open?: boolean } | undefined)?.open === true,
          questionBanner: hints?.banner ?? null,
          terminalOpen: current.drawer.open,
          threadHints: hints?.items ?? [],
          sourceControlOpen: current.rightPanel.kind === SOURCE_CONTROL_PANEL,
          working:
            (state.get("composer") as { isRunning?: boolean } | undefined)?.isRunning === true,
          draft: page?.kind === "draft",
        }),
      );
    });
    return dispose;
  });
  const unsubscribe = store.subscribe(() => {
    publish();
    composer!.sync();
    palette.sync();
  });
  const unsubscribeConnection = client.subscribeConnection((phase) =>
    state.set("connection", connectionState(phase)),
  );
  store.start();

  return {
    state,
    dispatch,
    setMode,
    idle: () => composer!.idle(),
    resize: (next) => {
      if (next.columns === size.columns && next.rows === size.rows) return;
      size = next;
      state.set("size", size);
      publishLayout();
      publishSidebar();
      terminal.sync();
    },
    Shell: { state, dispatch },
    Theme: createTuiTheme(),
    ready,
    settled: async () => {
      await addProject.settled();
      await files.settled();
      await terminal.settled();
      await threadView.settled();
      await cluster.settled();
      await sections!.settled();
    },
    attachPlugins: (port) => {
      pluginPort = port;
      refreshPlugins();
    },
    reportError: (error, where) =>
      addProblem({
        level: "error",
        message: error instanceof Error ? error.message : String(error),
        where: where ?? null,
      }),
    reportWarning: (message) => addProblem({ level: "warning", message, where: null }),
    destroy: () => {
      disposeStatusRow();
      unsubscribeConnection();
      unsubscribe();
      terminal.dispose();
      threadView.dispose();
      store.stop();
    },
  };
}

function connectionState(phase: TuiConnectionPhase): TuiConnectionState {
  return {
    state: phase,
    environments: [
      { id: "local", label: "This machine", kind: "local", connected: phase === "connected" },
    ],
    pairingHint: null,
  };
}

function pageFor(state: StoreState, selectedThreadId: string | null): TuiPageState {
  if (selectedThreadId === null) return { kind: "none" };
  const shellThread = state.shell?.threads.find((thread) => thread.id === selectedThreadId);
  const title = state.detail?.title ?? shellThread?.title ?? "";
  const projectId = state.detail?.projectId ?? shellThread?.projectId;
  const projectTitle =
    state.shell?.projects.find((project) => project.id === projectId)?.title ?? null;
  return {
    kind: "thread",
    key: threadKey(selectedThreadId),
    threadId: selectedThreadId,
    title,
    projectTitle,
  };
}
