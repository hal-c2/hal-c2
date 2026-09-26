# Sources:
#   features/README.md (hal-c2: QML on every surface)
#   /home/olafura/dev/opentui-qml (QML runtime, Plugin and Slot API)
#   apps/mobile/src/features/settings/appearance/ (the closest React Native equivalent: themes)
# New hal-c2 behaviour. How a QML file plugs into the UI (slots, sandboxing, API versions)
# is specified in features/plugins/. This file covers only the phone user's journey:
# choosing a file, previewing, applying, reverting, and per-environment memory.

Feature: Customising the phone UI with a QML file
  A user can load a QML file that changes how parts of the app look or behave. The user
  sees it before committing to it, can always get back to the standard UI, and each
  environment remembers its own choice.

  Background:
    Given the phone is paired with "My MacBook" and "Office Mac"
    And the user is looking at "My MacBook"

  @backlog @mobile
  Scenario: The user chooses a QML file from the phone's files
    When the user chooses to customise the UI
    And the user picks "compact-list.qml" from the files app
    Then a preview of the app with "compact-list.qml" is shown
    And nothing is changed until the user applies it

  @backlog @mobile
  Scenario: The user chooses a QML file from the environment's workspace
    When the user chooses to customise the UI
    And the user picks "ui/compact-list.qml" from the "shop" workspace on "My MacBook"
    Then a preview of the app with "ui/compact-list.qml" is shown

  @backlog @mobile
  Scenario: The user opens a QML file shared from another app
    When the user shares "compact-list.qml" to T3 Code from another app
    Then the user is offered to preview it as a UI customisation

  @backlog @mobile
  Scenario: The user leaves the preview without applying
    Given a preview of "compact-list.qml" is shown
    When the user cancels the preview
    Then the app looks as it did before

  @backlog @mobile
  Scenario: The user applies a previewed customisation
    Given a preview of "compact-list.qml" is shown
    When the user applies it
    Then the app uses "compact-list.qml" for "My MacBook"
    And the user is told which customisation is active

  @backlog @mobile
  Scenario: The user reverts to the standard UI
    Given "compact-list.qml" is applied for "My MacBook"
    When the user reverts to the standard UI
    Then the app uses the standard UI for "My MacBook"

  @backlog @mobile
  Scenario: A reverted customisation can be applied again from recent files
    Given the user reverted "compact-list.qml" for "My MacBook"
    When the user chooses "compact-list.qml" from recent customisations
    Then a preview of the app with "compact-list.qml" is shown

  @backlog @mobile
  Scenario: Each environment remembers its own customisation
    Given "compact-list.qml" is applied for "My MacBook"
    When the user switches to "Office Mac"
    Then the app uses the standard UI
    When the user switches back to "My MacBook"
    Then the app uses "compact-list.qml"

  @backlog @mobile
  Scenario: A customisation survives the app restarting
    Given "compact-list.qml" is applied for "My MacBook"
    When the app restarts
    Then the app uses "compact-list.qml" for "My MacBook"

  @backlog @mobile
  Scenario: Removing an environment forgets its customisation
    Given "compact-list.qml" is applied for "Office Mac"
    When the user removes "Office Mac" and pairs it again
    Then the app uses the standard UI for "Office Mac"

  @backlog @mobile
  Scenario: A file that is not valid QML is refused with the reason
    When the user picks a QML file with a syntax error
    Then the user is told the file could not be loaded and where the error is
    And the app looks as it did before

  @backlog @mobile
  Scenario: A file written for an incompatible app version is refused
    When the user picks a QML file that needs a newer app
    Then the user is told which app version the file needs
    And nothing is applied

  @backlog @mobile
  Scenario: A customisation that fails at start-up falls back to the standard UI
    Given "broken.qml" is applied for "My MacBook"
    And "broken.qml" fails while the app starts
    When the user opens the app
    Then the app uses the standard UI for "My MacBook"
    And the user is told "broken.qml" was turned off because it failed

  @backlog @mobile
  Scenario: The user can always reach the standard UI while a customisation is active
    Given a customisation is applied that hides the settings
    When the user follows a link to appearance settings
    Then the user is offered to revert to the standard UI

  @backlog @mobile
  Scenario: A customisation file that changed is offered again for preview
    Given "compact-list.qml" is applied for "My MacBook"
    When "compact-list.qml" changes on the phone
    Then the user is offered to preview the updated file
    And the applied version stays in use until the user applies the update

  @backlog @mobile
  Scenario: A customisation from a workspace is kept when the environment is offline
    Given "ui/compact-list.qml" from "My MacBook" is applied
    And "My MacBook" is unreachable
    When the app restarts
    Then the app still uses "ui/compact-list.qml" for "My MacBook"

  @backlog @mobile
  Scenario: A customisation that asks for more access tells the user before applying
    When the user picks a QML file that asks to run commands on the environment
    Then the preview says what the file asks to do
    And the user must allow it before applying
