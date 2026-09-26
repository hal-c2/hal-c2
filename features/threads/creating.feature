# Sources:
#   docs/user/thread-sidebar.md (New threads, background start, multi-model fan-out)
#   apps/web/src/hooks/useHandleNewThread.ts
#   apps/web/src/components/threadActionMenu.logic.ts (New thread on <branch>)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (New thread, draft rows)
#   apps/tui/src/newThread.logic.ts
#   apps/tui/src/commands.ts (New thread)
#   packages/contracts/src/orchestrationV2.ts (thread.create, thread.created)
#   packages/contracts/src/rpc.ts (launchThread)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread.create, launchThread)
#   apps/server/src/cli/app.test.ts, apps/web/src/desktopAppActivation.ts (hal-c2 app <folder>)
#   The basic "hal-c2 app ~/code/api" case lives in settings/install.feature.

Feature: Creating threads
  A thread is the durable conversation for a project. Starting one keeps the user's
  current context: the same project, model and mode, and a sensible workspace.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  @desktop @tui
  Scenario: A new thread starts in the project the user is looking at
    When the user starts a new thread
    Then a draft thread opens in "shop"
    And the draft is listed at the top of the thread list

  @desktop
  Scenario: A new thread started while the list is scoped to a project uses that project
    Given the thread list is scoped to the project "docs"
    When the user starts a new thread
    Then a draft thread opens in "docs"

  @backlog @desktop @mobile
  Scenario: A new thread keeps the current model and mode
    Given the current thread uses the model "Opus" in plan mode
    When the user starts a new thread
    Then the draft uses the model "Opus" in plan mode

  @backlog @desktop @mobile
  Scenario: A new thread uses the project default model when the project has one
    Given "shop" has the default model "Sonnet"
    And the current thread uses the model "Opus"
    When the user starts a new thread
    Then the draft uses the model "Sonnet"

  @tui
  Scenario: The new thread form preselects a new worktree from the current branch
    Given the current thread is on the branch "main"
    When the user opens the new thread form
    Then a new worktree is preselected
    And "main" is offered as the base branch

  @tui
  Scenario: The new thread form inherits the workspace of the selected thread
    Given the selected thread works in the worktree for "feature/cart"
    When the user opens the new thread form
    Then the form targets the worktree for "feature/cart"

  @tui
  Scenario: Choosing a branch that already has a worktree reuses it
    Given the branch "feature/cart" already has a worktree
    When the user starts a new thread on "feature/cart"
    Then the thread works in the existing worktree for "feature/cart"
    And no new worktree is created

  @tui
  Scenario: Choosing a branch that is not checked out switches the checkout
    Given the branch "fix/login" exists but is not checked out
    When the user starts a new thread in the project root on "fix/login"
    Then the project checkout switches to "fix/login"

  @tui
  Scenario: A new worktree needs a base branch
    Given the user chose a new worktree without a base branch
    When the user tries to start the thread
    Then the thread is not started
    And the user is told to pick a base branch

  @tui
  Scenario: A thread cannot start from an empty task
    When the user tries to start a thread with an empty first message
    Then the thread is not started

  @backlog @desktop @mobile
  Scenario: Starting a thread from another thread's branch
    Given the current thread is on the branch "feature/cart"
    When the user starts a new thread on that branch from the thread menu
    Then a draft opens in the same worktree as the current thread

  @node
  Scenario Outline: Launching a thread with a workspace strategy
    When a client launches a thread in "shop" with the <strategy> workspace
    Then the thread is created with <workspace>
    And the first message is sent to the agent

    Examples:
      | strategy          | workspace                                           |
      | project root      | the project root as its workspace                   |
      | existing worktree | the chosen existing worktree as its workspace       |
      | new worktree      | a worktree prepared from the base branch before run |

  @node
  Scenario: Launching into a new worktree prepares it before the agent runs
    When a client launches a thread in "shop" with a new worktree from "main"
    Then the thread shows that its workspace is being prepared
    And the agent starts only after the worktree is ready

  @node
  Scenario: Launching a thread can ask for a generated title
    When a client launches a thread with title generation requested
    Then the thread title is generated from the first message

  @node
  Scenario: A thread id can only be created once
    Given the thread "t-1" exists
    When a client creates another thread with the id "t-1"
    Then the command is rejected with "Thread t-1 already exists."

  @node
  Scenario: Launching can reuse an existing empty thread
    Given an empty draft thread exists for "shop"
    When a client launches a thread in "shop" and asks to reuse the existing thread
    Then the first message is sent in the existing thread
    And no second thread is created

  @backlog @desktop @mobile
  Scenario: Starting a thread in the background opens a fresh draft
    Given the user has written a first message in a draft
    When the user starts the thread in the background
    Then the thread starts working without being opened
    And a new draft opens with the same workspace mode and base branch

  @backlog @desktop @mobile
  Scenario: Each background start into a new worktree gets its own worktree
    Given the draft is set to use a new worktree
    When the user starts two threads in the background
    Then each thread works in its own new worktree

  @backlog @desktop
  Scenario: Fanning one request out to several models
    Given "shop" is a Git project
    When the user sends the first message to the models "Opus", "GPT-5" and "Gemini"
    Then three threads are created, one per model
    And each thread works in its own new worktree

  @backlog @desktop
  Scenario: Several models cannot be chosen outside a Git project
    Given "notes" is not a Git project
    When the user tries to pick more than one model for the first message
    Then only one model can be chosen

  @backlog @desktop @mobile
  Scenario: Changing a draft's project picks an environment that has it
    Given the project "api" exists only on the environment "server"
    When the user moves the draft to "api"
    Then the draft targets the environment "server"

  @backlog @desktop @mobile
  Scenario: A failed thread creation is reported
    Given the environment rejects new threads
    When the user starts a new thread
    Then the user is told "Could not create thread"

  @backlog @desktop @mobile @tui
  Scenario: A new thread cannot be created while the environment is offline
    Given the environment is unreachable
    When the user starts a new thread
    Then the user is told the environment is offline
    And no draft is sent to the environment

  @backlog @desktop
  Scenario: Opening a folder that is already a project starts a thread in it
    Given the desktop app is running and "shop" lives at "~/code/shop"
    When the user runs "hal-c2 app ~/code/shop"
    Then the desktop app opens a new thread in "shop"
    And no second "shop" project is added

  @backlog @desktop
  Scenario: Running hal-c2 app without a folder opens the current folder
    Given the desktop app is running
    When the user runs "hal-c2 app" inside "~/code/shop"
    Then the desktop app opens a new thread in "shop"

  @backlog @desktop
  Scenario Outline: hal-c2 app refuses what it cannot open
    Given <situation>
    When the user runs "hal-c2 app ~/code/shop"
    Then the command fails saying <reason>
    And no thread is opened

    Examples:
      | situation                                                            | reason                                               |
      | the user is connected over SSH                                       | it only controls a desktop app on the same machine   |
      | the desktop app's own environment is not connected                   | the desktop app's local environment is not connected |
      | the command runs in WSL but the desktop app's environment is Windows | cross-platform paths are not supported               |
      | the folder cannot be added as a project                              | HAL-C2 could not add the project                    |

