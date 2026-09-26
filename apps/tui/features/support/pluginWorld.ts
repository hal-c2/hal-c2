// The plugin scenarios' world: plugin files and a keymap file written to a temp
// directory, slot modes set through a user shell.qml, then the real shell booted
// with them (`world.boot`). Shared by plugins.steps.ts and keymaps.steps.ts.
//
// A contribution draws "[id]" unless the fixture table gives it a body.
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { createPropertyMap, type PropertyMap } from "opentui-qml";

import type { TuiProblem } from "../../src/host/host.ts";
import type { TuiPluginInfo } from "../../src/host/plugins.ts";
import { readUserConfig } from "../../src/host/userConfig.ts";
import { shownText } from "./threadWorld.ts";
import { boot, findObject, snapshot, type World } from "./world.ts";

export type SlotName = "statusbar" | "composer.actions" | "sidebar.footer";

export interface PluginWorld extends World {
  pluginDir?: string;
  /** Slot modes the scenario's shell sets. */
  slotModes?: Partial<Record<SlotName, string>>;
  /** The slot the last Given talked about ("contribute to it"). */
  lastSlot?: SlotName;
  /** Plugins written by Given steps, by id, in load order. */
  pluginSpecs?: Map<string, PluginSpec>;
  scriptPlugins?: object[];
  prefs?: PropertyMap;
  cleanupLog?: string[];
  listed?: ReadonlyArray<TuiPluginInfo>;
  serial?: unknown;
  echoed?: string;
  /** Plugin files written verbatim (file name → source), after the fixture plugins. */
  rawPlugins?: Map<string, string>;
  /** The user's keymap.json: bindings, or raw text for a broken file. */
  keymapFile?: Record<string, unknown> | string;
  /** What plugin keymaps recorded (`keyLog` in QML). */
  keyLog?: string[];
  /** Plugin keymaps by name (`keymaps` in QML), so steps can list and toggle them. */
  keymaps?: Record<string, KeymapHandle>;
  /** Options for the shell `start` boots, read when the shell is prepared. */
  startOptions?: StartOptions;
}

/** A Keymap object as JS sees it through its proxy. */
export interface KeymapHandle {
  enabled: boolean;
  keysFor(action: string): string[];
  describe(): Array<{ keys: string; action: string; description: string }>;
}

export interface PluginSpec {
  slot: SlotName;
  order: number | string;
  file?: string;
  /** Contributions to write: one normally, two for "twice". */
  bodies?: string[];
  declareId?: boolean;
}

/** Where each slot sits in the default shell. */
export const SLOT_OBJECTS: Record<SlotName, string> = {
  statusbar: "statusbarSlot",
  "composer.actions": "composerActionsSlot",
  "sidebar.footer": "sidebarFooterSlot",
};

/** The shell property that sets each slot's mode (`DefaultShell { statusLine.slotMode: … }`). */
export const MODE_PROPERTIES: Record<SlotName, string> = {
  statusbar: "statusLine.slotMode",
  "composer.actions": "composer.actionsMode",
  "sidebar.footer": "sidebar.footerMode",
};

/** Contribution bodies for plugins whose content matters to the scenario. */
export const BODIES: Record<string, string> = {
  "title-echo": `Text { objectName: "plugin-title-echo"
    property int serial: Math.floor(Math.random() * 1e9)
    text: "[title-echo " + data.title + " #" + serial + "]" }`,
  inspector: `Text { objectName: "plugin-inspector"
    text: "[id=" + plugin.pluginId + " slot=" + slot + " theme=" + theme
      + " engine=" + (engine ? "yes" : "no") + "]" }`,
  "broken-visual": `QtObject { }`,
  crashy: `Text { text: "[crashy]"; NoSuchType { } }`,
};

export const PROBE_BODY = (id: string) => `Text { objectName: "plugin-${id}"
    text: "[${id} theme=" + typeof theme + ":" + theme + " limit=" + typeof limit + ":" + limit + "]" }`;

export const label = (id: string) => `[${id}]`;

export function asSlot(name: string): SlotName {
  if (!(name in SLOT_OBJECTS)) throw new Error(`the default shell has no slot "${name}"`);
  return name as SlotName;
}

