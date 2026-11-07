// features/timeline/runs-and-queue.feature on the terminal client: how a message
// reached the agent, what a sent attachment shows, and the context window reading.
import { expect } from "bun:test";
import * as DateTime from "effect/DateTime";

import { step } from "../../steps.ts";
import { project, shell, thread } from "../fakeClient.ts";
import { clickText } from "../threadUi.ts";
import {
  hostState,
  message,
  openThread,
  plain,
  settle,
  updateThread,
  type ThreadWorld,
} from "../threadWorld.ts";
import {
  addItem,
  currentRun,
  itemsOf,
  linesOf,
  NOW_MS,
  setItem,
  settleRun,
  startRun,
  shownItems,
  sync,
  turns,
  type TurnWorld,
} from "../turnWorld.ts";
import { snapshot } from "../world.ts";

// --- How a message reached the agent -------------------------------------------------

const INTENTS: Record<string, string> = {
  "queued behind the active turn": "queued_turn",
  "sent as a steer": "steer",
  "queued and later promoted to a steer": "promoted_queued_to_steer",
};

// The MC records the intent on the message's user_message turn item.
step(/^the user's message was (.+)$/, async (ctx: TurnWorld, how: string) => {
  const inputIntent = INTENTS[how];
  if (!inputIntent) throw new Error(`unknown way a message reaches the agent: ${how}`);
  const run = await startRun(ctx);
  await addItem(ctx, "user_message", {
    id: `item:${run}`,
    messageId: `message:${run}`,
    text: "Add tax to the cart",
    inputIntent,
  });
});

step("the message is marked {string}", async (ctx: TurnWorld, marker: string) => {
  // The row's own text: the screen wraps a long marker inside the bubble.
  const rows = itemsOf(ctx, "message").flatMap(linesOf);
  expect(rows).toContain(marker);
  expect((await snapshot(ctx)).replace(/[│╭╮╰╯─\s]+/g, " ")).toContain(marker.split(" ")[0]!);
});

// --- Sent attachments ----------------------------------------------------------------

const address = (name: string) => `https://mc.example/attachments/${name}`;

/** How many addresses the MC has given out for an attachment (each is a new signed link). */
const issued = new WeakMap<object, number>();
const nextAddress = (ctx: ThreadWorld, name: string) => {
  const count = (issued.get(ctx) ?? 0) + 1;
  issued.set(ctx, count);
  return count === 1 ? address(name) : `${address(name)}?signature=${count}`;
};

async function sendImage(ctx: ThreadWorld, name: string) {
  await openThread(
    ctx,
    {
      ...thread(),
      messages: [
        message("m-1", "user", "Here it is", 1, {
          attachments: [
            { type: "image", id: `att-${name}`, name, mimeType: "image/png", sizeBytes: 2048 },
          ],
        } as never),
      ],
    } as never,
    { getAttachmentUrl: async () => nextAddress(ctx, name) },
  );
}

step("the user sent the image {string} with a message", sendImage);

step("the message shows the image {string} from its MC", async (ctx: ThreadWorld, name: string) => {
  const rows = itemsOf(ctx, "message").flatMap(linesOf);
  expect(rows.some((row) => row.startsWith(`▣ ${name} · 2 KB`))).toBe(true);
  // The label's row opens the address the MC gave it.
  const entry = itemsOf(ctx, "message")
    .flatMap((item) => item.lines)
    .find((candidate) => plain(candidate.text).includes(name));
  expect(entry).toMatchObject({ action: "link.open", payload: { url: address(name) } });
  expect(await snapshot(ctx)).toContain(`▣ ${name} · 2 KB`);
});

// The MC's links last an hour: once it is past, showing the thread asks for a new one.
step("more than an hour passes", async (ctx: ThreadWorld) => {
  ctx.nowMs = Date.now() + 61 * 60_000;
  await updateThread(ctx, () => ({}));
  await settle();
  await settle();
});

step(
  "the message shows the image {string} from a new address",
  async (ctx: ThreadWorld, name: string) => {
    const entry = itemsOf(ctx, "message")
      .flatMap((item) => item.lines)
      .find((candidate) => plain(candidate.text).includes(name));
    expect(entry).toMatchObject({
      action: "link.open",
      payload: { url: `${address(name)}?signature=2` },
    });
  },
);

