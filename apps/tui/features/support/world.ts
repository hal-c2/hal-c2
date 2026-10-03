// The scenario world: a fake client feeding the real host, rendered by the
// real QML bricks in opentui-qml's headless test renderer.
//
// Steps get the context (a plain object) and use these helpers on it. The
// client is not connected at boot: call `ctx.fake.connect()` (default
// snapshot) or `ctx.fake.emitShell(snapshot)` when the scenario has data.
// Configure the fake before the first render with `useClient(ctx, options)`.
import * as NodePath from "node:path";
import { KeyEvent } from "@opentui/core";
import type { QmlObject } from "opentui-qml";
import { testQml, type QmlTestApp } from "opentui-qml/testing";

import { createHost, type Host, type HostOptions } from "../../src/host/host.ts";
import { enginePluginPort } from "../../src/host/plugins.ts";
import { movePromptCursorToEnd } from "../../src/host/promptCursor.ts";
import type { StepContext } from "../steps.ts";
import { fakeClient } from "./fakeClient.ts";

export const QML_DIR = NodePath.resolve(import.meta.dir, "../../qml");
export const DEFAULT_SHELL = NodePath.join(QML_DIR, "HalC2/Tui/DefaultShell.qml");

const DEFAULT_COLUMNS = 100;
const DEFAULT_ROWS = 40;

/** How the client starts: a user shell, plugins, keymap overrides, context values. */
export interface BootOptions {
  /** A user `shell.qml` booted instead of DefaultShell; `import HalC2.Tui` resolves. */
  shellSource?: string;
  /** Plugin files (paths) or script plugins (`{ id, slots, ... }`). */
  plugins?: Array<string | object>;
  pluginDirs?: string[];
  keymap?: Record<string, unknown>;
  context?: Record<string, unknown>;
  /** Extra singletons next to Shell and Theme. */
  singletons?: Record<string, unknown>;
}

export interface World extends StepContext {
  readonly tags: ReadonlyArray<string>;
  readonly cleanups: Array<() => unknown>;
  columns?: number;
  rows?: number;
  fake?: ReturnType<typeof fakeClient>;
  host?: Host;
  app?: QmlTestApp;
  /** What the host logged (unknown actions). */
  logs?: string[];
  quitRequested?: boolean;
  /** Pinned wall clock (epoch ms) for snooze and age; the real clock when unset. */
  nowMs?: number;
  /** What the client put on the clipboard, newest last. */
  clipboard?: string[];
  /** False makes the terminal refuse the clipboard (OSC 52 unsupported). */
  clipboardSupported?: boolean;
  /** Deliver the first snapshot right after boot (scenarios that start on an open thread). */
  connectOnBoot?: boolean;
  /** Extra host options (editor runner, env, local files) set before boot. */
  hostOptions?: Partial<HostOptions>;
  /** Every action the host saw, oldest first. */
  dispatched?: Array<{ action: string; payload: unknown }>;
  /**
   * Encode keys with the Kitty keyboard protocol, as modern terminals do, so
   * Shift+Enter and Ctrl+Shift+M differ from Enter and Ctrl+M. Set before boot.
   */
  kittyKeyboard?: boolean;
  /** The current step's kind (the runner sets it): Given is "Context", Then is "Outcome". */
  stepType?: "Context" | "Action" | "Outcome" | "Unknown";
  /**
   * Requests a step deliberately left unanswered (a clone or branch switch in
   * flight). While above zero, `settle` renders without waiting for the host
   * to go idle, which it never would.
   */
  held?: number;
  /** Start options (user shell, plugins, keymap overrides); set them before the first boot. */
  qml?: BootOptions;
  /** Runs right before the first boot, from whichever step boots (scenario start options). */
  prepare?: () => void;
  /** Plugin loads the host started (`plugin.load`); await them before asserting. */
  pluginLoads?: Array<Promise<void>>;
}

/** Set up the fake client before boot; later calls replace it only if not booted. */
export function useClient(ctx: World, options: Parameters<typeof fakeClient>[0] = {}) {
  if (ctx.app) throw new Error("useClient: the client is already running");
  ctx.fake = fakeClient(options);
  return ctx.fake;
}

