# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/permission-modes.md
#   packages/contracts/src/orchestrationV2.ts (runtime-request.respond, thread.user-input.dismiss, approval_request, user_input_request)
#   packages/contracts/src/providerPolicy.ts (ProviderApprovalDecision)
#   packages/contracts/src/providerRuntime.ts (ProviderApprovalOption, ProviderRequestKind)
#   apps/server-ex/lib/hal_c2/orchestration.ex (runtime-request.respond, thread.user-input.dismiss)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (approval_request, user_input_request items)
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (acceptAlways becomes acceptForSession)
#   apps/server-ex/lib/hal_c2/claude/thread_runtime.ex (session approvals add session permission rules)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (allow_once, allow_always, reject_once)
#   apps/web/src/components/chat/ComposerPendingApprovalActions.tsx
#   apps/web/src/components/chat/ComposerPendingApprovalPanel.tsx
#   apps/web/src/components/chat/ComposerPendingUserInputPanel.tsx
#   apps/tui/src/approvals.ts (stale versus transient respond failure)
#   apps/desktop-qt/src/native/ComposerController.cpp (answers sent once, failed answers)
#   apps/tui/src/components/ChatView.tsx (approve, decline, cycle pending approvals)
#   apps/tui/src/components/ComposerPendingUserInputPanel.tsx
#
# Not found in any source: an "allow with edits" approval. No client or provider offers it.

Feature: Approvals and agent questions
  When the agent needs permission or an answer, the thread waits for the user. The
  user decides in the conversation and the agent carries on.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop" whose agent is working

  # TUI: approve and decline are implemented in apps/tui/src/components/ChatView.tsx
  @shared @backlog-mobile @backlog-tui
  Scenario Outline: The user answers an approval request
    Given the agent asks to run "rm -rf dist"
    When the user chooses to <decision>
    Then <outcome>

    Examples:
      | decision                     | outcome                                                         |
      | approve it                   | the command runs and the agent continues                        |
      | decline it                   | the command is not run and the agent is told it was declined    |
      | always allow it this session | the command runs and matching requests stop asking this session |
      | cancel the request           | the command is not run and the turn stops waiting               |

  @node
  Scenario Outline: Allowing always maps to what each provider supports
    Given the thread runs on <provider>
    And the agent asks to run "npm test"
    When the user allows it always
    Then <provider> is told to <native>

    Examples:
      | provider                                | native                                            |
      | Codex                                   | allow it for the rest of the session              |
      | an ACP agent such as OpenCode or Cursor | allow it always, or once if always is not offered |

  @plugin-claude @node
  Scenario: Claude remembers an approval for the session
    Given the thread runs on Claude
    When the user always allows "npm test" for this session
    And the agent asks to run "npm test" again
    Then the command runs without asking

  @plugin-claude @node @backlog
  Scenario: A released Claude session forgets its approvals
    Given the user always allowed "npm test" for this session on Claude
    When the Claude session is released and a new session starts
    And the agent asks to run "npm test"
    Then the user is asked again

  @shared @backlog-mobile @backlog-tui
  Scenario Outline: A request says what kind of permission it wants
    When the agent requests <kind>
    Then the request is titled "<title>"

    Examples:
      | kind                    | title                   |
      | to run a command        | Command approval        |
      | to read a file          | File read approval      |
      | to change a file        | File change approval    |
      | access for an app       | App access approval     |
      | a permission for an app | App permission approval |

  @shared @backlog-mobile @backlog-tui
  Scenario: A provider's warning is shown with the option it applies to
    Given the provider warns that an option may follow injected instructions
    When the user reviews the approval
    Then the warning is shown next to that option

  # TUI: implemented in apps/tui/src/components/ChatView.tsx
  @shared @backlog
  Scenario: Several pending approvals are answered one at a time
    Given the agent has three pending approvals
    Then the user sees "1/3"
    When the user moves to the next approval
    Then the user sees "2/3"
    When the user moves back
    Then the user sees "1/3"

  @shared @backlog-mobile @backlog-tui
  Scenario: A request whose agent is gone cannot be answered
    Given the provider process stopped while an approval was pending
    Then the approval cannot be answered
    And the user is told "Provider process is gone — interrupt or restart the run to respond."

  # TUI: implemented in apps/tui/src/approvals.ts
  @desktop @tui @backlog-tui
  Scenario Outline: A failed answer is kept or closed depending on why it failed
    Given the user approved a pending request
    When sending the answer fails because <reason>
    Then the approval is <state>

    Examples:
      | reason                              | state                                   |
      | the request was already resolved    | closed                                  |
      | the connection dropped for a moment | still open so the user can answer again |

  @desktop
  Scenario: An answer waiting on the node is not sent twice
    Given the agent asks to run "npm test"
    And the node holds its answers
    When the user approves it
    Then the approval shows it is being answered
    When the user approves it
    Then the node receives one answer

  @desktop
  Scenario: A failed answer is reported and can be sent again
    Given the agent asks to run "npm test"
    And the node refuses "runtime-request.respond" with "connection closed"
    When the user approves it
    Then the user sees an "error" toast "Failed to submit approval decision." saying "connection closed"
    And the approval is still open so the user can answer again

  # TUI: implemented in apps/tui/src/components/ComposerPendingUserInputPanel.tsx
  @shared @backlog-mobile @backlog-tui
  Scenario Outline: The user answers the agent's question
    Given the agent asks "Which database?" with the options "Postgres", "SQLite" and "MySQL"
    And the question allows <choices>
    When the user picks <picked>
    Then the agent receives <answer>

    Examples:
      | choices         | picked                 | answer                 |
      | one answer      | "SQLite"               | "SQLite"               |
      | several answers | "Postgres" and "MySQL" | "Postgres" and "MySQL" |

  @shared @backlog-mobile @backlog-tui
  Scenario: The user writes their own answer
    Given the agent asks "Which database?" with three options
    When the user answers "DuckDB, in memory"
    Then the agent receives "DuckDB, in memory"

  @node
  Scenario: The user dismisses a question without answering
    Given the agent asks "Which database?"
    When the user dismisses the question
    Then the question is closed as dismissed
    And the agent is not given an answer

  @shared @backlog-mobile @backlog-tui
  Scenario: A question stays answerable after its turn ends
    Given the agent asked a question that can be answered by message
    When the turn ends before the user answers
    Then the user can still answer the question
