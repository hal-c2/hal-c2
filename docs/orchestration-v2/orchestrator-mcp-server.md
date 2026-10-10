# Orchestrator MCP Server

## Purpose

HAL-C2 exposes orchestration through its app-owned MCP endpoint. A provider
agent can use this endpoint to:

- create an app-owned sub-agent on any supported provider instance;
- wait for or poll the sub-agent's durable result;
- cancel an active delegated task; and
- create one or more ordinary top-level HAL-C2 threads;
- list and incrementally read project threads;
- rename threads, regenerate titles, and link or unlink pull requests;
- send or steer follow-up messages; and
- wait for or interrupt ordinary thread runs.

These are HAL-C2 orchestration operations, not provider-native sub-agent APIs.
Delegated tasks always create a HAL-C2 child thread and run. The child receives
only the supplied task prompt, plus an optional role instruction supplied in
the same tool call. Parent conversation history is not copied into the child.

The tools are thin over the same commands the clients send.
[`HalC2.Mcp.Tools`](../../apps/server-ex/lib/hal_c2/mcp/tools.ex) and its area modules own
project-scoped lookup, listing, send-mode selection, wait polling, and interrupt selection, and
call [`HalC2.Orchestration`](../../apps/server-ex/lib/hal_c2/orchestration.ex) for the commands
themselves. [`HalC2.Mcp`](../../apps/server-ex/lib/hal_c2/mcp.ex) only authenticates, routes the
JSON-RPC request, and shapes the response.

## Transport And Authentication

The tools are served at `POST /mcp` on the MC, as JSON-RPC over HTTP (MCP's streamable HTTP
transport, answered with plain JSON):

```text
http://127.0.0.1:<server-port>/mcp
```

The provider-visible server key is `hal-c2`. Follow-up requests must send
`mcp-protocol-version: 2025-06-18`.

When a provider session opens, `HalC2.Mcp.for_agent/2` hands the runtime a bearer credential for
the HAL-C2 thread and the concrete provider instance, so every tool call acts as the thread that
made it. The credential lives in memory only and is not persisted in orchestration state. It lapses
after a day without MCP traffic unless the thread has a run in progress, and is revoked when the
thread's provider session stops. A project turns the whole server off for its threads with
`enableAgentBrowserAccess` in its settings overrides, and then the runtime gets no server.

The tools check what the caller may touch, not a credential capability: a caller sees only threads
of its own project, and changing another thread needs a caller that is itself running.

## Provider Injection

Each runtime projects the same authenticated endpoint into its provider's native MCP
configuration. The token never reaches logs or diagnostics.

- **Codex** gets `mcp_servers.hal-c2` (`url` and `http_headers`) in the config of its thread
  parameters ([`Codex.ThreadRuntime`](../../apps/server-ex/lib/hal_c2/codex/thread_runtime.ex)).
- **Claude** gets an HTTP server in `--mcp-config`, `mcp__hal-c2` in `--allowedTools`, and the
  shared instructions (`priv/mcp_instructions.md`) appended to its system prompt
  ([`Claude.Protocol`](../../apps/server-ex/lib/hal_c2/claude/protocol.ex)).
- **ACP agents** (Grok, OpenCode, Antigravity, registry agents) get it in the `mcpServers` field of
  `session/new`, `session/load` and `session/fork`, and only when the agent advertises HTTP MCP
  support ([`Acp.ThreadRuntime`](../../apps/server-ex/lib/hal_c2/acp/thread_runtime.ex)).
  ACP does not define native subagents or active steering, so these providers use
  orchestrator-owned child threads, and steering is cancel-and-restart.
- **Pi** has no MCP client. When a credential exists, `HalC2.Pi.launch/2` writes the HAL-C2 bridge
  extension ([`priv/pi/hal-c2-mcp-extension.ts`](../../apps/server-ex/priv/pi/hal-c2-mcp-extension.ts))
  into the cache directory and starts `pi --mode rpc --extension <cache>/pi-hal-c2-mcp-extension.ts`
  with `HAL_C2_MCP_URL` and `HAL_C2_MCP_BEARER_TOKEN` in its environment. The extension lists the
  endpoint's tools and registers each with `pi.registerTool` under a `mcp__hal-c2__` namespace
  (`mcp__hal-c2__delegate_task` and the rest), calling the original tool name over HTTP.

Pi keeps ownership of native extension discovery. HAL-C2 does not replace Pi's `subagent` tool.
Durable delegation goes through the namespaced `delegate_task` tool and the shared child-thread
lifecycle.

## Provider Support

Capability discovery reports every registered provider instance and marks the ones that cannot run
a child task unavailable, with a model-visible reason such as disabled, missing executable, or
missing authentication. This keeps provider selection visible to the model without allowing a
request that cannot run.

## Tool Surface

This page describes the orchestration tools. The full set the MC advertises is in
`priv/mcp_tools.json` and `priv/mcp_mc_tools.json`, and only the tools `HalC2.Mcp.Tools` implements
are listed to agents.

### `orchestrator_capabilities`

Returns:

