# Sources:
#   apps/mobile/src/features/terminal/ (sessions, status, text size, accessory keys, context)
#   apps/mobile/modules/hal-c2-terminal
#   apps/mobile/src/features/threads/ThreadGitControls.tsx (terminal menu: scripts, sessions, new terminal)
#   apps/mobile/src/features/threads/ThreadRouteScreen.tsx (terminal needs a workspace folder)
# Terminal sessions are specified in features/terminal/. This file covers using a terminal
# with a touch keyboard on a small screen.

Feature: Using a terminal on a phone
  The phone can open the thread's terminals, type with an accessory row for the keys a
  touch keyboard lacks, and send what is on screen to the agent.

  Background:
    Given the phone is paired with "My MacBook"
    And the user is in the thread "Fix checkout"

  @backlog @mobile
  Scenario: Opening the terminal attaches to the thread's session
    When the user opens the terminal
    Then the user sees that the terminal is opening
    And the thread's terminal session is shown

  @backlog @mobile
  Scenario: Opening the terminal shows a shell that is already running
    Given the thread's shell "term-2" is running and "term-1" is not
    When the user opens the terminal without choosing one
    Then "term-2" is shown

  @backlog @mobile
  Scenario: Opening the terminal prefers the first shell when several are running
    Given the thread has "term-1" and "term-2" running
    When the user opens the terminal without choosing one
    Then "term-1" is shown

  @backlog @mobile
  Scenario: A terminal opens in the folder the thread works in
    Given the thread works in its own worktree
    When the user opens a terminal that has not been started
    Then its shell starts in the thread's worktree

  @backlog @mobile
  Scenario: A terminal remembers the size it had
    Given the user has opened "term-1" on the phone before
    When the user opens "term-1" again
    Then it opens at the size it last had
    And it does not briefly show another size

  @backlog @mobile
  Scenario: A terminal of an environment that is not connected waits for it
    Given the environment "My MacBook" is not connected
    When the user opens the terminal
    Then the user is told the terminal will load when the environment is ready
    And the user is offered to reconnect it

  @backlog @mobile
  Scenario Outline: The terminal shows the state of its session
    Given the terminal session is <state>
    Then the terminal is labelled "<label>"

    Examples:
      | state                    | label        |
      | running a task           | Task running |
      | waiting for input        | Ready        |
      | starting                 | Starting     |
      | finished                 | Exited       |
      | failed to start          | Error        |
      | not started yet          | Not started  |

  @backlog @mobile
  Scenario: The user opens another terminal
    Given the terminal "term-1" is open
    When the user opens a new terminal
    Then "term-2" is shown
    And both terminals are listed

  @backlog @mobile
  Scenario: The user switches between terminals
    Given "term-1" and "term-2" are open
    When the user switches to "term-1"
    Then "term-1" is shown

  @backlog @mobile
  Scenario: Exiting a terminal returns to the previous live session
    Given "term-1" and "term-2" are open and the user is in "term-2"
    When the shell in "term-2" exits
    Then "term-1" is shown

  @backlog @mobile
  Scenario: Exiting the last terminal returns to the thread
    Given only "term-1" is open
    When the shell in "term-1" exits
    Then the thread is shown

  @backlog @mobile
  Scenario: A shell that ends under the user's open terminal screen is left on return
    Given the user is in "term-1" and has opened another screen over it
    And the shell in "term-1" exits
    When the user returns to the terminal
    Then the terminal is left for the previous live session or the thread
    And the ended shell is not shown

  @backlog @mobile
  Scenario: A shell that came back before the user returned is kept
    Given the user is in "term-1" and has opened another screen over it
    And the shell in "term-1" exits
    And "term-1" starts again before the user returns
    When the user returns to the terminal
    Then "term-1" is still shown

  @backlog @mobile
  Scenario: Exiting a terminal falls back to the nearest live one below it
    Given "term-1", "term-3" and "term-4" are running and the user is in "term-3"
    When the shell in "term-3" exits
    Then "term-1" is shown

  @backlog @mobile
  Scenario: Exiting the first terminal falls back to the nearest live one above it
    Given "term-1" and "term-3" are running and the user is in "term-1"
    When the shell in "term-1" exits
    Then "term-3" is shown

  @backlog @mobile
  Scenario: A terminal that ended while away starts again on attach
    Given "term-1" ended while no terminal screen of the phone had it open
    When the user opens the terminal
    Then "term-1" starts a new shell

  @backlog @mobile
  Scenario Outline: The accessory row types keys a touch keyboard lacks
    Given the user is typing in the terminal
    When the user presses "<key>" on the accessory row
    Then the terminal receives <input>

    Examples:
      | key    | input                  |
      | esc    | Escape                 |
      | tab    | Tab                    |
      | ctrl   | a Control chord        |
      | alt    | an Alt chord           |
      | up     | the Up arrow           |
      | ~      | a tilde                |
      | \|     | a pipe                 |
      | paste  | the clipboard contents |

  @backlog @mobile
  Scenario: Touching the terminal brings up the keyboard
    Given the terminal is shown and the keyboard is hidden
    When the user touches the terminal
    Then the keyboard is shown

  @backlog @mobile
  Scenario: Dragging a finger over the terminal scrolls its history
    Given the terminal has more output than fits on screen
    When the user drags a finger down the terminal
    Then older output is shown
    And the terminal scrolls one row for each row's height the finger moved

  @backlog @mobile
  Scenario: A quick flick keeps the terminal scrolling until a touch stops it
    Given the terminal has more output than fits on screen
    When the user flicks the terminal
    Then the terminal keeps scrolling for a moment
    When the user touches the terminal while it is scrolling
    Then it stops

  @backlog @mobile
  Scenario Outline: A keyboard attached to a tablet types control keys into the terminal
    Given a hardware keyboard is attached to a tablet
    When the user presses "<keys>" in the terminal
    Then the terminal receives <input>

    Examples:
      | keys       | input                         |
      | Escape     | Escape                        |
      | Up         | the Up arrow                  |
      | Left       | the Left arrow                |
      | Tab        | Tab                           |
      | Shift-Tab  | back-tab                      |
      | Ctrl-C     | Control-C                     |
      | Ctrl-Z     | Control-Z                     |
      | Backspace  | the delete key                |
      | Enter      | Return                        |

  @backlog @mobile
  Scenario: The shell is told the size that fits when the phone changes shape
    Given the terminal is shown
    When the phone is turned or the keyboard opens
    Then the shell is told how many columns and rows now fit
    And the shell is not told again while the size is unchanged

  @backlog @mobile
  Scenario: Prompt symbols are drawn without an installed symbol font
    When the shell prints a prompt with powerline separators and file-type icons
    Then the terminal draws those symbols
    And the text keeps its own font and cell size

  @backlog @mobile
  Scenario: The user clears the terminal screen
    Given the terminal shows earlier output
    When the user clears the terminal
    Then the terminal screen is empty

  @backlog @mobile
  Scenario Outline: The accessory row offers the modifier keys of the computer the shell runs on
    Given the thread's environment runs on <system>
    When the user opens the accessory row
    Then it offers the modifier keys <modifiers>

    Examples:
      | system  | modifiers    |
      | macOS   | cmd and ctrl |
      | Linux   | ctrl and alt |
      | Windows | ctrl and alt |

  @backlog @mobile
  Scenario: A modifier key applies to the next key only
    Given the user has pressed "ctrl" on the accessory row
    When the user types "c"
    Then the terminal receives a Control-C
    And "ctrl" is no longer waiting for a key

  @backlog @mobile
  Scenario: Pressing a modifier key again lets it go
    Given the user has pressed "ctrl" on the accessory row
    When the user presses "ctrl" again
    Then "ctrl" is no longer waiting for a key
    And typing "c" sends a plain "c"

  @backlog @mobile
  Scenario: A modifier key that is waiting is let go when the terminal is cleared
    Given the user has pressed "ctrl" on the accessory row
    When the user clears the terminal
    Then "ctrl" is no longer waiting for a key

  @backlog @mobile
  Scenario Outline: The paste chord pastes the phone's clipboard
    Given the thread's environment runs on <system>
    And the user has pressed "<modifier>" on the accessory row
    When the user types "v"
    Then the phone's clipboard is pasted into the terminal
    And "<modifier>" is no longer waiting for a key

    Examples:
      | system  | modifier |
      | macOS   | cmd      |
      | Linux   | ctrl     |
      | Windows | ctrl     |

  @backlog @mobile
  Scenario: Pasting turns line breaks into Enter
    Given the phone's clipboard holds two lines of text
    When the user presses "paste" on the accessory row
    Then the terminal receives the two lines separated by Enter
    And the paste is not wrapped in any markers

  @backlog @mobile
  Scenario: Pasting keeps tabs and removes the control characters that could run commands
    Given the phone's clipboard holds text with tabs and with a hidden control character
    When the user presses "paste" on the accessory row
    Then the terminal receives the tabs as they were
    And each hidden control character reaches the terminal as a space

  @backlog @mobile
  Scenario: A very long paste is sent in pieces
    Given the phone's clipboard holds more than 65,000 characters
    When the user presses "paste" on the accessory row
    Then the terminal receives all of it in several writes
    And no emoji or other character is cut in two

  @backlog @mobile
  Scenario: Two quick pastes arrive one after the other
    Given the phone's clipboard holds a long text
    When the user presses "paste" twice in a row
    Then the terminal receives the first paste in full before the second begins

  @backlog @mobile
  Scenario: A paste is dropped when the terminal restarts before it is read
    Given the user pressed "paste" and the clipboard is still being read
    When the terminal's shell restarts
    Then nothing is typed into the new shell

  @backlog @mobile
  Scenario: A clipboard that cannot be read types nothing
    Given the phone cannot read its clipboard
    When the user presses "paste" on the accessory row
    Then nothing is typed into the terminal
    And the terminal stays usable

  @backlog @mobile
  Scenario: Keys are not sent to a shell that is not running
    Given the terminal's shell has ended
    When the user presses a key on the accessory row
    Then nothing is sent to the terminal

  @backlog @mobile
  Scenario: The accessory row goes with the keyboard and the keyboard can be brought back
    Given the keyboard and the accessory row are showing
    When the user hides the keyboard
    Then the accessory row is hidden too
    And the terminal offers a way to show the keyboard again
    When the user shows the keyboard
    Then the keyboard and the accessory row are back

  @backlog @mobile
  Scenario Outline: The user changes the terminal text size within limits
    Given the terminal text size is <start> points
    When the user <change> the text size
    Then the terminal text size is <end> points

    Examples:
      | start | change    | end  |
      | 10.5  | increases | 11   |
      | 10.5  | decreases | 10   |
      | 14    | increases | 14   |
      | 6     | decreases | 6    |

  @backlog @mobile
  Scenario: The user runs a project script from the terminal
    Given "shop" has the script "test"
    When the user runs "test" from the terminal
    Then "test" runs in a terminal session

  @backlog @mobile
  Scenario: The terminal menu of a thread lists its scripts and its terminals
    Given "shop" has the scripts "test" and "lint"
    And the thread has a terminal that is running and one that has ended
    When the user opens the terminal menu of the thread
    Then "test" and "lint" are listed with the commands they run
    And each terminal is listed with its state and the folder it is in
    And the user is offered to open a new terminal

  @backlog @mobile
  Scenario: A project without scripts says so in the terminal menu
    Given "shop" has no saved scripts
    When the user opens the terminal menu of the thread
    Then the menu says the project has no saved scripts yet
    And no script can be chosen
    And the user is still offered to open a new terminal

  @backlog @mobile
  Scenario: Terminals that have ended are not listed in the terminal menu
    Given the thread has "term-1" running and "term-2" ended
    And the user is in "term-1"
    When the user opens the terminal menu
    Then only "term-1" is listed

  @backlog @mobile
  Scenario: The terminal being viewed is always listed
    Given the user is in "term-2" and its shell has ended
    When the user opens the terminal menu
    Then "term-2" is listed with its state

  @backlog @mobile
  Scenario: Terminals are listed in number order
    Given the thread has "term-2", "term-10" and "term-3" running
    When the user opens the terminal menu
    Then they are listed as "term-2", "term-3" and "term-10"

  @backlog @mobile
  Scenario: The terminal menu says which folder a new terminal starts in
    Given the thread works in the folder "shop"
    When the user opens the terminal menu
    Then the offer to open a new terminal says it starts in "shop"

  @backlog @mobile
  Scenario: A script that runs when a worktree is created is marked as setup
    Given "shop" has the script "bootstrap" that runs when a worktree is created
    When the user opens the terminal menu of the thread
    Then the script is listed as "bootstrap (setup)"

  @backlog @mobile
  Scenario: A script runs in the first terminal when no shell is running
    Given the thread has no shell running
    When the user runs "test" from the terminal menu
    Then "test" runs in "term-1"

  @backlog @mobile
  Scenario: A script runs in a new terminal when a shell is already running
    Given the thread has "term-1" running
    When the user runs "test" from the terminal menu
    Then "test" runs in "term-2"
    And "term-1" is left as it was

  @backlog @mobile
  Scenario: A script's command is typed once
    Given "test" is starting in a new terminal
    When the terminal attaches and its output arrives
    Then the command is typed into the shell once
    And it is not typed again when the terminal is shown again

  @backlog @mobile
  Scenario: The terminal is not offered for a thread with no workspace
    Given the thread has no workspace folder
    Then the thread offers no terminal

  @backlog @mobile
  Scenario: The user sends visible terminal output to the agent
    Given the terminal shows a failing test
    When the user adds the visible lines as context
    Then the draft carries those lines

  @backlog @mobile
  Scenario: Too much terminal context is refused
    Given the draft already carries the most context items it can
    When the user adds the visible lines as context
    Then the user is told there are too many context items

  @backlog @mobile
  Scenario: A terminal with nothing on screen has nothing to add
    Given the terminal shows nothing
    When the user adds the visible lines as context
    Then the user is told there is no visible output to attach
    And no list of lines is shown

  @backlog @mobile
  Scenario: The user picks which of the visible lines to add
    Given the terminal shows six lines
    When the user adds the visible lines as context
    And the user taps the second line and then the fourth
    And the user attaches the selected output
    Then the draft carries lines 2 to 4
    And the excerpt names the terminal and those lines

  @backlog @mobile
  Scenario: All visible lines are selected until the user narrows them
    Given the terminal shows six lines
    When the user adds the visible lines as context
    Then all six lines are selected

  @backlog @mobile
  Scenario: Too many selected lines cannot be attached
    Given the terminal shows more lines than a context item can carry
    When the user adds the visible lines as context
    Then the user is told to select fewer lines
    And the selection cannot be attached

  @backlog @mobile
  Scenario: Cancelling the list of lines adds nothing
    Given the user is choosing which visible lines to add
    When the user cancels
    Then the draft carries no terminal lines
    And the terminal is still shown

  @backlog @mobile
  Scenario: The user selects terminal text with a long press and copies it
    Given the terminal shows output with "3 tests failed"
    When the user long presses a word in the output
    And the user copies the selection
    Then the selected text is on the clipboard

  @backlog @mobile
  Scenario: Dragging a selection handle extends the selection by whole words
    Given the user has selected a word in the terminal
    When the user drags a selection handle across the output
    Then the selection covers whole words from its start to the handle

  @backlog @mobile
  Scenario: Select All in the selection menu selects the whole terminal screen
    Given the user has selected a word in the terminal
    When the user chooses "Select All"
    Then the whole terminal screen is selected

  @backlog @mobile
  Scenario: Closing the selection menu clears the selection
    Given the user has selected text in the terminal
    When the user closes the selection menu
    Then nothing is selected in the terminal

  @backlog @mobile
  Scenario: New terminal output clears the selection
    Given the user has selected text in the terminal
    When the terminal receives new output
    Then nothing is selected in the terminal

  @backlog @mobile
  Scenario: The terminal of a thread that is gone says so
    Given "Fix checkout" was deleted on another device
    When the user opens its terminal
    Then the user is told the thread is unavailable

  @backlog @mobile
  Scenario: A phone that cannot draw the terminal still shows its output as text
    Given the phone cannot draw the terminal itself
    When the user opens the terminal
    Then the user is told the terminal is shown as plain text
    And the shell's output is shown and can be selected
    And the user can still type into it
