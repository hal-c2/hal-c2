# Sources:
#   packages/contracts/src/terminal.ts (TerminalCwdError, TerminalSessionLookupError, TerminalNotRunningError, TerminalHistoryError)
#   apps/server-ex/lib/hal_c2/terminal.ex (check_cwd, lookup_error, not_running_error, start_shell failures, closed-race handling)
#   apps/server/src/terminal/Manager.ts (resolveProviderInstanceTerminalEnvironment, list ordering)
#   apps/server/src/terminal/Manager.test.ts (attach with a missing provider instance)
#   apps/server-ex/lib/hal_c2/rpc.ex (terminal.* routing, including terminal.list)
#   apps/server-ex/test/hal_c2/terminal_test.exs
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (terminal-list)
#   apps/tui/src/components/ChatView.tsx (status messages for list, clear and restart failures)
#   apps/tui/src/components/ThreadTerminalDrawer.tsx ("[terminal error: …]")
#   apps/web/src/components/ThreadTerminalDrawer.tsx
#   apps/web/src/components/TerminalEventSync.tsx
#   apps/web/src/components/useThreadTerminalActions.ts (failed open, split, new and script terminals)
#   apps/web/src/terminalUiStateStore.ts

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

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (provider_env)
    @backlog @mc
    Scenario: A terminal for a provider instance that is not configured is refused
      Given no provider instance "ghost" is configured and none is built in under that name
      When a client opens a terminal for the provider instance "ghost"
      Then the open fails with "Provider instance is not available: ghost"
      And no shell is started

    @backlog @mc
    Scenario: A terminal does not open when the instance's settings cannot be read
      Given the MC cannot read its provider settings
      When a client opens a terminal for the provider instance "work"
      Then the open fails
      And no shell is started with a missing home or variables

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

    # Legacy: apps/server/src/terminal/Manager.test.ts (fails closed when attaching would create a missing
    #   provider terminal; attaches to a running provider terminal without resolving the provider again)
    @backlog @mc
    Scenario: Attaching to a terminal that does not exist for a provider instance that is gone starts no shell
      Given no provider instance "deleted_instance" is configured
      And the thread has no terminal "term-2"
      When a client attaches to "term-2" in "/work/app" for the provider instance "deleted_instance"
      Then the attach fails with "Provider instance is not available: deleted_instance"
      And no shell is started

    # Legacy: apps/server/src/terminal/Manager.test.ts (attaches to a running provider terminal without
    #   resolving the provider again)
    @backlog @mc
    Scenario: A running provider terminal can be attached to after its instance was removed
      Given a terminal running for the provider instance "work"
      And the provider instance "work" has since been removed
      When a client attaches to it asking to restart it if it is not running
      Then the client receives the terminal's snapshot
      And the running shell is not restarted

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

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (list sorts term-N by number)
    @backlog @mc
    Scenario: A thread's terminals are listed in the order of their numbers
      Given a thread with saved terminals "term-10", "term-2" and "default"
      When a client lists the thread's terminals
      Then it receives them as "default", "term-2" and "term-10"

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

    @backlog @desktop
    Scenario Outline: A failed terminal action is written into the terminal
      Given the terminal shows a running shell
      When <action> fails with "<reason>"
      Then the terminal shows "[terminal] <message>"
      And the terminal keeps working

      Examples:
        | action                                | reason               | message                      |
        | sending what the user typed           | MC is unreachable    | MC is unreachable            |
        | sending what the user typed           |                      | Terminal write failed        |
        | copying the selection                 |                      | Unable to copy terminal selection |
        | pasting from the clipboard            |                      | Unable to read the clipboard |
        | moving the cursor by word or line     |                      | Failed to move cursor        |
        | deleting to the start of the line     |                      | Failed to delete terminal input |
        | clearing from the keyboard            |                      | Failed to clear terminal     |
        | opening a file path from the output   |                      | Unable to open path          |

    @backlog @desktop
    Scenario: A link that cannot be opened anywhere is reported without losing the terminal
      Given the user's links open in the in-app browser
      And neither the in-app browser nor the system browser can open an address
      When the user follows a web address in the terminal
      Then the user sees an "error" toast "Unable to open link"
      And the terminal keeps working

    @backlog @desktop
    Scenario: A first terminal that fails to start leaves no empty tab and is retried
      Given the thread has no terminals
      And the MC refuses to open the terminal
      When the user shows the terminal
      Then the drawer does not stay open with a dead terminal
      When the user shows the terminal again and the MC accepts
      Then the terminal opens and the drawer shows it

    @backlog @desktop
    Scenario Outline: A terminal that fails to start leaves the existing terminal as it was
      Given the thread has one running terminal that is active
      And the MC refuses to open another terminal
      When the user <action>
      Then the thread still has only its first terminal and it is still active
      And nothing is typed into any terminal

      Examples:
        | action                                         |
        | splits the terminal side by side               |
        | splits the terminal stacked                    |
        | opens a new terminal                           |
        | runs a project script that wants a new terminal |

    @backlog @desktop
    Scenario: A script that cannot reopen its terminal does not close it
      Given a project script's terminal is already known to the thread
      And the MC refuses to open it again
      When the user runs the script
      Then the terminal stays in the thread
      And the script's command is not typed

    @backlog @desktop
    Scenario: An empty drawer offers to start a terminal
      Given the thread has no terminals
      When the drawer is shown
      Then the drawer says "No terminal sessions for this thread yet."
      And it offers to open a new terminal

    @backlog @desktop
    Scenario: A terminal engine that fails to load tells the user how to retry
      Given the terminal's rendering engine cannot start
      When the user opens a terminal
      Then the terminal says why, followed by "close and reopen the terminal to retry."
      When the user closes the terminal and opens it again
      Then the terminal tries to start the engine again
