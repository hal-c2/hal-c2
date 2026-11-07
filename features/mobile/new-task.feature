# Sources:
#   https://github.com/pingdotgg/t3code/pull/20825
#   https://github.com/pingdotgg/t3code/pull/19641
#   https://github.com/pingdotgg/t3code/pull/17409
#   https://github.com/pingdotgg/t3code/pull/17611
#   https://github.com/pingdotgg/t3code/pull/13454 (branch search and remote-only branches)
#   apps/mobile/src/features/threads/NewTaskRouteScreen.tsx (project choice, empty states, search)
#   apps/mobile/src/features/threads/new-task-project-selection.ts (scopes, environment match)
#   apps/mobile/src/features/threads/NewTaskDraftRouteScreen.tsx (branch switch before the draft opens)
#   apps/mobile/src/features/threads/NewTaskContextPickerScreens.tsx (branch picker, switch failure)
#   apps/mobile/src/features/threads/NewTaskContextPickerScreens.tsx (branch picker empty states, retry, paging)
#   apps/mobile/src/features/threads/NewTaskDraftScreen.tsx (a task the outbox cannot save)
#   apps/mobile/src/features/threads/new-task-context-presentation.ts (checkout, worktree and branch labels)
#   apps/mobile/src/state/use-composer-drafts.ts (retargetNewTaskDraft), apps/mobile/src/state/pending-thread-creation.ts, apps/mobile/src/state/pending-new-tasks-model.ts (unstarted and pending tasks)
#   https://github.com/pingdotgg/t3code/pull/14532
#   https://github.com/pingdotgg/t3code/pull/25712
#   https://github.com/pingdotgg/t3code/pull/25706
#   https://github.com/pingdotgg/t3code/pull/24741
#   https://github.com/pingdotgg/t3code/pull/24269
# Drafting and sending are specified in features/composer/ and features/threads/. This file covers
# the phone's new task screens: choosing where the task runs before the first message is sent.

