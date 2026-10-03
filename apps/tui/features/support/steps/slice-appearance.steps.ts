// tui/appearance.feature: what the user takes out of the conversation (a
// message's text, a link, a file location in their editor).
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import type { EditorCommand } from "../../../src/promptEditor.ts";
import { step } from "../../steps.ts";
import { thread } from "../fakeClient.ts";
import { chooseCommand } from "../threadUi.ts";
import { clickText, message, openThread, type ThreadWorld } from "../threadWorld.ts";
import { pressKey, settle, type World } from "../world.ts";

interface TakeWorld extends ThreadWorld {
  editorRuns?: Array<{ command: EditorCommand; file: string; content: string }>;
}

const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };

const REPLY = [
  "The total is rounded twice.",
  "",
  "The second rounding is in src/cart.ts:42; drop it and the tax matches.",
].join("\n");
const CART = Array.from({ length: 60 }, (_, index) => `// cart line ${index + 1}`).join("\n");
const LINK = "https://hal-c2.example/attachments/att-receipt";

/** A thread with a question, the agent's two-paragraph reply and a screenshot with a link. */
async function openConversation(ctx: TakeWorld) {
  const runs = (ctx.editorRuns ??= []);
  ctx.hostOptions = {
    ...ctx.hostOptions,
    env: { EDITOR: "vim" },
    runEditor: async (command, file) => {
      runs.push({ command, file, content: NodeFS.readFileSync(file, "utf8") });
    },
  };
  const messages = [
    message("m-1", "user", "Why is the tax off by a cent?", 1, {
      attachments: [
        {
          type: "image",
          id: "att-receipt",
          name: "receipt.png",
          mimeType: "image/png",
          sizeBytes: 2048,
        },
      ],
    } as never),
    message("m-2", "assistant", REPLY, 2),
  ];
  await openThread(ctx, { ...thread(), messages } as never, {
    getAttachmentUrl: async () => LINK,
    readFile: async (_cwd, path) => (path === "src/cart.ts" ? CART : null),
  });
  await settle(ctx);
}

// --- Copy a message -------------------------------------------------------------

step("the user copies a message from the timeline", async (ctx: TakeWorld) => {
  await openConversation(ctx);
  await chooseCommand(ctx, "Copy a message…");
  // Newest first: the agent's reply, then the user's question.
  expect(select(ctx).options).toEqual([
    { label: "The total is rounded twice.", description: "agent" },
    { label: "Why is the tax off by a cent?", description: "you" },
  ]);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the message text is on the system clipboard", (ctx: TakeWorld) => {
  // The whole message, not just the line the picker showed.
  expect(ctx.clipboard).toEqual([REPLY]);
  expect(status(ctx)).toEqual({ kind: "success", text: "Message copied." });
});

// --- Links ------------------------------------------------------------------------

// The client draws in a terminal, possibly over SSH: it has no way to open a
// browser on the user's machine, so nothing is set up here beyond the clipboard.
step("the terminal cannot open links", (ctx: TakeWorld) => {
  ctx.clipboardSupported = true;
});

step("the user opens a link from the timeline", async (ctx: TakeWorld) => {
  await openConversation(ctx);
  await clickText(ctx, "receipt.png");
  await settle(ctx);
});

step("the link is copied and the status line says so", async (ctx: TakeWorld) => {
  expect(ctx.clipboard).toEqual([LINK]);
  expect(status(ctx)).toEqual({ kind: "success", text: "Link copied: open it in your browser." });
  const statusRow = ctx.host!.state.get("statusRow") as { label: string };
  expect(await settle(ctx)).toContain(statusRow.label);
  expect(statusRow.label).toContain("Link copied");
});

// --- File references ---------------------------------------------------------------

step("the user opens a file reference from the timeline", async (ctx: TakeWorld) => {
  await openConversation(ctx);
  await chooseCommand(ctx, "Open a file reference in $EDITOR…");
  expect(select(ctx).options.map((option) => option.label)).toEqual(["src/cart.ts:42"]);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the file opens in the user's editor at that line", (ctx: TakeWorld) => {
  expect(ctx.editorRuns).toHaveLength(1);
  const [run] = ctx.editorRuns!;
  expect(run!.command).toEqual({ cmd: "vim", args: ["+42"] });
  expect(NodePath.basename(run!.file)).toBe("cart.ts");
  expect(run!.content).toBe(CART);
  // Read only: nothing was written back.
  expect(ctx.fake!.calls.filter((call) => call.method === "writeFile")).toEqual([]);
});
