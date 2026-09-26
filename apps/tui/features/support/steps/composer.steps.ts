// The prompt editor: drafting, sending, $EDITOR and image attachments
// (features/tui/prompt.feature and composer/*). Assertions read the published
// `composer` key and what the fake client was asked.
import { expect } from "bun:test";
import * as NodeFS from "node:fs/promises";

import { PROVIDER_SEND_TURN_MAX_ATTACHMENTS, type OrchestrationThread } from "@t3tools/contracts";

import { step } from "../../steps.ts";
import type { TuiComposerState } from "../../../src/host/composerState.ts";
import type { EditorCommand } from "../../../src/promptEditor.ts";
import { PROVIDERS, shell, thread } from "../fakeClient.ts";
import {
  boot,
  findObject,
  pasteBytes,
  pasteText,
  pressKey,
  settle,
  snapshot,
  typeText,
  useClient,
  type World,
} from "../world.ts";

/** A valid 1x1 PNG. */
export const PNG = Uint8Array.from(
  Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    "base64",
  ),
);
const HOME = "/home/tester";

export interface ComposerWorld extends World {
  /** Mutable: steps set `VISUAL` / `EDITOR` after boot. */
  editorEnv?: { VISUAL?: string; EDITOR?: string };
  editorRuns?: Array<{ command: EditorCommand; file: string }>;
  /** What the stub editor saves (null keeps the file as written). */
  editorSaves?: string | null;
  localImages?: Map<string, Uint8Array>;
  localReads?: string[];
  clipboard?: { bytes: Uint8Array; mimeType: string };
  textBeforePaste?: string;
  releaseSend?: () => void;
  /** Attachments already in the draft before the step under test. */
  attachedBefore?: number;
  /** Text the user typed before the step under test. */
  typedText?: string;
  threadBDraft?: string;
}

export function composer(ctx: World): TuiComposerState {
  return ctx.host!.state.get("composer") as TuiComposerState;
}

export function callsTo(ctx: World, method: string) {
  return ctx.fake!.calls.filter((call) => call.method === method);
}

/** Stub editor, fixed home and local files; set before boot. */
export function prepareHost(ctx: ComposerWorld): void {
  const env = (ctx.editorEnv ??= {});
  const runs = (ctx.editorRuns ??= []);
  const localImages = (ctx.localImages ??= new Map());
  const localReads = (ctx.localReads ??= []);
  ctx.kittyKeyboard = true;
  ctx.hostOptions = {
    env,
    homeDir: HOME,
    runEditor: async (command, file) => {
      runs.push({ command, file });
      const saves = ctx.editorSaves === undefined ? "Edited in the editor" : ctx.editorSaves;
      if (saves !== null) await NodeFS.writeFile(file, saves, "utf8");
    },
    readLocalImage: async (path) => {
      localReads.push(path);
      const bytes = localImages.get(path);
      if (!bytes) throw new Error("The pasted image path is not a file.");
      return bytes;
    },
    ...ctx.hostOptions,
  };
}

/** Boot on thread t1 (or `detail`), connected and settled, focus in the prompt. */
export async function openOnThread(
  ctx: ComposerWorld,
  detail: OrchestrationThread = thread(),
  options: Parameters<typeof useClient>[1] = {},
): Promise<void> {
  prepareHost(ctx);
  if (!ctx.fake) useClient(ctx, { detail, providers: PROVIDERS, ...options });
  ctx.fake!.workspaceFiles.set("assets/logo.png", PNG);
  ctx.fake!.workspaceFiles.set("logo.png", PNG);
  ctx.localImages!.set(`${HOME}/Pictures/bug.png`, PNG);
  await boot(ctx);
  ctx.fake!.connect();
  await settle(ctx);
}

/** Push a new version of the selected thread. */
export async function updateThread(
  ctx: World,
  patch: (detail: OrchestrationThread) => OrchestrationThread,
): Promise<void> {
  const current = ctx.fake!.currentThread("t1") ?? thread();
  ctx.fake!.emitThread(patch(current));
  await settle(ctx);
}

export const running = (detail: OrchestrationThread) =>
  ({
    ...detail,
    session: { ...(detail.session as object), status: "running" },
  }) as OrchestrationThread;

