# Sources:
#   apps/mobile/src/features/home/ (thread list options, empty states, search, connection status)
#   apps/mobile/src/features/threads/thread-list-v2-items.tsx (status labels, shelves)
#   apps/mobile/src/features/threads/thread-provider-instance.ts (provider account badge on a row)
#   apps/mobile/src/features/threads/ThreadNavigationSidebar.tsx (environment and project choices, environment on a row, empty list)
#   apps/mobile/src/features/threads/threadListV2.ts (settled tail paging, queued messages keep a thread active)
#   apps/mobile/src/features/threads/thread-search-match.tsx (message excerpt with You:/Agent:)
#   apps/mobile/src/features/archive/ArchivedThreadsScreen.tsx
#   apps/mobile/src/features/archive/archivedThreadList.ts
#   apps/mobile/src/features/projects/AddProjectScreen.tsx
#   apps/mobile/src/features/projects/AddProjectScreen.logic.ts
#   apps/mobile/src/state/pending-new-tasks-model.ts
#   apps/mobile/src/state/pending-thread-creation.ts (stand-in thread while a new task is sent)
#   apps/mobile/src/components/ProjectFavicon.tsx, apps/mobile/src/lib/projectFaviconRequests.ts, projectFaviconDatabaseCache.ts (project icon placeholder and cache)
#   apps/mobile/src/state/use-thread-selection.ts, use-thread-pr.ts, thread-pr-presentation.ts
# Thread lifecycle (settle, snooze, pin) is specified in features/threads/. This file covers
# the phone home screen, which lists threads across every paired environment.

