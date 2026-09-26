# Threads from older versions

On your first V2 launch, HAL-C2 copies the V1 database, `state.sqlite`, into `statev2.sqlite`
in the same data directory and migrates the copy. Your threads appear automatically, with full
transcripts imported as needed. You do not need to run an import command.

V1 continues using its original database while V2 uses the copy. The database import can run while
V1 is open. Opening V2 again resumes your V2 history. The copy happens only once: later conversations
and changes in either version do not sync to the other. Settings, attachments, and workspace files
remain shared.

The V2 desktop app uses a separate browser profile, so browser cookies and caches do not carry
over from V1. You may need to sign in again to websites opened inside the app.

The migrated thread keeps its title, project, provider and model selection, permission and
interaction modes, branch or worktree, archive state, settlement state, snooze and pin state, and
linked pull request. HAL-C2 also brings over user and assistant messages, their timestamps, and
supported attachments. Large histories may appear in stages while the server imports transcripts.

The migration does not recreate the old provider's live session. It also does not convert old run
records, checkpoints and diffs, tool activity, approval history, or proposed plan history into the
new format. These items may be absent from a migrated timeline even though the conversation text is
present.

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

The Elixir node can write one thread to a file and read it on another machine, for machines that
are not in one cluster:

```sh
mix hal_c2.thread.export "Fix the cart" alpha.hal-c2-thread
mix hal_c2.thread.import alpha.hal-c2-thread --project shop
```

The file carries the conversation, attachments, terminal scrollback, checkpoints and, when the
provider can carry it, the agent's own session. Exporting leaves the thread where it was. Without
`--project`, the thread goes into the one project that is a checkout of the same repository; if
there are several or none, name one. Checkpoints only come along into a checkout of the same
repository. A file from the previous server imports too, and its next message hands the
conversation over as a provider switch does. Nothing is imported from a damaged file.

## Keeping a recovery copy

The previous server does not have a whole-thread export command. Before a major server update, stop
the server and copy its [data directory](./install.md#where-hal-c2-keeps-its-files) to a safe
location. The default is `~/.local/share/hal-c2`; a server started with `--base-dir <path>` uses
`<path>/data`. The V1 database is the `state.sqlite` in it.

If a migrated transcript is missing from the app, keep that copy unchanged. You can inspect the
old transcript without starting a server against it:

```sh
sqlite3 -readonly /path/to/recovery-copy/state.sqlite
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

Open only the copied database. Do not edit it or point a newer or older server at your recovery
copy. If the affected environment is remote, make and inspect the copy on the machine that runs
that environment.
