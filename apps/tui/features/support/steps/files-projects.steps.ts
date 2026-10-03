// Projects from the terminal (features/files/): removing one, its actions
// (run, add, edit, delete, shortcuts), and what its hal-c2.json offers. The
// project page is the `projects` settings section, opened from the palette.
import { expect } from "bun:test";
import type { ProjectScript, ProjectScriptIcon } from "@hal-c2/contracts";

import type { TuiNewThreadState, TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import {
  addProject,
  addThread,
  change,
  env,
  flush,
  projectNamed,
  threadNamed,
  ui,
} from "../environment.ts";
import { projectsMc, scriptsOf, writeProjectFile, type ScriptedProject } from "../projectsWorld.ts";
import { chooseRow, fillField, pageText, sectionState, selectRow } from "../settingsWorld.ts";
import { chooseCommand, palette, selectThread, sidebar } from "../threadUi.ts";
import { pressKey, settle, snapshot, typeText, type World } from "../world.ts";

interface FilesWorld extends World {
  /** The thread a scenario's actions run in. */
  actionThread?: string;
  /** The project's actions before the step under test. */
  scriptsBefore?: ProjectScript[];
}

const WORKTREE = "/work/shop/.worktrees/current";
const status = (ctx: World) => ctx.host!.state.get("status") as { kind: string; text: string };
const statusLabel = (ctx: World) => (ctx.host!.state.get("statusRow") as { label: string }).label;
const newThread = (ctx: World) => ctx.host!.state.get("newThread") as TuiNewThreadState | null;
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);
const writesTo = (ctx: World, thread: string, terminalId: string) =>
  ctx.fake!.terminals.get(`${threadNamed(ctx, thread).id}:${terminalId}`)?.writes ?? [];
const opened = (ctx: World, terminalId: string) =>
  callsTo(ctx, "terminalOpen")
    .map((call) => call.args[0] as Record<string, any>)
    .find((input) => input.terminalId === terminalId);

const script = (name: string, command: string, extra: Partial<ProjectScript> = {}) =>
  ({
    id: name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
    name,
    command,
    icon: "play",
    runOnWorktreeCreate: false,
    ...extra,
  }) as ProjectScript;

/** The client running on the environment, with the project side of the MC behind it. */
async function start(ctx: World) {
  projectsMc(ctx);
  await ui(ctx);
  await settle(ctx);
}

/** A thread of `project` is open (the scenario's own, or one made for it). */
async function inThread(ctx: FilesWorld, project = "shop"): Promise<string> {
  if (!ctx.actionThread) {
    const existing = env(ctx).threads.find(
      (thread) => thread.projectId === projectNamed(ctx, project).id,
    );
    ctx.actionThread = existing?.title ?? "Current work";
    if (!existing) {
      // `change` pushes the new thread to a client that is already connected.
      change(ctx, () => void addThread(ctx, ctx.actionThread!, { project }));
    }
  }
  await start(ctx);
  await selectThread(ctx, ctx.actionThread);
  await settle(ctx);
  return ctx.actionThread;
}

async function openProjectPage(ctx: World, project: string): Promise<void> {
  await start(ctx);
  // A page left open by an earlier step is closed first (Ctrl+P), as a user would.
  if (sectionState(ctx).open) ctx.host!.dispatch("section.close");
  await chooseCommand(ctx, `Project actions: ${project}`);
  await settle(ctx);
  expect(sectionState(ctx)).toMatchObject({ id: "projects", title: `project · ${project}` });
}

const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;

/** Run a project action by name: the palette's own entry for the one offered first, else the picker. */
async function runAction(ctx: FilesWorld, name: string): Promise<void> {
  await inThread(ctx);
  if (sectionState(ctx).open) ctx.host!.dispatch("section.close");
  if (scriptsOf(ctx, "shop").length === 1) {
    await chooseCommand(ctx, `Run ${name}`);
  } else {
    await chooseCommand(ctx, "Run a project script…");
    const index = select(ctx).options.findIndex((option) => option.label === name);
    expect(index, `no "${name}" among the scripts`).toBeGreaterThanOrEqual(0);
    for (let at = select(ctx).index; at < index; at += 1) await pressKey(ctx, "Down");
    for (let at = select(ctx).index; at > index; at -= 1) await pressKey(ctx, "Up");
    await pressKey(ctx, "Enter");
  }
  await settle(ctx);
}

