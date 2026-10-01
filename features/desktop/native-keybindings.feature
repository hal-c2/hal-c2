# Sources:
#   apps/desktop-qt/src/native/KeybindingController.cpp (the keymap and its native commands)
#   apps/desktop-qt/src/native/Keybindings.cpp (defaults, when expressions, merging the MC's rules)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (window shortcuts, standing down for a focused terminal)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   Shared domain: navigation/keybindings.feature and navigation/keybinding-customisation.feature
#   own what each binding does, including the thread shortcuts and the MC's rules;
#   composer/queue-and-steer.feature owns the stop shortcut. This file owns only who takes a
#   key when a terminal, the composer or the native chrome has focus.

Feature: The desktop shell keeps the keymap
  The Qt shell runs the commands it owns itself, even when a terminal has focus. A key it has
  no command for stays with the focused control.

  # The embedded page is gone, and with it the keys it forwarded and the focus it held.
  @dropped
  Rule: A key the page forwards runs natively

    Background:
      Given the time is "2026-09-23T10:00:00Z"
      And the desktop's MC "mc-a" serves the environment "env-a"
      And the MC has these threads:
        | id | project | title  | createdAt            |
        | t1 | p1      | First  | 2026-09-23T09:50:00Z |
        | t2 | p1      | Second | 2026-09-23T09:40:00Z |
        | t3 | p1      | Third  | 2026-09-23T09:30:00Z |
      And the MC has the project "p1" titled "proj-1"
      And the desktop shell is connected to its MC

    @desktop
    Scenario: A key the page forwards runs the shell's command
      Given the user opens "env-a:t1" from the sidebar
      When the page forwards mod+shift+]
      Then the window shows "env-a:t2"

  Rule: Focus decides who takes a key

    # The desktop has no embedded page to hold focus.
    @dropped @desktop
    Scenario: A shell command taken from a focused page runs once
      Given the page has keyboard focus
      When the user presses mod+b
      Then "sidebar.toggle" runs
      And the desktop shell does not forward it a second time

    @desktop
    Scenario: A focused terminal still hands the shell its own commands
      Given the user is in a terminal
      When the user presses mod+b
      Then "sidebar.toggle" runs

    @desktop
    Scenario: The native chrome's keys run in the shell
      Given the native chrome has keyboard focus
      When the user presses mod+o
      Then "editor.openFavorite" runs

    @desktop
    Scenario: A key the shell has no command for stays with the focused control
      Given the composer has keyboard focus
      When the user presses mod+shift+y
      Then the composer receives the key
