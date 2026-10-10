// Steps shared across feature areas. Workers append their own sections
// (`// --- added by Tn ---`) or add feature-area files next to this one.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { rectOf } from "../design.ts";
import { expectClientStatus } from "./launch.steps.ts";
import { expectCliStatus } from "./qml-runtime.steps.ts";
import { LIST_PANE_WIDTH } from "../../../src/components/ChatView.layout.ts";
import { addProject, flush } from "../environment.ts";
import { openOnThread } from "./composer.steps.ts";
import {
  boot,
  findObject,
  geometry,
  pressKey,
  resize,
  settle,
  snapshot,
  typeText,
  type World,
} from "../world.ts";

const NARROW_COLUMNS = 70;

const currentStatus = (ctx: World) => (ctx.host!.state.get("status") as { text: string }).text;
const statusLabel = (ctx: World) => (ctx.host!.state.get("statusRow") as { label: string }).label;

step("the terminal is {int} columns wide", async (ctx: World, columns: number) => {
  await resize(ctx, columns);
});

step("the user presses {string}", async (ctx: World, key: string) => {
  await pressKey(ctx, key);
});

step("the thread list is docked beside the conversation at full height", async (ctx: World) => {
  await snapshot(ctx);
  const sidebar = geometry(findObject(ctx, "sidebar"));
  const main = geometry(findObject(ctx, "main"));
  expect(sidebar).toMatchObject({ visible: true, x: 0, width: LIST_PANE_WIDTH });
  expect(sidebar.height).toBe(ctx.rows!);
  expect(main.visible).toBe(true);
  expect(rectOf(ctx, "main").x).toBe(LIST_PANE_WIDTH);
  expect(main.width).toBe(ctx.columns! - LIST_PANE_WIDTH);
});

step("the thread list is hidden", async (ctx: World) => {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "sidebar")).visible).toBe(false);
});

step("the conversation takes the full width", async (ctx: World) => {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "main"))).toMatchObject({
    visible: true,
    x: 0,
    width: ctx.columns!,
  });
});

async function expectListOverConversation(ctx: World): Promise<void> {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "sidebar"))).toMatchObject({
    visible: true,
    x: 0,
    width: ctx.columns!,
  });
  expect(geometry(findObject(ctx, "mainColumn")).visible).toBe(false);
  expect(findObject(ctx, "sidebarFilter").get("focused")).toBe(true);
}

step(
  "the thread list opens over the conversation with the filter focused",
  expectListOverConversation,
);

step("the thread list is open over the conversation on a narrow terminal", async (ctx: World) => {
  await resize(ctx, NARROW_COLUMNS);
  await pressKey(ctx, "Ctrl+F");
  await expectListOverConversation(ctx);
});

step("the thread list closes and the conversation has the full width again", async (ctx: World) => {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "sidebar")).visible).toBe(false);
  expect(findObject(ctx, "sidebarFilter").get("focused")).toBe(false);
  expect(geometry(findObject(ctx, "main"))).toMatchObject({
    visible: true,
    x: 0,
    width: ctx.columns!,
  });
});

step(
  "the status line says {string} until the first snapshot arrives",
  async (ctx: World, text: string) => {
    const app = await boot(ctx);
    expect(currentStatus(ctx)).toBe(text);
    expect(await app.snapshot()).toContain(statusLabel(ctx));
    ctx.fake!.connect();
    expect(await app.snapshot()).not.toContain(text);
  },
);

// --- added by T1 ---

// A connected environment holding one project (and nothing else yet). T2's
// thread world (threadWorld.ts `openThread`) boots on this project too.
step("a connected environment with the project {string}", (ctx: World, title: string) => {
  addProject(ctx, title);
});

// Typing lands where the keys are (prompt, filter, add-project path, terminal);
// the host's in-flight calls (T5's browse and terminal writes) settle first. Raw QML
// scenarios (qml-runtime.feature) have no host.
step("the user types {string}", async (ctx: World, text: string) => {
  await boot(ctx);
  await typeText(ctx, text);
  await ctx.host?.settled();
  await flush(ctx);
});

// The status message: the status line shows it (T2's "the user is told" too).
// The row shows the glyph and message cut to 32 cells, as the OpenTUI client does.
async function expectStatusLine(ctx: World, text: string) {
  await flush(ctx);
  expect(currentStatus(ctx)).toBe(text);
  expect(await snapshot(ctx)).toContain(statusLabel(ctx));
}

// "says"/"reads" is the outcome: in-flight calls land first. "is told" reads
// the line as it is now, so a busy message ("Clearing terminal…") is seen, and
// only waits for the host when the message is not there yet (a failed request).
step(/^the status line (?:says|reads) "([^"]*)"$/, async (ctx: World, text: string) => {
  await settle(ctx);
  await expectStatusLine(ctx, text);
});
step("the user is told {string}", async (ctx: World, text: string) => {
  await flush(ctx);
  if (ctx.app && currentStatus(ctx) !== text) await settle(ctx);
  await expectStatusLine(ctx, text);
});

// --- merged T1 + T2 ---

// Nothing is in the prompt: T1's layout Given and T2's "keys went to the
// approval, not the prompt" both read the prompt field and the composer key.
// As a Given, a draft left in the prompt is cleared (Esc) first.
step("the prompt is empty", async (ctx: World) => {
  await boot(ctx);
  const composer = () => ctx.host!.state.get("composer") as { text?: string } | undefined;
  if (ctx.stepType !== "Outcome" && (composer()?.text ?? "") !== "") await pressKey(ctx, "Esc");
  await settle(ctx);
  const field = findObject(ctx, "composerInput");
  expect(field.get("plainText") ?? field.get("text")).toBe("");
  expect(composer()?.text ?? "").toBe("");
});

// --- added by T4 ---

// Given: the client runs (on a thread, when nothing booted it yet). Then and
// Given alike: keys go to the prompt, not a menu, panel or the terminal drawer.
step("the prompt has focus", async (ctx: World) => {
  if (ctx.stepType !== "Outcome" && !ctx.host) await openOnThread(ctx);
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("compose");
  const terminal = ctx.host!.state.get("terminal") as { focused: boolean } | undefined;
  expect(terminal?.focused ?? false).toBe(false);
  expect(findObject(ctx, "composerInput").get("focus")).toBe(true);
});

step("the user presses escape", async (ctx: World) => {
  await pressKey(ctx, "Esc");
});

// --- added by T6 ---

// "opentui-qml …" and the client entry run programs; their exit status is the
// CLI's (qml-runtime) when one ran, else the client's.
step("it exits with status {int}", (ctx: World, status: number) =>
  ctx.cli ? expectCliStatus(ctx, status) : expectClientStatus(ctx, status),
);