export function pluginDir(ctx: PluginWorld): string {
  if (!ctx.pluginDir) {
    const dir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-tui-plugins-"));
    ctx.cleanups.push(() => NodeFS.rmSync(dir, { recursive: true, force: true }));
    ctx.pluginDir = dir;
  }
  return ctx.pluginDir;
}

export function writeFile(ctx: PluginWorld, name: string, content: string): string {
  const file = NodePath.join(pluginDir(ctx), name);
  NodeFS.mkdirSync(NodePath.dirname(file), { recursive: true });
  NodeFS.writeFileSync(file, content);
  return file;
}

export function pluginSource(id: string, spec: PluginSpec): string {
  const bodies = spec.bodies ?? [
    BODIES[id] ?? `Text { objectName: "plugin-${id}"; text: "${label(id)}" }`,
  ];
  const contributions = bodies
    .map((body) => `  Contribution { slot: "${spec.slot}"\n    ${body} }`)
    .join("\n");
  return `import OpenTUI
Plugin {
${spec.declareId === false ? "" : `  pluginId: "${id}"\n`}  order: ${spec.order}
  Component.onDestruction: cleanupLog.push("${id}")
${contributions}
}
`;
}

/** Record (or update) a plugin the shell will load at start. */
export function contribute(
  ctx: PluginWorld,
  id: string,
  slot: string = ctx.lastSlot ?? "statusbar",
  spec: Partial<PluginSpec> = {},
) {
  const plugins = (ctx.pluginSpecs ??= new Map());
  const existing = plugins.get(id);
  plugins.set(id, { order: 0, ...existing, slot: asSlot(slot), ...spec });
  ctx.lastSlot = asSlot(slot);
}

export function setMode(ctx: PluginWorld, slot: string, mode: string) {
  (ctx.slotModes ??= {})[asSlot(slot)] = mode;
  ctx.lastSlot = asSlot(slot);
}

export interface StartOptions {
  pluginDirs?: string[];
  plugins?: string[];
  context?: Record<string, unknown>;
}

/**
 * Boot with this scenario's plugins whenever the shell starts, also from shared steps
 * that boot on their own (a key press). Givens call this; `before` runs ahead of it.
 */
export function planShell(ctx: PluginWorld, before?: () => void) {
  ctx.prepare ??= () => {
    before?.();
    prepareShell(ctx, ctx.startOptions ?? {});
  };
}

/** Write the plugin files and the scenario shell, then boot (once). */
export async function start(ctx: PluginWorld, extra: StartOptions = {}) {
  if (ctx.app) return ctx.app;
  ctx.startOptions = extra;
  planShell(ctx);
  // Wide enough for the composer footer plus plugin controls: the OpenTUI
  // client's footer alone already fills a 100-column terminal.
  const app = await boot(ctx, { columns: ctx.columns ?? 160 });
  for (const [slot, objectName] of Object.entries(SLOT_OBJECTS)) {
    expect(findObject(ctx, objectName).get("name")).toBe(slot);
  }
  return app;
}

function prepareShell(ctx: PluginWorld, extra: StartOptions) {
  const files: string[] = [];
  for (const [id, spec] of ctx.pluginSpecs ?? []) {
    files.push(writeFile(ctx, spec.file ?? `${id}.qml`, pluginSource(id, spec)));
  }
  const modes = Object.entries(ctx.slotModes ?? {}).map(
    ([slot, mode]) => `${MODE_PROPERTIES[slot as SlotName]}: "${mode}"`,
  );
  for (const [file, source] of ctx.rawPlugins ?? []) files.push(writeFile(ctx, file, source));
  ctx.cleanupLog ??= [];
  ctx.keyLog ??= [];
  ctx.keymaps ??= {};
  const keymap = userKeymap(ctx);
  ctx.prefs ??= createPropertyMap({ weather: 20 });
  ctx.qml = {
    ...ctx.qml,
    ...(modes.length > 0
      ? { shellSource: `import HalC2.Tui\nDefaultShell { ${modes.join("; ")} }\n` }
      : {}),
    plugins: [...(ctx.scriptPlugins ?? []), ...files, ...(extra.plugins ?? [])],
    ...(extra.pluginDirs ? { pluginDirs: extra.pluginDirs } : {}),
    ...(keymap ? { keymap } : {}),
    context: {
      cleanupLog: ctx.cleanupLog,
      keyLog: ctx.keyLog,
      keymaps: ctx.keymaps,
      ...ctx.qml?.context,
      ...extra.context,
    },
    singletons: { Prefs: ctx.prefs },
  };
}

