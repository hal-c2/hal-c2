// plugins/keymaps.feature: the shell's keymaps (ShellKeymap: one per mode from
// `KEYMAP_LAYERS`, the global one, and the thread list's "list"), the user's keymap.json,
// and keymaps that plugins ship.
//
// Keymaps call `Shell.dispatch`; the world records every dispatch, so a key's effect is
// asserted on that log (actions the host has not implemented yet, like `palette.open`,
// still show up there) or on host state (thread selection, quit).
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import { ThreadId } from "@t3tools/contracts";

import { KEYMAP_LAYERS } from "../../../src/keymap.ts";
import { step } from "../../steps.ts";
import { shell } from "../fakeClient.ts";
import {
  configDir,
  expectProblem,
  planShell,
  start,
  writeFile,
  type KeymapHandle,
  type PluginWorld,
} from "../pluginWorld.ts";
import { findObject, pressKey, QML_DIR, useClient } from "../world.ts";

const TUI_DIR = NodePath.resolve(import.meta.dir, "../../..");
const ENTRY_TIMEOUT_MS = 10_000;

// `applyKeymapOverrides` is not exported from opentui-qml's entry; reach the module directly.
const keymapModule = new URL("./components/keymap.ts", import.meta.resolve("opentui-qml"));
const { applyKeymapOverrides } = (await import(keymapModule.href)) as {
  applyKeymapOverrides: (engine: unknown, overrides: Record<string, unknown>) => void;
};

interface KeymapWorld extends PluginWorld {
  entryRun?: { code: number | null; stderr: string };
  described?: ReturnType<KeymapHandle["describe"]>;
  selectedBefore?: string | null;
  dispatchedBefore?: number;
}

function keymapFile(ctx: KeymapWorld): Record<string, unknown> {
  planKeymaps(ctx);
  if (typeof ctx.keymapFile !== "object") ctx.keymapFile = {};
  return ctx.keymapFile;
}

/**
 * Boot, whichever step does it, connected with two threads so list keys can move. Keys
 * arrive from a terminal that reports every modifier (super, ctrl+shift+s, ctrl with "+"),
 * which a legacy terminal encoding drops.
 */
function planKeymaps(ctx: KeymapWorld) {
  planShell(ctx, () => {
    ctx.kittyKeyboard = true;
    if (!ctx.fake) {
      const current = shell();
      const second = { ...current.threads[0]!, id: ThreadId.make("t2"), title: "Thread two" };
      useClient(ctx, { shellSnapshot: { ...current, threads: [...current.threads, second] } });
    }
    ctx.fake!.connect();
  });
}

async function startKeymaps(ctx: KeymapWorld) {
  planKeymaps(ctx);
  return start(ctx);
}

function keymapHandle(ctx: KeymapWorld, objectName: string): KeymapHandle {
  return findObject(ctx, objectName).proxy as KeymapHandle;
}

/** Every keymap the scenario can see: the shell's two and the plugins'. */
function allKeymaps(ctx: KeymapWorld): KeymapHandle[] {
  return [
    keymapHandle(ctx, "globalKeymap"),
    keymapHandle(ctx, "listKeymap"),
    ...Object.values(ctx.keymaps ?? {}),
  ];
}

const actions = (ctx: KeymapWorld) => (ctx.dispatched ?? []).map((entry) => entry.action);

const selectedThread = (ctx: KeymapWorld) =>
  (ctx.host!.state.get("sidebar") as { activeThreadKey: string | null }).activeThreadKey;

/** Press a key and return the actions it dispatched. */
async function press(ctx: KeymapWorld, key: string): Promise<string[]> {
  await startKeymaps(ctx);
  const before = actions(ctx).length;
  await pressKey(ctx, key);
  return actions(ctx).slice(before);
}

function markBefore(ctx: KeymapWorld) {
  ctx.selectedBefore = selectedThread(ctx);
  ctx.dispatchedBefore = actions(ctx).length;
}

/** A plugin file whose only content is a Keymap. */
function keymapPlugin(
  ctx: KeymapWorld,
  name: string,
  body: { bindings: Record<string, string>; priority?: number; activated: string },
) {
  planKeymaps(ctx);
  (ctx.rawPlugins ??= new Map()).set(
    `${name}.qml`,
    `import OpenTUI
Plugin {
  pluginId: "${name}"
  Keymap {
    id: keys
    name: "${name}"
    priority: ${body.priority ?? 0}
    bindings: (${JSON.stringify(body.bindings)})
    onActivated: (action, event) => { ${body.activated} }
    Component.onCompleted: keymaps["${name}"] = keys
  }
}
`,
  );
}

