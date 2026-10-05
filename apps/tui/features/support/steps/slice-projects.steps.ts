// tui/files.feature: the project itself (rename, remove), its scripts run in
// the thread's terminal, and the preview links the workspace serves.
import { expect } from "bun:test";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { chooseRow, fillField, sectionState } from "../settingsWorld.ts";
import { chooseCommand } from "../threadUi.ts";
import { pressKey, settle, typeText, type World } from "../world.ts";
import { ensureOpen, type FilesWorld } from "./files.steps.ts";

type NamedWorld = FilesWorld & {
  runNamed?: (label: string) => Promise<boolean>;
  closeIt?: () => Promise<void>;
};

const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const sidebarProjects = (ctx: World) =>
  (ctx.host!.state.get("sidebar") as { projects: Array<{ displayName: string }> }).projects.map(
    (entry) => entry.displayName,
  );
const listedThreads = (ctx: World) =>
  (ctx.host!.state.get("sidebar") as { rows: Array<{ kind: string }> }).rows.filter(
    (row) => row.kind === "thread",
  ).length;
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);

// --- Projects ------------------------------------------------------------------------

step(
  "the user renames the project {string} to {string}",
  async (ctx: FilesWorld, from: string, to: string) => {
    expect(sidebarProjects(ctx)).toEqual([from]);
    await chooseCommand(ctx, `Rename project ${from}…`);
    // The field opens on the current name.
    expect(ctx.host!.state.get("ask")).toMatchObject({ label: "project name", value: from });
    for (let i = 0; i < from.length; i += 1) await pressKey(ctx, "Backspace");
    await typeText(ctx, to);
    await pressKey(ctx, "Enter");
    await settle(ctx);
  },
);

step("the project is listed as {string}", async (ctx: World, title: string) => {
  expect(callsTo(ctx, "updateProject").map((call) => call.args)).toEqual([["p1", { title }]]);
  expect(sidebarProjects(ctx)).toEqual([title]);
  // The thread's card names its project.
  expect((await objectRows(ctx, "sidebarList")).join("\n")).toContain(title);
});

