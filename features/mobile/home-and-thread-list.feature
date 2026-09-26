# Sources:
#   apps/mobile/src/features/home/ (thread list options, empty states, search, connection status)
#   apps/mobile/src/features/threads/thread-list-v2-items.tsx (status labels, shelves)
#   apps/mobile/src/features/threads/threadListV2.ts (settled tail paging)
#   apps/mobile/src/features/archive/ArchivedThreadsScreen.tsx
#   apps/mobile/src/features/archive/archivedThreadList.ts
#   apps/mobile/src/features/projects/AddProjectScreen.tsx
#   apps/mobile/src/features/projects/AddProjectScreen.logic.ts
#   apps/mobile/src/state/pending-new-tasks-model.ts
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
  Scenario: The user searches threads by title
    When the user searches threads for "checkout"
    Then only threads whose title matches "checkout" are listed

  @backlog @mobile
  Scenario: A search with no matches says so
    When the user searches threads for "zzz"
    Then the user is told there are no results

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
