# Sources:
#   packages/contracts/src/orchestrationV2.ts (checkpoint.captured, checkpoint-scope.created,
#     checkpoint.rollback, checkpoint.rollback-requested, run.updated, provider-thread.updated)
#   packages/contracts/src/rpc.ts (orchestration.getTurnDiff, orchestration.getFullThreadDiff)
#   apps/server-ex/lib/t3/checkpoint.ex
#   apps/server-ex/lib/t3/orchestration/rollback.ex
#   apps/server/src/checkpointing/ (checkpoint reactor, rollback)
#   docs/user/ (diffs and rewinding a thread)
Feature: Checkpoints, diffs and rewinding
  Each finished run captures its workspace as a hidden git commit, so every turn
  can be diffed and the thread can be rewound to any of them. Captures never touch
  the user's staging area.

  Background:
    Given a node with a project "demo" rooted at a git repository
    And thread "t1" exists in "demo" in its own worktree

  @node
  Scenario: A finished run captures a checkpoint under a hidden ref
    When a run of "t1" completes after changing "src/a.ts"
    Then a ready checkpoint for that run exists under a hidden checkpoint ref
    And the checkpoint lists "src/a.ts" with its added and removed line counts

  @node
  Scenario: Capturing a checkpoint leaves the user's staging area alone
    Given the user has staged "README.md" in the worktree
    When a run of "t1" completes
    Then "README.md" is still the only staged change

  @node
  Scenario: A thread whose workspace is not a git repository gets missing checkpoints
    Given thread "t2" works in a folder that is not a git repository
    When a run of "t2" completes
    Then the run's checkpoint is missing

  @node
  Scenario: A capture that fails marks the checkpoint as an error
    Given capturing the workspace of "t1" fails
    When a run of "t1" completes
    Then the run's checkpoint has status error

  @node
  Scenario: A failed baseline does not stop the run
    Given capturing the baseline of "t1" fails
    When the user sends "Hi" to "t1"
    Then the turn starts anyway

  @node
  Scenario: Checkpoint refs survive an unclean shutdown
    Given a run of "t1" completed and captured a checkpoint
    When the host loses power right after the capture
    Then the checkpoint ref is readable after the node restarts

  @node
  Scenario: The diff of one turn
    Given runs 1 and 2 of "t1" completed with checkpoints
    When a client asks for the diff from turn 1 to turn 2 of "t1"
    Then the patch shows what run 2 changed

  @node
  Scenario: The full thread diff starts before the first run
    Given runs 1 and 2 of "t1" completed with checkpoints
    When a client asks for the full diff of "t1" through turn 2
    Then the patch shows everything runs 1 and 2 changed

  @node
  Scenario: A diff between the same turn is empty
    When a client asks for the diff from turn 2 to turn 2 of "t1"
    Then the patch is empty

  @node
  Scenario: Diffs ignore whitespace unless asked not to
    Given run 1 of "t1" only re-indented a file
    When a client asks for the diff of turn 1
    Then the patch is empty
    And asking again without ignoring whitespace shows the re-indentation

  @node
  Scenario: A turn without a ready checkpoint of a completed run cannot be diffed
    Given run 3 of "t1" failed
    When a client asks for the diff from turn 2 to turn 3 of "t1"
    Then it fails with "turn 3 has no checkpoint"

  @node
  Scenario: Very large diffs are capped
    Given run 1 of "t1" produced a diff larger than 10 MB
    When a client asks for the diff of turn 1
    Then the request fails instead of sending the whole patch

  @node
  Scenario: A fork's full diff starts from its source's first checkpoint
    Given thread "f1" is a fork of "t1" after run 2
    When a client asks for the full diff of "f1" through turn 2
    Then the patch starts from the workspace before the first run of "t1"

  @node
  Scenario: Rewinding a thread to a checkpoint
    Given runs 1, 2 and 3 of "t1" completed with checkpoints
    When the user rewinds "t1" to the checkpoint of run 1
    Then runs 2 and 3 are rolled back and their root nodes too
    And the checkpoints of runs 2 and 3 are stale and their refs are deleted
    And the provider conversation continues from run 1
    And the worktree matches the checkpoint of run 1

  @node
  Scenario: Rewinding hides the rolled-back turns from the timeline
    Given "t1" was rewound past runs 2 and 3
    When a client reads the timeline of "t1"
    Then the items of runs 2 and 3 are not shown

  @node
  Scenario: Rewinding to before the first run
    Given run 1 of "t1" completed
    When the user rewinds "t1" to the baseline checkpoint
    Then run 1 is rolled back
    And the worktree matches the workspace before run 1

  @node
  Scenario: Rewinding the conversation without restoring files
    Given runs 1 and 2 of "t1" completed with checkpoints
    When the user rewinds "t1" to run 1 without restoring files
    Then run 2 is rolled back
    And the worktree is unchanged

  @node
  Scenario: Restoring files removes files the checkpoint lacks but keeps ignored files
    Given run 2 of "t1" created "new.txt" and the ignored "build/out.js"
    When the user rewinds "t1" to run 1
    Then "new.txt" is gone
    And "build/out.js" is still there
    And nothing is left staged

  @node
  Scenario: Rewinding refreshes source control state
    When the user rewinds "t1" to run 1
    Then clients see the worktree's git status after the restore

  @node
  Scenario Outline: Rewinding is refused when it cannot be done safely
    Given <situation>
    When the user rewinds "t1" to the checkpoint of run 1
    Then the command fails with "<message>"

    Examples:
      | situation                                             | message                                                       |
      | "t1" has a running turn                               | Interrupt the current turn before rewinding.                  |
      | the checkpoint of run 1 is missing                    | Checkpoint checkpoint-1 cannot be restored.                   |
      | the checkpoint is named with a different scope        | Checkpoint checkpoint-1 is not in scope other-scope.          |
      | "t1" has no active provider thread                    | No active provider thread exists for rollback.                |

  @node
  Scenario: Restoring files is refused in a shared workspace
    Given thread "t1" works in the project root
    When the user rewinds "t1" to run 1 restoring files
    Then the command fails explaining that file restore requires an isolated worktree
    And suggests rewinding the conversation without restoring files

  @node
  Scenario: Restoring files is refused when another thread uses the same worktree
    Given thread "t2" also points at the worktree of "t1"
    When the user rewinds "t1" to run 1 restoring files
    Then the command fails explaining that file restore requires an isolated worktree

  @node
  Scenario: Rewinding an unknown thread is refused
    When the user rewinds thread "missing" to a checkpoint
    Then the command fails with "Thread missing was not found."

  @node @plugin-claude
  Scenario: A Claude thread without a recorded message for the target turn cannot rewind
    Given a Claude thread whose run 1 recorded no provider message
    When the user rewinds it to run 1
    Then the command fails with "Cannot rewind this Claude thread: no message was recorded for that turn."

  @node
  Scenario: Rewinding when every later run is already gone does not ask the provider
    Given every run after run 1 of "t1" is already rolled back
    When the user rewinds "t1" to run 1
    Then the provider is not asked to drop any turns

  @node @backlog @plugin-codex
  Scenario: A Codex rollback whose history is paginated is reported as a rollback failure
    Given a Codex thread whose history needs more than one page to rewind
    When the user rewinds it to an early run
    Then the command fails explaining the provider could not roll back
    And no run is marked rolled back

  @node @backlog
  Scenario: Nested checkpoint scopes for subagent runs
    Given a run of "t1" delegated work to a subagent in the same worktree
    Then the subagent's work is captured in a nested checkpoint scope under the run