step("the user removes the project {string}", async (ctx: FilesWorld, title: string) => {
  expect(listedThreads(ctx)).toBe(1);
  await chooseCommand(ctx, `Remove project ${title}…`);
  // It asks first, and says what goes and what stays.
  expect(select(ctx).options).toEqual([
    { label: `Keep ${title}`, description: "Change nothing." },
    {
      label: `Remove ${title}`,
      description: "Clears its 1 thread and its conversation history.",
    },
  ]);
  await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("{string} and its threads leave the thread list", async (ctx: World, title: string) => {
  expect(sidebarProjects(ctx)).toEqual([]);
  expect(listedThreads(ctx)).toBe(0);
  expect((await objectRows(ctx, "sidebar")).join("\n")).not.toContain(title);
});

step("the project folder on disk is untouched", (ctx: World) => {
  // One request: forget the project. Nothing writes to or removes from the workspace.
  expect(callsTo(ctx, "deleteProject").map((call) => call.args)).toEqual([["p1"]]);
  for (const method of ["writeFile", "terminalWrite", "cloneRepository"]) {
    expect(callsTo(ctx, method)).toEqual([]);
  }
  expect(ctx.fake!.server.written.size).toBe(0);
  expect(status(ctx).text).toContain("is untouched");
});

// --- Scripts ----------------------------------------------------------------------------

const COMMANDS: Record<string, string> = {
  dev: "bun dev",
  test: "bun test",
  lint: "bun lint",
  build: "bun run build",
};
export const script = (name: string, extra: Record<string, unknown> = {}) => ({
  id: name,
  name,
  command: COMMANDS[name] ?? `bun run ${name}`,
  icon: "play",
  runOnWorktreeCreate: false,
  ...extra,
});
const shellScripts = (ctx: World) =>
  (ctx.fake!.latestShell().projects[0] as unknown as { scripts?: Array<{ name: string }> })
    .scripts ?? [];
const drawer = (ctx: World) =>
  ctx.host!.state.get("terminal") as {
    open: boolean;
    lines: ReadonlyArray<{ chunks: ReadonlyArray<{ text: string }> }>;
  };
const drawerText = (ctx: World) =>
  drawer(ctx)
    .lines.map((line) => line.chunks.map((part) => part.text).join(""))
    .join("\n");
const typedIntoTerminal = (ctx: World) =>
  [...ctx.fake!.terminals.values()].flatMap((terminal) => terminal.writes).join("");

/** Choose a palette command from wherever the keys are (the drawer hands them back first). */
export async function command(ctx: World, title: string) {
  await chooseCommand(ctx, title);
  await settle(ctx);
}

/** Give the project its scripts, as a shell snapshot from the server. */
export async function setScripts(ctx: NamedWorld, scripts: Array<ReturnType<typeof script>>) {
  await ensureOpen(ctx);
  const current = ctx.fake!.latestShell();
  ctx.fake!.emitShell({
    ...current,
    projects: current.projects.map((entry) => ({ ...entry, scripts })),
  } as never);
  await settle(ctx);
  // "the user runs "test"" (git.steps.ts) runs a script by its name from the picker.
  ctx.runNamed = async (label) => {
    if (!shellScripts(ctx).some((entry) => entry.name === label)) return false;
    await command(ctx, "Run a project script…");
    const index = select(ctx).options.findIndex((option) => option.label === label);
    expect(index).toBeGreaterThanOrEqual(0);
    for (let i = select(ctx).index; i < index; i += 1) await pressKey(ctx, "Down");
    await pressKey(ctx, "Enter");
    await settle(ctx);
    return true;
  };
}

/** The program behind the thread's terminal prints `data`. */
export async function terminalPrints(ctx: World, data: string) {
  const [terminal] = [...ctx.fake!.terminals.values()];
  expect(terminal).toBeDefined();
  terminal!.emit({
    type: "output",
    threadId: terminal!.threadId,
    terminalId: terminal!.terminalId,
    createdAt: "2026-07-13T00:00:00.000Z",
    data,
  } as never);
  await settle(ctx);
}

step(
  "{string} has the preferred script {string}",
  (ctx: NamedWorld, _project: string, name: string) =>
    setScripts(ctx, [script(name), script("test")]),
);

step("the user runs the project script", (ctx: World) =>
  // The palette names the script it will run.
  command(ctx, "Run dev"),
);

step(
  "{string} runs in a terminal and its progress shows there",
  async (ctx: World, name: string) => {
    expect(drawer(ctx).open).toBe(true);
    expect(typedIntoTerminal(ctx)).toBe(`${COMMANDS[name]}\r`);
    const [terminal] = [...ctx.fake!.terminals.values()];
    expect(terminal!.attach).toMatchObject({ threadId: "t1", cwd: "~/code/shop" });
    await terminalPrints(ctx, `$ ${COMMANDS[name]}\r\nVITE ready in 120 ms\r\n`);
    expect(drawerText(ctx)).toContain("VITE ready in 120 ms");
    expect((await objectRows(ctx, "drawer")).join("\n")).toContain("VITE ready in 120 ms");
  },
);

step(
  /^"([^"]+)" has the scripts "([^"]+)", "([^"]+)" and "([^"]+)"$/,
  (ctx: NamedWorld, _project: string, ...names: string[]) =>
    setScripts(
      ctx,
      names.map((name) => script(name)),
    ),
);

step("{string} runs in a terminal", (ctx: World, name: string) => {
  expect(drawer(ctx).open).toBe(true);
  expect(typedIntoTerminal(ctx)).toBe(`${COMMANDS[name]}\r`);
  expect(status(ctx)).toEqual({ kind: "success", text: `Running ${name} in the terminal.` });
});

step("the user adds the script {string} to {string}", async (ctx: NamedWorld, name: string) => {
  await setScripts(ctx, [script("dev"), script("test")]);
  // The project's page holds its scripts (files-projects.steps.ts drives the rest of it).
  await command(ctx, "Add or edit a project script…");
  expect(sectionState(ctx)).toMatchObject({ id: "projects", title: "project · shop" });
  await chooseRow(ctx, "+ Add an action");
  await chooseRow(ctx, "Name");
  await fillField(ctx, name);
  await chooseRow(ctx, "Command");
  await fillField(ctx, COMMANDS[name]!);
  await chooseRow(ctx, "Add action");
  await settle(ctx);
  // Back to the conversation, where the scripts are run from.
  ctx.host!.dispatch("section.close");
  await settle(ctx);
});

step("{string} is offered with the other scripts", async (ctx: World, name: string) => {
  expect(callsTo(ctx, "updateProject")).toHaveLength(1);
  expect(shellScripts(ctx).map((entry) => entry.name)).toEqual(["dev", "test", name]);
  await command(ctx, "Run a project script…");
  expect(select(ctx).options).toEqual([
    { label: "dev", description: "bun dev" },
    { label: "test", description: "bun test" },
    { label: name, description: COMMANDS[name]! },
  ]);
  // And it runs like the others.
  await pressKey(ctx, "Down");
  await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(typedIntoTerminal(ctx)).toBe(`${COMMANDS[name]}\r`);
});

// --- Previews -----------------------------------------------------------------------------

const PREVIEW_URL = "http://localhost:5173";

step("the dev server announced {string}", async (ctx: NamedWorld, url: string) => {
  await setScripts(ctx, [script("dev")]);
  await command(ctx, "Run dev");
  await terminalPrints(ctx, `  ➜  Local:   ${url}\r\n`);
  expect(drawerText(ctx)).toContain(url);
});

step("the user opens the preview list", (ctx: World) => command(ctx, "Previews"));

step("{string} is listed and can be opened or copied", async (ctx: World, url: string) => {
  expect(select(ctx)).toMatchObject({ open: true, title: "previews" });
  expect(select(ctx).options).toEqual([{ label: url, description: "seen in the terminal" }]);
  // Copied: for the user's own browser.
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "Open as a preview",
    "Copy link",
  ]);
  await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(ctx.clipboard).toEqual([url]);
  // Opened: it becomes one of the thread's previews.
  await command(ctx, "Previews");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(callsTo(ctx, "openPreview").map((call) => call.args)).toEqual([["t1", url]]);
  await command(ctx, "Previews");
  expect(select(ctx).options).toEqual([{ label: url, description: "open preview" }]);
});

