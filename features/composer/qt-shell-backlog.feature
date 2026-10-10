# Sources:
#   apps/desktop-qt/parity/features.backlog.test.ts (screen-snap-shot)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml
#   docs/user/keybindings.md (send shortcut, follow-up behaviour)
#   docs/user/snap-shot.md
#   apps/web/src/components/settings/SnapShotSettings.tsx
#   apps/web/src/components/desktop/SnapShotCoordinator.tsx (delivery target, errors, sound, animation)
#   apps/web/src/lib/snapShotSource.ts, snapShotSetupResume.ts, snapShotShortcut.ts, snapShotAnimation.ts

Feature: Desktop shell gaps: composer
  Composer behaviour the web app and the Electron desktop app have that the native desktop
  composer does not yet deliver.

  Rule: Snap Shot

    @desktop
    Scenario: The global Snap Shot shortcut attaches a screen region
      Given the composer is focused in HAL-C2
      When the user presses the global Snap Shot shortcut and selects a screen region
      Then the capture is attached to that composer

    @desktop
    Scenario: Snap Shot settings record the shortcut and show support
      When the user opens Snap Shot settings
      Then the user can record the global shortcut
      And the user can see whether the desktop compositor supports it

    @backlog @desktop
    Scenario: A capture goes to the conversation the user was in when they asked for it
      Given the user is in a thread
      When the user presses the Snap Shot shortcut
      And the user opens another thread before the capture arrives
      Then the capture is attached to the thread they were in when they pressed it

    @backlog @desktop
    Scenario: A capture is shrunk to fit and keeps its window data in the right place
      Given a captured window is larger than the provider's image limit
      And the capture carries the window's controls with their positions
      When the capture is attached
      Then the image is shrunk to fit
      And each control's position is scaled with the image

    @backlog @desktop
    Scenario: A capture the draft has no room for says to remove an attachment
      Given the draft already holds as many attachments as it can
      When a Snap Shot capture arrives
      Then the user is asked to remove an attachment and try the capture again

    @backlog @desktop
    Scenario: A capture taken while the app was away is attached when it returns
      Given a Snap Shot capture was taken while the app was in the background or closed
      When the app is brought back
      Then the capture is attached to the draft once
      And it is not attached again on the next focus

    @backlog @desktop
    Scenario: A failed capture is reported with its reason
      When a Snap Shot capture fails
      Then the user is told the snapshot failed and why
      And no capture animation or sound is left running

    @backlog @desktop
    Scenario: The capture sound plays once per capture
      Given the capture sound is on
      When a capture is taken and then delivered
      Then the sound plays once

    @backlog @desktop
    Scenario: Leaving the window ends a capture animation
      Given a capture animation is flying toward the draft
      When the user switches to another window
      Then the animation ends
      And the capture is still attached to the draft

    @backlog @desktop
    Scenario: Snap Shot setup resumes after the user grants a permission in system settings
      Given the user left Snap Shot setup to grant a permission in system settings
      When the app starts again
      Then Snap Shot setup reopens where it left off
      And it reopens only once for that launch

    @backlog @desktop
    Scenario: A Snap Shot shortcut that collides with a HAL-C2 keybinding is refused
      Given a HAL-C2 keybinding uses "Ctrl+Shift+S"
      When the user records "Ctrl+Shift+S" as the Snap Shot shortcut
      Then the shortcut is refused naming the keybinding it collides with
