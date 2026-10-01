// Terminal drawer steps (tui/terminal.feature, terminal/*.feature). The fake
// client plays the MC: attaching sends a snapshot of `ctx.history`, and
// steps push stream events with `emit`. Assertions read the published
// `terminal` key, the rendered frame and the fake's recorded calls, after
// `settle` (the host's receipt for in-flight calls and emulator writes).
import { expect } from "bun:test";
import { PasteEvent, type TextChunk } from "@opentui/core";
import type { TerminalAttachStreamEvent } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import type { TuiTerminalState } from "../../../src/host/terminalState.ts";
import { threadKey } from "../../../src/host/sidebarState.ts";
import type { Palette } from "../../../src/theme.ts";
import { THEME } from "../../../src/theme.ts";
import { expectColour, rectOf, regionRows, textWithin, type Rect } from "../design.ts";
import { shell } from "../fakeClient.ts";
import { recorded } from "../threadWorld.ts";
import { chooseCommand, palette } from "../threadUi.ts";
import {
  boot,
  paste,
  pressKey,
  resize,
  settle,
  typeText,
  useClient,
  type World,
} from "../world.ts";

type Deferred = { promise: Promise<void>; resolve: () => void };
type Overrides = {
  terminalClear?: () => Promise<void>;
  terminalRestart?: () => Promise<void>;
  terminalClose?: () => Promise<void>;
  listTerminalIds?: () => Promise<ReadonlyArray<string>>;
};

interface TerminalWorld extends World {
  history?: Record<string, string>;
  overrides?: Overrides;
  gates?: Deferred[];
  readingScreen?: string;
  /** Set by When steps, so a step shared by Given and Then knows which it is. */
  acted?: boolean;
}

const THREAD_ID = "t1";
const WORKSPACE = "/workspace/project-one";
const ORDINALS: Record<string, number> = { first: 1, second: 2, third: 3 };
const id = (n: number) => `term-${n}`;

function deferred(): Deferred {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => (resolve = done));
  return { promise, resolve };
}

function useTerminalClient(ctx: TerminalWorld) {
  if (ctx.fake) return ctx.fake;
  const threads = shell().threads;
  const second = { ...threads[0]!, id: "t2", title: "Thread two" };
  return useClient(ctx, {
    shellSnapshot: shell([...threads, second] as never),
    terminalHistory: (_thread, terminalId) => ctx.history?.[terminalId] ?? "",
    terminalClear: () => ctx.overrides?.terminalClear?.() ?? Promise.resolve(),
    terminalRestart: () => ctx.overrides?.terminalRestart?.() ?? Promise.resolve(),
    terminalClose: () => ctx.overrides?.terminalClose?.() ?? Promise.resolve(),
    listTerminalIds: () => ctx.overrides?.listTerminalIds?.() ?? Promise.resolve([]),
    // A shell that ends when told to.
    onTerminalWrite: (terminal, data) => {
      if (terminal.writes.join("").endsWith("exit\r")) {
        emitTo(terminal, { type: "exited", exitCode: 0, exitSignal: null });
      }
    },
  });
}

function emitTo(
  terminal: {
    threadId: string;
    terminalId: string;
    emit: (event: TerminalAttachStreamEvent) => void;
  },
  event: Record<string, unknown>,
) {
  terminal.emit({
    threadId: terminal.threadId,
    terminalId: terminal.terminalId,
    createdAt: "2026-07-13T00:00:00.000Z",
    ...event,
  } as unknown as TerminalAttachStreamEvent);
}

const state = (ctx: World) => ctx.host!.state.get("terminal") as TuiTerminalState;
const chunks = (ctx: World): TextChunk[][] =>
  state(ctx).lines.map((line) => (line as unknown as { chunks: TextChunk[] }).chunks);
const rowTexts = (ctx: World) => chunks(ctx).map((row) => row.map((c) => c.text).join(""));
const screen = (ctx: World) => rowTexts(ctx).join("\n");
const tabIds = (ctx: World) => state(ctx).tabs.map((tab) => tab.id);
const fakeTerminal = (ctx: World, terminalId: string) => {
  const terminal = ctx.fake!.terminals.get(`${THREAD_ID}:${terminalId}`);
  if (!terminal) throw new Error(`terminal ${terminalId} was never attached`);
  return terminal;
};
const calls = recorded;
/** Forget what was recorded for `method` so far (setup calls a Then should not see). */
const forget = (ctx: World, method: string) => {
  const list = ctx.fake!.calls;
  for (let i = list.length - 1; i >= 0; i -= 1) if (list[i]!.method === method) list.splice(i, 1);
};
const status = (ctx: World) => ctx.host!.state.get("status") as { kind: string; text: string };

async function emit(ctx: World, terminalId: string, event: Record<string, unknown>) {
  emitTo(fakeTerminal(ctx, terminalId), event);
  await settle(ctx);
}
const print = (ctx: World, data: string, terminalId = state(ctx).activeId!) =>
  emit(ctx, terminalId, { type: "output", data });
/** The active terminal of thread t1 prints `data` (keymap.steps.ts). */
export const printToTerminal = (ctx: World, data: string) => print(ctx, data);

/** Booted, connected, with the project's first thread selected. */
async function openThread(ctx: TerminalWorld) {
  if (ctx.app) return;
  useTerminalClient(ctx);
  await boot(ctx);
  ctx.fake!.connect();
  ctx.host!.dispatch("thread.open", { key: threadKey(THREAD_ID) });
  await settle(ctx);
}

