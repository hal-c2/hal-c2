# Sources:
#   docs/user/terminal.md (server-owned sessions, scrollback limits)
#   docs/internals/terminal-runtime.md (bounded restore, query stripping, 512 KiB client buffer)
#   packages/contracts/src/terminal.ts (TerminalAttachInput, TerminalAttachStreamEvent, TerminalMetadataStreamEvent, history limits)
#   apps/server-ex/lib/hal_c2/terminal.ex (attach, restartIfNotRunning, history persistence)
#   apps/server-ex/lib/hal_c2/terminal/history.ex (query stripping, split escapes, UTF-8 carry, trimming)
#   apps/server/src/terminal/Manager.ts (evictInactiveSessionsIfNeeded, legacy per-thread log migration, readHistory)
#   apps/server/src/terminal/Manager.test.ts, OutputProtocol.test.ts (attach streams across close and
#     reopen, output during the snapshot, ordering through exit, the pending-output window)
#   apps/server-ex/lib/hal_c2/terminal/hub.ex (metadata snapshot, upsert, remove)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (terminal and terminals subscription shapes, unknown MC)
#   apps/server-ex/lib/hal_c2/web/socket.ex (remote terminal hub watch)
#   apps/server-ex/test/hal_c2/terminal_test.exs
#   apps/tui/src/components/ThreadTerminalDrawer.tsx (snapshot replay, 128 KiB tail)
#   apps/tui/src/connection.ts (subscribeTerminal, subscribeTerminalMetadata)
#   apps/web/src/components/TerminalEventSync.tsx
#   Cross-domain: connections/ owns relay and tunnel transport; mc/ owns cluster routing.

