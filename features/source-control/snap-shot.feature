# Sources:
#   docs/user/snap-shot.md
#   docs/internals/linux-snap-shot.md
#   apps/web/src/components/desktop/SnapShotCoordinator.tsx
#   apps/web/src/components/chat/SnapShotAttachmentDetails.tsx
#   apps/web/src/components/settings/SnapShotSettings.logic.ts
#   apps/web/src/components/settings/SnapShotSetupDialog.logic.ts
#   apps/desktop/src/snapShot
#   apps/desktop/gnome-extension (extension.js, captureService.js, captureFeedback.js)
#   apps/desktop/src/snapShot/SnapShotAccessibility.ts, SnapShotTransition.ts, NativeCaptureFeedback.ts (app text limits, flight, helper effects)
#   apps/desktop-qt/src/native/SnapShotController.cpp
# The Qt desktop captures through the desktop portal on Linux Wayland only: no
# capture helper, no compositor bindings, no app text and no capture effects.

@desktop
Feature: Snap Shot captures another app's window into the draft
  With a global shortcut the user captures the window they are working in and it lands
  in the current draft, optionally with the app's text and controls.

  Background:
    Given the desktop app with Snap Shot turned on and its shortcut set

  Scenario: Capturing the window in front
    Given the user is working in a browser with a thread open in HAL-C2
    When the user presses the Snap Shot shortcut
    Then an image of the browser window is attached to the thread's draft
    And HAL-C2 comes to the front

  Scenario: Capturing with no thread open starts a draft
    Given no thread is open and the current project is "shop"
    When the user presses the Snap Shot shortcut from another app
    Then a new draft in "shop" holds the capture

  Scenario: Capturing while HAL-C2 is in front captures HAL-C2
    Given HAL-C2 is the app in front
    When the user presses the Snap Shot shortcut
    Then an image of the HAL-C2 window is attached to the draft

  Scenario: Captures waiting to be sent survive a restart
    Given a capture is attached to a draft that was not sent
    When the user restarts HAL-C2
    Then the capture is still attached to the draft

  Scenario: An oversize capture is discarded
    Given the window is too large to attach
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is told the capture was too large

  @backlog @desktop
  Scenario: Pressing the shortcut again while a capture is being taken is ignored
    Given the user has just pressed the Snap Shot shortcut
    When the user presses the shortcut again before the first capture has been taken
    Then only one capture is attached to the draft

  @backlog @desktop
  Scenario Outline: A capture that cannot be taken says so and leaves nothing behind
    Given the desktop app runs on <platform>
    And <failure>
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is told the window could not be captured
    And no half-finished capture is kept

    Examples:
      | platform         | failure                                                    |
      | macOS            | macOS returns an empty image for the window                |
      | Windows          | the Windows window capture does not answer in time         |
      | Windows          | an earlier Windows window capture is still running         |
      | Linux on GNOME   | the window in front is minimized or no window has focus    |
      | Linux on Niri    | Niri has no focused window                                 |
      | Linux on Wayland | the desktop returns an empty or unreadable screenshot      |

  @backlog @desktop
  Scenario Outline: A slow platform step ends the capture instead of hanging
    Given the desktop app runs on macOS
    And <step> has not answered after <limit>
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is told the window could not be captured
    And the next press of the shortcut captures normally

    Examples:
      | step                                          | limit      |
      | macOS finding the window in front             | 5 seconds  |
      | macOS taking the picture of the window        | 15 seconds |

  @backlog @desktop
  Scenario Outline: A capture with no window in front is explained
    Given the desktop app runs on <platform>
    And no window is available to capture
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is told the active window is not available for capture

    Examples:
      | platform |
      | macOS    |
      | Windows  |

  @backlog @desktop
  Scenario: Closing the window picker without choosing attaches nothing
    Given a Linux Wayland session on a compositor without automatic capture
    When the user presses the Snap Shot shortcut and closes the window picker without choosing
    Then nothing is attached and the user is told no window was selected

  @backlog @desktop
  Scenario: Taking a snapshot while Snap Shot is off asks the user to turn it on
    Given Snap Shot is off
    When the user takes a snapshot without the shortcut
    Then nothing is attached and the user is told to enable Snap Shot in Settings first

  @backlog @desktop
  Scenario Outline: A very large window is captured at a bounded size
    Given the desktop app runs on <platform>
    And the window in front is larger than 2,560 by 1,600 pixels
    When the user presses the Snap Shot shortcut
    Then the attached image is shrunk to fit within 2,560 by 1,600 pixels

    Examples:
      | platform         |
      | macOS            |
      | Windows          |
      | Linux on Wayland |

  @backlog @desktop
  Scenario: A very long app or window name does not lose the capture
    Given the window in front has a title of several thousand characters
    When the user presses the Snap Shot shortcut
    Then the image is attached
    And the attachment keeps the window title up to 1,000 characters and the app name up to 255

  @backlog @desktop
  Scenario Outline: The attachment names the app the way the user knows it
    Given the desktop app runs on <platform>
    And <window>
    When the user captures it
    Then the attachment names the app "<name>"

    Examples:
      | platform | window                                       | name   |
      | Windows  | the window belongs to the program "Code.exe" | Code   |
      | Windows  | the window reports no program name           | Window |

  @backlog @desktop
  Scenario: Capturing while HAL-C2 is minimized brings it back
    Given HAL-C2 is minimized and the user is working in a browser
    When the user presses the Snap Shot shortcut
    Then HAL-C2 is restored and comes to the front with the capture in its draft

  @backlog @desktop
  Scenario: The next capture does not photograph the previous capture's effects
    Given the capture effects of an earlier capture are still on screen
    When the user presses the Snap Shot shortcut again
    Then the earlier effects are dismissed before the window is captured
    And the new image shows only the window

  @backlog @desktop
  Scenario: Waiting captures are attached oldest first
    Given three captures were taken while no thread could take them
    When HAL-C2 collects the captures waiting to be attached
    Then they are attached in the order they were taken

  @backlog @desktop
  Scenario: A waiting capture that cannot be read is skipped
    Given one waiting capture's record is damaged and another is intact
    When HAL-C2 collects the captures waiting to be attached
    Then the intact capture is attached
    And the damaged one does not stop the others

  @backlog @desktop
  Scenario: A capture is removed from disk once it is in the draft
    Given a capture is waiting to be attached
    When the capture lands in the draft
    Then its image and record are deleted from the waiting captures

  @backlog @desktop
  Scenario: A capture still being written is not collected yet
    Given a capture's record is still being written
    When HAL-C2 collects the captures waiting to be attached
    Then that capture is not attached yet
    And it is attached the next time captures are collected

  @backlog @desktop
  Scenario: A waiting capture whose image is gone cannot be attached
    Given a waiting capture's record is intact but its image file is missing
    When HAL-C2 attaches that capture
    Then nothing is attached for it and the other waiting captures are attached
    And the user is told the capture could not be read

  @backlog @desktop
  Scenario: Nothing is waiting before the first capture
    Given HAL-C2 has never taken a capture
    When HAL-C2 collects the captures waiting to be attached
    Then no captures are waiting and no error is shown

  @backlog @desktop
  Scenario: A capture already removed can be acknowledged again
    Given a capture's image and record were already removed
    When the draft confirms the capture landed again
    Then no error is shown

  @backlog-desktop
  # The desktop portal gives only a screenshot.
  Scenario: Including the app's text and controls
    Given including app text is on
    When the user captures a browser window
    Then the attachment carries the window's text and controls along with the image
    And the user can inspect that data from the attachment

  @backlog-desktop
  # The desktop portal gives only a screenshot.
  Scenario: A slow app is captured without its text
    Given including app text is on and the app in front does not answer in time
    When the user presses the Snap Shot shortcut
    Then the image is attached without the app's text

  @backlog @desktop
  Scenario: A slow app's partly read text is kept and marked incomplete
    Given including app text is on and the app in front answers only part of its text in time
    When the user presses the Snap Shot shortcut
    Then the image is attached with the part of the text that was read
    And the attachment says the text is incomplete

  @backlog @desktop
  Scenario: App text is taken only from the window that was captured
    Given including app text is on
    And the app in front has several windows and none matches the captured one
    When the user presses the Snap Shot shortcut
    Then the image is attached without any app text
    And no other window's text is attached

  @backlog @desktop
  Scenario: Very long app text is cut at its limit and marked incomplete
    Given including app text is on and the window holds more than 32,000 characters of text
    When the user presses the Snap Shot shortcut
    Then the attached text stops at 32,000 characters
    And the attachment says the text is incomplete

  @backlog @desktop
  Scenario: A window with a huge number of controls is capped and marked incomplete
    Given including app text is on and the window holds more than 10,000 controls
    When the user presses the Snap Shot shortcut
    Then the attachment carries at most 10,000 controls and is marked incomplete
    And the capture still completes

  @backlog @desktop
  Scenario: Windows that cannot be told apart get no app text
    Given including app text is on
    And the app in front has two windows with the same title and the same size
    And neither of them is the one in front
    When the user presses the Snap Shot shortcut
    Then the image is attached without any app text

  @backlog @desktop
  Scenario: Of two windows that look the same the one in front gives its text
    Given including app text is on
    And the app in front has two windows with the same title and the same size
    And only one of them is in front
    When the user presses the Snap Shot shortcut
    Then the image is attached with the text and controls of the window in front

  @backlog @desktop
  Scenario: A terminal whose title changes while it is captured keeps its text
    Given a Linux Wayland session and including app text is on
    And the terminal in front shows a progress spinner at the start of its title
    And the spinner moves on between the capture and the reading of its text
    When the user presses the Snap Shot shortcut
    Then the image is attached with the terminal's text

  @backlog @desktop
  Scenario: A window of a sandboxed app still gives its text
    Given a Linux Wayland session and including app text is on
    And the app in front runs in a Flatpak sandbox that the desktop cannot find by its process
    When the user presses the Snap Shot shortcut
    Then the image is attached with the text and controls of the matching window

  @backlog @desktop
  Scenario: On Windows only the window in front gives its text
    Given the desktop app runs on Windows and including app text is on
    And the window in front belongs to a different program than the captured window
    When the user presses the Snap Shot shortcut
    Then the image is attached without any app text

  @backlog @desktop
  Scenario: A capture taken while an earlier app text read is still going has no text
    Given including app text is on
    And the app text of an earlier capture is still being read
    When the user presses the Snap Shot shortcut
    Then the image is attached without any app text
    And the capture is not held up by the earlier read

  @backlog @desktop
  Scenario: Controls carry a position only when it can be trusted
    Given including app text is on
    And the desktop reports no screen position for the app's controls
    When the user presses the Snap Shot shortcut
    Then the attachment lists the controls with their text and no positions
    And the image is attached with the window's text

  @backlog @desktop
  Scenario: Controls outside the captured image get no position
    Given including app text is on
    And the app's window has a control that lies outside the window
    When the user presses the Snap Shot shortcut
    Then that control is listed without a position
    And the controls inside the window are positioned on the captured image

  @backlog @desktop
  Scenario: Empty unnamed groups are left out of the controls
    Given including app text is on
    And the app's window has groups of controls that have no name, no text and nothing inside
    When the user presses the Snap Shot shortcut
    Then those groups are not in the attachment's controls
    And an unnamed group that holds a single control is replaced by that control

  @backlog @desktop
  Scenario Outline: A control's long text is cut and the attachment is marked incomplete
    Given including app text is on
    And a control in the window has <field> longer than <limit>
    When the user presses the Snap Shot shortcut
    Then the attachment keeps only the first <limit> of that <field>
    And the attachment says the controls are incomplete

    Examples:
      | field         | limit            |
      | a name        | 1,000 characters |
      | a value       | 8,000 characters |
      | a description | 2,000 characters |

  @backlog @desktop
  Scenario: A control lists at most 32 actions
    Given including app text is on
    And a control in the window offers more than 32 distinct actions
    When the user presses the Snap Shot shortcut
    Then the attachment lists the first 32 of that control's actions

  @backlog @desktop
  Scenario: A control's value or description that repeats its name is kept once
    Given including app text is on
    And a control in the window has the same text as its name and as its value
    When the user presses the Snap Shot shortcut
    Then the control is listed with that text once

  @backlog @desktop
  Scenario: Turning app text off stops its background helper
    Given including app text is on
    When the user turns app text off
    Then no background helper stays running to read app text
    And turning Snap Shot off has the same effect

  @backlog-desktop
  # The desktop portal cannot flash a window, and the Qt draft has no capture animation yet.
  Scenario: The capture plays its cues
    Given the sound, flash and animation are on
    When the user captures a window
    Then the sound plays, the captured window flashes and the image flies into the draft

  @backlog-desktop
  # The Qt draft has no capture animation yet.
  Scenario: Reduced motion turns the animation off
    Given the system asks for reduced motion
    When the user captures a window
    Then the image lands in the draft without animating

  Scenario: X11 sessions are not supported
    Given the desktop app runs in a Linux X11 session
    When the user opens Snap Shot settings
    Then Snap Shot is shown as not supported on this platform

  Scenario: XWayland apps can be captured on Wayland
    Given a Linux Wayland session with an app running under XWayland in front
    When the user presses the Snap Shot shortcut
    Then that app's window is captured

  @backlog-desktop
  # The Qt desktop has only the portal backend.
  Scenario: A capture uses one backend and never falls back
    Given a Hyprland session whose capture helper fails
    When the user presses the Snap Shot shortcut
    Then the capture fails and no other capture method is tried

  Scenario Outline: The Linux desktop decides how capture works
    Given a Linux Wayland session on <desktop>
    When the user sets up Snap Shot
    Then capture works through <backend>

    Examples:
      | desktop            | backend                                    |
      | another compositor | the desktop portal                         |

    # These desktops go through the desktop portal on the Qt desktop for now.
    @backlog-desktop
    Examples:
      | desktop            | backend                                    |
      | GNOME              | the HAL-C2 GNOME extension                |
      | KDE Plasma         | the capture helper                         |
      | Hyprland           | the capture helper and a Hyprland binding  |
      | Niri               | a Niri binding                             |

  Scenario: Other Wayland desktops choose a window each time
    Given a Linux Wayland session on a compositor without automatic capture
    When the user presses the Snap Shot shortcut
    Then the user picks the window to capture
    And the attachment has no text or controls data

  @backlog-desktop
  # The Qt desktop has no GNOME extension.
  Scenario: The GNOME extension needs a new login
    Given a GNOME session where the extension was just installed
    When the user continues setup
    Then the user is asked to sign out and back in, and setup waits for that

  @backlog-desktop
  # The Qt desktop has no GNOME extension.
  Scenario: A disabled GNOME extension is explained
    Given the GNOME extension is installed but turned off
    When the user checks capture access
    Then the user is told to turn on HAL-C2 SnapShots in GNOME Extensions

  @backlog-desktop
  # The Qt desktop edits no compositor config.
  Scenario: Editing a compositor config is reviewed and backed up
    Given a Hyprland session
    When the user reviews the changes to the Hyprland config and saves them
    Then the config is written in one step after checking it did not change since review
    And a backup of the previous config is kept

  @backlog-desktop
  # The Qt desktop edits no compositor config.
  Scenario: A config that changed after review is not overwritten
    Given the user reviewed the changes to the Niri config
    And the Niri config changed on disk afterwards
    When the user saves
    Then nothing is written and the user is asked to review again

  @backlog-desktop
  # The Qt desktop has no Hyprland capture.
  Scenario: Hyprland access being denied is shown plainly
    Given Hyprland refuses screen capture to HAL-C2
    When the user presses the Snap Shot shortcut
    Then the user is shown the capture was denied and how to allow it

  @backlog-desktop
  # The desktop portal gives only a screenshot.
  Scenario: GNOME browsers need accessibility for their text
    Given a GNOME session where the browser has accessibility turned off
    When the user captures the browser with app text included
    Then the image is attached and the user is told the browser needs accessibility for its text

  @backlog-desktop
  # The Qt desktop installs no capture setup.
  Scenario: Development and packaged apps keep separate capture setups
    Given both a development build and the packaged app are installed
    When the user sets up Snap Shot in the development build
    Then the packaged app's capture setup is untouched

  Scenario: A cancelled capture attaches nothing
    Given the user is working in a browser with a thread open in HAL-C2
    And the user cancels the desktop's capture prompt
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is told the snapshot was cancelled

  @backlog @desktop
  Scenario: A desktop that refuses the snapshot is told apart from a cancelled one
    Given a Linux Wayland session where the desktop portal captures the window
    And the desktop refuses the snapshot instead of the user cancelling it
    When the user presses the Snap Shot shortcut
    Then nothing is attached
    And the user is told the desktop did not allow the snapshot

  @backlog @desktop
  Scenario: A capture prompt nobody answers is given up after two minutes
    Given a Linux Wayland session where the desktop portal captures the window
    And the desktop's capture prompt stays unanswered
    When two minutes pass after the user presses the Snap Shot shortcut
    Then the prompt is closed and nothing is attached
    And the user is told the snapshot timed out

  @backlog @desktop
  Scenario: A portal that can capture one window needs no picker
    Given a Linux Wayland session on a compositor without automatic capture
    And the desktop portal can capture a single window
    When the user presses the Snap Shot shortcut
    Then the window in front is captured without a picker
    And the attachment has no text or controls data

  @backlog @desktop
  Scenario Outline: A sandboxed HAL-C2 never uses a compositor's own capture
    Given HAL-C2 runs inside a <sandbox> sandbox on a <desktop> Wayland session
    When the user sets up Snap Shot
    Then capture works through the desktop portal when it can capture a window
    And otherwise the user picks the window each time
    And no compositor config, extension or capture helper is offered

    Examples:
      | sandbox | desktop    |
      | Flatpak | GNOME      |
      | Flatpak | KDE Plasma |
      | Snap    | Hyprland   |
      | Snap    | Niri       |

  @backlog @desktop
  Scenario: The desktop portal is preferred to the GNOME extension
    Given a GNOME session with the HAL-C2 extension enabled
    And the desktop portal can capture a single window
    When the user presses the Snap Shot shortcut
    Then the capture goes through the desktop portal
    And the extension is not asked for the screenshot

  @backlog @desktop
  Scenario: The desktop's own screenshot file is read and never deleted
    Given the desktop portal saved the window's screenshot in a file it owns
    When the user presses the Snap Shot shortcut
    Then the image is attached
    And the desktop's screenshot file is left where it was

  @backlog @desktop
  Scenario Outline: A screenshot file that cannot be trusted is refused
    Given a Linux Wayland session where the desktop portal captures the window
    And the desktop hands over <file>
    When the user presses the Snap Shot shortcut
    Then nothing is attached
    And the user is told the window could not be captured

    Examples:
      | file                                   |
      | a screenshot file larger than 32 MiB   |
      | a file that is not a PNG image         |
      | a file whose image is empty            |
      | an address that is not a local file    |

  Scenario: Capturing with no project
    Given no project has been added
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is asked to add a project first

  Scenario: Turning Snap Shot off stops capturing
    Given the user is working in a browser with a thread open in HAL-C2
    And Snap Shot is off
    When the user presses the Snap Shot shortcut
    Then the desktop no longer holds the shortcut and nothing is captured

  @backlog @desktop
  Scenario: The GNOME extension answers only HAL-C2
    Given a GNOME session with the HAL-C2 extension enabled
    When another program asks the extension for a screenshot
    Then the extension refuses and no pixels are given to that program

  @backlog @desktop
  Scenario: The GNOME extension takes one capture at a time
    Given a GNOME session with the HAL-C2 extension enabled
    And a capture is already in progress
    When HAL-C2 asks for another capture
    Then the second request fails with a snapshot already in progress

  @backlog @desktop
  Scenario: The GNOME extension gives no pixels while the session is locked
    Given a GNOME session with the HAL-C2 extension enabled
    When the session is locked or the extension is turned off while a capture is being taken
    Then no screenshot is delivered
    And the user is told snapshots are unavailable in this session

  @backlog @desktop
  Scenario: Two HAL-C2 instances do not capture at the same time
    Given a GNOME session with two HAL-C2 instances running
    And one instance is capturing a window
    When the other instance's user presses the Snap Shot shortcut
    Then that capture fails and the user is told another HAL-C2 instance is capturing and to try again

  @backlog @desktop
  Scenario: Capture effects that do not start do not hold up the capture
    Given the flash and animation are on and the desktop's capture helper cannot show them
    When the user presses the Snap Shot shortcut
    Then the image is attached without waiting for the effects
    And the capture is not reported as failed

  @backlog @desktop
  Scenario: The flying capture never stays on screen for more than six seconds
    Given the animation is on
    And the draft never confirms that the capture landed
    When six seconds pass after the capture
    Then the flying image is removed from the screen

  @backlog @desktop
  Scenario: Capture effects are dismissed when the screen locks or the displays change
    Given a GNOME session and the capture's flying image is on screen
    When the session is locked or the display layout changes
    Then the capture effects are removed at once
    And the image is still attached to the draft

  @backlog @desktop
  Scenario: The flying capture says which window it came from
    Given the animation is on
    When the user captures the "Terminal" window titled "npm test"
    Then the flying image carries the app's icon, the app name "Terminal" and the title "npm test"

  @backlog @desktop
  Scenario: The flying capture of an untitled window with no icon is still labelled
    Given the animation is on
    When the user captures a window with no title and the app has no icon
    Then the flying image shows the app's first letter in place of its icon
    And the title reads "Captured window"

  @backlog @desktop
  Scenario: A capture still attaches when HAL-C2 cannot be brought forward
    Given a Linux Wayland session where the compositor refuses to focus HAL-C2
    When the user presses the Snap Shot shortcut
    Then the capture is attached to the draft
    And the capture is not reported as failed

  @backlog @desktop
  Scenario: Only the program that took the capture controls its effects
    Given a GNOME session with the HAL-C2 extension enabled
    And a capture with effects is in progress
    When another program asks the extension to bring HAL-C2 forward or move the flying image
    Then the extension refuses and the capture's effects are not changed

  @backlog @desktop
  Scenario: The flying capture is removed when HAL-C2 goes away
    Given a GNOME session and a capture's flying image is on screen
    When HAL-C2 quits or loses its connection to the desktop
    Then the flying image is removed from the screen at once

  @backlog @desktop
  Scenario: HAL-C2 is waited for briefly when its window is not on screen yet
    Given a GNOME session and HAL-C2's window was hidden to take the capture
    When the capture asks for HAL-C2 to be brought forward
    Then the desktop waits up to one and a half seconds for HAL-C2's window to appear
    And HAL-C2 is brought forward as soon as it does

  @backlog @desktop
  Scenario: Another HAL-C2 window is never brought forward in its place
    Given a GNOME session where HAL-C2 has several windows
    And none of them is the one named by the capture
    When the capture asks for HAL-C2 to be brought forward
    Then no window is brought forward
    And the capture is attached to the draft
    And the flying image is removed

  @backlog @desktop
  Scenario: A flying image never lands outside the window it flies to
    Given a GNOME session and the draft reports a landing place outside HAL-C2's window
    When the capture asks for the flying image to land there
    Then the desktop refuses the landing place
    And the flying image is removed
    And the capture is still attached to the draft

  @backlog @desktop
  Scenario: A short flight is quicker than a long one
    Given the animation is on
    When the captured window is close to the draft
    Then the flight takes about a third of a second
    And a flight across the screen takes at most about two thirds of a second

  @backlog @desktop
  Scenario: The flying image covers every display it crosses
    Given the animation is on and the user has several displays
    When the captured window and the draft are on different displays
    Then the flying image is shown across each display it passes over
    And a failing display does not cut the flight short on the others
