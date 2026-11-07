# Sources:
#   https://github.com/pingdotgg/t3code/pull/26797
#   https://github.com/pingdotgg/t3code/pull/23339
#   https://github.com/pingdotgg/t3code/pull/19975
#   https://github.com/pingdotgg/t3code/pull/21197
#   https://github.com/pingdotgg/t3code/pull/16040
#   https://github.com/pingdotgg/t3code/pull/17020
#   https://github.com/pingdotgg/t3code/pull/14534
#   https://github.com/pingdotgg/t3code/pull/17566
#   https://github.com/pingdotgg/t3code/pull/18502
#   https://github.com/pingdotgg/t3code/pull/18326
#   https://github.com/pingdotgg/t3code/pull/20077
#   https://github.com/pingdotgg/t3code/pull/13574
#   https://github.com/pingdotgg/t3code/pull/13534
#   https://github.com/pingdotgg/t3code/pull/12787
#   https://github.com/pingdotgg/t3code/pull/12813 (iPhone Duo postures, hinge and touch handoff; foldable Android)
#   docs/user/devices.md (Device panel, agent access, remote streaming)
#   docs/internals/devices.md
#   packages/contracts/src/device.ts (DeviceServiceState, device.open, device.close)
#   packages/client-runtime/src/device/stream.ts (serve-sim AVCC and input, serve-emu SEMU and gestures)
#   apps/web/src/components/devices/DevicePanel.tsx, DevicePicker.tsx, DeviceStreamView.tsx
#   apps/web/src/components/device/DevicePanel.tsx (header, buttons, banners, picker, empty states)
#   apps/web/src/components/device/DeviceSetup.tsx (first-use setup wizard)
#   apps/web/src/components/device/DeviceHostUpdates.tsx, DeviceHostAvailability.tsx, DeviceToolVersions.tsx
#   apps/web/src/components/device/DeviceLoadingView.tsx, DeviceToolsPanel.tsx
#   apps/web/src/components/device/DeviceStreamView.tsx (input state, accessibility overlay, MJPEG fallback)
#   apps/web/src/components/RightPanelTabs.tsx (device tabs replace the picker, dismissed tabs)
#   apps/web/src/rightPanelStore.ts (a tab per host and device, renamed tabs kept)
#   apps/server-ex/lib/hal_c2/devices.ex (devices shape, hubBasePath)
#   apps/server-ex/lib/hal_c2/devices/proxy.ex (/api/device-hub/mcs/<MC>/vendor/*, 401 and 403)
#   apps/desktop-qt/src/native/ThreadDevices.cpp, DeviceStream.cpp, DeviceDecoder.cpp, FFmpeg.cpp
#   apps/desktop-qt/src/native/PanelStage.h (the stage's panes and layouts)
#   apps/desktop-qt/qml/HalC2/Bricks/DevicePanel.qml
#   apps/desktop-qt/tests/native/features/DeviceSteps.cpp
#   Cross-domain: connections/device-hub.feature holds the MC's hub and proxy,
#   mobile/usage-diagnostics-devices.feature holds the phone's device viewer.
#   https://github.com/pingdotgg/t3code/pull/15551
#   https://github.com/pingdotgg/t3code/pull/15435
#   https://github.com/pingdotgg/t3code/pull/21841
#   https://github.com/pingdotgg/t3code/pull/25714
#   https://github.com/pingdotgg/t3code/pull/25815
#   https://github.com/pingdotgg/t3code/pull/24106
#   https://github.com/pingdotgg/t3code/pull/25248
#   https://github.com/pingdotgg/t3code/pull/21430

