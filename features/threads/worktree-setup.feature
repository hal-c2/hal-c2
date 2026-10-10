# Sources:
#   apps/server-ex/lib/hal_c2/worktree_setup.ex
#   apps/web/src/components/chat/WorktreeSetupCard.tsx
#   packages/contracts/src/rpc.ts (subscribeWorktreeSetup, worktreeSetup.cancel)
#   apps/mobile/src/features/threads/worktree-setup-card.tsx (Work locally, background setup script, output tail)
#   apps/mobile/src/features/threads/worktree-setup-state.ts
#   packages/client-runtime/src/worktreeSetup.ts (which setup the conversation shows)

Feature: Preparing a new thread's worktree
  A thread started in a new worktree waits while the worktree is made and the project's
  setup script runs. The user can watch the steps and cancel before the agent starts.

  Background:
    Given the project "shop" has a setup script
    And the user started the thread "Cart totals" in a new worktree from "main"

  @mc
  Scenario: The worktree is prepared in steps before the agent starts
    When the environment prepares the worktree
    Then it fetches "main" when asked, checks out the worktree and runs the setup script
    And the agent starts only after those steps finish

  @mc
  Scenario: A new worktree starts on a temporary branch that is renamed later
    When the worktree is checked out
    Then it is on a temporary branch
    And the branch is renamed from the first message in the background

  @mc
  Scenario: Clients see each step of the setup as it happens
    Given a client is watching the setup of "Cart totals"
    When the setup moves from checkout to the setup script
    Then the client sees the new step and the last lines of its output

  @mc
  Scenario: Cancelling the setup removes the worktree
    Given the setup script is still running
    When the user cancels the setup
    Then the worktree is removed
    And the thread's first run is cancelled

  @mc
  Scenario: The setup cannot be cancelled once the agent has started
    Given the agent has started working in "Cart totals"
    When the user tries to cancel the setup
    Then the setup is not cancelled

  @mc
  Scenario: Setup progress is not kept across a restart
    Given the worktree for "Cart totals" was prepared
    When the environment restarts
    Then "Cart totals" shows no setup progress

  @mc
  Scenario Outline: A step that is not needed is skipped
    Given <situation>
    When the environment prepares the worktree
    Then the <step> step is shown as skipped
    And the remaining steps still run

    Examples:
      | situation                                         | step         |
      | the user did not ask to start from origin         | fetch        |
      | the project has no "origin" remote                | fetch        |
      | the project has no script to run on new worktrees | setup script |

  @mc
  Scenario: The worktree starts from the local branch when origin lacks it
    Given the user asked to start from origin
    And "origin" has no branch "main"
    When the environment prepares the worktree
    Then the worktree starts from the local "main"

  @mc
  Scenario: A branch the user named is used as is
    Given the user named the branch "feature/cart-totals" for the new worktree
    When the worktree is checked out
    Then it is on "feature/cart-totals"
    And the branch is not renamed later

  @mc
  Scenario: The setup script runs in the thread's setup terminal
    When the setup script starts
    Then it runs in the worktree in a terminal named "setup" on "Cart totals"
    And the user can open that terminal to follow it

  @mc
  Scenario: A setup script that must finish first stops the thread when it fails
    Given the setup script must finish before the agent starts
    When the setup script exits with 1
    Then the setup fails with "Setup script exited with 1."
    And the agent does not start

  @mc
  Scenario: A setup script that runs alongside the agent does not stop it when it fails
    Given the setup script runs alongside the agent
    When the setup script exits with 1 after the agent started
    Then the setup script step is shown as failed with "exited with 1"
    And the agent keeps working in "Cart totals"

  @mc
  Scenario Outline: The setup fails when a step cannot happen
    Given <problem>
    When the environment prepares the worktree
    Then the setup fails with a message starting "<message>"
    And the thread's first run fails

    Examples:
      | problem                            | message                           |
      | the worktree cannot be created     | Could not create the worktree:    |
      | the setup script cannot be started | Could not start the setup script. |
      | the agent cannot be started        | The agent could not start:        |

  @desktop @mobile @backlog-mobile
  Scenario: The user reads the setup details from the conversation
    Given the setup of "Cart totals" failed
    When the user opens the setup details
    Then the user sees why the setup failed and the steps that ran

  @desktop @mobile @backlog-mobile
  Scenario Outline: The conversation shows how the setup is going
    Given the setup of "Cart totals" <state>
    When the user looks at "Cart totals"
    Then the conversation says "<label>"

    Examples:
      | state                                         | label                               |
      | is still running                              | Setting up worktree…                |
      | finished                                      | Worktree ready                      |
      | made the worktree but its setup script failed | Worktree ready, setup script failed |
      | failed                                        | Worktree setup failed               |
      | was cancelled                                 | Worktree setup cancelled            |

  # Legacy: packages/client-runtime/src/worktreeSetup.ts (resolveVisibleWorktreeSetup)
  @backlog @desktop @mobile
  Scenario: A setup that went cleanly leaves the conversation once the agent is replying
    Given the setup of "Cart totals" finished with every step done
    When the agent starts replying in "Cart totals"
    Then the conversation no longer shows the setup
    But a setup that failed, or whose script failed, or that was cancelled, stays shown

  # Legacy: packages/client-runtime/src/worktreeSetup.ts (resolveVisibleWorktreeSetup)
  @backlog @desktop @mobile
  Scenario: The setup is history once the user sends a follow-up
    Given the setup of "Cart totals" failed
    When the user sends another message in "Cart totals"
    Then the conversation no longer shows the setup
    And a setup that is still running is always shown

  # Legacy: packages/client-runtime/src/worktreeSetup.ts (findRecordedWorktreeSetup)
  @backlog @desktop @mobile
  Scenario: A reopened conversation shows the setup the MC recorded
    Given the setup of "Cart totals" is still running
    When the user opens "Cart totals" from another client
    Then that client shows the setup as running
    And follows its steps live until it settles

  @backlog @mobile
  Scenario: The user gives up on the worktree and works in the project folder instead
    Given the setup of "Cart totals" is still running and the agent has not started
    When the user chooses to work locally from the setup details
    Then the setup is cancelled
    And the first message of "Cart totals" is sent again to work in the project folder itself

  @backlog @mobile
  Scenario: A setup script that keeps running after the agent started is still reachable
    Given the agent of "Cart totals" started while the setup script is still running
    Then the conversation says how long the agent has been working
    And the user can open the setup progress by naming the script that is still running

  @backlog @mobile
  Scenario: The setup details show the last lines of the setup script's output
    Given the setup script of "Cart totals" is running or failed
    When the user opens the setup details
    Then the user sees the last few lines of the script's output
