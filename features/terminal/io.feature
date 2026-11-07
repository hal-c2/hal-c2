# Sources:
#   https://github.com/pingdotgg/t3code/pull/11305
#   https://github.com/pingdotgg/t3code/pull/19395
#   https://github.com/pingdotgg/t3code/pull/17091
#   https://github.com/pingdotgg/t3code/pull/18519
#   https://github.com/pingdotgg/t3code/pull/20289
#   https://github.com/pingdotgg/t3code/pull/17178
#   docs/user/terminal.md
#   docs/internals/terminal-runtime.md (pending writes drain before clear, restart and close)
#   packages/contracts/src/terminal.ts (TerminalWriteInput, TerminalResizeInput, TerminalClearInput, TerminalRestartInput, TerminalCloseInput, TerminalEvent)
#   apps/server-ex/lib/hal_c2/terminal.ex (write, resize, clear, restart, close, exit status, output batching)
#   apps/server-ex/lib/hal_c2/terminal/hub.ex (activity and running-command labels)
#   apps/server-ex/lib/hal_c2/terminal/output_window.ex (the unacknowledged output window)
#   apps/tui/src/host/terminalState.ts (acknowledging what the emulator has parsed)
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

    @mc @tui
    Scenario: A client that falls behind stops receiving the shell's output instead of buffering it
      Given a running terminal whose shell prints continuously
      When a client stops acknowledging the output it has received
      Then only a small amount of output waits unacknowledged for that client
      And the MC stops sending output to that client until it catches up
      And the shell itself keeps running

    # Upstream #17178: a client that only watched waited for an acknowledgement after
    # every chunk, so it slowed with network latency.
    @backlog @mc @priority-low
    Scenario: A client that only watches a terminal gets output as freely as one that types
      Given a client watches a running terminal without typing into it
      When the shell prints continuously
      Then up to eight chunks or 64 KiB of output reach that client before it must acknowledge any
      And it is held back like a client that types once it falls further behind

    @desktop
    Scenario: The desktop says what it has read in batches, not per chunk
      Given the terminal shows a running shell
      And saying what was read waits as long as it can
      When the shell prints a little, five times
      Then the MC has heard nothing about that output yet
      When the shell prints 20 KiB more
      Then the MC hears once that all of it has been read

    @desktop
    Scenario: Output that stops is still said to be read, so the desktop never stalls itself
      Given the terminal shows a running shell
      When the shell prints a little
      Then the MC hears that all of it has been read

    @desktop
    Scenario: A hidden terminal keeps reading
      Given the terminal shows a running shell
      When the user hides the terminal drawer
      And the shell prints a little
      Then the MC hears that all of it has been read

    @desktop
    Scenario: A new connection starts over from its snapshot
      Given the terminal shows a running shell
      And saying what was read waits as long as it can
      When the shell prints a little
      And the connection to the MC drops and comes back
      Then the terminal asks again to say what it has read
      And the MC hears once, of the new snapshot

    @desktop
    Scenario: A terminal of a thread the user left stops reading until they return
      Given the terminal shows a running shell
      When the user goes to another thread
      And the shell prints more than the MC sends a client that has not read it
      Then the MC holds the rest back
      And the terminal stays attached
      When the user returns to the terminal's thread
      Then the terminal has everything the shell printed
      And the MC holds nothing back

    @tui
    Scenario: A terminal the client has hidden costs nothing and catches up when shown
      Given a running terminal whose shell prints continuously
      When the terminal drawer is closed
      Then the shell goes on printing with nothing reaching the client
      When the terminal drawer opens again
      Then the client catches up from a snapshot and follows the shell again

    @tui
    Scenario: A terminal in a background tab keeps taking its shell's output
      Given a running terminal whose shell prints continuously
      When another terminal opens in front of it
      Then the terminal behind it goes on taking the shell's output

    @tui
    Scenario: Restarting a terminal lets a client that fell behind see the new shell
      Given a running terminal whose shell prints continuously
      And a client stops acknowledging the output it has received
      And only a small amount of output waits unacknowledged for that client
      When the terminal is restarted
      Then the held back client shows the new shell

    @tui
    Scenario: A client that fell behind and reconnects starts over from a snapshot
      Given a running terminal whose shell prints continuously
      And a client stops acknowledging the output it has received
      And only a small amount of output waits unacknowledged for that client
      When the client's connection drops and it stops being held back
      Then the client catches up from a snapshot and follows the shell again

    @mc
    Scenario: Resizing a terminal tells the running program its new size
      Given a running terminal at 120 columns and 30 rows
      When a client resizes it to 80 columns and 24 rows
      Then the running program sees 80 columns and 24 rows

    @backlog @desktop @priority-low
    Scenario: Releasing a resize drag tells the shell its new size at once
      Given the user is dragging the divider beside a running terminal
      When the user releases the drag at a narrower width
      Then the shell is told the final size once, without waiting out the resize delay
      And typing straight after the release lays out at the new width

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
    Scenario: A shell that ignores the stop request is killed after a short grace period
      Given a running terminal whose shell ignores the stop request
      When a client closes it
      Then the shell is asked to stop first
      And the shell is killed if it is still running a second later

    @mc @backlog
    Scenario: A shell that stops when asked is not killed and the close does not wait
      Given a running terminal whose shell stops as soon as it is asked
      When a client closes it
      Then the shell is asked to stop
      And it is never killed
      And the close finishes without waiting out the grace period

    # Legacy: apps/server/src/terminal/Manager.test.ts (scoped runtime shutdown stops active terminals
    #   cleanly)
    @mc
    Scenario: Stopping the MC stops every running shell
      Given running terminals, one of whose shells ignores the stop request
      When the MC shuts down with them running
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

    @mc
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

    @backlog @desktop @priority-low
    Scenario: Select all in the terminal's menu selects the whole kept history
      Given the terminal has more output than fits on screen
      When the user chooses "Select all" from the terminal's menu and copies
      Then all the output the terminal keeps is on the clipboard, including what is scrolled off screen

    @backlog @desktop
    Scenario Outline: The user reads the history without leaving the terminal's input
      Given the terminal has more output than fits on screen and a shell prompt
      When the user presses "<keys>" in the terminal
      Then <outcome>
      And the keys do not reach the shell

      Examples:
        | keys                  | outcome                                       |
        | Shift+PageUp          | the terminal shows the page of history above  |
        | Shift+PageDown        | the terminal shows the page of history below  |
        | Mod+Shift+Home        | the terminal shows the oldest output it keeps |
        | Mod+Shift+End         | the terminal shows the latest output          |
        | Mod+A on macOS        | all the output the terminal keeps is selected |
        | Ctrl+Shift+A on Linux | all the output the terminal keeps is selected |

    @backlog @desktop
    Scenario: History keys belong to a full-screen program
      Given a full-screen program runs in the terminal
      When the user presses "Shift+PageUp" or "Ctrl+A"
      Then the program receives the keys

    @backlog @desktop
    Scenario: Jump to latest returns a scrolled-back terminal to its current output
      Given the user has scrolled the terminal back into its history
      When the user chooses "Jump to latest" from the terminal's menu
      Then the terminal shows the live output again

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
    Scenario: Cmd+K clears the terminal on macOS
      Given the user is on macOS
      When the user presses "Cmd+K" in the terminal
      Then the shell receives Ctrl-L and redraws its prompt at the top

    @desktop
    Scenario: Cmd+Backspace deletes to the start of the line on macOS
      Given the user is on macOS
      And the shell prompt holds "git status --short"
      When the user presses "Cmd+Backspace" in the terminal
      Then the shell receives the command that deletes to the start of the line

    @desktop
    Scenario Outline: Arrow keys with a modifier move by word or line
      Given the user is on <platform>
      When the user presses "<keys>" in the terminal
      Then the terminal's cursor moves <movement>

      Examples:
        | platform | keys        | movement                 |
        | macOS    | Option+Left | one word left            |
        | macOS    | Option+Right | one word right          |
        | macOS    | Cmd+Left    | to the start of the line |
        | macOS    | Cmd+Right   | to the end of the line   |
        | Linux    | Ctrl+Left   | one word left            |
        | Linux    | Alt+Right   | one word right           |
        | Windows  | Ctrl+Right  | one word right           |

    @desktop
    Scenario: Selecting with Shift and an arrow is left to the terminal
      Given the user is on macOS
      When the user presses "Shift+Option+Left" in the terminal
      Then the shell receives the key as the terminal encodes it
      And no word or line movement is sent

    @desktop
    Scenario Outline: Clicking again selects a word and then a line
      Given the shell has printed "git commit -m fix"
      When the user clicks <times> in quick succession on "commit"
      Then <selected> is selected in the terminal

      Examples:
        | times   | selected            |
        | twice   | "commit"            |
        | 3 times | "git commit -m fix" |

    @desktop
    Scenario: Dragging a selection past the edge scrolls the history while it grows
      Given the terminal has scrolled-back output
      When the user drags a selection past the top of the terminal and holds it there
      Then the history keeps scrolling up
      And the selection grows with it

    # Upstream #11305: on a touch screen a drag selected text instead of scrolling.
    @backlog @desktop @mobile
    Scenario Outline: A finger dragged up or down a terminal scrolls it instead of selecting
      Given the terminal on a touch screen is showing <content>
      When the user drags a finger down the terminal and back up
      Then <outcome>
      And no text is selected

      Examples:
        | content                  | outcome                                          |
        | scrolled-back output     | the history scrolls back and forth with the finger |
        | a full-screen program    | the program receives the scrolling                |

    @backlog @desktop @mobile @priority-low
    Scenario: Touching a split terminal that is not active makes it active
      Given the terminal is split in two and the left one is active
      When the user touches the right one
      Then the right terminal is active and has focus

    @desktop
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

    @desktop
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

    @desktop
    Scenario: On macOS Cmd+C copies and Ctrl+C always interrupts
      Given the user is on macOS
      And the terminal has a selection
      When the user presses "Cmd+C" in the terminal
      Then the selected text is on the clipboard
      And the selection stays
      When the user presses "Ctrl+C" in the terminal
      Then the shell receives Ctrl-C

    # The terminal does this, but the offscreen platform the scenarios run on has
    # no selection clipboard to paste from. Needs an X11 or Wayland run.
    @backlog @desktop @priority-low
    Scenario: Middle-clicking on Linux pastes the selected text
      Given the user is on Linux
      And the terminal has a selection
      When the user middle-clicks the terminal
      Then the selected text is sent to the shell as a paste

    @desktop
    Scenario Outline: Middle-clicking where the button means something else does not paste
      Given the user is on <platform>
      And the terminal has a selection
      When the user middle-clicks the terminal
      Then nothing is sent to the shell

      Examples:
        | platform |
        | macOS    |
        | Windows  |

    @desktop
    Scenario: A program that asks for the mouse receives the user's clicks
      Given a program in the terminal has asked to receive mouse events
      When the user clicks and drags in the terminal
      Then the program receives the presses, motion and releases
      And no text is selected

    @desktop
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

    @desktop
    Scenario: Scrolling the wheel in a full-screen program moves it with arrow keys
      Given a full-screen program such as an editor or pager is showing
      When the user scrolls the wheel down three rows
      Then the shell receives three down-arrow keys
      And the terminal's own history does not scroll

    @desktop
    Scenario: Small wheel movements add up to whole rows
      Given the terminal has history above what is on screen
      When the user scrolls with a trackpad in many movements each smaller than a row
      Then the terminal scrolls one row each time the movements add up to a row
      And no movement is lost

    @desktop
    Scenario Outline: The wheel scrolls by the unit the device reports
      Given the terminal has history above what is on screen
      When the wheel reports <movement>
      Then the terminal scrolls <result>

      Examples:
        | movement    | result                                    |
        | three lines | three rows                                |
        | pixels      | by that many pixels, rounded down to rows |

      # Qt's wheel events report only pixels and angles, so a wheel that moves in
      # pages cannot be told from one that moves that far in lines.
      @dropped
      Examples:
        | movement | result        |
        | one page | one screenful |

    @desktop
    Scenario: The terminal shows a scrollbar for its history
      Given the terminal has more output than fits on screen
      Then a scrollbar shows where the view sits in the history
      And the drawer's buttons leave the scrollbar clear
      And the scrollbar is hidden while everything fits

    @desktop
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

    @desktop
    Scenario: The scrollbar's thumb stays large enough to grab
      Given the terminal has a very long history
      Then the scrollbar's thumb is never smaller than a small grab target

    @desktop
    Scenario: With history above it, the prompt sits flush with the bottom edge
      Given the terminal has history and its height is not a whole number of rows
      Then the leftover space is above the first row and not below the prompt
      And the prompt does not shift while the user drags a selection across rows

    @desktop
    Scenario: Scrolling the wheel reaches a program that asked for the mouse
      Given a program in the terminal has asked to receive mouse events
      When the user scrolls the wheel
      Then the program receives wheel events

    @desktop
    Scenario: Characters composed with an input method reach the shell once
      When the user composes "日本語" with an input method in the terminal
      Then the shell receives "日本語" once the composition is committed
      And the keys pressed during the composition are not sent separately

    @desktop
    Scenario: What an input method is composing shows at the cursor
      When the user is composing with an input method in the terminal
      Then what is being composed is drawn at the cursor
      When the user cancels the composition
      Then nothing is drawn in its place

    @desktop
    Scenario: A character typed with AltGr is typed as text
      Given the user's keyboard layout types "@" with AltGr
      When the user types "@" with AltGr in the terminal
      Then the shell receives "@"

    @desktop
    Scenario: The terminal draws prompt symbols without an installed symbol font
      Given the machine has no Nerd Font installed
      When the shell prints a prompt with powerline separators and file-type icons
      Then the terminal draws those symbols
      And the text keeps its own font and cell size
      And text outside the terminal does not take the symbol font

    @desktop
    Scenario: The cursor blinks only while the terminal has focus
      Given the shell asked for a blinking cursor
      When the terminal has focus
      Then the cursor blinks
      When the terminal loses focus
      Then the cursor is drawn as an outline and does not blink

    @desktop
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

    @mobile
    Scenario: The user types into a terminal from the phone
      Given the phone shows a thread's terminal
      When the user types "git status" and sends it
      Then the shell runs "git status" and the phone shows its output
