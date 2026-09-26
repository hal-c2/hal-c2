# Sources:
#   apps/tui/src/approvals.ts, approvals.test.ts
#   apps/tui/src/userInput.ts, userInput.test.ts
#   apps/tui/src/proposedPlan.ts, proposedPlan.test.ts
#   apps/tui/src/components/ComposerPendingUserInputPanel.tsx, ComposerPendingUserInputPanel.test.tsx
#   apps/tui/src/components/MessagesTimeline.tsx (plan card, approval count)
#   apps/tui/src/components/ChatView.tsx (^A/^R, ^U, ^Y, question submit, contextual key hints)
#   apps/tui/src/hooks/useKeyBindings.ts (userInput mode, approval navigation)
#   apps/tui/src/features.backlog.test.ts (plan-workspace)
#   Shared domain: timeline/ owns approvals, questions and plans on every surface.

Feature: Approvals, questions and plans from the keyboard
  When the agent needs the user, the terminal client says so in the composer and every
  answer is one chord away. Nothing needs the mouse.

  Background:
    Given the terminal client is open on a thread with focus in the prompt

  @tui
  Scenario: A pending approval shows its chords in the key hints
    Given the agent asks to run "rm -rf build"
    Then the key hints offer "^A/^R approve"

  @tui
  Scenario: Ctrl+A approves the pending request
    Given the agent asks to run "rm -rf build"
    When the user presses "Ctrl+A"
    Then the request is approved
    And the status line says "Approved."

  @tui
  Scenario: Ctrl+R declines the pending request
    Given the agent asks to run "rm -rf build"
    When the user presses "Ctrl+R"
    Then the request is declined
    And the status line says "Declined."

  @tui
  Scenario: A failed approval is reported instead of claiming success
    Given the agent asks to run "rm -rf build"
    When the user approves it and the request fails
    Then the status line says the approval failed
    And the request stays pending

  @tui
  Scenario: Several approvals show a count and the selected one
    Given the agent has three pending approvals
    Then the timeline shows that three approvals are pending
    And the first one is highlighted

  @tui @backlog
  Scenario: The approval panel sits in the conversation pane under the timeline
    Given the agent has three pending approvals
    Then the approval panel is inside the conversation frame and as wide as the timeline
    And the selected approval's "▸" marker is in the accent colour

  @tui
  Scenario: Arrow keys choose between approvals when the reply is empty
    Given the agent has three pending approvals
    And the prompt is empty
    When the user presses "Down"
    Then the second approval is highlighted
    And "Ctrl+A" approves that one

  @tui
  Scenario: Arrow keys move the cursor when the reply has text
    Given the agent has three pending approvals
    And the prompt contains two lines of text
    When the user presses "Up"
    Then the cursor moves up a line and the highlighted approval does not change

  @tui
  Scenario: A resolved approval disappears from every client
    Given the agent asks to run "rm -rf build"
    When another client approves it
    Then the request is no longer pending in the terminal client

  @tui
  Scenario: A question from the agent opens inside the composer
    Given the agent asks "Which database?" with the options "Postgres" and "SQLite"
    Then the composer shows the question with its options
    And the primary action is "Submit answer"

  @tui
  Scenario: Enter answers a single-choice question with the highlighted option
    Given the agent asks "Which database?" with the options "Postgres" and "SQLite"
    When the user moves to "SQLite" and presses "Enter"
    Then the answer "SQLite" is sent
    And the status line says "Answer sent."

  @tui
  Scenario: Space toggles options in a multiple-choice question
    Given the agent asks "Which checks?" allowing several of "lint", "test" and "build"
    When the user toggles "lint" and "test" with "Space" and presses "Enter"
    Then the answer is "lint" and "test"

  @tui
  Scenario: Space types a space while writing a custom answer
    Given a question is pending
    When the user types "use the staging db" as a custom answer
    Then the custom answer keeps its spaces
    And no option is toggled

  @tui
  Scenario: A typed custom answer wins over the highlighted option
    Given the agent asks "Which database?" with the options "Postgres" and "SQLite"
    When the user types "MySQL" and presses "Enter"
    Then the answer "MySQL" is sent

  @tui
  Scenario: Several questions are answered one after another
    Given the agent asks two questions in one request
    When the user answers the first
    Then the second question is shown
    And the answers are sent together after the last one

  @tui
  Scenario: Submitting without a choice asks for one
    Given a multiple-choice question with nothing selected
    When the user presses "Enter"
    Then the status line says "Pick an option or type an answer first."

  @tui
  Scenario: A custom answer is sent once even when Enter repeats
    Given the user typed a custom answer
    When the user presses "Enter" twice and the request fails
    Then one answer was sent
    And the custom answer is still in the composer

  @tui
  Scenario: Esc sets a question aside
    Given a question is pending
    When the user presses "Esc"
    Then the question panel closes and the user can write a normal reply

  @tui
  Scenario: Ctrl+U brings a set-aside question back
    Given the user set a pending question aside
    When the user presses "Ctrl+U"
    Then the question panel opens again

  @tui
  Scenario: Long option lists scroll around the highlighted option
    Given a question with thirty options
    When the user moves down to the twentieth option
    Then the twentieth option is visible and highlighted

  @tui
  Scenario: A proposed plan shows as a card without its title heading repeated
    Given the agent proposed a plan titled "Add caching"
    Then the timeline shows a plan card titled "Add caching"
    And the plan body does not repeat the title or a "Summary" heading

  @tui
  Scenario: Ctrl+Y implements the proposed plan
    Given the agent proposed a plan
    When the user presses "Ctrl+Y"
    Then the status line says "Implementing plan…"
    And the plan is handed to the agent to implement

  @tui @backlog
  Scenario: The plan card's caption is a caption, not a button
    Given the agent proposed a plan
    When the user clicks the plan card's caption
    Then the plan is not handed to the agent

  @tui
  Scenario: An implemented plan no longer offers to be implemented
    Given the latest plan was already implemented
    Then no plan card is shown
    And the key hints do not offer "^Y implement"

  @tui
  Scenario: The plan from the latest turn wins over a newer plan elsewhere
    Given the latest turn proposed a plan and an older turn's plan was edited later
    Then the plan card shows the latest turn's plan

  @backlog @tui
  Scenario: The plan shows step progress as the agent works
    Given the agent is implementing a plan with five steps
    Then the plan shows which steps are done, in progress and pending

  @backlog @tui
  Scenario: The user copies or saves the plan as Markdown
    Given the agent proposed a plan
    When the user saves the plan as Markdown
    Then a Markdown file with the plan is written to the workspace

  @backlog @tui
  Scenario: An implemented plan links to the thread that implemented it
    Given the plan was implemented in another thread
    Then the plan names that thread and the user can open it
