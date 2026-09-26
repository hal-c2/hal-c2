// Steps for tui/appearance.feature: the terminal palette, status glyphs, ages,
// status tones, icon widths and file tints, checked on the rendered cells.
import { expect } from "bun:test";
import type { CapturedSpan } from "@opentui/core";

import { step } from "../../steps.ts";
import { allIconGlyphs, fileTypeColor } from "../../../src/icons.ts";
import { ansi, statusGlyphColor, THEME, THREAD_STATUS_GLYPHS } from "../../../src/theme.ts";
import type { TuiSidebarState } from "../../../src/host/sidebarState.ts";
import { scheduleColorCapabilityLog } from "../../../src/terminalStartup.ts";
import { shell } from "../fakeClient.ts";
import { changes, ready, scm, setCheckout, settle, vcsStatus } from "../gitWorld.ts";
import { boot, snapshot, useClient, type World } from "../world.ts";

interface AppearanceWorld extends World {
  /** Timers the startup scheduled, run by "… two seconds later". */
  startupTimers?: Array<{ run: () => void; ms: number }>;
}

/** Every rendered cell run, row by row. */
const spans = (ctx: World): CapturedSpan[][] =>
  ctx.app!.setup.captureSpans().lines.map((line) => line.spans);

/** The span that holds `text` on the first row that also shows `rowText`. */
function spanOn(ctx: World, rowText: string, text: string): CapturedSpan {
  for (const row of spans(ctx)) {
    if (
      !row
        .map((span) => span.text)
        .join("")
        .includes(rowText)
    )
      continue;
    const span = row.find((candidate) => candidate.text.includes(text));
    if (span) return span;
  }
  throw new Error(`no row shows "${rowText}" with "${text}"`);
}

/** Cells that draw something (blank cells have no visible foreground). */
const inked = (span: CapturedSpan) => span.text.trim().length > 0;

/** Same terminal colour (default, or the same palette slot). */
function expectColour(actual: CapturedSpan["fg"], expected: CapturedSpan["fg"]): void {
  expect({ intent: actual.intent, slot: actual.slot }).toEqual({
    intent: expected.intent,
    slot: expected.slot,
  });
}

// --- the terminal's own theme ---

step("the user's terminal has a light theme", () => {
  // Nothing to set: the client never paints its own palette, so the terminal's
  // light or dark theme shows through whatever it is.
});

step("the terminal client opens", async (ctx: AppearanceWorld) => {
  ctx.connectOnBoot = true;
  // Two threads: the first opens selected (accent), the second is plain text.
  if (!ctx.fake) {
    const [first] = shell().threads;
    useClient(ctx, {
      shellSnapshot: shell([first!, { ...first!, id: "t2" as never, title: "Thread two" }]),
    });
  }
  const logs = (ctx.logs ??= []);
  const app = await boot(ctx);
  const timers: Array<{ run: () => void; ms: number }> = (ctx.startupTimers = []);
  // What the entry point does right after the renderer starts.
  scheduleColorCapabilityLog({
    log: (line) => logs.push(line),
    capabilities: () => app.engine.renderer.capabilities,
    env: { TERM: "xterm-ghostty", COLORTERM: "truecolor" },
    schedule: (run, ms) => timers.push({ run, ms }),
  });
  await settle(ctx);
});

step("text uses the terminal's default foreground and background", (ctx: World) => {
  const all = spans(ctx).flat();
  expect(
    all.filter((span) => inked(span) && span.fg.intent === "rgb").map((span) => span.text),
  ).toEqual([]);
  expect(all.filter((span) => span.bg.intent === "rgb").map((span) => span.text)).toEqual([]);
  // An unselected thread's title and the page background are the terminal's own colours.
  const title = spanOn(ctx, "Thread two", "Thread two");
  expect(title.fg.intent).toBe("default");
  expect(title.bg.intent).toBe("default");
});

step("accent colours come from the terminal's ANSI palette", (ctx: World) => {
  const indexed = spans(ctx)
    .flat()
    .filter(inked)
    .flatMap((span) => [span.fg, span.bg])
    .filter((colour) => colour.intent === "indexed");
  expect(indexed.length).toBeGreaterThan(0);
  expect(indexed.every((colour) => colour.slot >= 0 && colour.slot < 16)).toBe(true);
});

