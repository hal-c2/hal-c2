# Sources:
#   apps/desktop-qt/src/native/SettingsController.cpp (the node's settings document, this device's preferences)
#   apps/server-ex/lib/hal_c2/settings.ex (versioned put: a stale write is refused)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.readSettings, hal-c2.writeSettings)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (the config shape: config, config.settings, config.themes)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   settings/scopes-and-inheritance.feature holds the node's side of the document.

Feature: Saving settings from the desktop
  The desktop reads and saves the node's settings document, and keeps what belongs to this
  device in a file of its own.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"

  Rule: The desktop keeps the node's settings document

    @desktop
    Scenario: The desktop reads the node's settings when it connects
      Given the node's settings are at version 3 with "enableAssistantStreaming" on
      When the desktop shell is connected to its node
      Then the desktop holds the node's settings at version 3
      And the desktop holds "enableAssistantStreaming" on

    @desktop
    Scenario: A change is saved at the version the desktop read
      Given the node's settings are at version 3 with "enableAssistantStreaming" on
      And the desktop shell is connected to its node
      When the desktop turns "enableAssistantStreaming" off
      Then the node saved the change at version 3
      And the node holds "enableAssistantStreaming" off
      And the desktop holds the node's settings at version 4

    @desktop
    Scenario: A change made over a stale copy keeps the other client's change
      Given the desktop shell is connected to its node
      And another client saved "diffWordWrap" on without the desktop hearing of it
      When the desktop turns "enableAssistantStreaming" off
      Then the node refused the desktop's first save as stale
      And the node holds "diffWordWrap" on
      And the node holds "enableAssistantStreaming" off

    @desktop
    Scenario: A change that keeps meeting newer settings is reported and not saved
      Given the desktop shell is connected to its node
      And another client saves the settings each time the desktop reads them
      When the desktop turns "enableAssistantStreaming" off
      Then the desktop reports "Settings kept changing elsewhere; not saved."
      And the node does not hold "enableAssistantStreaming" off

    @desktop
    Scenario: A change the node refuses is reported
      Given the desktop shell is connected to its node
      And the node refuses to save settings with "Settings could not be written"
      When the desktop turns "enableAssistantStreaming" off
      Then the desktop reports "Settings could not be written"

    @desktop
    Scenario: A change before the node's settings are read is not saved
      Given the node holds back its settings
      And the desktop shell is connected to its node
      When the desktop turns "enableAssistantStreaming" off
      Then the desktop reports "The node's settings are not loaded."
      And the node's settings were not written

    @desktop
    Scenario: Settings another client saves reach the desktop
      Given the desktop shell is connected to its node
      When another client saves "diffWordWrap" on
      Then the desktop holds "diffWordWrap" on

    @desktop
    Scenario: The node's configuration reaches the desktop and follows its changes
      Given the node's configuration lists the provider "codex"
      When the desktop shell is connected to its node
      Then the desktop's configuration lists the provider "codex"
      When the node's providers become "claude"
      Then the desktop's configuration lists the provider "claude"

    @desktop
    Scenario: After a reconnect the desktop saves at the restarted node's version
      Given the desktop shell is connected to its node
      And the desktop turned "enableAssistantStreaming" off
      When the node restarts with "diffWordWrap" on
      And the desktop reconnects to the node
      Then the desktop holds "diffWordWrap" on
      And the desktop holds the node's settings at version 0
      When the desktop turns "enableAssistantStreaming" off
      Then the node saved the change at version 0

  Rule: This device's preferences stay on this device

    @desktop
    Scenario: A device preference is saved in the desktop's own file
      Given the desktop shell is connected to its node
      When the desktop saves the device preference "appearance" as "dark"
      Then this device's preferences file holds "appearance" as "dark"
      And the node's settings were not written

    @desktop
    Scenario: Device preferences are read back when the desktop starts
      Given this device's preferences say "appearance" is "dark"
      When the desktop shell starts
      Then the app is drawn dark

    @desktop
    Scenario: A device preference that cannot be saved is reported and left as it was
      Given this device's preferences cannot be saved
      When the desktop saves the device preference "appearance" as "dark"
      Then the desktop reports this device's preferences could not be saved
      And the device preference "appearance" is not set
