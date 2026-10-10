# Sources:
#   apps/web/src/components/settings/IntegrationsSettings.tsx
#   apps/web/src/components/settings/IntegrationsSettings.logic.test.ts
#   apps/web/src/components/device/DeviceToolVersions.tsx (version label and details)
#   apps/web/src/components/settings/IntegrationsSettings.test.tsx (browser files are not scanned on entering settings)
#   docs/user/devices.md (Settings → Integrations → Devices, device tool updates, auto-show floating preview)
#   apps/server-ex/lib/hal_c2/devices.ex (device.configure, device.list updateTool and inspectOnly)
#   apps/server/src/device/deviceToolMaintenance.ts (pruning old tool versions after an update)
#   apps/server/src/device/deviceToolMaintenance.test.ts, DeviceToolchain.test.ts (prune safety, the
#     maintenance lock, completion marks, failed installs)
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

    @backlog @desktop
    Scenario: The default viewport fills the panel until the user picks a size
      Given the default browser viewport is the built-in one
      Then new browser tabs fill the panel
      And no width or height is shown
      When the user chooses a standard device size
      Then its width and height are shown beside it

    @backlog @desktop
    Scenario: Choosing a responsive viewport keeps the current size
      Given the default browser viewport is the iPhone SE preset
      When the user chooses a responsive viewport
      Then new browser tabs open at the same width and height
      And they are no longer described as that device

    @backlog @desktop
    Scenario Outline: A typed viewport size is kept only when it is allowed
      Given the default browser viewport is 390 by 844
      When the user types <width> as the width and leaves the field
      Then the default viewport is <result>

      Examples:
        | width | result                                                                    |
        | 1024  | 1024 by 844, no longer described as a device                              |
        | 100   | still 390 by 844                                                          |
        | 5000  | still 390 by 844                                                          |

    @backlog @desktop
    Scenario: A viewport larger than a 4K screen is refused
      Given the default browser viewport is 390 by 2200
      When the user types 3840 as the width and leaves the field
      Then the default viewport is still 390 by 2200

    @backlog @desktop
    Scenario: A viewport size is saved when the field is left, not while typing
      When the user types "2560" into the viewport width one digit at a time
      Then the default is not saved as 256 on the way
      And it is saved once when the user leaves the field

    @backlog @desktop
    Scenario: Rotating the default viewport swaps its width and height
      Given the default browser viewport is the iPad preset in portrait
      When the user rotates it
      Then new browser tabs open in landscape
      And the viewport is still described as that device

    @backlog @desktop
    Scenario: Settings that are not at their default offer a reset
      Given the default viewport, zoom, appearance and frame rate are all at their defaults
      Then none of them offers a reset
      When the user changes the default zoom to 150%
      Then only the zoom offers a reset

    @backlog @desktop
    Scenario: The default zoom is one of the browser's zoom steps
      When the user opens the default browser zoom
      Then the user can choose between 25% and 500% in steps such as 33%, 67%, 90% and 110%
      And 100% is the built-in default

    @backlog @desktop
    Scenario: The default appearance follows the system until chosen
      Given the default browser appearance is the built-in one
      Then pages are told to prefer the system's colour scheme
      When the user chooses Light or Dark
      Then pages are told to prefer that scheme

    @backlog @desktop
    Scenario: Recording frame rate offers 30 and 60 frames a second
      When the user opens the default recording frame rate
      Then the user can choose 30 fps, which saves CPU and storage, or 60 fps, which is smoother
      And 30 fps is the built-in default

    @backlog @desktop
    Scenario: Holding a modifier key sends a link to the default browser
      Given links are set to open in HAL-C2
      When the user clicks a link while holding Cmd or Ctrl
      Then it opens in the default browser anyway

    @backlog @desktop
    Scenario: A new browser profile gets a name nobody else has
      Given profiles named "New profile" and "New profile 2" exist
      When the user creates a blank profile
      Then it is named "New profile 3"

    @backlog @desktop
    Scenario: Built-in browser profiles cannot be renamed or removed
      When the user looks at the built-in profiles
      Then their names are not editable
      And they offer no way to be removed
      But they can be made the default and have their cookies and cache cleared

    @backlog @desktop
    Scenario: Incognito is not a profile to manage
      When the user lists browser profiles
      Then incognito is not listed
      And the profiles description says incognito data is cleared when the app closes

    @backlog @desktop
    Scenario: A profile name is trimmed, shortened and never left empty
      Given a browser profile named "Work"
      When the user renames it to a name longer than 48 characters
      Then it is saved with the first 48 characters
      When the user renames it to only spaces
      Then it keeps its previous name

    @backlog @desktop
    Scenario: The default profile is marked and can be changed
      Given several browser profiles
      Then one of them is marked as the default
      When the user sets another as the default
      Then the mark moves to it
      And setting the profile that is already the default is not offered

    @backlog @desktop
    Scenario: Removing the default profile makes the built-in one the default
      Given the browser profile "Work" is the default
      When the user removes "Work" and confirms
      Then the built-in profile is the default
      And tabs already open in "Work" stay open until closed

    @backlog @desktop
    Scenario: Removing a profile says its logins are deleted
      When the user asks to remove the browser profile "Work"
      Then the user is asked "Remove “Work”?"
      And told that its cookies and logins are deleted
      And cancelling keeps the profile and its data

    @backlog @desktop
    Scenario: A profile whose data cannot be deleted stays
      Given the data of "Work" cannot be deleted
      When the user removes "Work" and confirms
      Then the user is told "Profile data could not be deleted. Try again."
      And "Work" is still listed with its data

    @backlog @desktop
    Scenario: Profile data cannot be cleared or removed with no environment connected
      Given no environment is connected
      When the user opens the options of a browser profile
      Then clearing its cookies and cache and removing it are not offered
      And the user is told to connect to an environment first
      And while environments are still being checked it says "Checking environments…"

    @backlog @desktop
    Scenario: Clearing a profile's data can fail
      Given clearing the cookies of "Work" fails
      When the user clears the data of "Work"
      Then the user is told "Could not clear Work's data"
      And "Work" is still listed

    @backlog @desktop
    Scenario: The profile limit is twenty-four
      Given the user has 24 browser profiles
      When the user opens the Add profile menu
      Then a blank profile cannot be created
      And the user is told they have reached the profile limit
      And importing into a new profile is not offered

    @backlog @desktop
    Scenario: The Add profile menu lists only browsers that can be imported from
      Given Chrome is installed, Firefox is not installed and Safari is not supported on this system
      When the user opens the Add profile menu
      Then Chrome is listed under "Import from"
      But Firefox and Safari are not
      And while the browsers are still being looked for it says "Looking for browsers…"
      And with none it says "No supported browsers found"

    @backlog @desktop
    Scenario: Importing needs a connected environment
      Given no environment is connected
      When the user opens the Add profile menu
      Then no browser can be chosen to import from
      And the user is told "Connect to an environment to import cookies"

    @backlog @desktop
    Scenario: Profiles cannot be changed while cookies are being imported
      Given an import into a browser profile is running
      Then adding, renaming, removing or setting a profile as default is not possible
      And a second import cannot start

    @backlog @desktop
    Scenario: A new profile that hits the limit during an import is not kept
      Given an import into a new profile is running
      And the profile limit is reached before it finishes
      When the import completes
      Then the imported cookies are cleared again
      And no new profile is added
      And the user is told the profile limit was reached

    # packages/contracts/src/browserImport.ts (profileNotSaved): the cookies were written, then the
    # new profile's partition is cleared so nothing is left orphaned.
    @backlog @desktop
    Scenario: A new profile that cannot be saved after an import is not kept
      Given an import into a new profile has brought cookies over
      And the new profile cannot be saved
      Then the imported cookies are cleared again
      And the user is told "The cookies were imported, but the new profile couldn't be saved. Try again."

    @backlog @desktop
    Scenario: An import into a new profile named after the browser stays unique
      Given a profile named "Chrome" exists
      When the user imports cookies from Chrome into a new profile
      Then the new profile is named "Chrome 2"

    @backlog @desktop
    Scenario: The browser's settings are not read until the user asks
      When the user opens the Integrations settings
      Then no other browser's files are scanned
      And they are looked for only when the Add profile menu is opened

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

    # Legacy: apps/server/src/device/DeviceService.test.ts (manual updates, failed installs, retry, inspect)
    # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (updateTool, inspectOnly, retryHostId)
    @backlog @mc
    Scenario: Updating one device tool starts nothing and changes no permission
      Given device support and agent device access are off
      When the user updates the agent device tool
      Then only the agent tool is installed
      And no helper is started and no device is listed
      And device support and agent device access stay off

    @backlog @mc
    Scenario: A failed device tool update changes nothing and can be tried again
      Given the agent device tool update fails once
      When the user updates the agent device tool
      Then the update fails
      And the device state is exactly as it was
      When the user updates it again
      Then the tool is installed

    @backlog @mc
    Scenario Outline: Retrying the device hub starts only what the user allowed
      Given <allowed>
      When the user retries the device hub
      Then <started>

      Examples:
        | allowed                                   | started                               |
        | device support is off                     | nothing starts                        |
        | device support is on, agent access is off | the hub starts and agent tools do not |
        | device support and agent access are on    | the hub and the agent tools start     |

    @backlog @mc
    Scenario: A failed version check keeps what was known
      Given the device hub is off and its tools are installed
      And the MC cannot read the installed tool versions
      When the user checks device tool versions on this MC
      Then the check reports that the versions could not be read
      And the device hub stays off
      And the installed tools are still listed as installed

    @backlog @mc
    Scenario: Updating a device tool removes old versions except the previous one and any still running
      Given older versions of the device hub tool are installed
      And one of the older versions is running a hub
      When the user updates the device hub tool
      Then the required version is installed
      And the previously installed version stays installed
      And the older version still running stays installed
      And the other older versions are removed

    # Legacy: apps/server/src/device/deviceToolMaintenance.test.ts (pruneTools)
    @backlog @mc
    Scenario: Old device tool versions stay until the required version has finished installing
      Given only an older version of the device hub tool is completely installed
      When the MC prunes old device tool versions
      Then the older version is not removed

    # Legacy: apps/server/src/device/deviceToolMaintenance.test.ts (process scan failure)
    @backlog @mc
    Scenario: Nothing is pruned when the MC cannot tell which versions are running
      Given older versions of the device hub tool are installed
      And the MC cannot list the machine's processes
      When the MC prunes old device tool versions
      Then every installed version stays

    # Legacy: apps/server/src/device/DeviceToolchain.test.ts, deviceToolMaintenance.test.ts
    # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (installed?, tool_version)
    @backlog @mc
    Scenario: A tool version that did not finish installing is not reported or removed
      Given a device tool folder for a version that never wrote its completion mark
      And a staging folder from an interrupted install
      When the user checks device tool versions on this MC
      Then neither is listed as installed
      And pruning leaves both alone

    # Legacy: apps/server/src/device/deviceToolMaintenance.test.ts (maintenance lock)
    @backlog @mc
    Scenario: Two MCs pruning one tool folder take turns
      Given two MC processes share a tool folder
      And a previous prune died holding the maintenance lock
      When both prune at the same time
      Then the dead holder's lock is reclaimed
      And the prunes never overlap
      And no lock is left behind

    # Legacy: apps/server/src/device/DeviceToolchain.test.ts (ensureDeviceHub)
    # Likely already implemented: apps/server-ex/lib/hal_c2/devices.ex (ensure_tool staging)
    @backlog @mc
    Scenario: A failed tool install names its step and leaves no half-installed tree
      Given the registry rejects the install with a message that contains an address with a password
      When the MC installs the device hub tool
      Then the error says the device hub install failed while running npm, with the exit code
      And the error does not repeat the registry's message
      And the staging folder is removed and the tool is not reported installed

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

    @backlog @desktop
    Scenario: Simulator support appears once the device hub is ready
      Given the device hub is off
      Then no iOS or Android status is shown
      When the user turns on the device hub and it finishes installing
      Then the iOS and Android status are shown
      And turning the device hub off hides them again

    @backlog @desktop
    Scenario: Simulator support can be checked again
      Given the device hub is on
      When the user refreshes simulator support
      Then the iOS and Android status are looked up again
      And refreshing is not possible while the hub is installing or starting

    @backlog @desktop
    Scenario: The device switches wait while the hub installs or starts
      Given the device hub is installing
      Then the device hub and agent device access switches cannot be changed
      And no tool update or version check can be started

    @backlog @desktop
    Scenario: A project cannot turn the device hub on or off
      Given the user is editing settings for project "api"
      Then the device hub switch cannot be changed
      But agent device access can be turned on or off for that project alone

    @backlog @desktop
    Scenario: Agent device access needs a device hub somewhere
      Given no connected environment has the device hub on
      When the user looks at agent device access
      Then it cannot be turned on

    @backlog @desktop
    Scenario: A device tool update names the version it installs
      Given the device hub tool is older than the required version
      Then the update offers "Update to v" followed by the required version
      And while it installs it says "Updating…"
      And nothing is offered when the installed versions already include the required one

    @backlog @desktop
    Scenario: A device tool check says it is checking
      Given the device hub supports inspecting its tools
      When the user checks versions
      Then the control says "Checking…" until the answer arrives
      And it is not offered for a host that cannot inspect its tools

    @backlog @desktop
    Scenario Outline: A device tool's version is shown beside its switch
      Given the device hub tool is <state>
      Then the version beside the switch reads "<label>"

      Examples:
        | state                                          | label           |
        | running version 1.4.0                          | v1.4.0          |
        | installed as 1.4.0 and required, not running   | v1.4.0          |
        | not installed                                  | Not installed   |
        | not yet reported by the host                   | Version unknown |

    @backlog @desktop
    Scenario: A device tool's version details list what runs, what is required and what is installed
      Given the device hub tool requires 1.4.0 and has 1.3.0 and 1.4.0 installed but not running
      When the user opens the tool's version details
      Then it lists "Not running" as the running version, "1.4.0" as required and "1.3.0, 1.4.0" as installed
      And it says tools update automatically on this host when needed

    @backlog @desktop
    Scenario: Version details before the first check say so
      Given the host has not reported its tool versions
      When the user opens the device tools' version details
      Then it says "Versions have not been checked."

    @backlog @desktop
    Scenario: A version check that fails shows its reason in the version details
      Given the last version check failed with "Host unreachable"
      Then the control reads "Versions unavailable"
      When the user opens the device tools' version details
      Then it says "Host unreachable"
