# Sources:
#   docs/internals/mobile-navigation.md (root stack, overlay routes, previews)
#   apps/mobile/src/Stack.tsx (route table, deep link prefixes, not found)
#   apps/mobile/src/features/shortcuts/ (Android launcher shortcuts, allowlisted links)
#   apps/mobile/app.config.ts (hal-c2, hal-c2-dev and hal-c2-preview schemes)
#   apps/mobile/plugins/withIosSceneLifecycle
# Desktop navigation and the command palette are specified in features/navigation/.
# This file covers links into the phone app and moving between phone screens.

Feature: Navigating the phone app and opening links into it
  Every screen a user can reach has a link, so a notification, widget, shortcut or shared
  link can land the user straight on the right thing with a sensible way back.

  Background:
    Given the phone is paired with "My MacBook"
    And "My MacBook" has the thread "Fix checkout"

  @backlog @mobile
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
