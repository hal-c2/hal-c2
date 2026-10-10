# Sources:
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

  @backlog @mc
  Scenario: The MC's secrets are kept readable by its owner only
    When the MC creates a secret it keeps on disk
    Then the secrets directory and the secret's file are not readable by other users

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

  @backlog @mc
  Scenario: A runtime record left by a process that is gone is ignored
    Given a runtime record whose process no longer exists
    When a local tool looks for a running MC
    Then it does not treat that MC as running

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

  @backlog @mc
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

  @backlog @mc
  Scenario: A login shell that cannot be read does not stop the MC
    Given the user's login shell fails or does not answer when the MC asks for its PATH
    When the MC starts
    Then the MC starts with the PATH it was given
    And the failure is written to the log

  @backlog @mc
  Scenario: On macOS a user's PATH is read from the login session when the shell gives none
    Given the MC runs on macOS and the login shell gives no PATH
    When the MC starts
    Then the MC takes the PATH of the user's login session

  @backlog @mc
  Scenario: On Windows the MC repairs a stale environment from the user's settings
    Given the MC runs on Windows with an environment that predates the user's latest settings
    When the MC starts
    Then the MC uses the user's current PATH and variables
    And a failure to read them is written to the log without stopping the MC

  # Legacy: apps/desktop/src/shell/DesktopShellEnvironment.ts (installWindowsEnvironment, knownWindowsCliDirs)
  @backlog @mc
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

  @backlog @mc
  Scenario: Agents started by an MC on macOS without a locale write UTF-8
    Given the MC runs on macOS started by a launcher that sets no locale
    And the user's login shell has none either
    When an agent produces text with non-ASCII characters
    Then the text is decoded as UTF-8

  @backlog @mc
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

  @mc
  Scenario: A user installs the MC as a background service with one command
    When a user asks to install the background service
    Then the MC is registered with the system's service manager
    And it starts on login
    And the user can see its status and remove it again

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
