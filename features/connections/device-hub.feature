# Sources:
#   apps/server-ex/lib/hal_c2/devices.ex (device.list, device.open, device.close, device.shutdown,
#     device.detail, device.action, device.testHost, devices shape, platform reasons)
#   apps/server-ex/lib/hal_c2/devices/actions.ex (per-platform actions, DeviceActionUnavailableError)
#   apps/server-ex/lib/hal_c2/devices/proxy.ex (/api/device-hub/*, route allowlist, scopes, cluster relay)
#   apps/server-ex/lib/hal_c2/mcp/devices.ex (device_list, device_open, device_screenshot, device_close,
#     agent device access with the project override, quick start)
#   docs/user/devices.md (Agents and devices: a device an agent opens floats over the chat)
#   docs/user/devices.md (Device panel, agent access, remote streaming)
#   docs/internals/devices.md
#   packages/contracts/src/device.ts
#   Shared domain: settings/device-hosts.feature holds SSH device hosts (dropped for cluster MCs),
#   settings/integrations.feature holds device support, agent access and tool updates,
#   mobile/usage-diagnostics-devices.feature holds the phone's device viewer.
#   apps/server/src/device/DeviceService.ts (boot failure reasons, open refused when support is off)
#   apps/server/src/device/DeviceActions.ts (settings and permission actions per platform)
#   apps/server/src/device/LocalDeviceHost.ts (hub supervisor restarts)
#   apps/server/src/device/AgentDeviceShim.ts (device command refused before a device is opened)
#   apps/server/src/device/DeviceHubProxy.ts, DeviceHubProxy.test.ts (path allow-lists, operate scope per
#     route, header and credential stripping, origin rewrite, socket pump)

