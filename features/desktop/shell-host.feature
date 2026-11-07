# Sources:
#   https://github.com/pingdotgg/t3code/pull/26099
#   https://github.com/pingdotgg/t3code/pull/23873 (dropped)
#   https://github.com/pingdotgg/t3code/pull/22572
#   https://github.com/pingdotgg/t3code/pull/30420 (dropped)
#   https://github.com/pingdotgg/t3code/pull/19706
#   https://github.com/pingdotgg/t3code/pull/19554
#   https://github.com/pingdotgg/t3code/pull/20277
#   https://github.com/pingdotgg/t3code/pull/15044
#   https://github.com/pingdotgg/t3code/pull/25903
#   https://github.com/pingdotgg/t3code/pull/24111
#   https://github.com/pingdotgg/t3code/pull/16670
#   https://github.com/pingdotgg/t3code/pull/19118
#   https://github.com/pingdotgg/t3code/pull/17587
#   https://github.com/pingdotgg/t3code/pull/14784
#   https://github.com/pingdotgg/t3code/pull/13469 (a malformed OTEL_RESOURCE_ATTRIBUTES no longer stops startup)
#   https://github.com/pingdotgg/t3code/pull/13355
#   apps/desktop-qt/host/main.ts (desktop host: MC lifecycle, the ready line)
#   apps/desktop-qt/host/elixirMc.ts (the MC's access token, found through its runtime record when attached)
#   apps/desktop-qt/host/main.test.ts (these scenarios, by name, against a fake MC)
#   apps/desktop-qt/src/BackendProcess.cpp (host process, ready/error lines, stdin close on exit)
#   apps/desktop-qt/src/main.cpp (--url attach mode, --home-dir, --screenshot scripted runs on NativeShell::ready)
#   apps/desktop-qt/tests/native/features/ConnectionSteps.cpp (the scripted screenshot)
#   apps/server-ex/lib/hal_c2/desktop.ex (bootstrap line on standard input)
#   apps/desktop/src/backend/DesktopBackendManager.ts (restart delays, readiness timeout)
#   apps/desktop/src/app/DesktopLifecycle.ts (SIGINT and SIGTERM quit)
#   apps/desktop/src/app/DesktopLinuxUrlHandler.ts (hal-c2:// handler registered on Linux)
#   apps/desktop/src/app/DesktopApp.ts (fatal startup error dialog), DesktopAppIdentity.ts (About panel build line)
#   apps/desktop/src/app/DesktopObservability.ts (log files, backend output log, OTLP endpoints)
#   apps/desktop/src/linuxSecretStorage.ts, DesktopEarlyElectronStartup.ts (Linux password store choice)
#   apps/desktop/src/settings/DesktopAppSettings.ts (damaged settings file, Tailscale port fallback)
#   docs/internals/desktop-qt.md (process model)
#   apps/web/src/legacyStorage.ts, apps/web/src/clientPersistenceStorage.ts (what a browser kept; dropped)
#   Shared domain: connections/ owns pairing; mc/platform/ owns the MC's side of the bootstrap.
#   https://github.com/pingdotgg/t3code/pull/15440
#   https://github.com/pingdotgg/t3code/pull/25317
#   https://github.com/pingdotgg/t3code/pull/25345
#   https://github.com/pingdotgg/t3code/pull/22471
#   https://github.com/pingdotgg/t3code/pull/28368
#   https://github.com/pingdotgg/t3code/pull/28464
#   https://github.com/pingdotgg/t3code/pull/29635