step("no terminal colour reply appears as typed text in the prompt", async (ctx: World) => {
  // The terminal answers the renderer's colour queries on stdin as the client opens.
  await ctx.app!.mockInput.pressKeys([
    "\x1b]11;rgb:ffff/ffff/ffff\x1b\\",
    "\x1b]10;rgb:1c1c/1c1c/1c1c\x07",
    "\x1b]4;1;rgb:cccc/0000/0000\x07",
  ]);
  const screen = await settle(ctx);
  expect(screen).not.toContain("rgb:");
  const inputs: string[] = [];
  const queue = [ctx.app!.root];
  while (queue.length > 0) {
    const object = queue.shift()!;
    if (object.typeName === "TextInput") inputs.push(String(object.get("text") ?? ""));
    queue.push(...object.children);
  }
  expect(inputs.length).toBeGreaterThan(0);
  for (const text of inputs) expect(text).not.toMatch(/rgb|\]1[01];/);
});

step("the client log records the detected colour capabilities", (ctx: World) => {
  const line = ctx.logs!.find((entry) => entry.startsWith("[color-caps startup]"));
  expect(line).toContain("TERM=xterm-ghostty");
  expect(line).toContain("COLORTERM=truecolor");
  // The headless renderer detects nothing, so the value is null here.
  expect(line).toMatch(/ caps=\S+$/);
});

step(
  "it records them again two seconds later after the terminal has answered",
  (ctx: AppearanceWorld) => {
    expect(ctx.logs!.some((entry) => entry.startsWith("[color-caps settled]"))).toBe(false);
    for (const timer of ctx.startupTimers!.filter((entry) => entry.ms <= 2000)) timer.run();
    expect(ctx.logs!.some((entry) => entry.startsWith("[color-caps settled]"))).toBe(true);
  },
);

// --- thread and project status ---

const STATES: Readonly<Record<string, Record<string, unknown>>> = {
  "waiting on an approval": { hasPendingApprovals: true, session: { status: "idle" } },
  "waiting on the user": { hasPendingUserInput: true, session: { status: "idle" } },
  "holding a ready plan": { hasActionableProposedPlan: true, session: { status: "idle" } },
  working: { session: { status: "running" } },
  connecting: { session: { status: "starting" } },
  failed: { session: { status: "error" } },
  ready: { session: { status: "ready" } },
  completed: { session: { status: "stopped" } },
  "sitting idle": { session: { status: "idle" } },
  "working and waiting on an approval": {
    hasPendingApprovals: true,
    session: { status: "running" },
  },
};

const listed = (id: string, title: string, over: Record<string, unknown>) => ({
  id,
  projectId: "p1",
  title,
  createdAt: new Date(Date.now() - 60_000).toISOString(),
  updatedAt: new Date(Date.now() - 60_000).toISOString(),
  session: { status: "idle" },
  ...over,
});

/** Boot with these threads in the list. */
async function showThreads(ctx: World, threads: Array<Record<string, unknown>>): Promise<void> {
  useClient(ctx, { shellSnapshot: shell(threads as never) });
  ctx.connectOnBoot = true;
  await boot(ctx);
  await settle(ctx);
}

// Only these states: T1's "a thread that (is idle|is running a turn|…)" shares the prefix.
step(
  new RegExp(`^a thread that is (${Object.keys(STATES).join("|")})$`),
  async (ctx: World, state: string) => {
    const over = STATES[state]!;
    await showThreads(ctx, [listed("t1", "Thread one", over)]);
  },
);

async function expectGlyph(ctx: World, glyph: string, colour: string): Promise<void> {
  await snapshot(ctx);
  expectColour(spanOn(ctx, "Thread one", glyph).fg, ansi(colour));
}

step(
  /^the thread list shows it with "(.+)" in (\w+)$/,
  (ctx: World, glyph: string, colour: string) => expectGlyph(ctx, glyph, colour),
);

step("the thread list shows the approval glyph", (ctx: World) => expectGlyph(ctx, "◆", "red"));