- the inherited provider instance and model;
- the parent runtime and interaction modes;
- registered provider instances and advertised models;
- whether each provider can run a child task; and
- feature flags for polling, cancellation, and batch thread creation.

Unavailable providers include model-visible constraints such as disabled state, missing executable, or missing authentication.

### `delegate_task`

Creates a HAL-C2-owned child thread and immediately dispatches the supplied task
prompt.

```ts
type DelegateTaskInput = {
  task: string;
  target?: {
    providerInstanceId?: string;
    driverKind?: string;
    model?: string;
  };
  title?: string;
  role?: "implementation" | "research" | "review" | "design" | "test" | "general";
  mode?: "async" | "wait";
  timeoutMs?: number;
  clientRequestId?: string;
  runtimeMode?: "inherit" | "approval-required" | "auto-accept-edits" | "full-access";
  interactionMode?: "inherit" | "plan" | "default";
};
```

Provider, model, runtime mode, and interaction mode inherit from the parent
when omitted. A driver-only target inherits the parent's provider instance
when it can run child tasks, and otherwise selects an available instance of
that driver; an explicit `providerInstanceId` is honored exactly and fails
when unavailable. Selecting a different provider without a model uses that
provider's first advertised model.

Delegation requires an active parent run owned by the MCP credential's
provider session. The request becomes the
`delegated_task.request` command.

`mode: "async"` returns the current durable state immediately.
`mode: "wait"` waits for the task result, including nested work and completion follow-ups, or until
the timeout expires. A wait timeout does not cancel the child; the result sets
`waitTimedOut: true`, and the caller can continue with `task_status`.

```ts
type DelegateTaskResult = {
  taskId: string;
  childThreadId: string;
  childRunId: string | null;
  childNodeId: string;
  status: "queued" | "running" | "waiting" | "completed" | "failed" | "cancelled" | "interrupted";
  workState: "working" | "waiting_for_children" | "result_available";
  hasPendingChildRuns: boolean;
  providerInstanceId: string;
  model: string | null;
  summary: string | null;
  resultContextTransferId: string | null;
  latestTerminalRunId: string | null;
  latestTerminalStatus: "completed" | "failed" | "cancelled" | "interrupted" | null;
  latestTerminalSummary: string | null;
  latestTerminalResultContextTransferId: string | null;
  waitTimedOut: boolean;
};
```

### `task_status`

Reads a delegated task from the parent thread's durable projection. A task ID
from another parent thread is rejected. `childRunId` identifies the original
run. `workState` distinguishes active work, a finished turn waiting for children,
and an available result. The task remains nonterminal until its known work
finishes. Its published `summary` and result transfer then remain stable across
later follow-ups. `hasPendingChildRuns` reports later queued or executing turns;
`latestTerminal*` exposes later executed, non-monitor results without replacing
the published task result.

### `task_cancel`

Interrupts the currently active task run through the normal `run.interrupt`
command. Native background work between turns currently has no interruptible run. It is idempotent for terminal tasks and accepts an optional cancellation
reason. Use `hal_c2_thread_interrupt` to interrupt a later follow-up run.

### `create_threads`

Creates between one and twenty ordinary top-level HAL-C2 threads:

```ts
type CreateThreadsInput = {
  threads: Array<{
    prompt?: string;
    title?: string;
    target?: {
      providerInstanceId?: string;
      driverKind?: string;
      model?: string;
    };
    runtimeMode?: "inherit" | "approval-required" | "auto-accept-edits" | "full-access";
    interactionMode?: "inherit" | "plan" | "default";
  }>;
  clientRequestId?: string;
};
```

Each entry independently resolves provider, model, and modes. The new threads
inherit the parent's project, branch, and worktree path, but they have no
sub-agent lineage. Entries with a prompt immediately dispatch a run; entries
without a prompt remain idle.

### `hal_c2_thread_launch`

Launches one ordinary top-level thread through the app's launch service. Use an
explicit `workspaceStrategy` to create a new worktree (`worktree` with `baseRef`),
attach an existing checkout (`existing_worktree` with `worktreePath`), or use the
project root (`root`, also the default). The thread is bound to that workspace
before the agent starts. Creating a worktree in the task prompt does not update
this binding.

Pass the task in `message`. Project, model, and modes inherit when omitted;
workspace does not. For stacked PRs, use the parent branch as `baseRef` with
`startFromOrigin: false`. Launch requires a full-access/default caller and has
no retry key, so inspect existing threads after a failed or lost response before
launching again. `create_threads` remains the batch option for a shared checkout.

### `hal_c2_thread_list`

Lists durable thread shells in the calling thread's project, newest first.
Callers can filter by title, run status, and whether app-owned sub-agent threads
are included. Results are bounded and offset-paginated. Deleted threads and
threads from other projects are never exposed.

### `hal_c2_thread_read`

Reads a project-scoped thread's durable state, recent runs, and visible
timeline. The default `messages` view returns user messages, assistant
messages, and proposed plans. The `activity` view also returns summarized tool,
reasoning, checkpoint, handoff, and runtime-request items. Large item text is
bounded and reports whether it was truncated. `afterPosition` and
`nextPosition` support incremental reads.

