# Sources:
#   https://github.com/pingdotgg/t3code/pull/25131
#   https://github.com/pingdotgg/t3code/pull/18406
#   https://github.com/pingdotgg/t3code/pull/19312
#   apps/desktop-qt/src/native/SettingsController.cpp (the MC's settings document, this device's preferences)
#   apps/server-ex/lib/hal_c2/settings.ex (versioned put: a stale write is refused)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.readSettings, hal-c2.writeSettings)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (the config shape: config, config.settings, config.themes)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   settings/scopes-and-inheritance.feature holds the MC's side of the document.
#   https://github.com/pingdotgg/t3code/pull/23427

Feature: Saving settings from the desktop
  The desktop reads and saves the MC's settings document, and keeps what belongs to this
  device in a file of its own.

  Background:
    Given the desktop's MC "mc-a" serves the environment "env-a"

  Rule: The desktop keeps the MC's settings document

    @desktop
    Scenario: The desktop reads the MC's settings when it connects
      Given the MC's settings are at version 3 with "enableAssistantStreaming" on
      When the desktop shell is connected to its MC
      Then the desktop holds the MC's settings at version 3
      And the desktop holds "enableAssistantStreaming" on

    @desktop
    Scenario: A change is saved at the version the desktop read
      Given the MC's settings are at version 3 with "enableAssistantStreaming" on
      And the desktop shell is connected to its MC
      When the desktop turns "enableAssistantStreaming" off
      Then the MC saved the change at version 3
      And the MC holds "enableAssistantStreaming" off
      And the desktop holds the MC's settings at version 4

    @desktop
    Scenario: A change made over a stale copy keeps the other client's change
      Given the desktop shell is connected to its MC
      And another client saved "diffWordWrap" on without the desktop hearing of it
      When the desktop turns "enableAssistantStreaming" off
      Then the MC refused the desktop's first save as stale
      And the MC holds "diffWordWrap" on
      And the MC holds "enableAssistantStreaming" off

    @desktop
    Scenario: A change that keeps meeting newer settings is reported and not saved
      Given the desktop shell is connected to its MC
      And another client saves the settings each time the desktop reads them
      When the desktop turns "enableAssistantStreaming" off
      Then the desktop reports "Settings kept changing elsewhere; not saved."
      And the MC does not hold "enableAssistantStreaming" off

    @desktop
    Scenario: A change the MC refuses is reported
      Given the desktop shell is connected to its MC
      And the MC refuses to save settings with "Settings could not be written"
      When the desktop turns "enableAssistantStreaming" off
      Then the desktop reports "Settings could not be written"

    @desktop
    Scenario: A change before the MC's settings are read is not saved
      Given the MC holds back its settings
      And the desktop shell is connected to its MC
      When the desktop turns "enableAssistantStreaming" off
      Then the desktop reports "The MC's settings are not loaded."
      And the MC's settings were not written

    @desktop
    Scenario: Settings another client saves reach the desktop
      Given the desktop shell is connected to its MC
      When another client saves "diffWordWrap" on
      Then the desktop holds "diffWordWrap" on

    @desktop
    Scenario: The MC's configuration reaches the desktop and follows its changes
      Given the MC's configuration lists the provider "codex"
      When the desktop shell is connected to its MC
      Then the desktop's configuration lists the provider "codex"
      When the MC's providers become "claude"
      Then the desktop's configuration lists the provider "claude"

    @desktop
    Scenario: After a reconnect the desktop saves at the restarted MC's version
      Given the desktop shell is connected to its MC
      And the desktop turned "enableAssistantStreaming" off
      When the MC restarts with "diffWordWrap" on
      And the desktop reconnects to the MC
      Then the desktop holds "diffWordWrap" on
      And the desktop holds the MC's settings at version 0
      When the desktop turns "enableAssistantStreaming" off
      Then the MC saved the change at version 0

    # Upstream #18406: changes made while the first snapshot loaded were lost.
    @backlog @mc
    Scenario: A change made while a client loads its settings reaches it
      Given a client has asked for its settings and not yet received them
      When another client changes a setting
      Then the first client receives its settings followed by that change

  Rule: This device's preferences stay on this device

    @desktop
    Scenario: A device preference is saved in the desktop's own file
      Given the desktop shell is connected to its MC
      When the desktop saves the device preference "appearance" as "dark"
      Then this device's preferences file holds "appearance" as "dark"
      And the MC's settings were not written

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

    # Upstream #19312: a stored value that no longer decoded blocked every later save of it.
    @backlog @shared
    Scenario: A device preference whose stored value cannot be read can be saved again
      Given this device's stored value for "appearance" can no longer be read
      Then "appearance" is shown at its default
      When the user sets "appearance" to "dark"
      Then this device's preferences hold "appearance" as "dark" in place of the unreadable value

    # Upstream #23427: leaving a field the user had not edited saved its stale value over a newer one.
    @backlog @desktop
    Scenario: Leaving a field without editing it saves nothing
      Given the user put the cursor in the project name field and changed nothing
      And another client renames the project to "shop-v2"
      When the user leaves the field
      Then the project is still named "shop-v2"

    # Upstream #25131: fields that save when left lost their text when Escape closed Settings.
    @backlog @desktop
    Scenario Outline: Closing Settings with Escape keeps what was typed in a field
      Given the user typed a new value into <field> in Settings
      When the user closes Settings with Escape
      Then the new value of <field> is saved

      Examples:
        | field                         |
        | the thread title instructions |
        | the project name              |
        | the branch naming             |
        | the worktree location         |
