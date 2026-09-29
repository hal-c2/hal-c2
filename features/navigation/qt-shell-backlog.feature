# Sources:
#   apps/desktop-qt/parity/features.backlog.test.ts (in-app-preview, right-panel-surfaces,
#   app-updates, ssh-environments, network-access, open-workspace-activation)
#   apps/desktop-qt/parity/web-parity.test.ts (thread jump, composer send chords, toolbar chords)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (window shortcuts)
#   apps/desktop-qt/qml/HalC2/Bricks/RightPanel.qml
#   docs/user/updating.md
#   docs/user/remote-access.md

Feature: Desktop shell gaps
  Behaviour the Electron desktop app has that the native desktop shell does not yet
  deliver, and known shell bugs, written as the behaviour the shell must end up with.

  Rule: In-app preview

    @backlog @desktop
    Scenario: The preview opens beside the thread
      Given a dev server is listening locally for the thread's project
      When the user toggles the preview
      Then the page opens in a browser tab beside the thread
      And the user is not told that the preview is desktop-only

    @backlog @desktop
    Scenario: The preview reloads when the agent restarts the dev server
      Given the preview is showing the dev server
      When the agent restarts the dev server
      Then the preview reloads

    @backlog @desktop
    Scenario: Closing the preview tab ends its session
      Given the preview is open
      When the user closes the preview tab
      Then the preview session on the server is closed

  Rule: Right panel surfaces

    @backlog @desktop
    Scenario: The right panel offers every surface
      When the user looks at what can be added to the right panel
      Then pull request list and connected devices are offered next to diff, files, terminal and pull request

    # Not native yet: the hub streams iOS as AVCC H.264 (MJPEG fallback) and Android as
    # SEMU-framed H.264 over a WebSocket, and Qt has no decoder for either without
    # QtMultimedia/FFmpeg; input needs the hub's binary WebSocket through the node's proxy.
    @backlog @desktop
    Scenario: A device tab streams a device screen
      Given a simulator is booted
      When the user adds a device tab for it
      Then the tab streams the simulator's screen

    @backlog @desktop
    Scenario: A pull requests tab lists open pull requests
      When the user adds a pull requests tab
      Then the open pull requests are listed
      When the user opens one
      Then its review is shown

  Rule: App updates

    @backlog @desktop
    Scenario: A newer release shows an update notice
      Given a newer release exists on the user's update channel
      When the app checks for updates
      Then the sidebar shows an update notice with that version

    @backlog @desktop
    Scenario: Restarting installs a downloaded update
      Given an update has been downloaded
      When the user restarts to update
      Then the update is installed
      And the app relaunches into the same windows

    @backlog @desktop
    Scenario: Changing update channel takes effect on the next check
      When the user switches to the Nightly update channel
      Then the next update check looks at the Nightly channel

  Rule: SSH environments

    @backlog @desktop
    Scenario: Adding an SSH host starts HAL-C2 there
      Given the user's SSH config names the host "build-box"
      When the user adds "build-box" in Connections settings
      Then HAL-C2 starts on "build-box"
      And "build-box" is added as an environment

    @backlog @desktop
    Scenario: SSH passwords are not remembered by the page
      When the user answers a password prompt while adding an SSH host
      Then the password is not kept in the app's page state

    @backlog @desktop
    Scenario: A saved SSH environment reconnects after a restart
      Given "build-box" was added over SSH
      When the user restarts the app
      Then "build-box" reconnects without pairing again

  Rule: Network access

    @backlog @desktop
    Scenario: Turning on network access shares the environment on the network
      When the user turns on network access
      Then the environment listens on the local network
      And the user is shown a pairing link

    @backlog @desktop
    Scenario: Tailscale serve advertises the tailnet address
      Given Tailscale is available
      When the user turns on network access with Tailscale serve
      Then the tailnet HTTPS address is advertised

    @backlog @desktop
    Scenario: Turning off network access stops sharing
      Given network access is on
      When the user turns off network access
      Then the environment only listens on this computer

  Rule: Opening a folder from outside

    @backlog @desktop
    Scenario: Opening a folder while the app runs adds it to the running window
      Given the app is running
      When the user launches the app again with a folder path
      Then the running window adds the folder as a project and opens a new thread there
      And no second server starts

    @backlog @desktop
    Scenario: Opening a folder that is already a project reuses it
      Given "~/code/api" is already a project
      When the user launches the app again with "~/code/api"
      Then a new thread opens in the existing project

  Rule: Known shell keyboard bugs

    # The page resolves mod+1…9 for the shell today (apps/web/src/shell/HalC2ShellBridge.tsx);
    # this passes once the native sidebar owns the order.
    @backlog @desktop
    Scenario: Thread number shortcuts work in the native desktop shell
      Given the thread list shows at least three threads
      When the user presses mod+3
      Then the third thread opens

    @backlog @desktop
    Scenario: The previous worktree shortcut works in the native composer
      Given the native composer has keyboard focus
      When the user presses mod+shift+l
      Then the composer switches to the previous worktree
