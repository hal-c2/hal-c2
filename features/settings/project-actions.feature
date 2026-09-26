# Sources:
#   docs/user/project-settings.md (Actions)
#   apps/web/src/components/settings/ProjectActionsSettings.tsx
#   apps/web/src/components/settings/ProjectActionsList.tsx
#   apps/web/src/components/settings/useProjectScriptSettings.ts
#   apps/web/src/components/projectScriptEditor.tsx
#   apps/server-ex/lib/t3/settings.ex (defaultProjectScripts, projectSettingsOverrides)
#   packages/contracts/src/rpc.ts (t3.readSettings, t3.writeSettings, t3.upsertKeybinding, t3.removeKeybinding)

Feature: Project actions settings panel
  The Actions panel lists the actions every project on an environment starts with, and a
  project's own actions when a project is picked. Running and editing actions is described
  in the files domain.

  Background:
    Given a connected environment "laptop" with the project "shop"

  @backlog @desktop
  Scenario: An environment without actions says so
    Given "laptop" has no default actions
    When the user opens the Actions settings for all projects
    Then the user is told no actions are configured

  @backlog @desktop
  Scenario: Default actions apply to every project on the environment
    When the user adds the default action "Dev" running "bun dev" for all projects
    Then "Dev" is offered in every project on "laptop" that has no actions of its own

  @backlog @desktop
  Scenario: A project's own actions replace the defaults
    Given "laptop" has the default action "Dev"
    When the user picks "shop" and adds the action "Storybook"
    Then "shop" offers its own list with "Dev" and "Storybook"
    And other projects still offer only "Dev"

  @backlog @desktop
  Scenario: Resetting a project's actions returns to the defaults
    Given "shop" has its own actions
    When the user resets the actions of "shop"
    Then "shop" offers the default actions of "laptop" again

  @backlog @desktop
  Scenario: The list marks the setup action and desktop-only previews
    Given "shop" has the setup action "Install" and the action "Dev" with a preview address
    When the user opens the Actions settings for "shop"
    Then "Install" is marked as the setup action
    And "Dev" is marked as having a preview on desktop only

  @backlog @desktop
  Scenario: Actions from t3.json can be imported without editing them first
    Given the checkout's t3.json declares the action "Lint"
    When the user imports the actions of "shop" from t3.json
    Then "shop" has the action "Lint"

  @backlog @desktop
  Scenario: An invalid t3.json is flagged in the panel
    Given the checkout's t3.json is invalid
    When the user opens the Actions settings for "shop"
    Then the user is warned that t3.json is invalid

  @backlog @desktop
  Scenario: Environments that disagree are shown as different
    Given the user applies settings to "laptop" and "server"
    And their default actions differ
    When the user opens the Actions settings
    Then the user is told the environments have different actions

  @backlog @desktop
  Scenario: A save that cannot be applied is reported
    Given no connected environment can take the change
    When the user adds a default action
    Then the user is told the actions were not saved

  @backlog @desktop
  Scenario: A save rejected by the environment is reported
    Given "laptop" rejects the settings change
    When the user adds a default action
    Then the user is told the project actions failed to save

  @backlog @desktop
  Scenario: Environments too old for project overrides are left out
    Given "server" runs a server without project overrides
    When the user picks "shop" in the Actions settings
    Then changes apply only to environments that support project overrides