step(
  /^the user sent the file "(.+)" of (\d+) MB with a message$/,
  async (ctx: ThreadWorld, name: string, megabytes: string) => {
    await openThread(ctx, {
      ...thread(),
      messages: [
        message("m-1", "user", "Here it is", 1, {
          attachments: [
            {
              type: "file",
              id: `att-${name.replace(/\W/g, "")}`,
              name,
              mimeType: "application/pdf",
              sizeBytes: Number(megabytes) * 1024 * 1024,
            },
          ],
        } as never),
      ],
    } as never);
  },
);

step(
  "the message shows {string} with its kind and size",
  async (ctx: ThreadWorld, name: string) => {
    const rows = itemsOf(ctx, "message").flatMap(linesOf);
    expect(rows.some((row) => row === `▤ ${name} · PDF · 2 MB  link unavailable`)).toBe(true);
    expect(await snapshot(ctx)).toContain(`▤ ${name} · PDF · 2 MB`);
  },
);

// --- A thread's error ----------------------------------------------------------------

/** The shell row of the open thread reports `error` as why its latest run failed. */
async function showError(ctx: ThreadWorld, error: string, extra: Record<string, unknown> = {}) {
  if (!ctx.thread) await updateThread(ctx, () => ({}));
  ctx.fake!.emitShell(
    shell(
      [
        {
          id: "t1",
          projectId: "p1",
          title: "Thread one",
          updatedAt: "2026-07-13T00:00:00.000Z",
          session: { status: "error", lastError: error },
          latestTurn: null,
          ...extra,
        },
      ] as never,
      [{ ...project, title: ctx.projectTitle ?? project.title }] as never,
    ),
  );
  await settle();
  await snapshot(ctx);
}

step("the thread shows the error {string}", (ctx: ThreadWorld, error: string) =>
  showError(ctx, error),
);

step("the user dismisses the error", async (ctx: ThreadWorld) => {
  await clickText(ctx, "dismiss");
});

step("the error is hidden for this thread", async (ctx: ThreadWorld) => {
  expect(await snapshot(ctx)).not.toContain("Rate limited");
  // The way back stays on screen.
  await clickText(ctx, "error hidden");
  expect(await snapshot(ctx)).toContain("Rate limited");
  await clickText(ctx, "dismiss");
});

step("a different error on the same thread is still shown", async (ctx: ThreadWorld) => {
  await showError(ctx, "Connection lost");
  expect(await snapshot(ctx)).toContain("Connection lost");
});

/** The thread's second run, ended in `state`. */
const laterRun = (state: "error" | "completed") => ({
  turnId: "run-2",
  state,
  requestedAt: "2026-07-13T00:00:00.000Z",
  startedAt: "2026-07-13T00:00:00.000Z",
  completedAt: "2026-07-13T00:00:05.000Z",
  assistantMessageId: null,
});

step("a later run of the thread fails with {string}", async (ctx: ThreadWorld, error: string) => {
  await showError(ctx, error, { latestTurn: laterRun("error") });
});

// The session keeps its last error after a run succeeds: the MC never clears it.
step("a later run of the thread completes", async (ctx: ThreadWorld) => {
  await showError(ctx, "Rate limited", {
    session: { status: "ready", lastError: "Rate limited" },
    latestTurn: laterRun("completed"),
  });
});

step("the thread shows no error", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).not.toContain("Rate limited");
  expect(screen).not.toContain("error hidden");
});

step("the thread shows {string} as its error", async (ctx: ThreadWorld, error: string) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain(error);
  expect(screen).not.toContain("error hidden");
});

// --- A usage limit -------------------------------------------------------------------

step(
  "the provider stopped the turn at its usage limit, resetting at the top of an hour",
  async (ctx: ThreadWorld) => {
    const reset = new Date(Math.ceil((Date.now() + 60_000) / 3_600_000) * 3_600_000);
    await showError(ctx, "You've hit your usage limit", {
      lastErrorClass: "usage_limit",
      usageLimitResetAt: reset.toISOString(),
    });
  },
);

