// tui/prompt.feature: context found by a trigger character ("/" commands,
// "$" skills, "@" files), file references as chips, and how a sent reference reads.
import { expect } from "bun:test";

import type { ServerProvider } from "@hal-c2/contracts";

import type { TuiComposerState, TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { PROVIDERS } from "../fakeClient.ts";
import { chooseCommand, clickText } from "../threadUi.ts";
import { message, timelineText, updateThread, type ThreadWorld } from "../threadWorld.ts";
import { findObject, pressKey, settle, typeText, type World } from "../world.ts";
import { chooseInPicker } from "./controls.steps.ts";

const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const labels = (ctx: World) => select(ctx).options.map((option) => option.label);
const sent = (ctx: World) => ctx.fake!.calls.filter((call) => call.method === "sendReply");

const FILES = ["src/cart.ts", "src/checkout.ts", "README.md"];

/** The thread's provider has commands and skills, and its workspace has files. */
async function withContext(ctx: World) {
  const providers = PROVIDERS.map((provider) =>
    provider.instanceId === "codex"
      ? {
          ...provider,
          slashCommands: [
            { name: "review", description: "Review the working tree" },
            { name: "compact", description: "Summarise the conversation so far" },
          ],
          skills: [
            {
              name: "release-notes",
              path: "/skills/release-notes",
              enabled: true,
              shortDescription: "Draft release notes",
            },
            { name: "retired", path: "/skills/retired", enabled: false },
          ],
        }
      : provider,
  ) as unknown as ServerProvider[];
  ctx.fake!.server.providers = providers;
  ctx.fake!.override(
    "getServerConfig",
    async () =>
      ({
        settings: ctx.fake!.server.settings,
        providers,
      }) as never,
  );
  ctx.fake!.override(
    "listEntries",
    async () => FILES.map((path) => ({ path, kind: "file" })) as never,
  );
  await chooseCommand(ctx, "Refresh providers");
  await settle(ctx);
}

async function typeTrigger(ctx: World, trigger: string) {
  await withContext(ctx);
  expect(composer(ctx).text).toBe("");
  await typeText(ctx, trigger);
  await settle(ctx);
}

step(/^the user types "([/$@])" in the prompt$/, typeTrigger);

const LISTS: Record<string, { title: string; labels: string[]; pick: string; text: string }> = {
  "slash commands": {
    title: "commands",
    labels: ["/review", "/compact"],
    pick: "/compact",
    text: "/compact ",
  },
  // Only the skills that are switched on.
  skills: {
    title: "skills",
    labels: ["$release-notes"],
    pick: "$release-notes",
    text: "$release-notes ",
  },
  files: { title: "files", labels: FILES, pick: "src/checkout.ts", text: "@src/checkout.ts " },
};

step(
  /^a list of (slash commands|skills|files) opens to pick from$/,
  async (ctx: World, items: string) => {
    const list = LISTS[items]!;
    expect(select(ctx)).toMatchObject({ open: true, title: list.title, searchable: true });
    expect(labels(ctx)).toEqual(list.labels);
    const rows = (await objectRows(ctx, "selectOverlay")).join("\n");
    for (const label of list.labels) expect(rows).toContain(label);
    // Typing narrows it, and the pick lands in the prompt where the trigger was.
    await typeText(ctx, list.pick.slice(1, 6));
    await settle(ctx);
    expect(labels(ctx)).toContain(list.pick);
    expect(labels(ctx).length).toBeLessThanOrEqual(list.labels.length);
    await chooseInPicker(ctx, list.pick);
    expect(select(ctx).open).toBe(false);
    expect(composer(ctx).text).toBe(list.text);
    expect(findObject(ctx, "composerInput").get("focus")).toBe(true);
  },
);

// --- Chips ---------------------------------------------------------------------------

async function addReference(ctx: World, path: string) {
  await typeText(ctx, "@");
  await settle(ctx);
  await chooseInPicker(ctx, path);
}

step("the user added a file reference to the prompt", async (ctx: World) => {
  await withContext(ctx);
  await typeText(ctx, "Fix the rounding in ");
  await addReference(ctx, "src/cart.ts");
  expect(composer(ctx).text).toBe("Fix the rounding in @src/cart.ts ");
});

step("the reference shows as a chip", async (ctx: World) => {
  expect(composer(ctx).references).toEqual([{ path: "src/cart.ts", label: "@src/cart.ts" }]);
  const [row] = await objectRows(ctx, "composerReferences");
  expect(row!.trim()).toBe("× @src/cart.ts");
});

step("the user can remove it before sending", async (ctx: World) => {
  await clickText(ctx, "× @src/cart.ts");
  await settle(ctx);
  // The chip and its mention are gone; the rest of the prompt stays.
  expect(composer(ctx).references).toEqual([]);
  expect(composer(ctx).text).toBe("Fix the rounding in ");
  expect(findObject(ctx, "composerReferences").get("visible")).toBe(false);
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(sent(ctx)).toHaveLength(1);
  expect(sent(ctx)[0]!.args[1]).toBe("Fix the rounding in");
});

// --- Sent references ---------------------------------------------------------------------

step("the user sends a prompt with a file reference", async (ctx: ThreadWorld) => {
  await withContext(ctx);
  await typeText(ctx, "Fix the rounding in ");
  await addReference(ctx, "src/cart.ts");
  await typeText(ctx, "please");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(sent(ctx)).toHaveLength(1);
  const text = sent(ctx)[0]!.args[1] as string;
  expect(text).toBe("Fix the rounding in @src/cart.ts please");
  // The server echoes the turn's message into the thread.
  await updateThread(ctx, (detail) => ({
    messages: [...detail.messages, message("m-sent", "user", text, 1)],
  }));
  await settle(ctx);
});

step("the sent message shows the reference inline", async (ctx: World) => {
  expect(timelineText(ctx)).toContain("Fix the rounding in @src/cart.ts please");
  expect(await settle(ctx)).toContain("Fix the rounding in @src/cart.ts please");
  // The prompt is clear again: no chip is left behind.
  expect(composer(ctx).references).toEqual([]);
});
