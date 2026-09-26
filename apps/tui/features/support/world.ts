// The scenario world: a fake client feeding the real host, rendered by the
// real QML bricks in opentui-qml's headless test renderer.
//
// Steps get the context (a plain object) and use these helpers on it. The
// client is not connected at boot: call `ctx.fake.connect()` (default
// snapshot) or `ctx.fake.emitShell(snapshot)` when the scenario has data.
// Configure the fake before the first render with `useClient(ctx, options)`.
import * as NodePath from "node:path";
import type { QmlObject } from "opentui-qml";
import { testQml, type QmlTestApp } from "opentui-qml/testing";

import { createHost, type Host } from "../../src/host/host.ts";
import type { StepContext } from "../steps.ts";
import { fakeClient } from "./fakeClient.ts";

export const QML_DIR = NodePath.resolve(import.meta.dir, "../../qml");
export const DEFAULT_SHELL = NodePath.join(QML_DIR, "T3/Tui/DefaultShell.qml");

const DEFAULT_COLUMNS = 100;
const DEFAULT_ROWS = 40;

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
  const columns = size.columns ?? ctx.columns ?? DEFAULT_COLUMNS;
  const rows = size.rows ?? ctx.rows ?? DEFAULT_ROWS;
  const fake = ctx.fake ?? useClient(ctx);
  const logs: string[] = (ctx.logs ??= []);
  const clipboard: string[] = (ctx.clipboard ??= []);
  const host = createHost({
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
  });
  ctx.cleanups.push(() => host.destroy());
  await host.ready;
  const app = await testQml(
    { file: DEFAULT_SHELL },
    {
      width: columns,
      height: rows,
      importPaths: [QML_DIR],
      singletons: { Shell: host.Shell, Theme: host.Theme },
    },
  );
  ctx.cleanups.push(() => app.destroy());
  Object.assign(ctx, { columns, rows, host, app });
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

export async function typeText(ctx: World, text: string): Promise<void> {
  await (await boot(ctx)).typeText(text);
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
