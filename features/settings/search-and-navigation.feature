# Sources:
#   apps/web/src/components/settings/settingsSearch.ts
#   apps/web/src/components/settings/useAvailableSettingsSearchItems.ts
#   apps/web/src/components/settings/SettingsSidebarNav.tsx
#   apps/web/src/components/settings/SettingsBreadcrumb.tsx
#   apps/web/src/components/settings/settingsLayout.tsx
#   apps/web/src/components/settings/SettingsPanels.tsx (settings restore)
#   apps/web/src/components/settings/SettingsPanels.logic.ts
#   apps/web/src/components/settings/FoldedSettingsSection.tsx
#   apps/web/src/components/settings/KeybindingsSettings.tsx (navigation and scope only)
#   apps/web/src/components/settings/ThemeSettings.tsx (navigation only)
#   docs/user/appearance.md (Settings → Appearance, Settings → Keybindings)
#   apps/desktop-qt/qml/HalC2/Bricks/SettingsNav.qml
#   apps/desktop-qt/tests/tst_SettingsNav.qml
#   apps/desktop-qt/qml/HalC2/Bricks/js/settingsPages.js (the native search)
#   apps/desktop-qt/qml/HalC2/Bricks/SettingsPage.qml (bringing a result into view)
#   apps/desktop-qt/tests/tst_SettingsPages.qml
#   apps/desktop-qt/tests/tst_ProjectSettings.qml (the Default model result)
#   apps/desktop-qt/src/native/ThemeController.cpp, SettingsController.cpp (restoring defaults)
#   apps/desktop-qt/tests/native/tst_ThemeResolution.cpp (a theme that cannot be restored)
#   apps/desktop-qt/src/native/NavigationController.cpp (settings sections and back)
#   apps/desktop-qt/src/native/DraftController.cpp (back to nowhere lands on a draft)
#   apps/tui/src/components/SettingsView.tsx
#   apps/tui/src/keymap.ts

