# Sources:
#   apps/desktop-qt/src/native/ToastController.cpp (timing, dismiss, a failure without a reason)
#   apps/desktop-qt/qml/HalC2/Bricks/Notifications.qml
#   apps/desktop-qt/tests/native/features/ToastSteps.cpp
#   apps/web/src/components/ui/toast.tsx (the five second timeout)
#   Shared domain: desktop/native-toasts.feature owns which toasts the Qt shell raises itself and
#   which it leaves to the page; timeline/notifications.feature owns alerts about threads.

Feature: Toasts
  Something the user did that failed is reported in a toast. A toast goes away on its own and
  the user can dismiss it sooner. The terminal client reports the same failures on its status
  line instead.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title | createdAt            |
      | t1 | p1      | First | 2026-09-23T09:50:00Z |
    And the node has the project "p1" titled "proj-1"
    And the desktop shell is connected to its node
    And the node refuses "thread.settle" with "No"

  @desktop
  Scenario: A toast goes away on its own after five seconds
    Given the user settles "env-a:t1"
    And the user sees an "error" toast "Failed to settle thread" saying "No"
    When 4 seconds pass
    Then the user sees an "error" toast "Failed to settle thread"
    When 1 second passes
    Then the toast "Failed to settle thread" is gone

  @desktop
  Scenario: Dismissing a toast
    Given the user settles "env-a:t1"
    And the user sees an "error" toast "Failed to settle thread" saying "No"
    When the user dismisses the toast "Failed to settle thread"
    Then the toast "Failed to settle thread" is gone

  @desktop
  Scenario: A failure without a reason still says something went wrong
    Given the node refuses "thread.settle" with ""
    When the user settles "env-a:t1"
    Then the user sees an "error" toast "Failed to settle thread" saying "An error occurred."
