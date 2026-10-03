// The settings pages (features/settings/*): helpers to set up the fake MC
// behind them (`fakeSettingsMc.ts`), open a page as the palette does, and read
// what it shows. The page's state is `Shell.state.settingsSection`.
import { expect } from "bun:test";

import type { TuiSettingsSectionState } from "../../src/host/settingsSections.ts";
import type { FakeSettingsMc } from "./fakeSettingsMc.ts";
import { objectRows } from "./design.ts";
import { project, shell } from "./fakeClient.ts";
import { boot, pressKey, settle, useClient, type World } from "./world.ts";

/** The fake MC's settings side, creating the fake client on first use. */
export const mc = (ctx: World): FakeSettingsMc => (ctx.fake ?? useClient(ctx)).settings;

export const sectionState = (ctx: World) =>
  ctx.host!.state.get("settingsSection") as TuiSettingsSectionState;

/** Another machine this MC is linked to, as `hal-c2.environmentLinks` lists it. */
export interface FakeLink {
  readonly id: string;
  label: string;
  online: boolean;
  serverVersion: string;
  capabilities: Record<string, unknown>;
  host?: string;
}

/** What the scenario's MC holds besides its settings calls: its projects and its links. */
export interface SettingsFixture {
  /** Project ids are their titles ("api"); empty leaves the fake client's default shell. */
  readonly projects: string[];
  readonly links: FakeLink[];
}

export interface SettingsWorld extends World {
  settingsFixture?: SettingsFixture;
}

/** The scenario's projects and links; the links answer `hal-c2.environmentLinks`. */
export function fixture(ctx: SettingsWorld): SettingsFixture {
  if (ctx.settingsFixture) return ctx.settingsFixture;
  const created: SettingsFixture = { projects: [], links: [] };
  ctx.settingsFixture = created;
  mc(ctx).on("hal-c2.environmentLinks", () =>
    created.links.map((link) => ({
      environment: {
        environmentId: link.id,
        label: link.label,
        serverVersion: link.serverVersion,
        capabilities: link.capabilities,
        ...(link.host ? { host: link.host } : {}),
      },
      origin: `http://${link.id}.example:3773`,
      online: link.online,
      ...(link.online ? {} : { problem: "unreachable" }),
    })),
  );
  return created;
}

/** Link another machine to the MC (connected unless said otherwise). */
export function linkMachine(ctx: SettingsWorld, label: string, online = true): FakeLink {
  const links = fixture(ctx).links;
  let link = links.find((known) => known.label === label);
  if (!link) {
    link = { id: `env-${label}`, label, online, serverVersion: "1.4.0", capabilities: {} };
    links.push(link);
  }
  link.online = online;
  return link;
}

/** Codex's and Claude's models, as the server lists them. */
export const MODELS = [
  { instanceId: "codex", model: "codex-model", label: "codex-model", providerLabel: "Codex" },
  { instanceId: "claude", model: "claude-model", label: "claude-model", providerLabel: "Claude" },
];

const fixtureProject = (title: string) => ({
  ...project,
  id: title,
  title,
  workspaceRoot: `/work/${title}`,
  // Claude's model, so a default that is not the first listed one shows.
  defaultModelSelection: { instanceId: "claude", model: "claude-model" },
});

/** Start the client connected to its MC, showing the scenario's projects. */
export async function connected(ctx: SettingsWorld): Promise<void> {
  if (ctx.app) return;
  const fake = ctx.fake ?? useClient(ctx);
  const projects = ctx.settingsFixture?.projects ?? [];
  if (projects.length === 0) {
    ctx.connectOnBoot = true;
    await boot(ctx);
  } else {
    fake.override("listModels", (async () => MODELS) as never);
    await boot(ctx);
    fake.emitConnection("connected");
    fake.emitShell(shell([] as never, projects.map(fixtureProject) as never));
  }
  await settle(ctx);
}

/** Open a settings page (the action its palette entry runs) and let it load. */
export async function openSection(
  ctx: World,
  id: string,
  payload: Record<string, unknown> = {},
): Promise<string> {
  await connected(ctx);
  ctx.host!.dispatch("section.open", { id, ...payload });
  const screen = await settle(ctx);
  expect(sectionState(ctx).id).toBe(id);
  return screen;
}

/** Every line of the open page, joined (what the page says, windowed or not). */
export const pageText = (ctx: World): string => sectionState(ctx).lines.join("\n");

/** The page as drawn: the rows of the settings pane on screen. */
export async function paneText(ctx: World): Promise<string> {
  await settle(ctx);
  return (await objectRows(ctx, "settingsSection")).join("\n");
}

/** The page as drawn, its borders dropped and runs of blanks joined: wrapped values read on. */
export async function paneWords(ctx: World): Promise<string> {
  return (await paneText(ctx)).replace(/[│╭╮╰╯─]/g, " ").replace(/\s+/g, " ");
}

/** Walk the selection to the row whose text contains `label`, with ↑/↓ as a user would. */
export async function selectRow(ctx: World, label: string): Promise<void> {
  await settle(ctx);
  for (let guard = 0; guard < 200; guard += 1) {
    const state = sectionState(ctx);
    const selected = state.rows.find((row) => row.selected);
    if (selected?.text.includes(label)) return;
    const before = state.selectedId;
    await pressKey(ctx, "Down");
    await settle(ctx);
    if (sectionState(ctx).selectedId === before) break;
  }
  // Not below: walk back up from the end.
  for (let guard = 0; guard < 200; guard += 1) {
    const state = sectionState(ctx);
    if (state.rows.find((row) => row.selected)?.text.includes(label)) return;
    const before = state.selectedId;
    await pressKey(ctx, "Up");
    await settle(ctx);
    if (sectionState(ctx).selectedId === before) break;
  }
  throw new Error(`no row "${label}" on the page:\n${pageText(ctx)}`);
}

/** Select a row and press Enter on it. */
export async function chooseRow(ctx: World, label: string): Promise<string> {
  await selectRow(ctx, label);
  await pressKey(ctx, "Enter");
  return settle(ctx);
}

/** Type into the page's one-line field (replacing what it holds) and press Enter. */
export async function fillField(ctx: World, text: string): Promise<string> {
  await settle(ctx);
  const input = sectionState(ctx).input;
  expect(input, "the page asks for nothing").not.toBeNull();
  expect(ctx.host!.state.get("mode")).toBe("sectionInput");
  for (let i = 0; i < input!.value.length; i += 1) await pressKey(ctx, "Backspace");
  if (text !== "") await ctx.app!.typeText(text);
  await pressKey(ctx, "Enter");
  return settle(ctx);
}
