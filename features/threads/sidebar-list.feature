# Sources:
#   docs/user/thread-sidebar.md
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml
#   apps/desktop-qt/tests/tst_Sidebar.qml
#   apps/desktop-qt/src/native/SidebarModel.cpp (the desktop's port of the grouping and order, offline rows)
#   apps/desktop-qt/src/native/LayoutController.cpp (hiding the thread list)
#   apps/web/src/components/Sidebar.tsx
#   apps/web/src/components/Sidebar.logic.ts
#   apps/web/src/hooks/useSidebarProjectGroups.ts
#   apps/web/src/components/NoProjectsHero.tsx
#   apps/web/src/components/NoActiveThreadState.tsx
#   apps/tui/src/components/Sidebar.logic.ts
#   packages/contracts/src/shell.ts (thread.open, draft.open, thread.new, sidebar.scope, sidebar.toggle, project.add, thread.menu)
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

  @desktop @mobile @backlog-mobile
  Scenario: A settled thread's age counts from when it settled
    Given "Alpha" settled after "Beta"
    And "Beta" was renamed since
    When the user looks at the settled section
    Then the rows for "Alpha" and "Beta" count their ages from when they settled

  @desktop @tui
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

  @desktop
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

  @desktop
  Scenario: Enter on a shelf header folds the shelf
    Given the thread list has keyboard focus on the settled section header
    When the user presses Enter
    Then the settled section collapses

  @desktop
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

  @desktop
  Scenario: Adding a project from the thread list
    When the user adds a project from the thread list
    Then the user can choose a project to add

  @desktop
  Scenario: Hiding and showing the thread list
    When the user hides the thread list
    Then the main view takes the full width
    When the user shows the thread list
    Then the thread list is back

  @desktop
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

  @desktop
  Scenario: Jump hints appear while holding the modifier
    When the user holds the thread jump modifier
    Then the first nine threads show their jump numbers after a short delay

  @desktop @mobile @backlog-mobile
  Scenario: The list catches up after a reconnect
    Given the client was disconnected while two threads were created
    When the client reconnects
    Then both threads are listed without reloading the whole list
    And the MC sent only the two new threads

  @desktop @mobile @backlog-mobile
  Scenario: The list starts over when its MC restarted
    Given the client was disconnected while its MC restarted and lost a thread
    When the client reconnects
    Then the MC sent its whole list
    And the lost thread is no longer listed

  @desktop @mobile @backlog-mobile
  Scenario: Threads on an offline environment are still listed
    Given the environment "work" is offline
    When the user looks at the thread list
    Then the threads from "work" are listed as unavailable
    And actions that need "work" are unavailable

  @backlog @desktop
  Scenario: The snoozed section lists the thread that wakes first at the top
    Given "Fix login" is snoozed until tomorrow
    And "Refactor cart" is snoozed until next week
    When the user looks at the snoozed section
    Then "Fix login" is listed above "Refactor cart"

  @backlog @desktop
  Scenario: A shelf stays open or closed the way the user left it
    Given the user expanded the settled section
    And the user left the snoozed section collapsed
    When the user restarts the app
    Then the settled section is expanded
    And the snoozed section is collapsed

  @backlog @desktop
  Scenario: Shelves start collapsed
    Given the user has never opened a shelf
    When the user looks at the thread list
    Then the snoozed and settled sections show only how many threads they hold

  @backlog @desktop
  Scenario: The open thread stays visible behind a collapsed shelf
    Given the user is viewing a settled thread
    And the settled section is collapsed
    When the user looks at the thread list
    Then the open thread is still listed under the settled section

  @backlog @desktop
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

  @backlog @desktop
  Scenario: Opening a project's settings from the project filter
    When the user opens the project filter
    And the user chooses the settings of "docs" beside its name
    Then the filter closes
    And the settings for "docs" open

  @backlog @desktop
  Scenario: The project filter is remembered across restarts
    Given the user scoped the list to "docs"
    When the user restarts the app
    Then the list is scoped to "docs"

  @backlog @desktop
  Scenario: A remembered project filter waits until every environment has reported
    Given the user scoped the list to "docs" before closing the app
    When the app starts and the environment "work" has not reported its projects yet
    Then the list stays scoped to "docs"
    When every environment has reported and "docs" is gone
    Then the list shows every project

  @backlog @desktop
  Scenario: Leaving the thread list for settings keeps the project filter
    Given the user scoped the list to "docs"
    When the user opens settings and then returns to the threads
    Then the list is still scoped to "docs"

  @backlog @desktop
  Scenario: The project filter shows the project it is scoped to
    Given the user scoped the list to "docs"
    When the user looks at the project filter
    Then it names "docs" and shows the project's icon

  @backlog @desktop
  Scenario: An empty project is named in the empty list
    Given the user scoped the list to "docs"
    And "docs" has no threads
    When the user looks at the thread list
    Then the list says "No threads in docs yet"

  @backlog @desktop
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

  @backlog @desktop
  Scenario: A thread row shows the providers it was handed over from
    Given "Beta" ran on Codex, then on Claude, then on OpenCode
    When the user looks at the thread list
    Then the row for "Beta" shows the three providers with OpenCode, where it runs now, last

  @backlog @desktop
  Scenario: A thread row shows the newest of its earlier providers when there are many
    Given "Beta" ran on Codex, then Claude, then Cursor, then OpenCode and now runs on Grok
    When the user looks at the thread list
    Then the row for "Beta" shows Cursor, OpenCode and Grok with Grok last
    And Codex and Claude are not shown on the row

  @backlog @desktop
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

  @backlog @desktop
  Scenario: Pointing at a pull request on a row lists the chain or stack
    Given "Beta" is linked to a stack of 3 pull requests
    When the user points at the pull requests on the row for "Beta"
    Then the user sees each pull request with its state and its place in the stack

  @backlog @desktop
  Scenario: A thread row keeps a finished pull request after the checkout moves on
    Given "Beta" works in the local checkout and its pull request 12 is merged
    When the checkout switches to another branch
    Then the row for "Beta" still shows pull request 12

  @backlog @desktop
  Scenario: A thread row drops an open pull request that no longer matches the checkout
    Given "Beta" works in the local checkout and its pull request 12 is open
    When the checkout switches to another branch
    Then the row for "Beta" no longer shows pull request 12

  @backlog @desktop
  Scenario: A thread with unsent text in its composer is marked on its row
    Given the user typed a message in the composer of "Beta" and did not send it
    And "Alpha" is the open thread
    When the user looks at the thread list
    Then the row for "Beta" says "Unsent draft"
    When the user discards the draft from the row
    Then the composer of "Beta" is empty
    And the row for "Beta" no longer says "Unsent draft"

  @backlog @desktop
  Scenario: A large change to the list does not animate every row
    Given the thread list shows hundreds of threads
    When the user scopes the list to one project
    Then the list changes at once without animating the rows that appear or leave

  @backlog @desktop
  Scenario: Rows slide when the list changes a little
    Given the user does not prefer reduced motion
    When a thread is snoozed and leaves the active section
    Then the rows below it slide up and the thread fades out

  # The legacy per-project tree: the user's switch to it is the "Sidebar (legacy)" setting.
  # Keep-or-drop is the maintainers' call; see the audit report.
  # Likely already implemented: apps/desktop-qt/qml/HalC2/Bricks/js/settingsRows.js (legacySidebarEnabled)
  @backlog @desktop
  Scenario: The user can switch the thread list to one tree of threads per project
    Given the user has not turned on the legacy sidebar
    When the user turns on "Sidebar (legacy)" in settings
    Then the thread list shows each project with its own threads beneath it
    When the user turns it off
    Then the thread list is grouped by attention again

  @backlog @desktop
  Scenario: A project in the tree folds and unfolds its threads
    Given the user has turned on the legacy sidebar
    When the user folds "shop" in the thread list
    Then the threads of "shop" are hidden
    When the user unfolds "shop"
    Then the threads of "shop" are shown again

  @backlog @desktop
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

  @backlog @desktop
  Scenario Outline: The number of threads a project shows is limited to a sensible range
    Given the user has turned on the legacy sidebar
    When the user sets the visible thread count to <typed>
    Then each project shows <shown> threads before offering more

    Examples:
      | typed | shown |
      | 0     | 1     |
      | 8     | 8     |
      | 40    | 15    |

  # Likely already implemented: apps/desktop-qt/src/native/SidebarController.cpp (sidebarProjectSortOrder, sidebarThreadSortOrder)
  @backlog @desktop
  Scenario Outline: The user chooses how projects and threads are sorted
    Given the user has turned on the legacy sidebar
    When the user sorts <what> by "<order>"
    Then <what> are listed <result>

    Examples:
      | what     | order             | result                                          |
      | projects | Last user message | by the latest message the user sent in each     |
      | projects | Created at        | by when each project's threads were started     |
      | projects | Manual            | in the order the user arranged them             |
      | threads  | Last user message | by the latest message the user sent in each     |
      | threads  | Created at        | by when each thread was started                 |

  @backlog @desktop
  Scenario: Projects are dragged into place only when they are sorted by hand
    Given the user has turned on the legacy sidebar
    And projects are sorted "Manual"
    When the user drags "docs" above "shop"
    Then "docs" is listed above "shop"
    And the user's order is remembered
    When the user sorts projects by "Created at"
    Then dragging a project does not move it

  @backlog @desktop
  Scenario Outline: Renaming a project from its menu
    Given the user has turned on the legacy sidebar
    When the user renames "shop" from its menu to "<title>"
    Then <result>

    Examples:
      | title      | result                                                       |
      | store      | "shop" is now called "store"                                 |
      | shop       | nothing is sent and the dialog closes                        |
      |            | the user is told "Project title cannot be empty"             |

  @backlog @desktop
  Scenario: A project rename the environment refuses is reported
    Given the user has turned on the legacy sidebar
    And the environment refuses to rename "shop"
    When the user renames "shop" from its menu to "store"
    Then the user is told "Failed to rename project"

  # Likely already implemented: apps/desktop-qt/src/native/SidebarController.cpp (sidebarProjectGroupingOverrides)
  @backlog @desktop
  Scenario Outline: A project chooses how it is grouped regardless of the device's default
    Given the user has turned on the legacy sidebar
    When the user groups "shop" by "<choice>" from its menu
    Then "shop" is grouped <result>

    Examples:
      | choice                   | result                                   |
      | Group by repository      | with the other folders of its repository |
      | Group by repository path | with the folders of its repository path  |
      | Keep separate            | on its own                               |
      | the device's default     | the way the device's default says        |

  @backlog @desktop
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

  @backlog @desktop
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

  @backlog @desktop
  Scenario: Removing a project that still has threads asks first
    Given the user has turned on the legacy sidebar
    And "shop" has 3 threads
    When the user removes "shop" from its menu
    Then the user is told "Project is not empty"
    And the user is offered "Delete anyway"
    When the user chooses "Delete anyway" and confirms
    Then "shop" and its 3 threads are removed

  @desktop @backlog-desktop @mobile @backlog-mobile
  Scenario: A thread row shows its project's icon
    Given the projects "shop" and "ops" have icons
    When the user looks at the thread list with every project in scope
    Then each slim and card row shows the icon of its project
    And a project without an icon shows its monogram

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

  @desktop @backlog-desktop
  Scenario: A thread opened from search is brought into view in the sidebar
    Given more settled threads than the sidebar lists
    When the user opens a settled thread past the listed ones from search
    Then the sidebar has a row for it and scrolls it into view
    And a folded Settled section still shows it
