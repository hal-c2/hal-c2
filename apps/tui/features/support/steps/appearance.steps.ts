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
import { PROVIDER_SEND_TURN_MAX_IMAGE_BYTES } from "@hal-c2/contracts";
import { decodeImage } from "@hal-c2/opentui-image";
import type { QmlObject } from "opentui-qml";

import { createAttachmentImageCache } from "../../../src/attachmentImages.ts";
import { FALLBACK_CELL_PIXELS } from "../../../src/host/timelineState.ts";
import { inlineImageTransport } from "../../../src/terminalGraphics.ts";
import { TUI_RENDERER_CONFIG } from "../../../src/terminalStartup.ts";
import { addThread, flush, ui } from "../environment.ts";
import { launchSetup, type LaunchWorld } from "../launchWorld.ts";
import { thread } from "../fakeClient.ts";
import {
  hostState,
  message,
  plain,
  openThread,
  timelineText,
  type ThreadWorld,
} from "../threadWorld.ts";
import {
  click,
  contextMenu,
  findOnScreen,
  rightClick,
  rowPosition,
  sidebar,
  threadRows,
  type ThreadRow,
} from "../threadUi.ts";
import {
  advance,
  boot,
  findObject,
  geometry,
  pressKey,
  settle as settleWorld,
  snapshot,
  useClient,
  type World,
} from "../world.ts";

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

// --- mouse ---

/** Two threads in the list; the first opens selected at boot. */
async function twoThreads(ctx: World): Promise<{ active: string; other: ThreadRow }> {
  addThread(ctx, "Fix the login form");
  addThread(ctx, "Tidy the docs");
  await ui(ctx);
  const active = sidebar(ctx).activeThreadKey;
  const other = threadRows(ctx).find((row) => row.key !== active);
  if (!active || !other) throw new Error("expected one open thread and another listed");
  return { active, other };
}

interface MouseWorld extends World {
  /** The thread the pointer acted on, and the thread open before it did. */
  pointed?: { key: string; activeBefore: string };
  /** Actions dispatched before the pointer acted. */
  dispatchedBefore?: number;
}

step("the user clicks a thread in the list", async (ctx: MouseWorld) => {
  const { active, other } = await twoThreads(ctx);
  ctx.pointed = { key: other.key, activeBefore: active };
  await click(ctx, rowPosition(ctx, other.thread.title));
});

step("that thread opens", (ctx: MouseWorld) => {
  expect(sidebar(ctx).activeThreadKey).toBe(ctx.pointed!.key);
  expect(ctx.host!.state.get("page")).toMatchObject({ kind: "thread", key: ctx.pointed!.key });
});

step("the user right-clicks a thread in the list", async (ctx: MouseWorld) => {
  const { active, other } = await twoThreads(ctx);
  ctx.pointed = { key: other.key, activeBefore: active };
  await rightClick(ctx, rowPosition(ctx, other.thread.title));
});

step("the user presses and holds on a thread in the list", async (ctx: MouseWorld) => {
  const { active, other } = await twoThreads(ctx);
  ctx.pointed = { key: other.key, activeBefore: active };
  const at = rowPosition(ctx, other.thread.title);
  await ctx.app!.mockMouse.pressDown(at.x, at.y);
  await ctx.app!.renderOnce();
  await advance(ctx, 500);
  await ctx.app!.mockMouse.release(at.x, at.y);
  await flush(ctx);
});

step(
  "the thread context menu opens without changing the selected thread",
  async (ctx: MouseWorld) => {
    expect(contextMenu(ctx)?.threadKey).toBe(ctx.pointed!.key);
    expect(sidebar(ctx).activeThreadKey).toBe(ctx.pointed!.activeBefore);
    await snapshot(ctx);
    expect(geometry(findObject(ctx, "contextMenu")).visible).toBe(true);
  },
);

