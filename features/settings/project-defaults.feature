# Sources:
#   docs/user/project-settings.md (Defaults and inheritance, Submodules, automatic pull)
#   apps/web/src/components/settings/ProjectDefaultsSettings.tsx
#   apps/server-ex/lib/hal_c2/settings.ex (project-scoped keys, for_project)
#   packages/contracts/src/project.ts (defaultModelSelection, defaultThreadEnvMode, autoPull)
#   packages/contracts/src/rpc.ts (hal-c2.readSettings, hal-c2.writeSettings)
#   Cross-domain: these rows are the ones ProjectDefaultsSettings.tsx embeds in the General,
#   Source Control and Integrations panels; no other settings/ file repeats them. How overrides
#   resolve, mixed values across environments and models missing on one environment are owned
#   by settings/scopes-and-inheritance.feature; scenarios repeated here name it in a comment.

Feature: Project defaults settings
  The defaults rows set how new threads start in a project: the model, the workspace, the
  permissions, submodules, automatic pull, the merge method, and browser access. The same
  rows edit an environment's defaults or a picked project's overrides.

  Background:
    Given a connected environment "laptop" with the project "shop"

  @mc
  Scenario: A project's override wins over the environment's value
    Given "laptop" uses the default workspace "local"
    And "shop" overrides the default workspace to "worktree"
    # Neither server serves project-resolved settings; the MC resolves them (HalC2.Settings.for_project).
    When the MC resolves the settings for "shop"
    Then the default workspace is "worktree"

  # Same behaviour as "A project model override on a disabled provider falls back to the
  # environment's" in settings/scopes-and-inheritance.feature, which owns it.
  @mc
  Scenario: A project's model override on a disabled provider falls back to the environment's
    Given "laptop" uses the default model "Sonnet"
    And "shop" overrides the default model with a model from a disabled provider
    # Neither server serves project-resolved settings; the MC resolves them (HalC2.Settings.for_project).
    When the MC resolves the settings for "shop"
    Then the default model is "Sonnet"

  @backlog @desktop @mobile
  Scenario Outline: Each default can be set for a project and reset to inherit
    Given the user picked "shop" in settings
    When the user sets <setting> to <value>
    Then new threads in "shop" use <value>
    When the user resets <setting>
    Then "shop" inherits <setting> from "laptop" again

    Examples:
      | setting                        | value           |
      | the default model              | "Opus"          |
      | the default workspace          | a new worktree  |
      | the default permissions        | plan mode       |
      | worktree submodules            | top-level only  |
      | automatic pull                 | on              |
      | the pull request merge method  | squash          |
      | agent browser access           | off             |

  @desktop @mobile @backlog-mobile
  Scenario: No default model means the model is picked automatically
    Given neither "shop" nor "laptop" sets a default model
    When the user looks at the project defaults of "shop"
    Then the default model shows as automatic

  # See "A model missing on one environment cannot be applied to all of them" in settings/scopes-and-inheritance.feature.
  @desktop
  Scenario: A model unavailable on an environment is not saved
    Given "Opus" is not available on "laptop"
    When the user sets the default model of "shop" to "Opus"
    Then the user is told the default model was not saved because it is unavailable on "laptop"

  @desktop
  Scenario: Without providers the model cannot be chosen
    Given "laptop" has no providers
    When the user looks at the project defaults of "shop"
    Then the user is told no providers are available

  # See "A value that differs between environments shows as mixed" in settings/scopes-and-inheritance.feature.
  @desktop @mobile @backlog-mobile
  Scenario: Environments that disagree show the value as mixed
    Given the user applies settings to "laptop" and "server"
    And their default workspaces differ
    When the user looks at the default workspace
    Then it shows as mixed
    When the user picks "local"
    Then both environments use "local"

  @desktop
  Scenario: Defaults are unavailable when no environment is connected
    Given no environment is connected
    When the user looks at the project defaults
    Then the defaults show as unavailable

  @backlog @desktop
  Scenario: The merge method can follow the last one the user chose
    When the user sets the default pull request merge method to "Last selected"
    And the user merges a pull request with "rebase"
    Then the next pull request merge defaults to "rebase"

  @backlog @desktop
  Scenario: A browser access change applies when the agent session next starts
    Given an agent session is running in "shop"
    When the user turns agent browser access off for "shop"
    Then the running session keeps its browser access
    And the next session in "shop" starts without browser access
