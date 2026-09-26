// plugins/ui-plugins.feature and plugins/plugin-catalog.feature: QML plugins filling the
// default shell's slots ("statusbar", "composer.actions", "sidebar.footer").
//
// Given steps write plugin files and collect start options; the first When/Then boots
// the real shell with them (see ../pluginWorld.ts).
import { expect } from "bun:test";
import * as NodePath from "node:path";
import { createPropertyMap } from "opentui-qml";

import { threadKey } from "../../../src/host/sidebarState.ts";
import { step } from "../../steps.ts";
import { shell } from "../fakeClient.ts";
import {
  asSlot,
  contribute,
  echoSerial,
  expectBefore,
  expectBuiltIn,
  expectProblem,
  label,
  listedPlugins,
  pluginDir,
  pluginSource,
  PROBE_BODY,
  problems,
  setMode,
  settleLoads,
  SLOT_OBJECTS,
  slotLine,
  start,
  writeFile,
  type PluginWorld,
} from "../pluginWorld.ts";
import { findObject, snapshot } from "../world.ts";

// --- shell and slots ------------------------------------------------------------------------------

step(
  "a client whose shell exposes the slots {string}, {string} and {string}",
  (ctx: PluginWorld, ...slots: string[]) => {
    // Checked against the running shell by `start`.
    for (const slot of slots) asSlot(slot);
  },
);

step("no plugin contributes to {string}", (ctx: PluginWorld, slot: string) => {
  for (const [id, spec] of ctx.pluginSpecs ?? []) {
    if (spec.slot === slot) ctx.pluginSpecs!.delete(id);
  }
});

step("the shell renders", async (ctx: PluginWorld) => {
  await start(ctx);
});

step("the plugin loads", async (ctx: PluginWorld) => {
  await start(ctx);
});

step("the contribution renders", async (ctx: PluginWorld) => {
  await start(ctx, { context: { theme: "dark" } });
});

step(
  /^"([^"]+)" shows its built-in content(?: again)?$/,
  async (ctx: PluginWorld, slot: string) => {
    await expectBuiltIn(ctx, asSlot(slot));
  },
);

step(
  "{string} replaces its built-in content when a plugin contributes",
  (ctx: PluginWorld, slot: string) => setMode(ctx, slot, "replace"),
);

step("{string} appends contributions", (ctx: PluginWorld, slot: string) =>
  setMode(ctx, slot, "append"),
);

step("{string} shows a single winner", (ctx: PluginWorld, slot: string) =>
  setMode(ctx, slot, "single_winner"),
);

step("the plugin {string} contributes to {string}", (ctx: PluginWorld, id: string, slot: string) =>
  contribute(ctx, id, slot),
);

step(
  "the plugin {string} replaces the {string} content",
  async (ctx: PluginWorld, id: string, slot: string) => {
    setMode(ctx, slot, "replace");
    contribute(ctx, id, slot);
    await start(ctx);
    expect(await slotLine(ctx, asSlot(slot))).toContain(label(id));
  },
);

step(
  "the plugins {string} and {string} contribute to {string}",
  (ctx: PluginWorld, first: string, second: string, slot: string) => {
    contribute(ctx, first, slot, { order: 1 });
    contribute(ctx, second, slot, { order: 2 });
  },
);

step(
  "the plugin {string} with order {int} and the plugin {string} with order {int} contribute to it",
  (ctx: PluginWorld, first: string, firstOrder: number, second: string, secondOrder: number) => {
    contribute(ctx, first, undefined, { order: firstOrder });
    contribute(ctx, second, undefined, { order: secondOrder });
  },
);

step("{string} shows the clock", async (ctx: PluginWorld, slot: string) => {
  expect(await slotLine(ctx, asSlot(slot))).toContain(label("clock"));
});

step("the built-in status content is hidden", async (ctx: PluginWorld) => {
  const status = (ctx.host!.state.get("status") as { text: string }).text;
  expect(await snapshot(ctx)).not.toContain(status);
});

step("{string} shows the built-in actions first", async (ctx: PluginWorld, slot: string) => {
  const line = await slotLine(ctx, asSlot(slot));
  const firstPlugin = [...(ctx.pluginSpecs?.keys() ?? [])][0]!;
  expectBefore(line, "Enter send", label(firstPlugin));
});

step("then {string} and {string}", async (ctx: PluginWorld, first: string, second: string) => {
  expectBefore(await slotLine(ctx, ctx.lastSlot!), label(first), label(second));
});

