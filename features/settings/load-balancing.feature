# Sources:
#   packages/client-runtime/src/load-balancing.ts (chooseLoadBalancedEnvironment)
#   apps/web/src/components/settings/LoadBalancingSettings.tsx
#   apps/web/src/components/settings/LoadBalancingSettings.test.ts (older weights snap to four preferences, closed summary)
#   apps/web/src/components/ChatView.tsx (balanced environment for new drafts)
#   apps/server-ex/lib/hal_c2/load_balancing.ex (hal-c2.placeThread)
#   apps/server-ex/lib/hal_c2/rpc.ex (server.getHostResources)
#   apps/tui/src/loadBalancing.ts (placeNewThread, the preference a weight shows as)
#   apps/tui/src/host/loadBalancingState.ts (settings rows and palette commands)
#   apps/tui/src/host/composerState.ts (submitNewThread)
#   apps/desktop-qt/src/native/ComposerController.cpp (place: a new thread's first send asks the MC)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (launch: a draft tied to its machine)
#   apps/desktop-qt/src/native/LoadBalancingController.cpp
#   apps/desktop-qt/qml/HalC2/Bricks/LoadBalancingGroup.qml
#   apps/desktop-qt/tests/native/features/LoadBalancingSteps.cpp
#   packages/contracts/src/rpc.ts (server.getHostResources)
#   docs/user/remote-access.md (Balance new threads across machines: desktop and terminal client)
#
# Decisions:
#   - The MC chooses, not the client. The legacy web client collected every machine's
#     resources and chose itself; here a client asks the MC it is connected to
#     (hal-c2.placeThread) and starts the thread where it says, so no client carries the
#     rules and all of them balance alike. The MC reads loadBalancingEnabled and
#     loadBalancingWeights from its own settings document.
#   - Each machine answers for itself when asked, so what is compared is how the machines
#     are doing now. The legacy rule that skipped a machine whose resources were reported
#     over 15s ago is therefore a machine that does not answer in time.
#   - The machine the user picked wins a tie, and keeps the checkout they picked.