/** The config directory the scenario's keymap.json lives in. */
export function configDir(ctx: PluginWorld): string {
  return NodePath.join(pluginDir(ctx), "config");
}

/** Write the scenario's keymap.json and read it back the way the client's entry does. */
export function userKeymap(ctx: PluginWorld): Record<string, unknown> | undefined {
  if (ctx.keymapFile === undefined) return undefined;
  const text =
    typeof ctx.keymapFile === "string" ? ctx.keymapFile : JSON.stringify(ctx.keymapFile, null, 2);
  writeFile(ctx, "config/keymap.json", text);
  return readUserConfig({ configDir: configDir(ctx), warn: () => {} }).keymap;
}

/** The screen line a slot is drawn on. */
export async function slotLine(ctx: PluginWorld, slot: SlotName): Promise<string> {
  await start(ctx);
  const screen = (await snapshot(ctx)).split("\n");
  const marker = BUILT_IN_MARKERS[slot];
  const lines =
    slot === "statusbar" ? [screen.findLast((line) => line.trim() !== "") ?? ""] : screen;
  return marker
    ? (lines.find((line) => line.includes(marker(ctx))) ?? lines.join("\n"))
    : lines.join("\n");
}

export const BUILT_IN_MARKERS: Record<SlotName, ((ctx: PluginWorld) => string) | null> = {
  statusbar: (ctx) => (ctx.host!.state.get("status") as { text: string }).text,
  "composer.actions": (ctx) => shownText(findObject(ctx, "composerModel").get("text")),
  "sidebar.footer": null,
};

export async function expectBuiltIn(ctx: PluginWorld, slot: SlotName) {
  await start(ctx);
  const marker = BUILT_IN_MARKERS[slot];
  if (marker) expect(await snapshot(ctx)).toContain(marker(ctx));
  const screen = await snapshot(ctx);
  for (const [id, spec] of ctx.pluginSpecs ?? []) {
    if (spec.slot === slot) expect(screen).not.toContain(label(id));
  }
}

export function problems(ctx: PluginWorld): ReadonlyArray<TuiProblem> {
  return (ctx.host!.state.get("problems") as { items: TuiProblem[] }).items;
}

export const problemText = (problem: TuiProblem) => `${problem.where ?? ""} ${problem.message}`;

export function expectProblem(
  ctx: PluginWorld,
  level: TuiProblem["level"] | null,
  ...needles: string[]
) {
  const found = problems(ctx).filter(
    (problem) =>
      (level === null || problem.level === level) &&
      needles.every((needle) => problemText(problem).includes(needle)),
  );
  expect(
    found.map(problemText),
    `problems:\n${problems(ctx).map(problemText).join("\n")}`,
  ).not.toEqual([]);
}

export function listedPlugins(ctx: PluginWorld): ReadonlyArray<TuiPluginInfo> {
  return (ctx.host!.state.get("plugins") as { items: TuiPluginInfo[] }).items;
}

export async function settleLoads(ctx: PluginWorld) {
  await Promise.all(ctx.pluginLoads ?? []);
}

export function expectBefore(text: string, first: string, second: string) {
  expect(text).toContain(first);
  expect(text).toContain(second);
  expect(text.indexOf(first)).toBeLessThan(text.indexOf(second));
}

/** The serial an echoing contribution drew next to `text`; fails when it shows something else. */
export function echoSerial(screen: string, id: string, text: string): string {
  const match = new RegExp(`\\[${id} ${text} #(\\d+)\\]`).exec(screen);
  expect(match, `"${id}" should show "${text}"`).not.toBeNull();
  return match![1]!;
}
