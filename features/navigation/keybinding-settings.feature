# Sources:
#   docs/user/keybindings.md (Settings → Keybindings)
#   apps/web/src/components/settings/KeybindingsSettings.tsx
#   apps/web/src/components/settings/KeybindingsSettings.logic.ts

Feature: Keybindings settings
  Settings → Keybindings lists every command with its shortcut and condition, and lets the
  user record, reset, remove and add bindings without editing the file.

  Background:
    Given the user is in Settings → Keybindings

  Rule: Browsing

    @backlog @desktop
    Scenario: Every command is listed with where its binding comes from
      Then each command is listed in order with its shortcut and condition
      And each binding is marked Default, Custom or Project

    @backlog @desktop
    Scenario: The panel shows how many bindings there are
      Then the number of bindings is shown

    @backlog @desktop
    Scenario Outline: Searching filters bindings
      When the user searches keybindings for "<query>"
      Then only bindings whose <field> matches are listed

      Examples:
        | query          | field     |
        | terminal.split | command   |
        | Start in Back  | label     |
        | mod+shift+e    | key       |
        | terminalFocus  | condition |
        | Custom         | source    |

    @backlog @desktop
    Scenario: Searching starts from its shortcut
      When the user presses mod+f
      Then the keybinding search has focus

    @backlog @desktop
    Scenario: Nothing matches the search
      When the user searches keybindings for "qqqq"
      Then the panel says "No keybindings match your search."

    @backlog @desktop
    Scenario Outline: Commands have readable names
      Then "<command>" is labelled "<label>"

      Examples:
        | command                   | label                                    |
        | composer.sendAlternate    | Composer: Opposite Queue or Steer Action |
        | composer.sendBackground   | Composer: Start in Background            |
        | thread.steerQueuedMessage | Queue: Send First Queued Message as Steer|
        | thread.editQueuedMessage  | Queue: Edit Last Queued Message          |
        | thread.copyReference      | Pull Request: Copy Link or Thread ID     |
        | script.test.run           | Run Script: test                         |

  Rule: Recording a shortcut

    @backlog @desktop
    Scenario: Recording a new shortcut rebinds the command
      When the user records mod+shift+y for "diff.toggle"
      Then "diff.toggle" is bound to mod+shift+y
      And the binding is marked Custom

    @backlog @desktop
    Scenario: The recorder waits for a shortcut
      When the user starts recording a shortcut for "diff.toggle"
      Then the user is prompted "Press shortcut"

    @backlog @desktop
    Scenario: Escape cancels recording
      Given the user is recording a shortcut for "diff.toggle"
      When the user presses Escape
      Then "diff.toggle" keeps its previous shortcut

    @backlog @desktop
    Scenario: A shortcut needs a modifier
      Given the user is recording a shortcut for "diff.toggle"
      When the user presses Y alone
      Then nothing is recorded

    @backlog @desktop
    Scenario Outline: Recorded modifiers follow the platform
      Given the user is on <platform>
      When the user records <pressed> plus Y
      Then the recorded shortcut is <stored>

      Examples:
        | platform | pressed | stored  |
        | macOS    | Command | mod+y   |
        | macOS    | Control | ctrl+y  |
        | Linux    | Ctrl    | mod+y   |
        | Linux    | Super   | meta+y  |

  Rule: Conditions and conflicts

    @backlog @desktop
    Scenario: A binding with no condition applies always
      When the user clears every condition on a binding
      Then the binding's condition reads "Always"

    @backlog @desktop
    Scenario: Conditions are built from variables, negation and groups
      When the user adds the condition "terminalFocus", negates it, and groups it with "previewOpen"
      Then the binding's condition is "!terminalFocus && previewOpen"

    @backlog @desktop
    Scenario: A malformed condition is explained
      When the user types the condition "terminalFocus &&"
      Then the user is told "Use variables with !, &&, ||, and parentheses."

    @backlog @desktop
    Scenario: An unknown condition variable is flagged
      When the user types the condition "sidebarFocus"
      Then "sidebarFocus" is flagged as unknown

    @backlog @desktop
    Scenario: Conflicting bindings are called out
      When the user records mod+k for "diff.toggle"
      Then the binding says it conflicts with "commandPalette.toggle"
      And the user is told the most recent matching binding wins when both conditions can apply

  Rule: Reset, remove and add

    @backlog @desktop
    Scenario: Resetting a custom binding restores the default
      Given "diff.toggle" was rebound to mod+shift+y
      When the user resets "diff.toggle" to its default
      Then "diff.toggle" is bound to mod+d again
      And the binding is marked Default

    @backlog @desktop
    Scenario: Default bindings cannot be removed, only rebound
      Then no default binding offers to be removed

    @backlog @desktop
    Scenario: Removing a custom binding
      Given a custom binding mod+alt+r for "script.test.run"
      When the user removes that binding
      Then "script.test.run" has no shortcut

    @backlog @desktop
    Scenario: Adding a binding for a command
      When the user adds a keybinding for "thread.stop" with mod+shift+.
      Then "thread.stop" is bound to mod+shift+.

    @backlog @desktop
    Scenario: Adding a binding can be cancelled
      Given the user started adding a keybinding
      When the user cancels
      Then no binding is added

  Rule: Saving and the file

    @backlog @desktop
    Scenario: A change is saved to every connected environment
      Given two environments are connected
      When the user rebinds "diff.toggle"
      Then both environments store the new binding

    @backlog @desktop
    Scenario Outline: Save failures are reported
      Given the environment will reject keybinding changes
      When the user <action> a binding
      Then the user is told "<message>"

      Examples:
        | action  | message                    |
        | saves   | Unable to save keybinding  |
        | removes | Unable to remove keybinding|

    @backlog @desktop
    Scenario: The file opens in the preferred editor
      When the user opens keybindings.json from settings
      Then keybindings.json opens in the user's preferred editor

    @backlog @desktop
    Scenario: The file cannot be opened
      Given no editor is available
      When the user opens keybindings.json from settings
      Then the user is told "Unable to open keybindings file"

    @backlog @desktop
    Scenario: A browser warns that it may claim shortcuts
      Given the user is using HAL-C2 in a browser
      Then the panel warns that some shortcuts may be claimed by the browser before HAL-C2 sees them
      And suggests the desktop app for better keybinding support