// --- Environments -------------------------------------------------------------

step(
  "a connected environment {string} with the project {string} at {string}",
  (ctx: World, _machine: string, title: string, root: string) => {
    addProject(ctx, title).workspaceRoot = root;
    projectsMc(ctx);
  },
);

step("{string} has the action {string} running {string}", (ctx: World, project, name, command) => {
  projectsMc(ctx);
  scriptsOf(ctx, project).push(script(name, command));
});

step(
  "{string} already has an action {string} running {string}",
  (ctx: World, project, name, command) => {
    projectsMc(ctx);
    scriptsOf(ctx, project).push(script(name, command));
  },
);

// --- Removing a project ---------------------------------------------------------

step("{string} has {int} threads", (ctx: World, project: string, count: number) => {
  for (let index = 1; index <= count; index += 1) addThread(ctx, `Thread ${index}`, { project });
});

step("the user asks to remove {string}", async (ctx: World, project: string) => {
  await start(ctx);
  await chooseCommand(ctx, `Remove project ${project}…`);
  await settle(ctx);
  expect(select(ctx)).toMatchObject({
    open: true,
    title: `remove ${project}? its files on disk are kept`,
  });
});

/** What removing would do, as the question's "Remove" choice says it. */
const removal = (ctx: World) =>
  select(ctx).options.find((option) => option.label.startsWith("Remove "))?.description ?? "";
const question = (ctx: World) => (sectionState(ctx).confirm?.lines ?? []).join(" ");
/** The screen's words, borders dropped and wrapped lines joined. */
const screenWords = async (ctx: World) =>
  (await snapshot(ctx)).replace(/[│╭╮╰╯─]/g, " ").replace(/\s+/g, " ");

step(
  "the user is told {int} threads and their conversation history will be cleared",
  async (ctx: World, count: number) => {
    expect(removal(ctx)).toBe(`Clears its ${count} threads and their conversation history.`);
    expect(await screenWords(ctx)).toContain(removal(ctx));
    // Nothing was removed by asking.
    expect(projectsMc(ctx).mutations).toEqual([]);
  },
);

step("the user is told the files on disk are kept", async (ctx: World) => {
  expect(select(ctx).title).toContain("its files on disk are kept");
  expect(await screenWords(ctx)).toContain("remove shop? its files on disk are kept");
  // Keeping it is the first answer.
  expect(select(ctx).options[select(ctx).index]?.label).toBe("Keep shop");
});

step("{string} has an unsent draft", async (ctx: World, project: string) => {
  await start(ctx);
  await pressKey(ctx, "Ctrl+N");
  await typeText(ctx, "Fix the checkout");
  await settle(ctx);
  expect(newThread(ctx)?.projectName).toBe(project);
  expect(sidebar(ctx).drafts).toHaveLength(1);
});

step("the user confirms removing {string}", async (ctx: World, project: string) => {
  await start(ctx);
  await chooseCommand(ctx, `Remove project ${project}…`);
  await settle(ctx);
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    `Keep ${project}`,
    `Remove ${project}`,
  ]);
  await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("{string} is no longer listed for {string}", async (ctx: World, project: string) => {
  const screen = await settle(ctx);
  expect(projectsMc(ctx).mutations).toEqual([
    expect.objectContaining({ type: "project.delete", projectId: "p-shop" }),
  ]);
  expect(sidebar(ctx).projects.map((entry) => entry.displayName)).not.toContain(project);
  expect(env(ctx).projects).toEqual([]);
  // Nothing of it is left on screen, and the user is told its folder was not touched.
  expect(
    screen
      .split("\n")
      .filter((line) => !line.includes(`Removed ${project}`))
      .join("\n"),
  ).not.toContain(project);
  expect(status(ctx)).toEqual({
    kind: "success",
    text: `Removed ${project}; /home/sam/shop is untouched.`,
  });
});

