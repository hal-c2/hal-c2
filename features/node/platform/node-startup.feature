# Sources:
#   apps/server-ex/config/config.exs (the hal-c2-dev profile for a dev node)
#   apps/server-ex/config/runtime.exs (HAL_C2_NODE_HOME, HAL_C2_HOME, T3_HOME, T3CODE_HOME, HAL_C2_NODE_PORT, HAL_C2_NODE_HOST, HAL_C2_HOST)
#   apps/server-ex/README.md (Run, Release: where the node keeps its state)
#   apps/server/src/cli/config.ts (HAL_C2_HOST)
#   apps/server-ex/lib/mix/tasks/hal_c2.server.ex, hal_c2.import.ex, hal_c2.bundle.ex
#   apps/server-ex/rel/env.sh.eex (RELEASE_DISTRIBUTION, cluster boot flags), rel/overlays/bin/hal-c2-data-dir (the release's home)
#   apps/server-ex/rel/hal-c2-node.sh (the single-file node)
#   apps/server-ex/rel/overlays/bin/hal-c2-service (restart loop on exit 75), lib/hal_c2/service.ex
#   apps/server-ex/lib/hal_c2/desktop.ex (HAL_C2_BOOTSTRAP_STDIN), acp.ex (HAL_C2_NODE_COMMAND, HAL_C2_NODE_ELECTRON)
#   apps/server-ex/lib/hal_c2/web.ex (access-token), environment.ex (environment-id, HAL_C2_LABEL, descriptor)
#   apps/server-ex/lib/hal_c2/runtime_record.ex (server-runtime.json)
#   apps/server/src/serverRuntimeState.ts (the record's fields, as the Node server writes them)
#   apps/server-ex/lib/hal_c2/import/v2.ex
#   packages/contracts/src/desktopBootstrap.ts
#   packages/contracts/src/environment.ts (ExecutionEnvironmentDescriptor)
#   docs/user/remote-access.md (hal-c2 serve, hal-c2 serve --host)
#   docs/user/background-service.md (service install, status, removal)
#   docs/user/install.md (Coming from T3 Code)
#   docs/internals/glossary.md (HAL-C2 home)
#   docs/internals/remote.md (environment identity survives restarts and address changes)
#   docs/operations/development.md (state and ports)

