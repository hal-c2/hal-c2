# Sources:
#   apps/mobile/src/features/threads/NewTaskRouteScreen.tsx (project choice, empty states, search)
#   apps/mobile/src/features/threads/new-task-project-selection.ts (scopes, environment match)
#   apps/mobile/src/features/threads/NewTaskDraftRouteScreen.tsx (branch switch before the draft opens)
#   apps/mobile/src/features/threads/NewTaskContextPickerScreens.tsx (branch picker, switch failure)
#   apps/mobile/src/features/threads/NewTaskContextPickerScreens.tsx (branch picker empty states, retry, paging)
#   apps/mobile/src/features/threads/NewTaskDraftScreen.tsx (a task the outbox cannot save)
#   apps/mobile/src/features/threads/new-task-context-presentation.ts (checkout, worktree and branch labels)
#   apps/mobile/src/state/use-composer-drafts.ts (retargetNewTaskDraft), apps/mobile/src/state/pending-thread-creation.ts, apps/mobile/src/state/pending-new-tasks-model.ts (unstarted and pending tasks)
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

  @backlog @mobile
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

  @backlog @mobile
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

  @backlog @mobile
  Scenario: Aiming the task at another project keeps what was written
    Given the user wrote "Add search" and attached a photo in a new task for "shop"
    When the user aims the task at the project "web"
    Then the new task editor still holds "Add search" and the photo
    And no second unstarted task is created for "web"

  @backlog @mobile
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

  @backlog @mobile
  Scenario: A branch checked out in another worktree starts the task there
    Given "feature/search" is checked out in another worktree of "shop"
    When the user chooses "feature/search" as the task's branch
    Then the task will run in that worktree
    And no branch is switched

  @backlog @mobile
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

  @backlog @mobile
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

  @backlog @mobile
  Scenario Outline: The task's branch list explains why it has nothing to choose
    When the user opens the branch list of the new task and <situation>
    Then the list says "<message>"

    Examples:
      | situation                         | message               |
      | the branches have not arrived yet | Loading branches…     |
      | the project has no branches       | No branches available |
      | a search matches no branch        | No matching branches  |

  @backlog @mobile
  Scenario: A branch list that could not be loaded can be asked for again
    Given "My MacBook" cannot list the branches of "shop"
    When the user opens the branch list of the new task
    Then the list says why the branches could not be loaded
    When "My MacBook" can list the branches again
    And the user asks to try again
    Then the branches are listed

  @backlog @mobile
  Scenario: The task's branch list loads more branches as the user scrolls
    Given "shop" has more branches than one page holds
    When the user opens the branch list of the new task
    And the user scrolls to the end of the list
    Then the next branches are listed

  @backlog @mobile
  Scenario: A task the phone cannot save for sending is not started
    Given the user wrote a new task in "shop"
    And the phone cannot save the task for sending
    When the user starts the task
    Then the user is told the task could not be queued and why
    And the draft is kept in the editor

  @backlog @mobile
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
