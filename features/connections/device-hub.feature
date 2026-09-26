# Sources:
#   apps/server-ex/lib/t3/devices.ex (device.list, device.open, device.close, device.shutdown,
#     device.detail, device.action, device.testHost, devices shape, platform reasons)
#   apps/server-ex/lib/t3/devices/actions.ex (per-platform actions, DeviceActionUnavailableError)
#   apps/server-ex/lib/t3/devices/proxy.ex (/api/device-hub/*, route allowlist, scopes, cluster relay)
#   apps/server-ex/lib/t3/mcp/devices.ex (device_list, device_open, device_screenshot, device_close,
#     agent device access with the project override, quick start)
#   docs/user/devices.md (Agents and devices: a device an agent opens floats over the chat)
#   docs/user/devices.md (Device panel, agent access, remote streaming)
#   docs/internals/devices.md
#   packages/contracts/src/device.ts
#   Shared domain: settings/device-hosts.feature holds SSH device hosts (dropped for cluster nodes),
#   settings/integrations.feature holds device support, agent access and tool updates,
#   mobile/usage-diagnostics-devices.feature holds the phone's device viewer.

Feature: Device hub on a node
  Each node offers the iOS Simulators and Android Emulators on its own machine. Threads open
  devices, the user watches them through the node, and agents drive the same devices.

  Background:
    Given a node with device support enabled
    And a paired client

  @node
  Scenario: Nothing is installed until device support is enabled
    Given a node with device support disabled
    When a client lists devices
    Then the node installs and starts no device tools

  @node
  Scenario: The device hub is installed on first use
    When a client lists devices for the first time
    Then the node installs the device hub under its home's tools folder
    And runs it on a loopback port

  @node
  Scenario Outline: A platform the machine cannot run explains why
    Given <situation>
    When a client lists devices
    Then <platform> devices are unavailable because "<reason>"

    Examples:
      | situation                                  | platform | reason                                              |
      | the node runs on Linux                     | iOS      | iOS Simulators need macOS with Xcode.               |
      | a Mac without Xcode command line tools     | iOS      | Xcode command line tools were not found.            |
      | no Android SDK is installed                | Android  | Android SDK was not found.                          |
      | the SDK lacks platform tools               | Android  | Android SDK Platform-Tools are missing              |
      | the SDK lacks the emulator                 | Android  | Android Emulator is missing                         |

  @node
  Scenario: Opening a device boots it and records it in the thread
    Given a shut-down simulator
    When a client opens it in a thread
    Then the node boots the simulator
    And the thread lists the device as open for the Device panel and for agents

  @node
  Scenario: Opening a device without booting leaves it off
    When a client opens a shut-down simulator in a thread without booting
    Then the device is recorded as open
    And stays shut down

  @node
  Scenario: Opening a device that is gone fails
    When a client opens a device id the hub does not list
    Then the node answers that the device was not found

  @node
  Scenario: Closing a device leaves it running
    Given a thread with an open simulator
    When a client closes that device in the thread
    Then the thread no longer lists it
    And the simulator keeps running

  @node
  Scenario: Closing every device in a thread
    Given a thread with two open devices
    When a client closes all devices in the thread
    Then the thread lists no devices

  @node
  Scenario: Closing with power off shuts the device down
    Given a thread with an open simulator
    When a client closes it and asks to power it off
    Then the simulator shuts down

  @node
  Scenario: Shutting a device down closes it in every thread
    Given a simulator open in two threads
    When a client shuts the simulator down
    Then neither thread lists it

  @node
  Scenario: Watchers see device changes as they happen
    Given a client subscribed to devices
    When another client opens a device
    Then the subscribed client receives the new device state

  @node
  Scenario: A client reads a device's settings and foreground app
    When a client asks for a booted device's detail
    Then the node answers with its settings and foreground app

  @node
  Scenario Outline: A device action runs and returns the fresh detail
    When a client runs "<action>" on a booted <platform> device
    Then the node answers with the device's detail after the action

    Examples:
      | action         | platform |
      | setAppearance  | iOS      |
      | openUrl        | iOS      |
      | sendPush       | iOS      |
      | setOrientation | Android  |
      | launchApp      | Android  |

  @node
  Scenario Outline: An action the platform lacks is unavailable
    When a client runs "<action>" on a booted <platform> device
    Then the node answers that the action is unavailable on that platform

    Examples:
      | action         | platform |
      | setOrientation | iOS      |
      | sendPush       | Android  |
      | setLiquidGlass | Android  |

  @node
  Scenario: Agent device access needs every prerequisite
    Given agents have not been granted device access
    When an agent asks for a device
    Then it is told device access requires device support, agent access and an available platform

  @node
  Scenario: A client watches a device stream through the node
    When a client with read access opens a device's stream through the node
    Then the stream is relayed from the hub for as long as the client reads it

  @node
  Scenario: Controlling a device needs the operate scope
    Given a session without the operate scope
    When it sends a control request through the device proxy
    Then the node refuses it as needing the operate scope

  @node
  Scenario: The device proxy refuses an unknown credential
    When a request reaches the device proxy with an invalid credential
    Then the node answers that the credential is invalid

  @node
  Scenario: Hub routes outside the Device panel's needs stay closed
    When a client asks the device proxy for the hub's shell route
    Then the node answers not found

  @node
  Scenario: A read-only hub route refuses writes
    When a client posts to a read-only device route
    Then the node answers the method is not allowed

  @node
  Scenario: A stream authorised by a ticket in its address
    Given a client that cannot set headers on an image stream
    When it opens the stream with a WebSocket ticket in the query
    Then the node accepts the ticket while it lasts

  @node
  Scenario Outline: A hub that cannot answer is reported
    Given <situation>
    When a client asks for a device route through the proxy
    Then the node answers <status>

    Examples:
      | situation                              | status |
      | the device hub is not running          | 503    |
      | the hub does not answer                | 502    |
      | the hub does not answer in time        | 504    |
      | the owning cluster member is offline   | 502    |

  @node
  Scenario: An agent lists the devices it may use
    Given agents have been granted device access
    When an agent lists devices
    Then it sees every host's devices and why a host has none
    And which of them are open in its own thread

  @node
  Scenario: An agent opens a device and learns how to drive it
    Given agents have been granted device access
    When an agent opens an iOS Simulator
    Then the device opens in the thread for the user to watch
    And the agent is told the device command and arguments pinned to that device

  @node
  Scenario: A device chosen by platform prefers one already running
    Given agents have been granted device access
    And one of two Android Emulators is running
    When an agent opens an Android device without naming one
    Then the running emulator is opened

  @node
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

  @node
  Scenario: An agent takes a screenshot of the device it opened last
    Given an agent has opened a device in its thread
    When the agent asks for a device screenshot
    Then it receives the screen as an image with its width and height

  @node
  Scenario: A screenshot with no open device asks the agent to open one
    Given no device is open in the agent's thread
    When the agent asks for a device screenshot
    Then the agent is told to open a device first

  @node
  Scenario: An agent closes its device and can power it off
    Given an agent has opened a device in its thread
    When the agent closes the device asking to shut it down
    Then the device leaves the thread and powers off

  @node
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
