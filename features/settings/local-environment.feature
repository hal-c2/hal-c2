# Sources:
#   apps/web/src/components/settings/LocalEnvironmentSetting.tsx
#   apps/web/src/components/settings/useAvailableSettingsSearchItems.ts (localEnvironmentOnly)
#   apps/web/src/components/settings/ConnectionsSettings.tsx (This machine)
#   apps/desktop/src/ipc/methods/localEnvironment.ts, apps/desktop/src/app/DesktopLifecycle.ts (restart only on change, dev relaunch)

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

    # Legacy: apps/desktop/src/ipc/methods/localEnvironment.ts (restarts only when the setting changed)
    @backlog @desktop
    Scenario: Choosing what the local environment already is does not restart the app
      Given the local environment is on
      When the app is asked to turn on the local environment
      Then the app does not restart

    # Legacy: apps/desktop/src/app/DesktopLifecycle.ts (relaunch)
    @backlog @desktop
    Scenario: A development app leaves it to its runner to start it again
      Given the user runs the desktop app from a development checkout
      When the app restarts for a changed setting
      Then the app exits with a code that tells the dev runner to start it again

    @backlog @desktop
    Scenario: The switch shows the state the app launched with
      Given the app launched with the local environment on
      When the user opens the Connections settings
      Then the local environment is shown as on

    @backlog @desktop
    Scenario Outline: The local environment says what the choice means
      Given the local environment is <state>
      When the user opens the Connections settings
      Then the local environment row says "<description>"

      Examples:
        | state | description                                                                      |
        | on    | Run agents on this computer. Turn off to use HAL-C2 only with remote environments. |
        | off   | Turned off. Agents only run in remote environments.                              |

    @backlog @desktop
    Scenario Outline: The confirmation names what a restart does
      Given the local environment is <state>
      When the user changes the local environment
      Then the user is asked "<title>"
      And told "<effect>"
      And the button reads "<button>"

      Examples:
        | state | title                          | effect                                                                                                                                                                                                                     | button               |
        | on    | Turn off local environment?    | HAL-C2 will restart without running a server on this computer. Any agents and terminals running here will stop, and other devices will no longer be able to connect to this computer. Your projects, history, and remote environments are unaffected. | Restart and turn off |
        | off   | Turn on local environment?     | HAL-C2 will restart and start running a server on this computer again.                                                                                                                                                      | Restart and turn on  |

    @backlog @desktop
    Scenario: The restart cannot be interrupted
      Given the user confirmed changing the local environment
      When the app is restarting
      Then the button reads "Restarting…" and the switch, Cancel and the dialog cannot be used

    @backlog @desktop
    Scenario: A failed restart shows its reason and lets the user try again
      Given the app cannot restart to change the local environment
      When the user confirms
      Then the dialog shows the reason, or "Couldn't change this setting."
      And the user can confirm again or cancel
      And cancelling clears the message

    @backlog @desktop
    Scenario: The switch is not offered where the app has no way to restart itself
      Given the app has no way to restart itself without its local environment
      When the user opens the Connections settings
      Then no local environment switch is shown
