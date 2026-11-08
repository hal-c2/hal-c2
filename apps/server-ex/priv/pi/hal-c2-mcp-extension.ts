import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { Type } from "typebox";

const URL_ENV = "HAL_C2_MCP_URL";
const TOKEN_ENV = "HAL_C2_MCP_BEARER_TOKEN";
const RUNTIME_MODE_ENV = "HAL_C2_PI_RUNTIME_MODE";
const ORCHESTRATION_INSTRUCTIONS = "__HAL_C2_INSTRUCTIONS__";
const PROTOCOL = "2025-06-18";
const READ_ONLY_TOOLS = new Set(["read", "grep", "find", "ls"]);
const FILE_CHANGE_TOOLS = new Set(["edit", "write"]);

type RuntimeMode = "approval-required" | "auto-accept-edits" | "auto" | "full-access";

type JsonRpcResponse = {
  readonly id?: number | string;
  readonly result?: unknown;
  readonly error?: { readonly message?: string };
};

// What Pi skips in a folder it does not trust (docs/security.md, "Resources
// protected by project trust"), under Pi's default project config directory.
const PROTECTED: ReadonlyArray<readonly [string, ReadonlyArray<string>]> = [
  ["settings", [".pi/settings.json"]],
  ["MCP servers", [".pi/mcp.json"]],
  ["extensions", [".pi/extensions"]],
  ["skills", [".pi/skills"]],
  ["prompt templates", [".pi/prompts"]],
  ["themes", [".pi/themes"]],
  ["system prompt files", [".pi/SYSTEM.md", ".pi/APPEND_SYSTEM.md"]],
];

/** What Pi skipped in `cwd`, an untrusted folder: the kinds of its protected resources there. */
function skippedResources(cwd: string): string[] {
  const skipped = PROTECTED.filter(([, paths]) =>
    paths.some((path) => existsSync(join(cwd, path))),
  ).map(([kind]) => kind);
  // Project skills in `.agents/skills` count from the folder or any folder above it,
  // except the home directory, whose are the user's own.
  let dir = cwd;
  while (!skipped.includes("skills") && dir !== homedir()) {
    if (existsSync(join(dir, ".agents/skills"))) skipped.push("skills");
    if (dirname(dir) === dir) break;
    dir = dirname(dir);
  }
  return skipped;
}

function listed(items: readonly string[]): string {
  return items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;
}

type McpTool = {
  readonly name: string;
  readonly description?: string;
  readonly inputSchema?: Record<string, unknown>;
};

function env(name: string): string | undefined {
  const value = process.env[name];
  return value && value.length > 0 ? value : undefined;
}

function runtimeMode(): RuntimeMode {
  const value = env(RUNTIME_MODE_ENV);
  return value === "approval-required" ||
    value === "auto-accept-edits" ||
    value === "auto" ||
    value === "full-access"
    ? value
    : "full-access";
}

function toolInputSummary(input: unknown): string {
  try {
    return JSON.stringify(input, null, 2).slice(0, 4_000);
  } catch {
    return String(input).slice(0, 4_000);
  }
}

function parseSseOrJson(body: string, contentType: string): JsonRpcResponse {
  if (contentType.includes("text/event-stream")) {
    for (const line of body.split("\n")) {
      const trimmed = line.startsWith("data:") ? line.slice(5).trim() : "";
      if (trimmed.length === 0) continue;
      const parsed = JSON.parse(trimmed) as JsonRpcResponse;
      if (parsed.id !== undefined || parsed.result !== undefined || parsed.error !== undefined) {
        return parsed;
      }
    }
    throw new Error("MCP SSE response had no JSON-RPC payload.");
  }
  return JSON.parse(body) as JsonRpcResponse;
}

function jsonSchemaToTypebox(schema: Record<string, unknown> | undefined) {
  const unsafe = (Type as { Unsafe?: (value: unknown) => unknown }).Unsafe;
  if (typeof unsafe === "function" && schema !== undefined) {
    return unsafe(schema);
  }
  return Type.Object({}, { additionalProperties: true });
}

