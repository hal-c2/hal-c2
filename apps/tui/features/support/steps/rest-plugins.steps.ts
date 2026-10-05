// plugins/ui-plugins.feature and plugins/plugin-catalog.feature beyond slots: the
// plugins page (what is loaded, turned off or failed), turning a plugin off and on
// again across a restart, loading one from a URL after the "not signed" question, and
// dev mode reloading a plugin whose file was saved.
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import { memoryPluginStore, type TuiPluginsState } from "../../../src/host/plugins.ts";
import type { TuiSettingsSectionState } from "../../../src/host/settingsSections.ts";
import { step } from "../../steps.ts";
import {
  contribute,
  expectBuiltIn,
  expectProblem,
  label,
  listedPlugins,
  openPluginList,
  pluginDir,
  pluginSource,
  problems,
  problemText,
  SLOT_OBJECTS,
  settleLoads,
  start,
  togglePlugin,
  type PluginWorld,
} from "../pluginWorld.ts";
import { findObject, pasteText, pressKey, settle, snapshot, typeText } from "../world.ts";

interface CatalogWorld extends PluginWorld {
  /** What the dev-mode watcher was asked to follow, and how it reports a save. */
  watched?: { files: ReadonlyArray<string>; onChange: (file: string) => void };
  /** URLs the client downloaded, in order. */
  downloads?: string[];
  /** What each URL serves: a plugin's source, or the error reaching it. */
  served?: Map<string, string | Error>;
  installDir?: string;
  draft?: string;
}

const plugins = (ctx: PluginWorld) => ctx.host!.state.get("plugins") as TuiPluginsState;
const section = (ctx: PluginWorld) =>
  ctx.host!.state.get("settingsSection") as TuiSettingsSectionState;
const status = (ctx: PluginWorld) =>
  ctx.host!.state.get("status") as { text: string; kind: string };
/** The page's words: columns are padded and long values wrap, so blanks are joined. */
const pageText = (ctx: PluginWorld) => section(ctx).lines.join("\n").replace(/\s+/g, " ");

// --- A slot this surface does not have ---------------------------------------------------

step(
  "the plugin {string} contributes only to {string}",
  (ctx: PluginWorld, id: string, slot: string) => {
    expect(Object.keys(SLOT_OBJECTS)).not.toContain(slot);
    (ctx.rawPlugins ??= new Map()).set(
      `${id}.qml`,
      `import OpenTUI
Plugin {
  pluginId: "${id}"
  Contribution { slot: "${slot}"; Text { text: "${label(id)}" } }
}
`,
    );
  },
);

step("it is loaded on a surface without that slot", async (ctx: PluginWorld) => {
  // `start` checks the shell's slots are the three the Background names.
  await start(ctx);
});

step("the plugin is listed as loaded with no visible contributions", async (ctx: PluginWorld) => {
  const [id] = [...ctx.rawPlugins!.keys()].map((file) => NodePath.basename(file, ".qml"));
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual([id!]);
  expect(await snapshot(ctx)).not.toContain(label(id!));
  await expectBuiltIn(ctx, "statusbar");
  await openPluginList(ctx);
  expect(pageText(ctx)).toContain(`${id} enabled`);
});

step("no error is reported", (ctx: PluginWorld) => {
  expect(problems(ctx).map(problemText)).toEqual([]);
});

// --- The plugins page ------------------------------------------------------------------------

step("the plugin {string} failed to load", async (ctx: PluginWorld, id: string) => {
  (ctx.rawPlugins ??= new Map()).set(
    `${id}.qml`,
    `import OpenTUI\nPlugin {\n  pluginId: "${id}"\n  Contribution { slot: "statusbar"; Text { text: "oops\n}\n`,
  );
  await start(ctx);
  expect(listedPlugins(ctx)).toEqual([]);
});

step("the user opens the plugin list", openPluginList);

step("{string} is shown with its error message", async (ctx: PluginWorld, id: string) => {
  const [problem] = problems(ctx);
  expect(problem).toMatchObject({ level: "error" });
  expect(problem!.message.length).toBeGreaterThan(0);
  expect(pageText(ctx)).toContain("Failed");
  expect(pageText(ctx)).toContain(`${id}: ${problem!.message}`);
  const screen = await snapshot(ctx);
  expect(screen).toContain("Failed");
  expect(screen).toContain(`${id}: `);
});

