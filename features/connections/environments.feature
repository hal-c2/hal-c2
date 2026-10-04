# Sources:
#   docs/user/remote-access.md (Load balancing, Local environment off)
#   docs/user/install.md (Windows Subsystem for Linux)
#   docs/internals/connection-runtime.md (saved environments, registry)
#   apps/server-ex/lib/hal_c2/environment.ex (descriptor, label, environmentIcon capability, platform.machine)
#   apps/server-ex/lib/hal_c2/environment/machine.ex
#   packages/contracts/src/environment.ts (ENVIRONMENT_MACHINE_KINDS, environmentIcon capability)
#   packages/contracts/src/settings.ts (environmentIcon, loadBalancingEnabled, loadBalancingWeights)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (environment list, Primary environment,
#     Remove from this device, WSL backend, "The environment is saved and will reconnect on app startup.")
#   apps/web/src/components/settings/EnvironmentRow.tsx (This machine, HAL-C2 Connect, Remote link, SSH)
#   apps/web/src/components/settings/EnvironmentIconPicker.tsx
#   apps/web/src/components/settings/LoadBalancingSettings.tsx
#   apps/web/src/components/settings/LocalEnvironmentSetting.tsx
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

  @desktop @mobile @backlog-mobile
  Scenario: A removed environment can be added back by pairing again
    Given the user removed an environment from this device
    When the user pairs with it again
    Then it returns to the list with its threads

  @desktop @mobile @backlog-mobile
  Scenario: A saved environment reconnects when the app starts
    Given a saved environment that was offline
    When the app starts
    Then the client reconnects to it without pairing again

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

  @desktop
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