function formatMcpContent(result: unknown): string {
  if (result === null || result === undefined) return "";
  if (typeof result !== "object") return String(result);
  const record = result as {
    readonly content?: ReadonlyArray<{ readonly type?: string; readonly text?: string }>;
    readonly structuredContent?: unknown;
    readonly isError?: boolean;
  };
  const texts: string[] = [];
  if (Array.isArray(record.content)) {
    for (const part of record.content) {
      if (part?.type === "text" && typeof part.text === "string") texts.push(part.text);
    }
  }
  if (record.structuredContent !== undefined) {
    texts.push(JSON.stringify(record.structuredContent));
  }
  if (texts.length > 0) return texts.join("\n");
  return JSON.stringify(result);
}

function isMcpToolError(result: unknown): boolean {
  return (
    typeof result === "object" && result !== null && "isError" in result && result.isError === true
  );
}

function createMcpClient(endpoint: string, token: string) {
  let nextId = 1;
  let sessionId: string | undefined;

  const headers = (): Record<string, string> => {
    const next: Record<string, string> = {
      accept: "application/json, text/event-stream",
      authorization: token.startsWith("Bearer ") ? token : `Bearer ${token}`,
      "content-type": "application/json",
      // Effect's HTTP MCP rejects post-initialize requests without this
      // (400). The worktree client in McpHttpServer tests sends the same
      // header; initialize itself does not require it.
      "mcp-protocol-version": PROTOCOL,
    };
    if (sessionId !== undefined) next["mcp-session-id"] = sessionId;
    return next;
  };

  const request = async (method: string, params?: unknown, signal?: AbortSignal) => {
    const id = nextId++;
    const response = await fetch(endpoint, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
      signal,
    });
    const nextSession = response.headers.get("mcp-session-id");
    if (nextSession) sessionId = nextSession;
    const body = await response.text();
    if (!response.ok) {
      throw new Error(`MCP ${method} failed (${response.status}): ${body.slice(0, 400)}`);
    }
    if (body.length === 0) return undefined;
    const parsed = parseSseOrJson(body, response.headers.get("content-type") ?? "");
    if (parsed.error) {
      throw new Error(parsed.error.message ?? `MCP ${method} returned an error`);
    }
    return parsed.result;
  };

  const notify = async (method: string, params?: unknown, signal?: AbortSignal) => {
    await fetch(endpoint, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ jsonrpc: "2.0", method, params }),
      signal,
    });
  };

  return {
    async connect(signal?: AbortSignal) {
      await request(
        "initialize",
        {
          protocolVersion: PROTOCOL,
          capabilities: {},
          clientInfo: { name: "hal-c2-pi-mcp", version: "1.0.0" },
        },
        signal,
      );
      await notify("notifications/initialized", {}, signal).catch(() => undefined);
    },
    async listTools(signal?: AbortSignal) {
      const tools: McpTool[] = [];
      let cursor: string | undefined;
      do {
        const result = (await request(
          "tools/list",
          cursor === undefined ? {} : { cursor },
          signal,
        )) as { tools?: McpTool[]; nextCursor?: string } | undefined;
        tools.push(...(result?.tools ?? []));
        cursor = result?.nextCursor;
      } while (cursor);
      return tools;
    },
    async callTool(name: string, args: Record<string, unknown>, signal?: AbortSignal) {
      return request("tools/call", { name, arguments: args }, signal);
    },
  };
}

