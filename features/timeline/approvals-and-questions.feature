# Sources:
#   https://github.com/pingdotgg/t3code/pull/24616
#   https://github.com/pingdotgg/t3code/pull/21086
#   https://github.com/pingdotgg/t3code/pull/13865
#   https://github.com/pingdotgg/t3code/pull/19197
#   https://github.com/pingdotgg/t3code/pull/17637
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/12900
#   https://github.com/pingdotgg/t3code/pull/21503
#   https://github.com/pingdotgg/t3code/pull/21393
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
#   packages/client-runtime/src/pendingRequests.ts (which requests are still open, their order, older native types)
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
  @shared @backlog-mobile @priority-high
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

  @mc
  Scenario Outline: Allowing always maps to what each provider supports
    Given the thread runs on <provider>
    And the agent asks to run "npm test"
    When the user allows it always
    Then <provider> is told to <native>

    Examples:
      | provider                                | native                                            |
      | Codex                                   | allow it for the rest of the session              |
      | an ACP agent such as OpenCode or Cursor | allow it always, or once if always is not offered |

  @plugin-claude @mc
  Scenario: Claude remembers an approval for the session
    Given the thread runs on Claude
    When the user always allows "npm test" for this session
    And the agent asks to run "npm test" again
    Then the command runs without asking

  @plugin-claude @mc
  Scenario: A released Claude session forgets its approvals
    Given the user always allowed "npm test" for this session on Claude
    When the Claude session is released and a new session starts
    And the agent asks to run "npm test"
    Then the user is asked again

  @shared @backlog-mobile @priority-high
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

  @shared @backlog-mobile
  Scenario: A provider's warning is shown with the option it applies to
    Given the provider warns that an option may follow injected instructions
    When the user reviews the approval
    Then the warning is shown next to that option

  # TUI: implemented in apps/tui/src/components/ChatView.tsx
  @shared @backlog-mobile @priority-high
  Scenario: Several pending approvals are answered one at a time
    Given the agent has three pending approvals
    Then the user sees "1/3"
    When the user moves to the next approval
    Then the user sees "2/3"
    When the user moves back
    Then the user sees "1/3"

  # Legacy: packages/client-runtime/src/pendingRequests.ts (derivePendingRequests sorts by createdAt)
  @backlog @desktop @mobile @priority-high
  Scenario: Pending requests are answered in the order they were asked
    Given the agent asked "Which database?" and then asked to run "npm test"
    When the user opens the pending requests
    Then "Which database?" comes first and "npm test" second

  # Upstream #17637: a request arriving mid-sentence took over the composer and caught
  # the rest of the draft as its answer.
  @backlog @desktop @priority-high
  Scenario: A request that arrives while the user is typing waits until they stop
    Given the user is typing a follow-up in the thread's composer
    When the agent asks a question or an approval
    Then the composer keeps the draft and sends it as a message, not as the answer
    And the request appears once the user has not typed for 1.5 seconds, sends or queues the draft, or leaves the composer

  @backlog @desktop
  Scenario: A request is held back for typing only once
    Given a request was held while the user typed and then appeared
    When the user starts typing again
    Then the request stays shown
    And a request that arrives while the user is not typing appears at once

  # Upstream #21503: the composer stays usable while an approval waits, and sending a message
  # declines every pending approval, then steers the message into the waiting turn whatever
  # the follow-up setting says.
  @backlog @mc @shared @priority-high
  Scenario: Sending a message while approvals wait declines them and redirects the agent
    Given the agent is waiting for the user to approve two commands
    And follow-ups are set to queue
    When the user sends "don't run that, just say hi instead"
    Then both commands are declined without running
    And the message steers the waiting turn instead of queueing behind it

  # Upstream #21503: only a message that is really sent declines approvals.
  @backlog @shared
  Scenario Outline: A send that does not reach the agent leaves the approvals waiting
    Given the agent is waiting for the user to approve a command
    When the user <sends>
    Then the command is still waiting for approval

    Examples:
      | sends                                       |
      | runs a slash command such as "/plan"        |
      | sends a draft the composer refuses          |
      | edits a message already in the queue        |

  # Upstream #21503: a decline that fails sends nothing.
  @backlog @shared
  Scenario: A decline that fails sends nothing
    Given the agent is waiting for the user to approve a command
    And the environment refuses the decline
    When the user sends a message
    Then the message is not sent and stays in the composer
    And the user is told the approval could not be declined

  # Legacy: packages/client-runtime/src/pendingRequests.ts (closedApprovals, closedUserInputs)
  @backlog @desktop @mobile @priority-high
  Scenario: A request that was settled stays settled whatever order the news arrived in
    Given the client hears that an approval was resolved before it hears that it was asked
    Then the approval is not offered to the user

  # Legacy: packages/client-runtime/src/pendingRequests.ts (parseQuestions)
  @backlog @desktop @mobile @priority-high
  Scenario: A question with nothing the user could answer is not shown
    Given the agent asked a question that has no options and allows no custom answer
    Then the user is not asked it

  # Legacy: packages/client-runtime/src/pendingRequests.ts (requestKindFromRequestType)
  @backlog @desktop @mobile @priority-low
  Scenario Outline: An approval recorded by an older version is shown as the kind of request it was
    Given a thread recorded an approval of the native type "<type>"
    When the user opens the thread
    Then the approval is shown as a request to <kind>

    Examples:
      | type                       | kind                  |
      | exec_command_approval      | run a command         |
      | apply_patch_approval       | change files          |
      | file_read_approval         | read a file           |
      | mcp_elicitation_approval   | answer an MCP request |

  @shared @backlog-mobile @priority-high
  Scenario: A request whose agent is gone cannot be answered
    Given the provider process stopped while an approval was pending
    Then the approval cannot be answered
    And the user is told "Provider process is gone — interrupt or restart the run to respond."

  # TUI: implemented in apps/tui/src/approvals.ts
  @desktop @tui
  Scenario Outline: A failed answer is kept or closed depending on why it failed
    Given the user approved a pending request
    When sending the answer fails because <reason>
    Then the approval is <state>

    Examples:
      | reason                              | state                                   |
      | the request was already resolved    | closed                                  |
      | the connection dropped for a moment | still open so the user can answer again |

  @desktop
  Scenario: An answer waiting on the MC is not sent twice
    Given the agent asks to run "npm test"
    And the MC holds its answers
    When the user approves it
    Then the approval shows it is being answered
    When the user approves it
    Then the MC receives one answer

  # Upstream #24616: an answer recorded but never delivered to the provider left the run spinning
  # with nothing to answer and no error.
  @backlog @mc @shared
  Scenario: An answer the provider never confirms says so in the timeline
    Given the user answered the agent's question
    When every attempt to deliver the answer to the provider fails
    Then the timeline shows "Answer delivery not confirmed."
    And the user's answer stays recorded and the run is not failed

  @desktop
  Scenario: A failed answer is reported and can be sent again
    Given the agent asks to run "npm test"
    And the MC refuses "runtime-request.respond" with "connection closed"
    When the user approves it
    Then the user sees an "error" toast "Failed to submit approval decision." saying "connection closed"
    And the approval is still open so the user can answer again

  # TUI: implemented in apps/tui/src/components/ComposerPendingUserInputPanel.tsx
  @shared @backlog-mobile @priority-high
  Scenario Outline: The user answers the agent's question
    Given the agent asks "Which database?" with the options "Postgres", "SQLite" and "MySQL"
    And the question allows <choices>
    When the user picks <picked>
    Then the agent receives <answer>

    Examples:
      | choices         | picked                 | answer                 |
      | one answer      | "SQLite"               | "SQLite"               |
      | several answers | "Postgres" and "MySQL" | "Postgres" and "MySQL" |

  @shared @backlog-mobile @priority-high
  Scenario: The user writes their own answer
    Given the agent asks "Which database?" with three options
    When the user answers "DuckDB, in memory"
    Then the agent receives "DuckDB, in memory"

  # Upstream #13865: a typed answer was lost after opening a new thread and coming back.
  @shared @backlog-mobile @backlog-tui @priority-low
  Scenario: A half-written answer survives leaving the thread
    Given the agent asks "Which database?" and the user has typed "DuckDB" without sending it
    When the user opens a new thread and comes back
    Then the answer still reads "DuckDB" on the same question

  @backlog @shared
  Scenario: A link in the agent's question opens the way a chat link does
    Given the agent asks "Authorize this device at https://example.com/device with `RTJS-TQGS`"
    When the user opens the link in the question
    Then the link opens the way a link in chat does
    And no option is picked
    And "RTJS-TQGS" is shown as inline code

  # Legacy: packages/client-runtime/src/work-log (answered question rows lead with the question)
  @backlog @shared
  Scenario: An answered question's timeline row leads with the question and shows the answer beside it
    Given the agent asked "Which approach should we use?" and the user answered "Incremental migration"
    When the timeline shows the exchange collapsed
    Then the row reads "Which approach should we use?" and shows "Incremental migration" beside it
    And expanding the row still shows the full question and answer

  # Upstream #21086: an answered question stays in sight after its turn.
  # Upstream #21393: the phone hid answered questions inside the turn's folded work.
  @backlog @shared
  Scenario: An answered question stays in sight after the turn finishes
    Given the agent asked the user a question during a turn and the user answered
    When the turn finishes
    Then the question and its answer are shown outside the turn's folded work
    And they are not merged into a summary of commands and tools

  @mc
  Scenario: The user dismisses a question without answering
    Given the agent asks "Which database?"
    When the user dismisses the question
    Then the question is closed as dismissed
    And the agent is not given an answer

  @shared @backlog-mobile @priority-high
  Scenario: A question stays answerable after its turn ends
    Given the agent asked a question that can be answered by message
    When the turn ends before the user answers
    Then the user can still answer the question
