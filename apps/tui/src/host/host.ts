import { createPropertyMap, type PropertyMap } from "opentui-qml";

import type { TuiClient } from "../connection.ts";
import { buildRows } from "../components/Sidebar.logic.ts";
import { createStore, type StatusKind, type StoreState } from "../store.ts";
import { buildTuiLayoutState, type TuiMode, type TuiSize } from "./layoutState.ts";
import { buildTuiSidebarState, idFromKey, threadKey } from "./sidebarState.ts";
import { createTuiTheme, TUI_THEME_STATE, type TuiTheme } from "./theme.ts";
import { createThreadView } from "./threadView.ts";

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
  const threadView = createThreadView({
    store,
    client,
    state,
    mode: () => mode,
    setMode: (next) => setMode(next),
    nowMs: () => Date.parse(now()),
  });
  const publishLayout = () => {
    const layout = buildTuiLayoutState({ size, sidebarCollapsed, rightPanelVisible: false, mode });
    state.set("layout", layout);
    threadView.setPaneWidth(layout.chatWidth);
  };
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
    threadView.sync(next, prev);
  };

  /** "compose" means the prompt has the keys, or an open question when one waits. */
  const setMode = (requested: TuiMode) => {
    const next = requested === "compose" ? threadView.composeMode() : requested;
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
        setMode("compose");
        store.select({ kind: "thread", id: idFromKey(key) });
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
      case "app.quit":
        options.onQuit?.();
        return;
      default:
        if (threadView.dispatch(action, payload)) return;
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
    },
    Shell: { state, dispatch },
    Theme: createTuiTheme(),
    destroy: () => {
      unsubscribe();
      store.stop();
    },
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
