# Glossary

Terms whose meaning matters across HAL-C2. Architecture and lifecycle constraints belong in the
[overview](./overview.md), not in these definitions.

## Workspace and conversation

| Term           | Meaning                                                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Environment    | One running MC and the machine, credentials, workspace access, and state it owns.                                                                                              |
| Client         | A desktop, phone, or terminal UI connected to an environment.                                                                                                                  |
| Project        | An environment-local workspace record rooted at a directory.                                                                                                                   |
| Workspace root | The project's base filesystem directory on the environment.                                                                                                                    |
| Worktree       | A separate Git checkout a thread can use instead of the project's main checkout.                                                                                               |
| Thread         | The durable conversation and work history for a project. It survives provider process exits.                                                                                   |
| Turn           | One user-to-agent work cycle. Provider work can finish before checkpoint and diff work settles.                                                                                |
| Activity       | A non-message timeline item, such as a tool action, approval, or failure.                                                                                                      |
| HAL-C2 home    | Where an environment keeps its files: XDG config, data, state, and cache directories named `hal-c2`, or all four under one root (`$HAL_C2_HOME`). See [storage](./storage.md). |

## Orchestration

Parking a thread means settling or snoozing it to move it out of active work.

| Term            | Meaning                                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Command         | A request to change domain state. Accepting it does not mean its side effects have finished.                                   |
| Stream          | A project or a thread: the unit with its own event log and live state on the MC, addressed by its string id.                   |
| Patch / event   | A persisted change to one entity of a stream. Its `seq` is the MC-wide offset clients resume from.                             |
| Projection      | The state of a stream folded from its patches, or a view derived from it for the sidebar or a client. Snapshots cache it.      |
| Handle / window | What a client's copy of a thread is a copy of, and how much of it the client holds. See [sync](./sync.md).                     |
| Command receipt | A durable record of a command's result in the store, used to make retries idempotent.                                          |
| Runtime         | The module that runs one provider's sessions and writes their turns into the thread's log.                                     |
| Settlement      | An MC deciding, without a client, that a thread needs nobody any more (`thread.auto-settle`) and moving it out of active work. |

## Providers and checkpoints

| Term                | Meaning                                                                                                      |
| ------------------- | ------------------------------------------------------------------------------------------------------------ |
| Provider            | The agent runtime HAL-C2 controls, such as Codex or Claude Code.                                             |
| Provider instance   | One configured provider, with its own settings and lifecycle. Several instances can share one provider kind. |
| Session             | The provider runtime attached to a thread. A session can be stopped and resumed without deleting the thread. |
| Runtime mode        | The thread's permission policy. See [permission modes](../user/permission-modes.md).                         |
| Interaction mode    | How the agent approaches the task, such as planning. Separate from permission policy.                        |
| Checkpoint          | A saved workspace state used for diffs and restore, stored as a hidden Git ref.                              |
| Checkpoint baseline | The workspace state captured before the work being compared.                                                 |
| Turn diff           | The workspace changes attributed to one turn.                                                                |

## Pull requests

| Term                 | Meaning                                                                                                                                                                                  |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pull request link    | A persisted thread association identified by host, repository, and number. Links can cross projects within an environment and carry a server-maintained snapshot.                        |
| Pull request sync    | The MC process that refreshes each distinct linked review once per cadence and discovers native stack layers. Explicit refreshes and failed stack reads trigger another read.            |
| Current pull request | The link used by single-review controls and older clients. Open work takes precedence; a completed single chain points at its top layer. Unrelated terminal links use the latest update. |

## Composer context

| Term                 | Meaning                                                                                                                                 |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Context record       | The typed payload behind a composer chip, keyed by `contextId` in `message.context.records`. It never holds bytes.                      |
| Context reference    | One occurrence of a record in message text: `[label](hal-c2-context://v1/<kind>/<contextId>)`. Several references can share one record. |
| Attachment binding   | The link from an image or file record to its server-owned attachment. Its attachment ID can change without changing `contextId`.        |
| Attachment inventory | The ordered image records shown as thumbnails above the prose, including images with no inline references.                              |

See [composer context references](./composer-context-references.md) for the contract and lifecycle.