step("the user drags across text in the timeline", async (ctx: MouseWorld & ThreadWorld) => {
  await openThread(ctx, {
    ...thread(),
    messages: [message("m1", "assistant", "The quick brown fox jumps over the lazy dog", 1)],
  } as never);
  const at = await findOnScreen(ctx, "quick brown fox");
  if (!at) throw new Error(`the message is not on screen:\n${await snapshot(ctx)}`);
  ctx.dispatchedBefore = ctx.dispatched!.length;
  await ctx.app!.mockMouse.drag(at.x, at.y, at.x + "quick brown fox".length, at.y);
  await settleWorld(ctx);
});

step("the terminal's native text selection works", (ctx: MouseWorld) => {
  // Pointer motion is never reported, so the terminal keeps drag-selection;
  // a drag inside the client selects text rather than acting.
  expect(TUI_RENDERER_CONFIG.enableMouseMovement).toBe(false);
  expect(ctx.dispatched!.slice(ctx.dispatchedBefore)).toEqual([]);
  expect(ctx.app!.renderer.getSelection()?.getSelectedText()).toContain("quick brown fox");
});

const LONG_MESSAGE = Array.from({ length: 30 }, (_, i) => `line ${i + 1} of the pasted log`).join(
  "\n",
);

step("one click reaches the same control more than once", async (ctx: MouseWorld & ThreadWorld) => {
  await openThread(ctx, {
    ...thread(),
    messages: [message("m1", "user", LONG_MESSAGE, 1)],
  } as never);
  const at = await findOnScreen(ctx, "Show full message");
  if (!at) throw new Error(`no collapsed message on screen:\n${await snapshot(ctx)}`);
  ctx.dispatchedBefore = ctx.dispatched!.length;
  // One press the terminal reported twice, handled before anything else runs.
  const press = Buffer.from(`\x1b[<0;${at.x + 1};${at.y + 1}M`);
  ctx.app!.renderer.stdin.emit("data", press);
  ctx.app!.renderer.stdin.emit("data", press);
  expect(ctx.dispatched!.slice(ctx.dispatchedBefore)).toEqual([]);
  ctx.app!.renderer.stdin.emit("data", Buffer.from(`\x1b[<0;${at.x + 1};${at.y + 1}m`));
  await settleWorld(ctx);
});

step("the action runs once, after the click has been handled", async (ctx: MouseWorld) => {
  const toggles = ctx
    .dispatched!.slice(ctx.dispatchedBefore)
    .filter((entry) => entry.action === "timeline.message.toggle");
  expect(toggles).toHaveLength(1);
  expect(await snapshot(ctx)).toContain("Show less");
});

// --- inline images ---

// A 160×80 PNG: twice as wide as it is tall, so a stretched preview shows.
const PNG = Uint8Array.from(
  atob(
    "iVBORw0KGgoAAAANSUhEUgAAAKAAAABQCAIAAAARP+ljAAAAlUlEQVR42u3RQQ0AAAjEsJODRCQiCxO8SJMpWFM9elwsACzAAizAAizAAgxYgAVYgAVYgAUYsAALsAALsAALsAADFmABFmABFmABBizAAizAAizAAgxYgAVYgAVYgAVYgAELsAALsAALsAADFmABFmABFmABBuwCYAEWYAEWYAEWYMACLMACLMACLMCABViABViAddUCiP1UGxK/LD4AAAAASUVORK5CYII=",
  ),
  (char) => char.charCodeAt(0),
);
const PNG_ASPECT = 160 / 80;

interface ImageFixture {
  /** The link the server hands out: a URL, none, or never answered. */
  link: "ready" | "unavailable" | "pending";
  /** Preview downloads that fail with a network error before one succeeds. */
  networkFailures: number;
  /** Advertised download size (the real one by default). */
  contentLength: number;
  fetches: number;
  decodes: number;
}

interface ImageWorld extends LaunchWorld, ThreadWorld {
  images?: ImageFixture;
  /** tmux's global environment (`tmux show-environment -g`). */
  tmuxEnvironment?: string;
  /** The timeline's scroll offset when the viewer opened. */
  scrollBefore?: number;
}

const ATTACHMENT = {
  type: "image",
  id: "att-screenshot",
  name: "screenshot.png",
  mimeType: "image/png",
  sizeBytes: 48 * 1024,
} as const;
const ATTACHMENT_URL = "https://hal-c2.example/attachments/att-screenshot";

