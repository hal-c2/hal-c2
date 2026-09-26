# Sources:
#   docs/user/keybindings.md (keybindings.json, rule shape, when keys, precedence)
#   packages/contracts/src/keybindings.ts (limits, forward-compatible decoding, KeybindingsConfigParseError)
#   packages/shared/src/keybindings.ts (when-expression evaluation)
#   apps/server-ex/lib/t3/keybindings.ex (server.upsertKeybinding, server.removeKeybinding)

Feature: Customising keybindings
  Custom rules live in keybindings.json in the T3 home. Each rule names a key, a command and
  an optional condition. The node stores the rules; clients merge them over the defaults.

  Rule: The node stores custom rules

    @node
    Scenario: Adding a rule saves it
      Given the node has no custom keybindings
      When a client adds the rule "mod+shift+t" for "terminal.new"
      Then the node's keybindings include that rule
      And keybindings.json contains that rule

    @node
    Scenario: Adding an identical rule replaces it instead of duplicating it
      Given the node has the rule "mod+shift+t" for "terminal.new"
      When a client adds the rule "mod+shift+t" for "terminal.new" again
      Then the node has exactly one such rule

    @node
    Scenario: Rebinding replaces the rule it names
      Given the node has the rule "mod+shift+t" for "terminal.new"
      When a client adds the rule "mod+alt+t" for "terminal.new" replacing the old rule
      Then the node's keybindings include "mod+alt+t" for "terminal.new"
      And they no longer include "mod+shift+t" for "terminal.new"

    @node
    Scenario: Removing a rule deletes it
      Given the node has the rule "mod+shift+t" for "terminal.new"
      When a client removes that rule
      Then the node's keybindings no longer include it

    @node
    Scenario: Only the newest 256 rules are kept
      Given the node has 256 custom rules
      When a client adds one more rule
      Then the node keeps 256 rules
      And the oldest rule is gone

    @node
    Scenario: Other clients learn about a change
      Given two clients are connected to the node
      When one client adds a keybinding rule
      Then the other client receives the updated keybindings

    @node
    Scenario: A write never leaves a half-written file
      When a client adds a keybinding rule
      Then keybindings.json is replaced in one step

    @node
    Scenario: Entries that are not rules are skipped
      Given keybindings.json contains a rule and a bare string
      When the node reads the keybindings
      Then only the rule is returned

  Rule: Clients merge custom rules with the defaults

    @backlog @desktop
    Scenario: Defaults are kept alongside custom rules
      Given keybindings.json only rebinds "chat.new"
      When the client starts
      Then every other command keeps its default shortcut

    @backlog @desktop
    Scenario: The last matching rule wins
      Given two rules bind mod+g, first to "composer.branch" and then to "diff.toggle"
      When the user presses mod+g
      Then "diff.toggle" runs

    @backlog @desktop
    Scenario: An invalid rule is ignored and the rest still apply
      Given keybindings.json has one valid rule and one with an unknown command
      When the client loads keybindings
      Then the valid rule applies
      And the unknown one is ignored

    @backlog @desktop
    Scenario: An unreadable file falls back to the defaults
      Given keybindings.json is not valid JSON
      When the client loads keybindings
      Then the default shortcuts apply
      And the user is told "Unable to parse keybindings config" with the file path

    @backlog @desktop
    Scenario: A project script can be bound
      Given the project has a script "test"
      And keybindings.json binds mod+alt+r to "script.test.run"
      When the user presses mod+alt+r
      Then the "test" script runs

    @backlog @node
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

    @backlog @desktop
    Scenario Outline: A condition limits where a rule applies
      Given "diff.toggle" is bound to mod+g when "<condition>"
      And <state>
      When the user presses mod+g
      Then "diff.toggle" <outcome>

      Examples:
        | condition                         | state                                         | outcome  |
        | terminalFocus                     | a terminal has focus                          | runs     |
        | terminalFocus                     | the composer has focus                        | does not run |
        | !terminalFocus                    | the composer has focus                        | runs     |
        | terminalOpen                      | the terminal is closed                        | does not run |
        | previewFocus                      | the preview has focus                         | runs     |
        | previewOpen                       | the preview is closed                         | does not run |
        | modelPickerOpen                   | the model picker is open                      | runs     |
        | composerFocus && composerDraft    | the composer has focus and a draft            | runs     |
        | composerFocus && turnRunning      | the composer has focus and no turn is running | does not run |
        | editableFocus                     | a text field has focus                        | runs     |
        | isWeb                             | the user is in a browser                      | runs     |
        | isDesktop                         | the user is in the desktop app                | runs     |
        | terminalFocus \|\| previewFocus   | the preview has focus                         | runs     |
        | !(terminalOpen && previewOpen)    | both the terminal and preview are open        | does not run |
        | somethingUnknown                  | anything                                      | does not run |