Feature: Home screen and thread list on a phone
  The phone opens on a single list of threads from every paired environment, grouped by
  project, with a status line that tells the user whether what they see is current.

  Background:
    Given the phone is paired with "My MacBook" and "Office Mac"

  @backlog @mobile
  Scenario: Home lists threads from every paired environment
    When the user opens the app
    Then threads from "My MacBook" and "Office Mac" are listed together

  @backlog @mobile
  Scenario: The user narrows the list to one environment
    When the user shows only "Office Mac"
    Then only threads from "Office Mac" are listed

  @backlog @mobile
  Scenario: The user widens the list back to all environments
    Given the list shows only "Office Mac"
    When the user shows all environments
    Then threads from every paired environment are listed

  @backlog @mobile
  Scenario: The user narrows the list to one project and back
    When the user shows only the project "shop"
    Then only threads in "shop" are listed
    When the user shows all projects
    Then threads from every project are listed

  @backlog @mobile
  Scenario: List options survive rotating to a tablet layout
    Given the list shows only "Office Mac"
    When the screen becomes wide enough for a sidebar
    Then the sidebar still shows only "Office Mac"

  @backlog @mobile
  Scenario: The project choices follow the environment shown
    Given "Office Mac" has the project "docs" and "My MacBook" has the project "shop"
    When the user shows only "Office Mac"
    Then the user can choose the project "docs"
    And the user cannot choose the project "shop"

  @backlog @mobile
  Scenario: A project that is gone stops narrowing the list
    Given the list shows only the project "docs"
    When "docs" is removed from its environment
    Then threads from every project are listed

  @backlog @mobile
  Scenario: An environment that is unpaired stops narrowing the list
    Given the list shows only "Office Mac"
    When the user removes "Office Mac" from the phone
    Then threads from every paired environment are listed

  @backlog @mobile
  Scenario: The same repository on two environments is one project in the list
    Given "My MacBook" and "Office Mac" both have a checkout of the repository "shop"
    When the user looks at the list
    Then the threads of both checkouts are listed under one project "shop"

  @backlog @mobile
  Scenario: Unrelated repositories that share a title stay separate projects
    Given "My MacBook" has a project "app" from one repository
    And "Office Mac" has a project "app" from another repository
    When the user looks at the list
    Then the two projects are listed separately

  @backlog @mobile
  Scenario: Projects are ordered by their latest activity
    Given "shop" has an older thread than "docs"
    When the user looks at the list
    Then "docs" is listed before "shop"
    When the user starts a new task in "shop"
    Then "shop" is listed before "docs"

  @backlog @mobile
  Scenario: Archived threads do not move a project up the list
    Given "docs" has a thread archived just now and "shop" has a thread active an hour ago
    When the user looks at the list
    Then "shop" is listed before "docs"

  @backlog @mobile
  Scenario: A thread row names its environment while the phone is paired with several
    Given "Fix cart" is a thread of "Office Mac"
    When the user looks at the list
    Then the row of "Fix cart" names "Office Mac"

  @backlog @mobile
  Scenario: A thread row does not name the environment when the phone has only one
    Given the user removed "Office Mac" from the phone
    And "Fix cart" is a thread of "My MacBook"
    When the user looks at the list
    Then the row of "Fix cart" does not name an environment

  @backlog @mobile
  Scenario Outline: A thread row marks its provider account only when the logo alone would not tell
    Given the thread "Fix cart" runs on the Codex account "Work" of its environment
    And <accounts>
    When the user looks at the list
    Then the row of "Fix cart" <badge>

    Examples:
      | accounts                                          | badge                                |
      | that environment has no other Codex account       | shows the provider without the badge |
      | that environment has a second Codex account       | marks it as the "Work" account       |
      | "Work" has an accent colour set                   | marks it as the "Work" account       |
      | another environment has a second Codex account    | shows the provider without the badge |

  @backlog @mobile
  Scenario: A project with no threads is named in the empty list
    Given the list shows only the project "docs"
    And "docs" has no threads
    Then the list says "No threads in docs"

  @backlog @mobile
  Scenario: The user searches threads by title
    When the user searches threads for "checkout"
    Then only threads whose title matches "checkout" are listed

  @backlog @mobile
  Scenario: A search with no matches says so
    When the user searches threads for "zzz"
    Then the user is told there are no results

  @backlog @mobile
  Scenario: The user searches what was said in a thread, not only its title
    Given the user wrote "the checkout total is wrong" in "Fix cart"
    When the user searches threads for "checkout"
    Then "Fix cart" is listed with a short excerpt of that message
    And the excerpt says it was written by "You:" and highlights "checkout"

  @backlog @mobile
  Scenario: A match in the agent's reply is attributed to the agent
    Given the agent wrote "the checkout total now rounds" in "Fix cart"
    When the user searches threads for "checkout"
    Then "Fix cart" is listed with an excerpt attributed to "Agent:"

  @backlog @mobile
  Scenario: A settled thread with queued messages is listed with the active ones
    Given the thread "Fix cart" is settled
    And the user queued a message for "Fix cart" while the phone had no connection
    When the user looks at the thread list
    Then "Fix cart" is listed with the active threads and not on the settled shelf

  @backlog @mobile
  Scenario Outline: The status line tells the user how current the list is
    Given <situation>
    Then the list status reads "<status>"

    Examples:
      | situation                                   | status                    |
      | the phone has no network                    | You are offline           |
      | "Office Mac" is reconnecting                | Reconnecting to Office Mac |
      | both environments are reconnecting          | Reconnecting 2 environments |
      | the environments are catching up on threads | Syncing threads...        |
      | no environment is connected                 | Not connected             |

  @backlog @mobile
  Scenario: A connection that drops for less than a second shows no status
    Given the list is connected
    When "Office Mac" drops and reconnects within half a second
    Then the list status never appears

  @backlog @mobile
  Scenario: A connection that stays down shows its status after a short wait
    Given the list is connected
    When "Office Mac" has been reconnecting for a second
    Then the list status reads "Reconnecting to Office Mac"
    When "Office Mac" is connected again
    Then the list status goes away at once

  @backlog @mobile
  Scenario: Tapping the status line opens environment settings
    Given "Office Mac" is reconnecting
    When the user taps the list status
    Then the environment settings open

  @backlog @mobile
  Scenario Outline: Empty states explain what is missing
    Given <situation>
    Then the user is told "<message>"

    Examples:
      | situation                                      | message                       |
      | the environments are still loading             | Loading environments          |
      | the only environment has no projects           | No projects found             |
      | the only project has no threads                | No threads yet                |
      | the only environment is still connecting       | Connecting to environment     |
      | the only environment is unavailable            | Environment unavailable       |

  @backlog @mobile
  Scenario Outline: Each thread shows the status that needs the user most
    Given a thread <state>
    Then the thread is labelled "<label>"

    Examples:
      | state                                    | label    |
      | waits for the user to approve a command  | Approval |
      | asks the user a question                 | Input    |
      | has a turn running                       | Working  |
      | ended its last turn with an error        | Failed   |
      | hit a provider usage limit               | Limited  |
      | finished work the user has not looked at | Done     |

  @backlog @mobile
  Scenario: Opening a finished thread on another device clears its Done label on the phone
    Given a thread is labelled "Done"
    When the user opens that thread on the desktop
    Then the thread is no longer labelled "Done" on the phone

  @backlog @mobile
  Scenario Outline: A failed or limited thread says why on its row
    Given a thread <state> with the message "<reason>"
    Then the thread's row shows "<reason>" in place of its branch and environment

    Examples:
      | state                         | reason                       |
      | ended its last turn in error  | Process exited unexpectedly  |
      | hit a provider usage limit    | Usage limit reached          |

  @backlog @mobile
  Scenario: A thread that was handed off shows the agents it came from
    Given "Fix cart" was handed off from Codex to Claude
    Then the row of "Fix cart" shows the Claude icon with the Codex icon receding behind it

  @backlog @mobile
  Scenario: A thread with a message waiting to send is marked on its row
    Given the user queued a message for "Fix cart" that has not been sent
    Then the row of "Fix cart" is marked as having messages queued to send

  @backlog @mobile
  Scenario Outline: An unsent task says what happens to it next
    Given the list holds <task>
    Then the row says "<label>"
    And the row sits under the "Unsent" heading

    Examples:
      | task                                                   | label             |
      | a task written offline that is waiting to be sent      | Sends on reconnect |
      | a task that was written but not started                | Draft             |

  @backlog @mobile
  Scenario: A subagent's own thread is not listed but a fork of the thread is
    Given "Fix cart" has a subagent thread and a fork "Fix cart fork"
    When the user looks at the thread list
    Then "Fix cart" and "Fix cart fork" are listed
    And the subagent's thread is not listed
    When the user searches threads for the subagent's title
    Then the subagent's thread is not among the results

  @backlog @mobile
  Scenario: The thread being read stays listed when its shelf is collapsed
    Given the user is reading a settled thread on a tablet
    When the user collapses the settled shelf
    Then the thread being read is still listed
    And the shelf's other threads are hidden

  @backlog @mobile
  Scenario: Threads snoozed elsewhere stay listed on an environment that cannot snooze
    Given the environment predates snoozing threads
    And a thread there carries a snooze time
    Then the thread is listed with the active threads

  @backlog @mobile
  Scenario: The snoozed shelf can be collapsed and expanded
    Given some threads are snoozed
    When the user collapses the snoozed shelf
    Then snoozed threads are hidden
    When the user expands the snoozed shelf
    Then snoozed threads are listed

  @backlog @mobile
  Scenario: Collapsed shelves stay collapsed after the app restarts
    Given the user has collapsed the settled shelf
    When the app restarts
    Then the settled shelf is still collapsed

  @backlog @mobile
  Scenario: Long settled lists page in on request
    Given a project has 40 settled threads
    Then 10 settled threads are listed
    When the user asks to show more
    Then 35 settled threads are listed

  @backlog @mobile
  Scenario: The new task button hides while scrolling on Android
    Given the user is on an Android phone
    When the user scrolls down the thread list
    Then the new task button hides
    When the user scrolls back up
    Then the new task button shows again

  @backlog @mobile
  Scenario: The new task button on Android waits for an environment
    Given the user is on an Android phone
    And no environment is paired
    When the user looks at the home screen
    Then no new task button is shown

  @backlog @mobile
  Scenario: A task written offline waits in the list until it can be sent
    Given the phone has no network
    When the user starts a new task in "shop"
    Then the task is listed as pending in "shop"
    And the task is sent when the environment is reachable again

  @backlog @mobile
  Scenario: The user deletes a pending task before it is sent
    Given a pending task is waiting in "shop"
    When the user deletes the pending task and confirms
    Then the pending task is no longer listed
    And nothing is sent to the environment

  @backlog @mobile
  Scenario: Declining to delete a pending task keeps it waiting
    Given a pending task is waiting in "shop"
    When the user deletes the pending task and declines the question
    Then the pending task is still listed
    And it is still sent when the environment is reachable

  @backlog @mobile
  Scenario: A pending task that cannot be removed is reported and kept
    Given a pending task is waiting in "shop"
    And the phone cannot remove it from its waiting messages
    When the user deletes the pending task and confirms
    Then the user is told the pending task could not be deleted and why
    And the pending task is still listed

  @backlog @mobile
  Scenario: Discarding an unstarted task clears what was written
    Given the user wrote "Add search" in a new task for "shop" and left without starting it
    When the user discards the unstarted task and confirms
    Then no unstarted task is listed for "shop"
    And nothing is sent to the environment
    And the next new task for "shop" starts with the project's default model and workspace

  @backlog @mobile
  Scenario: Declining to discard an unstarted task keeps it
    Given the user wrote "Add search" in a new task for "shop" and left without starting it
    When the user discards the unstarted task and declines the question
    Then the unstarted task is still listed for "shop"

  @backlog @mobile
  Scenario: A new task that was written but not started is listed with the pending tasks
    Given the user wrote "Add search" in a new task for "shop" and left without starting it
    Then the unstarted task is listed in "shop" with the pending tasks
    When the user opens it
    Then the new task editor holds "Add search"

  @backlog @mobile
  Scenario: Unstarted tasks lead the pending tasks and each group is newest first
    Given "shop" has two unstarted tasks and two pending tasks
    Then the unstarted tasks are listed before the pending tasks
    And within each group the newest comes first

  @backlog @mobile
  Scenario: An unstarted task with only attachments is named by their count
    Given the user attached one photo to a new task for "shop" and wrote no text
    Then the unstarted task is listed as "1 attachment"
    When the user attaches a second photo
    Then it is listed as "2 attachments"

  @backlog @mobile
  Scenario: A new task with only a model choice is not listed
    Given the user opened a new task for "shop" and only picked a model
    Then no unstarted task is listed for "shop"

  @backlog @mobile
  Scenario: A new task opens its thread straight away while it is being sent
    Given the user starts a new task "Add search" in "shop" while offline
    Then the thread of "Add search" opens showing the prompt
    And its status says it is preparing
    And a follow-up cannot be sent until the thread exists

  @backlog @mobile
  Scenario: The prompt stays on screen until the environment has built the thread
    Given the environment has created the thread for "Add search" but is still preparing its worktree
    Then the thread still shows the prompt and says it is preparing
    When the first turn starts
    Then the real conversation replaces the stand-in

  @backlog @mobile
  Scenario Outline: A thread row shows the state of its pull request
    Given a thread is linked to pull request 12 which is <state>
    Then its row shows "#12" as <state>

    Examples:
      | state  |
      | open   |
      | draft  |
      | merged |
      | closed |

  @backlog @mobile
  Scenario Outline: A thread row says when several pull requests are linked
    Given a thread is linked to <links>
    Then its row shows <badge>

    Examples:
      | links                                 | badge                                 |
      | pull requests 12 and 14               | "#12" with a count of the linked ones |
      | a stack of 3 pull requests            | the stack and its 3 layers            |
      | pull request 12, status not yet known | "#12" with its status pending         |

  @backlog @mobile
  Scenario: A thread row keeps its last known pull request state while it refreshes
    Given a thread row showed pull request 12 as open
    When the row is scrolled away and back while the environment is unreachable
    Then the row still shows pull request 12 as open

  @backlog @mobile
  Scenario: Archived threads are listed newest first and can be searched
    Given the user has archived threads
    When the user opens archived threads
    Then archived threads are listed newest first
    When the user searches archived threads for "checkout"
    Then only matching archived threads are listed

  @backlog @mobile
  Scenario: The user unarchives a thread from the phone
    Given the thread "Fix checkout" is archived
    When the user unarchives "Fix checkout"
    Then "Fix checkout" is listed on the home screen again

  @backlog @mobile
  Scenario: No archived threads says where they will appear
    Given the user has no archived threads
    When the user opens archived threads
    Then the user is told threads they archive will appear there

  @backlog @mobile
  Scenario: Archived threads can be narrowed to one environment
    Given "My MacBook" and "Office Mac" each have archived threads
    When the user narrows archived threads to "Office Mac"
    Then only the archived threads of "Office Mac" are listed

  @backlog @mobile
  Scenario: Archived threads can be listed oldest first
    Given the user has archived threads
    When the user sorts archived threads by oldest first
    Then archived threads are listed oldest first

  @backlog @mobile
  Scenario Outline: Searching archived threads matches the project and the thread
    Given the archived thread "Fix checkout" on branch "feature/cart" in the project "shop" at "/work/shop" on "My MacBook"
    When the user searches archived threads for "<query>"
    Then "Fix checkout" is listed

    Examples:
      | query        |
      | checkout     |
      | feature/cart |
      | shop         |
      | /work/shop   |
      | MacBook      |

  @backlog @mobile
  Scenario: A search that names a project lists all of its archived threads
    Given the project "shop" has the archived threads "Fix checkout" and "Add coupons"
    When the user searches archived threads for "shop"
    Then both "Fix checkout" and "Add coupons" are listed under "shop"

  @backlog @mobile
  Scenario: A search with no archived matches says so
    Given the user has archived threads
    When the user searches archived threads for something none of them mention
    Then the user is told there are no matching threads
    And the user is told to try another search or environment

  @backlog @mobile
  Scenario: Archived threads are fetched again each time the user opens them
    Given the user archived "Fix checkout" on another device after the phone last listed archived threads
    When the user opens archived threads
    Then "Fix checkout" is listed

  @backlog @mobile
  Scenario: Archived threads say they are loading the first time
    Given the phone has not yet heard back about archived threads
    When the user opens archived threads
    Then the user is told the archive is loading

  @backlog @mobile
  Scenario: One environment that cannot be reached does not hide the other archives
    Given "Office Mac" cannot be reached
    And "My MacBook" has archived threads
    When the user opens archived threads
    Then the user is told not every archive could be loaded and why
    And the archived threads of "My MacBook" are still listed

  @backlog @mobile
  Scenario: A failed archive load can be tried again
    Given the user was told not every archive could be loaded
    When the user chooses to try again
    Then the phone asks the environments for their archived threads again

  @backlog @mobile
  Scenario Outline: The user adds a project from the phone
    When the user adds a project from <source>
    Then the project is listed on "My MacBook"

    Examples:
      | source                                |
      | a folder on the environment's disk    |
      | a clone of a remote Git URL           |

  @backlog @mobile
  Scenario: Adding a project that already exists is refused
    Given "My MacBook" already has the project "shop"
    When the user adds the same folder as a project again
    Then the user is told the project already exists

  @backlog @mobile
  Scenario: A project's icon shows a placeholder until its picture has loaded
    Given "shop" has a picture as its icon that has not loaded yet
    When the user looks at the thread list
    Then "shop" shows a folder placeholder
    And the picture replaces the placeholder once it has loaded

  @backlog @mobile
  Scenario: A project's picture that cannot be loaded keeps the placeholder
    Given "shop" has a picture as its icon that cannot be loaded
    When the user looks at the thread list
    Then "shop" keeps its folder placeholder

  @backlog @mobile
  Scenario: A project's icon seen before shows at once and without the network
    Given the user has seen the icon of "shop" in the thread list
    When the phone has no network and the user looks at the thread list again
    Then "shop" shows its icon at once

  @backlog @mobile
  Scenario: A project's icon is kept small on the phone
    Given "shop" has an icon picture larger than the phone needs
    When the user has looked at the thread list
    Then the phone keeps a reduced copy of the icon
    And an icon that cannot be reduced small enough is not kept

  @backlog @mobile
  Scenario: A project's changed icon replaces the one the phone remembered
    Given the phone remembers the icon of "shop"
    When the icon of "shop" is changed on the environment
    Then the thread list shows the new icon
    And the old icon is not shown again
