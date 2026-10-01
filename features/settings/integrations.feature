# Sources:
#   apps/web/src/components/settings/IntegrationsSettings.tsx
#   apps/web/src/components/settings/IntegrationsSettings.logic.test.ts
#   docs/user/devices.md (Settings → Integrations → Devices, device tool updates, auto-show floating preview)
#   apps/server-ex/lib/hal_c2/devices.ex (device.configure, device.list updateTool and inspectOnly)
#   apps/server-ex/lib/hal_c2/rpc.ex (device.configure, device.list)
#   Ownership: this file is the only settings file for "Open links in", browser profiles and
#   auto-show floating preview (browser-import.feature covers importing cookies into a profile).
#   Terminal font and theme belong to the Appearance page in navigation/appearance.feature
#   (Fonts and text) and terminal/links-and-graphics.feature; no settings/ file repeats them.

Feature: Integrations settings
  The Integrations page holds the built-in browser's defaults for this device and the device
  hub that lets the user and agents use simulators and emulators on an environment.

  Background:
    Given the user has opened the Integrations settings

  Rule: Browser defaults belong to this device
    # The Qt desktop embeds no browser (previews open in the user's own), so
    # these wait for one there.

    @backlog @desktop
    Scenario Outline: A browser default applies to new browser tabs
      When the user sets the default <setting> to <value>
      Then new browser tabs open with <setting> <value>
      When the user resets the <setting>
      Then new browser tabs use the built-in <setting>

      Examples:
        | setting    | value           |
        | viewport   | 390 by 844      |
        | zoom       | 125%            |
        | appearance | Dark            |

    @backlog @desktop
    Scenario Outline: Recording defaults apply to new recordings
      When the user sets <setting>
      Then new browser recordings <effect>

      Examples:
        | setting                              | effect                                       |
        | the frame rate to 30 fps             | record at most 30 frames per second          |
        | key presses to be shown              | show pressed keys except in password fields  |
        | mouse presses to be shown            | highlight mouse presses and held buttons     |

    @backlog @desktop
    Scenario: Links can open in HAL-C2 or in the default browser
      When the user chooses to open links in HAL-C2
      Then links in the chat and terminal open in HAL-C2's browser
      When the user chooses the default browser
      Then links open in the default browser

    @backlog @desktop
    Scenario: The floating preview can stay hidden when an agent opens a browser
      When the user turns off auto-show floating preview
      Then an agent opening a browser does not show the floating preview

    @backlog @desktop
    Scenario: Browser defaults are unavailable in a web browser
      Given the user is using HAL-C2 in a web browser
      Then the browser defaults cannot be changed
      And the user is told they are only available in the desktop app

    @backlog @desktop
    Scenario: Creating, renaming and removing a browser profile
      When the user creates a browser profile named "Work"
      Then "Work" is listed as a browser profile
      When the user renames "Work" to "Client"
      Then "Client" is listed instead of "Work"
      When the user removes "Client" and confirms
      Then "Client" is no longer listed

    @backlog @desktop
    Scenario: Clearing a profile's data keeps the profile
      Given the browser profile "Work" has cookies
      When the user clears the data of "Work"
      Then the user is told the cookies and cache of "Work" were cleared
      And "Work" is still listed

    @backlog @desktop
    Scenario: The profile limit stops new profiles
      Given the user has reached the browser profile limit
      When the user tries to create a browser profile
      Then the user is told the browser profile limit is reached

  Rule: The device hub

    @mc
    Scenario: Turning on the device hub stores it and lists devices
      When the user turns on the device hub for this MC
      Then device support is stored as on
      And the MC lists the simulators and emulators on its machine

    @mc
    Scenario: Turning off the device hub stores it with agent device access off
      Given the device hub and agent device access are on
      When a client turns off the device hub and agent device access together
      Then device support is stored as off
      And agent device access is stored as off

    @mc
    Scenario: Checking device tool versions installs nothing
      When the user checks device tool versions on this MC
      Then the installed and required versions are reported
      And no tool is installed and no device is started

    @mc
    Scenario: Updating a device tool installs its required version
      Given the device hub tool is older than the required version
      When the user updates the device hub tool
      Then the required version is installed

    @mc
    Scenario: A device tool update without network access fails
      # An update only reaches the network when the installed tool is behind the pinned version.
      Given the device hub tool is older than the required version
      And this MC has no network access
      When the user updates the device hub tool
      Then the update fails with a device tool error

    @desktop
    Scenario: Turning off the device hub also turns off agent device access
      Given the device hub is on
      And agent device access is on
      When the user turns off the device hub
      Then the device hub is stored as off
      And agent device access is stored as off

    # What agents may then do is the MC's: connections/device-hub.feature
    # (Agent device access needs every prerequisite).
    @desktop
    Scenario: Agent device access can be granted and taken away
      Given the device hub is on
      When the user turns on agent device access
      Then agent device access is stored as on and shown as on
      When the user turns off agent device access
      Then agent device access is stored as off and shown as off

    @desktop
    Scenario: Device settings change on every selected environment
      Given the user is editing settings across all environments
      And saving on "Build box" fails
      When the user turns on the device hub
      Then the user is told device settings were not saved on all environments and could not update "Build box"

    @desktop
    Scenario: Leaving the page during a device tool check keeps the switches usable
      Given the device tools are still being checked
      When the user leaves the Integrations settings and comes back
      Then the device hub can be changed again

    @desktop
    Scenario: A failed tool update explains what to check
      Given the device hub tool update fails
      When the user updates the device hub tool
      Then the user is told to check this host's network connection and try again

    @desktop
    Scenario: Several environments show one environment's device status at a time
      Given the user is editing settings across "Laptop" and "Build box"
      When the user looks at simulator support
      Then the iOS and Android status of "Laptop" is shown
      And the user is told to select an environment to inspect its simulator support