function images(ctx: ImageWorld): ImageFixture {
  return (ctx.images ??= {
    link: "ready",
    networkFailures: 0,
    contentLength: PNG.byteLength,
    fetches: 0,
    decodes: 0,
  });
}

/** A terminal that draws Kitty graphics, for scenarios about the preview itself. */
const kittyTerminal = (ctx: ImageWorld) => Object.assign(launchSetup(ctx).env, TERMINALS_KITTY);
const TERMINALS_KITTY = { TERM: "xterm-kitty", TERM_PROGRAM: undefined };

/**
 * Open a thread whose user message carries a screenshot, the client deciding
 * inline images from the terminal environment as the entry point does and
 * loading previews through the real attachment cache.
 */
async function showImageMessage(
  ctx: ImageWorld,
  extra: { messagesAround?: number; threads?: number } = {},
): Promise<void> {
  const fixture = images(ctx);
  const transport = inlineImageTransport(launchSetup(ctx).env, () => ctx.tmuxEnvironment ?? "");
  ctx.hostOptions = { ...ctx.hostOptions, inlineImages: transport };
  const cache = createAttachmentImageCache({
    fetcher: async () => {
      fixture.fetches += 1;
      if (fixture.networkFailures > 0) {
        fixture.networkFailures -= 1;
        throw new TypeError("fetch failed");
      }
      return new Response(PNG, {
        headers: { "content-type": "image/png", "content-length": String(fixture.contentLength) },
      });
    },
    decoder: (encoded) => {
      fixture.decodes += 1;
      return decodeImage(encoded, { maxWidth: 720, maxHeight: 480 });
    },
  });
  const replies = (from: number) =>
    Array.from({ length: extra.messagesAround ?? 0 }, (_, i) =>
      message(
        `m-${from + i}`,
        "assistant",
        `Reply ${from + i}\n\nSecond paragraph of reply ${from + i}.`,
        from + i,
      ),
    );
  const messages = [
    ...replies(1),
    message("m-image", "user", "Here is the broken layout", 100, {
      attachments: [ATTACHMENT],
    } as never),
    ...replies(200),
  ];
  if (fixture.link === "pending") ctx.held = (ctx.held ?? 0) + 1;
  const [first] = shell().threads;
  await openThread(ctx, { ...thread(), messages } as never, {
    ...((extra.threads ?? 1) > 1 && {
      shellSnapshot: shell([first!, { ...first!, id: "t2" as never, title: "Thread two" }]),
    }),
    getAttachmentUrl: async () => {
      if (fixture.link === "pending") return new Promise<string | null>(() => {});
      return fixture.link === "ready" ? ATTACHMENT_URL : null;
    },
    getAttachmentImage: (attachmentId, url) => cache.load(attachmentId, url),
  });
  await settleWorld(ctx);
}

/** The inline preview's Image node, or null when none is drawn. */
function inlineImage(ctx: World): QmlObject | null {
  try {
    return findObject(ctx, `attachmentImage-${ATTACHMENT.id}`);
  } catch {
    return null;
  }
}

/** The timeline line that names the attachment. */
function attachmentLine(ctx: World): string {
  const found = timelineText(ctx).find((text) => text.includes(ATTACHMENT.name));
  if (!found) throw new Error(`no attachment line in:\n${timelineText(ctx).join("\n")}`);
  return found;
}

/**
 * The attachment's link as the line shows it: the URL, clipped with "…" when
 * the bubble is narrower, and a click on the line opens the whole URL.
 */
function expectAttachmentLink(ctx: World): void {
  const text = attachmentLine(ctx);
  const shown = text.slice(text.indexOf("KB") + 2).trim();
  expect(shown.length).toBeGreaterThan(8);
  expect(ATTACHMENT_URL.startsWith(shown.replace(/…$/, ""))).toBe(true);
  const entry = hostState(ctx, "timeline")
    .items.flatMap((item: { lines: unknown[] }) => item.lines)
    .find((line: { text: unknown }) => plain(line.text as never).includes(ATTACHMENT.name));
  expect(entry).toMatchObject({ action: "link.open", payload: { url: ATTACHMENT_URL } });
}

