# Sources:
#   apps/server-ex/lib/hal_c2/web/protocol.ex (preview, previewAutomation and localServers shapes; unknown MC)
#   apps/server-ex/lib/hal_c2/web/socket.ex (cross-MC subscriptions, remote/4 errors, unsubscribe on close)
#   apps/server-ex/lib/hal_c2/preview.ex (serverEpoch per MC run, watcher monitoring)
#   apps/server-ex/lib/hal_c2/preview_automation.ex (host stream ends on eviction, dropped on socket exit)
#   apps/server-ex/lib/hal_c2/local_servers.ex
#   apps/server-ex/lib/hal_c2/preview_forward.ex, preview_forward/ (preview.forward: listener, grant, pipes)
#   apps/server-ex/lib/hal_c2/cluster/distribution.ex (the cluster link a forward rides on)
#   apps/desktop-qt/src/native/ThreadPreviews.cpp (openAddress: a loopback page of another MC's thread opens through its forward)
#   apps/desktop-qt/src/native/RightPanelController.cpp (thread.openAddress, link.menu's Open link)
#   apps/web/src/components/preview/usePreviewSession.ts, useDiscoveredLocalServers.ts
#   apps/desktop-qt/parity/features.backlog.test.ts (in-app-preview)
#   apps/desktop-qt/src/native/ThreadPreviews.cpp, apps/desktop-qt/src/ShellBridge.cpp (tabs open in the system browser)
#   apps/desktop-qt/qml/HalC2/Bricks/ThreadView.qml (web links in a reply)
#   apps/web/src/browser/browserTargetResolver.ts (upstream rewrote localhost to the environment's host,
#     on private networks only; a forward replaces that)
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

  @desktop
  Scenario: A remote client suggests the MC's dev servers, not its own
    Given the desktop is connected to an MC on another machine
    When the user opens a new browser tab
    Then the suggestions are the dev servers running on the MC's machine

  @backlog @desktop @mobile @priority-low
  Scenario: A client with no MC of its own forwards a dev server's port itself
    Given the client is connected to an MC on another machine and its own machine runs no MC
    And a dev server on that machine listens on port 3000 for that machine only
    When the user opens a browser tab at "http://localhost:3000" for a thread on that MC
    Then the client listens on its own machine and carries the page over its connection to the MC

  # Until then a forward through an MC on another machine would listen on that machine.
  @desktop
  Scenario: A desktop whose MC is on another machine opens a dev server's address as it is
    Given the desktop's MC runs on another machine and is in a cluster with a second MC
    And a thread on the second MC has a browser tab at "http://localhost:3000"
    When the user opens the tab
    Then the system browser opens "http://localhost:3000"
    And nothing is forwarded

  # A dev server on the thread's machine is usually reachable only from that machine, and
  # its pages, cookies and sign-in callbacks expect the address "localhost". The MC on the
  # user's machine forwards the port over the cluster, so the user's browser opens the same
  # "http://localhost:3000" it would if the dev server ran on this machine.
  Rule: A browser on the client's machine reaches dev servers on the thread's machine

    Background:
      Given the client is connected to the MC on its own machine
      And that MC is in a cluster with a second MC on another machine
      And a dev server on the second MC's machine listens on port 3000 for that machine only

    @mc
    Scenario: Opening a tab for a dev server on another MC forwards its port
      When the client opens a browser tab at "http://localhost:3000" for a thread on the second MC
      Then the client's MC listens on port 3000 for its own machine only
      And a page asked of that port is answered by the second MC's dev server

    @mc
    Scenario: A forwarded dev server keeps its live connections
      Given the client's MC forwards port 3000 for a thread on the second MC
      When a page from the forward opens a websocket to the dev server
      Then messages pass both ways until either side closes it

    @mc
    Scenario: A port already in use on the client's machine is forwarded on another one
      Given port 3000 is in use on the client's machine
      When the client opens a browser tab at "http://localhost:3000" for a thread on the second MC
      Then the client's MC forwards the dev server on a free port of its own machine
      And the client is told the address it forwards to

    @mc
    Scenario Outline: Only a dev server a thread has a tab for is forwarded
      When the client asks to forward <port> of the second MC's machine for a thread
      Then the request is refused
      And nothing listens for it on the client's machine

      Examples:
        | port                                               |
        | a port none of the thread's tabs names             |
        | the second MC's own port, even when a tab names it |
        | the cluster's port, even when a tab names it       |

    @mc
    Scenario: A forward closes with the last tab that uses it
      Given the client's MC forwards port 3000 for a thread on the second MC
      When the thread's last tab at port 3000 is closed
      Then the client's MC stops listening on port 3000

    @mc
    Scenario: A forward to an MC that stops answering closes
      Given the client's MC forwards port 3000 for a thread on the second MC
      When the second MC stops answering
      Then the client's MC stops listening on port 3000
      And connections through it are closed rather than left hanging

    @mc
    Scenario: A dev server on the client's own MC is not forwarded
      When the client opens a browser tab at "http://localhost:3000" for a thread on its own MC
      Then nothing is forwarded
      And the tab's address stays "http://localhost:3000"

    @desktop
    Scenario: The desktop opens a dev server on another machine through the forward
      Given a thread on the second MC has a browser tab at "http://localhost:3000"
      When the user opens the tab
      Then the system browser opens the address the desktop's MC forwards to the dev server

    # The second MC forwards only a port one of the thread's tabs names.
    @desktop
    Scenario: A dev server link in a reply opens through the forward
      Given the agent of a thread on the second MC writes "http://localhost:3000/cart"
      When the user opens the link
      Then the thread gets a browser tab at "http://localhost:3000/cart"
      And the system browser opens "/cart" on the address the desktop's MC forwards to the dev server
