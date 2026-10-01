# Sources:
#   docs/user/terminal.md
#   docs/internals/terminal-runtime.md
#   packages/contracts/src/terminal.ts (TerminalOpenInput, TerminalSessionSnapshot, DEFAULT_TERMINAL_ID)
#   apps/server-ex/lib/hal_c2/terminal.ex (open, launch context, shell and env selection, labels)
#   apps/server-ex/lib/hal_c2/storage_cleanup.ex (busy? keeps worktrees with a running terminal)
#   apps/server-ex/test/hal_c2/terminal_test.exs
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalDrawer.qml (terminal.toggle, terminal.resize, focusTerminal)
#   apps/desktop-qt/qml/HalC2/Bricks/Workspace.qml (terminal toggle)
#   apps/desktop-qt/src/TerminalController.cpp (launch context, availability)
#   apps/desktop-qt/tests/tst_Scenarios.qml (terminal toggle)
#   features/terminal/drawer.feature (the desktop's launch-context scenarios, run natively)
#   apps/tui/src/components/ChatView.tsx (toggleTerminal, initialTabs)
#   apps/tui/src/components/ThreadTerminalDrawer.tsx
#   apps/web/src/components/ThreadTerminalDrawer.tsx
#   apps/web/src/components/ThreadTerminals.tsx
#   apps/mobile/src/features/terminal/ThreadTerminalRouteScreen.tsx
#   Cross-domain: files/ owns project scripts that run in a terminal; navigation/appearance.feature
#   owns terminal fonts.

Feature: Terminal sessions
  Every thread can run shells on the environment that owns it. The MC owns each shell, so
  a terminal keeps running while no client is looking at it, and every client sees the same one.

  Rule: The MC starts a shell where the thread works

    @mc
    Scenario: Opening a terminal starts a shell in the requested folder
      Given a thread whose project lives in "/work/app"
      When a client opens the thread's default terminal in "/work/app"
      Then a shell is running in "/work/app"
      And the terminal reports that it started

    @mc
    Scenario: A terminal on a worktree thread starts in the worktree
      Given a thread working in the worktree "/work/app-feature"
      When a client opens a terminal for that thread
      Then the shell starts in "/work/app-feature"
      And the terminal remembers which worktree it belongs to

    @mc
    Scenario: A terminal opens at a default size when the client gives none
      When a client opens a terminal without a size
      Then the shell sees a window of 120 columns and 30 rows

    @mc
    Scenario Outline: The MC picks the user's shell and falls back to common ones
      Given the user's login shell is <login shell>
      When a terminal opens
      Then the shell that runs is <shell>

      Examples:
        | login shell       | shell       |
        | "/usr/bin/fish"   | "fish"      |
        | not set           | "zsh"       |
        | not set, no zsh   | "bash"      |
        | not set, no bash  | "sh"        |

    @mc
    Scenario: The shell advertises a colour terminal
      When a terminal opens
      Then the shell sees TERM "xterm-256color" and COLORTERM "truecolor"

    @mc
    Scenario Outline: The MC keeps its own settings out of the user's shell
      Given the MC runs with <variable> set
      When a terminal opens
      Then the shell does not see <variable>

      Examples:
        | variable                            |
        | PORT                                |
        | ELECTRON_RENDERER_PORT              |
        | ELECTRON_RUN_AS_NODE                |
        | any variable starting with HAL_C2_  |
        | any variable starting with VITE_    |
        | any variable starting with RELEASE_ |
        | any variable starting with ERL_     |

    @mc
    Scenario: A client adds its own variables to a new shell
      When a client opens a terminal with the variable "APP_ENV" set to "preview"
      Then the shell sees "APP_ENV" as "preview"

    @mc
    Scenario: Opening a terminal that is already running only resizes it
      Given the thread's default terminal is running in "/work/app"
      When a client opens it again in "/work/app" at 100 columns and 40 rows
      Then the same shell keeps running
      And its window becomes 100 columns and 40 rows

    @mc
    Scenario Outline: Opening a terminal with a different launch context starts a fresh shell
      Given the thread's default terminal is running in "/work/app"
      When a client opens it again with <change>
      Then the old shell is replaced by a new one
      And the scrollback starts empty

      Examples:
        | change                        |
        | the folder "/work/app/web"    |
        | a different worktree          |
        | different extra variables     |

    @mc
    Scenario Outline: A terminal is labelled by its number
      When a client opens the terminal "<id>"
      Then the terminal is labelled "<label>"

      Examples:
        | id          | label       |
        | default     | Terminal 1  |
        | term-2      | Terminal 2  |
        | terminal-7  | Terminal 7  |
        | build-watch | build-watch |

    @mc
    Scenario: Worktree cleanup leaves a worktree with a running terminal alone
      Given a finished thread's worktree has a running terminal
      When storage cleanup looks for worktrees to remove
      Then that worktree is kept

  Rule: Clients open and hide the terminal without stopping it

    # Delivered natively (TerminalController, TerminalDrawer); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: The user shows and hides the terminal on desktop
      Given a thread whose environment can run terminals
      When the user shows the terminal
      Then the thread's terminal is visible and has focus
      When the user hides the terminal
      Then the terminal is hidden
      And its shell keeps running

    # Delivered natively (TerminalController, TerminalDrawer); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: The terminal toggle is only offered where a terminal can run
      Given the selected thread's environment cannot run terminals
      Then the user is not offered a way to show the terminal

    # Delivered natively (TerminalController, TerminalDrawer); no desktop test yet.
    @desktop @backlog-desktop
    Scenario Outline: The desktop terminal keeps a sensible height
      Given the terminal is showing in a window 1000 pixels tall
      When the user drags the terminal to <requested> pixels tall
      Then the terminal is <height> pixels tall

      Examples:
        | requested | height |
        | 100       | 180    |
        | 400       | 400    |
        | 900       | 750    |

    # Delivered natively (TerminalController, TerminalDrawer); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: Hiding and showing the terminal keeps what it was showing
      Given the terminal shows the output of a running build
      When the user hides the terminal and shows it again
      Then the same output is still on screen without a reload

    @tui
    Scenario: Opening the terminal in the terminal client starts the thread's default terminal
      Given a thread with no terminal open in the terminal client
      When the user opens the terminal
      Then the thread's default terminal is shown with focus
      And it is attached to the thread's working folder

    @tui
    Scenario: Hiding the terminal in the terminal client keeps its shell running
      Given the terminal is open in the terminal client
      When the user hides the terminal
      Then focus returns to the prompt
      And the shell keeps running on the server

    # Delivered natively (TerminalController, TerminalDrawer); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: A new terminal opened from the drawer uses the thread's launch context
      Given a thread working in a worktree
      When the user opens another terminal from the drawer
      Then it starts in the same folder and worktree as the thread

    # Delivered natively (TerminalController, TerminalDrawer); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: A terminal started by a project script shares that script's launch context
      Given a project script is running in a terminal
      When the user opens another terminal next to it
      Then the new terminal starts in the same folder and worktree as the script

    @backlog @mobile
    Scenario: The user opens a thread's terminal on the phone
      Given a thread with a running terminal on a paired environment
      When the user opens the thread's terminal on the phone
      Then the phone shows the same terminal and its recent output
