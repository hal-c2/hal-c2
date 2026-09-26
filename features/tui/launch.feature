# Sources:
#   apps/server/src/cli/tui.ts (t3 tui launcher, bearer session, Bun spawn, mintSocketUrl IPC)
#   apps/tui/src/index.tsx (renderer config, signals, crash handling, colour capability log)
#   apps/tui/src/terminalStartup.ts (tmux viewport preparation)
#   apps/tui/src/connection.ts (initial "Connecting…" status)
#   apps/tui/src/features.backlog.test.ts (environment-connections, environment-access-management)
#   apps/server-ex/test/t3/features_backlog_test.exs (TUI launch against the Elixir node)
#   Shared domain: connections/ owns pairing and remote access; this file holds the terminal twist.

Feature: Launching and leaving the terminal client
  The terminal client is started from the command line next to a running T3 Code server.
  It takes over the terminal while open and gives it back intact when it leaves.

  @tui
  Scenario: The terminal client opens against the running local server
    Given a T3 Code server is running on this machine
    When the user runs "t3 tui"
    Then the terminal client opens in the alternate screen
    And the status line says "Connecting…" until the first snapshot arrives

  @tui
  Scenario: Launching without a running server explains how to start one
    Given no T3 Code server is running on this machine
    When the user runs "t3 tui"
    Then the command fails with "No running T3 Code server was found. Start one with `t3 serve` (or `t3 start`) first."

  @tui
  Scenario: Launching against a server that has since stopped says so
    Given the recorded T3 Code server is no longer running
    When the user runs "t3 tui"
    Then the command fails and says the recorded server is no longer running

  @tui
  Scenario: Launching without Bun points the user at bun.sh
    Given Bun is not installed
    When the user runs "t3 tui"
    Then the command fails with a hint to install Bun from bun.sh

  @tui
  Scenario: The user chooses which Bun runs the terminal client
    Given the environment variable "T3_TUI_BUN" names a Bun binary
    When the user runs "t3 tui"
    Then the terminal client runs on that Bun binary

  @tui
  Scenario: The terminal client gets its own revocable session
    When the user runs "t3 tui"
    Then the server lists a client session labelled "T3 Code TUI"
    And the session expires after 30 days if never closed

  @tui
  Scenario: The terminal client refuses to start without an origin and credential
    Given the terminal client is started directly without an origin or bearer credential
    Then it exits with an error naming the missing value

  @tui
  Scenario Outline: Known truecolor terminals get full colour even when they do not advertise it
    Given the user's terminal is <terminal>
    And the terminal does not set COLORTERM
    When the user runs "t3 tui"
    Then the terminal client renders in truecolor

    Examples:
      | terminal  |
      | ghostty   |
      | kitty     |
      | wezterm   |
      | alacritty |
      | foot      |
      | rio       |
      | contour   |
      | iTerm     |
      | VS Code   |

  @tui
  Scenario: A colour setting the shell already made is left alone
    Given the shell already set COLORTERM
    When the user runs "t3 tui"
    Then the terminal client keeps the shell's COLORTERM

  @tui
  Scenario: An unrecognised terminal is not promised truecolor
    Given the user's terminal is not one the client recognises
    And the terminal does not set COLORTERM
    When the user runs "t3 tui"
    Then the client does not claim truecolor support

  @tui
  Scenario: Starting outside tmux never calls tmux
    Given the user is not inside tmux
    When the user runs "t3 tui"
    Then the client does not run any tmux command

  @tui
  Scenario: Starting inside a tmux pane in copy mode leaves copy mode first
    Given the user is inside a tmux pane that is in copy mode
    When the user runs "t3 tui"
    Then the pane leaves copy mode before the terminal client draws

  @tui
  Scenario: Terminal identity survives an SSH session
    Given the user runs the terminal client over SSH
    Then the client keeps the remote terminal's TERM, COLORTERM and TERM_PROGRAM

  @tui
  Scenario: Pressing Ctrl+C leaves the terminal client
    Given the prompt has focus
    When the user presses "Ctrl+C"
    Then the terminal client closes and the terminal returns to its previous screen

  # Needs a focused terminal tab (T5's terminal drawer) and a global keymap that
  # hands Ctrl+C to it; today the shell's global keymap always quits on Ctrl+C.
  @backlog @tui
  Scenario: Ctrl+C inside a focused terminal goes to the shell instead of quitting
    Given a terminal tab has focus
    When the user presses "Ctrl+C"
    Then the running shell program receives the interrupt
    And the terminal client stays open

  @tui
  Scenario Outline: Termination signals close the client cleanly
    When the terminal client receives <signal>
    Then the terminal client closes and restores the terminal
    And it exits with status 0

    Examples:
      | signal  |
      | SIGINT  |
      | SIGTERM |

  @tui
  Scenario: Leaving revokes the client's session on the server
    Given the terminal client is open
    When the user leaves the terminal client
    Then the server no longer lists the "T3 Code TUI" session

  @tui
  Scenario: A crash still gives the terminal back
    Given the terminal client hits an unrecoverable error
    Then the terminal leaves the alternate screen with the cursor and input restored
    And the client exits with status 1

  @backlog @tui
  Scenario: The user detaches and resumes the same terminal client later
    Given the terminal client is open on a thread
    When the user detaches from the terminal client
    Then the running turns keep going on the server
    And re-attaching later opens the same thread with the same focus

  @backlog @tui
  Scenario: The terminal client launches against an Elixir node
    Given an Elixir node is running on this machine
    When the user runs "t3 tui"
    Then the terminal client connects to that node

  @backlog @tui
  Scenario: The user pairs the terminal client with a remote environment
    Given a pairing link from a remote T3 Code environment
    When the user starts the terminal client with that pairing link
    Then the client connects to the remote environment
    And later launches reuse the paired credential

  @backlog @tui
  Scenario: Pairing with an invalid or expired credential explains the failure
    Given a pairing credential that has expired
    When the user starts the terminal client with it
    Then the client says the credential expired and does not connect

  @backlog @tui
  Scenario: The user lists environments and activates a reachable one
    Given local, remote and cloud environments are saved
    When the user opens the environment list from the terminal client
    Then every environment is listed with whether it is reachable
    And activating a reachable environment switches the client to it

  @backlog @tui
  Scenario: The user checks the relay client and installs it
    Given the relay client is not installed
    When the user checks relay status from the terminal client
    Then the client says the relay is missing and offers to install it

  @backlog @tui
  Scenario: The user reviews and revokes other clients' access
    Given other clients are paired with this environment
    When the user opens access management from the terminal client
    Then the list of clients updates live as access changes
    And the user can revoke one client or every other client
