# Legacy orchestration migration

Threads from the Node server's version 1 orchestrator reach the MC through
[`HalC2.Import.PreviousInstall`](../../apps/server-ex/lib/hal_c2/import/previous_install.ex)
(`mix hal_c2.import`, and the picker in the clients). The source database (`state.sqlite` or
`statev2.sqlite`) is opened read-only, so whatever still runs on it is undisturbed. A thread that
was logged only as version 1 events is folded by
[`HalC2.Import.V1Thread`](../../apps/server-ex/lib/hal_c2/import/v1_thread.ex); the user guide
for it is [threads from older versions](../user/thread-migration.md).

## Imported data

The thread keeps its identifier, title, provider and model selection, runtime and interaction
modes, branch, worktree path, creation, update, archive and delete times, and its user and
assistant messages with their timestamps and ordering. A message that was still streaming becomes
an interrupted turn item.

The importer does not translate provider session identity, native provider runs, activities and
tool calls, approvals, or proposed plans, so the MC must not present those records as migrated
history. Checkpoints are refs in the project's repository, so they need no copying.

## First continuation

A migrated thread has no active provider thread. Until one of its runs completes, a run that
starts a provider thread sends that conversation as imported history: the newest part of the
transcript that fits in 32,000 characters
([`HalC2.Orchestration.Handoff`](../../apps/server-ex/lib/hal_c2/orchestration/handoff.ex)).
This budget is separate from portable provider handoffs.

## Client and MC cutover

Clients and MCs must agree on the protocol version (`HalC2.Web.Protocol.version/0`, currently 3).
A client names the protocol it speaks with `?protocol=` on the socket URL, and the MC answers a
mismatch with HTTP 426 (`protocol_incompatible`) naming the side to update, before any RPC or
auth work runs. The environment descriptor carries `orchestrationProtocolVersion` for clients that
check before connecting. Either direction blocks the connection with a message naming the machine
to update rather than running half-upgraded.
