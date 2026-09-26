# Sources:
#   apps/desktop-qt/tests/tst_Scenarios.qml (thread list scenarios)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml

Feature: Desktop shell scenarios: thread list
  Executable scenarios for the native desktop thread list, driven through the shell's test
  double: the page's state goes in and the action the list asks for comes out.

  Background:
    Given the project "Project" is in the thread list

  @desktop
  Scenario: Arrow keys and Enter open another thread
    Given the threads "First" and "Second" with "First" open
    And the thread list has keyboard focus
    When the user moves down and presses Enter
    Then "Second" opens

  @desktop
  Scenario: Shift+F10 opens the focused thread's menu beside it
    Given the thread list has keyboard focus on "First"
    When the user presses Shift+F10
    Then the menu for "First" is requested beside that thread

  @desktop
  Scenario: Settling a thread from the list
    Given the thread "First" can be settled
    When the user settles "First" from the thread list
    Then "First" is settled

  @desktop
  Scenario: A snoozed thread offers to wake instead of settle
    Given the thread "First" is snoozed
    Then "First" offers to wake but not to settle
    When the user wakes "First" from the thread list
    Then "First" is no longer snoozed

  @desktop
  Scenario: A new thread starts in the project in scope
    Given the thread list is scoped to "Project"
    When the user starts a new thread from the thread list
    Then the new thread starts in "Project"
