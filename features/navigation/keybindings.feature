# Sources:
#   docs/user/keybindings.md
#   packages/contracts/src/keybindings.ts (every static command id and script.<id>.run)
#   packages/shared/src/keybindings.ts (DEFAULT_KEYBINDINGS)
#   apps/desktop-qt/parity/web-parity.test.ts (all 35 keymap rows)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (window shortcuts forwarded as keybinding.press)
#   apps/desktop-qt/qml/HalC2/Bricks/ModelPicker.qml (modelPicker.previousProvider, nextProvider and jump.1-9 while the picker is open)
#   Keybinding ids: sidebar.toggle, navigation.back, navigation.forward, terminal.toggle,
#   terminal.split, terminal.splitVertical, terminal.new, terminal.close, rightPanel.toggle,
#   threadPanel.toggle, rightPanel.toggleMaximized, rightPanel.close, pullRequest.copyNumber,
#   diff.toggle, preview.toggle, preview.refresh, preview.focusUrl, preview.zoomIn,
#   preview.zoomOut, preview.resetZoom, commandPalette.toggle, filePicker.toggle,
#   projectSearch.toggle, theme.select, appearance.cycle, themeEditor.toggle, composer.stash,
#   composer.sendAlternate, composer.sendBackground, composer.host, composer.effort,
#   composer.mode, composer.workspace, composer.previousWorktree, composer.branch, chat.new,
#   chat.newLocal, editor.openFavorite, modelPicker.toggle, modelPicker.previousProvider,
#   modelPicker.nextProvider, modelPicker.jump.1-9, thread.stop, thread.steerQueuedMessage,
#   thread.editQueuedMessage, thread.previous, thread.next, thread.copyReference,
#   thread.settle, thread.pin, thread.undo, thread.jump.1-9, script.<id>.run

