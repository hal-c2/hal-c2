import {
  canSnooze,
  effectiveSnoozed,
  resolveSnoozePresets,
} from "@hal-c2/client-runtime/state/thread-settled";
import type { ContextMenuItem } from "@hal-c2/contracts";
import type { PropertyMap } from "opentui-qml";

import type { TuiClient } from "../connection.ts";
import {
  firstContextMenuIndex,
  isSelectable,
  moveContextMenuIndex,
  resolveContextMenuLayout,
} from "../components/ContextMenu.logic.ts";
import { clip } from "../format.ts";
import type { Row } from "../components/Sidebar.logic.ts";
import type { TuiThreadShell } from "../orchestrationV2Adapter.ts";
import type { Store } from "../store.ts";
import { THEME } from "../theme.ts";
import { buildThreadContextMenuItems, type ThreadContextMenuAction } from "../threadMenu.logic.ts";
import type { TuiMode, TuiSize } from "./layoutState.ts";
import type { PaletteCommand } from "./paletteState.ts";
import { idFromKey, projectKey, threadKey } from "./sidebarState.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

/**
 * One painted line of the open menu: a divider or an item (`index` into
 * `items`), with its text as ContextMenu.tsx draws it; an active item sits on
 * the selected background.
 */
export type TuiContextMenuRow =
  | { readonly kind: "separator"; readonly key: string; readonly text: StyledText }
  | {
      readonly kind: "item";
      readonly key: string;
      readonly index: number;
      readonly id: string;
      readonly label: string;
      readonly disabled: boolean;
      readonly destructive: boolean;
      readonly selected: boolean;
      readonly active: boolean;
      readonly text: StyledText;
    };

/**
 * Published under `contextMenu`: the contract's `ShellContextMenuState` (null
 * when closed) plus the clamped box and paint rows the terminal draws.
 */
export interface TuiContextMenuState {
  readonly requestId: string;
  readonly surfaceId: "sidebar";
  readonly threadKey: string;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly items: ReadonlyArray<ContextMenuItem>;
  readonly selectedIndex: number;
  readonly rows: ReadonlyArray<TuiContextMenuRow>;
}

/**
 * Published under `overlay`: the rename prompt or the delete confirmation; the
 * confirmation's `line` is ConfirmDeleteMenu's first row.
 */
export type TuiOverlayState =
  | { readonly kind: "rename"; readonly threadKey: string; readonly title: string }
  | {
      readonly kind: "confirmDelete";
      readonly threadKey: string;
      readonly title: string;
      readonly line: StyledText;
    }
  | null;

export interface ThreadActionsContext {
  readonly client: TuiClient;
  readonly store: Store;
  readonly state: PropertyMap;
  readonly size: () => TuiSize;
  /** The rows the sidebar shows now (for the menu's section-aware items). */
  readonly rows: () => ReadonlyArray<Row>;
  readonly setMode: (mode: TuiMode) => void;
  /** The mode to return to when a menu or prompt closes. */
  readonly restingMode: () => TuiMode;
  readonly settlementSupported: () => boolean;
  readonly copyToClipboard?: ((text: string) => boolean) | undefined;
  /** The connection to the environment is lost: what it would have to do is refused here. */
  readonly offline: () => boolean;
  /** The clock (ISO), for what a thread may do now and the snooze choices. */
  readonly now: () => string;
  /** Menu entries other controllers add for a thread (moving it), and what choosing one does. */
  readonly extraMenuItems?: (thread: TuiThreadShell) => ReadonlyArray<ContextMenuItem>;
  readonly runExtraMenuItem?: (thread: TuiThreadShell, id: string) => boolean;
}

/** A second menu where the first was (snooze times, machines): its items and what choosing does. */
export interface ThreadSubmenu {
  readonly items: ReadonlyArray<ContextMenuItem>;
  readonly choose: (id: string) => void;
}

