# Sources:
#   https://github.com/pingdotgg/t3code/pull/24262
#   https://github.com/pingdotgg/t3code/pull/24750
#   https://github.com/pingdotgg/t3code/pull/24742
#   https://github.com/pingdotgg/t3code/pull/23795
#   https://github.com/pingdotgg/t3code/pull/23841
#   https://github.com/pingdotgg/t3code/pull/24524
#   https://github.com/pingdotgg/t3code/pull/24644
#   https://github.com/pingdotgg/t3code/pull/21033
#   https://github.com/pingdotgg/t3code/pull/14697
#   https://github.com/pingdotgg/t3code/pull/17268
#   https://github.com/pingdotgg/t3code/pull/15068
#   https://github.com/pingdotgg/t3code/pull/15844
#   https://github.com/pingdotgg/t3code/pull/19292
#   https://github.com/pingdotgg/t3code/pull/22526
#   docs/internals/mobile-navigation.md (root stack, overlay routes, previews)
#   apps/mobile/src/Stack.tsx (route table, deep link prefixes, not found)
#   apps/mobile/src/features/shortcuts/ (Android launcher shortcuts, allowlisted links)
#   apps/mobile/src/features/threads/useThreadHeaderOptions.tsx (way to the thread list when the thread is the only screen)
#   apps/mobile/src/components/AndroidScreenHeader.tsx (Navigate up, header actions folded into More actions)
#   apps/mobile/app.config.ts (hal-c2, hal-c2-dev and hal-c2-preview schemes)
#   apps/mobile/plugins/withIosSceneLifecycle
#   apps/mobile-qt/qml/HalC2/Mobile/MobileShell.qml (screens follow the route; Back goes back one step)
# Desktop navigation and the command palette are specified in features/navigation/.
# This file covers links into the phone app and moving between phone screens. The one link the
# QML client answers so far, the link that pairs (hal-c2://pair), is in
# pairing-and-environments.feature.

