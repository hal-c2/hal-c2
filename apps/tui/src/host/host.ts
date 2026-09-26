import { createPropertyMap, type PropertyMap } from "opentui-qml";

import type { TuiClient } from "../connection.ts";
import { STATUS_ROWS } from "../components/ChatView.layout.ts";
import {
  buildRows,
  nextSidebarRefreshAt,
  SIDEBAR_SETTLED_SECTION_ID,
} from "../components/Sidebar.logic.ts";
import { createStore, type StatusKind, type StoreState } from "../store.ts";
import { buildTuiLayoutState, type TuiMode, type TuiSize } from "./layoutState.ts";
import { createNewThreadFlow, type NewThreadSettings } from "./newThread.ts";
import { buildTuiSidebarState, idFromKey, projectKey, threadKey } from "./sidebarState.ts";
import { createThreadActions } from "./threadActions.ts";
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
      /** The new-thread form (`Shell.state.newThread`) fills the main column. */
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
  /** Put text on the system clipboard; false when the terminal cannot (OSC 52). */
  readonly copyToClipboard?: (text: string) => boolean;
}

/** Published under `clock`: when the sidebar's next time boundary (a snooze wake) is due. */
export interface TuiClockState {
  /** Milliseconds until `clock.tick` should run; 0 when nothing is time-bound. */
  readonly refreshInMs: number;
}

export interface Host {
  readonly state: PropertyMap;
  readonly dispatch: (action: string, payload?: unknown) => void;
  /** The terminal size changed (renderer "resize"). */
  readonly resize: (size: TuiSize) => void;
  /** QML singletons: `Shell.state.<key>`, `Shell.dispatch(action, payload)`, `Theme.*`. */
  readonly Shell: TuiShellSingleton;
  readonly Theme: TuiTheme;
  /** Settles once the server config (settlement support, new-thread defaults) has loaded or failed. */
  readonly ready: Promise<void>;
  readonly destroy: () => void;
}