step("the timeline shows one warning line naming when to retry", async (ctx: ThreadWorld) => {
  const [banner, ...rest] = itemsOf(ctx, "notice");
  expect(rest).toEqual([]);
  expect(linesOf(banner!)).toHaveLength(1);
  expect(linesOf(banner!)[0]).toMatch(/^⚠ Usage limit reached · retry at .*:00/);
  expect(await snapshot(ctx)).toContain("Usage limit reached · retry at");
});

// --- A steer restarts the run --------------------------------------------------------

step("the agent finished its reply", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addItem(ctx, "assistant_message", { id: "reply-1", text: "The cart total is done." });
});

step("the agent is in the middle of its reply", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addItem(ctx, "assistant_message", {
    id: "reply-1",
    text: "The cart total is half wri",
    status: "running",
    streaming: true,
  });
});

step(/^the user's steer restarts the run(?: before the turn closed)?$/, async (ctx: TurnWorld) => {
  // The MC marks the run the steer interrupted with the steer's run, which starts next.
  const interrupted = currentRun(ctx);
  await settleRun(ctx, "interrupted", 5);
  await setItem(ctx, "reply-1", { streaming: false });
  const steer = await startRun(ctx);
  const fixture = await turns(ctx);
  const run = fixture.runs.find((entry) => entry.id === interrupted)!;
  run.steeredByRunId = steer;
  await addItem(ctx, "user_message", {
    id: "steer-1",
    messageId: `message:${steer}`,
    text: "Add tax to the cart",
    inputIntent: "steer",
  });
  await addItem(ctx, "assistant_message", { id: "reply-2", text: "Tax added.", status: "running" });
});

step("the run ends interrupted without a steer", async (ctx: TurnWorld) => {
  // A crash, an MC restart or an import stops the reply; no stop request, no steer.
  await settleRun(ctx, "interrupted", 5);
  await setItem(ctx, "reply-1", { streaming: false });
  await startRun(ctx);
  await addItem(ctx, "assistant_message", { id: "reply-2", text: "Tax added.", status: "running" });
});

step("what the agent had written is not folded as cut off", async (ctx: TurnWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("half wri");
  expect(screen).not.toContain("Cut off by a steer");
});

step("the finished reply stays visible as the turn's answer", async (ctx: TurnWorld) => {
  expect(await snapshot(ctx)).toContain("The cart total is done.");
});

step("it is not folded away as partial output", (ctx: TurnWorld) => {
  expect(itemsOf(ctx, "message").flatMap(linesOf).join("\n")).toContain("The cart total is done.");
  expect(shownItems(ctx).flatMap(linesOf).join("\n")).not.toContain("Cut off by a steer");
});

step(
  "what the agent had written is folded under {string}",
  async (ctx: TurnWorld, label: string) => {
    const screen = await snapshot(ctx);
    expect(screen).toContain(label);
    expect(screen).not.toContain("half wri");
    await clickText(ctx, label);
    expect(await snapshot(ctx)).toContain("half wri");
  },
);

// --- The context window reading ------------------------------------------------------

step(
  /^the agent has used ([\d,]+) tokens (of .+)$/,
  async (ctx: TurnWorld, tokens: string, window: string) => {
    const fixture = await turns(ctx);
    const maxTokens = /^of a ([\d,]+) token window$/.exec(window)?.[1];
    fixture.thread = { ...fixture.thread, activeProviderThreadId: "provider-thread-1" };
    fixture.providerThreads = [
      {
        id: "provider-thread-1",
        driver: "codex",
        providerInstanceId: "codex",
        providerSessionId: null,
        nativeThreadRef: null,
        status: "idle",
        contextUsage: {
          usedTokens: Number(tokens.replaceAll(",", "")),
          ...(maxTokens && { maxTokens: Number(maxTokens.replaceAll(",", "")) }),
        },
        createdAt: DateTime.makeUnsafe(new Date(NOW_MS - 3_600_000)),
        updatedAt: DateTime.makeUnsafe(new Date(NOW_MS)),
      },
    ];
    await sync(ctx);
  },
);

step("the context window reads {string}", async (ctx: TurnWorld, reading: string) => {
  expect(plain(hostState(ctx, "timeline").context)).toContain(reading);
  expect(await snapshot(ctx)).toContain(reading);
});
