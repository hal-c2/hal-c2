# Sources:
#   apps/desktop-qt/src/native/ToastController.cpp (timing, dismiss, a failure without a reason)
#   apps/desktop-qt/qml/HalC2/Bricks/Notifications.qml
#   apps/desktop-qt/tests/native/features/ToastSteps.cpp
#   apps/web/src/components/ui/toast.tsx (the five second timeout, the stack, thread-scoped toasts,
#     expanded on keyboard focus, timers held while HAL-C2 is not in front, long error clamp and copy)
#   apps/web/src/components/GitActionsControl.logic.ts (success toasts leave after their own timeout)
#   @base-ui/react toast store (limit, expanded on hover or focus, timers held while expanded)
#   Shared domain: desktop/native-toasts.feature owns which toasts the Qt shell raises itself and
#   which it leaves to the page; timeline/notifications.feature owns alerts about threads.

Feature: Toasts
  Something the user did that failed is reported in a toast. A toast goes away on its own and
  the user can dismiss it sooner. Toasts stack, newest in front; the stack expands to show them
  all when the user points at it (on a phone, taps it) and collapses when they move away (tap
  outside it or on it again). No toast is dropped to make room. The terminal client reports the
  same failures on its status line instead.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title | createdAt            |
      | t1 | p1      | First | 2026-09-23T09:50:00Z |
      | t2 | p1      | Two   | 2026-09-23T09:51:00Z |
      | t3 | p1      | Three | 2026-09-23T09:52:00Z |
      | t4 | p1      | Four  | 2026-09-23T09:53:00Z |
      | t5 | p1      | Five  | 2026-09-23T09:54:00Z |
      | t6 | p1      | Six   | 2026-09-23T09:55:00Z |
    And the MC has the project "p1" titled "proj-1"
    And the desktop shell is connected to its MC
    And the MC refuses "thread.settle" with "No"

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
    Given the MC refuses "thread.settle" with ""
    When the user settles "env-a:t1"
    Then the user sees an "error" toast "Failed to settle thread" saying "An error occurred."

  @desktop @mobile @backlog-mobile
  Scenario: Newer toasts do not push older ones out
    When the user settles "env-a:t1"
    And the user settles "env-a:t2"
    And the user settles "env-a:t3"
    And the user settles "env-a:t4"
    And the user settles "env-a:t5"
    And the user settles "env-a:t6"
    Then the user sees 6 toasts

  @desktop @mobile @backlog-mobile
  Scenario: Toasts wait while the user looks them over
    Given the user settles "env-a:t1"
    And the user sees an "error" toast "Failed to settle thread" saying "No"
    And 4 seconds pass
    When the user expands the toasts
    And 30 seconds pass
    Then the user sees an "error" toast "Failed to settle thread"
    When the user collapses the toasts
    And 1 second passes
    Then the toast "Failed to settle thread" is gone

  @backlog @desktop @mobile
  Scenario: Only the newest three toasts show while the stack is collapsed
    When the user settles "env-a:t1"
    And the user settles "env-a:t2"
    And the user settles "env-a:t3"
    And the user settles "env-a:t4"
    Then the user sees 3 toasts while the stack is collapsed
    When the user expands the toasts
    Then the user sees 4 toasts

  @backlog @desktop
  Scenario: A toast about a thread shows only while that thread is open
    Given the user is looking at "env-a:t2"
    When the user settles "env-a:t1"
    Then the user sees no toast
    When the user opens "env-a:t1"
    Then the user sees an "error" toast "Failed to settle thread" saying "No"

  @backlog @desktop
  Scenario: A timed toast counts down only while HAL-C2 is in front
    Given the user sees a "success" toast "Committed abc0001"
    And 4 seconds pass
    When HAL-C2 is in the background for 30 seconds
    Then the user sees a "success" toast "Committed abc0001"
    When HAL-C2 comes to the front
    And 6 seconds pass
    Then the toast "Committed abc0001" is gone

  @backlog @desktop
  Scenario: Keyboard focus in the toast stack expands it
    Given the user settles "env-a:t1"
    And the user sees an "error" toast "Failed to settle thread" saying "No"
    And 4 seconds pass
    When the user moves keyboard focus into the toasts
    And 30 seconds pass
    Then the user sees an "error" toast "Failed to settle thread"
    When the user moves keyboard focus out of the toasts
    And 1 second passes
    Then the toast "Failed to settle thread" is gone

  @backlog @desktop
  Scenario: A long error is shortened in its toast and can still be copied whole
    Given the MC refuses "thread.settle" with a reason of 300 characters
    When the user settles "env-a:t1"
    Then the error toast shows its message in at most four lines
    When the user copies the error from the toast
    Then the clipboard holds the whole 300-character reason

  # Proved by tst_ShellExamples (noticesCoverNothing), not yet by a step (hal-c2/hal-c2#213).
  @desktop @backlog-desktop
  Scenario: Toasts appear under the header at the top right
    Given the terminal drawer and the thread details are open
    When a toast is shown
    Then it is below the header, at the right
    And it covers neither the window controls, the terminal drawer nor the composer
