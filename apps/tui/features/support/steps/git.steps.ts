// Steps for tui/git.feature and source-control/git-actions.feature: the
// source-control panel, its action list and what running an action asks of
// the server.
import { expect } from "bun:test";

import type { TuiLayoutState } from "../../../src/host/layoutState.ts";
import { step } from "../../steps.ts";
import { rectOf } from "../design.ts";
import { runLaunch } from "../launchWorld.ts";
import { runStorageLaunch, type StorageWorld } from "../storageWorld.ts";
import { runOpentuiQml } from "./qml-runtime.steps.ts";
import {
  CHECKOUTS,
  PR_URL,
  changes,
  focusPanel,
  gitState,
  hostMode,
  moveTo,
  panelState,
  ready,
  runAction,
  runFromPanel,
  scm,
  setCheckout,
  settle,
  statusText,
  vcsStatus,
} from "../gitWorld.ts";
import { chooseCommand } from "../threadUi.ts";
import { findObject, geometry, pressKey, typeText, type World } from "../world.ts";

const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Checkout phrases only git.feature uses, on top of the shared ones. */
const BRANCHES: Record<string, Partial<Parameters<typeof vcsStatus>[0]>> = {
  ...CHECKOUTS,
  "has no uncommitted changes and is ahead of its upstream": { aheadCount: 1 },
  "has an open pull request": CHECKOUTS["'s branch has an open pull request"]!,
};

function phrases(table: Record<string, unknown>, prefix: string): RegExp {
  const alternatives = Object.keys(table)
    .filter((key) => !key.startsWith("'"))
    .map(escape)
    .join("|");
  return new RegExp(`^${prefix}(${alternatives})$`);
}

/** Start a git action that never finishes, so the checkout stays busy. */
async function busy(ctx: World): Promise<void> {
  await ready(ctx);
  ctx.fake!.setGitOutcome({ kind: "hang" });
  ctx.host!.dispatch("git.run", { action: "push", label: "Push" });
  await settle(ctx);
  expect(gitState(ctx).busy).toBe(true);
}

// --- checkouts ---

step(
  "the terminal client is open on a thread whose workspace is a git repository",
  (ctx: World) => {
    scm(ctx);
    // Behind its upstream on a clean tree: the quick action pulls, and the menu
    // has a disabled Commit and Push to walk onto.
    setCheckout(ctx, vcsStatus({ behindCount: 1 }));
  },
);

step("a connected environment with a thread in the git project {string}", (ctx: World) => {
  scm(ctx);
});

step(phrases(BRANCHES, "the branch "), (ctx: World, phrase: string) => {
  setCheckout(ctx, vcsStatus(BRANCHES[phrase]));
});

step(phrases(CHECKOUTS, "the checkout "), (ctx: World, phrase: string) => {
  setCheckout(ctx, vcsStatus(CHECKOUTS[phrase]));
});

step("the checkout's branch has an open pull request", (ctx: World) => {
  setCheckout(ctx, vcsStatus(CHECKOUTS["'s branch has an open pull request"]));
});

step("the workspace has uncommitted changes", (ctx: World) => {
  setCheckout(ctx, vcsStatus(changes("src/cart.ts", "src/tax.ts")));
});

step("the workspace has no uncommitted changes", (ctx: World) => {
  setCheckout(ctx, vcsStatus());
});

step("the repository has no primary remote", (ctx: World) => {
  setCheckout(ctx, vcsStatus({ hasPrimaryRemote: false, hasUpstream: false }));
});

step("the thread's workspace is not a git repository", (ctx: World) => {
  setCheckout(ctx, vcsStatus({ isRepo: false, hasPrimaryRemote: false, hasUpstream: false }));
});

step("git status could not be read", (ctx: World) => setCheckout(ctx, null));
step("the checkout has no status yet", (ctx: World) => setCheckout(ctx, null));

step("the branch has a git action already running", busy);
step("a git action is running", busy);
step("the checkout is running another git action", busy);

step("the user's terminal does not support OSC 52", (ctx: World) => {
  ctx.clipboardSupported = false;
});

// --- the panel ---

step("the source-control panel is open", focusPanel);
step("the source-control panel has focus", focusPanel);
step("the user looks at the thread's git actions", focusPanel);
step("the user looks at the thread's git actions in the terminal client", focusPanel);
step("the user opens the git menu", focusPanel);

