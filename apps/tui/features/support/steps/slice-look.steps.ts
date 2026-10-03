// tui/appearance.feature: nerd font icons, the client's own colour themes,
// NO_COLOR, and the colours the client paints with at any colour depth.
import { expect } from "bun:test";
import type { CapturedSpan } from "@opentui/core";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { setNerdFont, TOOL_ICONS } from "../../../src/icons.ts";
import { noColorRequested, setColourTheme, THEME } from "../../../src/theme.ts";
import { step } from "../../steps.ts";
import { thread } from "../fakeClient.ts";
import { chooseCommand } from "../threadUi.ts";
import {
  checkpoint,
  command,
  message,
  openThread,
  timelineText,
  type ThreadWorld,
} from "../threadWorld.ts";
import { pressKey, settle, type World } from "../world.ts";

interface LookWorld extends ThreadWorld {
  env?: Record<string, string>;
  depth?: string;
  plainLines?: string[];
}

const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const spans = (ctx: World): CapturedSpan[] =>
  ctx.app!.setup.captureSpans().lines.flatMap((line) => line.spans);
const inked = (span: CapturedSpan) => span.text.trim().length > 0;
const hex = (colour: CapturedSpan["fg"]) =>
  `#${[colour.r ?? 0, colour.g ?? 0, colour.b ?? 0]
    .map((part) =>
      Math.round(part * 255)
        .toString(16)
        .padStart(2, "0"),
    )
    .join("")}`;

/** A thread with a reply in Markdown, a command the agent ran and a changed file. */
async function openWorkedThread(ctx: LookWorld) {
  // The palette and the icon set are process-wide: put them back after the scenario.
  ctx.cleanups.push(() => {
    setColourTheme("terminal");
    setNerdFont(false);
  });
  const detail = {
    ...thread(),
    messages: [
      message("m-1", "user", "Fix the rounding", 1),
      message("m-2", "assistant", "## Done\n\nChanged `cartTotal` in the cart.", 5, {
        turnId: "turn-1",
      } as never),
    ],
    activities: [command("c-1", 2, "bun test", "turn-1")],
    checkpoints: [checkpoint(1, ["src/cart.ts", "README.md"], 6, "m-2")],
  };
  await openThread(ctx, detail as never);
  await settle(ctx);
}

// --- Nerd font ------------------------------------------------------------------------

step("the user has told the client their terminal uses a nerd font", async (ctx: LookWorld) => {
  await openWorkedThread(ctx);
  ctx.plainLines = timelineText(ctx);
  expect(ctx.plainLines.join("\n")).toContain("◦ cart.ts");
  await chooseCommand(ctx, "Use nerd font icons");
  await settle(ctx);
});

step("tool and file icons use nerd font glyphs", async (ctx: LookWorld) => {
  const lines = timelineText(ctx).join("\n");
  // Private-use glyphs, each one column wide.
  expect(TOOL_ICONS.terminal.glyph as string).toBe("");
  expect(Bun.stringWidth(TOOL_ICONS.terminal.glyph)).toBe(1);
  expect(lines).toContain(" cart.ts");
  expect(lines).toContain(" README.md");
  expect(lines).not.toContain("◦");
  expect(await settle(ctx)).toContain(" cart.ts");
  // The same rows, only the glyphs differ.
  expect(timelineText(ctx).length).toBe(ctx.plainLines!.length);
});

step("turning the option off returns to the single-column fallbacks", async (ctx: LookWorld) => {
  await chooseCommand(ctx, "Use plain icons");
  await settle(ctx);
  expect(TOOL_ICONS.terminal.glyph as string).toBe("$");
  expect(timelineText(ctx)).toEqual(ctx.plainLines!);
  expect(await settle(ctx)).toContain("◦ cart.ts");
});

// --- Colour themes -----------------------------------------------------------------------

step("the user chooses a colour theme in the terminal client", async (ctx: LookWorld) => {
  await openWorkedThread(ctx);
  await chooseCommand(ctx, "Change colour theme…");
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "Terminal default",
    "Solarized dark",
    "Gruvbox dark",
  ]);
  await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the client redraws in that theme", async (ctx: World) => {
  expect(status(ctx)).toEqual({ kind: "success", text: "Theme → Solarized dark" });
  expect((ctx.host!.state.get("theme") as { id: string }).id).toBe("solarized");
  await settle(ctx);
  const all = spans(ctx);
  // The window is painted in the theme's background, text in its foreground.
  const backgrounds = new Set(
    all.filter((span) => span.bg.intent === "rgb").map((span) => hex(span.bg)),
  );
  expect(backgrounds.has("#002b36")).toBe(true);
  const foregrounds = new Set(
    all.filter((span) => inked(span) && span.fg.intent === "rgb").map((span) => hex(span.fg)),
  );
  // Text, dim text, borders and the accent, from bricks and from host-styled lines alike.
  for (const colour of ["#93a1a1", "#839496", "#586e75", "#268bd2"]) {
    expect(foregrounds.has(colour), `no cell in ${colour}`).toBe(true);
  }
  // Nothing is left in the terminal's default foreground.
  expect(
    all.filter((span) => inked(span) && span.fg.intent === "default").map((s) => s.text),
  ).toEqual([]);
});

