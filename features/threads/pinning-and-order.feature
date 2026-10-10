# Sources:
#   docs/user/thread-sidebar.md (Pinning, Undo, Arranging threads, drag between sections)
#   apps/web/src/components/Sidebar.tsx (pin, unpin, drag and drop, confirm unpin)
#   apps/web/src/components/Sidebar.drag.ts, Sidebar.pointer.ts (drag collisions, a drag that is cancelled)
#   apps/web/src/components/chat/threadContextDrag.ts (dropping threads on the composer)
#   apps/web/src/components/sidebar/SidebarThreadUndoNotice.tsx
#   apps/web/src/hooks/showThreadUndoNotice.ts
#   apps/web/src/hooks/threadUndo.ts
#   apps/web/src/hooks/useThreadActions.ts (the title each failed undo reports)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (pinned section, divider)
#   apps/desktop-qt/parity/features.backlog.test.ts (sidebar-multi-select-and-reorder)
#   packages/contracts/src/orchestrationV2.ts (thread.pin, thread.unpin, thread.pin.reorder, thread.active.reorder, thread.pinned, thread.unpinned, thread.pin-reordered, thread.active-reordered)
#   apps/server-ex/lib/hal_c2/orchestration.ex (pin, unpin, pin.reorder, active.reorder)
#   apps/web/src/components/ChatView.tsx (the pin shortcut on the open thread)

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

  @backlog @desktop
  Scenario Outline: The pin shortcut pins or unpins the open thread and reports a refusal
    Given the user has "Beta" open and it is <state>
    And the environment refuses the change with "Not now"
    When the user presses the shortcut that pins a thread
    Then the user sees an "error" toast "<message>" saying "Not now"
    And "Beta" is still <state>

    Examples:
      | state      | message                |
      | not pinned | Failed to pin thread   |
      | pinned     | Failed to unpin thread |

  @backlog @desktop
  Scenario: The pin shortcut does nothing where there is nothing to pin
    Given the user is writing the first message of a new thread
    When the user presses the shortcut that pins a thread
    Then nothing is pinned and no error is shown

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

  @backlog @desktop @mobile
  Scenario Outline: An undo that fails says so and leaves the thread as it is
    Given the user just <changed> "Beta"
    And the environment refuses the undo
    When the user undoes the change
    Then the user is told "<message>"
    And "Beta" stays <changed>

    Examples:
      | changed  | message                |
      | archived | Failed to undo archive |
      | unpinned | Failed to undo unpin   |
      | settled  | Failed to undo settle  |

  @desktop
  Scenario Outline: The undo offer counts the threads it will restore and names the shortcut
    Given the user just <changed> "Alpha"
    And the user just <changed> "Beta"
    Then one notice reads "<notice>" and names the undo shortcut
    When the user undoes the change
    Then "Alpha" is back where it was before
    And "Beta" is back where it was before

    Examples:
      | changed  | notice             |
      | settled  | Settled 2 threads  |
      | unpinned | Unpinned 2 threads |

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

  @backlog @desktop @mobile
  Scenario: A thread that is reopened leads the active threads
    Given "Gamma" was settled and the user arranged the active threads by hand
    When the user reopens "Gamma"
    Then "Gamma" is listed above the arranged threads
    And a thread that wakes from the settled section on new activity is listed there too

  @backlog @desktop @mobile
  Scenario: Pinned threads that were never arranged follow the arranged ones, newest first
    Given "Alpha" was pinned before the environment learned to arrange pinned threads
    And "Beta" and "Gamma" were arranged by hand
    When the user looks at the pinned section
    Then "Beta" and "Gamma" are listed in the order the user gave them
    And "Alpha" is listed after them

  @backlog @desktop @mobile
  Scenario: Moving a thread beside one that was never arranged arranges the section once
    Given "Alpha" and "Beta" are pinned and were never arranged
    When the user moves "Beta" above "Alpha"
    Then the pinned threads are listed as "Beta", "Alpha"
    And every pinned thread now has a place of its own in the order
    When the user moves "Alpha" above "Beta"
    Then only "Alpha" is changed

  @backlog @desktop @mobile
  Scenario: Arranging leaves the places of threads that are filtered out alone
    Given "Gamma" is hidden from the thread list by a filter
    And "Alpha" and "Beta" are pinned in that order
    When the user moves "Beta" above "Alpha"
    Then "Gamma" keeps its place in the order
    And no thread is given the place "Gamma" holds

  @backlog @desktop @mobile
  Scenario: Threads that share a place in the order are listed the same way on every device
    Given "Alpha" on "Laptop" and "Alpha" on "Build box" were given the same place in the order
    When two devices look at the pinned section
    Then both list the threads in the same order

  @backlog @mobile
  Scenario Outline: A thread at either end of the list cannot be moved past it
    Given "Alpha", "Beta" and "Gamma" are pinned in that order
    When the user looks at the arrangement actions of <thread>
    Then nothing is offered that would move <thread> <direction> past the end

    Examples:
      | thread  | direction |
      | "Alpha" | up        |
      | "Gamma" | down      |

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

  @backlog @desktop
  Scenario: Dragging threads out of the list onto the composer attaches them as context
    Given "Alpha" and "Gamma" are selected
    When the user drags "Alpha" out of the list and drops it on the composer
    Then the composer references "Alpha" and "Gamma"
    And the order of the threads in the list is unchanged

  @backlog @desktop
  Scenario: Dropping a dragged thread outside the list and outside the composer does nothing
    When the user drags "Beta" out of the list and drops it somewhere that is not the composer
    Then "Beta" stays where it was
    And no thread changes section

  @backlog @desktop
  Scenario Outline: A drag that is interrupted changes nothing
    When the user starts dragging "Beta" and <interruption>
    Then "Beta" stays where it was

    Examples:
      | interruption                  |
      | presses Escape                |
      | the window loses focus        |
      | the window is resized         |
      | releases the button elsewhere |

  @backlog @desktop
  Scenario: Letting go of a dragged thread does not open it
    When the user drags "Beta" to a new place and lets go
    Then "Beta" is not opened by the release

  @backlog @desktop
  Scenario Outline: A drag the environment refuses puts the thread back and says so
    Given the environment refuses the change
    When the user drags "Beta" <where>
    Then "Beta" returns to where it was
    And the user is told "<told>"

    Examples:
      | where                                | told                              |
      | onto the settled section header      | Failed to settle thread           |
      | into the active section from settled | Failed to un-settle thread        |
      | into the active section from snoozed | Failed to wake thread             |
      | to a new place among active threads  | Failed to reorder active threads  |
      | to a new place among pinned threads  | Failed to reorder pinned threads  |
