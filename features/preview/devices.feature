# Sources:
#   docs/user/devices.md (Device panel, agent access, remote streaming)
#   docs/internals/devices.md
#   packages/contracts/src/device.ts (DeviceServiceState, device.open, device.close)
#   packages/client-runtime/src/device/stream.ts (serve-sim AVCC and input, serve-emu SEMU and gestures)
#   apps/web/src/components/devices/DevicePanel.tsx, DevicePicker.tsx, DeviceStreamView.tsx
#   apps/web/src/components/RightPanelTabs.tsx (device tabs replace the picker, dismissed tabs)
#   apps/server-ex/lib/hal_c2/devices.ex (devices shape, hubBasePath)
#   apps/server-ex/lib/hal_c2/devices/proxy.ex (/api/device-hub/nodes/<node>/vendor/*, 401 and 403)
#   apps/desktop-qt/src/native/ThreadDevices.cpp, DeviceStream.cpp, DeviceDecoder.cpp
#   apps/desktop-qt/qml/HalC2/Bricks/DevicePanel.qml
#   apps/desktop-qt/tests/native/features/DeviceSteps.cpp
#   Cross-domain: connections/device-hub.feature holds the node's hub and proxy,
#   mobile/usage-diagnostics-devices.feature holds the phone's device viewer.