Feature: Settings search and navigation
  Settings are grouped into sections the user can move between, and one search finds any
  setting by name or related words and takes the user straight to it.

  Background:
    Given the user has opened settings

  Rule: Moving between sections

    @desktop
    Scenario: Choosing a section opens it
      When the user chooses the "Providers" section
      Then the Providers settings are shown
      And "Providers" is marked as the current section

    @desktop
    Scenario: The keyboard moves through sections
      Given the "General" section has keyboard focus
      When the user moves down and confirms
      Then the next section opens

    @desktop
    Scenario: Leaving settings returns to where the user was
      Given the user opened settings from a thread
      When the user goes back
      Then the thread is shown again

    @desktop
    Scenario: Moving between sections is one step back
      Given the user opened settings from a thread
      When the user picks the settings section "/settings/providers"
      Then the window shows the settings section "/settings/providers"
      When the user goes back from settings
      Then that thread is shown

    @desktop
    Scenario: Back with nowhere to return to lands on a new thread
      When the user goes back from settings
      Then the window shows a new draft in "shop"
      And the user can not go back

    @backlog @desktop
    Scenario Outline: The page names where the user is
      When the user opens <page>
      Then the page is titled "Settings / <section>"

      Examples:
        | page                              | section               |
        | the Keybindings section           | Keybindings           |
        | the Appearance section            | Appearance            |
        | diagnostics                       | Diagnostics           |
        | the open source licenses page     | Open source licenses  |

    @backlog @desktop
    Scenario: The project section appears only while editing a project
      Given the user is editing settings for all projects
      Then there is no project section
      When the user chooses the project "hal-c2"
      Then the project section is listed first

    @backlog @desktop
    Scenario: Device-only sections do not ask where settings apply
      When the user opens the Appearance section
      Then the page does not offer a choice of project or environment

    @backlog @desktop
    Scenario: Moving between sections keeps the chosen scope
      Given the user is editing settings for the project "hal-c2"
      When the user opens the Integrations section
      Then settings still apply to "hal-c2"

    @tui
    Scenario: The terminal client shows a read-only settings overview
      When the user opens settings in the terminal client
      Then the current model, reasoning, mode and runtime access are shown
      And the branch, pull request and working tree state are shown
      And the keybinding reference is listed by context

    @tui
    Scenario: The terminal settings overview closes with escape
      Given the settings overview is open in the terminal client
      When the user presses escape
      Then the conversation is shown again

  Rule: Searching settings

    # The desktop finds the settings of its native pages; Network access is not one yet.
    @desktop @backlog-desktop
    Scenario: Search results show each setting with its section
      When the user searches settings for "network"
      Then "Network access" is listed under "Connections"

    @desktop
    Scenario: Opening a search result goes to that setting
      Given the user has searched settings for "theme"
      When the user opens the first result
      Then the section holding that setting opens
      And the page brings the setting into view

    @desktop
    Scenario: Nothing matches the search
      When the user searches settings for "zzzz"
      Then the user is told no settings match

    @desktop
    Scenario: Escape clears the search
      Given the user has searched settings for "model"
      When the user presses escape in the search
      Then the search is empty
      And the list of sections is shown again

    # tst_SettingsPages.qml and tst_SettingsNav.qml check the next ones in QML, but no
    # feature runner drives the settings page yet.
    @desktop @backlog-desktop
    Scenario: The slash key starts a settings search
      Given the keyboard is not in a text field
      When the user presses "/"
      Then the settings search has keyboard focus

    @desktop @backlog-desktop
    Scenario Outline: Results are ranked by how well the title matches
      When the user searches settings for "<query>"
      Then the first result is "<first>"

      Examples:
        | query  | first          |
        | model  | Default model  |
        | mod+b  | Sidebar: Toggle |

    # Tailscale HTTPS is not a native Connections setting yet.
    @backlog @desktop
    Scenario: Every word of the search must match
      When the user searches settings for "tailscale https"
      Then only "Tailscale HTTPS" is listed

    @backlog @desktop
    Scenario Outline: Settings that do not apply here are not found
      Given <condition>
      When the user searches settings for "<query>"
      Then "<setting>" is not listed

      Examples:
        | condition                                  | query       | setting           |
        | the user is in a web browser               | local env   | Local environment |
        | the machine is not running Windows         | wsl         | WSL backend       |
        | the user is editing all projects           | project     | Project overview  |

    # Load balancing is not on the native Connections page yet (settings/load-balancing.feature).
    @backlog @desktop
    Scenario: A search result inside a folded section opens the fold
      Given the "Load balancing" group on the Connections page is folded
      When the user opens the search result "Load balancing"
      Then the "Load balancing" group is open
      And the page brings the setting into view

    @desktop @backlog-desktop
    Scenario: Opening the same result again scrolls back to it
      Given the user opened the search result "Default model" and scrolled away
      When the user opens the search result "Default model" again
      Then the page brings the setting into view again

  Rule: Restoring defaults

    # SettingsNav.qml asks and resets (tst_SettingsNav.qml, tst_ThemeResolution.cpp), but no
    # feature runner drives the settings page yet.
    @desktop @backlog-desktop
    Scenario: Restoring defaults lists what will change and asks first
      Given the user has changed the theme and the time format
      When the user restores default settings
      Then the user is asked to confirm a reset of the theme and the time format

    @desktop @backlog-desktop
    Scenario: Confirming the restore resets the listed settings
      Given the user is asked to confirm restoring default settings
      When the user confirms
      Then the theme and the time format are back to their defaults

    @desktop @backlog-desktop
    Scenario: Cancelling the restore changes nothing
      Given the user is asked to confirm restoring default settings
      When the user cancels
      Then every setting keeps its value

    @desktop @backlog-desktop
    Scenario: A theme that cannot be restored rolls back
      Given saving the theme on this device fails
      When the user confirms restoring default settings
      Then the theme settings keep their previous values
      And the user is told the theme settings could not be restored