Feature: The desktop app runs its own MC
  Started on its own, the Qt desktop app starts an MC on this machine and connects to
  it with the MC's own access token. Given an MC's pairing link, it attaches to that MC
  instead. Either way the shell's own client is paired with the MC before the window fills.

  # Upstream #23873: a quit stuck waiting on the bundled server's shutdown swallowed every later Quit
  # and SIGTERM. Dropped: the HAL-C2 desktop does not own the MC's shutdown, so its quit never
  # waits on one.
  @dropped @desktop
  Scenario: Quitting again after a stuck quit closes the app
    Given the app started quitting 10 seconds ago and is still waiting on its server to stop
    When the user quits again
    Then the app closes

  Rule: Starting the desktop app starts its MC and connects to it

    @desktop @backlog-desktop
    Scenario: Starting the desktop app starts an MC with the desktop's HAL-C2 home
      Given the desktop app's HAL-C2 home is "/tmp/sandbox"
      When the user starts the desktop app
      Then an MC starts with the HAL-C2 home "/tmp/sandbox"
      And its bootstrap reaches it on standard input, not on the command line

    # Upstream #19706: no window showed until the local backend reported ready.
    @backlog @desktop @priority-low
    Scenario: The desktop app shows it is starting while its MC starts
      When the user starts the desktop app
      Then a window saying "Starting HAL-C2…" shows before the MC is ready
      And it gives way to the main window once the MC is ready

    # The shell connects with the MC's own access token; there is no web app to pair.
    @dropped
    Scenario: The app opens paired with the desktop's MC
      When the user starts the desktop app
      Then the app opens with a pairing link for the desktop's MC
      And that link's token gives the app admin access to the MC
      And the user is not asked to pair

    @desktop @backlog-desktop
    Scenario: The desktop's own client is given the MC and its access token
      When the user starts the desktop app
      Then the shell is told the desktop MC's address and the MC's own access token

    # The desktop app no longer serves a web app.
    @dropped
    Scenario: The app is served from this machine, not by the MC
      When the user starts the desktop app
      Then the app's pages come from a loopback address on this machine
      And any page of the app loads the app

    @desktop @backlog-desktop
    Scenario: A configured MC release is the MC the desktop app runs
      Given "HAL_C2_MC_RELEASE" names an MC release
      When the user starts the desktop app
      Then that release is started

    # A release has no development profile; it would open the installed app's files.
    @desktop @backlog-desktop
    Scenario: A development shell does not start an MC release without a home of its own
      Given "HAL_C2_MC_RELEASE" names an MC release
      When a developer starts the desktop app with --dev and no home directory
      Then no MC is started
      And the desktop app says the release needs a home directory

    # The MC ignores such a home and would open the installed app's files instead.
    @desktop @backlog-desktop
    Scenario Outline: An MC home the MC would not use stops the start
      Given "HAL_C2_MC_HOME" is <home>
      When the user starts the desktop app
      Then no MC is started
      And the desktop app says what "HAL_C2_MC_HOME" must be

      Examples:
        | home                  |
        | a relative path       |
        | a directory in ~/.t3  |

    # The MC ignores an old home as its home too.
    @desktop @backlog-desktop
    Scenario Outline: An old home as the HAL-C2 home stops the start
      Given the desktop app's HAL-C2 home is <home>
      When the user starts the desktop app
      Then no MC is started
      And the desktop app says the HAL-C2 home cannot be an old home

      Examples:
        | home      |
        | ~/.t3     |
        | ~/.hal-c2 |

    @desktop @backlog-desktop
    Scenario: In a checkout without a release the MC runs from source
      Given no MC release is configured or bundled
      When the user starts the desktop app from a checkout
      Then the MC runs from the checkout's source

    @desktop @backlog-desktop
    Scenario: An MC run from source runs in the development environment
      Given "MIX_ENV" is "prod" where the desktop app starts
      When the desktop app starts its MC from a checkout
      Then that MC runs with "MIX_ENV" set to "dev"

    @desktop @backlog-desktop
    Scenario: An MC run from source keeps its access token in the development profile
      Given no HAL-C2 home is set for the desktop app
      When the desktop app starts its MC from a checkout
      Then the shell looks for the MC's access token in the "hal-c2-dev" data directory

    @desktop @backlog-desktop
    Scenario: The MC's JavaScript sidecars run on the desktop app's Node
      When the user starts the desktop app
      Then the MC is told to run its JavaScript sidecars with the Node that runs the desktop host

    @desktop @backlog-desktop
    Scenario: Without a configured port the MC takes the next free one
      Given another program listens on the MC's default port
      When the user starts the desktop app
      Then the MC listens on the next free port

    # Upstream #15044: a host without IPv6 support no longer reports every free port as taken.
    @backlog @desktop @priority-low
    Scenario: A host without IPv6 still finds a free port for the MC
      Given the host was started with IPv6 turned off
      And nothing listens on the MC's default port
      When the user starts the desktop app
      Then the MC listens on its default port

    @desktop @backlog-desktop
    Scenario: An MC already running on the desktop's files is used instead of starting another
      Given the background service runs an MC on the files the desktop app's MC would use
      When the user starts the desktop app
      Then the shell is told that MC's address and the MC's own access token
      And the desktop app starts no MC of its own

    # Upstream #19554: a second launch of the app starts no second backend
    @backlog @desktop
    Scenario: Starting the desktop app again shows the window already open
      Given the desktop app is running
      When the user starts it again
      Then the open window is brought forward
      And no second app or MC is started
      And a link the second start was given is handled by the running app

    # At login the app can start before the background service's MC has said where it
    # listens; the MC that gets the files first keeps them (mc-startup.feature).
    @desktop @backlog-desktop
    Scenario: An MC that takes the desktop's files while the desktop's own MC starts is used instead
      Given the background service starts an MC on the files the desktop app's MC would use
      When the user starts the desktop app before that MC says where it listens
      Then the desktop app's own MC stops, refused the files
      And the shell is told the service MC's address and its own access token

    @desktop @backlog-desktop
    Scenario: A running MC whose access token cannot be read stops the start
      Given the background service runs an MC on the files the desktop app's MC would use
      And that MC's access token cannot be read
      When the user starts the desktop app
      Then the start fails saying an MC already runs on those files
      And the desktop app starts no MC of its own

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

    @desktop @backlog-desktop
    Scenario: Restarting the desktop app connects to the same environment again
      Given the user started the desktop app before
      When the user starts the desktop app again
      Then the shell connects to an MC with the same environment as before

  Rule: Attaching to a running MC with its pairing link

    @desktop @backlog-desktop
    Scenario: Attaching to an MC with its pairing link
      Given an MC is running on this machine
      When the user starts the desktop app with that MC's pairing link
      Then the shell is told that MC's address and the session its pairing link opened
      And the desktop app starts no MC of its own

    @desktop @backlog-desktop
    Scenario: An attached desktop's own client is given the token of an MC on this machine
      Given `mise run mc` runs an MC on this machine
      When the user starts the desktop app with that MC's pairing link
      Then the shell is told that MC's address and the MC's own access token

    @desktop @backlog-desktop
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

    @desktop @backlog-desktop
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

    @desktop @backlog-desktop
    Scenario: An address that is not an MC is refused
      When the user starts the desktop app with the address of a web app
      Then the desktop app says that address is not a HAL-C2 MC

    @desktop @backlog-desktop
    Scenario: Attaching to an MC that is not running
      When the user starts the desktop app with a pairing link for an MC that is not running
      Then the desktop app says it cannot reach the MC at that address

  Rule: Quitting the desktop app stops the MC it started

    @desktop @backlog-desktop
    Scenario: Quitting the desktop app stops its MC
      Given the desktop app started its MC
      When the user quits the desktop app
      Then the MC stops

    @desktop @backlog-desktop
    Scenario: Quitting an attached desktop app leaves the MC running
      Given the desktop app is attached to a running MC
      When the user quits the desktop app
      Then the MC keeps running

    # Upstream #20277: the backend a desktop started exits when that desktop dies.
    @backlog @desktop
    Scenario: A desktop app that dies without quitting does not leave its MC running
      Given the desktop app started its own MC
      When the desktop app is killed
      Then the MC it started stops

    # Upstream #22572: quit gave up on a backend at the same moment its SIGTERM grace ran out, so the
    # SIGKILL that followed died with the app and the backend kept running, holding its database.
    @backlog @desktop
    Scenario: An MC slow to stop is still stopped when the desktop app quits
      Given the desktop app started its MC
      And that MC takes longer than its grace to shut down
      When the user quits the desktop app
      Then the desktop app waits until the MC has been killed before it exits
      And no MC is left running for that home

    # Upstream #22471: the MC's own "launcher is gone" notice hit the closed pipe and crashed it,
    # leaving its runtime record and the home held.
    @backlog @mc @desktop
    Scenario: An MC whose desktop died shuts down as if interrupted
      Given the desktop app started its own MC
      When the desktop app is killed
      Then the MC shuts down cleanly even though nothing reads its output
      And the next MC started for that home starts without finding it still held

  Rule: Start-up failures say what went wrong

    # The desktop app no longer serves a web app.
    @dropped
    Scenario: The app bundle is missing
      Given the desktop app has no built app bundle
      When the user starts the desktop app
      Then the desktop app says the app bundle is missing and how to build it
      And no MC is started

    @desktop @backlog-desktop
    Scenario: The MC fails to start
      Given the MC exits before it answers
      When the user starts the desktop app
      Then the desktop app says the MC failed to start, with its exit code

    # Upstream #25903: a release whose server crashed at boot was restarted forever behind no
    # window, so the app showed nothing at all.
    @backlog @desktop @priority-high
    Scenario: An MC that keeps failing to start offers a way out
      Given the desktop app's own MC fails three times before it answers
      When the user starts the desktop app
      Then a window says HAL-C2 could not start, with the reason and the end of the MC's output
      And it offers the newer build when one is available, else the last build that started on this machine
      And it offers to copy the details and to quit

    # Legacy: apps/desktop/src/app/DesktopApp.ts (handleFatalStartupError)
    @backlog @desktop
    Scenario: A failure while the app starts is shown with the step it failed in
      Given something unexpected fails while the desktop app starts
      When the user starts the desktop app
      Then the desktop app says "HAL-C2 failed to start" with the step it failed in and the reason
      And the app quits afterwards

    # Upstream #25317: a client that could not load offered only Reload, with no way to find
    # out what was wrong.
    @backlog @desktop @priority-low
    Scenario: A window that could not load says how to look into it
      Given the desktop app's window fails to load
      Then it offers to reload
      And it names the "hal-c2 triage" command as it runs on this machine, ready to copy

    # Upstream #25345: the real fix for a broken build was a newer one, and users could neither
    # find it nor share the error.
    @backlog @desktop @priority-low
    Scenario: A window that keeps failing to load offers a newer build and a report
      Given the desktop app's window failed to load
      And a newer build of HAL-C2 is available
      Then beside reload it offers to download the update, and then to restart into it
      And more options offer a reinstall link, the triage command, the error details to copy and a bug report filled in with them
      When the window fails to load again within five minutes
      Then those options are already open

    @backlog @desktop
    Scenario: A failure while the app is already quitting is not shown
      Given the user quit the desktop app while it was starting
      And something fails during that shutdown
      Then no failure message is shown

    # Legacy: apps/desktop/src/app/DesktopAppIdentity.ts (About panel)
    @backlog @desktop @priority-low
    Scenario Outline: The About panel names the app and the build it came from
      Given the desktop app is <build>
      When the user opens the About panel
      Then it shows the app's name and version
      And its build line reads "<build line>"

      Examples:
        | build                                           | build line   |
        | a release built from commit 0123456789abcdef    | 0123456789ab |
        | run from a development checkout                 | unknown      |

    # Legacy: apps/desktop/src/app/DesktopObservability.ts (desktop log files, backend output log, OTLP endpoints)
    @backlog @desktop @priority-low
    Scenario: The desktop app keeps what its MC prints in a log file
      Given the desktop app started its MC
      When the MC prints output or an error
      Then the output is kept in a log file in the app's log folder
      And a failure of the MC shows up there with the time it happened

    @backlog @desktop @priority-low
    Scenario: The desktop app's log files stop growing at a fixed size
      Given the desktop app's log file is full at 10 MiB
      When the app writes more
      Then it starts a new file and keeps at most ten older ones
      And the oldest is removed

    @backlog @desktop @priority-low
    Scenario Outline: A telemetry endpoint set in the environment wins over the saved one
      Given the saved settings name a <signal> endpoint
      And the environment names another <signal> endpoint
      When the user starts the desktop app
      Then the app exports its <signal> to the environment's endpoint
      And the other signals keep their own endpoints

      Examples:
        | signal  |
        | traces  |
        | metrics |
        | logs    |

    # The standard telemetry switch wins over every endpoint, saved or set in the environment.
    @backlog @desktop @priority-low
    Scenario: The standard telemetry switch stops every export, even to a saved endpoint
      Given the saved settings name a traces endpoint
      And the environment sets the standard telemetry switch to "true"
      When the user starts the desktop app
      Then the app exports nothing to any endpoint
      And its trace files and log output are still written

    # The resource attributes are an optional tag. A value the exporter cannot read is ignored
    # as a whole, the way a bad kill switch is, so a machine-wide variable never blocks launch.
    @backlog @desktop @priority-low
    Scenario: A resource attribute setting that cannot be read is ignored at startup
      Given the environment sets the resource attributes to "team=%zz"
      When the user starts the desktop app
      Then the app starts
      And no resource attributes are attached to its telemetry
      And the startup log names the setting as ignored

    # Legacy: apps/desktop/src/backend/DesktopBackendManager.ts (restart delay, readiness timeout)
    @backlog @desktop @priority-high
    Scenario: An MC that exits while the app runs is started again with growing delays
      Given the desktop app started its MC and the window is open
      When the MC exits unexpectedly several times in a row
      Then the app starts it again after half a second
      And each further restart waits twice as long, up to ten seconds

    @backlog @desktop
    Scenario: An MC that does not answer within a minute is reported
      Given the MC starts but never answers
      When the user starts the desktop app
      Then after a minute the desktop app says the MC did not become ready

    # Legacy: apps/desktop/src/app/DesktopLifecycle.ts (SIGINT, SIGTERM)
    @backlog @desktop
    Scenario Outline: Stopping the app from a terminal quits it cleanly
      Given the desktop app started its MC
      When the desktop app is sent <signal>
      Then the MC stops
      And the app exits

      Examples:
        | signal  |
        | SIGINT  |
        | SIGTERM |

    @desktop @backlog-desktop
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

    # Legacy: apps/desktop/src/settings/DesktopAppSettings.ts (readSettings, normalizeDesktopSettingsDocument)
    @backlog @desktop
    Scenario: A damaged desktop settings file starts the app with its defaults
      Given the desktop app's own settings file cannot be read as settings
      When the user starts the desktop app
      Then the app starts with the default desktop settings
      And the file is not repaired until the user changes a setting

    # Upstream #29635: each failed save of the desktop's settings, rewritten on every window move,
    # left one more temporary file beside them.
    @backlog @desktop @priority-low
    Scenario: A desktop settings save that fails leaves no temporary file behind
      Given the desktop app's settings file cannot be replaced for a while
      When the user moves the window several times
      Then no temporary settings files are left beside the settings file
      And the next save that can replace the file saves the window's place

    # Legacy: apps/desktop/src/settings/DesktopAppSettings.ts (normalizeTailscaleServePort)
    @backlog @desktop @priority-low
    Scenario: A saved Tailscale HTTPS port that is not a valid port falls back to 443
      Given the desktop settings file holds a Tailscale HTTPS port outside 1 to 65535
      When the user starts the desktop app
      Then Tailscale HTTPS uses port 443

    @backlog @desktop @priority-low
    Scenario: The version prints without a display
      When the desktop is started with --version and no display is available
      Then it prints its version and exits successfully

  Rule: The app fits the desktop it runs on

    # Upstream #16670: older xdg-open could not find a quoted Exec path; the path is quoted only when it must be.
    # Legacy: apps/desktop/src/app/DesktopLinuxUrlHandler.ts
    @backlog @desktop @priority-low
    Scenario: On Linux a link for HAL-C2 opens the installed app
      Given the user runs the packaged app on Linux
      When the app starts
      Then the system is told that HAL-C2 opens links such as "hal-c2://pair"
      And opening such a link from a browser or another app brings up HAL-C2

    # Upstream #24111: the desktop registered its links but ignored pairing ones, so a remote MC
    # could only be added by pasting its pairing link into Settings.
    @backlog @desktop @priority-high
    Scenario: Opening a pairing link asks before pairing the desktop
      Given the desktop app is running
      When the user opens a "hal-c2://pair" link for the MC at "http://vps.example.com:3773"
      Then the user is asked whether to add the MC at "http://vps.example.com:3773"
      And nothing reaches that MC until the user agrees
      When the user agrees
      Then the desktop pairs with that MC

    # Upstream #24111
    @backlog @desktop
    Scenario: A pairing link that starts the desktop is not lost
      Given the desktop app is not running
      When the user opens a "hal-c2://pair" link
      Then the desktop starts and asks whether to add that MC

    # Upstream #26099: with the local environment off, finding projects never settled, so a pull
    # request link that started the app opened a new thread instead of the pull request.
    @backlog @desktop
    Scenario: A pull request link that starts the desktop waits for a remote MC's projects
      Given the local environment is turned off and the desktop is paired with a remote MC
      And that MC has the project of "https://github.com/hal-c2/hal-c2/pull/42"
      When the user opens that link and the desktop starts
      Then the desktop waits until the remote MC has listed its projects
      And then opens pull request 42 in that project

    # Upstream #24111
    @backlog @desktop @priority-low
    Scenario: A pairing link opened again after it paired is skipped
      Given the desktop paired with a "hal-c2://pair" link
      When the same link is opened again
      Then the user is not asked again

    @backlog @desktop @priority-low
    Scenario: Failing to register the link handler does not stop the app
      Given the user runs the packaged app on Linux
      And the system's link handler registration fails
      When the app starts
      Then the app starts normally

    # Upstream #28368: one of the helpers the link handler registration runs could hang, and the
    # app never finished starting.
    @backlog @desktop @priority-low
    Scenario: A link handler registration that never finishes does not hold up the app
      Given the user runs the packaged app on Linux
      And the system's link handler registration never finishes
      When the app starts
      Then the app starts within seconds
      And the stuck registration is stopped and logged

    # Upstream #28464: restarting for a setting passed the link that launched the app to the new
    # process, which acted on it again.
    @backlog @desktop @priority-low
    Scenario: Restarting the app for a setting does not open its launch link again
      Given the app was started by opening a "hal-c2://pair" link
      When the user changes a setting that restarts the app
      Then the restarted app does not ask to pair again
      And the app's other launch options are kept

    @backlog @desktop @priority-low
    Scenario: An unpackaged app does not take over the system's links
      Given the user runs the app from a development checkout on Linux
      When the app starts
      Then the system's link handlers are left as they were

    # Upstream #17587: macOS grants the browser passkeys entitlement only to web browsers.
    @backlog @desktop @priority-low
    Scenario: On macOS HAL-C2 can be picked as the default web browser
      Given the user runs the packaged app on macOS
      Then HAL-C2 is offered among the system's choices of default web browser
      And on Linux and Windows the app does not offer itself for web links

    # Upstream #19118: macOS 26 offers Messages and Mail codes in any field unless the app opts out.
    @backlog @desktop @priority-low
    Scenario: On macOS verification codes are offered only in fields that ask for one
      Given the user runs the app on macOS 26 or later
      And a verification code has just arrived in Messages
      When the user focuses the composer or another text field
      Then the system does not offer to fill in the code

    @backlog @desktop @priority-low
    Scenario: A web link opened with HAL-C2 starts a thread showing the page
      Given HAL-C2 is the default web browser on macOS
      When the user opens "https://example.com" from another app
      Then a new thread with no project opens
      And its browser fills the panel showing "https://example.com"

    @backlog @desktop @priority-low
    Scenario: Web links that arrive before the app is ready are all opened in order
      Given HAL-C2 is the default web browser on macOS and is not running
      When the user opens two web links from another app
      Then HAL-C2 starts and opens a thread for each link, in the order they were opened
      And a link that arrives while the window is reloading is opened once it is back

    # Legacy: apps/desktop/src/linuxSecretStorage.ts, apps/desktop/src/settings/DesktopAppSettings.ts (linuxPasswordStore)
    # Uncertain: depends on how the Qt desktop stores secrets; may be dropped with Electron's safeStorage.
    @backlog @desktop @priority-low
    Scenario Outline: On Linux the app picks where it keeps secrets from the desktop environment
      Given the user runs the app on Linux with the password store set to "<setting>"
      And the desktop environment is "<desktop>"
      When the app starts
      Then secrets are kept in <store>

      Examples:
        | setting         | desktop | store             |
        | auto            | KDE     | the KDE wallet    |
        | auto            | GNOME   | the GNOME keyring |
        | auto            | Sway    | the GNOME keyring |
        | kwallet6        | GNOME   | the KDE Wallet 6  |
        | gnome-libsecret | KDE     | the GNOME keyring |

    @backlog @desktop @priority-low
    Scenario: A password store given on the command line wins over the setting
      Given the password store setting is "kwallet"
      When the user starts the app on Linux with the password store "gnome-libsecret" on the command line
      Then secrets are kept in the GNOME keyring

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

  Rule: What only a browser tab did has no replacement

    # Legacy: apps/web/src/lib/chunkReloadGuard.ts. The native app ships whole; nothing loads lazily from a server.
    @dropped @desktop
    Scenario: A page that went stale after an update reloads once by itself
      Given a web page was loaded before the app was updated
      When it asks for a script the update removed
      Then the page reloads once to pick up the new version
      And a second failure is shown instead of reloading again

    # Legacy: apps/web/src/lib/bootError.ts. The native app has no boot splash to replace.
    @dropped @desktop
    Scenario: A web page that fails to start says it could not load and offers Reload
      Given the web page fails while starting
      Then the page says "HAL-C2 could not load."
      And it offers a Reload button

    # Legacy: apps/web/src/lib/favicon.ts, apps/web/public/manifest.webmanifest, apps/web/index.html.
    # The tab's icon, its installable-app manifest and its theme colour are the browser's.
    # Upstream #30420: added the large icons Firefox on Android needs to install the web app as an app.
    @dropped @desktop
    Scenario: A browser tab carries the app's icon and can be installed as an app
      Given the user opens the app in a browser
      Then the tab shows the app's icon
      And the browser offers to install it as a standalone app

    # Legacy: apps/web/src/legacyStorage.ts. The state was the browser's own storage, which the native app never read.
    @dropped @desktop
    Scenario: A browser that used the app before the rename keeps its saved state
      Given a browser saved the app's settings and connections under the names from before the rename
      When the user opens the app in that browser after the rename
      Then the settings and connections are carried over to the new names
      And anything already saved under a new name is left as it is

    # Legacy: apps/web/src/clientPersistenceStorage.ts. An older browser copy of the device settings; the native app keeps its own.
    @dropped @desktop
    Scenario: Device settings a browser saved in the older form read with today's follow-up default
      Given a browser holds device settings saved in the older form, with follow-ups set to queue
      When the user opens the app in that browser
      Then the other settings are as saved
      And follow-ups use the current default

  Rule: Browser screenshots keep their own files

  @backlog @desktop @priority-low
  Scenario: Two browser screenshots of the same page never overwrite each other
    Given the user takes two screenshots of the same page in the same instant
    Then each is saved under its own file name
