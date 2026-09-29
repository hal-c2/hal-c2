# Sources:
#   docs/user/keyboard-focus.md
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (list keyboard navigation)
#   apps/desktop-qt/qml/HalC2/Bricks/SettingsNav.qml
#   apps/desktop-qt/qml/HalC2/Bricks/RightPanel.qml (tab activation from the keyboard)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (focusInput)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalDrawer.qml (focusTerminal, focus on open)
#   apps/desktop-qt/tests/native/tst_ShellExamples.cpp (terminalDrawerTakesAndReturnsTheKeyboard,
#     panelTabsSupportKeyboardActivationAndClose)
#   apps/desktop-qt/tests/tst_SettingsNav.qml
#   apps/desktop-qt/src/native/NavigationController.cpp (leaving settings)
#   apps/desktop-qt/qml/HalC2/Bricks/WindowControls.qml (accessible names)
#   apps/desktop-qt/src/native/CommandPaletteController.cpp (a background update keeps the query and highlight)

Feature: Keyboard focus and keyboard-only use
  Everything a user can do with the pointer can be done from the keyboard, and focus lands
  where the user expects after each action.

  Rule: Where focus goes

    @desktop
    Scenario: The palette keeps focus while it is open
      Given the command palette is open
      When a background update changes the thread list
      Then the command palette search still has keyboard focus

    @backlog @desktop
    Scenario: Number shortcuts pick entries in an open picker
      Given the model picker is open
      When the user presses mod+2
      Then the second model is chosen
      And no thread jump happens

    @backlog @desktop
    Scenario: Model shortcuts work in settings too
      Given the user is in settings
      When the user presses the model picker shortcut
      Then the model picker opens

    @backlog @desktop
    Scenario: Typing while a terminal starts stays in the composer
      Given the user is typing in the composer
      When a terminal starts on its own
      Then the composer keeps keyboard focus

    @desktop
    Scenario: Explicitly opening a terminal focuses it
      Given the terminal is closed
      When the user opens the terminal
      Then the terminal has keyboard focus

    @backlog @desktop
    Scenario: A new thread puts focus in the composer
      When the user starts a new thread
      Then the composer has keyboard focus

  Rule: Keyboard-only thread list

    # Delivered natively (Sidebar's keyboard outline); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: Tab reaches the thread list
      Given the thread list is visible
      When the user tabs into the thread list
      Then the current thread is highlighted for the keyboard

    # Delivered natively (Sidebar's keyboard outline); no desktop test yet.
    @desktop @backlog-desktop
    Scenario Outline: Home and End jump to the ends of the thread list
      Given the thread list has keyboard focus on a middle thread
      When the user presses <key>
      Then the <edge> thread is highlighted

      Examples:
        | key  | edge  |
        | Home | first |
        | End  | last  |

    # Delivered natively (Sidebar's keyboard outline); no desktop test yet.
    @desktop @backlog-desktop
    Scenario Outline: Enter and Space open the highlighted thread
      Given the thread list has keyboard focus on thread "B"
      When the user presses <key>
      Then thread "B" opens

      Examples:
        | key   |
        | Enter |
        | Space |

    # Delivered natively (Sidebar's keyboard outline); no desktop test yet.
    @desktop @backlog-desktop
    Scenario: The menu key opens the highlighted thread's menu
      Given the thread list has keyboard focus on thread "B"
      When the user presses the menu key
      Then the menu for thread "B" opens beside it

  Rule: Keyboard-only settings navigation

    Background:
      Given the user is in settings

    @desktop @backlog-desktop
    Scenario: Down and Enter move to the next section
      Given the "General" section has keyboard focus
      When the user presses Down and then Enter
      Then the "Providers" section opens

    @desktop @backlog-desktop
    Scenario: Up and Space move to the previous section
      Given the "Providers" section has keyboard focus
      When the user presses Up and then Space
      Then the "General" section opens

    @desktop @backlog-desktop
    Scenario: Searching settings lists matching settings with their section
      When the user searches settings for "theme"
      Then each result names its section

    @desktop @backlog-desktop
    Scenario: A settings result opens from the keyboard
      Given the settings search lists "Theme"
      When the user presses Space on that result
      Then the section holding "Theme" opens with "Theme" highlighted

    @desktop @backlog-desktop
    Scenario: Nothing matches the settings search
      When the user searches settings for "qqqq"
      Then the user is told "No matching settings"

    @desktop @backlog-desktop
    Scenario: Escape clears the settings search
      Given the user searched settings for "theme"
      When the user presses Escape
      Then the settings search is empty
      And the section list is shown again

    @desktop @backlog-desktop
    Scenario: The search follows a query set elsewhere
      Given the user cleared the settings search with Escape
      When the app sets the settings search to "font"
      Then the settings search shows "font"

    @desktop
    Scenario: Leaving settings goes back to the thread
      Given the user opened settings from a thread
      When the user goes back from settings
      Then that thread is shown

  Rule: Keyboard-only panels and window

    @desktop
    Scenario: A right panel tab is activated from the keyboard
      Given the right panel has "Diff" and "Files" tabs with "Diff" active
      When the user focuses the "Files" tab and presses Enter
      Then the "Files" tab is active

    # Delivered natively (WindowControls' accessible names); no desktop test yet.
    @desktop @backlog-desktop
    Scenario Outline: Window controls are announced by name
      Then the window control "<name>" is available to assistive technology

      Examples:
        | name     |
        | Close    |
        | Minimize |
        | Maximize |
