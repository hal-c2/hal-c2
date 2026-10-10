# Sources:
#   docs/user/terminal.md
#   docs/internals/terminal-runtime.md
#   packages/contracts/src/terminal.ts (TerminalOpenInput, TerminalSessionSnapshot, DEFAULT_TERMINAL_ID)
#   apps/server-ex/lib/hal_c2/terminal.ex (open, launch context, shell and env selection, labels)
#   apps/server-ex/lib/hal_c2/storage_cleanup.ex (busy? keeps worktrees with a running terminal)
#   apps/server-ex/test/hal_c2/terminal_test.exs
#   apps/server/src/terminal/Manager.ts (resolveShellCandidates, Windows shell order, stripAppImageRuntimeEnv,
#     resolveProviderInstanceTerminalEnvironment, openWithWorkspaceLease)
#   apps/server/src/terminal/Manager.test.ts (zsh prompt marker, provider environment change, worktree on reopen)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalDrawer.qml (terminal.toggle, terminal.resize, focusTerminal)
#   apps/desktop-qt/qml/HalC2/Bricks/Workspace.qml (terminal toggle)
#   apps/desktop-qt/src/TerminalController.cpp (launch context, availability)
#   apps/desktop-qt/tests/tst_Scenarios.qml (terminal toggle)
#   features/terminal/drawer.feature (the desktop's launch-context scenarios, run natively)
#   apps/tui/src/components/ChatView.tsx (toggleTerminal, initialTabs)
#   apps/tui/src/components/ThreadTerminalDrawer.tsx
#   apps/web/src/components/ThreadTerminalDrawer.tsx
#   apps/web/src/components/ThreadTerminals.tsx
#   apps/web/src/terminalUiStateStore.ts
#   apps/web/src/terminal/ghostty/surface.ts (a hidden terminal stops drawing)
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

    @backlog @mc
    Scenario Outline: On Windows the MC picks a PowerShell and falls back to the command prompt
      Given the MC runs on Windows with <installed>
      When a terminal opens
      Then the shell that runs is <shell>

      Examples:
        | installed                         | shell                |
        | PowerShell 7                      | "PowerShell 7"       |
        | only Windows PowerShell           | "Windows PowerShell" |
        | neither PowerShell                | "cmd"                |

    @mc
    Scenario: The shell advertises a colour terminal
      When a terminal opens
      Then the shell sees TERM "xterm-256color" and COLORTERM "truecolor"

    # Legacy: apps/server/src/terminal/Manager.test.ts (starts zsh with prompt spacer disabled)
    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (zsh started with -o nopromptsp)
    @backlog @mc
    Scenario: A zsh shell does not print a "%" marker after output that lacks a newline
      Given the user's shell is zsh
      When a terminal opens
      Then the shell is started with zsh's partial-line marker turned off

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

    # Not yet in apps/server-ex/lib/hal_c2/terminal.ex: its env scrub has no AppImage rule.
    @backlog @mc
    Scenario: A shell started from an AppImage build does not see the AppImage's mount
      Given the MC was started from an AppImage with APPIMAGE, APPDIR, ARGV0 and OWD set
      And PATH holds "/tmp/.mount_hal-c2/usr/bin" and "/usr/bin"
      When a terminal opens
      Then the shell sees none of APPIMAGE, APPDIR, ARGV0 or OWD
      And the shell sees PATH as "/usr/bin"

    # Not yet in apps/server-ex/lib/hal_c2/terminal.ex.
    @backlog @mc
    Scenario Outline: A search path that held only the AppImage's mount is removed from the shell
      Given the MC was started from an AppImage mounted at "/tmp/.mount_hal-c2"
      And <variable> holds only entries under "/tmp/.mount_hal-c2"
      When a terminal opens
      Then the shell does not see <variable>

      Examples:
        | variable             |
        | PATH                 |
        | LD_LIBRARY_PATH      |
        | XDG_DATA_DIRS        |
        | GSETTINGS_SCHEMA_DIR |

    @backlog @mc
    Scenario: A shell not started from an AppImage keeps its environment as it is
      Given the MC was not started from an AppImage
      And a variable named "OWD" is set
      When a terminal opens
      Then the shell sees "OWD" unchanged

    @mc
    Scenario: A client adds its own variables to a new shell
      When a client opens a terminal with the variable "APP_ENV" set to "preview"
      Then the shell sees "APP_ENV" as "preview"

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (provider_env)
    @backlog @mc
    Scenario: A terminal opened for a provider instance runs with that instance's variables
      Given the Codex instance "work" sets the variable "OPENAI_BASE_URL" to "https://gw.example"
      When a client opens a terminal for the provider instance "work"
      Then the shell sees "OPENAI_BASE_URL" as "https://gw.example"
      And the terminal's snapshot does not carry the instance's variables

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (provider_env)
    @backlog @mc
    Scenario Outline: An instance's home folder wins over a home variable in its environment
      Given the <driver> instance "work" has the home folder "~/work-home"
      And the instance also sets <variable> to "~/other"
      When a client opens a terminal for the provider instance "work"
      Then the shell sees <variable> as the expanded "~/work-home"

      Examples:
        | driver | variable          |
        | Codex  | CODEX_HOME        |
        | Claude | CLAUDE_CONFIG_DIR |

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (provider_env)
    @backlog @mc
    Scenario: The default instance of a provider opens a terminal without being configured
      Given no provider instance named "codex" is configured
      When a client opens a terminal for the provider instance "codex"
      Then the shell starts with the MC's own environment

    # Legacy: apps/server/src/terminal/Manager.test.ts (restarts a running terminal when the resolved
    #   provider environment changes)
    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (provider_env feeds the launch context)
    @backlog @mc
    Scenario: A running provider terminal restarts when its instance's variables have changed
      Given a terminal running for the provider instance "work" with "PROVIDER_SECRET" set to "first-secret"
      And the instance now sets "PROVIDER_SECRET" to "second-secret"
      When a client opens the terminal again
      Then the old shell is replaced by a new one
      And the new shell sees "PROVIDER_SECRET" as "second-secret"

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

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (open replaces an exited shell)
    @backlog @mc
    Scenario: Opening a terminal whose shell has ended starts a fresh shell
      Given the thread's default terminal printed "done" and its shell has exited
      When a client opens it again in the same folder
      Then a new shell is running
      And the scrollback starts empty
      And the terminal reports that it restarted

    # Legacy: apps/server/src/terminal/Manager.test.ts (preserves worktree metadata when reopening an
    #   exited session)
    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (launch_context keeps worktree_path)
    @backlog @mc
    Scenario: Opening a terminal whose shell ended on a worktree keeps it on that worktree
      Given the thread's default terminal runs on the worktree "/work/app-feature" and its shell has exited
      When a client opens it again on that worktree
      Then the new shell's snapshot and its started event name the worktree "/work/app-feature"

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (one process per terminal)
    @backlog @mc
    Scenario: Two clients opening the same terminal at once get one shell
      Given the thread has no terminal "term-2" yet
      When two clients open "term-2" at the same moment
      Then exactly one shell is started
      And both clients are told about that shell

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

    # Likely already implemented: apps/server-ex/lib/hal_c2/terminal.ex (label is cut to 128 characters)
    @backlog @mc
    Scenario: A terminal's label is never longer than 128 characters
      When a client opens a terminal whose id is 200 characters long
      Then the terminal is labelled with the first 128 characters of its id

    @mc
    Scenario: Worktree cleanup leaves a worktree with a running terminal alone
      Given a finished thread's worktree has a running terminal
      When storage cleanup looks for worktrees to remove
      Then that worktree is kept

  Rule: Clients open and hide the terminal without stopping it

    @desktop
    Scenario: The user shows and hides the terminal on desktop
      Given a thread whose environment can run terminals
      When the user shows the terminal
      Then the thread's terminal is visible and has focus
      When the user hides the terminal
      Then the terminal is hidden
      And its shell keeps running

    @desktop
    Scenario: The terminal toggle is only offered where a terminal can run
      Given the selected thread's environment cannot run terminals
      Then the user is not offered a way to show the terminal

    @desktop
    Scenario Outline: The desktop terminal keeps a sensible height
      Given the terminal is showing in a window 1000 pixels tall
      When the user drags the terminal to <requested> pixels tall
      Then the terminal is <height> pixels tall

      Examples:
        | requested | height |
        | 100       | 180    |
        | 400       | 400    |
        | 900       | 750    |

    @backlog @desktop
    Scenario: Shrinking the window pulls a tall terminal back within its limit
      Given the terminal is showing 700 pixels tall in a window 1000 pixels tall
      When the user shrinks the window to 600 pixels tall
      Then the terminal is 450 pixels tall
      And the terminal's shell is resized to match

    @backlog @desktop
    Scenario: A hidden terminal stops drawing but keeps reading its shell
      Given the terminal is running a build that prints continuously
      When the user hides the terminal
      Then the terminal does no drawing work
      And the shell's output keeps being read and its replies keep being sent
      When the user shows the terminal again
      Then the terminal is drawn in full and shows the latest output

    @backlog @desktop
    Scenario: Hiding the terminal does not shrink the shell
      Given the shell is running at 120 columns and 30 rows
      When the user hides the terminal so that it has no size
      Then the shell is not resized
      When the user shows the terminal at the same size again
      Then it is drawn again without a resize

    @desktop
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

    @desktop
    Scenario: A new terminal opened from the drawer uses the thread's launch context
      Given a thread working in a worktree
      When the user opens another terminal from the drawer
      Then it starts in the same folder and worktree as the thread

    @desktop
    Scenario: A terminal started by a project script shares that script's launch context
      Given a project script is running in a terminal
      When the user opens another terminal next to it
      Then the new terminal starts in the same folder and worktree as the script

    @backlog @mobile
    Scenario: The user opens a thread's terminal on the phone
      Given a thread with a running terminal on a paired environment
      When the user opens the thread's terminal on the phone
      Then the phone shows the same terminal and its recent output
