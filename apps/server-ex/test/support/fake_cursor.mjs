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
log({ event: "launch", mode, env: { CURSOR_API_KEY: process.env.CURSOR_API_KEY ?? null } });

const authError = () => Object.assign(new Error("Unauthorized"), { auth: true });
const refused = (key) => control.revoked === true || key === "revoked";

const store = {
  load: async () => {
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
    settingSources: options.local?.settingSources ?? null,
  });
  return {
    agentId,
    close: () => {},
    send: async (message, sendOptions) => {
      log({
        event: "send",
        agentId,
        message,
        model: sendOptions.model,
        mode: sendOptions.mode ?? null,
      });
      let cancel;
      const cancelled = new Promise((resolve) => (cancel = resolve));
      const say = (text) => sendOptions.onDelta({ update: { type: "text-delta", text } });
      const keys = /Return a JSON object with keys?: ([A-Za-z, ]+)\./.exec(message);
      return {
        cancel: async () => cancel(),
        wait: async () => {
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
  write: (message) => process.stdout.write(`${JSON.stringify(message)}\n`),
  sdk: {
    version: "1.0.31",
    store,
    envApiKey: process.env.CURSOR_API_KEY?.trim() || undefined,
    createAgent: async (options) => makeAgent(options),
    resumeAgent: async (agentId, options) => makeAgent(options, agentId),
    listModels: async (key) => {
      if (refused(key)) throw authError();
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
  void acp.receive(message);
});
lines.on("close", () => process.exit(0));
