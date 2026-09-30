# Sources:
#   docs/user/thread-sidebar.md (Copy thread reference)
#   apps/web/src/components/threadActionMenu.logic.ts
#   apps/web/src/hooks/useThreadActionMenu.ts
#   apps/web/src/hooks/useCopyToClipboard.ts
#   apps/web/src/components/Sidebar.tsx (multi-select, bulk menu, selection)
#   apps/web/src/threadSelectionStore.ts
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Menu key, Shift+F10)
#   apps/desktop-qt/parity/features.backlog.test.ts (sidebar-multi-select-and-reorder: Ctrl-click adds,
#     Shift-click extends the range, Escape clears the selection)
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml (right-click opens menu on press)
#   apps/tui/src/components/ContextMenu.tsx
#   apps/tui/src/components/Sidebar.tsx (context menu)
#   packages/contracts/src/shell.ts (thread.menu)
# Moving a thread to another machine from the menu is specified in threads/moving-between-machines.feature.

Feature: Thread menu and selecting several threads
  Every thread has a menu of the things the user can do to it. Selecting several threads
  applies the same actions to all of them.

  Background:
    Given a connected environment with the thread "Tidy logs" on the branch "chore/logs" in the project "shop"

  @desktop @tui
  Scenario: Opening a thread's menu
    When the user opens the menu for "Tidy logs"
    Then the actions for "Tidy logs" are offered

  @desktop
  Scenario: The menu opens as soon as the secondary button is pressed
    When the user presses the secondary button on "Tidy logs"
    Then the menu for "Tidy logs" opens without waiting for the release

  @tui
  Scenario: A long press opens the menu in the terminal
    When the user long-presses "Tidy logs"
    Then the menu for "Tidy logs" opens

  @desktop @mobile @backlog-mobile
  Scenario: The thread menu offers its actions in a fixed order
    When the user opens the menu for "Tidy logs"
    Then the actions read, in order: new thread on "chore/logs", pin, settle, snooze, rename, regenerate title, mark unread, filter by "shop", copy, project settings, archive, delete

  @desktop @mobile @backlog-mobile
  Scenario: Actions the environment does not support are left out
    Given the environment does not support snoozing or pinning
    When the user opens the menu for "Tidy logs"
    Then snoozing and pinning are not offered
    And archiving is still offered

  @tui
  Scenario Outline: Copying details of a thread
    When the user copies the <detail> of "Tidy logs"
    Then the clipboard holds <value>

    Examples:
      | detail    | value                       |
      | path      | the thread's workspace path |
      | branch    | "chore/logs"                |
      | thread id | the id of "Tidy logs"       |

  @desktop @mobile @backlog-mobile
  Scenario Outline: Copying details of a thread confirms what was copied
    When the user copies the <detail> of "Tidy logs"
    Then the clipboard holds <value>
    And the user is told "<message>"

    Examples:
      | detail    | value                       | message          |
      | path      | the thread's workspace path | Path copied      |
      | branch    | "chore/logs"                | Branch copied    |
      | thread id | the id of "Tidy logs"       | Thread ID copied |

  @tui
  Scenario: The path cannot be copied from a thread without a workspace
    Given "Tidy logs" has no workspace path
    When the user opens the menu for "Tidy logs"
    Then copying the path is unavailable

  @desktop @mobile @backlog-mobile
  Scenario: Copying a path that is missing explains why
    Given "Tidy logs" has no workspace path
    When the user copies the path of "Tidy logs"
    Then the user is told "Path unavailable — This thread does not have a workspace path to copy."

  @desktop @mobile @backlog-mobile
  Scenario: A failed copy is reported
    Given the clipboard cannot be written
    When the user copies the path of "Tidy logs"
    Then the user is told "Failed to copy path"

  @desktop @mobile @backlog-mobile
  Scenario Outline: Copying a thread reference
    Given "Tidy logs" <link>
    When the user copies a reference to "Tidy logs"
    Then the clipboard holds <value>

    Examples:
      | link                        | value                    |
      | is linked to a pull request | the pull request address |
      | has no pull request         | the thread id            |

  @desktop @mobile @backlog-mobile
  Scenario: Filtering the list from a thread's project
    When the user filters by the project of "Tidy logs"
    Then only threads from "shop" are listed
    When the user shows all projects again
    Then threads from every project are listed

  @desktop
  Scenario: Opening a thread's project settings
    When the user opens the project settings from "Tidy logs"
    Then the settings for "shop" open

  @backlog @desktop
  Scenario Outline: Selecting several threads
    Given the threads "A", "B", "C" and "D" are listed in that order
    When the user <gesture>
    Then <selection> are selected

    Examples:
      | gesture                                       | selection        |
      | adds "A" and then "C" to the selection        | "A" and "C"      |
      | selects "A" and then extends the range to "C" | "A", "B" and "C" |

  @backlog @desktop
  Scenario: Clearing a selection
    Given "A" and "C" are selected
    When the user clears the selection
    Then no thread is selected

  @backlog @desktop
  Scenario: Changing the project filter clears the selection
    Given "A" and "C" are selected
    When the user scopes the list to another project
    Then no thread is selected

  @backlog @desktop
  Scenario: The selection menu counts what each action affects
    Given "A" and "C" are selected and only "A" is pinned
    When the user opens the menu for the selection
    Then unpinning is offered for 1 thread
    And settling, snoozing, marking unread and deleting are offered for 2 threads

  @backlog @desktop
  Scenario Outline: A menu action applies to every selected thread
    Given "A" and "C" are selected
    When the user chooses to <action> from the menu of "A"
    Then "A" and "C" are <result>

    Examples:
      | action | result  |
      | settle | settled |
      | snooze | snoozed |
      | delete | deleted |

  @backlog @desktop
  Scenario: The selection cannot be archived while one of its threads is running
    Given "A" and "C" are selected and the agent is working in "C"
    When the user opens the menu for the selection
    Then archiving the selection is unavailable

  @backlog @desktop
  Scenario: A partly failed delete keeps the failed threads selected
    Given "A" and "C" are selected
    And deleting "C" fails
    When the user deletes the selection
    Then "A" is deleted
    And the user is told "Failed to delete threads"
    And "C" stays selected