export const withQuestion = (detail: OrchestrationThread) =>
  ({
    ...detail,
    activities: [
      ...detail.activities,
      {
        id: "q-activity",
        tone: "info",
        kind: "user-input.requested",
        summary: "user-input.requested",
        payload: {
          requestId: "r1",
          questions: [
            {
              id: "q1",
              header: "Database",
              question: "Which driver?",
              options: [
                { label: "Postgres", description: "pg" },
                { label: "SQLite", description: "sqlite" },
              ],
              multiSelect: false,
            },
          ],
        },
        turnId: null,
        sequence: 1,
        createdAt: "2026-07-13T00:00:01.000Z",
      },
    ],
  }) as unknown as OrchestrationThread;

async function expectPrompt(ctx: World, text: string): Promise<void> {
  await settle(ctx);
  expect(composer(ctx).text).toBe(text);
  expect(
    findObject(ctx, "composerInput").get("plainText") ??
      findObject(ctx, "composerInput").get("text"),
  ).toBe(text);
}

/** Type into the prompt as the user would. */
export async function typeIntoPrompt(ctx: World, text: string): Promise<void> {
  await typeText(ctx, text);
  await settle(ctx);
  expect(composer(ctx).text).toContain(text);
}

const attachmentNames = (ctx: World) => composer(ctx).attachments.map((image) => image.name);

// --- Background ------------------------------------------------------------

step(
  "the terminal client is open on a thread with focus in the prompt",
  async (ctx: ComposerWorld) => {
    await openOnThread(ctx);
    expect(ctx.host!.state.get("mode")).toBe("compose");
    expect(findObject(ctx, "composerInput").get("focused")).toBe(true);
  },
);

// --- Drafting and sending --------------------------------------------------

// Given: type the text. Then: the draft is exactly that text.
step("the prompt contains {string}", async (ctx: World, text: string) => {
  if (ctx.stepType === "Outcome") await expectPrompt(ctx, text);
  else await typeIntoPrompt(ctx, text);
});

step("the prompt still contains {string}", async (ctx: World, text: string) => {
  await expectPrompt(ctx, text);
});

step("the prompt is empty", async (ctx: World) => {
  if (ctx.stepType !== "Outcome" && composer(ctx).text.length > 0) {
    await pressKey(ctx, "Esc");
  }
  await expectPrompt(ctx, "");
});

step("{string} is sent to the thread", async (ctx: World, text: string) => {
  await settle(ctx);
  const sent = callsTo(ctx, "sendReply");
  expect(sent).toHaveLength(1);
  expect(String((sent[0]!.args[0] as OrchestrationThread).id)).toBe("t1");
  expect(sent[0]!.args[1]).toBe(text);
});

step("nothing is sent", async (ctx: World) => {
  await settle(ctx);
  expect(callsTo(ctx, "sendReply")).toHaveLength(0);
});

step(
  "the user presses {string} and types {string}",
  async (ctx: World, key: string, text: string) => {
    await pressKey(ctx, key);
    await typeText(ctx, text);
    await settle(ctx);
  },
);

step("the prompt holds two lines and nothing is sent", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).text).toBe("First line\nSecond line");
  expect(callsTo(ctx, "sendReply")).toHaveLength(0);
});

