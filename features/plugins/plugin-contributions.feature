# Sources:
#   packages/contracts/src/plugin.ts (PluginContributions: pages, threadKinds, slots, settings)
#   apps/desktop-qt/src/native/McPluginController.cpp (MC plugins per environment, UI parts cached and loaded)
#   apps/desktop-qt/qml/HalC2/Bricks/PluginRegistry.qml, PluginSlot.qml, PluginContext.qml
#   apps/desktop-qt/qml/HalC2/Bricks/PluginPart.qml, PluginThreadPart.qml (a UI part, a plugin thread's look)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellTabs.qml (the top-level tabs), PluginPages.qml, PluginPage.qml
#   apps/desktop-qt/qml/HalC2/Bricks/SidebarThreadRow.qml, ThreadView.qml, Sidebar.qml (marks, headers, sidebar sections)
#   apps/desktop-qt/qml/HalC2/Bricks/PluginsSettings.qml, PluginSettings.qml
#   apps/desktop-qt/src/native/NavigationController.cpp (the route's tab), SidebarModel.cpp (unlisted plugin threads)
#   docs/user/plugins.md

Feature: What plugins add to the clients
  A running plugin's UI parts reach every client of its environment. A plugin can add a
  page that the user switches to with the shell's tabs, a section of the sidebar, a
  look for the threads it starts, a settings page, and content in the shell's named
  slots. The shell looks and works as before when no plugin adds anything.

  Background:
    Given an environment whose MC runs the plugin "code-review"

  Rule: Pages are tabs

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin page is a tab beside the threads
      Given "code-review" adds the page "Reviews"
      When the shell is shown
      Then the shell has the tabs "Threads" and "Reviews"
      And "Threads" is selected

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: There are no tabs while no plugin adds a page
      Given no running plugin adds a page
      When the shell is shown
      Then the shell shows the threads with no tabs

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Switching to a plugin tab shows its page and switching back keeps the thread
      Given the user is reading the thread "Refactor auth"
      When the user switches to the "Reviews" tab
      And then switches back to the "Threads" tab
      Then the thread "Refactor auth" is shown where the user left it

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin page keeps its state while another tab is shown
      Given the user filtered the "Reviews" page to failed reviews
      When the user switches to "Threads" and back to "Reviews"
      Then the "Reviews" page still shows only failed reviews

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Opening a thread from a plugin page switches to the threads
      Given the user is on the "Reviews" page
      When the user opens the thread of a review
      Then the "Threads" tab is selected with that thread open

    @desktop @backlog-mobile @backlog-tui @mobile @tui
    Scenario: A plugin page can be reached from the command palette
      When the user searches the command palette for "Reviews"
      Then opening the result switches to the "Reviews" tab

    @desktop @backlog-mobile @backlog-tui @mobile @tui
    Scenario Outline: The keyboard moves between the tabs
      Given the "<from>" tab is selected
      When the user presses the keybinding for <command>
      Then the "<to>" tab is selected

      Examples:
        | from    | command          | to      |
        | Threads | the next tab     | Reviews |
        | Reviews | the next tab     | Threads |
        | Reviews | the previous tab | Threads |

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Disabling the plugin removes its tab and returns to the threads
      Given the user is on the "Reviews" tab
      When the user disables "code-review"
      Then the "Reviews" tab is gone
      And the threads are shown

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The same plugin on two environments is one tab
      Given a second environment also runs "code-review"
      When the shell is shown
      Then there is one "Reviews" tab
      And the page can tell each environment's data apart

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The same plugin in two versions is a tab for each version
      Given a second environment runs another version of "code-review"
      When the shell is shown
      Then there is a "Reviews" tab for each environment, named after it
      And each tab's page runs on its own environment only

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A version's tab stays put when the other version goes away
      Given a second environment runs another version of "code-review"
      And the user is on the "Reviews" tab of the second environment
      When "code-review" stops on the first environment
      Then the user is still on the same page

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A version's tab follows its environment to the version it updates to
      Given a second environment runs another version of "code-review"
      And the user is on the "Reviews" tab of the second environment
      When the second environment updates "code-review"
      Then the user is on the "Reviews" tab of the version the second environment runs

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A page whose UI part fails to load shows the error in its tab
      Given the "Reviews" page of "code-review" fails to load
      When the user switches to the "Reviews" tab
      Then the tab shows that "code-review" failed with its message
      And the other tabs keep working

  Rule: A plugin's threads look like what they are

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin thread shows the plugin's mark in the thread list
      Given "code-review" started a listed "review" thread
      When the thread list is shown
      Then the thread's row shows the mark "code-review" gives "review" threads

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin thread shows the plugin's header above the conversation
      Given "code-review" started a "review" thread
      When the user opens that thread
      Then the plugin's header for "review" threads is shown above the conversation
      And the header is given the thread it is shown for

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A thread the plugin keeps out of the list is not in the thread list
      Given "code-review" started a "review" thread that is not listed
      When the thread list is shown
      Then the thread is not in it

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin thread looks like any other thread when the plugin is not running
      Given "code-review" started a listed "review" thread
      When "code-review" is disabled
      Then the thread is listed and opens as an ordinary thread

  Rule: A plugin's settings live with the other settings

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The plugin list shows what each MC plugin is
      When the user opens the plugin list
      Then "code-review" is listed under its environment with its description, version, author and screenshots

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario Outline: A plugin that did not load says why in the plugin list
      Given "code-review" is listed as <status> because "<reason>"
      When the user opens the plugin list
      Then the card of "code-review" says "<says>: <reason>"

      Examples:
        | status       | reason                         | says                 |
        | error        | plugin.json is not valid JSON. | Failed               |
        | incompatible | It needs a newer MC.           | Not made for this MC |

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings of a plugin that did not load say why
      Given "code-review" is listed as error because "plugin.json is not valid JSON."
      When the user opens the settings of "code-review"
      Then the settings say "Failed: plugin.json is not valid JSON."

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Enabling a plugin shows the permissions before it runs
      Given "code-review" is disabled
      When the user enables "code-review"
      Then the user is shown each permission it asks for with its reason
      And "code-review" runs only after the user accepts them

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Declining the permissions leaves the plugin disabled
      Given "code-review" is disabled
      When the user enables "code-review" and declines its permissions
      Then "code-review" stays disabled

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin without its own settings page gets one from its declared settings
      Given the plugin "ntfy" declares a server address and a secret token
      When the user opens the settings of "ntfy"
      Then the page shows a field for each declared setting
      And saving it stores the settings on the MC

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A setting whose JSON does not parse cannot be saved
      Given the plugin "ntfy" declares a setting that takes JSON
      When the user opens the settings of "ntfy"
      And the user changes that setting to JSON that does not parse
      Then the page says the setting is not valid JSON
      And it can be saved again once the JSON parses

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin's own settings page replaces the generated one
      Given "code-review" adds its own settings page
      When the user opens the settings of "code-review"
      Then the plugin's settings page is shown

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Settings the plugin refuses show its message
      When the user saves settings that "code-review" refuses
      Then the plugin's message is shown
      And the saved settings are unchanged

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A failed plugin can be restarted from its settings
      Given "code-review" is listed as failed with its last error
      When the user restarts "code-review"
      Then "code-review" runs again

  Rule: A plugin fills the shell's named places

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A plugin adds a section to the sidebar
      Given "code-review" contributes to "sidebar.sections"
      When the thread list is shown
      Then the plugin's section is shown below the threads

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The UI part of an MC plugin can call its MC part
      Given the "Reviews" page is shown
      When the page asks "code-review" for its reviews
      Then the answer comes from the MC that runs "code-review"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A UI part follows the state its MC part publishes
      Given the "Reviews" page watches the "reviews" topic
      When "code-review" publishes a new list of reviews
      Then the page shows the new list without reloading

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: UI parts that watch the same topic share it
      Given the "Reviews" page watches the "reviews" topic
      When another part of "code-review" watches the "reviews" topic
      Then the other part is given the last list at once
      And the MC sends the "reviews" topic to the client once

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: An updated plugin's UI parts replace the old ones
      Given the "Reviews" page is shown
      When the MC runs a new version of "code-review"
      Then the page is loaded again from the new version
