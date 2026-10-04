# Sources:
#   apps/desktop-qt/host/main.ts (desktop host: MC lifecycle, the ready line)
#   apps/desktop-qt/host/elixirMc.ts (the MC's access token, found through its runtime record when attached)
#   apps/desktop-qt/host/main.test.ts (these scenarios, by name, against a fake MC)
#   apps/desktop-qt/src/BackendProcess.cpp (host process, ready/error lines, stdin close on exit)
#   apps/desktop-qt/src/main.cpp (--url attach mode, --home-dir, --screenshot scripted runs on NativeShell::ready)
#   apps/desktop-qt/tests/native/features/ConnectionSteps.cpp (the scripted screenshot)
#   apps/server-ex/lib/hal_c2/desktop.ex (bootstrap line on standard input)
#   docs/internals/desktop-qt.md (process model)
#   Shared domain: connections/ owns pairing; mc/platform/ owns the MC's side of the bootstrap.

Feature: The desktop app runs its own MC
  Started on its own, the Qt desktop app starts an MC on this machine and connects to
  it with the MC's own access token. Given an MC's pairing link, it attaches to that MC
  instead. Either way the shell's own client is paired with the MC before the window fills.

  Rule: Starting the desktop app starts its MC and connects to it

    @desktop
    Scenario: Starting the desktop app starts an MC with the desktop's HAL-C2 home
      Given the desktop app's HAL-C2 home is "/tmp/sandbox"
      When the user starts the desktop app
      Then an MC starts with the HAL-C2 home "/tmp/sandbox"
      And its bootstrap reaches it on standard input, not on the command line

    # The shell connects with the MC's own access token; there is no web app to pair.
    @dropped
    Scenario: The app opens paired with the desktop's MC
      When the user starts the desktop app
      Then the app opens with a pairing link for the desktop's MC
      And that link's token gives the app admin access to the MC
      And the user is not asked to pair

    @desktop
    Scenario: The desktop's own client is given the MC and its access token
      When the user starts the desktop app
      Then the shell is told the desktop MC's address and the MC's own access token

    # The desktop app no longer serves a web app.
    @dropped
    Scenario: The app is served from this machine, not by the MC
      When the user starts the desktop app
      Then the app's pages come from a loopback address on this machine
      And any page of the app loads the app

    @desktop
    Scenario: A configured MC release is the MC the desktop app runs
      Given "HAL_C2_MC_RELEASE" names an MC release
      When the user starts the desktop app
      Then that release is started

    @desktop
    Scenario: In a checkout without a release the MC runs from source
      Given no MC release is configured or bundled
      When the user starts the desktop app from a checkout
      Then the MC runs from the checkout's source

    @desktop
    Scenario: An MC run from source keeps its access token in the development profile
      Given no HAL-C2 home is set for the desktop app
      When the desktop app starts its MC from a checkout
      Then the shell looks for the MC's access token in the "hal-c2-dev" data directory

    @desktop
    Scenario: The MC's JavaScript sidecars run on the desktop app's Node
      When the user starts the desktop app
      Then the MC is told to run its JavaScript sidecars with the Node that runs the desktop host

    @desktop
    Scenario: Without a configured port the MC takes the next free one
      Given another program listens on the MC's default port
      When the user starts the desktop app
      Then the MC listens on the next free port

  Rule: Starting again reuses the environment

    # The address was the served web app's, whose saved state lived per origin.
    @dropped
    Scenario: The app keeps its address across restarts
      Given the user started the desktop app with the HAL-C2 home "/tmp/sandbox" before
      When the user starts it again with the same home
      Then the app is served from the same address as before
      And its saved environments, drafts and settings are still there

    # The web app's pairing on each start; the shell connects with the MC's own token.
    @dropped
    Scenario: Restarting the desktop app pairs the same environment again
      Given the user started the desktop app before and the app saved the desktop's MC
      When the user starts the desktop app again
      Then the app is paired with a fresh token for the same MC
      And the app lists the desktop's MC once

    @desktop
    Scenario: Restarting the desktop app connects to the same environment again
      Given the user started the desktop app before
      When the user starts the desktop app again
      Then the shell connects to an MC with the same environment as before

  Rule: Attaching to a running MC with its pairing link

    @desktop
    Scenario: Attaching to an MC with its pairing link
      Given an MC is running on this machine
      When the user starts the desktop app with that MC's pairing link
      Then the shell is told that MC's address and the session its pairing link opened
      And the desktop app starts no MC of its own

    @desktop
    Scenario: An attached desktop's own client is given the token of an MC on this machine
      Given `mise run mc` runs an MC on this machine
      When the user starts the desktop app with that MC's pairing link
      Then the shell is told that MC's address and the MC's own access token

    @desktop
    Scenario: An attached desktop's own client pairs with an MC it has no files for
      Given an MC is running whose runtime record this machine does not have
      When the user starts the desktop app with that MC's pairing link
      Then the shell is told that MC's address and the session its pairing link opened

    # The web app's own pairing link; the shell is the only client now.
    @dropped
    Scenario: A pairing link without access to pairing opens the app unpaired
      Given an MC is running whose pairing link carries standard access
      When the user starts the desktop app with that MC's pairing link
      Then the shell is told that MC's address and the session its pairing link opened
      And the app opens without a pairing link, because the link could only be used once

    @desktop
    Scenario: Attaching with a pairing link the MC refuses
      Given an MC is running on this machine
      When the user starts the desktop app with a pairing link that MC has spent or never issued
      Then the desktop app says the pairing link is invalid or expired

    # The shell works through its own client of the MC, so it has nothing to open for an
    # address that is not one.
    @dropped
    Scenario: An address that is not an MC is loaded as it is
      When the user starts the desktop app with the address of a web app
      Then that address is loaded unchanged

    @desktop
    Scenario: An address that is not an MC is refused
      When the user starts the desktop app with the address of a web app
      Then the desktop app says that address is not a HAL-C2 MC

    @desktop
    Scenario: Attaching to an MC that is not running
      When the user starts the desktop app with a pairing link for an MC that is not running
      Then the desktop app says it cannot reach the MC at that address

  Rule: Quitting the desktop app stops the MC it started

    @desktop
    Scenario: Quitting the desktop app stops its MC
      Given the desktop app started its MC
      When the user quits the desktop app
      Then the MC stops

    @desktop
    Scenario: Quitting an attached desktop app leaves the MC running
      Given the desktop app is attached to a running MC
      When the user quits the desktop app
      Then the MC keeps running

  Rule: Start-up failures say what went wrong

    # The desktop app no longer serves a web app.
    @dropped
    Scenario: The app bundle is missing
      Given the desktop app has no built app bundle
      When the user starts the desktop app
      Then the desktop app says the app bundle is missing and how to build it
      And no MC is started

    @desktop
    Scenario: The MC fails to start
      Given the MC exits before it answers
      When the user starts the desktop app
      Then the desktop app says the MC failed to start, with its exit code

    @desktop
    Scenario: The MC's port the desktop app was told to use is taken
      Given "HAL_C2_MC_PORT" names a port another program listens on
      When the user starts the desktop app
      Then the desktop app says that port is in use and names "HAL_C2_MC_PORT"
      And no MC is started

    # The web app's port; the desktop app no longer serves one.
    @dropped
    Scenario: The web app's port the desktop app was told to use is taken
      Given "HAL_C2_WEB_PORT" names a port another program listens on
      When the user starts the desktop app
      Then the desktop app says that port is in use and names "HAL_C2_WEB_PORT"
      And no MC is started

  Rule: A scripted screenshot shows what the user would see

    @desktop
    Scenario: A screenshot taken without a display shows the app's window
      Given the desktop app runs without a display
      When the user starts the desktop app asking for a screenshot
      Then the screenshot is taken once the MC's first snapshot is in
      And the screenshot shows the app's native window, not an empty view

    # main.cpp's own path: the native scenario runs the built app (ScreenshotSteps.cpp).
    @desktop
    Scenario: A screenshot of a desktop app that fails to start shows why and quits
      When the user starts the desktop app asking for a screenshot, with a pairing link for an MC that is not running
      Then the screenshot shows the desktop app saying it cannot reach the MC
      And the desktop app quits with a failure code
