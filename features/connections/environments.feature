# Sources:
#   docs/user/remote-access.md (Load balancing, Local environment off)
#   docs/user/install.md (Windows Subsystem for Linux)
#   docs/internals/connection-runtime.md (saved environments, registry)
#   apps/server-ex/lib/hal_c2/environment.ex (descriptor, label, environmentIcon capability, platform.machine)
#   apps/server-ex/lib/hal_c2/environment/machine.ex
#   apps/server/src/environment/ServerEnvironmentLabel.ts (friendly machine name)
#   apps/server/src/environment/ServerEnvironmentMachine.ts (machine kind from hardware)
#   apps/server/src/environment/RemoteOpenTargets.ts (SSH names the MC advertises)
#   packages/contracts/src/environment.ts (ENVIRONMENT_MACHINE_KINDS, environmentIcon capability)
#   packages/contracts/src/settings.ts (environmentIcon, loadBalancingEnabled, loadBalancingWeights)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (environment list, Primary environment,
#     Remove from this device, WSL backend, "The environment is saved and will reconnect on app startup.")
#   apps/web/src/components/settings/EnvironmentRow.tsx (This machine, HAL-C2 Connect, Remote link, SSH)
#   apps/web/src/components/settings/EnvironmentIconPicker.tsx
#   apps/web/src/components/settings/LoadBalancingSettings.tsx
#   apps/desktop-qt/src/native/LoadBalancingController.cpp, qml/HalC2/Bricks/LoadBalancingGroup.qml
#   apps/web/src/components/settings/LocalEnvironmentSetting.tsx
#   apps/desktop/src/wsl/DesktopWslBackend.ts, DesktopWslEnvironment.ts (preflight failures, Windows fallback, connecting splash,
#     runtime install/verify/prune/invalidate, login-shell PATH, distro address)
#   apps/desktop/src/ipc/methods/window.ts (getLocalEnvironmentBootstraps lists a starting WSL backend as pending)
#   apps/desktop/src/app/DesktopConnectionCatalogStore.ts, settings/DesktopSavedEnvironments.ts (saved credentials need system secret storage)
#   apps/web/src/connection/platform.ts, desktopLocal.ts (local backends kept while the topology cannot be read)
#   apps/mobile/src/features/connection/ConnectionsRouteScreen.tsx, LocalEnvironmentList.tsx,
#     ConnectionEnvironmentRow.tsx, environmentSections.ts, CloudEnvironmentRows.tsx
#   apps/tui/src/features.backlog.test.ts (environment-connections)
#   Shared domain: connections/cluster.feature holds the MC cluster and its sidebar;
#   settings/connections.feature holds the desktop Connections page (remove, switch off, icon, WSL);
#   settings/local-environment.feature and settings/load-balancing.feature hold those controls;
#   mobile/pairing-and-environments.feature holds managing environments from a phone.

