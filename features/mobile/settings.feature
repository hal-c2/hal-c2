# Sources:
#   apps/mobile/src/features/settings/SettingsRouteScreen.tsx (HAL-C2 Account row, sections)
#   apps/mobile/src/features/settings/SettingsAuthRouteScreen.tsx (sign in, profile, sign out)
#   apps/mobile/app.config.ts (Apple and Google sign-in configuration)
#   apps/mobile/src/Stack.tsx (SettingsWaitlist keeps the old waitlist link working)
#   apps/mobile/src/features/settings/SettingsEnvironmentsRouteScreen.tsx (Refresh cloud environments)
#   apps/mobile/src/features/settings/SettingsAppearanceRouteScreen.tsx
#   apps/mobile/src/features/settings/appearance/sections/ (theme, text, code and diffs, terminal)
#   apps/mobile/src/lib/appearancePreferences.ts (automatic sizes follow the text size; limits)
#   apps/mobile/src/lib/mobileTheme.ts (HAL-C2, Material You, built-in themes)
#   apps/mobile/src/features/settings/SettingsScheduledTasksRouteScreen.tsx
#   apps/mobile/src/features/settings/components/ScheduledTaskPromptField.tsx (dictating the prompt)
#   apps/mobile/src/features/settings/settings-environment-filter.tsx, settings-environment-filter.logic.ts,
#     components/SettingsEnvironmentFilterHeader.tsx (settings scope: environments and project)
#   apps/mobile/src/features/settings/SettingsRouteScreen.tsx (server settings rows, keyboard row)
#   apps/mobile/src/features/settings/SettingsServerControlsRouteScreen.tsx (server settings pages)
#   apps/mobile/src/features/settings/components/SettingsProjectOverridesSection.tsx
#   apps/mobile/src/features/settings/SettingsProviderAccountsRouteScreen.tsx
#   apps/mobile/src/features/settings/SettingsLegalRouteScreen.tsx, components/SettingsLegalDocumentRouteScreen.tsx,
#     lib/legal-document-url.ts (the license and security policy viewer)
#   apps/mobile/src/persistence/mobile-preferences.ts, mobile-secure-storage.ts (the phone's own settings, fallbacks)
#   apps/mobile/src/features/settings/SettingsThreadsRouteScreen.tsx (Legacy: Plan Mode)
# Settings shared with the desktop (thread behaviour, follow-ups, project grouping, project
# defaults, provider accounts, licenses) are specified in features/settings/ and
# features/providers/, tagged @mobile there. The Return key is in mobile/composer.feature.
# No phone client exists on HAL-C2, so everything here is @backlog.