/** The thread's drawer is open (with its default terminal) and focused. */
async function openDrawer(ctx: TerminalWorld) {
  await openThread(ctx);
  if (!state(ctx).open) await pressKey(ctx, "Ctrl+E");
  if (ctx.host!.state.get("mode") !== "terminal") ctx.host!.dispatch("terminal.focus.toggle");
  await settle(ctx);
  expect(state(ctx).open).toBe(true);
}

/** Run a terminal command from the palette (`chooseCommand` hands focus back first). */
async function runCommand(ctx: World, title: string) {
  await chooseCommand(ctx, title);
  await settle(ctx);
}

/** The palette's commands right now (opened and closed again to read them). */
async function paletteTitles(ctx: World): Promise<string[]> {
  if (ctx.host!.state.get("mode") === "terminal") await pressKey(ctx, "Ctrl+P");
  await pressKey(ctx, "Ctrl+K");
  const titles = palette(ctx).commands.map((item) => item.title);
  await pressKey(ctx, "Esc");
  return titles;
}

/** Open terminals until the thread has `count`, then activate `active`. */
async function haveTerminals(ctx: TerminalWorld, count: number, active?: number) {
  await openDrawer(ctx);
  while (state(ctx).tabs.length < count) await runCommand(ctx, "New terminal");
  if (active !== undefined) {
    ctx.host!.dispatch("terminal.select", { id: id(active) });
    await settle(ctx);
    expect(state(ctx).activeId).toBe(id(active));
  }
}

/** Exactly these numbered terminals (opened in order, the gaps closed). */
async function haveNumberedTerminals(ctx: TerminalWorld, numbers: number[], active?: number) {
  await haveTerminals(ctx, Math.max(...numbers));
  for (const tab of [...state(ctx).tabs]) {
    if (!numbers.includes(tab.number)) {
      ctx.host!.dispatch("terminal.close", { id: tab.id });
      await settle(ctx);
    }
  }
  forget(ctx, "terminalClose");
  expect(state(ctx).tabs.map((tab) => tab.number)).toEqual(numbers);
  if (active !== undefined) {
    ctx.host!.dispatch("terminal.select", { id: id(active) });
    await settle(ctx);
  }
}

const numbered = (lines: number, prefix = "line") =>
  Array.from(
    { length: lines },
    (_, index) => `${prefix}-${String(index + 1).padStart(3, "0")}`,
  ).join("\r\n");

async function scrolledBack(ctx: TerminalWorld) {
  await openDrawer(ctx);
  await print(ctx, numbered(120));
  await pressKey(ctx, "Shift+PgUp");
  await settle(ctx);
  expect(state(ctx).scrollNote).not.toBe("");
}

/** Scroll to the oldest line the emulator kept and return the top row. */
async function oldestLine(ctx: World): Promise<string> {
  let previous = "";
  for (;;) {
    ctx.host!.dispatch("terminal.scroll", { action: "page-up" });
    await settle(ctx);
    if (state(ctx).scrollNote === previous) break;
    previous = state(ctx).scrollNote;
  }
  return rowTexts(ctx)[0]!.trim();
}

const cursorChunks = (ctx: World) =>
  chunks(ctx)
    .flat()
    .filter(
      (chunk) => chunk.text === "█" || (chunk.bg !== undefined && chunk.bg.equals(THEME.accent)),
    );

// --- Opening, hiding and focus ---------------------------------------------

step("the terminal client is open on a thread in a project", openThread);
step("the terminal client shows a thread with its terminal open", openDrawer);
step("the terminal client shows a thread's terminal with focus", openDrawer);
step("the terminal client shows a terminal", openDrawer);
step("the terminal is open in the terminal client", openDrawer);
step("the terminal drawer has focus", openDrawer);
step("a thread with no terminal open in the terminal client", async (ctx: TerminalWorld) => {
  await openThread(ctx);
  expect(state(ctx).open).toBe(false);
});

step("the user opens the terminal drawer", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
});
step("the user opens the terminal", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
});
step("the user hides the terminal", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
});

step("the terminal drawer opens with one terminal", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(state(ctx)).toMatchObject({ open: true, focused: true, activeId: id(1) });
  expect(tabIds(ctx)).toEqual([id(1)]);
  expect(frame).toContain("Terminal · Thread one");
  expect(frame).toContain("▸ 1");
});

step("keys typed go to the shell", async (ctx: World) => {
  await typeText(ctx, "ls");
  await settle(ctx);
  expect(fakeTerminal(ctx, id(1)).writes.join("")).toBe("ls");
});

step("the terminal drawer is open with a long-running command", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, "$ bun run build\r\nbuilding…");
});

step("the drawer hides", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(state(ctx).open).toBe(false);
  expect(frame).not.toContain("Terminal · ");
});

async function shellKeepsRunning(ctx: World) {
  await settle(ctx);
  expect(calls(ctx, "terminalClose")).toEqual([]);
  expect(calls(ctx, "terminalRestart")).toEqual([]);
  // Showing it again reattaches to the same session and its output.
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
  expect(fakeTerminal(ctx, id(1)).attach).toMatchObject({ terminalId: id(1) });
}
step("the command keeps running", shellKeepsRunning);
step("the shell keeps running on the server", shellKeepsRunning);

// "the prompt has focus" (common.steps.ts) also checks the drawer let go.
step("focus returns to the prompt", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("compose");
  expect(state(ctx).focused).toBe(false);
});

step("pressing {string} again returns focus to the terminal", async (ctx: World, key: string) => {
  await pressKey(ctx, key);
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("terminal");
  expect(state(ctx).focused).toBe(true);
});

