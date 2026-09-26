// The terminal keymap (features/tui/keymap.feature): which chord reaches which
// host action in which mode. Outcomes owned by another area (the terminal
// drawer, the source-control panel, approvals) are checked as "the chord
// reached the action and the host handled it"; that area's own feature checks
// what the action does.
import { expect } from "bun:test";

import type { OrchestrationThread } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import {
  boundChords,
  KEYMAP_LAYERS,
  type KeymapParityRow,
  type KeyBindingGroup,
} from "../../../src/keymap.ts";
import type { TuiPaletteState } from "../../../src/host/paletteState.ts";
import { shell, thread } from "../fakeClient.ts";
import { shownText } from "../threadWorld.ts";
import { findObject, geometry, pressKey, settle, snapshot, type World } from "../world.ts";
import {
  callsTo,
  composer,
  openOnThread,
  running,
  typeIntoPrompt,
  type ComposerWorld,
} from "./composer.steps.ts";
import { newThread, runPaletteCommand, select } from "./controls.steps.ts";
import { printToTerminal } from "./terminal.steps.ts";

interface KeymapWorld extends ComposerWorld {
  /** The selected thread before a chord, to prove where the selection moved. */
  threadBefore?: string;
  paletteIndexBefore?: number;
  rowsBefore?: number;
  modeBefore?: string;
  parityAction?: string;
  /** Set by "the diff viewer is open" (timeline.steps.ts). */
  diffViewBefore?: string;
}

const keybindings = (ctx: World) =>
  ctx.host!.state.get("keybindings") as {
    layers: typeof KEYMAP_LAYERS;
    groups: ReadonlyArray<KeyBindingGroup>;
    parity: ReadonlyArray<KeymapParityRow>;
  };
const parityRow = (ctx: World, action: string) => {
  const row = keybindings(ctx).parity.find((candidate) => candidate.action === action);
  expect(row).toBeDefined();
  return row!;
};
const palette = (ctx: World) => ctx.host!.state.get("palette") as TuiPaletteState;
const page = (ctx: World) => ctx.host!.state.get("page") as { kind: string; threadId?: string };
const mode = (ctx: World) => ctx.host!.state.get("mode") as string;

/** Threads in list order (newest first): t1, t2, t3, t4. */
const FOUR_THREADS = [1, 2, 3, 4].map((n) => ({
  id: `t${n}`,
  projectId: "p1",
  title: `Thread ${n}`,
  updatedAt: `2026-07-13T00:00:0${9 - n}.000Z`,
  session: { status: "idle" },
}));

async function openOnFourThreads(ctx: KeymapWorld): Promise<void> {
  await openOnThread(ctx, thread(), { shellSnapshot: shell(FOUR_THREADS as never) });
  for (const { id, title } of FOUR_THREADS.slice(1)) {
    ctx.fake!.emitThread({ ...thread(), id, title } as unknown as OrchestrationThread);
  }
  await settle(ctx);
}

async function ensureRunning(ctx: KeymapWorld): Promise<void> {
  if (!ctx.host) await openOnThread(ctx);
}

/** The chord reached `action` and the host handled it (no "unknown action" log). */
function handled(ctx: World, action: string): void {
  expect(ctx.dispatched!.map((entry) => entry.action)).toContain(action);
  expect(ctx.logs ?? []).not.toContain(`hal-c2 tui: unknown shell action "${action}"`);
}

// --- Parity with the web app -------------------------------------------------

step(
  /^the web app binds "([^"]+)" to (.+)$/,
  async (ctx: KeymapWorld, action: string, web: string) => {
    await ensureRunning(ctx);
    expect(parityRow(ctx, action).webKeys).toBe(web);
  },
);

step(
  /^the terminal client binds "([^"]+)" to (.+)$/,
  async (ctx: KeymapWorld, action: string, keys: string) => {
    const row = parityRow(ctx, (ctx.parityAction = action));
    expect(row.keys).toBe(keys);
    const compose = boundChords({ compose: keybindings(ctx).layers.compose });
    for (const chord of row.chords) expect(compose).toContain(chord);
    // The first chord, pressed from the prompt, reaches the row's action.
    ctx.dispatched!.length = 0;
    await pressKey(
      ctx,
      row.chords[0]!.replace(/(^|\+)(\w)/g, (_, sep, c) => sep + c.toUpperCase()),
    );
    await settle(ctx);
    expect(ctx.dispatched![0]?.action).toBe(row.hostAction);
  },
);

