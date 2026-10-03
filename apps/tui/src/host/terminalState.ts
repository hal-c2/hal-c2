import { RGBA, StyledText, TextAttributes, type TextChunk } from "@opentui/core";
import type { ThreadId } from "@hal-c2/contracts";
import * as XtermHeadless from "@xterm/headless";

import { MIN_TERMINAL_DRAWER_ROWS } from "../components/ChatView.layout.ts";
import type { TuiClient } from "../connection.ts";
import type { Store } from "../store.ts";
import {
  addTab,
  closeTab,
  cycleActiveId,
  initialTabs,
  reduceKnownTerminals,
  tabsWithDiscovered,
  type ThreadTabs,
} from "../terminalTabs.ts";
import {
  encodeTerminalPaste,
  readTerminalFrame,
  readTerminalViewport,
  type TermColor,
  type TermSegment,
} from "../terminalView.ts";
import { clip } from "../format.ts";
import { THEME } from "../theme.ts";
import { chunk, styled, type StyledText as HostStyledText } from "./styledText.ts";

// The thread terminal drawer's model (ported from ThreadTerminalDrawer and the
// terminal half of ChatView). Each open tab owns a headless xterm fed by its
// PTY stream; the active one is published as styled rows the `TerminalDrawer`
// brick paints with a `Text` per row.

// Static namespace import: @xterm/headless is CommonJS; see ThreadTerminalDrawer.
const { Terminal } = XtermHeadless;
type XTerm = InstanceType<typeof Terminal>;

/** Cap on terminals per thread (mirrors the web's per-group limit). */
export const MAX_TERMINALS_PER_THREAD = 6;
/** Replay at most this many bytes of terminal history on attach (keeps it fast). */
export const TERMINAL_HISTORY_TAIL = 128 * 1024;
/** Drawer chrome around the screen: header, tab row and the frame's two borders. */
const DRAWER_CHROME_ROWS = 4;
const RENDER_THROTTLE_MS = 16;

export type TerminalScrollAction = "line-up" | "line-down" | "page-up" | "page-down" | "bottom";

export interface TuiTerminalTab {
  readonly id: string;
  /** The number the user sees: `term-N` is N. */
  readonly number: number;
  readonly active: boolean;
}

/** Published under `terminal`. */
export interface TuiTerminalState {
  /** A thread is selected, so the drawer can open. */
  readonly available: boolean;
  readonly open: boolean;
  readonly focused: boolean;
  readonly title: string;
  /** `Terminal · <title>` and the key hint, clipped to the drawer like ThreadTerminalDrawer. */
  readonly header: HostStyledText;
  readonly tabs: ReadonlyArray<TuiTerminalTab>;
  readonly activeId: string | null;
  /** Drawer height in rows, chrome included. */
  readonly height: number;
  readonly cols: number;
  readonly rows: number;
  /** The active screen, one styled row each (the scroll note replaces the last row). */
  readonly lines: ReadonlyArray<StyledText>;
  readonly rowCount: number;
  /** `▲ scrollback …` while viewing history, else "". */
  readonly scrollNote: string;
}

export interface TerminalThread {
  readonly threadId: string;
  readonly title: string;
  readonly cwd: string;
  readonly worktreePath: string | null;
  /** What the thread's shells find in their environment (the project and worktree folders). */
  readonly env?: Readonly<Record<string, string>>;
}

export interface TerminalControllerOptions {
  readonly client: TuiClient;
  readonly store: Store;
  /** The selected thread, or null. */
  readonly thread: () => TerminalThread | null;
  /** Width of the main column the drawer spans. */
  readonly width: () => number;
  /** Rows the layout gives the drawer slot (`layout.drawer.rows`). */
  readonly rows: () => number;
  /** The drawer opened, closed or asked for another height: re-run the layout. */
  readonly layoutChanged: () => void;
  /** Terminal focus is the host's `terminal` mode. */
  readonly isFocused: () => boolean;
  readonly setFocused: (focused: boolean) => void;
  readonly copyToClipboard: (text: string) => boolean;
  readonly publish: (state: TuiTerminalState) => void;
}

