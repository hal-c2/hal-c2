# Sources:
#   apps/desktop-qt/src/native/SettingsController.cpp (the node's settings document, this device's preferences)
#   apps/desktop-qt/src/native/ThemeController.cpp (the theme resolved from the choice, the built-ins and published themes)
#   apps/desktop-qt/src/ThemeStore.cpp (the palette the shell draws and hands the page)
#   apps/desktop-qt/scripts/gen-themes.mjs (the built-in palettes, from packages/shared/src/themePalettes.ts)
#   apps/server-ex/lib/hal_c2/settings.ex (versioned put: a stale write is refused)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.readSettings, hal-c2.writeSettings)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (the config shape: config, config.settings, config.themes)
#   apps/web/src/components/settings/themePalette.ts (getThemeDefinition, resolveThemeAppearance: what the shell mirrors)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   Shared domain: settings/scopes-and-inheritance.feature holds the node's side of the document.

Feature: The desktop shell keeps its own settings and theme
  The Qt shell reads and saves the node's settings document itself, keeps what belongs to
  this device in a file of its own, and resolves the theme it draws without the page. The
  page follows the shell's theme instead of leading it.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"

  Rule: The shell keeps the node's settings document

    @desktop
    Scenario: The shell reads the node's settings when it connects
      Given the node's settings are at version 3 with "enableAssistantStreaming" on
      When the desktop shell is connected to its node
      Then the shell holds the node's settings at version 3
      And the shell holds "enableAssistantStreaming" on

    @desktop
    Scenario: A change is saved at the version the shell read
      Given the node's settings are at version 3 with "enableAssistantStreaming" on
      And the desktop shell is connected to its node
      When the shell turns "enableAssistantStreaming" off
      Then the node saved the change at version 3
      And the node holds "enableAssistantStreaming" off
      And the shell holds the node's settings at version 4

    @desktop
    Scenario: A change made over a stale copy keeps the other client's change
      Given the desktop shell is connected to its node
      And another client saved "diffWordWrap" on without the shell hearing of it
      When the shell turns "enableAssistantStreaming" off
      Then the node refused the shell's first save as stale
      And the node holds "diffWordWrap" on
      And the node holds "enableAssistantStreaming" off

    @desktop
    Scenario: A change that keeps meeting newer settings is reported and not saved
      Given the desktop shell is connected to its node
      And another client saves the settings each time the shell reads them
      When the shell turns "enableAssistantStreaming" off
      Then the shell reports "Settings kept changing elsewhere; not saved."
      And the node does not hold "enableAssistantStreaming" off

    @desktop
    Scenario: A change the node refuses is reported
      Given the desktop shell is connected to its node
      And the node refuses to save settings with "Settings could not be written"
      When the shell turns "enableAssistantStreaming" off
      Then the shell reports "Settings could not be written"

    @desktop
    Scenario: A change before the node's settings are read is not saved
      Given the node holds back its settings
      And the desktop shell is connected to its node
      When the shell turns "enableAssistantStreaming" off
      Then the shell reports "The node's settings are not loaded."
      And the node's settings were not written

    @desktop
    Scenario: Settings another client saves reach the shell
      Given the desktop shell is connected to its node
      When another client saves "diffWordWrap" on
      Then the shell holds "diffWordWrap" on

    @desktop
    Scenario: The node's configuration reaches the shell and follows its changes
      Given the node's configuration lists the provider "codex"
      When the desktop shell is connected to its node
      Then the shell's configuration lists the provider "codex"
      When the node's providers become "claude"
      Then the shell's configuration lists the provider "claude"

    @desktop
    Scenario: After a reconnect the shell saves at the restarted node's version
      Given the desktop shell is connected to its node
      And the shell turned "enableAssistantStreaming" off
      When the node restarts with "diffWordWrap" on
      And the shell reconnects to the node
      Then the shell holds "diffWordWrap" on
      And the shell holds the node's settings at version 0
      When the shell turns "enableAssistantStreaming" off
      Then the node saved the change at version 0

  Rule: This device's preferences stay on this device

    @desktop
    Scenario: A device preference is saved in the shell's own file
      Given the desktop shell is connected to its node
      When the shell saves the device preference "appearance" as "dark"
      Then this device's preferences file holds "appearance" as "dark"
      And the node's settings were not written

    @desktop
    Scenario: Device preferences are read back when the shell starts
      Given this device's preferences say "appearance" is "dark"
      When the desktop shell starts
      Then the app is drawn dark

    @desktop
    Scenario: A device preference that cannot be saved is reported and left as it was
      Given this device's preferences cannot be saved
      When the shell saves the device preference "appearance" as "dark"
      Then the shell reports this device's preferences could not be saved
      And the device preference "appearance" is not set

  Rule: The shell resolves its own theme and the page follows
    # The choice is made through the shell's theme store; the settings pages that offer it
    # to the user are backlog in navigation/appearance.feature.

    @desktop
    Scenario: With no theme chosen the shell draws the standard theme
      When the desktop shell starts
      Then the app uses the standard theme
      And the page is drawn in the shell's theme

    @desktop
    Scenario: A built-in theme is drawn and handed to the page
      When the theme choice becomes "grove"
      Then the app uses "grove"
      And the page is drawn in the shell's theme

    @desktop
    Scenario: Clearing the theme choice returns to the standard theme
      Given the theme choice is "grove"
      When the theme choice is cleared
      Then the app uses the standard theme

    @desktop
    Scenario Outline: A pinned appearance ignores the operating system
      Given the operating system is <system>
      When the appearance choice becomes <mode>
      Then the app is drawn <drawn>

      Examples:
        | system | mode   | drawn |
        | dark   | Light  | light |
        | light  | Dark   | dark  |
        | dark   | System | dark  |

    @desktop
    Scenario: A theme for each appearance
      Given the theme choice is "grove" for light and "ocean" for dark
      When the appearance choice becomes Light
      Then the app uses "grove"
      When the appearance choice becomes Dark
      Then the app uses "ocean"

    @desktop
    Scenario: Clearing one appearance's theme returns it to the theme choice
      Given the theme choice is "iris"
      And the theme choice is "ocean" for dark
      When the dark theme choice is cleared
      And the appearance choice becomes Dark
      Then the app uses "iris"

    @desktop
    Scenario: A theme with one appearance only takes that appearance's half
      Given the user saved a custom theme "midnight" with only a dark palette
      And the theme choice is "grove"
      When the theme choice becomes "midnight"
      Then "midnight" is the dark theme
      And the light theme is still "grove"
      When the appearance choice becomes Light
      Then the app uses "grove"

    @desktop
    Scenario: A published theme stays chosen across a reconnect
      Given the user selected the published theme "nightfall"
      When the node drops the connection
      And the shell reconnects to the node
      Then the app uses the published "nightfall"
