# Sources:
#   apps/mobile/src/features/updates/app-updates.ts (background install, prompts, flush first)
#   apps/mobile/src/lib/foreground-handoff.ts (pickers, share sheet and sign-in pages hold back a restart)
#   apps/mobile/src/features/settings/SettingsAboutRouteScreen.tsx (hidden update check)
#   apps/mobile/app.config.ts (expo-updates on load, fingerprint runtime version, variants)
# MC hot upgrades are specified in features/connections/ and the MC domains.

Feature: Keeping the phone app up to date
  The app updates itself without losing work. Store builds replace the whole app; smaller
  updates install when the user is not looking.

  # Expo over-the-air JavaScript updates do not carry over to a native QML app. The need
  # stays: fixes must reach users between store releases, so QML updates are @backlog.

  @backlog @mobile
  Scenario: An update downloaded in the background installs the next time the app is backgrounded
    Given an update has downloaded while the user was using the app
    When the user switches away from the app
    Then the update is applied
    And the user returns to the screen they left

  @backlog @mobile
  Scenario: An app kept open for a long time asks before updating
    Given an update has been ready for a long time while the app stayed open
    Then the user is asked whether to restart now to update

  @backlog @mobile
  Scenario: The user postpones an update prompt
    Given the user is asked whether to restart now to update
    When the user postpones it
    Then the app keeps running on the current version

  @backlog @mobile
  Scenario: Updating waits until drafts and unsent messages are saved
    Given the user has an unsaved draft and an unsent message
    When an update is about to be applied
    Then the draft and the unsent message are saved first

  @backlog @mobile
  Scenario: An update is held back if saving fails
    Given saving the user's draft fails
    When an update is about to be applied
    Then the update is not applied
    And the draft is not lost

  @backlog @mobile
  Scenario: The app does not restart while the user is picking a photo
    Given an update is ready
    When the user switches to the photo picker
    Then the app does not restart for the update

  @backlog @mobile
  Scenario Outline: The app does not restart while it hands the user to another screen of the system
    Given an update is ready
    When the user is in <place>
    Then the app does not restart for the update
    When the user comes back to the app
    Then the update is applied

    Examples:
      | place                        |
      | the files app picker         |
      | the system share sheet       |
      | a sign-in page in a browser  |

  @backlog @mobile
  Scenario: The user checks for an update by hand
    When the user taps the app version five times
    Then the app checks for an update
    And the user sees the check progress through downloading to ready

  @backlog @mobile
  Scenario Outline: A manual update check reports what happened
    Given <situation>
    When the user checks for an update by hand
    Then the user is told "<message>"

    Examples:
      | situation                      | message      |
      | the app is already current     | Up to date   |
      | the update server is unreachable | Update failed |
      | a new update downloads         | Update ready |

  @backlog @mobile
  Scenario: An update the user asked for applies right away
    Given the user checked for an update by hand and it is ready
    Then the app restarts on the new version

  @backlog @mobile
  Scenario: An update the user asked for restarts even when saving fails
    Given the user checked for an update by hand and it is ready
    And saving the user's draft fails
    When the app is about to restart for the update
    Then the app restarts on the new version
    # An update nobody asked for is held back instead (see "An update is held back if saving fails").

  @backlog @mobile
  Scenario: A manual check that finds an update already downloaded does not download it again
    Given an update downloaded in the background is waiting for the app to be backgrounded
    When the user checks for an update by hand
    Then the app restarts on the new version
    And the update is not downloaded a second time

  @backlog @mobile
  Scenario: A manual check while another check is running joins that check
    Given the app is already checking for an update
    When the user checks for an update by hand
    Then the user sees the progress of that same check
    And only one update is downloaded

  @backlog @mobile
  Scenario: A downloaded update that cannot restart the app is kept for the next launch
    Given an update has downloaded
    And the app cannot restart itself
    When the update is about to be applied
    Then the user is told the update downloaded but the app could not restart
    And the update is applied the next time the app is opened

  @backlog @mobile
  Scenario: The app looks for an update when it opens
    When the user opens the app
    Then the app checks for an update once
    And an update it finds is downloaded in the background

  @backlog @mobile
  Scenario Outline: Coming back to a long-running app looks for a newer update only after a long break
    Given the app has been in the background for <time>
    And <waiting>
    When the user returns to the app
    Then the app <result>

    Examples:
      | time                | waiting                                  | result                            |
      | 15 minutes or more  | no downloaded update is waiting          | checks for an update              |
      | a few minutes       | no downloaded update is waiting          | does not check for an update      |
      | 15 minutes or more  | a downloaded update is already waiting   | does not check for an update      |

  @backlog @mobile
  Scenario: An update that withdraws a broken release is applied without asking
    Given the release the app runs was withdrawn and the app should go back to the version it shipped with
    When the app finds that instruction
    Then the app returns to the version it shipped with
    And the user is not asked whether to restart

  @backlog @mobile
  Scenario: A withdrawn release is not applied over unsaved work
    Given the release the app runs was withdrawn
    And saving the user's draft fails
    When the app is about to return to the version it shipped with
    Then the app keeps running until the next time it is backgrounded
    And the draft is not lost

  @backlog @mobile
  Scenario: The about page shows the update check's progress and then clears it
    Given the user checked for an update by hand
    When the app is already current
    Then the about page says "Up to date"
    And the message goes away after a few seconds

  @backlog @mobile
  Scenario: The app version shows which build variant is installed
    Given the user has the preview build installed
    When the user opens the about page
    Then the version is labelled as the preview build

  @backlog @mobile
  Scenario: An app that is too old for the environment asks the user to update
    Given "My MacBook" runs a newer server than the app supports
    When the phone connects to "My MacBook"
    Then the user is told to use compatible versions of the app and server

  @dropped @mobile
  Scenario: Development builds refuse over-the-air updates
    # Dropped: this guards the Expo development client, which HAL-C2 does not ship.
    Given the user runs a development build
    When the user checks for an update by hand
    Then the user is told updates are unavailable in development builds