step("{string} shows only {string}", async (ctx: PluginWorld, slot: string, id: string) => {
  const screen = await snapshot(await start(ctx).then(() => ctx));
  expect(screen).toContain(label(id));
  for (const other of ctx.pluginSpecs?.keys() ?? []) {
    if (other !== id) expect(screen).not.toContain(label(other));
  }
  expect(findObject(ctx, SLOT_OBJECTS[asSlot(slot)]).get("name")).toBe(slot);
});

step(
  "the plugin {string} loads before {string}",
  (ctx: PluginWorld, first: string, second: string) => {
    contribute(ctx, first);
    contribute(ctx, second);
  },
);

step(
  "{string} has order {int} and {string} has order {int}",
  (ctx: PluginWorld, first: string, firstOrder: number, second: string, secondOrder: number) => {
    contribute(ctx, first, undefined, { order: firstOrder });
    contribute(ctx, second, undefined, { order: secondOrder });
  },
);

step("{string} appears before the other plugin", async (ctx: PluginWorld, winner: string) => {
  const other = [...ctx.pluginSpecs!.keys()].find((id) => id !== winner)!;
  expectBefore(await slotLine(ctx, ctx.lastSlot!), label(winner), label(other));
});

step(
  "{string} and {string} contribute to the appending slot {string}",
  (ctx: PluginWorld, first: string, second: string, slot: string) => {
    setMode(ctx, slot, "append");
    contribute(ctx, first, slot, { order: 10 });
    // The second plugin reads its order from a store, so the scenario can change it live.
    contribute(ctx, second, slot, { order: `Prefs.${second}` });
    ctx.prefs = createPropertyMap({ [second]: 20 });
  },
);

step("{string} is shown first", async (ctx: PluginWorld, id: string) => {
  const other = [...ctx.pluginSpecs!.keys()].find((each) => each !== id)!;
  expectBefore(await slotLine(ctx, ctx.lastSlot!), label(id), label(other));
});

step("{string} changes its order to come first", (ctx: PluginWorld, id: string) => {
  ctx.serial = ctx.app;
  ctx.prefs!.set(id, 1);
});

step(
  "{string} is shown first without reloading the shell",
  async (ctx: PluginWorld, id: string) => {
    expect(ctx.app).toBe(ctx.serial as never);
    const other = [...ctx.pluginSpecs!.keys()].find((each) => each !== id)!;
    expectBefore(await slotLine(ctx, ctx.lastSlot!), label(id), label(other));
  },
);

step("the shell renames that slot to {string}", async (ctx: PluginWorld, name: string) => {
  await start(ctx);
  expect(await snapshot(ctx)).toContain(label("clock"));
  findObject(ctx, SLOT_OBJECTS[ctx.lastSlot!]).set("name", name);
});

step("{string} no longer shows in the renamed slot", async (ctx: PluginWorld, id: string) => {
  expect(await snapshot(ctx)).not.toContain(label(id));
});

step(
  "{string} shows again when a slot named {string} exists",
  async (ctx: PluginWorld, id: string, name: string) => {
    findObject(ctx, SLOT_OBJECTS[asSlot(name)]).set("name", name);
    expect(await snapshot(ctx)).toContain(label(id));
  },
);

// --- slot data, context and errors -------------------------------------------------------------------

step("{string} publishes the current thread title", async (ctx: PluginWorld, slot: string) => {
  ctx.lastSlot = asSlot(slot);
  await start(ctx);
  ctx.fake!.connect();
  ctx.host!.dispatch("thread.open", { key: threadKey("t1") });
  expect(findObject(ctx, SLOT_OBJECTS[asSlot(slot)]).get("data")).toMatchObject({
    title: "Thread one",
  });
});

step("the plugin {string} shows the slot's data", async (ctx: PluginWorld, id: string) => {
  // The shell is already up (the slot publishes a live title): load the plugin into it.
  ctx.host!.dispatch("plugin.load", {
    file: writeFile(ctx, `${id}.qml`, pluginSource(id, { slot: ctx.lastSlot!, order: 0 })),
  });
  await settleLoads(ctx);
  ctx.serial = echoSerial(await snapshot(ctx), id, "Thread one");
});

