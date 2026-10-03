// tui/keymap.feature: help for what has focus, the leader layer, keymap.json
// overrides (checked the way the entry checks them) and rebinding from the client.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { KEYMAP_LAYERS, LEADER_ACTIONS, chordLabel } from "../../../src/keymap.ts";
import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { readUserConfig } from "../../../src/host/userConfig.ts";
import { objectRows } from "../design.ts";
import { actionNamed } from "../keyNames.ts";
import { configDir, writeFile, type PluginWorld } from "../pluginWorld.ts";
import { boot, findObject, pressKey, settle, typeText, type World } from "../world.ts";
import { composer, openOnThread, type ComposerWorld } from "./composer.steps.ts";

interface KeysWorld extends ComposerWorld, PluginWorld {
  keymapConflicts?: string[];
  savedKeymap?: Array<Record<string, string | null>>;
  modeBeforeHelp?: string;
}

const hostAction = (name: string): string => {
  const action = actionNamed(name);
  if (!action) throw new Error(`no host action for "${name}"`);
  return action;
};

const mode = (ctx: World) => ctx.host!.state.get("mode") as string;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const sawAction = (ctx: World, action: string) =>
  ctx.dispatched!.some((entry) => entry.action === action);

/**
 * Boot on a thread the way the entry does with a keymap.json in the config
 * directory: read it (which checks it), hand the warnings to the host and the
 * bindings to the QML engine.
 */
async function startWithKeymap(ctx: KeysWorld): Promise<void> {
  writeFile(ctx, "config/keymap.json", JSON.stringify(ctx.keymapFile ?? {}, null, 2));
  const warnings: string[] = [];
  const config = readUserConfig({
    configDir: configDir(ctx),
    warn: (message) => warnings.push(message),
  });
  ctx.keymapConflicts = warnings;
  const planned = ctx.prepare;
  ctx.prepare = () => {
    planned?.();
    ctx.qml = { ...ctx.qml, ...(config.keymap ? { keymap: config.keymap } : {}) };
    ctx.hostOptions = { ...ctx.hostOptions, startupWarnings: warnings };
  };
  await openOnThread(ctx);
  await settle(ctx);
}

// --- Help ---------------------------------------------------------------------

step("the user asks for help", async (ctx: KeysWorld) => {
  await boot(ctx);
  ctx.modeBeforeHelp = mode(ctx);
  await pressKey(ctx, "F1");
  await settle(ctx);
});

step("an overlay lists the chords that work in the terminal drawer", async (ctx: KeysWorld) => {
  expect(ctx.modeBeforeHelp).toBe("terminal");
  expect(select(ctx).open).toBe(true);
  const chords = Object.keys(KEYMAP_LAYERS.terminal);
  expect(select(ctx).options.map((option) => option.label)).toEqual(chords.map(chordLabel));
  // Each chord says what it does there, not just the action's name.
  const toggle = select(ctx).options.find((option) => option.label === "Ctrl+E");
  expect(toggle?.description).toBe("Show / hide the terminal");
  const rows = (await objectRows(ctx, "selectOverlay")).join("\n");
  expect(rows).toContain("keys · terminal");
  expect(rows).toContain("Ctrl+E");
  // The prompt's chords are not the drawer's.
  expect(select(ctx).options.map((option) => option.label)).not.toContain("Ctrl+N");
});

step("closing it returns focus to the terminal drawer", async (ctx: KeysWorld) => {
  await pressKey(ctx, "Esc");
  await settle(ctx);
  expect(select(ctx).open).toBe(false);
  expect(mode(ctx)).toBe("terminal");
  expect((ctx.host!.state.get("terminal") as { focused: boolean }).focused).toBe(true);
});

// --- Leader -------------------------------------------------------------------

step("the user presses the leader key", async (ctx: KeysWorld) => {
  if (!ctx.app) await openOnThread(ctx);
  ctx.dispatched!.length = 0;
  await pressKey(ctx, "Ctrl+X");
  await settle(ctx);
});

step("the client shows the chords that can follow it", async (ctx: World) => {
  expect(mode(ctx)).toBe("leader");
  expect(select(ctx).options.map((option) => option.label)).toEqual(
    LEADER_ACTIONS.map((entry) => `${entry.key}  ${entry.title}`),
  );
  const rows = (await objectRows(ctx, "selectOverlay")).join("\n");
  for (const entry of LEADER_ACTIONS) expect(rows).toContain(`${entry.key}  ${entry.title}`);
});

step("pressing {string} cancels the leader without acting", async (ctx: World, key: string) => {
  const before = ctx.host!.state.get("page");
  await pressKey(ctx, key);
  await settle(ctx);
  expect(mode(ctx)).toBe("compose");
  expect(select(ctx).open).toBe(false);
  expect(ctx.dispatched!.map((entry) => entry.action)).toEqual(["leader.open", "leader.cancel"]);
  expect(ctx.host!.state.get("page")).toEqual(before);
  // The same key after the leader does act: the layer was live, Esc left it.
  await pressKey(ctx, "Ctrl+X");
  await pressKey(ctx, "n");
  await settle(ctx);
  expect(ctx.host!.state.get("newThread")).not.toBeNull();
});

// --- keymap.json --------------------------------------------------------------

// "a keymap file that binds/sets …" are keymaps.steps.ts's; they take an action's name too.

step(
  "a keymap file that binds {string} and {string} to the same chord",
  (ctx: KeysWorld, first: string, second: string) => {
    // Two spellings of one chord: JSON keeps both keys, the engine would keep the last.
    ctx.keymapFile = { "ctrl+t": hostAction(first), "Ctrl+T": hostAction(second) };
  },
);

step("the user starts the terminal client with that keymap file", startWithKeymap);

