# Sources:
#   apps/tui/src/components/ComposerFooter.tsx, ComposerFooter.test.tsx
#   apps/tui/src/components/ChatComposer.tsx (the composer frame)
#   apps/tui/src/components/ComposerDock.tsx, ComposerDock.test.tsx (workspace and branch under the composer)
#   apps/tui/src/components/ChatView.tsx (pickers, plan mode persistence, new-thread draft, add project)
#   apps/tui/src/components/SelectOverlay.tsx
#   apps/tui/src/components/AddProjectOverlay.tsx
#   apps/tui/src/controls.ts, controls.test.ts
#   apps/tui/src/models.ts, models.test.ts
#   apps/tui/src/newThread.logic.ts, newThread.logic.test.ts
#   apps/tui/src/features.backlog.test.ts (composer-provider-state, composer-provider-traits)
#   Shared domain: composer/ owns the controls and threads/creating.feature owns new threads.

Feature: Composer controls and new-thread drafts in the terminal
  Model, effort, plan or build, and runtime access are chosen next to the prompt. A new thread
  is a prompt with a project, a workspace and a branch chosen before the first send.

  Background:
    Given the terminal client is open on a thread with focus in the prompt

  @tui
  Scenario: Controls read model, effort, access and mode in that order
    Then the composer shows the model, then the effort, then the access level, then plan or build

  @tui
  Scenario: The composer is a rounded box centred under the conversation
    Then the composer is framed by a rounded border in the faint colour
    And the composer is centred under the conversation, one column in from each side

  @tui
  Scenario: The footer reads like the OpenTUI client
    Given the terminal is 140 columns wide
    Then the composer footer reads "model gpt-5 ▾ │ effort medium ▾ │ ^O Full access ▾ │ ^B Build" with "▸ Send ⏎" at the right
    And the footer's separators are faint, its captions dim and its values in the text colour

  @tui
  Scenario: Plan mode lights up its control
    Given the terminal is 140 columns wide
    And the thread is in plan mode
    Then "^B Plan" is in the accent colour

  @tui
  Scenario: Send lights up once there is something to send
    Then "▸ Send" is in the dim colour
    When the user types "hello"
    Then "▸ Send" is in the accent colour

  @tui
  Scenario: A running turn offers Stop in the error colour
    Given the agent is working
    Then the primary action reads "■ Stop Esc"
    And "■ Stop" is in the error colour

  @tui
  Scenario: A compact composer folds secondary controls into the command menu
    Given the conversation column is narrow
    Then only the primary controls are shown in the composer
    And the rest are reachable from the command palette

  @tui
  Scenario: A compact composer puts the primary action under the model
    Given the conversation column is narrow
    Then the composer footer's first row reads "model gpt-5 ▾" with "^K options" at the right
    And its second row has "▸ Send ⏎" at the right

  @tui
  Scenario: The user toggles plan and build mode
    Given the thread is in build mode
    When the user presses "Shift+Tab"
    Then the thread is in plan mode

  @tui
  Scenario: Toggling back returns to build mode
    Given the thread is in plan mode
    When the user presses "Ctrl+B"
    Then the thread is in build mode

  @tui
  Scenario: A failed mode change is undone and reported
    Given the thread is in build mode
    When the user switches to plan mode and the server rejects it
    Then the composer shows build mode again
    And the status line shows the error

  @tui
  Scenario Outline: Runtime access uses the web app's names
    When the user opens the runtime access picker
    Then "<label>" is offered

    Examples:
      | label             |
      | Supervised        |
      | Auto-accept edits |
      | Auto              |
      | Full access       |

  @tui
  Scenario: The model picker lists only usable providers
    Given one provider is disabled and another is unavailable
    When the user opens the model picker
    Then neither provider's models are listed

  @tui
  Scenario: Choosing a model applies its default effort and options
    When the user picks a model with a reasoning setting
    Then the model's default effort is selected

  @tui
  Scenario: Changing effort keeps the model's other options
    Given a model with effort and other options set
    When the user changes the effort
    Then the other options are unchanged

  @tui
  Scenario: The next reply carries every control the user changed
    Given the user changed the model, the effort and switched to plan mode
    When the user sends the next reply
    Then the reply is sent with that model, effort and plan mode

  @tui
  Scenario: Clicking an open picker's control again closes it
    Given the model picker is open
    When the user clicks the model control again
    Then the model picker closes

  @tui
  Scenario: A new thread inherits the selected thread's project and workspace
    Given the selected thread is in "shop" on a worktree
    When the user presses "Ctrl+N"
    Then the new-thread draft uses "shop" and the same workspace

  @tui
  Scenario: A new thread defaults to a new worktree when the server says so
    Given no thread is selected and the server default is a new worktree
    When the user starts a new thread
    Then a new worktree from the current branch is preselected

  @tui
  Scenario Outline: A new-thread draft explains what is missing
    Given a new-thread draft <gap>
    When the user presses "Enter"
    Then the status line says "<message>"
    And the draft is kept

    Examples:
      | gap                                  | message                                                |
      | with no project                      | Add or select a project before creating a thread.      |
      | with an empty task                   | Describe the task before creating the thread.          |
      | with no model                        | Select a model before creating the thread.             |
      | for a new worktree with no base      | Select a base branch before creating a new worktree.   |

  @tui
  Scenario: A new-worktree draft takes the chosen branch as its base
    Given a new-thread draft for a new worktree
    When the user chooses the base branch "develop" and sends the task
    Then the worktree is created from "develop"
    And the current checkout does not change

  @tui
  Scenario: Choosing a branch that already has a worktree reuses it
    Given the branch "feature/x" is checked out in a worktree
    When the user chooses "feature/x" for a new-thread draft on the current workspace
    Then the draft uses that existing worktree

  @tui
  Scenario: Choosing another branch for the current checkout switches it before sending
    Given a new-thread draft on the current checkout
    When the user chooses the branch "develop" and sends the task
    Then the checkout switches to "develop" before the thread starts

  @tui
  Scenario: Discarding a draft while its branch switch is running waits
    Given the checkout is switching branches for a new-thread draft
    When the user presses "Esc"
    Then the draft is kept
    And the status line says "Wait for the branch switch to finish."

  @tui
  Scenario: Esc clears a new-thread draft
    Given a new-thread draft with a task and an attached image
    When the user presses "Esc"
    Then the task and the image are cleared

  @tui
  Scenario: A failed thread creation keeps the task and sends once
    Given a new-thread draft with the task "Add caching"
    When the user presses "Enter" twice and creation fails
    Then only one creation request was made
    And the prompt still contains "Add caching"

  @tui
  Scenario: The user adds a project from a local folder
    When the user adds the local folder "~/code/shop" as a project
    Then "shop" is added and a new-thread draft opens in it

  @tui
  Scenario: The user adds a project by cloning a Git URL
    When the user adds a project from a Git URL
    Then the client asks where to clone it
    And the status line says "Cloning repository…" until the project is added

  @tui
  Scenario: Adding a folder that is already a project says so
    Given "~/code/shop" is already a project
    When the user adds "~/code/shop" again
    Then the status line says "Project already added. What should we build?"

  @backlog @tui
  Scenario: A disabled or signed-out provider explains itself in the composer
    Given the thread's provider is signed out
    Then the composer says the provider needs sign-in and how to fix it

  @backlog @tui
  Scenario: A model change that needs a new thread says so
    When the user picks a model from a provider the thread cannot switch to
    Then the client explains that a new thread is needed

  @tui
  Scenario: Provider configuration refreshes live
    When a provider's models change on the server
    Then the model picker lists the new models without restarting the client

  @backlog @tui
  Scenario: The user sets select and boolean provider traits
    Given the model has a select trait and a boolean trait
    When the user changes both
    Then the next reply is sent with those trait values

  @backlog @tui
  Scenario: Provider traits fold into a compact menu on a narrow terminal
    Given the terminal is narrow
    Then provider traits are reachable from one compact menu

  @tui
  Scenario: A new thread's workspace and branch sit under the composer
    When the user presses "Ctrl+N"
    Then the prompt placeholder reads "What should we build in Project one?"
    And under the composer "Project workspace ▾" is on the left and "branch main ▾" on the right in the dim colour
    And no new-thread form is shown

  @tui
  Scenario: Clicking the workspace under the composer picks where the thread works
    When the user presses "Ctrl+N"
    And the user clicks "Project workspace ▾"
    Then the picker offers "Current checkout" and "New worktree"

  @tui
  Scenario: Clicking the branch under the composer picks the base branch
    When the user presses "Ctrl+N"
    And the user clicks "branch main ▾"
    Then the branch picker opens

  @tui
  Scenario: A thread in a repository names its checkout under the composer
    Given the thread works in the project's checkout on "main"
    Then under the composer "Local checkout" is on the left and "branch main" on the right in the dim colour

  # The OpenTUI client's pickers (SelectOverlay.tsx) and add-project flow
  # (AddProjectOverlay.tsx) float above the prompt, which stays in place.

  @tui @backlog
  Scenario: A picker is a rounded box above the prompt, headed by its title and keys
    When the user opens the runtime access picker
    Then the picker has a rounded border in the accent colour
    And the picker's first row reads "access ▸ ↑/↓ or click · Enter apply · Esc cancel"
    And "access ▸ " is in the accent colour and "↑/↓ or click · Enter apply · Esc cancel" in the dim colour
    And the prompt is still shown under the picker

  @tui @backlog
  Scenario: Each picker option is its name over its description
    When the user opens the runtime access picker
    Then the picker's rows read:
      | row                                                                |
      |   Supervised                                                       |
      |     Ask before commands and file changes.                          |
      |   Auto-accept edits                                                |
      |     Auto-approve edits, ask before other actions.                  |
      |   Auto                                                             |
      |     An AI reviewer approves routine actions; risky ones still ask. |
      | ▸ Full access                                                      |
      |     Allow commands and edits without prompts.                      |
    And both rows of "Full access" have the selected background
    And the description of "Full access" is in the background colour
    And "Supervised" and its description are in the dim colour

  @tui @backlog
  Scenario Outline: A picker with nothing to show says why
    Given the model list <condition>
    When the user presses "Ctrl+Shift+M"
    Then the picker's second row reads "<text>" in the <colour> colour

    Examples:
      | condition        | text              | colour |
      | is still loading | loading…          | dim    |
      | fails to load    | failed to load    | error  |
      | is empty         | nothing to choose | dim    |

  @tui @backlog
  Scenario: Adding a project opens above the prompt with its sources listed
    When the user chooses "Add project" from the command palette
    Then the add-project box has a rounded border in the accent colour
    And the prompt is still shown under the add-project box
    And the add-project box's first row reads "＋ Search project sources…" with "Select" at its right end in the accent colour
    And the add-project box's second row reads "New project · Source ▸ ↑/↓ navigate · Enter select · Tab edit · Esc back"
    And the add-project box's next rows read "▸ Local folder" and "    Browse a folder on disk"

  @tui @backlog
  Scenario: A source that needs setup says so in the warning colour
    When the user chooses "Add project" from the command palette
    Then "GitHub repository" is followed by "  setup required" in the warning colour
    And "GitHub repository" is in the faint colour

  @tui @backlog
  Scenario: Tab moves between the add-project field and its list
    Given the user chose "Add project" from the command palette
    When the user presses "Tab"
    Then the add-project field has the keys
    And the add-project box's second row reads "New project · Source ▸ Enter action · Tab browse · Esc back"
    When the user presses "Tab"
    Then the add-project list has the keys again

  @tui @backlog
  Scenario: Browsing a local folder names the path and its action
    When the user chooses "Add project" from the command palette
    And the user chooses the "Local folder" source
    Then the add-project box's first row ends with "Add" in the accent colour
    And the add-project box's second row reads "New project · Local folder ▸ Enter action · Tab browse · Esc back"
