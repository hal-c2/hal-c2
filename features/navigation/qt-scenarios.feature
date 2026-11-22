# Sources:
#   apps/desktop-qt/tests/tst_Scenarios.qml (workspace terminal toggle)
#   apps/desktop-qt/qml/HalC2/Bricks/Workspace.qml

Feature: Desktop shell scenarios: header
  Executable scenarios for the native desktop header, driven through the shell's test double.

  @desktop
  Scenario: The header's terminal toggle opens and closes the terminal drawer
    Given the thread can open a terminal
    When the user toggles the terminal from the header
    Then the terminal drawer is toggled