Thread and message results include required `createdBy` and `creationSource`
provenance. MCP-created threads and user-role messages use `createdBy: "agent"`
and `creationSource: "mcp"`; provider output uses `creationSource: "provider"`.
Actor and ingress are separate so agent-authored user-role messages remain
distinguishable from human-authored messages.

### `hal_c2_thread_update`

Updates metadata for the calling thread or another thread in the same project.
The typed actions are `rename`, `regenerate_title`, `link_pull_request`, and
`unlink_pull_request`. A link input supplies the repository, number, and URL;
the server records the target thread's project ID. Branch and workspace changes
are outside this tool.

The result includes the command ID and durable event sequence together with the
resultant title, title-regeneration marker, and linked pull request. Reusing a
`clientRequestId` for the same action and thread replays the same command
receipt. Thread list and read results expose the linked pull request, and thread
detail also exposes an in-flight title regeneration.

### `hal_c2_thread_send`

Sends a message to an ordinary or delegated thread in the calling project:

- `auto` starts an idle thread, steers a fully active turn, or queues behind a
  turn that is not yet steerable;
- `queue` creates a separate follow-up run after active work;
- `steer` requires a steerable active provider turn; and
- `restart` requires an active provider turn and uses the orchestrator's
  interrupt-and-restart path.

The target runtime and interaction modes may not be broader than the caller's.
Stable command and message IDs are derived from `clientRequestId` for
idempotent retries.

### `hal_c2_thread_wait`

Waits for a selected run to become `completed`, `failed`, `cancelled`,
`interrupted`, or `rolled_back`. Without `runId`, it pins the latest run at call
time; an idle thread returns immediately. A timeout reports the latest durable
status and does not cancel work.

### `hal_c2_thread_interrupt`

Interrupts a selected active run through the normal `run.interrupt` command.
Without `runId`, it selects the newest interruptible run. A terminal run is
returned unchanged, and a thread with no active provider turn returns
`no_active_run`.

## Delegated Task Lifecycle

The MCP server is a command ingress. It does not call provider runtimes directly.

```text
provider model
  -> MCP tools/call delegate_task
  -> authenticated HalC2.Mcp, HalC2.Mcp.Tools
  -> HalC2.Orchestration.Delegation
  -> delegated_task.request command
  -> child thread + child run
  -> parent app_owned subagent projection
  -> parent/child execution nodes
  -> consumed subagent_spawn context transfer
  -> normal provider turn and runtime ingestion
  -> child run reaches a terminal state
  -> parent subagent/node/turn item finalized
  -> consumed subagent_result context transfer
  -> wait result or later task_status result
```

The child thread has lineage relationship `subagent` and points back to the
parent node. The parent gets an `app_owned` sub-agent projection and a
sub-agent turn item so the existing debug UI can render progress.

Terminal provider events trigger finalization. The event stream first replays
persisted events and then follows live events, so finalization also runs after
a server restart. An existing `subagent_result` transfer makes finalization
idempotent.

A failed run exposes its provider error before any progress text. Successful
results use the latest assistant content from the final work turn.

## Policy And Idempotency

- A child runtime mode may stay equal to or become narrower than the parent
  mode. It may not escalate privileges.
- A child interaction mode may stay equal to or narrow from `default` to
  `plan`. It may not escalate from `plan` to `default`.
- General thread management is limited to the calling thread's project. Send
  additionally enforces the same runtime and interaction privilege ceiling as
  child creation.
- Provider instances must be enabled, installed, available, authenticated, and
  backed by a runtime.
- A requested model must be advertised by the selected provider when the
  provider publishes a model list.
- `clientRequestId` derives stable command, thread, and message IDs within the
  provider session. Retrying the same call returns the same durable work.
- Calls without `clientRequestId` receive a generated request key and create
  new work.

Expected denials use the typed `OrchestratorMcpFailure` result:

```text
capability_denied
parent_not_active
provider_unavailable
model_unavailable
runtime_mode_escalation_denied
interaction_mode_escalation_denied
task_not_found
task_not_cancellable
thread_not_found
run_not_found
thread_not_sendable
thread_not_interruptible
invalid_request
orchestration_error
```

## Code Ownership

- Tool schemas and instructions: `apps/server-ex/priv/mcp_tools.json`,
  `mcp_mc_tools.json` and `mcp_instructions.md`
- HTTP endpoint, credentials and routing: `apps/server-ex/lib/hal_c2/mcp.ex`
- Tool handlers: `apps/server-ex/lib/hal_c2/mcp/tools.ex` and `mcp/tools/`
- Provider injection: the runtimes' `thread_runtime.ex` (`codex/`, `claude/`, `acp/`, `pi/`)
- Delegated tasks, command and finalization: `apps/server-ex/lib/hal_c2/orchestration/delegation.ex`

## Verification

The MC's ExUnit tests (`apps/server-ex/test/hal_c2/mcp_test.exs`) call the real endpoint with real
credentials against the real store, with deterministic provider runtimes. The delegation behaviour
is a scenario in `features/mc/orchestration/delegation.feature`; the MCP server's own is under
`features/mc/orchestration/`.
