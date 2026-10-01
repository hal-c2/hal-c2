# Sources:
#   apps/web/src/components/settings/scopedSettings.ts (planScopedSettingsPatch)
#   apps/web/src/components/settings/settingsScope.ts
#   apps/web/src/components/settings/settingsScopeAxis.ts
#   apps/web/src/components/settings/settingsScopeNavigation.ts
#   apps/web/src/components/settings/SettingsScopeContext.tsx
#   apps/web/src/components/settings/SettingsScopeSentence.tsx
#   apps/web/src/components/settings/SettingsScopeNotice.tsx
#   apps/web/src/components/settings/SettingInheritance.tsx
#   apps/web/src/components/settings/ScopedSwitch.tsx
#   apps/web/src/components/settings/useScopedSettings.ts
#   apps/web/src/components/settings/useScopedModelAvailability.ts
#   apps/web/src/components/settings/useSettingsProjectGroups.ts
#   packages/contracts/src/settings.ts (ServerSettings, ProjectSettingsOverrides, ServerSettingsPatch)
#   apps/server-ex/lib/hal_c2/settings.ex (versioned put, project resolution, watchers)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.readSettings, hal-c2.writeSettings)
#   apps/server-ex/lib/hal_c2/web/socket.ex (config.settings)

Feature: Settings scopes and inheritance
  Settings apply to all environments, one environment, one project, or one checkout of a
  project. A narrower scope overrides a wider one, and the user can see where each value
  comes from and clear an override to inherit again.

  Background:
    Given the user has environments "Laptop" and "Build box"
    And the project "hal-c2" has a checkout on each environment

  Rule: The MC stores one versioned settings document

    @mc
    Scenario: A write at the version the client read is saved
      Given a client has read the settings at their current version
      When the client writes a changed settings document at that version
      Then the MC saves the document
      And the MC answers with the next version

    @mc
    Scenario: A stale write is refused instead of overwriting another editor
      Given two clients have read the settings at the same version
      And the first client has saved a change
      When the second client writes its change at the old version
      Then the MC refuses the write as stale settings
      And the first client's change is kept

    @mc
    Scenario: Connected clients receive every saved change
      Given a client is subscribed to this MC's settings
      When another client saves a settings change
      Then the subscribed client receives the new settings document

    @mc
    Scenario: A project sees its overrides over the environment's values
      Given the environment's default runtime mode is full access
      And the project "hal-c2" overrides the default runtime mode to approval required
      When the MC resolves the settings for "hal-c2"
      Then the default runtime mode is approval required
      And settings the project does not override keep the environment's values

    @mc
    Scenario: A project cannot override an environment-wide setting
      Given the project "hal-c2" has an override for an environment-wide setting
      When the MC resolves the settings for "hal-c2"
      Then that setting keeps the environment's value

    @mc
    Scenario: A project model override on a disabled provider falls back to the environment's
      Given the project "hal-c2" overrides the default model with a model from "Codex"
      And the "Codex" provider is disabled on this environment
      When the MC resolves the settings for "hal-c2"
      Then the default model is the environment's default model

  Rule: The user chooses where settings apply

    @backlog @desktop
    Scenario: The page states the project and environment being edited
      When the user opens settings
      Then the page says it is applying settings for all projects across all environments

    @desktop
    Scenario Outline: Changing one axis of the scope keeps the other
      Given the user is editing settings for "hal-c2" on "Laptop"
      When the user chooses <choice>
      Then settings apply to <result>

      Examples:
        | choice                        | result                                |
        | the environment "Build box"   | "hal-c2" on "Build box"               |
        | all environments              | "hal-c2" across all checkouts         |
        | all projects                  | every project on "Laptop"             |

    @desktop
    Scenario: Offline environments are marked when choosing one
      Given "Build box" is offline
      When the user chooses which environment settings apply to
      Then "Build box" is listed as offline

    @backlog @desktop
    Scenario Outline: A scope that no longer exists explains why and saves nothing
      Given the user opened a settings link for <target>
      When the settings page loads
      Then the page says "<message>"
      And no change the user makes is saved anywhere

      Examples:
        | target                               | message                                                                        |
        | a checkout without a project         | Select a project to choose one of its checkouts.                               |
        | an environment that was removed      | This environment is no longer available.                                       |
        | a project that was removed           | This project is no longer available.                                           |
        | a checkout that was removed          | This checkout is no longer available in the selected project and environment. |

    @backlog @desktop
    Scenario: A section with nothing to change at this scope offers where to go instead
      Given the user is editing settings for the project "hal-c2"
      When the user opens a section that only has environment-wide settings
      Then the page offers each environment the section can be changed on

  Rule: Writes go to every environment in the scope

    @desktop
    Scenario: An environment-wide change is saved on every connected environment
      Given the user is editing settings across all environments
      When the user changes an environment-wide setting
      Then the change is saved on "Laptop" and on "Build box"

    @backlog @desktop
    Scenario: A project change is saved as an override for that project
      Given the user is editing settings for the project "hal-c2"
      When the user changes the default model
      Then "hal-c2" overrides the default model on each environment with a checkout of it
      And other projects keep the environment's default model

    @backlog @desktop
    Scenario: A device preference is saved on this device only
      Given the user is editing settings for the project "hal-c2"
      When the user changes a preference that belongs to this device
      Then the preference is saved on this device
      And no environment is changed

    @desktop
    Scenario: Saving on some environments but not others is reported
      Given the user is editing settings across all environments
      And saving on "Build box" fails
      When the user changes a setting
      Then the user is told the setting saved on some environments and could not update "Build box"

    @desktop
    Scenario: A setting cannot be changed while its environment is disconnected
      Given the user is editing settings for "Build box"
      And "Build box" is disconnected
      When the user looks at an environment setting
      Then the setting cannot be changed
      And the user is told to reconnect the selected environment to change it

    @backlog @desktop
    Scenario: An environment-wide setting cannot be changed at project scope
      Given the user is editing settings for the project "hal-c2"
      When the user looks at an environment-wide setting
      Then the setting cannot be changed
      And the user is told to select an environment to change it

  Rule: The user can see and clear where a value comes from

    @backlog @desktop
    Scenario: The inheritance chain shows which layer wins
      Given the user is editing settings for the project "hal-c2"
      And "hal-c2" does not override the default model
      When the user asks where the default model comes from
      Then the project, environment, repository file and built-in default layers are listed in that order
      And the environment layer is marked as the one in effect

    @backlog @desktop
    Scenario: Resetting a project override inherits the environment's value again
      Given "hal-c2" overrides the default model
      And the user is editing settings for the project "hal-c2"
      When the user resets the default model to the inherited value
      Then "hal-c2" no longer overrides the default model
      And the default model shows the environment's value

    @backlog @desktop
    Scenario: The environment view lists and clears project overrides
      Given "hal-c2" overrides the default model on "Laptop"
      And the user is editing settings for "Laptop"
      When the user asks where the default model comes from
      Then "hal-c2" is listed as overriding it
      When the user resets the override for "hal-c2"
      Then "hal-c2" uses the value from "Laptop"

    @backlog @desktop
    Scenario: A value that differs between environments shows as mixed
      Given the default model differs between "Laptop" and "Build box"
      And the user is editing settings across all environments
      When the user looks at the default model
      Then it shows as mixed across the selected environments
      When the user chooses one model
      Then every environment uses that model

    @backlog @desktop
    Scenario: A model missing on one environment cannot be applied to all of them
      Given the model "opus" is only available on "Laptop"
      And the user is editing settings across all environments
      When the user tries to choose "opus" as the default model
      Then the user is told the model is unavailable on "Build box"
      And is told to select that environment to choose its model separately