step("{string} starts a new thread", async (ctx: World, key: string) => {
  expect(ctx.host!.state.get("newThread")).toBeNull();
  await pressKey(ctx, key);
  await settle(ctx);
  expect(ctx.host!.state.get("newThread")).not.toBeNull();
  await pressKey(ctx, "Esc");
  await settle(ctx);
  expect(ctx.host!.state.get("newThread")).toBeNull();
});

step("{string} no longer does", async (ctx: World, key: string) => {
  ctx.dispatched!.length = 0;
  await pressKey(ctx, key);
  await settle(ctx);
  expect(ctx.host!.state.get("newThread")).toBeNull();
  expect(sawAction(ctx, "thread.new")).toBe(false);
});

step("{string} is passed through to the focused input", async (ctx: World, key: string) => {
  ctx.dispatched!.length = 0;
  await pressKey(ctx, key);
  await settle(ctx);
  // No chord took it: the filter did not open and the prompt still has the keys.
  expect(sawAction(ctx, "sidebar.filter.focus")).toBe(false);
  expect(mode(ctx)).toBe("compose");
  expect(findObject(ctx, "composerInput").get("focus")).toBe(true);
  await typeText(ctx, "x");
  await settle(ctx);
  expect(composer(ctx).text.endsWith("x")).toBe(true);
});

step("the client reports the conflict", async (ctx: KeysWorld) => {
  expect(ctx.keymapConflicts).toEqual([
    'keymap.json binds Ctrl+T to "thread.new" and "palette.open"; neither is applied',
  ]);
  const problems = ctx.host!.state.get("problems") as {
    items: Array<{ level: string; message: string; where: string | null }>;
  };
  expect(problems.items).toContainEqual({
    level: "warning",
    message: ctx.keymapConflicts![0]!,
    where: null,
  });
  // On screen too, not only in the log: the status line points at settings, which lists it.
  expect(status(ctx)).toEqual({
    kind: "error",
    text: "1 problem at startup: see Settings (^K)",
  });
  ctx.host!.dispatch("settings.open");
  const screen = (await settle(ctx)).replace(/\s+/g, " ");
  expect(screen).toContain("Problems");
  expect(screen).toContain("keymap.json binds Ctrl+T");
  ctx.host!.dispatch("settings.close");
  await settle(ctx);
});

step("both actions keep their default chords", async (ctx: World) => {
  ctx.dispatched!.length = 0;
  await pressKey(ctx, "Ctrl+T");
  await settle(ctx);
  expect(ctx.dispatched!.map((entry) => entry.action)).toEqual([]);
  await pressKey(ctx, "Ctrl+K");
  await settle(ctx);
  expect(mode(ctx)).toBe("command");
  await pressKey(ctx, "Esc");
  await pressKey(ctx, "Ctrl+N");
  await settle(ctx);
  expect(ctx.host!.state.get("newThread")).not.toBeNull();
});

// --- Rebinding from settings ----------------------------------------------------

step("the user rebinds {string} from settings", async (ctx: KeysWorld, name: string) => {
  const saved: Array<Record<string, string | null>> = (ctx.savedKeymap = []);
  ctx.prepare = () => {
    ctx.hostOptions = {
      ...ctx.hostOptions,
      features: { ...ctx.hostOptions?.features, saveKeymap: (entry) => saved.push(entry) },
    };
  };
  await openOnThread(ctx);
  ctx.host!.dispatch("settings.open");
  await settle(ctx);
  expect(mode(ctx)).toBe("settings");
  await pressKey(ctx, "r");
  await settle(ctx);
  expect(select(ctx).title).toBe("rebind");
  const index = select(ctx).options.findIndex(
    (option) => option.label === "Show / hide the terminal",
  );
  expect(hostAction(name)).toBe("terminal.toggle");
  expect(index).toBeGreaterThanOrEqual(0);
  expect(select(ctx).options[index]!.description).toBe("Ctrl+E");
  for (let i = select(ctx).index; i < index; i += 1) await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(mode(ctx)).toBe("ask");
  await typeText(ctx, "Ctrl+T");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the new chord takes effect immediately", async (ctx: KeysWorld) => {
  expect(status(ctx)).toEqual({ kind: "success", text: "Show / hide the terminal → Ctrl+T" });
  expect(ctx.savedKeymap).toEqual([{ "ctrl+e": null, "ctrl+t": "terminal.toggle" }]);
  // Back in settings; leave it and use the chord at the prompt.
  await pressKey(ctx, "Esc");
  await settle(ctx);
  expect(mode(ctx)).toBe("compose");
  const drawer = () => (ctx.host!.state.get("layout") as { drawer: { open: boolean } }).drawer;
  expect(drawer().open).toBe(false);
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
  expect(drawer().open).toBe(false);
  await pressKey(ctx, "Ctrl+T");
  await settle(ctx);
  expect(drawer().open).toBe(true);
  // The drawer took the keys; the same chord closes it there too.
  await pressKey(ctx, "Ctrl+T");
  await settle(ctx);
  expect(drawer().open).toBe(false);
});

step("a chord already in use is refused with the action that owns it", async (ctx: KeysWorld) => {
  ctx.host!.dispatch("keymap.rebind.open");
  await settle(ctx);
  const index = select(ctx).options.findIndex(
    (option) => option.label === "Show / hide the terminal",
  );
  for (let i = select(ctx).index; i < index; i += 1) await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await typeText(ctx, "Ctrl+K");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(status(ctx)).toEqual({ kind: "error", text: "Ctrl+K is already Command palette." });
  expect(ctx.savedKeymap).toHaveLength(1);
  // Ctrl+K still opens the palette, Ctrl+T still toggles the terminal.
  await pressKey(ctx, "Ctrl+K");
  await settle(ctx);
  expect(mode(ctx)).toBe("command");
});