step("the thread's default terminal is shown with focus", async (ctx: World) => {
  await settle(ctx);
  expect(tabIds(ctx)).toEqual([id(1)]);
  expect(state(ctx)).toMatchObject({ open: true, focused: true });
});
step("it is attached to the thread's working folder", (ctx: World) => {
  expect(fakeTerminal(ctx, id(1)).attach).toMatchObject({ cwd: WORKSPACE, worktreePath: null });
});

// --- Replay ------------------------------------------------------------------

step(
  "the thread's terminal printed output while the drawer was closed",
  async (ctx: TerminalWorld) => {
    await openThread(ctx);
    // ~200 KiB: more than the replayed tail, less than the emulator's scrollback.
    const filler = Array.from({ length: 1000 }, (_, index) => `out-${index} ${"x".repeat(190)}`);
    ctx.history = { [id(1)]: ["EARLY-MARKER", ...filler, "LATEST-LINE"].join("\r\n") };
  },
);
step("the recent output is shown, bounded to the last part of the history", async (ctx: World) => {
  await settle(ctx);
  expect(screen(ctx)).toContain("LATEST-LINE");
  await oldestLine(ctx);
  // Lines wrap, so the first numbered row is the oldest line kept.
  const oldest = rowTexts(ctx).find((row) => /out-\d+|EARLY-MARKER/.test(row))!;
  expect(oldest).not.toContain("EARLY-MARKER");
  expect(Number(/out-(\d+)/.exec(oldest)?.[1])).toBeGreaterThan(300);
});

step("a terminal with several megabytes of history", async (ctx: TerminalWorld) => {
  await openThread(ctx);
  const lines = Array.from(
    { length: 30_000 },
    (_, index) => `history-${index + 1} ${"y".repeat(90)}`,
  );
  ctx.history = { [id(1)]: lines.join("\r\n") };
});
step("the terminal client shows it", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
});
step("the terminal client replays only the newest 128 KiB", async (ctx: World) => {
  const oldest = await oldestLine(ctx);
  const number = Number(/history-(\d+)/.exec(oldest)?.[1]);
  // 128 KiB of ~100-byte lines is about the last 1300 lines.
  expect(number).toBeGreaterThan(30_000 - 1400);
  ctx.host!.dispatch("terminal.scroll", { action: "bottom" });
  await settle(ctx);
});
step("the terminal shows the latest screen quickly", async (ctx: World) => {
  const started = performance.now();
  await settle(ctx);
  expect(screen(ctx)).toContain("history-30000");
  expect(performance.now() - started).toBeLessThan(1000);
});

step("the thread's terminal shell has exited", async (ctx: TerminalWorld) => {
  await openThread(ctx);
  ctx.history = { [id(1)]: "$ exit\r\n[process exited]\r\n" };
});
step("the user opens that terminal in the terminal client", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
});
step("a new shell starts in the thread's folder", (ctx: World) => {
  // Attaching asks the MC to restart a shell that is not running
  // (`restartIfNotRunning` in the real client) in the thread's folder.
  expect(fakeTerminal(ctx, id(1)).attach).toMatchObject({
    threadId: THREAD_ID,
    terminalId: id(1),
    cwd: WORKSPACE,
  });
  expect(calls(ctx, "terminalRestart")).toEqual([]);
});

// --- Tabs --------------------------------------------------------------------

step("the terminal drawer has one terminal", (ctx: TerminalWorld) => haveTerminals(ctx, 1));
step("the terminal drawer is open with one terminal", (ctx: TerminalWorld) =>
  haveTerminals(ctx, 1),
);
step("the thread has one terminal", (ctx: TerminalWorld) => haveTerminals(ctx, 1));
step("the thread has two terminals", async (ctx: TerminalWorld) => {
  await haveTerminals(ctx, 2);
  expect(tabIds(ctx)).toHaveLength(2);
});
step("the thread has six terminals", (ctx: TerminalWorld) => haveTerminals(ctx, 6));
step(
  /^the thread has (two|three) terminals with the (first|second|third) active$/,
  (ctx: TerminalWorld, count: string, active: string) =>
    haveTerminals(ctx, count === "two" ? 2 : 3, ORDINALS[active]),
);
step(
  /^the thread has terminals ((?:\d+, )*\d+ and \d+)(?: with terminal (\d+) active)?$/,
  (ctx: TerminalWorld, list: string, active?: string) =>
    haveNumberedTerminals(
      ctx,
      list.split(/, | and /).map(Number),
      active ? Number(active) : undefined,
    ),
);
step("the terminal client shows terminal {int} for the thread", (ctx: TerminalWorld, n: number) =>
  haveNumberedTerminals(ctx, [n]),
);
step(
  "the terminal client shows terminals {int} and {int} for the thread",
  (ctx: TerminalWorld, a: number, b: number) => haveNumberedTerminals(ctx, [a, b]),
);
step("terminal {int} is active", async (ctx: TerminalWorld, n: number) => {
  // As a Given it activates the terminal; as a Then it checks.
  if (!ctx.acted) ctx.host!.dispatch("terminal.select", { id: id(n) });
  await settle(ctx);
  expect(state(ctx).activeId).toBe(id(n));
});

step("the user opens a new terminal", (ctx: World) => runCommand(ctx, "New terminal"));

step("a second terminal tab opens and becomes active", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(tabIds(ctx)).toEqual([id(1), id(2)]);
  expect(state(ctx).activeId).toBe(id(2));
  expect(frame).toContain("▸ 2");
});
step("the new terminal is the active one", (ctx: World) => {
  expect(state(ctx).activeId).toBe(tabIds(ctx).at(-1)!);
});
step("the new terminal is number {int}", (ctx: World, n: number) => {
  expect(state(ctx).tabs.at(-1)).toMatchObject({ number: n, active: true });
});
step("no terminal opens", (ctx: World) => {
  expect(tabIds(ctx)).toHaveLength(6);
});
step("no terminal is added", (ctx: World) => {
  expect(tabIds(ctx)).toHaveLength(6);
});

