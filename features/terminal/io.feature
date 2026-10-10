# Sources:
#   docs/user/terminal.md
#   docs/internals/terminal-runtime.md (pending writes drain before clear, restart and close)
#   packages/contracts/src/terminal.ts (TerminalWriteInput, TerminalResizeInput, TerminalClearInput, TerminalRestartInput, TerminalCloseInput, TerminalEvent)
#   apps/server-ex/lib/hal_c2/terminal.ex (write, resize, clear, restart, close, exit status, output batching)
#   apps/server-ex/lib/hal_c2/terminal/hub.ex (activity and running-command labels)
#   apps/server-ex/test/hal_c2/terminal_test.exs
#   apps/tui/src/components/ChatView.tsx (clearActiveTerminal, restartActiveTerminal, onTerminalKey, onTerminalCopy)
#   apps/tui/src/components/ThreadTerminalDrawer.tsx (paste, resize of the visible pane, scrollback)
#   apps/tui/src/terminalView.ts (encodeTerminalPaste, readTerminalViewport, readTerminalFrame)
#   apps/tui/src/terminalView.test.ts
#   apps/tui/src/hooks/useKeyBindings.ts (terminal key mode)
#   apps/web/src/keybindings.ts (isTerminalClearShortcut, terminalDeleteShortcutData, terminalNavigationShortcutData)
#   apps/tui/src/features.backlog.test.ts (terminal-session-actions)
#   apps/web/src/components/ThreadTerminalDrawer.tsx (copy, paste, clear shortcut, exit handling)
#   apps/web/src/terminal/ghostty/surface.ts (copy and paste keys, wheel, scrollbar, prompt position)
#   apps/web/src/terminal/ghostty/renderer.ts, runtime.ts, core.ts, keyCodes.ts (the web surface's drawing and key encoding)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalMenu.qml (menu, copy and paste keys)
#   apps/web/src/components/useThreadTerminalActions.ts
#   apps/web/src/lib/terminalCloseShortcut.ts
#   apps/server/src/terminal/Manager.ts (kill escalation, process-table polling failures)
#   apps/server/src/terminal/Manager.test.ts (scoped runtime shutdown)
#   apps/server/src/terminal/OutputProtocol.ts (output window and pause)
#   Cross-domain: tui/keymap.feature owns the terminal client's terminal chords.