step("the draft for {string} is gone", async (ctx: World, _project: string) => {
  await settle(ctx);
  expect(newThread(ctx)).toBeNull();
  expect(sidebar(ctx).drafts).toEqual([]);
  expect((ctx.host!.state.get("page") as { kind: string }).kind).not.toBe("draft");
});

step("{string} is still listed for {string}", async (ctx: World, project: string) => {
  await settle(ctx);
  expect(sidebar(ctx).projects.map((entry) => entry.displayName)).toContain(project);
  expect(env(ctx).projects.map((entry) => entry.title)).toContain(project);
  // The question is closed.
  expect(select(ctx).open).toBe(false);
});

step("the environment refuses to change projects with {string}", (ctx: World, reason: string) => {
  projectsMc(ctx).refusal = reason;
});

// The terminal's toast is its status line: the title, then what the environment said.
step(
  "the user sees an {string} toast {string} saying {string}",
  async (ctx: World, kind: string, title: string, message: string) => {
    const screen = await settle(ctx);
    expect(status(ctx)).toEqual({ kind, text: `${title}: ${message}` });
    expect(screen).toContain(statusLabel(ctx));
  },
);

// --- Running actions ------------------------------------------------------------

step(
  "the user is looking at a thread in {string} on a worktree",
  async (ctx: FilesWorld, project: string) => {
    ctx.actionThread = "Current work";
    addThread(ctx, ctx.actionThread, { project, branch: "feature/cart", worktreePath: WORKTREE });
    await inThread(ctx, project);
  },
);

step("the user runs the action {string}", (ctx: FilesWorld, name: string) => runAction(ctx, name));

step("a terminal in the worktree runs {string}", async (ctx: FilesWorld, command: string) => {
  await settle(ctx);
  expect(opened(ctx, "term-1")).toMatchObject({ cwd: WORKTREE, worktreePath: WORKTREE });
  expect(writesTo(ctx, ctx.actionThread!, "term-1")).toEqual([`${command}\r`]);
  // The drawer shows it without taking the keys from the prompt.
  expect(ctx.host!.state.get("terminal")).toMatchObject({ open: true, activeId: "term-1" });
  expect(ctx.host!.state.get("mode")).toBe("compose");
});

step("the command knows the project folder and the worktree folder", (ctx: FilesWorld) => {
  const root = projectNamed(ctx, "shop").workspaceRoot;
  const wanted = { HAL_C2_PROJECT_ROOT: root, HAL_C2_WORKTREE_PATH: WORKTREE };
  expect(opened(ctx, "term-1")?.env).toMatchObject(wanted);
  // The shell the drawer attached to starts with them too.
  const terminal = ctx.fake!.terminals.get(`${threadNamed(ctx, ctx.actionThread!).id}:term-1`);
  expect((terminal?.attach as { env?: unknown } | null)?.env).toMatchObject(wanted);
});

step("the thread's terminal is running a command", async (ctx: FilesWorld) => {
  const thread = await inThread(ctx);
  ctx.fake!.emitTerminalMetadata({
    type: "upsert",
    terminal: {
      threadId: threadNamed(ctx, thread).id,
      terminalId: "term-1",
      cwd: projectNamed(ctx, "shop").workspaceRoot,
      worktreePath: null,
      status: "running",
      pid: 41,
      exitCode: null,
      exitSignal: null,
      hasRunningSubprocess: true,
      label: "bun test --watch",
      updatedAt: "2026-07-15T12:00:00.000Z",
    },
  } as never);
  await settle(ctx);
});