// The list pane's chrome: its border and the filter field.
const SIDEBAR_CHROME_ROWS = 3;

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
  // The detail panel's kind ("sourceControl", …) or null when closed.
  let rightPanel: string | null = null;
  let drawerOpen = false;
  let drawerRows: number | null = null;
  let composerText = "";
  let popoverRows = 0;
  let settlementSupported = false;
  let settings: NewThreadSettings = {
    defaultThreadEnvMode: null,
    newWorktreesStartFromOrigin: false,
  };
  let scrollTop = 0;

  const state = createPropertyMap({
    mode,
    size,
    theme: TUI_THEME_STATE,
    notifications: { items: [] },
  });

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
  });
  const publishLayout = () => {
    const layout = buildTuiLayoutState({
      size,
      sidebarCollapsed,
      rightPanel,
      mode,
      drawerOpen,
      drawerRows,
      composerText,
      popoverRows: popoverRows + threadActions.popoverRows(),
    });
    state.set("layout", layout);
    threadView.setPaneWidth(layout.contentWidth);
  };
  const publishSidebar = () => {
    const next = store.getState();
    const selectedThreadId = next.selection?.kind === "thread" ? next.selection.id : null;
    const at = now();
    const sidebar = buildTuiSidebarState({
      shell: next.shell,
      rows: rowsNow(next),
      selectedThreadId,
      projectScopeId: next.projectScopeId,
      filter: next.filter,
      now: at,
      settlementSupported,
      draft: newThread.draft(),
      viewportRows: Math.max(1, size.rows - STATUS_ROWS - SIDEBAR_CHROME_ROWS),
      scrollTop,
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
    const draft = newThread.draft();
    state.set(
      "page",
      draft
        ? {
            kind: "draft",
            draftId: draft.draftId,
            projectKey: projectKey(draft.projectId),
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
  };

  /** "compose" means the prompt has the keys, or an open question when one waits. */
  const setMode = (requested: TuiMode) => {
    const next = requested === "compose" ? threadView.composeMode() : requested;
    if (next === mode) return;
    mode = next;
    state.set("mode", mode);
    publishLayout();
  };
  // Where keys go when a menu, prompt or palette closes.
  const restingMode = (): TuiMode => (newThread.draft() ? "newThread" : "compose");

  const unknownActions = new Set<string>();
  const dispatch = (action: string, payload?: unknown) => {
    if (threadActions.dispatch(action, payload) || newThread.dispatch(action, payload)) return;
    switch (action) {
      case "thread.open": {
        const key = payloadField(payload, "key");
        if (typeof key !== "string") return;
        if (newThread.draft()) newThread.dispatch("newThread.cancel");
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
      case "thread.jump": {
        const index = Number(payloadField(payload, "index"));
        if (Number.isInteger(index) && index > 0) store.selectThreadByIndex(index);
        return;
      }
      case "sidebar.toggle":
        sidebarCollapsed = !sidebarCollapsed;
        publishLayout();
        return;
      case "sidebar.scope": {
        const key = payloadField(payload, "projectKey");
        store.setProjectScope(typeof key === "string" ? idFromKey(key) : null);
        return;
      }
      case "sidebar.section.toggle": {
        const section = payloadField(payload, "section");
        if (section === "snoozed" || section === "settled") store.toggleSection(section);
        return;
      }
      case "sidebar.more":
        store.loadMore(SIDEBAR_SETTLED_SECTION_ID);
        return;
      case "sidebar.filter.focus":
        setMode("filter");
        return;
      case "sidebar.filter.set": {
        const query = payloadField(payload, "query");
        store.setFilter(typeof query === "string" ? query : "");
        return;
      }
      case "sidebar.filter.commit":
        setMode(restingMode());
        return;
      case "sidebar.filter.cancel":
        store.setFilter("");
        setMode(restingMode());
        return;
      case "clock.tick":
        publishSidebar();
        return;
      case "rightPanel.toggle": {
        const kind = payloadField(payload, "kind");
        const next = typeof kind === "string" ? kind : "sourceControl";
        rightPanel = rightPanel === next ? null : next;
        publishLayout();
        return;
      }
      case "rightPanel.close":
        if (rightPanel === null) return;
        rightPanel = null;
        publishLayout();
        return;
      case "terminal.toggle":
        drawerOpen = !drawerOpen;
        publishLayout();
        return;
      case "terminal.resize": {
        const height = Number(payloadField(payload, "height"));
        if (!Number.isFinite(height)) return;
        drawerRows = Math.max(1, Math.floor(height));
        publishLayout();
        return;
      }
      case "composer.text.set": {
        const text = payloadField(payload, "text");
        composerText = typeof text === "string" ? text : "";
        publishLayout();
        return;
      }
      case "layout.popover": {
        const rows = Number(payloadField(payload, "rows"));
        popoverRows = Number.isFinite(rows) ? Math.max(0, Math.floor(rows)) : 0;
        publishLayout();
        return;
      }
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

  const threadActions = createThreadActions({
    client,
    store,
    state,
    size: () => size,
    rows: () => rowsNow(),
    setMode,
    restingMode,
    settlementSupported: () => settlementSupported,
    dispatch,
    copyToClipboard: options.copyToClipboard,
  });
  const newThread = createNewThreadFlow({
    client,
    store,
    state,
    settings: () => settings,
    setMode,
    onDraftChange: () => {
      publishSidebar();
      publishPage();
    },
  });

  const ready = client.getServerConfig().then(
    (config) => {
      settings = {
        defaultThreadEnvMode: config.settings.defaultThreadEnvMode ?? null,
        newWorktreesStartFromOrigin: config.settings.newWorktreesStartFromOrigin,
      };
      settlementSupported = config.environment?.capabilities?.threadSettlement === true;
      publishSidebar();
    },
    () => {
      // Defaults stay usable while disconnected or on an older server.
    },
  );

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
      publishSidebar();
    },
    Shell: { state, dispatch },
    Theme: createTuiTheme(),
    ready,
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
