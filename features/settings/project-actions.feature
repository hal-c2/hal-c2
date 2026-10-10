# Sources:
#   docs/user/project-settings.md (Actions)
#   apps/web/src/components/settings/ProjectActionsSettings.tsx
#   apps/web/src/components/settings/ProjectActionsList.tsx
#   apps/web/src/components/settings/useProjectScriptSettings.ts
#   apps/web/src/components/projectScriptEditor.tsx
#   apps/server-ex/lib/hal_c2/settings.ex (defaultProjectScripts, projectSettingsOverrides)
#   packages/contracts/src/rpc.ts (hal-c2.readSettings, hal-c2.writeSettings, hal-c2.upsertKeybinding, hal-c2.removeKeybinding)

Feature: Project actions settings panel
  The Actions panel lists the actions every project on an environment starts with, and a
  project's own actions when a project is picked. Running and editing actions is described
  in the files domain.

  Background:
    Given a connected environment "laptop" with the project "shop"

  @desktop
  Scenario: An environment without actions says so
    Given "laptop" has no default actions
    When the user opens the Actions settings for all projects
    Then the user is told no actions are configured

  @desktop
  Scenario: Default actions apply to every project on the environment
    When the user adds the default action "Dev" running "bun dev" for all projects
    Then "Dev" is offered in every project on "laptop" that has no actions of its own

  @desktop
  Scenario: A project's own actions replace the defaults
    Given "laptop" has the default action "Dev"
    When the user picks "shop" and adds the action "Storybook"
    Then "shop" offers its own list with "Dev" and "Storybook"
    And other projects still offer only "Dev"

  @desktop
  Scenario: Resetting a project's actions returns to the defaults
    Given "shop" has its own actions
    When the user resets the actions of "shop"
    Then "shop" offers the default actions of "laptop" again

  @desktop
  Scenario: The list marks the setup action and desktop-only previews
    Given "shop" has the setup action "Install" and the action "Dev" with a preview address
    When the user opens the Actions settings for "shop"
    Then "Install" is marked as the setup action
    And "Dev" is marked as having a preview on desktop only

  @desktop
  Scenario: Actions from hal-c2.json can be imported without editing them first
    Given the checkout's hal-c2.json declares the action "Lint"
    When the user imports the actions of "shop" from hal-c2.json
    Then "shop" has the action "Lint"

  @desktop
  Scenario: An invalid hal-c2.json is flagged in the panel
    Given the checkout's hal-c2.json is invalid
    When the user opens the Actions settings for "shop"
    Then the user is warned that hal-c2.json is invalid

  @desktop
  Scenario: Environments that disagree are shown as different
    Given the user applies settings to "laptop" and "server"
    And their default actions differ
    When the user opens the Actions settings
    Then the user is told the environments have different actions

  @desktop
  Scenario: A save that cannot be applied is reported
    Given no connected environment can take the change
    When the user adds a default action
    Then the user is told the actions were not saved

  @desktop
  Scenario: A save rejected by the environment is reported
    Given "laptop" rejects the settings change
    When the user adds a default action
    Then the user is told the project actions failed to save

  @desktop
  Scenario: Environments too old for project overrides are left out
    Given "server" runs a server without project overrides
    When the user picks "shop" in the Actions settings
    Then changes apply only to environments that support project overrides

  # Legacy: apps/web/src/components/settings/ProjectActionsSettings.tsx (importableScripts)
  @backlog @desktop
  Scenario: Only actions the project does not have yet can be imported
    Given the checkout's hal-c2.json declares "Lint" running "bun lint" and "Dev" running "bun dev"
    And "shop" has an action named "dev" running "bun run start"
    When the user opens the Actions settings for "shop"
    Then only "Lint" can be imported from hal-c2.json
    When "shop" has every action of hal-c2.json
    Then there is nothing to import from hal-c2.json
