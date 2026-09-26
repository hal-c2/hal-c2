# Sources:
#   apps/web/src/components/settings/NotificationSettings.tsx
#   apps/web/src/threadNotifications.ts
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

    @backlog @desktop
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

    @backlog @desktop
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

  Rule: What the user is told

    @backlog @desktop
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

    @backlog @desktop
    Scenario: Clicking a notification opens the thread
      Given a system notification for "Fix login" is shown
      When the user clicks it
      Then HAL-C2 comes to the front showing "Fix login"

    @backlog @desktop
    Scenario: A toast appears instead while HAL-C2 is in front
      Given in-app notifications are on
      And HAL-C2 is in front showing another thread
      When "Fix login" finishes
      Then a toast says the thread completed and offers to open it
      And no system notification is shown

    @backlog @desktop
    Scenario: The thread on screen does not notify
      Given in-app notifications are on
      And HAL-C2 is in front showing "Fix login"
      When "Fix login" finishes
      Then no toast or notification is shown

    @backlog @desktop
    Scenario: Archived threads and subagents do not notify
      Given "Fix login" is archived
      When "Fix login" finishes
      Then no notification is shown

    @backlog @desktop
    Scenario: The app badge counts unseen notifications and clears on focus
      Given two system notifications are waiting
      Then the app shows a badge of 2
      When the user brings HAL-C2 to the front
      Then the notifications are dismissed and the badge is cleared
