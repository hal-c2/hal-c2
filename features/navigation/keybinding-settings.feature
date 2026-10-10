# Sources:
#   docs/user/keybindings.md (Settings → Keybindings)
#   apps/web/src/components/settings/KeybindingsSettings.tsx
#   apps/web/src/components/settings/KeybindingsSettings.logic.ts
#   apps/desktop-qt/qml/HalC2/Bricks/KeybindingsSettings.qml (the desktop's native page)
#   apps/desktop-qt/src/native/KeybindingController.cpp (its rows, recorder and saves)
#   apps/desktop-qt/tests/native/features/KeybindingSteps.cpp (runs the rows and saves against a fake MC)
#   apps/desktop-qt/tests/tst_KeybindingsSettings.qml (runs what the page shows and how its fields take keys)

Feature: Keybindings settings
  Settings → Keybindings lists every command with its shortcut and condition, and lets the
  user record, reset, remove and add bindings without editing the file.

  Background:
    Given the user is in Settings → Keybindings

  Rule: Browsing

    @desktop
    Scenario: Every command is listed with where its binding comes from
      Then each command is listed in order with its shortcut and condition
      And each binding is marked Default, Custom or Project

    # Legacy: apps/web/src/components/settings/KeybindingsSettings.logic.test.ts (multi-binding commands)
    @backlog @desktop
    Scenario: A command with several default shortcuts lists each one as a default
      Given "chat.new" has the defaults mod+n and mod+shift+o
      Then both shortcuts are listed for "chat.new"
      And each is marked Default

    @desktop
    Scenario: The panel shows how many bindings there are
      Then the number of bindings is shown

    @desktop
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

    @desktop
    Scenario: Searching starts from its shortcut
      When the user presses mod+f
      Then the keybinding search has focus

    @desktop
    Scenario: Nothing matches the search
      When the user searches keybindings for "qqqq"
      Then the panel says "No keybindings match your search."

    @desktop
    Scenario Outline: Commands have readable names
      Then "<command>" is labelled "<label>"

      Examples:
        | command                   | label                                    |
        | composer.sendAlternate    | Composer: Opposite Queue or Steer Action |
        | composer.sendBackground   | Composer: Start in Background            |
        | thread.steerQueuedMessage | Queue: Send First Queued Message as Steer|
        | thread.editQueuedMessage  | Queue: Edit Last Queued Message          |
        | thread.copyReference      | Pull Request: Copy Link or Thread ID     |
        | script.test.run           | Run Script: Test                         |

  Rule: Recording a shortcut

    @desktop
    Scenario: Recording a new shortcut rebinds the command
      When the user records mod+shift+y for "diff.toggle"
      Then "diff.toggle" is bound to mod+shift+y
      And the binding is marked Custom

    @desktop
    Scenario: The recorder waits for a shortcut
      When the user starts recording a shortcut for "diff.toggle"
      Then the user is prompted "Press shortcut"

    @desktop
    Scenario: Escape cancels recording
      Given the user is recording a shortcut for "diff.toggle"
      When the user presses Escape
      Then "diff.toggle" keeps its previous shortcut

    @desktop
    Scenario: A shortcut needs a modifier
      Given the user is recording a shortcut for "diff.toggle"
      When the user presses Y alone
      Then nothing is recorded

    @desktop
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

    # Legacy: apps/web/src/components/settings/KeybindingsSettings.logic.ts (keybindingFromKeyboardEvent)
    @backlog @desktop
    Scenario Outline: A recorded shortcut names the key that was pressed, not what Shift made it type
      Given the user is on macOS
      And the user is recording a shortcut for "diff.toggle"
      When the user presses Command and Shift with the key that types <typed> where <place>
      Then the recorded shortcut is <stored>

      Examples:
        | typed | place                  | stored        |
        | @     | the digit 2 key sits   | mod+shift+2   |
        | "     | the digit 2 key sits   | mod+shift+2   |
        | @     | the quote key sits     | mod+shift+'   |

    @backlog @desktop
    Scenario: A recorded letter follows the user's keyboard layout
      Given the user's layout types "m" on the physical key where QWERTY has ";"
      And the user is recording a shortcut for "diff.toggle"
      When the user presses Command with that key
      Then the recorded shortcut is mod+m

  Rule: Conditions and conflicts

    @desktop
    Scenario: A binding with no condition applies always
      When the user clears every condition on a binding
      Then the binding's condition reads "Always"

    @desktop
    Scenario: Conditions are built from variables, negation and groups
      When the user adds the condition "terminalFocus", negates it, and groups it with "previewOpen"
      Then the binding's condition is "!terminalFocus && previewOpen"

    @desktop
    Scenario: A malformed condition is explained
      When the user types the condition "terminalFocus &&"
      Then the user is told "Use variables with !, &&, ||, and parentheses."

    @desktop
    Scenario: An unknown condition variable is flagged
      When the user types the condition "sidebarFocus"
      Then "sidebarFocus" is flagged as unknown

    # Legacy: apps/web/src/components/settings/KeybindingsSettings.tsx (WhenExpressionBuilder, parseError overlay)
    @backlog @desktop
    Scenario: The condition builder is paused while the typed condition is broken
      When the user types the condition "terminalFocus &&"
      Then the visual condition builder says to fix the expression to continue editing visually
      And the condition can be edited again once the expression is valid

    # Legacy: apps/web/src/components/settings/KeybindingsSettings.logic.ts (whenNodeRemoveLabel)
    @backlog @desktop
    Scenario Outline: Removing from the condition builder says how much it removes
      Given a binding whose condition is "terminalFocus && !previewOpen"
      When the user looks at the removal choice for <target>
      Then it reads "<label>"

      Examples:
        | target                       | label                            |
        | the whole condition          | Clear all conditions             |
        | one variable                 | Remove condition                 |
        | a negated variable           | Remove condition                 |
        | a group of conditions        | Remove group and its conditions  |

    @desktop
    Scenario: Conflicting bindings are called out
      When the user records mod+k for "diff.toggle"
      Then the binding says it conflicts with "commandPalette.toggle"
      And the user is told the most recent matching binding wins when both conditions can apply

  Rule: Reset, remove and add

    @desktop
    Scenario: Resetting a custom binding restores the default
      Given "diff.toggle" was rebound to mod+shift+y
      When the user resets "diff.toggle" to its default
      Then "diff.toggle" is bound to mod+d again
      And the binding is marked Default

    @desktop
    Scenario: Default bindings cannot be removed, only rebound
      Then no default binding offers to be removed

    @desktop
    Scenario: Removing a custom binding
      Given a custom binding mod+alt+r for "script.test.run"
      When the user removes that binding
      Then "script.test.run" has no shortcut

    @desktop
    Scenario: Adding a binding for a command
      When the user adds a keybinding for "thread.stop" with mod+shift+.
      Then "thread.stop" is bound to mod+shift+.

    @desktop
    Scenario: Adding a binding can be cancelled
      Given the user started adding a keybinding
      When the user cancels
      Then no binding is added

  Rule: Saving and the file

    @desktop
    Scenario: A change is saved to every connected environment
      Given two environments are connected
      When the user rebinds "diff.toggle"
      Then both environments store the new binding

    @desktop
    Scenario Outline: Save failures are reported
      Given the environment will reject keybinding changes
      When the user <action> a binding
      Then the user is told "<message>"

      Examples:
        | action  | message                    |
        | saves   | Unable to save keybinding  |
        | removes | Unable to remove keybinding|

    @desktop
    Scenario: The file opens in the preferred editor
      When the user opens keybindings.json from settings
      Then keybindings.json opens in the user's preferred editor

    @desktop
    Scenario: The file cannot be opened
      Given no editor is available
      When the user opens keybindings.json from settings
      Then the user is told "Unable to open keybindings file"

    @backlog @desktop
    Scenario: A browser warns that it may claim shortcuts
      Given the user is using HAL-C2 in a browser
      Then the panel warns that some shortcuts may be claimed by the browser before HAL-C2 sees them
      And suggests the desktop app for better keybinding support
