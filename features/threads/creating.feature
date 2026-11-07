# Sources:
#   https://github.com/pingdotgg/t3code/pull/23967
#   https://github.com/pingdotgg/t3code/pull/19724
#   https://github.com/pingdotgg/t3code/pull/14538
#   https://github.com/pingdotgg/t3code/pull/17959
#   https://github.com/pingdotgg/t3code/pull/17371
#   https://github.com/pingdotgg/t3code/pull/17664
#   https://github.com/pingdotgg/t3code/pull/20442
#   https://github.com/pingdotgg/t3code/pull/20519
#   https://github.com/pingdotgg/t3code/pull/16628
#   docs/user/thread-sidebar.md (New threads, background start, multi-model fan-out)
#   apps/web/src/hooks/useHandleNewThread.ts
#   apps/web/src/components/ChatView.tsx (several models: started count, failed model, uncertain start, send gates)
#   apps/web/src/components/Sidebar.tsx (SidebarDraftBlock: only a draft with content is listed)
#   apps/web/src/components/Sidebar.logic.ts (shouldCreateNewThreadInCurrentProject)
#   apps/web/src/composerDraftStore.ts (what a draft keeps when its project, branch or machine changes)
#   apps/web/src/components/sidebar/SidebarThreadHeader.tsx (the new thread button and its hint)
#   apps/web/src/components/threadActionMenu.logic.ts (New thread on <branch>)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (New thread, draft rows)
#   apps/desktop-qt/src/native/DraftController.cpp (the desktop's drafts)
#   apps/desktop-qt/src/native/ComposerController.cpp, WorkspaceController.cpp (a draft's first send)
#   apps/tui/src/newThread.logic.ts
#   apps/tui/src/commands.ts (New thread)
#   packages/contracts/src/orchestrationV2.ts (thread.create, thread.created)
#   packages/contracts/src/rpc.ts (launchThread)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread.create, launchThread)
#   apps/server/src/cli/app.test.ts, apps/web/src/desktopAppActivation.ts (hal-c2 app <folder>)
#   The basic "hal-c2 app ~/code/api" case lives in settings/install.feature.
#   apps/desktop/src/app/DesktopAppActivationBroker.ts, DesktopAppActivation.ts, packages/shared/src/desktopAppControlSocket.ts
#     (queueing before the window is ready, timeouts, closing, request limits, socket privacy)
#   https://github.com/pingdotgg/t3code/pull/13612
#   https://github.com/pingdotgg/t3code/pull/15060
#   https://github.com/pingdotgg/t3code/pull/15356
#   https://github.com/pingdotgg/t3code/pull/15391

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
    And the thread list does not list the empty draft

  @desktop
  Scenario: A new thread started while the list is scoped to a project uses that project
    Given the thread list is scoped to the project "docs"
    When the user starts a new thread
    Then a draft thread opens in "docs"

  @desktop @priority-high
  Scenario: The new thread button asks which project when there are several
    Given the environment also has the project "docs"
    When the user presses the new thread button in the thread list
    Then the user is asked which project to start the thread in

  @desktop @priority-high
  Scenario: The new thread button starts straight away when there is one project
    Given "shop" is the only project
    When the user presses the new thread button in the thread list
    Then a draft thread opens in "shop" without asking

  @desktop
  Scenario: Shift on the new thread button starts in the current project
    Given the environment also has the project "docs"
    When the user presses the new thread button in the thread list with Shift held
    Then a draft thread opens in "shop" without asking
    And the button's hint says Shift starts the thread in the current project

  @backlog @desktop
  Scenario: The new thread button without a project starts a thread without one
    Given the environment has no projects
    And the environment offers threads without a project
    When the user presses the new thread button in the thread list
    Then a draft thread opens without a project

  @backlog @desktop
  Scenario: The new thread button stays disabled where threads without a project are not offered
    Given the environment has no projects
    And the environment does not offer threads without a project
    Then the new thread button in the thread list is disabled

  @desktop @mobile @priority-high
  Scenario: A new thread keeps the current model and mode
    Given the current thread uses the model "Opus" in plan mode
    When the user starts a new thread
    Then the draft uses the model "Opus" in plan mode

  @desktop @mobile @priority-high
  Scenario: A new thread from another thread takes that thread's model and mode
    Given the current thread uses the model "Opus" in plan mode
    And the user starts a new thread
    And the draft uses the model "Opus" in plan mode
    When the user opens another thread of "shop" that uses the model "GPT-5"
    And the user starts a new thread
    Then the draft uses the model "GPT-5" in default mode

  @desktop @mobile @priority-high
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

  @backlog @shared @mobile @tui
  Scenario Outline: A project created from a name starts its first thread in its folder
    Given new threads default to a new worktree
    And the project "notes" was created from just a name <override>
    When the user starts <which> thread in "notes"
    Then the thread works <where>

    Examples:
      | override                               | which         | where                  |
      | and has no thread mode of its own      | its first     | in the project folder  |
      | and has no thread mode of its own      | a second      | in a new worktree      |
      | and its own mode is a new worktree     | its first     | in a new worktree      |

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

  @desktop @tui
  Scenario: A new worktree needs a base branch
    Given the user chose a new worktree without a base branch
    When the user tries to start the thread
    Then the thread is not started
    And the user is told to pick a base branch

  @desktop @tui
  Scenario: A thread cannot start from an empty task
    When the user tries to start a thread with an empty first message
    Then the thread is not started

  @desktop @mobile @priority-high
  Scenario: Starting a thread from another thread's branch
    Given the current thread is on the branch "feature/cart"
    When the user starts a new thread on that branch from the thread menu
    Then a draft opens in the same worktree as the current thread

  @mc
  Scenario Outline: Launching a thread with a workspace strategy
    When a client launches a thread in "shop" with the <strategy> workspace
    Then the thread is created with <workspace>
    And the first message is sent to the agent

    Examples:
      | strategy          | workspace                                           |
      | project root      | the project root as its workspace                   |
      | existing worktree | the chosen existing worktree as its workspace       |
      | new worktree      | a worktree prepared from the base branch before run |

  @mc
  Scenario: Launching into a new worktree prepares it before the agent runs
    When a client launches a thread in "shop" with a new worktree from "main"
    Then the thread shows that its workspace is being prepared
    And the agent starts only after the worktree is ready

  @mc
  Scenario: Launching a thread can ask for a generated title
    When a client launches a thread with title generation requested
    Then the thread title is generated from the first message

  @mc
  Scenario: A thread id can only be created once
    Given the thread "t-1" exists
    When a client creates another thread with the id "t-1"
    Then the command is rejected with "Thread t-1 already exists."

  @mc
  Scenario: Launching can reuse an existing empty thread
    Given an empty draft thread exists for "shop"
    When a client launches a thread in "shop" and asks to reuse the existing thread
    Then the first message is sent in the existing thread
    And no second thread is created

  # Upstream #19724: a thread the sidebar had not listed yet sent its link back to the start page.
  @backlog @shared @priority-high
  Scenario: A just-created thread opens before the thread list has it
    Given another client has just created the thread "Fix checkout"
    And the thread list here does not show "Fix checkout" yet
    When the user opens a link to "Fix checkout"
    Then "Fix checkout" opens with its history
    But a link to a deleted or archived thread still returns to the start page

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: Starting a thread in the background opens a fresh draft
    Given the user has written a first message in a draft
    When the user starts the thread in the background
    Then the thread starts working without being opened
    And a new draft opens with the same workspace mode and base branch

  # Upstream #14538: New thread did nothing while the last sent draft was still creating its
  # worktree; it now opens a fresh draft.
  @shared @backlog-tui @priority-high
  Scenario: A new thread started while the last one sets up its worktree opens a fresh draft
    Given the user sent a draft that is still creating its worktree
    When the user starts a new thread
    Then a fresh draft opens
    And the sent thread keeps setting up and starts when its worktree is ready

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: Each background start into a new worktree gets its own worktree
    Given the draft is set to use a new worktree
    When the user starts two threads in the background
    Then each thread works in its own new worktree

  @desktop
  Scenario: Fanning one request out to several models
    Given "shop" is a Git project
    When the user sends the first message to the models "Opus", "GPT-5" and "Gemini"
    Then three threads are created, one per model
    And each thread works in its own new worktree

  @desktop
  Scenario: A request to several models cut off by a quit comes back to its draft once
    Given "shop" is a Git project
    And the MC holds its answers
    When the user sends the first message to the models "Opus", "GPT-5" and "Gemini"
    And the desktop quits and starts again
    And the MC drops the send
    And the desktop shell is connected to its MC
    Then the composer offers the new thread's text "Add caching"
    And the desktop keeps no unsent prompts

  @desktop
  Scenario: Several models cannot be chosen outside a Git project
    Given "notes" is not a Git project
    When the user tries to pick more than one model for the first message
    Then only one model can be chosen

  @backlog @desktop @priority-low
  Scenario: Several models that all start are counted in one notice
    Given "shop" is a Git project
    When the user sends the first message to the models "Opus", "GPT-5" and "Gemini"
    Then the user is told "Started 3 threads in background"
    And the draft is empty and ready for another prompt

  @backlog @desktop @priority-low
  Scenario: A model that fails to start is named and kept for another try
    Given "shop" is a Git project
    And starting a thread for "Gemini" will be refused
    When the user sends the first message to the models "Opus" and "Gemini"
    Then the user is told "Started 1 thread in background"
    And the user is told "Could not start Gemini" with the reason
    And the draft has its prompt back with only "Gemini" still chosen

  @desktop @priority-high
  Scenario: A failed start does not put back a prompt over a newer draft
    Given a request to several models is still starting
    And the user has typed a new prompt in the emptied draft
    When one of the models fails to start
    Then the new prompt is left as it is

  # Upstream #14538: a start that fails after the user moved on gives its prompt back to its own
  # draft.
  @shared @backlog-tui
  Scenario: A thread whose start fails gets its prompt back without touching a newer draft
    Given the user sent a draft and opened a new draft while it set up
    When the sent thread fails to start
    Then its prompt is back in its own draft
    And the new draft is unchanged

  @backlog @desktop @priority-low
  Scenario: A start that may have gone through is not sent twice by accident
    Given "shop" is a Git project
    And the answer to starting "Gemini" is lost, so it may be running
    When the user sends the same request to "Gemini" again
    Then no second request is sent
    And the user is told the previous request may have started and to open its thread first
    And the notice offers to open that thread

  @backlog @desktop
  Scenario: The user allows a retry that could make a duplicate thread
    Given the user was told a request to "Gemini" may have started
    When the user chooses "Allow retry" and confirms that a duplicate thread could result
    Then sending to "Gemini" again starts a new thread

  @backlog @desktop @priority-low
  Scenario: Several models need a new thread with a base branch
    Given the user has chosen several models
    And the draft has no base branch
    When the user sends the first message
    Then the user is told "Choose models and a base branch" and that each model gets its own worktree
    And nothing is sent

  @backlog @desktop @priority-low
  Scenario: A model whose provider is not ready stops the whole request
    Given the user has chosen the models "Opus" and "Gemini"
    And the provider for "Gemini" is not ready
    When the user sends the first message
    Then the user is told "Provider for Gemini is unavailable."
    And no thread is started for either model

  @backlog @desktop
  Scenario: An older server cannot start several models
    Given the environment's server is too old to set up a worktree per thread
    And the user has chosen several models
    When the user sends the first message
    Then the user is told "Update this server before starting multiple models."
    And nothing is sent

  @desktop @priority-high
  Scenario: A draft whose project is gone cannot be sent
    Given the draft's project is no longer available
    When the user sends the first message
    Then the user is told "Choose a project first"
    And the draft keeps its prompt

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: Changing a draft's project picks an environment that has it
    Given the project "api" exists only on the environment "server"
    When the user moves the draft to "api"
    Then the draft targets the environment "server"

  @backlog @desktop @priority-low
  Scenario: Changing a draft's project lets go of its branch but keeps how it will work
    Given a draft in "shop" set to use a new worktree from "release", started from origin
    When the user moves the draft to "api"
    Then the draft is still set to use a new worktree started from origin
    And the draft has no base branch and no worktree

  @backlog @desktop @priority-low
  Scenario: Choosing a branch for a draft on Auto balance pins it to that machine
    Given the user chose "Auto balance" for a new thread
    When the user chooses the branch "release" for the draft
    Then the draft runs on the machine whose branch was chosen instead of a balanced one

  @desktop @mobile @priority-high
  Scenario: A failed thread creation is reported
    Given the environment rejects new threads
    When the user sends the first message of a new thread
    Then the user is told "Could not create thread"

  @desktop @mobile @tui @priority-high
  Scenario: A new thread cannot be created while the environment is offline
    Given the environment is unreachable
    When the user starts a new thread
    Then the user is told the environment is offline
    And no draft is sent to the environment

  # Upstream #23967: a new thread waited on the project's settings from the chosen machine,
  # which never answered while it was offline, so nothing opened.
  @backlog @desktop @mobile @priority-high
  Scenario: A new thread on a project whose chosen machine is offline opens its draft at once
    Given "shop" lives on two machines and the one chosen for new threads is offline
    When the user starts a new thread in "shop"
    Then the draft opens at once with the usual defaults
    And the user can pick the machine that is online from the draft

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

  @backlog @desktop @priority-low
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

  # Legacy: apps/desktop/src/app/DesktopAppActivationBroker.ts, DesktopAppActivation.ts (control socket)
  @backlog @desktop
  Scenario: hal-c2 app starts the desktop app when it is not running
    Given the desktop app is not running
    When the user runs "hal-c2 app ~/code/shop"
    Then the desktop app starts and brings its window to the front
    And the desktop app opens a new thread in "shop" once it is ready

  @backlog @desktop
  Scenario: Folders sent while the window is still starting are opened one at a time
    Given the desktop app's window is still starting
    When the user runs "hal-c2 app ~/code/shop" and "hal-c2 app ~/code/docs"
    Then each folder opens a thread in its own project
    And each command reports its own result

  @backlog @desktop
  Scenario Outline: hal-c2 app reports a desktop app that could not finish
    Given <situation>
    When the user runs "hal-c2 app ~/code/shop"
    Then the command fails saying "<message>"

    Examples:
      | situation                                                   | message                                                    |
      | the desktop app takes longer than 15 seconds to open it     | The desktop app did not finish opening the project in time. |
      | the HAL-C2 window closes while it is opening the project    | The HAL-C2 window closed before it opened the project.      |
      | the desktop app is quitting                                 | HAL-C2 is shutting down.                                    |

  @backlog @desktop @priority-low
  Scenario: Interrupting hal-c2 app before the window is ready drops the request
    Given the desktop app's window is still starting
    And the user ran "hal-c2 app ~/code/shop"
    When the user interrupts the command
    Then no thread is opened in "shop" once the window is ready

  @backlog @desktop
  Scenario: The desktop app's control channel is private to the user
    Given the desktop app is running on Linux or macOS
    Then only the user who started it can talk to it
    And a leftover channel from an app that no longer runs is replaced at startup

  @backlog @desktop @priority-low
  Scenario Outline: The desktop app refuses a malformed command
    Given the desktop app is running
    When a program sends it <request>
    Then it answers that the request is invalid and does nothing

    Examples:
      | request                                |
      | more than 64 KiB of text               |
      | text that is not valid JSON            |
      | a request that reuses a request's id   |

  @backlog @shared @mc @priority-high
  Scenario: A thread can start without a project
    Given a connected environment
    When the user starts a thread with No project
    Then the thread works in its own scratch folder named from the date and its first words
    And the thread has no branch toolbar and no worktree mode
    And the draft reads "What should we work on?" with a project picker to move it into a project

  @backlog @mc
  Scenario: Threads without a project are offered on a machine without Git
    Given Git is not installed on the machine
    And the MC's data folder is not inside a Git checkout
    When a client asks what new threads the machine offers
    Then threads without a project are offered
    And a turn in such a thread runs without checkpoints

  @backlog @shared @priority-high
  Scenario Outline: No project is reachable from every new-thread entry point
    When the user uses "<entry>"
    Then a thread without a project is started on the machine in use

    Examples:
      | entry                                          |
      | the or-start-without-a-project link            |
      | No project in the project menu                 |
      | New thread without a project in the palette    |
      | the new-thread-without-project keybinding      |
      | Start without a project on the no-projects screen |

  @backlog @shared
  Scenario: No project is hidden on a machine that does not offer it
    Given the machine in use does not offer threads without a project
    When the user opens the project menu
    Then No project is not listed
    And the thread is never silently started on another machine

  @backlog @shared @priority-low
  Scenario: Starting a thread in the background has a plain-Enter binding
    Given the user is writing a new thread
    When the user presses the Start in Background keybinding
    Then the thread starts in the background and a fresh composer opens
    And both Mod+Enter and Mod+Alt+Enter are bound to it by default

  @backlog @shared @priority-low
  Scenario: A draft without a project can switch machines
    Given a new thread without a project
    When the user picks another connected machine that offers a scratch folder
    Then the draft moves to that machine's scratch folder, created on first use
    And sending waits for that setup

  # Upstream #20442: leaving the draft abandons the switch.
  @backlog @shared
  Scenario: A draft left while it is switching machines stays on its machine
    Given a new thread without a project is switching to another machine's scratch folder
    When the user leaves the draft before the scratch folder is ready
    Then the draft stays on its machine and project
    And the switch finishing later does not move it

  # Upstream #20519: the abandoned switch still clears its busy state.
  @backlog @shared
  Scenario: Coming back to a draft whose machine switch was abandoned finds it ready
    Given the user left a new thread draft while it was switching machines
    When the user comes back to that draft
    Then the draft is not shown preparing a machine
    And the user can send from it

  @backlog @shared @priority-low
  Scenario: A keybinding steps a new thread to the next machine
    Given a new thread draft and more than one machine
    When the user presses the Cycle Host key
    Then the draft moves to the next machine, as choosing it from the machine menu would
    And no key is bound to it by default on desktop

  @backlog @shared @priority-low
  Scenario: "No project" is offered right after the current project
    Given the user has more projects than fit on screen
    When the user picks where to start a new thread
    Then "No project" is listed right after the current project
    And it is first when the current thread has no project
    And the current project is still the default choice

  # Upstream #17664: the draft screen's picker searches like the sidebar's project filter.
  @shared @backlog-desktop @backlog-mobile
  Scenario: The new thread's project picker ends with Add project
    Given the user has many projects and is writing a new thread
    When the user opens the draft's project picker
    Then every project is listed, with "Add project" last

  @shared @backlog-desktop @backlog-mobile
  Scenario: The new thread's project picker can be searched
    Given the user has many projects and is writing a new thread
    When the user opens the draft's project picker and types part of a project's name
    Then only matching projects are listed
    And choosing one moves the draft into that project

  @shared @backlog-desktop @backlog-mobile
  Scenario: A project search with no match says so
    Given the user is searching the new thread's project picker
    When nothing matches the search
    Then the picker reads "No matching projects."
    And "Add project" is not listed while searching

  @backlog @shared @priority-low
  Scenario: The draft screen leaves a project through its own link
    Given the user is writing a new thread in a project
    When the user opens the draft's project picker
    Then "No project" is not among its rows
    And "or start without a project" under the headline moves the draft out of the project
