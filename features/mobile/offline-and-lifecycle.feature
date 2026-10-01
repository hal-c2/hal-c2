# Sources:
#   apps/mobile/src/connection/app-state-wakeups.ts (probe vs reconnect after 10 seconds)
#   apps/mobile/src/connection/background-activity.ts
#   apps/mobile/src/connection/background-activity-scopes.ts
#   apps/mobile/src/features/connection/EnvironmentConnectionNotice.tsx (cached data notices)
#   apps/mobile/src/features/threads/floating-working-status.ts (tap to reconnect)
#   apps/mobile/src/features/settings/SettingsClientStorageRouteScreen.tsx
#   apps/mobile/src/state/client-cache-state.ts
#   apps/mobile/src/persistence/mobile-database.ts
#   apps/mobile/src/Stack.tsx (outbox drain worker)
# MC reconnection and replay are specified in features/connections/. This file covers
# what a phone does as the system suspends and resumes it, and what it keeps offline.

Feature: Staying useful through backgrounding and bad connections
  Phones suspend apps and lose the network often. The app keeps what it last saw, says
  plainly when it is stale, and catches up quickly when it can.

  Background:
    Given the phone is paired with "My MacBook"
    And the user has opened the thread "Fix checkout" before

  @backlog @mobile
  Scenario: Returning to the app after a moment checks the connection quickly
    Given the user switched away from the app for 5 seconds
    When the user returns to the app
    Then the phone checks the existing connection instead of reconnecting

  @backlog @mobile
  Scenario: Returning to the app after a longer break reconnects
    Given the user switched away from the app for a minute
    When the user returns to the app
    Then the phone reconnects to "My MacBook"
    And "Fix checkout" catches up on what happened while the app was away

  @backlog @mobile
  Scenario: Cached threads open without a connection
    Given "My MacBook" is unreachable
    When the user opens "Fix checkout"
    Then the last known conversation is shown
    And the user is told cached data remains available until the connection returns

  @backlog @mobile
  Scenario: A thread never opened before cannot be shown offline
    Given "My MacBook" is unreachable
    When the user opens a thread the phone has never loaded
    Then the user is told the thread will load when the connection returns

  @backlog @mobile
  Scenario: The app keeps retrying on its own
    Given "My MacBook" is unreachable
    Then the user is told the app will keep retrying automatically
    When "My MacBook" becomes reachable
    Then the thread list is current again without the user doing anything

  @backlog @mobile
  Scenario: A working agent's status offers to reconnect when the connection drops
    Given an agent is working in "Fix checkout"
    When the connection to "My MacBook" drops
    Then the working status shows the connection is lost
    When the user taps the working status
    Then the phone reconnects to "My MacBook"

  @backlog @mobile
  Scenario: Messages written offline are sent in order once the connection returns
    Given "My MacBook" is unreachable
    When the user sends "first" and then "second" in "Fix checkout"
    And "My MacBook" becomes reachable
    Then "first" is sent before "second"

  @backlog @mobile
  Scenario: A message the environment rejects after reconnecting is kept for the user
    Given the user sent "first" while offline
    And the environment rejects "first" when the connection returns
    Then "first" is shown as not sent
    And the user can edit or delete it

  @backlog @mobile
  Scenario: The user sees how much each environment stores on the phone
    When the user opens client storage settings
    Then the storage used by "My MacBook" is shown

  @backlog @mobile
  Scenario: Clearing one environment's cache keeps the connection
    When the user clears the cache for "My MacBook" and confirms
    Then offline threads for "My MacBook" are removed from the phone
    And the phone stays paired with "My MacBook"

  @backlog @mobile
  Scenario: Clearing all client caches asks first
    When the user asks to clear all client caches
    Then the user is asked to confirm
    When the user cancels
    Then nothing is cleared

  @backlog @mobile
  Scenario: The splash screen waits for the user's appearance settings
    Given the user chose a dark theme
    When the app starts
    Then the first screen the user sees already uses the dark theme

  @backlog @mobile
  Scenario: Drafts are saved before the system suspends the app
    Given the user has typed "add a test" in "Fix checkout"
    When the system suspends and later terminates the app
    And the user opens the app again
    Then the draft in "Fix checkout" still reads "add a test"