const TEN_LINES = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`);

step("the user pastes ten lines of text", async (ctx: World) => {
  await pasteText(ctx, TEN_LINES.join("\n"));
});

step("all ten lines are in the prompt", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).text).toBe(TEN_LINES.join("\n"));
});

step("a reply is being sent", async (ctx: ComposerWorld) => {
  await typeIntoPrompt(ctx, "Run the tests");
  let release!: () => void;
  const answered = new Promise<void>((resolve) => {
    release = resolve;
  });
  ctx.releaseSend = release;
  ctx.cleanups.push(() => release());
  ctx.fake!.override("sendReply", () => answered);
  await pressKey(ctx, "Enter");
  expect(composer(ctx).isSendBusy).toBe(true);
});

step(
  "the user presses {string} again before the server answers",
  async (ctx: World, key: string) => {
    await pressKey(ctx, key);
  },
);

step("only one reply is sent", async (ctx: ComposerWorld) => {
  expect(callsTo(ctx, "sendReply")).toHaveLength(1);
  ctx.releaseSend?.();
  await settle(ctx);
  expect(callsTo(ctx, "sendReply")).toHaveLength(1);
});

step("the user sends it and the server accepts it", async (ctx: World) => {
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(callsTo(ctx, "sendReply")).toHaveLength(1);
});

step("the user sends it and the request fails", async (ctx: World) => {
  ctx.fake!.override("sendReply", () => Promise.reject(new Error("offline")));
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(callsTo(ctx, "sendReply")).toHaveLength(1);
});

step("the user presses {string} and then closes the palette", async (ctx: World, key: string) => {
  await pressKey(ctx, key);
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("command");
  await pressKey(ctx, "Esc");
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("compose");
});

step("the thread is running a turn", async (ctx: World) => {
  await updateThread(ctx, running);
  expect(composer(ctx).isRunning).toBe(true);
});

step("the turn is interrupted", async (ctx: World) => {
  await settle(ctx);
  expect(callsTo(ctx, "interrupt").map((call) => call.args[0])).toEqual(["t1"]);
});

async function expectPrimaryAction(ctx: World, label: string): Promise<void> {
  await settle(ctx);
  expect(composer(ctx).primaryAction as string).toBe(label);
  await snapshot(ctx);
  expect(String(findObject(ctx, "composerPrimaryAction").get("text"))).toContain(label);
}

step(
  "the primary action is {string} when the thread is idle",
  async (ctx: World, label: string) => {
    await expectPrimaryAction(ctx, label);
  },
);

step("it is {string} while the agent is working", async (ctx: World, label: string) => {
  await updateThread(ctx, running);
  await expectPrimaryAction(ctx, label);
});

step("it is {string} while a question is pending", async (ctx: World, label: string) => {
  await updateThread(ctx, (detail) =>
    withQuestion({ ...detail, session: { status: "idle" } } as OrchestrationThread),
  );
  await expectPrimaryAction(ctx, label);
});

// --- $EDITOR ---------------------------------------------------------------

step(
  "the environment variable {string} is {string}",
  (ctx: ComposerWorld, name: string, value: string) => {
    ctx.editorEnv![name as "VISUAL" | "EDITOR"] = value;
  },
);

const envValue = (raw: string): string | undefined =>
  raw === "unset" ? undefined : raw === "blank" ? "  " : raw.replace(/^"|"$/g, "");

step(
  /^VISUAL is (unset|blank|"[^"]*") and EDITOR is (unset|blank|"[^"]*")$/,
  (ctx: ComposerWorld, visual: string, editor: string) => {
    const env = ctx.editorEnv!;
    delete env.VISUAL;
    delete env.EDITOR;
    const nextVisual = envValue(visual);
    const nextEditor = envValue(editor);
    if (nextVisual !== undefined) env.VISUAL = nextVisual;
    if (nextEditor !== undefined) env.EDITOR = nextEditor;
  },
);

step("the draft opens in {string}", async (ctx: ComposerWorld, command: string) => {
  await settle(ctx);
  const runs = ctx.editorRuns!;
  expect(runs).toHaveLength(1);
  expect([runs[0]!.command.cmd, ...runs[0]!.command.args].join(" ")).toBe(command);
});

step("the edited text replaces the draft when the editor closes", async (ctx: World) => {
  await expectPrompt(ctx, "Edited in the editor");
});

async function saveInEditor(ctx: ComposerWorld, text: string): Promise<void> {
  ctx.editorSaves = text;
  await pressKey(ctx, "Ctrl+G");
  await settle(ctx);
  expect(ctx.editorRuns).toHaveLength(1);
}

step(
  "the user saves a draft with Windows line endings and trailing blank lines in the editor",
  async (ctx: ComposerWorld) => {
    await saveInEditor(ctx, "First paragraph\r\n\r\nSecond paragraph\r\n\r\n\r\n");
  },
);

step("the prompt uses plain line endings", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).text).not.toContain("\r");
});

step("the trailing blank lines are gone while interior blank lines stay", async (ctx: World) => {
  await expectPrompt(ctx, "First paragraph\n\nSecond paragraph");
});

step(
  "the user saves a draft in the editor with a line that is only a workspace image path",
  async (ctx: ComposerWorld) => {
    await saveInEditor(ctx, "Look at this\nassets/logo.png\nWhat is wrong?");
  },
);

step("that image is attached", async (ctx: World) => {
  await settle(ctx);
  expect(attachmentNames(ctx)).toEqual(["logo.png"]);
});

step("the path line is removed from the prompt", async (ctx: World) => {
  await expectPrompt(ctx, "Look at this\nWhat is wrong?");
});

// --- Pasting images --------------------------------------------------------

step("the clipboard holds a PNG image", (ctx: ComposerWorld) => {
  ctx.clipboard = { bytes: PNG, mimeType: "image/png" };
});

step("the clipboard holds truncated image bytes", (ctx: ComposerWorld) => {
  ctx.clipboard = { bytes: PNG.slice(0, 24), mimeType: "image/png" };
});

step("the user pastes into the prompt", async (ctx: ComposerWorld) => {
  ctx.textBeforePaste = composer(ctx).text;
  await pasteBytes(ctx, ctx.clipboard!.bytes, ctx.clipboard!.mimeType);
});

step("the user pastes {string}", async (ctx: ComposerWorld, text: string) => {
  ctx.textBeforePaste = composer(ctx).text;
  await pasteText(ctx, text);
});

step("the image is attached", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).attachments).toHaveLength(1);
  await snapshot(ctx);
  expect(String(findObject(ctx, "composerAttachments").get("text"))).toContain(
    composer(ctx).attachments[0]!.name,
  );
});

step("the draft text is unchanged", async (ctx: ComposerWorld) => {
  await expectPrompt(ctx, ctx.textBeforePaste ?? "");
});

step("the path is not inserted into the prompt", async (ctx: ComposerWorld) => {
  await expectPrompt(ctx, ctx.textBeforePaste ?? "");
});

step("the image is attached from the local disk", async (ctx: ComposerWorld) => {
  await settle(ctx);
  expect(attachmentNames(ctx)).toEqual(["bug.png"]);
  expect(ctx.localReads).toEqual([`${HOME}/Pictures/bug.png`]);
});

step("the prompt holds the prose without the path", async (ctx: World) => {
  await settle(ctx);
  const text = composer(ctx).text;
  expect(text).not.toContain("bug.png");
  expect(text).toContain("Why does");
  expect(text).toContain("look wrong?");
});

step("nothing is attached", async (ctx: ComposerWorld) => {
  await settle(ctx);
  expect(composer(ctx).attachments).toHaveLength(ctx.attachedBefore ?? 0);
});

// --- Attachment chips ------------------------------------------------------

async function attach(ctx: World, name: string): Promise<void> {
  ctx.host!.dispatch("composer.attach", { path: name });
  await settle(ctx);
}

// Given: attach it. Then: it is attached (and shown).
step("{string} is attached", async (ctx: World, name: string) => {
  if (ctx.stepType === "Outcome") await settle(ctx);
  else await attach(ctx, name);
  expect(attachmentNames(ctx)).toContain(name);
  await snapshot(ctx);
  expect(String(findObject(ctx, "composerAttachments").get("text"))).toContain(name);
});

step("the user attaches {string} again", async (ctx: World, name: string) => {
  await attach(ctx, name);
  expect(attachmentNames(ctx).filter((entry) => entry === name)).toHaveLength(1);
});

step(/^the status line says "([^"]*)" is already attached$/, async (ctx: World, name: string) => {
  await settle(ctx);
  expect((ctx.host!.state.get("status") as { text: string }).text).toBe(
    `${name} is already attached.`,
  );
});

step("the prompt has the most attachments a turn allows", async (ctx: World) => {
  for (let index = 0; index < PROVIDER_SEND_TURN_MAX_ATTACHMENTS; index += 1) {
    ctx.fake!.workspaceFiles.set(`shot-${index}.png`, PNG);
    ctx.host!.dispatch("composer.attach", { path: `shot-${index}.png` });
  }
  await settle(ctx);
  expect(composer(ctx).attachments).toHaveLength(PROVIDER_SEND_TURN_MAX_ATTACHMENTS);
});

step("the user attaches another image", async (ctx: World) => {
  ctx.fake!.workspaceFiles.set("one-more.png", PNG);
  await attach(ctx, "one-more.png");
});

step("the image is refused", async (ctx: World) => {
  expect(composer(ctx).attachments).toHaveLength(PROVIDER_SEND_TURN_MAX_ATTACHMENTS);
  expect(attachmentNames(ctx)).not.toContain("one-more.png");
});

step("the status line says how many images a turn can carry", async (ctx: World) => {
  expect((ctx.host!.state.get("status") as { text: string }).text).toContain(
    `up to ${PROVIDER_SEND_TURN_MAX_ATTACHMENTS} images`,
  );
});

step("the user removes the last attachment", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, "remove last attachment");
  await settle(ctx);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("{string} is no longer attached", async (ctx: World, name: string) => {
  await settle(ctx);
  expect(attachmentNames(ctx)).not.toContain(name);
  await snapshot(ctx);
  expect(String(findObject(ctx, "composerAttachments").get("text"))).not.toContain(name);
});

step(
  "{string} is attached and the prompt contains {string}",
  async (ctx: World, name: string, text: string) => {
    await attach(ctx, name);
    await typeIntoPrompt(ctx, text);
  },
);

step("the user sends the reply", async (ctx: World) => {
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step(
  "the reply carries {string} and a bounded copy of {string}",
  async (ctx: World, text: string, name: string) => {
    const sent = callsTo(ctx, "sendReply");
    expect(sent).toHaveLength(1);
    expect(sent[0]!.args[1]).toBe(text);
    const uploads = sent[0]!.args[2] as Array<{ name: string; sizeBytes: number; dataUrl: string }>;
    expect(uploads.map((upload) => upload.name)).toEqual([name]);
    expect(uploads[0]!.dataUrl.startsWith("data:image/")).toBe(true);
    const { PROVIDER_SEND_TURN_MAX_IMAGE_BYTES } = await import("@t3tools/contracts");
    expect(uploads[0]!.sizeBytes).toBeLessThanOrEqual(PROVIDER_SEND_TURN_MAX_IMAGE_BYTES);
  },
);

// --- composer/*.feature -------------------------------------------------------

step("a project with an open thread", async (ctx: ComposerWorld) => {
  await openOnThread(ctx);
});

step("a thread whose agent is working on a turn", async (ctx: ComposerWorld) => {
  await openOnThread(ctx, running(thread()));
  expect(composer(ctx).isRunning).toBe(true);
});

step("the thread's provider is ready", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).selectedModel).not.toBeNull();
});

step("the user has typed {string}", async (ctx: ComposerWorld, text: string) => {
  await typeIntoPrompt(ctx, (ctx.typedText = text));
});

step(/^the user presses (Enter|Escape)( again)?$/, async (ctx: World, key: string) => {
  await pressKey(ctx, key === "Escape" ? "Esc" : key);
  await settle(ctx);
});

step("the user types {string}", async (ctx: World, text: string) => {
  await typeText(ctx, text);
});

// "\n" in a feature string is a line break.
const unescape = (text: string) => text.replace(/\\n/g, "\n");

// Given: type it. Then: the draft is exactly that.
step("the draft reads {string}", async (ctx: ComposerWorld, text: string) => {
  if (ctx.stepType === "Outcome") await expectPrompt(ctx, unescape(text));
  else await typeIntoPrompt(ctx, (ctx.typedText = text));
});

step("the draft is empty", async (ctx: World) => {
  await expectPrompt(ctx, "");
});

step("the composer is empty", async (ctx: World) => {
  await expectPrompt(ctx, "");
  expect(composer(ctx).attachments).toHaveLength(0);
});

step("the message {string} is sent to the agent", async (ctx: World, text: string) => {
  await settle(ctx);
  const sent = callsTo(ctx, "sendReply");
  expect(sent.map((call) => call.args[1])).toEqual([text]);
  expect(String((sent[0]!.args[0] as OrchestrationThread).id)).toBe("t1");
});

// --- Sending while a send is in flight

step("the user has sent {string}", async (ctx: ComposerWorld, text: string) => {
  let release!: () => void;
  const answered = new Promise<void>((resolve) => {
    release = resolve;
  });
  ctx.releaseSend = release;
  ctx.cleanups.push(() => release());
  ctx.fake!.override("sendReply", () => answered);
  await typeIntoPrompt(ctx, text);
  await pressKey(ctx, "Enter");
  expect(callsTo(ctx, "sendReply").map((call) => call.args[1])).toEqual([text]);
});

step("the reply is still sending", (ctx: World) => {
  expect(composer(ctx).isSendBusy).toBe(true);
});

step(
  "the draft reads {string} after the send completes",
  async (ctx: ComposerWorld, text: string) => {
    ctx.releaseSend!();
    await settle(ctx);
    expect(composer(ctx).isSendBusy).toBe(false);
    await expectPrompt(ctx, text);
    expect(callsTo(ctx, "sendReply")).toHaveLength(1);
  },
);

step("the user sends it and the node rejects the message", async (ctx: World) => {
  ctx.fake!.override("sendReply", () => Promise.reject(new Error("turn rejected by the node")));
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the user sees why the send failed", async (ctx: World) => {
  await settle(ctx);
  expect(String(findObject(ctx, "statusText").get("text"))).toContain("turn rejected by the node");
});

step("the draft reads {string} again", async (ctx: World, text: string) => {
  await expectPrompt(ctx, text);
});

// --- Drafts per thread

const TWO_THREADS = [
  {
    id: "t1",
    projectId: "p1",
    title: "Thread A",
    updatedAt: "2026-07-13T00:00:02.000Z",
    session: { status: "idle" },
  },
  {
    id: "t2",
    projectId: "p1",
    title: "Thread B",
    updatedAt: "2026-07-13T00:00:01.000Z",
    session: { status: "idle" },
  },
];

step("the user has typed {string} in thread A", async (ctx: ComposerWorld, text: string) => {
  ctx.fake!.emitShell(shell(TWO_THREADS as never));
  ctx.fake!.emitThread({
    ...thread(),
    id: "t2",
    title: "Thread B",
  } as unknown as OrchestrationThread);
  await settle(ctx);
  expect(composer(ctx).target).toBe("thread:t1");
  await typeIntoPrompt(ctx, text);
});

step("the user switches to thread B and back to thread A", async (ctx: ComposerWorld) => {
  await pressKey(ctx, "Alt+Down");
  await settle(ctx);
  expect(composer(ctx).target).toBe("thread:t2");
  ctx.threadBDraft = composer(ctx).text;
  await pressKey(ctx, "Alt+Up");
  await settle(ctx);
  expect(composer(ctx).target).toBe("thread:t1");
});

step("thread A's draft reads {string}", async (ctx: World, text: string) => {
  await expectPrompt(ctx, text);
});

step("thread B's draft is empty", (ctx: ComposerWorld) => {
  expect(ctx.threadBDraft).toBe("");
});

// --- New threads

step("the user is starting a new thread in the project", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+N");
  await settle(ctx);
  expect(composer(ctx).newThread?.projectId).toBe("p1");
});

step("the user sends {string}", async (ctx: World, text: string) => {
  await typeIntoPrompt(ctx, text);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("a thread titled from {string} is created", async (ctx: World, text: string) => {
  const created = callsTo(ctx, "createThread");
  expect(created).toHaveLength(1);
  expect(created[0]!.args[0]).toMatchObject({ projectId: "p1", title: text });
  expect(composer(ctx).newThread).toBeNull();
});

step("its first turn starts with that message", (ctx: World) => {
  const [input] = callsTo(ctx, "createThread")[0]!.args as [
    { title: string; firstMessage: string },
  ];
  expect(input.firstMessage).toBe(input.title);
  expect(callsTo(ctx, "sendReply")).toHaveLength(0);
});

// --- Escape on a running turn

step("the turn is still running", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).isRunning).toBe(true);
  expect(callsTo(ctx, "interrupt")).toHaveLength(0);
});

step("the running turn is interrupted", async (ctx: World) => {
  await settle(ctx);
  expect(callsTo(ctx, "interrupt").map((call) => String(call.args[0]))).toEqual(["t1"]);
});

// --- Outside editor

step("the user's editor is set in VISUAL or EDITOR", (ctx: ComposerWorld) => {
  ctx.editorEnv!.VISUAL = "nvim";
});

step(
  "the user opens the draft in their editor and saves {string}",
  async (ctx: ComposerWorld, text: string) => {
    await saveInEditor(ctx, `${unescape(text)}\n\n\n`);
    expect(ctx.editorRuns![0]!.command.cmd).toBe("nvim");
  },
);

step("the draft reads the saved text without trailing blank lines", async (ctx: World) => {
  await expectPrompt(ctx, "start\nmore");
});

step(
  "the user saves a line naming {string} from their editor",
  async (ctx: ComposerWorld, path: string) => {
    ctx.editorEnv!.EDITOR = "vi";
    ctx.fake!.workspaceFiles.set(path, PNG);
    ctx.fake!.workspaceFiles.set(path.replace(/^\.\//, ""), PNG);
    await saveInEditor(ctx, `Why is this broken?\n${path}`);
  },
);

step("that line is not part of the prompt text", async (ctx: World) => {
  await expectPrompt(ctx, "Why is this broken?");
});

// --- Attachments

step("the draft carries {string}", async (ctx: ComposerWorld, name: string) => {
  if (ctx.stepType === "Outcome") {
    await settle(ctx);
    expect(attachmentNames(ctx)).toContain(name);
    return;
  }
  ctx.fake!.workspaceFiles.set(name, PNG);
  await typeIntoPrompt(ctx, (ctx.typedText = "What is wrong here?"));
  await attach(ctx, name);
  expect(attachmentNames(ctx)).toEqual([name]);
});

step("the user removes {string}", async (ctx: World, name: string) => {
  expect(attachmentNames(ctx).at(-1)).toBe(name);
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, "remove last attachment");
  await settle(ctx);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the draft carries no attachments", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).attachments).toHaveLength(0);
  await snapshot(ctx);
  expect(findObject(ctx, "composerAttachments").get("visible")).toBe(false);
});

step("the typed text is unchanged", async (ctx: ComposerWorld) => {
  await expectPrompt(ctx, ctx.typedText ?? "");
});

step(/^the user pastes (.+) into the prompt$/, async (ctx: ComposerWorld, raw: string) => {
  const pasted = raw.trim();
  const path = (pasted.match(/^'([^']+)'/)?.[1] ?? pasted.split(" ")[0])!;
  if (path.startsWith("/")) ctx.localImages!.set(path, PNG);
  else if (path.startsWith("~/")) ctx.localImages!.set(`${HOME}${path.slice(1)}`, PNG);
  else ctx.fake!.workspaceFiles.set(path, PNG);
  await pasteText(ctx, pasted);
});

step("the prompt text reads {string}", async (ctx: World, text: string) => {
  await expectPrompt(ctx, text);
});

step("the terminal can read images from the clipboard", (ctx: ComposerWorld) => {
  expect(ctx.kittyKeyboard).toBe(true);
  ctx.clipboard = { bytes: PNG, mimeType: "image/png" };
});

step("the user pastes an image", async (ctx: ComposerWorld) => {
  await pasteBytes(ctx, ctx.clipboard!.bytes, ctx.clipboard!.mimeType);
});

step("a clipboard image is attached to the draft", async (ctx: World) => {
  await settle(ctx);
  expect(attachmentNames(ctx)).toEqual(["clipboard-image-1.png"]);
});

step(/^the user tries to attach (.+)$/, async (ctx: ComposerWorld, image: string) => {
  const files = ctx.fake!.workspaceFiles;
  switch (image) {
    case "a 12 MB photo":
      files.set("photo.png", new Uint8Array(12 * 1024 * 1024));
      await attach(ctx, "photo.png");
      return;
    case "an empty image file":
      files.set("empty.png", new Uint8Array(0));
      await attach(ctx, "empty.png");
      return;
    case "a file that is not a supported image":
      files.set("notes.txt", new TextEncoder().encode("notes"));
      await attach(ctx, "notes.txt");
      return;
    case "an image that is already attached":
      files.set("bug.png", PNG);
      await attach(ctx, "bug.png");
      ctx.attachedBefore = 1;
      await attach(ctx, "bug.png");
      return;
    case "a 101st image":
      for (let index = 0; index < PROVIDER_SEND_TURN_MAX_ATTACHMENTS; index += 1) {
        files.set(`shot-${index}.png`, PNG);
        ctx.host!.dispatch("composer.attach", { path: `shot-${index}.png` });
      }
      await settle(ctx);
      ctx.attachedBefore = PROVIDER_SEND_TURN_MAX_ATTACHMENTS;
      files.set("one-more.png", PNG);
      await attach(ctx, "one-more.png");
      return;
    default:
      throw new Error(`unknown image "${image}"`);
  }
});
