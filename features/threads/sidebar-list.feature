# Sources:
#   docs/user/thread-sidebar.md
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml
#   apps/desktop-qt/tests/tst_Sidebar.qml
#   apps/desktop-qt/src/native/SidebarModel.cpp (the desktop's port of the grouping and order, offline rows)
#   apps/web/src/components/Sidebar.tsx
#   apps/web/src/components/Sidebar.logic.ts
#   apps/web/src/hooks/useSidebarProjectGroups.ts
#   apps/web/src/components/NoProjectsHero.tsx
#   apps/web/src/components/NoActiveThreadState.tsx
#   apps/tui/src/components/Sidebar.logic.ts
#   packages/contracts/src/shell.ts (thread.open, draft.open, thread.new, sidebar.scope, sidebar.toggle, project.add, thread.menu)
#   packages/contracts/src/rpc.ts (subscribeShell)

Feature: The thread list
  The thread list shows every thread the user can act on, grouped by how much attention
  it needs: drafts, pinned, active, then snoozed and settled on their own shelves.

  Background:
    Given a connected environment with the projects "shop" and "docs"

  @desktop
  Scenario: Threads are grouped into sections
    Given "shop" has a draft, a pinned thread, two active threads, a snoozed thread and a settled thread
    When the user looks at the thread list
    Then the sections read drafts, pinned, active, snoozed, settled in that order

  @desktop @tui
  Scenario: Active threads are listed newest first
    Given "Alpha" was created before "Beta"
    When the user looks at the thread list
    Then "Beta" is listed above "Alpha"

  @desktop @mobile @backlog-mobile
  Scenario: Settled threads are listed by when they settled
    Given "Alpha" settled after "Beta"
    When the user looks at the settled section
    Then "Alpha" is listed above "Beta"

  # Delivered natively (Sidebar, SidebarModel); no desktop test yet.
  @desktop @tui @backlog-desktop
  Scenario: Collapsing and expanding a shelf
    Given the settled section is expanded
    When the user collapses the settled section
    Then its threads are hidden
    And the section shows how many threads it holds
    When the user expands the settled section
    Then its threads are shown again

  @tui
  Scenario: Searching opens collapsed shelves
    Given the snoozed section is collapsed
    When the user filters the list by "cart"
    Then matching snoozed threads are shown

  @tui
  Scenario: The selected thread stays visible when its shelf collapses
    Given the user has selected a settled thread
    When the user collapses the settled section
    Then the selected thread is still shown

  @tui
  Scenario: Long settled shelves are shown a page at a time
    Given there are 25 settled threads
    When the user looks at the settled section
    Then the first 10 settled threads are shown
    And the user can show more

  @desktop
  Scenario: Very long settled shelves point to the rest
    Given there are 70 settled threads
    When the user looks at the settled section
    Then 50 settled threads are shown
    And the section says "20 more settled in the app"

  # Delivered natively (Sidebar, SidebarModel); no desktop test yet.
  @desktop @backlog-desktop
  Scenario Outline: Moving through the list with the keyboard
    Given the thread list has keyboard focus on "Beta"
    When the user presses <key>
    Then <result>

    Examples:
      | key       | result                      |
      | Down      | the next row is focused     |
      | Up        | the previous row is focused |
      | Home      | the first row is focused    |
      | End       | the last row is focused     |
      | Enter     | "Beta" opens                |
      | Shift+F10 | the menu for "Beta" opens   |

  # Delivered natively (Sidebar, SidebarModel); no desktop test yet.
  @desktop @backlog-desktop
  Scenario: Enter on a shelf header folds the shelf
    Given the thread list has keyboard focus on the settled section header
    When the user presses Enter
    Then the settled section collapses

  # Delivered natively (Sidebar, SidebarModel); no desktop test yet.
  @desktop @backlog-desktop
  Scenario: A thread row keeps its place while the list updates
    Given the user is pointing at "Beta"
    When the list is republished with a new thread above "Beta"
    Then "Beta" is still the row under the pointer

  @desktop
  Scenario: Opening a thread from the list
    When the user opens "Beta"
    Then "Beta" is shown in the main view

  @desktop
  Scenario: Opening a draft from the list
    Given "shop" has an unsent draft
    When the user opens the draft
    Then the draft composer is shown with its unsent text

  @desktop @tui
  Scenario: Scoping the list to one project
    When the user scopes the thread list to "docs"
    Then only threads from "docs" are listed
    When the user scopes the thread list to all projects
    Then threads from "shop" and "docs" are listed

  # Delivered natively (Sidebar's folder dialog, project.add); no desktop test yet.
  @desktop @backlog-desktop
  Scenario: Adding a project from the thread list
    When the user adds a project from the thread list
    Then the user can choose a project to add

  @desktop @backlog-desktop
  Scenario: Hiding and showing the thread list
    When the user hides the thread list
    Then the main view takes the full width
    When the user shows the thread list
    Then the thread list is back

  # Delivered natively (Sidebar, SidebarModel); no desktop test yet.
  @desktop @backlog-desktop
  Scenario Outline: Empty thread lists explain themselves
    Given <state>
    When the user looks at the thread list
    Then the list says "<message>"

    Examples:
      | state                                 | message              |
      | the environment has not published yet | Waiting for the app… |
      | the environment has no projects       | No projects yet      |
      | the scoped project has no threads     | No threads yet       |

  @desktop @mobile @backlog-mobile
  Scenario: Projects are ordered by recent use unless arranged by hand
    Given the user last wrote in "docs" after "shop"
    When the user looks at the projects
    Then "docs" is listed above "shop"

  @desktop @mobile @backlog-mobile
  Scenario: Projects with the same name on two environments stay separate
    Given the environments "home" and "work" both have a project "shop"
    When the user looks at the projects
    Then "shop" is listed once for each environment

  @desktop @mobile @backlog-mobile
  Scenario: Threads started by other agents are not listed
    Given the agent in "Alpha" started a helper agent thread
    When the user looks at the thread list
    Then the helper thread is not listed

  @backlog @desktop
  Scenario: Jump hints appear while holding the modifier
    When the user holds the thread jump modifier
    Then the first nine threads show their jump numbers after a short delay

  @backlog @desktop @mobile
  Scenario: The list catches up after a reconnect
    Given the client was disconnected while two threads were created
    When the client reconnects
    Then both threads are listed without reloading the whole list

  @desktop @mobile @backlog-mobile
  Scenario: Threads on an offline environment are still listed
    Given the environment "work" is offline
    When the user looks at the thread list
    Then the threads from "work" are listed as unavailable
    And actions that need "work" are unavailable
