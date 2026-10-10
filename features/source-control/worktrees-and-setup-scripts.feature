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
#   apps/desktop-qt/src/native/WorkspaceController.cpp (a new thread's checkout, the previous worktree)
#   apps/server/src/vcs/GitVcsDriverCore.ts (renameBranch, resolveAvailableBranchName)
#   apps/server/src/vcs/GitVcsDriverCore.ts (createWorktree: checkout progress, timeouts, base ref, folder name)
#   apps/server/src/project/ProjectSetupScriptRunner.ts, WorktreeSetupTracker.ts (output cleaning and caps)

Feature: Worktrees and setup scripts
  A thread can start in its own worktree. The MC creates it from a base ref, runs the
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

  @tui @mobile @backlog-mobile
  Scenario: Choosing a new worktree from the terminal client and phone
    When the user starts a thread in a new worktree of "shop"
    Then the thread starts in a worktree of its own

  @desktop @mobile @backlog-mobile
  Scenario: Picking the base ref for a new worktree
    When the user starts a thread in a new worktree based on "release/2"
    Then the worktree starts from "release/2"

  @mc
  Scenario: A new worktree is made under the HAL-C2 home by default
    When a worktree is created for the branch "feature/tax" with no path given
    Then it is made in the HAL-C2 home's worktrees folder under the repository and branch names

  @mc
  Scenario: Starting from origin fetches the base first
    Given the project starts worktrees from origin and "shop" has the remote "origin"
    When the user sends the first message of a thread in a new worktree
    Then the fetch stage runs before the files are checked out

  @mc
  Scenario: Without a remote the fetch stage is skipped
    Given "shop" has no remote
    When the user sends the first message of a thread in a new worktree
    Then the fetch stage is reported as skipped

  @mc
  Scenario: The temporary branch is renamed from the first message
    When the user sends "Add tax to the cart" as the first message of a thread in a new worktree
    Then the worktree first sits on a temporary branch
    And the branch is renamed to a name the writer model derives from the message

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (resolveAvailableBranchName, renameBranch)
  @mc @backlog
  Scenario: A renamed temporary branch whose new name is taken gets a number
    Given the branch "feature/add-tax" already exists
    When the temporary branch of a new worktree is renamed to "feature/add-tax"
    Then the worktree's branch is "feature/add-tax-1"

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (resolveAvailableBranchName: 100 candidates)
  @mc @backlog
  Scenario: A rename that finds no free name fails and keeps the temporary branch
    Given "feature/add-tax" and the hundred numbered names after it already exist
    When the temporary branch of a new worktree is renamed to "feature/add-tax"
    Then the user is told no available branch name could be found for "feature/add-tax"
    And the worktree stays on its temporary branch

  @mc
  Scenario: A client that names the temporary branch itself gets it renamed too
    Given the client names the new worktree's temporary branch "hal-c2/42a5d641"
    When the user sends "Add tax to the cart" as the first message of a thread in a new worktree
    Then the worktree first sits on the temporary branch "hal-c2/42a5d641"
    And the branch is renamed to a name the writer model derives from the message

  @mc
  Scenario: A branch named "hal-c2" does not stop a new worktree
    Given "shop" has a branch named "hal-c2"
    When the user sends the first message of a thread in a new worktree
    Then the worktree is made on a temporary branch beside "hal-c2"

  @mc
  Scenario Outline: Setup reports each stage as it runs
    When the user sends the first message of a thread in a new worktree
    Then the setup reports the stage "<stage>" with its status

    Examples:
      | stage              |
      | Fetch base branch  |
      | Check out files    |
      | Run setup script   |
      | Start agent        |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (createWorktree: onCheckoutProgress, parseGitCheckoutProgressLine)
  @mc @backlog
  Scenario: Checking out a large worktree reports how far it is
    Given "shop" is large enough that checking out its files takes a while
    When the user sends the first message of a thread in a new worktree
    Then the "Check out files" stage reports the share of files checked out as it grows
    And the stage ends at its full share when the checkout finishes

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (WORKTREE_ADD_TIMEOUT_MS, WORKTREE_REMOVE_TIMEOUT_MS)
  @mc @backlog
  Scenario Outline: Creating and removing a worktree is given minutes, not seconds
    Given "shop" is so large that <action> takes <duration>
    When the user <request>
    Then the git command is not stopped by the usual 30 second limit
    And it is stopped only after 5 minutes

    Examples:
      | action                | duration       | request                                              |
      | checking out files    | 2 minutes      | sends the first message of a thread in a new worktree |
      | removing the worktree | 2 minutes      | removes the worktree                                  |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (createWorktree: gh-merge-base)
  @mc @backlog
  Scenario: A new worktree's branch remembers the branch it started from
    Given a worktree is created for the new branch "feature/tax" based on "origin/dev"
    When the pull request for "feature/tax" is created
    Then it targets "dev"

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (createWorktree: sanitizedBranch)
  @mc @backlog
  Scenario: A branch with slashes gets a single folder name
    When a worktree is created for the branch "feature/tax/rates" with no path given
    Then its folder under the repository's name is "feature-tax-rates"

  @mc
  Scenario: Submodule initialization is its own setup stage
    Given "shop" has submodules
    When the user sends the first message of a thread in a new worktree
    Then the setup reports the stage "Init submodules" with its status

  @mc
  Scenario Outline: Submodules follow the project's setting
    Given "shop" has nested submodules and the worktree submodules setting is <setting>
    When a worktree is created
    Then <result>

    Examples:
      | setting        | result                                                  |
      | recursive      | every submodule is initialized, nested ones included    |
      | top level only | only the top level submodules are initialized           |
      | skip           | no submodule is initialized                             |

  @mc
  Scenario: The setup script runs in the setup terminal
    Given "shop" has a setup script set to run when a worktree is created
    When the user sends the first message of a thread in a new worktree
    Then the script runs in the thread's "setup" terminal inside the new worktree

  # files/project-scripts-and-actions.feature holds a project without a setup script
  # skipping that stage.
  @mc
  Scenario: The setup script's latest output is shown while it runs
    Given "shop" has a setup script that prints many lines
    When the user sends the first message of a thread in a new worktree
    Then the setup script stage shows the last 5 lines of its output as it runs

  # Legacy: apps/server/src/project/ProjectSetupScriptRunner.ts (stripTerminalControl, OUTPUT_LINE_MAX_LENGTH), WorktreeSetupTracker.ts
  @mc @backlog
  Scenario Outline: Setup script output is shown as plain, short lines
    Given "shop" has a setup script that prints <output>
    When the user sends the first message of a thread in a new worktree
    Then the setup script stage shows <shown>

    Examples:
      | output                                                  | shown                                         |
      | colored text and cursor movements                       | the same text without the colors and movement |
      | a progress bar that redraws one line with carriage returns | each redraw as a line of its own           |
      | a single line of 1,000 characters                       | the first 400 characters of it                |
      | output that never ends a line                           | no more than the last few thousand characters kept in memory |

  # Legacy: apps/server/src/project/ProjectSetupScriptRunner.ts (wrapCommandForCompletion, completionSentinel)
  @mc @backlog
  Scenario Outline: The end of a setup script is noticed however the script is written
    Given "shop" has a setup script that <script>
    When the user sends the first message of a thread in a new worktree
    Then the setup script stage ends with the script's own exit status
    And nothing the script printed is taken for its end

    Examples:
      | script                                          |
      | ends with a comment line                        |
      | reads from its input until it is closed         |
      | prints a line that looks like a completion mark |
      | is a few lines long with a here-document        |

  # Legacy: apps/server/src/project/ProjectSetupScriptRunner.ts (observeTerminalCompletion), ThreadLaunchService.ts
  @mc @backlog
  Scenario: A setup terminal that is closed before the script finishes fails the setup script
    Given the setup script must finish before the agent starts
    And its terminal is closed while it is still running
    When the setup stops waiting for it
    Then the setup fails with "Setup script exited with no exit code."
    And the agent does not start

  # Legacy: apps/server/src/project/ProjectSetupScriptRunner.ts (runForThread env: COLORTERM, NO_COLOR, FORCE_COLOR)
  # Other terminals advertise truecolour (terminal/sessions.feature). The MC already sets
  # NO_COLOR for the setup terminal (worktree_setup.ex) but still gives it COLORTERM "truecolor".
  @mc @backlog
  Scenario: A setup script's terminal, unlike the user's terminals, does not advertise colour
    Given "shop" has a setup script set to run when a worktree is created
    When the user sends the first message of a thread in a new worktree
    Then the script's terminal asks tools for plain output without colour
    And a tool that probes the terminal for truecolour does not wait for an answer

  # Legacy: apps/server/src/project/WorktreeSetupTracker.ts (clampText), packages/contracts/src/worktreeSetup.ts
  @mc @backlog
  Scenario Outline: A long setup detail or error is shortened before clients see it
    Given a setup stage reports a <kind> of 5,000 characters
    When a client reads the setup
    Then the <kind> is cut to <limit> characters and ends with an ellipsis

    Examples:
      | kind   | limit |
      | detail | 200   |
      | error  | 1,000 |

  @mc
  Scenario: A failing setup script that must finish first fails the setup
    Given the setup script must finish before the agent starts and it exits with 3
    When the user sends the first message of a thread in a new worktree
    Then the setup fails with "Setup script exited with 3."
    And the agent does not start

  @mc
  Scenario: A failing background setup script does not stop the agent
    Given the setup script runs in the background and it exits with 3
    When the user sends the first message of a thread in a new worktree
    Then the setup script stage is reported as failed
    And the agent still starts

  @mc
  Scenario: A worktree that cannot be created fails the setup
    Given the branch cannot be checked out into a new worktree
    When the user sends the first message of a thread in a new worktree
    Then the setup fails with a message starting "Could not create the worktree:"

  @mc
  Scenario: Cancelling setup before the agent starts
    Given a thread's worktree setup is still checking out files
    When the user cancels the setup
    Then the worktree is removed
    And the thread no longer points at a worktree
    And the setup is reported as cancelled

  @mc
  Scenario: Setup cannot be cancelled once the agent is starting
    Given a thread's worktree setup has reached the agent stage
    When the user cancels the setup
    Then the setup is not cancelled
    And the worktree stays

  @mc
  Scenario: An agent that cannot start fails the setup
    Given a thread's worktree is ready and its setup script finished
    And the thread's run cannot be released to the agent
    When the setup reaches the agent stage
    Then the setup fails with a message starting "The agent could not start:"

  @mc
  Scenario: A client that reconnects sees the setup where it is now
    Given a thread's worktree setup is running the setup script
    When the user's client drops and reconnects
    Then it receives the setup's current stages, not a replay

  @mc
  Scenario: Setup progress does not outlive the MC
    Given a thread's worktree setup finished
    When the MC restarts
    Then no setup progress is shown for that thread

  # Legacy: apps/server/src/project/WorktreeSetupTracker.ts (finish, FINISHED_RETENTION)
  @mc @backlog
  Scenario Outline: A stage still running when the setup ends is settled with it
    Given a thread's worktree setup is running a stage
    When the setup <ending>
    Then that stage is reported as "<status>"
    And stages that never started are left as they were

    Examples:
      | ending         | status  |
      | finishes       | done    |
      | fails          | failed  |
      | is cancelled   | skipped |

  # Legacy: apps/server/src/project/WorktreeSetupTracker.ts (FINISHED_RETENTION, begin)
  @mc @backlog
  Scenario: A finished setup stays readable for half a minute and a new one replaces it
    Given a thread's worktree setup finished
    When a client reads the setup 20 seconds later
    Then it sees the finished setup with its outcome
    When the thread starts another worktree setup
    Then clients see only the new setup from its first stage on

  @desktop @mobile @backlog-mobile
  Scenario: The setup card shows the base, branch and path
    When the user sends the first message of a thread in a new worktree
    Then the thread shows the worktree's base, branch and path with the stages
    And it reads "Worktree ready" once the agent starts

  @mc
  Scenario: Removing a worktree
    Given "feature/tax" has a worktree with no changes
    When the user removes that worktree
    Then its folder is gone and git no longer lists it

  @mc
  Scenario: Removing a worktree whose folder was already deleted
    Given the folder of the "feature/tax" worktree was deleted by hand
    When the user removes that worktree
    Then git forgets it without an error

  @mc
  Scenario: Forcing removal of a worktree with changes
    Given the "feature/tax" worktree has uncommitted changes
    When the user removes that worktree with force
    Then its folder is gone

  @desktop @mobile @backlog-mobile
  Scenario: Returning to the previous worktree
    Given the user just finished a thread in the worktree on "feature/tax"
    When the user starts a new thread in "shop"
    Then the user can pick the previous worktree on "feature/tax" for it

  @mc
  Scenario: The agent moves its thread into a new worktree
    Given the agent works in "shop" without a worktree
    When the agent hands the thread off to a new worktree on "feature/pay" with a continuation prompt
    Then the worktree is created and the thread points at it
    And the setup script is started
    And the agent continues in the worktree with the prompt

  @mc
  Scenario: A thread already in a worktree cannot be handed off again
    Given the thread already works in a worktree
    When the agent hands the thread off to a new worktree
    Then the handoff is refused as already in a worktree

  @mc
  Scenario: The agent asks where its thread is working
    Given the thread works in the worktree on "feature/tax"
    When the agent asks for its worktree status
    Then it learns it is attached, with the worktree path, branch and project root

  @backlog @desktop
  Scenario Outline: The workspace choice is named for what it is
    Given the user is writing the first message of a new thread in "shop" <where>
    When the user opens the workspace choice
    Then the choices are "<project>" and "New worktree"

    Examples:
      | where                      | project           |
      | in the project folder      | Current checkout  |
      | in an existing worktree    | Current worktree  |

  @backlog @desktop
  Scenario Outline: A thread that has started keeps its workspace
    Given a thread in "shop" has started <where>
    When the user looks at the thread's workspace
    Then it reads "<label>" and cannot be changed

    Examples:
      | where                     | label           |
      | in the project folder     | Local checkout  |
      | in a worktree             | Worktree        |

  @backlog @desktop
  Scenario: Several chosen models always get a worktree each
    Given the user chose two models for a new thread in "shop"
    When the user looks at the workspace choice
    Then it reads "New worktree" and cannot be changed
    And it says each model starts in its own worktree

  @backlog @desktop
  Scenario: The previous worktree is named after its branch
    Given the most recently used worktree of "shop" is on "feature/tax"
    When the user opens the workspace choice of a new thread
    Then it offers "Previous worktree (feature/tax)"

  @backlog @desktop
  Scenario: A previous worktree with no branch is just called the previous worktree
    Given the most recently used worktree of "shop" is on no branch
    When the user opens the workspace choice of a new thread
    Then it offers "Previous worktree"

  @backlog @desktop
  Scenario Outline: Some worktrees are not offered as the previous worktree
    Given the most recently used worktree of "shop" <situation>
    And an older thread in "shop" used another worktree
    When the user opens the workspace choice of a new thread
    Then the other worktree is offered as the previous worktree

    Examples:
      | situation                                          |
      | is the worktree the new thread is already in       |
      | belongs only to an archived thread                 |

  @backlog @desktop
  Scenario: No previous worktree is offered when there is none
    Given no thread in "shop" has used a worktree
    When the user opens the workspace choice of a new thread
    Then the choices are the current checkout and a new worktree only

  @backlog @desktop
  Scenario: The base of a new worktree can be started from origin
    Given the user chose a new worktree for a new thread in "shop"
    When the user opens the base picker
    Then it offers "Start from origin" with a switch for starting the worktree from origin
    And it explains this creates the worktree from the latest matching branch on origin instead of the local branch

  @backlog @desktop
  Scenario: The choice to start from origin belongs to the new thread
    Given "Start new worktrees from origin" is off in the settings
    When the user turns on "Start from origin" in a new thread's base picker
    Then that thread's worktree starts from origin
    And the setting stays off
