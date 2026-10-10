// tui/appearance.feature: the client with mouse support turned off. The real
// entry is started to see what it asks of the terminal; the keyboard routes
// are checked against every mouse handler in the bricks and driven in-process.
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { KEYMAP_LAYERS } from "../../../src/keymap.ts";
import { mouseDisabled, tuiRendererConfig } from "../../../src/terminalStartup.ts";
import { step } from "../../steps.ts";
import { shell, thread } from "../fakeClient.ts";
import {
  baseDir,
  launchSetup,
  leaveDirect,
  runningMc,
  startDirect,
  type LaunchWorld,
} from "../launchWorld.ts";
import { chooseCommand, palette } from "../threadUi.ts";
import { checkpoint, message, openThread, type ThreadWorld } from "../threadWorld.ts";
import { pressKey, QML_DIR, settle, typeText, type World } from "../world.ts";

type MouseWorld = LaunchWorld & ThreadWorld & { mouseOffOutput?: string; mouseOnOutput?: string };

// The sequences that ask a terminal to report the mouse (X10, button, any-motion, SGR).
const MOUSE_REPORTING = ["\x1b[?1000h", "\x1b[?1002h", "\x1b[?1003h", "\x1b[?1006h"];
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;

/** Start the real client against a fake MC, let it draw, leave, and return what it wrote. */
async function clientOutput(ctx: MouseWorld, mouse: string | undefined): Promise<string> {
  launchSetup(ctx).env.HAL_C2_TUI_MOUSE = mouse;
  runningMc(ctx);
  await startDirect(ctx, ["--base-dir", baseDir(ctx)]);
  expect(ctx.direct, ctx.client?.stderr).toBeDefined();
  return (await leaveDirect(ctx)).stdout;
}

step(
  "the user starts the terminal client with mouse support turned off",
  async (ctx: MouseWorld) => {
    expect(mouseDisabled({ HAL_C2_TUI_MOUSE: "0" })).toBe(true);
    expect(tuiRendererConfig({ HAL_C2_TUI_MOUSE: "0" }).useMouse).toBe(false);
    expect(tuiRendererConfig({}).useMouse).toBe(true);
    ctx.mouseOffOutput = await clientOutput(ctx, "0");
  },
);

step("clicks and wheel events go to the terminal emulator", async (ctx: MouseWorld) => {
  // The client never asked the terminal to report the mouse, so the emulator keeps it.
  for (const sequence of MOUSE_REPORTING) expect(ctx.mouseOffOutput).not.toContain(sequence);
  // Started the usual way it does ask: the check above is not vacuous.
  ctx.mouseOnOutput = await clientOutput(ctx, undefined);
  expect(MOUSE_REPORTING.some((sequence) => ctx.mouseOnOutput!.includes(sequence))).toBe(true);
});

// --- Every mouse action has a keyboard route ----------------------------------------------

/** A key: the action (or the one that does the same) is bound in a keymap layer. */
const KEY: Record<string, string> = {
  "composer.effortPicker.toggle": "composer.effortPicker.toggle",
  "composer.focus": "composer.focus",
  "composer.interactionMode.toggle": "composer.interactionMode.toggle",
  "composer.modelPicker.toggle": "composer.modelPicker.toggle",
  "composer.runtimePicker.toggle": "composer.runtimePicker.toggle",
  "git.log.dismiss": "git.log.dismiss",
  "image.close": "image.close",
  "palette.run": "palette.run",
  "project.add.action": "project.add.action",
  "sidebar.filter.focus": "sidebar.filter.focus",
  "section.activate": "section.activate",
  // The click's keyboard twin.
  "contextMenu.select": "contextMenu.run",
  "contextMenu.hover": "contextMenu.next",
  "files.select": "files.activate",
  "git.activate": "rightPanel.activate",
  "project.add.focusInput": "project.add.toggleFocus",
  "project.add.select": "project.add.activate",
  "select.choose": "select.confirm",
  "sidebar.scroll": "thread.next",
  "terminal.scroll": "terminal.scroll.lineUp",
};
/** A palette entry: a command that dispatches this action is defined. */
const PALETTE: Record<string, string> = {
  "composer.attachment.remove": "composer.attachment.remove",
  "composer.branchPicker.toggle": "composer.branchPicker.toggle",
  "composer.workspacePicker.toggle": "composer.workspacePicker.toggle",
  "composer.optionsPicker.toggle": "composer.optionsPicker.toggle",
  "composer.reference.remove": "composer.reference.remove",
  "composer.context.remove": "composer.context.remove",
  "project.add": "project.add",
  "sidebar.scopePicker.toggle": "sidebar.scopePicker.toggle",
  "sidebar.section.toggle": "sidebar.section.toggle",
  "terminal.close": "terminal.close",
  "terminal.new": "terminal.new",
  "terminal.select": "terminal.next",
  "update.notice.dismiss": "update.notice.dismiss",
  "section.open": "section.open",
  "notification.action": "reach.notifications",
  "notification.dismiss": "reach.notifications",
};
/** Bricks whose click runs whatever the host put on the row; each has its own route. */
const DYNAMIC: Record<string, string> = {
  "TimelineLine.qml": "reach.timeline",
  "PlanStatus.qml": "thread.open",
  "SidebarThreadRow.qml": "reach.threadMenu",
  "ContextMenu.qml": "contextMenu.run",
  "ComposerFooter.qml": "composer.submit",
  "ImageViewer.qml": "image.close",
  "TerminalDrawer.qml": "terminal.scroll.lineUp",
  "Sidebar.qml": "thread.next",
};