Feature: Starting a task from a phone
  The new task screens pick the project, the environment and the branch the task will run
  on, then hand over to the composer. Each choice can be wrong, empty or unavailable.

  Background:
    Given the phone is paired with "My MacBook" and "Office Mac"

  @backlog @mobile
  Scenario: A project that lives on several environments is listed once
    Given "shop" is a project on both "My MacBook" and "Office Mac"
    When the user starts a new task
    Then "shop" is listed once
    And the entry says it has 2 workspaces

  @backlog @mobile
  Scenario: Choosing a project that lives on several environments uses the environment the user was on
    Given "shop" is a project on both "My MacBook" and "Office Mac"
    And the new task was last aimed at "Office Mac"
    When the user chooses "shop"
    Then the task is aimed at "shop" on "Office Mac"

  # Upstream #17611: the draft named the workspace's folder ("server") while the picker named
  # the repository, and on iOS its header was empty.
  @backlog @mobile @priority-low
  Scenario Outline: A new task's draft names the project as the picker does and says it is new
    Given a project at <folder> is listed as "<listed>" in the project picker
    When the user chooses it for a new task
    Then the draft asks what to build in "<listed>"
    And the screen's title is "New thread"

    Examples:
      | folder                                                 | listed      |
      | apps/server in a repository from github.com/acme/shop | acme/shop   |
      | plain-notes, which is not a repository                 | plain-notes |

  @backlog @mobile @priority-high
  Scenario: Projects are searched by name or folder
    Given "My MacBook" has the projects "shop" in "~/code/shop" and "docs" in "~/work/handbook"
    When the user searches the projects for "handbook"
    Then only "docs" is listed

  @backlog @mobile
  Scenario: A project search with no match says so
    When the user searches the projects for "zzz"
    Then the user is told no projects match
    And the user is asked to try a different name or folder

  @backlog @mobile
  Scenario Outline: The project list explains why it is empty
    Given <situation>
    When the user starts a new task
    Then the user is told "<message>"
    And the user is offered to <action>

    Examples:
      | situation                                   | message                   | action              |
      | no environment is paired                    | No environments connected | add an environment  |
      | the only environment is still connecting    | Connecting to environment | add an environment  |
      | the only environment cannot be reached      | Environment unavailable   | add an environment  |
      | the only environment has no projects        | No projects found         | add a new project   |

  @backlog @mobile
  Scenario: Switching the new task to another environment follows the same repository
    Given the new task is aimed at the project "shop" with the repository "acme/shop" on "My MacBook"
    And "Office Mac" has the project "web" with the repository "acme/shop"
    And "Office Mac" has the project "shop" with the repository "other/shop"
    When the user aims the task at "Office Mac"
    Then the task is aimed at "web" on "Office Mac"

  @backlog @mobile @priority-low
  Scenario: Switching environments falls back to the folder name and then the title
    Given the new task is aimed at the project "shop" in "~/code/shop" on "My MacBook"
    And "Office Mac" has a project "shop" in "~/src/shop" whose repository is not known yet
    When the user aims the task at "Office Mac"
    Then the task is aimed at "shop" on "Office Mac"

  @backlog @mobile
  Scenario: Switching environments never matches a different repository by name
    Given the new task is aimed at the repository "acme/shop" on "My MacBook"
    And "Office Mac" has a project "shop" whose repository is "other/shop"
    When the user aims the task at "Office Mac"
    Then the task is not aimed at that "shop"

  @backlog @mobile @priority-high
  Scenario: Aiming the task at another project keeps what was written
    Given the user wrote "Add search" and attached a photo in a new task for "shop"
    When the user aims the task at the project "web"
    Then the new task editor still holds "Add search" and the photo
    And no second unstarted task is created for "web"

  @backlog @mobile @priority-low
  Scenario: Aiming the task at another project forgets the branch and keeps the model
    Given the new task for "shop" is set to the model "Opus 4", plan mode and a new worktree from "main"
    When the user aims the task at the project "web"
    Then the task keeps "Opus 4" and plan mode
    But the branch and worktree choices are cleared

  @backlog @mobile
  Scenario: A photo already uploaded to one environment is sent again to another
    Given the user attached a photo to a new task for "shop" on "My MacBook" and it finished uploading
    When the user aims the task at "web" on "Office Mac"
    Then the photo stays in the task
    And the photo is uploaded to "Office Mac"

  @backlog @mobile @priority-high
  Scenario: A branch checked out in another worktree starts the task there
    Given "feature/search" is checked out in another worktree of "shop"
    When the user chooses "feature/search" as the task's branch
    Then the task will run in that worktree
    And no branch is switched

  # Upstream #20825: a branch another worktree held failed with "Could not switch branch".
  @backlog @mobile
  Scenario: A thread's branch held by another worktree starts the new task there
    Given the thread "Fix checkout" is on "feature/cart", which another worktree of "shop" holds
    When the user starts a new thread on that branch from the thread's menu
    Then the task will run in that worktree
    And no branch is switched

  # Upstream #20825: a remote branch reuses a local one only when it tracks that remote branch.
  @backlog @mobile @priority-low
  Scenario Outline: A remote branch reuses the worktree of the local branch that tracks it
    Given the local branch "feature/search" is checked out in another worktree and tracks <upstream>
    When the user chooses "origin/feature/search" as the task's branch
    Then <outcome>

    Examples:
      | upstream                  | outcome                                  |
      | "origin/feature/search"   | the task will run in that worktree       |
      | "fork/feature/search"     | that worktree is not reused              |

  # Upstream #20825: reusing a worktree's root would move an agent out of a subfolder project.
  @backlog @mobile @priority-low
  Scenario: A subfolder project is not moved to another worktree's root
    Given the project "web" is the folder "apps/web" of its repository
    And "feature/search" is checked out in another worktree of that repository
    When the user chooses "feature/search" as the task's branch
    Then the user is told to choose another branch or start in a new worktree
    And the task keeps the branch it had

  @backlog @mobile @priority-high
  Scenario: A branch that is not checked out anywhere is switched to when the task is started in the project folder
    Given "feature/search" is not checked out anywhere
    When the user chooses "feature/search" as the task's branch
    Then the project folder is switched to "feature/search"
    And the task will run on it

  @backlog @mobile
  Scenario: A branch that cannot be switched to is not chosen
    Given switching "shop" to "feature/search" fails with "local changes would be overwritten"
    When the user chooses "feature/search" as the task's branch
    Then the user is told the branch could not be switched and why
    And the task keeps the branch it had

  @backlog @mobile
  Scenario: Starting a task on a thread's branch switches the folder first
    Given the thread "Fix checkout" is on the branch "feature/cart"
    When the user starts a new thread on that branch from the thread's menu
    Then the screen says the branch is being switched
    And the new task opens once the project folder is on "feature/cart"

  @backlog @mobile @priority-low
  Scenario: The user cannot leave while the branch is being switched
    Given a new task on "feature/cart" is switching the project folder
    When the user tries to go back
    Then the screen stays until the switch has finished

  @backlog @mobile
  Scenario: A thread's branch that cannot be switched to returns the user to the thread
    Given switching the project folder to "feature/cart" fails
    When the user starts a new thread on the branch of "Fix checkout" from the thread's menu
    Then the user is told the branch could not be switched and why
    And the user is back on "Fix checkout"

  # Upstream #25712: a reconnect while the branch is being switched does not switch it again.
  @backlog @mobile
  Scenario: A reconnect while the task's branch is being switched switches it once
    Given a new task on "feature/cart" is switching the project folder
    When the phone loses and regains its connection to "Office Mac" before the switch finishes
    Then the project folder is switched to "feature/cart" once
    And the new task opens when that switch finishes

  # Upstream #25706: a Local choice made before the branches load picks up the current branch.
  @backlog @mobile @priority-low
  Scenario: Choosing the project folder before its branches load picks up the current branch
    Given the project folder of "shop" is on "feature/cart" and its branches have not loaded yet
    When the user chooses to run the new task in the project folder
    And the phone app is closed and reopened before the branches load
    Then the task reads "feature/cart" once the branches load, and is sent on it

  # Upstream #25706: a new worktree with no chosen base starts from the project's default branch.
  @backlog @mobile @priority-low
  Scenario: A new worktree without a chosen base starts from the project's default branch
    Given "shop" has the default branch "main" and only "origin/main" exists
    When the user chooses a new worktree for the task without choosing a base
    Then the task reads "origin/main" as its base, and is sent with it

  @backlog @mobile @priority-low
  Scenario Outline: The task's branch list explains why it has nothing to choose
    When the user opens the branch list of the new task and <situation>
    Then the list says "<message>"

    Examples:
      | situation                         | message               |
      | the branches have not arrived yet | Loading branches…     |
      | the project has no branches       | No branches available |
      | a search matches no branch        | No matching branches  |

  @backlog @mobile @priority-low
  Scenario: A branch search ignores case and finds a dashed branch by typed spaces
    Given "feature/login-page" is a branch of "shop"
    When the user searches the new task's branches for "Login Page"
    Then "feature/login-page" is listed

  @backlog @mobile @priority-low
  Scenario: A branch that exists only on the remote is listed and labelled as remote
    Given "feature/cart" exists on the remote of "shop" but nowhere locally
    When the user opens the branch list of the new task
    Then "feature/cart" is listed with a "remote" label

  @backlog @mobile @priority-low
  Scenario: A branch list that could not be loaded can be asked for again
    Given "My MacBook" cannot list the branches of "shop"
    When the user opens the branch list of the new task
    Then the list says why the branches could not be loaded
    When "My MacBook" can list the branches again
    And the user asks to try again
    Then the branches are listed

  @backlog @mobile @priority-low
  Scenario: The task's branch list loads more branches as the user scrolls
    Given "shop" has more branches than one page holds
    When the user opens the branch list of the new task
    And the user scrolls to the end of the list
    Then the next branches are listed

  @backlog @mobile @priority-high
  Scenario: A task the phone cannot save for sending is not started
    Given the user wrote a new task in "shop"
    And the phone cannot save the task for sending
    When the user starts the task
    Then the user is told the task could not be queued and why
    And the draft is kept in the editor

  @backlog @mobile @priority-high
  Scenario Outline: A task cannot be started until it can be sent
    Given the user is writing a new task in "shop"
    When <situation>
    Then the task cannot be started yet

    Examples:
      | situation                                               |
      | the prompt holds only spaces                            |
      | no model is chosen                                      |
      | a new worktree is chosen with no base branch           |
      | a pasted text is still being turned into an attachment  |
      | the voice input is still being transcribed              |
      | the task is already being sent                          |

  # Upstream #17409: a photo shared to the app could not start a task until text was typed,
  # and a task with only a photo stayed in the outbox.
  @backlog @mobile
  Scenario: A task with only a photo can be started and is sent
    Given the user shared a photo to HAL-C2 and the new task holds it with no text
    When the user starts the task
    Then the thread is created with the photo as its first message

  @backlog @mobile @priority-low
  Scenario: The project picker has one No project row on top
    Given several machines are connected
    When the user opens the project picker
    Then a single No project row is at the top, above the projects
    And it starts on the selected machine when that machine offers it, otherwise on the first that does
    And scratch projects are never listed as projects

  # Upstream #19641: a draft without a project reads "No project" in the project picker.
  @backlog @mobile @priority-low
  Scenario: A draft without a project says No project
    Given the user is drafting a new task with No project chosen
    Then the project choice reads "No project"
    And No project is marked as chosen in the project picker

