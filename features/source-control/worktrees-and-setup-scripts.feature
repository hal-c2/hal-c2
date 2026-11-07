# Sources:
#   https://github.com/pingdotgg/t3code/pull/15833
#   https://github.com/pingdotgg/t3code/pull/21032
#   https://github.com/pingdotgg/t3code/pull/11773
#   https://github.com/pingdotgg/t3code/pull/19411
#   https://github.com/pingdotgg/t3code/pull/14917
#   https://github.com/pingdotgg/t3code/pull/20079
#   https://github.com/pingdotgg/t3code/pull/15594
#   https://github.com/pingdotgg/t3code/pull/16167
#   https://github.com/pingdotgg/t3code/pull/16220
#   https://github.com/pingdotgg/t3code/pull/16231
#   https://github.com/pingdotgg/t3code/pull/13314
#   https://github.com/pingdotgg/t3code/pull/21099
#   https://github.com/pingdotgg/t3code/pull/18359
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

  @tui @mobile
  Scenario: Choosing a new worktree from the terminal client and phone
    When the user starts a thread in a new worktree of "shop"
    Then the thread starts in a worktree of its own

  @desktop @mobile
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

  # Upstream #21032: a new worktree fetched origin even when its base branch tracks another
  # remote; it now fetches the base's own upstream, and a base that tracks nothing still uses origin.
  @backlog @mc
  Scenario: A new worktree starts from the remote its base branch tracks
    Given the project starts worktrees from origin and "shop" has the remotes "origin" and "upstream"
    And the base branch "main" tracks "upstream/main"
    When the user sends the first message of a thread in a new worktree from "main"
    Then "upstream/main" is fetched and the worktree starts from it

  # Upstream #21032: a base whose remote branch was deleted starts from the local branch.
  @backlog @mc @priority-low
  Scenario: A base whose remote branch is gone starts from the local branch
    Given the project starts worktrees from origin
    And the base branch "feature/tax" tracks a remote branch that was deleted
    When the user sends the first message of a thread in a new worktree from "feature/tax"
    Then the worktree starts from the local "feature/tax"
    And no stale remote-tracking ref is used

  @backlog @mc
  Scenario: A fetch that loses a ref race with another fetch is tried again
    Given the project starts worktrees from origin
    And a background fetch of "origin" holds "origin/main" while the worktree's fetch runs
    When git reports it could not update "refs/remotes/origin/main"
    Then the worktree's fetch is tried once more and the worktree is made
    And a lock failure that persists tells the user a local reference could not be updated

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
  @mc
  Scenario: A renamed temporary branch whose new name is taken gets a number
    Given the branch "feature/add-tax" already exists
    When the temporary branch of a new worktree is renamed to "feature/add-tax"
    Then the worktree's branch is "feature/add-tax-1"

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (resolveAvailableBranchName: 100 candidates)
  @mc
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

  @mc @backlog @priority-low
  Scenario: Subagents made before the temporary branch is renamed pick up the new name
    Given a thread in a new worktree delegated to two subagents while the worktree was on its temporary branch
    And one of the subagent threads is archived
    When the temporary branch is renamed to "feature/add-tax"
    Then the thread and both subagent threads record the branch "feature/add-tax"

  @mc @backlog @priority-low
  Scenario: A thread that moved off the worktree keeps its branch when the temporary branch is renamed
    Given a subagent recorded the new worktree's temporary branch
    And it was moved to another worktree before the rename
    When the temporary branch is renamed to "feature/add-tax"
    Then the subagent keeps the branch of the worktree it moved to

  @mc @backlog @priority-low
  Scenario: A provider's own subagent made on the temporary branch records the worktree's current branch
    Given the temporary branch of a new worktree was renamed to "feature/add-tax"
    When the provider starts its own subagent carrying the temporary branch from the turn's start
    Then the subagent thread records the branch "feature/add-tax" read from git

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
  @mc
  Scenario: Checking out a large worktree reports how far it is
    Given "shop" is large enough that checking out its files takes a while
    When the user sends the first message of a thread in a new worktree
    Then the "Check out files" stage reports the share of files checked out as it grows
    And the stage ends at its full share when the checkout finishes

  @mc
  Scenario: A checkout stopped by the time limit leaves nothing behind
    Given git hangs on "shop" once its new worktree is made
    When the user sends the first message of a thread in a new worktree
    Then the setup fails when the limit stops git
    And neither the worktree nor its new branch is left in "shop"

  @mc
  Scenario: A checkout stopped while it is filling the worktree leaves nothing behind
    Given git is stopped on "shop" while it is still filling its new worktree
    When the user sends the first message of a thread in a new worktree
    Then the setup fails when the limit stops git
    And nothing is still writing where the worktree was
    And neither the worktree nor its new branch is left in "shop"

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (WORKTREE_ADD_TIMEOUT_MS, WORKTREE_REMOVE_TIMEOUT_MS)
  @mc
  Scenario Outline: Creating and removing a worktree is given minutes, not seconds
    Given "shop" is so large that <action> takes <duration>
    When the user <request>
    Then the git command is not stopped by the usual 30 second limit
    And it is stopped only after 5 minutes

    Examples:
      | action                | duration       | request                                              |
      | checking out files    | 2 minutes      | sends the first message of a thread in a new worktree |
      | removing the worktree | 2 minutes      | removes the worktree                                  |

  # Upstream #14917: Git for Windows refuses paths over 260 characters unless core.longpaths is
  # set, and a removal that fails partway strands the folder where nothing cleans it up.
  @backlog @mc @priority-low
  Scenario Outline: A worktree with long paths works on Windows whatever Git's long-path setting
    Given the MC runs on Windows and Git's long-path setting is <setting>
    And "shop" tracks a file whose path in the worktree is longer than 260 characters
    When the user <request>
    Then it succeeds
    And the user's Git configuration is unchanged

    Examples:
      | setting       | request                                               |
      | not set       | sends the first message of a thread in a new worktree |
      | not set       | removes the worktree                                  |
      | set to false  | removes the worktree                                  |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (createWorktree: gh-merge-base)
  @mc
  Scenario: A new worktree's branch remembers the branch it started from
    Given a worktree is created for the new branch "feature/tax" based on "origin/dev"
    When the pull request for "feature/tax" is created
    Then it targets "dev"

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (createWorktree: sanitizedBranch)
  @mc
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
  @mc
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
  @mc
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
      | has a syntax error on its last line             |

  # Legacy: apps/server/src/project/ProjectSetupScriptRunner.ts (observeTerminalCompletion), ThreadLaunchService.ts
  @mc
  Scenario: A setup terminal that is closed before the script finishes fails the setup script
    Given a setup script that must finish before the agent starts
    And its terminal is closed while it is still running
    When the setup stops waiting for it
    Then the setup fails with "Setup script exited with no exit code."
    And the agent does not start

  # The script is the shell's argument, as a line typed into a starting shell can be
  # read by whatever its startup runs.
  @mc
  Scenario: A shell startup that reads its input does not swallow the setup script
    Given a blocking setup script that writes a file
    And the shell's startup reads whatever is waiting on its input
    When the thread's worktree is prepared
    Then the setup finishes and the script wrote its file

  @mc
  Scenario: A setup script that never begins fails the setup
    Given a blocking setup script that writes a file
    And the shell's startup never finishes
    When the thread's worktree is prepared
    Then the setup fails with a message starting "The setup script did not start within"
    And the setup script stage says it did not start
    And the agent does not start
    And the setup can no longer begin behind the failure

  @mc
  Scenario: A background setup script that never begins does not stop the agent
    Given a background setup script that writes a file
    And the shell's startup never finishes
    When the thread's worktree is prepared
    Then the setup script stage says it did not start
    And the agent starts on the first message

  @mc
  Scenario: A setup script that has begun may take as long as it needs
    Given a setup script that must finish before the agent starts
    And a setup script has 3 seconds to begin
    When the thread's worktree is prepared
    And the script is still running after those 3 seconds
    Then the setup is still running

  @mc
  Scenario: Retrying a failed setup runs its script again in the same worktree
    Given a blocking setup script that fails until a file exists
    And the thread's setup failed on that script
    When the file exists and the user retries the setup
    Then the setup finishes in the same worktree
    And the conversation no longer shows the failure
    And the agent starts on the first message

  @mc
  Scenario: A thread that went on without its setup cannot retry it
    Given a blocking setup script that fails until a file exists
    And the thread's setup failed on that script
    When the user sends another message in that thread
    Then the setup is no longer tracked
    And retrying the setup is refused

  # Legacy: apps/server/src/project/ProjectSetupScriptRunner.ts (runForThread env: COLORTERM, NO_COLOR, FORCE_COLOR)
  # Other terminals advertise truecolour (terminal/sessions.feature). The MC already sets
  # NO_COLOR for the setup terminal (worktree_setup.ex) but still gives it COLORTERM "truecolor".
  @mc
  Scenario: A setup script's terminal, unlike the user's terminals, does not advertise colour
    Given "shop" has a setup script set to run when a worktree is created
    When the user sends the first message of a thread in a new worktree
    Then the script's terminal asks tools for plain output without colour
    And a tool that probes the terminal for truecolour does not wait for an answer

  # Legacy: apps/server/src/project/WorktreeSetupTracker.ts (clampText), packages/contracts/src/worktreeSetup.ts
  @mc
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
  Scenario: A checkout that fails partway leaves no branch behind
    Given the checkout of a new worktree in "shop" fails partway
    When the user sends the first message of a thread in a new worktree
    Then the setup fails with a message starting "Could not create the worktree:"
    And neither the worktree nor its new branch is left in "shop"

  # Upstream #11773: writing the new branch's base into git's config is optional; a locked config
  # no longer fails a worktree git already made.
  @mc @backlog
  Scenario: A locked git config does not fail a worktree git has made
    Given another program holds the lock on the git config of "shop"
    When the user sends the first message of a thread in a new worktree
    Then the thread starts in the new worktree
    And the branch's base is taken from the default branch when it is needed

  @mc
  Scenario: Cancelling setup before the agent starts
    Given a thread's worktree setup is still checking out files
    When the user cancels the setup
    Then what the checkout started is no longer running
    And the worktree is removed
    And neither the worktree nor its new branch is left in "shop"
    And the thread no longer points at a worktree
    And the setup is reported as cancelled

  @mc
  Scenario: Cancelling setup after its branch was named takes the named branch
    Given a thread's worktree setup is running its script after its branch was named
    When the user cancels the setup
    Then the branch "claude-branch" is not left in "shop"
    And neither the worktree nor its new branch is left in "shop"

  @mc
  Scenario: Cancelling setup just as its branch is renamed takes the named branch
    Given a thread's worktree setup has renamed its branch and not yet said so
    When the user cancels the setup
    Then the branch "claude-branch" is not left in "shop"
    And neither the worktree nor its new branch is left in "shop"

  @mc
  Scenario: Cancelling setup keeps a branch its script switched to
    Given a thread's setup script has switched its worktree to the branch "kept"
    When the user cancels the setup
    Then the branch "kept" is still in "shop"
    And neither the worktree nor its new branch is left in "shop"

  @mc
  Scenario: Cancelling setup while its branch is being named
    Given a thread's worktree setup is running its script while its branch is being named
    When the user cancels the setup
    Then the branch is no longer being named
    And neither the worktree nor its new branch is left in "shop"
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
  @mc
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
  @mc
  Scenario: A finished setup stays readable for half a minute and a new one replaces it
    Given a thread's worktree setup finished
    When a client reads the setup 20 seconds later
    Then it sees the finished setup with its outcome
    When the thread starts another worktree setup
    Then clients see only the new setup from its first stage on

  @desktop @mobile
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

  # Upstream #15833: on Windows git can leave junctions behind after removing a worktree, and
  # they blocked making it again.
  @backlog @mc @priority-low
  Scenario: A worktree removed on Windows can be made again
    Given the MC runs on Windows and "feature/tax" has a worktree
    When the user removes that worktree
    Then no leftover links or empty folders remain where it was
    And a new worktree for "feature/tax" can be made in the same place
    And files found there are kept

  # Upstream #21099: removing a worktree on Windows followed its junctions and deleted what they
  # pointed to.
  @backlog @mc @priority-high
  Scenario: Removing a worktree on Windows never deletes what its links point to
    Given the MC runs on Windows and the "feature/tax" worktree holds a junction to a folder outside it
    When the user removes that worktree
    Then the folder the junction pointed to and its files are untouched

  # Upstream #21099: the cleanup keeps git's refusals.
  @backlog @mc @priority-high
  Scenario Outline: A worktree git refuses to remove on Windows is kept
    Given the MC runs on Windows and the "feature/tax" worktree <state>
    When the user removes that worktree without force
    Then the removal is refused and the worktree's files are kept

    Examples:
      | state                         |
      | is locked                     |
      | has uncommitted changes       |
      | has a populated submodule     |

  @desktop @mobile
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
  Scenario: A cloned repository's setup script waits until imported during agent handoff
    Given the agent works in "shop" without a worktree, and its hal-c2.json marks the setup script
    When the agent hands the thread off to a new worktree on "feature/pay" with a continuation prompt
    Then the handoff skips the setup script until it is imported

  @mc
  Scenario: The agent's new worktree waits for a branch's changed setup script to be imported
    Given the agent works in "shop" without a worktree, and its hal-c2.json marks the setup script
    And the branch "contrib" changes the setup script's command
    When the agent hands the thread off to a new worktree of "contrib"
    Then the handoff skips the setup script until it is imported

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

  @desktop
  Scenario Outline: The workspace choice is named for what it is
    Given the user is writing the first message of a new thread in "shop" <where>
    When the user opens the workspace choice
    Then the choices are "<project>" and "New worktree"

    Examples:
      | where                      | project           |
      | in the project folder      | Current checkout  |
      | in an existing worktree    | Current worktree  |

  @desktop
  Scenario Outline: A thread that has started keeps its workspace
    Given a thread in "shop" has started <where>
    When the user looks at the thread's workspace
    Then it reads "<label>" and cannot be changed

    Examples:
      | where                     | label           |
      | in the project folder     | Local checkout  |
      | in a worktree             | Worktree        |

  @desktop
  Scenario: Several chosen models always get a worktree each
    Given the user chose two models for a new thread in "shop"
    When the user looks at the workspace choice
    Then it reads "New worktree" and cannot be changed
    And it says each model starts in its own worktree

  @desktop
  Scenario: The previous worktree is named after its branch
    Given the most recently used worktree of "shop" is on "feature/tax"
    When the user opens the workspace choice of a new thread
    Then it offers "Previous worktree (feature/tax)"

  @desktop
  Scenario: A previous worktree with no branch is just called the previous worktree
    Given the most recently used worktree of "shop" is on no branch
    When the user opens the workspace choice of a new thread
    Then it offers "Previous worktree"

  @desktop
  Scenario Outline: Some worktrees are not offered as the previous worktree
    Given the most recently used worktree of "shop" <situation>
    And an older thread in "shop" used another worktree
    When the user opens the workspace choice of a new thread
    Then the other worktree is offered as the previous worktree

    Examples:
      | situation                                          |
      | is the worktree the new thread is already in       |
      | belongs only to an archived thread                 |

  @desktop
  Scenario: No previous worktree is offered when there is none
    Given no thread in "shop" has used a worktree
    When the user opens the workspace choice of a new thread
    Then the choices are the current checkout and a new worktree only

  @desktop
  Scenario: The base of a new worktree can be started from origin
    Given the user chose a new worktree for a new thread in "shop"
    When the user opens the base picker
    Then it offers "Start from origin" with a switch for starting the worktree from origin
    And it explains this creates the worktree from the latest matching branch on origin instead of the local branch

  @desktop
  Scenario: The choice to start from origin belongs to the new thread
    Given "Start new worktrees from origin" is off in the settings
    When the user turns on "Start from origin" in a new thread's base picker
    Then that thread's worktree starts from origin
    And the setting stays off

  @desktop
  Scenario: A new worktree starts as the setting says, and the thread can differ
    Given "Start new worktrees from origin" is on in the settings
    When the user turns off "Start from origin" in a new thread's base picker
    Then that thread's worktree starts from the local branch
    And the setting stays on

  @desktop
  Scenario: A project that starts in a new worktree starts it as the setting says
    Given "Start new worktrees from origin" is on in the settings
    And the project's default workspace is a new worktree
    When the user opens a new thread in "shop"
    Then that thread's worktree starts from origin

  @backlog @mc @priority-low
  Scenario: A new worktree honors the submodule setting
    Given the submodule setting is "skip" and the project has no worktree script of its own
    When a worktree is created
    Then submodules are not initialized

  @backlog @mc @priority-low
  Scenario Outline: A temporary worktree branch gets its name from the prefix
    Given <state>
    When a worktree thread is provisioned
    Then its temporary branch is <branch>
    And the background rename to a generated name still runs for it

    Examples:
      | state                                 | branch           |
      | no branch named after the prefix      | "<prefix>/<hex>" |
      | a local branch named exactly <prefix> | "<prefix>-<hex>" |

  @backlog @mc @shared
  Scenario: The user chooses where new worktrees are created
    Given the worktree location setting holds an absolute path, including on another drive
    When a worktree is created
    Then it is at "<location>/<repo>/<branch>" and existing worktrees stay put
    And a path that is not absolute on the MC fails the creation, pointing to the setting
    And storage cleanup accepts both the default and the custom folder

  # Upstream #18359: a thread whose worktree was deleted could never start another turn.
  @backlog @mc @shared @priority-high
  Scenario Outline: A thread whose worktree was deleted gets it back on its next message
    Given the thread "Fix checkout" worked in its own worktree on "feature/cart"
    And the worktree was deleted and <branch>
    When the user sends the next message
    Then the worktree is made again <from>
    And the turn runs in it

    Examples:
      | branch                         | from                                                          |
      | "feature/cart" still exists    | on "feature/cart"                                             |
      | "feature/cart" was deleted too | with "feature/cart" started from the project's current branch |

  @backlog @mc @shared
  Scenario: A worktree that cannot be made again stops before the agent starts
    Given the thread "Fix checkout" lost its worktree and making it again fails
    When the user sends the next message
    Then the agent is not started
    And the thread says the worktree could not be made, naming the branch and the path, without raw git output
    And the user can send again to retry