step("the parity status is {word}", (ctx: KeymapWorld, status: string) => {
  expect(parityRow(ctx, ctx.parityAction!).status).toBe(status as KeymapParityRow["status"]);
});

// --- From the prompt ---------------------------------------------------------

// "the prompt has focus" (common.steps.ts) boots on a thread as a Given.

step("the prompt has focus on a thread", async (ctx: KeymapWorld) => {
  await openOnFourThreads(ctx);
  // Start on the second thread so both directions have somewhere to go.
  await pressKey(ctx, "Alt+Down");
  await settle(ctx);
  expect(page(ctx).threadId).toBe("t2");
  await typeIntoPrompt(ctx, "Carry on");
  ctx.threadBefore = page(ctx).threadId!;
  ctx.rowsBefore = composer(ctx).rows;
  ctx.modeBefore = composer(ctx).interactionMode;
  ctx.dispatched!.length = 0;
});

step("the command palette opens", async (ctx: World) => {
  await settle(ctx);
  expect(palette(ctx).open).toBe(true);
  expect(mode(ctx)).toBe("command");
  expect(geometry(findObject(ctx, "commandPalette")).visible).toBe(true);
});

step("a new-thread draft opens", async (ctx: World) => {
  await settle(ctx);
  expect(newThread(ctx)).not.toBeNull();
});

step("the thread filter opens", async (ctx: World) => {
  await settle(ctx);
  expect(mode(ctx)).toBe("filter");
  expect(findObject(ctx, "sidebarFilter").get("focus")).toBe(true);
});

step("the source-control panel toggles", async (ctx: World) => {
  await settle(ctx);
  handled(ctx, "rightPanel.toggle");
});

step("the terminal drawer toggles", async (ctx: World) => {
  await settle(ctx);
  handled(ctx, "terminal.toggle");
});

step("the terminal client quits", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.quitRequested).toBe(true);
});

const THREAD_AT = { next: "t3", previous: "t1", third: "t3" } as const;

step(
  /^the (next|previous|third) thread in the list is selected$/,
  async (ctx: World, which: keyof typeof THREAD_AT) => {
    await settle(ctx);
    expect(page(ctx).threadId).toBe(THREAD_AT[which]);
    expect(composer(ctx).target).toBe(`thread:${THREAD_AT[which]}`);
  },
);

step(/^the timeline scrolls (up|down) one page$/, async (ctx: World, direction: string) => {
  await settle(ctx);
  handled(ctx, direction === "up" ? "timeline.pageUp" : "timeline.pageDown");
});

step(/^the prompt (grows|shrinks) by a row$/, async (ctx: KeymapWorld, change: string) => {
  await settle(ctx);
  expect(composer(ctx).rows).toBe(ctx.rowsBefore! + (change === "grows" ? 1 : -1));
  expect(geometry(findObject(ctx, "composerInput")).height).toBe(composer(ctx).rows);
});

step("the composer switches between plan and build", async (ctx: KeymapWorld) => {
  await settle(ctx);
  const next = ctx.modeBefore === "plan" ? "default" : "plan";
  expect(composer(ctx).interactionMode).toBe(next);
  expect(callsTo(ctx, "setInteractionMode").map((call) => call.args[1])).toEqual([next]);
});

const PICKERS = { "runtime access": "runtime", model: "model", "reasoning effort": "reasoning" };

step(
  /^the (runtime access|model|reasoning effort) picker opens$/,
  async (ctx: World, name: keyof typeof PICKERS) => {
    await settle(ctx);
    expect(select(ctx)).toMatchObject({ open: true, kind: PICKERS[name] });
    expect(mode(ctx)).toBe("select");
    expect(geometry(findObject(ctx, "selectOverlay")).visible).toBe(true);
  },
);

step("the prompt opens in the user's editor", async (ctx: ComposerWorld) => {
  await settle(ctx);
  expect(ctx.editorRuns).toHaveLength(1);
});

step("the reply is sent", async (ctx: World) => {
  await settle(ctx);
  const sent = callsTo(ctx, "sendReply");
  expect(sent.map((call) => call.args[1])).toEqual(["Carry on"]);
});

// --- Answering the agent -------------------------------------------------------

