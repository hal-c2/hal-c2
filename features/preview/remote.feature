# Sources:
#   apps/server-ex/lib/hal_c2/web/protocol.ex (preview, previewAutomation and localServers shapes; unknown MC)
#   apps/server-ex/lib/hal_c2/web/socket.ex (cross-MC subscriptions, remote/4 errors, unsubscribe on close)
#   apps/server-ex/lib/hal_c2/preview.ex (serverEpoch per MC run, watcher monitoring)
#   apps/server-ex/lib/hal_c2/preview_automation.ex (host stream ends on eviction, dropped on socket exit)
#   apps/server-ex/lib/hal_c2/local_servers.ex
#   apps/web/src/components/preview/usePreviewSession.ts, useDiscoveredLocalServers.ts
#   apps/desktop-qt/parity/features.backlog.test.ts (in-app-preview)
#   Cross-domain: connections/ owns pairing and relay setup; mc/ owns cluster membership.

Feature: Preview across MCs and devices
  Browser tabs, local server suggestions and agent browser hosts belong to the MC that runs
  the thread. A client connected to any MC of the cluster can reach them.

  @mc
  Scenario: A client follows browser tabs on another MC of the cluster
    Given the client is connected to one MC of a cluster
    And a thread on a second MC has browser tabs
    When the client watches the second MC's browser tabs
    Then it receives the second MC's tab changes as they happen

  @mc
  Scenario: A client reaches tabs on another MC by the MC's name
    Given the client is connected to one MC of a cluster
    When the client opens a browser tab for a thread on the second MC
    Then the tab is kept by the second MC

  @mc
  Scenario: Local servers are suggested from the machine of the chosen MC
    Given the client is connected to one MC of a cluster
    And a dev server is running on the second MC's machine
    When the client watches the second MC's local servers
    Then the second MC's dev server is suggested
    And servers on the first MC's machine are not

  @mc
  Scenario Outline: Watching preview activity on an MC the server does not know is refused
    When the client watches <activity> on an MC the server does not know
    Then the request fails with "unknown MC"

    Examples:
      | activity           |
      | browser tabs       |
      | local servers      |
      | agent browser work |

  @mc
  Scenario: Watching an MC that has gone away fails with the reason
    Given an MC of the cluster has stopped answering
    When the client watches that MC's browser tabs
    Then the request fails saying the MC is unavailable

  @mc
  Scenario: A desktop hosts the agent's browser for a thread on another MC
    Given the desktop is connected to one MC of a cluster
    And an agent runs in a thread on the second MC
    When the desktop offers its browser to the second MC
    Then the agent's browser actions reach the desktop

  @mc
  Scenario: A desktop that loses its connection stops receiving agent actions
    Given a desktop is offering its browser to an MC
    When the desktop's connection to the server closes
    Then the MC stops sending it the agent's browser actions
    And any action it had not answered fails as disconnected

  @mc
  Scenario: A client that stops watching no longer gets tab changes
    Given a client is watching an MC's browser tabs
    When the client stops watching
    Then the MC stops sending it tab changes

  @desktop
  Scenario: A client drops its old tabs after the MC restarts
    Given the client shows a thread's browser tabs
    When the MC restarts and a tab change arrives with a new run number
    Then the client lists the thread's tabs again
    And it shows only the tabs the restarted MC has

  @desktop
  Scenario: A late tab list from before a change is ignored
    Given the client has seen a tab change with a newer change number
    When an older tab list arrives
    Then the client keeps the newer tab state

  @backlog @desktop
  Scenario: A remote client suggests the MC's dev servers, not its own
    Given the desktop is connected to an MC on another machine
    When the user opens a new browser tab
    Then the suggestions are the dev servers running on the MC's machine
