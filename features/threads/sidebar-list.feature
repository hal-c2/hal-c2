# Sources:
#   https://github.com/pingdotgg/t3code/pull/26195
#   https://github.com/pingdotgg/t3code/pull/27327
#   https://github.com/pingdotgg/t3code/pull/26112
#   https://github.com/pingdotgg/t3code/pull/24610
#   https://github.com/pingdotgg/t3code/pull/15163
#   https://github.com/pingdotgg/t3code/pull/20808
#   https://github.com/pingdotgg/t3code/pull/17022
#   https://github.com/pingdotgg/t3code/pull/18368
#   https://github.com/pingdotgg/t3code/pull/17050
#   https://github.com/pingdotgg/t3code/pull/18740
#   https://github.com/pingdotgg/t3code/pull/20522
#   https://github.com/pingdotgg/t3code/pull/16291
#   https://github.com/pingdotgg/t3code/pull/13491
#   https://github.com/pingdotgg/t3code/pull/13759
#   docs/user/thread-sidebar.md
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml
#   apps/desktop-qt/tests/tst_Sidebar.qml
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml (the two lines of a row)
#   apps/desktop-qt/src/native/SidebarModel.cpp (the desktop's port of the grouping and order, offline rows)
#   apps/desktop-qt/src/native/LayoutController.cpp (hiding the thread list, the rows' density)
#   apps/desktop-qt/tests/native/features/ThreadListSteps.cpp
#   apps/web/src/components/Sidebar.tsx
#   apps/web/src/components/Sidebar.logic.ts
#   apps/web/src/hooks/useSidebarProjectGroups.ts
#   apps/web/src/components/NoProjectsHero.tsx
#   apps/web/src/components/NoActiveThreadState.tsx
#   apps/tui/src/components/Sidebar.logic.ts
#   apps/desktop-qt/src/native/SidebarController.cpp (sidebar.more: the settled shelf a page at a time)
#   packages/contracts/src/settings.ts (sidebarShowSettledPluginThreads)
#   packages/contracts/src/plugin.ts (ThreadPluginMark: the threads a plugin started)
#   plugins/code-review/mc/code_review.ex (settles each review thread it finishes)
#   apps/tui/src/host/features/server.ts (settings.settledPluginThreads: the TUI's toggle)
#   apps/tui/src/settingsClient.ts (subscribeServerSettings: the settings another client changed)
#   packages/contracts/src/shell.ts (thread.open, draft.open, thread.new, sidebar.scope, sidebar.toggle, sidebar.more, project.add, thread.menu)
#   packages/contracts/src/rpc.ts (subscribeShell)
#   apps/web/src/components/LegacySidebar.tsx (the per-project thread tree)
#   apps/web/src/components/ThreadStatusIndicators.tsx (row indicators)
#   packages/client-runtime/src/state/models.ts (resolveThreadProviderStack: the providers a row shows)
#   apps/web/src/components/ProjectEnvironmentBadge.tsx
#   apps/web/src/components/Sidebar.motion.ts
#   apps/web/src/uiStateStore.ts (the remembered project filter)
#   apps/web/src/sidebarProjectGrouping.ts
#   packages/client-runtime/src/state/projectGrouping.ts (the group's name, duplicate folders, the folder it opens on)
#   packages/client-runtime/src/state/shellReducer.ts (a repository that is not resolved yet keeps the earlier one)
#   https://github.com/pingdotgg/t3code/pull/13926
#   https://github.com/pingdotgg/t3code/pull/15034
#   https://github.com/pingdotgg/t3code/pull/15346
#   https://github.com/pingdotgg/t3code/pull/15418
#   https://github.com/pingdotgg/t3code/pull/14768
#   https://github.com/pingdotgg/t3code/pull/14587
#   https://github.com/pingdotgg/t3code/pull/25190
#   https://github.com/pingdotgg/t3code/pull/25415
#   https://github.com/pingdotgg/t3code/pull/24760
#   https://github.com/pingdotgg/t3code/pull/24723
#   https://github.com/pingdotgg/t3code/pull/25636
#   https://github.com/pingdotgg/t3code/pull/25284
#   https://github.com/pingdotgg/t3code/pull/21039
#   https://github.com/pingdotgg/t3code/pull/26387
#   https://github.com/pingdotgg/t3code/pull/26391
#   https://github.com/pingdotgg/t3code/pull/26463
#   https://github.com/pingdotgg/t3code/pull/26392
#   https://github.com/pingdotgg/t3code/pull/28169
#   https://github.com/pingdotgg/t3code/pull/28179
#   https://github.com/pingdotgg/t3code/pull/28605
#   https://github.com/pingdotgg/t3code/pull/22887
#   https://github.com/pingdotgg/t3code/pull/31269
#   https://github.com/pingdotgg/t3code/pull/27231

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

  # Upstream #27231: opening Settled with two or more projects in the project filter made the list
  # loop until the app crashed, and it crashed again on every start since the shelf stayed open.
  @backlog @desktop @mobile @priority-high
  Scenario: The settled section opens with several projects filtered
    Given the project filter holds "shop" and "docs"
    And "docs" has only settled threads older than the rest of the list
    When the user opens the settled section
    Then the settled threads of "shop" and "docs" are listed
    And the list stays still

  @desktop @mobile @backlog-mobile
  Scenario: Settled threads are listed by when they settled
    Given "Alpha" settled after "Beta"
    When the user looks at the settled section
    Then "Alpha" is listed above "Beta"

  @desktop @mobile @backlog-mobile
  Scenario: A settled thread's age counts from when it settled
    Given "Alpha" settled after "Beta"
    And "Beta" was renamed since
    When the user looks at the settled section
    Then the rows for "Alpha" and "Beta" count their ages from when they settled

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
    Given there are 40 settled threads
    When the user looks at the settled section
    Then the first 10 settled threads are shown
    When the user shows more settled threads
    Then the first 35 settled threads are shown

  @desktop @mobile
  Scenario: Very long settled shelves are shown a page at a time
    Given there are 120 settled threads
    When the user looks at the settled section
    Then 50 settled threads are shown
    And the section offers "Show 50 more"
    When the user shows more settled threads
    Then 100 settled threads are shown
    And the section offers "Show 20 more"
    When the user shows more settled threads
    Then 120 settled threads are shown
    And the section offers no more

  @desktop
  Scenario: The open thread stays listed past the settled page
    Given there are 70 settled threads
    When the user opens "Settled 65"
    Then "Settled 65" is among the settled threads
    And 51 settled threads are shown

  # Upstream #24723: a first connect sent every settled thread, 93% of the snapshot, though
  # they sit in a collapsed shelf; older ones now come on demand.
  @mc @priority-high
  Scenario: A first connect brings only the newest settled threads
    Given "shop" has 900 settled threads, one of them pinned and one snoozed
    When a client connects for the first time
    Then it is sent the 25 newest settled threads and the pinned and snoozed ones
    And it is told how many settled threads of "shop" were left out

  # Upstream #24723: the settled shelf's label counts the threads a connect left out, and they load a page at a time.
  @backlog @shared
  Scenario: The settled section counts and pages the threads a connect left out
    Given a client was sent 25 of the 900 settled threads of "shop"
    Then the settled section counts 900 threads
    When the user shows more settled threads
    Then the next 25 older settled threads are read from the MC and listed below the others

  # Upstream #24723: a search that matches an older settled thread brings it in with its family.
  @backlog @shared
  Scenario: Search finds settled threads a connect left out
    Given a client was not sent the older settled thread "Old billing fix"
    When the user searches threads for "billing"
    Then "Old billing fix" is among the results

  # Upstream #24723: opening an old thread (link, notification, search) brings in that thread's family.
  @backlog @shared
  Scenario: A link to a settled thread a connect left out opens it
    Given a client was not sent the older settled thread "Old billing fix"
    When the user opens a link to "Old billing fix"
    Then "Old billing fix" opens and is listed in the settled section

  # Rows are one line in a window under 1100 and the list is a rail under 860
  # (navigation/layout.feature): crossing either keeps the open thread's row in view
  # rather than the old scroll offset, which points at other rows once they change height.
  @desktop
  Scenario: The open thread stays in view when the rows change height
    Given there are 80 active threads
    And the window is 1280 wide
    And the user opens "Active 50"
    And the thread list is scrolled to "Active 50"
    When the window is 1000 wide
    Then the thread list shows "Active 50"
    When the window is 800 wide
    And the window is 1280 wide
    Then the thread list shows "Active 50"

  # A plugin settles its own threads as it finishes them, such as each code review,
  # and those would bury the user's own. They stay out of the shelf, before it pages
  # and counts, unless the user asks; search and the plugin's page still find them.
  @desktop @mobile @tui
  Scenario: Settled threads a plugin started stay out of the settled section
    Given there are 3 settled threads
    And 2 settled threads a plugin started
    When the user looks at the settled section
    Then 3 settled threads are shown
    And the settled section counts 3 threads

  @desktop @mobile @tui
  Scenario: The user can list settled plugin threads in the settled section
    Given there are 3 settled threads
    And 2 settled threads a plugin started
    When the user turns on "Show plugin threads in Settled"
    Then 5 settled threads are shown
    When the user turns off "Show plugin threads in Settled"
    Then 3 settled threads are shown

  # The setting is the MC's, shared by every client, so an open client follows a change
  # made on another.
  @tui
  Scenario: Plugin threads follow the setting when another device changes it
    Given there are 3 settled threads
    And 2 settled threads a plugin started
    When "Show plugin threads in Settled" is turned on on another device
    Then 5 settled threads are shown
    When "Show plugin threads in Settled" is turned off on another device
    Then 3 settled threads are shown

  @desktop @mobile @backlog-mobile
  Scenario: Search still finds a settled plugin thread
    Given 2 settled threads a plugin started
    When the user searches the palette for "Review 1"
    Then the command palette lists "Review 1"

  @tui
  Scenario: Filtering the thread list finds a settled plugin thread
    Given 2 settled threads a plugin started
    When the user filters the thread list by "Review 1"
    Then "Review 1" is among the settled threads

  @desktop
  Scenario: An open settled plugin thread stays listed
    Given 2 settled threads a plugin started
    When the user opens "Review 1"
    Then "Review 1" is among the settled threads

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

  @desktop @backlog-desktop
  Scenario: Enter on a shelf header folds the shelf
    Given the thread list has keyboard focus on the settled section header
    When the user presses Enter
    Then the settled section collapses

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

  @desktop @backlog-desktop
  Scenario: Adding a project from the thread list
    When the user adds a project from the thread list
    Then the user can choose a project to add

  @desktop
  Scenario: Hiding and showing the thread list
    When the user hides the thread list
    Then the main view takes the full width
    When the user shows the thread list
    Then the thread list is back

  @desktop @backlog-desktop
  Scenario Outline: Empty thread lists explain themselves
    Given <state>
    When the user looks at the thread list
    Then the list says "<message>"
    And Tab passes over the thread list

    Examples:
      | state                                 | message              |
      | the environment has not published yet | Waiting for the app… |
      | the environment has no projects       | No projects yet      |
      | no project has threads                | No threads yet       |

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

  @desktop
  Scenario: Jump hints appear while holding the modifier
    When the user holds the thread jump modifier
    Then the first nine threads show their jump numbers after a short delay

  # Upstream #25636: a second hold showed the hints at once.
  @backlog @desktop @priority-low
  Scenario: Jump hints wait for their delay on every hold
    Given the user held the thread jump modifier and let go
    When the user holds it again
    Then the jump numbers show only after the same short delay

  # Upstream #26112: the hint floated between the time and the provider icon, its ⌘ drawn too
  # small to read.
  @backlog @desktop @priority-low
  Scenario: A jump hint takes the row's status place while the modifier is held
    Given the user hovers a thread that is working
    When the user holds the thread jump modifier
    Then the row's status and its hover actions give way to its jump number, drawn like other shortcut hints
    And a long hint shortens the project name rather than covering it
    When the user lets go
    Then the row shows its status and hover actions again

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: The list catches up after a reconnect
    Given the client was disconnected while two threads were created
    When the client reconnects
    Then both threads are listed without reloading the whole list
    And the MC sent only the two new threads

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: The list starts over when its MC restarted
    Given the client was disconnected while its MC restarted and lost a thread
    When the client reconnects
    Then the MC sent its whole list
    And the lost thread is no longer listed

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: Threads on an offline environment are still listed
    Given the environment "work" is offline
    When the user looks at the thread list
    Then the threads from "work" are listed as unavailable
    And actions that need "work" are unavailable

  @backlog @desktop @priority-low
  Scenario: The snoozed section lists the thread that wakes first at the top
    Given "Fix login" is snoozed until tomorrow
    And "Refactor cart" is snoozed until next week
    When the user looks at the snoozed section
    Then "Fix login" is listed above "Refactor cart"

  @backlog @desktop @priority-low
  Scenario: A shelf stays open or closed the way the user left it
    Given the user expanded the settled section
    And the user left the snoozed section collapsed
    When the user restarts the app
    Then the settled section is expanded
    And the snoozed section is collapsed

  @backlog @desktop @priority-low
  Scenario: Shelves start collapsed
    Given the user has never opened a shelf
    When the user looks at the thread list
    Then the snoozed and settled sections show only how many threads they hold

  @backlog @desktop @priority-low
  Scenario: The open thread stays visible behind a collapsed shelf
    Given the user is viewing a settled thread
    And the settled section is collapsed
    When the user looks at the thread list
    Then the open thread is still listed under the settled section

  # Upstream #15163: opening a subagent left no thread highlighted in the sidebar.
  @backlog @desktop @priority-low
  Scenario: The parent thread stays highlighted while the user views its subagent
    Given the thread "Fix login" delegated a subagent
    When the user opens the subagent
    Then "Fix login" is highlighted in the thread list
    And moving to the next or previous thread starts from "Fix login"

  @backlog @desktop @tui
  Scenario: Settling a thread into a collapsed settled shelf keeps the list working
    Given the user is viewing "Fix login" and "Refactor cart" is active
    And the settled section is collapsed
    When the user settles "Refactor cart"
    Then "Refactor cart" leaves the active threads
    And the collapsed settled section counts one more thread
    And the user can still open and switch threads from the list

  @backlog @desktop @priority-low
  Scenario: A settled thread far down a long shelf is shown when it is opened
    Given there are 40 settled threads and the settled section is expanded
    When the user opens the 30th settled thread from a link
    Then the settled section lists that thread without the user asking for more

  @backlog @desktop
  Scenario: Finding a project to scope the list to by typing its name
    Given the user has several projects
    When the user opens the project filter and types "doc"
    Then only the projects matching "doc" are offered
    And the choice to show all projects is not offered

  # Upstream #27327: the list kept its old scroll, so narrowing landed on a project's oldest
  # threads and widening back landed mid-list.
  @backlog @desktop
  Scenario Outline: Changing the project filter starts the list at the top
    Given the user scrolled to the bottom of the thread list
    When the user <changes> the project filter
    Then the list shows its first threads

    Examples:
      | changes                                         |
      | picks "Alpha" in                                |
      | shift-clicks "Alpha" in                         |
      | chooses "Filter by project" on a thread to set  |

  # Upstream #27327
  @backlog @desktop @priority-low
  Scenario: Opening a thread outside the project filter still scrolls to that thread
    Given the thread list is filtered to "Alpha"
    When the user opens a thread of "Beta" from a link
    Then the list widens to show "Beta" and scrolls to that thread

  # Upstream #28605: a pick put focus back on the filter, lighting its focus ring and tooltip.
  @backlog @desktop
  Scenario Outline: Choosing in the project filter returns the focus only when the keyboard closed it
    When the user <how>
    Then the focus <where>

    Examples:
      | how                                           | where                         |
      | picks a project in the filter with the pointer | is not put back on the filter |
      | picks a project in the filter with Enter       | is back on the filter         |
      | closes the project filter with Escape          | is back on the filter         |

  @backlog @desktop
  Scenario: A project filter search that matches nothing says so
    When the user opens the project filter and types "zzz"
    Then the filter says "No matching projects."

  @backlog @desktop
  Scenario: The project filter says where a project lives
    Given the project "shop" is on the environments "home" and "work"
    When the user opens the project filter
    Then "shop" is listed once
    And its entry says it is also on the other environment, with that environment's name

  # Upstream #17050. Each environment's scratch folder is its own project, so each one used
  # to get its own "No project" entry. A real project named "No project" is not merged in.
  @backlog @shared @priority-low
  Scenario: Threads without a project on every environment share one "No project" filter
    Given the environments "home" and "work" each have a thread without a project
    When the user opens the project filter
    Then "No project" is listed once
    When the user chooses "No project"
    Then the list shows the threads without a project from "home" and "work"
    And no thread of a project is shown

  @backlog @shared @priority-low
  Scenario: A chosen "No project" filter survives the environments connecting late
    Given the user scoped the list to "No project"
    When the user restarts the app and the environments' settings arrive after their projects
    Then the list is still scoped to "No project"

  @backlog @desktop
  Scenario: Opening a project's settings from the project filter
    When the user opens the project filter
    And the user chooses the settings of "docs" beside its name
    Then the filter closes
    And the settings for "docs" open

  @desktop
  Scenario: The project filter is remembered across restarts
    Given the user scoped the list to "docs"
    When the user restarts the app
    Then the list is scoped to "docs"

  @desktop
  Scenario: A remembered project filter waits until every environment has reported
    Given the user scoped the list to "docs" before closing the app
    When the app starts and the environment "work" has not reported its projects yet
    Then the list stays scoped to "docs"
    When every environment has reported and "docs" is gone
    Then the list shows every project

  # Upstream #28179: with the local environment turned off the projects never counted as
  # reported, so a filter on a deleted project stayed with nothing selected.
  @backlog @desktop
  Scenario: A remembered filter on a deleted project is dropped with the local environment off
    Given the local environment is turned off and the app uses only remote environments
    And the user scoped the list to "docs" before closing the app
    When the app starts, every remote environment reports and "docs" is gone
    Then the list shows every project
    And the project filter shows all projects as chosen

  @desktop
  Scenario: Leaving the thread list for settings keeps the project filter
    Given the user scoped the list to "docs"
    When the user opens settings and then returns to the threads
    Then the list is still scoped to "docs"

  # Upstream #25284: the project filter holds several projects. Adding one keeps the filter open;
  # a plain pick still scopes to that one project and "All projects" clears the selection.
  @backlog @desktop @tui
  Scenario: Scoping the list to several projects at once
    Given the environment also has the project "infra"
    When the user opens the project filter
    And the user adds "docs" and "infra" to the filter
    Then the filter is still open
    And only threads from "docs" and "infra" are listed
    When the user chooses only "shop"
    Then the filter closes
    And only threads from "shop" are listed
    When the user chooses all projects
    Then threads from "shop", "docs" and "infra" are listed

  # Upstream #25284: search, the older settled threads and the draft count follow the whole selection.
  @backlog @desktop @tui
  Scenario: Search, settled threads and drafts follow a filter of several projects
    Given the user scoped the list to "docs" and "infra"
    When the user searches threads for "cart"
    Then only matching threads from "docs" and "infra" are found
    And the settled section and the draft count hold only threads from "docs" and "infra"

  # Upstream #25284: the selection is saved, and a filter saved before it could hold several carries over.
  @backlog @desktop @tui @priority-low
  Scenario: A filter of several projects is remembered and names its projects
    Given the user scoped the list to "docs" and "infra"
    When the user restarts the app
    Then the list is scoped to "docs" and "infra"
    And the project filter names "docs" and "infra"

  @backlog @desktop @priority-low
  Scenario: The project filter shows the project it is scoped to
    Given the user scoped the list to "docs"
    When the user looks at the project filter
    Then it names "docs" and shows the project's icon

  # Proved by tst_Sidebar.qml (test_emptyListMessage).
  @desktop @backlog-desktop
  Scenario: An empty project is named in the empty list
    Given the user scoped the list to "docs"
    And "docs" has no threads
    When the user looks at the thread list
    Then the list says "No threads in docs yet"

  # Proved by tst_Sidebar.qml (test_emptyListAddsAProject).
  @desktop @backlog-desktop
  Scenario: Adding a project from an empty list
    Given the environment has no projects
    When the user looks at the thread list
    Then the list says "No projects yet"
    And the user can add a project from the list

  @backlog @desktop
  Scenario: A thread row says its terminal has a process running
    Given a terminal in "Beta" is running two processes
    When the user looks at the thread list
    Then the row for "Beta" says "Terminal process running"
    And pointing at the row says "2 terminal processes running"

  @backlog @shared @priority-low
  Scenario: The running-terminal mark opens the terminal that is running
    Given "Beta" has the terminals "term-1" and "term-2" split side by side
    And only "term-2" is running a process
    When the user clicks the running-terminal mark on the row for "Beta"
    Then "Beta" opens with its terminal drawer showing "term-2"
    And no new terminal is started

  @backlog @desktop
  Scenario: A thread row says which worktree and branch it works in
    Given "Beta" works in a worktree on the branch "feature/cart"
    When the user points at the worktree mark on the row for "Beta"
    Then the user sees the worktree's folder and the branch "feature/cart"

  @backlog @desktop
  Scenario: A thread on another machine says which machine it is on
    Given the environment "work" is another machine with the thread "Gamma"
    When the user looks at the thread list
    Then the row for "Gamma" shows the kind of machine and the name "work"

  # Upstream #17022: every machine has its own "No project", so the row says which one.
  @backlog @desktop @priority-low
  Scenario Outline: A thread without a project names its machine where a branch would be
    Given <environments> connected
    And "Notes" has no project and runs on "work"
    When the user looks at the thread list
    Then the row for "Notes" <shows>

    Examples:
      | environments                        | shows                                                      |
      | the environments "home" and "work" are | shows the kind of machine and "work" on its branch line |
      | only the environment "work" is       | shows no machine name                                     |

  @backlog @desktop
  Scenario: A thread row shows the providers it was handed over from
    Given "Beta" ran on Codex, then on Claude, then on OpenCode
    When the user looks at the thread list
    Then the row for "Beta" shows the three providers with OpenCode, where it runs now, last

  @backlog @desktop @priority-low
  Scenario: A thread row shows the newest of its earlier providers when there are many
    Given "Beta" ran on Codex, then Claude, then Cursor, then OpenCode and now runs on Grok
    When the user looks at the thread list
    Then the row for "Beta" shows Cursor, OpenCode and Grok with Grok last
    And Codex and Claude are not shown on the row

  @backlog @desktop @priority-low
  Scenario: A thread that came back to a provider it used before shows it once
    Given "Beta" ran on Codex, then on Claude, and now runs on Codex again
    When the user looks at the thread list
    Then the row for "Beta" shows Claude and then Codex

  @backlog @desktop
  Scenario Outline: A thread row shows its pull requests
    Given "Beta" is linked to <links>
    When the user looks at the thread list
    Then the row for "Beta" shows <badge>

    Examples:
      | links                                        | badge                                          |
      | pull request 12                              | "#12" with its state                           |
      | pull requests 12 and 14                      | "#12" and that one more is linked              |
      | a stack of 3 pull requests                   | "Stack of 3 pull requests" with its overall state |
      | pull request 12 whose state is not known yet | "PR #12, status pending"                       |

  @backlog @desktop @priority-low
  Scenario: Pointing at a pull request on a row lists the chain or stack
    Given "Beta" is linked to a stack of 3 pull requests
    When the user points at the pull requests on the row for "Beta"
    Then the user sees each pull request with its state and its place in the stack

  # Upstream #18368: the second pull request arrived while the app was open.
  @backlog @desktop @priority-low
  Scenario: Pointing at a row's pull requests lists them after a second one is linked
    Given "Beta" is linked to pull request 12
    When pull request 14 is linked to "Beta" while the user watches the thread list
    And the user points at the pull requests on the row for "Beta"
    Then the user sees pull requests 12 and 14 with their states

  @backlog @desktop @priority-low
  Scenario: A thread row keeps a finished pull request after the checkout moves on
    Given "Beta" works in the local checkout and its pull request 12 is merged
    When the checkout switches to another branch
    Then the row for "Beta" still shows pull request 12

  @backlog @desktop @priority-low
  Scenario: A thread row drops an open pull request that no longer matches the checkout
    Given "Beta" works in the local checkout and its pull request 12 is open
    When the checkout switches to another branch
    Then the row for "Beta" no longer shows pull request 12

  @desktop @priority-high
  Scenario: A thread with unsent text in its composer is marked on its row
    Given the user typed a message in the composer of "Beta" and did not send it
    And "Alpha" is the open thread
    When the user looks at the thread list
    Then the row for "Beta" says "Unsent draft"
    When the user discards the draft from the row
    Then the composer of "Beta" is empty
    And the row for "Beta" no longer says "Unsent draft"

  @backlog @desktop @priority-low
  Scenario: A large change to the list does not animate every row
    Given the thread list shows hundreds of threads
    When the user scopes the list to one project
    Then the list changes at once without animating the rows that appear or leave

  @backlog @desktop @priority-low
  Scenario: Rows slide when the list changes a little
    Given the user does not prefer reduced motion
    When a thread is snoozed and leaves the active section
    Then the rows below it slide up and the thread fades out

  # The legacy per-project tree: the user's switch to it is the "Sidebar (legacy)" setting.
  # Keep-or-drop is the maintainers' call; see the audit report.
  @desktop @priority-high
  Scenario: The user can switch the thread list to one tree of threads per project
    Given "shop" has 2 threads
    And "docs" has 2 threads
    And the user has not turned on the legacy sidebar
    When the user turns on "Sidebar (legacy)" in settings
    Then the thread list shows each project with its own threads beneath it
    When the user turns off "Sidebar (legacy)" in settings
    Then the thread list is grouped by attention again

  @desktop
  Scenario: A project in the tree folds and unfolds its threads
    Given the user has turned on the legacy sidebar
    And "shop" has 2 threads
    When the user folds "shop" in the thread list
    Then the threads of "shop" are hidden
    When the user unfolds "shop"
    Then the threads of "shop" are shown again

  @desktop
  Scenario: A project in the tree shows a few threads and offers the rest
    Given the user has turned on the legacy sidebar
    And "shop" has 10 threads and the list shows 6 threads per project
    When the user looks at "shop" in the thread list
    Then the 6 most recent threads of "shop" are shown
    And "shop" offers to show more
    When the user asks to show more
    Then all 10 threads of "shop" are shown
    And "shop" offers to show less
    When the user asks to show less
    Then only 6 threads of "shop" are shown

  @desktop @priority-low
  Scenario Outline: The number of threads a project shows is limited to a sensible range
    Given the user has turned on the legacy sidebar
    And "shop" has 20 threads
    When the user sets the visible thread count to <typed>
    Then each project shows <shown> threads before offering more

    Examples:
      | typed | shown |
      | 0     | 1     |
      | 8     | 8     |
      | 40    | 15    |

  @desktop @priority-high
  Scenario Outline: The user chooses how projects and threads are sorted
    Given the user has turned on the legacy sidebar
    And "shop", "docs" and "blog" have threads started and written at different times
    And the user once arranged the projects "blog", "shop" and "docs" by hand
    When the user sorts <what> by "<order>"
    Then <what> are listed <result>

    Examples:
      | what     | order             | result                                          |
      | projects | Last user message | by the latest message the user sent in each     |
      | projects | Created at        | by when each project's threads were started     |
      | projects | Manual            | in the order the user arranged them             |
      | threads  | Last user message | by the latest message the user sent in each     |
      | threads  | Created at        | by when each thread was started                 |

  @desktop
  Scenario: Projects are dragged into place only when they are sorted by hand
    Given the user has turned on the legacy sidebar
    And projects are sorted "Manual"
    When the user drags "shop" above "docs"
    Then "shop" is listed above "docs"
    And the user's order is remembered
    When the user sorts projects by "Created at"
    Then dragging a project does not move it

  @desktop
  Scenario Outline: Renaming a project from its menu
    Given the user has turned on the legacy sidebar
    When the user renames "shop" from its menu to "<title>"
    Then <result>

    Examples:
      | title      | result                                                       |
      | store      | "shop" is now called "store"                                 |
      | shop       | nothing is sent and the dialog closes                        |
      |            | the user is told "Project title cannot be empty"             |

  @desktop @priority-low
  Scenario: A project rename the environment refuses is reported
    Given the user has turned on the legacy sidebar
    And the environment refuses to rename "shop"
    When the user renames "shop" from its menu to "store"
    Then the user is told "Failed to rename project"

  @desktop @priority-high
  Scenario Outline: A project chooses how it is grouped regardless of the device's default
    Given the user has turned on the legacy sidebar
    And "shop" sits in the repository folder "acme", as "shop-copy" does in another copy of it
    And the device groups projects by repository path
    When the user groups "shop" by "<choice>" from its menu
    Then "shop" is grouped <result>

    Examples:
      | choice                   | result                                   |
      | Group by repository      | with the other folders of its repository |
      | Group by repository path | with the folders of its repository path  |
      | Keep separate            | on its own                               |
      | the device's default     | the way the device's default says        |

  @backlog @desktop @priority-low
  Scenario Outline: A project made of several folders is named by what they share
    Given the folders of one repository are listed as one project
    And <folders>
    When the user looks at the thread list
    Then the project is called <name>

    Examples:
      | folders                                                                        | name                                |
      | every folder is titled "store" and the repository is named "shop"              | "store"                             |
      | the folders are titled "store" and "store-2" and the repository is "Acme Shop" | "Acme Shop"                         |
      | the folders are titled "shop" and "shop-2" and the repository is named "shop"  | "shop"                              |
      | the folders are titled "a" and "b" and the repository has no name              | the title of the folder it opens on |

  @backlog @desktop @priority-low
  Scenario: A project that is only one folder keeps that folder's title
    Given "shop" is the only folder of its repository
    And the repository is called "Acme Shop"
    When the user looks at the thread list
    Then the project is called "shop"

  @backlog @desktop
  Scenario: A project opens on the folder of the user's own machine when it has one
    Given "shop" is a folder on "My MacBook" and on "Office Mac" and the user is working on "My MacBook"
    When the user opens the project
    Then it opens on the folder of "My MacBook"
    And the folder on "Office Mac" is still listed as one of its folders

  @backlog @desktop
  Scenario: A folder registered twice in one environment is listed once
    Given "My MacBook" has two projects for the folder "/work/shop"
    When the user looks at the thread list
    Then the folder is listed once
    And the project that changed last is the one used
    And the threads of both projects are listed

  @backlog @desktop
  Scenario: A folder whose repository is not known yet stays with its group
    Given "shop" on "My MacBook" is grouped with "shop" on "Office Mac" by their repository
    When "My MacBook" sends an update for "shop" before its repository has been looked up again
    Then "shop" stays grouped with "shop" on "Office Mac"

  @backlog @desktop
  Scenario: A project's repository is kept from the freshest copy that has one
    Given "My MacBook" has two projects for the folder "/work/shop"
    And only the older one has a repository
    When the user looks at the thread list
    Then the folder is grouped by that repository

  @desktop @priority-high
  Scenario: Removing a project that still has threads asks first
    Given the user has turned on the legacy sidebar
    And "shop" has 3 threads
    When the user removes "shop" from its menu
    Then the user is told "Project is not empty"
    And the user is offered "Delete anyway"
    When the user chooses "Delete anyway" and confirms
    Then "shop" and its 3 threads are removed

  # The title leads; the project and its branch sit under it, the branch losing its middle when
  # long. The TUI still leads with the project (apps/tui/src/host/sidebarState.ts).
  @desktop @tui @backlog-tui
  Scenario: A thread row reads its title first, then its project and branch
    Given the thread "Fix the cart" in "shop" works on the branch "feature/cart"
    When the user looks at its row in the thread list
    Then the row's first line reads "Fix the cart"
    And its second line reads "shop · feature/cart"

  # Upstream #25415: phone rows lead with the title beside the project icon and drop the branch;
  # the line under it names the machine, pull request and provider.
  @backlog @mobile
  Scenario: A thread row on the phone leads with its title and leaves out the branch
    Given the thread "Fix the cart" in "shop" works on the branch "feature/cart" with pull request 42
    When the user looks at its row in the thread list on the phone
    Then the row leads with "Fix the cart" beside the icon of "shop"
    And the line under it names the thread's machine, pull request 42 and its provider
    And the row does not name "feature/cart"

  @desktop @backlog-desktop @mobile @backlog-mobile
  Scenario: A thread row shows its project's icon
    Given the projects "shop" and "ops" have icons
    When the user looks at the thread list with every project in scope
    Then each slim and card row shows the icon of its project
    And a project without an icon shows its monogram

  # Proved by tst_SidebarThreadRow.qml (test_restingRowGivesTheTitleTheSlot).
  @desktop @backlog-desktop @priority-low
  Scenario: A resting row gives its title the status slot's room
    Given a thread with a long title that was last active a minute ago
    When the user looks at its row in the thread list
    Then the title runs up to the row's age
    When the user points at the row
    Then the title shortens to make room for the row's actions

  @desktop @backlog-desktop
  Scenario: The thread list announces only the threads it shows
    Given the thread list is scoped to the project "shop"
    When a screen reader reads the thread list
    Then it reads only the rows the list draws

  @desktop @backlog-desktop
  Scenario: Projects with the same name can be told apart in the scope menu
    Given the projects "e2e-project" at "/a/work/e2e-project" and "/b/tmp/e2e-project"
    When the user opens the scope menu
    Then the entries read "e2e-project" with "work" and "e2e-project" with "tmp"
    And a project with a unique name has nothing after its name

  @desktop @backlog-desktop
  Scenario: The scope menu marks a project whose thread needs attention
    Given a thread of "qml-ghostty" stopped on a usage limit
    When the user opens the scope menu
    Then the entry for "qml-ghostty" says "a thread hit a usage limit"

  # Proved by tst_Sidebar.qml (test_scopeMenuShowsEveryProjectsMark).
  @desktop @backlog-desktop
  Scenario: The scope menu shows each project's icon or initial
    Given the project "shop" has an icon and "t3code-tracker-plugin" has none
    When the user opens the scope menu
    Then the entry for "shop" shows its icon
    And the entry for "t3code-tracker-plugin" shows the initial "T"
    And the hint "a thread failed" reads whole

  @desktop @backlog-desktop
  Scenario: A thread opened from search is brought into view in the sidebar
    Given more settled threads than the sidebar lists
    When the user opens a settled thread past the listed ones from search
    Then the sidebar has a row for it and scrolls it into view
    And a folded Settled section still shows it

  # Upstream #13759: settled threads that settled at the same moment are ordered by id, not by
  # the order the MC sent them.
  @desktop @mobile @backlog
  Scenario: Settled threads with the same settle time are listed in id order
    Given threads "t2" and "t1" settled at the same moment
    When the settled shelf is shown
    Then "t1" is listed before "t2" whatever order the MC sent them in

  # Upstream #13491: a row is announced by its title first, and the open thread as current.
  @desktop @backlog
  Scenario: A screen reader hears a thread's title first and which thread is open
    Given the thread "Fix checkout" is open
    When a screen reader reads the thread list
    Then each row is announced by its title first
    And the open thread is announced as current

  # Upstream #13491: the thread rows are reached in order, before the settled shelf and its footer.
  @desktop @backlog
  Scenario: A screen reader reaches the thread rows in order before the settled shelf
    Given threads "one" and "two" are listed above a settled shelf
    When a screen reader moves through the sidebar from its first thread
    Then "one" and then "two" are reached before the settled shelf and its footer

  @desktop @mobile @backlog-mobile
  Scenario: The Working section folds away busy threads
    Given Working section is on in General settings
    When threads are working, connecting or monitoring
    Then they move into a collapsed Working section above Snoozed and Settled
    And a thread returns to the top of the inbox when it finishes, fails or asks for approval or an answer
    And drag reordering in the inbox is off while it is on

  # Upstream #25190: the Working section was off unless turned on; it now starts on.
  @desktop @mobile @backlog-mobile @priority-low
  Scenario: The Working section is on until the user turns it off
    Given the user never changed whether the Working section is on
    When threads are working
    Then they move into the Working section
    And restoring the setting's default turns the Working section back on

  # Upstream #26195: a thread on an environment that stopped answering kept its last running
  # state and stayed hidden in the collapsed Working section.
  # Dropped: upstream reverted it in #31269. Threads left the Working section while their rows
  # still said "Working 39m", so the list contradicted itself; see the scenario below.
  @dropped @desktop @mobile
  Scenario: A thread whose environment stopped answering leaves the Working section
    Given the Working section is on and collapsed
    And "Fix login" is working on an environment that then stops answering
    Then "Fix login" is listed in the inbox where the user can see it
    And it goes back into the Working section once the environment reconnects and reports it working
    And threads keep their place while their environment is connecting for the first time

  # Upstream #31269: reverts #26195; the Working section follows the thread's working state only.
  @backlog @desktop @mobile
  Scenario: A working thread stays in the Working section while its environment is disconnected
    Given the Working section is on
    And "Fix login" is working on an environment that then stops answering
    Then "Fix login" stays in the Working section while it still says it is working

  # Upstream #24610: background shells never held a thread in Working and monitors always did,
  # but either can be a wait or a process left running, and only the agent knows which.
  @mc @shared @backlog-desktop @backlog-mobile @backlog-tui @priority-high
  Scenario Outline: Only background work the agent waits on keeps a finished thread Working
    Given the Working section is on
    And "Fix login" ended its turn leaving <work> running
    Then "Fix login" <outcome>

    Examples:
      | work                                         | outcome                       |
      | a background command the agent waits on      | stays in the Working section  |
      | a monitor the agent waits on                 | stays in the Working section  |
      | a subagent                                   | stays in the Working section  |
      | a background command the agent did not mark  | moves to the inbox            |
      | a monitor the agent did not mark             | moves to the inbox            |

    # The MC watches every link of an unsettled thread and has no explicit watch to
    # hold on yet (source-control/pull-request-threads.feature, watch_pull_request).
    @backlog
    Examples:
      | work                                         | outcome                       |
      | a pull request watch                         | stays in the Working section  |

  # Upstream #24610: Claude implements the mark on its background-task roster; other providers return unsupported.
  @mc @plugin-claude
  Scenario: A Claude agent marks the background work it waits on and can clear the mark
    Given Claude left the background commands "tests" and "dev server" running in "Fix login"
    When Claude marks "tests" as work it waits on
    Then "Fix login" stays Working until "tests" ends
    And marking a command that is not running reports it as unmatched and changes nothing
    When Claude marks "dev server" as work it waits on
    Then "dev server" holds "Fix login"
    When Claude clears the mark on "dev server"
    Then "dev server" no longer holds "Fix login"

  # Upstream #24610: other providers return "unsupported" for the wait mark and keep today's behaviour.
  @mc
  Scenario: Agents that cannot mark their waits keep holding only for subagents
    Given a Codex thread asks to mark a background command as work it waits on
    Then the mark is refused as unsupported
    And only the thread's subagents keep it Working

  @backlog @shared
  Scenario: Project order is a setting
    When the user picks a Project order in General settings
    Then the sidebar sorts projects that way
    And Restore defaults resets it

  @shared @backlog-mobile @backlog-tui @priority-high
  Scenario: Working threads keep their order while agents finish and wake
    Given several threads are in the Working section
    When an agent run ends, or a subagent result or pull request watch wakes a thread
    Then the section is ordered by the last message the user sent, newest first, and no row moves

  # Upstream #24760: a thread that stops working waits two seconds in Working, so a run that
  # continues or a settle that follows does not flash it through the inbox.
  # Upstream #28169: on the phone a finished thread stayed in Working until another update came.
  @desktop @mobile @backlog-mobile
  Scenario Outline: A thread that stops working waits briefly before it leaves Working
    Given the Working section is on
    And "Fix login" is in the Working section
    When its run ends and <next> within two seconds
    Then "Fix login" <outcome>

    Examples:
      | next                                     | outcome                                          |
      | its next run starts                      | never leaves the Working section                 |
      | the MC settles it                        | moves straight to Settled, never to the inbox    |
      | nothing else happens                     | moves to the inbox once the two seconds are up   |
      | it asks for approval                     | moves to the inbox at once                       |

  @backlog @desktop @priority-low
  Scenario: Dragging across rows settles, un-settles or wakes them together
    When the user presses a row's Settle, Un-settle or Wake button and drags across nearby rows
    Then releasing applies the action to every row swept in that section
    And Escape or losing focus cancels it, and a plain click keeps its single-row action

  @shared @backlog-mobile @backlog-tui
  Scenario: A thread's status has a spoken name
    When a screen reader reaches a thread's status marker
    Then it announces Working, Awaiting input or Pending approval

  # Upstream #22887: a reorder among keyless rows tried to write an order to an offline machine
  # and failed partway; offline rows now keep their order and are not written.
  @desktop @mobile @backlog-mobile @priority-high
  Scenario: A drop in the sidebar sticks when another machine is offline
    Given the Working section is off
    And the sidebar shows rows from a machine that is offline or asleep
    When the user drops a thread among rows that have no order yet
    Then the thread lands where it was dropped
    And rows that cannot store an order are not written

  # Upstream #20808: subagent threads a provider starts itself are not listed in the sidebar,
  # do not reorder projects and are skipped by the next and previous thread keys.
  @backlog @shared
  Scenario: A provider's own subagent threads are not sidebar rows
    Given thread "Fix cart" in project "shop" has a subagent thread its provider started
    When the subagent works
    Then the sidebar lists "Fix cart" but not the subagent thread
    And "shop" does not move up because of the subagent's activity
    And moving to the next thread from "Fix cart" skips the subagent thread

  # Upstream #21039: an opt-in "Boring sidebar (group by project)" setting puts active threads in a
  # folder per project, between the pinned threads and the snoozed and settled shelves. It replaced
  # the legacy per-project tree upstream; users who had that on land in this mode.
  @backlog @desktop
  Scenario: The user can group active threads into a folder per project
    Given "shop" and "docs" each have active threads and "shop" has a pinned thread
    When the user turns on "Boring sidebar (group by project)"
    Then the pinned thread is listed first
    And the active threads are listed in a folder for "shop" and a folder for "docs", in project order
    And the snoozed and settled sections follow the folders
    When the user turns it off
    Then the thread list is grouped by attention again

  # Upstream #21039: a closed folder counts its threads and says when a hidden one needs the user.
  @backlog @desktop
  Scenario: A closed project folder says what it hides
    Given the user groups the thread list by project
    And a thread in "shop" is waiting for an approval
    When the user closes the folder for "shop"
    Then the folder's threads are hidden
    And the folder shows how many threads it holds and that one needs the user
    When the user opens the folder for "shop"
    Then its threads are shown again

  # Upstream #21039: each folder starts a thread in its project and has a menu of New thread,
  # Copy path and Project settings.
  @backlog @desktop
  Scenario Outline: A project folder acts on its project
    Given the user groups the thread list by project
    When the user chooses "<action>" from the folder for "docs"
    Then <result>

    Examples:
      | action           | result                                         |
      | New thread       | a new thread starts in "docs"                  |
      | Copy path        | the folder of "docs" is on the clipboard       |
      | Project settings | the settings for "docs" open                   |

  # Upstream #21039: folders are part of the keyboard tree.
  @backlog @desktop
  Scenario Outline: Moving through project folders with the keyboard
    Given the user groups the thread list by project
    And the thread list has keyboard focus on <start>
    When the user presses <key>
    Then <result>

    Examples:
      | start                         | key   | result                                       |
      | the open folder for "shop"    | Left  | the folder for "shop" closes                 |
      | the closed folder for "shop"  | Right | the folder for "shop" opens                  |
      | the open folder for "shop"    | Right | the first thread of "shop" is focused        |
      | the first thread of "shop"    | Left  | the folder for "shop" is focused             |

  # Upstream #21039: a filter of several projects shows one folder for each.
  @backlog @desktop
  Scenario: A filter of several projects shows a folder for each
    Given the user groups the thread list by project
    When the user scopes the thread list to "shop" and "docs"
    Then the list shows a folder for "shop" and a folder for "docs" and no other

  # Upstream #21039: dragging and the Working section are off while threads are grouped by project.
  @backlog @desktop @priority-low
  Scenario: Grouping by project turns off dragging and the Working section
    Given the user groups the thread list by project
    When the user looks at the thread list
    Then there is no Working section
    And threads cannot be dragged into place

  # Upstream #26387: a project gets a folder only while it has active threads, unless the user
  # filtered to it, so a thread can still be started there.
  @backlog @desktop
  Scenario: A project without active threads has no folder unless the user filtered to it
    Given the user groups the thread list by project
    And "docs" has only settled threads
    When the user looks at the thread list
    Then there is no folder for "docs"
    When the user scopes the thread list to "docs"
    Then the list shows an empty folder for "docs"

  # Upstream #26387: settling a project's last active thread takes its folder away.
  @backlog @desktop
  Scenario: Settling a project's last active thread removes its folder
    Given the user groups the thread list by project
    And "Fix docs" is the only active thread in "docs"
    When the user settles "Fix docs"
    Then there is no folder for "docs"

  # Upstream #26391: inside a folder, threads follow the user's latest message; agent turns and
  # wakes do not move them.
  @backlog @desktop
  Scenario: A project folder lists the thread the user last wrote to first
    Given the user groups the thread list by project
    And "Alpha", "Bravo" and "Charlie" in "shop" were started in that order
    When the user sends a message to "Alpha"
    Then "Alpha" is listed first in the folder for "shop"
    When the agent in "Bravo" wakes and replies
    Then "Alpha" is still listed first in the folder for "shop"

  # Upstream #26463: an opt-in "Two-line folder rows" setting shows a folder thread's branch,
  # pull request, terminals and agent on a second line; a row with none of them stays one line.
  @backlog @desktop @priority-low
  Scenario: Folder threads can show their branch and pull request on a second line
    Given the user groups the thread list by project
    And "Alpha" in "shop" works on the branch "feature/cart" and "Bravo" has no branch
    When the user turns on "Two-line folder rows"
    Then the row for "Alpha" shows "feature/cart" below its title
    And the row for "Bravo" is one line
    When the user turns off "Two-line folder rows"
    Then the row for "Alpha" is one line

  # Upstream #26392: settling from the list moved focus to the settled shelf and scrolled the
  # list to the bottom, away from the next thread.
  @backlog @desktop @tui
  Scenario: Settling a thread from the list keeps the list where it was
    Given there are 30 active threads and the user is viewing "Active 1" at the top of the list
    When the user settles "Active 1" from the thread list
    Then the thread list stays at the top
    And the next thread is shown and in view
