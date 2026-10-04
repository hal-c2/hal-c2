# Sources:
#   packages/contracts/src/terminal.ts (TerminalCwdError, TerminalSessionLookupError, TerminalNotRunningError, TerminalHistoryError)
#   apps/server-ex/lib/hal_c2/terminal.ex (check_cwd, lookup_error, not_running_error, start_shell failures, closed-race handling)
#   apps/server-ex/lib/hal_c2/rpc.ex (terminal.* routing, including terminal.list)
#   apps/server-ex/test/hal_c2/terminal_test.exs
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (terminal-list)
#   apps/tui/src/components/ChatView.tsx (status messages for list, clear and restart failures)
#   apps/tui/src/components/ThreadTerminalDrawer.tsx ("[terminal error: …]")
#   apps/web/src/components/ThreadTerminalDrawer.tsx
#   apps/web/src/components/TerminalEventSync.tsx

Feature: Terminal failures
  If a terminal cannot start or has gone away, the user is told what went wrong in plain
  words and nothing else in the thread breaks.

  Rule: The MC explains why a terminal cannot open

    @mc
    Scenario Outline: A terminal refuses to open in a folder it cannot use
      When a client opens a terminal in <folder>
      Then opening fails with "<message>"
      And no shell starts

      Examples:
        | folder                               | message                                                  |
        | "/nope/not/here", which is missing     | Terminal cwd does not exist: /nope/not/here            |
        | "/work/app/README.md", which is a file | Terminal cwd is not a directory: /work/app/README.md   |

    @mc
    Scenario: A folder the MC may not read is reported with the reason
      Given the folder "/root/private" cannot be read by the MC
      When a client opens a terminal in "/root/private"
      Then opening fails with "Failed to access terminal cwd: /root/private" and the reason

    @mc
    Scenario: A machine with no usable shell reports which shells it tried
      Given the MC's machine has no login shell, zsh, bash or sh
      When a client opens a terminal
      Then attached clients receive the error "No shell found" naming each shell it tried
      And the terminal is marked as failed

    @mc
    Scenario: Typing into a shell that has ended is refused
      Given a terminal whose shell has exited
      When a client writes "ls" to it
      Then the write fails because the terminal is not running

    @mc
    Scenario Outline: Acting on a terminal that does not exist is refused
      When a client asks to <action> a terminal the thread does not have
      Then the request fails naming the unknown thread and terminal

      Examples:
        | action |
        | write  |
        | resize |
        | clear  |

    @mc
    Scenario: Restarting a terminal the thread does not have starts it
      When a client restarts a terminal the thread does not have, in "/work/app"
      Then a shell starts in "/work/app"

    @mc
    Scenario: Closing a terminal the thread does not have succeeds quietly
      When a client closes a terminal the thread does not have
      Then the request succeeds and nothing changes

    @mc
    Scenario: Attaching to a missing terminal without a folder is refused
      When a client attaches to a terminal the thread does not have, without giving a folder
      Then the attach fails naming the unknown thread and terminal

    @mc
    Scenario: A request that races the terminal closing is not an error
      Given a client is closing a terminal
      When another client closes the same terminal at the same moment
      Then both requests succeed

    @mc
    Scenario: Listing a thread's terminals works on the MC
      Given a thread with saved terminals 1 and 2
      When a client lists the thread's terminals
      Then it receives terminals 1 and 2

  Rule: Clients report terminal failures without losing the terminal

    @tui
    Scenario: A terminal error is written into the terminal itself
      Given the terminal client shows a terminal
      When the MC reports the terminal error "No shell found"
      Then the terminal shows "[terminal error: No shell found]"

    @tui
    Scenario Outline: A failed terminal action is reported on the status line
      Given the terminal client shows a terminal
      When <action> fails with "<reason>"
      Then the status line says "<message>"

      Examples:
        | action                | reason        | message                                          |
        | clearing it           | disconnected  | Could not clear terminal: disconnected           |
        | restarting it         | disconnected  | Could not restart terminal: disconnected         |
        | listing its terminals | not supported | Could not list terminal instances: not supported |

    @tui
    Scenario: Closing a terminal the MC already forgot still removes it
      Given the terminal client shows terminal 2, which the MC no longer has
      When the user closes terminal 2
      Then terminal 2 disappears without an error

    @desktop
    Scenario: A terminal that fails to open tells the user why
      When the user opens a terminal in a folder that no longer exists
      Then the terminal says the folder does not exist
      And the rest of the thread keeps working