Feature: Terminal input and output
  What the user types reaches the shell, and what the shell prints reaches every client
  watching it. Clearing, restarting and closing act on the MC's shell, not a local copy.

  Rule: The MC relays keystrokes and output

    @mc
    Scenario: Typed input runs in the shell and its output streams back
      Given a running terminal
      When a client writes "echo hello" and a return
      Then every client attached to the terminal receives "hello"

    @mc
    Scenario: Rapid output arrives in small batches instead of one event per byte
      Given a running terminal
      When the shell prints a thousand lines at once
      Then attached clients receive the lines in a few batched output events
      And no output is lost

    @backlog @mc
    Scenario: A client that falls behind pauses the shell's output instead of buffering it
      Given a running terminal whose shell prints continuously
      When a client stops acknowledging the output it has received
      Then only a small amount of output waits unacknowledged for that client
      And the MC stops sending output to that client until it catches up
      And the shell itself keeps running

    @mc
    Scenario: Resizing a terminal tells the running program its new size
      Given a running terminal at 120 columns and 30 rows
      When a client resizes it to 80 columns and 24 rows
      Then the running program sees 80 columns and 24 rows

    @mc
    Scenario: Clearing a terminal empties its history for every client
      Given a running terminal with output
      When a client clears it
      Then every attached client is told the terminal was cleared
      And a client attaching afterwards sees no earlier output
      And the shell keeps running

    @mc
    Scenario: Restarting a terminal starts a fresh shell with empty history
      Given a running terminal with output
      When a client restarts it
      Then the old shell stops and a new one starts in the same folder
      And every attached client is told the terminal restarted
      And the history starts empty

    @backlog @mc
    Scenario: A shell that ignores the stop request is killed after a short grace period
      Given a running terminal whose shell ignores the stop request
      When a client closes it
      Then the shell is asked to stop first
      And the shell is killed if it is still running a second later

    # Legacy: apps/server/src/terminal/Manager.test.ts (scoped runtime shutdown stops active terminals
    #   cleanly)
    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (terminate stops the shell)
    @backlog @mc
    Scenario: Stopping the MC stops every running shell
      Given running terminals, one of whose shells ignores the stop request
      When the MC shuts down
      Then each shell is asked to stop
      And the shell that ignores it is killed after the grace period
      And the MC does not wait for them longer than that

    @mc
    Scenario: Keystrokes sent just before a clear still reach the shell first
      Given a running terminal
      When a client writes a command and immediately clears the terminal
      Then the command runs before the history is cleared

    @mc
    Scenario Outline: A shell that ends reports how it ended
      Given a running terminal
      When the shell <ends>
      Then attached clients are told the terminal exited with <status>
      And the terminal's output is still readable

      Examples:
        | ends                       | status             |
        | exits with code 0          | exit code 0        |
        | exits with code 2          | exit code 2        |
        | is killed with SIGKILL     | signal 9           |

    @mc
    Scenario: A terminal shows what it is running
      Given a running terminal labelled "Terminal 1"
      When the user starts "npm run dev" in it
      Then within a second the terminal is marked as running a command
      And its label becomes "npm"

    @mc
    Scenario: A terminal goes back to its number when the command finishes
      Given a terminal labelled "npm" while a dev server runs
      When the dev server stops
      Then the terminal is no longer marked as running a command
      And its label returns to "Terminal 1"

    @backlog @mc
    Scenario: A terminal keeps working when the MC cannot list running processes
      Given a running terminal
      And the MC cannot read the list of processes on its machine
      When the user starts "npm run dev" in it
      Then the terminal keeps accepting input and showing output
      And the terminal is not marked as running a command

  Rule: The terminal client drives the shell from the keyboard

    Background:
      Given the terminal client shows a thread's terminal with focus

    @tui
    Scenario: Keys go to the shell while the terminal has focus
      When the user types "ls" and presses Enter
      Then the shell runs "ls"

    @tui
    Scenario: Pasting into a program that wants bracketed paste frames the text
      Given the running program asked for bracketed paste
      When the user pastes two lines of text
      Then the program receives both lines as one paste and does not run them line by line

    @tui
    Scenario: A pasted end-of-paste marker cannot break out of the paste
      Given the running program asked for bracketed paste
      When the user pastes text that contains an end-of-paste marker followed by a command
      Then the marker is removed
      And the command is not run as if typed

    @tui
    Scenario: Pasting into a program that did not ask for bracketed paste sends the text as is
      Given the running program did not ask for bracketed paste
      When the user pastes "echo hi"
      Then the program receives "echo hi" unchanged

    @tui
    Scenario: The user copies what the terminal shows
      Given the terminal shows three lines of output
      When the user copies the terminal
      Then the three visible lines are on the clipboard without trailing blank lines
      And the user is told "Terminal copied to clipboard."

    @tui
    Scenario: Copying scrolled-back output copies what is on screen
      Given the user has scrolled the terminal back into its history
      When the user copies the terminal
      Then the clipboard holds the older lines on screen, not the live tail

    @tui
    Scenario: Copying an empty terminal says there is nothing to copy
      Given the terminal shows no output
      When the user copies the terminal
      Then the user is told "Terminal is empty."

    @tui
    Scenario: Copying in a host terminal without clipboard support says so
      Given the user's terminal does not support clipboard writes
      When the user copies the terminal
      Then the user is told "Clipboard not supported by this terminal."

    @tui
    Scenario: The user scrolls back through a terminal's history
      Given the terminal has more output than fits on screen
      When the user scrolls the terminal up a page
      Then older output is shown with a note of how far back it is
      And the cursor is hidden while viewing history

    @tui
    Scenario: Typing returns a scrolled terminal to the live output
      Given the user has scrolled the terminal back into its history
      When the user types a key
      Then the terminal shows the live output again
      And the key reaches the shell

    @tui
    Scenario: New output does not yank a scrolled-back view
      Given the user has scrolled the terminal back into its history
      When the shell prints more output
      Then the lines the user was reading stay on screen

    @tui
    Scenario Outline: The user clears or restarts the terminal from the command palette
      When the user runs "<command>" from the command palette
      Then the user is told "<progress>"
      And then "<done>"

      Examples:
        | command          | progress               | done                |
        | Clear terminal   | Clearing terminal…     | Terminal cleared.   |
        | Restart terminal | Restarting terminal…   | Terminal restarted. |

    @tui
    Scenario: Growing the terminal client window resizes the shell
      When the user makes their terminal window wider
      Then the visible terminal's shell is told its new size
      And background terminals are resized only when they are shown

    @tui
    Scenario: A shell that ends says so in the terminal
      When the user types "exit" and presses Enter
      Then the terminal shows "[process exited]"

  Rule: The web terminal offers editing actions

    @desktop
    Scenario Outline: The user copies, pastes and clears from the terminal's menu
      Given the terminal has a selection
      When the user chooses "<action>" from the terminal's menu
      Then <outcome>

      Examples:
        | action | outcome                                   |
        | Copy   | the selected text is on the clipboard      |
        | Paste  | the clipboard text is sent to the shell    |

    @desktop
    Scenario Outline: The usual copy and paste keys work in the terminal
      Given the terminal has a selection
      When the user presses "<keys>" in the terminal
      Then <outcome>

      Examples:
        | keys   | outcome                                 |
        | Ctrl+C | the selected text is on the clipboard   |
        | Ctrl+V | the clipboard text is sent to the shell |

    @desktop
    Scenario: Ctrl+C with nothing selected still interrupts the program
      Given nothing is selected in the terminal
      When the user presses "Ctrl+C" in the terminal
      Then the shell receives Ctrl-C

    @desktop
    Scenario: Clearing the web terminal asks the shell to redraw
      When the user clears the terminal from the keyboard
      Then the shell receives Ctrl-L and redraws its prompt at the top

    @backlog @desktop
    Scenario: Cmd+K clears the terminal on macOS
      Given the user is on macOS
      When the user presses "Cmd+K" in the terminal
      Then the shell receives Ctrl-L and redraws its prompt at the top

    @backlog @desktop
    Scenario: Cmd+Backspace deletes to the start of the line on macOS
      Given the user is on macOS
      And the shell prompt holds "git status --short"
      When the user presses "Cmd+Backspace" in the terminal
      Then the shell receives the command that deletes to the start of the line

    @backlog @desktop
    Scenario Outline: Arrow keys with a modifier move by word or line
      Given the user is on <platform>
      When the user presses "<keys>" in the terminal
      Then the cursor moves <movement>

      Examples:
        | platform | keys        | movement                 |
        | macOS    | Option+Left | one word left            |
        | macOS    | Option+Right | one word right          |
        | macOS    | Cmd+Left    | to the start of the line |
        | macOS    | Cmd+Right   | to the end of the line   |
        | Linux    | Ctrl+Left   | one word left            |
        | Linux    | Alt+Right   | one word right           |
        | Windows  | Ctrl+Right  | one word right           |

    @backlog @desktop
    Scenario: Selecting with Shift and an arrow is left to the terminal
      Given the user is on macOS
      When the user presses "Shift+Option+Left" in the terminal
      Then the shell receives the key as the terminal encodes it
      And no word or line movement is sent

    @backlog @desktop
    Scenario Outline: Clicking again selects a word and then a line
      Given the terminal shows "git commit -m fix"
      When the user clicks <times> in quick succession on "commit"
      Then <selected> is selected

      Examples:
        | times  | selected           |
        | twice  | "commit"           |
        | 3 times | "git commit -m fix" |

    @backlog @desktop
    Scenario: Dragging a selection past the edge scrolls the history while it grows
      Given the terminal has scrolled-back output
      When the user drags a selection past the top of the terminal and holds it there
      Then the history keeps scrolling up
      And the selection grows with it

    @backlog @desktop
    Scenario Outline: The Linux and Windows copy and paste keys work in the terminal
      Given the user is on <platform>
      And the terminal has a selection
      When the user presses "<keys>" in the terminal
      Then <outcome>

      Examples:
        | platform | keys         | outcome                                 |
        | Linux    | Ctrl+Shift+C | the selected text is on the clipboard   |
        | Linux    | Ctrl+Insert  | the selected text is on the clipboard   |
        | Linux    | Ctrl+Shift+V | the clipboard text is sent to the shell |
        | Linux    | Shift+Insert | the clipboard text is sent to the shell |
        | Windows  | Ctrl+Insert  | the selected text is on the clipboard   |
        | Windows  | Shift+Insert | the clipboard text is sent to the shell |

    @backlog @desktop
    Scenario Outline: Ctrl+C copies once on Linux and Windows and then interrupts
      Given the user is on <platform>
      And the terminal has a selection
      When the user presses "Ctrl+C" in the terminal
      Then the selected text is on the clipboard
      And the selection is cleared
      When the user presses "Ctrl+C" in the terminal
      Then the shell receives Ctrl-C

      Examples:
        | platform |
        | Linux    |
        | Windows  |

    @backlog @desktop
    Scenario: On macOS Cmd+C copies and Ctrl+C always interrupts
      Given the user is on macOS
      And the terminal has a selection
      When the user presses "Cmd+C" in the terminal
      Then the selected text is on the clipboard
      And the selection stays
      When the user presses "Ctrl+C" in the terminal
      Then the shell receives Ctrl-C

    @backlog @desktop
    Scenario: Middle-clicking on Linux pastes the selected text
      Given the user is on Linux
      And the terminal has a selection
      When the user middle-clicks the terminal
      Then the selected text is sent to the shell as a paste

    @backlog @desktop
    Scenario Outline: Middle-clicking where the button means something else does not paste
      Given the user is on <platform>
      And the terminal has a selection
      When the user middle-clicks the terminal
      Then nothing is sent to the shell

      Examples:
        | platform |
        | macOS    |
        | Windows  |

    @backlog @desktop
    Scenario: A program that asks for the mouse receives the user's clicks
      Given a program in the terminal has asked to receive mouse events
      When the user clicks and drags in the terminal
      Then the program receives the presses, motion and releases
      And no text is selected

    @backlog @desktop
    Scenario Outline: Holding a modifier selects text even while a program has the mouse
      Given a program in the terminal has asked to receive mouse events
      When the user drags in the terminal holding <modifier>
      Then the text is selected
      And the program receives nothing

      Examples:
        | modifier |
        | Shift    |
        | Ctrl     |
        | Cmd      |

    @backlog @desktop
    Scenario: Scrolling the wheel in a full-screen program moves it with arrow keys
      Given a full-screen program such as an editor or pager is showing
      When the user scrolls the wheel down three rows
      Then the shell receives three down-arrow keys
      And the terminal's own history does not scroll

    @backlog @desktop
    Scenario: Small wheel movements add up to whole rows
      Given the terminal has history above what is on screen
      When the user scrolls with a trackpad in many movements each smaller than a row
      Then the terminal scrolls one row each time the movements add up to a row
      And no movement is lost

    @backlog @desktop
    Scenario Outline: The wheel scrolls by the unit the device reports
      Given the terminal has history above what is on screen
      When the wheel reports <movement>
      Then the terminal scrolls <result>

      Examples:
        | movement        | result              |
        | three lines     | three rows          |
        | one page        | one screenful       |
        | pixels          | by that many pixels, rounded down to rows |

    @backlog @desktop
    Scenario: The terminal shows a scrollbar for its history
      Given the terminal has more output than fits on screen
      Then a scrollbar shows where the view sits in the history
      And the scrollbar is hidden while everything fits

    @backlog @desktop
    Scenario Outline: The user moves through the history with the scrollbar
      Given the terminal has more output than fits on screen
      When the user <gesture>
      Then the view <result>

      Examples:
        | gesture                                 | result                                  |
        | drags the scrollbar's thumb             | follows the thumb row for row           |
        | clicks the scrollbar's track            | jumps to that place in the history      |
        | presses Page Up on the scrollbar        | moves up a screenful                    |
        | presses Page Down on the scrollbar      | moves down a screenful                  |
        | presses Home on the scrollbar           | moves to the oldest output              |
        | presses End on the scrollbar            | moves to the newest output              |
        | presses an arrow key on the scrollbar   | moves one row                           |

    @backlog @desktop
    Scenario: The scrollbar's thumb stays large enough to grab
      Given the terminal has a very long history
      Then the scrollbar's thumb is never smaller than a small grab target

    @backlog @desktop
    Scenario: With history above it, the prompt sits flush with the bottom edge
      Given the terminal has history and its height is not a whole number of rows
      Then the leftover space is above the first row and not below the prompt
      And the prompt does not shift while the user drags a selection across rows

    @backlog @desktop
    Scenario: Scrolling the wheel reaches a program that asked for the mouse
      Given a program in the terminal has asked to receive mouse events
      When the user scrolls the wheel
      Then the program receives wheel events

    @backlog @desktop
    Scenario: Characters composed with an input method reach the shell once
      When the user composes "日本語" with an input method in the terminal
      Then the shell receives "日本語" once the composition is committed
      And the keys pressed during the composition are not sent separately

    @backlog @desktop
    Scenario: A character typed with AltGr is typed as text
      Given the user's keyboard layout types "@" with AltGr
      When the user types "@" with AltGr in the terminal
      Then the shell receives "@"

    @backlog @desktop
    Scenario: The terminal draws prompt symbols without an installed symbol font
      Given the machine has no Nerd Font installed
      When the shell prints a prompt with powerline separators and file-type icons
      Then the terminal draws those symbols
      And the text keeps its own font and cell size

    @backlog @desktop
    Scenario: The cursor blinks only while the terminal has focus
      Given the shell asked for a blinking cursor
      When the terminal has focus
      Then the cursor blinks
      When the terminal loses focus
      Then the cursor is drawn as an outline and does not blink

    @backlog @desktop
    Scenario: The cursor stays steady when the user prefers reduced motion
      Given the shell asked for a blinking cursor
      And the user prefers reduced motion
      When the terminal has focus
      Then the cursor does not blink

    @desktop
    Scenario: Closing a terminal whose server session is gone still ends the shell
      Given a terminal whose close request fails
      When the user closes it
      Then the client sends "exit" to the shell instead

    @desktop
    Scenario: A terminal that exits on its own closes without asking
      Given the terminal's shell exits after the user types "exit"
      Then the terminal closes without a confirmation

    @backlog @mobile
    Scenario: The user types into a terminal from the phone
      Given the phone shows a thread's terminal
      When the user types "git status" and sends it
      Then the shell runs "git status" and the phone shows its output
