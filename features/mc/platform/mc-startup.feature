# Sources:
#   https://github.com/pingdotgg/t3code/pull/19715
#   https://github.com/pingdotgg/t3code/pull/7894
#   https://github.com/pingdotgg/t3code/pull/12199
#   https://github.com/pingdotgg/t3code/pull/11275
#   https://github.com/pingdotgg/t3code/pull/14263
#   https://github.com/pingdotgg/t3code/pull/20336
#   https://github.com/pingdotgg/t3code/pull/20446
#   https://github.com/pingdotgg/t3code/pull/19604
#   https://github.com/pingdotgg/t3code/pull/16102
#   https://github.com/pingdotgg/t3code/pull/19340
#   apps/server-ex/config/config.exs (the hal-c2-dev profile for a dev MC)
#   apps/server-ex/config/runtime.exs (HAL_C2_MC_HOME, HAL_C2_HOME, T3_HOME, T3CODE_HOME, HAL_C2_MC_PORT, HAL_C2_MC_HOST, HAL_C2_HOST)
#   apps/server-ex/README.md (Run, Release: where the MC keeps its state)
#   apps/server/src/cli/config.ts (HAL_C2_HOST)
#   apps/server-ex/lib/mix/tasks/hal_c2.server.ex, hal_c2.import.ex, hal_c2.bundle.ex
#   apps/server-ex/rel/env.sh.eex (RELEASE_DISTRIBUTION, cluster boot flags), rel/overlays/bin/hal-c2-data-dir (the release's home)
#   apps/server-ex/rel/hal-c2-mc.sh (the single-file MC)
#   apps/server-ex/rel/overlays/bin/hal-c2-service (restart loop on exit 75), lib/hal_c2/service.ex
#   apps/server-ex/lib/hal_c2/desktop.ex (HAL_C2_BOOTSTRAP_STDIN), acp.ex (HAL_C2_NODE_COMMAND)
#   apps/server-ex/lib/hal_c2/web.ex (access-token), environment.ex (environment-id, HAL_C2_LABEL, descriptor)
#   apps/server-ex/lib/hal_c2/runtime_record.ex (server-runtime.json)
#   apps/server-ex/lib/hal_c2/home_lock.ex, application.ex (one MC per home; exit 73)
#   apps/server/src/serverRuntimeState.ts (the record's fields, as the Node server writes them)
#   apps/server/src/auth/ServerSecretStore.ts (owner-only secrets, reuse, failures propagate)
#   apps/server/src/os-jank.ts, apps/server/src/pathExpansion.ts (PATH and HOME hydration, ~ expansion)
#   apps/desktop/src/shell/DesktopShellEnvironment.ts (usual Windows tool folders, SSH agent, session bus, UTF-8 locale)
#   apps/server-ex/lib/hal_c2/import/v2.ex
#   packages/contracts/src/desktopBootstrap.ts
#   apps/server/src/bootstrap.ts (no input, undecodable line, one second wait for the envelope)
#   packages/contracts/src/environment.ts (ExecutionEnvironmentDescriptor)
#   docs/user/remote-access.md (hal-c2 serve, hal-c2 serve --host)
#   docs/user/background-service.md (service install, status, removal)
#   docs/user/install.md (Coming from T3 Code)
#   docs/internals/glossary.md (HAL-C2 home)
#   docs/internals/remote.md (environment identity survives restarts and address changes)
#   docs/operations/development.md (state and ports)
#   https://github.com/pingdotgg/t3code/pull/15795
#   https://github.com/pingdotgg/t3code/pull/22559

