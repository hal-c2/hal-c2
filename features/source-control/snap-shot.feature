# Sources:
#   docs/user/snap-shot.md
#   docs/internals/linux-snap-shot.md
#   apps/web/src/components/desktop/SnapShotCoordinator.tsx
#   apps/web/src/components/chat/SnapShotAttachmentDetails.tsx
#   apps/web/src/components/settings/SnapShotSettings.logic.ts
#   apps/web/src/components/settings/SnapShotSetupDialog.logic.ts
#   apps/desktop/src/snapShot

@backlog @desktop
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

  Scenario: Including the app's text and controls
    Given including app text is on
    When the user captures a browser window
    Then the attachment carries the window's text and controls along with the image
    And the user can inspect that data from the attachment

  Scenario: A slow app is captured without its text
    Given including app text is on and the app in front does not answer in time
    When the user presses the Snap Shot shortcut
    Then the image is attached without the app's text

  Scenario: The capture plays its cues
    Given the sound, flash and animation are on
    When the user captures a window
    Then the sound plays, the captured window flashes and the image flies into the draft

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
      | GNOME              | the HAL-C2 GNOME extension                |
      | KDE Plasma         | the capture helper                         |
      | Hyprland           | the capture helper and a Hyprland binding  |
      | Niri               | a Niri binding                             |
      | another compositor | the desktop portal                         |

  Scenario: Other Wayland desktops choose a window each time
    Given a Linux Wayland session on a compositor without automatic capture
    When the user presses the Snap Shot shortcut
    Then the user picks the window to capture
    And the attachment has no text or controls data

  Scenario: The GNOME extension needs a new login
    Given a GNOME session where the extension was just installed
    When the user continues setup
    Then the user is asked to sign out and back in, and setup waits for that

  Scenario: A disabled GNOME extension is explained
    Given the GNOME extension is installed but turned off
    When the user checks capture access
    Then the user is told to turn on HAL-C2 SnapShots in GNOME Extensions

  Scenario: Editing a compositor config is reviewed and backed up
    Given a Hyprland session
    When the user reviews the changes to the Hyprland config and saves them
    Then the config is written in one step after checking it did not change since review
    And a backup of the previous config is kept

  Scenario: A config that changed after review is not overwritten
    Given the user reviewed the changes to the Niri config
    And the Niri config changed on disk afterwards
    When the user saves
    Then nothing is written and the user is asked to review again

  Scenario: Hyprland access being denied is shown plainly
    Given Hyprland refuses screen capture to HAL-C2
    When the user presses the Snap Shot shortcut
    Then the user is shown the capture was denied and how to allow it

  Scenario: GNOME browsers need accessibility for their text
    Given a GNOME session where the browser has accessibility turned off
    When the user captures the browser with app text included
    Then the image is attached and the user is told the browser needs accessibility for its text

  Scenario: Development and packaged apps keep separate capture setups
    Given both a development build and the packaged app are installed
    When the user sets up Snap Shot in the development build
    Then the packaged app's capture setup is untouched
