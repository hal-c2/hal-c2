# Sources:
#   apps/web/src/components/ThreadNotificationCoordinator.tsx (titles, transitions only, archived threads skipped, toast only when focused elsewhere, Open thread, badge)
#   apps/web/src/threadNotifications.ts (notification modes, sounds, badge)
#   apps/web/src/shell/ShellToastBridge.tsx
#   apps/desktop-qt/qml/HalC2/Bricks/Notifications.qml (in-app alert cards, dismiss, actions)
#   apps/desktop-qt/tests/tst_Notifications.qml
#   apps/desktop-qt/tests/tst_Scenarios.qml (notification scenarios)
#   apps/desktop-qt/src/native/AlertController.cpp (which thread changes alert, and how)
#   apps/desktop-qt/src/NativeNotifications.cpp (the desktop's notification service)
#   apps/desktop-qt/tests/native/tst_NativeNotifications.cpp (clicks keep their thread, one alert per thread, disabling closes alerts)
#   apps/desktop-qt/tests/native/features/AlertSteps.cpp
#   packages/contracts/src/settings.ts (notificationMode, inAppNotificationsEnabled)
#
# The desktop raises its alerts itself (AlertController); the page's coordinator stays off in
# the shell. The TUI has no alerts. Mobile push lives in docs/user/mobile-notifications.md and is
# out of scope. Muting alerts for a single thread exists in no client yet; the phone's version is
# in mobile/notifications.feature.

Feature: Alerts when a thread needs the user
  The user runs agents in the background. HAL-C2 tells them when a thread finishes
  or is waiting on them, without alerting for the thread they are already looking at.

  Background:
    Given a connected environment with the project "shop"
    And the user has alerts turned on

  @desktop
  Scenario Outline: A thread that changes state raises an alert
    Given the thread "Tax fix" is working in the background
    When the thread <change>
    Then the user is alerted "<title>" for "Tax fix"

    Examples:
      | change                              | title               |
      | completes                           | Thread completed    |
      | asks for approval                   | Approval needed     |
      | asks the user a question            | Input needed        |
      | fails                               | Thread failed       |
      | stops at the provider's usage limit | Usage limit reached |

  @desktop
  Scenario: Threads that finished before the user connected do not alert
    Given "Tax fix" completed while the client was closed
    When the user opens the client
    Then no alert is raised for "Tax fix"

  @desktop
  Scenario: The thread being viewed does not raise an in-app alert
    Given the user is looking at "Tax fix"
    When "Tax fix" completes
    Then no in-app alert is shown for "Tax fix"

  @desktop
  Scenario: The user opens a thread from its alert
    Given an in-app alert says "Tax fix" needs approval
    When the user opens the thread from the alert
    Then "Tax fix" is shown
    And the alert is gone

  @desktop
  Scenario: The user dismisses an in-app alert
    Given an in-app alert says "Tax fix" completed
    When the user dismisses the alert
    Then the alert is gone
    And "Tax fix" is not opened

  @desktop
  Scenario Outline: The alert setting decides between a system notification and a sound
    Given alerts are set to "<mode>"
    When a background thread completes
    Then a system notification is <notification>
    And a sound is <sound>

    Examples:
      | mode                     | notification | sound      |
      | Off                      | not shown    | not played |
      | Notifications only       | shown        | not played |
      | Sound only               | not shown    | played     |
      | Notifications with sound | shown        | played     |

  @desktop
  Scenario: Clicking a system notification opens its own thread
    Given system notifications were shown for "Tax fix" and then for "Docs"
    When the user clicks the older notification
    Then "Tax fix" is shown

  @desktop
  Scenario: A newer alert for a thread replaces its older one
    Given a system notification says "Tax fix" completed
    When "Tax fix" then asks for approval
    Then only one system notification is shown for "Tax fix"
    And it says "Tax fix" needs approval

  @desktop
  Scenario: Turning system notifications off clears the ones on screen
    Given system notifications are shown for two threads
    When the user turns system notifications off
    Then both notifications are closed
    And clicking a notification that was already on its way opens nothing

  @desktop
  Scenario: A system notification is not shown without permission
    Given the operating system has not allowed notifications
    When a background thread completes
    Then no system notification is shown
    And the in-app alert and sound still follow the user's settings

  @desktop
  Scenario: Coming back to the window clears its system notifications
    Given a system notification says "Tax fix" completed
    When the user comes back to the window
    Then no system notification is shown

  @desktop
  Scenario: Threads that finished while the connection was down do not alert
    Given the thread "Tax fix" is working in the background
    And the node holds back its snapshot
    And the node drops the connection
    And the shell reconnects to the node
    And "Tax fix" completes
    When the node sends its snapshot
    Then no alert is raised for "Tax fix"

  @desktop
  Scenario Outline: Threads of other environments alert like the node's own
    Given the thread "Tax fix" is working in the background on <where>
    When the thread completes
    Then the user is alerted "Thread completed" for "Tax fix"

    Examples:
      | where                       |
      | a linked environment        |
      | another node of the cluster |

  @desktop
  Scenario: A notification's action runs it
    Given the notification "Update ready" offers "Restart"
    When the user chooses "Restart"
    Then the "Restart" action of "Update ready" runs

  @desktop
  Scenario: Dismissing the last notification hides the notifications
    Given the only notification is "Copied"
    When the user dismisses "Copied"
    Then "Copied" is dismissed
    And no notifications are shown

  @desktop @tui @backlog
  Scenario: The user mutes alerts for one thread
    Given the thread "Tax fix" is working in the background
    When the user mutes alerts for "Tax fix"
    And "Tax fix" finishes its turn
    Then no alert is raised for "Tax fix"
    And alerts for other threads in "shop" still arrive

  @desktop @tui @backlog
  Scenario: The user unmutes a thread
    Given alerts for "Tax fix" are muted
    When the user unmutes "Tax fix"
    And "Tax fix" finishes its turn
    Then an alert for "Tax fix" is raised

