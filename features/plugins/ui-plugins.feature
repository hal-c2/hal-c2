# Sources:
#   /home/olafura/dev/opentui-qml src/plugins (Plugin, Contribution, Slot, registerPlugin, unregisterPlugin, listPlugins, loadQmlPlugin, loadPluginsFromDir)
#   /home/olafura/dev/opentui-qml src/cli.ts (--plugins, --plugin, --context, exit codes)
#   /home/olafura/dev/opentui-qml test/plugins.test.ts
#   apps/desktop-qt/examples/dashboard/shell.qml (plugin slots example)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml, SidebarThreadRow.qml (plugin mentions)
#   apps/tui/src/commands.ts (command palette entries)
#   docs/user/plugins.md
#   apps/desktop-qt/src/native/PluginController.cpp (plugin files, disable and enable, URL installs)
#   apps/desktop-qt/qml/HalC2/Bricks/PluginRegistry.qml, PluginSlot.qml, PluginsSettings.qml
#   apps/desktop-qt/tests/native/features/PluginSteps.cpp

Feature: UI plugins
  Every surface is built from QML documents that expose named slots. A plugin is a
  QML file whose contributions fill those slots. The shell works with no plugins at
  all, and one plugin failing never takes the others or the shell down.

  Background:
    Given a client whose shell exposes the slots "sidebar.footer", "composer.actions" and "statusbar"

  @tui
  Scenario: A slot with no contributions shows its built-in content
    Given no plugin contributes to "statusbar"
    When the shell renders
    Then "statusbar" shows its built-in content

  @tui
  Scenario: A replacing slot shows the plugin instead of the built-in content
    Given "statusbar" replaces its built-in content when a plugin contributes
    And the plugin "clock" contributes to "statusbar"
    When the shell renders
    Then "statusbar" shows the clock
    And the built-in status content is hidden

  @tui
  Scenario: The built-in content comes back when the replacing plugin goes away
    Given the plugin "clock" replaces the "statusbar" content
    When the user removes "clock"
    Then "statusbar" shows its built-in content again

  @tui
  Scenario: An appending slot shows built-in content followed by every plugin
    Given "composer.actions" appends contributions
    And the plugins "snippets" and "translate" contribute to "composer.actions"
    When the shell renders
    Then "composer.actions" shows the built-in actions first
    And then "snippets" and "translate"

  @tui
  Scenario: A single-winner slot shows only the first plugin by order
    Given "sidebar.footer" shows a single winner
    And the plugin "quota" with order 10 and the plugin "weather" with order 20 contribute to it
    When the shell renders
    Then "sidebar.footer" shows only "quota"

  @tui
  Scenario Outline: Contributions are ordered by plugin order, then by load order
    Given "composer.actions" appends contributions
    And the plugin "<first>" loads before "<second>"
    And "<first>" has order <firstOrder> and "<second>" has order <secondOrder>
    When the shell renders
    Then "<winner>" appears before the other plugin

    Examples:
      | first | second | firstOrder | secondOrder | winner |
      | a     | b      | 0          | 0           | a      |
      | a     | b      | 20         | 10          | b      |
      | a     | b      | 5          | 50          | a      |

  @tui
  Scenario: Changing a plugin's order re-sorts the slot live
    Given "quota" and "weather" contribute to the appending slot "statusbar"
    And "quota" is shown first
    When "weather" changes its order to come first
    Then "weather" is shown first without reloading the shell

  @tui
  Scenario: A contribution follows the slot when the slot is renamed
    Given the plugin "clock" contributes to "statusbar"
    When the shell renames that slot to "footer"
    Then "clock" no longer shows in the renamed slot
    And "clock" shows again when a slot named "statusbar" exists

  @tui
  Scenario: A contribution sees the slot's data and updates in place
    Given "statusbar" publishes the current thread title
    And the plugin "title-echo" shows the slot's data
    When the current thread title changes to "Refactor auth"
    Then "title-echo" shows "Refactor auth"
    And the contribution is updated rather than recreated

  @tui
  Scenario: A contribution can reach its plugin, the slot, the shell context and the engine
    Given the plugin "inspector" contributes to "statusbar"
    When the contribution renders
    Then it can read its own plugin id, the slot name, the context values and the engine

  @tui
  Scenario: Two contributions from one plugin to the same slot keep only the first
    Given the plugin "dup" contributes to "statusbar" twice
    When the plugin loads
    Then the user is warned that "dup" contributes to "statusbar" more than once
    And only the first contribution is shown

  @tui
  Scenario: A contribution that is not visual is reported and skipped
    Given the plugin "broken-visual" contributes something that cannot be drawn to "statusbar"
    When the plugin loads
    Then a plugin error names "broken-visual" and "statusbar"
    And "statusbar" shows its built-in content

  @tui
  Scenario: The plugin id falls back to the file name
    Given a plugin file "weather.qml" that does not declare an id
    When the plugin loads
    Then it is listed as "weather"

  @tui
  Scenario: Plugins load from a directory in file name order
    Given the plugin directory contains "b-weather.qml", "a-quota.qml" and a helper component
    When the client starts with that plugin directory
    Then "a-quota" loads before "b-weather"
    And the helper component is not treated as a plugin

  @tui
  Scenario: A single plugin file loads alongside a directory
    Given the plugin directory contains "quota.qml"
    When the client starts with that directory and the extra plugin file "clock.qml"
    Then both "quota" and "clock" are loaded

  @tui
  Scenario: A missing plugin directory only warns
    When the client starts with a plugin directory that does not exist
    Then the user is warned that the directory is missing
    And the shell starts with its built-in content

  @tui
  Scenario: A file whose root is not a plugin is rejected
    When the user loads a QML file whose root is not a plugin
    Then the load is rejected with a message saying the file is not a plugin
    And no other plugin is affected

  @tui
  Scenario: A plugin file that does not parse is reported and the rest still load
    Given the plugin directory contains "good.qml" and a "bad.qml" with a syntax error
    When the client starts with that directory
    Then "good" is loaded
    And a load error names "bad.qml"

  @tui
  Scenario: Two plugins with the same id are refused
    Given the plugin "clock" is loaded
    When another plugin with the id "clock" loads
    Then the second one is rejected as a duplicate
    And the first "clock" keeps working

  @tui
  Scenario: A plugin whose setup fails stays unregistered while the others work
    Given the plugin "flaky" throws while setting up
    And the plugin "clock" loads normally
    When the shell renders
    Then "flaky" is not registered
    And a plugin error names "flaky" and the setup phase
    And "clock" is shown

  @tui
  Scenario: A contribution that fails while rendering does not break the slot's neighbours
    Given "composer.actions" appends contributions from "snippets" and "crashy"
    When "crashy" fails while rendering
    Then a plugin error names "crashy", "composer.actions" and the render phase
    And "snippets" and the built-in actions are still shown

  @tui
  Scenario: Removing a plugin runs its cleanup and removes its contributions
    Given the plugin "clock" is loaded and contributes to "statusbar"
    When the user removes "clock"
    Then "clock" runs its cleanup
    And "clock" no longer appears in the installed plugin list

  @tui
  Scenario: Context values given at start are available to every plugin
    When the client starts with the context value "theme" set to "dark" and "limit" set to 5
    Then every plugin reads "theme" as the text "dark"
    And every plugin reads "limit" as the number 5

  @tui
  Scenario: The installed plugins can be listed with their kind and file
    Given the QML plugin "clock" from "clock.qml" and a script plugin "metrics" are loaded
    When the user lists the loaded plugins
    Then the list shows "clock" as a QML plugin with its file
    And the list shows "metrics" as a script plugin

  @tui
  Scenario: Plugins are ready before the first frame is drawn
    Given the plugin "clock" contributes to "statusbar"
    When the client starts
    Then the first frame already shows the clock

  @desktop
  Scenario: The desktop shell exposes the same slots as the TUI where the surfaces match
    Given the plugin "quota" contributes to "sidebar.footer"
    When the same plugin file is loaded on the desktop app
    Then the desktop sidebar footer shows "quota"

  @shared @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: The same plugin file works on every surface
    Given the plugin file "quota.qml" uses only shared components
    When it is loaded on the desktop app, the mobile app and the TUI
    Then each surface shows "quota" in its sidebar footer

  @shared @desktop @mobile @tui @backlog-mobile
  Scenario: A slot a surface does not have is skipped quietly
    Given the plugin "hover-card" contributes only to "thread.hovercard"
    When it is loaded on a surface without that slot
    Then the plugin is listed as loaded with no visible contributions
    And no error is reported

  @backlog @desktop @mobile @tui
  Scenario: A plugin can be loaded from a paired MC
    Given the paired environment "workstation" offers the plugin "team-status"
    When the user loads "team-status" from "workstation"
    Then "team-status" is loaded and listed with "workstation" as its source

  @desktop @mobile @tui @backlog-mobile
  Scenario: A plugin can be loaded from a pasted URL
    When the user pastes the URL of a plugin file and confirms loading it
    Then the plugin is downloaded, checked and loaded
    And the plugin is listed with that URL as its source

  @desktop @mobile @tui @backlog-mobile
  Scenario: A plugin URL that cannot be reached is reported
    When the user pastes a plugin URL that cannot be reached
    Then the user is told the plugin could not be downloaded
    And nothing is loaded

  @desktop @mobile @tui @backlog-mobile
  Scenario: Disabling a plugin keeps it installed but hides its contributions
    Given the plugin "clock" is loaded
    When the user disables "clock"
    Then "statusbar" shows its built-in content
    And "clock" stays in the installed list as disabled

  @desktop @mobile @tui @backlog-mobile
  Scenario: Re-enabling a plugin restores its contributions
    Given the plugin "clock" is disabled
    When the user enables "clock"
    Then "statusbar" shows the clock again

  @desktop @mobile @tui @backlog-mobile
  Scenario: A disabled plugin stays disabled after a restart
    Given the user disabled "clock"
    When the client restarts
    Then "clock" is still disabled

  @desktop @tui
  Scenario: Editing a plugin file in dev reloads it without restarting
    Given the client runs in dev mode with the plugin "clock" loaded from a file
    When the developer saves a change to that file
    Then "clock" is replaced by the new version
    And the rest of the shell keeps its state

  @desktop @tui
  Scenario: A hot reload that breaks the plugin keeps the last working version
    Given the client runs in dev mode with the plugin "clock" loaded from a file
    When the developer saves a version that fails to load
    Then a plugin error names "clock"
    And the previous version of "clock" keeps running

  @desktop @mobile @tui @backlog-mobile
  Scenario: Plugin errors are visible to the user
    Given the plugin "flaky" failed to load
    When the user opens the plugin list
    Then "flaky" is shown with its error message