Feature: Reattaching to terminals
  A terminal outlives the client that opened it. Any client, on any device, can attach later
  and pick up where the shell is, with its recent history replayed.

  Rule: Attaching replays history and then streams live output

    @mc
    Scenario: Attaching to a running terminal replays its history first
      Given a running terminal that has printed "build ok"
      When a second client attaches to it
      Then the second client first receives a snapshot containing "build ok"
      And then receives new output as it happens

    @mc
    Scenario: Two clients attached to one terminal see the same output
      Given two clients attached to the same terminal
      When one client runs "date"
      Then both clients receive the date

    @mc
    Scenario: Attaching to an unknown terminal with a folder opens it
      Given the thread has no terminal "term-2"
      When a client attaches to "term-2" in "/work/app"
      Then a shell starts in "/work/app"
      And the client receives its snapshot

    @mc
    Scenario: Attaching to a terminal whose shell ended can restart it
      Given a terminal whose shell has exited
      When a client attaches asking to restart it if it is not running
      Then a new shell starts
      And the client is told the terminal restarted

    @mc
    Scenario: Attaching to a terminal whose shell ended shows its last output
      Given a terminal whose shell has exited after printing "done"
      When a client attaches without asking for a restart
      Then the client receives the history containing "done"
      And the terminal is reported as exited

    @mc
    Scenario: Detaching a client leaves the shell running
      Given a client attached to a running terminal
      When the client disconnects
      Then the shell keeps running
      And its output keeps being recorded

    # Legacy: apps/server/src/terminal/Manager.test.ts (keeps attach streams live when a terminal id is
    #   closed and reopened)
    @backlog @mc
    Scenario: A client attached to a terminal stays attached when it is closed and opened again
      Given a client attached to a running terminal
      When the terminal is closed and then opened again
      Then the client is told the terminal closed
      And receives a snapshot of the new shell
      And does not have to attach again

    # Legacy: apps/server/src/terminal/Manager.test.ts (buffers attach output delivered during the
    #   initial snapshot callback; streams attach snapshots followed by live events without duplicates)
    @backlog @mc
    Scenario: Output that arrives while a client is receiving its snapshot is not lost
      Given a running terminal whose shell prints as a client attaches
      When the shell prints "during snapshot" before the client has taken its snapshot
      Then the client receives its snapshot first
      And then receives "during snapshot" exactly once
      And receives no second snapshot

    # Legacy: apps/server/src/terminal/Manager.test.ts (preserves queued PTY output ordering through exit
    #   callbacks)
    @backlog @mc
    Scenario: Output queued before a shell ends arrives before its exit
      Given a running terminal
      When the shell prints "first" and "second" and exits at once
      Then attached clients receive "first", then "second", then the exit
      And a client attaching afterwards receives a snapshot that already includes the exit

  Rule: The MC keeps a bounded, replayable history

    @mc
    Scenario: History is kept across the terminal closing unless deletion is asked for
      Given a terminal that has printed "migrations applied"
      When a client closes the terminal without deleting its history
      And later opens the same terminal again
      Then the new shell's history begins with "migrations applied"

    @mc
    Scenario: Closing a terminal with history deletion removes its saved output
      Given a terminal that has printed "secret token"
      When a client closes the terminal and deletes its history
      Then no saved output remains for that terminal

    @mc
    Scenario: Closing every terminal of a thread at once
      Given a thread with terminals 1, 2 and 3
      When a client closes the thread's terminals without naming one
      Then all three shells stop

    @mc
    Scenario: History is saved to disk once output goes quiet
      Given a terminal that keeps printing output
      When the output stops for half a second
      Then the history is written to the MC's terminal store

    @mc
    Scenario Outline: History keeps the newest output within its limits
      Given a terminal that has printed <amount>
      When a client attaches
      Then the replayed history keeps only the newest <kept>

      Examples:
        | amount          | kept             |
        | 6,000 lines     | 5,000 lines      |
        | 10 MiB of text  | 8 MiB of text    |

    @backlog @mc
    Scenario: The MC keeps at most 128 ended terminals in memory
      Given the MC holds 128 terminals whose shells have ended
      When another terminal's shell ends
      Then the ended terminal that changed least recently is dropped from the MC's list
      And its saved output stays on disk
      And a terminal whose shell is running is never dropped

    @backlog @mc
    Scenario: Output saved by an older layout is picked up by the default terminal
      Given the terminal log folder holds an old per-thread file for "thread-1" with the text "old build"
      When a client opens the default terminal of "thread-1"
      Then the history begins with "old build"
      And the old file is replaced by the default terminal's own saved file
      And the terminal "term-2" of that thread does not receive the old text

    @mc
    Scenario: Replayed history does not make the shell answer old questions
      Given a program asked the terminal for its cursor position and colours
      When a client attaches and the history is replayed
      Then the replay does not contain those questions or their answers
      And the shell receives no stray replies

    @mc
    Scenario: Replayed history keeps what draws the screen
      Given a program changed the cursor shape and saved the cursor
      When a client attaches and the history is replayed
      Then the replay keeps the cursor shape and the saved cursor

    @mc
    Scenario: A character split between two reads is kept whole
      Given the shell prints an emoji whose bytes arrive in two reads
      When a client attaches and the history is replayed
      Then the emoji appears once and intact

    @mc
    Scenario: An escape sequence split between two reads is kept whole
      Given the shell prints a colour change whose bytes arrive in two reads
      When a client attaches and the history is replayed
      Then the colour change is applied and no stray characters appear

    @mc
    Scenario: Invalid bytes in the output become replacement characters
      Given the shell prints bytes that are not valid UTF-8
      Then attached clients see a replacement character in their place

  Rule: Clients discover terminals and follow them across reconnects

    @mc
    Scenario: A client watching terminals gets the current list and then changes
      Given the MC runs terminals for two threads
      When a client starts watching the MC's terminals
      Then it first receives both terminals
      And then it is told each time a terminal is added, changes or goes away

    @mc
    Scenario: A closed terminal is removed from the list
      Given a client is watching the MC's terminals
      When another client closes one of the terminals
      Then the watching client is told that terminal was removed

    @mc
    Scenario: A client attaches to a terminal on another MC of the cluster
      Given a cluster of two MCs
      And a thread whose terminal runs on the second MC
      When a client connected to the first MC attaches to that terminal
      Then the client receives the terminal's history and live output from the second MC

    @mc
    Scenario: Attaching to an MC the cluster does not know fails
      When a client attaches to a terminal on an MC the cluster does not know
      Then the subscription fails with "unknown MC"

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

    @desktop
    Scenario: The web terminal keeps up to 512 KiB of output per terminal
      Given a terminal that has printed more than 512 KiB since the client attached
      Then the client keeps the newest 512 KiB

    @backlog @mobile
    Scenario: The phone reattaches to a terminal after losing its connection
      Given the phone shows a running terminal
      When the phone loses its connection and reconnects
      Then the terminal shows its history and continues streaming
