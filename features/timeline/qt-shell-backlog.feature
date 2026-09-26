# Sources:
#   apps/desktop-qt/parity/features.backlog.test.ts (thread-notifications)
#   apps/desktop-qt/qml/T3/Bricks/Notifications.qml
#   docs/internals/desktop-qt.md (native notification presenter)

Feature: Desktop shell gaps: thread notifications
  Operating system notifications the Electron desktop app delivers that the native desktop
  shell does not yet deliver on its own.

  @backlog @desktop
  Scenario: A turn that finishes in the background notifies without extensions
    Given the native desktop shell has no notification extension installed
    And the app is in the background
    When a turn finishes
    Then an operating system notification arrives

  @backlog @desktop
  Scenario: macOS gets a notification when a thread needs approval
    Given the user is on macOS
    And the app is in the background
    When a thread asks for approval
    Then a native macOS notification arrives

  @backlog @desktop
  Scenario: The dock or taskbar badge counts unseen completions
    Given the app is in the background
    When two turns finish
    Then the dock or taskbar badge shows 2

  @backlog @desktop
  Scenario: The badge clears when the user returns
    Given the dock or taskbar badge shows 2
    When the user returns to the app
    Then the badge is cleared