/** Boot (once) at the given size, or the current / default size. */
export async function boot(
  ctx: World,
  size: { columns?: number; rows?: number } = {},
): Promise<QmlTestApp> {
  if (ctx.app) return ctx.app;
  ctx.prepare?.();
  const columns = size.columns ?? ctx.columns ?? DEFAULT_COLUMNS;
  const rows = size.rows ?? ctx.rows ?? DEFAULT_ROWS;
  const fake = ctx.fake ?? useClient(ctx);
  const logs: string[] = (ctx.logs ??= []);
  const clipboard: string[] = (ctx.clipboard ??= []);
  const dispatched = (ctx.dispatched ??= []);
  const host = createHost({
    ...ctx.hostOptions,
    client: fake.client,
    size: { columns, rows },
    log: (message) => logs.push(message),
    onQuit: () => {
      ctx.quitRequested = true;
    },
    now: () => new Date(ctx.nowMs ?? Date.now()).toISOString(),
    copyToClipboard: (text) => {
      if (ctx.clipboardSupported === false) return false;
      clipboard.push(text);
      return true;
    },
    trace: (action, payload) => dispatched.push({ action, payload }),
    promptCursorToEnd: (text) => {
      if (ctx.app) movePromptCursorToEnd(ctx.app.root, text);
    },
  });
  ctx.cleanups.push(() => host.destroy());
  await host.ready;
  const { shellSource, ...runOptions } = ctx.qml ?? {};
  const app = await testQml(shellSource ?? { file: DEFAULT_SHELL }, {
    ...runOptions,
    width: columns,
    height: rows,
    importPaths: [QML_DIR],
    ...(ctx.kittyKeyboard ? { renderer: { kittyKeyboard: true } } : {}),
    singletons: { ...runOptions.singletons, Shell: host.Shell, Theme: host.Theme },
    onError: host.reportError,
    onWarning: host.reportWarning,
  });
  ctx.cleanups.push(() => app.destroy());
  const port = enginePluginPort(app.engine);
  const pluginLoads = (ctx.pluginLoads ??= []);
  host.attachPlugins({
    ...port,
    load: (file) => {
      const loading = port.load(file);
      pluginLoads.push(loading);
      return loading;
    },
  });
  Object.assign(ctx, { columns, rows, host, app });
  if (ctx.connectOnBoot) fake.connect();
  return app;
}

/** Resize the terminal (booting at that size if nothing runs yet). */
export async function resize(ctx: World, columns: number, rows = ctx.rows ?? DEFAULT_ROWS) {
  if (!ctx.app) {
    await boot(ctx, { columns, rows });
    return;
  }
  ctx.host!.resize({ columns, rows });
  await ctx.app.resize(columns, rows);
  ctx.columns = columns;
  ctx.rows = rows;
}

export async function snapshot(ctx: World): Promise<string> {
  return (await boot(ctx)).snapshot();
}

const NAMED_KEYS: Record<string, string> = {
  esc: "ESCAPE",
  escape: "ESCAPE",
  enter: "RETURN",
  return: "RETURN",
  tab: "TAB",
  backspace: "BACKSPACE",
  delete: "DELETE",
  pgup: "\x1b[5~",
  pageup: "\x1b[5~",
  pgdn: "\x1b[6~",
  pagedown: "\x1b[6~",
  up: "ARROW_UP",
  down: "ARROW_DOWN",
  left: "ARROW_LEFT",
  right: "ARROW_RIGHT",
  home: "HOME",
  end: "END",
  space: " ",
};

