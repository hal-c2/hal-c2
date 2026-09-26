# Sources:
#   /home/olafura/dev/opentui-qml src/runtime/plugins.ts (Slot replace and append, fallback content)
#   apps/mobile/src/features/settings (screens a plugin may replace or extend)
#   apps/mobile/src/features/threads/ThreadSettingsSheet.tsx
#   apps/server-ex/lib/hal_c2/environment.ex (per-environment identity)

Feature: Customising the mobile app
  The mobile app is QML too, so the user can load UI plugins onto it the same way as
  on the other surfaces: from a file on the phone, from a paired node, or from a
  pasted URL. Plugins can replace or extend screens, are checked before they load,
  are remembered per environment, and survive app updates. The stock app is always
  one step away.

  Background:
    Given the mobile app is paired with the environment "workstation"

  @backlog @mobile
  Scenario: A plugin file on the phone can be loaded
    Given the phone has the plugin file "compact-threads.qml"
    When the user loads it from the phone's files
    Then "compact-threads" is loaded and listed with the phone as its source

  @backlog @mobile
  Scenario: A plugin offered by a paired node can be loaded
    Given "workstation" offers the plugin "team-status"
    When the user picks "team-status" from the plugins "workstation" offers
    Then "team-status" is loaded and listed with "workstation" as its source

  @backlog @mobile
  Scenario: A plugin can be loaded from a pasted URL
    When the user pastes a plugin URL and confirms
    Then the plugin is downloaded, checked and loaded

  @backlog @mobile
  Scenario: A plugin that cannot be downloaded is reported
    When the user pastes a plugin URL that cannot be reached
    Then the user is told the plugin could not be downloaded
    And the app is unchanged

  @backlog @mobile
  Scenario: A plugin can replace a whole screen
    Given the plugin "compact-threads" replaces the thread list screen
    When the user opens the thread list
    Then the plugin's thread list is shown instead of the stock one

  @backlog @mobile
  Scenario: A plugin can add to a screen without replacing it
    Given the plugin "quota-card" adds a card to the home screen
    When the user opens the home screen
    Then the stock home screen is shown with the quota card added

  @backlog @mobile
  Scenario: Two plugins that extend the same screen are shown in order
    Given the plugins "quota-card" and "weather-card" both add to the home screen
    When the user opens the home screen
    Then both cards are shown in plugin order

  @backlog @mobile
  Scenario: Only one plugin can replace a given screen at a time
    Given "compact-threads" replaces the thread list screen
    When the user loads another plugin that also replaces the thread list screen
    Then the user is told which plugin currently replaces that screen
    And the user chooses which one to keep

  @backlog @mobile
  Scenario: Resetting to default removes every customisation
    Given several plugins customise the app
    When the user resets the app to its default layout
    Then every screen is the stock screen
    And the plugins are kept but disabled

  @backlog @mobile
  Scenario: A single screen can be reset without touching the others
    Given "compact-threads" replaces the thread list and "quota-card" extends the home screen
    When the user resets only the thread list
    Then the thread list is the stock one
    And the home screen still shows the quota card

  @backlog @mobile
  Scenario: Customisations are remembered per environment
    Given the app is also paired with "laptop"
    And "compact-threads" is enabled for "workstation" only
    When the user switches to "laptop"
    Then the stock thread list is shown
    When the user switches back to "workstation"
    Then the plugin's thread list is shown again

  @backlog @mobile
  Scenario: A plugin is validated before it loads
    Given a plugin file that uses a component the mobile app does not have
    When the user tries to load it
    Then the load is refused with a message naming the missing component
    And the app is unchanged

  @backlog @mobile
  Scenario: A plugin that fails while running falls back to the stock screen
    Given "compact-threads" replaces the thread list
    When "compact-threads" fails while drawing
    Then the stock thread list is shown
    And the user is told that "compact-threads" failed

  @backlog @mobile
  Scenario: The app can start with plugins turned off
    Given a plugin makes the app unusable
    When the user starts the app in safe mode
    Then every plugin is skipped for that start
    And the user can remove the plugin

  @backlog @mobile
  Scenario: Customisations survive an app update
    Given "compact-threads" is enabled
    When the app is updated from the store
    Then "compact-threads" is still enabled after the update

  @backlog @mobile
  Scenario: A plugin that no longer fits the updated app is disabled with a reason
    Given "compact-threads" replaces a screen the new app version no longer has
    When the app is updated from the store
    Then "compact-threads" is disabled
    And the user is told it needs an update

  @backlog @mobile
  Scenario: Disabling a plugin restores the screen it changed
    Given "compact-threads" replaces the thread list
    When the user disables "compact-threads"
    Then the stock thread list is shown

  @backlog @mobile
  Scenario: Removing a plugin deletes it from the phone
    Given "compact-threads" was loaded from a pasted URL
    When the user removes it
    Then it is no longer listed
    And loading it again needs the URL again

  @backlog @mobile @shared
  Scenario: A plugin made for the desktop app works on the phone when it uses shared components
    Given the plugin file "quota.qml" uses only shared components
    When the user loads it on the phone
    Then it shows in the same slot as on the desktop app