step("the source-control panel opens with its first action highlighted", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(panelState(ctx)).toMatchObject({ visible: true, focused: true });
  expect(hostMode(ctx)).toBe("panel");
  expect(gitState(ctx).selectedIndex).toBe(0);
  expect(geometry(findObject(ctx, "sourceControlPanel")).visible).toBe(true);
  expect(screen).toContain(`▸ ${gitState(ctx).actions[0]!.label}`);
});

step("it shows the branch's sync state and change counts", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(screen).toContain("on feature/tax");
  expect(screen).toContain("↓1 upstream");
  expect(screen).toContain("working tree clean");
});

// keymap.feature: the panel's keys on a fresh panel, which opens on its first action.
step(/^the (next|previous) git action is highlighted$/, async (ctx: World, which: string) => {
  const screen = await settle(ctx);
  const { actions, selectedIndex } = gitState(ctx);
  expect(actions.length).toBeGreaterThan(1);
  expect(selectedIndex).toBe(which === "next" ? 1 : actions.length - 1);
  expect(screen).toContain(`▸ ${actions[selectedIndex]!.label}`);
});

step("the highlighted git action runs", async (ctx: World) => {
  await settle(ctx);
  const action = gitState(ctx).actions[gitState(ctx).selectedIndex]!;
  expect(action).toMatchObject({ label: "Pull", kind: "pull", disabled: false });
  expect(ctx.fake!.gitCalls).toEqual([{ method: "runGitPull", cwd: "/workspace/shop" }]);
});

step("focus returns to the conversation", async (ctx: World) => {
  await settle(ctx);
  // On a narrow terminal the panel stood in for the conversation and closes;
  // git.feature covers the wide terminal, where it stays open.
  expect(hostMode(ctx)).toBe("compose");
  expect(panelState(ctx).focused).toBe(false);
  expect(geometry(findObject(ctx, "conversation")).visible).toBe(true);
  expect(findObject(ctx, "composerInput").get("focus")).toBe(true);
});

step("the source-control panel closes", async (ctx: World) => {
  await settle(ctx);
  expect(panelState(ctx).visible).toBe(false);
  expect(hostMode(ctx)).toBe("compose");
  expect(() => findObject(ctx, "sourceControlPanel")).toThrow();
});

step("the source-control panel has focus on the pull request link", async (ctx: World) => {
  await moveTo(ctx, "View PR");
  expect(gitState(ctx).actions[gitState(ctx).selectedIndex]!.kind).toBe("url");
});

step("the panel closes", async (ctx: World) => {
  await settle(ctx);
  expect(panelState(ctx).visible).toBe(false);
  expect(() => findObject(ctx, "sourceControlPanel")).toThrow();
});

step("the panel stays visible", async (ctx: World) => {
  await settle(ctx);
  expect(panelState(ctx)).toMatchObject({ visible: true, focused: false });
  expect(panelState(ctx).asMain).toBe(false);
  const panel = geometry(findObject(ctx, "sourceControlPanel"));
  expect(panel).toMatchObject({ visible: true, width: panelState(ctx).width });
  expect(geometry(findObject(ctx, "conversation")).visible).toBe(true);
});

step("the quick action is {string}", async (ctx: World, label: string) => {
  await ready(ctx);
  expect(gitState(ctx).quickAction.label).toBe(label);
  expect(gitState(ctx).actions[0]).toMatchObject({ label, primary: true, disabled: false });
});

step("the recommended action is {string}", async (ctx: World, label: string) => {
  const screen = await settle(ctx);
  expect(gitState(ctx).actions[0]).toMatchObject({ label, primary: true, disabled: false });
  expect(screen).toContain(`▸ ${label}`);
});

step("the recommended action is unavailable", async (ctx: World) => {
  await settle(ctx);
  expect(gitState(ctx).actions[0]).toMatchObject({ primary: true, disabled: true });
});

async function expectPanelHint(ctx: World, text: string): Promise<void> {
  const screen = await settle(ctx);
  expect(String(findObject(ctx, "gitHint").get("text")).trim()).toBe(text);
  expect(screen).toContain(text);
}

step("the reason given is {string}", expectPanelHint);
step("the panel shows {string}", expectPanelHint);