export default async function halC2McpExtension(pi: ExtensionAPI) {
  // Workaround for an upstream Pi context-budgeting bug: pi-ai reuses the
  // previous response's usage even when a fork's instructions/tools differ,
  // then reserves almost all remaining context for output. OpenRouter can
  // reject even a short conversation. Remove this cap when Pi accounts for
  // the current request prefix reliably (api/simple-options + utils/estimate).
  // Pi quietly skips a folder's own settings, extensions and skills until the folder
  // is trusted. A Pi process says so once, as it starts; HAL-C2 shows the notice in
  // the thread's next turn.
  pi.on("session_start", (event, ctx) => {
    if (event.reason !== "startup" || ctx.isProjectTrusted()) return;
    const skipped = skippedResources(ctx.cwd);
    if (skipped.length === 0) return;
    ctx.ui.notify(
      `Pi does not trust ${ctx.cwd}, so it skipped the folder's ${listed(skipped)}. ` +
        `To trust the folder, run "/trust" in Pi's terminal app there.`,
      "warning",
    );
  });

  pi.on("before_provider_request", (event, ctx) => {
    if (ctx.model?.provider !== "openrouter") return;
    const payload = event.payload;
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return;
    const replacement = { ...payload } as Record<string, unknown>;
    let changed = false;
    for (const key of ["max_tokens", "max_completion_tokens"]) {
      const limit = replacement[key];
      if (typeof limit === "number" && Number.isFinite(limit) && limit > 32_768) {
        replacement[key] = 32_768;
        changed = true;
      }
    }
    if (changed) return replacement;
  });

  // Pi deliberately leaves permission policy to extensions. HAL-C2's injected
  // bridge uses Pi's public blocking tool hook so the shared runtime modes
  // keep their normal meaning without replacing or shadowing Pi's runtime.
  pi.on("tool_call", async (event, ctx) => {
    const mode = runtimeMode();
    if (mode === "full-access" || READ_ONLY_TOOLS.has(event.toolName)) return;
    if (mode === "auto-accept-edits" && FILE_CHANGE_TOOLS.has(event.toolName)) {
      return;
    }
    const approved = await ctx.ui.confirm(
      `Allow ${event.toolName}?`,
      toolInputSummary(event.input),
    );
    if (!approved) {
      return { block: true, reason: `${event.toolName} was declined in HAL-C2.` };
    }
  });

  const endpoint = env(URL_ENV);
  const token = env(TOKEN_ENV);
  if (endpoint === undefined || token === undefined) {
    pi.on("session_start", async (_event, ctx) => {
      ctx.ui.notify(
        "hal-c2 MCP unavailable: HAL_C2_MCP_URL or HAL_C2_MCP_BEARER_TOKEN is missing.",
        "warning",
      );
    });
    return;
  }

  const client = createMcpClient(endpoint, token);
  let started: Promise<void> | undefined;

  const ensureStarted = () => {
    if (started !== undefined) return started;
    const attempt = (async () => {
      const signal = AbortSignal.timeout(10_000);
      await client.connect(signal);
      const tools = await client.listTools(signal);
      for (const tool of tools) {
        const name = tool.name;
        const registeredName = `mcp__hal-c2__${name}`;
        const description = tool.description ?? name;
        pi.registerTool({
          name: registeredName,
          label: name,
          description,
          promptSnippet: description.split("\n")[0] ?? name,
          promptGuidelines: [
            `Use ${registeredName} from the hal-c2 MCP server when the user asks for HAL-C2 orchestration that this tool covers.`,
          ],
          parameters: jsonSchemaToTypebox(tool.inputSchema),
          async execute(_toolCallId, params, signal) {
            const result = await client.callTool(
              name,
              (params ?? {}) as Record<string, unknown>,
              signal,
            );
            const text = formatMcpContent(result);
            return {
              content: [{ type: "text", text }],
              details: { server: "hal-c2", tool: name },
              ...(isMcpToolError(result) ? { isError: true } : {}),
            };
          },
        });
      }
    })();
    started = attempt;
    void attempt.catch(() => {
      if (started === attempt) started = undefined;
    });
    return attempt;
  };

  // Await here so tools exist before session_start and the first prompt.
  // session_start is a retry if the process later reloads the extension.
  // Best effort during extension load. A failed first connection is retried
  // below on session_start instead of pinning this process to the failure.
  await ensureStarted().catch(() => undefined);

  pi.on("session_start", async (_event, ctx) => {
    try {
      await ensureStarted();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      ctx.ui.notify(`hal-c2 MCP unavailable: ${message}`, "warning");
    }
  });

  // Deliver orchestration guidance through pi's real system-prompt channel.
  // Wrapping the first user message instead would stop it from starting
  // with "/" and silently break slash-command expansion.
  pi.on("before_agent_start", (event) => ({
    systemPrompt: event.systemPrompt + "\n\n" + ORCHESTRATION_INSTRUCTIONS,
  }));
}
