// tui/reconnect.feature: a server restart, as the client sees it (the
// connection drops and comes back) and what it leaves untouched.
import { expect } from "bun:test";

import type { TuiComposerState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import type { ReconnectWorld } from "../reconnectWorld.ts";
import type { ThreadWorld } from "../threadWorld.ts";
import { pressKey, resize, settle, snapshot, typeText } from "../world.ts";

type World = ReconnectWorld & ThreadWorld & { before?: Record<string, unknown> };

const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;
const panel = (ctx: World) =>
  (ctx.host!.state.get("layout") as { rightPanel: { visible: boolean; kind: string | null } })
    .rightPanel;
const where = (ctx: World) => ({
  page: ctx.host!.state.get("page"),
  draft: composer(ctx).text,
  panel: panel(ctx),
  mode: ctx.host!.state.get("mode"),
});

step("the server restarts", async (ctx: World) => {
  // Mid-work, on a terminal wide enough for a panel beside the conversation: a
  // half-written prompt and the source-control panel open.
  await resize(ctx, 160);
  await typeText(ctx, "Next, cover the edge case where");
  await pressKey(ctx, "Ctrl+L");
  await pressKey(ctx, "Esc");
  await settle(ctx);
  ctx.before = where(ctx);
  expect(composer(ctx).text).toBe("Next, cover the edge case where");
  expect(panel(ctx).visible).toBe(true);
  await ctx.connection!.drop();
});

step("the status line reports the restart", async (ctx: World) => {
  expect(ctx.connection!.phases.at(-1)).toBe("reconnecting");
  expect(status(ctx)).toEqual({ kind: "busy", text: "The server went away; reconnecting…" });
  const row = ctx.host!.state.get("statusRow") as { label: string };
  expect(await snapshot(ctx)).toContain(row.label);
  expect(row.label).toContain("The server went away");
});

step("the thread, draft and open panels are the same once it is back", async (ctx: World) => {
  await ctx.connection!.connected(2);
  await settle(ctx);
  expect((ctx.host!.state.get("connection") as { state: string }).state).toBe("connected");
  expect(status(ctx)).toEqual({
    kind: "success",
    text: "The server is back; carrying on where you were.",
  });
  expect(where(ctx) as Record<string, unknown>).toEqual(ctx.before!);
  // On screen as well: the draft in the prompt and the panel beside the conversation.
  const screen = await snapshot(ctx);
  expect(screen).toContain("Next, cover the edge case where");
  expect(screen).toContain("Source Control");
  // And the prompt still takes the keys.
  await typeText(ctx, " x");
  expect(composer(ctx).text).toBe("Next, cover the edge case where x");
});
