# Sources:
#   docs/user/project-settings.md (Import actions, Submodules)
#   packages/contracts/src/halC2ProjectFile.ts
#   packages/shared/src/halC2ProjectFile.ts (parseHalC2ProjectFile)
#   packages/shared/src/projectSettings.ts
#   apps/web/src/hooks/useHalC2ProjectFileScripts.ts
#   apps/web/src/lib/halC2ProjectFileDefaults.ts
#   apps/web/src/hooks/useHandleNewThread.ts (defaultThreadEnvMode)
#   apps/server-ex/lib/hal_c2/vcs.ex (submodules)
#   apps/server-ex/lib/hal_c2/project_file.ex (scripts)
#   apps/server-ex/lib/hal_c2/worktree_setup.ex (setup_script)
#   apps/desktop-qt/src/native/ProjectFile.cpp (parse)
#   apps/desktop-qt/src/native/ProjectActionsController.cpp (importScripts: the project keeps its setup script)
#   apps/server/src/project/HalC2ProjectFileLoader.ts
#   apps/server/src/project/ProjectFaviconResolver.ts (iconPath)

Feature: The hal-c2.json project file
  A checkout can carry a hal-c2.json file with shared defaults for everyone who opens it:
  actions, the script that sets up a new worktree, the default workspace for new threads,
  how deep submodules go, and an icon.
  Settings the user saves always win over the file, and the file wins over built-in defaults.

  Background:
    Given a connected environment with the project "shop"

  @mc
  Scenario Outline: New worktrees fill submodules as deep as the project asks
    Given <source> asks for "<mode>" submodules
    When a new worktree is created for "shop"
    Then its submodules are filled <depth>

    Examples:
      | source                                | mode      | depth                    |
      | the checkout's hal-c2.json                | top-level | one level deep           |
      | the checkout's hal-c2.json                | none      | not at all               |
      | the project's settings                | top-level | one level deep           |

  @mc
  Scenario: Project settings win over hal-c2.json for submodules
    Given the checkout's hal-c2.json asks for "none" submodules
    And the project's settings ask for "recursive" submodules
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @mc
  Scenario: Without hal-c2.json or a setting every submodule level is filled
    Given "shop" has no hal-c2.json and no submodule setting
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @mc
  Scenario: An unreadable hal-c2.json falls back to filling every submodule level
    Given the checkout's hal-c2.json is not valid JSON
    When a new worktree is created for "shop"
    Then its submodules are filled at every level

  @mc
  Scenario: A new worktree runs the setup script hal-c2.json marks
    Given the checkout's hal-c2.json marks "Setup" to run on new worktrees
    And "shop" has no saved actions
    When a thread starts in a new worktree of "shop"
    Then "Setup" runs in the new worktree

  # A branch cannot choose which setup command runs. The command still runs against
  # the branch's files, the same as a saved setup script.
  @mc
  Scenario: A branch cannot change which setup command runs
    Given the checkout's hal-c2.json marks "Setup" to run on new worktrees
    And the branch "contrib" changes the command of "Setup"
    When a thread starts in a new worktree of "shop" from "contrib"
    Then the new worktree skips the setup script because it differs from the main checkout's

  @mc
  Scenario: A setup script only a branch's hal-c2.json has does not run
    Given the branch "contrib" adds a hal-c2.json marking "Setup" to run on new worktrees
    When a thread starts in a new worktree of "shop" from "contrib"
    Then the new worktree skips the setup script because it differs from the main checkout's

  @mc
  Scenario: A saved setup script wins over hal-c2.json
    Given the checkout's hal-c2.json marks "Setup" to run on new worktrees
    And "shop" has the saved action "Install" marked to run on new worktrees
    When a thread starts in a new worktree of "shop"
    Then "Install" runs in the new worktree

  @mc
  Scenario: The first setup script in hal-c2.json is the one that runs
    Given the checkout's hal-c2.json marks "Setup" and then "Setup (Windows)" to run on new worktrees
    When a thread starts in a new worktree of "shop"
    Then "Setup" runs in the new worktree

  @mc
  Scenario: hal-c2.json is read from the new worktree's branch
    Given the project folder of "shop" has an uncommitted hal-c2.json marking "Setup" to run on new worktrees
    When a thread starts in a new worktree of "shop"
    Then the new worktree runs no setup script

  @mc
  Scenario: A hal-c2.json that does not match the format runs no setup script
    Given the checkout's hal-c2.json marks "Setup" to run on new worktrees with an unknown icon
    When a thread starts in a new worktree of "shop"
    Then the new worktree runs no setup script
    And a warning is logged that the project file was ignored

  @desktop @mobile @tui @backlog-mobile
  Scenario: hal-c2.json sets the default workspace for new threads
    Given the checkout's hal-c2.json sets the default workspace to "worktree"
    And the user never chose a default workspace for "shop"
    When the user starts a new thread in "shop"
    Then the draft starts in a new worktree

  @desktop @mobile @tui @backlog-mobile
  Scenario: A saved default workspace wins over hal-c2.json
    Given the checkout's hal-c2.json sets the default workspace to "worktree"
    And the user set the default workspace for "shop" to "local"
    When the user starts a new thread in "shop"
    Then the draft starts in the project folder

  @desktop @mobile @tui @backlog-mobile
  Scenario: Actions declared in hal-c2.json are offered for import
    Given the checkout's hal-c2.json declares the actions "Dev" and "Test"
    When the user looks at the actions of "shop"
    Then "Dev" and "Test" are offered to import from hal-c2.json

  @desktop @mobile @tui @backlog-mobile
  Scenario: Importing skips actions that already exist
    Given "shop" already has an action "dev" running "bun dev"
    And the checkout's hal-c2.json declares "Dev" running "bun dev" and "Lint" running "bun lint"
    When the user imports actions from hal-c2.json
    Then only "Lint" is added

  @desktop
  Scenario: An invalid hal-c2.json is reported and ignored
    Given the checkout's hal-c2.json does not match the project file format
    When the user looks at the actions of "shop"
    Then the user is warned that hal-c2.json is invalid
    And no actions are offered from it

  @desktop
  Scenario: hal-c2.json may contain comments
    Given the checkout's hal-c2.json has comments and declares the action "Dev"
    When the user looks at the actions of "shop"
    Then "Dev" is offered to import from hal-c2.json

  @mc
  Scenario: The icon named in hal-c2.json is used before the usual icon locations
    Given the checkout's hal-c2.json names "branding/mark.svg" as its icon
    And the checkout also has "public/favicon.ico"
    When a client asks for the icon of "shop"
    Then "branding/mark.svg" is served

  # Legacy: apps/server/src/project/HalC2ProjectFileLoader.ts (HAL_C2_PROJECT_FILE_NAMES)
  # Likely already implemented: apps/server-ex/lib/hal_c2/project_file.ex
  @mc @backlog
  Scenario: A checkout that only has the old t3.json is read from it
    Given the checkout has a "t3.json" declaring the action "Dev" and no hal-c2.json
    When the user looks at the actions of "shop"
    Then "Dev" is offered to import from the project file

  # Legacy: apps/server/src/project/HalC2ProjectFileLoader.ts (only a missing file falls through)
  @mc @backlog
  Scenario: hal-c2.json wins over t3.json, even when hal-c2.json cannot be read
    Given the checkout has a "t3.json" declaring the action "Old" and a hal-c2.json that cannot be read
    When the user looks at the actions of "shop"
    Then no actions are offered from either file
    And a warning is logged that the project file could not be read