# Upstream #24741: New thread starts in the current or last project, else the picker.
Rule: New thread starts in the project the user is working in

  @backlog @mobile
  Scenario Outline: New thread starts in the project the user is working in
    Given <where>
    When the user starts a new thread from the thread list
    Then <result>

    Examples:
      | where                                                                  | result                                           |
      | the user is in a thread of "shop"                                      | the new task's draft is in "shop"                |
      | the user is in a subagent or archived thread of "shop"                 | the new task's draft is in "shop"                |
      | the user is in no thread and last opened a thread of "docs" on the phone | the new task's draft is in "docs"              |
      | the user has not opened or chosen a project on the phone               | the project picker opens                         |

  @backlog @mobile @priority-low
  Scenario: Turning off Use last project always opens the project picker
    Given the user turned off "Use last project" in Settings, General, New threads, on the phone
    And the user is in a thread of "shop"
    When the user starts a new thread from the thread list
    Then the project picker opens
    And "Use last project" stays on for the user's other phones

  @backlog @mobile @priority-low
  Scenario: Backing out of the first project picker closes the draft
    Given the project picker opened for a new thread
    When the user backs out of it without choosing
    Then no draft is left open in a project nobody chose

  # Upstream #24269: adding a project from the new task flow opens that project's draft.
  @backlog @mobile
  Scenario: Adding a project from the new task flow opens its draft on the chosen machine
    Given the user chose "Office Mac" in the new task flow
    When the user adds the folder "~/dev/shop" as a project
    Then the new task's draft opens in "shop" on "Office Mac" once the project is listed
    And the screen goes straight to the draft, without passing through the thread list

  @backlog @mobile
  Scenario: A project added after the user moved on does not take them back
    Given the user added a project from the new task flow
    And the user left that flow and opened another screen before the project was listed
    When the project is listed
    Then the user stays on the screen they opened