step("the quick action is disabled with {string}", async (ctx: World, reason: string) => {
  await ready(ctx);
  expect(gitState(ctx).quickAction.disabledReason).toBe(reason);
  expect(gitState(ctx).actions[0]).toMatchObject({ disabled: true, hint: reason });
});

step("the user selects the quick action", async (ctx: World) => {
  await focusPanel(ctx);
  expect(gitState(ctx).selectedIndex).toBe(0);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the user moves onto the disabled {string} action", async (ctx: World, label: string) => {
  await moveTo(ctx, label);
  expect(gitState(ctx).actions[gitState(ctx).selectedIndex]).toMatchObject({
    label,
    disabled: true,
  });
});

step("{string} is unavailable because {string}", async (ctx: World, label: string, why: string) => {
  const index = gitState(ctx).actions.findIndex(
    (action) => action.id.startsWith("menu-") && action.label === label,
  );
  expect(index).toBeGreaterThan(0);
  while (gitState(ctx).selectedIndex !== index) await pressKey(ctx, "Down");
  expect(gitState(ctx).actions[index]!.disabled).toBe(true);
  await expectPanelHint(ctx, why);
});

step("commit, push and the pull request action are all disabled", async (ctx: World) => {
  await settle(ctx);
  const menu = gitState(ctx).menu;
  expect(menu.map((item) => item.id)).toEqual(["commit", "push", "pr"]);
  for (const item of menu) expect(item.disabledReason).toBe("A git action is already in progress.");
  expect(gitState(ctx).actions.every((action) => action.disabled)).toBe(true);
});

step("pushing and opening a pull request are unavailable", async (ctx: World) => {
  await settle(ctx);
  const menu = gitState(ctx).menu;
  expect(menu.find((item) => item.id === "push")?.disabledReason).toBeTruthy();
  expect(menu.find((item) => item.id === "pr")?.disabledReason).toBeTruthy();
  expect(menu.find((item) => item.id === "commit")?.disabledReason).toBeNull();
});

step("the user is told to create and check out a branch first", (ctx: World) =>
  expectPanelHint(ctx, "Create and checkout a ref before pushing or opening a PR."),
);

step("publishing is unavailable", async (ctx: World) => {
  await settle(ctx);
  expect(gitState(ctx).canPublish).toBe(false);
  expect(gitState(ctx).actions[0]).toMatchObject({ label: "Publish repository", disabled: true });
});

step("the panel menu offers only {string}", async (ctx: World, label: string) => {
  await focusPanel(ctx);
  expect(gitState(ctx).menu.map((item) => item.label)).toEqual([label]);
  const menuRows = gitState(ctx).actions.filter((action) => action.id.startsWith("menu-"));
  expect(menuRows.map((action) => action.label)).toEqual([label]);
});

step(
  "the panel says repository initialization is not available in the terminal yet",
  (ctx: World) =>
    expectPanelHint(ctx, "Repository initialization is not available in the TUI yet."),
);

// --- running actions ---

// One "the user runs" for every world: `hal-c2 …` is the real launcher (only
// `hal-c2 tui` runs here), `opentui-qml …` the runtime's CLI, palette commands
// (T5's add-project entries) go through the palette, everything else is a git
// action.
const PALETTE_COMMANDS = new Set(["Add project", "Open WSL folder"]);
step("the user runs {string}", async (ctx: World, label: string) => {
  if (label.startsWith("hal-c2 ")) {
    if (label !== "hal-c2 tui")
      throw new Error(`the user runs "${label}": only "hal-c2 tui" launches here`);
    // storage-layout.feature runs the client entry itself, to see where it reads the shell.
    if ((ctx as StorageWorld).storage) return runStorageLaunch(ctx);
    await runLaunch(ctx);
    return;
  }
  if (/^opentui-qml(?: |$)/.test(label)) return runOpentuiQml(ctx, label);
  return PALETTE_COMMANDS.has(label) ? chooseCommand(ctx, label) : runAction(ctx, label);
});
step("the user runs {string} from the keyboard", (ctx: World, label: string) =>
  runFromPanel(ctx, label),
);
step(
  "the user activates {string} with the keyboard in the terminal client",
  (ctx: World, label: string) => runFromPanel(ctx, label),
);
step("the user chooses to view the pull request", (ctx: World) => runFromPanel(ctx, "View PR"));
step("the user runs a commit-and-push action", (ctx: World) => runAction(ctx, "Commit & push"));

