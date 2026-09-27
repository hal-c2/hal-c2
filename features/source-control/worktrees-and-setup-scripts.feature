# Sources:
#   docs/user/source-control.md
#   packages/contracts/src/vcs.ts (VcsCreateWorktreeInput, VcsRemoveWorktreeInput)
#   packages/contracts/src/worktreeSetup.ts (WorktreeSetupSnapshot, stages, phases)
#   packages/contracts/src/worktreeMcp.ts (hal_c2_worktree_handoff, hal_c2_worktree_status, hal_c2_worktree_list)
#   packages/contracts/src/rpc.ts (vcs.createWorktree, vcs.removeWorktree, subscribeWorktreeSetup, worktreeSetup.cancel)
#   apps/server-ex/lib/hal_c2/vcs.ex (create_worktree, remove_worktree)
#   apps/server-ex/lib/hal_c2/worktree_setup.ex (temporary_branch, temporary?)
#   apps/server/src/orchestration-v2/ThreadLaunchService.ts (temporary branch rename)
#   packages/shared/src/git.ts (WORKTREE_BRANCH_PREFIX, isTemporaryWorktreeBranch)
#   apps/server-ex/lib/hal_c2/mcp/tools/projects.ex (hal_c2_worktree_handoff, hal_c2_worktree_status, hal_c2_worktree_list)
#   apps/web/src/components/BranchToolbarEnvModeSelector.tsx
#   apps/web/src/components/BranchToolbar.logic.ts (Previous worktree, worktree submodules)
#   apps/web/src/components/WorktreeBaseBranchPicker.tsx
#   apps/web/src/components/chat/WorktreeSetupCard.tsx
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (checkout mode)
#   packages/contracts/src/shell.ts (workspace.envMode.set)