step("{string} runs in a new terminal", async (ctx: FilesWorld, command: string) => {
  await settle(ctx);
  expect(opened(ctx, "term-2")).toBeDefined();
  expect(writesTo(ctx, ctx.actionThread!, "term-2")).toEqual([`${command}\r`]);
  expect(ctx.host!.state.get("terminal")).toMatchObject({ open: true, activeId: "term-2" });
});

step("the busy terminal keeps running", (ctx: FilesWorld) => {
  expect(writesTo(ctx, ctx.actionThread!, "term-1")).toEqual([]);
  expect(callsTo(ctx, "terminalClose")).toEqual([]);
  expect(callsTo(ctx, "terminalRestart")).toEqual([]);
  const tabs = (ctx.host!.state.get("terminal") as { tabs: Array<{ id: string }> }).tabs;
  expect(tabs.map((tab) => tab.id)).toEqual(["term-1", "term-2"]);
});

// "mod+shift+d", as the server resolves it for a `script.<id>.run` rule.
step("{string} has the shortcut {string}", (ctx: World, name: string, shortcut: string) => {
  const parts = shortcut.toLowerCase().split("+");
  env(ctx).keybindings.push({
    command: `script.${script(name, "").id}.run`,
    shortcut: {
      key: parts.at(-1)!,
      metaKey: false,
      ctrlKey: parts.includes("ctrl"),
      shiftKey: parts.includes("shift"),
      altKey: parts.includes("alt"),
      modKey: parts.includes("mod"),
    },
  });
});

step(
  "the user presses {string} in a thread of {string}",
  async (ctx: FilesWorld, shortcut: string, project: string) => {
    // Ctrl+Shift+D differs from Ctrl+D only for a terminal that reports every modifier.
    ctx.kittyKeyboard = true;
    await inThread(ctx, project);
    expect(ctx.host!.state.get("mode")).toBe("compose");
    // `mod` is Ctrl in a terminal.
    await pressKey(ctx, shortcut.replace(/^mod\+/i, "Ctrl+"));
    await settle(ctx);
  },
);

step("{string} runs in the thread's terminal", async (ctx: FilesWorld, command: string) => {
  await settle(ctx);
  expect(opened(ctx, "term-1")).toMatchObject({
    threadId: threadNamed(ctx, ctx.actionThread!).id,
    cwd: projectNamed(ctx, "shop").workspaceRoot,
  });
  expect(writesTo(ctx, ctx.actionThread!, "term-1")).toEqual([`${command}\r`]);
  // The chord ran the action; nothing was typed into the prompt.
  expect((ctx.host!.state.get("composer") as { text: string }).text).toBe("");
});

step("terminals cannot be opened for the thread", async (ctx: FilesWorld) => {
  await inThread(ctx);
  ctx.fake!.override("terminalOpen", () =>
    Promise.reject(new Error("Terminal limit reached on this machine")),
  );
});

step(
  "the user is told the action {string} failed to run",
  async (ctx: FilesWorld, name: string) => {
    const screen = await settle(ctx);
    expect(status(ctx)).toEqual({
      kind: "error",
      text: `Failed to run action "${name}": Terminal limit reached on this machine`,
    });
    expect(screen).toContain(statusLabel(ctx));
    expect(writesTo(ctx, ctx.actionThread!, "term-1")).toEqual([]);
  },
);

// --- Adding, editing and removing actions ------------------------------------------

async function fillNewAction(
  ctx: FilesWorld,
  input: { name?: string; command?: string; icon?: ProjectScriptIcon },
): Promise<void> {
  ctx.scriptsBefore = [...scriptsOf(ctx, "shop")];
  await openProjectPage(ctx, "shop");
  await chooseRow(ctx, "+ Add an action");
  expect(sectionState(ctx).title).toBe("project · shop · new action");
  if (input.name !== undefined) {
    await chooseRow(ctx, "Name");
    await fillField(ctx, input.name);
  }
  if (input.command !== undefined) {
    await chooseRow(ctx, "Command");
    await fillField(ctx, input.command);
  }
  for (let guard = 0; guard < 6 && input.icon !== undefined; guard += 1) {
    if (pageText(ctx).includes(`Icon`) && new RegExp(`Icon\\s+${input.icon}`).test(pageText(ctx))) {
      break;
    }
    await chooseRow(ctx, "Icon");
  }
  await chooseRow(ctx, "Add action");
  await settle(ctx);
}

