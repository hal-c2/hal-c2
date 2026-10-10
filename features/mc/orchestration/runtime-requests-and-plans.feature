# Sources:
#   packages/contracts/src/orchestrationV2.ts (runtime-request.respond, runtime-request.updated,
#     thread.user-input.dismiss, plan.updated, turn-item.updated, node.updated)
#   apps/server-ex/lib/hal_c2/orchestration.ex (runtime-request.respond, thread.user-input.dismiss,
#     implemented_plan)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (open_request, open_question,
#     resolve_request, plans)
#   apps/server/src/orchestration-v2/ (runtime request lifecycle)
#   apps/server/src/orchestration-v2/Orchestrator.ts, RuntimeRequestService.ts (answers given by
#     message, optional questions, requests that cannot be resumed)
#   apps/server/src/orchestration-v2/ProviderRuntimeRecoveryService.ts (requests at startup and shutdown)
#   apps/server/src/orchestration-v2/ProviderSessionManager.ts (requests when a session closes, requests
#     raised before a run)
#   apps/server/src/orchestration-v2/ProviderEventIngestor.ts (requests at turn end, step durations)
#   apps/server/src/orchestration-v2/EventSink.ts (an answer racing the end of its turn)
#   apps/server/src/orchestration/decider.ts (thread.user-input.respond and .dismiss refusals)
Feature: Approvals, questions and plans
  A provider can stop to ask for approval or to ask the user questions. The
  engine records each as a pending runtime request with a waiting item, and the
  user's answer resolves it. Plans the agent proposes are tracked so a later
  message can implement them.

  Background:
    Given an MC with a project "demo"
    And thread "t1" exists in "demo" with a running turn

  @mc
  Scenario Outline: A provider asking for approval opens a pending request
    When the provider asks for approval of a <kind> with prompt "May I?"
    Then "t1" has a pending runtime request of kind "<kind>" answerable live
    And the run has a waiting approval request item with prompt "May I?"

    Examples:
      | kind        |
      | command     |
      | file-change |
      | file-read   |
      | permission  |

  @mc
  Scenario: Approving a request resolves it and resumes the provider
    Given the provider asked for approval of a command
    When the user approves the request
    Then the request is resolved with decision accept
    And the approval item is completed

  # Codex has no "always"; both servers send it acceptForSession instead.
  @mc
  Scenario Outline: Every approval decision reaches the provider
    Given the provider asked for approval of a command
    When the user responds with decision "<decision>"
    Then the provider receives decision "<received>"
    And the request records decision "<decision>"

    Examples:
      | decision         | received         |
      | accept           | accept           |
      | acceptForSession | acceptForSession |
      | acceptAlways     | acceptForSession |
      | decline          | decline          |
      | cancel           | cancel           |

  @mc
  Scenario: A response without a decision declines
    Given the provider asked for approval of a command
    When the user responds to the request without a decision
    Then the request is resolved with decision decline

  @mc
  Scenario: Responding to a request nobody is waiting for is refused
    When the user responds to request "runtime-request:codex:gone"
    Then the command fails with "no pending request"

  @mc
  Scenario: A provider asking questions opens a user input request
    When the provider asks the user "Which database?" with options
    Then "t1" has a pending runtime request of kind "user_input"
    And the run has a waiting user input request item with the question

  @mc
  Scenario: Answering questions sends the answers to the provider
    Given the provider asked the user "Which database?"
    When the user answers "Postgres"
    Then the provider receives the answer "Postgres"
    And the user input item is completed with the answer

  @mc
  Scenario: Files attached to an answer are named with where they were saved
    Given the provider asked the user "Show me the error"
    When the user answers "Here" attaching "error.png"
    Then the provider receives "Here" followed by a line naming "error.png" and its saved path

  @mc
  Scenario: An answer whose attachment is no longer available is refused
    Given the provider asked the user "Show me the error"
    When the user answers attaching a file whose upload expired
    Then the command fails asking the user to attach it again

  @mc
  Scenario: Dismissing questions closes them without answering
    Given the provider asked the user "Which database?"
    When the user dismisses the questions
    Then the provider is told the questions were dismissed
    And the request is no longer pending

  @backlog @mc
  Scenario: A question the provider is blocked on cannot be dismissed
    Given the provider is blocked until it gets an answer to "Which database?"
    When the user dismisses the questions
    Then the command fails with "This question needs an answer. Answer it or stop the turn."
    And the request is still pending

  @backlog @mc
  Scenario Outline: A question that was already answered or dismissed cannot be dismissed again
    Given the provider asked the user "Which database?"
    And the questions were already <done>
    When the user dismisses the questions
    Then the command fails with "This question has already been answered."

    Examples:
      | done      |
      | answered  |
      | dismissed |

  @backlog @mc
  Scenario: A question answered by message needs every question answered
    Given the provider asked two questions it does not wait on
    When the user answers only the first
    Then the command fails with "Answer each question before sending."
    And nothing is sent to the thread

  @backlog @mc
  Scenario: A file cannot be attached to a question that only takes fixed choices
    Given the provider asked the user "Which database?" with fixed choices only
    When the user answers attaching "schema.sql"
    Then the command fails with "This question does not accept file references."

  @backlog @mc
  Scenario: Files attached to an answer for a question that is no longer pending are refused
    Given the provider asked the user "Show me the error"
    And the question has since closed
    When the user answers attaching "error.png"
    Then the command fails with "This question is no longer pending."

  @backlog @mc
  Scenario: Answers given by message reach the agent as one message of questions and answers
    Given the provider asked "Which database?" and "Which port?" without waiting on them
    When the user answers "Postgres" and "5432"
    Then "t1" receives one user message pairing each question with its answer, in the order asked
    And the questions are closed as answered

  @backlog @mc
  Scenario Outline: An answer given by message is delivered the way the provider can take it
    Given "t1" runs on a provider that <steering>
    And the provider asked a question it does not wait on and its turn is still running
    When the user answers
    Then the answer <delivery>

    Examples:
      | steering                       | delivery                                   |
      | can take messages mid-turn     | joins the running turn                     |
      | cannot take messages mid-turn  | waits in the queue behind the running turn |

  @backlog @mc
  Scenario: Optional questions answered by message may be left blank
    Given the provider asked a required question and an optional one without waiting on them
    When the user answers only the required question
    Then the answer is sent with the required question alone

  @backlog @mc
  Scenario: Leaving every optional question blank sends nothing
    Given the provider asked only optional questions without waiting on them
    When the user sends without answering any
    Then the command fails with "Enter an answer before sending."
    And nothing is sent to the thread

  @backlog @mc
  Scenario: A request that can no longer be answered refuses the answer with its reason
    Given a request of "t1" is still pending but marked as one that cannot be resumed, with a reason
    When the user responds to it
    Then the command fails with the reason recorded on the request
    And nothing is sent to the provider

  # Both servers mark a request left pending at startup expired, not cancelled.
  @mc
  Scenario: Pending requests expire when the MC restarts
    Given the provider asked for approval of a command
    When the MC restarts
    Then the request expires

  @mc
  Scenario: A pending request that cannot be answered after a restart is marked not resumable
    Given the provider asked for approval of a command
    When the MC restarts
    Then the request is marked not resumable rather than cancelled
    And the thread explains the request can no longer be answered

  @backlog @mc
  Scenario: Requests pending at a clean shutdown are cancelled rather than expired
    Given the provider asked for approval of a command
    When the MC shuts down cleanly
    Then the request is cancelled and marked not resumable
    And it says the server shut down before the request was resolved

  @backlog @mc
  Scenario: A question that can be answered by message survives a restart
    Given the provider asked a question the user can answer with a message
    When the MC restarts
    Then the question is still pending
    And the user can still answer it

  @backlog @mc
  Scenario Outline: A request left pending when its provider session closes says why
    Given the provider asked for approval of a command
    When the provider session of "t1" <ends>
    Then the request is <status> and marked not resumable
    And it says "<reason>"

    Examples:
      | ends                   | status    | reason                                                                |
      | fails                  | expired   | Provider session failed before this runtime request was resolved.     |
      | is stopped by the user | cancelled | Provider session was closed before this runtime request was resolved. |

  @backlog @mc
  Scenario Outline: A question only its running turn could take is closed when the turn ends
    Given the provider asked the user a question that only the running turn can receive the answer to
    When the provider's turn <ends> before the user answers
    Then the question is cancelled and no longer pending

    Examples:
      | ends           |
      | completes      |
      | fails          |
      | is interrupted |

  @backlog @mc
  Scenario: An answer given just as the turn ends is not erased
    Given the provider asked the user a question
    And the provider's turn ends at the same moment the user answers
    When the user's answer is recorded first
    Then the question stays answered with what the user chose
    And the turn's end does not mark it cancelled

  @backlog @mc
  Scenario: A provider that asks before any turn has started can be answered
    Given thread "t2" exists in "demo" and has not run a turn
    When the provider of "t2" asks the user to trust the project folder while its session starts
    Then "t2" has a pending request the user can answer
    And the answer reaches the provider

  @mc @backlog
  Scenario: A run waiting on a request shows as waiting
    When the provider asks for approval of a command
    Then the run of "t1" is waiting
    And it returns to running when the request is resolved

  @mc
  Scenario: A proposed plan is a draft until the provider finishes it
    When the provider streams a proposed plan
    Then "t1" has a draft plan that grows as it streams
    And the plan becomes active when the provider finishes it

  @mc
  Scenario: A to-do list is tracked as a plan that completes with its steps
    When the provider reports a to-do list with two steps, one done
    Then "t1" has an active to-do plan
    And the plan completes when every step is done

  @backlog @mc
  Scenario: A to-do step records how long it took
    Given the provider reported a to-do list whose first step is in progress
    When the provider reports that step done
    Then the step records the time from when it started until it was done
    And a step whose wording changed since does not take over that time

  @mc
  Scenario: Implementing a proposed plan completes it
    Given "t1" has an active proposed plan "p1"
    When the user sends "Implement it" to "t1" referring to plan "p1"
    Then plan "p1" is completed

  # The Node server completes a plan implemented from another thread of its project
  # (the composer's "Implement in a new thread").
  @mc
  Scenario: A plan implemented from another thread is completed
    Given thread "t2" has an active proposed plan "p2"
    When the user sends a message to "t1" referring to plan "p2" of "t2"
    Then plan "p2" is completed

  @backlog @mc
  Scenario: A plan from a thread of another project cannot be implemented
    Given thread "t2" of project "other" has an active proposed plan "p2"
    When the user sends a message to "t1" referring to plan "p2" of "t2"
    Then the command fails with "Proposed plan 'p2' belongs to thread 't2' in a different project."
    And plan "p2" is still active

  @backlog @mc
  Scenario: A plan that does not exist cannot be implemented
    When the user sends a message to "t1" referring to plan "gone" of "t1"
    Then the command fails with "Proposed plan 'gone' does not exist on thread 't1'."

  # Two devices, or a second press, can both ask to implement the same plan.
  @backlog @mc
  Scenario: A plan that was already implemented cannot be implemented again
    Given plan "p1" of "t1" was implemented and is completed
    When the user sends another message to "t1" referring to plan "p1"
    Then the command fails with "Proposed plan p1 is not active."
    And no second run starts for the plan
