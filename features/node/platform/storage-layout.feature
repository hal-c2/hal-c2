# Sources:
#   XDG Base Directory specification (https://specifications.freedesktop.org/basedir-spec/latest/)
#   https://wiki.archlinux.org/title/XDG_Base_Directory
#   packages/shared/src/devHome.ts (resolveHalC2Home, resolveWorktreeHalC2Home: a worktree's .hal-c2 outranks HAL_C2_HOME)
#   scripts/dev-runner.ts (--home-dir, worktree .hal-c2, dev and userdata profiles)
#   apps/server/src/config.ts (deriveServerPaths: settings, database, attachments, logs, caches)
#   apps/server/src/cli/config.ts (--base-dir, a dev URL picks the dev profile)
#   apps/server/src/cli/pair.ts (probes both profiles)
#   apps/server/src/device/SshDeviceHost.ts, packages/ssh/src/tunnel.ts (ssh-launch on remote hosts)
#   apps/server-ex/config/config.exs (the hal-c2-dev profile for a dev node)
#   apps/server-ex/config/runtime.exs (HAL_C2_NODE_HOME, HAL_C2_HOME)
#   apps/server-ex/rel/env.sh.eex (the release's home)
#   apps/server-ex/README.md (Run, Release: where the node keeps its state)
#   apps/desktop-qt/src/StoragePaths.cpp, apps/desktop-qt/src/main.cpp (--home-dir, shell config dir, web profile, --base-dir for the hosted server)
#   packages/shared/src/desktopAppControlSocket.ts, apps/desktop/src/app/DesktopAppActivation.ts (desktop app control socket)
#   apps/desktop/src/wsl/DesktopWslEnvironment.ts (wsl-runtime inside a distro)
#   apps/tui/src/shellConfigDir.ts (HAL_C2_TUI_SHELL_DIR, config/shell/tui)
#   docs/internals/glossary.md (HAL-C2 home)
#   docs/internals/desktop-qt.md (web engine profile, shell directory)
#   docs/operations/development.md (State and ports)
#   docs/user/install.md (Coming from T3 Code)