step("the current thread title changes to {string}", (ctx: PluginWorld, title: string) => {
  const current = shell();
  ctx.fake!.emitShell({
    ...current,
    threads: current.threads.map((thread) => (thread.id === "t1" ? { ...thread, title } : thread)),
  });
});

step(/^"(title-echo)" shows "([^"]*)"$/, async (ctx: PluginWorld, id: string, text: string) => {
  ctx.echoed = echoSerial(await snapshot(ctx), id, text);
});

step("the contribution is updated rather than recreated", (ctx: PluginWorld) => {
  // Each delegate instance draws a random serial: the same serial is the same instance.
  expect(ctx.echoed).toBe(ctx.serial as string);
});

step(
  "it can read its own plugin id, the slot name, the context values and the engine",
  async (ctx: PluginWorld) => {
    expect(await snapshot(ctx)).toContain("[id=inspector slot=statusbar theme=dark engine=yes]");
  },
);

step(
  "the plugin {string} contributes to {string} twice",
  (ctx: PluginWorld, id: string, slot: string) =>
    contribute(ctx, id, slot, {
      bodies: [`Text { text: "[${id} one]" }`, `Text { text: "[${id} two]" }`],
    }),
);

step(
  "the user is warned that {string} contributes to {string} more than once",
  (ctx: PluginWorld, id: string, slot: string) => {
    expectProblem(ctx, "warning", `plugin "${id}"`, `several Contributions for slot "${slot}"`);
  },
);

step("only the first contribution is shown", async (ctx: PluginWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("[dup one]");
  expect(screen).not.toContain("[dup two]");
});

step(
  "the plugin {string} contributes something that cannot be drawn to {string}",
  (ctx: PluginWorld, id: string, slot: string) => contribute(ctx, id, slot),
);

step(
  /^a plugin error names "([^"]+)" and "([^"]+)"$/,
  (ctx: PluginWorld, id: string, slot: string) => {
    expectProblem(ctx, "error", `plugin "${id}"`, `slot "${slot}"`);
  },
);

step("a plugin error names {string} and the setup phase", (ctx: PluginWorld, id: string) => {
  expectProblem(ctx, "error", `plugin "${id}"`, "setup");
});

step(
  "a plugin error names {string}, {string} and the render phase",
  (ctx: PluginWorld, id: string, slot: string) => {
    expectProblem(ctx, "error", `plugin "${id}"`, `slot "${slot}"`, "render");
  },
);

// --- loading ---------------------------------------------------------------------------------------

step("a plugin file {string} that does not declare an id", (ctx: PluginWorld, file: string) => {
  contribute(ctx, NodePath.basename(file, ".qml"), "statusbar", { file, declareId: false });
});

step("it is listed as {string}", (ctx: PluginWorld, id: string) => {
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toContain(id);
});

step(
  "the plugin directory contains {string}, {string} and a helper component",
  (ctx: PluginWorld, first: string, second: string) => {
    for (const file of [first, second]) {
      writeFile(
        ctx,
        `plugins/${file}`,
        pluginSource(NodePath.basename(file, ".qml"), { slot: "statusbar", order: 0 }),
      );
    }
    writeFile(ctx, "plugins/Helper.qml", `import OpenTUI\nText { text: "[helper]" }\n`);
  },
);

step("the plugin directory contains {string}", (ctx: PluginWorld, file: string) => {
  const id = NodePath.basename(file, ".qml");
  writeFile(ctx, `plugins/${file}`, pluginSource(id, { slot: "composer.actions", order: 0 }));
});

step(
  "the plugin directory contains {string} and a {string} with a syntax error",
  (ctx: PluginWorld, good: string, bad: string) => {
    writeFile(
      ctx,
      `plugins/${good}`,
      pluginSource(NodePath.basename(good, ".qml"), { slot: "composer.actions", order: 0 }),
    );
    writeFile(
      ctx,
      `plugins/${bad}`,
      `import OpenTUI\nPlugin {\n  pluginId: "bad"\n  Contribution { slot: "statusbar"; Text { text: "oops\n}\n`,
    );
  },
);

step(/^the client starts with that (?:plugin )?directory$/, async (ctx: PluginWorld) => {
  await start(ctx, { pluginDirs: [NodePath.join(pluginDir(ctx), "plugins")] });
});

step(
  "the client starts with that directory and the extra plugin file {string}",
  async (ctx: PluginWorld, file: string) => {
    const extra = writeFile(
      ctx,
      file,
      pluginSource(NodePath.basename(file, ".qml"), { slot: "composer.actions", order: 0 }),
    );
    await start(ctx, { pluginDirs: [NodePath.join(pluginDir(ctx), "plugins")], plugins: [extra] });
  },
);

step("{string} loads before {string}", (ctx: PluginWorld, first: string, second: string) => {
  const ids = listedPlugins(ctx).map((plugin) => plugin.id);
  expect(ids).toContain(first);
  expect(ids.indexOf(first)).toBeLessThan(ids.indexOf(second));
});

step("the helper component is not treated as a plugin", async (ctx: PluginWorld) => {
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).not.toContain("Helper");
  expect(problems(ctx).filter((problem) => problem.level === "error")).toEqual([]);
  expect(await snapshot(ctx)).not.toContain("[helper]");
});

