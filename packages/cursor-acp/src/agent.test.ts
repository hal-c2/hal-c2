import type { InteractionUpdate, SendOptions, StoredSdkCredentials } from "@cursor/sdk";
import { describe, expect, it } from "vite-plus/test";

import { makeCursorAcp, makeUpdateTranslator, type CursorSdk } from "./agent.ts";

const credentials: StoredSdkCredentials = {
  version: 1,
  backendUrl: "https://api.cursor.test",
  apiKey: "key-1",
  createdAtMs: 0,
};

/** A Cursor SDK whose runs replay `updates` and finish (or wait for cancel). */
function fakeSdk(updates: ReadonlyArray<InteractionUpdate>) {
  let stored: StoredSdkCredentials | undefined;
  const sent: Array<{ message: string; options: SendOptions }> = [];
  let finishLogin = () => {};
  const sdk: CursorSdk = {
    version: "test",
    envApiKey: undefined,
    store: {
      load: async () => stored,
      save: async (next) => {
        stored = next;
      },
      clear: async () => {
        stored = undefined;
      },
    },
    listModels: async () => [{ id: "gpt-9", displayName: "GPT 9" }],
    login: ({ store, signal, onLoginUrl }) =>
      new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(new Error("login declined")));
        onLoginUrl("https://cursor.test/login");
        finishLogin = () => void store.save(credentials).then(resolve);
      }),
    createAgent: async () => agent,
    resumeAgent: async () => agent,
    isAuthError: () => false,
  };
  let cancelled: (() => void) | undefined;
  const agent = {
    agentId: "agent-1",
    close: () => {},
    send: async (given: string | { text: string }, options: SendOptions) => {
      const message = typeof given === "string" ? given : given.text;
      sent.push({ message, options });
      for (const update of updates) await options.onDelta?.({ update });
      return {
        wait: () =>
          message.includes("wait")
            ? new Promise<{ status: string }>((resolve) => {
                cancelled = () => resolve({ status: "cancelled" });
              })
            : Promise.resolve({ status: "finished" }),
        cancel: async () => cancelled?.(),
      };
    },
  };
  // The user finishing the sign-in page.
  return { sdk, sent, finishLogin: () => finishLogin() };
}

/** Lets pending promise callbacks run. */
const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

/** Drives the sidecar like a client: requests get ids, replies are collected. */
function client(sdk: CursorSdk) {
  const out: Array<Record<string, unknown>> = [];
  const acp = makeCursorAcp({ sdk, mode: "full-access", write: (m) => out.push(m as never) });
  let id = 0;
  const call = async (method: string, params: object = {}) => {
    const mine = ++id;
    await acp.receive({ id: mine, method, params: params as Record<string, unknown> });
    return out.find((m) => m.id === mine) as { result?: any; error?: any };
  };
  return { acp, out, call };
}

