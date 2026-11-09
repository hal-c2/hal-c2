import type { InteractionUpdate, SendOptions, StoredSdkCredentials } from "@cursor/sdk";
import { describe, expect, it } from "vite-plus/test";

import type { AgentOptions } from "@cursor/sdk";

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
function client(
  sdk: CursorSdk,
  mode: "full-access" | "text-generation-unsandboxed" = "full-access",
) {
  const out: Array<Record<string, unknown>> = [];
  const acp = makeCursorAcp({ sdk, mode, write: (m) => out.push(m as never) });
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

  // Review of #1284.
  it("keeps only a file's reference as a read's result, not its content", () => {
    const sent: Array<Record<string, unknown>> = [];
    const updates = makeUpdateTranslator((update) => sent.push(update as never));
    const toolCall = (result: unknown) => ({
      type: "read",
      args: { path: "/work/big.txt" },
      result,
    });
    updates({
      type: "tool-call-completed",
      callId: "r1",
      toolCall: toolCall({ status: "success", value: { content: "x".repeat(50_000) } }),
    } as unknown as InteractionUpdate);
    const done = sent.find((u) => u.sessionUpdate === "tool_call_update") as any;
    expect(done.rawOutput.results).toEqual([{ fileName: "/work/big.txt" }]);
  });

  it("still fails the turn on a transport error while /compact hides the reply", () => {
    const sent: Array<Record<string, unknown>> = [];
    const updates = makeUpdateTranslator(
      (update) => sent.push(update as never),
      () => {},
      { suppressText: true },
    );
    updates({
      type: "text-delta",
      text: "Something went wrong communicating with the server. Please try again.",
    } as unknown as InteractionUpdate);
    expect(updates.finish({ status: "finished" })).toMatchObject({
      message: "Provider turn failed.",
    });
    expect(sent).toEqual([]);
  });

  it("fails a /compact whose only reply is a transport error in the run's result", () => {
    const sent: Array<Record<string, unknown>> = [];
    const updates = makeUpdateTranslator(
      (update) => sent.push(update as never),
      () => {},
      { suppressText: true },
    );
    expect(
      updates.finish({
        status: "finished",
        result: "Something went wrong communicating with the server. Please try again.",
      }),
    ).toMatchObject({ message: "Provider turn failed." });
    expect(sent).toEqual([]);
  });

  it("shows nothing of a late-resumed /compact reply either", () => {
    const sent: Array<Record<string, unknown>> = [];
    const updates = makeUpdateTranslator(
      (update) => sent.push(update as never),
      () => {},
      { suppressText: true },
    );
    updates({ type: "turn-ended" } as unknown as InteractionUpdate);
    expect(
      updates.finish({
        status: "error",
        result: "Compacted.",
        error: { message: "repeated resume attempts made no progress" },
      }),
    ).toBeUndefined();
    expect(sent).toEqual([]);
  });

  const failure = "Something went wrong communicating with the server. Please try again.";
  const translator = () => {
    const sent: Array<Record<string, any>> = [];
    const updates = makeUpdateTranslator((update) => sent.push(update as never));
    const push = (update: object) => updates(update as unknown as InteractionUpdate);
    return { sent, updates, push };
  };

  it("keeps an earlier transport failure through a whitespace-only segment", () => {
    const { updates, push } = translator();
    push({ type: "text-delta", text: "Commentary" });
    push({ type: "thinking-delta", text: "hm" });
    push({ type: "text-delta", text: failure });
    push({ type: "thinking-delta", text: "hm" });
    push({ type: "text-delta", text: "  \n" });
    push({ type: "turn-ended" });
    expect(updates.finish({ status: "finished" })).toMatchObject({
      message: "Provider turn failed.",
    });
  });

  it("does not turn a transport failure into a late-resumed success", () => {
    const { updates, push } = translator();
    push({ type: "text-delta", text: failure });
    push({ type: "turn-ended" });
    expect(
      updates.finish({
        status: "error",
        error: { message: "repeated resume attempts made no progress" },
      }),
    ).toMatchObject({ message: "repeated resume attempts made no progress" });
  });

  it("does not close an unfinished plan or todo list as an interrupted tool", () => {
    const { sent, updates, push } = translator();
    push({
      type: "tool-call-started",
      callId: "p1",
      toolCall: { type: "createPlan", args: { plan: "Do it" } },
    });
    push({
      type: "tool-call-started",
      callId: "t1",
      toolCall: { type: "updateTodos", args: { todos: [] } },
    });
    updates.finish({ status: "cancelled" });
    expect(sent.map((update) => update.sessionUpdate)).toEqual(["proposed_plan", "plan"]);
  });

  it("times out the post-login catalog request instead of hanging the sign-in", async () => {
    const { sdk, finishLogin } = fakeSdk([]);
    const hanging: CursorSdk = { ...sdk, listModels: () => new Promise(() => {}) };
    const out: Array<Record<string, unknown>> = [];
    const acp = makeCursorAcp({
      sdk: hanging,
      mode: "full-access",
      catalogTimeoutMs: 20,
      write: (m) => out.push(m as never),
    });
    const signingIn = acp.receive({ id: 100, method: "authenticate", params: {} });
    await settle();
    finishLogin();
    await signingIn;
    expect(out.find((m) => m.id === 100)).toMatchObject({ result: {} });
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

  it("names every setting source and passes HAL-C2's MCP servers at creation", async () => {
    const { sdk, sent } = fakeSdk([]);
    await sdk.store.save(credentials);
    const created: Array<AgentOptions> = [];
    const counting: CursorSdk = {
      ...sdk,
      createAgent: async (options) => {
        created.push(options);
        return sdk.createAgent(options);
      },
    };
    const { call } = client(counting);
    await call("session/new", {
      cwd: "/work",
      mcpServers: [{ type: "http", name: "hal-c2", url: "http://127.0.0.1:3780/mcp", headers: [] }],
    });

    expect(created).toHaveLength(1);
    // Without sources the SDK loads no CLI settings at all — the user's own
    // MCP servers, rules and skills with them.
    expect(created[0]?.local?.settingSources).toEqual([
      "project",
      "user",
      "team",
      "mdm",
      "plugins",
    ]);
    expect(Object.keys(created[0]?.mcpServers ?? {})).toEqual(["hal-c2"]);

    // A send names no servers: the SDK would turn them into an override
    // replacing the settings' own instead of joining them.
    await call("session/prompt", {
      sessionId: "agent-1",
      prompt: [{ type: "text", text: "hello" }],
    });
    expect(sent).toHaveLength(1);
    expect(sent[0]?.options.mcpServers).toBeUndefined();
  });

  it("reads the account only for a probe, and refuses it before any agent exists", async () => {
    const { sdk } = fakeSdk([]);
    await sdk.store.save(credentials);
    let meCalls = 0;
    let agentsCreated = 0;
    const counting: CursorSdk = {
      ...sdk,
      me: async () => {
        meCalls++;
        throw new Error("network unreachable");
      },
      createAgent: async (options) => {
        agentsCreated++;
        return sdk.createAgent(options);
      },
    };
    const { call } = client(counting);

    // A real thread's session never asks the account endpoint.
    const session = await call("session/new", { cwd: "/work" });
    expect(session.result.sessionId).toBe("agent-1");
    expect(meCalls).toBe(0);
    expect(agentsCreated).toBe(1);

    // The probe does, and a sign-in it cannot confirm fails the probe —
    // before a second agent is created and orphaned.
    const probe = await call("session/new", { cwd: "/work", _meta: { probe: true } });
    expect(probe.error.message).toBe("Could not verify the Cursor sign-in. Try again.");
    expect(meCalls).toBe(1);
    expect(agentsCreated).toBe(1);
  });

  it("explains a usage limit on the unsandboxed text-generation retry too", async () => {
    const { sdk } = fakeSdk([]);
    await sdk.store.save(credentials);
    const limited: CursorSdk = {
      ...sdk,
      createAgent: async () => ({
        agentId: "agent-1",
        close: () => {},
        send: async () => ({
          wait: async () => ({
            status: "error",
            error: { message: "You have reached your usage limit" },
          }),
          cancel: async () => {},
        }),
      }),
    };
    const { call } = client(limited, "text-generation-unsandboxed");
    await call("session/new", { cwd: "/work" });
    const reply = await call("session/prompt", {
      sessionId: "agent-1",
      prompt: [{ type: "text", text: "title please" }],
    });
    expect(reply.error.message).toBe(
      "Cursor usage limit reached. Try again later or choose another text-generation provider.",
    );
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