step("choosing the terminal default again borrows the terminal's colours", async (ctx: World) => {
  await chooseCommand(ctx, "Change colour theme…");
  expect(select(ctx).index).toBe(1);
  await pressKey(ctx, "Up");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect((ctx.host!.state.get("theme") as { id: string }).id).toBe("terminal");
  const all = spans(ctx);
  expect(all.filter((span) => inked(span) && span.fg.intent === "rgb").map((s) => s.text)).toEqual(
    [],
  );
  expect(all.filter((span) => span.bg.intent === "rgb").map((s) => s.text)).toEqual([]);
  expect(
    all.some((span) => inked(span) && span.fg.intent === "indexed" && span.fg.slot === 6),
  ).toBe(true);
});

// --- NO_COLOR ---------------------------------------------------------------------------------

step("the environment variable {string} is set", (ctx: LookWorld, name: string) => {
  ctx.env = { ...ctx.env, [name]: "1" };
  // The client reads it once, as it starts.
  ctx.cleanups.push(() => setColourTheme("terminal"));
  if (noColorRequested(ctx.env)) setColourTheme("none");
});

step("no colour escape sequences are written", async (ctx: World) => {
  await settle(ctx);
  // Every cell is the terminal's default foreground on its default background.
  const coloured = spans(ctx).filter(
    (span) => (inked(span) && span.fg.intent !== "default") || span.bg.intent !== "default",
  );
  expect(coloured.map((span) => span.text)).toEqual([]);
});

step("status is still readable from glyphs and text", async (ctx: World) => {
  const screen = await settle(ctx);
  // The status line's glyph and message, and each thread's status dot and title.
  const row = ctx.host!.state.get("statusRow") as { label: string };
  expect(row.label).toStartWith("· ");
  expect(screen).toContain(row.label);
  expect(screen).toContain("○");
  expect(screen).toContain("Thread two");
  // An error reads as one without its colour: the glyph says so.
  ctx.host!.dispatch("thread.archive", { key: "local:missing" });
  ctx.fake!.override("archiveThread", async () => {
    throw new Error("server unreachable");
  });
  ctx.host!.dispatch("thread.archive", { key: "local:t1" });
  const after = await settle(ctx);
  expect((ctx.host!.state.get("statusRow") as { label: string }).label).toStartWith("✗ ");
  expect(after).toContain("✗ ");
  expect(spans(ctx).filter((span) => inked(span) && span.fg.intent !== "default")).toEqual([]);
});

// --- Colour depth -----------------------------------------------------------------------------

step(/^the terminal supports (truecolor|256 colours)$/, async (ctx: LookWorld, depth: string) => {
  ctx.depth = depth;
  await openWorkedThread(ctx);
});

step("status, diff and syntax colours stay distinguishable", async (ctx: LookWorld) => {
  // The client paints with the terminal's 16 ANSI slots and its defaults only:
  // a 256-colour terminal and a truecolor one are sent the same sequences, so
  // nothing is quantised and no two roles collapse into one colour.
  expect(["truecolor", "256 colours"]).toContain(ctx.depth!);
  const roles = {
    success: THEME.success,
    error: THEME.error,
    busy: THEME.accent,
    warning: THEME.warning,
  };
  const slots = Object.values(roles).map((colour) => `${colour.intent}:${colour.slot}`);
  expect(new Set(slots).size).toBe(slots.length);
  // On screen: the reply's heading and inline code (syntax), the changed files'
  // additions and deletions (diff), and the status line.
  await settle(ctx);
  const cell = (text: string) => {
    const span = spans(ctx).find((candidate) => candidate.text.includes(text));
    expect(span, `"${text}" is not on screen`).toBeDefined();
    return span!.fg;
  };
  const heading = cell("Done");
  const code = cell("cartTotal");
  const added = cell("+3");
  const removed = cell("-1");
  for (const colour of [heading, code, added, removed]) {
    expect(colour.intent).toBe("indexed");
    expect(colour.slot).toBeLessThan(16);
  }
  expect(new Set([heading.slot, code.slot, added.slot, removed.slot]).size).toBe(4);
  // Nothing on the whole screen needs more than the 16 slots.
  const beyond = spans(ctx).filter(
    (span) =>
      (inked(span) &&
        (span.fg.intent === "rgb" || (span.fg.intent === "indexed" && span.fg.slot > 15))) ||
      span.bg.intent === "rgb" ||
      (span.bg.intent === "indexed" && span.bg.slot > 15),
  );
  expect(beyond.map((span) => span.text)).toEqual([]);
});
