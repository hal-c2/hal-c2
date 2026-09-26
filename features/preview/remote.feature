# Sources:
#   apps/server-ex/lib/hal_c2/web/protocol.ex (preview, previewAutomation and localServers shapes; unknown node)
#   apps/server-ex/lib/hal_c2/web/socket.ex (cross-node subscriptions, remote/4 errors, unsubscribe on close)
#   apps/server-ex/lib/hal_c2/preview.ex (serverEpoch per node run, watcher monitoring)
#   apps/server-ex/lib/hal_c2/preview_automation.ex (host stream ends on eviction, dropped on socket exit)
#   apps/server-ex/lib/hal_c2/local_servers.ex
#   apps/web/src/components/preview/usePreviewSession.ts, useDiscoveredLocalServers.ts
#   apps/desktop-qt/parity/features.backlog.test.ts (in-app-preview)
#   Cross-domain: connections/ owns pairing and relay setup; node/ owns cluster membership.

Feature: Preview across nodes and devices
  Browser tabs, local server suggestions and agent browser hosts belong to the node that runs
  the thread. A client connected to any node of the cluster can reach them.

  @node
  Scenario: A client follows browser tabs on another node of the cluster
    Given the client is connected to one node of a cluster
    And a thread on a second node has browser tabs
    When the client watches the second node's browser tabs
    Then it receives the second node's tab changes as they happen

  @node
  Scenario: A client reaches tabs on another node by the node's name
    Given the client is connected to one node of a cluster
    When the client opens a browser tab for a thread on the second node
    Then the tab is kept by the second node

  @node
  Scenario: Local servers are suggested from the machine of the chosen node
    Given the client is connected to one node of a cluster
    And a dev server is running on the second node's machine
    When the client watches the second node's local servers
    Then the second node's dev server is suggested
    And servers on the first node's machine are not

  @node
  Scenario Outline: Watching preview activity on a node the server does not know is refused
    When the client watches <activity> on a node the server does not know
    Then the request fails with "unknown node"

    Examples:
      | activity           |
      | browser tabs       |
      | local servers      |
      | agent browser work |

  @node
  Scenario: Watching a node that has gone away fails with the reason
    Given a node of the cluster has stopped answering
    When the client watches that node's browser tabs
    Then the request fails saying the node is unavailable

  @node
  Scenario: A desktop hosts the agent's browser for a thread on another node
    Given the desktop is connected to one node of a cluster
    And an agent runs in a thread on the second node
    When the desktop offers its browser to the second node
    Then the agent's browser actions reach the desktop

  @node
  Scenario: A desktop that loses its connection stops receiving agent actions
    Given a desktop is offering its browser to a node
    When the desktop's connection to the server closes
    Then the node stops sending it the agent's browser actions
    And any action it had not answered fails as disconnected

  @node
  Scenario: A client that stops watching no longer gets tab changes
    Given a client is watching a node's browser tabs
    When the client stops watching
    Then the node stops sending it tab changes

  @backlog @desktop
  Scenario: A client drops its old tabs after the node restarts
    Given the client shows a thread's browser tabs
    When the node restarts and a tab change arrives with a new run number
    Then the client lists the thread's tabs again
    And it shows only the tabs the restarted node has

  @backlog @desktop
  Scenario: A late tab list from before a change is ignored
    Given the client has seen a tab change with a newer change number
    When an older tab list arrives
    Then the client keeps the newer tab state

  @backlog @desktop
  Scenario: A remote client suggests the node's dev servers, not its own
    Given the desktop is connected to a node on another machine
    When the user opens a new browser tab
    Then the suggestions are the dev servers running on the node's machine
