import type {
  AgentOptions,
  InteractionUpdate,
  McpServerConfig,
  ModelParameterDefinition,
  ModelSelection,
  ModelVariant,
  SdkCredentialStore,
  SDKUserMessage,
  SendOptions,
  ToolCall,
} from "@cursor/sdk";

/**
 * Cursor as an Agent Client Protocol agent, so a HAL-C2 MC runs it like any other ACP
 * agent. Each ACP session is a local Cursor agent; a prompt is one Cursor run whose
 * deltas become `session/update` notifications. Signing in is Cursor's browser
 * login, whose URL goes to the client as a URL elicitation.
 *
 * The SDK is injected (`CursorSdk`) so the protocol can be tested without Cursor.
 */

export interface CursorSdk {
  readonly version: string;
  readonly store: SdkCredentialStore;
  /** `CURSOR_API_KEY`, which replaces the stored sign-in. */
  readonly envApiKey: string | undefined;
  readonly createAgent: (options: AgentOptions) => Promise<CursorAgent>;
  readonly resumeAgent: (agentId: string, options: AgentOptions) => Promise<CursorAgent>;
  readonly listModels: (apiKey: string) => Promise<
    ReadonlyArray<{
      readonly id: string;
      readonly displayName: string;
      /** The model's own options (reasoning, context size, ...) and its default variant. */
      readonly parameters?: ReadonlyArray<ModelParameterDefinition>;
      readonly variants?: ReadonlyArray<ModelVariant>;
    }>
  >;
  /** The account behind a key, when the SDK can say (its email may be absent). */
  readonly me?: (apiKey: string) => Promise<{
    readonly userEmail?: string;
    readonly apiKeyName: string;
  }>;
  readonly login: (options: {
    readonly store: SdkCredentialStore;
    readonly signal: AbortSignal;
    readonly onLoginUrl: (url: string) => void;
  }) => Promise<unknown>;
  /** Whether an SDK failure means the credentials were refused. */
  readonly isAuthError: (cause: unknown) => boolean;
}

export interface CursorAgent {
  readonly agentId: string;
  readonly send: (message: string | SDKUserMessage, options: SendOptions) => Promise<CursorRun>;
  readonly close: () => void;
}

export interface CursorRun {
  readonly wait: () => Promise<{
    readonly status: string;
    readonly result?: string;
    readonly error?: { readonly message: string; readonly code?: string };
  }>;
  readonly cancel: () => Promise<void>;
}

/**
 * The runtime mode the node started this process for (`--mode`). "text-generation"
 * writes titles and commit messages: read-only planning, without the user's Cursor
 * settings, rules or tools.
 */
export type RuntimeMode =
  | "full-access"
  | "approval-required"
  | "auto-accept-edits"
  | "auto"
  | "text-generation"
  /** Text generation retried once, after its sandbox stopped the first run. */
  | "text-generation-unsandboxed";

type JsonRpcId = string | number;
type Message = {
  readonly id?: JsonRpcId;
  readonly method?: string;
  readonly params?: Record<string, unknown>;
  readonly result?: unknown;
  readonly error?: unknown;
};

