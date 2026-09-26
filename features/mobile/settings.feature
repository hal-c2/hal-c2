# Sources:
#   apps/mobile/src/features/settings/SettingsRouteScreen.tsx (HAL-C2 Account row, sections)
#   apps/mobile/src/features/settings/SettingsAuthRouteScreen.tsx (sign in, profile, sign out)
#   apps/mobile/src/Stack.tsx (SettingsWaitlist keeps the old waitlist link working)
#   apps/mobile/src/features/settings/SettingsEnvironmentsRouteScreen.tsx (Refresh cloud environments)
#   apps/mobile/src/features/settings/SettingsAppearanceRouteScreen.tsx
#   apps/mobile/src/features/settings/appearance/sections/ (theme, text, code and diffs, terminal)
#   apps/mobile/src/lib/appearancePreferences.ts (automatic sizes follow the text size; limits)
#   apps/mobile/src/lib/mobileTheme.ts (HAL-C2, Material You, built-in themes)
#   apps/mobile/src/features/settings/SettingsScheduledTasksRouteScreen.tsx
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
