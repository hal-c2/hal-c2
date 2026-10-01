# Sources:
#   /home/olafura/dev/opentui-qml src/runtime (Keymap, KeyBinding, Action, Shortcut, applyKeymapOverrides, parseKeySequence)
#   /home/olafura/dev/opentui-qml src/cli.ts (--keymap file.json)
#   /home/olafura/dev/opentui-qml test/keymap.test.ts
#   apps/tui/src/keymap.ts (KEYBINDING_GROUPS), apps/tui/src/keymap.test.ts
#   apps/tui/src/components/SettingsView.tsx (keybindings section)
#   apps/web/src/components/settings/KeybindingsSettings.tsx
#   apps/server-ex/lib/hal_c2/keybindings.ex (keybindings.json rules)
#   packages/contracts/src/rpc.ts (server.upsertKeybinding, server.removeKeybinding)
#   packages/contracts/src/keybindings.ts (KeybindingsConfigError)

Feature: Keymaps
  A keymap is a JSON file that maps key sequences to named actions. The TUI loads
  keymaps as overrides on top of its built-in bindings, and a keymap file can ship as
  a plugin. The same file format is meant to work on desktop and mobile.

  Background:
    Given the built-in keymap binds "ctrl+k" to "palette.open" and "ctrl+n" to "thread.new"

  @tui
  Scenario: A keymap file given at start overrides a built-in binding
    Given a keymap file that binds "ctrl+p" to "palette.open"
    When the TUI starts with that keymap file
    Then pressing "ctrl+p" opens the command palette

  @tui
  Scenario: A binding set to null in the keymap file is removed
    Given a keymap file that sets "ctrl+n" to null
    When the TUI starts with that keymap file
    Then pressing "ctrl+n" does not start a new thread

  @tui
  Scenario: An override can add a second key for the same action
    Given a keymap file that binds "ctrl+q" to "quit"
    And the built-in keymap binds "ctrl+c" to "quit"
    When the TUI starts with that keymap file
    Then both "ctrl+c" and "ctrl+q" quit
    And the keys listed for "quit" are "ctrl+c" and "ctrl+q"

  @tui
  Scenario: A nested section in the keymap file overrides only the keymap with that name
    Given the thread list has its own keymap named "list" that binds "j" to "next"
    And a keymap file with a "list" section that binds "n" to "next" and sets "j" to null
    When the TUI starts with that keymap file
    Then in the thread list "n" moves to the next thread
    And "j" does nothing in the thread list

  @tui
  Scenario: Overrides applied while running reach keymaps that already exist
    Given the TUI is running
    When a keymap override binds "ctrl+q" to "quit"
    Then pressing "ctrl+q" quits without a restart

  @tui
  Scenario: An override can carry a description shown when bindings are listed
    Given a keymap file that binds "ctrl+q" to "quit" with the description "Leave"
    When the keymap's bindings are listed
    Then "ctrl+q" is listed as "Leave"

  @tui
  Scenario: A keymap file that is not valid JSON stops the TUI with an error
    Given a keymap file that is not valid JSON
    When the TUI starts with that keymap file
    Then the TUI exits with a load error naming the keymap file

  @tui
  Scenario Outline: Key sequences are written in a forgiving, case-insensitive form
    Given a keymap file that binds "<written>" to "palette.open"
    When the user presses <pressed>
    Then the command palette opens

    Examples:
      | written   | pressed                 |
      | Ctrl+K    | control and k           |
      | alt+Enter | alt and enter           |
      | option+x  | alt and x               |
      | cmd+k     | the super key and k     |
      | esc       | escape                  |
      | PgDn      | page down               |
      | ctrl++    | control and plus        |

  # opentui-qml keymaps accept "hyper" as a modifier (keymap-host MODIFIER_NAMES); only parseKeySequence rejects it.
  @backlog @tui
  Scenario: A key sequence with an unknown modifier is reported and skipped
    Given a keymap file that binds "hyper+x" to "palette.open"
    When the keymap loads
    Then the user is warned that "hyper" is not a known modifier
    And the other bindings in the file still work

  @tui
  Scenario: A higher priority keymap wins a key both keymaps bind
    Given the plugin keymap "vim-nav" with high priority binds "ctrl+n" to "list.next"
    When the user presses "ctrl+n"
    Then the selection moves to the next thread
    And no new thread is started

  @tui
  Scenario: A keymap can let a key fall through to lower keymaps
    Given the plugin keymap "logger" records "ctrl+n" and lets it pass
    When the user presses "ctrl+n"
    Then "logger" records the key
    And a new thread is started

  @tui
  Scenario: A disabled keymap lets its keys through
    Given the plugin keymap "vim-nav" binds "j" to "list.next"
    When the user disables "vim-nav"
    Then pressing "j" no longer moves the selection

  @tui
  Scenario: Typing in a text field is not taken over by single-key bindings
    Given the plugin keymap "vim-nav" binds "j" to "list.next"
    And the composer has focus
    When the user types "j"
    Then "j" is added to the draft

  @tui
  Scenario: A shortcut scoped to a panel only fires while that panel has focus
    Given the terminal panel binds "ctrl+o" to "terminal.copy" for itself only
    And the composer has focus
    When the user presses "ctrl+o"
    Then the terminal viewport is not copied

  @tui
  Scenario: A plugin ships its own keymap and actions
    Given the plugin "snippets" declares the action "snippets.insert" bound to "ctrl+shift+s"
    When the plugin loads
    Then pressing "ctrl+shift+s" inserts a snippet
    And the keys listed for "snippets.insert" are "ctrl+shift+s"

  @tui
  Scenario: Removing a plugin removes its key bindings
    Given the plugin "snippets" binds "ctrl+shift+s"
    When the user removes "snippets"
    Then pressing "ctrl+shift+s" does nothing

  @tui
  Scenario: The keybinding reference lists every binding by context
    When the user opens the keybinding reference in Settings
    Then bindings are grouped into Global, Conversation, Terminal and Source control

  # The desktop's window shortcuts, and how they stand down for a focused page, are
  # navigation/keybindings.feature and navigation/keybinding-customisation.feature.

  @mc
  Scenario: A keybinding rule saved on one client reaches every client of the MC
    Given two clients are connected to the same environment
    When the user binds "ctrl+shift+n" to "thread.new" on the first client
    Then the second client receives the new rule

  @mc
  Scenario: Removing a saved keybinding rule restores the default for that key
    Given the user bound "ctrl+shift+n" to "thread.new"
    When the user removes that rule
    Then "ctrl+shift+n" does what it does by default

  @mc
  Scenario: Malformed entries in the keybindings file are skipped
    Given the MC's keybindings file contains one valid rule and one entry without a command
    When a client reads the keybindings
    Then only the valid rule is applied

  @backlog @shared @desktop @mobile @tui
  Scenario: One keymap file format works on every surface
    Given a keymap file that binds "ctrl+k" to "palette.open"
    When it is loaded on the desktop app, the mobile app with a hardware keyboard, and the TUI
    Then pressing "ctrl+k" opens the command palette on each

  @backlog @shared @desktop @mobile @tui
  Scenario: Actions a surface does not have are ignored on that surface
    Given a keymap file that binds "ctrl+e" to "terminal.toggle"
    When it is loaded on a surface without a terminal
    Then the binding is listed as unavailable on that surface
    And no error is reported

  @backlog @desktop @mobile @tui
  Scenario: A keymap file can be installed as a plugin from a paired MC or a URL
    When the user installs the keymap "vim-nav" from a paired MC
    Then "vim-nav" is listed with the installed plugins
    And its bindings take effect

  @backlog @desktop @tui
  Scenario: The TUI reads the MC's saved keybinding rules
    Given the user bound "ctrl+shift+n" to "thread.new" on the desktop app
    When the user connects the TUI to the same environment
    Then pressing "ctrl+shift+n" in the TUI starts a new thread

  @backlog @desktop @tui
  Scenario: Two keymaps that bind the same key at the same priority are flagged
    Given the keymaps "vim-nav" and "emacs-nav" both bind "ctrl+n" at the same priority
    When the user opens the keybinding reference
    Then "ctrl+n" is flagged as a conflict naming both keymaps

  @backlog @desktop @mobile @tui
  Scenario: Resetting keybindings removes every override
    Given the user has several keybinding overrides
    When the user resets keybindings to the defaults
    Then only the built-in bindings apply
