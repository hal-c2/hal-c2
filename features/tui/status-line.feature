# Sources:
#   apps/tui/src/host/statusLog.ts, statusLog.test.ts (the pinned error, dismissal, the history)
#   apps/tui/src/host/statusState.ts (the row: an error beside the message that followed it)
#   apps/tui/qml/HalC2/Tui/StatusLine.qml (click to dismiss, a replacing plugin yields)
#   hal-c2/hal-c2#86 (an error replaced by the next status message was never read)
#   Shared domain: navigation/toasts.feature owns how the desktop reports the same failures;
#   plugins/ui-plugins.feature owns the "statusbar" slot's modes.

Feature: Errors stay on the terminal client's status line
  The status line holds one message, and the desktop's toasts have no counterpart in a
  terminal. An error would be gone before it was read, so it stays until the user dismisses it
  (clicking it, or the palette's "Dismiss the status error") or a newer error takes its place.
  Messages that follow it show beside it. "Show status history" lists the recent errors. A hint
  about what the user just typed ("Commit needs a message.") is a warning, not an error: it
  does not stay once the next message arrives.

  Background:
    Given the terminal client is open on a thread whose workspace is a git repository

  @tui
  Scenario: An error stays on the status line when a later message arrives
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    When the user pulls the branch
    Then the status line shows "Pull failed: Error: offline"
    When pulling will succeed
    And the user pulls the branch
    Then the status line shows "Pull failed: Error: offline" before "Pulled."

  @tui
  Scenario: A hint about the user's input does not stay on the line
    Given the terminal is 160 columns wide
    And the user submits an empty commit message
    And the status line shows "Commit needs a message."
    And pulling will succeed
    When the user pulls the branch
    Then the status line shows "Pulled."
    And the status line no longer shows "Commit needs a message."

  @tui
  Scenario: A newer error takes the place of the one on the line
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    And the user pulls the branch
    When pulling will fail with "timed out"
    And the user pulls the branch
    Then the status line shows "Pull failed: Error: timed out"
    And the status line no longer shows "Pull failed: Error: offline"

  @tui
  Scenario: The palette dismisses the error
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    And the user pulls the branch
    When the user runs the palette command "Dismiss the status error"
    Then the status line no longer shows "Pull failed"
    And the palette does not offer "Dismiss the status error"

  @tui
  Scenario: Clicking the error dismisses it
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    And the user pulls the branch
    When the user clicks "Pull failed: Error: offline" on the status line
    Then the status line no longer shows "Pull failed"

  @tui
  Scenario: Clicking a later message beside the error leaves the error on the line
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    And the user pulls the branch
    And pulling will succeed
    And the user pulls the branch
    When the user clicks "Pulled." on the status line
    Then the status line shows "Pull failed: Error: offline" before "Pulled."

  @tui
  Scenario: A message after a dismissed error shows on its own
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    And the user pulls the branch
    And the user clicks "Pull failed: Error: offline" on the status line
    When pulling will succeed
    And the user pulls the branch
    Then the status line shows "Pulled."
    And the status line no longer shows "Pull failed"

  @tui
  Scenario: The status history lists the recent errors, newest first
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    And the user pulls the branch
    And pulling will fail with "timed out"
    And the user pulls the branch
    When the user runs the palette command "Show status history"
    Then the picker "Status history" lists "Pull failed: Error: timed out" then "Pull failed: Error: offline"

  @tui
  Scenario: A plugin that replaces the status message gives way to an error
    Given the plugin "clock" replaces the "statusbar" content
    And pulling will fail with "offline"
    When the user pulls the branch
    Then the status line shows "Pull failed: Error: offline" before "[clock]"

  @tui
  Scenario: The plugin has the line again once the error is dismissed
    Given the plugin "clock" replaces the "statusbar" content
    And pulling will fail with "offline"
    And the user pulls the branch
    When the user clicks "Pull failed: Error: offline" on the status line
    Then the status line shows "[clock]"
    And the status line no longer shows "Pull failed"

  # The status line and the picker cut a long error to their width, so choosing an entry gives the whole text.
  @tui
  Scenario: Choosing an error in the status history copies it
    Given the terminal is 160 columns wide
    And pulling will fail with "offline"
    And the user pulls the branch
    And the user runs the palette command "Show status history"
    When the user chooses "Pull failed: Error: offline" in the picker
    Then "Pull failed: Error: offline" is on the clipboard
    And the status line shows "Error copied to clipboard."

  @tui
  Scenario: A terminal without a clipboard says so when an error is chosen from the history
    Given the terminal is 160 columns wide
    And the user's terminal does not support OSC 52
    And pulling will fail with "offline"
    And the user pulls the branch
    And the user runs the palette command "Show status history"
    When the user chooses "Pull failed: Error: offline" in the picker
    Then the status line shows "Clipboard unavailable here."