const WAITING: Record<string, (detail: OrchestrationThread) => OrchestrationThread> = {
  "a proposed plan": (detail) =>
    ({
      ...detail,
      interactionMode: "plan",
      proposedPlans: [
        {
          id: "plan-1",
          turnId: null,
          planMarkdown: "# Ship it\n\n1. Do the work",
          implementedAt: null,
          implementationThreadId: null,
          createdAt: "2026-07-13T00:00:05.000Z",
          updatedAt: "2026-07-13T00:00:05.000Z",
        },
      ],
    }) as unknown as OrchestrationThread,
  "a request for approval": (detail) =>
    ({
      ...running(detail),
      activities: [
        {
          id: "a-1",
          kind: "approval.requested",
          tone: "approval",
          summary: "Run command",
          turnId: null,
          sequence: 1,
          createdAt: "2026-07-13T00:00:05.000Z",
          payload: { requestId: "r1", requestKind: "command", detail: "rm -rf build" },
        },
      ],
    }) as unknown as OrchestrationThread,
  "a question the user set aside": (detail) =>
    ({
      ...running(detail),
      activities: [
        {
          id: "a-2",
          kind: "user-input.requested",
          tone: "info",
          summary: "Question",
          turnId: null,
          sequence: 1,
          createdAt: "2026-07-13T00:00:05.000Z",
          payload: {
            requestId: "req-2",
            questions: [
              {
                id: "q1",
                header: "Scope",
                question: "Which package?",
                options: [{ label: "web", description: "The web app" }],
              },
            ],
          },
        },
      ],
    }) as unknown as OrchestrationThread,
};

step(
  /^the thread has (a proposed plan|a request for approval|a question the user set aside)$/,
  async (ctx: KeymapWorld, waiting: string) => {
    await openOnThread(ctx, WAITING[waiting]!(thread()));
    // Setting a question aside is Esc on its form.
    if (waiting === "a question the user set aside") await pressKey(ctx, "Esc");
    await settle(ctx);
    ctx.dispatched!.length = 0;
  },
);

step("the plan is implemented", async (ctx: World) => {
  await settle(ctx);
  handled(ctx, "plan.implement");
  expect(callsTo(ctx, "implementPlan")).toHaveLength(1);
});

// "the request is approved/declined" (approvals.steps.ts) reads what reached the server.

step("the question opens again", async (ctx: World) => {
  await settle(ctx);
  handled(ctx, "userInput.reopen");
});

// --- Esc: the draft, then the turn -------------------------------------------

step("the agent is working on a turn", async (ctx: KeymapWorld) => {
  await openOnThread(ctx, running(thread()));
  expect(composer(ctx).isRunning).toBe(true);
});

step("the prompt holds a draft", async (ctx: World) => {
  await typeIntoPrompt(ctx, "half a thought");
});

step("the user presses {string} again", async (ctx: World, key: string) => {
  await pressKey(ctx, key);
  await settle(ctx);
});

step("the draft is cleared", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).text).toBe("");
});

step("the turn keeps running", async (ctx: World) => {
  expect(composer(ctx).isRunning).toBe(true);
  expect(callsTo(ctx, "interrupt")).toHaveLength(0);
});

// --- The terminal drawer -------------------------------------------------------

step("the terminal drawer is open with focus", async (ctx: KeymapWorld) => {
  await ensureRunning(ctx);
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
  expect(mode(ctx)).toBe("terminal");
  // Something on screen, so a copy has text to take.
  await printToTerminal(ctx, "build ok\r\n$ ");
  ctx.dispatched!.length = 0;
});

step("focus moves back to the prompt", async (ctx: World) => {
  await settle(ctx);
  expect(mode(ctx)).toBe("compose");
  expect(findObject(ctx, "composerInput").get("focus")).toBe(true);
});

const TERMINAL_OUTCOMES: Record<string, string> = {
  "the drawer grows by 2 rows": "terminal.grow",
  "the drawer shrinks by 2 rows": "terminal.shrink",
  "the scrollback moves up one page": "terminal.scroll.pageUp",
  "the scrollback moves up one line": "terminal.scroll.lineUp",
};

for (const [outcome, action] of Object.entries(TERMINAL_OUTCOMES)) {
  step(outcome, async (ctx: World) => {
    await settle(ctx);
    handled(ctx, action);
  });
}

// --- Overlays --------------------------------------------------------------------

step(/^the (next|previous) command is highlighted$/, async (ctx: KeymapWorld, which: string) => {
  await settle(ctx);
  const count = palette(ctx).commands.length;
  const before = ctx.paletteIndexBefore ?? 0;
  expect(palette(ctx).index).toBe((before + (which === "next" ? 1 : -1) + count) % count);
  expect(await snapshot(ctx)).toContain(`▸ ${palette(ctx).commands[palette(ctx).index]!.title}`);
});

