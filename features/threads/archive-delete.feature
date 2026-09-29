# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829 (upstream orchestrator behavior)
#   apps/web/src/components/threadActionMenu.logic.ts (Archive thread, Delete)
#   apps/web/src/hooks/useThreadActions.ts
#   apps/web/src/components/Sidebar.tsx (confirm archive, confirm delete, orphaned worktree prompt, navigation after delete)
#   apps/tui/src/commands.ts (Archive thread, Unarchive thread, Delete thread)
#   apps/tui/src/components/ThreadOverlays.tsx (delete confirmation)
#   packages/contracts/src/orchestrationV2.ts (thread.archive, thread.unarchive, thread.delete, thread.archived, thread.unarchived, thread.deleted)
#   packages/contracts/src/rpc.ts (getArchivedShellSnapshot, subscribeArchivedShell)
#   apps/server-ex/lib/hal_c2/orchestration.ex (archive, unarchive, delete, getArchivedShellSnapshot)
#   apps/web/src/components/settings/SettingsPanels.tsx (ArchivedThreadsPanel: loading, empty, error, per-project groups)

Feature: Archiving and deleting threads
  Archiving hides a thread and can be undone. Deleting clears its history for good, and
  can take its worktree with it.

  Background:
    Given a connected environment with the idle thread "Old spike" in the project "shop"

  @tui
  Scenario: Archiving a thread
    When the user archives "Old spike"
    Then "Old spike" is no longer in the thread list
    And the status line reads "Archived."

  @tui
  Scenario: Unarchiving a thread
    Given "Old spike" is archived
    When the user unarchives "Old spike"
    Then "Old spike" is back in the thread list
    And the status line reads "Unarchived."

  @backlog @desktop @mobile
  Scenario: Archiving and unarchiving from the desktop and phone
    When the user archives "Old spike"
    And the user restores "Old spike" from the archived threads
    Then "Old spike" is back in the thread list

  @tui
  Scenario: A thread with a running agent cannot be archived
    Given the agent is working in "Old spike"
    When the user opens the thread's menu
    Then archiving is unavailable

  @backlog @desktop @mobile
  Scenario: Archiving waits for the agent on the desktop and phone
    Given the agent is working in "Old spike"
    When the user opens the thread menu
    Then archiving is unavailable

  @node
  Scenario: Archiving cancels runs that have not started
    Given "Old spike" has a queued turn
    When a client archives "Old spike"
    Then the queued turn is cancelled

  @node
  Scenario: Archived threads are listed separately
    Given "Old spike" and "Older spike" are archived
    When a client asks for the archived threads
    Then both threads are returned with their project

  # Dropped with a reason in parity/rpc.feature: no client subscribes to the archived
  # shell; the archived list is fetched as a snapshot when the user opens it.
  @dropped @node
  Scenario: Archived threads stream to clients that watch them
    Given a client is watching the archived threads
    When "Old spike" is archived
    Then the client sees "Old spike" appear in the archived threads

  @node
  Scenario: The archived list is fetched fresh when a client opens it
    Given "Old spike" was archived after the client last looked
    When a client asks for the archived threads
    Then "Old spike" is in the answer

  @backlog @desktop @mobile
  Scenario: Archiving asks first when the user wants confirmation
    Given the user asked to confirm before archiving
    When the user archives "Old spike"
    Then the user is asked "Archive thread 'Old spike'?"

  @backlog @desktop @mobile
  Scenario: Archiving the open thread when the next thread cannot be opened
    Given the user is viewing "Old spike"
    And opening another thread fails
    When the user archives "Old spike"
    Then the user is told "Thread archived, but navigation failed"

  @tui
  Scenario: Deleting a thread asks for confirmation
    When the user deletes "Old spike"
    Then the user is warned that this can't be undone
    And "Old spike" is kept until the user confirms

  @tui
  Scenario: Confirming a delete
    Given the user was asked to confirm deleting "Old spike"
    When the user confirms
    Then "Old spike" is deleted

  @tui
  Scenario: Cancelling a delete
    Given the user was asked to confirm deleting "Old spike"
    When the user cancels
    Then "Old spike" is still in the thread list

  @backlog @desktop @mobile
  Scenario: Deleting from the desktop and phone asks when the user wants confirmation
    Given the user asked to confirm before deleting
    When the user deletes "Old spike"
    Then the user is warned that deleting clears the conversation history

  @node
  Scenario: A deleted thread is gone for every client
    When a client deletes "Old spike"
    Then no client lists "Old spike"
    And its history can no longer be read

  @node
  Scenario: Deleting a thread with a running agent stops the agent first
    Given the agent is working in "Old spike"
    When the user deletes "Old spike"
    Then the agent session is stopped
    And "Old spike" is deleted

  @backlog @desktop @mobile
  Scenario: Deleting the last thread in a worktree offers to remove the worktree
    Given "Old spike" is the only thread using its worktree
    When the user deletes "Old spike"
    Then the user is asked whether to delete the worktree too

  @backlog @desktop @mobile
  Scenario: The worktree is removed without asking when the user chose automatic cleanup
    Given "Old spike" is the only thread using its worktree
    And the user chose to always remove orphaned worktrees
    When the user deletes "Old spike"
    Then the thread and its worktree are deleted without a question

  @backlog @desktop @mobile
  Scenario: A worktree that cannot be removed is reported
    Given the worktree of "Old spike" cannot be removed
    When the user deletes "Old spike" and its worktree
    Then "Old spike" is deleted
    And the user is told "Failed to delete worktree"

  @backlog @desktop @mobile
  Scenario: Deleting the open thread opens the next thread in the project
    Given the user is viewing "Old spike"
    And "Newer work" is the top remaining thread in "shop"
    When the user deletes "Old spike"
    Then "Newer work" opens

  @backlog @desktop
  Scenario: Deleting several threads at once
    Given the user has selected three threads
    When the user deletes the selection
    Then the user is asked "Delete 3 threads?"
    And all three threads are deleted after confirming

  @backlog @desktop @tui
  Scenario: Deleting is not possible while the environment is offline
    Given the environment is unreachable
    When the user deletes "Old spike"
    Then "Old spike" is kept
    And the user is told the delete failed

  @backlog @desktop
  Scenario Outline: The archived threads list says where it stands
    Given <situation>
    When the user opens the archived threads
    Then the user sees "<title>"

    Examples:
      | situation                                | title                           |
      | the environments are still being checked | Loading archived threads        |
      | no thread has been archived              | No archived threads             |
      | the archived threads cannot be loaded    | Could not load archived threads |

  @backlog @desktop
  Scenario: Archived threads are grouped by project
    Given "Old spike" in "shop" and "Try vite" in "docs" are archived
    When the user opens the archived threads
    Then "Old spike" is listed under "shop" and "Try vite" under "docs"

  @backlog @desktop
  Scenario: Archived threads for one project show only that project's threads
    Given "Old spike" in "shop" and "Try vite" in "docs" are archived
    When the user opens the archived threads from the settings of "shop"
    Then only "Old spike" is listed

  @backlog @desktop
  Scenario Outline: An archived thread action that fails says why
    Given "Old spike" is archived
    When the user tries to <action> "Old spike" and the environment refuses
    Then the user is told "<message>" and why
    And "Old spike" stays in the archived threads

    Examples:
      | action    | message                    |
      | unarchive | Failed to unarchive thread |
      | delete    | Failed to delete thread    |

