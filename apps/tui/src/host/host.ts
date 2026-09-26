import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";

import { PROVIDER_SEND_TURN_MAX_IMAGE_BYTES } from "@t3tools/contracts";
import { createPropertyMap, type PropertyMap } from "opentui-qml";

import type { TuiClient } from "../connection.ts";
import { buildRows } from "../components/Sidebar.logic.ts";
import { KEYBINDING_GROUPS, KEYMAP_LAYERS, KEYMAP_PARITY } from "../keymap.ts";
import type { EditorCommand } from "../promptEditor.ts";
import { latestActionableProposedPlan } from "../proposedPlan.ts";
import { createStore, type StatusKind, type StoreState } from "../store.ts";
import { createComposer, type ImageDecoder } from "./composerState.ts";
import { buildTuiLayoutState, type TuiMode, type TuiSize } from "./layoutState.ts";
import { buildTuiSidebarState, idFromKey, threadKey } from "./sidebarState.ts";
import { createPalette } from "./paletteState.ts";
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
  /** `VISUAL` / `EDITOR` for Ctrl+G (default: the process environment). */
  readonly env?: { readonly VISUAL?: string | undefined; readonly EDITOR?: string | undefined };
  /** Expands `~` in pasted image paths (default: the user's home). */
  readonly homeDir?: string;
  /** Ctrl+G: run the editor on a file; the entry suspends the renderer around it. */
  readonly runEditor?: (command: EditorCommand, file: string) => Promise<void>;
  /** Read an image pasted as an absolute path on this machine. */
  readonly readLocalImage?: (path: string) => Promise<Uint8Array>;
  /** Decode attached images for their preview (default: `@t3tools/opentui-image`). */
  readonly decodeImage?: ImageDecoder;
  /** Sees every action dispatched, from QML or from the palette (tests, debugging). */
  readonly trace?: (action: string, payload: unknown) => void;
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
    keybindings: { layers: KEYMAP_LAYERS, groups: KEYBINDING_GROUPS, parity: KEYMAP_PARITY },
  });

  // Republish a key only when what it is derived from changed, so bindings
  // on other keys are not re-evaluated by every store emit.
  let last: StoreState | null = null;
  let layout = buildTuiLayoutState({ size, sidebarCollapsed, rightPanelVisible: false, mode });
  const publishLayout = () => {
    layout = buildTuiLayoutState({ size, sidebarCollapsed, rightPanelVisible: false, mode });
    state.set("layout", layout);
    composer?.relayout();
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
  };

  const setMode = (next: TuiMode) => {
    if (next === mode) return;
    mode = next;
    state.set("mode", mode);
    publishLayout();
  };

  let composer: ReturnType<typeof createComposer> | null = null;
  composer = createComposer({
    client,
    store,
    state,
    mode: () => mode,
    setMode,
    chatWidth: () => layout.chatWidth,
    env: options.env ?? { VISUAL: process.env.VISUAL, EDITOR: process.env.EDITOR },
    homeDir: options.homeDir ?? NodeOS.homedir(),
    runEditor: options.runEditor ?? (() => Promise.reject(new Error("no editor runner"))),
    readLocalImage: options.readLocalImage ?? readLocalImageFile,
    ...(options.decodeImage ? { decodeImage: options.decodeImage } : {}),
  });
  const palette = createPalette({
    state,
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
    run: (action, payload) => {
      dispatch(action, payload);
    },
  });

  const unknownActions = new Set<string>();
  const dispatch = (action: string, payload?: unknown): boolean => {
    options.trace?.(action, payload);
    return handle(action, payload);
  };
  const handle = (action: string, payload?: unknown): boolean => {
    if (palette.dispatch(action, payload)) return true;
    if (action === "composer.paste") return composer!.dispatch(action, payload);
    if (composer!.dispatch(action, payload)) return true;
    const jump = /^thread\.jump\.([1-9])$/.exec(action);
    if (jump) {
      store.selectThreadByIndex(Number(jump[1]));
      return true;
    }
    switch (action) {
      case "composer.focus":
        palette.dispatch("palette.close");
        composer!.dispatch("select.close");
        setMode("compose");
        return true;
      case "thread.open": {
        const key = payloadField(payload, "key");
        if (typeof key !== "string") return true;
        store.select({ kind: "thread", id: idFromKey(key) });
        setMode("compose");
        return true;
      }
      case "thread.next":
        store.moveThreadSelection(1);
        return true;
      case "thread.previous":
        store.moveThreadSelection(-1);
        return true;
      case "sidebar.toggle":
        sidebarCollapsed = !sidebarCollapsed;
        publishLayout();
        return true;
      case "sidebar.scope": {
        const key = payloadField(payload, "projectKey");
        store.setProjectScope(typeof key === "string" ? idFromKey(key) : null);
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
        setMode("compose");
        return true;
      case "sidebar.filter.cancel":
        store.setFilter("");
        setMode("compose");
        return true;
      case "app.quit":
        options.onQuit?.();
        return true;
      default:
        if (!unknownActions.has(action)) {
          unknownActions.add(action);
          log(`t3 tui: unknown shell action "${action}"`);
        }
        return false;
    }
  };

  publishLayout();
  publish();
  composer.sync();
  const unsubscribe = store.subscribe(() => {
    publish();
    composer!.sync();
    palette.sync();
  });
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
