// The Cursor ACP agent (packages/cursor-acp/src/agent.ts) over a fake Cursor SDK,
// for the Cursor features (`HalC2.Test.AcpFixtures`).
//
//   node fake_cursor.mjs --control DIR --mode MODE
//
// The instance is the directory HAL_C2_CURSOR_CREDENTIALS sits in; its behaviour is
// DIR/control.json["cursor-<instance>"] (`models`, `revoked`) and everything the SDK
// is asked to do is appended to DIR/cursor-<instance>.log as JSON lines. Browser
// sign-in finishes when DIR/cursor-<instance>.login-done exists ("the user finished
// on the website").
import * as fs from "node:fs";
import * as path from "node:path";
import * as readline from "node:readline";

import { makeCursorAcp } from "../../../../packages/cursor-acp/src/agent.ts";

const argv = process.argv.slice(2);
const opt = (flag, fallback) => {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : fallback;
};
const dir = opt("--control");
const mode = opt("--mode", "approval-required");
const credentials = process.env.HAL_C2_CURSOR_CREDENTIALS;
const name = `cursor-${path.basename(path.dirname(credentials))}`;
let control = {};
try {
  control = JSON.parse(fs.readFileSync(path.join(dir, "control.json"), "utf8"))[name] ?? {};
} catch {}

const log = (entry) =>
  fs.appendFileSync(path.join(dir, `${name}.log`), `${JSON.stringify(entry)}\n`);

// A late SDK rejection is logged, never fatal, as in the sidecar's own main.
process.on("unhandledRejection", (cause) => {
  log({ event: "unhandled-rejection-swallowed", message: String(cause?.message ?? cause) });
});
log({ event: "launch", mode, env: { CURSOR_API_KEY: process.env.CURSOR_API_KEY ?? null } });

const authError = () => Object.assign(new Error("Unauthorized"), { auth: true });
const refused = (key) => control.revoked === true || key === "revoked";

const store = {
  load: async () => {
    if (control.storeBroken === true) throw new Error("cannot read credentials file");
    try {
      return JSON.parse(fs.readFileSync(credentials, "utf8"));
    } catch {
      return undefined;
    }
  },
  save: async (value) => {
    fs.mkdirSync(path.dirname(credentials), { recursive: true });
    fs.writeFileSync(credentials, JSON.stringify(value), { mode: 0o600 });
  },
  clear: async () => fs.rmSync(credentials, { force: true }),
};

