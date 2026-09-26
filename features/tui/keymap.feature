# Sources:
#   apps/tui/src/web-parity.test.ts (KEYMAP_PARITY)
#   apps/tui/src/keymap.ts (KEYBINDING_GROUPS)
#   apps/tui/src/keymap.test.ts
#   apps/tui/src/hooks/useKeyBindings.ts (mode routing)
#   apps/tui/src/components/SettingsView.tsx (keybinding reference)
#   apps/tui/src/features.backlog.test.ts (editable-settings: custom keybindings)
#   /home/olafura/dev/opentui-qml/README.md (--keymap JSON overrides)
#   Shared domain: navigation/ and parity/keybindings.feature own the cross-surface keymap.

Feature: Keyboard map of the terminal client
  Every action has a chord the terminal can deliver. Where the web app has the same action,
  the terminal chord is the closest one a terminal can send.

  @tui
  Scenario Outline: Terminal chords line up with the web app's keybindings
    Given the web app binds "<action>" to <web keys>
    Then the terminal client binds "<action>" to <keys>
    And the parity status is <status>

    Examples:
      | action               | web keys          | keys                | status  |
      | plan/build toggle    | Shift+Tab         | Shift+Tab or Ctrl+B | aligned |
      | new thread           | Cmd/Ctrl+N        | Ctrl+N              | aligned |
      | toggle terminal      | Ctrl+`            | Ctrl+E              | aligned |
      | command palette      | Cmd/Ctrl+K        | Ctrl+K              | aligned |
      | filter / search      | Cmd/Ctrl+F        | Ctrl+F              | aligned |
      | source-control panel | a visible surface | Ctrl+L              | aligned |
      | thread next/prev     | Cmd/Ctrl+[ and ]  | Alt+Up and Alt+Down | aligned |
      | thread jump 1-9      | Cmd/Ctrl+1 to 9   | Alt+1 to Alt+9      | aligned |

  # Terminal split has no terminal chord. Cmd/Ctrl+D is delivered to the shell as EOF and there is
  # no free modifier left that every terminal emulator passes through, so the TUI keeps one pane per tab.
  @dropped @tui
  Scenario: Splitting a terminal pane has a chord
    Given the web app binds "terminal split" to Cmd/Ctrl+D
    Then the terminal client binds "terminal split" to a chord

  @tui
  Scenario Outline: Global chords work from the conversation
    Given the prompt has focus
    When the user presses "<keys>"
    Then <outcome>

    Examples:
      | keys   | outcome                          |
      | Ctrl+K | the command palette opens        |
      | Ctrl+N | a new-thread draft opens         |
      | Ctrl+F | the thread filter opens          |
      | Ctrl+L | the source-control panel toggles |
      | Ctrl+E | the terminal drawer toggles      |
      | Ctrl+C | the terminal client quits        |

  @tui
  Scenario Outline: Conversation chords act on the selected thread
    Given the prompt has focus on a thread
    When the user presses "<keys>"
    Then <outcome>

    Examples:
      | keys         | outcome                                      |
      | Alt+Down     | the next thread in the list is selected      |
      | Alt+Up       | the previous thread in the list is selected  |
      | Alt+3        | the third thread in the list is selected     |
      | PgUp         | the timeline scrolls up one page             |
      | PgDn         | the timeline scrolls down one page           |
      | Ctrl+Up      | the prompt grows by a row                    |
      | Ctrl+Down    | the prompt shrinks by a row                  |
      | Ctrl+B       | the composer switches between plan and build |
      | Shift+Tab    | the composer switches between plan and build |
      | Ctrl+O       | the runtime access picker opens              |
      | Ctrl+Shift+M | the model picker opens                       |
      | Ctrl+Shift+E | the reasoning effort picker opens            |
      | Ctrl+G       | the prompt opens in the user's editor        |
      | Enter        | the reply is sent                            |

  @tui
  Scenario Outline: Chords that answer the agent act on what is waiting
    Given the thread has <waiting>
    When the user presses "<keys>"
    Then <outcome>

    Examples:
      | waiting                       | keys   | outcome                  |
      | a proposed plan               | Ctrl+Y | the plan is implemented  |
      | a request for approval        | Ctrl+A | the request is approved  |
      | a request for approval        | Ctrl+R | the request is declined  |
      | a question the user set aside | Ctrl+U | the question opens again |

  @tui
  Scenario: Esc clears the draft before it stops the turn
    Given the agent is working on a turn
    And the prompt holds a draft
    When the user presses "Esc"
    Then the draft is cleared
    And the turn keeps running
    When the user presses "Esc" again
    Then the turn stops

  @tui
  Scenario Outline: Terminal chords act on the terminal drawer
    Given the terminal drawer is open with focus
    When the user presses "<keys>"
    Then <outcome>

    Examples:
      | keys       | outcome                                              |
      | Ctrl+P     | focus moves back to the prompt                       |
      | Ctrl+Up    | the drawer grows by 2 rows                           |
      | Ctrl+Down  | the drawer shrinks by 2 rows                         |
      | Ctrl+O     | the visible terminal text is copied to the clipboard |
      | Shift+PgUp | the scrollback moves up one page                     |
      | Shift+Up   | the scrollback moves up one line                     |
      | Ctrl+E     | the drawer hides                                     |

  @tui
  Scenario Outline: Lists and overlays share the same movement keys
    Given the <overlay> is open
    When the user presses "<keys>"
    Then <outcome>

    Examples:
      | overlay              | keys   | outcome                                     |
      | command palette      | Down   | the next command is highlighted             |
      | command palette      | Up     | the previous command is highlighted         |
      | command palette      | Enter  | the highlighted command runs                |
      | command palette      | Esc    | the palette closes                          |
      | diff viewer          | s      | the diff switches between split and stacked |
      | diff viewer          | Esc    | the diff viewer closes                      |
      | thread context menu  | j      | the next enabled item is highlighted        |
      | thread context menu  | k      | the previous enabled item is highlighted    |
      | source-control panel | Down   | the next git action is highlighted          |
      | source-control panel | Up     | the previous git action is highlighted      |
      | source-control panel | Enter  | the highlighted git action runs             |
      | source-control panel | Esc    | focus returns to the conversation           |
      | source-control panel | Ctrl+L | the source-control panel closes             |
      | file browser         | Enter  | the highlighted file opens                  |
      | model picker         | Enter  | the highlighted model is applied            |

  @tui
  Scenario: Enter on the pull request link in the source-control panel copies it
    Given the branch has an open pull request
    And the source-control panel has focus on the pull request link
    When the user presses "Enter"
    Then the pull request link is copied to the clipboard

  @tui
  Scenario: Ctrl+P from any auxiliary pane returns focus to the prompt
    Given the source-control panel has focus
    When the user presses "Ctrl+P"
    Then the prompt has focus

  @tui
  Scenario: The context menu skips disabled items and wraps around
    Given the thread context menu is open for a thread with no workspace
    When the user moves down past the last item
    Then the highlight wraps to the first item
    And "Copy path" is never highlighted

  @tui
  Scenario: Wheel events that tmux delivers as arrow keys never change the thread
    Given the terminal client runs inside tmux without mouse passthrough
    When the user scrolls the wheel over the timeline
    Then the selected thread does not change

  @tui
  Scenario: The settings overlay lists every binding by context
    When the user opens settings from the command palette
    Then the keybinding reference lists the Global, Conversation, Terminal, Source control and Overlays groups
    And every chord the client handles appears in it

  @backlog @tui
  Scenario: A help overlay lists the chords available in the current focus
    Given the terminal drawer has focus
    When the user asks for help
    Then an overlay lists the chords that work in the terminal drawer
    And closing it returns focus to the terminal drawer

  @backlog @tui
  Scenario: A leader key opens a second layer of chords
    When the user presses the leader key
    Then the client shows the chords that can follow it
    And pressing "Esc" cancels the leader without acting

  @backlog @tui
  Scenario: The user rebinds a chord with a keymap JSON file
    Given a keymap file that binds "new thread" to "Ctrl+T"
    When the user starts the terminal client with that keymap file
    Then "Ctrl+T" starts a new thread
    And "Ctrl+N" no longer does

  @backlog @tui
  Scenario: Removing a binding in the keymap file frees the chord
    Given a keymap file that sets "filter threads" to null
    When the user starts the terminal client with that keymap file
    Then "Ctrl+F" is passed through to the focused input

  @backlog @tui
  Scenario: A conflicting custom binding is reported instead of silently winning
    Given a keymap file that binds "new thread" and "command palette" to the same chord
    When the user starts the terminal client with that keymap file
    Then the client reports the conflict
    And both actions keep their default chords

  @backlog @tui
  Scenario: Custom keybindings are edited from the client with conflict checks
    When the user rebinds "toggle terminal" from settings
    Then the new chord takes effect immediately
    And a chord already in use is refused with the action that owns it
