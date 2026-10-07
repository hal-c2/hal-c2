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
#   apps/tui/src/features.backlog.test.ts (terminal-session-actions)
#   apps/web/src/components/ThreadTerminalDrawer.tsx (copy, paste, clear shortcut, exit handling)
#   apps/web/src/terminal/ghostty/surface.ts (copy and paste keys)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalMenu.qml (menu, copy and paste keys)
#   apps/web/src/components/useThreadTerminalActions.ts
#   apps/web/src/lib/terminalCloseShortcut.ts
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