Feature: Where HAL-C2 keeps its files
  HAL-C2 follows the XDG Base Directory layout on every platform. Settings, data the
  user cannot get back, logs and runtime state, and re-downloadable caches each live
  in their own base directory, in a directory named "hal-c2". There is no "~/.hal-c2"
  and no "~/.t3"; those are only read once, by the migration.

  One variable, HAL_C2_HOME, or a command-line root, puts everything under a single
  directory instead. There is no HAL-C2 variable for a single kind; the XDG variables
  are how a user moves one kind.

  # The Electron desktop app's own browser profile stays where Electron keeps it, in
  # "hal-c2" (or "hal-c2-dev") under the platform's application data directory.

  Rule: Each kind of file has one base directory

    @node
    Scenario Outline: With nothing configured each kind uses its platform default
      Given a <platform> user with no XDG variables and no HAL-C2 home configured
      When HAL-C2 starts
      Then its <kind> directory is "<path>"

      Examples:
        | platform | kind    | path                        |
        | Linux    | config  | ~/.config/hal-c2            |
        | Linux    | data    | ~/.local/share/hal-c2       |
        | Linux    | state   | ~/.local/state/hal-c2       |
        | Linux    | cache   | ~/.cache/hal-c2             |
        | Linux    | runtime | ~/.local/state/hal-c2       |
        | macOS    | config  | ~/.config/hal-c2            |
        | macOS    | data    | ~/.local/share/hal-c2       |
        | macOS    | state   | ~/.local/state/hal-c2       |
        | macOS    | cache   | ~/.cache/hal-c2             |
        | macOS    | runtime | ~/.local/state/hal-c2       |
        | Windows  | config  | %APPDATA%\hal-c2\config     |
        | Windows  | data    | %LOCALAPPDATA%\hal-c2\data  |
        | Windows  | state   | %LOCALAPPDATA%\hal-c2\state |
        | Windows  | cache   | %LOCALAPPDATA%\hal-c2\cache |
        | Windows  | runtime | %LOCALAPPDATA%\hal-c2\state |

    @node
    Scenario: macOS keeps nothing in the Library folder
      Given a macOS user with no XDG variables and no HAL-C2 home configured
      When HAL-C2 starts and saves its settings
      Then nothing is written under "~/Library/Application Support"

    @node
    Scenario Outline: An XDG variable moves its kind on every platform
      Given a <platform> user with <variable> set to "<value>"
      When HAL-C2 starts
      Then its <kind> directory is "<path>"

      Examples:
        | platform | variable        | value             | kind    | path                     |
        | Linux    | XDG_CONFIG_HOME | /xdg/config       | config  | /xdg/config/hal-c2       |
        | Linux    | XDG_DATA_HOME   | /xdg/data         | data    | /xdg/data/hal-c2         |
        | Linux    | XDG_STATE_HOME  | /xdg/state        | state   | /xdg/state/hal-c2        |
        | Linux    | XDG_CACHE_HOME  | /xdg/cache        | cache   | /xdg/cache/hal-c2        |
        | Linux    | XDG_RUNTIME_DIR | /run/user/1000    | runtime | /run/user/1000/hal-c2    |
        | macOS    | XDG_DATA_HOME   | /Volumes/xdg/data | data    | /Volumes/xdg/data/hal-c2 |
        | macOS    | XDG_RUNTIME_DIR | /tmp/xdg-runtime  | runtime | /tmp/xdg-runtime/hal-c2  |
        | Windows  | XDG_CONFIG_HOME | D:\xdg\config     | config  | D:\xdg\config\hal-c2     |
        | Windows  | XDG_CACHE_HOME  | D:\xdg\cache      | cache   | D:\xdg\cache\hal-c2      |

    @node
    Scenario Outline: An XDG variable that is not an absolute path is ignored
      Given a Linux user with <variable> set to <value>
      When HAL-C2 starts
      Then its <kind> directory is "<path>"

      Examples:
        | variable        | value           | kind    | path                  |
        | XDG_DATA_HOME   | ""              | data    | ~/.local/share/hal-c2 |
        | XDG_DATA_HOME   | "share"         | data    | ~/.local/share/hal-c2 |
        | XDG_CONFIG_HOME | "./config"      | config  | ~/.config/hal-c2      |
        | XDG_RUNTIME_DIR | ""              | runtime | ~/.local/state/hal-c2 |
        | XDG_RUNTIME_DIR | "run/user/1000" | runtime | ~/.local/state/hal-c2 |

    @node
    Scenario Outline: Every directory HAL-C2 creates is private to the user
      Given a Linux user whose <kind> directory does not exist yet
      When HAL-C2 starts
      Then HAL-C2 creates its <kind> directory readable only by the user

      Examples:
        | kind    |
        | config  |
        | data    |
        | state   |
        | cache   |
        | runtime |

    @node
    Scenario: Secrets stay private inside the data directory
      When HAL-C2 stores a secret for the first time
      Then its "secrets" directory in the data directory is readable only by the user

  Rule: One root can hold every kind

    @node
    Scenario Outline: HAL_C2_HOME puts every kind under one root
      Given HAL_C2_HOME is "/srv/hal-c2"
      When HAL-C2 starts
      Then its <kind> directory is "<path>"

      Examples:
        | kind    | path               |
        | config  | /srv/hal-c2/config |
        | data    | /srv/hal-c2/data   |
        | state   | /srv/hal-c2/state  |
        | cache   | /srv/hal-c2/cache  |
        | runtime | /srv/hal-c2/state  |

    @node
    Scenario Outline: HAL_C2_HOME outranks the XDG variables
      Given HAL_C2_HOME is "/srv/hal-c2"
      And <variable> is set to "<value>"
      When HAL-C2 starts
      Then its <kind> directory is "<path>"

      Examples:
        | variable        | value          | kind    | path              |
        | XDG_DATA_HOME   | /xdg/data      | data    | /srv/hal-c2/data  |
        | XDG_RUNTIME_DIR | /run/user/1000 | runtime | /srv/hal-c2/state |

    # A dev node keeps its state in the hal-c2-dev profile from a worktree too
    # (node-startup.feature); only the TypeScript dev runner gives a worktree its own root.
    @dropped @node
    Scenario: A worktree's own directory outranks an ambient HAL_C2_HOME
      Given HAL_C2_HOME is "/srv/hal-c2" in the developer's shell
      When a developer starts HAL-C2 from a linked git worktree
      Then every kind lives under the worktree's ".hal-c2" directory
      And nothing is written under "/srv/hal-c2"

    @backlog @node
    Scenario Outline: A root named on the command line outranks the worktree and HAL_C2_HOME
      Given HAL_C2_HOME is "/srv/hal-c2" in the developer's shell
      When a developer starts <what> from a linked git worktree with <flag> "/tmp/sandbox"
      Then every kind lives under "/tmp/sandbox"

      Examples:
        | what                   | flag       |
        | the development runner | --home-dir |
        | the server             | --base-dir |

    @backlog @desktop
    Scenario: The desktop app's home directory outranks the worktree and HAL_C2_HOME
      Given HAL_C2_HOME is "/srv/hal-c2" in the developer's shell
      When a developer starts the desktop app from a linked git worktree with --home-dir "/tmp/sandbox"
      Then the desktop app and the server it hosts keep every kind under "/tmp/sandbox"

  Rule: Development keeps its own directories

    @node
    Scenario Outline: A development server with no root uses the development profile
      Given no HAL-C2 home is configured
      When a developer starts a development server from a linked git worktree
      Then its <kind> directory is "<path>"
      And the installed app's "<installed>" is not touched

      Examples:
        | kind   | path                      | installed             |
        | config | ~/.config/hal-c2-dev      | ~/.config/hal-c2      |
        | data   | ~/.local/share/hal-c2-dev | ~/.local/share/hal-c2 |
        | state  | ~/.local/state/hal-c2-dev | ~/.local/state/hal-c2 |
        | cache  | ~/.cache/hal-c2-dev       | ~/.cache/hal-c2       |

    @node
    Scenario Outline: Under an explicit root there is one profile
      Given <root>
      When a developer starts a development server
      Then its data directory is <path>
      And there is no "dev" or "userdata" level inside it

      # A dev node has no worktree root (node-startup.feature).
      @dropped
      Examples: Dropped on the node
        | root                                         | path                          |
        | the server is started from a linked worktree | the worktree's ".hal-c2/data" |

      # A dev node ignores HAL_C2_HOME (only a release reads it), and --base-dir is the
      # TypeScript server's.
      @backlog
      Examples: Not yet on the node
        | root                                          | path                |
        | HAL_C2_HOME is "/srv/hal-c2"                  | "/srv/hal-c2/data"  |
        | the server is given --base-dir "/tmp/sandbox" | "/tmp/sandbox/data" |

    @backlog @node
    Scenario Outline: Pairing finds a running server in either profile
      Given <which> server is running with no HAL-C2 home configured
      When the user runs "hal-c2 pair"
      Then it prints a pairing link for that server

      Examples:
        | which         |
        | the installed |
        | a development |

  Rule: The node's files are sorted by kind

    Background:
      Given a Linux user with no XDG variables and no HAL-C2 home configured

    # The node keeps its files under an "elixir" level in each kind so it never collides
    # with the server the desktop app hosts, which uses the same root.
    @node
    Scenario Outline: Each of the node's files lives in the kind it belongs to
      When a user starts the node from a release
      Then the node keeps <what> at "<path>"

      Examples:
        | what                            | path                                              |
        | its settings                    | ~/.config/hal-c2/elixir/settings.json             |
        | its keybindings                 | ~/.config/hal-c2/elixir/keybindings.json          |
        | its themes                      | ~/.config/hal-c2/elixir/themes                    |
        | its database                    | ~/.local/share/hal-c2/elixir/hal-c2.sqlite        |
        | its environment id              | ~/.local/share/hal-c2/elixir/environment-id       |
        | its access token                | ~/.local/share/hal-c2/elixir/access-token         |
        | attachments                     | ~/.local/share/hal-c2/elixir/attachments          |
        | browser captures                | ~/.local/share/hal-c2/elixir/browser-artifacts    |
        | the worktrees it creates        | ~/.local/share/hal-c2/elixir/worktrees            |
        | installed plugins               | ~/.local/share/hal-c2/elixir/plugins              |
        | secrets                         | ~/.local/share/hal-c2/elixir/secrets              |
        | provider sign-ins               | ~/.local/share/hal-c2/elixir/provider-auth        |
        | provider data                   | ~/.local/share/hal-c2/elixir/providers            |
        | cluster membership              | ~/.local/share/hal-c2/elixir/cluster              |
        | staged upgrades                 | ~/.local/share/hal-c2/elixir/upgrades             |
        | scheduled tasks                 | ~/.local/share/hal-c2/elixir/scheduled-tasks.json |
        | device hub state                | ~/.local/share/hal-c2/elixir/device               |
        | server, trace and provider logs | ~/.local/state/hal-c2/elixir/logs                 |
        | downloaded tools                | ~/.cache/hal-c2/elixir/tools                      |
        | the ACP registry                | ~/.cache/hal-c2/elixir/acp-registry               |
        | the Pi cache                    | ~/.cache/hal-c2/elixir/pi                         |
        | the usage scan cache            | ~/.cache/hal-c2/elixir/usage-scan-cache.bin       |
        | model rates for usage           | ~/.cache/hal-c2/elixir/usage-model-rates.json     |

    @node
    Scenario Outline: HAL_C2_NODE_HOME is a root for the node alone
      Given HAL_C2_NODE_HOME is "/srv/node"
      When the node starts
      Then the node keeps <what> at "<path>"

      Examples:
        | what             | path                           |
        | its settings     | /srv/node/config/settings.json |
        | its database     | /srv/node/data/hal-c2.sqlite   |
        | its logs         | /srv/node/state/logs           |
        | downloaded tools | /srv/node/cache/tools          |

    @node
    Scenario: HAL_C2_NODE_HOME outranks HAL_C2_HOME for the node
      Given HAL_C2_NODE_HOME is "/srv/node" and HAL_C2_HOME is "/srv/hal-c2"
      When the node starts
      Then its database is "/srv/node/data/hal-c2.sqlite"

    @node
    Scenario: Clearing the cache loses nothing the user made
      Given the node has threads, settings, provider sign-ins and secrets
      When the user deletes "~/.cache/hal-c2" and restarts the node
      Then the threads, settings, provider sign-ins and secrets are all still there
      And downloaded tools are fetched again when they are next needed

  Rule: The desktop app's and the hosted server's files are sorted by kind

    Background:
      Given a Linux user with no XDG variables and no HAL-C2 home configured

    @backlog @desktop
    Scenario Outline: Each of the desktop app's files lives in the kind it belongs to
      When the user starts the desktop app
      Then it keeps <what> at "<path>"

      Examples:
        | what                           | path                                   |
        | the user's shell               | ~/.config/hal-c2/shell/shell.qml       |
        | the user's shell theme         | ~/.config/hal-c2/shell/theme.json      |
        | the user's extra QML modules   | ~/.config/hal-c2/shell/qml             |
        | its desktop settings           | ~/.config/hal-c2/desktop-settings.json |
        | its web profile and page cache | ~/.cache/hal-c2/shell-web              |
        | its logs                       | ~/.local/state/hal-c2/logs             |

    # The server the desktop app hosts. The node's own files are in the rule above.
    @backlog @desktop
    Scenario Outline: Each of the hosted server's files lives in the kind it belongs to
      When the user starts the desktop app
      Then the server it hosts keeps <what> at "<path>"

      Examples:
        | what                              | path                                          |
        | its settings                      | ~/.config/hal-c2/settings.json                |
        | its keybindings                   | ~/.config/hal-c2/keybindings.json             |
        | its themes                        | ~/.config/hal-c2/themes                       |
        | client settings                   | ~/.config/hal-c2/client-settings.json         |
        | its database                      | ~/.local/share/hal-c2/statev2.sqlite          |
        | attachments                       | ~/.local/share/hal-c2/attachments             |
        | secrets                           | ~/.local/share/hal-c2/secrets                 |
        | its environment id                | ~/.local/share/hal-c2/environment-id          |
        | HAL-C2 Connect sign-in            | ~/.local/share/hal-c2/clerk-tokens.json       |
        | saved environments                | ~/.local/share/hal-c2/saved-environments.json |
        | the connection catalog            | ~/.local/share/hal-c2/connection-catalog.json |
        | browser captures                  | ~/.local/share/hal-c2/browser-artifacts       |
        | Snap Shots                        | ~/.local/share/hal-c2/snap-shots              |
        | provider data                     | ~/.local/share/hal-c2/providers               |
        | device hosts and device tools     | ~/.local/share/hal-c2/device                  |
        | ACP provider sign-ins             | ~/.local/share/hal-c2/acp-auth                |
        | the worktrees it creates          | ~/.local/share/hal-c2/worktrees               |
        | installed CLI versions            | ~/.local/share/hal-c2/runtime                 |
        | database backups                  | ~/.local/share/hal-c2/runtime/db-backup       |
        | server, trace and provider logs   | ~/.local/state/hal-c2/logs                    |
        | terminal logs                     | ~/.local/state/hal-c2/logs/terminals          |
        | the running server's record       | ~/.local/state/hal-c2/server-runtime.json     |
        | the anonymous id                  | ~/.local/state/hal-c2/anonymous-id            |
        | service state and restart markers | ~/.local/state/hal-c2/service-state.json      |
        | triage reports                    | ~/.local/state/hal-c2/triage                  |
        | provider status                   | ~/.cache/hal-c2/provider-status               |
        | pull request data                 | ~/.cache/hal-c2/pull-requests                 |
        | native app icons                  | ~/.cache/hal-c2/native-app-icons              |
        | the ACP registry                  | ~/.cache/hal-c2/acp-registry                  |
        | the Pi cache                      | ~/.cache/hal-c2/pi                            |
        | the model manifest                | ~/.cache/hal-c2/model-manifest.json           |
        | model rates for usage             | ~/.cache/hal-c2/usage-model-rates.json        |
        | the usage scan cache              | ~/.cache/hal-c2/usage-scan-cache.json         |
        | downloaded tools and binaries     | ~/.cache/hal-c2/tools                         |
        | triage source checkouts           | ~/.cache/hal-c2/source                        |
        | the WSL server tree               | ~/.cache/hal-c2/wsl-server-tree               |

    @desktop @backlog-desktop
    Scenario Outline: The desktop app's control socket lives in the runtime directory
      Given <runtime>
      When the user starts the desktop app
      Then its control socket is in "<path>"

      Examples:
        | runtime                             | path                  |
        | XDG_RUNTIME_DIR is "/run/user/1000" | /run/user/1000/hal-c2 |
        | XDG_RUNTIME_DIR is not set          | ~/.local/state/hal-c2 |

    @desktop @backlog-desktop
    Scenario: The desktop app on Windows keeps its named pipe
      Given a Windows user
      When the user starts the desktop app
      Then its control channel is the same named pipe as before

    @tui
    Scenario Outline: The terminal client finds the user's shell in the config directory
      Given <setting>
      When the user runs "hal-c2 tui"
      Then the terminal client loads the user's shell from "<dir>"

      Examples:
        | setting                                  | dir                          |
        | no HAL-C2 home is configured             | ~/.config/hal-c2/shell/tui   |
        | XDG_CONFIG_HOME is "/xdg/config"         | /xdg/config/hal-c2/shell/tui |
        | HAL_C2_HOME is "/srv/hal-c2"             | /srv/hal-c2/config/shell/tui |
        | HAL_C2_TUI_SHELL_DIR is "/opt/tui-shell" | /opt/tui-shell               |

  Rule: Remote hosts and WSL follow the same rules

    # Blocked: needs "The first SSH launch installs the server on the host"
    # (connections/connection-modes.feature) first.
    @backlog @blocked @node
    Scenario Outline: A host reached over SSH keeps its launch state in its own state directory
      Given a remote host reached over SSH where <setting>
      When HAL-C2 launches a server on that host
      Then the launch state on that host is in "<path>"

      Examples:
        | setting                               | path                                |
        | XDG_STATE_HOME is not set             | ~/.local/state/hal-c2/ssh-launch    |
        | XDG_STATE_HOME is "/var/lib/me/state" | /var/lib/me/state/hal-c2/ssh-launch |

    @desktop @backlog-desktop
    Scenario Outline: A WSL distro keeps its runtime state in its own state directory
      Given a WSL distro where <setting>
      When the desktop app starts a server inside that distro
      Then the runtime state inside the distro is in "<path>"

      Examples:
        | setting                               | path                                 |
        | XDG_STATE_HOME is not set             | ~/.local/state/hal-c2/wsl-runtime    |
        | XDG_STATE_HOME is "/var/lib/me/state" | /var/lib/me/state/hal-c2/wsl-runtime |
