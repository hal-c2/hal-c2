# Sources:
#   apps/web/src/components/settings/OpenSourceLicenses.tsx
#   docs/user/open-source-licenses.md
#   docs/internals/open-source-licenses.md
#   apps/web/src/components/settings/SettingsSidebarNav.tsx (licenses page keeps General active)

Feature: Open source licenses
  The user can read the license and attribution notice of every third-party package and asset
  HAL-C2 ships or installs on demand, without being connected to any environment.

  Rule: Finding the notices

    @backlog @desktop
    Scenario: The licenses page opens from General settings
      Given the user has opened the General settings
      When the user views the open source licenses
      Then the list of third-party notices is shown
      And "General" stays marked as the current section

    @backlog @mobile
    Scenario: The licenses page opens from About on mobile
      Given the user has opened settings on mobile
      When the user opens About HAL-C2 and then Open source licenses
      Then the list of third-party notices is shown

    @backlog @desktop @mobile
    Scenario: Each notice names its version, license and where it is used
      Given the user has opened the open source licenses
      Then each entry shows its version when known, its license identifier and the parts of HAL-C2 that use it

    @backlog @desktop @mobile
    Scenario: Opening an entry shows its full notice text
      Given the user has opened the open source licenses
      When the user opens the entry "react"
      Then the complete notice text for "react" is shown

    @backlog @desktop
    Scenario Outline: Searching narrows the notices
      Given the user has opened the open source licenses
      When the user searches the licenses for "<query>"
      Then only entries whose <field> matches "<query>" are listed
      And the page shows how many of the notices match

      Examples:
        | query    | field           |
        | effect   | package name    |
        | MIT      | license         |
        | mobile   | app component   |

    @backlog @desktop
    Scenario: A search with no match says so
      Given the user has opened the open source licenses
      When the user searches the licenses for "zzzz"
      Then the user is told no licenses match that search

    @backlog @desktop
    Scenario: Optional device tools are listed though they are not bundled
      Given the user has opened the open source licenses
      Then the device tools HAL-C2 installs on demand are listed

    @backlog @desktop
    Scenario: Notices load without an environment
      Given no environment is connected
      When the user opens the open source licenses
      Then the list of third-party notices is shown

    @backlog @desktop
    Scenario: Notices that fail to load can be retried
      Given the license list cannot be loaded
      When the user opens the open source licenses
      Then the user is told the open source notices are unavailable
      When the user tries again and the list loads
      Then the list of third-party notices is shown
