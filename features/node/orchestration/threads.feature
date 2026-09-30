# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (thread.create, thread.created, thread.metadata.update,
#     thread.metadata-updated, thread.archive, thread.archived, thread.unarchive, thread.unarchived,
#     thread.delete, thread.deleted, thread.removed, thread.visit, thread.visited, thread.mark-unread,
#     thread.marked-unread, thread.runtime-mode.set, thread.runtime-mode-updated,
#     thread.interaction-mode.set, thread.interaction-mode-updated, thread.updated,
#     thread.title.regeneration.complete, thread.created.record)
#   packages/contracts/src/rpc.ts (orchestration.dispatchCommand)
#   apps/server-ex/lib/hal_c2/orchestration.ex
#   apps/server/src/orchestration-v2/ (decider and projector for thread commands)
#   docs/internals/glossary.md
Feature: Thread lifecycle in the orchestration engine
  A thread is the durable conversation for a project. The engine creates it,
  records its metadata, and moves it between active, archived and deleted, with
  every change visible as an event on the thread's stream.

  Background:
    Given a node with a project "demo" rooted at a git repository

  @node
  Scenario: Creating a thread records it on the project
    When a client creates thread "t1" in "demo" titled "Fix the build"
    Then thread "t1" exists with title "Fix the build"
    And a thread-created event is recorded for "t1"
    And the thread's runtime mode is "full-access" and its interaction mode is "default"

  @node
  Scenario: Creating a thread with a branch and worktree remembers both
    When a client creates thread "t1" in "demo" on branch "feature/x" in worktree "/work/x"
    Then thread "t1" records branch "feature/x" and worktree "/work/x"

  @node
  Scenario: Creating a thread with an id that already exists is refused
    Given thread "t1" exists in "demo"
    When a client creates thread "t1" in "demo" again
    Then the command fails with "Thread t1 already exists."
    And thread "t1" is unchanged

  @node
  Scenario: A command naming an unknown thread is refused
    When a client archives thread "missing"
    Then the command fails with "unknown thread missing"

  @node
  Scenario: A command type the node does not implement is refused by name
    When a client dispatches a command of a type the node does not serve
    Then the command fails saying that type "is not supported by this node yet"

  @node
  Scenario: Renaming a thread
    Given thread "t1" exists in "demo" titled "Old"
    When a client updates the metadata of "t1" with title "New"
    Then thread "t1" is titled "New"
    And a thread-metadata-updated event is recorded

  @node
  Scenario Outline: Metadata updates change only the named field
    Given thread "t1" exists in "demo"
    When a client updates the metadata of "t1" with <field> set to <value>
    Then thread "t1" has <field> <value>

    Examples:
      | field           | value           |
      | branch          | "feature/y"     |
      | worktree path   | "/work/y"       |

  @node
  Scenario: A metadata update guarded by the expected worktree fails when the worktree moved
    Given thread "t1" is in worktree "/work/a"
    When a client updates the branch of "t1" expecting worktree "/work/b"
    Then the command fails with "the thread's worktree changed"
    And the branch of "t1" is unchanged

  @node
  Scenario: Asking for a new title marks the thread as regenerating and starts it
    Given thread "t1" has user and assistant messages
    When a client updates the metadata of "t1" asking to regenerate the title
    Then thread "t1" shows title regeneration started by that command
    And a new title is generated from the thread's messages and its previous title

  @node
  Scenario: A regenerated title that equals the old one clears the mark without renaming
    Given thread "t1" is regenerating its title
    When the generated title equals the current title
    Then thread "t1" keeps its title
    And the title regeneration mark is cleared

  @node
  Scenario: A failed title regeneration clears the mark
    Given thread "t1" is regenerating its title
    When title generation fails
    Then the title regeneration mark is cleared
    And thread "t1" keeps its title

  @node
  Scenario: A thread with no messages cannot regenerate its title
    Given thread "t1" has no messages
    When a client asks to regenerate the title of "t1"
    Then the title regeneration mark is cleared without asking a model

  @node
  Scenario: Setting a title explicitly cancels a pending regeneration
    Given thread "t1" is regenerating its title
    When a client updates the metadata of "t1" with title "Chosen"
    Then thread "t1" is titled "Chosen"
    And the title regeneration mark is cleared

  @node
  Scenario: A client completes title regeneration with a command
    Given thread "t1" is regenerating its title for request "r1"
    When a client completes title regeneration "r1" with title "Done"
    Then thread "t1" is titled "Done"
    And a completion for a different request id changes nothing

  @node
  Scenario: Archiving a thread records when it was archived
    Given thread "t1" exists in "demo"
    When a client archives "t1"
    Then thread "t1" is archived
    And a thread-archived event is recorded

  @node
  Scenario: Archiving a thread cancels its queued messages
    Given thread "t1" has a running turn and two queued messages
    When a client archives "t1"
    Then both queued runs are cancelled

  @node
  Scenario: Unarchiving a thread makes it active again
    Given thread "t1" is archived
    When a client unarchives "t1"
    Then thread "t1" is not archived
    And a thread-unarchived event is recorded

  @node
  Scenario: Unarchiving does not bring back queued messages that archiving cancelled
    Given thread "t1" was archived with a queued message
    When a client unarchives "t1"
    Then the queued message stays cancelled

  @node
  Scenario: Deleting a thread removes it from the shell
    Given thread "t1" exists in "demo"
    When a client deletes "t1"
    Then thread "t1" records when it was deleted
    And "t1" no longer appears among the project's threads

  # The client flow is threads/archive-delete.feature "Deleting a thread with a running
  # agent stops the agent first".
  @node
  Scenario: Deleting a thread stops its live provider session first
    Given thread "t1" has a live provider session
    When a client deletes "t1"
    Then the provider session of "t1" is stopped before "t1" is removed

  @node
  Scenario: Deleting a thread emits a removal to shell subscribers
    # The thread must exist before it can be deleted; the node sends its row marked deleted.
    Given thread "t1" exists in "demo"
    And a client subscribes to the shell
    When a client deletes "t1"
    Then the subscriber receives a thread-removed event for "t1"

  @node
  Scenario: Visiting a thread marks it read up to the visit
    Given thread "t1" has a completed turn the user has not seen
    When a client records a visit to "t1"
    Then thread "t1" is read as of that visit

  @node
  Scenario: A late visit never moves the read watermark backwards
    Given thread "t1" was visited at 10:05
    When a client records a visit to "t1" at 10:00
    Then thread "t1" is still read as of 10:05

  @node
  Scenario: Marking a thread unread clears its last visit
    Given thread "t1" was visited
    When a client marks "t1" unread
    Then thread "t1" has no last visit
    And a thread-marked-unread event is recorded

  @node
  Scenario: Visits and mark-unread do not bump the thread's activity time
    Given thread "t1" was last updated at 09:00
    When a client records a visit to "t1" at 10:00
    Then the last activity of thread "t1" is still 09:00

  @node
  Scenario Outline: Changing a thread's modes applies to its next turn
    Given thread "t1" exists in "demo"
    When a client sets the <mode> of "t1" to "<value>"
    Then thread "t1" has <mode> "<value>"
    And the next turn of "t1" starts with <mode> "<value>"

    Examples:
      | mode             | value             |
      | runtime mode     | approval-required |
      | runtime mode     | auto-accept-edits |
      | runtime mode     | full-access       |
      | interaction mode | plan              |
      | interaction mode | default           |

  @node
  Scenario: A parent run records a thread it created
    Given a running turn in thread "parent" created thread "child"
    When the creation is recorded on the parent
    Then the parent's timeline links to "child" and the run that created it