let agents = 0;
// A resumed agent keeps its id, as the SDK's `Agent.resume` does.
const makeAgent = (options, resumed) => {
  if (refused(options.apiKey)) throw authError();
  const agentId = resumed ?? `cursor-agent-${process.pid}-${++agents}`;
  // The SDK loads the project's rules and skills from the agent's working directory
  // unless its setting sources leave the project out.
  const sources = options.local?.settingSources;
  const cwd = options.local?.cwd;
  const loaded = [];
  if (cwd && (sources === undefined || sources.includes("project") || sources.includes("all"))) {
    for (const kind of ["rules", "skills"]) {
      const folder = path.join(cwd, ".cursor", kind);
      if (fs.existsSync(folder))
        for (const name of fs.readdirSync(folder).sort()) loaded.push(`${kind}/${name}`);
    }
  }
  log({
    event: "agent",
    agentId,
    cwd: cwd ?? null,
    loaded,
    mode: options.mode,
    apiKey: options.apiKey,
    autoReview: options.local?.autoReview,
    sandbox: options.local?.sandboxOptions?.enabled,
    agentRetries: options.local?.enableAgentRetries ?? null,
    settingSources: options.local?.settingSources ?? null,
  });
  return {
    agentId,
    close: () => {},
    send: async (message, sendOptions) => {
      const images = typeof message === "string" ? [] : (message.images ?? []);
      // What follows reads the message's text; images ride beside it.
      message = typeof message === "string" ? message : (message.text ?? "");
      log({
        event: "send",
        agentId,
        message,
        model: sendOptions.model,
        mode: sendOptions.mode ?? null,
        images: images.map((image) => ({
          mimeType: image.mimeType ?? null,
          bytes: typeof image.data === "string" ? image.data.length : 0,
        })),
        mcpServers: Object.keys(sendOptions.mcpServers ?? {}),
      });
      let cancel;
      const cancelled = new Promise((resolve) => (cancel = resolve));
      const say = (text) => sendOptions.onDelta({ update: { type: "text-delta", text } });
      const started = (callId, toolCall) =>
        sendOptions.onDelta({ update: { type: "tool-call-started", callId, toolCall } });
      const completed = (callId, toolCall, value) =>
        sendOptions.onDelta({
          update: {
            type: "tool-call-completed",
            callId,
            toolCall: { ...toolCall, result: { status: "success", value } },
          },
        });
      const tool = (callId, toolCall, value) => {
        started(callId, toolCall);
        completed(callId, toolCall, value);
      };
      const untilReleased = (file) =>
        Promise.race([
          cancelled,
          new Promise((resolve) => {
            const timer = setInterval(() => {
              if (fs.existsSync(path.join(dir, file))) {
                clearInterval(timer);
                resolve();
              }
            }, 20);
          }),
        ]);
      const keys = /Return a JSON object with keys?: ([A-Za-z, ]+)\./.exec(message);
      return {
        cancel: async () => cancel(),
        wait: async () => {
          // Triggers read what the user asked, never HAL-C2's own instructions
          // wrapped around it (they name tools such as hal_c2_thread_wait).
          message = /<user_request>\n([\s\S]*?)\n<\/user_request>/.exec(message)?.[1] ?? message;
          if (
            control.sandboxBlocksTextGen === true &&
            options.local?.sandboxOptions?.enabled === true &&
            (mode === "text-generation" || mode === "text-generation-unsandboxed")
          ) {
            return {
              status: "error",
              error: { message: "Operation blocked by the sandbox policy" },
            };
          }
          if (message.includes("run it sandboxed")) {
            // The SDK retries a sandbox-stopped command outside the sandbox
            // only when the agent was made with retries on.
            const shell = { type: "shell", args: { command: "curl https://example.test" } };
            started("sb-1", shell);
            sendOptions.onDelta({
              update: {
                type: "tool-call-completed",
                callId: "sb-1",
                toolCall: {
                  ...shell,
                  result: { status: "error", value: { reason: { case: "sandboxDenied" } } },
                },
              },
            });
            if (options.local?.enableAgentRetries === true) {
              tool("sb-2", shell, { stdout: "200 ok", stderr: "", exitCode: 0 });
            }
            say("Fetched it.");
            return { status: "finished" };
          }
          if (control.usageLimit === true) {
            return {
              status: "error",
              error: { message: "Cursor SDK request finished with an error: usage limit reached" },
            };
          }
          if (message === "/compress") {
            say("Summary of everything so far.");
            return { status: "finished" };
          }
          if (message.includes("die mid-turn")) {
            // The SDK's stream closes under a write and the process goes with it.
            say("Working on it.");
            setTimeout(() => process.exit(1), 30);
            await cancelled;
            return { status: "cancelled" };
          }
          if (message.includes("late write after the end")) {
            say("All done.");
            setTimeout(() => {
              void sendOptions.onDelta({ update: { type: "text-delta", text: "late" } });
              void Promise.reject(new Error("WritableIterable is closed"));
            }, 40);
            return { status: "finished" };
          }
          if (message.includes("start reading secret.txt")) {
            started("read-1", { type: "read", args: { path: "secret.txt" } });
            say("That read never came back.");
            return { status: "finished" };
          }
          if (message.includes("answer only in the result")) {
            return { status: "finished", result: "The answer arrived with the result." };
          }
          if (message.includes("reply with a connection error")) {
            say("Something went wrong communicating with the server. Please try again.");
            return { status: "finished" };
          }
          if (message.includes("comment then a connection error")) {
            say("Checking the build first.");
            tool(
              "step-1",
              { type: "shell", args: { command: "npm run build" } },
              {
                stdout: "built",
                stderr: "",
                exitCode: 0,
              },
            );
            say("Error: RetriableError: WritableIterable is closed");
            if (message.includes("then recover")) {
              tool(
                "step-2",
                { type: "shell", args: { command: "npm test" } },
                {
                  stdout: "ok",
                  stderr: "",
                  exitCode: 0,
                },
              );
              say("All good now.");
            }
            return { status: "finished" };
          }
          if (message.includes("quote a connection error")) {
            say(
              "That message means the stream closed early:\nSomething went wrong communicating with the server. Please try again.\nIt is safe to retry.",
            );
            return { status: "finished" };
          }
          if (message.includes("fail with model blocked")) {
            return {
              status: "error",
              error: {
                message: "Model Blocked Please ask your admin to enable access",
                code: "model_blocked",
              },
            };
          }
          if (message.includes("reject the model")) {
            return {
              status: "error",
              error: { message: "Invalid parameters for registry model: model not found" },
            };
          }
          if (message.includes("resume gives up")) {
            const noProgress = {
              status: "error",
              error: {
                message: "Agent turn stopped after repeated resume attempts made no progress",
              },
            };
            if (message.includes("after the turn ended")) {
              say("Here is the answer.");
              sendOptions.onDelta({ update: { type: "turn-ended" } });
              if (message.includes("then carry on")) say("One more thing…");
              if (message.includes("checkpoint fails")) {
                return {
                  status: "error",
                  error: { message: "Checkpoint persistence failed" },
                };
              }
              return noProgress;
            }
            say("Still working…");
            return noProgress;
          }
          if (message.includes("stream a long command")) {
            const shell = { type: "shell", args: { command: "npm run build --watch" } };
            started("cmd-long", shell);
            sendOptions.onDelta({
              update: { type: "shell-output-delta", event: { text: "compiling…\n" } },
            });
            await untilReleased(`${name}.release`);
            completed("cmd-long", shell, {
              stdout: "compiling…\ndone\n",
              stderr: "",
              exitCode: 0,
            });
            say("Build finished.");
            return { status: "finished" };
          }
          if (message.includes("tour:")) {
            if (message.includes("tour: shell")) {
              tool(
                "t-shell",
                { type: "shell", args: { command: "npm test" } },
                {
                  stdout: "4 passing",
                  stderr: "",
                  exitCode: 0,
                },
              );
            } else if (message.includes("tour: write")) {
              tool(
                "t-write",
                { type: "write", args: { path: "notes.txt", fileText: "hi\n" } },
                {
                  path: "notes.txt",
                  linesCreated: 1,
                  fileSize: 3,
                },
              );
            } else if (message.includes("tour: edit")) {
              tool(
                "t-edit",
                { type: "edit", args: { path: "app.ex" } },
                {
                  linesAdded: 2,
                  linesRemoved: 1,
                  diffString: "-old line\n+new line\n+another line",
                },
              );
            } else if (message.includes("tour: delete")) {
              tool("t-delete", { type: "delete", args: { path: "old.txt" } }, { fileSize: 12 });
            } else if (message.includes("tour: image")) {
              tool(
                "t-image",
                { type: "generateImage", args: { description: "a cat", filePath: "cat.png" } },
                { filePath: "cat.png", imageData: "iVBORw0KGgo=" },
              );
            } else if (message.includes("tour: read")) {
              tool(
                "t-read",
                { type: "read", args: { path: "README.md" } },
                {
                  content: "# Shop\n",
                  totalLines: 1,
                  fileSize: 7,
                },
              );
            } else if (message.includes("tour: ls")) {
              const leaf = (absPath, names) => ({
                absPath,
                childrenDirs: [],
                childrenFiles: names.map((name) => ({ name })),
                childrenWereProcessed: true,
                fullSubtreeExtensionCounts: {},
                numFiles: names.length,
              });
              tool(
                "t-ls",
                { type: "ls", args: { path: "src" } },
                {
                  directoryTreeRoot: {
                    ...leaf("src", ["app.ex"]),
                    childrenDirs: [leaf("src/web", ["router.ex", "live.ex"])],
                  },
                },
              );
            } else if (message.includes("tour: glob")) {
              tool(
                "t-glob",
                { type: "glob", args: { globPattern: "**/*.ex" } },
                {
                  files: ["lib/app.ex", "lib/web.ex"],
                  totalFiles: 2,
                  clientTruncated: false,
                  ripgrepTruncated: false,
                },
              );
            } else if (message.includes("tour: grep-count")) {
              tool(
                "t-grep",
                { type: "grep", args: { pattern: "needle", outputMode: "count" } },
                {
                  workspaceResults: {
                    ws: {
                      type: "count",
                      output: {
                        counts: [
                          { file: "a.ex", count: 1 },
                          { file: "b.ex", count: 3 },
                        ],
                        total: 4,
                      },
                    },
                  },
                },
              );
            } else if (message.includes("tour: grep")) {
              tool(
                "t-grep",
                { type: "grep", args: { pattern: "needle" } },
                {
                  workspaceResults: {
                    ws: {
                      type: "content",
                      output: {
                        matches: [{ file: "a.ex", lineNumber: 3, line: "a needle here" }],
                        totalMatches: 1,
                      },
                    },
                  },
                },
              );
            } else if (message.includes("tour: semsearch")) {
              tool(
                "t-sem",
                { type: "semSearch", args: { query: "how auth works" } },
                {
                  results: "lib/auth.ex handles it",
                },
              );
            } else if (message.includes("tour: lints")) {
              tool(
                "t-lints",
                { type: "readLints", args: { paths: ["app.ex"] } },
                {
                  fileDiagnostics: [
                    {
                      path: "app.ex",
                      diagnosticsCount: 1,
                      diagnostics: [
                        {
                          severity: "warning",
                          message: "unused variable x",
                          source: "lint",
                          code: "W1",
                          range: { start: { line: 4, character: 2 } },
                        },
                      ],
                    },
                  ],
                  totalFiles: 1,
                  totalDiagnostics: 1,
                },
              );
            } else if (message.includes("tour: mcp")) {
              const mcp = {
                type: "mcp",
                args: { providerIdentifier: "docs", toolName: "search", args: { q: "x" } },
              };
              tool("t-mcp", mcp, { content: [{ text: { text: "found it" } }], isError: false });
              tool("t-mcp2", mcp, { content: [{ text: { text: "boom" } }], isError: true });
            } else if (message.includes("tour: todos")) {
              const todos = [
                { content: "Keep me", status: "inProgress" },
                { content: "Dropped", status: "cancelled" },
                { content: "   ", status: "pending" },
              ];
              tool("t-todos", { type: "updateTodos", args: { todos } }, { todos });
            }
            say("Tour done.");
            return { status: "finished" };
          }
          if (message.includes("hand a task to a subagent")) {
            const task = {
              type: "task",
              args: { description: "Survey the code", prompt: "List the modules" },
            };
            started("task-1", task);
            const nested = (taskUpdate) =>
              sendOptions.onDelta({
                update: { type: "tool-call-delta", callId: "task-1", taskUpdate },
              });
            nested({ type: "text-delta", text: "Looking around." });
            if (message.includes("empty ls")) {
              const ls = { type: "ls", args: { path: "src" } };
              nested({ type: "tool-call-started", callId: "sub-ls", toolCall: ls });
              nested({
                type: "tool-call-completed",
                callId: "sub-ls",
                toolCall: {
                  ...ls,
                  result: {
                    status: "success",
                    value: {
                      directoryTreeRoot: {
                        absPath: "src",
                        childrenDirs: [
                          {
                            absPath: "src/web",
                            childrenDirs: [],
                            childrenFiles: [],
                            childrenWereProcessed: true,
                            fullSubtreeExtensionCounts: {},
                            numFiles: 0,
                          },
                        ],
                        childrenFiles: [],
                        childrenWereProcessed: true,
                        fullSubtreeExtensionCounts: {},
                        numFiles: 0,
                      },
                    },
                  },
                },
              });
            } else if (message.includes("empty lints")) {
              const lints = { type: "readLints", args: { paths: ["app.ex"] } };
              nested({ type: "tool-call-started", callId: "sub-lints", toolCall: lints });
              nested({
                type: "tool-call-completed",
                callId: "sub-lints",
                toolCall: {
                  ...lints,
                  result: {
                    status: "success",
                    value: { fileDiagnostics: [], totalFiles: 1, totalDiagnostics: 0 },
                  },
                },
              });
            } else if (message.includes("empty mcp")) {
              const mcp = {
                type: "mcp",
                args: { providerIdentifier: "docs", toolName: "search", args: {} },
              };
              nested({ type: "tool-call-started", callId: "sub-mcp", toolCall: mcp });
              nested({
                type: "tool-call-completed",
                callId: "sub-mcp",
                toolCall: {
                  ...mcp,
                  result: { status: "success", value: { content: [], isError: false } },
                },
              });
            } else {
              const read = { type: "read", args: { path: "lib/app.ex" } };
              nested({ type: "tool-call-started", callId: "sub-read", toolCall: read });
              nested({
                type: "tool-call-completed",
                callId: "sub-read",
                toolCall: {
                  ...read,
                  result: {
                    status: "success",
                    value: { content: "defmodule App", totalLines: 1, fileSize: 14 },
                  },
                },
              });
            }
            completed("task-1", task, {
              isBackground: false,
              backgroundReason: "unspecified",
              conversationSteps: [
                { type: "assistantMessage", message: { text: "There are three modules." } },
              ],
              resultSuffix: "Survey complete.",
            });
            say("The survey is in.");
            return { status: "finished" };
          }
          if (message.includes("run a command and wait")) {
            // A shell that runs until the run is cancelled; the SDK then reports the
            // killed shell as a finished tool call, like any other.
            const toolCall = { type: "shell", args: { command: "npm test" } };
            sendOptions.onDelta({
              update: { type: "tool-call-started", callId: "cmd-1", toolCall },
            });
            await cancelled;
            log({ event: "tool-completed", callId: "cmd-1" });
            sendOptions.onDelta({
              update: {
                type: "tool-call-completed",
                callId: "cmd-1",
                toolCall: {
                  ...toolCall,
                  result: { status: "success", value: { stdout: "", stderr: "", exitCode: 143 } },
                },
              },
            });
            return { status: "cancelled" };
          }
          if (message.includes("ignore the cancel")) {
            // A run that never confirms a cancellation.
            await new Promise(() => {});
            return { status: "cancelled" };
          }
          if (message.includes("wait")) {
            await cancelled;
            return { status: "cancelled" };
          }
          if (message.includes("make a plan")) {
            // Plan mode: the task list, then the plan itself.
            const todos = [
              { content: "Read the code", status: "completed" },
              { content: "Write the plan", status: "inProgress" },
              { content: "Dropped", status: "cancelled" },
            ];
            sendOptions.onDelta({
              update: {
                type: "tool-call-completed",
                callId: "todos-1",
                toolCall: {
                  type: "updateTodos",
                  args: { todos },
                  result: { status: "success", value: { todos } },
                },
              },
            });
            const plan = { type: "createPlan", args: { plan: "# Plan\n- do it" } };
            sendOptions.onDelta({
              update: { type: "tool-call-started", callId: "plan-1", toolCall: plan },
            });
            sendOptions.onDelta({
              update: {
                type: "tool-call-completed",
                callId: "plan-1",
                toolCall: { ...plan, result: { status: "success", value: {} } },
              },
            });
            return { status: "finished" };
          }
          if (message.includes("a command that cannot start")) {
            // The shell could not be spawned: the tool call fails and the run goes on.
            const toolCall = { type: "shell", args: { command: "nosuchtool --version" } };
            sendOptions.onDelta({
              update: { type: "tool-call-started", callId: "cmd-1", toolCall },
            });
            sendOptions.onDelta({
              update: {
                type: "tool-call-completed",
                callId: "cmd-1",
                toolCall: {
                  ...toolCall,
                  result: { status: "error", error: "spawn nosuchtool ENOENT" },
                },
              },
            });
            say("That tool is not installed.");
            return { status: "finished" };
          }
          if (keys || message.includes("Return JSON with keys")) {
            const names = keys
              ? keys[1].split(",").map((k) => k.trim())
              : ["title", "needsRefinement"];
            say(
              JSON.stringify(
                Object.fromEntries(
                  names.map((k) => [k, k === "needsRefinement" ? false : `cursor ${k}`]),
                ),
              ),
            );
          } else if (message.includes("leave a command running")) {
            // A shell the run started and never reported finished.
            sendOptions.onDelta({
              update: {
                type: "tool-call-started",
                callId: "cmd-bg",
                toolCall: { type: "shell", args: { command: "npm run dev" } },
              },
            });
            say("Started it.");
          } else {
            say("Hello from Cursor");
          }
          return { status: "finished" };
        },
      };
    },
  };
};