step(
  /^the user (?:switches|moves) to the (next|previous) terminal$/,
  (ctx: TerminalWorld, direction: string) => {
    ctx.acted = true;
    return runCommand(ctx, direction === "next" ? "Next terminal" : "Previous terminal");
  },
);
step(
  /^the (first|second|third) terminal is (?:still )?active$/,
  async (ctx: World, which: string) => {
    await settle(ctx);
    expect(state(ctx).activeId).toBe(id(ORDINALS[which]!));
  },
);
step("the last remaining terminal is active", (ctx: World) => {
  expect(tabIds(ctx)).toEqual([id(1), id(3)]);
  expect(state(ctx).activeId).toBe(id(3));
});

step("the user is not offered next or previous terminal", async (ctx: World) => {
  const titles = await paletteTitles(ctx);
  expect(titles).not.toContain("Next terminal");
  expect(titles).not.toContain("Previous terminal");
});

step("two terminals are running commands", async (ctx: TerminalWorld) => {
  await haveTerminals(ctx, 2);
  await print(ctx, "first-build-output", id(1));
  await print(ctx, "second-build-output", id(2));
});
step("the user switches from one tab to the other and back", async (ctx: World) => {
  for (const target of [id(1), id(2)]) {
    ctx.host!.dispatch("terminal.select", { id: target });
    await settle(ctx);
  }
});
step("both terminals show their output without a replay", async (ctx: World) => {
  for (const [target, output] of [
    [id(1), "first-build-output"],
    [id(2), "second-build-output"],
  ] as const) {
    ctx.host!.dispatch("terminal.select", { id: target });
    await settle(ctx);
    expect(screen(ctx)).toContain(output);
    expect(fakeTerminal(ctx, target).attachCount).toBe(1);
  }
});

step("terminal 2 is running a build while terminal 1 is active", async (ctx: TerminalWorld) => {
  await haveTerminals(ctx, 2, 1);
  for (let index = 1; index <= 5; index += 1) await print(ctx, `build step ${index}\r\n`, id(2));
});
step("the user switches to terminal {int}", async (ctx: World, n: number) => {
  ctx.host!.dispatch("terminal.select", { id: id(n) });
  await settle(ctx);
});
step(
  "terminal 2 shows everything the build printed while it was in the background",
  (ctx: World) => {
    for (let index = 1; index <= 5; index += 1)
      expect(screen(ctx)).toContain(`build step ${index}`);
    expect(fakeTerminal(ctx, id(2)).attachCount).toBe(1);
  },
);

async function closeActive(ctx: TerminalWorld) {
  ctx.acted = true;
  await runCommand(ctx, "Close terminal");
}
step("the user closes the active terminal", closeActive);
step("the user closes it", closeActive);
step(
  /^the user closes (?:the third terminal|terminal (\d+))$/,
  async (ctx: TerminalWorld, n?: string) => {
    ctx.acted = true;
    // The tab's ✕.
    ctx.host!.dispatch("terminal.close", { id: id(n ? Number(n) : 3) });
    await settle(ctx);
  },
);
step("terminal 2's shell stops on the server", (ctx: World) => {
  expect(calls(ctx, "terminalClose")).toEqual([[THREAD_ID, id(2)]]);
});
step("the terminal drawer closes", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(state(ctx).open).toBe(false);
  expect(frame).not.toContain("Terminal · ");
  expect(calls(ctx, "terminalClose")).toEqual([[THREAD_ID, id(1)]]);
});
step("the terminal is hidden", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(state(ctx).open).toBe(false);
  expect(frame).not.toContain("Terminal · ");
});

async function otherClientOpens(ctx: World, n: number) {
  ctx.fake!.emitTerminalMetadata({
    type: "upsert",
    terminal: { threadId: THREAD_ID, terminalId: id(n) },
  } as never);
  await settle(ctx);
}
async function otherClientCloses(ctx: World, n: number) {
  ctx.fake!.emitTerminalMetadata({
    type: "remove",
    threadId: THREAD_ID,
    terminalId: id(n),
  } as never);
  await settle(ctx);
}
step("another client opens a terminal on the same thread", (ctx: World) =>
  otherClientOpens(ctx, 2),
);
step("another client opens terminal {int} on the same thread", otherClientOpens);
step("another client closes the second terminal", (ctx: World) => otherClientCloses(ctx, 2));
step("another client closes terminal {int}", otherClientCloses);

step("a second tab appears and the active tab does not change", (ctx: World) => {
  expect(tabIds(ctx)).toEqual([id(1), id(2)]);
  expect(state(ctx).activeId).toBe(id(1));
});
step("terminal 2 appears next to terminal 1", (ctx: World) => {
  expect(state(ctx).tabs.map((tab) => tab.number)).toEqual([1, 2]);
});
step("terminal 1 stays active", (ctx: World) => {
  expect(state(ctx).activeId).toBe(id(1));
});
step("its tab disappears", (ctx: World) => {
  expect(tabIds(ctx)).toEqual([id(1)]);
});
step("only terminal 1 remains", (ctx: World) => {
  expect(tabIds(ctx)).toEqual([id(1)]);
  expect(state(ctx).open).toBe(true);
});

// --- Palette actions ------------------------------------------------------------