step("both {string} and {string} are loaded", (ctx: PluginWorld, first: string, second: string) => {
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual(
    expect.arrayContaining([first, second]),
  );
});

step("the client starts with a plugin directory that does not exist", async (ctx: PluginWorld) => {
  await start(ctx, { pluginDirs: [NodePath.join(pluginDir(ctx), "no-such-plugins")] });
});

step("the user is warned that the directory is missing", (ctx: PluginWorld) => {
  expectProblem(ctx, null, "no-such-plugins");
});

step("the shell starts with its built-in content", async (ctx: PluginWorld) => {
  await expectBuiltIn(ctx, "statusbar");
  await expectBuiltIn(ctx, "composer.actions");
});

step("the user loads a QML file whose root is not a plugin", async (ctx: PluginWorld) => {
  contribute(ctx, "clock", "statusbar");
  await start(ctx);
  const file = writeFile(
    ctx,
    "not-a-plugin.qml",
    `import OpenTUI\nText { text: "[not a plugin]" }\n`,
  );
  ctx.host!.dispatch("plugin.load", { file });
  await settleLoads(ctx);
});

step("the load is rejected with a message saying the file is not a plugin", (ctx: PluginWorld) => {
  expectProblem(ctx, "error", "not-a-plugin.qml", "root object is not a Plugin");
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).not.toContain("not-a-plugin");
});

step("no other plugin is affected", async (ctx: PluginWorld) => {
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual(["clock"]);
  expect(await snapshot(ctx)).toContain(label("clock"));
});

step("{string} is loaded", (ctx: PluginWorld, id: string) => {
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toContain(id);
});

step("a load error names {string}", (ctx: PluginWorld, file: string) => {
  expectProblem(ctx, "error", file);
});

step("the plugin {string} is loaded", async (ctx: PluginWorld, id: string) => {
  contribute(ctx, id, "statusbar");
  await start(ctx);
});

step("another plugin with the id {string} loads", async (ctx: PluginWorld, id: string) => {
  const file = writeFile(
    ctx,
    `${id}-copy.qml`,
    `import OpenTUI\nPlugin { pluginId: "${id}"; Contribution { slot: "statusbar"; Text { text: "[${id} copy]" } } }\n`,
  );
  ctx.host!.dispatch("plugin.load", { file });
  await settleLoads(ctx);
});

step("the second one is rejected as a duplicate", (ctx: PluginWorld) => {
  expectProblem(ctx, "error", "is already registered");
});

step("the first {string} keeps working", async (ctx: PluginWorld, id: string) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain(label(id));
  expect(screen).not.toContain(`[${id} copy]`);
  expect(listedPlugins(ctx).filter((plugin) => plugin.id === id)).toHaveLength(1);
});

step("the plugin {string} throws while setting up", (ctx: PluginWorld, id: string) => {
  (ctx.scriptPlugins ??= []).push({
    id,
    setup() {
      throw new Error(`${id} could not set up`);
    },
    slots: {},
  });
});

step("the plugin {string} loads normally", (ctx: PluginWorld, id: string) =>
  contribute(ctx, id, "statusbar"),
);

step("{string} is not registered", (ctx: PluginWorld, id: string) => {
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).not.toContain(id);
});

step("{string} is shown", async (ctx: PluginWorld, id: string) => {
  expect(await snapshot(ctx)).toContain(label(id));
});

step(
  "{string} appends contributions from {string} and {string}",
  (ctx: PluginWorld, slot: string, first: string, second: string) => {
    setMode(ctx, slot, "append");
    contribute(ctx, first, slot, { order: 1 });
    contribute(ctx, second, slot, { order: 2 });
  },
);

