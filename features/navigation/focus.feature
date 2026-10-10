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
#   apps/desktop-qt/qml/HalC2/Bricks/Timeline.qml, CommandPalette.qml (accessible names)
#   apps/desktop-qt/src/native/CommandPaletteController.cpp (a background update keeps the query and highlight)
#   apps/web/src/components/ChatView.tsx (typing and pasting with nothing focused, focus on returning
#     to the window, page keys from the composer)

Feature: Keyboard focus and keyboard-only use
  Everything a user can do with the pointer can be done from the keyboard, and focus lands
  where the user expects after each action.

  Rule: Where focus goes

    @desktop
    Scenario: The palette keeps focus while it is open
      Given the command palette is open
      When a background update changes the thread list
      Then the command palette search still has keyboard focus

    @desktop
    Scenario Outline: Thread shortcuts do nothing while the command palette is open
      Given the command palette is open
      When the user presses <key>
      Then "<command>" does not run
      And the command palette is open

      Examples:
        | key         | command             |
        | mod+shift+m | modelPicker.toggle  |
        | mod+d       | diff.toggle         |
        | mod+o       | editor.openFavorite |
        | mod+alt+b   | rightPanel.toggle   |

    # The palette's own modes and what belongs to the window, not the thread.
    @desktop
    Scenario Outline: The window's shortcuts still run while the command palette is open
      Given the command palette is open
      When the user presses <key>
      Then "<command>" runs

      Examples:
        | key   | command           |
        | mod+b | sidebar.toggle    |
        | mod+p | filePicker.toggle |

    @desktop
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

    @desktop
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

    @backlog @desktop
    Scenario: Typing with nothing focused goes to the composer
      Given the user is looking at a thread and no field has keyboard focus
      When the user types "h"
      Then the composer has keyboard focus
      And the draft reads "h"

    @backlog @desktop
    Scenario Outline: Typing is left where it belongs
      Given the user is looking at a thread
      And <situation>
      When the user types "h"
      Then the composer's draft is unchanged

      Examples:
        | situation                                  |
        | another text field has keyboard focus      |
        | a button or a list row has keyboard focus  |
        | a menu or a dialog is open                 |
        | the key is pressed with a modifier held    |
        | the user is composing with an input method |

    @backlog @desktop
    Scenario: Pasting text with nothing focused goes to the composer
      Given the user is looking at a thread and no field has keyboard focus
      And the clipboard holds the text "npm test"
      When the user pastes
      Then the composer has keyboard focus
      And the draft reads "npm test"

    @backlog @desktop
    Scenario: Coming back to the window puts focus in the composer
      Given the user is looking at a thread and keyboard focus was last outside any field
      When the user switches to another app and back
      Then the composer has keyboard focus

    @backlog @desktop
    Scenario Outline: Coming back to the window leaves focus with what takes typing
      Given the user is looking at a thread and <holder> has keyboard focus
      When the user switches to another app and back
      Then <holder> still has keyboard focus

      Examples:
        | holder                         |
        | the terminal drawer            |
        | a terminal in the right panel  |
        | a search field                 |

    @backlog @desktop
    Scenario Outline: Page keys in the composer scroll the conversation
      Given the composer has keyboard focus and the conversation is longer than the view
      When the user presses <key>
      Then the conversation scrolls <direction> by a page
      And the composer keeps keyboard focus

      Examples:
        | key      | direction |
        | PageUp   | up        |
        | PageDown | down      |

  Rule: Keyboard-only thread list

    @desktop
    Scenario: Tab reaches the thread list
      Given the thread list is visible
      When the user tabs into the thread list
      Then the current thread is highlighted for the keyboard

    @desktop
    Scenario Outline: Home and End jump to the ends of the thread list
      Given the thread list has keyboard focus on a middle thread
      When the user presses <key>
      Then the <edge> thread is highlighted

      Examples:
        | key  | edge  |
        | Home | first |
        | End  | last  |

    @desktop
    Scenario Outline: Enter and Space open the highlighted thread
      Given the thread list has keyboard focus on thread "B"
      When the user presses <key>
      Then thread "B" opens

      Examples:
        | key   |
        | Enter |
        | Space |

    @desktop
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

    @desktop
    Scenario: Searching settings lists matching settings with their section
      When the user searches settings for "theme"
      Then each result names its section

    @desktop
    Scenario: A settings result opens from the keyboard
      Given the settings search lists "Theme"
      When the user presses Space on that result
      Then the section holding "Theme" opens with "Theme" highlighted

    @desktop
    Scenario: Nothing matches the settings search
      When the user searches settings for "qqqq"
      Then the user is told "No matching settings"

    @desktop
    Scenario: Escape clears the settings search
      Given the user searched settings for "theme"
      When the user presses Escape
      Then the settings search is empty
      And the section list is shown again

    @desktop
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

    @desktop
    Scenario Outline: Window controls are announced by name
      Then the window control "<name>" is available to assistive technology

      Examples:
        | name     |
        | Close    |
        | Minimize |
        | Maximize |

  Rule: The conversation and the palette are announced

    # Proved by tst_CommandPalette.qml (test_rowsAreNamedListItems), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop @backlog-mobile @backlog-tui
    Scenario: Command palette entries are announced by their title
      Given the command palette is open
      Then each entry is a list item named by its title, then its description and shortcut

    # Proved by tst_Timeline.qml (test_workLinesAreNamed), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop @backlog-mobile @backlog-tui
    Scenario: Tool calls and subagents in the timeline are announced
      Given the timeline shows tool calls and a subagent
      Then each tool call is announced by its label
      And a subagent is announced by its title, its status and its latest line, as a link when it has a thread
