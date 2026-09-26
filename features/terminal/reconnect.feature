# Sources:
#   docs/user/terminal.md (server-owned sessions, scrollback limits)
#   docs/internals/terminal-runtime.md (bounded restore, query stripping, 512 KiB client buffer)
#   packages/contracts/src/terminal.ts (TerminalAttachInput, TerminalAttachStreamEvent, TerminalMetadataStreamEvent, history limits)
#   apps/server-ex/lib/hal_c2/terminal.ex (attach, restartIfNotRunning, history persistence)
#   apps/server-ex/lib/hal_c2/terminal/history.ex (query stripping, split escapes, UTF-8 carry, trimming)
#   apps/server-ex/lib/hal_c2/terminal/hub.ex (metadata snapshot, upsert, remove)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (terminal and terminals subscription shapes, unknown node)
#   apps/server-ex/lib/hal_c2/web/socket.ex (remote terminal hub watch)
#   apps/server-ex/test/hal_c2/terminal_test.exs
#   apps/tui/src/components/ThreadTerminalDrawer.tsx (snapshot replay, 128 KiB tail)
#   apps/tui/src/connection.ts (subscribeTerminal, subscribeTerminalMetadata)
#   apps/web/src/components/TerminalEventSync.tsx
#   Cross-domain: connections/ owns relay and tunnel transport; node/ owns cluster routing.

Feature: Reattaching to terminals
  A terminal outlives the client that opened it. Any client, on any device, can attach later
  and pick up where the shell is, with its recent history replayed.

  Rule: Attaching replays history and then streams live output

    @node
    Scenario: Attaching to a running terminal replays its history first
      Given a running terminal that has printed "build ok"
      When a second client attaches to it
      Then the second client first receives a snapshot containing "build ok"
      And then receives new output as it happens

    @node
    Scenario: Two clients attached to one terminal see the same output
      Given two clients attached to the same terminal
      When one client runs "date"
      Then both clients receive the date

    @node
    Scenario: Attaching to an unknown terminal with a folder opens it
      Given the thread has no terminal "term-2"
      When a client attaches to "term-2" in "/work/app"
      Then a shell starts in "/work/app"
      And the client receives its snapshot

    @node
    Scenario: Attaching to a terminal whose shell ended can restart it
      Given a terminal whose shell has exited
      When a client attaches asking to restart it if it is not running
      Then a new shell starts
      And the client is told the terminal restarted

    @node
    Scenario: Attaching to a terminal whose shell ended shows its last output
      Given a terminal whose shell has exited after printing "done"
      When a client attaches without asking for a restart
      Then the client receives the history containing "done"
      And the terminal is reported as exited

    @node
    Scenario: Detaching a client leaves the shell running
      Given a client attached to a running terminal
      When the client disconnects
      Then the shell keeps running
      And its output keeps being recorded

  Rule: The node keeps a bounded, replayable history

    @node
    Scenario: History is kept across the terminal closing unless deletion is asked for
      Given a terminal that has printed "migrations applied"
      When a client closes the terminal without deleting its history
      And later opens the same terminal again
      Then the new shell's history begins with "migrations applied"

    @node
    Scenario: Closing a terminal with history deletion removes its saved output
      Given a terminal that has printed "secret token"
      When a client closes the terminal and deletes its history
      Then no saved output remains for that terminal

    @node
    Scenario: Closing every terminal of a thread at once
      Given a thread with terminals 1, 2 and 3
      When a client closes the thread's terminals without naming one
      Then all three shells stop

    @node
    Scenario: History is saved to disk once output goes quiet
      Given a terminal that keeps printing output
      When the output stops for half a second
      Then the history is written to the node's terminal store

    @node
    Scenario Outline: History keeps the newest output within its limits
      Given a terminal that has printed <amount>
      When a client attaches
      Then the replayed history keeps only the newest <kept>

      Examples:
        | amount          | kept             |
        | 6,000 lines     | 5,000 lines      |
        | 10 MiB of text  | 8 MiB of text    |

    @node
    Scenario: Replayed history does not make the shell answer old questions
      Given a program asked the terminal for its cursor position and colours
      When a client attaches and the history is replayed
      Then the replay does not contain those questions or their answers
      And the shell receives no stray replies

    @node
    Scenario: Replayed history keeps what draws the screen
      Given a program changed the cursor shape and saved the cursor
      When a client attaches and the history is replayed
      Then the replay keeps the cursor shape and the saved cursor

    @node
    Scenario: A character split between two reads is kept whole
      Given the shell prints an emoji whose bytes arrive in two reads
      When a client attaches and the history is replayed
      Then the emoji appears once and intact

    @node
    Scenario: An escape sequence split between two reads is kept whole
      Given the shell prints a colour change whose bytes arrive in two reads
      When a client attaches and the history is replayed
      Then the colour change is applied and no stray characters appear

    @node
    Scenario: Invalid bytes in the output become replacement characters
      Given the shell prints bytes that are not valid UTF-8
      Then attached clients see a replacement character in their place

  Rule: Clients discover terminals and follow them across reconnects

    @node
    Scenario: A client watching terminals gets the current list and then changes
      Given the node runs terminals for two threads
      When a client starts watching the node's terminals
      Then it first receives both terminals
      And then it is told each time a terminal is added, changes or goes away

    @node
    Scenario: A closed terminal is removed from the list
      Given a client is watching the node's terminals
      When another client closes one of the terminals
      Then the watching client is told that terminal was removed

    @node
    Scenario: A client attaches to a terminal on another node of the cluster
      Given a cluster of two nodes
      And a thread whose terminal runs on the second node
      When a client connected to the first node attaches to that terminal
      Then the client receives the terminal's history and live output from the second node

    @node
    Scenario: Attaching to a node the cluster does not know fails
      When a client attaches to a terminal on a node the cluster does not know
      Then the subscription fails with "unknown node"

    @tui
    Scenario: The terminal client replays a bounded tail on attach
      Given a terminal with several megabytes of history
      When the terminal client shows it
      Then the terminal client replays only the newest 128 KiB
      And the terminal shows the latest screen quickly

    @tui
    Scenario: The terminal client restarts an ended shell when it shows the terminal
      Given the thread's terminal shell has exited
      When the user opens that terminal in the terminal client
      Then a new shell starts in the thread's folder

    @backlog @desktop
    Scenario: The web terminal keeps up to 512 KiB of output per terminal
      Given a terminal that has printed more than 512 KiB since the client attached
      Then the client keeps the newest 512 KiB

    @backlog @mobile
    Scenario: The phone reattaches to a terminal after losing its connection
      Given the phone shows a running terminal
      When the phone loses its connection and reconnects
      Then the terminal shows its history and continues streaming