Feature: Keybindings
  Every command has an id, and most have a default shortcut that only applies in a given
  context. "mod" is Command on macOS and Ctrl everywhere else.

  Rule: Every default binding runs its command in its context

    @desktop
    Scenario Outline: A default binding runs its command
      Given no custom keybindings
      And the user is <context>
      When the user presses <key>
      Then the command "<command>" runs

      Examples: Forwarded by the desktop shell today
        | command                      | key                 | context                    | status  |
        | sidebar.toggle               | mod+b               | anywhere                   | aligned |
        | navigation.back              | mod+[               | outside a terminal         | aligned |
        | navigation.forward           | mod+]               | outside a terminal         | aligned |
        | terminal.toggle              | mod+j               | anywhere                   | aligned |
        | rightPanel.toggle            | mod+alt+b           | anywhere                   | aligned |
        | terminal.split               | mod+d               | in a terminal              | aligned |
        | diff.toggle                  | mod+d               | outside a terminal         | aligned |
        | commandPalette.toggle        | mod+k               | outside a terminal         | aligned |
        | filePicker.toggle            | mod+p               | outside a terminal         | aligned |
        | projectSearch.toggle         | mod+shift+f         | outside a terminal         | aligned |
        | theme.select                 | mod+alt+a           | outside a terminal         | aligned |
        | chat.new                     | mod+n               | outside a terminal         | aligned |
        | chat.newLocal                | mod+shift+n         | outside a terminal         | aligned |
        | modelPicker.toggle           | mod+shift+m         | outside a terminal         | aligned |
        | editor.openFavorite          | mod+o               | anywhere                   | aligned |
        | thread.previous              | mod+shift+[         | anywhere                   | aligned |
        | thread.next                  | mod+shift+]         | anywhere                   | aligned |
        | thread.copyReference         | mod+shift+c         | outside a terminal         | aligned |
        | thread.settle                | mod+shift+s         | outside a terminal         | aligned |
        | thread.pin                   | mod+shift+p         | outside a terminal         | aligned |
        | modelPicker.previousProvider | mod+shift+arrowup   | with the model picker open | aligned |
        | modelPicker.nextProvider     | mod+shift+arrowdown | with the model picker open | aligned |
        | modelPicker.jump.1           | mod+1               | with the model picker open | aligned |
        | modelPicker.jump.2           | mod+2               | with the model picker open | aligned |
        | modelPicker.jump.3           | mod+3               | with the model picker open | aligned |
        | modelPicker.jump.4           | mod+4               | with the model picker open | aligned |
        | modelPicker.jump.5           | mod+5               | with the model picker open | aligned |
        | modelPicker.jump.6           | mod+6               | with the model picker open | aligned |
        | modelPicker.jump.7           | mod+7               | with the model picker open | aligned |
        | modelPicker.jump.8           | mod+8               | with the model picker open | aligned |
        | modelPicker.jump.9           | mod+9               | with the model picker open | aligned |

      @backlog
      Examples: Not yet honoured by the native client
        | command                   | key             | context                           | status  |
        | terminal.splitVertical    | mod+shift+d     | in a terminal                     | backlog |
        | terminal.new              | mod+n           | in a terminal                     | backlog |
        | terminal.close            | mod+w           | in a terminal                     | backlog |
        | rightPanel.close          | mod+w           | outside a terminal                | backlog |
        | pullRequest.copyNumber    | mod+shift+k     | outside a terminal                | backlog |
        | preview.toggle            | mod+shift+j     | anywhere                          | backlog |
        | preview.refresh           | mod+r           | in the preview                    | backlog |
        | preview.focusUrl          | mod+l           | in the preview                    | backlog |
        | preview.zoomIn            | mod+=           | in the preview                    | backlog |
        | preview.zoomIn            | mod++           | in the preview                    | backlog |
        | preview.zoomOut           | mod+-           | in the preview                    | backlog |
        | preview.resetZoom         | mod+0           | in the preview                    | backlog |
        | appearance.cycle          | mod+alt+shift+a | outside a terminal                | backlog |
        | themeEditor.toggle        | mod+alt+shift+t | anywhere                          | backlog |
        | composer.stash            | mod+s           | outside a terminal                | backlog |
        | thread.steerQueuedMessage | mod+shift+enter | outside a terminal                | backlog |
        | thread.editQueuedMessage  | alt+arrowup     | in the composer                   | backlog |
        | composer.sendAlternate    | mod+enter       | in the composer while a turn runs | backlog |
        | composer.sendBackground   | mod+alt+enter   | in the composer of a new thread   | backlog |
        | chat.new                  | mod+shift+o     | outside a terminal                | backlog |
        | composer.host             | mod+shift+h     | outside a terminal                | backlog |
        | composer.effort           | mod+shift+e     | outside a terminal                | backlog |
        | composer.mode             | mod+shift+a     | outside a terminal                | backlog |
        | composer.workspace        | mod+shift+x     | outside a terminal                | backlog |
        | composer.branch           | mod+shift+g     | outside a terminal                | backlog |
        | composer.previousWorktree | mod+shift+l     | outside a terminal                | backlog |
        | thread.undo               | mod+z           | outside text fields and terminals | backlog |
        | thread.jump.1             | mod+1           | anywhere                          | backlog |
        | thread.jump.2             | mod+2           | anywhere                          | backlog |
        | thread.jump.3             | mod+3           | anywhere                          | backlog |
        | thread.jump.4             | mod+4           | anywhere                          | backlog |
        | thread.jump.5             | mod+5           | anywhere                          | backlog |
        | thread.jump.6             | mod+6           | anywhere                          | backlog |
        | thread.jump.7             | mod+7           | anywhere                          | backlog |
        | thread.jump.8             | mod+8           | anywhere                          | backlog |
        | thread.jump.9             | mod+9           | anywhere                          | backlog |

    @backlog @desktop
    Scenario Outline: A command with no default binding can still be bound
      Given no custom keybindings
      Then "<command>" has no shortcut
      When the user binds "<command>" to <key>
      And the user presses <key>
      Then the command "<command>" runs

      Examples:
        | command                    | key         |
        | thread.stop                | mod+shift+. |
        | threadPanel.toggle         | mod+alt+t   |
        | rightPanel.toggleMaximized | mod+alt+m   |
        | script.test.run            | mod+alt+r   |

    @backlog @desktop
    Scenario: A binding outside its context does nothing
      Given the user is in a terminal
      When the user presses mod+k
      Then the command palette does not open
      And the terminal receives the key

    @backlog @desktop
    Scenario: The same key runs different commands in different contexts
      Given the user is in a terminal
      When the user presses mod+d
      Then the terminal splits
      But the diff panel does not toggle

  Rule: The desktop shell honours the web keymap

    The native desktop chrome registers each page shortcut as a window shortcut while the
    page does not have focus, and hands the key to the page. Each row states whether that
    works today.

    @desktop
    Scenario Outline: A web shortcut works from the native chrome
      Given the native chrome has keyboard focus
      When the user presses <key>
      Then "<command>" behaves as it does in the web app

      Examples: aligned
        | command               | key         | status  | note                                      |
        | chat.new              | mod+n       | aligned | forwarded as a keybinding press           |
        | chat.newLocal         | mod+shift+n | aligned | forwarded as a keybinding press           |
        | commandPalette.toggle | mod+k       | aligned | forwarded as a keybinding press           |
        | terminal.toggle       | mod+j       | aligned | also the header terminal toggle           |
        | sidebar.toggle        | mod+b       | aligned | also the native sidebar toggles           |
        | rightPanel.toggle     | mod+alt+b   | aligned | forwarded as a keybinding press           |
        | diff.toggle           | mod+d       | aligned | forwarded as a keybinding press           |
        | terminal.split        | mod+d       | aligned | handled by the terminal drawer's own page |
        | navigation.back       | mod+[       | aligned | forwarded as a keybinding press           |
        | navigation.forward    | mod+]       | aligned | forwarded as a keybinding press           |
        | thread.previous       | mod+shift+[ | aligned | forwarded as a keybinding press           |
        | thread.next           | mod+shift+] | aligned | forwarded as a keybinding press           |
        | filePicker.toggle     | mod+p       | aligned | forwarded as a keybinding press           |
        | projectSearch.toggle  | mod+shift+f | aligned | forwarded as a keybinding press           |
        | theme.select          | mod+alt+a   | aligned | forwarded as a keybinding press           |
        | modelPicker.toggle    | mod+shift+m | aligned | the page toggles the native model picker  |
        | editor.openFavorite   | mod+o       | aligned | forwarded as a keybinding press           |
        | thread.copyReference  | mod+shift+c | aligned | forwarded as a keybinding press           |
        | thread.settle         | mod+shift+s | aligned | forwarded as a keybinding press           |
        | thread.pin            | mod+shift+p | aligned | forwarded as a keybinding press           |

      @backlog
      Examples: backlog
        | command                   | key           | status  | note                                                  |
        | thread.jump.1-9           | mod+1..9      | backlog | only bound when running in Electron                   |
        | plan and build toggle     | shift+tab     | backlog | the native composer does not handle it                |
        | prompt history            | arrowup       | backlog | the native composer does not recall prompts           |
        | composer.sendAlternate    | mod+enter     | backlog | the window shortcut takes it and loses composer focus |
        | composer.sendBackground   | mod+alt+enter | backlog | the window shortcut takes it and loses composer focus |
        | thread.editQueuedMessage  | alt+arrowup   | backlog | only applies with composer focus                      |
        | composer.effort           | mod+shift+e   | backlog | the page opens a toolbar it does not render           |
        | composer.mode             | mod+shift+a   | backlog | the page opens a toolbar it does not render           |
        | composer.host             | mod+shift+h   | backlog | the page opens a toolbar it does not render           |
        | composer.workspace        | mod+shift+x   | backlog | the page opens a toolbar it does not render           |
        | composer.branch           | mod+shift+g   | backlog | the page opens a toolbar it does not render           |
        | composer.previousWorktree | mod+shift+l   | backlog | the page opens a toolbar it does not render           |
        | preview.toggle            | mod+shift+j   | backlog | needs the in-app preview                              |

      @dropped
      Examples: n/a
        | command                      | key                 | status | note                                     |
        | modelPicker.previousProvider | mod+shift+arrowup   | n/a    | the native picker has its own arrow keys |
        | modelPicker.nextProvider     | mod+shift+arrowdown | n/a    | the native picker has its own arrow keys |

    @desktop
    Scenario: Window shortcuts stand down while the page has focus
      Given the page has keyboard focus
      When the user presses mod+k
      Then the page handles the key itself
      And the desktop shell does not forward it a second time

    @desktop
    Scenario: Keys without a modifier are never taken by the window
      Given the composer has keyboard focus
      When the user presses Enter
      Then the composer receives the key

  Rule: Platform modifiers

    @backlog @desktop
    Scenario Outline: mod means the platform's primary modifier
      Given the user is on <platform>
      When the user presses <physical> and K
      Then the command palette opens

      Examples:
        | platform | physical |
        | macOS    | Command  |
        | Linux    | Ctrl     |
        | Windows  | Ctrl     |

    @backlog @desktop
    Scenario: Ctrl stays Ctrl on macOS
      Given the user is on macOS
      And "chat.new" is bound to ctrl+n
      When the user presses Command and N
      Then no new thread starts

  Rule: What the commands do

    @backlog @desktop
    Scenario: Undo reverses the last sidebar action
      Given the user settled a thread from the sidebar
      When the user presses mod+z within 5 seconds
      Then the thread is no longer settled

    @backlog @desktop
    Scenario: Consecutive sidebar actions of the same kind undo together
      Given the user snoozed three threads one after another
      When the user presses mod+z
      Then all three threads are awake again

    @backlog @desktop
    Scenario: Undo expires after 5 seconds
      Given the user pinned a thread 6 seconds ago
      When the user presses mod+z
      Then the thread stays pinned

    @backlog @desktop
    Scenario: Undo leaves text fields alone
      Given the user settled a thread from the sidebar
      And the composer has keyboard focus
      When the user presses mod+z
      Then the composer's own undo runs
      And the thread stays settled

    @backlog @desktop
    Scenario: Back and forward move through visited threads like browser history
      Given the user opened thread "A" and then thread "B"
      When the user goes back
      Then thread "A" is shown
      When the user goes forward
      Then thread "B" is shown

    @backlog @desktop
    Scenario: A new thread may ask which project to use
      Given the user has several projects and none is in scope
      When the user starts a new thread
      Then the user is asked to choose a project

    @backlog @desktop
    Scenario: A new local thread skips the project chooser
      Given the user has several projects
      When the user starts a new local thread
      Then a new thread starts in the current project without asking

    @backlog @desktop
    Scenario Outline: Closing with mod+w closes the innermost thing first
      Given <open>
      When the user presses mod+w
      Then <closed>

      Examples:
        | open                                              | closed                            |
        | a focused terminal and an open right panel tab    | the focused terminal closes       |
        | an active right panel tab and no focused terminal | the active right panel tab closes |
        | nothing but the window                            | the window closes                 |

    @backlog @desktop
    Scenario: Steering the first queued message
      Given a turn is running and two messages are queued
      When the user presses mod+shift+enter
      Then the first queued message is sent as a steer
      And the second stays queued

    @backlog @desktop
    Scenario: The terminal shortcut shows and hides the thread's terminal
      Given the thread's terminal is hidden
      When the user presses mod+j
      Then the thread's terminal is shown
      When the user presses mod+j again
      Then the thread's terminal is hidden

    @backlog @desktop
    Scenario Outline: Terminal shortcuts open the terminal when it is hidden
      Given the thread's terminal is hidden
      When the user runs "<command>"
      Then the thread's terminal is shown with <result>

      Examples:
        | command                | result                          |
        | terminal.new           | a new terminal                  |
        | terminal.split         | a second terminal side by side  |
        | terminal.splitVertical | a second terminal stacked below |

    @backlog @desktop
    Scenario Outline: Terminal shortcuts act on the focused terminal
      Given a terminal in the thread has keyboard focus
      When the user presses <key>
      Then <result>

      Examples:
        | key         | result                                       |
        | mod+d       | a second terminal opens side by side         |
        | mod+shift+d | a second terminal opens stacked below        |
        | mod+n       | a new terminal opens instead of a new thread |
        | mod+w       | the focused terminal closes                  |

    @backlog @desktop
    Scenario: The preview shortcut shows and hides the preview
      Given the user is looking at a thread in the desktop app
      When the user presses mod+shift+j
      Then the preview is shown
      When the user presses mod+shift+j again
      Then the preview is hidden

    @backlog @desktop
    Scenario: The preview shortcut in a browser says the preview needs the desktop app
      Given the user is looking at a thread in a browser
      When the user presses mod+shift+j
      Then the user is told "Preview is desktop-only"
      And the user is told to open HAL-C2 in the desktop app to use it

    @backlog @desktop
    Scenario Outline: Preview shortcuts act on the focused preview
      Given the preview has keyboard focus at 100% zoom
      When the user presses <key>
      Then <result>

      Examples:
        | key   | result                        |
        | mod+r | the page reloads              |
        | mod+l | the address can be typed into |
        | mod+= | the page zooms in one step    |
        | mod+- | the page zooms out one step   |
        | mod+0 | the page returns to 100% zoom |

    @backlog @desktop
    Scenario: Preview shortcuts do nothing outside the preview
      Given the composer has keyboard focus
      When the user presses mod+l
      Then the preview's address is not focused

