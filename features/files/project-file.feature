# Sources:
#   docs/user/project-settings.md (Import actions, Submodules)
#   packages/contracts/src/t3ProjectFile.ts
#   packages/shared/src/t3ProjectFile.ts (parseT3ProjectFile)
#   packages/shared/src/projectSettings.ts
#   apps/web/src/hooks/useT3ProjectFileScripts.ts
#   apps/web/src/lib/t3ProjectFileDefaults.ts
#   apps/web/src/hooks/useHandleNewThread.ts (defaultThreadEnvMode)
#   apps/server-ex/lib/t3/vcs.ex (submodules)
#   apps/server/src/project/T3ProjectFileLoader.ts
#   apps/server/src/project/ProjectFaviconResolver.ts (iconPath)

Feature: The t3.json project file
  A checkout can carry a t3.json file with shared defaults for everyone who opens it:
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
      | the checkout's t3.json                | top-level | one level deep           |
      | the checkout's t3.json                | none      | not at all               |
      | the project's settings                | top-level | one level deep           |

  @node
  Scenario: Project settings win over t3.json for submodules
    Given the checkout's t3.json asks for "none" submodules
    And the project's settings ask for "recursive" submodules
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @node
  Scenario: Without t3.json or a setting every submodule level is filled
    Given "shop" has no t3.json and no submodule setting
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @node
  Scenario: An unreadable t3.json falls back to filling every submodule level
    Given the checkout's t3.json is not valid JSON
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @backlog @desktop @mobile @tui
  Scenario: t3.json sets the default workspace for new threads
    Given the checkout's t3.json sets the default workspace to "worktree"
    And the user never chose a default workspace for "shop"
    When the user starts a new thread in "shop"
    Then the draft starts in a new worktree

  @backlog @desktop @mobile @tui
  Scenario: A saved default workspace wins over t3.json
    Given the checkout's t3.json sets the default workspace to "worktree"
    And the user set the default workspace for "shop" to "local"
    When the user starts a new thread in "shop"
    Then the draft starts in the project folder

  @backlog @desktop @mobile @tui
  Scenario: Actions declared in t3.json are offered for import
    Given the checkout's t3.json declares the actions "Dev" and "Test"
    When the user looks at the actions of "shop"
    Then "Dev" and "Test" are offered to import from t3.json

  @backlog @desktop @mobile @tui
  Scenario: Importing skips actions that already exist
    Given "shop" already has an action "dev" running "bun dev"
    And the checkout's t3.json declares "Dev" running "bun dev" and "Lint" running "bun lint"
    When the user imports actions from t3.json
    Then only "Lint" is added

  @backlog @desktop
  Scenario: An invalid t3.json is reported and ignored
    Given the checkout's t3.json does not match the project file format
    When the user looks at the actions of "shop"
    Then the user is warned that t3.json is invalid
    And no actions are offered from it

  @backlog @desktop
  Scenario: t3.json may contain comments
    Given the checkout's t3.json has comments and declares the action "Dev"
    When the user looks at the actions of "shop"
    Then "Dev" is offered to import from t3.json

  @node
  Scenario: The icon named in t3.json is used before the usual icon locations
    Given the checkout's t3.json names "branding/mark.svg" as its icon
    And the checkout also has "public/favicon.ico"
    When a client asks for the icon of "shop"
    Then "branding/mark.svg" is served