// --- Turning a plugin off and on ---------------------------------------------------------------

const clockFile = (ctx: PluginWorld, id: string) => NodePath.join(pluginDir(ctx), `${id}.qml`);

/** What this device remembers survives a restart of the client. */
function rememberPlugins(ctx: PluginWorld) {
  ctx.hostOptions = { pluginStore: memoryPluginStore(), ...ctx.hostOptions };
}

async function disable(ctx: PluginWorld, id: string) {
  rememberPlugins(ctx);
  contribute(ctx, id, "statusbar");
  await start(ctx);
  expect(await snapshot(ctx)).toContain(label(id));
  await togglePlugin(ctx, id, "enabled");
  expect(status(ctx)).toEqual({ kind: "success", text: `Plugin "${id}" disabled.` });
}

step("{string} stays in the installed list as disabled", async (ctx: PluginWorld, id: string) => {
  expect(listedPlugins(ctx)).toEqual([]);
  expect(plugins(ctx).disabled).toEqual([{ id, file: clockFile(ctx, id) }]);
  // Installed still: its file is where it was, and it is on the page to turn on again.
  expect(NodeFS.existsSync(clockFile(ctx, id))).toBe(true);
  expect(ctx.cleanupLog).toContain(id);
  await openPluginList(ctx);
  expect(pageText(ctx)).toContain(`${id} disabled · ${clockFile(ctx, id)}`);
});

step("the plugin {string} is disabled", async (ctx: PluginWorld, id: string) => {
  await disable(ctx, id);
  await expectBuiltIn(ctx, "statusbar");
});

step("the user enables {string}", async (ctx: PluginWorld, id: string) => {
  await togglePlugin(ctx, id, "disabled");
  expect(status(ctx)).toEqual({ kind: "success", text: `Plugin "${id}" enabled.` });
});

step("{string} shows the clock again", async (ctx: PluginWorld, slot: string) => {
  expect(findObject(ctx, SLOT_OBJECTS[slot as keyof typeof SLOT_OBJECTS]).get("name")).toBe(slot);
  expect(await snapshot(ctx)).toContain(label("clock"));
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual(["clock"]);
  expect(plugins(ctx).disabled).toEqual([]);
});

step("the user disabled {string}", (ctx: PluginWorld, id: string) => disable(ctx, id));

// The same device again: its plugin files and what it remembered about them.
step("the client restarts", async (ctx: PluginWorld) => {
  for (const cleanup of ctx.cleanups.splice(1).toReversed()) await cleanup();
  delete ctx.app;
  delete ctx.host;
  delete ctx.fake;
  ctx.pluginLoads = [];
  ctx.cleanupLog!.length = 0;
  await start(ctx);
});

step("{string} is still disabled", async (ctx: PluginWorld, id: string) => {
  expect(listedPlugins(ctx)).toEqual([]);
  expect(plugins(ctx).disabled).toEqual([{ id, file: clockFile(ctx, id) }]);
  expect(await snapshot(ctx)).not.toContain(label(id));
  await expectBuiltIn(ctx, "statusbar");
});

// --- Dev mode -------------------------------------------------------------------------------------

step(
  "the client runs in dev mode with the plugin {string} loaded from a file",
  async (ctx: CatalogWorld, id: string) => {
    // What HAL_C2_TUI_DEV=1 gives the host: a watcher on the loaded plugin files.
    ctx.hostOptions = {
      ...ctx.hostOptions,
      watchPlugins: (files, onChange) => {
        ctx.watched = { files, onChange };
        return () => {};
      },
    };
    contribute(ctx, id, "statusbar");
    await start(ctx);
    ctx.fake!.connect();
    expect(ctx.watched!.files).toEqual([clockFile(ctx, id)]);
    expect(await snapshot(ctx)).toContain(label(id));
    // Something of the user's that a restart would lose.
    ctx.draft = "half a thought";
    await typeText(ctx, ctx.draft);
    await settle(ctx);
    ctx.serial = ctx.app;
  },
);