/** Press a key as the feature files spell it: "Ctrl+F", "Esc", "Alt+Up", "Shift+Tab". */
export async function pressKey(ctx: World, spelled: string): Promise<void> {
  const app = await boot(ctx);
  const parts = spelled.split("+");
  const keyName = parts.pop() ?? "";
  const modifiers = { ctrl: false, shift: false, meta: false };
  for (const part of parts) {
    const name = part.trim().toLowerCase();
    if (name === "ctrl" || name === "control") modifiers.ctrl = true;
    else if (name === "shift") modifiers.shift = true;
    else if (name === "alt" || name === "meta" || name === "option") modifiers.meta = true;
    else throw new Error(`pressKey: unknown modifier "${part}" in "${spelled}"`);
  }
  const named = NAMED_KEYS[keyName.toLowerCase()];
  const key = named ?? (keyName.length === 1 ? keyName.toLowerCase() : keyName);
  if (keyName.length === 1 && keyName !== keyName.toLowerCase() && !modifiers.ctrl) {
    modifiers.shift = true;
  }
  await app.pressKey(key, modifiers);
}

/**
 * Hold a key past the terminal's repeat delay: one press, then `repeats`
 * auto-repeat events (what kitty-protocol terminals report while a key is held).
 */
export async function holdKey(ctx: World, name: string, repeats = 2): Promise<void> {
  const app = await boot(ctx);
  const event = (eventType: "press" | "repeat") =>
    new KeyEvent({
      name,
      ctrl: false,
      meta: false,
      shift: false,
      option: false,
      sequence: name === "escape" ? "\x1b" : name,
      number: false,
      raw: name === "escape" ? "\x1b" : name,
      eventType,
      source: "kitty",
      repeated: eventType === "repeat",
    });
  app.renderer.keyInput.emit("keypress", event("press"));
  await app.renderOnce();
  for (let i = 0; i < repeats; i += 1) {
    app.renderer.keyInput.emit("keypress", event("repeat"));
    await app.renderOnce();
  }
}

export async function typeText(ctx: World, text: string): Promise<void> {
  await (await boot(ctx)).typeText(text);
}

export async function paste(ctx: World, text: string): Promise<void> {
  await (await boot(ctx)).paste(text);
}

/**
 * Wait for every request the host started (client calls, clones, terminal
 * writes), then render. While a step holds a request open, render without
 * waiting for the host to go idle, which it never would.
 */
export async function settle(ctx: World): Promise<string> {
  const app = await boot(ctx);
  for (let round = 0; round < 5; round += 1) {
    if (ctx.held) await new Promise((resolve) => setImmediate(resolve));
    else {
      await ctx.host!.idle();
      await ctx.host!.settled();
    }
    await app.advance(0);
  }
  return app.snapshot();
}

export async function advance(ctx: World, ms: number): Promise<void> {
  await (await boot(ctx)).advance(ms);
}

/** The first object with this `objectName`, depth first. Throws when missing. */
export function findObject(ctx: World, objectName: string): QmlObject {
  if (!ctx.app) throw new Error(`findObject(${objectName}): the client is not running`);
  const queue: QmlObject[] = [ctx.app.root];
  while (queue.length > 0) {
    const object = queue.shift()!;
    if (object.get("objectName") === objectName) return object;
    queue.push(...object.children);
  }
  throw new Error(`no object named "${objectName}" in the shell`);
}

export interface Geometry {
  readonly visible: boolean;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** Laid-out geometry of a visual (x/y relative to its parent). */
export function geometry(object: QmlObject): Geometry {
  return {
    visible: object.get("visible") === true,
    x: Number(object.get("x")),
    y: Number(object.get("y")),
    width: Number(object.get("layoutWidth")),
    height: Number(object.get("layoutHeight")),
  };
}

/** A bracketed text paste into whatever has focus. */
export async function pasteText(ctx: World, text: string): Promise<void> {
  await (await boot(ctx)).paste(text);
  await settle(ctx);
}

/** A clipboard image paste (Kitty OSC 5522 delivers bytes with a MIME type). */
export async function pasteBytes(ctx: World, bytes: Uint8Array, mimeType: string): Promise<void> {
  const app = await boot(ctx);
  app.renderer.keyInput.processPaste(bytes, { mimeType });
  await settle(ctx);
}

/** Click the first cell of a named object. */
export async function clickObject(ctx: World, objectName: string): Promise<void> {
  const app = await boot(ctx);
  await app.snapshot();
  const renderable = (
    findObject(ctx, objectName) as unknown as { renderable: { x: number; y: number } }
  ).renderable;
  await app.click(renderable.x, renderable.y);
  await settle(ctx);
}
