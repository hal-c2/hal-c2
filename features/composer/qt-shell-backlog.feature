# Sources:
#   apps/desktop-qt/parity/features.backlog.test.ts (composer-keyboard-parity, screen-snap-shot)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml
#   docs/user/keybindings.md (send shortcut, follow-up behaviour)
#   docs/user/snap-shot.md
#   apps/web/src/components/settings/SnapShotSettings.tsx

Feature: Desktop shell gaps: composer
  Composer behaviour the web app and the Electron desktop app have that the native desktop
  composer does not yet deliver.

  Rule: Keyboard parity

    @backlog @desktop
    Scenario: Shift+Tab switches between plan and build
      Given the composer is in build mode with keyboard focus
      When the user presses Shift+Tab
      Then the composer is in plan mode

    @backlog @desktop
    Scenario: Up in an empty composer recalls the previous prompt
      Given the user sent "Run the tests" earlier in this thread
      And the composer is empty with keyboard focus
      When the user presses Up
      Then the composer contains "Run the tests"

    @backlog @desktop
    Scenario: mod+alt+Enter sends in the background from the composer
      Given a new thread's composer has a draft and keyboard focus
      When the user presses mod+alt+Enter
      Then the thread starts in the background
      And the window shortcut does not take the key

    @backlog @desktop
    Scenario Outline: mod+Enter during a turn does the opposite of the follow-up setting
      Given follow-ups are set to <setting>
      And a turn is running
      And the composer has a draft with keyboard focus
      When the user presses mod+Enter
      Then the draft is <result>

      Examples:
        | setting | result  |
        | Queue   | steered |
        | Steer   | queued  |

    @backlog @desktop
    Scenario: mod+shift+E opens the effort picker
      Given the composer has keyboard focus
      When the user presses mod+shift+E
      Then the effort picker opens

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