Feature: Device panel
  A thread's Device tab lists the simulators and emulators of the thread's environment,
  shows the one the user opens live through the node, and passes the user's touches,
  keys and buttons to it. The screen always comes through the node's device proxy, never
  straight from the device.

  Rule: Choosing a device

    @desktop
    Scenario: Picking a device shows its screen
      Given the thread's environment has an iOS Simulator "iPhone 17" running
      When the user adds a Device tab
      Then "iPhone 17" is offered under "iOS Simulators"
      When the user opens "iPhone 17" from the Device tab
      Then the thread has "iPhone 17" open
      And the tab "iPhone 17" shows the device's screen
      And the screen came through the node's device proxy

    @desktop
    Scenario: A stopped device is offered to start
      Given the thread's environment has an Android Emulator "Pixel 9" stopped
      When the user adds a Device tab
      Then "Pixel 9" is offered under "Android Emulators" to start

    @desktop
    Scenario: An environment without devices says so
      Given the thread's environment has no simulators or emulators
      When the user adds a Device tab
      Then the tab says "No simulators or emulators were found on this environment."

    @desktop
    Scenario: A device the node cannot open says why
      Given the thread's environment has an iOS Simulator "iPhone 17" running
      And the node cannot open devices because "Simulator failed to boot"
      When the user adds a Device tab
      And the user opens "iPhone 17" from the Device tab
      Then the tab says "Simulator failed to boot"
      When the user dismisses the error
      Then the tab shows no error

    @desktop
    Scenario: Device support that is off points to its settings
      Given device support is off on the thread's environment
      When the user adds a Device tab
      Then the tab points to the Integrations settings

  Rule: Watching a device

    @desktop
    Scenario: The tab says it is connecting until the first picture
      Given the thread has the iOS Simulator "iPhone 17" open
      And the device sends no picture yet
      When the user shows the "iPhone 17" tab
      Then the tab says it is connecting to the device
      When the device starts sending pictures
      Then the tab "iPhone 17" shows the device's screen

    @desktop
    Scenario: Video that arrives in pieces still shows the screen
      Given the thread has the iOS Simulator "iPhone 17" open
      And the device sends no picture yet
      When the user shows the "iPhone 17" tab
      And the device sends its video in pieces
      Then the tab "iPhone 17" shows the device's screen

    @desktop
    Scenario: A tab turned to another device never shows the last one's picture
      Given the thread has the iOS Simulator "iPhone 17" open
      And the thread has the Android Emulator "Pixel 9" open
      And the user is watching the "iPhone 17" tab
      And the device sends no picture yet
      When the user shows the "Pixel 9" tab
      Then the tab says it is connecting to the device
      And the tab shows no picture

    @desktop
    Scenario: A device that sends nothing is an error the user can retry
      Given the thread has the iOS Simulator "iPhone 17" open
      And the device sends no picture yet
      When the user shows the "iPhone 17" tab
      And no picture comes in time
      Then the tab says "No video received from the device. Reconnect to try again."
      When the device starts sending pictures
      And the user reconnects
      Then the tab "iPhone 17" shows the device's screen

    @desktop
    Scenario: Video the desktop cannot decode is an error, not endless reconnecting
      Given the thread has the iOS Simulator "iPhone 17" open
      And the device sends video the desktop cannot decode
      When the user shows the "iPhone 17" tab
      Then the tab says "The device's video could not be decoded. Reconnect to try again."
      And the tab asked for the device's video 3 times

    @desktop
    Scenario: A stream that ends connects again
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the device's stream ends
      Then the tab connects to the device again
      And the tab "iPhone 17" shows the device's screen

    @desktop
    Scenario: A stream the node refuses is an error
      Given the thread has the Android Emulator "Pixel 9" open
      And the node refuses the device stream
      When the user shows the "Pixel 9" tab
      Then the tab says "The node refused the device stream. Reconnect to try again."

    @desktop
    Scenario: An Android emulator that rotates starts its video over
      Given the thread has the Android Emulator "Pixel 9" open
      And the user is watching the "Pixel 9" tab
      When the emulator's video restarts
      Then the device is asked for a fresh keyframe
      And the tab "Pixel 9" shows the device's screen

    @desktop
    Scenario: A Device tab in the background streams nothing
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user switches to the Diff tab
      Then no device stream is open
      When the user shows the "iPhone 17" tab
      Then the tab "iPhone 17" shows the device's screen

  Rule: Driving a device

    @desktop
    Scenario: Touches and keys reach a simulator through the node
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user taps the middle of the screen
      Then the device receives a touch that begins and ends at the middle
      When the user types "a" on the device
      Then the device receives the key "a" going down and up
      When the user presses the device's Home button
      Then the device receives the "home" button

    @desktop
    Scenario: Touches, keys and buttons reach an emulator through the node
      Given the thread has the Android Emulator "Pixel 9" open
      And the user is watching the "Pixel 9" tab
      When the user taps the middle of the screen
      Then the emulator receives a touch down and up at the middle
      When the user types "a" on the device
      Then the emulator receives the text "a"
      When the user presses Escape on the device
      Then the emulator receives the "back" button
      When the user presses the device's Recents button
      Then the emulator receives the "recents" button

    @desktop
    Scenario: A touch taken away mid-drag ends where it was
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user drags from the middle of the screen to its left middle and the touch is taken away
      Then the device receives a touch that ends at the left middle

    @desktop
    Scenario: Rotating a simulator turns its screen
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user rotates the device
      Then the device is asked to turn to "landscape_left"
      When the device reports it is held "landscape_left"
      Then the screen is shown sideways and wider than tall
      When the user taps the left middle of the screen
      Then the device receives the touch where it lands on its own portrait screen

  Rule: Closing

    @desktop
    Scenario: Closing a device tab stops watching but leaves the device open
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user closes the "iPhone 17" tab
      Then no device stream is open
      And the thread still has "iPhone 17" open

    @desktop
    Scenario: Powering a device off closes it and its tab
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user powers the device off
      Then the node is asked to close "iPhone 17" and shut it down
      And the right panel has no "iPhone 17" tab

    @desktop
    Scenario: A device powered off from a thread the user left closes that thread's tab
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      And the node is slow to close devices
      When the user powers the device off
      And before the node answers, the user switches to another thread showing "iPhone 17"
      And the node answers
      Then the right panel shows the "iPhone 17" tab
      When the user goes back to the first thread
      Then the right panel has no "iPhone 17" tab

  Rule: Devices an agent opens

    @desktop
    Scenario: A device an agent opens shows as a side panel tab
      Given the thread's environment has an iOS Simulator "iPhone 17" running
      And the user is looking at the thread
      When an agent opens "iPhone 17" in the thread
      Then the right panel shows the "iPhone 17" tab

    @desktop
    Scenario: A device tab the user closed does not come back on its own
      Given the thread's environment has an iOS Simulator "iPhone 17" running
      And the user is looking at the thread
      And an agent opened "iPhone 17" in the thread
      When the user closes the "iPhone 17" tab
      And the agent closes "iPhone 17" and opens it again
      Then the right panel has no "iPhone 17" tab
      When the user adds a Device tab
      And the user opens "iPhone 17" from the Device tab
      Then the right panel shows the "iPhone 17" tab