const acp = makeCursorAcp({
  mode,
  platform: process.env.HAL_C2_CURSOR_PLATFORM ?? "linux",
  catalogTimeoutMs: control.catalogTimeoutMs ?? 10000,
  write: (message) => process.stdout.write(`${JSON.stringify(message)}\n`),
  sdk: {
    version: "1.0.31",
    store,
    envApiKey: process.env.CURSOR_API_KEY?.trim() || undefined,
    createAgent: async (options) => makeAgent(options),
    resumeAgent: async (agentId, options) => makeAgent(options, agentId),
    me: async (key) => {
      log({ event: "me" });
      if (refused(key)) throw authError();
      if (control.freePlan === true) {
        throw new Error("Free plan users cannot use the Cursor SDK. Upgrade to a paid plan.");
      }
      if (control.meError === "blocked") {
        throw new Error("403 Forbidden: permission denied by team settings");
      }
      if (control.meError === "boom") throw new Error("network unreachable");
      return control.noEmail === true
        ? { apiKeyName: "HAL-C2" }
        : { userEmail: control.email ?? "dev@example.com", apiKeyName: "HAL-C2" };
    },
    listModels: async (key) => {
      if (refused(key)) throw authError();
      if (control.freePlan === true) {
        throw new Error("Free plan users cannot use the Cursor SDK. Upgrade to a paid plan.");
      }
      if (control.catalogError === true) throw new Error("socket hang up");
      if (control.catalogHang === true) await new Promise(() => {});
      return (
        control.models ?? [
          ["composer-2", "Composer 2"],
          ["gpt-5", "GPT-5"],
        ]
      ).map(([id, displayName]) => ({
        id,
        displayName,
        // `parameters` / `variants` in the control give a model its own options.
        ...(control.parameters?.[id] ? { parameters: control.parameters[id] } : {}),
        ...(control.variants?.[id] ? { variants: control.variants[id] } : {}),
      }));
    },
    login: async ({ store, signal, onLoginUrl }) => {
      log({ event: "login" });
      onLoginUrl("https://cursor.test/login");
      const done = path.join(dir, `${name}.login-done`);
      await new Promise((resolve, reject) => {
        const timer = setInterval(() => {
          if (signal.aborted) {
            clearInterval(timer);
            reject(new Error("Cursor sign-in was declined."));
          } else if (fs.existsSync(done)) {
            clearInterval(timer);
            resolve();
          }
        }, 20);
      });
      await store.save({ apiKey: "cursor-key" });
    },
    isAuthError: (cause) => cause?.auth === true,
  },
});

const lines = readline.createInterface({ input: process.stdin });
lines.on("line", (line) => {
  if (line.trim() === "") return;
  const message = JSON.parse(line);
  log({
    event: message.method ? "request" : "response",
    method: message.method ?? null,
    id: message.id ?? null,
    result: message.result ?? null,
  });
  // A probe the MC is still waiting on: its first request never answers.
  if (control.hangInitialize === true && message.method === "initialize") return;
  void acp.receive(message);
});
lines.on("close", () => process.exit(0));
