# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (thread.updated, thread.removed, project.updated,
#     project.removed, shell and thread projection schemas)
#   packages/contracts/src/rpc.ts (orchestration.getThreadProjection, orchestration.subscribeShell,
#     orchestration.subscribeThread, orchestration.subscribeArchivedShell,
#     orchestration.getArchivedShellSnapshot)
#   apps/server-ex/lib/hal_c2/projection/shell.ex, thread_error.ex, background_work.ex, timeline.ex
#   apps/server-ex/lib/hal_c2/orchestration.ex (getArchivedShellSnapshot)
#   apps/server-ex/lib/hal_c2/streams/view.ex (windows and pages of a thread)
#   apps/server/src/orchestration-v2/ (projector, shell and thread projections)
#   apps/server/src/orchestration-v2/threadHistoryPaging.ts, ProjectionStore.ts (page sizes, cursors,
#     what a bounded snapshot keeps), WireProjection.ts (what is left off the wire),
#     ShellStream.ts (repository details after the first shell snapshot)
#   apps/server/src/orchestration-v2/testkit/fixtures/queued_cancelled_while_active (shell row beside a
#     cancelled latest run)
Feature: What the engine projects for clients
  Clients render projections, not raw entities. A thread's shell row summarizes
  it for lists without message bodies; its timeline decides which items show.

  Background:
    Given an MC with a project "demo"
    And thread "t1" exists in "demo"

  @mc
  Scenario Outline: The shell row status follows the latest run
    Given the latest run of "t1" is <status>
    Then the shell row of "t1" has status "<status>"

    Examples:
      | status      |
      | queued      |
      | running     |
      | waiting     |
      | completed   |
      | failed      |
      | interrupted |
      | cancelled   |
      | rolled_back |

  @mc
  Scenario: A thread with no runs is idle
    Then the shell row of "t1" has status "idle"

  @mc
  Scenario: The active run is the latest one preparing, starting or running
    Given run 2 of "t1" is running
    Then the shell row names run 2 as the active run and its activity status is running

  @mc
  Scenario: A waiting run is activity but not an interruptible active run
    Given run 2 of "t1" is waiting
    Then the shell row has no active run
    And its activity status is waiting

  @backlog @mc
  Scenario: A cancelled queued run does not hide the run still running before it
    Given run 1 of "t1" is running and run 2 was queued behind it
    When run 2 is cancelled before it starts
    Then the shell row of "t1" has status "cancelled" because run 2 is the latest run
    And the shell row names run 1 as the active run and its activity status is running
    And the activity start time is the start of run 1

  @mc
  Scenario: A pending request shows on the shell row
    Given the provider asked for approval of a command in "t1"
    Then the shell row of "t1" shows the pending request's id, kind and time

  @mc
  Scenario: Shell rows never carry message bodies
    Given "t1" has a long conversation
    Then the shell row of "t1" has no latest visible message text
    And it records when the latest user message was sent

  @mc
  Scenario: A thread with an active proposed plan is marked actionable
    Given "t1" has an active proposed plan
    Then the shell row of "t1" has an actionable proposed plan
    And the mark clears when the plan is completed

  @mc
  Scenario: Background work that outlives a turn is listed
    Given the latest run of "t1" completed while a background command kept running
    Then the shell row of "t1" lists that background task

  @mc
  Scenario: No background work is listed while a foreground run is active
    Given run 2 of "t1" is running and a background command from run 1 is still active
    Then the shell row of "t1" lists no background tasks

  @mc
  Scenario: Background work stays with the run that started it
    Given run 1 of "t1" started a background shell command
    When run 2 of "t1" starts
    Then the command stays attached to run 1
    And its completion cannot finish run 2

  @mc
  Scenario: A rolled-back latest run abandons its background work
    Given the latest run of "t1" was rolled back while a background command ran
    Then the shell row of "t1" lists no background tasks

  @mc
  Scenario: The thread error comes from the failed root turn of the latest run
    Given the latest run of "t1" failed with a usage limit error that resets at 15:00
    Then the shell row of "t1" shows that error, its class and the reset time

  @mc
  Scenario: A different provider session error supersedes the classification
    Given the latest run of "t1" failed and the provider session reports a different error
    # A distinct session error carries no class; both servers drop the turn's classification.
    Then the shell row of "t1" shows the session's error without the turn's classification

  @mc
  Scenario: An error from an earlier run is not shown after a later run succeeds
    Given run 1 of "t1" failed and run 2 completed
    Then the shell row of "t1" shows no error

  @mc
  Scenario: Provider history lists the instances that owned the root conversation
    Given "t1" ran on "codex" and then "claudeAgent", and delegated a task to "opencode"
    Then the provider history of "t1" is "codex", "claudeAgent"

  @mc
  Scenario: A fork counts its source's history among its visible items
    Given "f1" is a fork of "t1" after 10 items and has 3 items of its own
    Then the shell row of "f1" counts 3 own items and more than 10 visible items

  @mc
  Scenario Outline: The timeline hides items that no longer belong to the conversation
    Given "t1" has <items>
    When a client reads the timeline of "t1"
    Then those items are not shown

    Examples:
      | items                                                      |
      | items of a rolled-back run                                  |
      | a queued message whose run was cancelled                    |
      | an unpaired interrupt result of a superseded attempt        |

  @mc
  Scenario: A legacy model selection naming a provider is shown with an instance id
    Given "t1" was stored with a model selection that names provider "codex"
    Then the shell row of "t1" shows instance "codex" and the model

  @mc
  Scenario: The archived shell snapshot lists archived threads and their projects
    Given "t1" is archived and "t2" is active and "t3" is archived and deleted
    When a client asks for the archived shell snapshot
    Then it contains "t1" and project "demo"
    And it does not contain "t2" or "t3"

  @mc
  Scenario: The shell row's activity time is the time of the thread's latest event
    Given the latest event on "t1" happened at 10:00
    Then the shell row of "t1" was updated at 10:00

  # The MC answers this with hal-c2.threadRows; orchestration.getThreadProjection itself
  # is refused below (parity/rpc.feature).
  @mc
  Scenario: A client reads a thread's full projection with one request
    Given "t1" has a finished run with a message, an item, a plan, a checkpoint and a pending request
    When a client asks for the projection of "t1"
    Then it receives the thread, its runs, items, messages, plans, checkpoints and requests
    And it receives the sequence the projection is at

  # A client bounds a thread by subscribing with a window (HalC2.Streams.View); without
  # one it is sent the whole thread, as the legacy clients expect.
  @mc
  Scenario: Subscribing to a thread with a window sends a bounded snapshot and then live events
    Given "t1" has a very long history
    When a client subscribes to "t1" with a window
    Then it receives the newest part of the history with a marker that older history exists
    And it can page older history on request
    And then it receives live events after the snapshot's sequence

  @mc
  Scenario: A bounded page of history holds only visible turns
    Given "t1" has hidden and visible earlier turns
    When a client asks for a bounded page of the history of "t1"
    Then the page holds only visible turns
    And it ends at the true start of the history

  @mc @backlog
  Scenario: A bounded snapshot holds the newest 10 user turns and older pages hold 20
    Given "t1" has 60 user turns
    When a client asks for a bounded snapshot of "t1"
    Then it receives the newest 10 user turns and a cursor for older history
    When it asks for the page before that cursor
    Then it receives the 20 user turns before them

  @mc @backlog
  Scenario: A page of history never splits a turn
    Given an earlier turn of "t1" ran hundreds of tool calls and was steered twice
    When a client pages back to that turn
    Then the page holds the whole turn, from the user's message to its last item
    And the steering messages do not count as turns of their own

  @mc @backlog
  Scenario: Automatic turns cannot make a page of history unbounded
    Given "t1" has hundreds of turns started by background work between two user messages
    When a client asks for a bounded page of the history of "t1"
    Then the page holds at most 150 turns of any kind

  @mc @backlog
  Scenario: History that records no turn starts is paged by items and size
    Given "t1" holds imported history that records no turn starts
    When a client asks for a bounded page of the history of "t1"
    Then the page holds at most 75 items and about one megabyte
    And it holds at least one item, however large that item is

  @mc @backlog
  Scenario Outline: A history cursor the MC cannot use is refused
    When a client asks for older history of "t1" with <cursor>
    Then the request fails as an invalid history cursor

    Examples:
      | cursor                                |
      | an empty cursor                       |
      | a cursor the MC never gave            |
      | a cursor longer than 4,096 characters |

  @mc @backlog
  Scenario: A history cursor stays valid while the thread grows
    Given a client holds a cursor into the history of "t1"
    When "t1" gains new turns
    And the client asks for the page before that cursor
    Then it receives the same older turns as before, with none skipped or repeated

  @mc @backlog
  Scenario: A history cursor whose item is gone resumes from where the item was
    Given a client holds a cursor into the history of "t1"
    And the item the cursor names has since left the timeline
    When the client asks for the page before that cursor
    Then it receives the turns before the position the cursor recorded

  @mc @backlog
  Scenario: A bounded snapshot keeps everything the user can still act on
    Given "t1" has a very long history
    And an active proposed plan, a pending handoff, a pending approval and a queued message are older than its newest turns
    When a client asks for a bounded snapshot of "t1"
    Then the snapshot still carries the plan, the handoff, the approval and the queued message

  @mc @backlog
  Scenario: Finished plans and handoffs in a bounded snapshot carry only their status
    Given the newest turns of "t1" include a completed plan and a finished handoff
    When a client asks for a bounded snapshot of "t1"
    Then each carries its status and says its detail is in its timeline item
    And neither carries the plan text or the handoff summary a second time

  @mc @backlog
  Scenario: A bounded snapshot says when it could not stay within its size budget
    Given what the user can still act on in "t1" is larger than one megabyte
    When a client asks for a bounded snapshot of "t1"
    Then nothing the user can act on is left out
    And the snapshot is marked as over its payload budget

  @mc @backlog
  Scenario Outline: Bulky item bodies are left out of what a thread subscriber is sent
    Given "t1" has <item>
    When a client reads or follows "t1"
    Then the item arrives without <left out>
    And it still carries <kept>

    Examples:
      | item                                  | left out                               | kept                                           |
      | a command that printed a long output  | the output                             | the command and its exit code                  |
      | a file change                         | the before and after text and the diff | the file and its change counts                 |
      | a call to a tool the provider defined | the tool's raw output                  | the ids the result named and whether it failed |
      | a handoff to another provider         | the handoff summary                    | the providers and models it went between       |

  @mc @backlog
  Scenario: A command whose output shows a failure is still sent as failed
    Given a command in "t1" exited with code 0 but its output reports an error
    When a client reads or follows "t1"
    Then the command arrives without its output
    And it is marked as having failed

  @mc @backlog
  Scenario: Long subagent text is cut for transport and says so
    Given a subagent in "t1" has a prompt, progress or result longer than 32,768 bytes
    When a client reads or follows "t1"
    Then the text is cut at 32,768 bytes without splitting a character
    And it ends with "… output truncated for transport"

  @mc @backlog
  Scenario: A large tool input is sent as its first line
    Given a call to a provider-defined tool in "t1" has an input larger than 16,384 bytes
    When a client reads or follows "t1"
    Then the input arrives as its first non-blank line, cut to 160 characters, marked truncated
    And a smaller input arrives unchanged

  @mc @backlog
  Scenario: A context handoff is sent without the transcript it carries
    Given "t1" was handed off with its conversation history and a summary
    When a client reads or follows "t1"
    Then the handoff arrives with its status
    And without the history, the delivery record or the summary text

  @mc @backlog
  Scenario: What is left off the wire stays in the stored thread
    Given "t1" has a file change whose diff was not sent to subscribers
    When a client asks for that change's diff
    Then it receives the full diff
    And the stored command outputs, tool results and handoff transcripts are unchanged

  @mc @backlog
  Scenario: The first shell snapshot does not wait for repository lookups
    Given project "demo" has a repository whose identity is not resolved yet
    When a client subscribes to the shell
    Then it receives every project and thread row at once
    And the repository details of "demo" follow as an update that carries no thread rows

  @mc @backlog
  Scenario: A client that already holds a shell snapshot is not sent the rows again
    Given a client loaded the shell snapshot before connecting
    When it subscribes to the shell after that snapshot's sequence
    Then it receives only what changed since and the repository details that have resolved
    And it is not sent the full list of rows again

  @mc @backlog
  Scenario: An unchanged repository refresh is not sent twice
    Given a client is subscribed to the shell
    When the repository details of "demo" are refreshed and nothing changed
    Then the client receives no second update for "demo"

  @mc
  Scenario: Subscribing after a known sequence replays only what was missed
    Given a client saw "t1" up to sequence 40
    When it subscribes to "t1" after sequence 40
    Then it receives only events after 40 and a completion marker

  # Dropped with a reason in parity/rpc.feature: no client subscribes to
  # orchestration.subscribeArchivedShell; archived threads come from getArchivedShellSnapshot.
  @mc @dropped
  Scenario: Subscribing to the archived shell streams archive changes
    When a client subscribes to the archived shell
    And "t1" is archived
    Then the subscriber receives the archived row for "t1"

  @mc
  Scenario: Methods the MC does not serve are refused by name
    When a client calls "orchestration.getThreadProjection"
    Then it fails with "orchestration.getThreadProjection is not served by this MC yet"
