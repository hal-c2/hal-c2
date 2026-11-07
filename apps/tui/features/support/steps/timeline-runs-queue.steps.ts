// features/timeline/runs-and-queue.feature on the terminal client: how a message
// reached the agent, what a sent attachment shows, and the context window reading.
import { expect } from "bun:test";
import * as DateTime from "effect/DateTime";

import { step } from "../../steps.ts";
import { thread } from "../fakeClient.ts";
import { hostState, message, openThread, plain, type ThreadWorld } from "../threadWorld.ts";
import {
  addItem,
  itemsOf,
  linesOf,
  NOW_MS,
  startRun,
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
    { getAttachmentUrl: async () => address(name) },
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
