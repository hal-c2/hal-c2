# Sources:
#   apps/mobile/src/features/terminal/ (sessions, status, text size, accessory keys, context)
#   apps/mobile/modules/hal-c2-terminal
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
  Scenario: A terminal that ended while away starts again on attach
    Given "term-1" ended while the phone was in the background
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
  Scenario: The user clears the terminal screen
    Given the terminal shows earlier output
    When the user clears the terminal
    Then the terminal screen is empty

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
  Scenario: The terminal of a thread that is gone says so
    Given "Fix checkout" was deleted on another device
    When the user opens its terminal
    Then the user is told the thread is unavailable
