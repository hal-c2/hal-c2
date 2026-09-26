# Sources:
#   docs/user/project-settings.md (Import actions, Submodules)
#   packages/contracts/src/halC2ProjectFile.ts
#   packages/shared/src/halC2ProjectFile.ts (parseHalC2ProjectFile)
#   packages/shared/src/projectSettings.ts
#   apps/web/src/hooks/useHalC2ProjectFileScripts.ts
#   apps/web/src/lib/halC2ProjectFileDefaults.ts
#   apps/web/src/hooks/useHandleNewThread.ts (defaultThreadEnvMode)
#   apps/server-ex/lib/hal_c2/vcs.ex (submodules)
#   apps/server/src/project/HalC2ProjectFileLoader.ts
#   apps/server/src/project/ProjectFaviconResolver.ts (iconPath)

Feature: The hal-c2.json project file
  A checkout can carry a hal-c2.json file with shared defaults for everyone who opens it:
  actions, the default workspace for new threads, how deep submodules go, and an icon.
  Settings the user saves always win over the file, and the file wins over built-in defaults.

  Background:
    Given a connected environment with the project "shop"

  @node
  Scenario Outline: New worktrees fill submodules as deep as the project asks
    Given <source> asks for "<mode>" submodules
    When a new worktree is created for "shop"
    Then its submodules are filled <depth>

    Examples:
      | source                                | mode      | depth                    |
      | the checkout's hal-c2.json                | top-level | one level deep           |
      | the checkout's hal-c2.json                | none      | not at all               |
      | the project's settings                | top-level | one level deep           |

  @node
  Scenario: Project settings win over hal-c2.json for submodules
    Given the checkout's hal-c2.json asks for "none" submodules
    And the project's settings ask for "recursive" submodules
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @node
  Scenario: Without hal-c2.json or a setting every submodule level is filled
    Given "shop" has no hal-c2.json and no submodule setting
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @node
  Scenario: An unreadable hal-c2.json falls back to filling every submodule level
    Given the checkout's hal-c2.json is not valid JSON
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @backlog @desktop @mobile @tui
  Scenario: hal-c2.json sets the default workspace for new threads
    Given the checkout's hal-c2.json sets the default workspace to "worktree"
    And the user never chose a default workspace for "shop"
    When the user starts a new thread in "shop"
    Then the draft starts in a new worktree

  @backlog @desktop @mobile @tui
  Scenario: A saved default workspace wins over hal-c2.json
    Given the checkout's hal-c2.json sets the default workspace to "worktree"
    And the user set the default workspace for "shop" to "local"
    When the user starts a new thread in "shop"
    Then the draft starts in the project folder

  @backlog @desktop @mobile @tui
  Scenario: Actions declared in hal-c2.json are offered for import
    Given the checkout's hal-c2.json declares the actions "Dev" and "Test"
    When the user looks at the actions of "shop"
    Then "Dev" and "Test" are offered to import from hal-c2.json

  @backlog @desktop @mobile @tui
  Scenario: Importing skips actions that already exist
    Given "shop" already has an action "dev" running "bun dev"
    And the checkout's hal-c2.json declares "Dev" running "bun dev" and "Lint" running "bun lint"
    When the user imports actions from hal-c2.json
    Then only "Lint" is added

  @backlog @desktop
  Scenario: An invalid hal-c2.json is reported and ignored
    Given the checkout's hal-c2.json does not match the project file format
    When the user looks at the actions of "shop"
    Then the user is warned that hal-c2.json is invalid
    And no actions are offered from it

  @backlog @desktop
  Scenario: hal-c2.json may contain comments
    Given the checkout's hal-c2.json has comments and declares the action "Dev"
    When the user looks at the actions of "shop"
    Then "Dev" is offered to import from hal-c2.json

  @node
  Scenario: The icon named in hal-c2.json is used before the usual icon locations
    Given the checkout's hal-c2.json names "branding/mark.svg" as its icon
    And the checkout also has "public/favicon.ico"
    When a client asks for the icon of "shop"
    Then "branding/mark.svg" is served
