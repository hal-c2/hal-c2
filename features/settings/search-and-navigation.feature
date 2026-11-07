# Sources:
#   https://github.com/pingdotgg/t3code/pull/27376
#   https://github.com/pingdotgg/t3code/pull/20764
#   https://github.com/pingdotgg/t3code/pull/17396
#   https://github.com/pingdotgg/t3code/pull/17859
#   https://github.com/pingdotgg/t3code/pull/13516 (Escape in settings returns to the last main page)
#   https://github.com/pingdotgg/t3code/pull/25651
#   https://github.com/pingdotgg/t3code/pull/25686
#   apps/web/src/components/settings/settingsSearch.ts
#   apps/web/src/components/settings/useAvailableSettingsSearchItems.ts
#   apps/web/src/components/settings/SettingsSidebarNav.tsx
#   apps/web/src/components/settings/SettingsBreadcrumb.tsx
#   apps/web/src/components/settings/settingsLayout.tsx
#   apps/web/src/components/settings/SettingsPanels.tsx (settings restore)
#   apps/web/src/routes/settings.tsx (the restore control)
#   apps/web/src/routes/settings.tsx (SettingsScopeBoundary), apps/web/src/components/settings/SettingsScopeNotice.tsx
#   apps/web/src/components/settings/SettingsPanels.logic.ts
#   apps/web/src/components/settings/FoldedSettingsSection.tsx
#   apps/web/src/components/settings/KeybindingsSettings.tsx (navigation and scope only)
#   apps/web/src/components/settings/ThemeSettings.tsx (navigation only)
#   docs/user/appearance.md (Settings → Appearance, Settings → Keybindings)
#   apps/desktop-qt/qml/HalC2/Bricks/SettingsNav.qml
#   apps/desktop-qt/tests/tst_SettingsNav.qml
#   apps/desktop-qt/qml/HalC2/Bricks/js/settingsPages.js (the native search)
#   apps/desktop-qt/qml/HalC2/Bricks/SettingsPage.qml (bringing a result into view)
#   apps/desktop-qt/qml/HalC2/Bricks/LoadBalancingGroup.qml (the fold a result opens)
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
    Scenario: Tab from the settings search reaches the current section
      Given the user has focus in the settings search
      When the user presses Tab
      Then the list of sections has focus, on the current section

    @backlog @desktop @priority-low
    Scenario Outline: The find key focuses the settings search in every section
      Given the user is in the "<section>" settings
      When the user presses mod+f
      Then the settings search has focus

      Examples:
        | section     |
        | General     |
        | Providers   |
        | Keybindings |

    @desktop
    Scenario: Escape leaves settings when nothing else takes it
      Given the user opened settings from a thread
      And the search is empty
      When the user presses escape on the settings page
      Then the thread is shown again

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

    @desktop
    Scenario Outline: The page names where the user is
      When the user opens <page>
      Then the page is titled "Settings / <section>"

      Examples:
        | page                              | section               |
        | the Keybindings section           | Keybindings           |
        | the Appearance section            | Appearance            |
        | the Providers section             | Providers             |
        | the Cluster section               | Cluster               |
        | the Archive section               | Archive               |
        | diagnostics                       | Diagnostics           |
        | the open source licenses page     | Open source licenses  |

    @desktop
    Scenario: The project section appears only while editing a project
      Given the user is editing settings for all projects
      Then there is no project section
      When the user chooses the project "hal-c2"
      Then the project section is listed first

    @desktop
    Scenario: Device-only sections do not ask where settings apply
      When the user opens the Appearance section
      Then the page does not offer a choice of project or environment

    @desktop
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

  # Upstream #25651: the desktop's settings regrouped by concern, under headed groups.
  # Upstream #25686: the phone's settings follow the same groups.
  # HAL-C2's own sections (Cluster and the like) join the group of their concern.
  Rule: Settings are grouped by concern

    @backlog @desktop @mobile
    Scenario Outline: Each settings group holds the sections of one concern
      When the user opens settings
      Then the "<group>" group lists <sections>

      Examples:
        | group       | sections                                                   |
        | Agents      | Providers, Threads, Browser, Devices and Scheduled tasks    |
        | Code        | Projects, Source control and Worktrees                     |
        | Connections | Environments and Sharing & access                          |

    @backlog @desktop @mobile
    Scenario Outline: A setting is found in the section of its concern
      When the user looks for <setting>
      Then it is in the <section> section

      Examples:
        | setting                                         | section                |
        | where new worktrees go and worktree cleanup     | Worktrees              |
        | the composer's and the conversation's settings  | Chat                   |
        | diff and pull request settings                  | Diffs & pull requests  |
        | artifact and log cleanup                        | Maintenance            |
        | who may reach this machine                      | Sharing & access       |
        | the machines this client connects to            | Environments           |
        | features still in testing                       | Labs                   |

    @backlog @desktop @priority-low
    Scenario: Projects settings open to a project picker
      When the user opens the Projects section without a project chosen
      Then the user is asked to choose a project

    @backlog @desktop @mobile
    Scenario: A link to a section that moved opens where its setting went
      Given a link to the old Integrations, Storage or Beta section, or to a setting that moved
      When the user follows it
      Then the section that now holds it opens, at that setting

    @backlog @desktop @priority-low
    Scenario: Advanced settings sit in one fold at the end of a section
      When the user opens a section with advanced settings
      Then they are in one "Advanced" fold at the end of the section
      And a settings search for one of them opens the fold

  Rule: Searching settings

    @desktop
    Scenario: Search results show each setting with its section
      When the user searches settings for "word wrap"
      Then "Word wrap" is listed under "Appearance"

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

    # Upstream #20764: the highlight stays clamped when the results shrink and come back.
    @backlog @desktop @priority-low
    Scenario: The highlighted result stays within the results when they shrink
      Given the user has searched settings and highlighted the eighth of eight results
      When the results shrink to two
      Then the second result is highlighted
      When the results grow back to eight without the user moving the highlight
      Then the second result is still highlighted

    # The native runner drives the settings navigation beside its page (SettingsSearchSteps.cpp).
    @desktop
    Scenario: The slash key starts a settings search
      Given the keyboard is not in a text field
      When the user presses "/"
      Then the settings search has keyboard focus

    @desktop
    Scenario Outline: Results are ranked by how well the title matches
      When the user searches settings for "<query>"
      Then the first result is "<first>"

      Examples:
        | query  | first          |
        | model  | Default model  |
        | mod+b  | Sidebar: Toggle |

    @desktop
    Scenario: Every word of the search must match
      When the user searches settings for "composer vim"
      Then only "Vim keys in the composer" is listed

    @desktop
    Scenario Outline: Settings that do not apply here are not found
      Given <condition>
      When the user searches settings for "<query>"
      Then "<setting>" is not listed

      Examples:
        | condition                                  | query       | setting           |
        | the user is editing all projects           | project     | Project overview  |

      # There is no web client.
      @dropped
      Examples:
        | condition                                  | query       | setting           |
        | the user is in a web browser               | local env   | Local environment |

      # Waits on the WSL backend setting of settings/connections.feature.
      @backlog @blocked @priority-low
      Examples:
        | condition                                  | query       | setting           |
        | the machine is not running Windows         | wsl         | WSL backend       |

    # Legacy: apps/web/src/components/settings/settingsSearch.ts (filterAvailableSettingsSearchItems)
    @desktop
    Scenario Outline: Settings that depend on what this machine can do are only found when it can
      Given <condition>
      When the user searches settings for "<query>"
      Then "<setting>" is not listed

      Examples:
        | condition                                        | query              | setting                         |
        | no connected environment has provider settings   | usage providers    | Usage providers                 |
        | no connected environment has provider settings   | health check       | Provider health check interval  |

      # Waits on the desktop managing this machine's server: Network access, the environment
      # icon and Tailscale HTTPS in settings/connections.feature.
      @backlog @blocked @priority-low
      Examples:
        | condition                                        | query              | setting                |
        | the app cannot manage this machine's server      | network access     | Network access         |
        | the app cannot manage this machine's server      | environment icon   | Environment icon       |
        | the app cannot manage this machine's server      | tailscale          | Tailscale HTTPS        |

    @desktop
    Scenario: A search result inside a folded section opens the fold
      Given the "Load balancing" group on the Connections page is folded
      When the user opens the search result "Load balancing"
      Then the "Load balancing" group is open
      And the page brings the setting into view

    @desktop
    Scenario: Opening the same result again scrolls back to it
      Given the user opened the search result "Default model" and scrolled away
      When the user opens the search result "Default model" again
      Then the page brings the setting into view again

    @desktop
    Scenario Outline: A setting is found by the words people use for it
      When the user searches settings for "<query>"
      Then the first result is "<first>"

      Examples:
        | query              | first                  |
        | multiline          | Send shortcut          |
        | new line           | Send shortcut          |
        | long lines         | Word wrap              |
        | battery saver      | Background activity    |
        | binary path        | Providers              |
        | pull request template | Follow change request templates |

      # Upstream #17396: About's version and update track rows were not in settings search.
      # The update track is only found where the app has a release channel to change.
      @backlog
      Examples:
        | query              | first                  |
        | check for updates  | Version                |
        | nightly            | Update track           |

    @desktop
    Scenario: Search ignores case, extra spaces and accents
      When the user searches settings for "  WORD   WRAP  "
      Then "Word wrap" is the only result
      When the user searches settings for "thèmes" with an accent on the e
      Then "Theme" is the first result

    @desktop
    Scenario: Thread confirmations are listed in the order of the page
      When the user searches settings for "confirmation"
      Then the results are the unpin, archive and delete confirmations in that order

    @desktop
    Scenario Outline: Keyboard commands are found by name, id or default key
      When the user searches settings for "<query>"
      Then the first result is the "Sidebar: Toggle" keybinding

      Examples:
        | query          |
        | toggle sidebar |
        | sidebar.toggle |

    @desktop
    Scenario: Keyboard commands rank after other settings
      When the user searches settings for "model"
      Then "Default model" is the first result
      And the model picker keybinding is listed after "Text generation model"

    @desktop
    Scenario: A command with no default key opens the keybindings section
      When the user opens the search result for the "thread.stop" command
      Then the Keybindings section opens at that command's row

    @desktop
    Scenario: A setting that only appears when another is on opens at that toggle
      Given window capture is off
      When the user opens the search result "Capture sound"
      Then the window capture toggle is brought into view

    @desktop
    Scenario: A setting only some environments support is offered for those
      Given "laptop" can settle threads and "server" cannot
      When the user searches settings for "auto-settle"
      Then the results are found
      And choosing one offers "laptop" and not "server"

    @desktop
    Scenario Outline: A setting no chosen environment supports says what it needs
      Given the settings are scoped to "server", which cannot settle threads
      And <others>
      When the user opens the search result "Auto-settle merged threads"
      Then the page says "<notice>" in place of the settings

      Examples:
        | others                            | notice                                                                                                      |
        | "laptop" can settle threads       | Auto-settle merged threads requires a supporting environment. Choose one to continue.                       |
        | no environment can settle threads | Auto-settle merged threads requires a supporting environment. Connect or update an environment to continue. |

    @desktop
    Scenario: A setting on an environment that went offline is offered where it can be set
      Given "laptop" and "server" can settle threads
      And the user scopes the settings to "server"
      And "server" goes offline
      When the user opens the search result "Auto-settle merged threads"
      Then the page says "Auto-settle merged threads requires a supporting environment. Choose one to continue." in place of the settings
      And choosing one offers "laptop" and not "server"

    @desktop
    Scenario: A setting that belongs to another scope asks the user to choose that scope
      Given the settings are scoped to the project "shop"
      When the user opens the search result of a setting that is set per environment
      Then the page says that setting is not available for the selected target and to choose its owning scope
      And the user can choose the scope there to carry on to the setting

    @desktop
    Scenario: Environment settings are found without a primary environment
      Given no environment is the primary one
      When the user searches settings for "writing style"
      Then "Writing style" is the first result

    # Upstream #27376: the fallback model could not be found in settings search.
    @backlog @desktop
    Scenario Outline: The fallback model is found in settings search
      When the user searches settings for "<query>"
      Then "Fallback model" is a result

      Examples:
        | query          |
        | fallback       |
        | fallback agent |
        | fallback model |

    # Upstream #27376: choosing the other scope from the notice left the user on the notice.
    @backlog @desktop
    Scenario: The fallback model opens for all environments from a project's settings
      Given the settings are scoped to the project "shop"
      When the user opens the search result "Fallback model" and chooses all environments
      Then the page shows the fallback model setting, not the scope notice

  Rule: Restoring defaults

    # SettingsNav.qml asks and resets; the native runner drives its dialog (SettingsSearchSteps.cpp).
    @desktop
    Scenario: Restoring defaults lists what will change and asks first
      Given the user has changed the theme and the time format
      When the user restores default settings
      Then the user is asked to confirm a reset of the theme and the time format

    @desktop
    Scenario: Confirming the restore resets the listed settings
      Given the user is asked to confirm restoring default settings
      When the user confirms
      Then the theme and the time format are back to their defaults

    @desktop
    Scenario: Cancelling the restore changes nothing
      Given the user is asked to confirm restoring default settings
      When the user cancels
      Then every setting keeps its value

    @desktop
    Scenario: A theme that cannot be restored rolls back
      Given saving the theme on this device fails
      When the user confirms restoring default settings
      Then the theme settings keep their previous values
      And the user is told the theme settings could not be restored

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (useSettingsRestore), apps/web/src/routes/settings.tsx
    @desktop
    Scenario: Restoring defaults is unavailable while every setting is at its default
      Given every setting the restore covers is at its default
      When the user looks at the settings page
      Then restoring default settings cannot be chosen

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (useSettingsRestore, enableAgentBrowserAccess)
    @desktop
    Scenario: Restoring defaults gives agents browser access back and says so
      Given the user turned agent browser access off
      When the user restores default settings
      Then the confirmation lists agent browser access among the settings it will reset
      When the user confirms
      Then agents have browser access again
