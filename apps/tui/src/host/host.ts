import { createPropertyMap, type PropertyMap } from "opentui-qml";

import type { TuiClient, TuiConnectionPhase } from "../connection.ts";
import { buildRows } from "../components/Sidebar.logic.ts";
import { createStore, type StatusKind, type StoreState } from "../store.ts";
import { buildTuiLayoutState, type TuiMode, type TuiSize } from "./layoutState.ts";
import type { PluginPort, TuiPluginsState } from "./plugins.ts";
import { buildTuiSidebarState, idFromKey, threadKey } from "./sidebarState.ts";
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
}

export interface Host {
  readonly state: PropertyMap;
  readonly dispatch: (action: string, payload?: unknown) => void;
  /** The terminal size changed (renderer "resize"). */
  readonly resize: (size: TuiSize) => void;
  /** QML singletons: `Shell.state.<key>`, `Shell.dispatch(action, payload)`, `Theme.*`. */
  readonly Shell: TuiShellSingleton;
  readonly Theme: TuiTheme;
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
    plugins: { items: [] } satisfies TuiPluginsState,
    problems: { items: [] },
    connection: connectionState("connecting"),
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

  // Republish a key only when what it is derived from changed, so bindings
  // on other keys are not re-evaluated by every store emit.
  let last: StoreState | null = null;
  const publishLayout = () =>
    state.set(
      "layout",
      buildTuiLayoutState({ size, sidebarCollapsed, rightPanelVisible: false, mode }),
    );
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
  };

  const setMode = (next: TuiMode) => {
    if (next === mode) return;
    mode = next;
    state.set("mode", mode);
    publishLayout();
  };

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
      case "sidebar.list.focus":
        setMode("list");
        return;
      case "sidebar.list.blur":
        setMode("compose");
        return;
      case "plugins.refresh":
        refreshPlugins();
        return;
      case "plugin.remove": {
        const id = payloadField(payload, "id");
        if (typeof id !== "string" || !pluginPort) return;
        pluginPort.remove(id);
        refreshPlugins();
        return;
      }
      case "plugin.load": {
        const file = payloadField(payload, "file");
        if (typeof file !== "string" || !pluginPort) return;
        void pluginPort.load(file).then(refreshPlugins);
        return;
      }
      case "app.quit":
        options.onQuit?.();
        return;
      default:
        if (unknownActions.has(action)) return;
        unknownActions.add(action);
        log(`t3 tui: unknown shell action "${action}"`);
    }
  };

  publishLayout();
  publish();
  const unsubscribe = store.subscribe(publish);
  const unsubscribeConnection = client.subscribeConnection((phase) =>
    state.set("connection", connectionState(phase)),
  );
  store.start();

  return {
    state,
    dispatch,
    resize: (next) => {
      if (next.columns === size.columns && next.rows === size.rows) return;
      size = next;
      state.set("size", size);
      publishLayout();
    },
    Shell: { state, dispatch },
    Theme: createTuiTheme(),
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
      unsubscribeConnection();
      unsubscribe();
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
