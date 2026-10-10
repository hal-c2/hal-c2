# Sources:
#   docs/user/snap-shot.md
#   docs/internals/linux-snap-shot.md
#   apps/web/src/components/settings/SnapShotSettings.tsx
#   apps/web/src/components/settings/SnapShotSettings.logic.ts
#   apps/web/src/components/settings/SnapShotSetupDialog.tsx
#   apps/web/src/components/settings/SnapShotSetupDialog.logic.ts
#   apps/web/src/components/settings/useSnapShotShortcutRecorder.tsx
#   apps/web/src/components/settings/CaptureShortcutConfig.tsx (config review, backup, remove, manual setup)
#   apps/web/src/components/permissions/PermissionChecklist.tsx, usePermissionStatus.ts (permission list, status checks)
#   apps/web/src/components/settings/SnapShotSettings.test.tsx, SnapShotSettings.logic.test.ts, SnapShotSetupDialog.logic.test.ts, CaptureShortcutConfig.test.tsx, useSnapShotShortcutRecorder.test.tsx
#   apps/desktop-qt/src/native/SnapShotController.cpp
#   apps/desktop/src/permissions/MacPermissionHelper.ts (the drag-the-app panel beside System Settings)
#   apps/desktop/src/snapShot/CaptureShortcutConfig.ts, captureConfigEdit.ts, captureConfigKdl.ts (config review refusals and edits)
#   apps/desktop/src/snapShot/PortalCaptureShortcut.ts, NiriCaptureShortcut.ts, NiriSnapShot.ts (shortcut session and endpoint errors)
#   apps/desktop/src/snapShot/GnomeCaptureSetup.ts, KdeSnapShot.ts, HyprlandSnapShot.ts (extension and helper install safety)
#   apps/desktop/src/snapShot/DesktopSnapShot.ts, snapShot.ts (shortcut registration, modifier-pair and conflict messages)
# The Qt desktop captures through the desktop portal on Linux Wayland only: no
# macOS or Windows capture, no capture helper, no compositor bindings and no
# app text yet.