Feature: Navigating the phone app and opening links into it
  Every screen a user can reach has a link, so a notification, widget, shortcut or shared
  link can land the user straight on the right thing with a sensible way back.

  Background:
    Given the phone is paired with "My MacBook"
    And "My MacBook" has the thread "Fix checkout"

  @mobile
  Scenario: Opening a thread keeps the home screen one step back
    When the user opens "Fix checkout" from the home screen
    Then going back returns to the home screen

  # Upstream #19292: on Android, Back from a thread whose turn was running often froze the app.
  @backlog @mobile @priority-high
  Scenario: Going back from a thread whose agent is working returns home at once
    Given an agent is working in "Fix checkout"
    And the user opened "Fix checkout" from the home screen
    When the user goes back
    Then the home screen is shown
    And the row for "Fix checkout" keeps counting how long it has been working

  # Upstream #22526: on a folded phone the list came back after Back, but picking another row
  # changed nothing.
  @backlog @mobile @priority-low
  Scenario: After going back on a folded phone another row opens
    Given the phone is folded and the user opened "Fix checkout"
    When the user goes back to the list
    And the user picks the thread "Port tests"
    Then "Port tests" is shown

  # Upstream #22526
  @backlog @mobile @priority-low
  Scenario: A back swipe the user cancels keeps the thread open
    Given the phone is folded and the user opened "Fix checkout"
    When the user starts a back swipe and lets it go back
    Then "Fix checkout" is still shown
    And going back afterwards returns to the list

  # Upstream #24742: on a split layout, picking a thread after the sidebar came back pushed a
  # new page each time, so Back stepped through every thread picked.
  @backlog @mobile
  Scenario Outline: Picking a thread from <where> replaces the page shown
    Given the user opened "Fix checkout"
    When the user picks the thread "Port tests" from <where>
    Then "Port tests" is shown
    And going back once returns to the home screen

    Examples:
      | where                                     |
      | the sidebar after unfolding the phone     |
      | the sidebar after hiding and showing it   |
      | the command palette                       |
      | a notification                            |
      | a link                                    |

  # Upstream #24742
  @backlog @mobile
  Scenario: A thread opened from inside a thread is a step forward
    Given the user opened "Fix checkout"
    When the user opens a pull request from "Fix checkout"
    And the user goes back
    Then "Fix checkout" is shown

  # Upstream #24262: opening a pull request while its environment was connecting moved it for
  # good to another connected copy of the repository.
  @backlog @mobile
  Scenario Outline: A pull request opens on the environment it was asked for while it <state>
    Given "My MacBook" and "Office Mac" both have the project "shop"
    And "Office Mac" <state>
    When the user opens pull request 42 of "shop" on "Office Mac"
    Then <outcome>

    Examples:
      | state             | outcome                                              |
      | is connecting     | it opens on "Office Mac" once it has connected       |
      | is reconnecting   | it opens on "Office Mac" once it has connected       |
      | is offline        | it opens on "My MacBook"                             |
      | was removed       | it opens on "My MacBook"                             |

  # Upstream #24742: a cold launch switched from Settings back to Chats showed the thread, then
  # an empty page.
  @backlog @mobile @priority-low
  Scenario: Returning to Chats after a fresh start shows the reopened thread once
    Given the app started again on "Fix checkout"
    When the user opens Settings and goes back to Chats
    Then "Fix checkout" is shown, with no empty page and no second transition

  # Upstream #24750: returning to Chats after leaving a new task's draft opened the last thread
  # instead of the draft.
  @backlog @mobile
  Scenario: Chats reopens the draft the user left it on
    Given the user was writing a new task in Chats
    When the user opens Settings and goes back to Chats
    Then the new task's draft is shown
    When the user opens "Fix checkout" and later leaves Chats and comes back
    Then "Fix checkout" is shown

  # Upstream #21033: Android Back from a subagent thread dropped its parent.
  @backlog @mobile
  Scenario: Back from a subagent's thread returns to the thread that started it
    Given the user opened "Fix checkout" from the home screen
    When the user opens a subagent's thread from "Fix checkout"
    And the user goes back
    Then "Fix checkout" is shown
    And going back again returns to the home screen

  # Upstream #17268: navigation is preserved after a native swipe back
  @backlog @mobile @priority-low
  Scenario: A tap right after swiping back opens what was tapped
    Given the user opened "Fix checkout" from the home screen
    When the user swipes back and at once taps "Fix checkout" again
    Then "Fix checkout" opens and stays open
    And a swipe back the user lets go of halfway leaves "Fix checkout" open with its history

  @backlog @mobile
  Scenario Outline: A link opens the matching screen for a thread
    When the user follows a link to the <place> of "Fix checkout"
    Then the <place> of "Fix checkout" is shown

    Examples:
      | place                  |
      | conversation           |
      | terminal               |
      | review                 |
      | files                  |
      | git actions            |
      | commit form            |
      | branch list            |
      | device viewer          |

  @backlog @mobile
  Scenario: A link to a file opens that file in the thread's files
    When the user follows a link to "src/cart.ts" in "Fix checkout"
    Then "src/cart.ts" is shown from the thread's workspace

  @backlog @mobile
  Scenario Outline: Links open app-level screens
    When the user follows a link to <place>
    Then <place> is shown

    Examples:
      | place                 |
      | a new task            |
      | adding a project      |
      | the environments list |
      | adding an environment |
      | settings              |

  @backlog @mobile
  Scenario: A link that the app does not know shows a way home
    When the user follows a link to a screen that does not exist
    Then the user is told the route was not found
    And the user is offered to return home

  @backlog @mobile
  Scenario: A link to a thread on an environment that is not paired explains why it cannot open
    When the user follows a link to a thread on an environment the phone is not paired with
    Then the user is told the thread is unavailable
    And the user can return home

  # Upstream #14697: thread links stay open until the shell is live
  @backlog @shared @mobile
  Scenario: A link to a thread the client has not seen yet waits for the environment
    Given the client still shows the thread list it saved before going offline
    When the user follows a link to a thread created since on another device
    Then the link stays on that thread while the environment catches up
    And the thread opens once it arrives, instead of a new thread
    And only a thread still missing once the environment is up to date leaves the link

  @backlog @mobile
  Scenario: A thread that is the only screen offers a way to the thread list
    Given the phone opened "Fix checkout" from a link with no screen behind it
    When the user looks at the thread's header
    Then the user is offered to go to the threads list
    When the user chooses to go to the threads list
    Then the home screen is shown in place of the thread

  @backlog @mobile
  Scenario: A bare app link does not reset where the user was
    Given the user is reading "Fix checkout"
    When the phone opens the app with a link that has no path
    Then "Fix checkout" is still shown

  @backlog @mobile @priority-low
  Scenario Outline: Each app build answers only its own link scheme
    Given the user has the <build> build installed
    When the user follows a "<scheme>" link
    Then the <build> build opens

    Examples:
      | build       | scheme           |
      | production  | hal-c2://        |
      | preview     | hal-c2-preview:// |
      | development | hal-c2-dev://    |

  @backlog @mobile @priority-low
  Scenario: Sheets and previews do not change the layout behind them
    Given the user is looking at "Fix checkout" beside the thread list on a tablet
    When the user opens settings over it
    And the user closes settings
    Then "Fix checkout" is still shown beside the thread list

  @backlog @mobile @priority-low
  Scenario: A preview stays open after its source disappears
    Given the user is previewing an image attached to a message
    When the message is removed from the thread
    Then the preview stays open until the user closes it

  @backlog @mobile @priority-low
  Scenario: Android launcher shortcuts offer a new task and recent threads
    Given the user is on an Android phone
    And the user recently opened "Fix checkout", "Add search" and "Refactor auth"
    When the user long presses the app icon
    Then the user is offered to start a new task
    And the user is offered up to three recent threads

  @backlog @mobile @priority-low
  Scenario: A recent thread shortcut opens that thread with home behind it
    Given the app is not running
    When the user opens "Fix checkout" from a launcher shortcut
    Then "Fix checkout" is shown
    And going back returns to the home screen

  @backlog @mobile @priority-low
  Scenario: A shortcut to a thread that no longer exists falls back to home
    Given "Fix checkout" has been deleted
    When the user opens "Fix checkout" from a launcher shortcut
    Then the home screen is shown

  @backlog @mobile @priority-low
  Scenario: The new task launcher shortcut starts a task
    Given the app is running on an Android phone
    When the user chooses "New task" from the app icon's shortcuts
    Then a new task opens

  @backlog @mobile @priority-low
  Scenario: Reopening a recent thread moves it to the front of the shortcuts
    Given the launcher shortcuts list "Fix checkout", "Add search" and "Refactor auth"
    When the user opens "Refactor auth"
    Then the launcher lists "Refactor auth" first
    And "Refactor auth" is listed only once

  @backlog @mobile @priority-low
  Scenario: A fourth recent thread pushes the oldest out of the shortcuts
    Given the launcher shortcuts list "Fix checkout", "Add search" and "Refactor auth"
    When the user opens "Tax line"
    Then the launcher lists "Tax line", "Fix checkout" and "Add search"
    And "Refactor auth" is no longer listed

  @backlog @mobile @priority-low
  Scenario: A recent thread with no title is listed as a thread
    Given the user opened a thread that has no title yet
    Then the launcher lists it as "Thread"

  @backlog @mobile @priority-low
  Scenario: A recent thread keeps its name while the thread loads
    Given the launcher lists "Fix checkout"
    When the user reopens it and its title has not loaded yet
    Then the launcher still lists "Fix checkout"

  @backlog @mobile @priority-low
  Scenario: A shortcut that points anywhere but a new task or a thread goes nowhere
    Given a launcher shortcut left over from another version points to another screen
    When the user chooses it
    Then nothing opens beyond the app itself

  @backlog @mobile @priority-low
  Scenario: Recent threads that cannot be read do not erase the saved list
    Given the app cannot read the saved list of recent threads on launch
    Then the launcher offers a new task and no recent threads
    And the saved list is left as it was
    When the user launches the app again and the saved list can be read
    Then the recent threads are offered again

  # New behaviour: the React Native app has no Siri or App Shortcuts integration.
  @backlog @mobile @priority-low
  Scenario: Siri and App Shortcuts can start a task
    Given the user is on an iPhone
    When the user asks Siri to start a HAL-C2 task in "shop"
    Then a new task opens in "shop"

  @backlog @mobile @priority-low
  Scenario: Siri and App Shortcuts can open a recent thread
    Given the user is on an iPhone
    When the user runs the shortcut to open "Fix checkout"
    Then "Fix checkout" is shown

  @backlog @mobile @priority-low
  Scenario Outline: An Android screen header keeps its first actions in view and puts the rest in a menu
    Given the user is on an Android screen whose header has <count> actions
    And the screen is <width> wide
    Then <direct> of them are shown in the header
    And the others are under "More actions"

    Examples:
      | count | width           | direct |
      | 2     | any width       | 2      |
      | 4     | under 600 dp    | 1      |
      | 4     | 600 dp or more  | 3      |

  @backlog @mobile @priority-low
  Scenario: An action in a header's "More actions" menu keeps its checked and unavailable states
    Given an Android screen header has a toggle that is on and an action that is unavailable under "More actions"
    When the user opens "More actions"
    Then the toggle is shown as on
    And the unavailable action cannot be chosen

  @backlog @mobile @priority-low
  Scenario: An Android screen header can go back with "Navigate up"
    Given the user opened a screen that has a screen behind it on an Android phone
    When the user chooses "Navigate up" in its header
    Then the screen behind it is shown

  # Upstream #15068: back from a live subagent card returns to the parent
  # Upstream #15844: back from a finished subagent row returns to the parent
  @backlog @mobile
  Scenario Outline: Back from a subagent's thread returns to its parent
    Given the user opened a subagent's thread from <entry> in its parent's feed
    When the user goes back
    Then the parent thread is shown at the scroll position they left

    Examples:
      | entry                  |
      | the live subagent card |
      | its finished row       |

  # Upstream #23795: Open thread on a subagent's row, and thread links, swapped out the thread
  # they were tapped in, so Back skipped it.
  @backlog @mobile
  Scenario Outline: Back from a thread opened from another thread returns to it
    Given the user is reading "Fix checkout"
    When the user opens "Add tests" from <entry> in "Fix checkout"
    And the user goes back
    Then "Fix checkout" is shown

    Examples:
      | entry                                    |
      | "Open thread" on its expanded row        |
      | a thread link in a reply                 |
      | a thread mention in a message's context  |
      | the composer's thread chip               |

  @backlog @mobile @priority-low
  Scenario: Opening the thread just behind goes back to it
    Given the user opened the subagent thread "Add tests" from "Fix checkout"
    When the user opens "Fix checkout" from a message in "Add tests"
    Then "Fix checkout" is shown
    And going back again returns to the home screen

  # Upstream #23841 and #24524: Usage was reached only through Settings, and Settings opened as
  # a separate card outside the workspace's columns.
  @backlog @mobile
  Scenario: The workspace's navigation reaches chats, pull requests, usage and settings
    When the user looks at the phone's workspace navigation
    Then it offers Chats, Pull requests, Usage and Settings
    And the section that is open is marked

  @backlog @mobile
  Scenario: Settings on a split layout keeps its list beside the page
    Given the layout is split
    When the user opens Settings and chooses "Environments"
    Then the settings list stays in the sidebar with "Environments" marked
    And the "Environments" page opens beside it

  @backlog @mobile
  Scenario: Switching sections never lands on an empty page
    Given the layout is split and the user was last on the "Environments" settings page
    When the user switches from Settings to Chats and back
    Then the "Environments" page is shown, not a "Select a…" placeholder

  # Upstream #24644: returning to Settings showed nothing marked for a moment.
  @backlog @mobile @priority-low
  Scenario: Returning to Settings shows the page it reopens on marked from the start
    Given the layout is split and Settings was last on "Environments"
    When the user returns to Settings from Chats
    Then "Environments" is marked in the settings list as soon as it shows
