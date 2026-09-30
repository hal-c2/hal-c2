# Sources:
#   apps/desktop-qt/tests/tst_Scenarios.qml (composer scenarios)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml
#   apps/web/src/components/chat/ModelPickerContent.tsx, apps/web/src/components/chat/ModelPickerSidebar.tsx (the picker the native one copies)

Feature: Desktop shell scenarios: composer
  Executable scenarios for the native desktop composer, driven through the shell's test
  double: the shell's state goes in and the action the composer asks for comes out.

  @desktop @backlog-desktop
  Scenario: Enter sends the draft in the foreground
    Given the composer has the draft "Fix the build"
    When the user presses Enter
    Then "Fix the build" is sent in the foreground

  @desktop @backlog-desktop
  Scenario: Switching from build to plan
    Given the composer is in build mode
    When the user switches the composer's mode
    Then plan mode is requested

  @desktop @backlog-desktop
  Scenario: Shift+Tab switches from build to plan
    Given the composer is in build mode with keyboard focus
    When the user presses Shift+Tab
    Then plan mode is requested
    And the composer keeps the keyboard

  @desktop @backlog-desktop
  Scenario: Up in an empty composer recalls the previous prompt
    Given the composer is empty with keyboard focus
    When the user presses Up
    Then the shell is asked for the previous prompt
    When the shell recalls "Run the tests"
    Then the composer contains "Run the tests"

  @desktop @backlog-desktop
  Scenario: Up below the first line moves the caret
    Given the composer holds two lines with the caret on the second
    When the user presses Up
    Then the shell is not asked for the previous prompt

  @desktop @backlog-desktop
  Scenario Outline: The shell's toolbar shortcuts open the native controls
    When the shell asks to open the <control>
    Then the native <control> opens

    Examples:
      | control            |
      | effort picker      |
      | access mode picker |
      | host picker        |
      | workspace picker   |
      | branch picker      |

  @desktop @backlog-desktop
  Scenario: With a turn running and no draft, the primary action stops the turn
    Given a turn is running
    And the composer is empty
    When the user uses the composer's primary action
    Then the turn is interrupted
    And nothing is sent

  @desktop @backlog-desktop
  Scenario: The shell can open and close the model picker
    When the shell asks to toggle the model picker
    Then the model picker is open
    When the shell asks to toggle the model picker again
    Then the model picker is closed

  @desktop @backlog-desktop
  Scenario: The model picker has a section for each provider the shell lists
    Given the shell lists models from Codex and Claude
    When the shell asks to toggle the model picker
    Then the model picker offers a Codex section and a Claude section
    And the Codex section lists only Codex's models

  @desktop @backlog-desktop
  Scenario: The model picker names the chosen model and its provider
    Given the shell lists models from Codex and Claude
    And the shell has chosen "Claude Opus" on Claude
    Then the model picker shows "Claude Opus" marked as a Claude model

  @desktop @backlog-desktop
  Scenario: Choosing a model in the picker asks the shell to switch
    Given the shell lists models from Codex and Claude
    When the shell asks to toggle the model picker
    And the user chooses "Claude Opus"
    Then the shell is asked to switch to "opus" on Claude
    And the model picker is closed

  @desktop @backlog-desktop
  Scenario: Searching the model picker matches provider and model names
    Given the shell lists models from Codex and Claude
    When the shell asks to toggle the model picker
    And the user searches for "claude"
    Then only Claude's models are listed

  @desktop @backlog-desktop
  Scenario: Favourite models are listed first and can be unfavourited
    Given the shell lists "Claude Opus" as a favourite
    When the shell asks to toggle the model picker
    Then the favourites list "Claude Opus" first
    When the user removes "Claude Opus" from the favourites
    Then the shell is asked to toggle "opus" on Claude as a favourite

  @desktop @backlog-desktop
  Scenario: A disabled model shows its reason and cannot be chosen
    Given the shell says "GPT-5.5" cannot be used because "Start a new thread to use this model."
    When the shell asks to toggle the model picker
    Then "GPT-5.5" shows "Start a new thread to use this model."
    When the user chooses "GPT-5.5"
    Then the shell is not asked to switch models

  @desktop @backlog-desktop
  Scenario: An unavailable provider is shown but cannot be chosen
    Given the shell lists Cursor as unavailable because "Cursor — Unavailable. Not installed."
    When the shell asks to toggle the model picker
    Then Cursor is listed with "Cursor — Unavailable. Not installed."
    And Cursor cannot be chosen

  @desktop @backlog-desktop
  Scenario: Arrow keys and Enter choose a model
    Given the shell lists models from Codex and Claude
    When the shell asks to toggle the model picker
    And the user presses Down and then Enter
    Then the shell is asked to switch to the second model listed

  @desktop @backlog-desktop
  Scenario: The provider shortcuts move between providers
    Given the shell lists models from Codex and Claude
    When the shell asks to toggle the model picker
    And the user presses the next provider shortcut
    Then only Claude's models are listed

  @desktop @backlog-desktop
  Scenario: A jump shortcut chooses the numbered model
    Given the shell lists models from Codex and Claude
    When the shell asks to toggle the model picker
    And the user presses the shortcut for the second model
    Then the shell is asked to switch to the second model listed
