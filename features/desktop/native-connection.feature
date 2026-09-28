# Sources:
#   apps/desktop-qt/src/native/NodeClient.cpp (protocol-3 socket: subscriptions, rpc, reconnect)
#   apps/desktop-qt/src/native/ShellStore.cpp (the shell shape folded into project and thread rows)
#   apps/desktop-qt/src/native/NativeShell.cpp (hand-over from the page after the first snapshot)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (the protocol the shell speaks)
#   packages/client-runtime/src/v3/clusterSocket.ts (the TypeScript twin of the shell's client)
#   Shared domain: desktop/shell-host.feature starts the node and hands the shell its token.

Feature: The desktop shell talks to its node itself
  The Qt shell holds its own connection to the desktop's node, as the TUI does, so the sidebar
  and the composer's turn actions no longer travel through the page. The page stays in charge
  until the node's first snapshot arrives, so a node that never answers leaves a working app.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title |
      | t1 | p1      | One   |
    And the node has the project "p1" titled "proj-1"

  Rule: The shell connects with the node's access token and follows the shell shape

    @desktop
    Scenario: The shell connects with the node's own access token
      When the desktop shell connects to its node with the token "node-token"
      Then the node was reached with the token "node-token"
      And the shell subscribed to the node's "shell" shape

    @desktop
    Scenario: The node's updates reach the shell's sidebar
      Given the desktop shell is connected to its node
      When the node updates the thread "t1" with the title "Renamed"
      Then the sidebar's "active" section lists "Renamed"

    @desktop
    Scenario: A thread the node deletes leaves the shell's sidebar
      Given the desktop shell is connected to its node
      When the node deletes the thread "t1"
      Then the sidebar's "active" section is empty

  Rule: The page keeps the sidebar and the composer until the node's first snapshot

    @desktop
    Scenario: Before the first snapshot the page handles the shell's actions
      Given the node holds back its snapshot
      And the desktop shell connects to its node
      When the user settles "env-a:t1"
      Then the action "thread.settle" for "env-a:t1" reaches the page
      And the shell has not taken over from the page
      And the node receives no commands

    @desktop
    Scenario: The first snapshot hands the sidebar and the composer to the shell
      Given the node holds back its snapshot
      And the desktop shell connects to its node
      When the node sends its snapshot
      Then the shell tells the page it owns the sidebar and the composer

    @desktop
    Scenario: Before the first snapshot the page is told nothing when it asks
      Given the node holds back its snapshot
      And the desktop shell connects to its node
      When the page asks who owns the sidebar
      Then the page has not been told who owns the sidebar

    @desktop
    Scenario: A page that loads after the hand-over asks and is told
      Given the desktop shell is connected to its node
      And the page forgets who owns the sidebar
      When the page asks who owns the sidebar
      Then the shell tells the page it owns the sidebar and the composer

    @desktop
    Scenario: The page's own sidebar no longer replaces the shell's
      Given the desktop shell is connected to its node
      When the page publishes its own sidebar
      Then the sidebar's "active" section lists "One"

  Rule: A dropped connection comes back on its own

    @desktop
    Scenario: The shell reconnects and subscribes again after the connection drops
      Given the desktop shell is connected to its node
      When the node drops the connection
      Then the shell reconnects to the node
      And the shell subscribed to the node's "shell" shape again

    @desktop
    Scenario: An action while the node is unreachable fails with a toast
      Given the desktop shell is connected to its node
      And the node stops accepting connections
      When the node drops the connection
      And the user settles "env-a:t1"
      Then the user sees an "error" toast "Failed to settle thread" saying "not connected"
