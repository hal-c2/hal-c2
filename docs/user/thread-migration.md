# Threads from older versions

Threads from T3 Code or an earlier HAL-C2 come across in two ways, both described in
[Coming from T3 Code](./install.md#coming-from-t3-code): the first start with no data
of its own copies them, and `threads import` picks more later. You do not need to
convert anything by hand.

The old install is only read, never changed. Later conversations and changes in either
app do not sync to the other. A thread you import twice is not duplicated; HAL-C2 tells
you it is already there.

A migrated thread keeps its title, project, provider and model selection, permission and
interaction modes, branch or worktree, archive state, settlement state, snooze and pin
state, and linked pull request. HAL-C2 also brings over user and assistant messages,
their timestamps, and supported attachments. A thread picked with `threads import` also
brings its subagent threads and terminal scrollback, and joins the project already at
its folder.

The migration does not recreate the old provider's live session. It also does not
convert old run records, checkpoints and diffs, tool activity, approval history, or
proposed plan history into the new format. These items may be absent from a migrated
timeline even though the conversation text is present.

## Continuing a migrated thread

The first new message starts a fresh provider session. HAL-C2 selects intact user and assistant
messages using the same [handoff budget](./portable-handoffs.md) as a provider switch. Omitted text
remains in the thread and can be retrieved by the agent. The migration retains its separate
32,000-character recovery excerpt; neither that excerpt nor the handoff replaces the full imported
transcript.

Before continuing a long or important thread, read the recent transcript and include any older
requirements the agent still needs in your next message. Starting a new thread and pasting a short
handoff is also a good choice when the old conversation contains conflicting instructions.

## Copying a thread to another machine

The MC can write one thread to a file and read it on another machine, for machines that
are not in one cluster:

```sh
mix hal_c2.thread.export "Fix the cart" alpha.hal-c2-thread
mix hal_c2.thread.import alpha.hal-c2-thread --project shop
```

The file carries the conversation, attachments, terminal scrollback, checkpoints and, when the
provider can carry it, the agent's own session. Exporting leaves the thread where it was. Without
`--project`, the thread goes into the one project that is a checkout of the same repository; if
there are several or none, name one. Checkpoints only come along into a checkout of the same
repository. A thread archive from an earlier install imports too, and its next message hands
the conversation over as a provider switch does. Nothing is imported from a damaged file.

## Looking at the old transcript

Your old install's data directory is untouched, so it is already your recovery copy:
`~/.t3/userdata` for T3 Code, or the [data directory](./install.md#where-hal-c2-keeps-its-files)
of an earlier HAL-C2. If a migrated transcript is missing from the app, keep that
directory unchanged. You can inspect the old transcript without starting a server
against it:

```sh
sqlite3 -readonly /path/to/old-data/state.sqlite
```

At the SQLite prompt, list recent legacy threads:

```sql
.headers on
.mode tabs
SELECT thread_id, title, updated_at
FROM projection_threads
ORDER BY updated_at DESC;
```

Then print one transcript, replacing `<thread-id>` with the value from the first query:

```sql
SELECT role, text, created_at
FROM projection_thread_messages
WHERE thread_id = '<thread-id>'
  AND role IN ('user', 'assistant')
ORDER BY created_at, message_id;
```

Open the database read-only and do not edit it. If a server is still running on it,
make the copy first with `VACUUM INTO` so you read a consistent file. If the affected
environment is remote, do this on the machine that runs that environment.
