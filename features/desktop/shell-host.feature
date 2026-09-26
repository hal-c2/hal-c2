# Sources:
#   apps/desktop-qt/host/main.ts (desktop host: node lifecycle, app bundle, ready URL)
#   apps/desktop-qt/host/main.test.ts (these scenarios, by name, against a fake node)
#   apps/desktop-qt/src/BackendProcess.cpp (host process, ready/error lines, stdin close on exit)
#   apps/desktop-qt/src/main.cpp (--url attach mode, --home-dir)
#   apps/server-ex/lib/hal_c2/desktop.ex (bootstrap line on standard input)
#   apps/web/src/components/auth/PairingRouteSurface.tsx (hosted pairing route, auto=1)
#   docs/internals/desktop-qt.md (process model)
#   Shared domain: connections/ owns pairing; node/platform/ owns the node's side of the bootstrap.

Feature: The desktop app runs its own node
  Started on its own, the Qt desktop app starts an Elixir node on this machine and opens the
  app already paired with it. Given a node's pairing link, it attaches to that node instead.
  The app itself is served by the desktop app from this machine; the node serves no app.

  Rule: Starting the desktop app starts its node and opens the app paired

    @desktop @backlog
    Scenario: Starting the desktop app starts a node with the desktop's HAL-C2 home
      Given the desktop app's HAL-C2 home is "/tmp/sandbox"
      When the user starts the desktop app
      Then a node starts with the HAL-C2 home "/tmp/sandbox"
      And its bootstrap token reaches it on standard input, not on the command line

    @desktop @backlog
    Scenario: The app opens paired with the desktop's node
      When the user starts the desktop app
      Then the app opens with a pairing link for the desktop's node
      And that link's token gives the app admin access to the node
      And the user is not asked to pair

    @desktop @backlog
    Scenario: The app is served from this machine, not by the node
      When the user starts the desktop app
      Then the app's pages come from a loopback address on this machine
      And any page of the app loads the app

    @desktop @backlog
    Scenario: A configured node release is the node the desktop app runs
      Given "HAL_C2_NODE_RELEASE" names a node release
      When the user starts the desktop app
      Then that release is started

    @desktop @backlog
    Scenario: In a checkout without a release the node runs from source
      Given no node release is configured or bundled
      When the user starts the desktop app from a checkout
      Then the node runs from the checkout's source

    @desktop @backlog
    Scenario: The node's JavaScript sidecars run on the desktop app's Node
      When the user starts the desktop app
      Then the node is told to run its JavaScript sidecars with the Node that runs the desktop host

    @desktop @backlog
    Scenario: Without a configured port the node takes the next free one
      Given another program listens on the node's default port
      When the user starts the desktop app
      Then the node listens on the next free port

  Rule: Starting again reuses the paired environment

    @desktop @backlog
    Scenario: The app keeps its address across restarts
      Given the user started the desktop app with the HAL-C2 home "/tmp/sandbox" before
      When the user starts it again with the same home
      Then the app is served from the same address as before
      And its saved environments, drafts and settings are still there

    @desktop @backlog
    Scenario: Restarting the desktop app pairs the same environment again
      Given the user started the desktop app before and the app saved the desktop's node
      When the user starts the desktop app again
      Then the app is paired with a fresh token for the same node
      And the app lists the desktop's node once

  Rule: Attaching to a running node with its pairing link

    @desktop @backlog
    Scenario: Attaching to a node with its pairing link
      Given a node is running on this machine
      When the user starts the desktop app with that node's pairing link
      Then the app opens with a pairing link for that node
      And the desktop app starts no node of its own

    @desktop @backlog
    Scenario: An address that is not a node is loaded as it is
      When the user starts the desktop app with the address of a web app
      Then that address is loaded unchanged

    @desktop @backlog
    Scenario: Attaching to a node that is not running
      When the user starts the desktop app with a pairing link for a node that is not running
      Then the desktop app says it cannot reach the node at that address

  Rule: Quitting the desktop app stops the node it started

    @desktop @backlog
    Scenario: Quitting the desktop app stops its node
      Given the desktop app started its node
      When the user quits the desktop app
      Then the node stops

    @desktop @backlog
    Scenario: Quitting an attached desktop app leaves the node running
      Given the desktop app is attached to a running node
      When the user quits the desktop app
      Then the node keeps running

  Rule: Start-up failures say what went wrong

    @desktop @backlog
    Scenario: The app bundle is missing
      Given the desktop app has no built app bundle
      When the user starts the desktop app
      Then the desktop app says the app bundle is missing and how to build it
      And no node is started

    @desktop @backlog
    Scenario: The node fails to start
      Given the node exits before it answers
      When the user starts the desktop app
      Then the desktop app says the node failed to start, with its exit code

    @desktop @backlog
    Scenario Outline: A port the desktop app was told to use is taken
      Given "<setting>" names a port another program listens on
      When the user starts the desktop app
      Then the desktop app says that port is in use and names "<setting>"
      And no node is started

      Examples:
        | setting          |
        | HAL_C2_NODE_PORT |
        | HAL_C2_WEB_PORT  |