Feature: Worktrees and setup scripts
  A thread can start in its own worktree. The node creates it from a base ref, runs the
  project's setup script, starts the agent, and shows each stage while it happens.

  Background:
    Given a connected environment with the git project "shop" whose default branch is "main"

  @desktop
  Scenario: Choosing a new worktree for a new thread
    Given the user is writing the first message of a new thread in "shop"
    When the user picks the new worktree checkout mode
    Then the thread will start in a worktree of its own instead of the project folder

  @desktop
  Scenario: Going back to the project folder
    Given the user picked the new worktree checkout mode for a new thread
    When the user picks the current checkout mode
    Then the thread will start in the project folder

  @backlog @tui @mobile
  Scenario: Choosing a new worktree from the terminal client and phone
    When the user starts a thread in a new worktree of "shop"
    Then the thread starts in a worktree of its own

  @backlog @desktop @mobile
  Scenario: Picking the base ref for a new worktree
    When the user starts a thread in a new worktree based on "release/2"
    Then the worktree starts from "release/2"

  @node
  Scenario: A new worktree is made under the HAL-C2 home by default
    When a worktree is created for the branch "feature/tax" with no path given
    Then it is made in the HAL-C2 home's worktrees folder under the repository and branch names

  @node
  Scenario: Starting from origin fetches the base first
    Given the project starts worktrees from origin and "shop" has the remote "origin"
    When the user sends the first message of a thread in a new worktree
    Then the fetch stage runs before the files are checked out

  @node
  Scenario: Without a remote the fetch stage is skipped
    Given "shop" has no remote
    When the user sends the first message of a thread in a new worktree
    Then the fetch stage is reported as skipped

  @node
  Scenario: The temporary branch is renamed from the first message
    When the user sends "Add tax to the cart" as the first message of a thread in a new worktree
    Then the worktree first sits on a temporary branch
    And the branch is renamed to a name the writer model derives from the message

  @node
  Scenario: A client that names the temporary branch itself gets it renamed too
    Given the client names the new worktree's temporary branch "hal-c2/42a5d641"
    When the user sends "Add tax to the cart" as the first message of a thread in a new worktree
    Then the worktree first sits on the temporary branch "hal-c2/42a5d641"
    And the branch is renamed to a name the writer model derives from the message

  @node
  Scenario: A branch named "hal-c2" does not stop a new worktree
    Given "shop" has a branch named "hal-c2"
    When the user sends the first message of a thread in a new worktree
    Then the worktree is made on a temporary branch beside "hal-c2"

  @node
  Scenario Outline: Setup reports each stage as it runs
    When the user sends the first message of a thread in a new worktree
    Then the setup reports the stage "<stage>" with its status

    Examples:
      | stage              |
      | Fetch base branch  |
      | Check out files    |
      | Run setup script   |
      | Start agent        |

  @node
  Scenario: Submodule initialization is its own setup stage
    Given "shop" has submodules
    When the user sends the first message of a thread in a new worktree
    Then the setup reports the stage "Init submodules" with its status

  @node
  Scenario Outline: Submodules follow the project's setting
    Given "shop" has nested submodules and the worktree submodules setting is <setting>
    When a worktree is created
    Then <result>

    Examples:
      | setting        | result                                                  |
      | recursive      | every submodule is initialized, nested ones included    |
      | top level only | only the top level submodules are initialized           |
      | skip           | no submodule is initialized                             |

  @node
  Scenario: The setup script runs in the setup terminal
    Given "shop" has a setup script set to run when a worktree is created
    When the user sends the first message of a thread in a new worktree
    Then the script runs in the thread's "setup" terminal inside the new worktree

  # files/project-scripts-and-actions.feature holds a project without a setup script
  # skipping that stage.
  @node
  Scenario: The setup script's latest output is shown while it runs
    Given "shop" has a setup script that prints many lines
    When the user sends the first message of a thread in a new worktree
    Then the setup script stage shows the last 5 lines of its output as it runs

  @node
  Scenario: A failing setup script that must finish first fails the setup
    Given the setup script must finish before the agent starts and it exits with 3
    When the user sends the first message of a thread in a new worktree
    Then the setup fails with "Setup script exited with 3."
    And the agent does not start

  @node
  Scenario: A failing background setup script does not stop the agent
    Given the setup script runs in the background and it exits with 3
    When the user sends the first message of a thread in a new worktree
    Then the setup script stage is reported as failed
    And the agent still starts

  @node
  Scenario: A worktree that cannot be created fails the setup
    Given the branch cannot be checked out into a new worktree
    When the user sends the first message of a thread in a new worktree
    Then the setup fails with a message starting "Could not create the worktree:"

  @node
  Scenario: Cancelling setup before the agent starts
    Given a thread's worktree setup is still checking out files
    When the user cancels the setup
    Then the worktree is removed
    And the thread no longer points at a worktree
    And the setup is reported as cancelled

  @node
  Scenario: Setup cannot be cancelled once the agent is starting
    Given a thread's worktree setup has reached the agent stage
    When the user cancels the setup
    Then the setup is not cancelled
    And the worktree stays

  @node
  Scenario: An agent that cannot start fails the setup
    Given a thread's worktree is ready and its setup script finished
    And the thread's run cannot be released to the agent
    When the setup reaches the agent stage
    Then the setup fails with a message starting "The agent could not start:"

  @node
  Scenario: A client that reconnects sees the setup where it is now
    Given a thread's worktree setup is running the setup script
    When the user's client drops and reconnects
    Then it receives the setup's current stages, not a replay

  @node
  Scenario: Setup progress does not outlive the node
    Given a thread's worktree setup finished
    When the node restarts
    Then no setup progress is shown for that thread

  @backlog @desktop @mobile
  Scenario: The setup card shows the base, branch and path
    When the user sends the first message of a thread in a new worktree
    Then the thread shows the worktree's base, branch and path with the stages
    And it reads "Worktree ready" once the agent starts

  @node
  Scenario: Removing a worktree
    Given "feature/tax" has a worktree with no changes
    When the user removes that worktree
    Then its folder is gone and git no longer lists it

  @node
  Scenario: Removing a worktree whose folder was already deleted
    Given the folder of the "feature/tax" worktree was deleted by hand
    When the user removes that worktree
    Then git forgets it without an error

  @node
  Scenario: Forcing removal of a worktree with changes
    Given the "feature/tax" worktree has uncommitted changes
    When the user removes that worktree with force
    Then its folder is gone

  @backlog @desktop @mobile
  Scenario: Returning to the previous worktree
    Given the user just finished a thread in the worktree on "feature/tax"
    When the user starts a new thread in "shop"
    Then the user can pick the previous worktree on "feature/tax" for it

  @node
  Scenario: The agent moves its thread into a new worktree
    Given the agent works in "shop" without a worktree
    When the agent hands the thread off to a new worktree on "feature/pay" with a continuation prompt
    Then the worktree is created and the thread points at it
    And the setup script is started
    And the agent continues in the worktree with the prompt

  @node
  Scenario: A thread already in a worktree cannot be handed off again
    Given the thread already works in a worktree
    When the agent hands the thread off to a new worktree
    Then the handoff is refused as already in a worktree

  @node
  Scenario: The agent asks where its thread is working
    Given the thread works in the worktree on "feature/tax"
    When the agent asks for its worktree status
    Then it learns it is attached, with the worktree path, branch and project root
