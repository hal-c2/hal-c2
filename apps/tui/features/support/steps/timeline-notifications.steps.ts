// features/timeline/notifications.feature on the terminal client: muting one
// thread's alerts. Threads live in the fake environment (environment.ts); the
// user mutes from the palette while the thread is open, as on the desktop.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { addThread, change, flush, threadNamed, ui, type EnvThread } from "../environment.ts";
import { chooseCommand, palette, selectThread } from "../threadUi.ts";
import { snapshot, type World } from "../world.ts";

/** The thread the user looks at while the others work. */
const VIEWED = "Notes";

type Alert = { title: string; description: string };
const alerts = (ctx: World) => (ctx.host!.state.get("notifications") as { items: Alert[] }).items;
const alertFor = (ctx: World, title: string) =>
  alerts(ctx).find((alert) => alert.description === title);

const turn = (state: "running" | "completed") =>
  ({
    turnId: "turn-1",
    state,
    requestedAt: "2026-07-15T11:00:00.000Z",
    startedAt: "2026-07-15T11:00:00.000Z",
    completedAt: state === "completed" ? "2026-07-15T11:05:00.000Z" : null,
    assistantMessageId: null,
  }) as unknown as EnvThread["latestTurn"];

/** `title` works while the user looks at another thread. */
async function workInBackground(ctx: World, title: string) {
  addThread(ctx, VIEWED);
  addThread(ctx, title, { session: { status: "running" }, latestTurn: turn("running") });
  change(ctx, () => {});
  await ui(ctx);
  await selectThread(ctx, VIEWED);
}

async function finish(ctx: World, title: string) {
  change(ctx, () => {
    Object.assign(threadNamed(ctx, title), {
      session: { status: "idle" },
      latestTurn: turn("completed"),
    });
  });
  await flush(ctx);
}

// The terminal's in-app alerts have no switch: they are on.
step("the user has alerts turned on", async (ctx: World) => {
  await ui(ctx);
  expect(alerts(ctx)).toEqual([]);
});

step("the thread {string} is working in the background", (ctx: World, title: string) =>
  workInBackground(ctx, title),
);

async function toggleMute(ctx: World, title: string, command: string) {
  await selectThread(ctx, title);
  await chooseCommand(ctx, command);
  expect(palette(ctx).open).toBe(false);
  // Back to the other thread, so `title`'s alerts are not the shown thread's.
  await selectThread(ctx, VIEWED);
}

const mute = (ctx: World, title: string) => toggleMute(ctx, title, "Mute alerts for this thread");

step("the user mutes alerts for {string}", mute);

step("alerts for {string} are muted", async (ctx: World, title: string) => {
  await workInBackground(ctx, title);
  await mute(ctx, title);
});

step("the user unmutes {string}", (ctx: World, title: string) =>
  toggleMute(ctx, title, "Unmute alerts for this thread"),
);

step("{string} finishes its turn", finish);

step("no alert is raised for {string}", async (ctx: World, title: string) => {
  expect(alertFor(ctx, title)).toBeUndefined();
  expect(await snapshot(ctx)).not.toContain(`Thread completed · ${title}`);
});

step("alerts for other threads in {string} still arrive", async (ctx: World, project: string) => {
  const other = addThread(ctx, "Docs pass", {
    project,
    session: { status: "running" },
    latestTurn: turn("running"),
  });
  change(ctx, () => {});
  await flush(ctx);
  await finish(ctx, other.title);
  expect(alertFor(ctx, "Docs pass")).toMatchObject({ title: "Thread completed" });
  expect(await snapshot(ctx)).toContain("Thread completed · Docs pass");
});

step("an alert for {string} is raised", async (ctx: World, title: string) => {
  expect(alertFor(ctx, title)).toMatchObject({ title: "Thread completed" });
  expect(await snapshot(ctx)).toContain(`Thread completed · ${title}`);
});
