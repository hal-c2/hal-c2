# Sources:
#   hal-c2/hal-c2#640 (a session launched from the app lacks the environment a terminal in the same
#     checkout has, so a .mcp.json that expands ${SOME_URL} fails)
#   docs/user/project-settings.md (Project environment)
#   apps/server-ex/lib/hal_c2/project_environment.ex (loaders, precedence, the notice)
#   apps/server-ex/lib/hal_c2/settings.ex (projectEnvironment and projectEnvironmentFile are project-scoped)
#   packages/contracts/src/settings.ts (projectEnvironment, projectEnvironmentFile)
#   apps/desktop-qt/src/native/ProjectSettingsController.cpp, apps/desktop-qt/qml/HalC2/Bricks/ProjectSettings.qml
#   apps/tui/src/host/sections/projects.ts
#   Decisions:
#   - Off by default: loading runs the checkout's own configuration, so it is trusted per project.
#   - Precedence, lowest first: the MC's environment, the project's, then what the adapter sets for
#     the session (the provider instance's variables and HAL-C2's own). The project never sets a
#     HAL_C2_* variable or one the launch removes.
#   - The working directory is the thread's: a worktree thread loads its worktree's configuration.
#   - mise's `mise trust` and direnv's `direnv allow` still apply; HAL-C2 reports them, never bypasses them.

Feature: Loading a project's environment into agent sessions
  A project can give the agents it starts the variables a terminal in its checkout would have:
  what its mise configuration, direnv .envrc or a dotenv file declares.

  Background:
    Given a connected environment "laptop" with the project "shop"

  @mc
  Scenario Outline: A project that loads its environment gives it to <provider> sessions
    Given "shop" loads its environment from ".env"
    And the checkout of "shop" declares the session's variables in ".env"
    When a <provider> thread in "shop" runs a turn
    Then the <provider> session had the project's variables

    Examples:
      | provider  |
      | Codex     |
      | Claude    |
      | OpenCode  |
      | Grok      |
      | Cursor    |
      | Pi        |
      | Muse Code |

  @mc
  Scenario: A project does not load its environment unless the user turns it on
    Given the checkout of "shop" declares the session's variables in ".env"
    When a Codex thread in "shop" runs a turn
    Then the Codex session did not have the project's variables

  @mc
  Scenario: Turning loading off stops it from the next session
    Given "shop" loads its environment from ".env"
    And the checkout of "shop" declares the session's variables in ".env"
    When the user turns off loading the environment of "shop"
    And a Codex thread in "shop" runs a turn
    Then the Codex session did not have the project's variables
    And "shop" shows its environment is not loaded

  @mc
  Scenario: An environment that cannot be loaded does not stop the session
    Given "shop" loads its environment from ".env.dev"
    And the checkout of "shop" has no ".env.dev"
    When a Codex thread in "shop" runs a turn
    Then the session starts anyway and the turn completes
    And the thread shows the project environment was not loaded because ".env.dev" was not found

  @mc
  Scenario: A configuration direnv has not allowed is reported, not loaded
    Given "shop" loads its environment from mise and direnv
    And the checkout of "shop" has an .envrc direnv has not allowed
    When a Codex thread in "shop" runs a turn
    Then the session starts anyway and the turn completes
    And the thread shows the project environment was not loaded and to run "direnv allow"

  @mc
  Scenario: The project's environment cannot replace a variable HAL-C2 sets for the session
    Given "shop" loads its environment from ".env"
    And the checkout of "shop" declares "HAL_C2_MCP_URL" and the provider instance's "CODEX_HOME" in ".env"
    When the MC builds the environment of a session in "shop"
    Then the session keeps HAL-C2's "HAL_C2_MCP_URL" and the instance's "CODEX_HOME"

  # Proven by apps/desktop-qt/tests/tst_ProjectSettings.qml (the environment row and its file);
  # the phone shows the same ProjectSettings brick. The TUI's row is proven by
  # apps/tui/src/host/sections/projects.test.ts.
  @desktop @mobile @tui @backlog-desktop @backlog-mobile @backlog-tui
  Scenario Outline: The user chooses where a project's environment comes from
    Given the user picked "shop" in settings
    When the user sets the project environment to <source>
    Then the project settings of "shop" show the project environment as <source>
    And the user is told loading it runs the checkout's own configuration

    Examples:
      | source              |
      | off                 |
      | mise and direnv     |
      | the dotenv ".env.a" |