class RpcError extends Error {
  readonly code: number;
  /** Cursor's own error code for a failed run, when the SDK gave one. */
  readonly data: { readonly code: string } | undefined;
  constructor(code: number, message: string, data?: { readonly code: string }) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

// ACP's "authentication required".
const authRequired = () => new RpcError(-32000, "Sign in to Cursor to use this agent.");

interface Session {
  readonly agent: CursorAgent;
  model: ModelSelection;
  /** Cursor's conversation mode for the next run: the client's plan toggle sets it. */
  mode: "agent" | "plan";
  run: CursorRun | undefined;
  /** Whether the no-sandbox-on-Windows warning was already shown in this session. */
  warnedNoSandbox: boolean;
}

export function makeCursorAcp(input: {
  readonly sdk: CursorSdk;
  readonly mode: RuntimeMode;
  readonly write: (message: object) => void;
  /** The platform the MC runs on (`process.platform`); Cursor's sandbox is not on Windows. */
  readonly platform?: string;
  /** How long a model catalog request may take before Cursor reads as unavailable. */
  readonly catalogTimeoutMs?: number;
}) {
  const { sdk, write } = input;
  const sessions = new Map<string, Session>();
  const pending = new Map<JsonRpcId, (result: unknown) => void>();
  let nextRequest = 0;

  const request = (method: string, params: object) =>
    new Promise<unknown>((resolve) => {
      const id = `cursor-${++nextRequest}`;
      pending.set(id, resolve);
      write({ jsonrpc: "2.0", id, method, params });
    });

  const loadStore = async () => {
    try {
      return await sdk.store.load();
    } catch {
      throw new RpcError(-32603, "Could not open the Cursor credential store.");
    }
  };

  /** The run's key, and whether it is the stored sign-in rather than `CURSOR_API_KEY`. */
  const requireKey = async (): Promise<{ key: string; stored: boolean }> => {
    if (sdk.envApiKey !== undefined) return { key: sdk.envApiKey, stored: false };
    const stored = (await loadStore())?.apiKey;
    if (stored === undefined) throw authRequired();
    return { key: stored, stored: true };
  };

  const paidPlan = () =>
    new RpcError(
      -32603,
      "A paid Cursor plan is needed to use Cursor with HAL-C2. Free Cursor accounts cannot use the Cursor SDK.",
    );
  const freePlanError = (cause: unknown) =>
    /free (?:plan|tier|account)|paid plan|upgrade (?:to|your)/i.test(
      cause instanceof Error ? cause.message : String(cause),
    );
  const blockedAccountError = (cause: unknown) =>
    /permission|forbidden|\b403\b|blocked by|not authorized/i.test(
      cause instanceof Error ? cause.message : String(cause),
    );

  /**
   * The model catalog, time-boxed: a refused key and a free-plan account are
   * answers about the sign-in, a hang or a network failure is the catalog's.
   */
  const catalog = async (key: string, stored: boolean, clearOnFree = true) => {
    const timeoutMs = input.catalogTimeoutMs ?? 10_000;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const models = await Promise.race([
        sdk.listModels(key),
        new Promise<never>((_resolve, reject) => {
          // @effect-diagnostics-next-line globalTimers:off - a plain timer races the SDK call.
          timer = setTimeout(() => reject(new Error("cursor catalog timeout")), timeoutMs);
        }),
      ]);
      return { models, catalogError: undefined as "failed" | "timeout" | undefined };
    } catch (cause) {
      if (cause instanceof Error && cause.message === "cursor catalog timeout") {
        return { models: [], catalogError: "timeout" as const };
      }
      if (sdk.isAuthError(cause)) throw authRequired();
      if (freePlanError(cause)) {
        if (stored && clearOnFree) await sdk.store.clear().catch(() => {});
        throw paidPlan();
      }
      return { models: [], catalogError: "failed" as const };
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  };

  /**
   * Who the key belongs to, for the provider list — read only for the MC's
   * probe session (`_meta.probe`), never for a real thread's session, whose
   * turns must not wait on or fail with Cursor's account endpoint. A team
   * that blocks the account endpoint still lets Cursor run: the account
   * then reads as a Cursor account (or API key) without an email, and only
   * a saved sign-in Cursor cannot confirm at all is an error.
   */
  const account = async (key: string, stored: boolean) => {
    const fallback = { label: stored ? "Cursor account" : "Cursor API key" };
    if (sdk.me === undefined) return fallback;
    try {
      const me = await sdk.me(key);
      return me.userEmail ? { email: me.userEmail } : fallback;
    } catch (cause) {
      if (sdk.isAuthError(cause)) throw authRequired();
      if (freePlanError(cause)) {
        if (stored) await sdk.store.clear().catch(() => {});
        throw paidPlan();
      }
      if (blockedAccountError(cause)) return fallback;
      if (stored) {
        throw new RpcError(-32603, "Could not verify the Cursor sign-in. Try again.");
      }
      return fallback;
    }
  };

  const text = input.mode === "text-generation" || input.mode === "text-generation-unsandboxed";
  const windows = (input.platform ?? "linux") === "win32";
  // Cursor's SDK has no sandbox on Windows, so a mode whose safety is the sandbox
  // alone (auto-accept edits: no review either) cannot run there at all.
  const sandboxRefused =
    windows && input.mode === "auto-accept-edits"
      ? "Cursor cannot sandbox on Windows, so auto-accept edits cannot run on a Windows MC."
      : undefined;
  const agentOptions = (
    cwd: string,
    key: string,
    model: ModelSelection,
    servers: Record<string, McpServerConfig>,
  ): AgentOptions => ({
    model,
    name: "HAL-C2",
    mode: text ? "plan" : "agent",
    apiKey: key,
    // HAL-C2's servers ride at creation too: the SDK merges them with the
    // MCP servers the setting sources load, where a send that named servers
    // replaced the user's own (upstream #15875).
    ...(Object.keys(servers).length === 0 ? {} : { mcpServers: servers }),
    local: {
      cwd,
      // Auto reviews escalations instead of denying them (upstream #19712).
      autoReview: input.mode === "approval-required" || input.mode === "auto",
      sandboxOptions: {
        enabled:
          input.mode !== "full-access" && input.mode !== "text-generation-unsandboxed" && !windows,
      },
      enableAgentRetries: true,
      // The SDK loads no CLI settings — rules, skills, the user's own MCP
      // servers — unless its setting sources are named.
      settingSources: text ? [] : ["project", "user", "team", "mdm", "plugins"],
    },
  });

  // Each model's catalog variants, for Max Mode when a model is picked.
  const variantsByModel = new Map<string, ReadonlyArray<ModelVariant>>();

  const modelOption = async (key: string, current: string, stored = false) => {
    const { models, catalogError } = await catalog(key, stored);
    for (const model of models) {
      if (model.variants !== undefined) variantsByModel.set(model.id, model.variants);
    }
    return {
      catalogError,
      options: [
        {
          id: "model",
          name: "Model",
          type: "select",
          currentValue: current,
          options: [
            { value: "default", name: "Auto" },
            // Each model's parameters ride along, for the client's model options.
            ...models.map((model) => ({
              value: model.id,
              name: model.displayName,
              ...(model.parameters === undefined || model.parameters.length === 0
                ? {}
                : { _meta: { parameters: model.parameters, variants: model.variants ?? [] } }),
            })),
          ],
        },
        // Cursor's own plan mode, which the client's plan toggle chooses.
        ...(text
          ? []
          : [
              {
                id: "mode",
                name: "Mode",
                category: "mode",
                type: "select",
                currentValue: "agent",
                options: [
                  { value: "agent", name: "Agent" },
                  { value: "plan", name: "Plan" },
                ],
              },
            ]),
      ],
    };
  };

  const open = async (params: Record<string, unknown>, agentId?: string) => {
    if (sandboxRefused !== undefined) throw new RpcError(-32603, sandboxRefused);
    const { key, stored } = await requireKey();
    const cwd = String(params.cwd ?? process.cwd());
    const model: ModelSelection = { id: "default" };
    // Everything that can refuse the session runs before an agent exists, so
    // a refused open never orphans one. The account read is the probe's alone.
    const { options, catalogError } = await modelOption(key, model.id, stored);
    const probe = (params._meta as { readonly probe?: unknown } | undefined)?.probe === true;
    const who = probe ? await account(key, stored) : undefined;
    const servers = mcpServers(params.mcpServers);
    const agent = await guard(
      agentId === undefined
        ? sdk.createAgent(agentOptions(cwd, key, model, servers))
        : sdk.resumeAgent(agentId, agentOptions(cwd, key, model, servers)),
    );
    sessions.get(agent.agentId)?.agent.close();
    sessions.set(agent.agentId, {
      agent,
      model,
      mode: "agent",
      run: undefined,
      warnedNoSandbox: false,
    });
    return {
      ...(agentId === undefined ? { sessionId: agent.agentId } : {}),
      configOptions: options,
      _meta: {
        ...(who === undefined ? {} : { account: who }),
        ...(catalogError === undefined ? {} : { catalogError }),
      },
    };
  };

  // SDK failures from refused credentials become ACP's sign-in error.
  const guard = async <A>(promise: Promise<A>): Promise<A> => {
    try {
      return await promise;
    } catch (cause) {
      if (sdk.isAuthError(cause)) throw authRequired();
      throw cause;
    }
  };

  const session = (params: Record<string, unknown>) => {
    const found = sessions.get(String(params.sessionId));
    if (found === undefined)
      throw new RpcError(-32602, `Unknown session ${String(params.sessionId)}`);
    return found;
  };

  const prompt = async (params: Record<string, unknown>) => {
    const current = session(params);
    const sessionId = String(params.sessionId);
    const blocks = Array.isArray(params.prompt) ? params.prompt : [];
    const texts: string[] = [];
    const images: Array<{ data: string; mimeType: string }> = [];
    for (const block of blocks) {
      if (typeof block !== "object" || block === null) continue;
      const record = block as Record<string, unknown>;
      if (record.type === "image" && typeof record.data === "string") {
        images.push({
          data: record.data,
          mimeType: typeof record.mimeType === "string" ? record.mimeType : "image/png",
        });
      } else if (typeof record.text === "string") {
        texts.push(record.text);
      }
    }
    const asked = texts.join("\n\n");
    // HAL-C2's `/compact` is Cursor's own `/compress`, whole and unadorned; its
    // summary is the new context, not a reply in the chat.
    const compacting = asked.trim() === "/compact" && images.length === 0;
    const message: string | SDKUserMessage = compacting
      ? "/compress"
      : images.length === 0
        ? asked
        : { text: asked, images };
    const notify = (target: string, update: object) =>
      write({
        jsonrpc: "2.0",
        method: "session/update",
        params: { sessionId: target, update },
      });
    if (windows && input.mode !== "full-access" && !current.warnedNoSandbox) {
      current.warnedNoSandbox = true;
      notify(sessionId, {
        sessionUpdate: "notice",
        message: "Cursor has no sandbox on Windows, so this thread runs without one.",
      });
    }
    const updates = makeUpdateTranslator(
      (update) => notify(sessionId, update),
      (childSession, update) => notify(childSession, update),
      { suppressText: compacting },
    );
    const run = await guard(
      current.agent.send(message, {
        model: current.model,
        mode: current.mode,
        // No servers on a send: the SDK turns a send's into an override that
        // replaces the user's own. HAL-C2's ride at creation and resume
        // instead, where they merge with the settings' servers.
        onDelta: ({ update }) => updates(update),
      }),
    );
    current.run = run;
    try {
      const result = await run.wait();
      const failure = updates.finish(result);
      if (result.status === "cancelled") return { stopReason: "cancelled" };
      if (failure !== undefined)
        throw new RpcError(
          -32603,
          explainFailure(failure.message, current.model.id, input.mode),
          failure.code ? { code: failure.code } : undefined,
        );
      return { stopReason: "end_turn" };
    } finally {
      current.run = undefined;
    }
  };

  const handlers: Record<string, (params: Record<string, unknown>) => Promise<unknown>> = {
    initialize: async () => ({
      protocolVersion: 1,
      agentInfo: { name: "cursor", version: sdk.version },
      agentCapabilities: {
        loadSession: false,
        promptCapabilities: { image: true },
        sessionCapabilities: { resume: {} },
        auth: { logout: {} },
      },
      authMethods:
        sdk.envApiKey === undefined
          ? [
              {
                id: "cursor-login",
                name: "Log in with Cursor",
                description: "Sign in on cursor.com in your browser.",
              },
            ]
          : [],
    }),
    authenticate: async () => {
      const aborted = new AbortController();
      await sdk.login({
        store: sdk.store,
        signal: aborted.signal,
        onLoginUrl: (url) => {
          void request("elicitation/create", {
            mode: "url",
            url,
            elicitationId: "cursor-login",
            message: "Sign in to Cursor",
          }).then((answer) => {
            const action = (answer as { readonly action?: unknown } | undefined)?.action;
            if (action !== "accept") aborted.abort();
          });
        },
      });
      // A free-plan sign-in is no sign-in for the SDK: say so now, rather
      // than keeping credentials every later run refuses. The next status
      // check is what discards them (see `catalog`), so it can say why too.
      const key = (await loadStore())?.apiKey;
      if (key !== undefined) {
        await sdk.listModels(key).catch((cause: unknown) => {
          if (freePlanError(cause)) throw paidPlan();
          return [];
        });
      }
      return {};
    },
    logout: async () => {
      await sdk.store.clear();
      return {};
    },
    "session/new": (params) => open(params),
    "session/resume": (params) => open(params, String(params.sessionId)),
    "session/set_config_option": async (params) => {
      const current = session(params);
      if (params.configId === "model" && typeof params.value === "string") {
        // The options picked for the model come with it (`_meta.params`).
        const meta = params._meta as { readonly params?: unknown } | undefined;
        const picked = Array.isArray(meta?.params)
          ? meta.params.flatMap((entry) =>
              typeof entry === "object" &&
              entry !== null &&
              typeof entry.id === "string" &&
              typeof entry.value === "string"
                ? [{ id: entry.id, value: entry.value }]
                : [],
            )
          : [];
        // A variant that only runs in Max Mode must ask for it, or Cursor
        // refuses the run's parameters (upstream #21074): when every catalog
        // variant consistent with the picked parameters is a Max Mode one,
        // the run is a Max Mode run.
        const variants = variantsByModel.get(params.value) ?? [];
        const consistent = variants.filter((variant) =>
          picked.every((pick) =>
            variant.params.some((entry) => entry.id === pick.id && entry.value === pick.value),
          ),
        );
        const maxMode =
          consistent.length > 0 && consistent.every((variant) => variant.isMaxMode === true);
        current.model = {
          id: params.value,
          ...(picked.length === 0 ? {} : { params: picked }),
          ...(maxMode ? { maxMode: true } : {}),
        };
      }
      if (params.configId === "mode") {
        current.mode = params.value === "plan" ? "plan" : "agent";
      }
      return { configOptions: [] };
    },
    "session/prompt": prompt,
  };

  /** Handles one message from the client. */
  const receive = async (message: Message) => {
    if (message.method === undefined) {
      if (message.id !== undefined) pending.get(message.id)?.(message.result);
      if (message.id !== undefined) pending.delete(message.id);
      return;
    }
    if (message.method === "session/cancel") {
      await sessions.get(String(message.params?.sessionId))?.run?.cancel();
      return;
    }
    if (message.id === undefined) return;
    const handler = handlers[message.method];
    try {
      if (handler === undefined) throw new RpcError(-32601, message.method);
      const result = await handler(message.params ?? {});
      write({ jsonrpc: "2.0", id: message.id, result });
    } catch (cause) {
      const code = cause instanceof RpcError ? cause.code : -32603;
      const text = cause instanceof Error ? cause.message : String(cause);
      const data = cause instanceof RpcError ? cause.data : undefined;
      write({
        jsonrpc: "2.0",
        id: message.id,
        error: { code, message: text, ...(data === undefined ? {} : { data }) },
      });
    }
  };

  return { receive };
}

/**
 * Turns one run's Cursor deltas into ACP updates. Text and thinking between tool
 * calls become separate messages, so each keeps its place in the transcript.
 */
export function makeUpdateTranslator(
  emit: (update: object) => void,
  emitChild: (sessionId: string, update: object) => void = () => {},
  options: { readonly suppressText?: boolean } = {},
) {
  let segment = 0;
  let last: "text" | "thinking" | "tool" | undefined;
  const nextSegment = (kind: "text" | "thinking" | "tool") => {
    if (last !== kind) segment++;
    last = kind;
    return `segment-${segment}`;
  };

  // A reply that is only a connection error is Cursor's transport failing, not
  // its answer (upstream's CursorTransportFailure). Text is held back until the
  // segment proves ordinary, so a pure error segment is never shown as a reply.
  let pending = "";
  let pendingId: string | undefined;
  let tracker = new TransportFailure();
  let streamedText = false;
  let tailFailure = false;
  let turnEnded = false;
  let afterTurnEnded = false;
  const openTools = new Map<string, ToolCall>();
  const childTranslators = new Map<string, ReturnType<typeof makeUpdateTranslator>>();
  const shellOutput = new Map<string, string>();

  const flushPending = () => {
    if (pending !== "" && pendingId !== undefined) {
      emit({
        sessionUpdate: "agent_message_chunk",
        messageId: pendingId,
        content: { type: "text", text: pending },
      });
      if (pending.trim() !== "") streamedText = true;
    }
    pending = "";
  };

  // Ends the text segment being built: a segment that is only a transport
  // error is dropped and remembered, an ordinary one is shown whole.
  const endTextSegment = () => {
    if (pendingId === undefined) return;
    if (tracker.failure !== undefined) {
      pending = "";
      tailFailure = true;
    } else {
      flushPending();
      if (streamedText) tailFailure = false;
    }
    pendingId = undefined;
    tracker = new TransportFailure();
  };

  const emitText = (text: string) => {
    emit({
      sessionUpdate: "agent_message_chunk",
      messageId: nextSegment("text"),
      content: { type: "text", text },
    });
    if (text.trim() !== "") streamedText = true;
  };

  const push = (update: InteractionUpdate) => {
    if (turnEnded && update.type !== "turn-ended") afterTurnEnded = true;
    // Cursor's plan and its task list are not tool calls of the transcript: the plan
    // is a proposed plan (a HAL-C2 update, which ACP has none for) and the todos are
    // ACP's plan entries.
    if (update.type === "tool-call-started" || update.type === "tool-call-completed") {
      endTextSegment();
      const toolCall = update.toolCall;
      if (update.type === "tool-call-started") openTools.set(update.callId, toolCall);
      else openTools.delete(update.callId);
      if (toolCall.type === "createPlan") {
        nextSegment("tool");
        emit({
          sessionUpdate: "proposed_plan",
          planId: update.callId,
          markdown: toolCall.args.plan,
          status:
            update.type !== "tool-call-completed"
              ? "in_progress"
              : toolFailed(toolCall)
                ? "failed"
                : "completed",
        });
        return;
      }
      if (toolCall.type === "updateTodos") {
        nextSegment("tool");
        const todos =
          toolCall.result?.status === "success" ? toolCall.result.value.todos : toolCall.args.todos;
        emit({
          sessionUpdate: "plan",
          entries: todos
            .filter((todo) => todo.status !== "cancelled" && todo.content.trim().length > 0)
            .map((todo) => ({
              content: todo.content,
              priority: "medium",
              status:
                todo.status === "inProgress"
                  ? "in_progress"
                  : todo.status === "completed"
                    ? "completed"
                    : "pending",
            })),
        });
        return;
      }
    }
    switch (update.type) {
      case "text-delta": {
        if (options.suppressText === true) return;
        const id = nextSegment("text");
        if (pendingId !== undefined && pendingId !== id) endTextSegment();
        if (tracker.disqualified) {
          emitText(update.text);
          tailFailure = false;
          return;
        }
        pendingId = id;
        pending += update.text;
        tracker.push(update.text);
        if (tracker.disqualified) {
          flushPending();
          tailFailure = false;
        }
        return;
      }
      case "thinking-delta":
        endTextSegment();
        emit({
          sessionUpdate: "agent_thought_chunk",
          messageId: nextSegment("thinking"),
          content: { type: "text", text: update.text },
        });
        return;
      case "tool-call-started":
        nextSegment("tool");
        emit({
          sessionUpdate: "tool_call",
          toolCallId: update.callId,
          status: "in_progress",
          ...toolFields(update.toolCall),
          ...(update.toolCall.type === "task"
            ? { _meta: { childSessionId: `cursor-task-${update.callId}` } }
            : {}),
        });
        return;
      case "tool-call-completed": {
        nextSegment("tool");
        childTranslators.get(update.callId)?.finish({ status: "finished" });
        childTranslators.delete(update.callId);
        const output = toolOutput(update.toolCall);
        const rawOutput = toolRawOutput(update.toolCall);
        emit({
          sessionUpdate: "tool_call_update",
          toolCallId: update.callId,
          status: toolFailed(update.toolCall) ? "failed" : "completed",
          ...toolFields(update.toolCall),
          ...(output === ""
            ? {}
            : { content: [{ type: "content", content: { type: "text", text: output } }] }),
          ...(rawOutput === undefined ? {} : { rawOutput }),
        });
        return;
      }
      case "shell-output-delta": {
        // Output of the shell still running: the newest open shell call's.
        const shell = [...openTools.entries()]
          .toReversed()
          .find(([, toolCall]) => toolCall.type === "shell");
        if (shell === undefined) return;
        const [callId, toolCall] = shell;
        const appended = (shellOutput.get(callId) ?? "") + shellOutputText(update.event);
        const soFar = shellTail(appended);
        shellOutput.set(callId, soFar);
        emit({
          sessionUpdate: "tool_call_update",
          toolCallId: callId,
          status: "in_progress",
          ...toolFields(toolCall),
          content: [{ type: "content", content: { type: "text", text: soFar } }],
        });
        return;
      }
      case "tool-call-delta": {
        // A subagent's own work, streamed inside its task call: it goes to the
        // subagent's child session, which the MC shows as its child thread.
        let child = childTranslators.get(update.callId);
        if (child === undefined) {
          child = makeUpdateTranslator((childUpdate) =>
            emitChild(`cursor-task-${update.callId}`, childUpdate),
          );
          childTranslators.set(update.callId, child);
        }
        child(update.taskUpdate as InteractionUpdate);
        return;
      }
      case "turn-ended":
        endTextSegment();
        turnEnded = true;
        afterTurnEnded = false;
        return;
      default:
        return;
    }
  };

  const finish = (result: {
    readonly status: string;
    readonly result?: string;
    readonly error?: { readonly message: string; readonly code?: string };
  }): { readonly message: string; readonly code?: string } | undefined => {
    for (const child of childTranslators.values()) child.finish({ status: "finished" });
    childTranslators.clear();
    endTextSegment();
    // A tool Cursor started and never reported back did not succeed: it is
    // interrupted with the run, and stays in the timeline showing so. A shell
    // left running is background work Cursor started, which ends with the turn.
    for (const [callId, toolCall] of openTools) {
      if (toolCall.type === "shell") continue;
      emit({
        sessionUpdate: "tool_call_update",
        toolCallId: callId,
        status: "failed",
        _meta: { interrupted: true },
        ...toolFields(toolCall),
      });
    }
    openTools.clear();
    if (result.status === "cancelled") return undefined;
    if (result.status === "error") {
      const message = result.error?.message ?? "Cursor run failed";
      // A turn Cursor already reported ended is answered, however a late
      // resume of it ends (upstream #24231) — unless Cursor went on after
      // the end, in which case the run giving up is the turn's end too.
      if (
        /repeated resume attempts made no progress/.test(message) &&
        turnEnded &&
        !afterTurnEnded
      ) {
        if (!streamedText && result.result) emitText(result.result);
        return undefined;
      }
      return { message, ...(result.error?.code ? { code: result.error.code } : {}) };
    }
    if (tailFailure) return { message: "Provider turn failed." };
    // An answer that arrives only with the run's result is still the answer.
    if (!streamedText && result.result && options.suppressText !== true) {
      const probe = new TransportFailure();
      probe.push(result.result);
      if (probe.failure !== undefined) return { message: "Provider turn failed." };
      emitText(result.result);
    }
    return undefined;
  };

  return Object.assign(push, { finish });
}

function toolFields(toolCall: ToolCall) {
  switch (toolCall.type) {
    case "shell":
      return {
        kind: "execute",
        title: toolCall.args.command,
        rawInput: { command: toolCall.args.command },
      };
    case "write":
    case "edit":
      return {
        kind: "edit",
        title: toolCall.args.path,
        locations: [{ path: toolCall.args.path }],
        rawInput: toolCall.args,
      };
    case "delete":
      return {
        kind: "delete",
        title: toolCall.args.path,
        locations: [{ path: toolCall.args.path }],
        rawInput: toolCall.args,
      };
    case "read":
      return {
        kind: "read",
        title: toolCall.args.path,
        locations: [{ path: toolCall.args.path }],
        rawInput: toolCall.args,
      };
    case "generateImage": {
      const path =
        toolCall.args.filePath ??
        (toolCall.result?.status === "success" ? toolCall.result.value.filePath : undefined) ??
        "generated-image";
      return {
        kind: "edit",
        title: path,
        locations: [{ path }],
        rawInput: toolCall.args,
      };
    }
    case "glob":
    case "grep":
    case "ls":
    case "semSearch":
    case "readLints": {
      const pattern = searchPattern(toolCall);
      return {
        kind: "search",
        title: toolCall.type,
        rawInput: {
          ...toolCall.args,
          ...(pattern === undefined ? {} : { pattern }),
        },
      };
    }
    case "mcp":
      return {
        kind: "other",
        title: `mcp__${toolCall.args.providerIdentifier ?? "mcp"}__${toolCall.args.toolName ?? "unknown"}`,
        rawInput: toolCall.args,
      };
    default:
      return { kind: "other", title: toolCall.type, rawInput: toolCall.args };
  }
}

function toolFailed(toolCall: ToolCall): boolean {
  if (toolCall.result?.status === "error") return true;
  return (
    toolCall.type === "mcp" &&
    toolCall.result?.status === "success" &&
    toolCall.result.value.isError === true
  );
}

/** What a subagent (the `task` tool) said: its assistant messages, then its closing note. */
function taskOutput(value: unknown): string {
  const record = (input: unknown): Record<string, unknown> | undefined =>
    typeof input === "object" && input !== null ? (input as Record<string, unknown>) : undefined;
  const result = record(value);
  const steps = Array.isArray(result?.conversationSteps) ? result.conversationSteps : [];
  const texts = steps.map((step) => {
    const entry = record(step);
    const message = record(
      entry?.type === "assistantMessage" ? entry.message : entry?.assistantMessage,
    );
    return typeof message?.text === "string" ? message.text : "";
  });
  const suffix = typeof result?.resultSuffix === "string" ? result.resultSuffix : "";
  return [...texts, suffix].filter((part) => part.trim().length > 0).join("\n");
}

/** A finished tool's output as text: a command's output, an edit's diff, or its result. */
function toolOutput(toolCall: ToolCall): string {
  const result = toolCall.result;
  if (result === undefined) return "";
  if (result.status !== "success")
    return typeof result.error === "string" ? result.error : JSON.stringify(result.error);
  // The MC shows a subagent's result as text (`HalC2.Acp.ThreadRuntime`), not as JSON.
  if (toolCall.type === "task") return taskOutput(result.value);
  if (toolCall.type === "shell" && toolCall.result?.status === "success") {
    const { stdout, stderr } = toolCall.result.value;
    return [stdout, stderr].filter((part) => part.length > 0).join("\n");
  }
  if (toolCall.type === "edit" && toolCall.result?.status === "success") {
    return toolCall.result.value.diffString ?? "";
  }
  const value = result.value;
  return typeof value === "string" ? value : JSON.stringify(value);
}

/** What a search looked for, in the words its own tool uses. */
function searchPattern(toolCall: ToolCall): string | undefined {
  switch (toolCall.type) {
    case "glob":
      return toolCall.args.globPattern;
    case "grep":
      return toolCall.args.pattern;
    case "semSearch":
      return toolCall.args.query;
    case "ls":
      return toolCall.args.path;
    case "readLints":
      return toolCall.args.paths.join(", ");
    default:
      return undefined;
  }
}

interface SearchResult {
  readonly fileName: string;
  readonly line?: number;
  readonly column?: number;
  readonly preview?: string;
}

function lsResults(node: {
  readonly absPath: string;
  readonly childrenFiles: ReadonlyArray<{ readonly name: string }>;
  readonly childrenDirs: ReadonlyArray<unknown>;
}): SearchResult[] {
  const join = (dir: string, name: string) => (dir.endsWith("/") ? dir + name : `${dir}/${name}`);
  return [
    ...node.childrenFiles.map((file) => ({ fileName: join(node.absPath, file.name) })),
    ...node.childrenDirs.flatMap((child) => lsResults(child as typeof node)),
  ];
}

/** A finished tool's structured results, for the thread's item shapes. */
function toolRawOutput(toolCall: ToolCall): Record<string, unknown> | undefined {
  if (toolCall.result?.status !== "success") return undefined;
  switch (toolCall.type) {
    case "shell":
      return { exitCode: toolCall.result.value.exitCode };
    case "edit": {
      const value = toolCall.result.value;
      return {
        ...(value.linesAdded === undefined ? {} : { linesAdded: value.linesAdded }),
        ...(value.linesRemoved === undefined ? {} : { linesRemoved: value.linesRemoved }),
      };
    }
    case "write":
      return { linesAdded: toolCall.result.value.linesCreated, linesRemoved: 0 };
    case "read":
      return {
        pattern: toolCall.args.path,
        results: [{ fileName: toolCall.args.path, preview: toolCall.result.value.content }],
      };
    case "glob":
      return {
        pattern: toolCall.args.globPattern,
        results: toolCall.result.value.files.map((fileName) => ({ fileName })),
      };
    case "grep":
      return {
        pattern: toolCall.args.pattern,
        results: Object.values(toolCall.result.value.workspaceResults ?? {}).flatMap<SearchResult>(
          (result) => {
            if (result.type === "files") {
              return result.output.files.map((fileName) => ({ fileName }));
            }
            if (result.type === "count") {
              return result.output.counts.map((entry) => ({
                fileName: entry.file,
                preview: entry.count === 1 ? "1 match" : `${entry.count} matches`,
              }));
            }
            return result.output.matches.map((entry) => ({
              fileName: entry.file,
              ...(entry.lineNumber === undefined ? {} : { line: entry.lineNumber }),
              preview: entry.line,
            }));
          },
        ),
      };
    case "ls":
      return {
        pattern: toolCall.args.path,
        results: lsResults(toolCall.result.value.directoryTreeRoot),
      };
    case "readLints":
      return {
        pattern: toolCall.args.paths.join(", "),
        results: toolCall.result.value.fileDiagnostics.flatMap<SearchResult>((file) =>
          file.diagnostics.map((diagnostic) => {
            const line = diagnostic.range?.start?.line;
            const character = diagnostic.range?.start?.character;
            const hasLine = typeof line === "number" && Number.isInteger(line) && line >= 0;
            return {
              fileName: file.path,
              ...(hasLine ? { line: line + 1 } : {}),
              ...(hasLine &&
              typeof character === "number" &&
              Number.isInteger(character) &&
              character >= 0
                ? { column: character + 1 }
                : {}),
              preview: diagnostic.message,
            };
          }),
        ),
      };
    case "semSearch":
      return {
        pattern: toolCall.args.query,
        results: [{ fileName: "semantic-search", preview: toolCall.result.value.results }],
      };
    default:
      return undefined;
  }
}

/**
 * The tail of a running shell's output worth re-sending on each delta: the MC
 * keeps only this much of a command's output (`CommandTail.kept/0`), so more
 * only costs pipe traffic that grows with the output already sent.
 */
const shellTailBytes = 256 * 1024;

function shellTail(text: string): string {
  if (text.length <= shellTailBytes) return text;
  const cut = text.slice(text.length - shellTailBytes);
  // A cut can land inside a surrogate pair: its leftover half goes.
  return cut.charCodeAt(0) >= 0xdc00 && cut.charCodeAt(0) <= 0xdfff ? cut.slice(1) : cut;
}

function shellOutputText(event: Record<string, unknown>): string {
  return [event.text, event.output, event.data, event.stdout, event.stderr, event.chunk]
    .filter((value): value is string => typeof value === "string")
    .join("");
}

// A standalone Cursor transport diagnostic, tracked line by line without
// holding a whole streamed answer (upstream's CursorTransportFailure).
const transportError =
  /^Error: (?:RetriableError: (?!\[internal\]).+|ConnectError: \[(?:unavailable|aborted|deadline_exceeded)\].*)$/;
const serverError = "Something went wrong communicating with the server. Please try again.";

/** Whether `text` (a line so far, end-trimmed) could still grow into a transport error line. */
function couldBeTransportError(text: string): boolean {
  const retriable = "Error: RetriableError: ";
  const connect = "Error: ConnectError: [";
  if (retriable.startsWith(text) || connect.startsWith(text)) return true;
  if (text.startsWith(retriable)) {
    return !text.slice(retriable.length).startsWith("[internal]");
  }
  if (text.startsWith(connect)) {
    const rest = text.slice(connect.length);
    return ["unavailable", "aborted", "deadline_exceeded"].some(
      (word) => word.startsWith(rest) || rest.startsWith(`${word}]`),
    );
  }
  return false;
}

class TransportFailure {
  disqualified = false;
  #failure: string | undefined;
  #line = "";

