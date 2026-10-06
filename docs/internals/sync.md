# Sync

> For maintainers. The wire format is in
> [`protocol.ex`](../../apps/server-ex/lib/hal_c2/web/protocol.ex); the behaviour is specified in
> [websocket-protocol.feature](../../features/mc/platform/websocket-protocol.feature) and
> [projections.feature](../../features/mc/orchestration/projections.feature). This page records
> why sync works the way it does.

A client is on a phone as often as on a desk, and the MC it talks to is often one cluster hop from
the thread it reads. Both links are slow enough that the rule is: **nobody is sent what it already
holds.** Every copy of MC state (a client's copy of a thread, a client's copy of the sidebar, one
MC's copy of another's sidebar rows) says what it holds and is sent the difference.

The model is Electric's shapes: a client subscribes to a shape and keeps it in sync from an
offset. We do not use Electric or `phoenix_sync` themselves. They replicate Postgres tables, and
an MC is one SQLite file per machine whose log is already the unit of sync.

## A thread: handle, offset, window

A client that keeps a thread keeps three things with it.

- **Offset**: the seq of the last event it applied. Seqs count every event in one MC's store, so
  an offset means nothing in another store.
- **Handle**: names the store the offset came from and the trimming rules
  ([`wire.ex`](../../apps/server-ex/lib/hal_c2/web/wire.ex)) its entities were sent under. A
  thread that moved to another machine, or an MC whose trimming changed, has another handle, and
  the client starts over. Without the handle a kept offset would be replayed against a log it did
  not come from. Change `Wire.version/0` whenever trimming changes what a client stores.
- **Window**: a long thread opens as its newest runs. The window's floor is a run ordinal; turn
  items, messages and nodes of earlier runs are not held, everything else is. Earlier runs arrive
  as pages when the client asks.

The view a client holds ([`view.ex`](../../apps/server-ex/lib/hal_c2/streams/view.ex)) also filters
events, on the MC that owns the thread. A patch only means something against the entity it
changes, so a client must never be sent a patch to an entity outside its view. Any new way of
leaving entities out has to go through the view for that reason, not through the socket.

### Catching up never falls back to the whole thread

A client behind by a few events is replayed the log. A client behind by thousands is not sent a
snapshot: the stream records the seq of each entity's latest change, and the client is sent one
event replacing each entity changed since its offset. That costs what changed, not the length of
the log or of the thread. A snapshot is left for a client with nothing, or with another handle.

The record of changes starts where a stream was last folded from scratch (`since`). State
snapshots written before the record existed carry none, so a client behind such a snapshot starts
over once. Deletions are remembered up to a bound, past which `since` moves up; that is the only
way a long-lived stream forgets.

A catch-up merged per entity only makes sense whole. Its frames carry the offset the client is at
after applying them, which only the last frame moves. Clients store the frame's offset, never a
seq read out of the events.

### Trimming belongs to the thread's MC

Command output and file diffs are the bulk of a thread and no client shows them. They are trimmed
on the MC that owns the thread, once for every client and before the cluster hop. Trimming in the
socket would carry them across to the MC the client is connected to and drop them there.

A subscriber on another MC is fed through its own relay process, so a slow link stalls only that
subscriber. Everything it is sent goes through the relay, pages included: a page is the thread as
of a seq, and one that overtook the events before it would have them applied twice.

## The sidebar: versions

Each MC counts the changes to its own rows. A copy of its rows is "as of `{epoch, rev}`", and
whoever holds one (a client, or a peer MC) asks for the rows after it.

The epoch names one run of the MC's shell process, and the count lives in memory. An MC that
restarts therefore sends its rows whole, once, to its peers and to clients. Keeping the count in
the store would avoid that, but needs a column older MCs do not write, so a downgrade and upgrade
would hand out revs a client had already passed. We chose the occasional resend over a store
older MCs must refuse to open.

A row deleted from the sidebar stays a row (`deletedAt`), so "the rows after rev" needs no
separate record of deletions.

## What the cluster does not do

Threads are not replicated between MCs. A thread lives on one machine and is read through
whichever MC the client reached. The slow link is client to MC, not MC to MC, so a second copy
would add a consistency problem to save little. Moving a thread is a different operation
(`features/threads/moving-between-machines.feature`).

## Clients

Everything above is opt-in per subscription, so the protocol stays version 3.

The Qt client (desktop, and the QML mobile client built from the same `src/native`) keeps the
sidebar and the threads the user opened in a local SQLite cache, paints from it before the socket
is up, and subscribes with what it holds. Its rules are in
[desktop-qt.md](./desktop-qt.md#client-cache).

The TypeScript clients (`packages/client-runtime/src/v3`: the TUI and the legacy web and mobile
apps) send no handle, window, kinds or sidebar version. They are sent whole threads and the whole
sidebar as before, and resume a dropped socket from an in-memory offset. They do benefit from the
catch-up no longer falling back to a snapshot. Giving the TUI a cache means seeding its fold from
kept entities first: a patch needs the entity it changes.
