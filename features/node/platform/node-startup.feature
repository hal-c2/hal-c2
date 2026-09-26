# Sources:
#   apps/server-ex/config/runtime.exs (HAL_C2_NODE_HOME, HAL_C2_HOME, HAL_C2_NODE_PORT, HAL_C2_NODE_HOST, HAL_C2_HOST)
#   apps/server/src/cli/config.ts (HAL_C2_HOST)
#   apps/server-ex/lib/mix/tasks/hal_c2.server.ex, hal_c2.import.ex, hal_c2.bundle.ex
#   apps/server-ex/rel/env.sh.eex (RELEASE_DISTRIBUTION, cluster vm.args)
#   apps/server-ex/rel/overlays/bin/hal-c2-service (restart loop on exit 75), lib/hal_c2/service.ex
#   apps/server-ex/lib/hal_c2/desktop.ex (HAL_C2_BOOTSTRAP_STDIN), acp.ex (HAL_C2_NODE_COMMAND, HAL_C2_NODE_ELECTRON)
#   apps/server-ex/lib/hal_c2/web.ex (access-token), environment.ex (environment-id, HAL_C2_LABEL, descriptor)
#   apps/server-ex/lib/hal_c2/import/v2.ex
#   packages/contracts/src/desktopBootstrap.ts
#   packages/contracts/src/environment.ts (ExecutionEnvironmentDescriptor)
#   docs/user/remote-access.md (hal-c2 serve, hal-c2 serve --host)
#   docs/user/background-service.md (service install, status, removal)
#   docs/internals/remote.md (environment identity survives restarts and address changes)
#   docs/operations/development.md (state and ports)

Feature: Starting the node
  A node is one Elixir release that owns a HAL-C2 home directory. It starts from a checkout
  for development, from a release for everyone else, as a background service, or as the
  desktop app's own server.

  @node
  Scenario: Starting a node from a checkout prints its client URL
    When a developer starts the node from a checkout
    Then it prints a WebSocket URL on loopback with the node's own access token
    And a client can connect with that URL

  @node
  Scenario: The node listens on port 3780 by default
    Given no port is configured
    When the node starts
    Then it serves clients on port 3780

  @node
  Scenario: The port and home directory come from the environment
    Given HAL_C2_NODE_PORT is 4100 and HAL_C2_HOME is "/srv/hal-c2"
    When the node starts
    Then it serves clients on port 4100
    And its database, logs and worktrees live under "/srv/hal-c2/elixir"

  @node
  Scenario: The home directory's name from before the rename still works
    Given the home directory is set with its name from before the rename, T3CODE_HOME="/srv/t3"
    When the node starts
    Then its database, logs and worktrees live under "/srv/t3/elixir"

  @node
  Scenario: A checkout keeps its state inside the checkout
    Given no home directory is configured
    When a developer starts the node from a checkout
    Then its state lives in the checkout's ".hal-c2/elixir" directory

  @node
  Scenario: A release keeps its state in the user's HAL-C2 home
    Given no home directory is configured
    When a user starts the node from a release
    Then its state lives in "~/.hal-c2/elixir"

  @node
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

  @backlog @node
  Scenario: A user starts the node from a published package without installing Elixir
    Given a machine with no Elixir or Erlang installed
    When the user runs the published start command
    Then a node starts with its bundled runtime
    And it prints a pairing link

  @node
  Scenario: A release bundle is packaged for one platform with a checksum
    When a maintainer builds a release bundle
    Then it writes one archive named for the version and platform
    And a SHA-256 file beside it

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
    And keeps its state under the "elixir" directory of that HAL-C2 home
    And the token never appears in the process arguments or environment

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
  Scenario: A node joins its cluster on boot when it has been made a member
    Given the home directory holds cluster boot arguments
    When the release starts
    Then it starts with cluster distribution over mutual TLS
    And without them it starts with distribution off

  # The TypeScript server's --home-dir, --port and --mode flags. A node reads HAL_C2_HOME and
  # HAL_C2_NODE_PORT and has one mode; the desktop bootstrap covers the desktop case.
  @dropped @node
  Scenario: The server takes its home and mode as command-line flags
    When a user starts the server with a home directory flag
    Then the server uses that home directory
