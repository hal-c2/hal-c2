# Sources:
#   docs/user/keybindings.md (keybindings.json, rule shape, when keys, precedence)
#   packages/contracts/src/keybindings.ts (limits, forward-compatible decoding, KeybindingsConfigParseError)
#   packages/shared/src/keybindings.ts (when-expression evaluation)
#   apps/server-ex/lib/hal_c2/keybindings.ex (server.upsertKeybinding, server.removeKeybinding)
#   apps/desktop-qt/src/native/KeybindingController.cpp (the desktop merges config.keybindings over its defaults, as the MC changes them)
#   apps/desktop-qt/tests/native/features/KeybindingSteps.cpp (runs the @desktop scenarios against a fake MC)
#   apps/web/src/routes/__root.tsx (the "Keybindings updated" toast, KEYBINDINGS_SUCCESS_TOAST_COOLDOWN_MS)

Feature: Customising keybindings
  Custom rules live in keybindings.json in the HAL-C2 home. Each rule names a key, a command and
  an optional condition. The MC stores the rules; clients merge them over the defaults.

  Rule: The MC stores custom rules

    @mc
    Scenario: Adding a rule saves it
      Given the MC has no custom keybindings
      When a client adds the rule "mod+shift+t" for "terminal.new"
      Then the MC's keybindings include that rule
      And keybindings.json contains that rule

    @mc
    Scenario: Adding an identical rule replaces it instead of duplicating it
      Given the MC has the rule "mod+shift+t" for "terminal.new"
      When a client adds the rule "mod+shift+t" for "terminal.new" again
      Then the MC has exactly one such rule

    @mc
    Scenario: Rebinding replaces the rule it names
      Given the MC has the rule "mod+shift+t" for "terminal.new"
      When a client adds the rule "mod+alt+t" for "terminal.new" replacing the old rule
      Then the MC's keybindings include "mod+alt+t" for "terminal.new"
      And they no longer include "mod+shift+t" for "terminal.new"

    @mc
    Scenario: Removing a rule deletes it
      Given the MC has the rule "mod+shift+t" for "terminal.new"
      When a client removes that rule
      Then the MC's keybindings no longer include it

    @mc
    Scenario: Only the newest 256 rules are kept
      Given the MC has 256 custom rules
      When a client adds one more rule
      Then the MC keeps 256 rules
      And the oldest rule is gone

    @mc
    Scenario: Other clients learn about a change
      Given two clients are connected to the MC
      When one client adds a keybinding rule
      Then the other client receives the updated keybindings

    @mc
    Scenario: A write never leaves a half-written file
      When a client adds a keybinding rule
      Then keybindings.json is replaced in one step

    @mc
    Scenario: Entries that are not rules are skipped
      Given keybindings.json contains a rule and a bare string
      When the MC reads the keybindings
      Then only the rule is returned

  Rule: Clients merge custom rules with the defaults

    @desktop
    Scenario: Defaults are kept alongside custom rules
      Given keybindings.json only rebinds "chat.new"
      When the client starts
      Then every other command keeps its default shortcut

    @desktop
    Scenario: The last matching rule wins
      Given two rules bind mod+g, first to "composer.branch" and then to "diff.toggle"
      When the user presses mod+g
      Then "diff.toggle" runs

    @desktop
    Scenario: An invalid rule is ignored and the rest still apply
      Given keybindings.json has one valid rule and one with an unknown command
      When the client loads keybindings
      Then the valid rule applies
      And the unknown one is ignored

    @desktop
    Scenario: An unreadable file falls back to the defaults
      Given keybindings.json is not valid JSON
      When the client loads keybindings
      Then the default shortcuts apply
      And the user is told "Unable to parse keybindings config" with the file path

    @desktop
    Scenario: A project script can be bound
      Given the project has a script "test"
      And keybindings.json binds mod+alt+r to "script.test.run"
      When the user presses mod+alt+r
      Then the "test" script runs

    @desktop
    Scenario: A rule the MC pushes applies at once
      Given no custom keybindings
      When the MC adds the rule mod+alt+g for "diff.toggle"
      And the user presses mod+alt+g
      Then "diff.toggle" runs

    @desktop
    Scenario: A reload of the keybindings is confirmed
      Given no custom keybindings
      When the MC adds the rule mod+alt+g for "diff.toggle"
      Then the user sees a "success" toast "Keybindings updated" saying "Keybindings configuration reloaded successfully."

    @desktop
    Scenario: Reloads close together are confirmed once
      Given no custom keybindings
      When the MC adds the rule mod+alt+g for "diff.toggle"
      And the MC adds the rule mod+alt+h for "diff.toggle"
      Then the user sees the toast "Keybindings updated" once

    @desktop
    Scenario: Starting with custom keybindings is not announced
      Given keybindings.json binds mod+alt+g to "diff.toggle"
      When the client starts
      Then the user sees no toast

    @desktop
    Scenario: A rule the MC removes stops applying
      Given "diff.toggle" is bound to mod+alt+g
      When the MC removes every custom rule
      And the user presses mod+alt+g
      Then "diff.toggle" does not run

    @mc
    Scenario Outline: Rules beyond the limits are rejected
      When a client adds a rule whose <part> is <size>
      Then the rule is rejected

      Examples:
        | part            | size                                    |
        | key             | longer than 64 characters               |
        | condition       | longer than 256 characters              |
        | condition       | nested deeper than 64 levels            |
        | script id       | longer than 24 characters               |
        | script id       | starting with a dash                    |

  Rule: Conditions

    @desktop
    Scenario Outline: A condition limits where a rule applies
      Given "diff.toggle" is bound to mod+g when "<condition>"
      And <state>
      When the user presses mod+g
      Then "diff.toggle" <outcome>

      Examples:
        | condition                         | state                                         | outcome  |
        | terminalFocus                     | the composer has focus                        | does not run |
        | !terminalFocus                    | the composer has focus                        | runs     |
        | terminalOpen                      | the terminal is closed                        | does not run |
        | isDesktop                         | the user is in the desktop app                | runs     |
        | somethingUnknown                  | anything                                      | does not run |
        | terminalFocus                     | a terminal has focus                          | runs     |
        | previewOpen                       | the preview is closed                         | does not run |
        | composerFocus && turnRunning      | the composer has focus and no turn is running | does not run |
        | editableFocus                     | a text field has focus                        | runs     |
        | !(terminalOpen && previewOpen)    | both the terminal and preview are open        | does not run |
        | modelPickerOpen                   | the model picker is open                      | runs     |
        | composerFocus && composerDraft    | the composer has focus and a draft            | runs     |

      @backlog
      Examples: Not yet honoured by the native client
        | condition                         | state                                         | outcome  |
        | previewFocus                      | the preview has focus                         | runs     |
        | isWeb                             | the user is in a browser                      | runs     |
        | terminalFocus \|\| previewFocus   | the preview has focus                         | runs     |
