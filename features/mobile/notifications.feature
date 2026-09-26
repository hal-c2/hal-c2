# Sources:
#   docs/user/mobile-notifications.md
#   apps/mobile/src/features/agent-awareness/ (push registration, live activity arming, channels)
#   apps/mobile/src/features/settings/SettingsNotificationsRouteScreen.tsx
#   apps/mobile/modules/t3-agent-notifications
#   apps/mobile/src/Stack.tsx (notification navigation)
# Agent activity publishing on the environment is specified in features/connections/.
# This file covers what the phone does with it.

Feature: Push notifications and live agent activity
  A phone signed in to T3 Connect is told when an agent finishes, fails, needs approval or
  asks a question, and can follow ongoing work from the lock screen.

  Background:
    Given the user is signed in to T3 Connect on the phone
    And the phone uses "My MacBook" through T3 Connect
    And "My MacBook" publishes agent activity

  @backlog @mobile
  Scenario: Turning on device notifications registers the phone
    When the user turns on device notifications
    And the user allows notifications when the phone asks
    Then the user is told notifications are enabled

  @backlog @mobile
  Scenario: Refusing the system prompt leaves notifications off
    When the user turns on device notifications
    And the user refuses notifications when the phone asks
    Then the user is told notifications are disabled
    And the user is offered to open the system settings

  @backlog @mobile
  Scenario: Turning off device notifications goes through the system settings
    Given device notifications are on
    When the user turns off device notifications
    Then the phone's notification settings for T3 Code open

  @backlog @mobile
  Scenario: A registration that fails says so and can be retried
    Given the relay rejects the phone's registration
    When the user turns on device notifications
    Then the user is told notifications could not be enabled
    When the user tries again
    Then the phone registers with the relay again

  @backlog @mobile
  Scenario: Notifications require T3 Connect
    Given the user is signed out of T3 Connect
    When the user opens notification settings
    Then the user is asked to sign in to T3 Connect

  @backlog @mobile
  Scenario: An app build too old for notifications says so
    Given the installed app build cannot receive notifications
    When the user opens notification settings
    Then the user is told to install a newer app build

  @backlog @mobile
  Scenario Outline: The phone is alerted when an agent needs the user or is done
    Given device notifications are on
    And the app is in the background
    When an agent in "Fix checkout" <event>
    Then the phone shows an alert for "Fix checkout"

    Examples:
      | event                          |
      | finishes its turn              |
      | fails                          |
      | needs approval for a command   |
      | asks the user a question       |

  @backlog @mobile
  Scenario: Tapping an alert opens the thread
    Given the phone shows an alert for "Fix checkout"
    When the user taps the alert
    Then "Fix checkout" is shown

  @backlog @mobile
  Scenario: Tapping an alert when the app was not running opens the thread with home behind it
    Given the app is not running
    And the phone shows an alert for "Fix checkout"
    When the user taps the alert
    Then "Fix checkout" is shown
    And going back returns to the home screen

  @backlog @mobile
  Scenario: No alert is shown while the app is open
    Given device notifications are on
    And the app is in the foreground
    When an agent in "Fix checkout" finishes its turn
    Then the phone shows no alert

  @backlog @mobile
  Scenario: Reading the thread on another device does not silence the phone
    Given device notifications are on
    And the user is reading "Fix checkout" on the desktop
    When an agent in "Fix checkout" finishes its turn
    Then the phone shows an alert for "Fix checkout"

  @backlog @mobile
  Scenario: An environment that does not publish activity sends no alerts
    Given "Office Mac" does not publish agent activity
    When an agent on "Office Mac" finishes its turn
    Then the phone shows no alert

  @backlog @mobile
  Scenario: A directly paired environment alone gives no background alerts
    Given the phone reaches "Home Server" only over the local network
    And the app is in the background
    When an agent on "Home Server" finishes its turn
    Then the phone shows no alert

  @backlog @mobile
  Scenario: Sending work from the phone starts a live activity
    Given live activity updates are on
    When the user sends a message in "Fix checkout"
    Then the lock screen shows that agent work is in progress

  @backlog @mobile
  Scenario: The live activity follows the agent and shows the result
    Given the lock screen shows agent work in progress for "Fix checkout"
    When the agent finishes its turn
    Then the lock screen shows that the agent work completed
    And the result stays visible for up to 15 minutes

  @backlog @mobile
  Scenario: Only one live activity is shown per phone
    Given the lock screen shows agent work in progress for "Fix checkout"
    When the user sends a message in "Add search"
    Then the lock screen shows a single card covering both threads

  @backlog @mobile
  Scenario: No live activity starts when the environment does not publish activity
    Given "My MacBook" does not publish agent activity
    When the user sends a message in "Fix checkout"
    Then no live activity starts

  @backlog @mobile
  Scenario: The user turns live activity updates off and on
    Given live activity updates are on
    When the user turns live activity updates off
    Then sending work starts no live activity
    When the user turns live activity updates on
    Then sending work starts a live activity

  @backlog @mobile
  Scenario: Dismissing the Android activity card keeps alerts on
    Given the user is on an Android phone
    And the ongoing agent activity card is showing
    When the user dismisses the card
    Then the card is gone
    And alerts still arrive when an agent finishes

  @backlog @mobile
  Scenario: Android 16 promotes ongoing activity to a live update
    Given the user is on an Android 16 phone
    When the user sends a message in "Fix checkout"
    Then the agent activity is shown as a live update
    And the user is offered the live update settings

  @backlog @mobile
  Scenario: Coming back to the app repairs a live activity that drifted
    Given the lock screen shows work in progress for a turn that already ended
    When the user opens the app
    Then the lock screen shows the current state of the agent work

  @backlog @mobile
  Scenario: Signing out ends lock screen activity and stops alerts
    Given the lock screen shows agent work in progress
    When the user signs out of T3 Connect
    Then the lock screen activity ends
    And the phone stops receiving alerts

  @backlog @mobile
  Scenario: A force-stopped Android app receives alerts again once reopened
    Given the user force-stopped the app on Android
    When an agent finishes its turn
    Then the phone shows no alert
    When the user opens the app
    Then later alerts arrive again

  # New behaviour: the React Native app has no per-thread mute.
  @backlog @mobile
  Scenario: The user mutes alerts for one thread
    Given device notifications are on
    When the user mutes alerts for "Fix checkout"
    And an agent in "Fix checkout" finishes its turn
    Then the phone shows no alert

  @backlog @mobile
  Scenario: The user unmutes a thread
    Given alerts for "Fix checkout" are muted
    When the user unmutes "Fix checkout"
    And an agent in "Fix checkout" finishes its turn
    Then the phone shows an alert for "Fix checkout"

  # New behaviour: the React Native app has no quiet hours; it relies on system focus modes.
  @backlog @mobile
  Scenario: Alerts wait during quiet hours
    Given the user set quiet hours from 22:00 to 07:00
    When an agent finishes its turn at 23:00
    Then the phone shows no alert until 07:00

  @backlog @mobile
  Scenario: Approval requests break through quiet hours when the user allows it
    Given the user set quiet hours that let approval requests through
    When an agent needs approval during quiet hours
    Then the phone shows an alert
