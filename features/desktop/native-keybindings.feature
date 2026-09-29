# Sources:
#   apps/desktop-qt/src/native/KeybindingController.cpp (the keymap, its native commands and keybinding.press)
#   apps/desktop-qt/src/native/Keybindings.cpp (defaults, when expressions, merging the node's rules)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (window shortcuts, standing down for a focused page or terminal)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/components/Sidebar.tsx (thread.previous, thread.next and thread.jump follow the sidebar's order)
#   Shared domain: navigation/keybindings.feature and navigation/keybinding-customisation.feature
#   own what each binding does; this file owns that the Qt shell keeps the keymap and runs
#   its own commands without the page.

Feature: The desktop shell keeps the keymap
  The Qt shell merges the defaults with the rules the node keeps in keybindings.json, the way
  the web app does. It runs the commands it owns itself (a new thread, back, the sidebar, the
  terminal, the next, previous or numbered thread, the composer's pickers, stopping a turn)
  and hands every other bound key to the page as a keybinding press.

  Rule: The shell's own commands move the window

    Background:
      Given the time is "2026-09-23T10:00:00Z"
      And the desktop's node "node-a" serves the environment "env-a"
      And the node has these threads:
        | id | project | title  | createdAt            |
        | t1 | p1      | First  | 2026-09-23T09:50:00Z |
        | t2 | p1      | Second | 2026-09-23T09:40:00Z |
        | t3 | p1      | Third  | 2026-09-23T09:30:00Z |
      And the node has the project "p1" titled "proj-1"
      And the desktop shell is connected to its node

    @desktop
    Scenario: The next and previous thread follow the sidebar
      Given the user opens "env-a:t1" from the sidebar
      When the user presses mod+shift+]
      Then the window shows "env-a:t2"
      When the user presses mod+shift+[
      Then the window shows "env-a:t1"

    @desktop
    Scenario: There is no thread past either end of the sidebar
      Given the user opens "env-a:t3" from the sidebar
      When the user presses mod+shift+]
      Then the window shows "env-a:t3"

    @desktop
    Scenario: A thread's number opens it
      Given the user opens "env-a:t1" from the sidebar
      When the user presses mod+3
      Then the window shows "env-a:t3"

    @desktop
    Scenario: The new thread shortcut starts one in the project the window shows
      Given the user opens "env-a:t2" from the sidebar
      When the user presses mod+n
      Then the window shows a new draft in "proj-1"

    @desktop
    Scenario: The back shortcut returns where the user came from
      Given the user opens "env-a:t1" from the sidebar
      And the user opens "env-a:t2" from the sidebar
      When the user presses mod+[
      Then the window shows "env-a:t1"

    @desktop
    Scenario: A key the page forwards runs the shell's command
      Given the user opens "env-a:t1" from the sidebar
      When the page forwards mod+shift+]
      Then the window shows "env-a:t2"

  Rule: Focus decides who takes a key

    @desktop
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
    Scenario: The page's commands go to the page from the native chrome
      Given the native chrome has keyboard focus
      When the user presses mod+k
      Then the page is handed the key once
      And "commandPalette.toggle" runs

  Rule: The node's rules apply as they change

    @desktop
    Scenario: A rule the node pushes applies at once
      Given no custom keybindings
      When the node adds the rule mod+alt+g for "diff.toggle"
      And the user presses mod+alt+g
      Then "diff.toggle" runs

    @desktop
    Scenario: A rule the node removes stops applying
      Given "diff.toggle" is bound to mod+alt+g
      When the node removes every custom rule
      And the user presses mod+alt+g
      Then "diff.toggle" does not run

  Rule: Stopping a turn

    Background:
      Given a connected environment with the project "shop"
      And the user is looking at a thread in "shop" whose agent is working

    @desktop
    Scenario: A shortcut bound to stop interrupts the running turn
      Given "thread.stop" is bound to mod+shift+.
      When the user presses mod+shift+.
      Then the running turn is interrupted
