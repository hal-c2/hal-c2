# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (checkpoint.captured, checkpoint-scope.created,
#     checkpoint.rollback, checkpoint.rollback-requested, run.updated, provider-thread.updated)
#   packages/contracts/src/rpc.ts (orchestration.getTurnDiff, orchestration.getFullThreadDiff)
#   apps/server-ex/lib/hal_c2/checkpoint.ex
#   apps/server-ex/lib/hal_c2/orchestration/rollback.ex
#   apps/server/src/checkpointing/ (checkpoint reactor, rollback)
#   apps/server/src/checkpointing/CheckpointStore.ts, CheckpointDiffQuery.ts (file summaries,
#     path prefixes, which turns count)
#   apps/server/src/vcs/GitVcsDriver.ts (checkpoint capture and restore corners)
#   apps/server/src/orchestration-v2/CheckpointCaptureService.ts, CheckpointRollbackService.ts,
#     CheckpointRestoreSafety.ts (repeated captures, shared workspaces, provider changes)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts (which turns a rewind drops)
#   docs/user/ (diffs and rewinding a thread)
Feature: Checkpoints, diffs and rewinding
  Each finished run captures its workspace as a hidden git commit, so every turn
  can be diffed and the thread can be rewound to any of them. Captures never touch
  the user's staging area.

  Background:
    Given an MC with a project "demo" rooted at a git repository
    And thread "t1" exists in "demo" in its own worktree

  @mc
  Scenario: A finished run captures a checkpoint under a hidden ref
    When a run of "t1" completes after changing "src/a.ts"
    Then a ready checkpoint for that run exists under a hidden checkpoint ref
    And the checkpoint lists "src/a.ts" with its added and removed line counts

  @mc
  Scenario: Capturing a checkpoint leaves the user's staging area alone
    Given the user has staged "README.md" in the worktree
    When a run of "t1" completes
    Then "README.md" is still the only staged change

  @mc
  Scenario: A thread whose workspace is not a git repository gets missing checkpoints
    Given thread "t2" works in a folder that is not a git repository
    When a run of "t2" completes
    Then the run's checkpoint is missing

  @mc
  Scenario: A capture that fails marks the checkpoint as an error
    Given capturing the workspace of "t1" fails
    When a run of "t1" completes
    Then the run's checkpoint has status error

  @mc
  Scenario: A failed baseline does not stop the run
    Given capturing the baseline of "t1" fails
    When the user sends "Hi" to "t1"
    Then the turn starts anyway

  @mc
  Scenario: Checkpoint refs survive an unclean shutdown
    Given a run of "t1" completed and captured a checkpoint
    When the host loses power right after the capture
    Then the checkpoint ref is readable after the MC restarts

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: sparse checkout)
  # Likely already implemented: apps/server-ex/lib/hal_c2/checkpoint.ex
  @mc @backlog
  Scenario: A sparse checkout is captured without counting the folders it leaves out as deleted
    Given the worktree of "t1" is a sparse checkout that leaves out the folder "docs"
    When a run of "t1" completes
    Then the checkpoint still holds "docs"
    And the turn's diff does not list the files of "docs" as removed

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: CHECKPOINT_RECOVERY_MAX_CANDIDATES, CHECKPOINT_RECOVERY_TIMEOUT)
  @mc @backlog
  Scenario: A repository inside the workspace that has no commit yet does not fail the capture
    Given the worktree of "t1" holds a folder "vendor/lib" that is its own repository with no commits
    When a run of "t1" completes
    Then the checkpoint is captured without "vendor/lib"

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: recovery limits)
  @mc @backlog
  Scenario Outline: A capture that would take too much work to recover from fails instead
    Given the worktree of "t1" holds <situation>
    When a run of "t1" completes
    Then the checkpoint is marked as an error

    Examples:
      | situation                                                                    |
      | more than 64 untracked folders that need checking for their own repositories |
      | untracked folders that take longer than 5 seconds to check                   |

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (legacyCheckpointRef, deleteCheckpointRefs)
  # Likely already implemented: apps/server-ex/lib/hal_c2/checkpoint.ex
  @mc @backlog
  Scenario: Checkpoints made before the hidden namespace was renamed are still used
    Given a checkpoint of "t1" exists only under the old hidden namespace
    When the user views that turn's diff or rewinds to it
    Then the old checkpoint is used
    When the thread's checkpoints are deleted
    Then the old checkpoint is deleted along with the new ones

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: commit identity)
  # Likely already implemented: apps/server-ex/lib/hal_c2/checkpoint.ex
  @mc @backlog
  Scenario: A checkpoint is committed under HAL-C2's own identity
    Given the user has no git name or email configured
    When a run of "t1" completes
    Then the checkpoint is captured

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: racy index timestamps)
  @mc @backlog
  Scenario: A file edited again within the same second of an earlier capture is captured as edited
    Given a checkpoint of "t1" was captured a moment ago
    And "src/a.ts" was edited again within the same second without its size or modification time changing
    When a run of "t1" completes
    Then the checkpoint holds the new content of "src/a.ts"

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: user index fallback)
  @mc @backlog
  Scenario Outline: A damaged git index does not stop a checkpoint and is left as it was
    Given the index of the worktree of "t1" is <state>
    When a run of "t1" completes
    Then the checkpoint holds the files as they are on disk
    And the index is still <state>

    Examples:
      | state                  |
      | missing                |
      | not a valid index file |

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: filter runs, temp index cleanup)
  @mc @backlog
  Scenario: Capturing a checkpoint leaves no work files behind and skips filters for unchanged files
    Given the worktree of "t1" has a content filter configured and one file changed since the last commit
    When a run of "t1" completes
    Then the filter ran only for the changed file
    And the repository's metadata folder holds no leftover checkpoint files

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (captureCheckpoint: non-cone sparse checkout)
  @mc @backlog
  Scenario: A checkpoint that would record false deletions fails instead
    Given the worktree of "t1" is a sparse checkout that is not folder-based
    And the checkpoint cannot reuse the worktree's index
    When a run of "t1" completes
    Then the run's checkpoint has status error
    And the error says the checkpoint index cannot be rebuilt for a non-cone sparse checkout

  # Legacy: apps/server/src/vcs/GitVcsDriver.ts (restoreCheckpoint: empty workspace)
  # Likely already implemented: apps/server-ex/lib/hal_c2/checkpoint.ex
  @mc @backlog
  Scenario: Restoring a checkpoint with no files leaves the workspace folder in place
    Given the checkpoint of run 1 holds no files
    When the user rewinds "t1" to before run 2
    Then the workspace folder still exists and is empty

  @mc
  Scenario: The diff of one turn
    Given runs 1 and 2 of "t1" completed with checkpoints
    When a client asks for the diff from turn 1 to turn 2 of "t1"
    Then the patch shows what run 2 changed

  @mc
  Scenario: The full thread diff starts before the first run
    Given runs 1 and 2 of "t1" completed with checkpoints
    When a client asks for the full diff of "t1" through turn 2
    Then the patch shows everything runs 1 and 2 changed

  @mc
  Scenario: A diff between the same turn is empty
    When a client asks for the diff from turn 2 to turn 2 of "t1"
    Then the patch is empty

  @mc
  Scenario: Diffs ignore whitespace unless asked not to
    Given run 1 of "t1" only re-indented a file
    When a client asks for the diff of turn 1
    Then the patch is empty
    And asking again without ignoring whitespace shows the re-indentation

  @mc
  Scenario: A turn without a ready checkpoint of a completed run cannot be diffed
    Given run 3 of "t1" failed
    When a client asks for the diff from turn 2 to turn 3 of "t1"
    Then it fails with "turn 3 has no checkpoint"

  @mc
  Scenario: Very large diffs are capped
    Given run 1 of "t1" produced a diff larger than 10 MB
    When a client asks for the diff of turn 1
    Then the request fails instead of sending the whole patch

  @mc
  Scenario: A fork's full diff starts from its source's first checkpoint
    Given thread "f1" is a fork of "t1" after run 2
    When a client asks for the full diff of "f1" through turn 2
    Then the patch starts from the workspace before the first run of "t1"

  @backlog @mc
  Scenario: Turns that were rewound do not count in diff turn numbers
    Given runs 1, 2 and 3 of "t1" completed and the thread was rewound to run 1
    And a new run of "t1" completed afterwards
    When a client asks for the diff of turn 2 of "t1"
    Then the patch shows what the new run changed

  @backlog @mc
  Scenario: A patch keeps its path prefixes whatever the repository's diff settings
    Given the repository of "demo" is configured to show diffs without path prefixes
    When a client asks for the diff of turn 1 of "t1"
    Then every file in the patch is still named with its "a/" and "b/" prefixes

  @backlog @mc
  Scenario Outline: A checkpoint's file list counts each kind of change
    When a run of "t1" completes after <change>
    Then the checkpoint lists <listed>

    Examples:
      | change                                                     | listed                                   |
      | renaming "old.ts" to "new.ts"                              | "new.ts" and not "old.ts"                |
      | adding an image                                            | the image with no added or removed lines |
      | adding an empty file                                       | the file with no added or removed lines  |
      | editing a file whose name has spaces and non-Latin letters | the file under its exact name            |
      | editing "b.ts" and then "a.ts"                             | "a.ts" before "b.ts"                     |

  @backlog @mc
  Scenario: A checkpoint lists its files even when its patch is very large
    When a run of "t1" completes after writing a file of tens of megabytes
    Then the checkpoint still lists that file with its line counts

  @backlog @mc
  Scenario: A checkpoint whose file list cannot be worked out is still ready
    Given listing the files a run of "t1" changed fails
    When the run completes
    Then a ready checkpoint for that run exists with no files listed

  @backlog @mc
  Scenario: A workspace folder inside a repository is checkpointed
    Given thread "t3" works in a subfolder of a repository, with no git folder of its own
    When a run of "t3" completes after changing a file
    Then a ready checkpoint for that run exists

  @backlog @mc
  Scenario: A capture asked for twice leaves the first checkpoint in place
    Given a run of "t1" completed with a checkpoint
    When the capture for that run is asked for again after a restart
    Then the run keeps the checkpoint it had
    And no second checkpoint item is added to the run

  @backlog @mc
  Scenario: A placeholder never replaces a checkpoint that was really captured
    Given a run of "t1" completed with a captured checkpoint
    When the provider's own diff for that run arrives as a placeholder because no checkpoint was found
    Then the run keeps the checkpoint it had
    And the command fails saying the turn already has a captured checkpoint

  @mc
  Scenario: Rewinding a thread to a checkpoint
    Given runs 1, 2 and 3 of "t1" completed with checkpoints
    When the user rewinds "t1" to the checkpoint of run 1
    Then runs 2 and 3 are rolled back and their root nodes too
    And the checkpoints of runs 2 and 3 are stale and their refs are deleted
    And the provider conversation continues from run 1
    And the worktree matches the checkpoint of run 1

  @mc
  Scenario: Rewinding hides the rolled-back turns from the timeline
    Given "t1" was rewound past runs 2 and 3
    When a client reads the timeline of "t1"
    Then the items of runs 2 and 3 are not shown

  @mc
  Scenario: Rewinding to before the first run
    Given run 1 of "t1" completed
    When the user rewinds "t1" to the baseline checkpoint
    Then run 1 is rolled back
    And the worktree matches the workspace before run 1

  @mc
  Scenario: Rewinding the conversation without restoring files
    Given runs 1 and 2 of "t1" completed with checkpoints
    When the user rewinds "t1" to run 1 without restoring files
    Then run 2 is rolled back
    And the worktree is unchanged

  @mc
  Scenario: Restoring files removes files the checkpoint lacks but keeps ignored files
    Given run 2 of "t1" created "new.txt" and the ignored "build/out.js"
    When the user rewinds "t1" to run 1
    # "the file" keeps this step apart from the theme editor's `"<name>" is gone`.
    Then the file "new.txt" is gone
    And "build/out.js" is still there
    And nothing is left staged

  @mc
  Scenario: Rewinding refreshes source control state
    When the user rewinds "t1" to run 1
    Then clients see the worktree's git status after the restore

  @mc
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

  @mc
  Scenario: Restoring files is refused in a shared workspace
    Given thread "t1" works in the project root
    When the user rewinds "t1" to run 1 restoring files
    Then the command fails explaining that file restore requires an isolated worktree
    And suggests rewinding the conversation without restoring files

  @mc
  Scenario: Restoring files is refused when another thread uses the same worktree
    Given thread "t2" also points at the worktree of "t1"
    When the user rewinds "t1" to run 1 restoring files
    Then the command fails explaining that file restore requires an isolated worktree

  @backlog @mc
  Scenario Outline: A worktree another thread has worked in counts as shared
    Given <other>
    When the user rewinds "t1" to run 1 restoring files
    Then the command fails explaining that file restore requires an isolated worktree

    Examples:
      | other                                                                  |
      | an archived thread "t2" also points at the worktree of "t1"            |
      | thread "t2" points at the worktree of "t1" through a symbolic link     |
      | thread "t2" ran turns in the worktree of "t1" before moving elsewhere  |

  @backlog @mc
  Scenario: A rewind is refused when the thread moved to another provider meanwhile
    Given runs 1 and 2 of "t1" completed with checkpoints
    When the user rewinds "t1" to run 1 and the thread's active provider changes before the rewind runs
    Then the rewind fails saying the active provider changed before the rewind could run

  @mc
  Scenario: Rewinding an unknown thread is refused
    When the user rewinds thread "missing" to a checkpoint
    Then the command fails with "Thread missing was not found."

  @mc @plugin-claude
  Scenario: A Claude thread without a recorded message for the target turn cannot rewind
    Given a Claude thread whose run 1 recorded no provider message
    When the user rewinds it to run 1
    Then the command fails with "Cannot rewind this Claude thread: no message was recorded for that turn."

  @mc
  Scenario: Rewinding when every later run is already gone does not ask the provider
    Given every run after run 1 of "t1" is already rolled back
    When the user rewinds "t1" to run 1
    Then the provider is not asked to drop any turns

  @mc
  Scenario: Rewinding twice keeps the provider's history right
    Given runs 1, 2 and 3 of "t1" completed and "t1" was rewound to run 2 and then to run 1
    When the user sends "Again" to "t1"
    Then the provider receives the history through run 1
    And neither rolled-back run is replayed

  @mc
  Scenario: A rewind whose restore fails ends with an error
    Given runs 1 and 2 of "t1" completed with checkpoints
    When the user rewinds "t1" to run 1 and restoring the files fails
    Then the rewind ends with an error
    And "t1" is not left waiting
    And the checkpoint of run 1 is still the last valid checkpoint

  # The files are restored before the provider is asked to drop the later turns, so a
  # failed restore leaves its conversation matching what the thread still shows.
  @mc
  Scenario: A rewind whose restore fails leaves the provider's conversation whole
    Given runs 1 and 2 of "t1" completed with checkpoints
    When the user rewinds "t1" to run 1 and restoring the files fails
    Then the provider still holds the conversation through run 2
    And the next message to "t1" continues after run 2

  @mc @backlog
  Scenario: Editing from a message after a stopped run starts from that message
    Given run 2 of "t1" was stopped by the user after an assistant message
    When the user edits from that message
    Then the new turn starts from the checkpoint before that message
    And the stopped run stays in the history

  @mc @plugin-codex
  Scenario: A Codex rollback whose history is paginated is reported as a rollback failure
    Given a Codex thread whose history needs more than one page to rewind
    When the user rewinds it to an early run
    Then the command fails explaining the provider could not roll back
    And no run is marked rolled back

  # CodexAdapterV2.ts resolveCodexRollbackTurnCount.
  @backlog @mc @plugin-codex
  Scenario: A Codex thread whose target turn is not in its recorded history cannot rewind
    Given a Codex thread whose run 1 has no turn in the history the MC recorded for Codex
    When the user rewinds it to run 1
    Then the command fails saying the target turn was not found in the provider's turn history
    And Codex is not asked to drop any turns

  # Dropped: a subagent works in its run's worktree, so the run's own checkpoint already
  # holds its changes and a rewind already undoes them. Upstream never wrote a nested
  # scope either: every scope it creates has no parent.
  @dropped @mc
  Scenario: Nested checkpoint scopes for subagent runs
    Given a run of "t1" delegated work to a subagent in the same worktree
    Then the subagent's work is captured in a nested checkpoint scope under the run