/** The developer's editor writes the file; the watcher reports it. */
async function save(ctx: CatalogWorld, source: string) {
  const [file] = ctx.watched!.files;
  NodeFS.writeFileSync(file!, source);
  ctx.watched!.onChange(file!);
  await ctx.host!.settled();
  await settleLoads(ctx);
  await settle(ctx);
}

step("the developer saves a change to that file", (ctx: CatalogWorld) =>
  save(
    ctx,
    pluginSource("clock", {
      slot: "statusbar",
      order: 0,
      bodies: [`Text { text: "[clock v2]" }`],
    }),
  ),
);

step("{string} is replaced by the new version", async (ctx: CatalogWorld, id: string) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("[clock v2]");
  expect(screen).not.toContain(label(id));
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual([id]);
  // The old one is gone, not left running beside it.
  expect(ctx.cleanupLog).toEqual([id]);
  expect(status(ctx)).toEqual({ kind: "success", text: `Plugin "${id}" reloaded.` });
  expect(problems(ctx).map(problemText)).toEqual([]);
});

step("the rest of the shell keeps its state", async (ctx: CatalogWorld) => {
  expect(ctx.app).toBe(ctx.serial as never);
  expect((ctx.host!.state.get("composer") as { text: string }).text).toBe(ctx.draft!);
  const field = findObject(ctx, "composerInput");
  expect(field.get("plainText") ?? field.get("text")).toBe(ctx.draft!);
  expect(ctx.host!.state.get("mode")).toBe("compose");
});

step("the developer saves a version that fails to load", (ctx: CatalogWorld) =>
  save(
    ctx,
    `import OpenTUI\nPlugin {\n  pluginId: "clock"\n  Contribution { slot: "statusbar"; Text { text: "oops\n}\n`,
  ),
);

step(/^a plugin error names "([^"]+)"$/, (ctx: PluginWorld, id: string) => {
  expectProblem(ctx, "error", `plugin "${id}"`);
});

step("the previous version of {string} keeps running", async (ctx: CatalogWorld, id: string) => {
  expect(await snapshot(ctx)).toContain(label(id));
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual([id]);
  // It was never taken down.
  expect(ctx.cleanupLog).toEqual([]);
  expect(status(ctx).kind).toBe("error");
  expect(status(ctx).text).toContain("the last working version keeps running");
});

// --- A plugin from a URL ------------------------------------------------------------------------------

const PLUGIN_URL = "https://plugins.example/team-status.qml";
const DEAD_URL = "https://plugins.invalid/team-status.qml";

/** The client downloads through the scenario's network, into a plugin directory of its own. */
function network(ctx: CatalogWorld) {
  ctx.downloads = [];
  ctx.served = new Map<string, string | Error>([
    [PLUGIN_URL, pluginSource("team-status", { slot: "statusbar", order: 0 })],
    ["https://plugins.example/notes.qml", `import OpenTUI\nText { text: "[not a plugin]" }\n`],
    [DEAD_URL, new Error("getaddrinfo ENOTFOUND plugins.invalid")],
  ]);
  ctx.installDir = NodePath.join(pluginDir(ctx), "installed");
  ctx.hostOptions = {
    ...ctx.hostOptions,
    pluginStore: memoryPluginStore(),
    pluginDir: ctx.installDir,
    downloadPlugin: async (url) => {
      ctx.downloads!.push(url);
      const answer = ctx.served!.get(url);
      if (answer === undefined || answer instanceof Error) throw answer ?? new Error("404");
      return answer;
    },
  };
}

