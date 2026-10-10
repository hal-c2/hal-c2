# Sources:
#   apps/web/src/components/settings/BrowserImportWizard.tsx
#   apps/web/src/components/settings/browserImportWizard.logic.ts
#   apps/web/src/components/settings/browserImportWizard.logic.test.ts
#   apps/web/src/components/settings/IntegrationsSettings.tsx (Import from, browser profiles)
#   apps/desktop/src/preview/BrowserImport (browser and profile discovery, running detection, cookie reading and writing)

Feature: Importing cookies from another browser
  The user can bring cookies from an installed browser into a HAL-C2 browser profile, so agents
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

    @backlog @desktop
    Scenario Outline: Which browsers can be imported from depends on the computer
      Given the user is on <system>
      When the user chooses to import cookies
      Then the browsers that cannot be imported from are <unavailable>

      Examples:
        | system  | unavailable                                         |
        | macOS   | none                                                |
        | Linux   | Arc and Safari                                      |
        | Windows | Chrome, Edge, Brave, Vivaldi, Opera, Arc and Safari |

    @backlog @desktop
    Scenario: A browser that left an empty folder behind is not offered
      Given Edge left its data folder on this computer but has no cookie file
      And Chrome has cookies
      When the user chooses to import cookies
      Then Chrome is offered
      And Edge is shown as not installed

    @backlog @desktop
    Scenario: Profiles are found even when the browser's profile list is missing
      Given Chrome's list of profiles is missing but its folder "Profile 1" holds cookies
      When the user chooses to import cookies from Chrome
      Then "Profile 1" is offered as a profile

    @backlog @desktop
    Scenario: Firefox profiles that were never opened are not offered
      Given Firefox lists the profiles "default" and "spare"
      And "spare" was never opened and holds no cookies
      When the user chooses to import cookies from Firefox
      Then only "default" is offered

    @backlog @desktop
    Scenario: Firefox installed as a snap is offered with the regular install
      Given Firefox is installed both normally and as a snap
      When the user chooses to import cookies from Firefox
      Then the profiles of both installs are offered

    @backlog @desktop
    Scenario: Safari's own profiles are offered with its default one
      Given Safari has the profile "Work" besides its default one
      And a deleted Safari profile still has its data on disk
      When the user chooses to import cookies from Safari
      Then the default profile and "Work" are offered
      And the deleted profile is not

    @backlog @desktop
    Scenario: A profile the browser never listed is refused
      Given a request names a profile that Chrome does not list
      When the import is attempted
      Then the user is told that browser profile no longer exists
      And no file outside Chrome's own folder is read

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

    @backlog @desktop
    Scenario: A cookie for one host does not reach its subdomains
      Given the browser holds a cookie scoped to "example.com" alone
      When the cookies are imported
      Then the cookie is sent to "example.com" only, not to "app.example.com"

    @backlog @desktop
    Scenario: A cookie for a whole domain stays a domain cookie
      Given the browser holds a cookie scoped to ".example.com"
      When the cookies are imported
      Then the cookie is sent to "example.com" and its subdomains

    @backlog @desktop
    Scenario: Cookies keep their security settings and lifetime
      Given the browser holds a secure, HTTP-only cookie that expires next month
      And it holds a cookie that ends with the browser session
      When the cookies are imported
      Then the first cookie is still secure and HTTP-only and expires next month
      And the second ends with the session

    @backlog @desktop
    Scenario: A cookie that made no SameSite choice is left to the browser's default
      Given the browser holds a cookie that declared no SameSite setting
      When the cookies are imported
      Then the imported cookie declares none either

    @backlog @desktop
    Scenario: Safari cookies are imported as Lax
      Given Safari holds cookies
      When the cookies are imported
      Then every imported cookie is Lax

    @backlog @desktop
    Scenario: Firefox containers and private windows are left out
      Given Firefox holds cookies from a container and from a private window
      When the cookies are imported
      Then only the cookies of the default container are imported
      And the others are not counted as skipped

    @backlog @desktop
    Scenario: Cookies kept per top-level site are skipped
      Given Chrome holds cookies partitioned by the site that embeds them
      When the cookies are imported
      Then those cookies are skipped and counted
      And their sites are named among the skipped ones

    @backlog @desktop
    Scenario: A cookie the profile refuses costs only itself
      Given the profile refuses one of the cookies being imported
      When the cookies are imported
      Then the other cookies are imported
      And the refused one is counted as skipped with its site named

    @backlog @desktop
    Scenario: Cookies are saved before the import is reported done
      When an import finishes with at least one cookie imported
      Then the cookies are written to the profile's storage before the user is told "Imported"

    @backlog @desktop
    Scenario: Importing never changes the source browser
      Given Chrome is installed
      When the user imports cookies from Chrome
      Then Chrome's own cookie file is read from a copy
      And nothing in Chrome's folder is written to

    @backlog @desktop
    Scenario: Cookies that do not need the keyring still import without one
      Given Chrome on Linux holds cookies that need the system keyring and cookies that do not
      And the keyring is not running
      When the user imports cookies from Chrome
      Then the cookies that do not need it are imported
      And the others are skipped and counted

    @backlog @desktop
    Scenario: A keyring that is not running fails an import that needs it
      Given every cookie in Chrome on Linux needs the system keyring
      And the keyring is not running
      When the user imports cookies from Chrome
      Then the user is told the system keyring could not be accessed

    @backlog @desktop
    Scenario: A cookie file that does not add up is refused whole
      Given Safari's cookie file is damaged or its contents do not match its header
      When the user imports cookies from Safari
      Then the user is told the browser's cookie database could not be read
      And no cookie is imported

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
      Given HAL-C2 does not have Full Disk Access
      When the user imports cookies from Safari
      Then the user is asked to allow Full Disk Access
      And is told to quit and reopen HAL-C2 if access does not update

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

    @backlog @desktop
    Scenario: A browser that crashed is not treated as running
      Given Chrome crashed and left its lock behind
      When the user imports cookies from Chrome
      Then the user is not asked to quit Chrome

    @backlog @desktop
    Scenario: A lock that cannot be checked counts as a running browser
      Given Chrome's lock names a browser on another computer sharing the same home folder
      When the user imports cookies from Chrome
      Then the user is asked to quit Chrome

    @backlog @desktop
    Scenario: Safari does not have to be quit
      Given Safari is running
      When the user imports cookies from Safari
      Then the user is not asked to quit Safari

    @backlog @desktop
    Scenario: The keychain prompt is never cut short
      Given the user is importing from Chrome on macOS
      When the keychain prompt stays open for a long time before the user approves it
      Then the import continues once it is approved

  Rule: Choosing what to import

    @backlog @desktop
    Scenario: A browser's profiles are listed with their cookie counts
      Given Chrome has the profiles "Personal" with 5,065 cookies, "Work" with 1 cookie and "Old" with none
      When the user chooses to import cookies from Chrome
      Then the profiles are listed as "5,065 cookies", "1 cookie" and "no cookies"
      And a profile whose cookie store cannot be read shows no count
      And the first profile is chosen

    @backlog @desktop
    Scenario: The destination starts as a new profile
      Given the user can still create browser profiles
      When the user chooses to import cookies
      Then "New profile, created for these cookies" is the chosen destination
      And the user's existing profiles are listed as other destinations

    @backlog @desktop
    Scenario: With no room for another profile the first existing one is chosen
      Given the user has reached the browser profile limit
      When the user chooses to import cookies
      Then a new profile is not offered as a destination
      And the first existing profile is chosen

    @backlog @desktop
    Scenario: A new profile that stopped being possible is explained
      Given the user chose to import into a new profile
      And the profile limit is reached before the user imports
      When the import step is shown
      Then the user is told "You've reached the profile limit. Choose an existing profile to import into."
      And importing is not available until an existing profile is chosen

    @backlog @desktop
    Scenario: The wizard says which environment the cookies are for
      Given the user is connected to the environment "workstation"
      When the user chooses to import cookies from Chrome
      Then the wizard says the cookies are imported for "workstation"
      And the result names "workstation" as well

    @backlog @desktop
    Scenario: Cancelling leaves everything as it was
      When the user cancels while choosing what to import, quitting the browser or allowing access
      Then the wizard closes
      And no cookie and no profile was added

    @backlog @desktop
    Scenario: Choosing a source profile survives quitting the browser
      Given Chrome has the profiles "Personal" and "Work"
      And the user chose "Work" and was asked to quit Chrome
      When the user says they have quit it
      Then "Work" is still the chosen profile
      And when Chrome no longer lists "Work" the first profile is chosen instead

    @backlog @desktop
    Scenario: The wizard says what it is checking while it waits
      When the user says they have quit the browser
      Then the wizard says it is checking whether the browser has closed
      When the user continues after allowing Full Disk Access
      Then it says it is checking Full Disk Access

  Rule: What the result says

    @backlog @desktop
    Scenario Outline: The result counts cookies in plain words
      Given an import brought <imported> cookies and skipped <skipped>
      When the import finishes
      Then the user is told "<title>"
      And "<detail>"

      Examples:
        | imported | skipped | title                  | detail                                             |
        | 1        | 0       | Imported 1 cookie      | Added to Work for workstation.                     |
        | 5065     | 0       | Imported 5,065 cookies | Added to Work for workstation.                     |
        | 40       | 2       | Imported 40 cookies    | Added to Work for workstation. 2 cookies skipped.  |
        | 0        | 3       | Skipped 3 cookies      | No cookies were imported for workstation.          |
        | 0        | 0       | No cookies found       | There were no cookies to import for workstation.   |

    @backlog @desktop
    Scenario Outline: Skipped sites are named briefly
      Given the cookies from <sites> were skipped
      When the import finishes
      Then the user is told the skipped sites are "<shown>"

      Examples:
        | sites                                        | shown                                |
        | example.com                                  | example.com                          |
        | example.com and google.com                   | example.com and google.com           |
        | a.com, b.com and c.com                       | a.com, b.com and c.com               |
        | a.com, b.com, c.com, d.com, e.com and f.com  | a.com, b.com, c.com and 3 more       |

  Rule: Failures say what happened

    @backlog @desktop
    Scenario Outline: A failed import explains itself
      Given the import cannot continue because <reason>
      Then the user is told "<message>"

      Examples:
        | reason                                           | message                                                                             |
        | the browser is not installed                     | Not installed on this machine.                                                      |
        | the keychain prompt was not approved             | Needs Keychain access to read its cookies.                                          |
        | the browser's key is not in the keychain         | No encryption key in your Keychain — sign in to that browser once, then retry.      |
        | the system keyring is locked or not running      | The system keyring could not be accessed. Make sure your desktop keyring is running and unlocked, then retry. |
        | the platform cannot import from that browser     | Importing from this browser isn't possible on this platform.                        |
        | the browser was removed meanwhile                | That browser is no longer available to import from.                                 |
        | its profile was removed meanwhile                | That browser profile no longer exists.                                              |
        | the destination profile cannot be opened         | The target profile could not be opened.                                             |
        | the cookie store cannot be read                  | The browser's cookie database could not be read.                                    |
        | the new profile could not be saved               | The cookies were imported, but the new profile couldn't be saved. Try again.        |
        | the profile limit was reached                    | You've reached the profile limit. Delete a profile or import into an existing one.  |

    @backlog @desktop
    Scenario: A browser that is not importable opens on its reason, not on a form
      Given Chrome cannot be imported from on this platform
      When the user chooses to import cookies from Chrome
      Then the wizard opens on the reason Chrome cannot be imported from
      And there is nothing to retry

    @backlog @desktop
    Scenario: A failure while re-listing the browser after the user acted is reported
      Given the user quit the browser or allowed Full Disk Access
      When HAL-C2 cannot list the browser again
      Then the user is told "The browser's cookie database could not be read."
      And can try again

    @backlog @desktop
    Scenario: A failure that returns the user to Full Disk Access says it is still required
      Given the user allowed Full Disk Access but the import still cannot read the browser
      When the import fails
      Then the user is told "Access is still required. Quit and reopen HAL-C2 if you just allowed it, then retry the import."

    @backlog @desktop
    Scenario: A keychain retry lands in the same new profile
      Given an import into a new profile failed on the keychain prompt
      When the user retries and approves the prompt
      Then the cookies go into one new profile, not a second one