Feature: Device hub on an MC
  Each MC offers the iOS Simulators and Android Emulators on its own machine. Threads open
  devices, the user watches them through the MC, and agents drive the same devices.

  Background:
    Given an MC with device support enabled
    And a paired client

  @mc
  Scenario: Nothing is installed until device support is enabled
    Given an MC with device support disabled
    When a client lists devices
    Then the MC installs and starts no device tools

  @mc
  Scenario: The device hub is installed on first use
    When a client lists devices for the first time
    Then the MC installs the device hub under its home's tools folder
    And runs it on a loopback port

  @mc
  Scenario Outline: A platform the machine cannot run explains why
    Given <situation>
    When a client lists devices
    Then <platform> devices are unavailable because "<reason>"

    Examples:
      | situation                              | platform | reason                                   |
      | the MC runs on Linux                   | iOS      | iOS Simulators need macOS with Xcode.    |
      | a Mac without Xcode command line tools | iOS      | Xcode command line tools were not found. |
      | no Android SDK is installed            | Android  | Android SDK was not found.               |
      | the SDK lacks platform tools           | Android  | Android SDK Platform-Tools are missing   |
      | the SDK lacks the emulator             | Android  | Android Emulator is missing              |

  # Legacy: apps/server/src/device/LocalDeviceHost.test.ts (Android SDK availability)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (platform_reason, android_sdk)
  @backlog @mc
  Scenario Outline: An Android SDK without current command-line tools says what to install
    Given an Android SDK with platform tools and the emulator, <tools>
    When a client lists devices
    Then Android devices are <result>

    Examples:
      | tools                                                  | result                                                                                               |
      | and no command-line tools                              | unavailable because "Command-line Tools (latest) are missing"                                        |
      | and only the old command-line tools under tools/bin    | unavailable because the tools are an older, unsupported version, naming the SDK folder and what to install |
      | and both the old and the latest command-line tools     | available                                                                                            |

  # Legacy: apps/server/src/device/LocalDeviceHost.test.ts (standard macOS SDK without ANDROID_HOME,
  #   detected tools put on the helper PATH)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (android_sdk, host_env)
  @backlog @mc
  Scenario: The Android SDK is found where Android Studio puts it
    Given no ANDROID_HOME is set
    And the SDK is in the user's home under Library/Android/sdk with every tool installed
    When a client lists devices
    Then Android devices are available
    And the device tools run with the SDK's platform-tools and emulator folders ahead of PATH

  # Legacy: apps/server/src/device/LocalDeviceHost.test.ts (Node.js missing, nothing installed)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (node_executable)
  @backlog @mc
  Scenario: Device support without Node.js says how to fix it
    Given the MC's machine has no node on its PATH
    When a client opens a device for the first time
    Then it fails saying device support requires Node.js and to put node on PATH, then retry
    And no tool is installed

  @mc
  Scenario: Opening a device boots it and records it in the thread
    Given a shut-down simulator
    When a client opens it in a thread
    Then the MC boots the simulator
    And the thread lists the device as open for the Device panel and for agents

  @mc
  Scenario: Opening a device without booting leaves it off
    When a client opens a shut-down simulator in a thread without booting
    Then the device is recorded as open
    And stays shut down

  @mc
  Scenario: Opening a device that is gone fails
    When a client opens a device id the hub does not list
    Then the MC answers that the device was not found

  # Legacy: apps/server/src/device/DeviceService.test.ts (stopped AVD boot, boot progress)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (avds, booting)
  @backlog @mc
  Scenario: A stopped Android virtual device boots under its running serial
    Given an Android virtual device "Pixel_API_35" that is not running
    And a client has asked the MC to set up device support
    Then the device is listed by its name as not booted
    When a client opens "Pixel_API_35" in a thread
    Then clients see "Pixel_API_35" as booting until the boot finishes
    And the thread's session names the emulator's serial
    And the device is listed once, under that serial

  # Legacy: apps/server/src/device/DeviceService.test.ts (capture recovery after close and shutdown)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (post_shutdown ios)
  @backlog @mc
  Scenario Outline: A simulator closed or powered off streams afresh when it is opened again
    Given a thread with an open iOS simulator that is being streamed
    When a client <action>
    Then the simulator's stream capture is released
    And opening it again starts a new capture

    Examples:
      | action                                  |
      | closes it and asks to power it off      |
      | shuts the simulator down                |

  # Legacy: apps/server/src/device/DeviceService.test.ts (serve-sim rejects a shutdown)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (post_shutdown)
  @backlog @mc
  Scenario Outline: A shutdown the hub rejects stands only when the simulator is off
    Given a booted iOS simulator in the MC's device list
    And the hub rejects the shutdown request
    And the hub then reports the simulator <state>
    When a client shuts the simulator down
    Then the shutdown <outcome>
    And the simulator is listed as <listed>

    Examples:
      | state                     | outcome  | listed    |
      | off                       | succeeds | not booted |
      | booted                    | fails    | booted    |
      | missing from a partial list | fails  | booted    |

  # Legacy: apps/server/src/device/DeviceService.test.ts (shutdown refresh failure)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (shutdown_device)
  @backlog @mc
  Scenario: A shutdown stands when the device list cannot be read afterwards
    Given a thread with an open emulator
    And the hub cannot list devices once the emulator is off
    When a client closes the device and asks to power it off
    Then the request succeeds
    And the thread lists no devices
    And the emulator is listed as not booted

  @backlog @mc
  Scenario Outline: A device that cannot boot is not opened and the user is told why
    Given a shut-down <platform> device and <situation>
    When a client opens it in a thread
    Then the device does not open in the thread
    And the user is told <reason>

    Examples:
      | platform | situation                                | reason                             |
      | iOS      | the disk is full                         | the device ran out of disk space   |
      | Android  | the disk is full                         | the device ran out of disk space   |
      | iOS      | the boot takes longer than three minutes | the boot timed out                 |
      | Android  | the boot takes longer than three minutes | the boot timed out                 |
      | iOS      | the simulator fails to launch            | the device failed to launch        |

  @backlog @mc
  Scenario: Turning device support off while a device boots fails the open
    Given a device is booting for a thread
    When the user turns device support off
    Then the open fails saying device support was turned off while the device was opening

  @mc
  Scenario: Closing a device leaves it running
    Given a thread with an open simulator
    When a client closes that device in the thread
    Then the thread no longer lists it
    And the simulator keeps running

  @mc
  Scenario: Closing every device in a thread
    Given a thread with two open devices
    When a client closes all devices in the thread
    Then the thread lists no devices

  @mc
  Scenario: Closing with power off shuts the device down
    Given a thread with an open simulator
    When a client closes it and asks to power it off
    Then the simulator shuts down

  @mc
  Scenario: Shutting a device down closes it in every thread
    Given a simulator open in two threads
    When a client shuts the simulator down
    Then neither thread lists it

  @mc
  Scenario: Watchers see device changes as they happen
    Given a client subscribed to devices
    When another client opens a device
    Then the subscribed client receives the new device state

  @mc
  Scenario: A client reads a device's settings and foreground app
    When a client asks for a booted device's detail
    Then the MC answers with its settings and foreground app

  @mc
  Scenario Outline: A device action runs and returns the fresh detail
    When a client runs "<action>" on a booted <platform> device
    Then the MC answers with the device's detail after the action

    Examples:
      | action         | platform |
      | setAppearance  | iOS      |
      | openUrl        | iOS      |
      | sendPush       | iOS      |
      | setOrientation | Android  |
      | launchApp      | Android  |

  @mc
  Scenario Outline: An action the platform lacks is unavailable
    When a client runs "<action>" on a booted <platform> device
    Then the MC answers that the action is unavailable on that platform

    Examples:
      | action         | platform |
      | setOrientation | iOS      |
      | sendPush       | Android  |
      | setLiquidGlass | Android  |

  # Legacy: apps/server/src/device/DeviceActions.test.ts (supportsAction, runDeviceAction)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/actions.ex
  @backlog @mc
  Scenario Outline: An accessibility toggle belongs to one platform
    When a client turns <toggle> on for a booted <platform> device
    Then the MC answers <answer>
    And no command runs on the device when it is unavailable

    Examples:
      | toggle         | platform | answer                                           |
      | VoiceOver      | iOS      | with the device's detail after the change        |
      | VoiceOver      | Android  | that the action is unavailable on that platform  |
      | network access | Android  | with the device's detail after the change        |
      | network access | iOS      | that the action is unavailable on that platform  |

  # Legacy: apps/server/src/device/DeviceActions.test.ts (rotation, push payload)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/actions.ex (orientation, push)
  @backlog @mc
  Scenario Outline: A rotation reaches an emulator and a physical phone differently
    When a client sets the orientation of <device> to landscape
    Then the MC <how>

    Examples:
      | device                     | how                                                 |
      | an Android emulator        | tilts the emulator's accelerometer to that side     |
      | a physical Android phone   | locks the phone's rotation to that side             |

  @backlog @mc
  Scenario: A plain push message arrives as a notification alert
    When a client sends the push "Hello" to an app on a booted iOS simulator
    Then the simulator receives a notification whose alert is "Hello"
    And a client that sends a full payload has that payload delivered as written

  # Legacy: apps/server/src/device/DeviceActions.test.ts (missing helper, exit codes, unreadable settings)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/actions.ex (requires a helper)
  @backlog @mc
  Scenario: An accessibility change that needs a helper the install lacks says so
    Given the hub install has no accessibility helper
    When a client sets a colour filter on a booted iOS device
    Then the MC answers that the action requires a helper and to set up device support again

  @backlog @mc
  Scenario: A device command that fails is reported without its output
    Given a booted iOS device whose appearance command exits with an error and a message
    When a client sets its appearance to dark
    Then the MC answers that the appearance change failed with the exit code
    And the answer does not repeat the command's own message

  @backlog @mc
  Scenario: A setting the MC cannot read is left unknown instead of failing the read
    Given a booted device whose settings commands all fail
    When a client asks for its detail
    Then the detail is returned with no settings and no foreground app

  @backlog @mc
  Scenario Outline: A client changes a device's appearance or accessibility setting
    When a client sets <setting> on a booted <platform> device to <value>
    Then the MC answers with the device's detail after the change

    Examples:
      | setting           | platform | value       |
      | text size         | iOS      | extra large |
      | text size         | Android  | 1.3         |
      | reduce motion     | iOS      | on          |
      | reduce motion     | Android  | on          |
      | increase contrast | iOS      | on          |
      | Liquid Glass      | iOS      | off         |

  @backlog @mc
  Scenario Outline: A client grants or revokes an app permission on a booted device
    When a client sets the <permission> permission to <state> on a booted <platform> device
    Then the MC answers with the device's detail after the change

    Examples:
      | permission    | state   | platform |
      | camera        | granted | iOS      |
      | notifications | granted | Android  |
      | location      | revoked | Android  |

  @backlog @mc
  Scenario Outline: A client sets a device's location and later clears it
    When a client sets the location of a booted <platform> device to "<place>"
    And a client clears the location of that device
    Then the MC answers with the device's detail after each change

    Examples:
      | platform | place        |
      | iOS      | Reykjavik    |
      | Android  | Reykjavik    |

  @backlog @mc
  Scenario Outline: A client stops an app that is running on a booted device
    When a client stops "the shop app" on a booted <platform> device
    Then the MC answers with the device's detail after the action

    Examples:
      | platform |
      | iOS      |
      | Android  |

  @mc
  Scenario: Agent device access needs every prerequisite
    Given agents have not been granted device access
    When an agent asks for a device
    Then it is told device access requires device support, agent access and an available platform

  @mc
  Scenario: A client watches a device stream through the MC
    When a client with read access opens a device's stream through the MC
    Then the stream is relayed from the hub for as long as the client reads it

  @mc
  Scenario: Controlling a device needs the operate scope
    Given a session without the operate scope
    When it sends a control request through the device proxy
    Then the MC refuses it as needing the operate scope

  @mc
  Scenario: The device proxy refuses an unknown credential
    When a request reaches the device proxy with an invalid credential
    Then the MC answers that the credential is invalid

  @mc
  Scenario: Hub routes outside the Device panel's needs stay closed
    When a client asks the device proxy for the hub's shell route
    Then the MC answers not found

  @mc
  Scenario: A read-only hub route refuses writes
    When a client posts to a read-only device route
    Then the MC answers the method is not allowed

  @mc
  Scenario: A stream authorised by a ticket in its address
    Given a client that cannot set headers on an image stream
    When it opens the stream with a WebSocket ticket in the query
    Then the MC accepts the ticket while it lasts

  @mc
  Scenario Outline: A hub that cannot answer is reported
    Given <situation>
    When a client asks for a device route through the proxy
    Then the MC answers <status>

    Examples:
      | situation                              | status |
      | the device hub is not running          | 503    |
      | the hub does not answer                | 502    |
      | the hub does not answer in time        | 504    |
      | the owning cluster member is offline   | 502    |

  # Legacy: apps/server/src/device/DeviceHubProxy.ts, DeviceHubProxy.test.ts (controlsDevice,
  #   read-only sessions get 403 on the input sockets and no upstream request is made)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/proxy.ex (controls)
  @backlog @mc
  Scenario Outline: A session that may only read can watch the device list but not drive a device
    Given a session with the read scope and without the operate scope
    When it opens the WebSocket "<socket>" through the device proxy
    Then the MC answers <answer>
    And <upstream>

    Examples:
      | socket                       | answer                         | upstream                      |
      | /api/devices/ws              | by relaying the socket         | the hub receives the socket   |
      | /vendor/serve-sim/helper/ws  | that the operate scope is needed | the hub receives no request |
      | /vendor/serve-emu/ws         | that the operate scope is needed | the hub receives no request |

  # Legacy: apps/server/src/device/DeviceHubProxy.ts (ALLOWED_WS_PATHS, controlsDevice on stream-mode
  #   and stream-settings)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/proxy.ex (@mutable, controls)
  @backlog @mc
  Scenario Outline: Changing the Android stream's mode or settings needs the operate scope
    Given a session with the read scope and without the operate scope
    When it <method> "<path>" through the device proxy
    Then the MC answers <answer>

    Examples:
      | method | path                                | answer                              |
      | reads  | /vendor/serve-emu/api/stream-mode   | with the stream mode                |
      | posts  | /vendor/serve-emu/api/stream-mode   | that the operate scope is needed    |
      | reads  | /vendor/serve-emu/api/stream-settings | with the stream settings          |
      | posts  | /vendor/serve-emu/api/stream-settings | that the operate scope is needed  |

  # Legacy: apps/server/src/device/DeviceHubProxy.ts, DeviceHubProxy.test.ts (header allow-list,
  #   wsTicket and hostId removed from the upstream query, the upstream response released)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/proxy.ex (@dropped_request, @credentials)
  @backlog @mc
  Scenario: The hub never sees the client's credentials
    Given a client that authorises with a WebSocket ticket in the query, a cookie and a bearer header
    When it requests a device route through the proxy
    Then the request the hub receives has none of the ticket, the cookie or the bearer header
    And it has no host id parameter, which belongs to the MC

  # Legacy: apps/server/src/device/DeviceHubProxy.ts (Origin is rewritten to the hub's own)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/proxy.ex (relay_init origin)
  @backlog @mc
  Scenario: A mutation reaches a hub that checks where it came from
    Given the Android hub refuses a change whose origin is not its own
    When a client with the operate scope posts a stream setting through the device proxy
    Then the hub accepts the change

  # Legacy: apps/server/src/device/DeviceHubProxy.ts (WebSocket pump: whichever side closes first ends
  #   the other; 10 s to open)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/proxy.ex (ProxySocket, await_upgrade)
  @backlog @mc
  Scenario Outline: A relayed device socket ends when either end does
    Given a client has a device socket open through the proxy
    When <ending>
    Then the other end of the socket is closed too

    Examples:
      | ending                         |
      | the hub closes the socket      |
      | the client closes the socket   |
      | the hub fails to answer the upgrade within ten seconds |

  # Legacy: apps/server/src/device/DeviceHubProxy.ts (cache-control: no-store, no-transform)
  # Likely already implemented: apps/server-ex/lib/hal_c2/devices/proxy.ex (relay)
  @backlog @mc
  Scenario: A live stream is never cached or recompressed on the way to the client
    When a client opens a device's MJPEG stream through the proxy
    Then the response says it must not be stored or transformed
    And frames reach the client as the hub sends them

  @backlog @mc
  Scenario: A device hub that exits is restarted, waiting longer after each quick exit
    Given the device hub is running
    When the hub exits
    Then the MC restarts it after one second
    And each further exit within a minute of starting doubles the wait, up to 30 seconds
    And a hub that ran for a minute restarts after the short wait again

  @mc
  Scenario: An agent lists the devices it may use
    Given agents have been granted device access
    When an agent lists devices
    Then it sees every host's devices and why a host has none
    And which of them are open in its own thread

  @mc
  Scenario: An agent opens a device and learns how to drive it
    Given agents have been granted device access
    When an agent opens an iOS Simulator
    Then the device opens in the thread for the user to watch
    And the agent is told the device command and arguments pinned to that device

  @mc
  Scenario: A device chosen by platform prefers one already running
    Given agents have been granted device access
    And one of two Android Emulators is running
    When an agent opens an Android device without naming one
    Then the running emulator is opened

  @mc
  Scenario Outline: An agent's device request that cannot be met says what to do
    Given agents have been granted device access
    And <situation>
    When an agent opens a device
    Then the agent is told <advice>

    Examples:
      | situation                                           | advice                                   |
      | device support is turned off                        | to ask the user to turn device support on |
      | the named device does not exist                     | to list the devices for current ids      |
      | no simulators or emulators exist                    | to list the devices to see why           |
      | both iOS and Android devices exist and none is named | to choose a platform or a device         |

  @mc
  Scenario: An agent takes a screenshot of the device it opened last
    Given an agent has opened a device in its thread
    When the agent asks for a device screenshot
    Then it receives the screen as an image with its width and height

  @mc
  Scenario: A screenshot with no open device asks the agent to open one
    Given no device is open in the agent's thread
    When the agent asks for a device screenshot
    Then the agent is told to open a device first

    # Legacy: apps/server/src/device/DeviceService.test.ts (discovery after a restart)
    # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (device_list rediscovery)
    @backlog @mc
    Scenario: A named device can be captured right after the MC restarts
      Given device support is on and no client has listed devices since the MC started
      When a screenshot of a device is asked for by its id
      Then the MC finds the device itself
      And answers with its screen image

    # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (write_shim)
    @backlog @mc
    Scenario: A device command run before any device is opened is refused with a pointer to open one
      Given an agent has not opened a device in its thread
      When the agent runs a device command without the device's config and session
      Then the command fails telling the agent to open a device first

  @mc
  Scenario: An agent closes its device and can power it off
    Given an agent has opened a device in its thread
    When the agent closes the device asking to shut it down
    Then the device leaves the thread and powers off

  @mc
  Scenario: A project's agent device access overrides the environment's
    Given agents have device access on the environment
    And the thread's project turns agent device access off
    When an agent in that thread asks for a device
    Then the agent is told agent device access is turned off

  @backlog @desktop
  Scenario: A device an agent opens floats over the chat
    Given auto-show floating preview is on
    When an agent opens a device in the thread the user is watching
    Then the device floats over the conversation, the way an agent-driven browser does

  @backlog @desktop
  Scenario: A device an agent opens waits in the side panel when auto-show is off
    Given auto-show floating preview is off
    When an agent opens a device in the thread the user is watching
    Then the device opens as a side panel tab instead of floating
