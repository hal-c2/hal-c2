# Sources:
#   docs/user/source-control.md
#   docs/internals/consistency-action-names.md
#   apps/web/src/components/GitActionsControl.logic.ts (buildMenuItems, resolveQuickAction)
#   apps/web/src/components/GitActionsControl.tsx
#   apps/web/src/shell/ShellGitBridge.tsx
#   packages/contracts/src/shell.ts (ShellGitState, git.quick, git.menu, git.refresh, git.publish)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml
#   apps/desktop-qt/src/native/GitController.cpp (the desktop's recommended action and menu, results, init)
#   apps/server-ex/lib/hal_c2/vcs.ex (vcs.init)
#   apps/server-ex/lib/hal_c2/web/socket.ex (the error while a cluster member is offline)
#   apps/tui/src/gitActions.logic.ts (resolveGitQuickAction, buildGitMenuItems, buildGitPanelActions)
#   apps/tui/src/components/RightPanel.tsx

Feature: Recommended git action and the git menu
  Next to every thread sits one recommended git action for the state the checkout is in,
  plus a menu with commit, push and pull request, each explaining why it is unavailable.

  Background:
    Given a connected environment with a thread in the git project "shop"

  @desktop @tui
  Scenario Outline: The recommended action follows the checkout
    Given the checkout <state>
    When the user looks at the thread's git actions
    Then the recommended action is "<action>"

    Examples:
      | state                                                          | action            |
      | has uncommitted changes and no remote                          | Commit            |
      | has uncommitted changes on the default branch                  | Commit & push     |
      | has uncommitted changes on a branch with an open pull request  | Commit & push     |
      | has uncommitted changes on a feature branch with a remote      | Commit, push & PR |
      | has commits on a feature branch with no upstream               | Push & create PR  |
      | is behind its upstream                                         | Pull              |
      | is ahead of its upstream with an open pull request             | Push              |
      | is pushed and ahead of the default branch with no pull request | Create PR         |
      | is up to date with an open pull request                        | View PR           |

  @desktop @tui
  Scenario Outline: The recommended action is withheld with a reason
    Given the checkout <state>
    When the user looks at the thread's git actions
    Then the recommended action is unavailable
    And the reason given is "<reason>"

    Examples:
      | state                                    | reason                                                  |
      | is running another git action            | Git action in progress.                                 |
      | has no status yet                        | Git status is unavailable.                              |
      | has diverged from its upstream           | Branch has diverged from upstream. Rebase/merge first.  |
      | is up to date with nothing to do         | Branch is up to date. No action needed.                 |
      | has no upstream and no local commits     | No local commits to push.                               |

  @desktop @tui
  Scenario: A detached checkout only allows committing
    Given the checkout is on a detached HEAD with changes
    When the user looks at the thread's git actions
    Then pushing and opening a pull request are unavailable
    And the user is told to create and check out a branch first

  @desktop
  Scenario: A repository without a remote recommends publishing it
    Given the checkout has commits and no remote
    When the user looks at the thread's git actions
    Then the recommended action is "Publish repository"
    And the git menu offers only committing and publishing

  @tui
  Scenario: Publishing a repository from the terminal client
    Given the checkout has commits and no remote
    When the user publishes the repository from the terminal client
    Then the terminal client guides provider, repository, visibility and protocol in place

  @tui
  Scenario: Publishing is explained as unavailable in the terminal client
    Given the checkout has commits and no remote
    When the user looks at the thread's git actions in the terminal client
    Then publishing is unavailable
    And the reason given is "Repository publishing is not available in the TUI yet."

  @desktop @tui
  Scenario Outline: A menu entry that cannot run says why
    Given the checkout <state>
    When the user opens the git menu
    Then "<entry>" is unavailable because "<reason>"

    Examples:
      | state                                     | entry     | reason                                |
      | has no uncommitted changes                | Commit    | No uncommitted changes.               |
      | is behind its upstream                    | Push      | Pull or rebase before pushing.        |
      | is behind its upstream                    | Create PR | Pull or rebase before creating a PR.  |
      | has uncommitted changes                   | Create PR | Commit changes before creating a PR.  |

  @desktop @tui
  Scenario: Opening the pull request of the branch
    Given the checkout's branch has an open pull request
    When the user chooses to view the pull request
    Then the pull request opens on its host

  @tui
  Scenario: The terminal client copies the pull request link
    Given the checkout's branch has an open pull request
    When the user activates "View PR" with the keyboard in the terminal client
    Then the pull request link is copied

  @desktop
  Scenario: Opening the git menu refreshes status
    Given the checkout changed outside HAL-C2 a moment ago
    When the user opens the git menu
    Then the menu reflects the checkout as it is now

  @desktop @mobile @tui @backlog-mobile
  Scenario Outline: The actions use the host's own name for a pull request
    Given the project's primary remote is on <host>
    When the user opens the git menu
    Then the pull request entry is called "<name>"

    Examples:
      | host   | name                 |
      | GitHub | Create PR            |
      | GitLab | Create MR            |

  @backlog @mobile
  Scenario: Running the recommended action from the phone
    Given the checkout has uncommitted changes on a feature branch with a remote
    When the user runs the recommended git action from the phone
    Then the changes are committed, pushed and a pull request is opened

  @desktop
  Scenario: A new pull request can be viewed from its result
    Given the checkout has uncommitted changes on a feature branch with a remote
    When the user runs the recommended action
    And the user chooses "View PR" on the toast "Created PR #42"
    Then the browser opens "https://github.com/acme/shop/pull/42"

  @desktop
  Scenario: An action with nothing to do says why
    Given the checkout is up to date with nothing to do
    When the user runs the recommended action
    Then the user sees an "info" toast "Commit" saying "Branch is up to date. No action needed."

  @desktop
  Scenario: Initializing Git
    Given the checkout is not a repository
    And the git actions offer to initialize Git
    When the user initializes Git
    Then the checkout is a repository

  @desktop
  Scenario: A refused initialization is reported
    Given the checkout is not a repository
    And the MC refuses to initialize Git with "Permission denied"
    When the user initializes Git
    Then the user sees an "error" toast "Git initialization failed" saying "Permission denied"

  @desktop
  Scenario: A machine that is offline says why its git actions cannot run
    Given the MC is clustered with "mc-c", which serves "env-c"
    And "env-c" has the thread "t7" titled "Deploy" in "shop" on the branch "feature/tax"
    And "env-c" becomes unreachable
    When the user goes to "env-c:t7"
    Then the git actions say "MC unavailable: noconnection"
    When "env-c" is reachable again
    Then the git actions are available again

  Rule: Publishing a repository without a remote

    Background:
      Given the checkout has commits and no remote

    @desktop
    Scenario: Publishing pushes the branch to the new repository
      When the user runs the recommended action
      Then the publish dialog is open
      When the user publishes "acme/shop" as a private GitHub repository
      Then the MC published "acme/shop" to "origin" as private on github
      And the publish dialog is closed
      And the user sees a "success" toast "Published acme/shop" saying "Pushed feature/tax to origin."
      When the user chooses "Open repository" on the toast "Published acme/shop"
      Then the browser opens "https://github.com/acme/shop"

    @desktop
    Scenario: A refused publish keeps the dialog open with the reason
      Given the MC refuses to publish with "Repository already exists"
      When the user runs the recommended action
      And the user publishes "acme/shop" as a public GitHub repository
      Then the publish dialog says "Repository already exists"

    @desktop
    Scenario: A repository name needs its owner
      When the user runs the recommended action
      And the user publishes "shop" as a private GitHub repository
      Then the publish dialog says "Name the repository as owner/name."
      And nothing is published

    @desktop
    Scenario: Cancelling the dialog publishes nothing
      When the user runs the recommended action
      And the user cancels publishing
      Then the publish dialog is closed
      And nothing is published
