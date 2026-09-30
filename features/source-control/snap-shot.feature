# Sources:
#   docs/user/snap-shot.md
#   docs/internals/linux-snap-shot.md
#   apps/web/src/components/desktop/SnapShotCoordinator.tsx
#   apps/web/src/components/chat/SnapShotAttachmentDetails.tsx
#   apps/web/src/components/settings/SnapShotSettings.logic.ts
#   apps/web/src/components/settings/SnapShotSetupDialog.logic.ts
#   apps/desktop/src/snapShot
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

  Scenario: Capturing with no project
    Given no project has been added
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is asked to add a project first

  Scenario: Turning Snap Shot off stops capturing
    Given the user is working in a browser with a thread open in HAL-C2
    And Snap Shot is off
    When the user presses the Snap Shot shortcut
    Then the desktop no longer holds the shortcut and nothing is captured