describe("Cursor over ACP", () => {
  it("asks for a sign-in, signs in through a URL the client opens, then opens sessions", async () => {
    const { sdk, finishLogin } = fakeSdk([]);
    const { acp, out, call } = client(sdk);

    const init = await call("initialize");
    expect(init.result.authMethods).toEqual([expect.objectContaining({ id: "cursor-login" })]);
    expect((await call("session/new", { cwd: "/work" })).error.code).toBe(-32000);

    const signingIn = acp.receive({ id: 100, method: "authenticate", params: {} });
    await settle();
    const elicitation = out.find((m) => m.method === "elicitation/create") as any;
    expect(elicitation.params).toMatchObject({ mode: "url", url: "https://cursor.test/login" });
    await acp.receive({ id: elicitation.id, result: { action: "accept" } });
    finishLogin();
    await signingIn;
    expect(out.find((m) => m.id === 100)).toMatchObject({ result: {} });

    const session = await call("session/new", { cwd: "/work" });
    expect(session.result.sessionId).toBe("agent-1");
    expect(session.result.configOptions[0].options).toEqual([
      { value: "default", name: "Auto" },
      { value: "gpt-9", name: "GPT 9" },
    ]);
  });

  it("streams a run as messages and tool calls, split around each tool", async () => {
    const shell = { type: "shell", args: { command: "ls" } };
    const { sdk, sent } = fakeSdk([
      { type: "text-delta", text: "Let me look." },
      { type: "tool-call-started", callId: "c1", toolCall: shell },
      {
        type: "tool-call-completed",
        callId: "c1",
        toolCall: {
          ...shell,
          result: { status: "success", value: { stdout: "a.txt", stderr: "" } },
        },
      },
      { type: "text-delta", text: "Found a.txt." },
    ] as unknown as ReadonlyArray<InteractionUpdate>);
    await sdk.store.save(credentials);
    const { out, call } = client(sdk);
    await call("session/new", { cwd: "/work" });
    await call("session/set_config_option", {
      sessionId: "agent-1",
      configId: "model",
      value: "gpt-9",
    });

    const reply = await call("session/prompt", {
      sessionId: "agent-1",
      prompt: [{ type: "text", text: "list files" }],
    });

    expect(reply.result).toEqual({ stopReason: "end_turn" });
    expect(sent[0]).toMatchObject({ message: "list files", options: { model: { id: "gpt-9" } } });
    const updates = out
      .filter((m) => m.method === "session/update")
      .map((m: any) => m.params.update);
    expect(updates.map((u) => [u.sessionUpdate, u.messageId ?? u.toolCallId])).toEqual([
      ["agent_message_chunk", "segment-1"],
      ["tool_call", "c1"],
      ["tool_call_update", "c1"],
      ["agent_message_chunk", "segment-3"],
    ]);
    expect(updates[2]).toMatchObject({
      status: "completed",
      kind: "execute",
      rawInput: { command: "ls" },
      content: [{ type: "content", content: { type: "text", text: "a.txt" } }],
    });
  });

  it("reports a subagent's result as what the subagent said", async () => {
    const task = { type: "task", args: { description: "Survey", prompt: "List the modules" } };
    const { sdk } = fakeSdk([
      { type: "tool-call-started", callId: "t1", toolCall: task },
      {
        type: "tool-call-completed",
        callId: "t1",
        toolCall: {
          ...task,
          result: {
            status: "success",
            value: {
              conversationSteps: [
                { type: "assistantMessage", message: { text: "lib has three modules" } },
                { type: "toolCall" },
              ],
              resultSuffix: "Agent finished.",
            },
          },
        },
      },
    ] as unknown as ReadonlyArray<InteractionUpdate>);
    await sdk.store.save(credentials);
    const { out, call } = client(sdk);
    await call("session/new", { cwd: "/work" });
    await call("session/prompt", {
      sessionId: "agent-1",
      prompt: [{ type: "text", text: "survey the code" }],
    });

    const updates = out
      .filter((m) => m.method === "session/update")
      .map((m: any) => m.params.update);
    expect(updates[0]).toMatchObject({ sessionUpdate: "tool_call", title: "task" });
    expect(updates[1]).toMatchObject({
      status: "completed",
      rawInput: { prompt: "List the modules" },
      content: [
        {
          type: "content",
          content: { type: "text", text: "lib has three modules\nAgent finished." },
        },
      ],
    });
  });

  it("streams ordinary text before its first newline, and still hides a pure transport error", () => {
    const shown: Array<string> = [];
    const updates = makeUpdateTranslator((update) => {
      const text = (update as { content?: { text?: string } }).content?.text;
      if (text !== undefined) shown.push(text);
    });
    const delta = (text: string) =>
      updates({ type: "text-delta", text } as unknown as InteractionUpdate);

    // No newline yet, and already not a transport error: it streams at once.
    delta("Hello there");
    expect(shown).toEqual(["Hello there"]);

    // Still a possible transport error prefix: held, until it proves ordinary.
    shown.length = 0;
    const held = makeUpdateTranslator((update) => {
      const text = (update as { content?: { text?: string } }).content?.text;
      if (text !== undefined) shown.push(text);
    });
    const heldDelta = (text: string) =>
      held({ type: "text-delta", text } as unknown as InteractionUpdate);
    heldDelta("Error: Retr");
    expect(shown).toEqual([]);
    heldDelta("iableError: [internal] a note about errors");
    expect(shown).toEqual(["Error: RetriableError: [internal] a note about errors"]);

    // The server error itself, in pieces, is never shown as a reply.
    shown.length = 0;
    const failed = makeUpdateTranslator((update) => {
      const text = (update as { content?: { text?: string } }).content?.text;
      if (text !== undefined) shown.push(text);
    });
    failed({
      type: "text-delta",
      text: "Something went wrong communicating with the server. Please try again.",
    } as unknown as InteractionUpdate);
    expect(shown).toEqual([]);
    expect(failed.finish({ status: "finished" })).toMatchObject({
      message: "Provider turn failed.",
    });
  });

  it("sends only a bounded tail of a running shell's output per delta", () => {
    const texts: Array<string> = [];
    const updates = makeUpdateTranslator((update) => {
      const content = (update as { content?: Array<{ content?: { text?: string } }> }).content;
      const text = content?.[0]?.content?.text;
      if (text !== undefined) texts.push(text);
    });
    const push = (update: unknown) => updates(update as InteractionUpdate);
    push({
      type: "tool-call-started",
      callId: "s1",
      toolCall: { type: "shell", args: { command: "yes" } },
    });
    const big = "x".repeat(300 * 1024);
    push({ type: "shell-output-delta", event: { text: big } });
    push({ type: "shell-output-delta", event: { text: "tail-end" } });

    expect(texts[0]?.length).toBe(256 * 1024);
    // The second delta carries the bounded tail, not everything again.
    expect(texts[1]?.length).toBe(256 * 1024);
    expect(texts[1]?.endsWith("tail-end")).toBe(true);
  });

  it("forwards Cursor's error code, and only rewrites a model the account does not offer", async () => {
    const { sdk } = fakeSdk([]);
    await sdk.store.save(credentials);
    let failure: { message: string; code?: string } = { message: "boom" };
    const failing: CursorSdk = {
      ...sdk,
      createAgent: async () => ({
        agentId: "agent-1",
        close: () => {},
        send: async () => ({
          wait: async () => ({ status: "error", error: failure }),
          cancel: async () => {},
        }),
      }),
    };
    const { call } = client(failing);
    await call("session/new", { cwd: "/work" });
    const prompt = () =>
      call("session/prompt", {
        sessionId: "agent-1",
        prompt: [{ type: "text", text: "go" }],
      });

    failure = { message: "Model Blocked by your admin", code: "model_blocked" };
    const blocked = await prompt();
    expect(blocked.error.data).toEqual({ code: "model_blocked" });
    expect(blocked.error.message).toBe("Model Blocked by your admin");

    // A transient failure is not rewritten as "choose another model".
    failure = { message: "The model is temporarily unavailable" };
    expect((await prompt()).error.message).toBe("The model is temporarily unavailable");
    failure = { message: "model produced invalid tool call" };
    expect((await prompt()).error.message).toBe("model produced invalid tool call");

    failure = { message: "Invalid parameters for registry model: model not found" };
    expect((await prompt()).error.message).toContain("is not one this Cursor account offers");
  });

  it("cancels a running prompt", async () => {
    const { sdk } = fakeSdk([]);
    await sdk.store.save(credentials);
    const { acp, out, call } = client(sdk);
    await call("session/new", { cwd: "/work" });

    const running = acp.receive({
      id: 50,
      method: "session/prompt",
      params: { sessionId: "agent-1", prompt: [{ type: "text", text: "wait here" }] },
    });
    await settle();
    await acp.receive({ method: "session/cancel", params: { sessionId: "agent-1" } });
    await running;
    expect(out.find((m) => m.id === 50)).toMatchObject({ result: { stopReason: "cancelled" } });
  });
});
