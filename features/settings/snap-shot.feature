# Sources:
#   docs/user/snap-shot.md
#   docs/internals/linux-snap-shot.md
#   apps/web/src/components/settings/SnapShotSettings.tsx
#   apps/web/src/components/settings/SnapShotSettings.logic.ts
#   apps/web/src/components/settings/SnapShotSetupDialog.tsx
#   apps/web/src/components/settings/SnapShotSetupDialog.logic.ts
#   apps/web/src/components/settings/useSnapShotShortcutRecorder.tsx

@backlog @desktop
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

  Scenario Outline: Setup asks for the permissions the platform needs
    Given the desktop app runs on <platform>
    When the user allows capture during setup
    Then the user is asked for <permissions>

    Examples:
      | platform                          | permissions                          |
      | macOS                             | Screen Recording                     |
      | macOS with app text included      | Screen Recording and Accessibility   |
      | Windows                           | nothing                              |

  Scenario: Finishing setup later
    Given the user installed the capture helper during setup
    When the user chooses to finish later
    Then capture is off and the helper stays installed

  Scenario: Turning Snap Shot off
    Given Snap Shot is on with a shortcut
    When the user turns off snapshots
    Then the shortcut is released and nothing that was installed is removed

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
      | a shortcut T3 Code already uses           | it collides with a T3 Code keybinding           |
      | a shortcut the system reserves            | the system reserves it                          |

  Scenario: Including app text
    When the user turns on including app text
    Then captures carry the app's text and controls when the app makes them available

  Scenario Outline: Choosing the capture cues
    When the user turns <cue> off
    Then captures happen without <effect>

    Examples:
      | cue       | effect                                 |
      | sound     | a sound                                |
      | flash     | a flash on the captured window         |
      | animation | the image flying into the draft        |

  Scenario: Choosing the capture sound
    When the user picks the Click sound
    Then captures play Click instead of Whoosh

  Scenario: Capture effects that the desktop cannot show
    Given a Niri session
    When the panel loads
    Then the user is told capture effects are not available on Niri

  Scenario: Reviewing compositor changes again
    Given a Hyprland session where the Snap Shot binding changed outside T3 Code
    When the panel loads
    Then setup reopens to review the changes

  Scenario: The web app says Snap Shot needs the desktop app
    Given the user opens Settings, SnapShots in a browser
    When the panel loads
    Then the user is told "Only available in the desktop app."
