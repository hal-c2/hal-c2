# Sources:
#   apps/web/src/components/settings/OpenSourceLicenses.tsx
#   docs/user/open-source-licenses.md
#   docs/internals/open-source-licenses.md
#   apps/web/src/components/settings/SettingsSidebarNav.tsx (licenses page keeps General active)

Feature: Open source licenses
  The user can read the license and attribution notice of every third-party package and asset
  HAL-C2 ships or installs on demand, without being connected to any environment.

  Rule: Finding the notices

    @desktop
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

    @desktop @mobile @backlog-mobile
    Scenario: Each notice names its version, license and where it is used
      Given the user has opened the open source licenses
      Then each entry shows its version when known, its license identifier and the parts of HAL-C2 that use it

    @desktop @mobile @backlog-mobile
    Scenario: Opening an entry shows its full notice text
      Given the user has opened the open source licenses
      When the user opens the entry "react"
      Then the complete notice text for "react" is shown

    @desktop
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

    @desktop
    Scenario: A search with no match says so
      Given the user has opened the open source licenses
      When the user searches the licenses for "zzzz"
      Then the user is told no licenses match that search

    @desktop
    Scenario: Optional device tools are listed though they are not bundled
      Given the user has opened the open source licenses
      Then the device tools HAL-C2 installs on demand are listed

    @desktop
    Scenario: Notices load without an environment
      Given no environment is connected
      When the user opens the open source licenses
      Then the list of third-party notices is shown

    @desktop
    Scenario: Notices that fail to load can be retried
      Given the license list cannot be loaded
      When the user opens the open source licenses
      Then the user is told the open source notices are unavailable
      When the user tries again and the list loads
      Then the list of third-party notices is shown

  Rule: Reading the list

    @backlog @desktop
    Scenario: The list says it is loading
      Given the license list is still loading
      When the user opens the open source licenses
      Then the user is told the open source notices are loading
      And no count and no search are offered yet

    @backlog @desktop
    Scenario: The list says how many notices there are
      Given the user has opened the open source licenses
      Then the page says how many notices there are
      When the user searches the licenses for "mit"
      Then the page says how many of the total match, such as "3 of 120"

    @backlog @desktop
    Scenario: A failed load says why
      Given the license list request fails with status 404
      When the user opens the open source licenses
      Then the user is told the open source notices are unavailable
      And the reason names the failing status

    @backlog @desktop
    Scenario: Each notice links to the project's source
      Given an entry has a project source address
      When the user views the entry "react"
      Then it offers to open the project's source
      And an entry without an address offers nothing

    @backlog @desktop
    Scenario: Only one notice is open at a time
      Given the user opened the notice for "react"
      When the user opens the notice for "effect"
      Then the notice for "react" closes
      And the notice for "effect" shows its full text

    @backlog @desktop
    Scenario: Bundles are named in plain words
      Given an entry is used by the Qt desktop, the Qt mobile app and the device tools
      When the user views the entry
      Then it reads "Qt desktop, Qt mobile, Device tools"

    @backlog @desktop
    Scenario: Several search words must all match
      Given the user has opened the open source licenses
      When the user searches the licenses for "effect mit"
      Then only entries matching both "effect" and "mit" are listed

    @backlog @desktop
    Scenario: Search also matches versions
      Given the user has opened the open source licenses
      When the user searches the licenses for a version number such as "19.0"
      Then entries at that version are listed

    @backlog @desktop
    Scenario: Search closes when empty and Escape clears it
      Given the user opened the license search
      When the user leaves it with nothing typed
      Then it collapses back to the count
      When the user types a search and presses Escape
      Then the search is cleared and collapsed
