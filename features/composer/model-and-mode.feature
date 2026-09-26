# Sources:
#   docs/user/composer.md (custom models, remembered model defaults)
#   docs/user/permission-modes.md
#   apps/desktop-qt/qml/T3/Bricks/Composer.qml (model, effort, permissions, Build and Plan, context strip)
#   apps/tui/src/models.ts (flattened model list, unavailable providers skipped)
#   apps/tui/src/components/ChatView.tsx (plan toggle, access, model and effort shortcuts)
#   apps/server-ex/lib/t3/orchestration.ex (thread.runtime-mode.set, thread.interaction-mode.set, thread.model-selection.set)
#   apps/web/src/components/chat/TraitsPicker.tsx
#   apps/web/src/components/chat/ModelPickerContent.tsx
#   apps/web/src/components/chat/ModelPickerSidebar.tsx
#   apps/web/src/composerDraftStore.ts (sticky model selection per provider)
#   packages/shared/src/keybindings.ts (modelPicker.toggle, modelPicker.previousProvider, modelPicker.nextProvider, modelPicker.jump.1-9, composer.effort, composer.mode, composer.host, composer.workspace, composer.branch, composer.previousWorktree)
#   packages/contracts/src/settings.ts (planModeEnabled, favorites, providerModelPreferences)
#   apps/web/src/components/BranchToolbarEnvironmentSelector.tsx, apps/web/src/components/ChatView.tsx (Run on, Auto balance labels)
#   apps/web/src/components/chat/useAutoBalanceUpdateBanner.tsx (one update notice for balanced machines)
#   Auto balance is desktop and terminal only; phones pick the machine by hand (settings/load-balancing.feature).

Feature: Choosing the model, effort, permissions and workspace for a turn
  Before sending, the user decides which model runs the turn, how hard it
  thinks, what it may do without asking, and where it works. Changes apply to
  the next turn and are remembered for the thread.

  Background:
    Given a project with an open thread on Codex

  @desktop @tui
  Scenario: The user switches the model for the next turn
    When the user chooses the model "gpt-5-codex"
    Then the next turn runs on "gpt-5-codex"

  @desktop @tui
  Scenario: Models from unavailable providers cannot be chosen
    Given the Cursor provider is not installed
    When the user looks through the models
    Then Cursor's models cannot be chosen

  @desktop @tui
  Scenario Outline: The user sets the reasoning effort for the next turn
    When the user sets the effort to <effort>
    Then the next turn runs with <effort> effort

    Examples:
      | effort |
      | low    |
      | medium |
      | high   |

  @node @desktop @tui
  Scenario Outline: The user sets what the agent may do without asking
    When the user sets the permissions to <mode>
    Then the next turn runs in <mode>

    Examples:
      | mode                 |
      | Supervised           |
      | Auto-accept edits    |
      | Auto                 |
      | Full access          |

  @node @tui
  Scenario: Planning and building can be toggled for the next turn
    Given the thread is building
    When the user toggles to planning
    Then the next turn plans instead of making changes
    When the user toggles back
    Then the next turn builds again

  @backlog @desktop
  Scenario: Ultrathink prefixes the prompt
    Given the thread runs on Claude
    When the user turns on Ultrathink and sends "design the cache"
    Then the agent receives "Ultrathink: design the cache"

  @backlog @desktop @mobile
  Scenario: Favourite models are listed first and can be unfavourited
    When the user marks "claude-opus" as a favourite
    Then "claude-opus" is listed among the favourites
    When the user removes it from the favourites
    Then it is no longer listed among the favourites

  @backlog @desktop @mobile
  Scenario: A thread's provider is locked once it has started
    Given the thread has already run a turn on Codex
    When the user looks through the models
    Then only Codex models can be chosen

  @backlog @desktop @tui @mobile
  Scenario: The last model used with each provider is remembered
    Given the user last used "gpt-5" with Codex
    When the user starts a new thread on Codex
    Then "gpt-5" is chosen
    But a model set for the project takes precedence

  @backlog @desktop @tui @mobile
  Scenario: New threads start with the default permissions
    Given the default permissions for new threads are Supervised
    When the user starts a new thread
    Then the thread runs in Supervised
    But a project that overrides the default uses its own permissions

  @desktop
  Scenario: The user chooses which environment runs a new thread
    Given two environments are connected
    When the user starts a new thread on the second environment
    Then the thread is created in the second environment

  @desktop
  Scenario: The user chooses to work in the current checkout or a new worktree
    Given the project is a Git repository
    When the user chooses to work in a new worktree from branch "main"
    Then the first turn works in a new worktree based on "main"

  @desktop
  Scenario: A branch that does not exist is created when chosen
    Given the project has no branch "feature/cache"
    When the user searches for "feature/cache" and confirms it
    Then the thread works on a new branch "feature/cache"

  @backlog @desktop
  Scenario: New worktree mode needs a base branch before sending
    Given the user chose to work in a new worktree
    And no base branch is chosen
    When the user tries to send the first message
    Then the user is asked to select a base branch

  @backlog @desktop
  Scenario: The user lets a new thread's machine be picked automatically
    Given the project exists on two connected machines and load balancing is on
    When the user chooses "Auto balance" as the machine a new thread runs on
    Then the thread starts on the machine with the most room when the first message is sent

  @backlog @desktop
  Scenario: Auto balance says when it cannot check the machines
    Given the user chose "Auto balance" for a new thread
    When checking the machines' free resources fails
    Then the picker shows "Auto balance unavailable"

  @backlog @desktop
  Scenario: The user takes a new thread off Auto balance
    Given the user chose "Auto balance" for a new thread
    When the user chooses the machine "laptop" instead
    Then the thread starts on "laptop"

  @backlog @desktop
  Scenario Outline: Updates for every balanced machine are gathered in one notice
    Given the user chose "Auto balance" for a new thread
    And <state>
    When the user looks at the composer
    Then one notice reads "<notice>"
    And opening it lists each machine and its update

    Examples:
      | state                                      | notice                            |
      | "laptop" and "server" both have an update  | Update available for 2 machines   |
      | "server" is updating                       | Updating 1 machine                |
      | the update of "server" failed              | Could not update 1 machine        |