step(
  /^only the second terminal is (cleared|restarted with a fresh shell|closed)$/,
  (ctx: World, result: string) => {
    const name =
      result === "cleared"
        ? "terminalClear"
        : result === "closed"
          ? "terminalClose"
          : "terminalRestart";
    const recorded = calls(ctx, name);
    expect(recorded).toHaveLength(1);
    if (name === "terminalRestart") {
      expect(recorded[0]![0]).toMatchObject({
        threadId: THREAD_ID,
        terminalId: id(2),
        cwd: WORKSPACE,
      });
    } else {
      expect(recorded[0]).toEqual([THREAD_ID, id(2)]);
    }
    if (result === "closed") expect(tabIds(ctx)).toEqual([id(1)]);
  },
);

step(
  "the user runs {string} from the command palette",
  async (ctx: TerminalWorld, title: string) => {
    // Hold the MC's answer so the progress message can be seen.
    const gate = deferred();
    (ctx.gates ??= []).push(gate);
    ctx.overrides = {
      ...ctx.overrides,
      terminalClear: () => gate.promise,
      terminalRestart: () => gate.promise,
    };
    // Not `runCommand`: its settle would wait on the held answer.
    await chooseCommand(ctx, title);
    await ctx.app!.snapshot();
  },
);
step("then {string}", async (ctx: TerminalWorld, text: string) => {
  for (const gate of ctx.gates ?? []) gate.resolve();
  const frame = await settle(ctx);
  expect(status(ctx).text).toBe(text);
  expect(frame).toContain(text);
});

// --- Screen: output, clearing, scrolling ---------------------------------------

step("the terminal shows output", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, "stale-output-line");
  expect(screen(ctx)).toContain("stale-output-line");
});
step("the session is cleared from any client", (ctx: World) =>
  emit(ctx, state(ctx).activeId!, { type: "cleared" }),
);
step("the old output disappears from the drawer", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(screen(ctx)).not.toContain("stale-output-line");
  expect(frame).not.toContain("stale-output-line");
});

step("the terminal has more output than fits", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, numbered(120));
});
step("the terminal has more output than fits on screen", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, numbered(120));
});
step("the user scrolls the terminal up a page", async (ctx: World) => {
  await pressKey(ctx, "Shift+PgUp");
  await settle(ctx);
});

async function olderOutputShown(ctx: World) {
  const frame = await settle(ctx);
  expect(screen(ctx)).not.toContain("line-120");
  expect(screen(ctx)).toMatch(/line-0\d\d/);
  expect(state(ctx).scrollNote).toMatch(/^▲ scrollback −\d+\/\d+/);
  expect(frame).toContain("▲ scrollback −");
}
async function cursorHidden(ctx: World) {
  await settle(ctx);
  expect(cursorChunks(ctx)).toEqual([]);
}
step("older output is shown and the cursor is hidden", async (ctx: World) => {
  await olderOutputShown(ctx);
  await cursorHidden(ctx);
});
step("older output is shown with a note of how far back it is", olderOutputShown);
step("the cursor is hidden while viewing history", cursorHidden);

step("the user scrolled back in the terminal", scrolledBack);
step("the user has scrolled the terminal back into its history", scrolledBack);
step("the terminal is scrolled back to earlier output", scrolledBack);
step("the user scrolled back and output is still arriving", async (ctx: TerminalWorld) => {
  await scrolledBack(ctx);
  ctx.readingScreen = screen(ctx);
  await print(ctx, `\r\n${numbered(30, "late")}`);
});

step("the user types a key", async (ctx: World) => {
  await typeText(ctx, "x");
  await settle(ctx);
});
step("the terminal shows the live output again", async (ctx: World) => {
  await settle(ctx);
  expect(state(ctx).scrollNote).toBe("");
  expect(screen(ctx)).toContain("line-120");
});
step("{string} reaches the shell", (ctx: World, text: string) => {
  expect(fakeTerminal(ctx, state(ctx).activeId!).writes.join("")).toContain(text);
});
step("the key reaches the shell", (ctx: World) => {
  expect(fakeTerminal(ctx, state(ctx).activeId!).writes.join("")).toBe("x");
});

step("the shell prints more output", async (ctx: TerminalWorld) => {
  ctx.readingScreen = screen(ctx);
  await print(ctx, `\r\n${numbered(30, "late")}`);
});
step("the lines the user was reading stay on screen", (ctx: TerminalWorld) => {
  expect(screen(ctx)).toBe(ctx.readingScreen!);
});

step("a pager is running in the terminal", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, `${numbered(120)}\r\n(END)`);
});
// tui/launch.feature: the global keymap steps aside in the drawer, so ^C is the program's.
step("a terminal tab has focus", openDrawer);
step("the running shell program receives the interrupt", async (ctx: World) => {
  await settle(ctx);
  expect(fakeTerminal(ctx, state(ctx).activeId!).writes).toEqual(["\x03"]);
});
step("the terminal client stays open", (ctx: World) => {
  expect(ctx.quitRequested ?? false).toBe(false);
  expect(ctx.host!.state.get("mode")).toBe("terminal");
});

step("the pager receives the key", async (ctx: World) => {
  await settle(ctx);
  expect(fakeTerminal(ctx, state(ctx).activeId!).writes).toEqual(["\x1b[5~"]);
  expect(state(ctx).scrollNote).toBe("");
});

// --- Typing, pasting, copying ------------------------------------------------------

step("the user types {string} and presses Enter", async (ctx: World, text: string) => {
  await typeText(ctx, text);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});
step("the shell runs {string}", (ctx: World, command: string) => {
  expect(fakeTerminal(ctx, state(ctx).activeId!).writes.join("")).toBe(`${command}\r`);
});
step("the terminal shows {string}", async (ctx: World, text: string) => {
  const frame = await settle(ctx);
  expect(screen(ctx)).toContain(text);
  expect(frame).toContain(text);
});
step("the MC reports the terminal error {string}", (ctx: World, message: string) =>
  emit(ctx, state(ctx).activeId!, { type: "error", message }),
);