step("{string} fails while rendering", async (ctx: PluginWorld) => {
  await start(ctx);
});

step("{string} and the built-in actions are still shown", async (ctx: PluginWorld, id: string) => {
  expectBefore(await slotLine(ctx, "composer.actions"), "Enter send", label(id));
});

// --- removing and listing ------------------------------------------------------------------------------

step(
  "the plugin {string} is loaded and contributes to {string}",
  async (ctx: PluginWorld, id: string, slot: string) => {
    contribute(ctx, id, slot);
    await start(ctx);
    expect(await snapshot(ctx)).toContain(label(id));
  },
);

step("the user removes {string}", async (ctx: PluginWorld, id: string) => {
  await start(ctx);
  ctx.host!.dispatch("plugin.remove", { id });
});

step("{string} runs its cleanup", (ctx: PluginWorld, id: string) => {
  expect(ctx.cleanupLog).toContain(id);
});

step(
  "{string} no longer appears in the installed plugin list",
  async (ctx: PluginWorld, id: string) => {
    expect(listedPlugins(ctx).map((plugin) => plugin.id)).not.toContain(id);
    expect(await snapshot(ctx)).not.toContain(label(id));
  },
);

step(
  "the client starts with the context value {string} set to {string} and {string} set to {int}",
  async (ctx: PluginWorld, textKey: string, text: string, numberKey: string, number: number) => {
    // Two probes side by side on the status line, the widest slot.
    for (const id of ["a", "b"]) contribute(ctx, id, "statusbar", { bodies: [PROBE_BODY(id)] });
    await start(ctx, { context: { [textKey]: text, [numberKey]: number } });
  },
);

step(
  "every plugin reads {string} as the text {string}",
  async (ctx: PluginWorld, key: string, text: string) => {
    const screen = await snapshot(ctx);
    for (const id of ctx.pluginSpecs!.keys()) {
      expect(screen).toMatch(new RegExp(`\\[${id}[^\\]]* ${key}=string:${text}`));
    }
  },
);

step(
  "every plugin reads {string} as the number {int}",
  async (ctx: PluginWorld, key: string, number: number) => {
    const screen = await snapshot(ctx);
    for (const id of ctx.pluginSpecs!.keys()) {
      expect(screen).toMatch(new RegExp(`\\[${id}[^\\]]* ${key}=number:${number}\\]`));
    }
  },
);

step(
  /^the (?:TUI loaded the )?QML plugin "([^"]+)"(?: from "([^"]+)")? and (?:a|the) script plugin "([^"]+)"(?: are loaded)?$/,
  async (ctx: PluginWorld, id: string, file: string | undefined, script: string) => {
    contribute(ctx, id, "statusbar", file ? { file } : {});
    (ctx.scriptPlugins ??= []).push({ id: script, slots: {} });
    await start(ctx);
  },
);

step(/^the user lists the (?:loaded|installed) plugins$/, (ctx: PluginWorld) => {
  ctx.host!.dispatch("plugins.refresh");
  ctx.listed = listedPlugins(ctx);
});

step("the list shows {string} as a QML plugin with its file", (ctx: PluginWorld, id: string) => {
  const plugin = ctx.listed!.find((each) => each.id === id);
  expect(plugin).toMatchObject({ kind: "qml" });
  expect(plugin!.file).toBe(
    NodePath.join(pluginDir(ctx), ctx.pluginSpecs!.get(id)!.file ?? `${id}.qml`),
  );
});

step("the list shows {string} as a script plugin", (ctx: PluginWorld, id: string) => {
  expect(ctx.listed!.find((each) => each.id === id)).toMatchObject({ kind: "script", file: null });
});

step(
  "{string} and {string} are listed with their kind and source file",
  (ctx: PluginWorld, qml: string, script: string) => {
    expect(ctx.listed).toContainEqual({
      id: qml,
      kind: "qml",
      file: NodePath.join(pluginDir(ctx), `${qml}.qml`),
      order: 0,
    });
    expect(ctx.listed).toContainEqual({ id: script, kind: "script", file: null, order: 0 });
  },
);

step("the client starts", async (ctx: PluginWorld) => {
  await start(ctx);
});

step("the first frame already shows the clock", async (ctx: PluginWorld) => {
  // `boot` resolves after the first frame; nothing has advanced the clock since.
  expect(await ctx.app!.snapshot()).toContain(label("clock"));
});
