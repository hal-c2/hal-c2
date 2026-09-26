# Sources:
#   packages/shared/src/devHome.ts (the ~/.hal-c2 and ~/.t3 homes and T3CODE_HOME being replaced)
#   apps/server/src/config.ts (userdata and dev state dirs, caches, worktrees, runtime)
#   apps/server/src/cloud/bootService.ts (service units: HAL_C2_HOME lines in systemd units and launchd plists)
#   apps/server/src/serviceLauncher.ts (units from before the rename export T3CODE_HOME; the launcher required a home)
#   apps/server-ex/config/runtime.exs (T3_HOME, T3CODE_HOME)
#   apps/server-ex/rel/env.sh.eex (an install that only has ~/.t3/elixir)
#   apps/server-ex/lib/hal_c2/service.ex (service install, status, uninstall)
#   apps/server-ex/lib/hal_c2/store.ex (the node's database, legacy t3.sqlite)
#   apps/server-ex/README.md (Release: an install from before the rename)
#   docs/user/install.md (Coming from T3 Code)
#   docs/user/background-service.md (service install, status, uninstall)
#   docs/internals/glossary.md (HAL-C2 home)
#   docs/operations/development.md (never run against the live ~/.t3/userdata or ~/.hal-c2/userdata)

Feature: Moving in from T3 Code and the old HAL-C2 home
  A user coming from T3 Code has "~/.t3", and an early HAL-C2 user has "~/.hal-c2". The
  first time HAL-C2 starts with no data of its own, it copies what it needs from one of
  them into its XDG directories. It never moves, links or changes the old home, and it
  never reads it again. T3CODE_HOME and T3_HOME only say where that old home is.

  Below, "for the first time" means HAL-C2 starts with no data directory of its own.

  Background:
    Given a Linux user with no XDG variables and no HAL-C2 home configured

  Rule: Migration copies from one old home, first match wins

    @backlog @node
    Scenario Outline: The old home is chosen in a fixed order
      Given <homes>
      When HAL-C2 starts for the first time
      Then it copies from "<source>"
      And it reads nothing from the other old homes

      Examples:
        | homes                                                           | source    |
        | T3CODE_HOME is "/srv/t3" and "~/.hal-c2" and "~/.t3" both exist | /srv/t3   |
        | T3_HOME is "/srv/t3" and "~/.hal-c2" and "~/.t3" both exist     | /srv/t3   |
        | "~/.hal-c2" and "~/.t3" both exist                              | ~/.hal-c2 |
        | only "~/.t3" exists                                             | ~/.t3     |

    @backlog @node
    Scenario: A T3CODE_HOME that names a missing directory is skipped
      Given T3CODE_HOME is "/srv/gone", which does not exist
      And "~/.t3" exists
      When HAL-C2 starts for the first time
      Then it copies from "~/.t3"

    @backlog @node
    Scenario: T3CODE_HOME is never used as HAL-C2's home
      Given T3CODE_HOME is "/srv/t3"
      When HAL-C2 starts for the first time and the user creates a thread
      Then the thread is stored in "~/.local/share/hal-c2"
      And nothing is written under "/srv/t3"

    @backlog @node
    Scenario: With no old home HAL-C2 starts fresh
      Given there is no "~/.hal-c2", no "~/.t3" and no T3CODE_HOME or T3_HOME
      When HAL-C2 starts for the first time
      Then it starts with no threads or projects
      And no migration is recorded

    @backlog @node
    Scenario Outline: Each part of HAL-C2 copies from its own part of the old home
      Given "~/.t3" holds state for the installed app, a development server and the node
      When <what> starts for the first time
      Then it copies from "<source>"

      Examples:
        | what                 | source         |
        | the installed server | ~/.t3/userdata |
        | a development server | ~/.t3/dev      |
        | the node             | ~/.t3/elixir   |

  Rule: Migration copies what the user cannot get back, and nothing else

    Background:
      Given "~/.t3" is the old home

    @backlog @node
    Scenario Outline: The node's files land in the kind they belong to
      Given the old home holds "<old>"
      When the node starts for the first time
      Then a copy is at "<new>"

      Examples:
        | old                               | new                                               |
        | ~/.t3/elixir/settings.json        | ~/.config/hal-c2/elixir/settings.json             |
        | ~/.t3/elixir/keybindings.json     | ~/.config/hal-c2/elixir/keybindings.json          |
        | ~/.t3/elixir/themes               | ~/.config/hal-c2/elixir/themes                    |
        | ~/.t3/elixir/hal-c2.sqlite        | ~/.local/share/hal-c2/elixir/hal-c2.sqlite        |
        | ~/.t3/elixir/t3.sqlite            | ~/.local/share/hal-c2/elixir/hal-c2.sqlite        |
        | ~/.t3/elixir/environment-id       | ~/.local/share/hal-c2/elixir/environment-id       |
        | ~/.t3/elixir/access-token         | ~/.local/share/hal-c2/elixir/access-token         |
        | ~/.t3/elixir/secrets              | ~/.local/share/hal-c2/elixir/secrets              |
        | ~/.t3/elixir/attachments          | ~/.local/share/hal-c2/elixir/attachments          |
        | ~/.t3/elixir/provider-auth        | ~/.local/share/hal-c2/elixir/provider-auth        |
        | ~/.t3/elixir/plugins              | ~/.local/share/hal-c2/elixir/plugins              |
        | ~/.t3/elixir/cluster              | ~/.local/share/hal-c2/elixir/cluster              |
        | ~/.t3/elixir/scheduled-tasks.json | ~/.local/share/hal-c2/elixir/scheduled-tasks.json |
        | ~/.t3/elixir/logs                 | ~/.local/state/hal-c2/elixir/logs                 |

    @backlog @desktop
    Scenario Outline: The hosted server's and desktop app's files land in the kind they belong to
      Given the old home holds "<old>"
      When the user starts the desktop app for the first time
      Then a copy is at "<new>"

      Examples:
        | old                                    | new                                                 |
        | ~/.t3/userdata/settings.json           | ~/.config/hal-c2/settings.json                      |
        | ~/.t3/userdata/keybindings.json        | ~/.config/hal-c2/keybindings.json                   |
        | ~/.t3/userdata/desktop-settings.json   | ~/.config/hal-c2/desktop-settings.json              |
        | ~/.t3/shell/shell.qml                  | ~/.config/hal-c2/shell/shell.qml                    |
        | ~/.t3/shell/tui/shell.qml              | ~/.config/hal-c2/shell/tui/shell.qml                |
        | ~/.t3/userdata/statev2.sqlite          | ~/.local/share/hal-c2/statev2.sqlite                |
        | ~/.t3/userdata/state.sqlite            | ~/.local/share/hal-c2/state.sqlite                  |
        | ~/.t3/userdata/secrets                 | ~/.local/share/hal-c2/secrets                       |
        | ~/.t3/userdata/attachments             | ~/.local/share/hal-c2/attachments                   |
        | ~/.t3/userdata/environment-id          | ~/.local/share/hal-c2/environment-id                |
        | ~/.t3/userdata/saved-environments.json | ~/.local/share/hal-c2/saved-environments.json       |
        | ~/.t3/caches/acp-auth-claude.json      | ~/.local/share/hal-c2/acp-auth/acp-auth-claude.json |
        | ~/.t3/userdata/logs                    | ~/.local/state/hal-c2/logs                          |

    @backlog @node
    Scenario: A database is copied whole while T3 Code still has it open
      Given T3 Code is running against "~/.t3" and writing to its database
      When HAL-C2 copies the database
      Then the copy is a consistent snapshot that opens without repair
      And T3 Code keeps running undisturbed

    @backlog @node
    Scenario: A half-copied database is never at its final path
      Given HAL-C2 is copying the database from the old home
      When HAL-C2 looks for its database before the copy finishes
      Then there is no database at its final path yet

    @backlog @node
    Scenario Outline: What can be downloaded or rebuilt again is not copied
      Given the old home holds <what> at "<old>"
      When HAL-C2 starts for the first time
      Then nothing is copied from "<old>"

      Examples:
        | what                          | old                                |
        | cached provider status        | ~/.t3/caches/provider-status       |
        | cached pull request data      | ~/.t3/caches/pull-requests         |
        | the model manifest            | ~/.t3/userdata/model-manifest.json |
        | downloaded tools              | ~/.t3/tools                        |
        | installed server versions     | ~/.t3/runtime/versions             |
        | the desktop app's web profile | ~/.t3/userdata/shell-web           |
        | the node's download cache     | ~/.t3/elixir/cache                 |

    @backlog @node
    Scenario: Copied secrets stay private
      Given the old home holds secrets
      When HAL-C2 copies them
      Then the copied "secrets" directory is readable only by the user

    @backlog @node
    Scenario: Nothing in the new directories points back into the old home
      When HAL-C2 migrates from the old home
      Then no file or directory it created is a link into "~/.t3"

  Rule: Worktrees stay where they are

    Background:
      Given "~/.t3" is the old home
      And a thread in project "api" works in the worktree "~/.t3/worktrees/api/feature-login"

    @backlog @node
    Scenario: Existing worktrees are not copied
      When HAL-C2 migrates from the old home
      Then nothing is copied from "~/.t3/worktrees"

    @backlog @node
    Scenario: A migrated thread keeps working in its worktree
      Given HAL-C2 migrated from the old home
      When the user sends a message in that thread
      Then the agent works in "~/.t3/worktrees/api/feature-login"
      And the project's repository still lists that worktree

    @backlog @node
    Scenario: New worktrees are created in HAL-C2's data directory
      Given HAL-C2 migrated from the old home
      When the user starts a new thread in a new worktree of "api"
      Then the worktree is created under "~/.local/share/hal-c2/worktrees"

  Rule: Migration runs once and forgets the old home

    Background:
      Given "~/.t3" is the old home

    @backlog @node
    Scenario: A finished migration is recorded
      When HAL-C2 migrates from the old home
      Then "~/.local/state/hal-c2/migrated-from.json" names "~/.t3", when it ran and what it copied
      And HAL-C2 logs one line saying it migrated from "~/.t3"

    @backlog @node
    Scenario: A later change to the old home is not seen
      Given HAL-C2 migrated from the old home
      And the user then renamed a thread in T3 Code
      When HAL-C2 restarts
      Then the thread keeps its old name in HAL-C2

    @backlog @node
    Scenario: The old home is left exactly as it was
      When HAL-C2 migrates from the old home and runs for a while
      Then every file in "~/.t3" is byte-for-byte what it was before
      And no file was added to or removed from "~/.t3"

    @backlog @node
    Scenario Outline: Migration does not run when HAL-C2 already has data
      Given HAL-C2's data directory already holds "<file>"
      When <what> starts
      Then nothing is copied from the old home
      And the old home is not read

      Examples:
        | what                 | file                                       |
        | the installed server | ~/.local/share/hal-c2/environment-id       |
        | the installed server | ~/.local/share/hal-c2/statev2.sqlite       |
        | the node             | ~/.local/share/hal-c2/elixir/hal-c2.sqlite |

    @backlog @node
    Scenario: Migration does not run again after the user removes the data directory
      Given HAL-C2 migrated from the old home
      When the user deletes "~/.local/share/hal-c2" and HAL-C2 restarts
      Then it starts with no threads or projects
      And nothing is copied from the old home

    @backlog @node
    Scenario: Removing the migration record lets migration run again
      Given HAL-C2 migrated from the old home
      When the user deletes "~/.local/share/hal-c2" and "~/.local/state/hal-c2/migrated-from.json"
      And HAL-C2 restarts
      Then it copies from "~/.t3" again

    @backlog @node
    Scenario: HAL_C2_NO_MIGRATE starts fresh without reading the old home
      Given HAL_C2_NO_MIGRATE is "1"
      When HAL-C2 starts for the first time
      Then it starts with no threads or projects
      And the old home is not read

    @backlog @node
    Scenario: HAL-C2 started once with HAL_C2_NO_MIGRATE does not migrate later
      Given HAL-C2 started once with HAL_C2_NO_MIGRATE set to "1"
      When HAL-C2 restarts without it
      Then nothing is copied from the old home

  Rule: A failed migration never blocks startup

    Background:
      Given "~/.t3" is the old home

    @backlog @node
    Scenario Outline: A copy that fails leaves no half-migrated data
      Given <failure>
      When HAL-C2 starts for the first time
      Then HAL-C2 starts with no threads or projects
      And none of the old home's files are in its data directory
      And no unfinished copy is left beside the data directory
      And HAL-C2 warns that migrating from "~/.t3" failed and why
      And "~/.t3" is unchanged

      Examples:
        | failure                                    |
        | the disk fills up partway through the copy |
        | a file in the old home cannot be read      |
        | the old home's database is corrupt         |

    @backlog @node
    Scenario: A migration cut short by a crash runs again on the next start
      Given HAL-C2 was stopped partway through copying from the old home
      When HAL-C2 starts again
      Then it copies from "~/.t3" from the beginning
      And the unfinished copy is not used

  Rule: Background services installed before still work

    @backlog @node
    Scenario Outline: A service installed before is still recognised
      Given a <manager> service installed before, whose definition sets <variable>
      When the user runs "hal-c2 service status"
      Then the service is reported as installed
      And the user can remove it with "hal-c2 service uninstall"

      Examples:
        | manager | variable    |
        | systemd | T3CODE_HOME |
        | systemd | HALC2_HOME  |
        | systemd | HAL_C2_HOME |
        | launchd | T3CODE_HOME |
        | launchd | HALC2_HOME  |
        | launchd | HAL_C2_HOME |

    @backlog @node
    Scenario: A service installed by T3 Code migrates on its next start
      Given a service installed before whose definition sets T3CODE_HOME to "~/.t3"
      And HAL-C2's data directory does not exist yet
      When the service starts HAL-C2
      Then it copies from "~/.t3"
      And it runs from the XDG directories

    # Interpretation: services written before always named their home. A definition that
    # names an old home as HAL_C2_HOME or HALC2_HOME must not make HAL-C2 use it in place.
    @backlog @node
    Scenario Outline: A service that names an old home as its root migrates instead
      Given a service installed before whose definition sets <variable> to "<home>"
      When the service starts HAL-C2
      Then it copies from "<home>"
      And it runs from the XDG directories

      Examples:
        | variable    | home      |
        | HAL_C2_HOME | ~/.hal-c2 |
        | HALC2_HOME  | ~/.hal-c2 |
        | HAL_C2_HOME | ~/.t3     |

    @backlog @node
    Scenario: A new service relies on the XDG directories
      Given no HAL-C2 home is configured
      When the user runs "hal-c2 service install"
      Then the service definition names no HAL-C2 home
      And the service keeps its files in the XDG directories

    @backlog @node
    Scenario: A new service keeps a home the user chose
      Given HAL_C2_HOME is "/srv/hal-c2"
      When the user runs "hal-c2 service install"
      Then the service definition sets HAL_C2_HOME to "/srv/hal-c2"

    @backlog @node
    Scenario: Reinstalling a service from before rewrites it for the XDG directories
      Given a service installed before whose definition sets T3CODE_HOME
      And no HAL-C2 home is configured
      When the user runs "hal-c2 service install"
      Then the service definition names no HAL-C2 home and no T3CODE_HOME
