# Sources:
#   apps/server/src/cli/tui.ts (hal-c2 tui launcher, bearer session, Bun spawn, mintSocketUrl IPC)
#   apps/tui/src/index.tsx (renderer config, signals, crash handling, colour capability log)
#   apps/tui/src/terminalStartup.ts (tmux viewport preparation)
#   apps/tui/src/connection.ts (initial "Connecting…" status)
#   apps/tui/src/features.backlog.test.ts (environment-connections, environment-access-management)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (TUI launch against the MC)
#   apps/tui/src/mcDiscovery.ts (runtime record, access token, pairing link, saved credentials)
#   apps/tui/src/socketTicket.ts (socket tickets over HTTP without a launcher)
#   apps/server-ex/lib/hal_c2/runtime_record.ex, lib/hal_c2/auth.ex (access token as bearer)
#   mise-tasks/tui/_default (mise run tui)
#   Shared domain: connections/ owns pairing and remote access; this file holds the terminal twist.

Feature: Launching and leaving the terminal client
  The terminal client is started from the command line next to a running HAL-C2 server.
  It takes over the terminal while open and gives it back intact when it leaves.

  On its own ("mise run tui", or the client's entry with --base-dir) it finds the MC on
  this machine through the MC's runtime record and signs in with the MC's access token;
  with --url it pairs with a remote MC instead. "hal-c2 tui" is the Node server's launcher,
  which hands the client an origin, a bearer and socket tickets.

  @tui
  Scenario: The terminal client opens against the running local server
    Given a HAL-C2 server is running on this machine
    When the user runs "hal-c2 tui"
    Then the terminal client opens in the alternate screen
    And the status line says "Connecting…" until the first snapshot arrives

  @tui
  Scenario: Launching without a running server explains how to start one
    Given no HAL-C2 server is running on this machine
    When the user runs "hal-c2 tui"
    Then the command fails with "No running HAL-C2 server was found. Start one with `hal-c2 serve` (or `hal-c2 start`) first."

  @tui
  Scenario: Launching against a server that has since stopped says so
    Given the recorded HAL-C2 server is no longer running
    When the user runs "hal-c2 tui"
    Then the command fails and says the recorded server is no longer running

  @tui
  Scenario: Launching without Bun points the user at bun.sh
    Given Bun is not installed
    When the user runs "hal-c2 tui"
    Then the command fails with a hint to install Bun from bun.sh

  @tui
  Scenario: The user chooses which Bun runs the terminal client
    Given the environment variable "HAL_C2_TUI_BUN" names a Bun binary
    When the user runs "hal-c2 tui"
    Then the terminal client runs on that Bun binary

  @tui
  Scenario: The terminal client gets its own revocable session
    When the user runs "hal-c2 tui"
    Then the server lists a client session labelled "HAL-C2 TUI"
    And the session expires after 30 days if never closed

  # Started directly, the client finds the MC itself (the scenarios on the MC
  # below); an origin and bearer only come from the Node server's launcher.
  @dropped @tui
  Scenario: The terminal client refuses to start without an origin and credential
    Given the terminal client is started directly without an origin or bearer credential
    Then it exits with an error naming the missing value

  @tui
  Scenario Outline: Known truecolor terminals get full colour even when they do not advertise it
    Given the user's terminal is <terminal>
    And the terminal does not set COLORTERM
    When the user runs "hal-c2 tui"
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
    When the user runs "hal-c2 tui"
    Then the terminal client keeps the shell's COLORTERM

  @tui
  Scenario: An unrecognised terminal is not promised truecolor
    Given the user's terminal is not one the client recognises
    And the terminal does not set COLORTERM
    When the user runs "hal-c2 tui"
    Then the client does not claim truecolor support

  @tui
  Scenario: Starting outside tmux never calls tmux
    Given the user is not inside tmux
    When the user runs "hal-c2 tui"
    Then the client does not run any tmux command

  @tui
  Scenario: Starting inside a tmux pane in copy mode leaves copy mode first
    Given the user is inside a tmux pane that is in copy mode
    When the user runs "hal-c2 tui"
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

  @tui
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
    Then the server no longer lists the "HAL-C2 TUI" session

  @tui
  Scenario: A crash still gives the terminal back
    Given the terminal client hits an unrecoverable error
    Then the terminal leaves the alternate screen with the cursor and input restored
    And the client exits with status 1

  # No detach: the client is one process on the terminal and leaves with it.
  @backlog @tui
  Scenario: The user detaches and resumes the same terminal client later
    Given the terminal client is open on a thread
    When the user detaches from the terminal client
    Then the running turns keep going on the server
    And re-attaching later opens the same thread with the same focus

  @tui
  Scenario: The terminal client launches against an MC
    Given an MC is running on this machine
    When the user starts the terminal client
    Then the terminal client connects to that MC
    And it signs in with the MC's access token

  @tui
  Scenario: Starting the terminal client with no MC running explains how to start one
    Given no MC is running on this machine
    When the user starts the terminal client
    Then it exits saying "No running HAL-C2 MC was found. Start one with `mise run mc` first."

  @tui
  Scenario: Starting the terminal client against an MC that has since stopped says so
    Given the recorded MC is no longer running
    When the user starts the terminal client
    Then it exits saying the recorded MC is no longer running

  @tui
  Scenario: Starting the terminal client against an MC that does not answer says so
    Given the recorded MC does not answer
    When the user starts the terminal client
    Then it exits saying the MC at the recorded address could not be reached

  @tui
  Scenario: Without a launcher the client buys its socket tickets over HTTP
    Given an MC is running on this machine
    When the user starts the terminal client
    Then the client buys a socket ticket from the MC over HTTP
    And the socket URL carries only that ticket

  @tui
  Scenario: Without a launcher a dropped connection reconnects with a fresh ticket
    Given the terminal client is connected to an MC
    When the MC drops the connection
    Then the client buys a new socket ticket over HTTP
    And it reconnects without the user doing anything

  # --url <pairing link>. The session is saved for the environment's origin rather than
  # revoked on exit: an MC does not let a session revoke itself, and a link works once.
  @tui
  Scenario: The user pairs the terminal client with a remote environment
    Given a pairing link from a remote HAL-C2 environment
    When the user starts the terminal client with that pairing link
    Then the client connects to the remote environment
    And later launches reuse the paired credential

  @tui
  Scenario: Pairing with an invalid or expired credential explains the failure
    Given a pairing credential that has expired
    When the user starts the terminal client with it
    Then the client says the credential expired and does not connect

  @tui
  Scenario: Leaving keeps a paired remote session until the environment revokes it
    Given the terminal client paired with a remote environment
    When the user leaves the terminal client
    Then the environment still lists the "HAL-C2 TUI" session

  @tui
  Scenario: A saved session the environment revoked asks for a new pairing link
    Given the terminal client paired with a remote environment
    And the environment revoked that session
    When the user starts the terminal client for that environment again
    Then the client says its access was revoked and asks for a new pairing link
    And it forgets the saved credential

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: The user lists environments and activates a reachable one
    Given local, remote and cloud environments are saved
    When the user opens the environment list from the terminal client
    Then every environment is listed with whether it is reachable
    And activating a reachable environment switches the client to it

  @tui
  Scenario: The user checks the relay client and installs it
    Given the relay client is not installed
    When the user checks relay status from the terminal client
    Then the client says the relay is missing and offers to install it

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: The user reviews and revokes other clients' access
    Given other clients are paired with this environment
    When the user opens access management from the terminal client
    Then the list of clients updates live as access changes
    And the user can revoke one client or every other client
