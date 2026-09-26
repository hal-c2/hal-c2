import { createPropertyMap, type PropertyMap } from "opentui-qml";

import type { TuiClient } from "../connection.ts";
import { buildRows } from "../components/Sidebar.logic.ts";
import { createStore, type StatusKind, type StoreState } from "../store.ts";
import { createAddProjectController } from "./addProjectState.ts";
import { createFilesController } from "./filesState.ts";
import { buildTuiLayoutState, type TuiMode, type TuiSize } from "./layoutState.ts";
import { buildTuiSidebarState, idFromKey, projectKey, threadKey } from "./sidebarState.ts";
import {
  createTerminalController,
  type TerminalScrollAction,
  type TerminalThread,
} from "./terminalState.ts";
import { createTuiTheme, TUI_THEME_STATE, type TuiTheme } from "./theme.ts";

/** Published under `status`: the one-line status message and its tone. */
export interface TuiStatusState {
  readonly kind: StatusKind;
  readonly text: string;
}

/** Published under `page`: what the main area shows. */
export type TuiPageState =
  | { readonly kind: "none" }
  | {
      /** A new thread in the project, before its first message. */
      readonly kind: "draft";
      readonly draftId: string;
      readonly projectKey: string;
      readonly projectTitle: string | null;
    }
  | {
      readonly kind: "thread";
      readonly key: string;
      readonly threadId: string;
      readonly title: string;
      readonly projectTitle: string | null;
    };

export interface TuiShellSingleton {
  readonly state: PropertyMap;
  readonly dispatch: (action: string, payload?: unknown) => void;
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
  /** Put text on the user's clipboard (OSC 52); false when the terminal cannot. */
  readonly copyToClipboard?: (text: string) => boolean;
}

/** A palette command an area offers now: its title and the action it dispatches. */
export interface TuiCommand {
  readonly title: string;
  readonly action: string;
  readonly payload?: unknown;
}