export interface TerminalController {
  readonly toggle: () => void;
  readonly open: () => void;
  readonly toggleFocus: () => void;
  readonly newTab: () => void;
  readonly select: (id: string) => void;
  readonly cycle: (delta: 1 | -1) => void;
  readonly close: (id?: string) => void;
  readonly clear: () => void;
  readonly restart: () => void;
  readonly copy: () => void;
  readonly input: (data: string) => void;
  readonly paste: (text: string) => void;
  /**
   * Type a project action's command into the thread's terminal: the active
   * one, or a new one while that is running something. False without a thread.
   */
  readonly runAction: (action: { readonly name: string; readonly command: string }) => boolean;
  readonly scroll: (action: TerminalScrollAction) => void;
  /** Grow (+) or shrink (−) the drawer by rows. */
  readonly resizeBy: (delta: number) => void;
  readonly setHeight: (rows: number) => void;
  /** Whether the drawer shows (open, with a thread selected). */
  readonly visible: () => boolean;
  /** The height the user asked for, or null for the layout's default. */
  readonly preferredRows: () => number | null;
  /** The selected thread or the window changed. */
  readonly sync: () => void;
  /** Palette commands for the terminal (titles as the palette shows them). */
  readonly commands: () => ReadonlyArray<{ readonly title: string; readonly action: string }>;
  /** Resolves once client calls and emulator writes in flight have landed and are published. */
  readonly settled: () => Promise<void>;
  readonly dispose: () => void;
}