/** On the plugins page: "Load a plugin from a URL…", then the address pasted in. */
async function pasteUrl(ctx: CatalogWorld, url: string) {
  if (!ctx.app) network(ctx);
  await openPluginList(ctx);
  for (let guard = 0; section(ctx).selectedId !== "url" && guard < 50; guard += 1) {
    await pressKey(ctx, "Down");
  }
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(section(ctx).input).toMatchObject({ label: "plugin URL" });
  await pasteText(ctx, url);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

async function answer(ctx: CatalogWorld, key: "y" | "n") {
  expect(ctx.host!.state.get("mode")).toBe("sectionConfirm");
  await pressKey(ctx, key);
  await ctx.host!.settled();
  await settleLoads(ctx);
  await settle(ctx);
}

const installed = (ctx: CatalogWorld) =>
  NodeFS.existsSync(ctx.installDir!) ? NodeFS.readdirSync(ctx.installDir!) : [];

step(
  "the user pastes the URL of a plugin file and confirms loading it",
  async (ctx: CatalogWorld) => {
    await pasteUrl(ctx, PLUGIN_URL);
    await answer(ctx, "y");
  },
);

step("the plugin is downloaded, checked and loaded", async (ctx: CatalogWorld) => {
  expect(ctx.downloads).toEqual([PLUGIN_URL]);
  expect(installed(ctx)).toEqual(["team-status.qml"]);
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual(["team-status"]);
  expect(status(ctx)).toEqual({
    kind: "success",
    text: 'Plugin "team-status" loaded from plugins.example.',
  });
  await pressKey(ctx, "Esc");
  expect(await settle(ctx)).toContain(label("team-status"));
  // Checked by loading it: a file that is not a plugin is refused and not kept.
  await pasteUrl(ctx, "https://plugins.example/notes.qml");
  await answer(ctx, "y");
  expect(status(ctx)).toEqual({
    kind: "error",
    text: "notes.qml is not a plugin this client can load.",
  });
  expect(installed(ctx)).toEqual(["team-status.qml"]);
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual(["team-status"]);
});

step("the plugin is listed with that URL as its source", async (ctx: CatalogWorld) => {
  expect(plugins(ctx).sources).toEqual({ "team-status": PLUGIN_URL });
  await openPluginList(ctx);
  expect(pageText(ctx)).toContain(`team-status enabled · ${PLUGIN_URL}`);
});

step("the user pastes a plugin URL that cannot be reached", async (ctx: CatalogWorld) => {
  await pasteUrl(ctx, DEAD_URL);
  await answer(ctx, "y");
});

step("the user is told the plugin could not be downloaded", async (ctx: CatalogWorld) => {
  expect(ctx.downloads).toEqual([DEAD_URL]);
  expect(status(ctx).kind).toBe("error");
  expect(status(ctx).text).toBe(
    "The plugin could not be downloaded: getaddrinfo ENOTFOUND plugins.invalid",
  );
  expect(await snapshot(ctx)).toContain("The plugin could not be");
});

step("nothing is loaded", (ctx: CatalogWorld) => {
  expect(listedPlugins(ctx)).toEqual([]);
  expect(installed(ctx)).toEqual([]);
  expect(plugins(ctx).sources).toEqual({});
});

// --- Unverified plugins ask first -----------------------------------------------------------------------

step("the user installs a plugin from a pasted URL", (ctx: CatalogWorld) =>
  pasteUrl(ctx, PLUGIN_URL),
);

step("the user is warned that the plugin is not signed", async (ctx: CatalogWorld) => {
  const question = section(ctx).confirm!.lines.join(" ");
  expect(question).toContain("This plugin is not signed");
  expect(question).toContain("plugins.example");
  expect(await snapshot(ctx)).toContain("This plugin is not signed");
});

step("the plugin loads only after the user confirms", async (ctx: CatalogWorld) => {
  // Asked, and nothing has been fetched or loaded yet.
  expect(ctx.downloads).toEqual([]);
  expect(listedPlugins(ctx)).toEqual([]);
  // Declined, it stays that way.
  await answer(ctx, "n");
  expect(ctx.downloads).toEqual([]);
  expect(listedPlugins(ctx)).toEqual([]);
  expect(status(ctx).text).toBe("Nothing was loaded.");
  // Asked again and confirmed, it is downloaded and loaded.
  await pasteUrl(ctx, PLUGIN_URL);
  await answer(ctx, "y");
  expect(ctx.downloads).toEqual([PLUGIN_URL]);
  expect(listedPlugins(ctx).map((plugin) => plugin.id)).toEqual(["team-status"]);
});
