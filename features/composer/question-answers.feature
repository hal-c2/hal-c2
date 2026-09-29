# Sources:
#   docs/user/question-attachments.md
#   apps/tui/src/userInput.ts
#   apps/tui/src/components/ChatView.tsx (question panel, defer and reopen)
#   apps/web/src/components/chat/ComposerPendingUserInputPanel.tsx
#   apps/web/src/components/chat/ComposerPrimaryActions.tsx (question navigation, plan follow-up)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (Implement, approvals waiting)

Feature: Answering the agent's questions from the composer
  When the agent asks the user questions, the composer becomes the place to
  answer them. Answers can be picked, typed or put off, and the plan the agent
  proposed can be implemented from here.

  Background:
    Given the agent has asked "Which database?" with options "Postgres" and "SQLite"

  @tui
  Scenario: Picking an option answers the question
    When the user picks "Postgres" and submits
    Then the agent receives "Postgres" as the answer
    And the user is told the answer was sent

  @tui
  Scenario: A typed answer wins over a picked option
    Given the user picked "SQLite"
    When the user types "MySQL" and submits
    Then the agent receives "MySQL" as the answer

  @tui
  Scenario: A question that allows several answers takes them all
    Given the question allows several answers
    When the user picks "Postgres" and "SQLite" and submits
    Then the agent receives both answers

  @tui
  Scenario: Submitting with no answer is refused
    When the user submits without picking or typing anything
    Then the user is asked to pick an option or type an answer first
    And nothing is sent

  @tui
  Scenario: A deferred question can be reopened
    When the user puts the question off
    Then the user can write a normal message
    When the user reopens the pending question
    Then "Which database?" is shown again with its options

  @desktop @mobile @backlog-mobile
  Scenario: A question can be dismissed without an answer
    When the user dismisses the question without answering
    Then the agent is told the question was dismissed

  @backlog @desktop @mobile
  Scenario: Files can be attached to a typed answer and stay with that question
    Given the user has a separate draft "unrelated"
    When the user types "use this schema" and attaches "schema.sql"
    And submits the answer
    Then the agent receives "use this schema" with "schema.sql"
    And the normal draft still reads "unrelated"

  @backlog @desktop @mobile
  Scenario: A question with only fixed choices takes no attachments
    Given the question only allows its listed options
    When the user tries to attach a file
    Then the user is told this question cannot accept attachments

  @backlog @desktop @mobile
  Scenario: A failed answer keeps what the user wrote
    Given the user typed "MySQL"
    When submitting the answer fails
    Then the answer still reads "MySQL"

  @tui @desktop
  Scenario: A proposed plan is implemented from the composer
    Given the agent proposed a plan and the thread is idle
    When the user chooses to implement the plan
    Then a turn starts that carries out the plan