Feature: Starting the node
  A node is one Elixir release that keeps its files in the user's XDG directories, or under
  one root when it is given one. It starts from a checkout for development, from a release
  for everyone else, as a background service, or as the desktop app's own server. Where each
  file lives is in storage-layout.feature; moving in from "~/.t3" or "~/.hal-c2" is in
  storage-migration.feature.

  @node
  Scenario: Starting a node from a checkout prints its client URL
    When a developer starts the node from a checkout
    Then it prints a WebSocket URL on loopback with the node's own access token
    And it says how to pair a client, since that token is not a pairing code
    And a client can connect with that URL

  @node
  Scenario: The node listens on port 3780 by default
    Given no port is configured
    When the node starts
    Then it serves clients on port 3780

  @node
  Scenario: The port comes from the environment
    Given HAL_C2_NODE_PORT is 4100 and HAL_C2_HOME is "/srv/hal-c2"
    When the node starts
    Then it serves clients on port 4100

  @node
  Scenario: HAL_C2_HOME is the root of the node's files
    Given HAL_C2_HOME is "/srv/hal-c2"
    When the node starts
    Then its settings are in "/srv/hal-c2/config/elixir"
    And its database, secrets and worktrees are in "/srv/hal-c2/data/elixir"
    And its logs are in "/srv/hal-c2/state/elixir/logs"
    And its downloaded tools are in "/srv/hal-c2/cache/elixir/tools"

  # T3CODE_HOME and T3_HOME no longer name a home. They only say where to migrate from
  # (storage-migration.feature), and the node then keeps its files in the XDG directories.
  @dropped @node
  Scenario: The home directory's name from before the rename still works
    Given the home directory is set with its name from before the rename, T3CODE_HOME="/srv/t3"
    When the node starts
    Then its database, logs and worktrees live under "/srv/t3/elixir"

  @node
  Scenario Outline: A dev node keeps its state in the development profile, from any checkout
    Given no home directory is configured
    When a developer starts the node from <checkout>
    Then its database, secrets and worktrees are in "~/.local/share/hal-c2-dev/elixir"
    And its logs are in "~/.local/state/hal-c2-dev/elixir/logs"
    And nothing is written to the user's XDG directories

    Examples:
      | checkout              |
      | the main checkout     |
      | a linked git worktree |

  @node
  Scenario: A dev node ignores HAL_C2_HOME
    Given HAL_C2_HOME is "/srv/hal-c2" in the developer's shell
    When a developer starts the node from a linked git worktree
    Then its database is in "~/.local/share/hal-c2-dev/elixir"
    And nothing is written under "/srv/hal-c2"

  @node
  Scenario: A release keeps its state in the user's XDG directories
    Given no home directory is configured
    When a user starts the node from a release
    Then its settings are in "~/.config/hal-c2/elixir"
    And its database, secrets and worktrees are in "~/.local/share/hal-c2/elixir"
    And its logs are in "~/.local/state/hal-c2/elixir/logs"
    And its downloaded tools are in "~/.cache/hal-c2/elixir/tools"

  @node
  Scenario: A release never keeps its state in the old HAL-C2 home
    Given no home directory is configured
    And the user's home has a "~/.hal-c2/elixir" directory
    When a user starts the node from a release
    Then its database is in "~/.local/share/hal-c2/elixir"
    And nothing is written under "~/.hal-c2"

  # An install from before the rename is copied once into the XDG directories
  # (storage-migration.feature) and never used in place.
  @dropped @node
  Scenario: A release keeps using the state an install from before the rename left
    Given no home directory is configured
    And the user's home holds the node state of an install from before the rename
    When a user starts the node from a release
    Then its state lives in "~/.t3/elixir"

  @node
  Scenario: The node binds to loopback unless it was told otherwise
    When the node starts from a checkout or a release
    Then only clients on the same machine can reach it

  @node
  Scenario: The bind address comes from the environment
    Given the bind host is set to "100.64.0.7" in the environment
    When the node starts
    Then it serves clients on "100.64.0.7"

  @node
  Scenario: A user starts the node on a network address for LAN pairing
    When a user starts the node with a LAN or tailnet host address
    Then clients on that network can reach it
    And its pairing links use that address

  @node
  Scenario: The node writes its own access token with owner-only permissions
    When the node starts for the first time
    Then it writes an access token file readable only by its owner
    And local tools connect with that token

  @node
  Scenario: A running node records where local tools can find it
    When the node is serving clients
    Then its state directory holds a runtime record naming its process, port, origin and start time
    And that origin serves the node's environment descriptor

  @node
  Scenario: A node that stops removes its runtime record
    Given the node is serving clients
    When the node stops
    Then its state directory holds no runtime record

  @node
  Scenario: The environment id survives restarts
    Given the node started once and recorded its environment id
    When the node restarts on another port
    Then it reports the same environment id

  @node
  Scenario: The environment label defaults to the host name
    Given no label is configured
    When a client reads the node's environment descriptor
    Then the label is the machine's host name

  @node
  Scenario: A configured label names the environment
    Given HAL_C2_LABEL is "Build box"
    When a client reads the node's environment descriptor
    Then the label is "Build box"

  @node
  Scenario: The environment descriptor says what the node is
    When a client reads the node's environment descriptor
    Then it names the environment id, label, platform and server version
    And it declares orchestration protocol version 3
    And it lists the node's capabilities

  @node
  Scenario: A release runs as a background service that restarts into upgrades
    Given the node runs under the service wrapper
    When the node exits asking for a restart
    Then the wrapper starts the node again
    And any other exit stops the wrapper

  @node
  Scenario: A user installs the node as a background service with one command
    When a user asks to install the background service
    Then the node is registered with the system's service manager
    And it starts on login
    And the user can see its status and remove it again

  @node
  Scenario: A user starts the node from one downloaded file without installing Elixir
    Given the single-file node of a release
    When a user runs it with "--flag"
    Then the release and its runtime are unpacked in the node's data directory
    And the service wrapper starts the release with "--flag"

  @node
  Scenario: Running the single file again starts the version the node upgraded to
    Given a user ran the single-file node of a release
    And the node has since upgraded itself to "9.9.9"
    When a user runs it with "--flag"
    Then the service wrapper starts "9.9.9" with "--flag"
    And the installed release is left as it was

  @node
  Scenario: The single file of another version moves the node to it
    Given a user ran the single-file node of a release
    When a user runs the single-file node of "9.9.9"
    Then the service wrapper starts "9.9.9" with ""
    And the versions installed before are kept

  @node
  Scenario: A release bundle is packaged for one platform with a checksum
    When a maintainer builds a release bundle
    Then it writes one archive named for the version and platform
    And an executable single-file node named the same without the extension
    And a SHA-256 file beside each

  @node
  Scenario: The release carries the Cursor sidecar
    Given the machine has Node 22 or newer
    When the node needs the Cursor provider
    Then it runs the sidecar shipped inside the release

  @node
  Scenario: The desktop app starts the node without putting its secret on the command line
    Given the desktop app launches the node in bootstrap mode
    When it writes the port, host, HAL-C2 home and bootstrap token as one line on standard input
    Then the node listens on that host and port
    And the token never appears in the process arguments or environment

  @node
  Scenario: The HAL-C2 home the desktop app names is the root of the node's files
    Given the desktop app launches the node in bootstrap mode with the HAL-C2 home "/tmp/sandbox"
    When the node starts
    Then its database is in "/tmp/sandbox/data/elixir"
    And its logs are in "/tmp/sandbox/state/elixir/logs"

  @node
  Scenario: A desktop app that names no HAL-C2 home leaves the node on the XDG directories
    Given the desktop app launches the node in bootstrap mode without a HAL-C2 home
    When the node starts
    Then its database is in "~/.local/share/hal-c2/elixir"

  @node
  Scenario: The desktop app's Electron runs the node's JavaScript sidecars
    Given the desktop app names its Electron binary for the node
    When the node starts a JavaScript sidecar
    Then it runs it with that binary in Node mode

  @node
  Scenario: A Node server's history is imported into a node
    Given a consistent snapshot of a TypeScript server's database
    When an operator imports it into the node's home
    Then every thread stream is copied into the node's store
    And the import reports how many streams and events it moved

  @node
  Scenario: Importing without a source path explains the usage
    When an operator runs the import with no source
    Then it refuses with the expected usage

  @node
  Scenario: A release boots ready to cluster
    When the release starts
    Then it boots with TLS distribution whose options are in the node's data directory
    And asking the release for named distribution leaves the cluster flags out

  # The TypeScript server's --home-dir, --port and --mode flags. A node reads HAL_C2_HOME and
  # HAL_C2_NODE_PORT and has one mode; the desktop bootstrap covers the desktop case.
  @dropped @node
  Scenario: The server takes its home and mode as command-line flags
    When a user starts the server with a home directory flag
    Then the server uses that home directory
