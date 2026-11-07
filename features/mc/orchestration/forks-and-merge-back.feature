# Sources:
#   https://github.com/pingdotgg/t3code/pull/29572
#   https://github.com/pingdotgg/t3code/pull/24014
#   https://github.com/pingdotgg/t3code/pull/16623
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (thread.fork, thread.merge_back, thread.created,
#     context-transfer.created, context-transfer.updated, context-handoff.updated)
#   apps/server-ex/lib/hal_c2/orchestration/fork.ex
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex
#   apps/server/src/orchestration-v2/ (fork and merge-back transfers)
#   apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts, CodexAdapterV2.ts (native fork points)
#   docs/internals/ (context transfers and handoffs)
#   https://github.com/pingdotgg/t3code/pull/23554
#   https://github.com/pingdotgg/t3code/pull/26901
#   https://github.com/pingdotgg/t3code/pull/29902
Feature: Forking a thread and merging work back
  A fork is a new thread that starts with a copy of its source's history through
  a finished run. Its first run picks the conversation up natively when the
  provider can, or from a transcript. Merging back hands the fork's newer work to
  the parent's next run.

  Background:
    Given an MC with a project "demo"
    And thread "t1" titled "Parser" has completed runs 1 and 2 on "codex"

  @mc
  Scenario: Forking at a run copies history through that run
    When the user forks "t1" at run 1 as "f1"
    Then thread "f1" exists titled "Parser fork"
    And "f1" has a copy of run 1 with its messages, items, plans and checkpoint
    And "f1" does not have run 2

  @mc
  Scenario: Forking records lineage and where it forked from
    When the user forks "t1" at run 2 as "f1"
    Then "f1" names "t1" as its parent with relationship fork
    And "f1" names "t1" as its root thread
    And "f1" records it forked from run 2 of "t1"

  @mc
  Scenario: A fork of a fork keeps the original root
    Given "f1" is a fork of "t1"
    When the user forks "f1" as "f2"
    Then "f2" names "f1" as its parent and "t1" as its root thread

  @mc
  Scenario: Forking with a title uses it
    When the user forks "t1" as "f1" titled "Try a different parser"
    Then thread "f1" is titled "Try a different parser"

  # Upstream #24014: a fork made while its source's title was being generated stayed marked as regenerating forever.
  @mc @backlog
  Scenario: A fork does not inherit its source's title regeneration
    Given the title of "t1" is still being generated
    When the user forks "t1" as "f1"
    Then "f1" is not marked as regenerating its title
    And the user can regenerate the title of "f1"

  @mc
  Scenario: A fork starts unorganized
    Given "t1" is pinned, settled, snoozed, archived and visited
    When the user forks "t1" as "f1"
    Then "f1" is not pinned, settled, snoozed, archived or visited

  # Queued runs are numbered after the running one, so a fork of a finished run never
  # copies them: the fork starts with an empty queue instead of cancelled copies.
  @mc
  Scenario: Messages that were queued in the source stay in the source
    Given "t1" has a queued message after run 2
    When the user forks "t1" at run 2 as "f1"
    Then the fork has no queued message

  @mc
  Scenario: Forking at the latest stable point uses the latest completed run
    Given run 3 of "t1" failed
    When the user forks "t1" at its latest stable point as "f1"
    Then "f1" forked from run 2

  @mc
  Scenario: Forking at a checkpoint uses that checkpoint's run
    When the user forks "t1" at the checkpoint of run 1 as "f1"
    Then "f1" forked from run 1

  @mc
  Scenario: Forking from a run the provider finished before the MC settled it
    Given the provider finished run 3 of "t1" but the MC has not settled it yet
    When the user forks "t1" at run 3 as "f1"
    Then "f1" forked from run 3
    And "f1" has no queued message

  @mc
  Scenario Outline: Forking is refused when there is nothing finished to fork from
    Given <situation>
    When the user forks "t1" at <point> as "f1"
    Then the command fails with "<message>"

    Examples:
      | situation                     | point                   | message                                                  |
      | "t1" has no completed run     | its latest stable point | No stable source run was found.                          |
      | run 3 of "t1" is running      | run 3                   | Run run-3 is running; only finished runs can be used.    |
      | run 3 of "t1" failed          | run 3                   | Run run-3 is failed; only finished runs can be used.     |
      | no checkpoint "cp-x" exists   | checkpoint "cp-x"       | No stable source run was found.                          |

  @mc
  Scenario: Forking an unknown thread is refused
    When the user forks thread "missing" as "f1"
    Then the command fails with "Thread missing was not found."

  @mc
  Scenario: Forking into a thread id that exists is refused
    Given thread "f1" exists
    When the user forks "t1" as "f1"
    Then the command fails with "Thread f1 already exists."

  @mc
  Scenario: A fork keeps its history if the source is deleted
    Given "f1" is a fork of "t1" at run 2
    # "a client deletes" is the thread step; "the user deletes" names a file elsewhere.
    When a client deletes "t1"
    Then "f1" still shows the copied history and its diffs

  # Upstream #16623: a fork keeps its pull request links but does not watch them.
  @backlog @mc
  Scenario: A fork keeps the pull request links but not their watches
    Given a thread is linked to a pull request it watches
    When the user forks the thread
    Then the fork is linked to the pull request
    And the fork does not watch it

  @mc
  Scenario: A fork on the same provider continues the provider's own conversation
    Given "f1" is a fork of "t1" at run 2 on "codex"
    When the user sends "Try again" to "f1" on "codex"
    Then the provider forks its own thread at the turn of run 2
    And the fork transfer is consumed as a native fork

  @mc
  Scenario: A fork on another provider starts from a transcript
    Given "f1" is a fork of "t1" at run 2 on "codex"
    When the user sends "Try again" to "f1" on "claudeAgent"
    Then the provider receives a transcript of the copied history before the message
    And the fork transfer is consumed as portable context with a full thread summary handoff

  @mc
  Scenario: A fork of a provider that cannot fork natively starts from a transcript
    Given "f1" is a fork of "t1" at run 2 on "grok"
    When the user sends "Try again" to "f1"
    Then the provider receives a transcript of the copied history before the message

  # Upstream #26901: a native fork of a running Claude or OpenCode session failed, and a Codex one
  # forked the live session; whether the source runs is checked again when the fork first runs.
  @backlog @mc @priority-high
  Scenario: A fork of a thread that is running starts from a transcript on every provider
    Given "f1" is a fork of "t1" at run 2 on "codex"
    And "t1" is running when "f1" first runs
    When the user sends "Try again" to "f1" on "codex"
    Then the provider receives a transcript of the copied history before the message
    And the fork transfer is consumed as portable context

  # ClaudeAdapterV2.ts resolveClaudeForkCursor, CodexAdapterV2.ts resolveCodexForkBoundary:
  # a native fork needs the provider's own mark for the run it forks at.
  @mc
  Scenario Outline: A native fork whose fork point the provider cannot find fails the fork's first run
    Given "f1" is a fork of "t1" at run 1 on "<provider>"
    And <missing>
    When the user sends "Try again" to "f1" on "<provider>"
    Then the run fails saying the thread cannot be forked from that turn
    And the provider's conversation for "t1" is unchanged

    Examples:
      | provider    | missing                                                        |
      | codex       | run 1's turn is not in the provider's conversation for "t1"    |
      | claudeAgent | the provider recorded no message position for run 1's turn     |

  @mc @plugin-codex
  Scenario: Codex forks at a run it kept no reference for by trimming the later turns
    Given "f1" is a fork of "t1" at run 1 on "codex"
    And the MC holds no Codex turn reference for run 1
    When the user sends "Try again" to "f1" on "codex"
    Then Codex forks the whole conversation and drops the turns after run 1 from the fork
    And the conversation of "t1" keeps every turn

  @mc @plugin-codex
  Scenario: Codex trims a fork whose history is paginated before the first later turn
    Given "f1" is a fork of "t1" at run 1 on "codex"
    And the MC holds no Codex turn reference for run 1
    And Codex keeps the forked conversation as paginated history
    When the user sends "Try again" to "f1" on "codex"
    Then Codex cuts the forked conversation before the turn after run 1
    And the conversation of "t1" keeps every turn

  @mc @plugin-codex
  Scenario: Codex cannot trim a fork whose paginated history it cannot cut
    Given "f1" is a fork of "t1" at run 1 on "codex"
    And the MC holds no Codex turn reference for run 1
    And Codex keeps the forked conversation as paginated history it cannot cut before a turn
    When the user sends "Try again" to "f1" on "codex"
    Then the run fails saying the fork point cannot be honoured on paginated history

  # Upstream #29902: the fork was cut at "the turn after run 1", which was an undone turn the
  # provider no longer had, so the provider copied the whole conversation.
  @backlog @mc @priority-high
  Scenario Outline: A native fork after an undo gives the agent only the history the fork shows
    Given "t1" ran runs 1 and 2 on "<provider>", the user undid run 2 and then ran run 3
    And "f1" is a fork of "t1" at run 1 on "<provider>"
    When the user sends "Try again" to "f1" on "<provider>"
    Then the provider's conversation for "f1" holds run 1 and not runs 2 or 3

    Examples:
      | provider    |
      | codex       |
      | opencode    |
      | claudeAgent |

  @mc
  Scenario: Merging a fork back queues its work for the parent's next run
    Given "f1" is a fork of "t1" at run 2 and has completed run 3
    When the user merges "f1" back into "t1"
    Then "t1" has a pending merge-back transfer from "f1"
    And the transfer's base is the fork point

  @mc
  Scenario: The parent's next run receives the fork's newer work
    Given "f1" was merged back into "t1"
    When the user sends "Continue" to "t1"
    Then the provider receives the work of "f1" since the fork point, introduced as coming from the fork by its title
    And the merge-back transfer is consumed with a fork delta summary handoff

  # Upstream #29572: each summarized message was cut at 237 UTF-16 units, so an emoji at the cut
  # left a lone surrogate the provider's JSON request rejected, and the turn failed unexplained.
  @backlog @mc @priority-high
  Scenario Outline: A summarized message cut through an emoji still reaches the provider
    Given a message of <source> is longer than 240 characters with an emoji at its 237th character
    When <transfer>
    Then the provider receives that message cut before the emoji, not through it
    And the run starts

    Examples:
      | source                     | transfer                                                     |
      | "t1"                       | the user asks a question in a side chat of "t1"              |
      | its fork "f1" since run 2  | the user merges "f1" back into "t1" and sends "Continue" to it |

  @mc
  Scenario: A newer merge from the same fork supersedes an unused one
    Given "f1" was merged back into "t1" and "t1" has not run since
    When the user merges "f1" back into "t1" again
    Then the earlier merge-back transfer is superseded by the new one
    And only the new merge reaches the parent's next run

  @mc
  Scenario: Merges from different forks all reach the parent's next run
    Given "f1" and "f2" were each merged back into "t1"
    When the user sends "Continue" to "t1"
    Then the provider receives the work of both forks

  @mc
  Scenario: Merging back from a run that is waiting on the user is allowed
    Given "f1" is a fork of "t1" whose latest run is waiting
    When the user merges "f1" back into "t1" at that run
    Then "t1" has a pending merge-back transfer from "f1"

  @mc
  Scenario Outline: Merging back is refused when the threads are not a fork and its parent
    Given <situation>
    When the user merges "f1" back into "t1"
    Then the command fails with "<message>"

    Examples:
      | situation                                   | message                          |
      | "f1" was not forked from "t1"               | Thread f1 is not a fork of t1.   |
      | thread "f1" does not exist                  | Thread f1 was not found.         |
      | "t1" was removed from this MC              | Thread t1 was not found.         |

  @mc
  Scenario: Merging back from an unfinished run is refused
    Given "f1" is a fork of "t1" with a running run 3
    When the user merges "f1" back into "t1" at run 3
    Then the command fails saying only finished runs can be used

  # Upstream #23554: a merge into a busy parent left a transfer its queued message could not take,
  # and that message failed.
  # Upstream #26901: Bring back is refused while the parent runs.
  @backlog @mc @priority-high
  Scenario Outline: Merging back into a parent that is busy is refused
    Given "f1" is a fork of "t1"
    And <busy>
    When the user merges "f1" back into "t1"
    Then the command fails saying "t1" must be idle with an empty queue
    And nothing is handed to "t1"

    Examples:
      | busy                                  |
      | "t1" has a run being prepared         |
      | "t1" has a run starting               |
      | "t1" has a run running                |
      | "t1" has a run waiting on the user    |
      | "t1" has a queued message             |

  # Upstream #26901: Bring back is also refused while the parent still holds another fork's unused
  # work; this replaces "Merges from different forks all reach the parent's next run" above.
  @backlog @mc
  Scenario: Merging back is refused while the parent holds another fork's unused work
    Given "f2" was merged back into "t1" and "t1" has not run since
    When the user merges "f1" back into "t1"
    Then the command fails saying "t1" already has pending context from another fork
    And only the merge from "f2" reaches the parent's next run

  # Upstream #23554: the refusal does not block ordinary messages, and the merge works once idle.
  @backlog @mc
  Scenario: A refused merge-back can be retried once the parent is idle
    Given merging "f1" back into the busy "t1" was refused
    When the user queues a message in "t1"
    Then the message is queued
    When "t1" finishes and its queue is empty
    And the user merges "f1" back into "t1"
    Then the fork's work is queued for "t1"'s next run

  @mc
  Scenario: A merge-back only carries what the parent has not seen yet
    Given "f1" was merged back into "t1" once already
    When the user merges "f1" back again after more work
    Then the handoff carries only the fork's work since the last merge the parent consumed