const field = (payload: unknown, name: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[name]
    : undefined;

const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

/**
 * Thread lifecycle from the sidebar and the palette: the row context menu,
 * rename and delete prompts, settle/archive/stop and copy, plus the palette
 * entries for them. `dispatch` returns false for actions it does not own.
 */
export function createThreadActions(ctx: ThreadActionsContext) {
  const { client, store, state } = ctx;
  let menu: TuiContextMenuState | null = null;
  // Set while the open menu is a submenu: choosing an item runs this instead of a thread action.
  let menuChoose: ((id: string) => void) | null = null;
  // Where the thread's menu last opened: a submenu opens in its place.
  let menuAt: { x: number; y: number; threadId: string | null } = { x: 0, y: 0, threadId: null };
  let overlay: TuiOverlayState = null;
  let menuRequests = 0;

  const shellThread = (id: string): TuiThreadShell | null =>
    store.getState().shell?.threads.find((thread) => thread.id === id) ?? null;
  const threadFromPayload = (payload: unknown): TuiThreadShell | null => {
    const key = field(payload, "key");
    if (typeof key === "string") return shellThread(idFromKey(key));
    const selection = store.getState().selection;
    return selection?.kind === "thread" ? shellThread(selection.id) : null;
  };
  const workspacePath = (thread: TuiThreadShell): string | null =>
    thread.worktreePath ||
    store.getState().shell?.projects.find((project) => project.id === thread.projectId)
      ?.workspaceRoot ||
    null;

  const report = (promise: Promise<unknown>, success: string, failure: string) => {
    void promise.then(
      () => store.setStatus(success, "success"),
      (error: unknown) => store.setStatus(`${failure}: ${errorText(error)}`, "error"),
    );
  };

  const publishMenu = () => {
    if (menu) {
      let separators = 0;
      const rows: TuiContextMenuRow[] = [];
      // Inside the border and a cell of padding on each side.
      const labelWidth = Math.max(1, menu.width - 4);
      menu.items.forEach((item, index) => {
        if (item.separatorBefore) {
          rows.push({
            kind: "separator",
            key: `sep:${separators++}`,
            text: styled(chunk("─".repeat(labelWidth), { fg: THEME.faint })),
          });
        }
        const active = index === menu!.selectedIndex && isSelectable(item);
        const colour = item.destructive
          ? THEME.error
          : item.disabled || item.header
            ? THEME.faint
            : active
              ? THEME.text
              : THEME.dim;
        rows.push({
          kind: "item",
          key: item.id,
          index,
          id: item.id,
          label: item.label,
          disabled: item.disabled === true || item.header === true,
          destructive: item.destructive === true,
          selected: index === menu!.selectedIndex,
          active,
          text: styled(
            chunk(active ? "▸ " : "  ", { fg: active ? THEME.accent : THEME.faint }),
            chunk(clip(item.label, labelWidth - 2), { fg: colour }),
          ),
        });
      });
      menu = { ...menu, rows };
    }
    state.set("contextMenu", menu);
  };
  const publishOverlay = () => state.set("overlay", overlay);

  const closeMenu = () => {
    if (!menu) return;
    menu = null;
    menuChoose = null;
    publishMenu();
  };

  const showMenu = (
    thread: TuiThreadShell,
    items: ReadonlyArray<ContextMenuItem>,
    at: { x: number; y: number },
    choose: ((id: string) => void) | null,
  ) => {
    const { columns, rows } = ctx.size();
    // The menu acts on its own thread; the open thread stays as it was.
    const box = resolveContextMenuLayout(items, at, { width: columns, height: rows });
    menuRequests += 1;
    menu = {
      requestId: `thread-menu-${menuRequests}`,
      surfaceId: "sidebar",
      threadKey: threadKey(thread.id),
      ...box,
      items,
      selectedIndex: firstContextMenuIndex(items),
      rows: [],
    };
    menuChoose = choose;
    publishMenu();
    ctx.setMode("contextMenu");
  };

  const openMenu = (thread: TuiThreadShell, x: number, y: number) => {
    const row = ctx
      .rows()
      .find(
        (candidate): candidate is Extract<Row, { kind: "thread" }> =>
          candidate.kind === "thread" && candidate.id === thread.id,
      );
    const items = buildThreadContextMenuItems({
      row: row ?? { section: "active", thread },
      settlementSupported: ctx.settlementSupported(),
      hasWorkspacePath: workspacePath(thread) !== null,
      canSnooze: canSnooze(thread, { now: ctx.now() }),
      extra: ctx.extraMenuItems?.(thread) ?? [],
    });
    menuAt = { x, y, threadId: thread.id };
    showMenu(thread, items, menuAt, null);
  };

  /** A second menu for `thread` (in the first one's place, or mid-screen from the palette). */
  const openSubmenu = (thread: TuiThreadShell, submenu: ThreadSubmenu) => {
    const { columns, rows } = ctx.size();
    const at =
      menuAt.threadId === thread.id
        ? menuAt
        : { x: Math.floor(columns / 3), y: Math.floor(rows / 3) };
    showMenu(thread, submenu.items, at, submenu.choose);
  };

  /** The times a thread can be snoozed until, as a submenu. */
  const snoozeMenu = (thread: TuiThreadShell): ThreadSubmenu => {
    const presets = resolveSnoozePresets(new Date(ctx.now()));
    return {
      items: [
        { id: "header", label: `Snooze ${clip(thread.title, 24)} until`, header: true },
        ...presets.map((preset) => ({
          id: preset.id,
          label: `${preset.label} · ${preset.whenLabel}`,
        })),
      ],
      choose: (id) => {
        const preset = presets.find((candidate) => candidate.id === id);
        if (!preset) return;
        report(
          client.snoozeThread(thread.id as never, preset.snoozedUntil),
          `Snoozed until ${preset.whenLabel}.`,
          "Failed to snooze thread",
        );
      },
    };
  };

  const copy = (value: string, label: string) => {
    const copied = ctx.copyToClipboard?.(value) ?? false;
    store.setStatus(
      copied ? `${label} copied.` : "Clipboard not supported by this terminal.",
      copied ? "success" : "error",
    );
  };

  const openOverlay = (next: Exclude<TuiOverlayState, null>) => {
    overlay = next;
    publishOverlay();
    ctx.setMode(next.kind);
  };
  const closeOverlay = () => {
    overlay = null;
    publishOverlay();
    ctx.setMode(ctx.restingMode());
  };

  const runMenuAction = (thread: TuiThreadShell, action: ThreadContextMenuAction) => {
    switch (action) {
      case "settle":
        return settle(thread);
      case "unsettle":
        return report(client.unsettleThread(thread.id as never), "Un-settled.", "Un-settle failed");
      case "rename":
        return openOverlay({
          kind: "rename",
          threadKey: threadKey(thread.id),
          title: thread.title,
        });
      case "copy-path": {
        const path = workspacePath(thread);
        if (path) copy(path, "Path");
        return;
      }
      case "copy-branch":
        if (thread.branch) copy(thread.branch, "Branch");
        return;
      case "copy-thread-id":
        return copy(thread.id, "Thread ID");
      case "snooze":
        // The same rule the server enforces: a thread that waits on the user stays in view.
        if (!canSnooze(thread, { now: ctx.now() })) {
          store.setStatus("This thread is waiting on you and cannot be snoozed.", "error");
          return;
        }
        return openSubmenu(thread, snoozeMenu(thread));
      case "unsnooze":
        return report(client.unsnoozeThread(thread.id as never), "Woken.", "Failed to wake thread");
      case "archive":
        return report(client.archiveThread(thread.id as never), "Archived.", "Archive failed");
      case "delete":
        if (ctx.offline()) {
          store.setStatus("Delete failed: the environment is offline.", "error");
          return;
        }
        return openOverlay({
          kind: "confirmDelete",
          threadKey: threadKey(thread.id),
          title: thread.title,
          line: styled(
            chunk("delete ", { fg: THEME.error }),
            chunk(clip(thread.title, 48), { fg: THEME.text }),
            chunk(" — this can't be undone", { fg: THEME.dim }),
          ),
        });
    }
  };

  // The server owns the settle rules and rejects a thread that still needs
  // attention, so its answer is what the status line reports.
  const settle = (thread: TuiThreadShell) =>
    report(client.settleThread(thread.id as never), "Settled.", "Settle failed");

  const rename = (thread: TuiThreadShell, raw: string) => {
    const title = raw.trim();
    if (title.length === 0) {
      store.setStatus("Thread title cannot be empty", "error");
      return;
    }
    if (title === thread.title) return;
    report(client.renameThread(thread.id as never, title), "Renamed.", "Rename failed");
  };

  /** The selected thread's lifecycle, the project scope and the filter, as palette entries. */
  const paletteCommands = (): PaletteCommand[] => {
    const selection = store.getState().selection;
    const thread = selection?.kind === "thread" ? shellThread(selection.id) : null;
    const list: PaletteCommand[] = [];
    if (thread) {
      const payload = { key: threadKey(thread.id) };
      list.push({ id: "rename", title: "Rename thread", action: "thread.rename", payload });
      list.push(
        thread.archivedAt != null
          ? { id: "unarchive", title: "Unarchive thread", action: "thread.unarchive", payload }
          : { id: "archive", title: "Archive thread", action: "thread.archive", payload },
      );
      if (ctx.settlementSupported()) {
        const settled = thread.settledOverride === "settled";
        list.push({
          id: "settle",
          title: settled ? "Un-settle thread" : "Settle thread",
          keywords: "park done inbox active lifecycle",
          action: settled ? "thread.unsettle" : "thread.settle",
          payload,
        });
      }
      const snoozed = effectiveSnoozed(thread, { now: ctx.now() });
      list.push(
        snoozed
          ? {
              id: "unsnooze",
              title: "Wake thread",
              keywords: "unsnooze snooze",
              action: "thread.unsnooze",
              payload,
            }
          : {
              id: "snooze",
              title: "Snooze thread…",
              keywords: "later park hide wake",
              action: "thread.snooze",
              payload,
            },
      );
      list.push({ id: "delete", title: "Delete thread", action: "thread.delete", payload });
      list.push({ id: "stop", title: "Stop session", action: "thread.stop", payload });
    }
    // The thread list's project scope (the old sidebar's project picker).
    const scopeId = store.getState().projectScopeId;
    for (const project of store.getState().shell?.projects ?? []) {
      if (project.id === scopeId) continue;
      list.push({
        id: `scope:${project.id}`,
        title: `Show project ${project.title}`,
        keywords: "scope filter projects",
        action: "sidebar.scope",
        payload: { projectKey: projectKey(project.id) },
      });
    }
    if (scopeId !== null) {
      list.push({
        id: "scope:all",
        title: "Show all projects",
        keywords: "scope filter projects",
        action: "sidebar.scope",
        payload: { projectKey: null },
      });
    }
    list.push({
      id: "filter",
      title: "Filter threads",
      hint: "^F",
      keywords: "search",
      action: "sidebar.filter.focus",
    });
    return list;
  };

  publishMenu();
  publishOverlay();

  const dispatch = (action: string, payload?: unknown): boolean => {
    switch (action) {
      case "thread.menu": {
        const thread = threadFromPayload(payload);
        if (!thread) return true;
        const x = Number(field(payload, "x") ?? 0);
        const y = Number(field(payload, "y") ?? 0);
        openMenu(thread, x, y);
        return true;
      }
      case "contextMenu.move": {
        if (!menu) return true;
        const delta = Number(field(payload, "delta")) < 0 ? -1 : 1;
        menu = {
          ...menu,
          selectedIndex: moveContextMenuIndex(menu.items, menu.selectedIndex, delta),
        };
        publishMenu();
        return true;
      }
      case "contextMenu.hover": {
        // The pointer over an item selects it (ContextMenu.tsx's onMouseMove).
        const index = Number(field(payload, "index"));
        if (!menu || index === menu.selectedIndex || !isSelectable(menu.items[index])) return true;
        menu = { ...menu, selectedIndex: index };
        publishMenu();
        return true;
      }
      case "contextMenu.select": {
        if (!menu) return true;
        const requestId = field(payload, "requestId");
        if (requestId !== undefined && requestId !== menu.requestId) return true;
        const id = field(payload, "id");
        const item = menu.items.find((candidate) => candidate.id === id);
        const thread = shellThread(idFromKey(menu.threadKey));
        if (id !== null && (!item || item.disabled || item.header)) return true;
        const choose = menuChoose;
        closeMenu();
        ctx.setMode(ctx.restingMode());
        if (!item || !thread) return true;
        if (choose) choose(item.id);
        else if (ctx.runExtraMenuItem?.(thread, item.id) !== true) {
          runMenuAction(thread, item.id as ThreadContextMenuAction);
        }
        return true;
      }
      case "thread.rename": {
        const thread = threadFromPayload(payload);
        const title = field(payload, "title");
        if (typeof title === "string") {
          if (overlay?.kind === "rename") closeOverlay();
          if (thread) rename(thread, title);
          return true;
        }
        if (thread) runMenuAction(thread, "rename");
        return true;
      }
      case "thread.delete": {
        const thread = threadFromPayload(payload);
        if (thread) runMenuAction(thread, "delete");
        return true;
      }
      case "thread.delete.confirm": {
        if (overlay?.kind !== "confirmDelete") return true;
        const id = idFromKey(overlay.threadKey);
        closeOverlay();
        if (ctx.offline()) {
          store.setStatus("Delete failed: the environment is offline.", "error");
          return true;
        }
        report(client.deleteThread(id as never), "Deleted.", "Delete failed");
        return true;
      }
      case "thread.snooze": {
        const thread = threadFromPayload(payload);
        if (thread) runMenuAction(thread, "snooze");
        return true;
      }
      case "thread.unsnooze": {
        const thread = threadFromPayload(payload);
        if (thread) runMenuAction(thread, "unsnooze");
        return true;
      }
      case "overlay.cancel":
        if (overlay) closeOverlay();
        return true;
      case "thread.settle": {
        const thread = threadFromPayload(payload);
        if (thread) settle(thread);
        return true;
      }
      case "thread.unsettle": {
        const thread = threadFromPayload(payload);
        if (thread) runMenuAction(thread, "unsettle");
        return true;
      }
      case "thread.archive": {
        const thread = threadFromPayload(payload);
        if (thread) runMenuAction(thread, "archive");
        return true;
      }
      case "thread.unarchive": {
        const thread = threadFromPayload(payload);
        if (thread) {
          report(client.unarchiveThread(thread.id as never), "Unarchived.", "Unarchive failed");
        }
        return true;
      }
      case "thread.stop": {
        const thread = threadFromPayload(payload);
        if (thread)
          report(client.stopSession(thread.id as never), "Session stopped.", "Stop failed");
        return true;
      }
      case "thread.copy": {
        const thread = threadFromPayload(payload);
        const what = field(payload, "what");
        if (!thread) return true;
        if (what === "path") runMenuAction(thread, "copy-path");
        else if (what === "branch") runMenuAction(thread, "copy-branch");
        else runMenuAction(thread, "copy-thread-id");
        return true;
      }
      default:
        return false;
    }
  };

  return {
    dispatch,
    paletteCommands,
    /** The palette opening over an open menu closes the menu. */
    closeMenu,
    openSubmenu,
  };
}
