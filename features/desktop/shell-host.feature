# Sources:
#   apps/desktop-qt/host/main.ts (desktop host: node lifecycle, app bundle, ready URL)
#   apps/desktop-qt/host/elixirNode.ts (the node's access token, found through its runtime record when attached)
#   apps/desktop-qt/host/main.test.ts (these scenarios, by name, against a fake node)
#   apps/desktop-qt/src/BackendProcess.cpp (host process, ready/error lines, stdin close on exit)
#   apps/desktop-qt/src/main.cpp (--url attach mode, --home-dir, --screenshot scripted runs)
#   apps/desktop-qt/src/WebProfile.cpp (software rendering for a run without a display)
#   apps/server-ex/lib/hal_c2/desktop.ex (bootstrap line on standard input)
#   apps/web/src/components/auth/PairingRouteSurface.tsx (hosted pairing route, auto=1)
#   docs/internals/desktop-qt.md (process model)
#   Shared domain: connections/ owns pairing; node/platform/ owns the node's side of the bootstrap.

Feature: The desktop app runs its own node
  Started on its own, the Qt desktop app starts an Elixir node on this machine and opens the
  app already paired with it. Given a node's pairing link, it attaches to that node instead.
  Either way the shell's own client is paired with the node, so the shell never waits on the page.
  The app itself is served by the desktop app from this machine; the node serves no app.

  Rule: Starting the desktop app starts its node and opens the app paired

    @desktop
    Scenario: Starting the desktop app starts a node with the desktop's HAL-C2 home
      Given the desktop app's HAL-C2 home is "/tmp/sandbox"
      When the user starts the desktop app
      Then a node starts with the HAL-C2 home "/tmp/sandbox"
      And its bootstrap token reaches it on standard input, not on the command line

    @desktop
    Scenario: The app opens paired with the desktop's node
      When the user starts the desktop app
      Then the app opens with a pairing link for the desktop's node
      And that link's token gives the app admin access to the node
      And the user is not asked to pair

    @desktop
    Scenario: The desktop's own client is given the node and its access token
      When the user starts the desktop app
      Then the shell is told the desktop node's address and the node's own access token
      And that token is not the bootstrap token the app pairs with

    @desktop
    Scenario: The app is served from this machine, not by the node
      When the user starts the desktop app
      Then the app's pages come from a loopback address on this machine
      And any page of the app loads the app

    @desktop
    Scenario: A configured node release is the node the desktop app runs
      Given "HAL_C2_NODE_RELEASE" names a node release
      When the user starts the desktop app
      Then that release is started

    @desktop
    Scenario: In a checkout without a release the node runs from source
      Given no node release is configured or bundled
      When the user starts the desktop app from a checkout
      Then the node runs from the checkout's source

    @desktop
    Scenario: A node run from source keeps its access token in the development profile
      Given no HAL-C2 home is set for the desktop app
      When the desktop app starts its node from a checkout
      Then the shell looks for the node's access token in the "hal-c2-dev" data directory

    @desktop
    Scenario: The node's JavaScript sidecars run on the desktop app's Node
      When the user starts the desktop app
      Then the node is told to run its JavaScript sidecars with the Node that runs the desktop host

    @desktop
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

    @desktop
    Scenario: Restarting the desktop app pairs the same environment again
      Given the user started the desktop app before and the app saved the desktop's node
      When the user starts the desktop app again
      Then the app is paired with a fresh token for the same node
      And the app lists the desktop's node once

  Rule: Attaching to a running node with its pairing link

    @desktop
    Scenario: Attaching to a node with its pairing link
      Given a node is running on this machine
      When the user starts the desktop app with that node's pairing link
      Then the app opens with a pairing link for that node
      And the desktop app starts no node of its own

    @desktop
    Scenario: An attached desktop's own client is given the token of a node on this machine
      Given `mise run node` runs a node on this machine
      When the user starts the desktop app with that node's pairing link
      Then the shell is told that node's address and the node's own access token

    @desktop
    Scenario: An attached desktop's own client pairs with a node it has no files for
      Given a node is running whose runtime record this machine does not have
      When the user starts the desktop app with that node's pairing link
      Then the shell is told that node's address and the session its pairing link opened
      And the app opens with a fresh pairing link of its own

    @desktop
    Scenario: A pairing link without access to pairing opens the app unpaired
      Given a node is running whose pairing link carries standard access
      When the user starts the desktop app with that node's pairing link
      Then the shell is told that node's address and the session its pairing link opened
      And the app opens without a pairing link, because the link could only be used once

    @desktop
    Scenario: Attaching with a pairing link the node refuses
      Given a node is running on this machine
      When the user starts the desktop app with a pairing link that node has spent or never issued
      Then the desktop app says the pairing link is invalid or expired

    @desktop
    Scenario: An address that is not a node is loaded as it is
      When the user starts the desktop app with the address of a web app
      Then that address is loaded unchanged

    @desktop
    Scenario: Attaching to a node that is not running
      When the user starts the desktop app with a pairing link for a node that is not running
      Then the desktop app says it cannot reach the node at that address

  Rule: Quitting the desktop app stops the node it started

    @desktop
    Scenario: Quitting the desktop app stops its node
      Given the desktop app started its node
      When the user quits the desktop app
      Then the node stops

    @desktop
    Scenario: Quitting an attached desktop app leaves the node running
      Given the desktop app is attached to a running node
      When the user quits the desktop app
      Then the node keeps running

  Rule: Start-up failures say what went wrong

    @desktop
    Scenario: The app bundle is missing
      Given the desktop app has no built app bundle
      When the user starts the desktop app
      Then the desktop app says the app bundle is missing and how to build it
      And no node is started

    @desktop
    Scenario: The node fails to start
      Given the node exits before it answers
      When the user starts the desktop app
      Then the desktop app says the node failed to start, with its exit code

    @desktop
    Scenario Outline: A port the desktop app was told to use is taken
      Given "<setting>" names a port another program listens on
      When the user starts the desktop app
      Then the desktop app says that port is in use and names "<setting>"
      And no node is started

      Examples:
        | setting          |
        | HAL_C2_NODE_PORT |
        | HAL_C2_WEB_PORT  |

  Rule: A scripted screenshot shows what the user would see

    @desktop
    Scenario: A screenshot taken without a display shows the app's page
      Given the desktop app runs without a display
      When the user starts the desktop app asking for a screenshot
      Then the screenshot shows the app's page inside the window, not an empty view

    # Delivered natively (main.cpp --screenshot); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: A screenshot of a desktop app that fails to start shows why and quits
      When the user starts the desktop app asking for a screenshot, with a pairing link for a node that is not running
      Then the screenshot shows the desktop app saying it cannot reach the node
      And the desktop app quits with a failure code