/** Plugin keymap actions named after the list ("list.next") reach the host's thread actions. */
const LIST_ACTIVATED = `Shell.dispatch(action === "list.next" ? "thread.next" : action)`;

// --- the built-in keymaps ----------------------------------------------------------------------

/** The chords a keymap layer binds to `action` ("up, k" lists two chords). */
const chordsFor = (layer: Readonly<Record<string, string>>, action: string) =>
  Object.entries(layer).flatMap(([chords, bound]) =>
    bound === action ? chords.split(",").map((chord) => chord.trim()) : [],
  );

step(
  /^the built-in keymap binds "([^"]+)" to "([^"]+)"(?: and "([^"]+)" to "([^"]+)")?$/,
  (_ctx: KeymapWorld, ...pairs: Array<string | undefined>) => {
    for (let index = 0; index < pairs.length; index += 2) {
      const [key, action] = [pairs[index], pairs[index + 1]];
      if (key === undefined || action === undefined) continue;
      // The prompt's layer sits over the global one; either binding counts.
      const bound = [
        ...chordsFor(KEYMAP_LAYERS.global, action),
        ...chordsFor(KEYMAP_LAYERS.compose, action),
      ];
      expect(bound).toContain(key);
    }
  },
);

step(
  "the thread list has its own keymap named {string} that binds {string} to {string}",
  (_ctx: KeymapWorld, name: string, key: string, action: string) => {
    // A Given: read the source, so the keymap file that follows still applies at boot.
    const source = NodeFS.readFileSync(NodePath.join(QML_DIR, "T3/Tui/ShellKeymap.qml"), "utf8");
    expect(source).toContain(`name: "${name}"`);
    expect(source).toContain(`bindings: keys.layers.${name}`);
    expect(chordsFor(KEYMAP_LAYERS.list, action)).toContain(key);
  },
);

// --- the user's keymap file ----------------------------------------------------------------------

step(
  "a keymap file that binds {string} to {string}",
  (ctx: KeymapWorld, key: string, action: string) => {
    keymapFile(ctx)[key] = action;
  },
);

step("a keymap file that sets {string} to null", (ctx: KeymapWorld, key: string) => {
  keymapFile(ctx)[key] = null;
});

step(
  "a keymap file that binds {string} to {string} with the description {string}",
  (ctx: KeymapWorld, key: string, action: string, description: string) => {
    keymapFile(ctx)[key] = { action, description };
  },
);

step(
  "a keymap file with a {string} section that binds {string} to {string} and sets {string} to null",
  (ctx: KeymapWorld, section: string, key: string, action: string, unbound: string) => {
    keymapFile(ctx)[section] = { [key]: action, [unbound]: null };
  },
);

step("a keymap file that is not valid JSON", (ctx: KeymapWorld) => {
  ctx.keymapFile = `{ "ctrl+p": "palette.open", }`;
});

step("the TUI starts with that keymap file", async (ctx: KeymapWorld) => {
  if (typeof ctx.keymapFile !== "string") {
    await startKeymaps(ctx);
    return;
  }
  // A broken file stops the real entry before it takes over the terminal.
  writeFile(ctx, "config/keymap.json", ctx.keymapFile);
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !key.startsWith("T3_TUI_") && key !== "T3CODE_HOME")
      env[key] = value;
  }
  const child = Bun.spawn(["bun", "src/index.ts"], {
    cwd: TUI_DIR,
    env: {
      ...env,
      T3_TUI_ORIGIN: "http://127.0.0.1:9",
      T3_TUI_BEARER: "unused",
      T3_TUI_SHELL_DIR: configDir(ctx),
      T3_TUI_LOG: writeFile(ctx, "tui.log", ""),
    },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(), ENTRY_TIMEOUT_MS);
  const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  clearTimeout(timer);
  ctx.entryRun = { code, stderr };
});

step("the TUI exits with a load error naming the keymap file", (ctx: KeymapWorld) => {
  expect(ctx.entryRun?.code).toBe(1);
  expect(ctx.entryRun?.stderr).toContain(NodePath.join(configDir(ctx), "keymap.json"));
  expect(ctx.entryRun?.stderr).toContain("is not valid JSON");
});

step("pressing {string} opens the command palette", async (ctx: KeymapWorld, key: string) => {
  expect(await press(ctx, key)).toContain("palette.open");
});

step("pressing {string} does not start a new thread", async (ctx: KeymapWorld, key: string) => {
  expect(await press(ctx, key)).not.toContain("thread.new");
});