const BRACKETED_PASTE_ON = "\x1b[?2004h";
step("the shell has bracketed paste on", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, BRACKETED_PASTE_ON);
});
step("the running program asked for bracketed paste", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, BRACKETED_PASTE_ON);
});
step("the running program did not ask for bracketed paste", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, "$ ");
});

/**
 * A paste event carrying exactly `text`. The test renderer's bracketed paste
 * would end at an embedded end marker, as the stdin parser does; a host
 * terminal that passes pasted escapes through delivers them inside the event.
 */
async function pasteEvent(ctx: World, text: string) {
  ctx.app!.renderer.keyInput.emit("paste", new PasteEvent(new TextEncoder().encode(text)));
  await settle(ctx);
}

const pasted = (ctx: World) => fakeTerminal(ctx, state(ctx).activeId!).writes;
async function pasteText(ctx: World, text: string) {
  await paste(ctx, text);
  await settle(ctx);
}
step("the user pastes two lines of text", (ctx: World) => pasteText(ctx, "echo one\necho two"));
step(
  "the program receives both lines as one paste and does not run them line by line",
  (ctx: World) => {
    expect(pasted(ctx)).toEqual(["\x1b[200~echo one\necho two\x1b[201~"]);
  },
);
step(
  /^the user pastes text that contains an? (?:bracketed paste end|end-of-paste) marker(?: followed by a command)?$/,
  (ctx: World) => pasteEvent(ctx, "echo safe\x1b[201~rm -rf ~\r"),
);
function markerRemoved(ctx: World) {
  expect(pasted(ctx)).toEqual(["\x1b[200~echo saferm -rf ~\r\x1b[201~"]);
}
step("the end marker is removed before the text reaches the shell", markerRemoved);
step("the marker is removed", markerRemoved);
step("the command is not run as if typed", (ctx: World) => {
  // The command stays inside the one paste frame: nothing follows its end marker.
  const [write] = pasted(ctx);
  expect(write!.endsWith("\x1b[201~")).toBe(true);
  expect(write!.split("\x1b[201~")).toEqual([expect.stringContaining("rm -rf"), ""]);
});
// Into whatever has focus: the terminal's program, or the prompt (which
// remembers what it held, for composer.steps.ts' outcomes).
step("the user pastes {string}", (ctx: World & { textBeforePaste?: string }, text: string) => {
  const prompt = ctx.host?.state.get("composer") as { text: string } | undefined;
  if (prompt) ctx.textBeforePaste = prompt.text;
  return pasteText(ctx, text);
});
step("the program receives {string} unchanged", (ctx: World, text: string) => {
  expect(pasted(ctx)).toEqual([text]);
});

async function copy(ctx: World) {
  await pressKey(ctx, "Ctrl+O");
  await settle(ctx);
}
step("the user copies the terminal", copy);
step("the user presses {string} in the terminal", async (ctx: TerminalWorld, key: string) => {
  await openDrawer(ctx);
  await pressKey(ctx, key);
  await settle(ctx);
});
step("the terminal shows three lines of output", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  await print(ctx, "one\r\ntwo\r\nthree");
});
step("the three visible lines are on the clipboard without trailing blank lines", (ctx: World) => {
  expect(ctx.clipboard).toEqual(["one\ntwo\nthree"]);
});
step("the terminal shows no output", openDrawer);
step("the terminal is empty", openDrawer);
async function noClipboard(ctx: TerminalWorld) {
  await openDrawer(ctx);
  await print(ctx, "something to copy");
  ctx.clipboardSupported = false;
}
// With output on screen, unlike git.steps' "does not support OSC 52" (the flag only).
step("the user's terminal does not support clipboard writes", noClipboard);

function copiedScrolledBackView(ctx: World) {
  expect(ctx.clipboard).toHaveLength(1);
  const copied = ctx.clipboard![0]!;
  // What is on screen (the scroll note takes the place of the last row), up to
  // its last non-blank row and without the live cursor's block.
  const onScreen = rowTexts(ctx)
    .map((row) => row.trimEnd().replace(/█$/, "").trimEnd())
    .join("\n")
    .replace(/\n+$/, "");
  expect(onScreen.length).toBeGreaterThan(0);
  expect(copied.startsWith(onScreen)).toBe(true);
  expect(copied).not.toContain("line-120");
  expect(copied).not.toContain("late-");
}
step("the visible terminal text is copied to the clipboard", async (ctx: World) => {
  await settle(ctx);
  copiedScrolledBackView(ctx);
});
step("the clipboard holds the older lines on screen, not the live tail", copiedScrolledBackView);
step("the copied text is the scrolled-back view, not the live tail", (ctx: TerminalWorld) => {
  copiedScrolledBackView(ctx);
  expect(screen(ctx)).toBe(ctx.readingScreen!);
});

// --- Resizing -------------------------------------------------------------------

step("the user makes their terminal window wider", async (ctx: TerminalWorld) => {
  // A second terminal in the background, to see when it learns the size.
  await haveTerminals(ctx, 2, 1);
  forget(ctx, "terminalResize");
  await resize(ctx, ctx.columns! + 20);
  await settle(ctx);
});
step("the visible terminal's shell is told its new size", (ctx: World) => {
  expect(calls(ctx, "terminalResize")).toEqual([
    [THREAD_ID, id(1), state(ctx).cols, state(ctx).rows],
  ]);
});
step("background terminals are resized only when they are shown", async (ctx: World) => {
  ctx.host!.dispatch("terminal.select", { id: id(2) });
  await settle(ctx);
  expect(calls(ctx, "terminalResize").at(-1)).toEqual([
    THREAD_ID,
    id(2),
    state(ctx).cols,
    state(ctx).rows,
  ]);
  expect(calls(ctx, "terminalResize")).toHaveLength(2);
});

