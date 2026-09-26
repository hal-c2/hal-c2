# Sources:
#   apps/desktop-qt/tests/tst_Scenarios.qml (composer scenarios)
#   apps/desktop-qt/qml/T3/Bricks/Composer.qml

Feature: Desktop shell scenarios: composer
  Executable scenarios for the native desktop composer, driven through the shell's test
  double: the page's state goes in and the action the composer asks for comes out.

  @desktop
  Scenario: Enter sends the draft in the foreground
    Given the composer has the draft "Fix the build"
    When the user presses Enter
    Then "Fix the build" is sent in the foreground

  @desktop
  Scenario: Switching from build to plan
    Given the composer is in build mode
    When the user switches the composer's mode
    Then plan mode is requested

  @desktop
  Scenario: With a turn running and no draft, the primary action stops the turn
    Given a turn is running
    And the composer is empty
    When the user uses the composer's primary action
    Then the turn is interrupted
    And nothing is sent

  @desktop
  Scenario: The page can open and close the model picker
    When the page asks to toggle the model picker
    Then the model picker is open
    When the page asks to toggle the model picker again
    Then the model picker is closed
