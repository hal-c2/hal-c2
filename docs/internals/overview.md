# Architecture

HAL-C2 keeps execution in the environment that owns the workspace. The Qt desktop, the phone client,
and the TUI control it over authenticated RPC. A remote client must never substitute its own
filesystem, provider credentials, or machine state for the environment's. The desktop launches a
local MC when none is running, but its UI follows the same boundary.

## Ownership boundaries

Provider processes, terminals, Git, and project files belong to the MC. Clients supply platform
services and UI; the rules for reconnecting and for several environments are written once per
client runtime, see [connection runtime](./connection-runtime.md) and
[remote environments](./remote.md).

The [RPC contract](../../packages/contracts/src/rpc.ts) is the boundary between independently
versioned clients and MCs. Subscriptions send the state a client needs, so a client viewing one
thread does not pay for every thread's history ([sync](./sync.md)). Authentication of a socket does
not authorize every method on it. See [environment auth](./environment-auth.md).

### Pull request linking compatibility

Clients and environments upgrade independently. Negotiate linking through the environment
descriptor, never through a client version or an assumed coordinated release:

| Environment capability                | Client behavior                                                                                                   |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `threadPullRequests: true`            | Use persisted `pullRequests[]`, multi-link commands, stack UI, and reverse thread lookup.                         |
| Only `threadPullRequestLinking: true` | Use `linkedPullRequest` and the existing `thread.meta.update` single-link operation. Do not call multi-link RPCs. |
| Neither flag                          | Hide linking actions; existing branch-discovered PR display remains available.                                    |

MCs advertise the legacy flag, accept legacy metadata commands, and emit the derived
`linkedPullRequest` field for older clients. That hostless field includes only
links in the thread project's own repository; cross-host and cross-repository links require the
multi-link protocol. Clients accept snapshots that omit `pullRequests`. Retain the legacy wire
fields and replay support; this feature does not schedule their removal. Missing new capabilities
must also override cached multi-link data after an environment downgrade.

Provider-specific behavior belongs behind a runtime. Orchestration works with normalized commands
and events, so adding a provider should not require branches throughout the domain or clients.
See [provider constraints](./providers.md).

## Settings ownership

Client preferences stay in the current client; environment defaults and project overrides stay
on their owning server. The settings target is resolved against current connections and project
membership. An unavailable target must not fall back to another environment.
**All environments** is an explicit bulk edit of connected, loaded servers, not a durable global
default or a promise to synchronize offline or future environments. Project-group targets similarly
select known environment-local checkouts; the group itself does not store inherited defaults.

## Durable intent and side effects

The event log is the source of truth ([`HalC2.Store`](../../apps/server-ex/lib/hal_c2/store.ex)).
A _stream_ is a project or a thread, and every event is a `HalC2.Patch` to one entity of it. One
process per active stream ([`HalC2.Streams`](../../apps/server-ex/lib/hal_c2/streams.ex)) folds
patches into its state, appends them to the log, and only then sends them to its subscribers, so
no client sees a change the log lacks. Snapshots are a cache that can be rebuilt from events.

A command's acknowledgement means its intent committed, not that the provider, checkpoint, or
other follow-up work finished. Command receipts are kept in the store's meta table so a retried
command is answered rather than run twice. Keep external I/O out of the step that decides and
commits a change. Provider runtimes stream their turns back into the log afterwards
([`TurnWriter`](../../apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex)), and work tied to
a lost provider process cannot replay: [recovery](./server-updates.md#recovering-interrupted-threads)
ends it before new work is admitted.

Persisted events must remain decodable on replay. Changing the shape of an entity affects old
stores at startup as well as live RPC traffic, and an MC refuses to open a store written by a
newer schema. Compatibility work must account for stored history, not just what the newest client
sends.

## Turn completion and checkpoints

A provider turn ending and its follow-up work settling are separate milestones. A late
checkpoint or diff must not extend the recorded provider duration or keep the client showing
provider work as active. PR discovery after completion also checks that the checkout still matches
the thread's non-default branch and that a newer run is not active.

[Checkpoints](../../apps/server-ex/lib/hal_c2/checkpoint.ex) use hidden Git refs to capture
workspace state without adding commits to the user's branch or touching its staging area. A
[rollback](../../apps/server-ex/lib/hal_c2/orchestration/rollback.ex) must coordinate workspace
state with the provider conversation: a provider that cannot drop turns from its conversation
rejects the operation before the filesystem changes, and a step that fails undoes the ones before
it.

Thread settlement is MC-owned. [`HalC2.Orchestration.Settlement`](../../apps/server-ex/lib/hal_c2/orchestration/settlement.ex)
evaluates PR and inactivity settings without a connected client and re-checks the thread as it
settles, so newer activity wins. Clients render the persisted result; they do not derive
settlement from their own clocks or PR caches.

## Waiting for asynchronous work

Tests wait for a specific persisted event or state (`await_stream` in
`apps/server-ex/test/support`), never for elapsed time. Production behavior must use persisted
state and events, not test instrumentation or assumptions about timing.

See the [glossary](./glossary.md) for shared terms and the
[development runbook](../operations/development.md) for setup and checks.
