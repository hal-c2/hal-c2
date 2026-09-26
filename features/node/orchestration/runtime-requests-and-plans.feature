# Sources:
#   packages/contracts/src/orchestrationV2.ts (runtime-request.respond, runtime-request.updated,
#     thread.user-input.dismiss, plan.updated, turn-item.updated, node.updated)
#   apps/server-ex/lib/t3/orchestration.ex (runtime-request.respond, thread.user-input.dismiss,
#     implemented_plan)
#   apps/server-ex/lib/t3/orchestration/turn_writer.ex (open_request, open_question,
#     resolve_request, plans)
#   apps/server/src/orchestration-v2/ (runtime request lifecycle)
Feature: Approvals, questions and plans
  A provider can stop to ask for approval or to ask the user questions. The
  engine records each as a pending runtime request with a waiting item, and the
  user's answer resolves it. Plans the agent proposes are tracked so a later
  message can implement them.

  Background:
    Given a node with a project "demo"
    And thread "t1" exists in "demo" with a running turn

  @node
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

  @node
  Scenario: Approving a request resolves it and resumes the provider
    Given the provider asked for approval of a command
    When the user approves the request
    Then the request is resolved with decision accept
    And the approval item is completed

  # Codex has no "always"; both servers send it acceptForSession instead.
  @node
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

  @node
  Scenario: A response without a decision declines
    Given the provider asked for approval of a command
    When the user responds to the request without a decision
    Then the request is resolved with decision decline

  @node
  Scenario: Responding to a request nobody is waiting for is refused
    When the user responds to request "runtime-request:codex:gone"
    Then the command fails with "no pending request"

  @node
  Scenario: A provider asking questions opens a user input request
    When the provider asks the user "Which database?" with options
    Then "t1" has a pending runtime request of kind "user_input"
    And the run has a waiting user input request item with the question

  @node
  Scenario: Answering questions sends the answers to the provider
    Given the provider asked the user "Which database?"
    When the user answers "Postgres"
    Then the provider receives the answer "Postgres"
    And the user input item is completed with the answer

  @node
  Scenario: Files attached to an answer are named with where they were saved
    Given the provider asked the user "Show me the error"
    When the user answers "Here" attaching "error.png"
    Then the provider receives "Here" followed by a line naming "error.png" and its saved path

  @node
  Scenario: An answer whose attachment is no longer available is refused
    Given the provider asked the user "Show me the error"
    When the user answers attaching a file whose upload expired
    Then the command fails asking the user to attach it again

  @node
  Scenario: Dismissing questions closes them without answering
    Given the provider asked the user "Which database?"
    When the user dismisses the questions
    Then the provider is told the questions were dismissed
    And the request is no longer pending

  # Both servers mark a request left pending at startup expired, not cancelled.
  @node
  Scenario: Pending requests expire when the node restarts
    Given the provider asked for approval of a command
    When the node restarts
    Then the request expires

  @node
  Scenario: A pending request that cannot be answered after a restart is marked not resumable
    Given the provider asked for approval of a command
    When the node restarts
    Then the request is marked not resumable rather than cancelled
    And the thread explains the request can no longer be answered

  @node @backlog
  Scenario: A run waiting on a request shows as waiting
    When the provider asks for approval of a command
    Then the run of "t1" is waiting
    And it returns to running when the request is resolved

  @node
  Scenario: A proposed plan is a draft until the provider finishes it
    When the provider streams a proposed plan
    Then "t1" has a draft plan that grows as it streams
    And the plan becomes active when the provider finishes it

  @node
  Scenario: A to-do list is tracked as a plan that completes with its steps
    When the provider reports a to-do list with two steps, one done
    Then "t1" has an active to-do plan
    And the plan completes when every step is done

  @node
  Scenario: Implementing a proposed plan completes it
    Given "t1" has an active proposed plan "p1"
    When the user sends "Implement it" to "t1" referring to plan "p1"
    Then plan "p1" is completed

  # The Node server completes a plan implemented from another thread of its project
  # (the composer's "Implement in a new thread").
  @node
  Scenario: A plan implemented from another thread is completed
    Given thread "t2" has an active proposed plan "p2"
    When the user sends a message to "t1" referring to plan "p2" of "t2"
    Then plan "p2" is completed
