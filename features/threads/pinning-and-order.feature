# Sources:
#   docs/user/thread-sidebar.md (Pinning, Undo, Arranging threads, drag between sections)
#   apps/web/src/components/Sidebar.tsx (pin, unpin, drag and drop, confirm unpin)
#   apps/web/src/components/sidebar/SidebarThreadUndoNotice.tsx
#   apps/web/src/hooks/showThreadUndoNotice.ts
#   apps/web/src/hooks/threadUndo.ts
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (pinned section, divider)
#   apps/desktop-qt/parity/features.backlog.test.ts (sidebar-multi-select-and-reorder)
#   packages/contracts/src/orchestrationV2.ts (thread.pin, thread.unpin, thread.pin.reorder, thread.active.reorder, thread.pinned, thread.unpinned, thread.pin-reordered, thread.active-reordered)
#   apps/server-ex/lib/hal_c2/orchestration.ex (pin, unpin, pin.reorder, active.reorder)

Feature: Pinning and arranging threads
  Pinned threads stay at the top of the list. Pinned and active threads can be put in
  any order, and that order is kept by the environment so every device sees it.

  Background:
    Given a connected environment with the active threads "Alpha", "Beta" and "Gamma"

  @desktop
  Scenario: Pinned threads are listed above active threads
    Given "Gamma" is pinned
    When the user looks at the thread list
    Then "Gamma" is listed in the pinned section above "Alpha" and "Beta"

  @desktop @mobile @backlog-mobile
  Scenario: Pinning a thread
    When the user pins "Beta"
    Then "Beta" moves to the pinned section
    And every connected device shows "Beta" as pinned

  @desktop @mobile @backlog-mobile
  Scenario: Unpinning a thread
    Given "Beta" is pinned
    When the user unpins "Beta"
    Then "Beta" returns to its place among the active threads

  @desktop @backlog-desktop @mobile @backlog-mobile
  Scenario: A pinned thread shows a pin that unpins it
    Given "Beta" is pinned
    Then the row of "Beta" shows a pin labelled "Unpin thread"
    When the user clicks the pin on the row of "Beta"
    Then "Beta" is unpinned, asking first when the user wants confirmation

  @desktop @mobile @backlog-mobile
  Scenario: Unpinning asks first when the user wants confirmation
    Given "Beta" is pinned
    And the user asked to confirm before unpinning
    When the user unpins "Beta"
    Then the user is asked "Unpin thread 'Beta'? This will move the thread out of your pinned section."
    And "Beta" stays pinned until the user confirms

  @desktop @mobile @backlog-mobile
  Scenario Outline: Undoing a thread change
    Given the user just <changed> "Beta"
    When the user undoes the change within five seconds
    Then "Beta" is back where it was before

    Examples:
      | changed  |
      | unpinned |
      | settled  |
      | snoozed  |
      | archived |

  # Proved by tst_KeysToastRegression.cpp, not yet by a step (hal-c2/hal-c2#194).
  @desktop @backlog-desktop
  Scenario: The undo offer counts the threads it will restore and names the shortcut
    Given the user just settled "Alpha"
    When the user settles "Beta"
    Then one notice reads "Settled 2 threads" and names the undo shortcut
    And undoing it brings both threads back

  @desktop
  Scenario: Undo reopens an archived thread the user was viewing
    Given the user is viewing "Beta"
    And the user just archived "Beta"
    When the user undoes the change
    Then "Beta" is restored and opened again

  @desktop
  Scenario: The undo shortcut only acts when no text is being edited
    Given the user just unpinned "Beta"
    And the user is typing in the composer
    When the user presses the undo shortcut
    Then the text edit is undone
    And "Beta" stays unpinned

  @desktop @mobile @backlog-mobile
  Scenario: The undo offer expires
    Given the user just unpinned "Beta"
    When five seconds pass
    Then the change can no longer be undone

  @backlog @desktop @mobile
  Scenario: Pinning or unpinning keeps the list where the user was reading
    Given the user has scrolled down the thread list
    When the user pins "Gamma"
    Then the list stays scrolled to the same place

  @mc
  Scenario: Pinned threads can be reordered
    Given "Alpha" and "Beta" are pinned in that order
    When a client moves "Beta" above "Alpha"
    Then the pinned threads are listed as "Beta", "Alpha"
    And the order survives a refresh

  @mc
  Scenario: Active threads can be reordered
    When a client moves "Gamma" above "Alpha"
    Then the active threads are listed with "Gamma" before "Alpha"
    And every connected device sees the same order

  @mc
  Scenario: Moving one thread does not renumber the others
    Given "Alpha", "Beta" and "Gamma" are pinned in that order
    When a client moves "Gamma" between "Alpha" and "Beta"
    Then only "Gamma" is changed

  @desktop
  Scenario: Moving a thread up or down from its menu
    When the user moves "Beta" up
    Then "Beta" is listed above "Alpha"

  @desktop
  Scenario: New threads appear above arranged active threads
    Given the user arranged the active threads by hand
    When a new thread "Delta" is created
    Then "Delta" is listed above the arranged threads

  @desktop @mobile @backlog-mobile
  Scenario: Activity does not reorder threads
    When the agent finishes work in "Gamma"
    Then the order of the active threads does not change

  @desktop @mobile @backlog-mobile
  Scenario: Pinning and snoozing keep an active thread's position for later
    Given "Beta" is the second active thread
    When the user pins and then unpins "Beta"
    Then "Beta" is the second active thread again

  @desktop
  Scenario: Arranging is unavailable on an environment that needs an update
    Given the environment does not support reordering active threads
    When the user tries to move "Beta"
    Then the user is told "Update this environment's server to reorder active threads."

  @desktop
  Scenario Outline: Reordering threads by dragging within a section is kept
    Given the <section> threads are "Alpha" then "Beta"
    When the user drags "Beta" above "Alpha"
    Then the <section> threads are "Beta" then "Alpha"
    And the order is the same after a restart

    Examples:
      | section |
      | pinned  |
      | active  |

  @desktop
  Scenario Outline: Dragging a thread between sections
    Given "Beta" is <from>
    When the user drags "Beta" <onto>
    Then "Beta" is <result>

    Examples:
      | from    | onto                            | result                        |
      | active  | into the pinned section         | pinned at the drop position   |
      | pinned  | into the active section         | unpinned without confirmation |
      | active  | onto the settled section header | settled                       |
      | settled | into the active section         | un-settled                    |
      | snoozed | into the active section         | woken                         |

  @desktop
  Scenario: A thread cannot be dragged into the snoozed shelf
    When the user drags "Beta" onto the snoozed section
    Then nothing happens to "Beta"

  @desktop
  Scenario: Dragging to the top pins when nothing is pinned yet
    Given no thread is pinned
    When the user drags "Gamma" to the top of the list
    Then "Gamma" is pinned

  @desktop
  Scenario: Dropping files onto a thread attaches them
    When the user drops two files onto "Beta" in the thread list
    Then "Beta" opens
    And the files are attached to its composer with the usual attachment limits

  @backlog @desktop @mobile
  Scenario: Reordered threads respect reduced motion
    Given the user prefers reduced motion
    When a thread moves in the list
    Then it moves without animation