step("both {string} and {string} quit", async (ctx: KeymapWorld, first: string, second: string) => {
  for (const key of [first, second]) {
    ctx.quitRequested = false;
    await press(ctx, key);
    expect(ctx.quitRequested, `${key} should quit`).toBe(true);
  }
});

step(
  /^the keys listed for "([^"]+)" are "([^"]+)"(?: and "([^"]+)")?$/,
  async (ctx: KeymapWorld, action: string, ...keys: Array<string | undefined>) => {
    await startKeymaps(ctx);
    const listed = allKeymaps(ctx).flatMap((keymap) => [...keymap.keysFor(action)]);
    expect(listed.map((key) => key.toLowerCase()).toSorted()).toEqual(
      keys
        .filter((key) => key !== undefined)
        .map((key) => key.toLowerCase())
        .toSorted(),
    );
  },
);

/** Give the thread list the keys, as the user would before pressing list keys. */
async function focusList(ctx: KeymapWorld) {
  await startKeymaps(ctx);
  if (ctx.host!.state.get("mode") !== "list") ctx.host!.dispatch("sidebar.list.focus");
}

step(
  "in the thread list {string} moves to the next thread",
  async (ctx: KeymapWorld, key: string) => {
    await focusList(ctx);
    const before = selectedThread(ctx);
    expect(await press(ctx, key)).toEqual(["thread.next"]);
    expect(selectedThread(ctx)).not.toBe(before);
  },
);

step("{string} does nothing in the thread list", async (ctx: KeymapWorld, key: string) => {
  await focusList(ctx);
  const before = selectedThread(ctx);
  expect(await press(ctx, key)).toEqual([]);
  expect(selectedThread(ctx)).toBe(before);
});

step("the TUI is running", async (ctx: KeymapWorld) => {
  await startKeymaps(ctx);
});

step(
  "a keymap override binds {string} to {string}",
  (ctx: KeymapWorld, key: string, action: string) => {
    ctx.serial = ctx.app;
    applyKeymapOverrides(ctx.app!.engine, { [key]: action });
  },
);

step("pressing {string} quits without a restart", async (ctx: KeymapWorld, key: string) => {
  await press(ctx, key);
  expect(ctx.quitRequested).toBe(true);
  expect(ctx.app).toBe(ctx.serial as never);
});

step("the keymap's bindings are listed", async (ctx: KeymapWorld) => {
  await startKeymaps(ctx);
  ctx.described = [...keymapHandle(ctx, "globalKeymap").describe()];
});

step("{string} is listed as {string}", (ctx: KeymapWorld, key: string, description: string) => {
  const entry = ctx.described!.find((each) => each.keys.toLowerCase() === key.toLowerCase());
  expect(entry, `bindings: ${JSON.stringify(ctx.described)}`).toMatchObject({ description });
});

// --- key spellings ------------------------------------------------------------------------------------

/**
 * The key a scenario names in words, as pressed on the keyboard. "escape" is the common
 * "the user presses escape" step, which boots the planned keymap shell the same way.
 */
const SPOKEN_KEYS: Record<string, { key: string; modifiers?: Record<string, boolean> }> = {
  "control and k": { key: "k", modifiers: { ctrl: true } },
  "alt and enter": { key: "RETURN", modifiers: { meta: true } },
  "alt and x": { key: "x", modifiers: { meta: true } },
  "the super key and k": { key: "k", modifiers: { super: true } },
  "page down": { key: "\u001b[6~" },
  "control and plus": { key: "+", modifiers: { ctrl: true } },
};

step(
  new RegExp(`^the user presses (${Object.keys(SPOKEN_KEYS).join("|")})$`),
  async (ctx: KeymapWorld, spoken: string) => {
    const app = await startKeymaps(ctx);
    markBefore(ctx);
    const { key, modifiers } = SPOKEN_KEYS[spoken]!;
    await app.pressKey(key, modifiers);
  },
);

// "the command palette opens" is keymap.steps.ts's: the palette is open on screen.

step("the keymap loads", async (ctx: KeymapWorld) => {
  await (await startKeymaps(ctx)).renderOnce();
});

step(
  "the user is warned that {string} is not a known modifier",
  (ctx: KeymapWorld, modifier: string) => {
    expectProblem(ctx, "warning", `unknown modifier "${modifier}"`);
  },
);

step("the other bindings in the file still work", async (ctx: KeymapWorld) => {
  // The file's entries merge over the built-in keymap; the rest of it still answers.
  expect(await press(ctx, "ctrl+k")).toContain("palette.open");
});