Feature: Load balancing new threads across machines
  With several machines in a cluster, new threads in a shared project can start
  on whichever machine has the most room, weighted by the user's preference.
  Balancing is offered on desktop and in the terminal client; phones keep choosing the machine
  by hand.

  @mc
  Scenario: An MC reports its free resources
    When a client asks the MC for its host resources
    Then the MC answers with its CPU count, CPU use and free memory

  @mc @desktop @tui
  Scenario: Load balancing is off by default
    Given a cluster of the machines "laptop" and "server"
    And the project "api" on each machine is a checkout of the same repository
    And "laptop" is busy and "server" is idle
    When the user starts a new thread in "api" on "laptop"
    Then the thread starts on "laptop"

  @mc @desktop @tui
  Scenario: A new thread starts on the machine with the most room
    Given a cluster of the machines "laptop" and "server"
    And the project "api" on each machine is a checkout of the same repository
    And load balancing is on
    And "laptop" is busy and "server" is idle
    When the user starts a new thread in "api" on "laptop"
    Then the thread starts on "server" in its checkout of "api"

  @mc @desktop @tui
  Scenario: A thread stays on the machine the user picked when no other has more room
    Given a cluster of the machines "laptop" and "server"
    And the project "api" on each machine is a checkout of the same repository
    And load balancing is on
    And both machines are equally idle
    When the user starts a new thread in "api" on "laptop"
    Then the thread starts on "laptop"

  @mc @desktop @tui
  Scenario Outline: A machine is skipped when it cannot take work
    Given a cluster of the machines "laptop" and "server"
    And the project "api" on each machine is a checkout of the same repository
    And load balancing is on
    And "laptop" is busy and "server" is idle
    And "server" <state>
    When the user starts a new thread in "api" on "laptop"
    Then the thread starts on "laptop"

    Examples:
      | state                                       |
      | is set to manual only                       |
      | does not answer in time                     |
      | is offline                                  |
      | is at 95% CPU                               |
      | has 5% of memory free                       |
      | does not have the chosen provider signed in |
      | instead has no checkout of the repository   |

  @mc @desktop @tui
  Scenario: Preferring a machine sends it more new threads
    Given a cluster of the machines "laptop" and "server"
    And the project "api" on each machine is a checkout of the same repository
    And load balancing is on
    And the user prefers "server" and sets "laptop" to less often
    And "server" is somewhat busier than "laptop"
    When the user starts a new thread in "api" on "laptop"
    Then the thread starts on "server" in its checkout of "api"

  @desktop @tui
  Scenario: A draft already tied to a machine is not moved
    Given load balancing is on
    And the user chose a branch for the new thread on "laptop"
    When the user sends the first message
    Then the thread starts on "laptop"

  @desktop @tui
  Scenario: Load balancing needs more than one machine
    Given only one machine is connected
    When the user opens connection settings
    Then load balancing is not offered

  @desktop @tui
  Scenario: Load balancing goes when the cluster is one machine again
    Given a cluster of the machines "laptop" and "server"
    And the user opens connection settings
    When "server" is removed from the cluster
    Then load balancing is not offered

  # The terminal reads the MC's settings when a second machine first makes them matter,
  # not only when settings or the palette open.
  @tui
  Scenario: Load balancing appears when a second machine joins while settings are open
    Given only one machine is connected
    And the user opens connection settings
    When a second machine joins the cluster
    Then load balancing is offered and off without opening settings again

  @backlog @mobile
  Scenario: On a phone the user always chooses the machine for a new thread
    Given two connected machines share project "api"
    And load balancing is on for the user's desktop
    When the user starts a new thread in "api" on a phone
    Then the thread starts on the machine the user picked
    And load balancing is not offered on the phone

  @backlog @desktop @tui
  Scenario Outline: Each machine has one of four load preferences
    Given load balancing is on with several machines connected
    When the user sets "server" to <preference>
    Then "server" receives <effect>

    Examples:
      | preference  | effect                                          |
      | Prefer      | the most new threads when it has the room       |
      | Normal      | new threads by free CPU and memory alone        |
      | Less often  | fewer new threads than its free resources imply |
      | Manual only | no balanced threads, only ones the user picks   |

  @backlog @desktop @tui
  Scenario Outline: A preference saved by an older version shows as the nearest one
    Given a machine's saved weight is <weight>
    When the user opens load balancing settings
    Then the machine shows <preference>

    Examples:
      | weight  | preference  |
      | none    | Normal      |
      | 50      | Normal      |
      | 0       | Manual only |
      | 10      | Less often  |
      | 80      | Prefer      |

  @backlog @desktop @tui
  Scenario: The closed load balancing section summarises what is not normal
    Given load balancing is on
    And "server" is set to Prefer and "laptop" to Less often
    And "build-box" is left at Normal
    When the user looks at load balancing with the section closed
    Then the summary reads "server prefer · laptop less often"

  @backlog @desktop @tui
  Scenario: The closed load balancing section says when it is off
    Given load balancing is off
    When the user looks at load balancing with the section closed
    Then the summary reads "Off"
    And with every machine at Normal while it is on, no summary is shown

  @backlog @desktop @tui
  Scenario: Preferences wait for load balancing to be turned on
    Given load balancing is off
    Then every machine's preference is shown but cannot be changed
    When the user turns load balancing on
    Then the preferences can be changed

  @backlog @desktop @tui
  Scenario: Only machines that are switched on are listed for balancing
    Given a cluster of the machines "laptop", "server" and "build-box"
    And "build-box" is switched off
    When the user opens load balancing settings
    Then "laptop" and "server" are listed
    And "build-box" is not
    And load balancing is not offered when only one machine is left switched on