step("the highlighted command runs", async (ctx: World) => {
  await settle(ctx);
  // The first command is "New thread".
  expect(palette(ctx).open).toBe(false);
  expect(ctx.dispatched!.map((entry) => entry.action)).toContain("thread.new");
  expect(newThread(ctx)).not.toBeNull();
});

step("the palette closes", async (ctx: World) => {
  await settle(ctx);
  expect(palette(ctx).open).toBe(false);
  expect(mode(ctx)).toBe("compose");
  expect(geometry(findObject(ctx, "commandPalette")).visible).toBe(false);
});

step("the diff switches between split and stacked", async (ctx: KeymapWorld) => {
  await settle(ctx);
  const { view } = ctx.host!.state.get("diff") as { view: string };
  expect(ctx.diffViewBefore).toBeDefined();
  expect(["split", "unified"]).toContain(view);
  expect(view).not.toBe(ctx.diffViewBefore);
  expect(findObject(ctx, "diffViewer").get("visible")).toBe(true);
});

step("the diff viewer closes", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(findObject(ctx, "diffViewer").get("visible")).toBe(false);
  expect(mode(ctx)).toBe("compose");
  expect(screen).not.toContain("diff · ");
});

step("the highlighted model is applied", async (ctx: World) => {
  await settle(ctx);
  expect(select(ctx).open).toBe(false);
  // The picker opens on the thread's model, gpt-5.
  expect(composer(ctx).selectedModel).toBe("gpt-5");
  expect(ctx.dispatched!.map((entry) => entry.action)).toContain("select.confirm");
  expect(shownText(findObject(ctx, "composerModel").get("text"))).toContain("gpt-5");
});

// --- tmux wheel ---------------------------------------------------------------

step("the terminal client runs inside tmux without mouse passthrough", async (ctx: KeymapWorld) => {
  await openOnFourThreads(ctx);
  ctx.threadBefore = page(ctx).threadId!;
});

// tmux turns wheel notches into plain arrow keys.
step("the user scrolls the wheel over the timeline", async (ctx: World) => {
  for (const key of ["Down", "Down", "Down", "Up", "Down"]) {
    await pressKey(ctx, key);
    await settle(ctx);
  }
});

step("the selected thread does not change", async (ctx: KeymapWorld) => {
  expect(page(ctx).threadId).toBe(ctx.threadBefore!);
  expect(composer(ctx).target).toBe(`thread:${ctx.threadBefore}`);
});

// --- The settings reference ----------------------------------------------------

step("the user opens settings from the command palette", async (ctx: KeymapWorld) => {
  await ensureRunning(ctx);
  await runPaletteCommand(ctx, "Settings");
  handled(ctx, "settings.open");
});

/** Everything the settings page shows, paging from its top (PgUp) down to its end (PgDn). */
async function settingsText(ctx: World): Promise<string> {
  for (let guard = 0, last = ""; guard < 20; guard += 1) {
    await pressKey(ctx, "PgUp");
    const screen = await settle(ctx);
    if (screen === last) break;
    last = screen;
  }
  const pages = [await snapshot(ctx)];
  for (let guard = 0; guard < 20; guard += 1) {
    await pressKey(ctx, "PgDn");
    const next = await settle(ctx);
    if (next === pages[pages.length - 1]) break;
    pages.push(next);
  }
  expect(mode(ctx)).toBe("settings");
  return pages.join("\n");
}

step(
  "the keybinding reference lists the Global, Conversation, Terminal, Source control and Overlays groups",
  async (ctx: World) => {
    const titles = keybindings(ctx).groups.map((group) => group.title.split(" (")[0]);
    expect(titles).toEqual(["Global", "Conversation", "Terminal", "Source control", "Overlays"]);
    const text = await settingsText(ctx);
    for (const title of titles) expect(text).toContain(title!);
  },
);

step("every chord the client handles appears in it", async (ctx: World) => {
  const documented = new Set(
    keybindings(ctx).groups.flatMap((group) =>
      group.bindings.flatMap((binding) => binding.chords ?? []),
    ),
  );
  for (const chord of boundChords(keybindings(ctx).layers)) expect(documented).toContain(chord);
  const text = await settingsText(ctx);
  // A long description is cut at the pane's edge.
  for (const group of keybindings(ctx).groups) {
    for (const binding of group.bindings) expect(text).toContain(binding.description.slice(0, 32));
  }
});