// --- Failures ----------------------------------------------------------------------

step(
  /^(clearing it|restarting it|listing its terminals) fails with "([^"]*)"$/,
  async (ctx: TerminalWorld, action: string, reason: string) => {
    const fail = () => Promise.reject(new Error(reason));
    if (action === "clearing it") {
      ctx.overrides = { ...ctx.overrides, terminalClear: fail };
      await runCommand(ctx, "Clear terminal");
    } else if (action === "restarting it") {
      ctx.overrides = { ...ctx.overrides, terminalRestart: fail };
      await runCommand(ctx, "Restart terminal");
    } else {
      // Terminals are listed when a thread is opened.
      ctx.overrides = { ...ctx.overrides, listTerminalIds: fail };
      ctx.host!.dispatch("thread.open", { key: threadKey("t2") });
      await settle(ctx);
    }
  },
);

step(
  "the terminal client shows terminal 2, which the MC no longer has",
  async (ctx: TerminalWorld) => {
    await haveTerminals(ctx, 2, 2);
    ctx.overrides = {
      ...ctx.overrides,
      terminalClose: () => Promise.reject(new Error("Unknown terminal")),
    };
  },
);
step("terminal 2 disappears without an error", async (ctx: World) => {
  await settle(ctx);
  expect(tabIds(ctx)).toEqual([id(1)]);
  expect(status(ctx).kind).not.toBe("error");
});

// --- Colours, cursor, styles, links ---------------------------------------------------

const chunkWith = (ctx: World, text: string) => {
  const chunk = chunks(ctx)
    .flat()
    .find((candidate) => candidate.text.includes(text));
  if (!chunk) throw new Error(`"${text}" is not on the terminal screen:\n${screen(ctx)}`);
  return chunk;
};

async function printAndShow(ctx: TerminalWorld, data: string) {
  await openDrawer(ctx);
  await print(ctx, data);
}

step("the shell prints text in ANSI colours and in truecolor", (ctx: TerminalWorld) =>
  printAndShow(ctx, "\x1b[31mansi-red\x1b[0m \x1b[38;2;18;52;86mexact-blue\x1b[0m"),
);
step("ANSI colours use the user's terminal palette", (ctx: World) => {
  const fg = chunkWith(ctx, "ansi-red").fg!;
  expect(fg.intent).toBe("indexed");
  expect(fg.slot).toBe(1);
});
step("truecolor text keeps its exact colour", (ctx: World) => {
  const fg = chunkWith(ctx, "exact-blue").fg!;
  expect(fg.intent).toBe("rgb");
  expect(fg.toInts().slice(0, 3)).toEqual([18, 52, 86]);
});

const COLOUR_SAMPLES: Record<string, string> = {
  "an ANSI palette colour": "\x1b[32msample-text\x1b[0m",
  "an exact 24-bit colour": "\x1b[38;2;250;128;114msample-text\x1b[0m",
  "the default colour": "sample-text",
};
step(/^a program prints text in (.+)$/, async (ctx: TerminalWorld, colour: string) => {
  await openThread(ctx);
  ctx.history = { [id(1)]: COLOUR_SAMPLES[colour]! };
});
step("the terminal client shows the terminal", openDrawer);
step(/^the text is drawn in (.+)$/, (ctx: World, drawn: string) => {
  const fg = chunkWith(ctx, "sample-text").fg!;
  if (drawn.startsWith("the user's own terminal theme")) {
    expect([fg.intent, fg.slot]).toEqual(["indexed", 2]);
  } else if (drawn === "that exact colour") {
    expect(fg.intent).toBe("rgb");
    expect(fg.toInts().slice(0, 3)).toEqual([250, 128, 114]);
  } else {
    expect(fg.intent).toBe("default");
  }
});

step("the shell cursor is on a blank cell or over text", (ctx: TerminalWorld) =>
  printAndShow(ctx, "$ "),
);
step("the cursor is drawn as a visible block", async (ctx: World) => {
  // On a blank cell: a block glyph.
  expect(chunkWith(ctx, "█").fg!.equals(THEME.accent)).toBe(true);
  // Over text: the character on a cursor-coloured background.
  await print(ctx, "abc\x1b[2D");
  const over = chunks(ctx)
    .flat()
    .find((chunk) => chunk.bg?.equals(THEME.accent));
  expect(over?.text).toBe("b");
});
step("the shell's prompt is waiting at an empty cell", (ctx: TerminalWorld) =>
  printAndShow(ctx, "$ "),
);
step("the terminal client shows a solid cursor block there", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(rowTexts(ctx)[0]).toStartWith("$ █");
  expect(frame).toContain("$ █");
  expect(chunkWith(ctx, "█").fg!.equals(THEME.accent)).toBe(true);
});
step("the cursor is dimmed while the terminal does not have focus", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+P");
  await settle(ctx);
  expect(chunkWith(ctx, "█").fg!.equals(THEME.faint)).toBe(true);
});

step("a program prints bold, italic, underlined and reversed text", (ctx: TerminalWorld) =>
  printAndShow(
    ctx,
    "\x1b[1mBOLD\x1b[0m \x1b[3mITALIC\x1b[0m \x1b[4mUNDER\x1b[0m \x1b[7mREVERSE\x1b[0m",
  ),
);
step("the terminal client shows each style", async (ctx: World) => {
  const { TextAttributes } = await import("@opentui/core");
  expect(chunkWith(ctx, "BOLD").attributes! & TextAttributes.BOLD).toBeTruthy();
  expect(chunkWith(ctx, "ITALIC").attributes! & TextAttributes.ITALIC).toBeTruthy();
  expect(chunkWith(ctx, "UNDER").attributes! & TextAttributes.UNDERLINE).toBeTruthy();
  // Reversed: the default colours swap.
  const reversed = chunkWith(ctx, "REVERSE");
  expect(reversed.fg!.equals(THEME.bg)).toBe(true);
  expect(reversed.bg!.equals(THEME.text)).toBe(true);
});