async function expectInlineImage(ctx: ImageWorld, transport: "direct" | "tmux"): Promise<void> {
  expect(hostState(ctx, "graphics")).toEqual({ inlineImages: transport });
  await snapshot(ctx);
  const image = inlineImage(ctx);
  expect(image).not.toBeNull();
  expect(geometry(image!)).toMatchObject({ visible: true });
  expect(geometry(image!).width).toBeGreaterThan(0);
  expect(image!.get("protocol")).toBe("kitty");
  expect(image!.get("status")).toBe("ready");
}

step("the terminal client runs inside tmux in Ghostty", (ctx: ImageWorld) => {
  Object.assign(launchSetup(ctx).env, TMUX_PANE);
  ctx.tmuxEnvironment = "TERM=xterm-ghostty\nTERM_PROGRAM=ghostty\n";
});

step("the terminal client runs inside tmux in a terminal it cannot identify", (ctx: ImageWorld) => {
  Object.assign(launchSetup(ctx).env, TMUX_PANE);
  ctx.tmuxEnvironment = "TERM=xterm-256color\nTERM_PROGRAM=SomeTerm\n";
});

// Inside tmux the pane names tmux, not the terminal around it.
const TMUX_PANE = {
  TMUX: "/tmp/tmux-1000/default,4242,0",
  TERM: "tmux-256color",
  TERM_PROGRAM: "tmux",
};

step("a message with an image attachment is shown", (ctx: ImageWorld) => showImageMessage(ctx));

step("the image is drawn inline in the timeline", (ctx: ImageWorld) =>
  expectInlineImage(ctx, "direct"),
);

step("the image is drawn inline through tmux passthrough", (ctx: ImageWorld) =>
  expectInlineImage(ctx, "tmux"),
);

step("no image is drawn", async (ctx: ImageWorld) => {
  expect(hostState(ctx, "graphics")).toEqual({ inlineImages: null });
  await snapshot(ctx);
  expect(inlineImage(ctx)).toBeNull();
  expect(images(ctx).fetches).toBe(0);
});

step("the attachment shows its name, size and link", async (ctx: ImageWorld) => {
  expect(attachmentLine(ctx)).toContain("screenshot.png · 48 KB");
  expectAttachmentLink(ctx);
  expect(await snapshot(ctx)).toContain("screenshot.png · 48 KB");
});

step(
  /^an image attachment whose link is (still loading|unavailable)$/,
  async (ctx: ImageWorld, state: string) => {
    images(ctx).link = state === "still loading" ? "pending" : "unavailable";
    await showImageMessage(ctx);
  },
);

step("the attachment line reads {string}", async (ctx: ImageWorld, text: string) => {
  expect(attachmentLine(ctx)).toContain(text);
  expect(await snapshot(ctx)).toContain(text);
});

step("an image attachment larger than the preview byte limit", async (ctx: ImageWorld) => {
  kittyTerminal(ctx);
  images(ctx).contentLength = PROVIDER_SEND_TURN_MAX_IMAGE_BYTES + 1;
  await showImageMessage(ctx);
});

step("no inline preview is drawn", async (ctx: ImageWorld) => {
  await snapshot(ctx);
  expect(images(ctx).fetches).toBe(1);
  expect(images(ctx).decodes).toBe(0);
  expect(inlineImage(ctx)).toBeNull();
});

step("the attachment line stays visible", async (ctx: ImageWorld) => {
  expectAttachmentLink(ctx);
  expect(await snapshot(ctx)).toContain("screenshot.png · 48 KB");
});

step("an image preview failed because of a network error", async (ctx: ImageWorld) => {
  kittyTerminal(ctx);
  images(ctx).networkFailures = 1;
  await showImageMessage(ctx, { threads: 2 });
  expect(images(ctx).fetches).toBe(1);
  expect(inlineImage(ctx)).toBeNull();
});

step("the message is shown again", async (ctx: ImageWorld) => {
  // Away to the other thread and back.
  await pressKey(ctx, "Alt+Down");
  await settleWorld(ctx);
  await pressKey(ctx, "Alt+Up");
  await settleWorld(ctx);
  expect(ctx.host!.state.get("page")).toMatchObject({ kind: "thread", threadId: "t1" });
});