  // Whether the partial line could still leave this segment a pure transport
  // failure (a transport error line, the server error, blank so far, or a
  // stack line under a failure already seen). Once it cannot, the segment is
  // ordinary text and streams instead of waiting for its first newline.
  #couldStillFail(): boolean {
    const text = this.#line.trimEnd();
    if (text.trim() === "") return true;
    if (serverError.startsWith(text) || couldBeTransportError(text)) return true;
    return this.#failure !== undefined && /^\s+(?:a|at(?:\s.*)?)?$/.test(this.#line);
  }

  #consume(line: string, state: { disqualified: boolean; failure: string | undefined }) {
    if (state.disqualified) return;
    const text = line.trimEnd();
    if (transportError.test(text) || text === serverError) {
      state.failure = text;
    } else if (text.trim() !== "" && !(state.failure && /^\s+at\s/.test(text))) {
      state.disqualified = true;
      state.failure = undefined;
    }
  }

  push(text: string) {
    for (const [index, part] of text.split("\n").entries()) {
      if (this.disqualified) return;
      if (index > 0) {
        const state = { disqualified: this.disqualified, failure: this.#failure };
        this.#consume(this.#line, state);
        this.disqualified = state.disqualified;
        this.#failure = state.failure;
        this.#line = "";
      }
      if (this.#line.length + part.length > 4096) {
        this.disqualified = true;
        this.#failure = undefined;
        this.#line = "";
        return;
      }
      this.#line += part;
      if (!this.#couldStillFail()) {
        this.disqualified = true;
        this.#failure = undefined;
        this.#line = "";
        return;
      }
    }
  }

  get failure(): string | undefined {
    const state = { disqualified: this.disqualified, failure: this.#failure };
    this.#consume(this.#line, state);
    return state.failure;
  }
}

/**
 * A failed run's reason in the user's words where Cursor's own words mislead:
 * a model the account does not offer will not work on a retry, and a text
 * generation stopped by a usage limit names the way out.
 */
function explainFailure(message: string, model: string, mode: RuntimeMode): string {
  if (
    (mode === "text-generation" || mode === "text-generation-unsandboxed") &&
    /usage limit|rate limit|quota|insufficient.*credit/i.test(message)
  ) {
    return "Cursor usage limit reached. Try again later or choose another text-generation provider.";
  }
  if (
    /invalid parameters for registry model|unknown model|model .{0,80}?\b(?:not found|does not exist)\b/i.test(
      message,
    )
  ) {
    return `The model "${model}" is not one this Cursor account offers. Choose a model the Cursor account offers.`;
  }
  return message;
}

/** The MCP servers a session was opened with, in the SDK's shape, by name. */
function mcpServers(named: unknown): Record<string, McpServerConfig> {
  const servers: Record<string, McpServerConfig> = {};
  if (!Array.isArray(named)) return servers;
  for (const entry of named) {
    if (typeof entry !== "object" || entry === null) continue;
    const server = entry as Record<string, unknown>;
    const name = typeof server.name === "string" ? server.name : undefined;
    if (name === undefined || name === "") continue;
    if (typeof server.url === "string" && server.url !== "") {
      const headers: Record<string, string> = {};
      if (Array.isArray(server.headers)) {
        for (const header of server.headers) {
          if (typeof header !== "object" || header === null) continue;
          const { name: key, value } = header as Record<string, unknown>;
          if (typeof key === "string" && typeof value === "string") headers[key] = value;
        }
      }
      servers[name] = {
        type: server.type === "sse" ? "sse" : "http",
        url: server.url,
        ...(Object.keys(headers).length === 0 ? {} : { headers }),
      };
    } else if (typeof server.command === "string" && server.command !== "") {
      const env: Record<string, string> = {};
      if (Array.isArray(server.env)) {
        for (const variable of server.env) {
          if (typeof variable !== "object" || variable === null) continue;
          const { name: key, value } = variable as Record<string, unknown>;
          if (typeof key === "string" && typeof value === "string") env[key] = value;
        }
      } else if (typeof server.env === "object" && server.env !== null) {
        for (const [key, value] of Object.entries(server.env)) {
          if (typeof value === "string") env[key] = value;
        }
      }
      servers[name] = {
        command: server.command,
        ...(Array.isArray(server.args)
          ? { args: server.args.filter((arg): arg is string => typeof arg === "string") }
          : {}),
        ...(Object.keys(env).length === 0 ? {} : { env }),
      };
    }
  }
  return servers;
}