step(
  "the user adds an action named {string} running {string} with the test icon",
  (ctx: FilesWorld, name: string, command: string) =>
    fillNewAction(ctx, { name, command, icon: "test" }),
);

step("{string} has the action {string}", async (ctx: World, project: string, name: string) => {
  await settle(ctx);
  const added = scriptsOf(ctx, project).find((entry) => entry.name === name);
  expect(added).toMatchObject({ name, command: "bun test", icon: "test", id: "test" });
  // Back on the project's page, it is listed with its command.
  expect(sectionState(ctx).title).toBe(`project · ${project}`);
  expect(pageText(ctx)).toMatch(new RegExp(`${name}\\s+bun test`));
});

step("{string} can be run", async (ctx: FilesWorld, name: string) => {
  const command = scriptsOf(ctx, "shop").find((entry) => entry.name === name)!.command;
  await runAction(ctx, name);
  expect(writesTo(ctx, ctx.actionThread!, "term-1")).toEqual([`${command}\r`]);
});

step(/^the user adds an action with (no name|no command)$/, (ctx: FilesWorld, missing: string) =>
  fillNewAction(ctx, missing === "no name" ? { command: "bun test" } : { name: "Test" }),
);

step("no action is added", async (ctx: FilesWorld) => {
  await settle(ctx);
  expect(projectsMc(ctx).mutations).toEqual([]);
  expect(scriptsOf(ctx, "shop")).toEqual(ctx.scriptsBefore!);
  // The form is still open, saying what is missing.
  expect(sectionState(ctx).title).toBe("project · shop · new action");
  expect(pageText(ctx)).toMatch(/(Name|Command) is required\./);
});

step(
  "the user changes the command of {string} to {string}",
  async (ctx: World, name: string, command: string) => {
    await openProjectPage(ctx, "shop");
    await chooseRow(ctx, name);
    await chooseRow(ctx, "Command");
    await fillField(ctx, command);
    await settle(ctx);
  },
);

step("{string} runs {string}", async (ctx: FilesWorld, name: string, command: string) => {
  expect(scriptsOf(ctx, "shop").find((entry) => entry.name === name)?.command).toBe(command);
  expect(pageText(ctx)).toContain(command);
  await runAction(ctx, name);
  expect(writesTo(ctx, ctx.actionThread!, "term-1")).toEqual([`${command}\r`]);
});

step("the user deletes the action {string}", async (ctx: World, name: string) => {
  await openProjectPage(ctx, "shop");
  await chooseRow(ctx, name);
  await chooseRow(ctx, "Delete action…");
});

step(
  "the user is asked to confirm deleting {string} because it cannot be undone",
  async (ctx: World, name: string) => {
    expect(ctx.host!.state.get("mode")).toBe("sectionConfirm");
    expect(question(ctx)).toBe(`Delete action "${name}"? This cannot be undone.`);
    expect(await snapshot(ctx)).toContain(`Delete action "${name}"? This cannot be undone.`);
    expect(projectsMc(ctx).mutations).toEqual([]);
    expect(scriptsOf(ctx, "shop").map((entry) => entry.name)).toContain(name);
  },
);

step("{string} no longer has the action {string}", async (ctx: World, project, name) => {
  await settle(ctx);
  expect(scriptsOf(ctx, project).map((entry) => entry.name)).not.toContain(name);
  expect(sectionState(ctx).title).toBe(`project · ${project}`);
  expect(pageText(ctx)).not.toContain(name);
  await pressKey(ctx, "Ctrl+P");
  await pressKey(ctx, "Ctrl+K");
  await flush(ctx);
  expect(palette(ctx).commands.map((entry) => entry.title)).not.toContain(`Run ${name}`);
});

// --- hal-c2.json ---------------------------------------------------------------------

