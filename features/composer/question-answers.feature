# Sources:
#   docs/user/question-attachments.md
#   apps/tui/src/userInput.ts
#   apps/tui/src/components/ChatView.tsx (question panel, defer and reopen)
#   apps/web/src/components/chat/ComposerPendingUserInputPanel.tsx
#   apps/web/src/components/ChatView.tsx (answers wait for their uploads)
#   apps/web/src/components/chat/ComposerPrimaryActions.tsx (question navigation, plan follow-up)
#   apps/web/src/pendingUserInput.ts, apps/web/src/questionAttachments.ts (what counts as an answer, files across a request's questions)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (Implement, approvals waiting)
#   apps/mobile/src/features/threads/PendingUserInputCard.tsx (fold away, not resumable, submit lock)
#   apps/mobile/src/features/threads/QuestionAttachments.tsx (capability, too many, resolved elsewhere)
#   apps/mobile/src/features/threads/QuestionAnswerHistory.tsx (answered question with files)
#   apps/mobile/src/lib/threadActivity.ts (typed answer or picked option, answers built per question)

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

  @backlog @desktop
  Scenario: A question that could not be dismissed stays and says why
    Given the environment refuses to dismiss the question
    When the user dismisses the question without answering
    Then the thread shows the reason, or "Failed to dismiss the question." when none is given
    And the question is still waiting for an answer

  @desktop @mobile @backlog-mobile
  Scenario: Files can be attached to a typed answer and stay with that question
    Given the user has a separate draft "unrelated"
    When the user types "use this schema" and attaches "schema.sql"
    And submits the answer
    Then the agent receives "use this schema" with "schema.sql"
    And the normal draft still reads "unrelated"

  @desktop @mobile @backlog-mobile
  Scenario: A question with only fixed choices takes no attachments
    Given the question only allows its listed options
    When the user tries to attach a file
    Then the user is told this question cannot accept attachments

  @desktop @mobile @backlog-mobile
  Scenario: A failed answer keeps what the user wrote
    Given the user typed "MySQL"
    When submitting the answer fails
    Then the answer still reads "MySQL"

  @tui @desktop
  Scenario: A proposed plan is implemented from the composer
    Given the agent proposed a plan and the thread is idle
    When the user chooses to implement the plan
    Then a turn starts that carries out the plan

  @backlog @mobile
  Scenario: The question panel can be folded away to read the conversation
    Given the agent is waiting for the user's answer
    When the user folds the question panel away
    Then the conversation can be read and the question stays pending
    When the user opens the question panel again
    Then the question and what the user already answered are shown

  @backlog @mobile
  Scenario: A question that can no longer be answered disables its controls
    Given the agent asked a question and its session can no longer take the answer
    Then the user cannot submit an answer to it

  @backlog @mobile
  Scenario: A question already being answered cannot be submitted twice
    Given the user submitted the answer to "Which database?"
    And the answer is still on its way to the agent
    Then submitting is unavailable

  @backlog @mobile
  Scenario: An environment that does not take attachments to answers offers none
    Given the environment does not support attachments to answers
    When the user looks at a question that allows a typed answer
    Then no way of attaching a file to the answer is offered

  @backlog @mobile
  Scenario: Too many attachments on an answer are refused
    Given the answer to "Which schema?" already carries the most attachments it can
    When the user attaches another file
    Then the user is told the file could not be attached because there are too many attachments
    And the file is not attached

  @backlog @desktop
  Scenario: An answer is not sent while its files are still uploading or failed
    Given the answer to "Which database?" has a file that has not finished uploading
    When the user submits the answers
    Then the user is told "Wait for attachments to finish uploading, or remove failed uploads."
    And the question stays open with what the user wrote

  @backlog @mobile
  Scenario: A question answered elsewhere while the user picks a file drops that file
    Given the user is choosing a file for the answer to "Which schema?"
    When another client answers the question
    Then the chosen file is not attached to anything
    And the user is not left with a question that is no longer pending

  @backlog @mobile
  Scenario: An answered question stays in the conversation with its answers and files
    Given the user answered "Which schema?" with "use this one" and attached "schema.sql"
    When the user reads the conversation
    Then the question is listed with the answer "use this one"
    And "schema.sql" is listed under the answer and can be opened

  @backlog @desktop
  Scenario: A number key picks the option in that place
    Given the user is not typing in the composer
    When the user presses 2
    Then "SQLite" is picked
    When the user is typing an answer and presses 2
    Then "2" is typed into the answer and no option is picked

  @backlog @desktop
  Scenario: Picking an option of a single-choice question moves on to the next question
    Given the agent asked "Which database?" and "Which cache?" in one request
    When the user picks "Postgres"
    Then "Which cache?" is shown with "Postgres" kept as the first answer

  @backlog @desktop
  Scenario: A question that allows several answers waits for the user to move on
    Given the question allows several answers
    Then the user is told "Select one or more options."
    When the user picks "Postgres"
    Then "Which database?" is still shown so "SQLite" can be picked too

  @backlog @desktop
  Scenario: Several questions are stepped through and answered together
    Given the agent asked "Which database?" and "Which cache?" in one request
    Then the question is marked "1/2" and the user can go on to the next question
    When the user answers both questions
    Then the user can go back to the previous question to change its answer
    And submitting sends both answers to the agent together

  @backlog @desktop
  Scenario: The first question still unanswered is the one shown
    Given the agent asked "Which database?" and "Which cache?" in one request
    And the user answered "Which database?" and left the thread
    When the user opens the thread again
    Then "Which cache?" is shown

  @backlog @desktop
  Scenario: Picking an option after typing an answer gives the typed text back to the draft
    Given the thread's draft reads "unrelated"
    And the user typed "MySQL" as the answer
    When the user picks "Postgres"
    Then the answer is "Postgres"
    And the thread's draft reads "unrelated" followed by "MySQL"

  @backlog @desktop
  Scenario: A file alone answers a question that allows a typed answer
    When the user attaches "schema.sql" and submits without picking or typing anything
    Then the agent receives "schema.sql" as the answer

  @backlog @desktop
  Scenario: The questions of one request share the attachment limit
    Given the agent asked "Which database?" and "Which cache?" in one request
    And the answer to "Which database?" already carries the most attachments a message can
    When the user attaches a file to the answer to "Which cache?"
    Then the file is not attached
    And the user is told there are too many attachments

  @backlog @desktop
  Scenario: The question is folded away on the desktop to read the conversation
    When the user hides the question and its options
    Then only the question's title stays above the composer
    And number keys pick nothing while it is hidden
    When the user shows the question again
    Then the options and what the user already picked are shown

  @backlog @desktop
  Scenario: A question asked during a turn still lets the user stop the turn
    Given the agent asked the question while its turn is still running
    Then the user can stop the turn as well as answer the question

  @backlog @desktop
  Scenario: Files cannot be removed from an answer that is on its way
    Given the user typed "use this schema" and attached "schema.sql"
    When the user submits the answer and the agent has not taken it yet
    Then "schema.sql" cannot be removed from the answer
    And the question cannot be dismissed

  @backlog @mobile
  Scenario: A typed answer wins over a picked option on the phone
    Given the user picked "SQLite"
    When the user types "MySQL" and submits
    Then the agent receives "MySQL" as the answer

  @backlog @mobile
  Scenario: Typing an answer lets go of the picked options
    Given the user picked "SQLite"
    When the user types "MySQL"
    Then "SQLite" is no longer shown as picked
    When the user clears the typed answer
    Then no option is shown as picked

  @backlog @mobile
  Scenario: Picking an option on the phone replaces what was typed
    Given the user typed "MySQL" as the answer
    When the user picks "Postgres"
    Then "Postgres" is shown as picked
    And the typed answer is empty

  @backlog @mobile
  Scenario: Picking an option again takes it back when a question allows several answers
    Given the question allows several answers
    And the user picked "Postgres" and "SQLite"
    When the user picks "SQLite" again
    Then only "Postgres" is picked

  @backlog @mobile
  Scenario: A question that does not allow a typed answer ignores typed text
    Given the question allows only its listed options
    When the user submits without picking an option
    Then nothing is sent

  @backlog @mobile
  Scenario: Questions in one request are sent only when each has an answer
    Given the agent asked "Which database?" and "Which cache?" in one request
    And the user answered only "Which database?"
    Then the answers cannot be submitted
    When the user answers "Which cache?" too
    Then both answers are sent together
