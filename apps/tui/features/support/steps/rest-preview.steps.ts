// preview/surfaces.feature: the terminal client has no browser, so it lists the
// addresses there are (open on the MC, configured on a script, printed by the
// terminal) and acts on the MC's tabs.
import { expect } from "bun:test";
import type { PreviewSessionSnapshot } from "@hal-c2/contracts";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { pressKey, settle, type World } from "../world.ts";
import { ensureOpen, type FilesWorld } from "./files.steps.ts";
import { command, script, setScripts, terminalPrints } from "./slice-projects.steps.ts";

const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method).map((call) => [...call.args]);

async function pick(ctx: World, label: string) {
  const index = select(ctx).options.findIndex((option) => option.label === label);
  expect(index, `no "${label}" in the picker`).toBeGreaterThanOrEqual(0);
  const moves = index - select(ctx).index;
  for (let i = 0; i < Math.abs(moves); i += 1) await pressKey(ctx, moves > 0 ? "Down" : "Up");
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

const STORYBOOK = "http://localhost:6006";
const DEV = "http://localhost:5173";

// --- Addresses ----------------------------------------------------------------------------

// Storybook's address is set on its script; the dev server's is only known
// because the terminal printed it.
step("a project with configured and discovered preview addresses", async (ctx: FilesWorld) => {
  await setScripts(ctx, [script("dev"), script("storybook", { previewUrl: STORYBOOK })]);
  await command(ctx, "Run dev");
  await terminalPrints(ctx, `  ➜  Local:   ${DEV}\r\n`);
});

step("the user opens previews in the terminal client", (ctx: World) => command(ctx, "Previews"));

step("the addresses are listed with ways to open or copy each one", async (ctx: World) => {
  expect(select(ctx)).toMatchObject({ open: true, title: "previews" });
  expect(select(ctx).options).toEqual([
    { label: STORYBOOK, description: "configured for storybook" },
    { label: DEV, description: "seen in the terminal" },
  ]);
  const rows = (await objectRows(ctx, "selectOverlay")).join("\n");
  expect(rows).toContain(STORYBOOK);
  expect(rows).toContain(DEV);
  // Each one offers the same two things: a preview on the MC, or the link for a browser.
  for (const url of [STORYBOOK, DEV]) {
    await pick(ctx, url);
    expect(select(ctx).title).toBe(url);
    expect(select(ctx).options.map((option) => option.label)).toEqual([
      "Open as a preview",
      "Copy link",
    ]);
    await pick(ctx, "Copy link");
    expect(status(ctx)).toEqual({ kind: "success", text: "Link copied." });
    await command(ctx, "Previews");
  }
  expect(ctx.clipboard).toEqual([STORYBOOK, DEV]);
  await pick(ctx, STORYBOOK);
  await pick(ctx, "Open as a preview");
  expect(callsTo(ctx, "openPreview")).toEqual([["t1", STORYBOOK]]);
  expect(status(ctx).text).toBe(`Preview opened: ${STORYBOOK}`);
  // No page is drawn here: the conversation is still what the terminal shows.
  expect(ctx.host!.state.get("page")).toMatchObject({ kind: "thread" });
});

// --- The MC's tabs ---------------------------------------------------------------------------

const tab = (tabId: string, url: string): PreviewSessionSnapshot =>
  ({
    threadId: "t1",
    tabId,
    navStatus: { _tag: "Success", url, title: url },
    canGoBack: false,
    canGoForward: false,
    updatedAt: "2026-07-15T12:00:00.000Z",
  }) as unknown as PreviewSessionSnapshot;

step("the thread has preview tabs", async (ctx: FilesWorld) => {
  await ensureOpen(ctx);
  ctx.fake!.server.previews = [tab("tab-1", DEV), tab("tab-2", STORYBOOK)];
  // The dev server has stopped since: loading its page again finds nothing there.
  ctx.fake!.override("refreshPreview", async (threadId, tabId) => {
    ctx.fake!.server.previews = ctx.fake!.server.previews.map((preview) =>
      preview.threadId === threadId && preview.tabId === tabId && preview.tabId === "tab-1"
        ? ({
            ...preview,
            navStatus: {
              _tag: "LoadFailed",
              url: DEV,
              title: DEV,
              code: -102,
              description: "connection refused",
            },
          } as unknown as PreviewSessionSnapshot)
        : preview,
    );
  });
});

step("the user refreshes or closes one in the terminal client", async (ctx: World) => {
  await command(ctx, "Previews");
  expect(select(ctx).options).toEqual([
    { label: DEV, description: "open preview" },
    { label: STORYBOOK, description: "open preview" },
  ]);
  await pick(ctx, DEV);
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "Copy link",
    "Refresh",
    "Close preview",
  ]);
  await pick(ctx, "Refresh");
});

step("the MC's tab list updates and unreachable pages are reported", async (ctx: World) => {
  expect(callsTo(ctx, "refreshPreview")).toEqual([["t1", "tab-1"]]);
  // The refresh found nothing listening: said at once, and kept in the list.
  expect(status(ctx)).toEqual({
    kind: "error",
    text: `Preview unreachable: ${DEV} (connection refused)`,
  });
  await command(ctx, "Previews");
  expect(select(ctx).options).toEqual([
    { label: DEV, description: "open preview · unreachable: connection refused" },
    { label: STORYBOOK, description: "open preview" },
  ]);
  expect((await objectRows(ctx, "selectOverlay")).join("\n")).toContain("unreachable");
  // Closing it takes the tab off the MC; the other one stays.
  await pick(ctx, DEV);
  await pick(ctx, "Close preview");
  expect(callsTo(ctx, "closePreview")).toEqual([["t1", "tab-1"]]);
  expect(ctx.fake!.server.previews.map((preview) => preview.tabId)).toEqual(["tab-2"]);
  await command(ctx, "Previews");
  expect(select(ctx).options).toEqual([{ label: STORYBOOK, description: "open preview" }]);
});
