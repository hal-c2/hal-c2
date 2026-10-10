# Sources:
#   docs/user/mobile-notifications.md
#   apps/mobile/src/features/agent-awareness/ (push registration, live activity arming, channels)
#   apps/mobile/src/features/settings/SettingsNotificationsRouteScreen.tsx
#   apps/mobile/modules/hal-c2-agent-notifications
#   apps/mobile/src/Stack.tsx (notification navigation)
# Agent activity publishing on the environment is specified in features/connections/.
# This file covers what the phone does with it.

Feature: Push notifications and live agent activity
  A phone signed in to HAL-C2 Connect is told when an agent finishes, fails, needs approval or
  asks a question, and can follow ongoing work from the lock screen.

  Background:
    Given the user is signed in to HAL-C2 Connect on the phone
    And the phone uses "My MacBook" through HAL-C2 Connect
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
    Then the phone's notification settings for HAL-C2 open

  @backlog @mobile
  Scenario: A registration that fails says so and can be retried
    Given the relay rejects the phone's registration
    When the user turns on device notifications
    Then the user is told notifications could not be enabled
    When the user tries again
    Then the phone registers with the relay again

  @backlog @mobile
  Scenario: Notifications require HAL-C2 Connect
    Given the user is signed out of HAL-C2 Connect
    When the user opens notification settings
    Then the user is asked to sign in to HAL-C2 Connect

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

  # Likely already implemented: apps/mobile/src/features/settings/SettingsNotificationsRouteScreen.tsx
  @backlog @mobile
  Scenario: A build without HAL-C2 Connect says notifications are unavailable
    Given the installed app build was made without HAL-C2 Connect
    When the user opens notification settings
    Then the user is told notifications require HAL-C2 Connect in this build

  @backlog @mobile
  Scenario: Device notifications show as on only when the phone is allowed and registered
    Given the system allows HAL-C2 notifications
    And the relay has not registered the phone
    When the user opens notification settings
    Then device notifications are shown as off
    When the relay registers the phone
    Then device notifications are shown as on

  @backlog @mobile
  Scenario: Allowing notifications in the system settings is noticed on return
    Given the system blocks HAL-C2 notifications
    When the user allows HAL-C2 notifications in the system settings
    And the user returns to the app
    Then notification settings show the phone as allowed

  @backlog @mobile
  Scenario: Live activity updates ask the user to sign in first
    Given the user is signed out of HAL-C2 Connect
    When the user turns live activity updates on
    Then the user is told live activity updates need HAL-C2 Connect to be delivered
    And the user can continue to sign in

  @backlog @mobile
  Scenario: A live activity preference left on after signing out can be turned off
    Given the user is signed out of HAL-C2 Connect
    And live activity updates were left on
    When the user turns the live activity preference off
    Then live activity updates stay off the next time the user signs in

  @backlog @mobile
  Scenario Outline: Turning on live activity updates says how many environments are linked
    Given the phone has <count> environments
    When the user turns live activity updates on
    Then the user is told <message>

    Examples:
      | count | message                                                       |
      | 0     | updates are on and adding an environment starts them          |
      | 1     | 1 environment is linked for agent activity updates            |
      | 3     | 3 environments are linked for agent activity updates          |

  @backlog @mobile
  Scenario: Ongoing activity on Android needs notification permission
    Given the user is on an Android phone
    And the system blocks HAL-C2 notifications
    When the user turns live activity updates on
    Then the user is told notification permission is needed
    And the user is offered to open the system settings
    And live activity updates stay off

  @backlog @mobile
  Scenario: Live activity updates that cannot be turned on stay off
    Given the relay cannot be reached
    When the user turns live activity updates on
    Then the user is told live activity updates are unavailable
    And live activity updates stay off

  @backlog @mobile
  Scenario: Live activity updates that cannot be turned off stay on
    Given live activity updates are on
    And the relay cannot be reached
    When the user turns live activity updates off
    Then live activity updates stay on

  @backlog @mobile
  Scenario: Live activity updates turned on before the phone is registered start later
    Given the relay rejects the phone's registration
    When the user turns live activity updates on
    Then the user is told the phone could not be registered yet
    And live activity updates start once registration succeeds

  @backlog @mobile
  Scenario: Coming back to the app repairs a live activity that drifted
    Given the lock screen shows work in progress for a turn that already ended
    When the user opens the app
    Then the lock screen shows the current state of the agent work

  @backlog @mobile
  Scenario: Opening the app while no agent is working starts no lock screen card
    Given live activity updates are on
    And no agent is working in any linked environment
    When the user opens the app
    Then the lock screen shows no agent activity

  @backlog @mobile
  Scenario: Opening the app while an agent started elsewhere is working shows its card
    Given live activity updates are on
    And an agent in "Fix checkout" was started from the desktop and is working
    When the user opens the app
    Then the lock screen shows that agent work is in progress for "Fix checkout"

  @backlog @mobile
  Scenario: Opening the app again with nothing changed does not register the phone again
    Given the relay has registered the phone for this account
    And the notification settings have not changed
    When the user closes and opens the app
    Then the phone is not registered with the relay a second time

  @backlog @mobile
  Scenario Outline: The phone is registered again when what the relay knows about it changes
    Given the relay has registered the phone for this account
    When <change>
    Then the phone is registered with the relay again

    Examples:
      | change                                      |
      | the system gives the phone a new push token |
      | the user signs in with another account      |
      | the app is updated to a new version         |
      | the user changes the live activity setting  |

  @backlog @mobile
  Scenario: A later registration that fails does not turn notifications off
    Given the relay has registered the phone for this account
    And the relay cannot be reached
    When the app tries to register the phone again
    Then device notifications are still shown as on

  @backlog @mobile
  Scenario: Signing in on a phone with notifications already allowed registers it without asking
    Given the system already allows HAL-C2 notifications
    And the user is signed out of HAL-C2 Connect
    When the user signs in to HAL-C2 Connect
    Then the phone is registered with the relay
    And the user is not asked for notification permission again

  @backlog @mobile
  Scenario Outline: A tapped alert that does not name a thread opens nothing
    Given the phone shows an alert whose link <problem>
    When the user taps the alert
    Then the app stays where it was
    And no error is shown

    Examples:
      | problem                                      |
      | points outside HAL-C2                        |
      | is malformed                                 |
      | names neither an environment nor a thread    |

  @backlog @mobile
  Scenario: An alert whose link is unusable still opens the thread it names
    Given the phone shows an alert for "Fix checkout" whose link is not a thread link
    But the alert names the environment and the thread
    When the user taps the alert
    Then "Fix checkout" is shown

  @backlog @mobile
  Scenario: One tap on an alert opens the thread once
    Given the app was not running
    And the phone shows an alert for "Fix checkout"
    When the user taps the alert
    Then "Fix checkout" is shown once
    And going back does not show "Fix checkout" again

  @backlog @mobile
  Scenario: Signing out ends lock screen activity and stops alerts
    Given the lock screen shows agent work in progress
    When the user signs out of HAL-C2 Connect
    Then the lock screen activity ends
    And the phone stops receiving alerts

  @backlog @mobile
  Scenario: A force-stopped Android app receives alerts again once reopened
    Given the user force-stopped the app on Android
    When an agent finishes its turn
    Then the phone shows no alert
    When the user opens the app
    Then later alerts arrive again

  @backlog @mobile
  Scenario: An alert that reaches the phone more than ten minutes late is not shown
    Given device notifications are on
    And the app is in the background
    When an agent in "Fix checkout" finishes its turn
    And the alert reaches the phone more than ten minutes after that
    Then the phone shows no alert

  @backlog @mobile
  Scenario: An alert the relay delivers again is shown only once
    Given device notifications are on
    And the app is in the background
    When an agent in "Fix checkout" finishes its turn
    And the relay delivers the same alert again
    Then the phone shows one alert for "Fix checkout"

  @backlog @mobile
  Scenario: Alerts stay off while the system has blocked HAL-C2 notifications
    Given device notifications are on
    And the app is in the background
    And the system has blocked notifications for HAL-C2
    When an agent in "Fix checkout" finishes its turn
    Then the phone shows no alert

  @backlog @mobile
  Scenario: A running agent's card ends when two hours pass without an update
    Given the lock screen shows agent work in progress for "Fix checkout"
    When two hours pass without a new update
    Then the lock screen activity ends

  @backlog @mobile
  Scenario: A status update that arrives after a newer one does not roll the card back
    Given the lock screen shows that the agent work in "Fix checkout" completed
    When an older update saying the work is still running arrives late
    Then the lock screen still shows that the agent work completed

  @backlog @mobile
  Scenario: A new run shows its card again after the user dismissed the last one
    Given the user dismissed the agent activity card for "Fix checkout"
    When the agent starts a new turn in "Fix checkout"
    Then the ongoing agent activity card is shown again

  @backlog @mobile
  Scenario: Repeated updates for a dismissed run do not bring its card back
    Given the user dismissed the agent activity card for "Fix checkout"
    When the relay repeats the finished update for "Fix checkout"
    Then no agent activity card is shown

  @backlog @mobile
  Scenario: Activity card updates make no sound while alerts do
    Given the user is on an Android phone
    And the ongoing agent activity card is showing
    When the agent's status changes
    Then the card updates without a sound
    And alerts for finished agents still make a sound

  @backlog @mobile
  Scenario Outline: A card that needs the user offers the action that answers it
    Given the agent in "Fix checkout" <state>
    And the ongoing agent activity card is showing
    Then the card offers "<action>"
    When the user taps "<action>" on the card
    Then "Fix checkout" is shown

    Examples:
      | state                            | action  |
      | is waiting for approval          | Approve |
      | is asking the user a question    | Answer  |

  @backlog @mobile
  Scenario: An alert that arrived while the app was open does not appear after it is closed
    Given device notifications are on
    And the app is in the foreground
    When an agent in "Fix checkout" finishes its turn
    And the app goes to the background
    And the relay delivers the same alert again
    Then the phone shows no alert

  @backlog @mobile
  Scenario: An alert dropped while notifications were blocked is shown after the user allows them
    Given device notifications are on
    And the app is in the background
    And the system has blocked notifications for HAL-C2
    When an agent in "Fix checkout" finishes its turn
    And the user allows HAL-C2 notifications in the system settings
    And the relay delivers the same alert again
    Then the phone shows an alert for "Fix checkout"

  @backlog @mobile
  Scenario: A grouped alert names every thread it covers
    Given device notifications are on
    And the app is in the background
    When agents in five threads finish their turns together
    Then the phone shows one alert titled "5 agents finished"
    And the alert lists the title of each of the five threads
    And a repeat delivery of that alert does not change it

  @backlog @mobile
  Scenario Outline: The activity card sums up several threads in its title
    Given the ongoing agent activity card covers <threads>
    Then the card is titled "<title>"

    Examples:
      | threads                                         | title             |
      | one thread waiting for approval and others working | 1 needs you    |
      | two threads waiting for approval or answers      | 2 need you        |
      | three threads working                            | 3 working         |
      | two threads working and one failed               | 1 failed          |
      | two threads finished and one failed              | Finished, 1 failed |
      | three threads finished                           | All finished      |

  @backlog @mobile
  Scenario: The activity card counts its threads under the title
    Given the ongoing agent activity card covers two working threads in "shop"
    Then the card says "shop" and that two are active

  @backlog @mobile
  Scenario: The activity card for one thread names it and its project
    Given the ongoing agent activity card covers only "Fix checkout" in "shop"
    Then the card is titled "Fix checkout"
    And the card says "shop" beside its status
    And the card shows no progress bar

  @backlog @mobile
  Scenario: The activity card lists every thread with its status in front
    Given the ongoing agent activity card covers five threads in different states
    When the user expands the card
    Then each thread is listed on its own line with its status before its title
    And a thread's project is named when the threads are from different projects

  @backlog @mobile
  Scenario: The activity card shows no clock
    Given the ongoing agent activity card is showing
    When a thread is renamed while its approval is waiting
    Then the card shows no time and no running timer

  @backlog @mobile
  Scenario Outline: The live update chip says what the agent wants
    Given the user is on an Android 16 phone
    And the live update covers <state>
    Then the live update chip reads "<chip>"

    Examples:
      | state                               | chip    |
      | one agent working                   | Working |
      | an agent waiting for approval       | Approve |
      | an agent asking a question          | Answer  |
      | an agent waiting for an update      | Waiting |
      | two agents working                  | 2 live  |
      | ten agents working                  | 9+ live |

  @backlog @mobile
  Scenario: A finished activity card can be swiped away and has no buttons
    Given the ongoing agent activity card shows that the agent work completed
    Then the card can be swiped away
    And tapping the card opens "Fix checkout"
    And the card offers no buttons
    And the card shows no live update chip

  @backlog @mobile
  Scenario: Android before 16 shows the activity card as an ordinary ongoing notification
    Given the user is on an Android 15 phone
    When the user sends a message in "Fix checkout"
    Then the agent activity is shown as an ongoing notification
    And the user is not offered the live update settings

  @backlog @mobile
  Scenario: Alerts and ongoing activity can be silenced separately in the system settings
    Given the user is on an Android phone
    When the user opens the notification settings of HAL-C2 in the system settings
    Then "Agent alerts" and "Ongoing agent activity" are listed as separate categories

  @backlog @mobile
  Scenario: Alerts and the activity card keep their text private while the phone is locked
    Given the user is on an Android phone
    And the phone hides sensitive notification content on the lock screen
    When an agent in "Fix checkout" finishes its turn
    Then the lock screen does not show the thread's title or text

  @backlog @mobile
  Scenario: Switching accounts removes the previous account's cards and ignores its late alerts
    Given the lock screen shows agent work in progress for "Fix checkout"
    When the user signs in with another account
    Then the previous account's cards and alerts are gone
    When an alert for the previous account arrives
    Then the phone shows no alert

  @backlog @mobile
  Scenario: An update stamped far in the future is ignored and does not hold back later ones
    Given device notifications are on
    When an update arrives that is dated an hour ahead
    Then the phone shows nothing for it
    When a current update arrives for "Fix checkout"
    Then the phone shows it

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