step("the prompt asks for a commit message", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(hostMode(ctx)).toBe("commit");
  expect(gitState(ctx).commitPrompt).not.toBeNull();
  expect(findObject(ctx, "commitMessage").get("focused")).toBe(true);
  expect(screen).toContain("Commit message for");
  expect(ctx.fake!.gitCalls).toEqual([]);
});

step("the prompt is asking for a commit message", async (ctx: World) => {
  setCheckout(ctx, vcsStatus(changes("src/cart.ts")));
  await runFromPanel(ctx, "Commit, push & PR");
  expect(hostMode(ctx)).toBe("commit");
});

step(
  "entering {string} commits, pushes and opens a pull request",
  async (ctx: World, message: string) => {
    await typeText(ctx, message);
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(ctx.fake!.gitCalls).toEqual([
      {
        method: "runGitStackedAction",
        cwd: "/workspace/shop",
        action: "commit_push_pr",
        commitMessage: message,
      },
    ]);
    expect(gitState(ctx).commitPrompt).toBeNull();
  },
);

step("no commit is made", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([]);
  expect(gitState(ctx).commitPrompt).toBeNull();
  expect(hostMode(ctx)).not.toBe("commit");
  expect(screen).not.toContain("Commit message for");
});

step("the branch is pushed without asking for a commit message", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([
    { method: "runGitStackedAction", cwd: "/workspace/shop", action: "push" },
  ]);
  expect(gitState(ctx).commitPrompt).toBeNull();
});

async function expectPulled(ctx: World): Promise<void> {
  await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([{ method: "runGitPull", cwd: "/workspace/shop" }]);
  expect(statusText(ctx)).toBe("Pulled.");
}

step("the branch is pulled from its upstream", expectPulled);
step("the action runs", expectPulled);

async function expectCopied(ctx: World): Promise<void> {
  await settle(ctx);
  expect(ctx.clipboard ?? []).toEqual([PR_URL]);
}

step("the exact pull request URL is copied to the clipboard", expectCopied);
step("the pull request link is copied", expectCopied);
step("the pull request link is copied to the clipboard", expectCopied);
step("the pull request opens on its host", expectCopied);

step("the status line says the PR link was copied", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(statusText(ctx)).toBe("PR link copied. Ctrl-click the underlined link to open it.");
  expect(screen).toContain("PR link copied.");
});

step("the status line shows {string} followed by the URL", async (ctx: World, prefix: string) => {
  const screen = await settle(ctx);
  expect(statusText(ctx)).toBe(`${prefix} ${PR_URL}`);
  expect(ctx.clipboard ?? []).toEqual([]);
  expect(screen).toContain(prefix);
});

// --- narrow terminals ---

async function expectPanelAsMain(ctx: World): Promise<void> {
  await settle(ctx);
  const layout = ctx.host!.state.get("layout") as TuiLayoutState;
  expect(layout.rightPanel.asMain).toBe(true);
  expect(geometry(findObject(ctx, "sourceControlPanel")).visible).toBe(true);
  // In the conversation pane's place, the prompt still under it.
  const pane = rectOf(ctx, "conversationPane");
  expect(rectOf(ctx, "sourceControlPanel")).toMatchObject({
    x: pane.x,
    y: pane.y,
    width: layout.mainWidth,
    height: pane.height,
  });
}

step(
  "the user opens the source-control panel and runs the highlighted action",
  async (ctx: World) => {
    await focusPanel(ctx);
    await pressKey(ctx, "Enter");
    await settle(ctx);
  },
);

step("the panel replaces the conversation while open", expectPanelAsMain);

step("the source-control panel has replaced the conversation", async (ctx: World) => {
  await focusPanel(ctx);
  await expectPanelAsMain(ctx);
});

step("the panel closes and the conversation is shown", async (ctx: World) => {
  await settle(ctx);
  expect(panelState(ctx).visible).toBe(false);
  expect(() => findObject(ctx, "sourceControlPanel")).toThrow();
  expect(geometry(findObject(ctx, "main")).visible).toBe(true);
  expect(geometry(findObject(ctx, "conversation")).visible).toBe(true);
  expect(hostMode(ctx)).toBe("compose");
});
