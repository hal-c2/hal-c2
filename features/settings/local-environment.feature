# Sources:
#   apps/web/src/components/settings/LocalEnvironmentSetting.tsx
#   apps/web/src/components/settings/useAvailableSettingsSearchItems.ts (localEnvironmentOnly)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (This machine)

Feature: Local environment
  The desktop app runs its own environment on this machine. The user can turn it off to use
  the app only as a client for other environments, and turn it back on.

  Background:
    Given the user is using the desktop app
    And the user has opened the Connections settings

  Rule: Turning the local environment off and on

    @backlog @desktop
    Scenario: Turning off the local environment explains the effect and asks first
      Given the local environment is on
      When the user turns off the local environment
      Then the user is told agents and terminals here will stop
      And the user is told other devices will no longer reach this machine
      And the user is asked to confirm restarting with it off

    @backlog @desktop
    Scenario: Confirming turns the local environment off after a restart
      Given the user is asked to confirm turning off the local environment
      When the user confirms
      Then the app restarts without its local environment
      And this machine is no longer listed as an environment

    @backlog @desktop
    Scenario: Turning the local environment back on
      Given the local environment is off
      When the user turns on the local environment and confirms
      Then the app restarts with its local environment
      And this machine is listed as an environment again

    @backlog @desktop
    Scenario: Cancelling leaves the local environment as it was
      Given the local environment is on
      When the user turns off the local environment and cancels
      Then the local environment stays on

    @backlog @desktop
    Scenario: A change that fails is reported
      Given the app cannot save the local environment choice
      When the user turns off the local environment and confirms
      Then the user is told the setting could not be changed
      And the local environment stays on

    @backlog @desktop
    Scenario: The switch shows the state the app launched with
      Given the app launched with the local environment on
      When the user opens the Connections settings
      Then the local environment is shown as on
