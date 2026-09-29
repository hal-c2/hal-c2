# Sources:
#   apps/desktop-qt/src/native/ToastController.cpp (the shell's toasts, and the page's dismissals passed on)
#   apps/desktop-qt/qml/HalC2/Bricks/Notifications.qml (draws the shell's toasts above the page's)
#   apps/desktop-qt/tests/tst_Notifications.qml
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/shell/ShellToastBridge.tsx (the page's own toasts, which stay the page's)
#   Shared domain: navigation/toasts.feature owns how a toast behaves; this file owns which
#   toasts are the shell's and which the page's.

Feature: The desktop shell shows its own toasts
  What the shell does itself (a refused settle, a snooze with Undo, a failed send) it reports in
  its own toasts, without asking the page to show them. The page's toasts (git progress and
  the like) still come from the page and are drawn next to them.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title | createdAt            |
      | t1 | p1      | First | 2026-09-23T09:50:00Z |
    And the node has the project "p1" titled "proj-1"
    And the desktop shell is connected to its node
    And the page has followed the window to its new thread
    And the node refuses "thread.settle" with "No"

  @desktop
  Scenario: The shell's toast does not go through the page
    When the user settles "env-a:t1"
    Then the user sees an "error" toast "Failed to settle thread" saying "No"
    And nothing reaches the page

  @desktop
  Scenario: Dismissing one of the page's toasts is left to the page
    When the user dismisses the page's toast "git-progress"
    Then the action "notification.dismiss" reaches the page