step("the client tries to load the preview again", async (ctx: ImageWorld) => {
  expect(images(ctx).fetches).toBe(2);
  await snapshot(ctx);
  expect(inlineImage(ctx)).not.toBeNull();
});

/** Click the inline preview where it is drawn. */
async function clickImage(ctx: ImageWorld): Promise<void> {
  await snapshot(ctx);
  const image = inlineImage(ctx);
  if (!image) throw new Error("no inline image to click");
  const { x, y } = (image as unknown as { renderable: { x: number; y: number } }).renderable;
  await ctx.app!.click(x + 1, y + 1);
  await settleWorld(ctx);
}

step("an inline image in the timeline", async (ctx: ImageWorld) => {
  kittyTerminal(ctx);
  await showImageMessage(ctx);
  await expectInlineImage(ctx, "direct");
});

step("the user clicks the image", clickImage);

step("the image opens fitted inside the terminal without distortion", async (ctx: ImageWorld) => {
  expect(hostState(ctx, "mode")).toBe("imagePreview");
  const viewer = hostState(ctx, "imageViewer");
  expect(viewer).toMatchObject({ id: ATTACHMENT.id });
  await snapshot(ctx);
  const image = findObject(ctx, "imageViewerImage");
  expect(geometry(image)).toMatchObject({
    visible: true,
    width: viewer.columns,
    height: viewer.rows,
  });
  expect(image.get("status")).toBe("ready");
  const drawn = (image as unknown as { renderable: { x: number; y: number } }).renderable;
  expect(drawn.x).toBeGreaterThanOrEqual(0);
  expect(drawn.y).toBeGreaterThanOrEqual(0);
  expect(drawn.x + viewer.columns).toBeLessThanOrEqual(ctx.columns!);
  expect(drawn.y + viewer.rows).toBeLessThanOrEqual(ctx.rows!);
  // It fills the room it has in one direction and keeps the image's shape:
  // cells are taller than wide, so the rows follow from the columns.
  const cell = FALLBACK_CELL_PIXELS;
  const expectedRows = (viewer.columns * cell.width) / PNG_ASPECT / cell.height;
  expect(Math.abs(viewer.rows - expectedRows)).toBeLessThanOrEqual(1);
  expect(viewer.columns >= ctx.columns! - 4 || viewer.rows >= ctx.rows! - 4).toBe(true);
});

const timelineScroll = (ctx: World) => Number(findObject(ctx, "timeline").get("contentY"));

step("an image is open full size", async (ctx: ImageWorld) => {
  kittyTerminal(ctx);
  await showImageMessage(ctx, { messagesAround: 15 });
  // Scroll back up until the screenshot is on screen, away from the newest reply.
  for (let page = 0; page < 20; page += 1) {
    await snapshot(ctx);
    const image = inlineImage(ctx) as unknown as { renderable: { y: number } } | null;
    const scroller = findObject(ctx, "timeline") as unknown as {
      renderable: { y: number; height: number };
    };
    const y = image?.renderable.y ?? -1;
    if (y >= scroller.renderable.y && y < scroller.renderable.y + scroller.renderable.height - 2)
      break;
    await pressKey(ctx, "PgUp");
    await settleWorld(ctx);
  }
  ctx.scrollBefore = timelineScroll(ctx);
  expect(ctx.scrollBefore).toBeGreaterThan(0);
  await clickImage(ctx);
  expect(hostState(ctx, "imageViewer")).not.toBeNull();
});

step("the image closes", async (ctx: ImageWorld) => {
  expect(hostState(ctx, "imageViewer")).toBeNull();
  expect(hostState(ctx, "mode")).not.toBe("imagePreview");
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "imageViewerLayer")).visible).toBe(false);
});

step("the timeline is at the same scroll position as before", async (ctx: ImageWorld) => {
  await snapshot(ctx);
  expect(timelineScroll(ctx)).toBe(ctx.scrollBefore!);
  expect(inlineImage(ctx)).not.toBeNull();
});