const boundActions = new Set(
  Object.values(KEYMAP_LAYERS as Record<string, Record<string, string>>).flatMap((layer) =>
    Object.values(layer),
  ),
);
function sourceFiles(dir: string): string[] {
  return NodeFS.readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory()
      ? sourceFiles(NodePath.join(dir, entry.name))
      : entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts")
        ? [NodePath.join(dir, entry.name)]
        : [],
  );
}
const HOST_SOURCE = sourceFiles(NodePath.resolve(QML_DIR, "../src"))
  .map((file) => NodeFS.readFileSync(file, "utf8"))
  .join("\n");
const definesCommand = (action: string) => HOST_SOURCE.includes(`action: "${action}"`);

function mouseHandlers() {
  const dir = NodePath.join(QML_DIR, "HalC2/Tui");
  const literal = new Set<string>();
  const dynamic = new Set<string>();
  for (const name of NodeFS.readdirSync(dir).filter((file) => file.endsWith(".qml"))) {
    const lines = NodeFS.readFileSync(NodePath.join(dir, name), "utf8").split("\n");
    lines.forEach((line, at) => {
      if (!/onMouse(Down|Up|Scroll|Drag)/.test(line)) return;
      // The handler's body: this line, or the block it opens.
      const body = lines.slice(at, at + 6).join("\n");
      const actions = [...body.matchAll(/Shell\.dispatch\("([a-zA-Z.]+)"/g)].map((m) => m[1]!);
      if (actions.length === 0 || /dispatch\((?!")/.test(lines[at]!)) dynamic.add(name);
      for (const action of actions) literal.add(action);
    });
  }
  return { literal: [...literal].toSorted(), dynamic: [...dynamic].toSorted() };
}

step("every action is still reachable from the keyboard", async (ctx: MouseWorld) => {
  const handlers = mouseHandlers();
  // The scan sees the bricks (a broken scan would pass everything below).
  expect(handlers.literal.length).toBeGreaterThan(25);
  expect(handlers.literal).toContain("select.choose");
  expect(handlers.dynamic).toContain("TimelineLine.qml");
  // Every action a brick dispatches from a mouse handler has a key or a palette entry.
  const unrouted = handlers.literal.filter((action) => !(action in KEY) && !(action in PALETTE));
  expect(unrouted).toEqual([]);
  for (const [action, key] of Object.entries(KEY)) {
    expect(boundActions.has(key), `${action}: no chord runs ${key}`).toBe(true);
  }
  for (const [action, command] of Object.entries(PALETTE)) {
    expect(definesCommand(command), `${action}: no palette command runs ${command}`).toBe(true);
  }
  // Bricks that run whatever action the host put on a row are all accounted for.
  expect(handlers.dynamic.filter((name) => !(name in DYNAMIC))).toEqual([]);
  for (const route of Object.values(DYNAMIC)) {
    expect(boundActions.has(route) || definesCommand(route), `no route ${route}`).toBe(true);
  }

  // And they work: with no mouse, open a changed file from the conversation…
  const [first] = shell().threads;
  await openThread(
    ctx,
    {
      ...thread(),
      messages: [
        message("m-1", "user", "Fix the rounding", 1),
        message("m-2", "assistant", "Done.", 5, { turnId: "turn-1" } as never),
      ],
      checkpoints: [checkpoint(1, ["src/cart.ts"], 6, "m-2")],
    } as never,
    { shellSnapshot: shell([first!, { ...first!, id: "t2" as never, title: "Thread two" }]) },
  );
  await chooseCommand(ctx, "Conversation actions…");
  await settle(ctx);
  const file = select(ctx).options.findIndex((option) => option.label.includes("cart.ts"));
  expect(file).toBeGreaterThanOrEqual(0);
  expect(select(ctx).options[file]!.description).toBe("diff.open");
  await typeText(ctx, "cart.ts");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("diff");
  await pressKey(ctx, "Esc");

  // …answer a notification about another thread…
  const current = ctx.fake!.latestShell();
  ctx.fake!.emitShell({
    ...current,
    threads: current.threads.map((row) =>
      row.id === "t2" ? { ...row, hasPendingApprovals: true } : row,
    ),
  } as never);
  await settle(ctx);
  await chooseCommand(ctx, "Notifications…");
  await settle(ctx);
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "Open: Approval needed · Thread two",
    "Dismiss: Approval needed · Thread two",
  ]);
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(ctx.host!.state.get("page")).toMatchObject({ kind: "thread", threadId: "t2" });

  // …and reach the thread menu.
  await chooseCommand(ctx, "Thread menu…");
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("contextMenu");
  expect(palette(ctx).open).toBe(false);
});
