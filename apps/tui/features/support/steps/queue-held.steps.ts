// composer/queue-and-steer.feature: a held queue says so, and ^X q or the palette resumes it.
import { expect } from "bun:test";

import type { OrchestrationThread } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import type { TimelineState } from "../../../src/host/timelineState.ts";
import { objectRows } from "../design.ts";
import { message, shownText } from "../threadWorld.ts";
import { pressKey, settle, type World } from "../world.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import { callsTo, updateThread, type ComposerWorld } from "./composer.steps.ts";

const timeline = (ctx: World) => ctx.host!.state.get("timeline") as TimelineState;

step("{string} was queued when the MC restarted", async (ctx: ComposerWorld, text: string) => {
  // The adapter's shape for a held queue: the message waits in line, and the thread says so.
  await updateThread(
    ctx,
    (detail) =>
      ({
        ...detail,
        messages: [
          ...detail.messages,
          { ...message("queued-1", "user", text, 5), queued: { position: 1, held: true } },
        ],
        queueHeld: true,
      }) as unknown as OrchestrationThread,
  );
});

step("the MC comes back", async (ctx: World) => {
  // The restart ended the running turn; the queue stays held behind it.
  await updateThread(
    ctx,
    (detail) =>
      ({
        ...detail,
        session: { ...(detail.session as object), status: "idle" },
      }) as OrchestrationThread,
  );
});

step(
  "the queue is headed {string} and says {string}",
  async (ctx: World, heading: string, says: string) => {
    const held = timeline(ctx).queueHeld;
    expect(held).not.toBeNull();
    expect(shownText(held!.text)).toContain(heading);
    expect(shownText(held!.text)).toContain(says);
    // On screen, with the keys that resume it.
    const rows = (await objectRows(ctx, "queueHeld")).join("\n");
    expect(rows).toContain(heading);
    expect(rows).toContain("^X q resume");
  },
);

step("the queue is shown as held", async (ctx: World) => {
  expect((await objectRows(ctx, "queueHeld")).join("\n")).toContain("Queue held");
});

step("the user resumes the queue", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+X");
  await pressKey(ctx, "q");
  await settle(ctx);
});

step("the user resumes the queue from the command palette", async (ctx: World) => {
  await runPaletteCommand(ctx, "Resume the queue");
});

step("the MC is asked to resume the queue", async (ctx: World) => {
  expect(callsTo(ctx, "resumeQueue").map((call) => call.args[0])).toEqual(["t1"]);
  expect((ctx.host!.state.get("status") as { text: string }).text).toBe("Queue resumed.");
});