Feature: Device panel
  A thread's Device tab lists the simulators and emulators of the thread's environment,
  shows the one the user opens live through the MC, and passes the user's touches,
  keys and buttons to it. The screen always comes through the MC's device proxy, never
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
      And the screen came through the MC's device proxy

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
    Scenario: A device the MC cannot open says why
      Given the thread's environment has an iOS Simulator "iPhone 17" running
      And the MC cannot open devices because "Simulator failed to boot"
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

    @desktop
    Scenario: Following the pointer opens the Integrations settings
      Given device support is off on the thread's environment
      When the user adds a Device tab
      And the user follows the tab to its settings
      Then the window shows the settings section "/settings/integrations"

    @desktop
    Scenario: The user gives a device tab a name of their own
      Given the thread has "iPhone 17" open in a tab
      When the user renames the tab to "Checkout flow"
      Then the tab is named "Checkout flow"
      And the tab keeps that name when the device list is read again

    @desktop
    Scenario: Escape leaves a device tab's name as it was
      Given the user is renaming the tab "iPhone 17"
      When the user types "Checkout flow" and presses Escape
      Then the tab is still named "iPhone 17"

    @desktop
    Scenario: The same device on two machines gets a tab for each
      Given two connected machines each offer a simulator with the same device id
      When the user opens both
      Then each has its own tab
      And closing one leaves the other open

    @desktop
    Scenario: Running devices are listed before stopped ones
      Given the thread's environment has the iOS Simulators "iPad" stopped and "iPhone 17" running
      When the user adds a Device tab
      Then "iPhone 17" is listed before "iPad" under "iOS Simulators"

    @desktop
    Scenario: Devices in the same state are listed by name
      Given the thread's environment has the Android Emulators "Pixel 9" and "Nexus 5", both running
      When the user adds a Device tab
      Then "Nexus 5" is listed before "Pixel 9" under "Android Emulators"

    @desktop
    Scenario Outline: Each device in the list says where it runs and what state it is in
      Given the machine "studio" has the iOS Simulator "iPhone 17" on iOS 26.0, <state>
      When the user adds a Device tab
      Then the row for "iPhone 17" reads "studio · iOS 26.0 · <label>"
      And the row offers "<action>"

      Examples:
        | state   | label   | action |
        | running | Running | Open   |
        | stopped | Stopped | Start  |

    # Upstream #19975: a ready host's discovery warnings showed without a label, or not at all.
    @backlog @desktop
    Scenario: A machine whose device discovery warns says so by name while its devices still work
      Given the machine "studio" lists its iOS Simulators but warns that Android discovery failed
      When the user adds a Device tab
      Then the list shows the warning under the name "studio"
      And the iOS Simulators of "studio" can still be opened
      And the warning goes away once Android discovery works again

    # Upstream #25248: the warning stopped at the hub's message and dropped the cause it reported.
    @backlog @mc
    Scenario: A device discovery warning gives the cause the device tools reported
      Given the machine's iOS Simulator service stops answering
      When the user or an agent lists the machine's devices
      Then the warning names the cause, "Unable to connect to CoreSimulatorService"
      And it is one line without the tools' stack trace

    @desktop
    Scenario: Only one device is opened at a time from the list
      Given the thread's environment has the iOS Simulators "iPhone 17" and "iPad" running
      When the user opens "iPhone 17" from the Device tab
      Then "iPad" cannot be chosen until "iPhone 17" is open

    @desktop
    Scenario Outline: The tab says what it is waiting for while a device opens
      Given <situation>
      Then the Device tab says "<message>"

      Examples:
        | situation                                              | message                    |
        | the user opened "iPhone 17", which is already running  | Opening device…            |
        | the user opened "iPhone 17", which is stopped          | Starting device…           |
        | the device tools are still being installed             | Installing device support… |
        | the list of devices has not arrived yet                | Finding devices…           |

    @desktop
    Scenario: The tab tells the user which devices are starting
      Given the thread has "iPhone 17" starting
      Then the Device tab says "Starting iPhone 17… This can take a minute."
      When "iPhone 17" is running
      Then that message goes away

    @desktop
    Scenario: The tab shows the device hub's own words while it installs
      Given the device hub is installing on the thread's environment and reports "Downloading device tools"
      When the user adds a Device tab
      Then the tab says "Downloading device tools"

    @desktop
    Scenario Outline: A device hub that failed to start is named in the empty list
      Given the device hub failed to start on the thread's environment <reason>
      And it has no simulators or emulators
      When the user adds a Device tab
      Then the tab says "<message>"

      Examples:
        | reason                         | message                              |
        | and says "Port 4400 is in use" | Port 4400 is in use                  |
        | without saying why             | The device hub failed to start.      |

    @desktop
    Scenario: What the device hub says while it runs is shown above the list
      Given the device hub is ready and reports "Using Xcode 26.1"
      When the user adds a Device tab
      Then the tab shows "Using Xcode 26.1" above the list of devices

    # Upstream #25815: a Mac without the Android SDK warned about avdmanager on every refresh.
    @backlog @mc @desktop @priority-low
    Scenario: A machine without the Android SDK shows no Android tool warnings
      Given the thread's environment has no Android SDK
      When the user adds a Device tab and refreshes the devices
      Then the tab says the Android SDK was not found
      And no warning about Android's device tools is shown
      But on a machine with the Android SDK, an Android tool failure is still shown

    @desktop
    Scenario: A machine with the Android SDK but no virtual devices says how to make one
      Given the thread's environment has the Android SDK
      And it has no Android virtual devices
      When the user adds a Device tab
      Then the tab says "No Android virtual devices found. Create one in Android Studio's Device Manager, then refresh."

    @desktop
    Scenario: The device list is refreshed by hand
      Given the user added a Device tab on an environment with no simulators
      When the machine gains the iOS Simulator "iPhone 17"
      And the user chooses "Refresh devices"
      Then "iPhone 17" is offered under "iOS Simulators"

    @desktop
    Scenario: Refreshing is not offered while a machine is busy preparing devices
      Given the device tools are being installed on the thread's environment
      When the user adds a Device tab
      Then the tab does not offer "Refresh devices"

    @desktop
    Scenario: Showing the Device tab refreshes its list but never turns device support on
      Given device support is on and "iPhone 17" was added since the list was last read
      When the user shows the Device tab
      Then "iPhone 17" is offered
      Given device support is off
      When the user shows the Device tab
      Then nothing is installed or started on the environment

    @desktop
    Scenario: A device tab names the machine and the device's version
      Given the thread has "iPhone 17" on iOS 26.0 open on the machine "studio"
      Then the tab's header reads "studio · iOS 26.0"

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
    Scenario: Without FFmpeg the device tab explains what to install
      Given FFmpeg is not installed
      And the thread's environment has an iOS Simulator "iPhone 17" running
      When the user adds a Device tab
      Then "iPhone 17" is offered under "iOS Simulators"
      When the user opens "iPhone 17" from the Device tab
      Then the thread has "iPhone 17" open
      And the tab says to install FFmpeg to watch device screens
      And the tab asked for the device's video 0 times

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
    Scenario: A stream the MC refuses is an error
      Given the thread has the Android Emulator "Pixel 9" open
      And the MC refuses the device stream
      When the user shows the "Pixel 9" tab
      Then the tab says "The MC refused the device stream. Reconnect to try again."

    # Upstream #21841: a simulator locked to WebRTC (as EAS Simulator always is) refuses the
    # usual video; the viewer switches to WebRTC instead of failing.
    @backlog @desktop @mobile @priority-low
    Scenario: A simulator that streams only over WebRTC is still shown
      Given the thread has an iOS Simulator open that serves its screen only over WebRTC
      When the user shows its tab
      Then the tab shows the device's screen

    # Upstream #26797: EAS Simulator hosts offered only an iPhone; Android sessions could not open,
    # since the host assumed iOS and the viewer never asked serve-emu for its WebRTC stream.
    @backlog @desktop @mobile @priority-low
    Scenario: A hosted simulator offers an Android device beside the iPhone
      Given the machine's device hub is an EAS Simulator host
      When the user opens an Android device from it
      Then the tab shows the Android device's screen over WebRTC
      And the device's input reconnects without restarting its video

    # Upstream #26797
    @backlog @desktop @mobile @priority-low
    Scenario: A hosted simulator offers only what a hosted device can do
      Given the thread has a device open from an EAS Simulator host
      When the user looks at the device's controls
      Then navigation, screenshots and powering off are offered
      And device settings and tools that need the host's own commands are not

    @desktop
    Scenario: An Android emulator that rotates starts its video over
      Given the thread has the Android Emulator "Pixel 9" open
      And the user is watching the "Pixel 9" tab
      When the emulator's video restarts
      Then the device is asked for a fresh keyframe
      And the tab "Pixel 9" shows the device's screen

    # Upstream #18326. An idle simulator can go minutes without a keyframe of its own, so
    # only the video is reconnected; input and the 3D view stay connected.
    @desktop @backlog @priority-low
    Scenario: A simulator picture that fell behind catches up within seconds
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the picture falls behind while the simulator moves from Settings to Home
      Then the tab "iPhone 17" shows Home within a few seconds
      And the device's input and 3D view stay connected

    @desktop @backlog
    Scenario: A device that does not admit input says input is unavailable
      Given the thread has the iOS Simulator "iPhone 17" open
      And the device refuses input to the viewer
      When the user shows the "iPhone 17" tab
      Then the picture is shown and the tab says input is unavailable
      And the device's buttons cannot be used

    # Upstream #17566: a decoder backlog switched the viewer to still pictures for good and
    # lost the 3D view.
    @desktop @backlog @priority-low
    Scenario: A decoder that falls behind starts again at a keyframe and keeps the video
      Given the thread has the iOS Simulator "iPhone 17" open in 3D
      And the user is watching the "iPhone 17" tab
      When the desktop's decoder falls behind the device's video
      Then the decoder starts again from the device's next keyframe
      And the tab keeps showing video in the same 3D view

    @desktop @backlog @priority-low
    Scenario: A still picture that arrives late does not cover newer video
      Given the "iPhone 17" tab has shown decoded video
      When the device's first still picture arrives after it
      Then the tab keeps showing the newer video

    @desktop @backlog
    Scenario: Input is offered only once the device has admitted it
      Given the thread has the iOS Simulator "iPhone 17" open
      When the user shows the "iPhone 17" tab
      Then the device's buttons stay unavailable until the device admits the viewer's input
      And they become available again when input recovers after being unavailable

    @desktop
    Scenario: A Device tab in the background streams nothing
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user switches to the Diff tab
      Then no device stream is open
      When the user shows the "iPhone 17" tab
      Then the tab "iPhone 17" shows the device's screen

    @desktop
    Scenario: Two devices stream side by side in the centre
      Given the thread has the iOS Simulator "iPhone 17" open
      And the thread has the Android Emulator "Pixel 9" open
      When the user puts "iPhone 17" and "Pixel 9" side by side in the centre
      Then "iPhone 17" and "Pixel 9" both stream at once

    @desktop
    Scenario: A device hidden from the centre stops streaming and the other goes on
      Given the thread has the iOS Simulator "iPhone 17" open
      And the thread has the Android Emulator "Pixel 9" open
      And "iPhone 17" and "Pixel 9" stream side by side in the centre
      When the user shows only "iPhone 17" on the stage
      Then "Pixel 9" streams nothing
      And "iPhone 17" keeps its stream

    @desktop
    Scenario: Closing one of two devices leaves the other streaming
      Given the thread has the iOS Simulator "iPhone 17" open
      And the thread has the Android Emulator "Pixel 9" open
      And "iPhone 17" and "Pixel 9" stream side by side in the centre
      When the user closes the device "Pixel 9"
      Then "Pixel 9" streams nothing
      And "iPhone 17" keeps its stream

    @desktop
    Scenario: A device opens side by side with another from its tab
      Given the thread has the iOS Simulator "iPhone 17" open
      And the thread has the Android Emulator "Pixel 9" open
      And the user is watching the "Pixel 9" tab
      And the user is watching the "iPhone 17" tab
      When the user opens it side by side with "Pixel 9"
      Then "iPhone 17" and "Pixel 9" show side by side in the centre
      And "iPhone 17" and "Pixel 9" both stream at once

    @desktop
    Scenario: A device moved to the centre keeps its stream
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user moves "iPhone 17" to the centre
      Then "iPhone 17" keeps its stream

    @desktop
    Scenario: The tab shows which of its two steps it is on
      Given the thread has the iOS Simulator "iPhone 17" opening
      Then the tab shows its progress as "Step 1 of 2: open device"
      When the device is open and no picture has arrived yet
      Then the tab shows its progress as "Step 2 of 2: connect video"

    @desktop
    Scenario: A stream whose access expired reconnects without the user doing anything
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the MC refuses the stream because its access has expired
      Then the tab asks the MC for fresh access
      And the tab "iPhone 17" shows the device's screen again

    @desktop
    Scenario: Access that expires again is refreshed again
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the MC refuses the stream because its access has expired
      Then the tab "iPhone 17" shows the device's screen again
      When the MC refuses the stream because its access has expired
      Then the tab asks the MC for fresh access again
      And the tab "iPhone 17" shows the device's screen again

    @desktop
    Scenario: Fresh access answered after a reconnect is not used
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      And the MC is slow to give fresh access
      When the MC refuses the stream because its access has expired
      And the user reconnects before the MC answers
      And the MC answers the earlier request
      Then the tab does not use that answer
      When the MC answers the later request
      Then the tab "iPhone 17" shows the device's screen again

    @desktop
    Scenario: A lost input connection is shown over the picture
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the device's input connection drops with the reason "socket closed"
      Then the picture stays and the tab says "Input disconnected (socket closed), reconnecting…"
      And the device's buttons cannot be used
      When the input connection returns
      Then the message goes away and the buttons work again

    @desktop
    Scenario: The device keeps its shape in a panel of any size
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user makes the panel narrower than the device is wide
      Then the device is shown smaller with its own proportions
      And a touch at the middle of the shown screen is sent as the middle of the device

    @desktop
    Scenario: The device can be shown as a 3D body the user turns
      Given the thread has the iOS Simulator "iPhone 18 Pro" open
      And the user is watching the "iPhone 18 Pro" tab
      When the user shows the device in 3D and drags across it
      Then the body turns with the drag
      And when the drag ends the body settles on the nearest view that faces its screen

    @desktop @backlog @priority-low
    Scenario: An iPhone Duo shows both of its screens on a body that folds
      Given the thread has the iOS Simulator "iPhone Duo" open
      And the user is watching the "iPhone Duo" tab
      When the user shows the device in 3D
      Then both of its screens are shown on a body with a hinge between them
      And the device's screen is live on the screen facing the user

    @desktop @backlog @priority-low
    Scenario: The user picks a posture for an iPhone Duo
      Given the user is viewing the iOS Simulator "iPhone Duo" in 3D
      When the user picks the "Laptop" posture
      Then the body folds into that posture
      And both screens stay live

    @desktop @backlog @priority-low
    Scenario: Touches reach a Duo screen only once it faces the user
      Given the user is viewing the iOS Simulator "iPhone Duo" in 3D
      And the posture turns one screen away from the user
      When the device turns the other screen to the user
      Then touches go to that screen only after the device confirms the change and shows a fresh picture on it

    @desktop @backlog @priority-low
    Scenario: A device host that cannot report a Duo's posture shows it flat
      Given the thread has the iOS Simulator "iPhone Duo" open
      And the device host cannot report the Duo's posture
      When the user shows the device in 3D
      Then the device is shown in the flat view with its live screen

    @desktop @backlog @priority-low
    Scenario: A foldable Android emulator changes its picture when it is folded or opened
      Given the thread has the Android Emulator "Pixel 9 Pro Fold" open
      And the user is watching the "Pixel 9 Pro Fold" tab
      When the emulator is folded or opened
      Then the picture changes to the new size without the tab being reopened

    # Upstream #13534: the fold controls drive the emulator's hinge and animate the 3D model.
    @desktop @backlog @priority-low
    Scenario: The user folds and unfolds a foldable Android emulator from the device panel
      Given the thread has the Android Emulator "Pixel 10 Pro Fold" open in 3D
      When the user folds the device and then unfolds it
      Then the 3D model animates through each hinge angle
      And the picture follows the device's posture

    @desktop @backlog @priority-low
    Scenario: Fold controls appear only for an emulator that reports folding
      Given the thread has an Android Emulator open that does not report a fold posture
      Then no fold controls are shown

    # Upstream #13574: the fold model is sized from the inner screen, so a landscape panel is not stretched.
    @desktop @backlog @priority-low
    Scenario: The fold model keeps the shape of a landscape inner screen
      Given the thread has the Android Emulator "Pixel Fold" open with a landscape inner screen
      Then the 3D model is drawn with a landscape inner screen, not stretched

    @desktop
    Scenario Outline: A device shown in 3D keeps a plain body when its own model is missing
      Given the thread has the <device> open
      And <reason>
      When the user shows the device in 3D
      Then a plain body of the device's family is shown instead of an error
      And the device's screen is still live on it

      Examples:
        | device                              | reason                                 |
        | Android Emulator "Pixel 9"          | the device has no 3D model             |
        | iOS Simulator "iPhone 18 Pro"       | the 3D model cannot be downloaded      |
        | iOS Simulator "iPhone 18 Pro"       | the 3D model file is not a valid model |

    @desktop
    Scenario: Switching to the flat view hides the Magic Keyboard
      Given the user is viewing the iOS Simulator "iPad Pro 13-inch" in 3D with the Magic Keyboard attached
      When the user switches to the flat view
      Then the live screen fills the panel
      And the Magic Keyboard is not shown

    @desktop
    Scenario: Returning to the 3D view shows the Magic Keyboard attached again
      Given the user is viewing the iOS Simulator "iPad Pro 13-inch" in the flat view with the Magic Keyboard attached
      When the user switches to the 3D view
      Then the Magic Keyboard is shown attached to the iPad

    @desktop
    Scenario: Attaching the Magic Keyboard in the 3D view shows it on the iPad
      Given the user is viewing the iOS Simulator "iPad Pro 13-inch" in 3D with no keyboard attached
      When the user attaches the Magic Keyboard
      Then the Magic Keyboard is shown attached to the iPad

    @desktop
    Scenario: Detaching the Magic Keyboard in the 3D view removes it from the iPad
      Given the user is viewing the iOS Simulator "iPad Pro 13-inch" in 3D with the Magic Keyboard attached
      When the user detaches the Magic Keyboard
      Then the Magic Keyboard is no longer shown

    @desktop
    Scenario: Attaching the Magic Keyboard in portrait turns the device to landscape
      Given the user is viewing the iOS Simulator "iPad Pro 13-inch" in portrait with no keyboard attached
      When the user attaches the Magic Keyboard
      Then the device is asked to turn to landscape

    @desktop
    Scenario: The user overlays the device's accessibility elements
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user turns on "Overlay element frames" in the tools
      Then each accessibility element on the device is outlined over the screen with its label
      And the outlines follow the device as its screen changes
      When the user turns it off or shows another tab
      Then the outlines go away

    @desktop
    Scenario: A stalled accessibility read is not asked again
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      And the accessibility requests stall
      When the user turns on "Overlay element frames" in the tools
      Then no second accessibility request is out

    @desktop
    Scenario: The overlay outlines a crowded Android screen only so far
      Given the user has the tools open for the Android Emulator "Pixel 9" with "com.example.shop" in front
      And the device's screen has more elements than the overlay shows
      When the user turns on "Overlay element frames" in the tools
      Then the overlay outlines the first 500 of them

    @desktop
    Scenario: The 3D body shows a device held sideways upright
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the device reports it is held "landscape_left"
      And the user shows the device in 3D
      Then the 3D screen stands upright on its body

    @desktop
    Scenario: The flat view decodes at its own size after the 3D view
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user shows the device in 3D
      And the user switches to the flat view
      Then the picture is decoded for the flat view's size

    @desktop
    Scenario: Overlaying accessibility elements needs device access
      Given the thread has "iPhone 17" open and the MC has given the client no device access yet
      Then "Overlay element frames" cannot be turned on

    @desktop @dropped
    Scenario: A browser without video decoding falls back to still pictures
      # The web client fell back to the hub's MJPEG endpoint when the browser had no WebCodecs
      # or a plain-http origin; the Qt desktop and the phone decode with FFmpeg or the system.
      Given the browser cannot decode the device's video
      When the user watches a device
      Then the tab shows the device's still pictures instead

    @backlog @mobile
    Scenario: The device viewer fills the screen
      When the user opens a simulator or device on the phone
      Then its stream fills the screen at the device's aspect ratio
      And its controls sit in an overlay that shows while connecting and on tap

  Rule: Driving a device

    @desktop
    Scenario: Touches and keys reach a simulator through the MC
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user taps the middle of the screen
      Then the device receives a touch that begins and ends at the middle
      When the user types "a" on the device
      Then the device receives the key "a" going down and up
      When the user presses the device's Home button
      Then the device receives the "home" button

    # Upstream #23339: keys typed on a numeric keypad never reached an iOS simulator.
    @backlog @desktop @mobile @priority-low
    Scenario Outline: A numeric keypad types into an iOS simulator
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user presses the keypad's "<key>" on the device
      Then the device receives the keypad's "<key>" going down and up

      Examples:
        | key   |
        | 7     |
        | Enter |
        | .     |
        | *     |

    # Upstream #17020: right and middle clicks on the device's screen are no longer sent as touches.
    @backlog @desktop
    Scenario: Only the primary button touches the device
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user right-clicks the middle of the screen
      And the user middle-clicks the middle of the screen
      Then the device receives no touch

    @desktop
    Scenario: Touches, keys and buttons reach an emulator through the MC
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

    # Upstream #21430: a touch whose pointer is taken away ends once, at its last point.
    @desktop
    Scenario: A touch taken away mid-drag ends where it was
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user drags from the middle of the screen to its left middle and the touch is taken away
      Then the device receives a touch that ends at the left middle

    # Upstream #21430: a second finger could start its own gesture and end the first one's.
    @backlog @desktop @mobile
    Scenario: A second finger does not interrupt a touch in progress on the flat view
      Given the thread has the iOS Simulator "iPhone 17" open in the flat view
      And the user is dragging one finger across the screen
      When the user puts a second finger on the screen and lifts it
      Then the device receives only the first finger's drag
      And the drag ends when the first finger lifts

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

    @desktop
    Scenario Outline: The tab offers the buttons its platform has
      Given the thread has <device> open
      Then the tab offers <buttons>

      Examples:
        | device                        | buttons                   |
        | the iOS Simulator "iPhone 17" | Home and Rotate           |
        | the Android Emulator "Pixel 9" | Home, Back and Recents   |

    @desktop
    Scenario: Keys go to the device only while its screen has the focus
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user types "a" in the tab's tools instead of on the screen
      Then the device receives no key
      When the user clicks the device's screen and types "a"
      Then the device receives the key "a" going down and up

    # Upstream #14534: letters typed on a focused device screen no longer jump to the composer.
    @backlog @desktop
    Scenario: Letters typed on the device's screen do not move to the composer
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user clicks the device's screen and types "hello"
      Then the device receives the keys "h", "e", "l", "l" and "o"
      And the composer stays empty

    # Upstream #14534: coming back to the window leaves focus on the device screen.
    @backlog @desktop
    Scenario: Coming back to the window keeps the device's screen focused
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user clicked the "iPhone 17" screen
      When the user switches to another app and back
      Then the device's screen still has the focus
      And the composer does not take it

    @desktop
    Scenario: Command shortcuts stay with the app while the device has the focus
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user clicked the device's screen
      When the user presses Command with "K"
      Then the device receives no key
      And the app handles the shortcut
      When the user presses Command with "R"
      Then the device receives the key "r" with Command

    @desktop
    Scenario: Letting go of Command first lifts both keys on the device
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user clicked the device's screen
      When the user holds Command with "R" and lets go of Command first
      Then the device has both keys up

    @desktop
    Scenario: A chord cut off by a dropped connection does not outlive it
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user clicked the device's screen
      When the user holds Command with "R"
      And the device's input connection drops with the reason "hub restarted"
      And the input connection returns
      And the user presses Command with "R" again
      Then the device receives the key "r" with Command

    @desktop
    Scenario: Command is the Mac's own key on a Mac
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      Then on a Mac the app keeps every Command chord but Command with "R"

    # Upstream #21197: pasting into the focused device screen types the text into the Android device.
    @backlog @desktop
    Scenario: Pasting into a focused Android screen types into the device
      Given an Android device's screen has the focus
      When the user pastes "hello@example.com"
      Then the device receives "hello@example.com" as typed text
      And the composer does not receive it

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
      Then the MC is asked to close "iPhone 17" and shut it down
      And the right panel has no "iPhone 17" tab

    @desktop
    Scenario: A device powered off from a thread the user left closes that thread's tab
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      And the MC is slow to close devices
      When the user powers the device off
      And before the MC answers, the user switches to another thread showing "iPhone 17"
      And the MC answers
      Then the right panel shows the "iPhone 17" tab
      When the user goes back to the first thread
      Then the right panel has no "iPhone 17" tab

    # Upstream #16040: a device action's progress and error stay with the thread that started it.
    @backlog @desktop
    Scenario: A device action's progress and error stay with the thread that started it
      Given the user starts opening the iOS Simulator "iPhone 17" in a thread
      And the MC is slow to answer
      When the user switches to another thread
      Then that thread's Device tab shows no progress and offers its own device choice
      When the MC answers that "iPhone 17" could not be opened
      And the user goes back to the first thread
      Then the first thread's Device tab says the device could not be opened

    @desktop
    Scenario: A device that cannot be powered off stays open and says why
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      And the MC cannot shut the device down because "Simulator is busy"
      When the user powers the device off
      Then the tab says "Simulator is busy"
      And the right panel still has the "iPhone 17" tab
      When the user dismisses the error
      Then the tab shows no error

    @desktop
    Scenario: The user floats a device over the chat
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user floats the device over the chat
      Then the device floats over the conversation
      And the right panel closes

    @desktop
    Scenario: Opening the right panel brings a floating device home
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user floats the device over the chat
      And the user opens the right panel
      Then the device no longer floats

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

    # Upstream #25714: a device an agent opened in a thread the user was not viewing never showed.
    @backlog @desktop
    Scenario: A device an agent opened while the user was elsewhere shows on returning
      Given the user is looking at another thread
      When an agent opens "iPhone 17" in "Fix checkout"
      And the user switches to "Fix checkout"
      Then "Fix checkout" shows "iPhone 17", floating or as a right panel tab as the user's setting says

    # Upstream #25714: a floating device stayed open after its session ended in another thread.
    @backlog @desktop
    Scenario: A floating device closes when its session ends
      Given "iPhone 17" floats over "Fix checkout"
      When its session ends while the user is looking at another thread
      Then "iPhone 17" no longer floats over "Fix checkout"

    # Upstream #25714: a floating device stayed open after its session ended.
    @backlog @desktop @priority-low
    Scenario: Closing the right panel does not float a device whose session ended
      Given the right panel shows the "iPhone 17" tab and its session has ended
      When the user closes the right panel
      Then no device floats over the conversation

  Rule: Setting devices up from the Device tab
    # Device support that is off already points to the Integrations settings (Choosing a
    # device); the legacy web client opened this wizard in front of the tab instead.

    @desktop
    Scenario: A first visit to the Device tab opens a setup wizard
      Given device support has never been set up on the thread's environment
      When the user adds a Device tab
      Then a "Set up devices" wizard opens with the steps "Device hub", "Simulators" and "Agent access"
      And it says "Review what runs on this environment before using simulators and emulators."

    @desktop
    Scenario: Turning device support off brings the wizard back
      Given the user finished setting devices up
      And later turned device support off
      When the user shows the Device tab
      Then the wizard opens at its first step

    # Upstream #24106: a reload showed the wizard before the environment answered.
    @backlog @desktop
    Scenario: A restored Device tab waits for the device list before offering setup
      Given device support is set up on the thread's environment
      And the Device tab was open when the desktop restarted
      When the tab comes back before the environment has sent its devices
      Then the tab says "Finding devices…" and no setup wizard opens

    # Upstream #24106: waiting for a first answer that failed spun on "Finding devices…" for good.
    @backlog @desktop
    Scenario: A device list that fails to load says why and offers to try again
      Given the environment refuses the Device tab's first request for its devices
      When the user shows the Device tab
      Then the tab shows the error with "Retry"
      When the user retries and the environment answers
      Then the tab lists the environment's devices

    @desktop
    Scenario: Enabling the device hub says what it is doing until it is ready
      Given the wizard is at "Device hub" with the hub off
      When the user turns on "Enable device hub"
      Then the wizard says "Installing device hub…", then "Starting device hub…"
      And when the hub is up it says "Device hub is ready."
      And the user can continue to the next step

    @desktop
    Scenario: The wizard cannot go on until the device hub is ready
      Given the wizard is at "Device hub" and the hub is off
      Then the user cannot continue

    @desktop @backlog @priority-low
    Scenario: A ready remote machine lets the wizard go on without local device tools
      Given the thread's environment has no simulator tooling and its own hub is idle
      And the remote machine "Mac mini" has its device tools ready with "iOS Simulator"
      When the user opens the "Set up devices" wizard
      Then the machines are checked without the user asking
      And the user can continue
      And the "Simulators" step reads "Xcode and iOS Simulator are available on Mac mini."
      And it does not say that no simulator is installed

    @desktop
    Scenario: Turning the device hub off also turns agent access off
      Given the hub is on and agents may control devices
      When the user turns off "Enable device hub" in the wizard
      Then agent access is off as well

    @desktop
    Scenario: The wizard's switches wait while the hub installs or starts
      Given the device hub is installing
      Then "Enable device hub" cannot be changed
      And the user cannot go back or choose another step until it is done

    @desktop
    Scenario: A later step cannot be jumped to
      Given the wizard is at "Device hub" with the hub ready
      When the user chooses the step "Agent access" directly
      Then the wizard stays at "Device hub"
      When the user continues twice and then chooses "Device hub"
      Then the wizard returns to "Device hub"

    @desktop
    Scenario Outline: The Simulators step says what each platform needs
      Given the hub is ready and <situation>
      When the user is at the "Simulators" step
      Then <platform> reads "<message>"

      Examples:
        | situation                                                       | platform | message                                                                                                            |
        | iOS is not detected and the machine gives no reason             | iOS      | iOS support was not detected.                                                                                       |
        | Android is not detected and the machine gives no reason         | Android  | Android support was not detected.                                                                                   |
        | iOS is unavailable because "Xcode is not installed"             | iOS      | Xcode is not installed                                                                                              |
        | Xcode is installed with no iOS Simulator runtime                | iOS      | Xcode is installed, but no iOS Simulator is available. Install a runtime in Xcode Settings → Components.          |
        | the Android SDK is installed with no virtual device             | Android  | The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager.         |
        | Xcode has an iOS Simulator                                      | iOS      | Xcode and iOS Simulator are available.                                                                              |
        | the Android SDK has an emulator                                 | Android  | The Android SDK and Emulator are available.                                                                         |

    @desktop
    Scenario: One platform missing does not block the other
      Given the hub is ready and only Android has an emulator
      When the user is at the "Simulators" step
      Then the wizard says "You can use either platform. Fixing a missing platform does not block the other one."
      And the user can continue

    @desktop
    Scenario: The user checks the platforms again after installing something
      Given the user is at the "Simulators" step and iOS has no simulator runtime
      When the user installs a runtime and chooses "Check again"
      Then the button says "Checking…" until the answer arrives
      And iOS reads "Xcode and iOS Simulator are available."

    @desktop
    Scenario Outline: The Agent access step says what it is doing
      Given the user is at the "Agent access" step
      When the user turns on "Allow agents to control devices" and the hub is <state>
      Then the wizard says "<message>"

      Examples:
        | state                   | message                      |
        | installing agent tools  | Installing agent tools…      |
        | starting agent tools    | Starting agent tools…        |
        | updating                | Updating agent access…       |
        | ready with agent tools  | Agent tools are ready.       |

    @backlog @mc @desktop
    Scenario: Agent tools that exit at startup say why at once
      Given the agent tools refuse to start because of a lock left by an older version
      When the user turns on "Allow agents to control devices"
      Then the device status says why the agent tools did not start and where their state is
      And it says so without waiting 30 seconds for them to come up
      And the old lock is left in place for the user to repair

    @desktop
    Scenario: Agent access can stay off
      Given the user is at the "Agent access" step
      Then the wizard says "Leave this off to keep manual device controls without giving agents access."
      And "Allow agents to control devices" cannot be turned on while the hub is off

    @desktop
    Scenario: Finishing the wizard shows the device list
      Given the user is at the "Agent access" step with the hub ready
      When the user chooses "Done"
      Then the button says "Saving…" until the answer arrives
      And the wizard closes
      And the Device tab lists the environment's devices
      When the user shows the Device tab in another thread
      Then no wizard opens

    @desktop
    Scenario: Cancelling the wizard leaves device support as it is
      Given the wizard is at its first step
      When the user chooses "Cancel"
      Then the wizard closes
      And device support stays as the user left it

    @desktop
    Scenario: Back goes to the step before
      Given the wizard is at the "Simulators" step
      When the user chooses "Back"
      Then the wizard shows the "Device hub" step

    @desktop
    Scenario: A device hub that fails to start says why in the wizard
      Given the user turned on "Enable device hub"
      When the hub fails with "Port 4400 is in use"
      Then the wizard shows "Port 4400 is in use" as an error
      And the user cannot continue

    @backlog @desktop
    Scenario: Missing platform tooling is explained before the hub is ready
      Given devices are on and the local host has no usable platform
      When the user opens the first wizard step or the Devices settings
      Then each platform's diagnostics and its refresh are shown
      And continuing still waits for a ready hub

  Rule: A machine preparing its device tools says so
    # A machine is the environment itself or a remote device host; each gets its own banner.

    @desktop
    Scenario Outline: A machine installing or starting its tools shows a banner
      Given the machine "studio" is <state>
      When the user shows the Device tab
      Then the tab shows a banner for "studio" saying "<message>"

      Examples:
        | state                                         | message                       |
        | installing its device tools                   | Installing device tools…      |
        | starting its device tools                     | Starting device tools…        |
        | installing and says "Downloading serve-sim"   | Downloading serve-sim         |

    @desktop
    Scenario: A machine that could not start says what to do
      Given the machine "studio" failed to start its device tools without saying why
      When the user shows the Device tab
      Then the banner for "studio" says "Device support could not start."
      And it says "Check the host connection and network access, then retry. Your device settings are saved."

    @desktop
    Scenario: A failed machine can be retried
      Given the MC can retry a single machine
      And the machine "studio" failed to start its device tools
      When the user chooses "Retry" on its banner
      Then the button says "Retrying…" until the answer arrives
      And only "studio" is retried

    @desktop
    Scenario: A failed machine offers no retry when the MC cannot retry one
      Given the MC cannot retry a single machine
      And the machine "studio" failed to start its device tools
      When the user shows the Device tab
      Then the banner for "studio" offers no "Retry"

    @desktop
    Scenario: Banners are not shown while device support is off
      Given device support is off and the machine "studio" failed earlier
      Then no banner is shown for "studio"

    @desktop
    Scenario: The wizard and the Device tab show the same banners
      Given the machine "studio" is installing its device tools
      Then the setup wizard shows the banner for "studio"
      And so does the Device tab once setup is done

  Rule: The Tools drawer
    # Every change is one request to the MC; the control then shows what the device confirmed.

    @desktop
    Scenario: The user opens a device's tools beside its screen
      Given the thread has the iOS Simulator "iPhone 17" open
      And the user is watching the "iPhone 17" tab
      When the user opens "Tools"
      Then the tools open beside the screen when the panel is wide enough
      And over the screen when it is narrow
      When the user chooses "Close tools"
      Then the tools close

    @desktop
    Scenario: The tools wait for the device's own settings
      Given the thread has the iOS Simulator "iPhone 17" open
      When the user opens "Tools"
      Then the tools say "Reading device settings…" and no control can be changed
      When the device's settings arrive
      Then the controls show what the device reports

    @desktop
    Scenario: A setting the device refused is not shown as changed
      Given the thread has the iOS Simulator "iPhone 17" open in light appearance
      And the user has the tools open
      And the device refuses to change appearance because "Not allowed"
      When the user chooses "Dark"
      Then the tools show "Not allowed"
      And the appearance still reads "Light"

    @desktop
    Scenario: The tools stay busy while a change is running
      Given the user has the tools open
      When the user changes a setting and the device is slow to answer
      Then a spinner shows beside "Tools"
      And no other control can be changed until it answers

    @desktop
    Scenario: Another device's tools start fresh
      Given the user changed the location of "iPhone 17" in the tools
      When the user shows the tab of "Pixel 9"
      Then its tools show its own settings and an empty location

    @desktop
    Scenario Outline: The tools offer the settings the platform has
      Given the thread has <device> open
      When the user opens "Tools"
      Then the tools list <settings> under "<section>"

      Examples:
        | device                         | section   | settings                                                                                                                 |
        | the iOS Simulator "iPhone 17"  | Simulator | Appearance, Text size, Liquid Glass, Color filter, Reduce Motion, Increase Contrast, Reduce Transparency, Show Borders and VoiceOver |
        | the Android Emulator "Pixel 9" | Emulator  | Appearance, Text size, Orientation, Reduce Motion and Network                                                            |

    @desktop
    Scenario Outline: A choice in the tools is applied by the device
      Given the user has the tools open for <device>
      When the user chooses "<choice>" for "<control>"
      Then the device is asked to apply "<choice>"
      And the control then shows "<choice>"

      Examples:
        | device                         | control      | choice               |
        | the iOS Simulator "iPhone 17"  | Appearance   | Dark                 |
        | the iOS Simulator "iPhone 17"  | Text size    | Extra large          |
        | the iOS Simulator "iPhone 17"  | Liquid Glass | Tinted               |
        | the iOS Simulator "iPhone 17"  | Color filter | Red / green (protanopia) |
        | the Android Emulator "Pixel 9" | Orientation  | Landscape left       |

    @desktop
    Scenario: Switches show and change the device's accessibility settings
      Given the user has the tools open for the iOS Simulator "iPhone 17" with Reduce Motion off
      When the user turns on "Reduce Motion"
      Then the device is asked to turn it on
      And the switch then reads on

    @desktop
    Scenario: A setting the device does not report cannot be changed
      Given the device reports no value for "Liquid Glass"
      Then "Liquid Glass" cannot be changed

    @desktop
    Scenario: The tools show the app in front and can stop or restart it
      Given the iOS Simulator "iPhone 17" has "com.example.shop" in front
      When the user opens "Tools"
      Then "Foreground" reads "com.example.shop"
      When the user chooses "Terminate"
      Then the app is stopped
      When the user chooses "Relaunch"
      Then the app is started again

    @desktop
    Scenario: The foreground app changes as the user uses the device
      Given the user has the tools open for "iPhone 17" with "com.example.shop" in front
      When the user opens another app on the device
      Then "Foreground" reads the other app's id

    @desktop
    Scenario: The foreground follows the device again after its feed ends
      Given the user has the tools open for "iPhone 17" with "com.example.shop" in front
      When the user opens another app on the device
      Then "Foreground" reads the other app's id
      When the foreground feed ends with "com.example.shop" in front
      Then "com.example.shop" reads "com.example.shop"

    @desktop
    Scenario: No app in front is shown as a dash
      Given the device has no app in front
      Then "Foreground" reads "—"
      And "Terminate" and "Relaunch" are not offered

    @desktop
    Scenario Outline: The user opens an address or launches an app by name
      Given the user has the tools open for <device>
      When the user types "<value>" into "<field>" and chooses "<action>"
      Then the device is asked to <result>
      And the field is empty again

      Examples:
        | device                         | field                    | value                | action | result                          |
        | the iOS Simulator "iPhone 17"  | https:// or myapp://     | myapp://cart         | Open   | open "myapp://cart"             |
        | the iOS Simulator "iPhone 17"  | Bundle ID to launch      | com.example.shop     | Launch | launch "com.example.shop"       |
        | the Android Emulator "Pixel 9" | Package name to launch   | com.example.shop     | Launch | launch "com.example.shop"       |

    @desktop
    Scenario: An empty address or app name cannot be sent
      Given the user has the tools open
      Then "Open" and "Launch" cannot be chosen while their fields are empty

    @desktop
    Scenario Outline: The user places the device somewhere
      Given the user has the tools open for <device>
      When the user types latitude "<latitude>" and longitude "<longitude>" and chooses "Set"
      Then <result>

      Examples:
        | device                         | latitude | longitude | result                              |
        | the iOS Simulator "iPhone 17"  | 59.33    | 18.07     | the device is placed there          |
        | the iOS Simulator "iPhone 17"  | 91       | 18.07     | "Set" could not be chosen           |
        | the iOS Simulator "iPhone 17"  | 59.33    | 181       | "Set" could not be chosen           |
        | the iOS Simulator "iPhone 17"  | 59.33    |           | "Set" could not be chosen           |

    @desktop
    Scenario Outline: A location preset places the device at once
      Given the user has the tools open
      When the user chooses the preset "<city>"
      Then the fields show the preset's latitude and longitude
      And the device is placed there

      Examples:
        | city          |
        | San Francisco |
        | New York      |
        | London        |
        | Stockholm     |
        | Tokyo         |

    @desktop
    Scenario: A simulator's location can be cleared but an emulator's cannot
      Given the user has the tools open for the iOS Simulator "iPhone 17" placed in Tokyo
      When the user chooses "Clear" under "Location"
      Then the fields are empty and the simulator has no location
      Given the user has the tools open for the Android Emulator "Pixel 9"
      Then "Clear" is not offered under "Location"

    @desktop
    Scenario Outline: The user grants or revokes an app's permission
      Given the user has the tools open for <device> with "com.example.shop" in front
      When the user chooses the permission "<permission>" and then "<decision>"
      Then the device is asked to <decision> "<permission>" for "com.example.shop"

      Examples:
        | device                         | permission | decision |
        | the iOS Simulator "iPhone 17"  | Camera     | grant    |
        | the iOS Simulator "iPhone 17"  | Face ID    | revoke   |
        | the iOS Simulator "iPhone 17"  | Photos     | reset    |
        | the Android Emulator "Pixel 9" | Motion     | grant    |

    @desktop
    Scenario: A permission can be set for an app that is not in front
      Given the user has the tools open with "com.example.shop" in front
      When the user types "com.example.mail" as the app and chooses "Grant" for "Camera"
      Then the device is asked to grant "Camera" for "com.example.mail"

    @desktop
    Scenario: Permissions need an app
      Given the device has no app in front and the user typed no app
      Then "Grant", "Revoke" and "Reset" cannot be chosen

    @desktop
    Scenario Outline: The permissions offered depend on the platform
      Given the user has the tools open for <device>
      Then the permission list <result>

      Examples:
        | device                         | result                                                                         |
        | the iOS Simulator "iPhone 17"  | includes Reminders, Media library and Face ID, and offers "Reset"              |
        | the Android Emulator "Pixel 9" | has none of those, calls Motion "Physical activity" and offers no "Reset"      |

    @desktop
    Scenario: A simulator is sent a push notification for the app in front
      Given the user has the tools open for the iOS Simulator "iPhone 17" with "com.example.shop" in front
      When the user types "Order shipped" under "Push notification" and chooses "Send"
      Then the simulator is sent the notification for "com.example.shop"

    @desktop
    Scenario: A push notification needs an app in front
      Given the user has the tools open for the iOS Simulator "iPhone 17" with no app in front
      Then the tools say "Open an app first."
      And "Send" cannot be chosen

    @desktop
    Scenario: An emulator has no push notification section
      Given the user has the tools open for the Android Emulator "Pixel 9"
      Then the tools have no "Push notification" section

    @desktop
    Scenario: A simulator's event log follows the device live
      Given the user has the tools open for the iOS Simulator "iPhone 17"
      When the user opens "Event log"
      Then it says "No events yet." until the simulator reports something
      When the simulator reports events
      Then each is listed with its time and summary
      And only the latest 100 are kept

    @desktop
    Scenario: A closed event log stops listening
      Given the event log is open with entries
      When the user closes "Event log"
      Then the simulator's events are no longer read
      When the user opens "Event log" again
      Then it starts empty

    @desktop
    Scenario: The event log needs device access and an iOS Simulator
      Given the user has the tools open for the Android Emulator "Pixel 9"
      Then the tools have no "Event log"
      Given the MC has given the client no device access yet
      And the user has the tools open for the iOS Simulator "iPhone 17"
      Then the tools have no "Event log"