const linked = (ctx: World) =>
  chunks(ctx)
    .flat()
    .filter((chunk) => chunk.link !== undefined);

step("the shell prints {string}", (ctx: TerminalWorld, text: string) => printAndShow(ctx, text));
step("only {string} is a link", (ctx: World, url: string) => {
  expect(linked(ctx).map((chunk) => chunk.text)).toEqual([url]);
});
step("following it opens {string}", (ctx: World, url: string) => {
  expect(linked(ctx).map((chunk) => chunk.link!.url)).toEqual([url]);
});

const WRAPPING_URL = `https://example.com/${"a".repeat(60)}/${"b".repeat(60)}`;
async function printWrappingUrl(ctx: TerminalWorld) {
  await openDrawer(ctx);
  await print(ctx, `see ${WRAPPING_URL} now`);
  expect(WRAPPING_URL.length).toBeGreaterThan(state(ctx).cols);
}
function everyPieceOpensUrl(ctx: World) {
  const rows = chunks(ctx).filter((row) => row.some((chunk) => chunk.link));
  expect(rows.length).toBeGreaterThanOrEqual(2);
  for (const row of rows) {
    for (const chunk of row.filter((candidate) => candidate.link)) {
      expect(chunk.link!.url).toBe(WRAPPING_URL);
    }
  }
  expect(
    linked(ctx)
      .map((chunk) => chunk.text)
      .join(""),
  ).toBe(WRAPPING_URL);
}
step("the terminal printed a URL that wraps across two rows", printWrappingUrl);
step("the shell prints a web address longer than the terminal is wide", printWrappingUrl);
step("clicking either row opens the complete URL", everyPieceOpensUrl);
step("every visible piece of it opens the complete address", everyPieceOpensUrl);

step("the shell prints Chinese text followed by a web address", (ctx: TerminalWorld) =>
  printAndShow(ctx, "你好世界 https://example.com/中 end"),
);
step("the link covers exactly the address", (ctx: World) => {
  expect(linked(ctx).map((chunk) => chunk.text)).toEqual(["https://example.com/中"]);
});

step("the shell prints a web address longer than 4 KiB", (ctx: TerminalWorld) =>
  printAndShow(ctx, `https://example.com/${"x".repeat(5 * 1024)}`),
);
step("the shell prints a single line longer than 64 KiB with an address", (ctx: TerminalWorld) =>
  printAndShow(ctx, `${"z".repeat(65 * 1024)} https://example.com/short`),
);
step("no link is created for it", (ctx: World) => {
  expect(linked(ctx)).toEqual([]);
});

// The drawer's look (ThreadTerminalDrawer): the rows inside its border.
async function drawerInner(ctx: World): Promise<Rect> {
  await settle(ctx);
  const { x, y, width, height } = rectOf(ctx, "terminalDrawer");
  return { x: x + 2, y: y + 1, width: width - 4, height: height - 2 };
}

step("the thread is titled {string}", async (ctx: TerminalWorld, title: string) => {
  const threads = shell().threads.map((thread) =>
    thread.id === THREAD_ID ? { ...thread, title } : thread,
  );
  ctx.fake!.emitShell(shell(threads as never));
  const detail = ctx.fake!.currentThread(THREAD_ID);
  if (detail) ctx.fake!.emitThread({ ...detail, title });
  await settle(ctx);
});

step(
  /^the drawer's (first|second) row reads "(.*)"$/,
  async (ctx: World, ordinal: string, text: string) => {
    const rows = await regionRows(ctx, await drawerInner(ctx));
    expect(rows[ordinal === "first" ? 0 : 1]!.trimEnd()).toBe(text);
  },
);

step(
  /^"(.*)" is in the (accent|warning) colour and the rest in the dim colour$/,
  async (ctx: World, label: string, colour: keyof Palette) => {
    const inner = await drawerInner(ctx);
    const header = { ...inner, height: 1 };
    const found = await textWithin(ctx, header, label);
    expectColour(found.span.fg, THEME[colour]);
    const rest = await textWithin(ctx, header, " · ^");
    expect(rest.x).toBe(found.x + label.length);
    expectColour(rest.span.fg, THEME.dim);
  },
);

step(
  "the tab marker {string} is in the accent colour and its number in the text colour",
  async (ctx: World, marker: string) => {
    const tabs = { ...(await drawerInner(ctx)), height: 2 };
    const found = await textWithin(ctx, tabs, `${marker} `);
    expectColour(found.span.fg, THEME.accent);
    const active = state(ctx).tabs.find((tab) => tab.active)!;
    const number = await textWithin(ctx, { ...tabs, x: found.x + 1 }, ` ${active.number}`);
    expect(number.x).toBe(found.x + 1);
    expectColour(number.span.fg, THEME.text);
  },
);

step("the other tab's number is in the dim colour", async (ctx: World) => {
  const inner = await drawerInner(ctx);
  const tabRow = { ...inner, y: inner.y + 1, height: 1 };
  const other = state(ctx).tabs.find((tab) => !tab.active)!;
  const number = await textWithin(ctx, tabRow, `  ${other.number}`);
  expectColour(number.span.fg, THEME.dim);
});