step("a preview is open", async (ctx: NamedWorld) => {
  await ensureOpen(ctx);
  await ctx.fake!.client.openPreview("t1" as never, PREVIEW_URL);
  ctx.fake!.calls.length = 0;
  await command(ctx, "Previews");
  expect(select(ctx).options).toEqual([{ label: PREVIEW_URL, description: "open preview" }]);
  // "the user closes it" (terminal.steps.ts) closes what this Given opened.
  ctx.closeIt = async () => {
    await pressKey(ctx, "Enter");
    await settle(ctx);
    // An open preview refreshes and closes; one only seen in the terminal opens.
    expect(select(ctx).options.map((option) => option.label)).toEqual([
      "Copy link",
      "Refresh",
      "Close preview",
    ]);
    await pressKey(ctx, "Down");
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(callsTo(ctx, "refreshPreview").map((call) => call.args)).toEqual([["t1", "tab-1"]]);
    await command(ctx, "Previews");
    await pressKey(ctx, "Enter");
    await settle(ctx);
    await pressKey(ctx, "Down");
    await pressKey(ctx, "Down");
    await pressKey(ctx, "Enter");
    await settle(ctx);
  };
});

step("it leaves the preview list", async (ctx: World) => {
  expect(callsTo(ctx, "closePreview").map((call) => call.args)).toEqual([["t1", "tab-1"]]);
  expect(status(ctx)).toEqual({ kind: "success", text: `Preview closed: ${PREVIEW_URL}` });
  await command(ctx, "Previews");
  // Nothing left to list: the picker does not open.
  expect(select(ctx).open).toBe(false);
  expect(status(ctx).text).toBe("No previews: nothing is open and the terminal shows no URL.");
});

step("a project script is set to open its URL", async (ctx: NamedWorld) => {
  await setScripts(ctx, [script("dev", { previewUrl: PREVIEW_URL, autoOpenPreview: true })]);
  await command(ctx, "Run dev");
  // Not before the server is up: the script has printed nothing yet.
  expect(callsTo(ctx, "openPreview")).toEqual([]);
});

step("the script prints its URL", (ctx: World) =>
  terminalPrints(ctx, `  ➜  Local:   ${PREVIEW_URL}/\r\n`),
);

step("the URL is added to the preview list", async (ctx: World) => {
  expect(callsTo(ctx, "openPreview").map((call) => call.args)).toEqual([["t1", PREVIEW_URL]]);
  // Once: more output does not open it again.
  await terminalPrints(ctx, "page reload src/app.ts\r\n");
  expect(callsTo(ctx, "openPreview")).toHaveLength(1);
  await command(ctx, "Previews");
  expect(select(ctx).options[0]).toEqual({ label: PREVIEW_URL, description: "open preview" });
});