export interface Host {
  readonly state: PropertyMap;
  readonly dispatch: (action: string, payload?: unknown) => void;
  /** The terminal size changed (renderer "resize"). */
  readonly resize: (size: TuiSize) => void;
  /** QML singletons: `Shell.state.<key>`, `Shell.dispatch(action, payload)`, `Theme.*`. */
  readonly Shell: TuiShellSingleton;
  readonly Theme: TuiTheme;
  /** The palette commands the host's areas offer right now. */
  readonly commands: () => ReadonlyArray<TuiCommand>;
  /**
   * Resolves once client calls and terminal writes in flight have landed and
   * their state is published: the receipt tests wait on.
   */
  readonly settled: () => Promise<void>;
  readonly destroy: () => void;
}

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
  const store = createStore(client);

  let mode: TuiMode = "compose";
  let size = options.size;
  let sidebarCollapsed = false;

  const state = createPropertyMap({
    mode,
    size,
    theme: TUI_THEME_STATE,
    notifications: { items: [] },
  });

  // Republish a key only when what it is derived from changed, so bindings
  // on other keys are not re-evaluated by every store emit.
  let last: StoreState | null = null;
  const layoutState = () =>
    buildTuiLayoutState({ size, sidebarCollapsed, rightPanelVisible: false, mode });
  const publishLayout = () => state.set("layout", layoutState());

  const terminalThread = (): TerminalThread | null => {
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
  const terminal = createTerminalController({
    client,
    store,
    thread: terminalThread,
    area: () => ({ width: layoutState().mainWidth, height: size.rows }),
    isFocused: () => mode === "terminal",
    setFocused: (focused) => {
      if (focused) setMode("terminal");
      else if (mode === "terminal") setMode("compose");
    },
    copyToClipboard: options.copyToClipboard ?? (() => false),
    publish: (next) => state.set("terminal", next),
  });
  const files = createFilesController({
    client,
    cwd: () => terminalThread()?.cwd ?? null,
    height: () => {
      const drawer = state.get("terminal") as { open: boolean; height: number } | undefined;
      return size.rows - 1 - (drawer?.open ? drawer.height : 0);
    },
    setOpen: (open) => setMode(open ? "files" : "compose"),
    publish: (next) => state.set("files", next),
  });
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
    height: () => size.rows - 1,
    setOpen: (open) => setMode(open ? "project" : "compose"),
    // Pending the new-thread flow: selecting the project shows its draft.
    openDraft: (projectId) => store.select({ kind: "project", id: projectId }),
    publish: (next) => state.set("addProject", next),
  });
  const publish = () => {
    const next = store.getState();
    const prev = last;
    last = next;
    const selectedThreadId = next.selection?.kind === "thread" ? next.selection.id : null;
    if (
      !prev ||
      prev.shell !== next.shell ||
      prev.expanded !== next.expanded ||
      prev.loadedInFull !== next.loadedInFull ||
      prev.selection !== next.selection ||
      prev.filter !== next.filter ||
      prev.projectScopeId !== next.projectScopeId
    ) {
      const at = now();
      state.set(
        "sidebar",
        buildTuiSidebarState({
          shell: next.shell,
          rows: buildRows(
            next.shell,
            next.expanded,
            next.loadedInFull,
            selectedThreadId,
            next.filter,
            next.projectScopeId,
            at,
          ),
          selectedThreadId,
          projectScopeId: next.projectScopeId,
          filter: next.filter,
          now: at,
        }),
      );
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
      state.set("page", pageFor(next, selectedThreadId));
    }
    if (!prev || prev.selection !== next.selection || prev.detail !== next.detail) {
      terminal.sync();
    }
    if (prev && prev.selection !== next.selection) files.close();
    if (prev && prev.shell !== next.shell) addProject.sync();
  };

  function setMode(next: TuiMode) {
    if (next === mode) return;
    mode = next;
    state.set("mode", mode);
    publishLayout();
  }

  const unknownActions = new Set<string>();
  const dispatch = (action: string, payload?: unknown) => {
    switch (action) {
      case "thread.open": {
        const key = payloadField(payload, "key");
        if (typeof key !== "string") return;
        store.select({ kind: "thread", id: idFromKey(key) });
        setMode("compose");
        return;
      }
      case "thread.next":
        store.moveThreadSelection(1);
        return;
      case "thread.previous":
        store.moveThreadSelection(-1);
        return;
      case "sidebar.toggle":
        sidebarCollapsed = !sidebarCollapsed;
        publishLayout();
        return;
      case "sidebar.scope": {
        const key = payloadField(payload, "projectKey");
        store.setProjectScope(typeof key === "string" ? idFromKey(key) : null);
        return;
      }
      case "sidebar.filter.focus":
        setMode("filter");
        return;
      case "sidebar.filter.set": {
        const query = payloadField(payload, "query");
        store.setFilter(typeof query === "string" ? query : "");
        return;
      }
      case "sidebar.filter.commit":
        setMode("compose");
        return;
      case "sidebar.filter.cancel":
        store.setFilter("");
        setMode("compose");
        return;
      case "terminal.toggle":
        terminal.toggle();
        return;
      case "terminal.open":
        terminal.open();
        return;
      case "terminal.focus.toggle":
        terminal.toggleFocus();
        return;
      case "terminal.new":
        terminal.newTab();
        return;
      case "terminal.next":
        terminal.cycle(1);
        return;
      case "terminal.previous":
        terminal.cycle(-1);
        return;
      case "terminal.select": {
        const id = payloadField(payload, "id");
        if (typeof id === "string") terminal.select(id);
        return;
      }
      case "terminal.close": {
        const id = payloadField(payload, "id");
        terminal.close(typeof id === "string" ? id : undefined);
        return;
      }
      case "terminal.clear":
        terminal.clear();
        return;
      case "terminal.restart":
        terminal.restart();
        return;
      case "terminal.copy":
        terminal.copy();
        return;
      case "terminal.input": {
        const data = payloadField(payload, "data");
        if (typeof data === "string") terminal.input(data);
        return;
      }
      case "terminal.paste": {
        const text = payloadField(payload, "text");
        if (typeof text === "string") terminal.paste(text);
        return;
      }
      case "terminal.scroll": {
        const scroll = payloadField(payload, "action");
        if (typeof scroll === "string") terminal.scroll(scroll as TerminalScrollAction);
        return;
      }
      case "terminal.resize": {
        const height = payloadField(payload, "height");
        const delta = payloadField(payload, "delta");
        if (typeof height === "number") terminal.setHeight(height);
        else if (typeof delta === "number") terminal.resizeBy(delta);
        return;
      }
      case "app.quit":
        options.onQuit?.();
        return;
      default:
        if (files.dispatch(action, payload) || addProject.dispatch(action, payload)) return;
        if (unknownActions.has(action)) return;
        unknownActions.add(action);
        log(`t3 tui: unknown shell action "${action}"`);
    }
  };

  publishLayout();
  publish();
  const unsubscribe = store.subscribe(publish);
  store.start();

  return {
    state,
    dispatch,
    resize: (next) => {
      if (next.columns === size.columns && next.rows === size.rows) return;
      size = next;
      state.set("size", size);
      publishLayout();
      terminal.sync();
      files.sync();
    },
    Shell: { state, dispatch },
    Theme: createTuiTheme(),
    commands: () => [...addProject.commands(), ...files.commands(), ...terminal.commands()],
    settled: async () => {
      await addProject.settled();
      await files.settled();
      await terminal.settled();
    },
    destroy: () => {
      unsubscribe();
      terminal.dispose();
      store.stop();
    },
  };
}

function pageFor(state: StoreState, selectedThreadId: string | null): TuiPageState {
  const selection = state.selection;
  if (selection?.kind === "project") {
    return {
      kind: "draft",
      draftId: `draft:${selection.id}`,
      projectKey: projectKey(selection.id),
      projectTitle:
        state.shell?.projects.find((project) => project.id === selection.id)?.title ?? null,
    };
  }
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