// --- plugin keymaps ------------------------------------------------------------------------------------

step(
  "the plugin keymap {string} with high priority binds {string} to {string}",
  (ctx: KeymapWorld, name: string, key: string, action: string) => {
    keymapPlugin(ctx, name, {
      bindings: { [key]: action },
      priority: 10,
      activated: LIST_ACTIVATED,
    });
  },
);

step(
  "the plugin keymap {string} binds {string} to {string}",
  (ctx: KeymapWorld, name: string, key: string, action: string) => {
    keymapPlugin(ctx, name, { bindings: { [key]: action }, activated: LIST_ACTIVATED });
  },
);

step(
  "the plugin keymap {string} records {string} and lets it pass",
  (ctx: KeymapWorld, name: string, key: string) => {
    keymapPlugin(ctx, name, {
      bindings: { [key]: "record" },
      priority: 10,
      activated: `keyLog.push("${name} ${key}"); event.accepted = false`,
    });
  },
);

step("the selection moves to the next thread", (ctx: KeymapWorld) => {
  expect(actions(ctx)).toContain("thread.next");
  expect(selectedThread(ctx)).not.toBeNull();
});

step("no new thread is started", (ctx: KeymapWorld) => {
  expect(actions(ctx)).not.toContain("thread.new");
});

step("{string} records the key", (ctx: KeymapWorld, name: string) => {
  expect(ctx.keyLog?.some((entry) => entry.startsWith(`${name} `))).toBe(true);
});

step("a new thread is started", (ctx: KeymapWorld) => {
  expect(actions(ctx)).toContain("thread.new");
});

step("the user disables {string}", async (ctx: KeymapWorld, name: string) => {
  await startKeymaps(ctx);
  ctx.keymaps![name]!.enabled = false;
});

step("pressing {string} no longer moves the selection", async (ctx: KeymapWorld, key: string) => {
  const before = selectedThread(ctx);
  expect(await press(ctx, key)).not.toContain("thread.next");
  expect(selectedThread(ctx)).toBe(before);
});

step(
  /^the plugin "([^"]+)" (?:declares the action "([^"]+)" bound to|binds) "([^"]+)"$/,
  (ctx: KeymapWorld, name: string, action: string | undefined, key: string) => {
    const snippetAction = action ?? `${name}.insert`;
    keymapPlugin(ctx, name, {
      bindings: { [key]: snippetAction },
      activated: `Shell.dispatch("composer.insert", { text: "snippet from ${name}" })`,
    });
  },
);

step("pressing {string} inserts a snippet", async (ctx: KeymapWorld, key: string) => {
  await press(ctx, key);
  expect(ctx.dispatched).toContainEqual({
    action: "composer.insert",
    payload: { text: "snippet from snippets" },
  });
});

step("pressing {string} does nothing", async (ctx: KeymapWorld, key: string) => {
  expect(await press(ctx, key)).toEqual([]);
});

// --- scoped keys (need the composer, terminal and settings bricks) -------------------------------------

step("the composer has focus", async (ctx: KeymapWorld) => {
  await startKeymaps(ctx);
  ctx.host!.dispatch("thread.open", { key: "thread:t1" });
  expect(ctx.host!.state.get("mode")).toBe("compose");
});

step("{string} is added to the draft", (ctx: KeymapWorld, text: string) => {
  expect((ctx.host!.state.get("composer") as { text: string }).text).toContain(text);
  expect(actions(ctx)).not.toContain("thread.next");
});

step(
  "the terminal panel binds {string} to {string} for itself only",
  async (ctx: KeymapWorld, key: string, action: string) => {
    await startKeymaps(ctx);
    expect(keymapHandle(ctx, "terminalKeymap").keysFor(action)).toContain(key);
  },
);

step("the terminal viewport is not copied", (ctx: KeymapWorld) => {
  expect(actions(ctx)).not.toContain("terminal.copy");
});

step("the user opens the keybinding reference in Settings", async (ctx: KeymapWorld) => {
  await startKeymaps(ctx);
  ctx.host!.dispatch("settings.open", { section: "keybindings" });
});

step(
  "bindings are grouped into Global, Conversation, Terminal and Source control",
  (ctx: KeymapWorld) => {
    expect(ctx.host!.state.get("settings")).toMatchObject({ active: true });
    const reference = ctx.host!.state.get("keybindings") as {
      groups: ReadonlyArray<{ title: string }>;
    };
    expect(reference.groups.map((group) => group.title)).toEqual(
      expect.arrayContaining(["Global", "Conversation", "Terminal", "Source control"]),
    );
  },
);