Feature: Managing environments on a client
  A client keeps a list of the environments it has paired with. Each shows its machine, label
  and how it is reached, and new threads can be spread across them.

  Background:
    Given a client paired with two environments

  @mc
  Scenario: An MC describes itself for the environment list
    When a client reads the MC's descriptor
    Then it names the environment id, label, platform and detected machine kind

  @backlog @mc
  Scenario Outline: An MC with no configured label names itself by the friendliest name its machine has
    Given no label is configured
    And the machine <has>
    When a client reads the MC's descriptor
    Then the label is <label>

    Examples:
      | has                                                 | label                            |
      | is a Mac with a computer name                       | the computer name                |
      | is a Linux machine with a pretty host name          | the pretty host name             |
      | is a Linux machine that only has a plain host name  | the host name                    |
      | has no host name at all                             | the name of the MC's working folder |

  @backlog @mc
  Scenario Outline: The machine kind is read from the hardware
    When a client reads the descriptor of an MC running on <machine>
    Then the detected machine kind is <kind>

    Examples:
      | machine                                    | kind       |
      | a Mac mini                                 | mac-mini   |
      | a Mac Studio                               | mac-studio |
      | a MacBook                                  | laptop     |
      | an iMac or a Mac Pro                       | desktop    |
      | a Linux machine with a laptop chassis      | laptop     |
      | a Linux machine with a server chassis      | server     |
      | a virtual machine of a cloud or hypervisor | cloud      |
      | Windows Subsystem for Linux                | linux      |
      | a machine that gives no hardware signal    | none, so clients draw a generic server |

  @backlog @mc
  Scenario Outline: The MC advertises the SSH names that reach it
    Given <situation>
    When a client asks the MC for its configuration
    Then the MC advertises <targets> for opening workspaces over SSH

    Examples:
      | situation                                                   | targets                                         |
      | no SSH server is listening on this machine                   | no SSH names                                    |
      | the SSH server listens only on IPv6 loopback                 | its names, because it is listening              |
      | Tailscale reports a MagicDNS name and the machine has a name | the tailnet name first, then the .local name    |
      | Tailscale is not available                                   | only the machine's .local name                  |

  @backlog @mc
  Scenario: A slow SSH name check does not stall the configuration
    Given finding the machine's SSH names takes longer than a client should wait
    When a client asks the MC for its configuration
    Then the configuration arrives without SSH names

  @mc
  Scenario: A chosen environment icon persists on the MC
    Given a paired administrator's client
    When it sets the environment icon to "mac-studio"
    And the MC restarts
    Then the MC's settings still name "mac-studio" as the environment icon

  @mc
  Scenario: Clearing the environment icon returns to the detected machine
    Given an environment icon was chosen
    When a client clears the environment icon
    Then the MC's settings name no icon
    And the descriptor still names the machine the MC detected

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: The user sees every saved environment and how it is reached
    When the user opens the list of environments
    Then each environment shows its label, its icon and whether it is this machine, a remote link, SSH or HAL-C2 Connect
    And each shows whether it is connected

  @backlog @desktop @mobile
  Scenario: A removed environment can be added back by pairing again
    Given the user removed an environment from this device
    When the user pairs with it again
    Then it returns to the list with its threads

  @backlog @desktop @mobile
  Scenario: A saved environment reconnects when the app starts
    Given a saved environment that was offline
    When the app starts
    Then the client reconnects to it without pairing again

  # Legacy: packages/client-runtime/src/platform/storageDocument.ts (disabledEnvironmentIds)
  @backlog @desktop @mobile
  Scenario: A switched-off environment is still off after the app restarts
    Given "Build box" is switched off
    When the app starts
    Then "Build box" is listed as switched off
    And the client does not connect to "Build box"

  # Legacy: packages/client-runtime/src/platform/storageDocument.ts (registerConnectionInCatalog keeps the flag)
  @backlog @desktop @mobile
  Scenario: Editing a switched-off environment leaves it switched off
    Given "Build box" is switched off
    When the user changes its name or address and saves
    Then "Build box" is listed with the change
    And it is still switched off

  # Legacy: packages/client-runtime/src/platform/storageDocument.ts (removeConnectionFromCatalog)
  @backlog @desktop @mobile
  Scenario: A switched-off environment that is removed and paired again starts switched on
    Given "Build box" is switched off
    When the user removes "Build box" and pairs with it again
    Then "Build box" is connected

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: The user switches the terminal client to another environment
    Given the terminal client knows a local and a remote environment
    When the user activates the remote environment
    Then the terminal client shows that environment's projects and threads

  # The TUI reaches only the server that launched it: the host has no environment
  # list, pairing or access management (`connection.environments` is that one server).
  @backlog @tui
  Scenario: An unreachable environment cannot be activated
    Given a known environment that is offline
    When the user tries to activate it
    Then the terminal client says it is unreachable
    And stays on the current environment

  @desktop @mobile @backlog-mobile
  Scenario Outline: The icon cannot be changed
    Given <situation>
    When the user tries to change the environment's icon
    Then the client says <reason>

    Examples:
      | situation                                        | reason                                                   |
      | the environment is not connected                 | connect to the environment to change its icon            |
      | the environment's server predates icons          | the server is too old to keep an icon and should update  |
      | the user's session cannot change settings        | this session cannot change the environment's settings    |

  @desktop
  Scenario: A preference saved by an older build snaps to the nearest choice
    Given an environment's saved load weight is 80
    When the user opens load balancing
    Then the environment shows "Prefer"

  @desktop
  Scenario: Turning load balancing off keeps the preferences
    Given load balancing is on with preferences set
    When the user turns load balancing off
    And turns it on again
    Then the earlier preferences are back

  # The MC holds the preferences it places threads by (settings/load-balancing.feature), so its clients share them.
  @dropped @desktop
  Scenario: Load preferences belong to each client
    Given two desktop clients paired with the same environments
    When the user sets a preference on one client
    Then the other client keeps its own preferences

  @backlog @mobile
  Scenario: Mobile keeps its manual environment choice
    Given load balancing is on in the desktop client
    When the user starts a thread on mobile
    Then mobile uses the environment the user chose

  @backlog @desktop
  Scenario: Choosing a WSL distro runs the local environment inside it
    Given the machine runs Windows with a WSL distro that has the provider CLIs installed
    When the user chooses that distro for the local environment
    Then HAL-C2 installs its own MC runtime in the distro without further steps
    And agents and projects run inside the distro with the provider CLIs installed there

  @backlog @desktop
  Scenario: The first launch after an app update prepares the distro again
    Given the local environment runs in a WSL distro
    When the app starts for the first time after an update
    Then the MC runtime in the distro is brought up to the app's version before it connects

  @backlog @desktop
  Scenario: The user switches the WSL distro
    Given the WSL backend runs
    When the user picks another distro and confirms
    Then the WSL backend restarts on that distro
    And sessions running on the old distro are interrupted

  @backlog @desktop
  Scenario: Windows runs when WSL is unavailable
    Given the user chose to run only WSL
    And WSL is unavailable
    When the app starts
    Then the Windows backend runs instead
    And the client says to turn WSL off to clear the preference

  # Legacy: apps/desktop/src/wsl/DesktopWslBackend.ts, apps/desktop/src/wsl/DesktopWslEnvironment.ts (preflight failures)
  @backlog @desktop
  Scenario: A WSL start that cannot be fixed falls back to Windows for good
    Given the user chose to run only WSL
    And the distro lacks something HAL-C2 cannot supply
    When the app starts
    Then the user is told "WSL backend couldn't start" with the reason
    And the Windows backend runs instead
    And the next start uses Windows too until the user turns WSL on again in the Connections settings

  @backlog @desktop
  Scenario: A WSL start that keeps failing for a passing reason falls back to Windows for this launch only
    Given the user chose to run only WSL
    And WSL answers too slowly or not at all for several attempts in a row
    When the app starts
    Then the user is told "WSL backend is still unavailable"
    And the Windows backend runs for this launch
    And the next start tries WSL again

  @backlog @desktop
  Scenario: A WSL backend that fails beside Windows leaves Windows running
    Given the user chose to run both Windows and WSL
    And the WSL backend cannot start
    When the app starts
    Then the Windows backend runs normally
    And the Connections settings say why the WSL backend could not start

  @backlog @desktop
  Scenario: A WSL backend that is still starting shows as connecting
    Given the user chose to run both Windows and WSL
    And the WSL backend is still starting
    When the user looks at the environments
    Then the WSL environment shows as connecting
    And no client tries to reach it until it is ready

  # Legacy: apps/web/src/connection/platform.ts, desktopLocal.ts (topology read failure vs empty topology)
  @backlog @desktop
  Scenario: A local backend stays listed while the app cannot read which backends are running
    Given the app reached the WSL backend beside the Windows one
    When the app cannot read which local backends are running
    Then the WSL environment stays listed while its last credential is still valid
    And an environment whose credential has run out is no longer shown as reachable

  @backlog @desktop
  Scenario: A local backend that stopped is removed once the app can read the list again
    Given the app reached the WSL backend beside the Windows one
    When the app reads which local backends are running and the WSL one is not among them
    Then the WSL environment is no longer listed

  @backlog @desktop
  Scenario: Starting only WSL shows that WSL is connecting
    Given the user chose to run only WSL
    When the app starts
    Then a small window says it is connecting to WSL until the main window opens
    And bringing the app forward while it waits shows that window again

  # Uncertain: the checks were about Node, build tools and node-pty in the distro; the MC's runtime needs differ.
  @backlog @desktop
  Scenario Outline: A distro that cannot run the MC says what is wrong
    Given the user chose a WSL distro that <problem>
    When the app prepares the WSL backend
    Then the user is told what is missing or wrong in that distro
    And the WSL backend does not start

    Examples:
      | problem                                                  |
      | lacks a tool HAL-C2 needs to run its runtime             |
      | has a runtime HAL-C2 cannot run on that architecture     |
      | runs out of disk space while the runtime is installed    |
      | takes too long to install the runtime                    |

  # Legacy: apps/desktop/src/wsl/DesktopWslEnvironment.ts (buildWslRuntimeInstallScript, sha256 identity)
  @backlog @desktop
  Scenario: A runtime installed in the distro is reused while it still runs
    Given the distro already holds the runtime for this version of the app
    When the app prepares the WSL backend
    Then the existing runtime is used without installing it again

  @backlog @desktop
  Scenario: A runtime that does not match its recorded checksum is not installed
    Given the runtime shipped with the app does not match the checksum recorded for it
    When the app prepares the WSL backend
    Then the runtime is not installed in the distro
    And the user is told the runtime does not match its checksum

  @backlog @desktop
  Scenario: A runtime that was changed after it was installed is installed again
    Given the runtime in the distro no longer matches what the app installed there
    When the app prepares the WSL backend
    Then the runtime is installed again from the app's copy

  @backlog @desktop
  Scenario: Two launches preparing the same distro do not interfere
    Given two backends are being prepared at the same time in one distro
    When both need the same runtime
    Then the runtime is installed once
    And neither launch sees a half-installed runtime

  @backlog @desktop
  Scenario: A runtime that fails its check at launch is installed again on the next start
    Given the runtime in the distro was installed but does not run on that distro
    When the app prepares the WSL backend
    Then the user is told why the runtime could not run
    And the next start installs the runtime again

  @backlog @desktop
  Scenario: Older runtimes in the distro are cleaned up but the previous one is kept
    Given the distro holds runtimes from several earlier versions of the app
    When the app prepares the WSL backend
    Then the runtime in use and the one before it are kept
    And older runtimes that no process uses are removed
    And a runtime that a running backend still uses is never removed

  @backlog @desktop
  Scenario: Agents in the distro find the provider CLIs the user's login shell finds
    Given a provider CLI is installed in the distro through a version manager
    When the app starts the WSL backend
    Then the backend runs with the folders the user's login shell in the distro puts on its path
    And the provider CLI is found by name

  @backlog @desktop
  Scenario: The WSL backend is reached at the distro's own address
    Given the WSL backend listens inside the distro
    When the app connects to it
    Then it connects at the distro's address rather than waiting for the machine's forwarding to the distro

  # Legacy: apps/desktop/src/backend/DesktopBackendConfiguration.ts (isLocalHostIpv4, getDistroIp)
  @backlog @desktop
  Scenario Outline: A distro that shares the machine's network is reached on this machine
    Given the WSL backend listens inside a distro <network>
    When the app connects to it
    Then it connects at <address>

    Examples:
      | network                                             | address                    |
      | that shares the Windows machine's network addresses | this machine's own address |
      | whose address cannot be read                        | this machine's own address |
      | that has its own address                            | the distro's address       |

  # Legacy: apps/desktop/src/backend/DesktopBackendConfiguration.ts (WSL_FORWARDED_ENV_NAMES)
  @backlog @desktop
  Scenario: Provider keys and telemetry headers set on Windows reach the WSL backend
    Given the Windows environment holds provider API keys and telemetry headers
    When the WSL backend starts
    Then the backend sees those values
    And values that are empty or not set are not passed on

  # Legacy: apps/desktop/src/backend/DesktopBackendConfiguration.ts (preflight distro match)
  @backlog @desktop
  Scenario Outline: The chosen distro is matched by name however it is capitalized
    Given the user chose the distro "<chosen>"
    And Windows lists the distro as "<listed>"
    When the WSL backend starts
    Then the backend runs in the listed distro

    Examples:
      | chosen | listed |
      | ubuntu | Ubuntu |
      | UBUNTU | Ubuntu |

  # Legacy: apps/desktop/src/wsl/DesktopWslBackend.ts (port allocation)
  @backlog @desktop
  Scenario: A WSL backend beside Windows that finds no free port is skipped
    Given the Windows backend and the WSL backend run side by side
    And no port is free for the WSL backend
    When the WSL backend starts
    Then the WSL backend is not started
    And the Windows backend keeps running

  # Legacy: apps/desktop/src/app/DesktopConnectionCatalogStore.ts, apps/desktop/src/settings/DesktopSavedEnvironments.ts
  # Uncertain: depends on how the Qt desktop stores secrets (see desktop/shell-host.feature, password store).
  @backlog @desktop
  Scenario: Saved credentials are not read while the system cannot protect them
    Given the user saved a remote environment with a credential
    And the system's secret storage is unavailable
    When the app starts
    Then the saved environment is not connected with a credential the system could not unlock
    And the user is asked to pair it again
