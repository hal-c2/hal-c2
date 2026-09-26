# Sources:
#   apps/tui/src/components/RightPanel.tsx, RightPanel.test.tsx
#   apps/tui/src/gitActions.logic.ts, gitActions.logic.test.ts
#   apps/tui/src/components/ChatView.tsx (onRunGitAction, commit mode, PR link copy)
#   apps/tui/src/components/ChatView.layout.ts (panel replaces the main pane when narrow)
#   apps/tui/src/hooks/useKeyBindings.ts (panel and commit modes)
#   apps/tui/src/features.backlog.test.ts (branch-worktree-management, pull-request-checkout,
#     repository-setup-publishing, git-operation-progress)
#   Shared domain: source-control/ owns git status, refs, worktrees and pull requests.

Feature: Source control from the terminal
  The source-control panel shows where the thread's branch stands and offers the one git
  action that moves it forward, plus commit, push and pull request actions.

  Background:
    Given the terminal client is open on a thread whose workspace is a git repository

  @tui
  Scenario: Ctrl+L opens the source-control panel with focus
    When the user presses "Ctrl+L"
    Then the source-control panel opens with its first action highlighted
    And it shows the branch's sync state and change counts

  @tui
  Scenario: Ctrl+L closes the panel again
    Given the source-control panel is open
    When the user presses "Ctrl+L"
    Then the panel closes

  @tui
  Scenario: Esc on a wide terminal returns to the conversation with the panel still open
    Given the terminal is 160 columns wide
    And the source-control panel has focus
    When the user presses "Esc"
    Then the prompt has focus
    And the panel stays visible

  @backlog @tui
  Scenario: The source-control panel is titled inside a rounded border
    Given the terminal is 150 columns wide
    When the user presses "Ctrl+L"
    Then the source-control panel has a rounded border in the accent colour
    And the panel's first row reads "Source Control" in bold
    And the panel's second row reads "↑/↓ select · Enter activate · Esc back" in the dim colour

  @backlog @tui
  Scenario: A running git action marks the panel title
    Given the terminal is 150 columns wide
    And a git action is running
    When the user opens the source-control panel
    Then the panel's first row reads "Source Control · working…"
    And " · working…" is in the warning colour

  @backlog @tui
  Scenario: Without git status the panel says so, indented
    Given the terminal is 150 columns wide
    And git status could not be read
    When the user opens the source-control panel
    Then the panel's third row reads "  no git status" in the dim colour

  @backlog @tui
  Scenario: The working tree is summed up on one line
    Given the terminal is 150 columns wide
    And the workspace has uncommitted changes
    When the user opens the source-control panel
    Then the panel shows "2 files · +6 -2" in the dim colour
    And the changed files are not listed one by one

  @backlog @tui
  Scenario: A pull request shows its number in its state's colour
    Given the terminal is 150 columns wide
    And the checkout's branch has an open pull request
    When the user opens the source-control panel
    Then the panel shows "◰ PR #42 open ↗"
    And "◰ PR #42" is in the success colour and "open ↗" in the dim colour

  @backlog @tui
  Scenario: A long branch name is cut to fit the panel
    Given the terminal is 150 columns wide
    And the branch is named "feature/an-extremely-long-branch-name-that-does-not-fit"
    When the user opens the source-control panel
    Then the branch line ends with "…" inside the panel's border

  @tui
  Scenario Outline: The quick action matches where the branch stands
    Given the branch <state>
    Then the quick action is "<action>"

    Examples:
      | state                                                     | action            |
      | is a feature branch with changes and an upstream          | Commit, push & PR |
      | is the default branch with changes                        | Commit & push     |
      | has changes and no remote at all                          | Commit            |
      | is a feature branch ahead of its upstream with no PR      | Push & create PR  |
      | has an open PR and is up to date                          | View PR           |
      | is behind its upstream                                    | Pull              |
      | is a clean default branch ahead of its upstream           | Push              |

  @tui
  Scenario Outline: A disabled quick action explains itself
    Given the branch <state>
    When the user selects the quick action
    Then the status line says "<hint>"

    Examples:
      | state                                  | hint                                                    |
      | has diverged from its upstream         | Branch has diverged from upstream. Rebase/merge first.  |
      | has no upstream and nothing to push    | No local commits to push.                               |
      | is up to date with nothing to do       | Branch is up to date. No action needed.                 |
      | has a git action already running       | Git action in progress.                                 |

  @tui
  Scenario: Every git action is disabled while one is running
    Given a git action is running
    Then commit, push and the pull request action are all disabled

  @tui
  Scenario Outline: Moving onto a disabled menu action shows why
    Given the source-control panel has focus
    When the user moves onto the disabled "<item>" action
    Then the panel shows "<reason>"

    Examples:
      | item   | reason                                  |
      | Commit | No uncommitted changes.                 |
      | Push   | Pull or rebase before pushing.          |

  @tui
  Scenario: A commit action asks for the commit message first
    Given the workspace has uncommitted changes
    When the user runs "Commit, push & PR"
    Then the prompt asks for a commit message
    And entering "Fix login" commits, pushes and opens a pull request

  @tui
  Scenario: Cancelling the commit message runs nothing
    Given the prompt is asking for a commit message
    When the user presses "Esc"
    Then no commit is made

  @tui
  Scenario: A commit-and-push with nothing to commit just pushes
    Given the branch has no uncommitted changes and is ahead of its upstream
    When the user runs a commit-and-push action
    Then the branch is pushed without asking for a commit message

  @tui
  Scenario: A bare commit with nothing to commit says so
    Given the workspace has no uncommitted changes
    When the user runs "Commit"
    Then the status line says "Nothing to commit."

  @tui
  Scenario: The user pulls a branch that is behind
    Given the branch is behind its upstream
    When the user runs "Pull"
    Then the branch is pulled from its upstream

  @tui
  Scenario: Viewing a PR copies its link
    Given the branch has an open pull request
    When the user runs "View PR" from the keyboard
    Then the exact pull request URL is copied to the clipboard
    And the status line says the PR link was copied

  @tui
  Scenario: Viewing a PR without clipboard support prints the link
    Given the branch has an open pull request
    And the user's terminal does not support OSC 52
    When the user runs "View PR"
    Then the status line shows "Open PR:" followed by the URL

  @tui
  Scenario: Without a primary remote only commit is offered
    Given the repository has no primary remote
    Then the panel menu offers only "Commit"

  @tui
  Scenario: A folder that is not a repository gets an honest hint
    Given the thread's workspace is not a git repository
    When the user opens the source-control panel
    Then the panel says repository initialization is not available in the terminal yet

  @tui
  Scenario: Missing git status disables the quick action with a reason
    Given git status could not be read
    Then the quick action is disabled with "Git status is unavailable."

  @tui
  Scenario: On a narrow terminal the panel takes the main pane
    Given the terminal is 90 columns wide
    When the user opens the source-control panel and runs the highlighted action
    Then the panel replaces the conversation while open
    And the action runs

  @tui
  Scenario: Esc on a narrow terminal closes the panel and shows the conversation
    Given the terminal is 90 columns wide
    And the source-control panel has replaced the conversation
    When the user presses "Esc"
    Then the panel closes and the conversation is shown

  @backlog @tui
  Scenario: The user switches to or creates a ref
    When the user switches the workspace to the new branch "fix/login"
    Then the workspace is on "fix/login"

  @backlog @tui
  Scenario: The user creates and removes a worktree
    When the user creates a worktree for "fix/login"
    Then the worktree is listed
    And removing it deletes the worktree and keeps the branch

  @backlog @tui
  Scenario: Worktrees match the same project across environments
    Given "shop" is open on two environments
    Then worktrees on both are listed under the one project

  @backlog @tui
  Scenario Outline: The user resolves a pull request from any reference
    When the user checks out the pull request <reference>
    Then the pull request is resolved and a local checkout or worktree is prepared

    Examples:
      | reference                                      |
      | "https://github.com/acme/shop/pull/42"         |
      | "gh pr checkout 42"                            |
      | "#42"                                          |

  @backlog @tui
  Scenario: The user initializes a repository
    Given the thread's workspace is not a git repository
    When the user initializes a repository
    Then the workspace becomes a git repository

  @backlog @tui
  Scenario: The client discovers which source-control providers are available
    When the user opens source-control providers
    Then each provider is listed with whether it is installed and signed in

  @backlog @tui
  Scenario: The user publishes a repository to a source provider
    Given the repository has no remote and a source provider is signed in
    When the user publishes the repository
    Then the repository is created on the provider and set as the remote

  @backlog @tui
  Scenario: Git operations stream their phases and hooks
    When the user runs "Commit, push & PR"
    Then the panel shows each phase and hook output as it runs

  @backlog @tui
  Scenario: A failed git operation keeps its error and refreshes status
    When a push fails because of a hook
    Then the error stays visible until dismissed
    And the git status is refreshed
