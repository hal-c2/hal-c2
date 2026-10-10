# Sources:
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

  @backlog @mobile
  Scenario Outline: Each app build answers only its own link scheme
    Given the user has the <build> build installed
    When the user follows a "<scheme>" link
    Then the <build> build opens

    Examples:
      | build       | scheme           |
      | production  | hal-c2://        |
      | preview     | hal-c2-preview:// |
      | development | hal-c2-dev://    |

  @backlog @mobile
  Scenario: Sheets and previews do not change the layout behind them
    Given the user is looking at "Fix checkout" beside the thread list on a tablet
    When the user opens settings over it
    And the user closes settings
    Then "Fix checkout" is still shown beside the thread list

  @backlog @mobile
  Scenario: A preview stays open after its source disappears
    Given the user is previewing an image attached to a message
    When the message is removed from the thread
    Then the preview stays open until the user closes it

  @backlog @mobile
  Scenario: Android launcher shortcuts offer a new task and recent threads
    Given the user is on an Android phone
    And the user recently opened "Fix checkout", "Add search" and "Refactor auth"
    When the user long presses the app icon
    Then the user is offered to start a new task
    And the user is offered up to three recent threads

  @backlog @mobile
  Scenario: A recent thread shortcut opens that thread with home behind it
    Given the app is not running
    When the user opens "Fix checkout" from a launcher shortcut
    Then "Fix checkout" is shown
    And going back returns to the home screen

  @backlog @mobile
  Scenario: A shortcut to a thread that no longer exists falls back to home
    Given "Fix checkout" has been deleted
    When the user opens "Fix checkout" from a launcher shortcut
    Then the home screen is shown

  @backlog @mobile
  Scenario: The new task launcher shortcut starts a task
    Given the app is running on an Android phone
    When the user chooses "New task" from the app icon's shortcuts
    Then a new task opens

  @backlog @mobile
  Scenario: Reopening a recent thread moves it to the front of the shortcuts
    Given the launcher shortcuts list "Fix checkout", "Add search" and "Refactor auth"
    When the user opens "Refactor auth"
    Then the launcher lists "Refactor auth" first
    And "Refactor auth" is listed only once

  @backlog @mobile
  Scenario: A fourth recent thread pushes the oldest out of the shortcuts
    Given the launcher shortcuts list "Fix checkout", "Add search" and "Refactor auth"
    When the user opens "Tax line"
    Then the launcher lists "Tax line", "Fix checkout" and "Add search"
    And "Refactor auth" is no longer listed

  @backlog @mobile
  Scenario: A recent thread with no title is listed as a thread
    Given the user opened a thread that has no title yet
    Then the launcher lists it as "Thread"

  @backlog @mobile
  Scenario: A recent thread keeps its name while the thread loads
    Given the launcher lists "Fix checkout"
    When the user reopens it and its title has not loaded yet
    Then the launcher still lists "Fix checkout"

  @backlog @mobile
  Scenario: A shortcut that points anywhere but a new task or a thread goes nowhere
    Given a launcher shortcut left over from another version points to another screen
    When the user chooses it
    Then nothing opens beyond the app itself

  @backlog @mobile
  Scenario: Recent threads that cannot be read do not erase the saved list
    Given the app cannot read the saved list of recent threads on launch
    Then the launcher offers a new task and no recent threads
    And the saved list is left as it was
    When the user launches the app again and the saved list can be read
    Then the recent threads are offered again

  # New behaviour: the React Native app has no Siri or App Shortcuts integration.
  @backlog @mobile
  Scenario: Siri and App Shortcuts can start a task
    Given the user is on an iPhone
    When the user asks Siri to start a HAL-C2 task in "shop"
    Then a new task opens in "shop"

  @backlog @mobile
  Scenario: Siri and App Shortcuts can open a recent thread
    Given the user is on an iPhone
    When the user runs the shortcut to open "Fix checkout"
    Then "Fix checkout" is shown

  @backlog @mobile
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

  @backlog @mobile
  Scenario: An action in a header's "More actions" menu keeps its checked and unavailable states
    Given an Android screen header has a toggle that is on and an action that is unavailable under "More actions"
    When the user opens "More actions"
    Then the toggle is shown as on
    And the unavailable action cannot be chosen

  @backlog @mobile
  Scenario: An Android screen header can go back with "Navigate up"
    Given the user opened a screen that has a screen behind it on an Android phone
    When the user chooses "Navigate up" in its header
    Then the screen behind it is shown