step("a project with one idle thread and one thread waiting on the user", async (ctx: World) => {
  await showThreads(ctx, [
    listed("t1", "Thread one", STATES["sitting idle"]!),
    listed("t2", "Thread two", STATES["waiting on the user"]!),
  ]);
});

step("the project shows the waiting-on-the-user status", (ctx: World) => {
  const sidebar = ctx.host!.state.get("sidebar") as TuiSidebarState;
  expect(sidebar.projects[0]).toMatchObject({ glyph: "◆", glyphColor: "yellow" });
});

// --- ages ---

const UNIT_MS: Readonly<Record<string, number>> = {
  second: 1000,
  minute: 60_000,
  hour: 3_600_000,
  day: 86_400_000,
};

step(
  /^a thread last updated (\d+) (second|minute|hour|day)s? ago$/,
  async (ctx: World, amount: string, unit: string) => {
    const at = new Date(Date.now() - Number(amount) * UNIT_MS[unit]!).toISOString();
    await showThreads(ctx, [
      listed("t1", "Thread one", { createdAt: at, updatedAt: at, latestUserMessageAt: at }),
    ]);
  },
);

step("its age reads {string}", async (ctx: World, label: string) => {
  const rows = (await snapshot(ctx)).split("\n").filter((line) => line.includes("Thread one"));
  // The list row ends with the age; the conversation header only has the title.
  expect(rows.map((row) => row.split("│")[1]?.trim().split(/\s+/).at(-1))).toContain(label);
});

// --- status tones ---

const TONES: Readonly<Record<string, (ctx: World) => Promise<void>>> = {
  // Nothing has arrived yet: the client is connecting.
  busy: async (ctx) => {
    await boot(ctx);
    await settle(ctx);
  },
  // The first snapshot: the project and thread counts.
  info: async (ctx) => {
    await ready(ctx);
  },
  success: async (ctx) => {
    await ready(ctx);
    ctx.host!.dispatch("git.pull");
    await settle(ctx);
  },
  error: async (ctx) => {
    scm(ctx).onPull = () => {
      throw new Error("remote hung up");
    };
    await ready(ctx);
    ctx.host!.dispatch("git.pull");
    await settle(ctx);
  },
};

step(/^the client reports an? (\w+) message$/, async (ctx: World, tone: string) => {
  const report = TONES[tone];
  if (!report) throw new Error(`no status tone "${tone}"`);
  await report(ctx);
  expect((ctx.host!.state.get("status") as { kind: string }).kind).toBe(tone);
});

step("the status line starts with {string}", async (ctx: World, glyph: string) => {
  const screen = await snapshot(ctx);
  const text = (ctx.host!.state.get("status") as { text: string }).text;
  const line = screen.split("\n").find((row) => row.includes(text));
  expect(line, `the status line does not show "${text}"`).toBeDefined();
  expect(line!.trimStart().startsWith(`${glyph} `)).toBe(true);
});

// --- icons ---

step("every tool and status icon is a single-column character in any monospace font", () => {
  const tones = (["info", "success", "error", "busy"] as const).map(
    (kind) => statusGlyphColor(kind).glyph,
  );
  for (const glyph of [
    ...allIconGlyphs().map((icon) => icon.glyph),
    ...THREAD_STATUS_GLYPHS,
    ...tones,
  ]) {
    expect({ glyph, width: Bun.stringWidth(glyph) }).toEqual({ glyph, width: 1 });
  }
});

// --- file tints ---

step(
  "a changed file {string} and a changed file {string}",
  async (ctx: World, first: string, second: string) => {
    scm(ctx);
    setCheckout(ctx, vcsStatus(changes(first, second)));
    await ready(ctx);
    ctx.host!.dispatch("rightPanel.open");
    await settle(ctx);
  },
);

step("{string} is tinted for its file type", (ctx: World, path: string) => {
  const colour = fileTypeColor(path);
  expect(colour, `${path} has no file type colour`).not.toBeNull();
  const fg = spanOn(ctx, path, path).fg;
  expectColour(fg, ansi(colour!));
  expect(fg.slot).not.toBe(THEME.dim.slot);
});

step("{string} is dimmed", (ctx: World, path: string) => {
  expectColour(spanOn(ctx, path, path).fg, THEME.dim);
});