const projectFile = (ctx: World, contents: object) =>
  writeProjectFile(ctx, "shop", "hal-c2.json", JSON.stringify(contents, null, 2));

step(
  "the checkout's hal-c2.json sets the default workspace to {string}",
  (ctx: World, mode: string) => projectFile(ctx, { defaultThreadEnvMode: mode }),
);

step("the user never chose a default workspace for {string}", (ctx: World, project: string) => {
  expect((projectNamed(ctx, project) as ScriptedProject).defaultThreadEnvMode ?? null).toBeNull();
  expect(env(ctx).defaultThreadEnvMode).toBeNull();
});

step(
  "the user set the default workspace for {string} to {string}",
  (ctx: World, project: string, mode: string) => {
    (projectNamed(ctx, project) as ScriptedProject).defaultThreadEnvMode = mode as "local";
  },
);

step("the user starts a new thread in {string}", async (ctx: World, project: string) => {
  await start(ctx);
  await pressKey(ctx, "Ctrl+N");
  await settle(ctx);
  expect(newThread(ctx)?.projectName).toBe(project);
});

step("the draft starts in a new worktree", async (ctx: World) => {
  expect(newThread(ctx)).toMatchObject({ workspaceMode: "new-worktree", worktreePath: null });
  expect(await snapshot(ctx)).toContain("New worktree");
});

step("the draft starts in the project folder", async (ctx: World) => {
  expect(newThread(ctx)).toMatchObject({ workspaceMode: "current", worktreePath: null });
  expect(await snapshot(ctx)).not.toContain("New worktree");
});

step(
  "the checkout's hal-c2.json declares the actions {string} and {string}",
  (ctx: World, first: string, second: string) =>
    projectFile(ctx, {
      scripts: [
        { name: first, command: `bun ${first.toLowerCase()}` },
        { name: second, command: `bun ${second.toLowerCase()}` },
      ],
    }),
);

step(
  "the checkout's hal-c2.json declares {string} running {string} and {string} running {string}",
  (ctx: World, first: string, firstCommand: string, second: string, secondCommand: string) =>
    projectFile(ctx, {
      scripts: [
        { name: first, command: firstCommand },
        { name: second, command: secondCommand },
      ],
    }),
);

step("the user looks at the actions of {string}", (ctx: World, project: string) =>
  openProjectPage(ctx, project),
);

step(
  "{string} and {string} are offered to import from hal-c2.json",
  async (ctx: World, first: string, second: string) => {
    const screen = await settle(ctx);
    const lines = sectionState(ctx).lines;
    const heading = lines.indexOf("From hal-c2.json");
    expect(heading).toBeGreaterThan(0);
    const offered = lines.slice(heading + 1).join("\n");
    for (const name of [first, second]) {
      expect(offered).toMatch(new RegExp(`Import ${name}\\s+bun ${name.toLowerCase()}`));
      expect(screen).toContain(`Import ${name}`);
    }
    // Offered, not added.
    expect(projectsMc(ctx).mutations).toEqual([]);
  },
);

step("the user imports actions from hal-c2.json", async (ctx: World) => {
  await openProjectPage(ctx, "shop");
  const offered = sectionState(ctx).lines.filter((line) => line.trim().startsWith("Import "));
  expect(offered.length).toBeGreaterThan(0);
  // Every offered action: the one row, or "Import all" when there are several.
  await selectRow(ctx, offered.length > 1 ? "Import all" : offered[0]!.trim().split(/\s{2,}/)[0]!);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("only {string} is added", async (ctx: World, name: string) => {
  await settle(ctx);
  expect(projectsMc(ctx).mutations).toHaveLength(1);
  expect(scriptsOf(ctx, "shop").map((entry) => [entry.name, entry.command])).toEqual([
    ["dev", "bun dev"],
    [name, `bun ${name.toLowerCase()}`],
  ]);
  // Nothing is left to import.
  expect(pageText(ctx)).not.toContain("From hal-c2.json");
});
