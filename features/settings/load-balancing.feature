# Sources:
#   packages/client-runtime/src/load-balancing.ts (chooseLoadBalancedEnvironment)
#   apps/web/src/components/settings/LoadBalancingSettings.tsx
#   apps/web/src/components/ChatView.tsx (balanced environment for new drafts)
#   apps/server-ex/lib/t3/rpc.ex (server.getHostResources)
#   packages/contracts/src/rpc.ts (server.getHostResources)
#   docs/user/remote-access.md (Balance new threads across machines: web and desktop only)

Feature: Load balancing new threads across machines
  With several machines connected, new threads in a shared project can start
  on whichever machine has the most room, weighted by the user's preference.
  Balancing is offered on desktop and in the terminal client; phones keep choosing the machine
  by hand.

  @node
  Scenario: A node reports its free resources
    When a client asks the node for its host resources
    Then the node answers with its CPU count, CPU use and free memory

  @backlog @desktop @tui
  Scenario: Load balancing is off by default
    Given two connected machines share project "api"
    When the user starts a new thread in "api"
    Then the thread starts on the machine the user picked

  @backlog @desktop @tui
  Scenario: A new thread starts on the machine with the most room
    Given load balancing is on
    And "laptop" is busy and "server" is idle
    When the user starts a new thread in "api"
    Then the thread starts on "server"

  @backlog @desktop @tui
  Scenario Outline: A machine is skipped when it cannot take work
    Given load balancing is on
    And "server" <state>
    When the user starts a new thread in "api"
    Then the thread does not start on "server"

    Examples:
      | state                                    |
      | is set to manual only                    |
      | reported its resources over 15s ago      |
      | is at 95% CPU                            |
      | has 5% of memory free                    |
      | does not have the chosen provider signed in |

  @backlog @desktop @tui
  Scenario: Preferring a machine sends it more new threads
    Given load balancing is on
    And the user prefers "server" and sets "laptop" to less often
    When both machines are equally idle
    Then new threads start on "server"

  @backlog @desktop @tui
  Scenario: A draft already tied to a machine is not moved
    Given load balancing is on
    And the user chose a branch for the new thread on "laptop"
    When the user sends the first message
    Then the thread starts on "laptop"

  @backlog @desktop @tui
  Scenario: Load balancing needs more than one machine
    Given only one machine is connected
    When the user opens connection settings
    Then load balancing is not offered

  @backlog @mobile
  Scenario: On a phone the user always chooses the machine for a new thread
    Given two connected machines share project "api"
    And load balancing is on for the user's desktop
    When the user starts a new thread in "api" on a phone
    Then the thread starts on the machine the user picked
    And load balancing is not offered on the phone