@desktop
Feature: Snap Shot settings
  The SnapShots panel turns capture on, walks through setup, records the shortcut and
  sets the capture cues. Capturing itself lives in source-control/snap-shot.feature.

  Background:
    Given the user opens Settings, SnapShots in the desktop app

  Scenario: Snap Shot is off until the user turns it on
    Given the user never turned on Snap Shot
    When the panel loads
    Then capture is off and the user is invited to turn it on to set up snapshots

  Scenario: Turning on Snap Shot starts setup
    When the user turns on snapshots
    Then setup asks the user to allow capture and then to choose a shortcut

  @backlog-desktop
  # The Qt desktop captures only on Linux so far.
  Scenario Outline: Setup asks for the permissions the platform needs
    Given the desktop app runs on <platform>
    When the user allows capture during setup
    Then the user is asked for <permissions>

    Examples:
      | platform                          | permissions                          |
      | macOS                             | Screen Recording                     |
      | macOS with app text included      | Screen Recording and Accessibility   |
      | Windows                           | nothing                              |

  @backlog-desktop
  # There is no capture helper to install on the Qt desktop.
  Scenario: Finishing setup later
    Given the user installed the capture helper during setup
    When the user chooses to finish later
    Then capture is off and the helper stays installed

  Scenario: Turning Snap Shot off
    Given Snap Shot is on with a shortcut
    When the user turns off snapshots
    Then the shortcut is released and nothing that was installed is removed

  @backlog-desktop
  # The Qt desktop captures only on Linux so far.
  Scenario: The default shortcut presses both Shift keys
    Given the desktop app runs on macOS
    When the user finishes setup without changing the shortcut
    Then the shortcut is pressing both Shift keys

  Scenario: Recording a new shortcut
    When the user changes the shortcut and presses Ctrl+Shift+2
    Then the shortcut is saved as Ctrl+Shift+2

  Scenario: Cancelling shortcut recording
    Given the user is recording a new shortcut
    When the user presses Escape
    Then the previous shortcut is kept

  Scenario Outline: A shortcut that cannot be used is refused
    When the user records <shortcut>
    Then the shortcut is refused because <reason>

    Examples:
      | shortcut                                  | reason                                         |
      | a modifier with no key on Linux           | Linux shortcuts need a letter, number or function key |
      | a shortcut HAL-C2 already uses           | it collides with a HAL-C2 keybinding           |
      | a shortcut the system reserves            | the system reserves it                          |

  @backlog-desktop
  # The desktop portal gives only a screenshot.
  Scenario: Including app text
    When the user turns on including app text
    Then captures carry the app's text and controls when the app makes them available

  Scenario Outline: Choosing the capture cues
    When the user turns <cue> off
    Then captures happen without <effect>

    Examples:
      | cue       | effect                                 |
      | sound     | a sound                                |

    # The desktop portal cannot flash a window, and the Qt draft has no
    # capture animation yet.
    @backlog-desktop
    Examples:
      | cue       | effect                                 |
      | flash     | a flash on the captured window         |
      | animation | the image flying into the draft        |

  Scenario: Choosing the capture sound
    When the user picks the Click sound
    Then captures play Click instead of Whoosh

  Scenario: Capture effects that the desktop cannot show
    Given a Niri session
    When the panel loads
    Then the user is told capture effects are not available on Niri

  @backlog-desktop
  # The Qt desktop edits no compositor config.
  Scenario: Reviewing compositor changes again
    Given a Hyprland session where the Snap Shot binding changed outside HAL-C2
    When the panel loads
    Then setup reopens to review the changes

  @dropped
  # HAL-C2 has no web client.
  Scenario: The web app says Snap Shot needs the desktop app
    Given the user opens Settings, SnapShots in a browser
    When the panel loads
    Then the user is told "Only available in the desktop app."

  Scenario: Finishing setup later leaves Snap Shot off
    When the user turns on snapshots
    And the user chooses to finish later
    Then capture is off and the user is invited to turn it on to set up snapshots

  Scenario: The desktop does not allow the shortcut
    Given the desktop will not allow the shortcut
    When the user changes the shortcut and presses Ctrl+Shift+2
    Then the user is told the desktop did not allow it and can ask again

  @backlog @desktop
  Scenario Outline: The panel says where capture setup stands
    Given Snap Shot is <situation>
    When the panel loads
    Then the capture row reads "<status>"

    Examples:
      | situation                                                          | status                                               |
      | still being checked                                                | Checking snapshots…                                  |
      | off                                                                | Turn this on to set up snapshots.                    |
      | on but the capture helper is not installed                         | Install the capture helper to continue               |
      | on but the capture helper's access check failed                    | Check capture access in setup                        |
      | on with the GNOME extension not enabled                            | Set up active-window snapshots                       |
      | on with only a manual window picker available                      | Manual capture only — you'll choose a window each time |
      | on and waiting for the user to approve the shortcut                | Waiting for shortcut permission                      |
      | on with a shortcut saved but never seen to work from another app   | Use your shortcut from another app                   |
      | on with a shortcut that has been seen to work                      | Ready to capture                                     |
      | on with no shortcut chosen yet                                     | Finish shortcut setup                                |
      | on but the desktop reports a problem                               | Capture needs attention                              |

  @backlog @desktop
  Scenario: A desktop without capture says why instead of offering setup
    Given the desktop reports that capture is not supported on this platform
    When the panel loads
    Then the capture row says the desktop's reason, or "Not supported on this platform."
    And capture cannot be turned on

  @backlog @desktop
  Scenario Outline: The setup button names the desktop it sets up
    Given Snap Shot is on and setup is not finished on <desktop>
    When the panel loads
    Then the setup button reads "<button>"

    Examples:
      | desktop                          | button                |
      | GNOME                            | Set up GNOME capture  |
      | KDE Plasma                       | Set up KDE capture    |
      | a desktop HAL-C2 cannot name     | Continue setup        |

  @backlog @desktop
  Scenario: Setup that is complete reads as managing capture
    Given capture access is in place
    When the panel loads
    Then the setup button reads "Manage capture"
    And it reopens setup to revisit access or the shortcut

  @backlog @desktop
  Scenario: Windows turns capture on without any setup
    Given the desktop app runs on Windows
    When the user turns on snapshots
    Then capture is on and no setup is opened
    And the setup button is not shown

  @backlog @desktop
  Scenario: macOS hides setup once permissions and the shortcut are in place
    Given the desktop app runs on macOS
    And Screen Recording is allowed, and Accessibility too when app text is included
    And a shortcut is saved
    When the panel loads
    Then no setup button is shown and the shortcut stays editable in the panel
    When the user revokes a permission
    Then the setup button returns as "Continue setup"

  @backlog @desktop
  Scenario: On macOS, turning on capture needs a test capture that works
    Given the desktop app runs on macOS
    When the user allows capture in setup and the test capture fails
    Then capture stays off, the user is told "Couldn't verify capture access" with the reason
    And the user can try again

  @backlog @desktop
  Scenario: Setup continues after macOS restarts the app for a permission
    Given the desktop app runs on macOS
    And the user allowed Screen Recording and the app had to quit and reopen
    When the panel loads
    Then setup resumes where the user left it, with capture on or off as it was

  # Legacy: apps/desktop/src/permissions/MacPermissionHelper.ts
  @backlog @desktop
  Scenario: macOS shows where to drop the app when a permission must be granted by hand
    Given the desktop app runs on macOS
    When the user is sent to System Settings to allow Screen Recording or Accessibility
    Then a small panel beside System Settings says to drag HAL-C2 into the list
    And the user can drag the app from it or choose to reveal the app in Finder

  @backlog @desktop
  Scenario: The permission panel goes away when it is no longer needed
    Given the permission panel is showing beside System Settings
    When the permission is granted
    Then the panel closes itself
    When instead the user closes System Settings or brings another app forward
    Then the panel closes or hides with it

  @backlog @desktop
  Scenario: A shortcut is saved only when the user saves it
    Given Snap Shot is on with the shortcut Ctrl+Shift+1
    When the user changes the shortcut and presses Ctrl+Shift+2
    Then the panel shows Ctrl+Shift+2 with Save and Cancel
    And the shortcut in use is still Ctrl+Shift+1
    When the user cancels
    Then the panel shows Ctrl+Shift+1 again and nothing changed

  @backlog @desktop
  Scenario Outline: The shortcut row says what is happening with a new shortcut
    Given the user is changing the shortcut
    When <moment>
    Then the shortcut row says "<message>"

    Examples:
      | moment                                                    | message                                         |
      | recording starts                                          | Press your shortcut. Esc cancels.               |
      | the desktop is being asked if the shortcut is free        | Checking shortcut…                              |
      | the desktop says the shortcut is free                     | Ready to save.                                  |
      | the shortcut is one HAL-C2 uses for "Toggle terminal"     | HAL-C2 already uses this for "Toggle terminal". |
      | the user presses only modifier keys on a Wayland desktop  | Add a letter, number, or function key to your shortcut. |

  @backlog @desktop
  Scenario: A shortcut that cannot be checked is reported, not assumed free
    Given the user recorded a new shortcut
    When the desktop fails while checking it
    Then the shortcut row shows the failure, or "Could not check this shortcut."
    And Save is not available

  @backlog @desktop
  Scenario: Only the newest shortcut check counts
    Given the user recorded a shortcut and its check is still running
    When the user records another shortcut
    Then the answer to the first check is ignored
    And the second shortcut's answer decides whether Save is available

  @backlog @desktop
  Scenario: A portal desktop suggests a letter-based shortcut
    Given a desktop that gives shortcuts through the desktop portal
    And no shortcut is saved yet
    When the panel loads
    Then the shortcut row suggests a shortcut such as Ctrl+Shift+2
    And pressing both Shift keys is not offered as the shortcut

  @backlog @desktop
  Scenario: Capture shortcuts are paused while a new one is recorded
    Given Snap Shot is on with a shortcut
    When the user starts recording a new shortcut and presses the current one
    Then no capture starts
    And pausing the capture shortcut ends when recording ends, is cancelled, or the panel closes

  @backlog @desktop
  Scenario: Recording a shortcut cannot start when the desktop will not pause capture
    Given the desktop fails to pause the capture shortcut
    When the user starts recording a shortcut
    Then recording does not start
    And the user is told "Could not start shortcut recording." or the desktop's reason

  @backlog @desktop
  Scenario: Pressing Tab while recording moves on without recording a shortcut
    Given the user is recording a new shortcut
    When the user presses Tab, holds a key down, or presses a modifier on its own
    Then no shortcut is recorded

  @backlog @desktop
  Scenario: Shortcut permission can be asked for again
    Given the desktop shows a portal shortcut that was refused or never granted
    When the user chooses Shortcut permissions
    Then the desktop asks for the shortcut again
    And the button is disabled while its prompt is pending
    And the row says "Approve the shortcut permission prompt to continue." while it is

  @backlog @desktop
  Scenario: Asking again is not offered when it cannot help
    Given the shortcut is a modifier pair, or the desktop says asking again changes nothing
    When the panel loads
    Then there is no Shortcut permissions button

  @backlog @desktop
  Scenario: A shortcut kept in the compositor is changed through setup
    Given a Niri or Hyprland session where HAL-C2 keeps the binding in the compositor config
    When the panel loads
    Then the shortcut row offers "Change shortcut"
    And choosing it opens setup at the shortcut step

  @backlog @desktop
  Scenario: A shortcut that cannot be read is replaced, not guessed
    Given the desktop reports a shortcut HAL-C2 cannot read
    When the panel loads
    Then the shortcut row says "Change shortcut" instead of showing keys
    And recording a new one replaces it

  @backlog @desktop
  Scenario: App text is not offered where the desktop only gives a screenshot
    Given a Linux desktop that only provides a screenshot
    When the panel loads
    Then including app text is off and cannot be turned on
    And the panel says "This desktop only provides a screenshot."

  @backlog @desktop
  Scenario: Including app text asks for the permission on macOS
    Given Snap Shot is on and the desktop app runs on macOS
    When the user turns on including app text
    Then the user is asked for Accessibility
    When the permission is refused
    Then app text stays off and the user is told "Couldn't allow app text capture" with the reason

  @backlog @desktop
  Scenario: A preference that fails to save stays as it was
    Given the user's settings cannot be written
    When the user turns off the capture sound
    Then the sound is still on
    And the user is told the save failed with the reason

  @backlog @desktop
  Scenario Outline: The sound menu offers Off, Whoosh and Click
    When the user opens the capture sound choices
    Then the choices are Off, "Whoosh (Default)" and Click
    And the current choice is shown on the row as <current>

    Examples:
      | current          |
      | Off              |
      | Whoosh (Default) |
      | Click            |

  @backlog @desktop
  Scenario: A capture sound can be heard before choosing it
    Given the capture sound choices are open
    When the user plays Click without selecting it
    Then Click plays once
    And the choices stay open and the sound in use does not change

  @backlog @desktop
  Scenario Outline: The panel explains why capture effects are not available
    Given a Linux session where <situation>
    When the panel loads
    Then the user is told "<message>"

    Examples:
      | situation                                                    | message                                                                 |
      | Hyprland has its helper ready but no effects                 | Capture effects aren't available on this desktop.                       |
      | Hyprland has no helper or an outdated one                    | Install or update the capture helper to enable effects.                 |
      | KDE Plasma has its helper ready but no effects               | Capture effects aren't available on this desktop.                       |
      | KDE Plasma has no helper or an outdated one                  | Install or update the capture helper to enable effects.                 |
      | the GNOME extension is installed but is the first version    | Update the GNOME extension, then sign out and back in to enable effects. |
      | GNOME setup has not been finished                            | Finish extension setup to enable effects.                               |
      | any other desktop but Niri                                   | Capture effects aren't available on this desktop.                       |

  @backlog @desktop
  Scenario: A desktop that can only pick a window says so
    Given a desktop that gives only a window picker
    When the panel loads
    Then the capture row says "Automatic capture isn't available here. Choose a window instead."
    And the shortcut row says "Choose a window to capture from any app."

  @backlog @desktop
  Scenario: The panel catches up when the user returns or the shortcut changes elsewhere
    Given the panel is open
    When the user returns to the app after changing capture access or the shortcut outside it
    Then the panel shows the current state without being reopened
    And it does the same when the desktop reports the shortcut changed

  @backlog @desktop
  Scenario: A permission error is shown once and can be retried
    Given the user asked for shortcut permission and the desktop failed
    Then the user is told what went wrong once
    And the user can ask again

  @backlog @desktop
  Scenario: Setup errors stay in setup
    Given setup is open and a step fails
    Then the error is shown in setup
    And closing setup does not repeat it in the panel

  @backlog @desktop
  Scenario: Finishing later restores capture to how it was before setup opened
    Given Snap Shot was off and the user opened setup
    When the user chooses to finish later
    Then capture is off again
    Given Snap Shot was on and the user opened setup to change something
    When the user chooses to finish later
    Then capture is still on

  @backlog @desktop
  Scenario: Setup that cannot save the opt-in keeps finishing later available
    Given Snap Shot is off
    And turning it on succeeds but the following status check fails
    When the user opens setup
    Then setup opens at its first step
    And finishing later turns capture back off

  @backlog @desktop
  Scenario: Setup has two steps, access then shortcut
    When the user opens setup
    Then the title says "Set up snapshots for" the user's desktop, or just "Set up snapshots"
    And the steps are capture access and the shortcut
    And the user can go back to access but cannot jump ahead to the shortcut

  @backlog @desktop
  Scenario Outline: Setup is closed with Close once it has been on, otherwise Finish later
    Given Snap Shot was <state> when the user opened setup
    Then the setup footer offers "<button>"

    Examples:
      | state | button       |
      | on    | Close        |
      | off   | Finish later |

  @backlog @desktop
  Scenario: Setup cannot be dismissed while it is working
    Given setup is checking access or saving
    Then the user cannot close setup or move between its steps until it has finished

  @backlog @desktop
  Scenario Outline: The access step walks through the GNOME extension
    Given a GNOME session where the extension is <state>
    When the user is on the access step
    Then setup says "<title>" with the action "<action>"

    Examples:
      | state                                    | title                       | action              |
      | not installed                            | Install the extension       | Install extension   |
      | installed but waiting for a new login    | Extension installed         | Check again         |
      | installed but too old                    | Update the extension        | Update extension    |
      | installed while GNOME extensions are off | Allow GNOME extensions      | Check again         |
      | installed but turned off                 | Enable the extension        | Enable extension    |
      | enabled and answering                    | Capture is ready            | Continue            |
      | failing to start                         | Couldn't set up the extension | Check again       |

  @backlog @desktop
  Scenario: A GNOME version the extension does not support falls back to choosing a window
    Given a GNOME version the extension does not support
    When the user is on the access step
    Then setup says "Automatic capture isn't available"
    And it points to Take snapshot in the command palette to choose a window
    And the user can still finish setup

  @backlog @desktop
  Scenario: The user can remove what setup installed
    Given the GNOME extension is enabled
    When the user opens Advanced on the access step
    Then they can disable the extension
    And on KDE Plasma and Hyprland they can remove the capture helper
    And the helper's own note says it is included with HAL-C2 and needs no download

  @backlog @desktop
  Scenario Outline: The access step offers the capture helper on KDE Plasma and Hyprland
    Given a <desktop> session where the capture helper is <state>
    When the user is on the access step
    Then setup offers "<action>"

    Examples:
      | desktop    | state                | action                      |
      | KDE Plasma | not installed        | Install the capture helper  |
      | KDE Plasma | out of date          | Update the capture helper   |
      | KDE Plasma | failing its check    | Check again                 |
      | Hyprland   | not installed        | Install the capture helper  |
      | Hyprland   | failing its check    | Check again                 |

  @backlog @desktop
  Scenario: A failing capture helper suggests reinstalling it
    Given a KDE Plasma session where the capture helper fails its access check
    When the user checks again and it still fails
    Then setup says "Let's fix capture access"
    And suggests reinstalling the capture helper and checking again

  @backlog @desktop
  Scenario: Checking capture access that cannot be read is not reported as a success
    Given the desktop cannot report whether capture is supported
    When the user checks capture access
    Then setup says "Let's try that again" and "Couldn't check snapshots. Try again to continue."
    And capture access is not reported as ready

  @backlog @desktop
  Scenario: An access check that changes nothing says so
    Given a GNOME session that still needs a new login
    When the user checks again
    Then the answer is acknowledged and setup keeps asking for the login

  @backlog @desktop
  Scenario: Hyprland may ask for permission the first time
    Given a Hyprland session with the capture helper installed
    When the user is on the access step
    Then setup says the desktop may ask for permission when the user first captures

  @backlog @desktop
  Scenario: macOS permissions are granted one at a time
    Given the desktop app runs on macOS
    When the user is on the access step
    Then Screen Recording is shown with "Capture the window you're using."
    And Accessibility is shown as optional text and controls
    And Continue is "Test capture and continue"
    And Accessibility only gates Continue when app text is included

  @backlog @desktop
  Scenario: The macOS test capture is discarded
    Given the desktop app runs on macOS
    When the user continues past the access step
    Then the user is told macOS may ask to bypass its window picker and to choose Allow
    And the test image is discarded

  @backlog @desktop
  Scenario: Finishing needs capture access to still be there
    Given the user is on the shortcut step
    When capture access is lost
    Then setup says "Capture needs attention. Go back to check access."
    And the user cannot finish until access is back

  @backlog @desktop
  Scenario: A shortcut that changed must be saved before setup finishes
    Given the user is on the shortcut step with a saved shortcut
    When the user records a different one
    Then the finishing button reads "Save and finish" and is available only when the shortcut can be saved
    When the user records nothing
    Then the button reads "Done"

  @backlog @desktop
  Scenario Outline: The shortcut step explains what to press
    Given the user is on the shortcut step on <platform>
    Then setup says "<instruction>"

    Examples:
      | platform                                    | instruction                                              |
      | a desktop that records modifier pairs       | Use both Shift keys, or record a different shortcut.     |
      | a desktop that gives shortcuts by portal    | Choose your keys, then approve the permission prompt if asked. |
      | while recording                             | Click the shortcut, then press the keys you want.        |

  @backlog @desktop
  Scenario: Leaving setup while the desktop's prompt is open is allowed, a refusal is not
    Given setup asked the desktop for a shortcut and its prompt is pending
    Then the user can finish setup and approve the prompt later
    When the desktop has refused the shortcut
    Then the user cannot finish until it is allowed or changed

  @backlog @desktop
  Scenario: A Niri or Hyprland shortcut is reviewed before it is written
    Given a Niri or Hyprland session
    When the user records a shortcut and chooses Review changes
    Then the config's changes are shown as a diff with "Only these changes will be saved. We'll keep a backup."
    And nothing is written until the user chooses Save shortcut

  @backlog @desktop
  Scenario: Preparing config changes shows progress and can fail
    Given a Hyprland session
    When the user chooses Review changes
    Then the button reads "Preparing changes…" until the proposal arrives
    When the desktop cannot prepare the changes
    Then the user is told "Couldn't prepare the changes. Check Advanced for help."
    And the technical reason is under Advanced
    And the user can try again

  @backlog @desktop
  Scenario: Changing the keys while reviewing needs a new diff
    Given the user is reviewing a diff for the shortcut Ctrl+Shift+1
    When the user records Ctrl+Shift+3
    Then the old diff is withdrawn and the user reviews again

  @backlog @desktop
  Scenario: Cancelling a reviewed diff writes nothing
    Given the user is reviewing a diff
    When the user cancels
    Then the config is not written and setup is not finished

  @backlog @desktop
  Scenario: A shortcut already in the config is not written again
    Given the config already holds the shortcut
    When the user reviews changes
    Then the user is told "This shortcut is already set up."
    And the user can choose Done

  @backlog @desktop
  Scenario: Saving the shortcut finishes setup with a message
    Given the user reviewed a diff and saves it
    When the config is written and the desktop reloaded
    Then the user is told "Shortcut saved" and to use the shortcut from another app
    And setup closes

  @backlog @desktop
  Scenario: A reload that fails is not reported as success
    Given the user reviewed a diff and saves it
    When the config is written but the desktop could not reload
    Then the user is told "Saved, but the shortcut needs attention. Check Advanced for help."
    And setup does not finish

  @backlog @desktop
  Scenario: A failed write asks for another review
    Given the user reviewed a diff and saves it
    When the write fails
    Then the user is told "Couldn't save your shortcut. Review the changes and try again."
    And the old diff is withdrawn

  @backlog @desktop
  Scenario: The shortcut can be removed from the compositor config
    Given a Niri or Hyprland session with a saved shortcut
    When the user chooses Remove shortcut under Advanced and reviews the change
    Then the diff removes only HAL-C2's binding
    And saving says "Shortcut removed."
    And with no binding to remove the user is told "There's no capture shortcut to remove."

  @backlog @desktop
  Scenario: The config file can be chosen by the user
    Given a Niri or Hyprland session
    When the user opens Advanced and chooses a different file
    Then the changes are prepared against that file
    And the panel shows which settings file is in use, including a link's target and that it will be kept

  @backlog @desktop
  Scenario: The binding can be set up by hand
    Given a Niri or Hyprland session
    When the user opens Advanced
    Then the binding is shown with where to paste it and a way to copy it
    And copying says "Copied"

  @backlog @desktop
  Scenario: The config that was written is backed up and its path shown
    Given the user saved the shortcut into the config
    When the user opens Advanced
    Then the backup file's path is shown

  @backlog @desktop
  Scenario: A config change cannot be prepared by an older desktop app
    Given the desktop app is too old to prepare compositor config changes
    When the user is on the shortcut step
    Then Review changes is unavailable
    And the user is told "Update HAL-C2 to finish setting up your shortcut."

  @backlog @desktop
  Scenario: A shortcut waiting for the compositor says what is missing
    Given a Hyprland session where HAL-C2's shortcut action is not registered yet
    When the user is on the shortcut step
    Then setup says "Connecting to your desktop…" while it connects
    And "Restart HAL-C2 to finish connecting your shortcut." when it is not coming

  @backlog @desktop
  Scenario Outline: A config that is not safe to edit is refused with a reason
    Given a Niri or Hyprland session
    And <config>
    When the user chooses Review changes
    Then nothing is changed and the user is told "<reason>"

    Examples:
      | config                                                          | reason                                                                  |
      | the settings file cannot be read                                | Couldn't read your settings file. Choose a different file in Advanced.  |
      | the settings file belongs to another user or to Omarchy defaults | Choose your own config, not system or Omarchy defaults.                |
      | the settings file has an unexpected extension                   | Choose a .kdl Niri config or a .conf/.lua Hyprland config.              |
      | a Niri config includes files by pattern or variable             | This config uses a dynamic include. Use manual setup in Advanced.       |
      | a Niri config includes more than 64 files or nests deeper than 10 levels | This config has too many included files. Use manual setup in Advanced. |
      | a Niri include cannot be read                                   | Couldn't read an included Niri config. Check its location in Advanced.  |
      | a Hyprland Lua config returns early or uses long strings       | This Lua config needs a manual edit. Choose your bindings file or use manual setup in Advanced. |
      | a Niri config has more than one binds section                   | This Niri config has an unexpected binds section. Check it in Advanced. |

  @backlog @desktop
  Scenario: A shortcut already used elsewhere is refused before it is written
    Given a Niri or Hyprland session
    And the chosen keys are already bound in the config, in a file it includes, or by Hyprland itself
    When the user chooses Review changes
    Then nothing is changed and the user is told the keys are already used and to choose another shortcut

  @backlog @desktop
  Scenario: A Hyprland that cannot list its shortcuts blocks the change
    Given a Hyprland session that cannot report its current shortcuts
    When the user chooses Review changes
    Then the user is told to try again from the Hyprland session
    And nothing is changed

  @backlog @desktop
  Scenario: Only one config change is prepared at a time
    Given the desktop is saving a reviewed shortcut change
    When the user asks to review another change
    Then the user is told to wait for the current config change to finish

  @backlog @desktop
  Scenario: A shortcut that is not a letter, number or function key with Ctrl, Alt or Super is refused for the config
    Given a Niri or Hyprland session
    When the user records a shortcut of Shift and a letter, or of a punctuation key
    Then the user is told to choose a letter, number or function key with Ctrl, Alt or Super

  @backlog @desktop
  Scenario: A Niri config is checked before it replaces the user's file
    Given the user reviewed a change to the Niri config
    When the user saves
    Then Niri validates the new config first
    And a config Niri rejects is not saved

  @backlog @desktop
  Scenario: Saving keeps the file's permissions and line endings
    Given the user reviewed a change to a config that uses Windows line endings and is readable only by the user
    When the user saves
    Then the new binding uses the same line endings
    And the file keeps its permissions

  @backlog @desktop
  Scenario Outline: A config file that is too big or not text is refused
    Given a Niri or Hyprland session
    And <config>
    When the user chooses Review changes
    Then nothing is changed and the user is told "<reason>"

    Examples:
      | config                                                    | reason                              |
      | the settings file is larger than 1 MB                     | Choose a config file smaller than 1 MB. |
      | the settings file and its included files add up to more than 1 MB | This config has too many included files. Use manual setup in Advanced. |
      | the settings file is not a text file                      | Choose a text config file.          |

  @backlog @desktop
  Scenario: A Hyprland that reports config errors after a reload fails the save
    Given the user reviewed a change to the Hyprland config and saves it
    When Hyprland reloads and reports errors in its config
    Then the user is told Hyprland reported config errors
    And setup does not finish

  @backlog @desktop
  Scenario: A review that is no longer current cannot be saved
    Given the user reviewed a change to the Niri or Hyprland config
    And the user has since reviewed another change, or the change was already saved
    When the user saves the earlier review
    Then nothing is written
    And the user is told the preview expired and to review the changes again

  @backlog @desktop
  Scenario: A missing optional include that appears after review is not ignored
    Given the user reviewed a change to a Niri config that includes an optional file that does not exist
    And that file has been created since the review
    When the user saves
    Then nothing is written and the user is asked to review again

  @backlog @desktop
  Scenario Outline: A shortcut on a key the Wayland portal cannot name is refused
    Given a desktop that gives shortcuts through the desktop portal
    When the user records <shortcut>
    Then the shortcut row says "This key isn't supported as a Wayland capture shortcut. Choose another key."

    Examples:
      | shortcut                      |
      | Ctrl+Shift with an arrow key  |
      | Ctrl+Alt with Home            |

  @backlog @desktop
  Scenario Outline: A shortcut the system or common apps already use says why
    Given the user is changing the shortcut
    When the user records <shortcut>
    Then the shortcut row says "<message>"
    And Save is not available

    Examples:
      | shortcut      | message                                                                  |
      | Shift+K       | Shift combinations are used for typing and text selection. Add another modifier. |
      | Ctrl+C        | This shortcut is Copy in most apps.                                      |
      | Ctrl+S        | This shortcut is Save in most apps.                                      |
      | Ctrl+Z        | This shortcut is Undo in most apps.                                      |
      | Alt+Tab       | The system uses Alt+Tab to switch apps.                                  |
      | Super+L       | The system already uses this shortcut.                                   |

  @backlog @desktop
  Scenario Outline: A shortcut of one modifier key warns that it is observed, not reserved
    Given the desktop app runs on <platform>
    When the user chooses the shortcut of pressing both <key> keys
    Then the shortcut row says it is observed and cannot be reserved exclusively
    And it adds "<note>"

    Examples:
      | platform | key   | note                                           |
      | Windows  | Super | This key can also open the system's own menu.  |
      | Linux    | Super | This key can also open the system's own menu.  |
      | Windows  | Alt   | This key can also activate app menu bars.      |
      | macOS    | Shift | no further note                                |

  @backlog @desktop
  Scenario: A modifier key the system will not let HAL-C2 watch is reported
    Given the desktop app runs on Windows or macOS
    When the user chooses a shortcut of pressing both of a modifier key and the system refuses to let HAL-C2 watch it
    Then the shortcut row says that key is not available on this system
    And capture does not claim the shortcut is registered

  @backlog @desktop
  Scenario: A modifier-pair shortcut is not offered in a Wayland session that cannot watch keys
    Given a Wayland session that is not Hyprland
    When the user chooses the shortcut of pressing both Shift keys
    Then the shortcut row says modifier-pair shortcuts aren't available in this Wayland session
    And it suggests another shortcut or Take snapshot from the command palette

  @backlog @desktop
  Scenario Outline: The shortcut row says what the desktop did with the shortcut request
    Given a desktop that gives shortcuts through the desktop portal
    When <outcome>
    Then the shortcut row says "<message>"

    Examples:
      | outcome                                                                      | message                                                                                  |
      | the desktop grants the shortcut and shows it as "Ctrl+Alt+S"                  | Desktop shortcut: Ctrl+Alt+S                                                             |
      | the user refuses the permission prompt on a desktop that can ask again        | Shortcut permission wasn't granted. Open shortcut permissions to allow it.               |
      | the user refuses the permission prompt on a desktop that cannot ask again     | Shortcut permission wasn't granted. Allow HAL-C2 in your desktop's shortcut settings.    |
      | the desktop grants the shortcut but assigns no keys, and can ask again        | No shortcut is assigned. Open shortcut permissions to choose one.                        |
      | the desktop grants the shortcut but assigns no keys, and cannot ask again     | No shortcut is assigned. Choose one in your desktop's shortcut settings.                 |

  @backlog @desktop
  Scenario: The portal's shortcut prompt is waited for up to two minutes
    Given a desktop that gives shortcuts through the desktop portal
    And the desktop's shortcut permission prompt is open
    When the user takes up to two minutes to answer it
    Then HAL-C2 keeps waiting and the shortcut row keeps asking for the prompt to be approved
    And the shortcut is registered as soon as the user approves

  @backlog @desktop
  Scenario Outline: A Hyprland shortcut session says whether the capture action is registered
    Given a Hyprland session where the binding is kept in the Hyprland config
    When <situation>
    Then the shortcut row says "<message>"

    Examples:
      | situation                                                    | message                                                                                                                         |
      | HAL-C2 is still connecting to Hyprland's shortcuts           | Connecting to Hyprland shortcuts…                                                                                               |
      | Hyprland registers the capture action                        | Managed by Hyprland. Add the binding to your config and save it.                                                                |
      | Hyprland does not register the capture action                | Hyprland did not register the capture action. Check that xdg-desktop-portal-hyprland is running, then restart HAL-C2.            |
      | Hyprland's shortcut session cannot be reached                | Couldn't connect to Hyprland shortcuts. Make sure xdg-desktop-portal-hyprland is running, then restart HAL-C2.                   |

  @backlog @desktop
  Scenario: Asking for the shortcut again is not offered for a Hyprland binding
    Given a Hyprland session where the binding is kept in the Hyprland config
    When the user asks for the shortcut permission
    Then the user is told to change the capture binding in the Hyprland config and save it

  @backlog @desktop
  Scenario: Asking again without a shortcut session says where to allow it
    Given a desktop that gives shortcuts through the desktop portal
    And the desktop's shortcut session could not be started
    When the user asks for the shortcut permission
    Then the user is told to open the desktop's shortcut settings and allow HAL-C2's capture shortcut

  @backlog @desktop
  Scenario Outline: A shortcut service that fails says what to do
    Given a desktop that gives shortcuts through the desktop portal
    When <failure>
    Then the shortcut row says "<message>"
    And the user can ask for the shortcut again

    Examples:
      | failure                                               | message                                                             |
      | the desktop's shortcut service restarts                | The desktop shortcut service restarted. Retry the shortcut request. |
      | the desktop closes HAL-C2's shortcut session           | Your desktop closed the capture shortcut. Retry the shortcut request. |
      | the permission prompt is not answered in time          | Shortcut permission request timed out. Try again.                   |
      | the desktop's shortcut service cannot be reached       | Could not connect to your desktop's shortcut service.               |

  @backlog @desktop
  Scenario Outline: The Niri capture shortcut endpoint reports why it is not working
    Given a Niri session of version 25.11 or newer
    When <situation>
    Then the panel says "<message>"

    Examples:
      | situation                                                    | message                                                                    |
      | another HAL-C2 instance already owns the endpoint            | Could not start the Niri capture endpoint. Another HAL-C2 instance may be using it. |
      | the endpoint disconnects while HAL-C2 is running             | The Niri capture endpoint disconnected. Restart HAL-C2.                    |
      | the endpoint is up and the binding is not in the config yet  | Set up the shortcut to add it to your Niri config.                         |

  @backlog @desktop
  Scenario: Niri older than 25.11 cannot capture
    Given a Niri session older than version 25.11
    When the user presses the Snap Shot shortcut
    Then nothing is attached and the user is told SnapShots require Niri 25.11 or newer

  @backlog @desktop
  Scenario: The Niri binding endpoint refuses calls with arguments
    Given a Niri session with the capture binding set up
    When another program calls the capture endpoint with arguments
    Then the call is refused as invalid
    And no capture is taken

  @backlog @desktop
  Scenario: Shortcut settings in Niri and Hyprland are changed in the compositor
    Given a Niri or Hyprland session
    When the user checks a shortcut in HAL-C2
    Then the shortcut row says to configure the capture shortcut in the compositor's config and save it
    And HAL-C2 does not register the shortcut itself

  @backlog @desktop
  Scenario: Saving unrelated settings leaves the shortcut registered
    Given Snap Shot is on and its shortcut is registered
    When the user changes a setting that is not about Snap Shot
    Then the shortcut stays registered without being released and set up again
    And an approved desktop shortcut session is not dropped

  @backlog @desktop
  Scenario: A permission that macOS grants again brings the shortcut back
    Given the desktop app runs on macOS
    And Snap Shot is on and a permission was revoked so capture needs attention
    When the user allows the permission again
    Then the panel clears the message and the shortcut works again
    And no restart of HAL-C2 is needed

  @backlog @desktop
  Scenario: Updating the GNOME extension keeps the version it replaces
    Given a GNOME session with an older HAL-C2 extension installed
    When the user updates the extension in setup
    Then the new extension is put in place in one step
    And the replaced version is kept in a backup folder
    And a failed update puts the old version back

  @backlog @desktop
  Scenario: A newer GNOME extension is not replaced by an older bundle
    Given a GNOME session with a newer HAL-C2 extension installed than the one bundled with the app
    When the user installs the extension in setup
    Then nothing is replaced
    And the user is told a newer extension is installed and to update HAL-C2 instead

  @backlog @desktop
  Scenario: An extension folder that is a link is left to GNOME Extensions
    Given the HAL-C2 extension's folder is a link or not a regular folder
    When the user installs the extension in setup
    Then nothing is replaced
    And the user is told to manage it in GNOME Extensions instead

  @backlog @desktop
  Scenario: GNOME extensions turned off by the user are not turned on for them
    Given a GNOME session where the user has turned off all user extensions
    When the user checks capture access
    Then setup tells the user to turn on Extensions in the GNOME Extensions app
    And HAL-C2 does not enable the user's other extensions

  @backlog @desktop
  Scenario: Installing the extension needs no download or administrator password
    Given a GNOME session where the extension is not installed
    When the user installs the extension in setup
    Then the extension bundled with the app is copied for this user only
    And nothing is downloaded and no administrator password is asked

  @backlog @desktop
  Scenario Outline: A capture helper is never written over a link
    Given a <desktop> session
    And <conflict>
    When the user installs or removes the capture helper
    Then nothing is replaced
    And the user is told "<message>"

    Examples:
      | desktop    | conflict                                          | message                                                                             |
      | KDE Plasma | the helper or its launcher entry is a link         | Capture helper files must be regular files. Remove the conflicting link before trying again. |
      | KDE Plasma | the helper's folder is a link                      | The capture helper directory is not a regular directory.                           |
      | KDE Plasma | another program's launcher entry has the helper's name | Another desktop entry uses the capture helper's name. Rename it before continuing. |
      | Hyprland   | the helper is a link                               | The capture helper must be a regular file, not a link.                              |
      | Hyprland   | the helper's folder is a link                      | The capture helper directory must not be a link.                                    |

  @backlog @desktop
  Scenario Outline: A capture helper that this build does not carry is reported
    Given a <desktop> session
    And the app was built without its capture helper
    When the user checks capture access or installs the helper
    Then the user is told the helper is missing from this build and to update or reinstall HAL-C2

    Examples:
      | desktop    |
      | KDE Plasma |
      | Hyprland   |

  @backlog @desktop
  Scenario Outline: A capture helper that cannot be set up says why
    Given a KDE Plasma session
    When <situation>
    Then the user is told "<message>"

    Examples:
      | situation                                                | message                                                                                              |
      | KDE's service tools are not installed                    | KDE couldn't register the capture helper. Make sure KDE's service tools (kbuildsycoca6) are installed, then reinstall the helper. |
      | KDE has not granted the helper screen capture access     | KDE hasn't granted capture access. Reinstall the capture helper in setup, then try again.           |
      | the helper does not answer a check                       | The KDE capture helper did not respond. Reopen capture setup and check access.                       |

  @backlog @desktop
  Scenario: Capturing before the capture helper is ready points to setup
    Given a KDE Plasma or Hyprland session where the capture helper is not ready
    When the user presses the Snap Shot shortcut
    Then nothing is attached
    And the user is told what is missing and to open Settings, SnapShots to continue setup

  @backlog @desktop
  Scenario: A Hyprland capture helper that does not answer fails the capture
    Given a Hyprland session with the capture helper installed
    And the helper does not answer within twenty seconds
    When the user presses the Snap Shot shortcut
    Then nothing is attached
    And the user is told Hyprland capture did not respond and to check capture setup and try again

  @backlog @desktop
  Scenario: Setup installs or removes only what the user chose
    Given a KDE Plasma or Hyprland session
    When the user checks capture access without choosing to install
    Then nothing is written to the user's files
    And files are written only after the user chooses to install the helper

  @backlog @desktop
  Scenario Outline: A setup step that belongs to another desktop is refused
    Given the desktop app runs <session>
    When setup is asked to <step>
    Then nothing is installed, removed or changed
    And the user is told this step is not available in this session

    Examples:
      | session                 | step                                     |
      | on a GNOME session      | install the KDE Plasma capture helper    |
      | on a KDE Plasma session | install the Hyprland capture helper      |
      | on Linux without GNOME  | install the GNOME extension              |
      | on Linux                | allow screen recording the way macOS does |
      | on Linux                | test a capture the way macOS does        |
      | on Windows              | review a Niri or Hyprland config change  |

  # The Qt desktop and its capture code ship as one app, so there is no older bridge to update past.
  @dropped @desktop
  Scenario: An older desktop app is told to update to use snapshots
    Given the desktop app predates the Snap Shot bridge
    When the user opens Settings, SnapShots
    Then the user is told "Update the desktop app to use snapshots."

  @backlog @desktop
  Scenario: Setup lists each permission and lets the user continue only when all are allowed
    Given setup asks for two permissions and one is allowed
    Then the allowed permission is marked as allowed
    And the other offers to be allowed
    And the user cannot continue
    When the user allows the other permission in system settings and returns to the app
    Then both are marked as allowed
    And the user can continue

  @backlog @desktop
  Scenario: A permission check that fails is retried on its own
    Given setup is waiting on a permission
    When the check of the permission's state fails
    Then the user is told "Could not check permissions. We'll try again automatically."
    And the user cannot continue
    When the next check succeeds
    Then the message goes away
