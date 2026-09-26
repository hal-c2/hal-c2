# Sources:
#   apps/web/src/components/settings/BrowserImportWizard.tsx
#   apps/web/src/components/settings/browserImportWizard.logic.ts
#   apps/web/src/components/settings/browserImportWizard.logic.test.ts
#   apps/web/src/components/settings/IntegrationsSettings.tsx (Import from, browser profiles)

Feature: Importing cookies from another browser
  The user can bring cookies from an installed browser into a T3 Code browser profile, so agents
  and previews are signed in to the same sites.

  Background:
    Given the user is using the desktop app
    And the user has opened the browser profiles in Integrations settings

  Rule: Finding a browser to import from

    @backlog @desktop
    Scenario: Installed browsers are offered as import sources
      Given Chrome and Firefox are installed
      When the user chooses to import cookies
      Then Chrome and Firefox are offered

    @backlog @desktop
    Scenario: No supported browser is found
      Given no supported browser is installed
      When the user chooses to import cookies
      Then the user is told no supported browsers were found

    @backlog @desktop
    Scenario: A browser with no profiles cannot be imported from
      Given Chrome is installed without a profile
      When the user imports cookies from Chrome
      Then the user is told the browser profile is unknown and there is nothing to retry

  Rule: Importing

    @backlog @desktop
    Scenario: Importing into an existing profile
      When the user imports cookies from Chrome into the profile "Work"
      Then the user is told how many cookies were added to "Work"

    @backlog @desktop
    Scenario: Importing into a new profile
      When the user imports cookies from Chrome into a new profile
      Then a new browser profile is created for these cookies
      And the cookies are added to it

    @backlog @desktop
    Scenario: Skipped cookies name their sites briefly
      Given Chrome has cookies that cannot be imported for five sites
      When the import finishes
      Then the user is told the first three sites and "2 more" were skipped

    @backlog @desktop
    Scenario: An import with nothing to bring
      Given Chrome has no cookies
      When the import finishes
      Then the user is told no cookies were found

    @backlog @desktop
    Scenario: The wizard cannot be closed while importing
      Given an import is running
      When the user tries to close the wizard
      Then the wizard stays open until the import finishes

    @backlog @desktop
    Scenario: A chosen profile that disappears asks for another
      Given the profile "Work" is removed while the user is importing into it
      When the user imports
      Then the user is told the profile is no longer available and to choose where to import

  Rule: Recovering from what blocks an import

    @backlog @desktop
    Scenario: A running browser must be quit first
      Given Chrome is running
      When the user imports cookies from Chrome
      Then the user is asked to quit Chrome
      When the user says they have quit it
      Then the import continues

    @backlog @desktop
    Scenario: A browser reopened mid-import returns to the quit step
      Given the user quit Chrome and started an import
      When Chrome is reopened before the import finishes
      Then the user is asked to quit Chrome again

    @backlog @desktop
    Scenario: Full Disk Access is needed on macOS
      Given T3 Code does not have Full Disk Access
      When the user imports cookies from Safari
      Then the user is asked to allow Full Disk Access
      And is told to quit and reopen T3 Code if access does not update

    @backlog @desktop
    Scenario: System Settings cannot be opened for Full Disk Access
      Given System Settings cannot be opened
      When the user chooses to allow Full Disk Access
      Then the user is told to open Privacy and Security, Full Disk Access by hand

    @backlog @desktop
    Scenario Outline: Retry is offered only when it could help
      Given the import fails because <reason>
      Then retrying is <offered>

      Examples:
        | reason                                     | offered     |
        | the keychain prompt was declined           | offered     |
        | the browser's key is missing               | offered     |
        | the cookie store could not be read         | offered     |
        | the browser is not supported               | not offered |