export function terminalNumber(id: string, index: number): number {
  const match = /^term-(\d+)$/.exec(id);
  return match ? Number(match[1]) : index + 1;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

const toRgba = (color: TermColor | undefined): RGBA | undefined =>
  color === undefined ? undefined : typeof color === "string" ? RGBA.fromHex(color) : color;

/**
 * One segment as a text chunk. A cursor on an empty cell is a block glyph, and
 * over text an explicit background, so it stays visible on any palette.
 */
function segmentChunk(segment: TermSegment, focused: boolean): TextChunk {
  const blankCursor = segment.cursor === true && segment.text === " ";
  const cursorColor = focused ? THEME.accent : THEME.faint;
  const inverse = segment.cursor ? false : segment.inverse;
  const fg = segment.cursor
    ? blankCursor
      ? cursorColor
      : (segment.backgroundColor ?? THEME.bg)
    : inverse
      ? (segment.backgroundColor ?? THEME.bg)
      : (segment.color ?? THEME.text);
  const bg = segment.cursor
    ? blankCursor
      ? segment.backgroundColor
      : cursorColor
    : inverse
      ? (segment.color ?? THEME.text)
      : segment.backgroundColor;
  let attributes = 0;
  if (segment.bold) attributes |= TextAttributes.BOLD;
  if (segment.italic) attributes |= TextAttributes.ITALIC;
  if (segment.dimColor) attributes |= TextAttributes.DIM;
  if (segment.underline || segment.href) attributes |= TextAttributes.UNDERLINE;
  // Inverse is resolved into fg/bg above; keep the flag so the style stays visible to readers.
  if (inverse) attributes |= TextAttributes.INVERSE;
  const chunk: TextChunk = { __isChunk: true, text: blankCursor ? "█" : segment.text };
  const fgRgba = toRgba(fg);
  const bgRgba = toRgba(bg);
  if (fgRgba) chunk.fg = fgRgba;
  if (bgRgba) chunk.bg = bgRgba;
  if (attributes) chunk.attributes = attributes;
  if (segment.href) chunk.link = { url: segment.href };
  return chunk;
}

/** The drawer's header row: the label, then as much of the key hint as fits in `cols`. */
export function terminalHeader(title: string, cols: number, focused: boolean): HostStyledText {
  const hint = focused
    ? " · ^P prompt · ^E close · ^↑/^↓ resize · ^O copy · paste ✓"
    : " · ^P focus · ^E close";
  const label = clip(`Terminal · ${title}`, Math.max(1, cols));
  const visibleHint = clip(hint, Math.max(0, cols - Bun.stringWidth(label)));
  return styled(
    chunk(label, { fg: focused ? THEME.accent : THEME.warning }),
    visibleHint !== "" && chunk(visibleHint, { fg: THEME.dim }),
  );
}

export function terminalRowText(
  segments: ReadonlyArray<TermSegment>,
  focused: boolean,
): StyledText {
  if (segments.length === 0) return new StyledText([{ __isChunk: true, text: " " }]);
  return new StyledText(segments.map((segment) => segmentChunk(segment, focused)));
}

/** One tab's emulator and live subscription. */
class Pane {
  readonly term: XTerm;
  offset = 0;
  private readonly unsubscribe: () => void;
  private readonly client: TuiClient;
  readonly threadId: string;
  readonly terminalId: string;
  private readonly track: (promise: Promise<unknown>) => void;
  private readonly changed: (pane: Pane) => void;

  constructor(
    client: TuiClient,
    threadId: string,
    terminalId: string,
    thread: TerminalThread,
    cols: number,
    rows: number,
    track: (promise: Promise<unknown>) => void,
    changed: (pane: Pane) => void,
  ) {
    this.client = client;
    this.threadId = threadId;
    this.terminalId = terminalId;
    this.track = track;
    this.changed = changed;
    this.term = new Terminal({ cols, rows, allowProposedApi: true, scrollback: 2000 });
    this.unsubscribe = client.subscribeTerminal(
      {
        threadId: threadId as ThreadId,
        terminalId,
        cwd: thread.cwd,
        worktreePath: thread.worktreePath,
        cols,
        rows,
        ...(thread.env ? { env: thread.env } : {}),
      },
      (event) => {
        if (event.type === "snapshot" || event.type === "restarted") {
          this.term.reset();
          this.offset = 0;
          const history = event.snapshot.history;
          this.write(
            history.length > TERMINAL_HISTORY_TAIL
              ? history.slice(history.length - TERMINAL_HISTORY_TAIL)
              : history,
          );
        } else if (event.type === "cleared") {
          this.term.reset();
          this.offset = 0;
          this.changed(this);
        } else if (event.type === "output") {
          this.writeLive(event.data);
        } else if (event.type === "exited") {
          this.writeLive("\r\n[process exited]\r\n");
        } else if (event.type === "error") {
          this.writeLive(`\r\n[terminal error: ${event.message}]\r\n`);
        }
      },
    );
  }

  private write(data: string, after?: () => void) {
    this.track(
      new Promise<void>((resolve) =>
        this.term.write(data, () => {
          after?.();
          this.changed(this);
          resolve();
        }),
      ),
    );
  }

  /** Live output; a scrolled-back view keeps its lines by following the growth. */
  private writeLive(data: string) {
    const previousBaseY = this.term.buffer.active.baseY;
    this.write(data, () => {
      const nextBaseY = this.term.buffer.active.baseY;
      if (this.offset > 0 && nextBaseY > previousBaseY) {
        this.offset = Math.min(nextBaseY, this.offset + nextBaseY - previousBaseY);
      }
    });
  }

  send(data: string) {
    this.track(
      this.client.terminalWrite(this.threadId as ThreadId, this.terminalId, data).catch(() => {}),
    );
  }

  resize(cols: number, rows: number, tellServer: boolean) {
    if (this.term.cols !== cols || this.term.rows !== rows) this.term.resize(cols, rows);
    if (tellServer) {
      this.track(
        this.client
          .terminalResize(this.threadId as ThreadId, this.terminalId, cols, rows)
          .catch(() => {}),
      );
    }
  }

  scroll(action: TerminalScrollAction): boolean {
    const max = this.term.buffer.active.baseY;
    const page = Math.max(1, this.term.rows - 1);
    const next = Math.max(
      0,
      Math.min(
        max,
        action === "line-up"
          ? this.offset + 1
          : action === "line-down"
            ? this.offset - 1
            : action === "page-up"
              ? this.offset + page
              : action === "page-down"
                ? this.offset - page
                : 0,
      ),
    );
    if (next === this.offset) return false;
    this.offset = next;
    return true;
  }

  dispose() {
    this.unsubscribe();
    this.term.dispose();
  }
}

export function createTerminalController(options: TerminalControllerOptions): TerminalController {
  const { client, store } = options;
  let open = false;
  let heightOverride: number | null = null;
  let tabsByThread: ReadonlyMap<string, ThreadTabs> = new Map();
  let known: ReadonlyMap<string, ReadonlyArray<string>> = new Map();
  // Terminals (`thread:terminal`) the server says are running a command.
  const busy = new Set<string>();
  const panes = new Map<string, Pane>();
  const inFlight = new Set<Promise<unknown>>();
  let renderTimer: ReturnType<typeof setTimeout> | null = null;
  let lastThreadId: string | null = null;
  let lastSize = { cols: 0, rows: 0 };
  let resizedPaneKey: string | null = null;

  const track = (promise: Promise<unknown>) => {
    inFlight.add(promise);
    void promise.finally(() => inFlight.delete(promise));
  };

  const currentTabs = (): ThreadTabs | null => {
    const thread = options.thread();
    return thread ? (tabsByThread.get(thread.threadId) ?? null) : null;
  };
  const visible = () => open && currentTabs() !== null;

  const drawerRows = () => options.rows();
  const paneSize = () => ({
    cols: Math.max(2, options.width() - 4),
    rows: Math.max(2, drawerRows() - DRAWER_CHROME_ROWS),
  });

  const paneKey = (threadId: string, id: string) => `${threadId}:${id}`;
  const activePane = (): Pane | null => {
    const thread = options.thread();
    const tabs = currentTabs();
    return thread && tabs && open
      ? (panes.get(paneKey(thread.threadId, tabs.activeId)) ?? null)
      : null;
  };

  const publishNow = () => {
    if (renderTimer !== null) {
      clearTimeout(renderTimer);
      renderTimer = null;
    }
    const thread = options.thread();
    const tabs = currentTabs();
    const isOpen = visible();
    const focused = isOpen && options.isFocused();
    const size = paneSize();
    const pane = activePane();
    let lines: StyledText[] = [];
    let scrollNote = "";
    if (pane) {
      const frame = readTerminalFrame(pane.term, pane.offset);
      const scrolled = frame.scrollOffset > 0;
      if (scrolled) {
        scrollNote = `▲ scrollback −${frame.scrollOffset}/${frame.maxScroll} · ⇧PgUp/PgDn · type to return`;
      }
      const body = scrolled ? frame.rows.slice(0, Math.max(0, frame.rows.length - 1)) : frame.rows;
      lines = body.map((segments) => terminalRowText(segments, focused));
    }
    options.publish({
      available: thread !== null,
      open: isOpen,
      focused,
      title: thread?.title ?? "",
      header: terminalHeader(thread?.title ?? "", size.cols, focused),
      tabs: (tabs?.ids ?? []).map((id, index) => ({
        id,
        number: terminalNumber(id, index),
        active: id === tabs?.activeId,
      })),
      activeId: tabs?.activeId ?? null,
      height: isOpen ? drawerRows() : 0,
      cols: size.cols,
      rows: size.rows,
      lines,
      rowCount: lines.length,
      scrollNote,
    });
  };

  const schedulePublish = (pane: Pane) => {
    if (pane !== activePane() || renderTimer !== null) return;
    renderTimer = setTimeout(publishNow, RENDER_THROTTLE_MS);
  };

  /** Mount a pane per open tab of the selected thread; drop the rest. */
  const reconcilePanes = () => {
    const thread = options.thread();
    const tabs = currentTabs();
    const wanted = new Set(
      open && thread && tabs ? tabs.ids.map((id) => paneKey(thread.threadId, id)) : [],
    );
    for (const [key, pane] of panes) {
      if (!wanted.has(key)) {
        pane.dispose();
        panes.delete(key);
      }
    }
    if (!thread || !tabs || !open) {
      resizedPaneKey = null;
      return;
    }
    const size = paneSize();
    for (const id of tabs.ids) {
      const key = paneKey(thread.threadId, id);
      if (!panes.has(key)) {
        panes.set(
          key,
          new Pane(
            client,
            thread.threadId,
            id,
            thread,
            size.cols,
            size.rows,
            track,
            schedulePublish,
          ),
        );
      }
    }
    // Only the visible pane tells the server its size; a hidden one resyncs when shown.
    const activeKey = paneKey(thread.threadId, tabs.activeId);
    const sizeChanged = size.cols !== lastSize.cols || size.rows !== lastSize.rows;
    for (const [key, pane] of panes) {
      const tellServer = key === activeKey && (sizeChanged || resizedPaneKey !== key);
      pane.resize(size.cols, size.rows, tellServer);
    }
    lastSize = size;
    resizedPaneKey = activeKey;
  };

  // What the layout last saw; it re-runs only when these change.
  let laidOut = { visible: false, rows: null as number | null };
  const update = () => {
    const shown = visible();
    if (shown !== laidOut.visible || heightOverride !== laidOut.rows) {
      laidOut = { visible: shown, rows: heightOverride };
      options.layoutChanged();
    }
    reconcilePanes();
    publishNow();
  };

  const updateTabs = (threadId: string, change: (tabs: ThreadTabs | null) => ThreadTabs | null) => {
    const current = tabsByThread.get(threadId) ?? null;
    const next = change(current);
    if (next === current) return next;
    const map = new Map(tabsByThread);
    if (next) map.set(threadId, next);
    else map.delete(threadId);
    tabsByThread = map;
    return next;
  };

  const setOpen = (next: boolean) => {
    open = next;
    if (!next) options.setFocused(false);
  };

  const mergeDiscovered = () => {
    const thread = options.thread();
    if (!open || !thread) return;
    updateTabs(thread.threadId, (tabs) =>
      tabsWithDiscovered(tabs, known.get(thread.threadId) ?? []),
    );
  };

  const unsubscribeMetadata = client.subscribeTerminalMetadata((event) => {
    known = reduceKnownTerminals(known, event);
    if (event.type === "snapshot") busy.clear();
    for (const summary of event.type === "snapshot"
      ? event.terminals
      : event.type === "upsert"
        ? [event.terminal]
        : []) {
      const key = paneKey(summary.threadId, summary.terminalId);
      if (summary.hasRunningSubprocess) busy.add(key);
      else busy.delete(key);
    }
    if (event.type === "remove") busy.delete(paneKey(event.threadId, event.terminalId));
    if (
      event.type === "remove" &&
      tabsByThread.get(event.threadId)?.ids.includes(event.terminalId)
    ) {
      const remaining = updateTabs(event.threadId, (tabs) =>
        tabs ? closeTab(tabs, event.terminalId) : tabs,
      );
      if (remaining === null && options.thread()?.threadId === event.threadId && open) {
        setOpen(false);
      }
    }
    mergeDiscovered();
    update();
  });

  const listThreadTerminals = (threadId: string) => {
    track(
      client.listTerminalIds(threadId as ThreadId).then(
        (ids) => {
          if (ids.length === 0) return;
          const map = new Map(known);
          const merged = [...(map.get(threadId) ?? [])];
          for (const id of ids) if (!merged.includes(id)) merged.push(id);
          map.set(threadId, merged);
          known = map;
          mergeDiscovered();
          update();
        },
        (error) => {
          store.setStatus(`Could not list terminal instances: ${errorText(error)}`, "error");
        },
      ),
    );
  };

  const focusPrompt = () => options.setFocused(false);

  const controller: TerminalController = {
    toggle: () => {
      if (visible()) {
        setOpen(false);
        update();
        return;
      }
      controller.open();
    },
    open: () => {
      const thread = options.thread();
      if (!thread) return;
      updateTabs(thread.threadId, (tabs) => tabs ?? initialTabs());
      open = true;
      mergeDiscovered();
      options.setFocused(true);
      update();
    },
    toggleFocus: () => {
      if (!visible()) return;
      options.setFocused(!options.isFocused());
      update();
    },
    newTab: () => {
      const thread = options.thread();
      if (!thread) return;
      open = true;
      options.setFocused(true);
      updateTabs(thread.threadId, (tabs) => {
        if (tabs && tabs.ids.length >= MAX_TERMINALS_PER_THREAD) {
          store.setStatus(`At most ${MAX_TERMINALS_PER_THREAD} terminals per thread.`);
          return tabs;
        }
        return addTab(tabs);
      });
      update();
    },
    select: (id) => {
      const thread = options.thread();
      if (!thread) return;
      updateTabs(thread.threadId, (tabs) =>
        tabs?.ids.includes(id) && tabs.activeId !== id ? { ...tabs, activeId: id } : tabs,
      );
      options.setFocused(true);
      update();
    },
    cycle: (delta) => {
      const thread = options.thread();
      if (!thread) return;
      updateTabs(thread.threadId, (tabs) =>
        tabs ? { ...tabs, activeId: cycleActiveId(tabs, delta) } : tabs,
      );
      options.setFocused(true);
      update();
    },
    close: (id) => {
      const thread = options.thread();
      const tabs = currentTabs();
      if (!thread || !tabs) return;
      const target = id ?? tabs.activeId;
      if (!tabs.ids.includes(target)) return;
      track(client.terminalClose(thread.threadId as ThreadId, target).catch(() => {}));
      const remaining = updateTabs(thread.threadId, (current) =>
        current ? closeTab(current, target) : current,
      );
      if (remaining === null) {
        setOpen(false);
        focusPrompt();
      }
      update();
    },
    clear: () => {
      const thread = options.thread();
      const tabs = currentTabs();
      if (!visible() || !thread || !tabs) return;
      store.setStatus("Clearing terminal…", "busy");
      track(
        client.terminalClear(thread.threadId as ThreadId, tabs.activeId).then(
          () => store.setStatus("Terminal cleared.", "success"),
          (error) => store.setStatus(`Could not clear terminal: ${errorText(error)}`, "error"),
        ),
      );
    },
    restart: () => {
      const thread = options.thread();
      const tabs = currentTabs();
      if (!visible() || !thread || !tabs) return;
      const size = paneSize();
      store.setStatus("Restarting terminal…", "busy");
      track(
        client
          .terminalRestart({
            threadId: thread.threadId as ThreadId,
            terminalId: tabs.activeId,
            cwd: thread.cwd,
            worktreePath: thread.worktreePath,
            cols: size.cols,
            rows: size.rows,
          } as Parameters<TuiClient["terminalRestart"]>[0])
          .then(
            () => store.setStatus("Terminal restarted.", "success"),
            (error) => store.setStatus(`Could not restart terminal: ${errorText(error)}`, "error"),
          ),
      );
    },
    copy: () => {
      const pane = activePane();
      if (!pane) return;
      const text = readTerminalViewport(pane.term, pane.offset);
      if (text.trim().length === 0) {
        store.setStatus("Terminal is empty.", "info");
        return;
      }
      if (options.copyToClipboard(text))
        store.setStatus("Terminal copied to clipboard.", "success");
      else store.setStatus("Clipboard not supported by this terminal.", "error");
    },
    input: (data) => {
      const pane = activePane();
      if (!pane) return;
      // Any keystroke returns a scrolled-back view to the live tail first.
      if (pane.scroll("bottom")) publishNow();
      pane.send(data);
    },
    paste: (text) => {
      const pane = activePane();
      if (!pane || text.length === 0) return;
      pane.send(encodeTerminalPaste(text, pane.term.modes.bracketedPasteMode));
    },
    runAction: (action) => {
      const thread = options.thread();
      if (!thread) return false;
      let tabs = updateTabs(thread.threadId, (current) => current ?? initialTabs())!;
      if (busy.has(paneKey(thread.threadId, tabs.activeId))) {
        if (tabs.ids.length >= MAX_TERMINALS_PER_THREAD) {
          store.setStatus(`At most ${MAX_TERMINALS_PER_THREAD} terminals per thread.`, "error");
          return true;
        }
        tabs = updateTabs(thread.threadId, (current) => addTab(current))!;
      }
      const terminalId = tabs.activeId;
      // The drawer shows the run; the keys stay where they are.
      open = true;
      mergeDiscovered();
      update();
      const size = paneSize();
      store.setStatus(`Running ${action.name}…`, "busy");
      track(
        client
          // The shell is started first (again, when it has ended), so the command always runs.
          .terminalOpen({
            threadId: thread.threadId as ThreadId,
            terminalId,
            cwd: thread.cwd,
            worktreePath: thread.worktreePath,
            cols: size.cols,
            rows: size.rows,
            ...(thread.env ? { env: thread.env } : {}),
          })
          .then(() =>
            client.terminalWrite(thread.threadId as ThreadId, terminalId, `${action.command}\r`),
          )
          .then(
            () => store.setStatus(`Ran ${action.name} in the terminal.`, "success"),
            (error) =>
              store.setStatus(
                `Failed to run action "${action.name}": ${errorText(error)}`,
                "error",
              ),
          ),
      );
      return true;
    },
    scroll: (action) => {
      const pane = activePane();
      if (pane?.scroll(action)) publishNow();
    },
    resizeBy: (delta) => {
      if (!visible()) return;
      heightOverride = Math.max(
        MIN_TERMINAL_DRAWER_ROWS,
        (heightOverride ?? options.rows()) + delta,
      );
      update();
    },
    setHeight: (rows) => {
      heightOverride = Math.max(MIN_TERMINAL_DRAWER_ROWS, Math.floor(rows));
      update();
    },
    visible,
    preferredRows: () => heightOverride,
    sync: () => {
      const thread = options.thread();
      const threadId = thread?.threadId ?? null;
      if (threadId !== lastThreadId) {
        lastThreadId = threadId;
        // Focus is global but tabs are per thread: a thread switch returns it to the prompt.
        if (options.isFocused()) focusPrompt();
        if (threadId !== null) listThreadTerminals(threadId);
        mergeDiscovered();
      }
      update();
    },
    commands: () => {
      const thread = options.thread();
      const tabs = currentTabs();
      const list: Array<{ title: string; action: string }> = [
        { title: visible() ? "Hide terminal" : "Show terminal", action: "terminal.toggle" },
      ];
      if (thread) list.push({ title: "New terminal", action: "terminal.new" });
      if (tabs && tabs.ids.length > 1) {
        list.push({ title: "Next terminal", action: "terminal.next" });
        list.push({ title: "Previous terminal", action: "terminal.previous" });
      }
      if (visible()) {
        list.push({ title: "Clear terminal", action: "terminal.clear" });
        list.push({ title: "Restart terminal", action: "terminal.restart" });
        list.push({ title: "Close terminal", action: "terminal.close" });
      }
      return list;
    },
    settled: async () => {
      while (inFlight.size > 0) await Promise.all([...inFlight]);
      publishNow();
    },
    dispose: () => {
      unsubscribeMetadata();
      if (renderTimer !== null) clearTimeout(renderTimer);
      for (const pane of panes.values()) pane.dispose();
      panes.clear();
    },
  };
  return controller;
}
