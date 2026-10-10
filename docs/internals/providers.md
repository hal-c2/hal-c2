# Provider constraints

Orchestration records intent and state without knowing which provider runs a thread. Provider
protocols, account ownership, permissions, and capabilities belong in the per-provider runtimes
(`HalC2.Codex`, `HalC2.Claude`, `HalC2.Pi`, `HalC2.Acp` for Grok, OpenCode, Antigravity and the
other ACP agents) that [`HalC2.Orchestration`](../../apps/server-ex/lib/hal_c2/orchestration.ex)
calls. Normalize there instead of spreading provider checks through the orchestration modules and
clients.

A driver kind identifies an integration; an instance identifies one configuration and account
lifecycle. Route work by instance, so two accounts using the same driver do not share mutable
session or catalog state.

## Process and account isolation

Each OpenCode agent process runs the [HTTP server](../../apps/server-ex/lib/hal_c2/acp/opencode.ex)
`opencode acp --port` offers, on loopback with a password made for that process, for the calls ACP
lacks (forking a session at a user message, reading its messages). Nothing else shares that server.

Pi runs the user's own `pi` install in RPC mode and owns native extension, package, and project
trust discovery. HAL-C2 adds only its MCP bridge extension, so a Pi session behaves as it does in
the Pi TUI. Pi session files back native resume, rewind, and same-instance thread forks, which
use `pi --fork`. See the [runtime](../../apps/server-ex/lib/hal_c2/pi/thread_runtime.ex).

Antigravity separates account profiles per instance while sharing the installed executable across
the environment. Every instance runs with a private Google profile under the MC's `providers/`
directory, and the Google variables in the MC's own environment are removed from the launch
environment, so an instance cannot silently use another account or billing project. See
[`HalC2.Acp.Antigravity`](../../apps/server-ex/lib/hal_c2/acp/antigravity.ex).

The [Antigravity installer](../../apps/server-ex/lib/hal_c2/acp/antigravity/installation.ex)
outlives client connections. One install runs at a time, a cancelled or failed one leaves the
previous runtime active, and removal waits until no session or sign-in uses the runtime. Do not
replace an executable under a running agent.

## Setup must not happen as a health-check side effect

Opening a provider session can start MCP servers, run hooks, or launch a login browser. A probe
therefore reads what an agent offers from `initialize`
([`HalC2.Acp.Auth.methods/1`](../../apps/server-ex/lib/hal_c2/acp/auth.ex)) and does not open a
session. An Antigravity thread never opens the agent's sign-in link either: a missing or expired
login fails the turn and shows the instance as signed out, and sign-in runs from Settings.

[Antigravity sign-in](../../apps/server-ex/lib/hal_c2/acp/antigravity/auth.ex) belongs to the
initiating HAL-C2 auth session. The agent's loopback listener may be on another machine, so a
user pastes the final redirect URL and the MC forwards only the callback for the owned pending
flow. A successful callback page is not proof that authentication finished; a sign-in succeeds
only once a session opens and lists the account's models.

## Provider updates run only through the owning installer

A one-click update is offered only when the resolved executable's location proves which installer
owns it: Homebrew, a global npm prefix, or Claude Code's own `claude update`. Anything unproven
stays manual-only but still reports the version gap. An update checks that the installer is still
the one the providers were last reported with, and afterwards that the provider is no longer
behind. See [`HalC2.ProviderUpdates`](../../apps/server-ex/lib/hal_c2/provider_updates.ex).

## Protocol traps

Codex async questions arrive as notifications and are answered with a new user message. There is
no pending RPC response to send. The runtime persists them as `user_input_request` turn items and
runtime requests with `responseCapability: { type: "message" }`
([`TurnWriter`](../../apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex)). Their execution
nodes do not block the run, and requests remain pending after a turn finishes, a provider exits,
or the MC restarts. Do not infer that a request has disappeared merely because it is outside the
recent history window.

Capabilities must describe what the provider can actually do. Antigravity can capture workspace
checkpoints but cannot roll back its conversation. The [checkpoint boundary](./overview.md#turn-completion-and-checkpoints)
therefore rejects revert before touching files. Native permission and question option IDs must
also survive normalization; a display label is not necessarily a valid reply.

## Attachments

Attachments live outside the project workspace. [`HalC2.Attachments`](../../apps/server-ex/lib/hal_c2/attachments.ex)
validates uploads and the thread's MC claims them; runtimes choose native input formats for those
environment-local files. A path in the prompt does not grant filesystem access. Keep provider
sandbox and approval rules in force; copying uploads into the project to bypass them changes that
boundary.

## Provider diagnostics

[`HalC2.ProviderLog`](../../apps/server-ex/lib/hal_c2/provider_log.ex) keeps native event logs
(lifecycle events, responses, failures). Token deltas and duplicate raw frames are filtered before
payloads are copied or redacted. Log payloads have a 64 KiB budget; large or deeply nested
payloads become structural summaries that retain routing identifiers, methods, status, and error
fields. These limits apply to diagnostics; provider event handling is unchanged.

Codex's initialization opts out of `turn/diff/updated`: HAL-C2 derives diffs from checkpoints. The
logger filters those notifications when an older provider still sends them.

Model classification has its own [manifest constraints](./model-manifest.md). Assistant-reference
handling is documented under [citations](./assistant-citations.md).
