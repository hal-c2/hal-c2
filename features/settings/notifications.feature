# Sources:
#   apps/web/src/components/settings/NotificationSettings.tsx
#   apps/web/src/threadNotifications.ts
#   apps/web/src/assets/notification-completion.mp3, notification-input.mp3 (the sounds)
#   apps/web/src/components/ThreadNotificationCoordinator.tsx
#   apps/web/src/components/settings/SettingsPanels.tsx (in-app notifications)
#   apps/desktop-qt/parity/features.backlog.test.ts (thread-notifications)

Feature: Thread notifications
  The user chooses how this device tells them a thread finished, failed, or needs input or
  approval: a system notification, a sound, both, or nothing, and whether a toast appears while
  HAL-C2 is in front.

  Background:
    Given the user has a thread "Fix login"

  Rule: Choosing how to be notified

    @desktop
    Scenario Outline: The notification mode decides what happens when a thread finishes in the background
      Given the notification mode is "<mode>"
      And HAL-C2 is in the background
      When "Fix login" finishes
      Then <effect>

      Examples:
        | mode                      | effect                                                  |
        | Off                       | nothing is shown or played                              |
        | Notifications only        | a system notification "Thread completed" is shown       |
        | Sound only                | the completion sound plays                              |
        | Notifications with sound  | a system notification is shown and the sound plays      |

    # The web app bundled its own completion and input sounds (apps/web/src/assets/*.mp3).
    # The Qt desktop (main.cpp) only asks the Linux sound theme's player, so another system
    # or a Linux desktop without one stays silent.
    @backlog @desktop
    Scenario Outline: The notification sound plays on every system
      Given the notification mode is "Sound only"
      And the user is on <system>
      When "Fix login" finishes
      Then the completion sound plays
      When "Fix login" asks the user a question
      Then the input sound plays

      Examples:
        | system                                  |
        | macOS                                   |
        | Windows                                 |
        | Linux without a sound theme player      |

    @desktop
    Scenario: Notifications need the system's permission
      Given the system has not allowed notifications
      When the user chooses notifications only and the system refuses
      Then the notification mode is unchanged
      And the user is told to allow notifications and that sound only is still available

    @backlog @desktop
    Scenario: Notifications need a secure page in a web browser
      Given the user is using HAL-C2 over plain HTTP in a web browser
      When the user chooses notifications only
      Then the user is told notifications need HTTPS or the desktop app and that sound only is still available

    # Legacy: apps/web/src/components/settings/NotificationSettings.tsx (permission request throws)
    @backlog @desktop
    Scenario: A permission request that cannot be made keeps the mode and offers sound only
      Given the system cannot show the permission request
      When the user chooses notifications with sound
      Then the notification mode is unchanged
      And the user is told notifications are unavailable and that sound only is still available

  Rule: What the user is told

    @desktop
    Scenario Outline: The title says what the thread needs
      Given the notification mode is "Notifications only"
      And HAL-C2 is in the background
      When "Fix login" <event>
      Then a system notification titled "<title>" names "Fix login"

      Examples:
        | event                    | title               |
        | finishes                 | Thread completed    |
        | fails                    | Thread failed       |
        | asks for approval        | Approval needed     |
        | asks a question          | Input needed        |
        | hits its usage limit     | Usage limit reached |

    @desktop
    Scenario: Clicking a notification opens the thread
      Given a system notification for "Fix login" is shown
      When the user clicks it
      Then HAL-C2 comes to the front showing "Fix login"

    @desktop
    Scenario: A toast appears instead while HAL-C2 is in front
      Given in-app notifications are on
      And HAL-C2 is in front showing another thread
      When "Fix login" finishes
      Then a toast says the thread completed and offers to open it
      And no system notification is shown

    @desktop
    Scenario: The thread on screen does not notify
      Given in-app notifications are on
      And HAL-C2 is in front showing "Fix login"
      When "Fix login" finishes
      Then no toast or notification is shown

    @desktop
    Scenario: Archived threads and subagents do not notify
      Given "Fix login" is archived
      When "Fix login" finishes
      Then no notification is shown

    @desktop
    Scenario: The app badge counts unseen notifications and clears on focus
      Given two system notifications are waiting
      Then the app shows a badge of 2
      When the user brings HAL-C2 to the front
      Then the notifications are dismissed and the badge is cleared

    # Likely already implemented: apps/desktop-qt/src/native/AlertController.cpp
    @backlog @desktop
    Scenario: A thread that stays waiting does not notify again
      Given the notification mode is "Notifications only"
      And HAL-C2 is in the background
      And "Fix login" asked for approval and notified
      When "Fix login" is still waiting for the same approval after the environment sends its state again
      Then no further notification is shown

    @backlog @desktop
    Scenario: A new request from the same thread notifies again
      Given the notification mode is "Notifications only"
      And HAL-C2 is in the background
      And "Fix login" asked for approval and notified
      When "Fix login" is answered and then asks for approval again in a new run
      Then a system notification titled "Approval needed" is shown

    @backlog @desktop
    Scenario: A thread that finished before is not announced as finishing again
      Given the notification mode is "Notifications only"
      And HAL-C2 is in the background
      And "Fix login" finished and notified
      When the environment sends its state again with "Fix login" finished at the same time
      Then no further notification is shown

    @backlog @desktop
    Scenario Outline: The sound depends on what the thread needs
      Given the notification mode is "Sound only"
      When "Fix login" <event>
      Then the <sound> sound plays

      Examples:
        | event                | sound      |
        | finishes             | completion |
        | asks for approval    | input      |
        | asks a question      | input      |
        | fails                | input      |
        | hits its usage limit | input      |

    @backlog @desktop
    Scenario: A toast is not shown when in-app notifications are off
      Given in-app notifications are off
      And HAL-C2 is in front showing another thread
      When "Fix login" finishes
      Then no toast is shown
      And no system notification is shown

    @backlog @desktop
    Scenario: A toast says whether the thread failed, needs input or finished
      Given in-app notifications are on
      And HAL-C2 is in front showing another thread
      When "Fix login" fails
      Then the toast titled "Thread failed" is shown as an error
      When "Fix login" asks a question
      Then the toast titled "Input needed" is shown as a warning
      When "Fix login" finishes
      Then the toast titled "Thread completed" is shown as a success

    @backlog @desktop
    Scenario: Changing the notification mode clears waiting notifications
      Given two system notifications are waiting
      When the user changes the notification mode
      Then the notifications are dismissed and the badge is cleared

    @backlog @desktop
    Scenario: Removing an environment clears its waiting notifications
      Given a system notification is waiting for a thread on the environment "work"
      When the user removes the environment "work"
      Then that notification is dismissed
      And the badge no longer counts it

    @backlog @desktop
    Scenario: A badge over nine says so
      Given ten system notifications are waiting
      Then the badge reads "9+" where the platform draws the count

    # The web app's tab icon wore the badge instead; there is no tab in the desktop client.
    @desktop @dropped
    Scenario: The browser tab's icon shows the count of waiting notifications
      Given the user runs HAL-C2 in a browser tab
      And two system notifications are waiting
      Then the tab's icon shows a badge of 2
      When the user brings the tab to the front
      Then the tab's icon is restored
