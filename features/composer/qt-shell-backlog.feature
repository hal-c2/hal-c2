# Sources:
#   apps/desktop-qt/parity/features.backlog.test.ts (screen-snap-shot)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml
#   docs/user/keybindings.md (send shortcut, follow-up behaviour)
#   docs/user/snap-shot.md
#   apps/web/src/components/settings/SnapShotSettings.tsx

Feature: Desktop shell gaps: composer
  Composer behaviour the web app and the Electron desktop app have that the native desktop
  composer does not yet deliver.

  Rule: Snap Shot

    @backlog @desktop
    Scenario: The global Snap Shot shortcut attaches a screen region
      Given the composer is focused in HAL-C2
      When the user presses the global Snap Shot shortcut and selects a screen region
      Then the capture is attached to that composer

    @backlog @desktop
    Scenario: Snap Shot settings record the shortcut and show support
      When the user opens Snap Shot settings
      Then the user can record the global shortcut
      And the user can see whether the desktop compositor supports it