Feature: Starting the MC
  An MC is one Elixir release that keeps its files in the user's XDG directories, or under
  one root when it is given one. It starts from a checkout for development, from a release
  for everyone else, as a background service, or as the desktop app's own server. Where each
  file lives is in storage-layout.feature; moving in from "~/.t3" or "~/.hal-c2" is in
  storage-migration.feature.

  @mc
  Scenario: Starting an MC from a checkout prints its client URL
    When a developer starts the MC from a checkout
    Then it prints a WebSocket URL on loopback with the MC's own access token
    And it says how to pair a client, since that token is not a pairing code
    And a client can connect with that URL

  # Upstream #20446: the startup URL carries a token, so it is printed, never logged or traced.
  @backlog @mc @priority-high
  Scenario: The URL the MC prints with its token never reaches its logs
    When a developer starts the MC from a checkout
    Then the URL with its token is printed to the terminal
    And neither the MC's log files nor its traces hold the token

  # Upstream #20446: the URL now prints at every log level, as it was dropped at warn and error.
  @backlog @mc @priority-low
  Scenario: The MC prints its client URL whatever the log level
    Given the MC's log level is "error"
    When a developer starts the MC from a checkout
    Then it still prints its client URL

  @mc
  Scenario: An MC run from a checkout listens on port 3780 by default
    Given no port is configured
    When the MC starts
    Then it serves clients on port 3780

  @mc
  Scenario: A release MC listens on port 3790, beside one run from a checkout
    Given no port is configured for a release
    When the MC starts
    Then it serves clients on port 3790

  @mc
  Scenario: A release MC listens for cluster members on its own port
    Given no port is configured for a release
    When the MC starts
    Then it listens for cluster members on port 4380, not on 4370 as one run from a checkout does

  @mc
  Scenario: The port comes from the environment
    Given HAL_C2_MC_PORT is 4100 and HAL_C2_HOME is "/srv/hal-c2"
    When the MC starts
    Then it serves clients on port 4100

  @mc
  Scenario: HAL_C2_HOME is the root of the MC's files
    Given HAL_C2_HOME is "/srv/hal-c2"
    When the MC starts
    Then its settings are in "/srv/hal-c2/config/elixir"
    And its database, secrets and worktrees are in "/srv/hal-c2/data/elixir"
    And its logs are in "/srv/hal-c2/state/elixir/logs"
    And its downloaded tools are in "/srv/hal-c2/cache/elixir/tools"

  # T3CODE_HOME and T3_HOME no longer name a home. They only say where to migrate from
  # (storage-migration.feature), and the MC then keeps its files in the XDG directories.
  @dropped @mc
  Scenario: The home directory's name from before the rename still works
    Given the home directory is set with its name from before the rename, T3CODE_HOME="/srv/t3"
    When the MC starts
    Then its database, logs and worktrees live under "/srv/t3/elixir"

  @mc
  Scenario Outline: A dev MC keeps its state in the development profile, from any checkout
    Given no home directory is configured
    When a developer starts the MC from <checkout>
    Then its database, secrets and worktrees are in "~/.local/share/hal-c2-dev/elixir"
    And its logs are in "~/.local/state/hal-c2-dev/elixir/logs"
    And nothing is written to the user's XDG directories

    Examples:
      | checkout              |
      | the main checkout     |
      | a linked git worktree |

  @mc
  Scenario: A dev MC ignores HAL_C2_HOME
    Given HAL_C2_HOME is "/srv/hal-c2" in the developer's shell
    When a developer starts the MC from a linked git worktree
    Then its database is in "~/.local/share/hal-c2-dev/elixir"
    And nothing is written under "/srv/hal-c2"

  @mc
  Scenario: A release keeps its state in the user's XDG directories
    Given no home directory is configured
    When a user starts the MC from a release
    Then its settings are in "~/.config/hal-c2/elixir"
    And its database, secrets and worktrees are in "~/.local/share/hal-c2/elixir"
    And its logs are in "~/.local/state/hal-c2/elixir/logs"
    And its downloaded tools are in "~/.cache/hal-c2/elixir/tools"

  @mc
  Scenario: A release never keeps its state in the old HAL-C2 home
    Given no home directory is configured
    And the user's home has a "~/.hal-c2/elixir" directory
    When a user starts the MC from a release
    Then its database is in "~/.local/share/hal-c2/elixir"
    And nothing is written under "~/.hal-c2"

  # An install from before the rename is copied once into the XDG directories
  # (storage-migration.feature) and never used in place.
  @dropped @mc
  Scenario: A release keeps using the state an install from before the rename left
    Given no home directory is configured
    And the user's home holds the MC state of an install from before the rename
    When a user starts the MC from a release
    Then its state lives in "~/.t3/elixir"

  @mc
  Scenario: The MC binds to loopback unless it was told otherwise
    When the MC starts from a checkout or a release
    Then only clients on the same machine can reach it

  @mc
  Scenario: The bind address comes from the environment
    Given the bind host is set to "100.64.0.7" in the environment
    When the MC starts
    Then it serves clients on "100.64.0.7"

  @mc
  Scenario: A user starts the MC on a network address for LAN pairing
    When a user starts the MC with a LAN or tailnet host address
    Then clients on that network can reach it
    And its pairing links use that address

  @mc
  Scenario: The MC writes its own access token with owner-only permissions
    When the MC starts for the first time
    Then it writes an access token file readable only by its owner
    And local tools connect with that token

  @backlog @mc @priority-high
  Scenario: The MC's secrets are kept readable by its owner only
    When the MC creates a secret it keeps on disk
    Then the secrets directory and the secret's file are not readable by other users

  # Upstream #22559: a second creator racing the first read an empty secret; it now waits for
  # the winner's whole secret.
  @backlog @mc
  Scenario: A secret that already exists is reused, never regenerated
    Given the MC already stored a secret
    When the MC needs that secret again, or two parts of it need it at once
    Then every one of them gets the same stored secret

  @backlog @mc
  Scenario: A secret that cannot be written stops what needed it
    Given the MC cannot write its secrets directory
    When it needs to create a secret
    Then the step that needed it fails with the reason
    And the MC does not carry on as if the secret existed

  @mc
  Scenario: A running MC records where local tools can find it
    When the MC is serving clients
    Then its state directory holds a runtime record naming its process, port, origin and start time
    And that origin serves the MC's environment descriptor

  @mc
  Scenario: An MC that stops removes its runtime record
    Given the MC is serving clients
    When the MC stops
    Then its state directory holds no runtime record

  @backlog @mc
  Scenario: The runtime record says when the background service supervises the MC
    Given the MC runs under the background service
    When a local tool reads its runtime record
    Then the record says the service manages it
    And an MC started by hand is not marked as service-managed

  # Upstream #14263: an MC started from a terminal of a service-run MC runs as one started by hand.
  @backlog @mc @priority-low
  Scenario: An MC started from a terminal of a service-run MC runs as one started by hand
    Given the MC runs under the background service
    When the user starts another MC from one of its terminals
    Then the new MC starts as one started by hand
    And it is not refused for the service's launch details

  @backlog @mc
  Scenario: A runtime record left by a process that is gone is ignored
    Given a runtime record whose process no longer exists
    When a local tool looks for a running MC
    Then it does not treat that MC as running

  # Upstream #20336: a stale runtime record that names the starting MC's own process does not block it.
  @backlog @mc
  Scenario: A runtime record naming the MC's own process does not stop it starting
    Given the MC stopped uncleanly and left its runtime record
    And the MC starts again under the same process id
    When it checks for a running MC
    Then it starts and replaces the record
    And a record naming another live process still stops the start

  @backlog @mc
  Scenario: A runtime record that cannot be read fails loudly instead of looking absent
    Given a runtime record that is damaged
    When a local tool reads it
    Then the tool is told the record is unreadable
    And it is not told that no MC is running

  @mc
  Scenario: The environment id survives restarts
    Given the MC started once and recorded its environment id
    When the MC restarts on another port
    Then it reports the same environment id

  @mc
  Scenario: The environment label defaults to the host name
    Given no label is configured
    When a client reads the MC's environment descriptor
    Then the label is the machine's host name

  @mc
  Scenario: A configured label names the environment
    Given HAL_C2_LABEL is "Build box"
    When a client reads the MC's environment descriptor
    Then the label is "Build box"

  @mc
  Scenario: The environment descriptor says what the MC is
    When a client reads the MC's environment descriptor
    Then it names the environment id, label, platform and server version
    And it declares orchestration protocol version 3
    And it lists the MC's capabilities

  @backlog @mc @priority-high
  Scenario: An MC started with a minimal environment finds the tools on the user's search path
    Given the MC is started by a service manager or a desktop launcher with a short PATH
    When the MC starts
    Then the MC adds the folders the user's login shell would have on its PATH
    And provider and editor commands installed there can be started

  @backlog @mc
  Scenario: Folders the MC was started with stay on its search path
    Given the MC is started with a PATH that names a folder the login shell does not
    When the MC starts
    Then that folder is still searched
    And the folders from the login shell are searched as well

  # Upstream #7894: Nushell rejected the POSIX login-shell probe, so its PATH was missed.
  @backlog @mc
  Scenario: The search path comes from a Nushell login shell too
    Given the user's login shell is Nushell and its configuration adds "~/.cargo/bin" to the PATH
    When the MC starts with a short PATH
    Then "~/.cargo/bin" with the home folder filled in is on the MC's search path
    And a variable the Nushell configuration does not set does not stop the others being read

  # Upstream #19340: the login shell's PATH also brings mise's record of what it added, so wrappers no longer loop
  @backlog @mc
  Scenario: Provider commands behind a mise wrapper start as they do in a terminal
    Given the user's "claude" and "codex" are wrappers that run the real tool through mise
    And the user's login shell activates mise
    When the MC takes its PATH from the login shell
    Then it also takes mise's record of the folders mise added
    And Claude and Codex answer their status checks instead of timing out

  # Upstream #19604: CA trust variables come from the login shell
  @backlog @mc
  Scenario Outline: Certificate settings from the login shell reach the commands the MC starts
    Given the MC is started by a desktop launcher without "<variable>"
    And the user's login shell exports "<variable>"
    When the MC starts a provider's update command
    Then the command sees "<variable>" as the login shell sets it
    But a "<variable>" the MC was started with is kept

    Examples:
      | variable            |
      | SSL_CERT_FILE       |
      | SSL_CERT_DIR        |
      | NODE_EXTRA_CA_CERTS |

  @backlog @mc
  Scenario: A login shell that cannot be read does not stop the MC
    Given the user's login shell fails or does not answer when the MC asks for its PATH
    When the MC starts
    Then the MC starts with the PATH it was given
    And the failure is written to the log

  # Upstream #11275: the login shell probe stopped on job control and held up startup past its timeout.
  @backlog @mc @priority-low
  Scenario: A login shell that wants the terminal does not hold up the MC
    Given the MC was started from a terminal another program is in the foreground of
    And the user's shell reads its PATH only when it runs interactively
    When the MC starts
    Then the MC starts with the PATH from the user's interactive login shell
    And the shell's question for input or the terminal is answered as end of input

  @backlog @mc @priority-low
  Scenario: On macOS a user's PATH is read from the login session when the shell gives none
    Given the MC runs on macOS and the login shell gives no PATH
    When the MC starts
    Then the MC takes the PATH of the user's login session

  @backlog @mc @priority-low
  Scenario: On Windows the MC repairs a stale environment from the user's settings
    Given the MC runs on Windows with an environment that predates the user's latest settings
    When the MC starts
    Then the MC uses the user's current PATH and variables
    And a failure to read them is written to the log without stopping the MC

  # Legacy: apps/desktop/src/shell/DesktopShellEnvironment.ts (installWindowsEnvironment, knownWindowsCliDirs)
  @backlog @mc @priority-low
  Scenario: On Windows the places command line tools are usually installed are searched
    Given the MC runs on Windows and the user's PATH does not name where npm, Node, Volta, pnpm, bun or scoop put commands
    When the MC starts
    Then those usual folders under the user's profile are searched as well
    And a folder that is already on the PATH is not listed twice

  # Legacy: apps/desktop/src/shell/DesktopShellEnvironment.ts (installPosixEnvironment)
  @backlog @mc
  Scenario: An MC started from a desktop launcher finds the user's SSH agent
    Given the MC is started without an SSH agent socket
    And the user's login shell has one
    When the MC starts
    Then SSH connections the MC makes use that agent
    And an agent socket the MC was given is kept

  @backlog @mc
  Scenario: An MC started from a desktop launcher on Linux finds the user's session bus
    Given the MC runs on Linux without a session bus address
    And the user's runtime folder holds a session bus
    When the MC starts
    Then the MC uses that session bus

  @backlog @mc @priority-low
  Scenario: Agents started by an MC on macOS without a locale write UTF-8
    Given the MC runs on macOS started by a launcher that sets no locale
    And the user's login shell has none either
    When an agent produces text with non-ASCII characters
    Then the text is decoded as UTF-8

  @backlog @mc @priority-low
  Scenario: A locale the MC was given is not mixed with the login shell's
    Given the MC runs on macOS with one locale variable set
    When the MC starts
    Then the locale variables the MC was given are kept as they are

  @backlog @mc
  Scenario: An MC started without a HOME finds the user's home folder
    Given the MC is started by a service manager that sets no HOME
    When the MC starts
    Then the MC uses the home folder of the account it runs as
    And a HOME it was given is kept

  @backlog @mc
  Scenario: A leading tilde in a configured folder means the user's home folder
    Given a folder setting or flag is written as "~/work/hal-c2"
    When the MC reads it
    Then the folder is the user's home folder followed by "work/hal-c2"
    But "~someone" is not expanded to another user's home

  @mc
  Scenario: A release runs as a background service that restarts into upgrades
    Given the MC runs under the service wrapper
    When the MC exits asking for a restart
    Then the wrapper starts the MC again
    And any other exit stops the wrapper

  @mc
  Scenario: Stopping the background service lets the MC shut down
    Given the MC is running under the service wrapper
    When the service manager stops the wrapper
    Then the MC is told to stop and the wrapper waits for it

  # Two MCs on one home share its database and its cluster name: a member's connection
  # flips between them and each undoes the other's work. The desktop app can start its
  # MC at login before the background service's MC has said where it listens.
  # Upstream #16102: one owner of the state directory, a second server refuses to start
  # Upstream #19715: a server is refused a home an older background service still runs on.
  @mc
  Scenario: A second MC on the same files stops before it opens them
    Given an MC holds its HAL-C2 home
    When another MC starts on that home
    Then it is refused the home

  # Upstream #16102: one owner of the state directory, the service launcher does not restart-loop on refusal
  @mc
  Scenario: The background service waits for the MC that holds its files
    Given an MC holds its HAL-C2 home
    When the background service starts an MC on that home
    Then the service's MC waits without opening the files
    And it takes the home once the other MC stops

  # Upstream #16102: the ownership lock is released when the process exits, even killed
  @mc
  Scenario: An MC that was killed leaves its home free
    Given an MC held its HAL-C2 home and was killed
    When another MC starts on that home
    Then it takes the home

  @mc
  Scenario: A user installs the MC as a background service with one command
    When a user asks to install the background service
    Then the MC is registered with the system's service manager
    And it starts on login
    And the user can see its status and remove it again

  # Upstream #12199: a service install whose start failed looked current to the next install; it
  # now stays marked as needing repair until a start succeeds.
  @mc @backlog @priority-low
  Scenario: A service install that failed to start is not taken as current
    Given installing the background service wrote the new version but the service manager could not start it
    When a user asks to install the background service again
    Then the service status says it needs repair
    And the install starts it again

  @mc
  Scenario: A user starts the MC from one downloaded file without installing Elixir
    Given the single-file MC of a release
    When a user runs it with "--flag"
    Then the release and its runtime are unpacked in the MC's data directory
    And the service wrapper starts the release with "--flag"

  @mc
  Scenario: Running the single file again starts the version the MC upgraded to
    Given a user ran the single-file MC of a release
    And the MC has since upgraded itself to "9.9.9"
    When a user runs it with "--flag"
    Then the service wrapper starts "9.9.9" with "--flag"
    And the installed release is left as it was

  @mc
  Scenario: An install cut off before it finished runs again
    Given a user ran the single-file MC of a release
    And the install was cut off before it named the release to start
    When a user runs it with "--flag"
    Then the release and its runtime are unpacked in the MC's data directory
    And the service wrapper starts the release with "--flag"

  @mc
  Scenario: The single file of another version moves the MC to it
    Given a user ran the single-file MC of a release
    When a user runs the single-file MC of "9.9.9"
    Then the service wrapper starts "9.9.9" with ""
    And the versions installed before are kept

  @mc
  Scenario: A release bundle is packaged for one platform with a checksum
    When a maintainer builds a release bundle
    Then it writes one archive named for the version and platform
    And an executable single-file MC named the same without the extension
    And a SHA-256 file beside each

  @mc
  Scenario: The release carries the Cursor sidecar
    Given the machine has Node 22 or newer
    When the MC needs the Cursor provider
    Then it runs the sidecar shipped inside the release

  @mc
  Scenario: The desktop app starts the MC without putting its secret on the command line
    Given the desktop app launches the MC in bootstrap mode
    When it writes the port, host, HAL-C2 home and bootstrap token as one line on standard input
    Then the MC listens on that host and port
    And the token never appears in the process arguments or environment

  @backlog @mc
  Scenario: A start with no bootstrap input starts the MC normally
    Given nothing writes a bootstrap line to the MC's standard input
    When the MC starts
    Then it starts from its own configuration without waiting on the desktop app

  @backlog @mc
  Scenario: A bootstrap line that cannot be understood stops the start
    Given the desktop app launches the MC in bootstrap mode
    When it writes a line that is not a valid bootstrap
    Then the MC stops saying the bootstrap could not be decoded

  @mc
  Scenario: The HAL-C2 home the desktop app names is the root of the MC's files
    Given the desktop app launches the MC in bootstrap mode with the HAL-C2 home "/tmp/sandbox"
    When the MC starts
    Then its database is in "/tmp/sandbox/data/elixir"
    And its logs are in "/tmp/sandbox/state/elixir/logs"

  @mc
  Scenario: A desktop app that names no HAL-C2 home leaves the MC on the XDG directories
    Given the desktop app launches the MC in bootstrap mode without a HAL-C2 home
    When the MC starts
    Then its database is in "~/.local/share/hal-c2/elixir"

  # The Electron desktop app that named its binary is gone; the Qt desktop starts the MC with Node.
  @mc @dropped
  Scenario: The desktop app's Electron runs the MC's JavaScript sidecars
    Given the desktop app names its Electron binary for the MC
    When the MC starts a JavaScript sidecar
    Then it runs it with that binary in Node mode

  @mc
  Scenario: A Node server's history is imported into an MC
    Given a consistent snapshot of a TypeScript server's database
    When an operator imports it into the MC's home
    Then every thread stream is copied into the MC's store
    And the import reports how many streams and events it moved

  @mc
  Scenario: Importing without a source path explains the usage
    When an operator runs the import with no source
    Then it refuses with the expected usage

  @mc
  Scenario: A release boots ready to cluster
    When the release starts
    Then it boots with TLS distribution whose options are in the MC's data directory
    And asking the release for named distribution leaves the cluster flags out

  # The TypeScript server's --home-dir, --port and --mode flags. An MC reads HAL_C2_HOME and
  # HAL_C2_MC_PORT and has one mode; the desktop bootstrap covers the desktop case.
  @dropped @mc
  Scenario: The server takes its home and mode as command-line flags
    When a user starts the server with a home directory flag
    Then the server uses that home directory

  # Upstream #15795: unknown bare words are rejected instead of starting a server
  @backlog @mc @priority-low
  Scenario: The MC command line rejects an unknown word
    When the MC command is run with a bare word that names no command or existing directory
    Then it fails with help instead of starting a server

  # Upstream #15795: a launch checks the recorded live pid before creating directories or opening state
  @backlog @mc
  Scenario: A launch while a recorded MC is still alive is refused
    Given the home records an MC that is still alive
    When another MC is launched on that home
    Then it is refused before it creates directories or opens state
