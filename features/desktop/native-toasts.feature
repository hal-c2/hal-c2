# Sources:
#   apps/desktop-qt/src/native/ToastController.cpp (the shell's toasts)
#   apps/desktop-qt/qml/HalC2/Bricks/Notifications.qml (draws them)
#   apps/desktop-qt/tests/tst_Notifications.qml
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   Shared domain: navigation/toasts.feature owns how a toast behaves; this file owns where the
#   desktop's toasts come from.

Feature: The desktop shell shows its own toasts
  What the shell does itself (a refused settle, a snooze with Undo, a failed send) it reports in
  its own toasts, and so does what the app raises on its own (a keybindings reload, a provider
  update).

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title | createdAt            |
      | t1 | p1      | First | 2026-09-23T09:50:00Z |
    And the MC has the project "p1" titled "proj-1"
    And the desktop shell is connected to its MC
    And the MC refuses "thread.settle" with "No"

  @desktop
  Scenario: A refused settle shows the shell's own toast
    When the user settles "env-a:t1"
    Then the user sees an "error" toast "Failed to settle thread" saying "No"