Feature: Settings that belong to the phone
  Some settings only make sense on a phone: how the app looks on this device, the HAL-C2 account
  it is signed in with, and editing scheduled tasks with a touch keyboard.

  Background:
    Given the phone is paired with "My MacBook"

  Rule: HAL-C2 account

    @backlog @mobile
    Scenario: Settings says whether the phone is signed in to HAL-C2
      Given the user is signed in to HAL-C2 as "sam@example.com"
      When the user opens settings
      Then the HAL-C2 account shows "sam@example.com"

    @backlog @mobile
    Scenario: The user signs in to HAL-C2 from settings
      Given the user is signed out of HAL-C2
      When the user signs in to HAL-C2 from settings
      Then the HAL-C2 account shows the user's email

    @backlog @mobile
    Scenario Outline: The user signs in to HAL-C2 with <provider> from settings
      Given the user is signed out of HAL-C2
      When the user signs in to HAL-C2 with <provider> from settings
      Then the HAL-C2 account shows the user's email

      Examples:
        | provider |
        | Apple    |
        | Google   |

    @backlog @mobile
    Scenario: Sign in with Apple is not offered on a build that cannot use it
      Given the app was built without Apple sign-in
      And the user is signed out of HAL-C2
      When the user opens the HAL-C2 account
      Then the HAL-C2 account offers no Apple sign-in

    @backlog @mobile
    Scenario: Signing out returns the user to settings
      Given the user is looking at their HAL-C2 profile
      When the user signs out
      Then the user is back in settings
      And the HAL-C2 account offers to sign in

    @backlog @mobile
    Scenario: The old waitlist link opens HAL-C2 sign in
      When the user follows a link to the HAL-C2 waitlist
      Then the user is asked to sign in to HAL-C2

    @backlog @mobile
    Scenario: A build without HAL-C2 Connect offers no HAL-C2 account
      Given the app was built without HAL-C2 Connect
      When the user follows a link to the HAL-C2 account
      Then the user sees settings without a HAL-C2 account

    @backlog @mobile
    Scenario: The user refreshes environments from HAL-C2 Connect
      Given the user is signed in to HAL-C2 Connect
      When the user refreshes cloud environments
      Then environments added to the user's HAL-C2 Connect profile are listed

  Rule: Appearance

    @backlog @mobile
    Scenario Outline: The user chooses whether the app is light or dark
      When the user sets the appearance to "<mode>"
      Then the app is <result>

      Examples:
        | mode   | result                       |
        | System | light or dark with the phone |
        | Light  | always light                 |
        | Dark   | always dark                  |

    @backlog @mobile
    Scenario: A theme is chosen for both light and dark
      When the user chooses the theme "Ocean"
      Then "Ocean" is used in light and in dark

    @backlog @mobile
    Scenario: A theme is chosen for only light or only dark
      Given the theme is "HAL-C2"
      When the user chooses "Ocean" for dark only
      Then "Ocean" is used in dark
      And "HAL-C2" is still used in light

    @backlog @mobile
    Scenario: Material You is offered when the phone provides its own colours
      Given the phone provides system colours
      When the user chooses the theme "Material You"
      Then the app takes its colours from the phone

    @backlog @mobile
    Scenario: Material You is not offered when the phone has no system colours
      Given the phone provides no system colours
      Then the theme "Material You" is not offered

    @backlog @mobile
    Scenario: The text size changes the size of every message
      When the user sets the text size to 18 points
      Then messages are shown at 18 points

    @backlog @mobile
    Scenario Outline: Code and terminal sizes follow the text size until the user sets their own
      Given the <surface> has no size of its own
      When the user changes the text size
      Then the <surface> grows or shrinks with it
      When the user sets a size of its own for the <surface>
      Then the <surface> keeps that size when the text size changes
      When the user turns the size of its own off
      Then the <surface> follows the text size again

      Examples:
        | surface        |
        | code and diffs |
        | terminal       |

    @backlog @mobile
    Scenario Outline: Sizes stay within limits
      When the user sets the <setting> to <asked> points
      Then the <setting> is <kept> points

      Examples:
        | setting        | asked | kept |
        | text size      | 30    | 22   |
        | text size      | 6     | 11   |
        | code font size | 30    | 18   |
        | code font size | 4     | 8    |

    @backlog @mobile
    Scenario: Word break wraps long lines of code instead of scrolling them
      Given a diff with a line longer than the screen
      When the user turns word break on
      Then the long line wraps onto the next line
      When the user turns word break off
      Then the long line scrolls sideways

    @backlog @mobile
    Scenario: The appearance page previews a change before the user leaves it
      When the user changes the code font size
      Then the preview on the appearance page shows code at the new size

  Rule: Scheduled tasks on a phone

    @backlog @mobile
    Scenario: The phone lists each environment's scheduled tasks
      Given "My MacBook" has the scheduled task "Check for issues" every weekday at 9:00
      When the user opens scheduled tasks
      Then "Check for issues" is listed under "My MacBook" as "Weekdays at 9:00"

    @backlog @mobile
    Scenario Outline: A task's days are described in words
      Given a scheduled task runs on <days>
      Then the task says it runs <description>

      Examples:
        | days                         | description   |
        | every day of the week        | Every day     |
        | Monday to Friday             | Weekdays      |
        | Monday, Wednesday and Friday | Mon, Wed, Fri |

    @backlog @mobile
    Scenario: The user creates a scheduled task on the phone
      When the user creates a scheduled task "Check for issues" in "shop" every day at 9:00
      Then "Check for issues" is listed under "My MacBook"

    @backlog @mobile
    Scenario: A task missing what it needs is not saved
      When the user saves a new scheduled task without a prompt
      Then the task is not saved
      And the user is told to add a name, prompt, project, model, valid schedule and checkout path if needed

    @backlog @mobile
    Scenario: A task for a project the environment no longer has is not saved
      Given the user is editing a scheduled task for a project that was removed
      When the user saves the task
      Then the user is asked to choose a project in this environment

    @backlog @mobile
    Scenario: A task that fails to save says why
      Given "My MacBook" rejects the task
      When the user saves a new scheduled task
      Then the user is told the task could not be saved and why
      And the task is still open for editing

    @backlog @mobile
    Scenario: Leaving an edited task asks before discarding it
      Given the user changed a scheduled task without saving
      When the user leaves the task
      Then the user is asked whether to discard the changes
      When the user keeps editing
      Then the changes are still there

    @backlog @mobile
    Scenario: A task cannot be left while it is saving
      Given the user is saving a scheduled task
      When the user tries to leave the task
      Then the user is told to wait for the task to finish saving

    @backlog @mobile
    Scenario: Without a connected environment no task can be created
      Given no environment is connected
      When the user opens scheduled tasks
      Then the user is told to connect an environment to view and create scheduled tasks
      And creating a task is not offered

    @backlog @mobile
    Scenario: The user dictates the prompt of a scheduled task
      Given the phone can dictate
      When the user dictates the prompt of a new scheduled task
      Then the spoken words are added to the prompt
      And the user reviews the prompt before saving the task

    @backlog @mobile
    Scenario: A task cannot be saved while dictation is still finishing
      Given the user is dictating the prompt of a scheduled task
      Then saving the task is not offered until the dictation has finished or been cancelled

    @backlog @mobile
    Scenario: Leaving a task while dictating says the dictation will be lost
      Given the user is dictating the prompt of a scheduled task
      When the user tries to leave the task
      Then the user is asked whether to discard the dictation and the unsaved changes

    @backlog @mobile
    Scenario: A task's time of day is read in the environment's time zone
      When the user opens a scheduled task that runs at a time of day
      Then the user is told the time follows the environment's time zone
      And that it may differ from the phone's

  Rule: Settings scope on a phone

    The settings pages apply to the environments and the project chosen at the top of the
    settings pages. Until the user chooses, they apply to every connected environment.

    @backlog @mobile
    Scenario: Settings start with every connected environment
      Given "My MacBook" and "Office Mac" are connected
      When the user opens settings
      Then the settings scope reads "All environments"
      And the settings pages apply to "My MacBook" and "Office Mac"

    @backlog @mobile
    Scenario: The user narrows settings to some environments
      Given "My MacBook" and "Office Mac" are connected
      When the user chooses only "Office Mac" for the settings scope
      Then the settings pages apply to "Office Mac" only
      When the user also chooses "My MacBook"
      Then the settings scope reads "All environments" again

    @backlog @mobile
    Scenario: Only connected environments can be chosen for settings
      Given "Office Mac" is disconnected
      When the user opens the settings scope
      Then "Office Mac" is not offered
      And the settings pages apply to "My MacBook" only

    @backlog @mobile
    Scenario: The user narrows settings to one project
      Given "shop" has a checkout on "My MacBook"
      And the project "docs" only exists on "Office Mac"
      When the user chooses the project "shop" for the settings scope
      Then the settings scope reads "shop"
      And the project's overview is offered in settings
      And the settings pages apply to the checkout on "My MacBook"

    @backlog @mobile
    Scenario: Only projects of the chosen environments are offered
      Given the project "docs" only exists on "Office Mac"
      When the user chooses only "My MacBook" for the settings scope
      Then the project "docs" is not offered

    @backlog @mobile
    Scenario: A chosen project that is no longer available says so
      Given the user chose the project "docs" for the settings scope
      When "Office Mac" disconnects
      Then the settings scope reads "Unavailable project"
      And the project's pages ask the user to select a project with a checkout on a connected environment

    @backlog @mobile
    Scenario Outline: Server settings need a connected environment
      Given no environment is connected
      When the user opens settings
      Then "<page>" is listed but cannot be opened

      Examples:
        | page              |
        | Provider accounts |
        | New threads       |
        | Source control    |
        | Agent behavior    |
        | Maintenance       |

    @backlog @mobile
    Scenario: A server settings page with nothing chosen asks for an environment
      Given the user chose no environment that is connected
      When the user opens the new thread settings
      Then the user is told to use the scope to select a connected environment

    @backlog @mobile
    Scenario Outline: The keyboard settings are offered on iPhone only
      Given the user is on <phone>
      When the user opens settings
      Then keyboard settings are <offered>

      Examples:
        | phone      | offered     |
        | an iPhone  | offered     |
        | an Android | not offered |

  Rule: Server settings on a phone

    @backlog @mobile
    Scenario: A setting changed with several environments chosen applies to each of them
      Given "My MacBook" and "Office Mac" are connected
      And the settings scope is "All environments"
      When the user turns on automatically pulling the default branch
      Then "My MacBook" and "Office Mac" both pull the default branch automatically

    @backlog @mobile
    Scenario: Settings changes are applied one at a time
      Given the user has just changed a server setting
      And the environments have not answered yet
      Then the other choices on the page cannot be used until they have

    @backlog @mobile
    Scenario: Restart continuation cannot be changed on an environment that cannot do it
      Given the settings scope includes an MC that cannot continue threads after a restart
      When the user opens maintenance settings
      Then continuing after a restart cannot be turned on
      And the user is told to update the older MC to control it

    @backlog @mobile
    Scenario: Project settings on an environment that cannot keep overrides are read only
      Given the user chose the project "shop"
      And the MC of "My MacBook" cannot keep project overrides
      When the user opens a server settings page
      Then no setting can be changed
      And the user is told to update the selected environments to edit project overrides

    @backlog @mobile
    Scenario: An environment-wide setting cannot be changed from a project
      Given the user chose the project "shop"
      When the user opens maintenance settings
      Then checking for provider updates is shown but cannot be changed
      And the user is told it is environment-wide and to select all projects to change it

  Rule: Provider accounts on a phone

    @backlog @mobile
    Scenario: Provider accounts lists each chosen environment's providers that can sign in
      Given "My MacBook" has providers that can sign in from the app
      When the user opens provider accounts
      Then each of those providers is listed under "My MacBook"
      And each says whether it is signed in

    @backlog @mobile
    Scenario: An environment without a provider that can sign in says how to set one up
      Given "My MacBook" has no provider that can sign in from the app
      When the user opens provider accounts
      Then "My MacBook" says a provider with in-app sign-in has to be configured from the desktop settings

    @backlog @mobile
    Scenario: Provider accounts asks for an environment when none is chosen
      Given the user chose no environment that is connected
      When the user opens provider accounts
      Then the user is told to select a connected environment

    @backlog @mobile
    Scenario: A signed-in account's email stays hidden until asked
      Given "Claude" is signed in on "My MacBook" as "ada@example.com"
      When the user opens provider accounts
      Then the account's email is hidden
      When the user reveals the account's email
      Then "ada@example.com" is shown
      When the user hides the account's email
      Then the account's email is hidden again

    @backlog @mobile
    Scenario: A provider with several sign-in methods asks which one to use
      Given "Codex" offers two ways to sign in
      When the user signs in to "Codex"
      Then the user is asked which way to sign in
      When the user chooses one
      Then that sign-in starts

    @backlog @mobile
    Scenario: A provider with one sign-in method starts it at once
      Given "Codex" offers one way to sign in
      When the user signs in to "Codex"
      Then that sign-in starts without asking

    @backlog @mobile
    Scenario: A sign-in page that needs consent asks before opening
      Given "Codex" is waiting for the user to sign in on a page that needs consent
      When the user opens the sign-in page
      Then the consent is given to "Codex" first
      And the sign-in page opens in the phone's browser

    @backlog @mobile
    Scenario: A sign-in that shows a code says where to enter it
      Given "Codex" is waiting for the user to enter a device code
      Then the code is shown with the page to enter it on

    @backlog @mobile
    Scenario: A sign-in finished on a page that does not load is completed from its address
      Given "Codex" is waiting for the address the browser ends on
      Then continuing is not offered until an address is pasted
      When the user pastes the final address and continues
      Then "Codex" finishes the sign-in

    @backlog @mobile
    Scenario: A provider that asks questions in a terminal is answered in the app
      Given "Codex" is asking for a response in its login terminal
      When the user sends a response
      Then the response reaches the login terminal
      And the response field is cleared

    @backlog @mobile
    Scenario: A provider that asks for credentials takes them in the app
      Given "Codex" is asking for an API key
      When the user connects with the key
      Then "Codex" is signed in
      And the key is not shown again

    @backlog @mobile
    Scenario: A sign-in in progress can be cancelled
      Given the user started signing in to "Codex"
      When the user cancels the sign-in
      Then "Codex" is not signed in
      And the user can sign in again

    @backlog @mobile
    Scenario: A sign-in that fails says why in place
      Given "Codex" fails to sign in
      Then the reason is shown under "Codex"

    @backlog @mobile
    Scenario: Signing out says what it will stop
      Given "Claude" is signed in on "My MacBook"
      When the user signs out of "Claude"
      Then the user is told running threads sharing the sign-in on "My MacBook" will stop and their history is kept
      When the user declines
      Then "Claude" is still signed in

    @backlog @mobile
    Scenario: A provider that is turned off or not installed cannot start a sign-in
      Given "Codex" is turned off on "My MacBook"
      When the user opens provider accounts
      Then signing in to "Codex" is shown but cannot be used

    @backlog @mobile
    Scenario: A provider with no in-app sign-in points to its documentation
      Given "Gemini" does not offer a sign-in the app can drive
      When the user opens provider accounts
      Then "Gemini" says to follow the provider's documentation
      And the provider's documentation can be opened

  Rule: Legal documents on a phone

    @backlog @mobile
    Scenario: Legal opens the license inside the app
      When the user opens Legal from About
      Then the project's license is shown in the app
      And the user can close it

    @backlog @mobile
    Scenario: A legal page that cannot load says why and can be retried
      Given the legal page cannot be loaded
      When the user opens Legal from About
      Then the user is told the legal document could not be loaded and why
      When the user tries again
      Then the legal page is loaded again
      And the user can open it in the browser instead

    @backlog @mobile
    Scenario: Links out of a legal page open in the browser
      Given the user is reading the license
      When the user follows a link to another site
      Then the link opens in the phone's browser
      And the license stays open in the app

    @backlog @mobile
    Scenario: The legal page can be opened in the browser from its header
      Given the user is reading the security policy
      When the user chooses to open the document in the browser
      Then that document opens in the phone's browser

  Rule: Settings kept on the phone

    # Likely already implemented: apps/mobile/src/persistence/mobile-preferences.ts
    @backlog @mobile
    Scenario: The phone's own settings are kept when the app restarts
      Given the user chose a dark theme, a larger text size and thread grouping by project
      When the app is closed and opened again
      Then the dark theme, the larger text size and the grouping are still chosen

    @backlog @mobile
    Scenario: Settings that cannot be read fall back to their defaults
      Given the phone's saved settings are damaged
      When the app starts
      Then the app uses its default settings
      And the user can choose settings again

    @backlog @mobile
    Scenario: A saved setting the app does not recognise is ignored
      Given the phone's saved settings hold a theme the app does not know
      When the app starts
      Then the default theme is used
      And the user's other settings are kept

    @backlog @mobile
    Scenario: Settings are kept when the phone's database is unavailable
      Given the phone's database cannot be opened
      When the user changes a setting
      Then the setting is kept on the phone
      And it is still chosen the next time the app starts

    @backlog @mobile
    Scenario: Two settings changed together are both kept
      When the user changes two settings in quick succession
      Then both settings are kept

    @backlog @mobile
    Scenario: Plan Mode is off until the user asks for it
      Given the user has not turned on Plan Mode under Legacy
      When the user starts a task
      Then the task runs in Build mode
      And no Build and Plan choice is offered

    @backlog @mobile
    Scenario: Turning on Plan Mode brings back the Build and Plan choice
      When the user turns on Plan Mode under Legacy
      Then the Build and Plan choice is offered when starting a task
