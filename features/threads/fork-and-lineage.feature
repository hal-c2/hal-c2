# Sources:
#   docs/orchestration-v2/thread-lineage-and-context-transfer.md
#   docs/orchestration-v2/feature-lifecycles.md (fork, merge back, provider switch)
#   docs/internals/context-handoffs.md
#   apps/web/src/components/chat/ThreadRelationshipsControl.tsx (Previous agents, Show more, Disconnect agent session)
#   packages/client-runtime/src/state/threadRelationships.ts (relatives, their order)
#   packages/client-runtime/src/state/threadWorkflows.ts (the turn that can be merged back, a live agent session)
#   apps/web/src/components/ChatView.tsx (Fork from this response)
#   apps/mobile/src/features/threads/ThreadFeed.tsx (Fork from this response, fork not yet received), threadForkNavigation.ts
#   packages/contracts/src/orchestrationV2.ts (thread.fork, thread.merge_back, provider.switch, thread.provider-switched, context-transfer.created, context-transfer.updated, context-handoff.updated)
#   apps/server-ex/lib/hal_c2/orchestration/fork.ex
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex

Feature: Forking threads and merging work back
  A fork is a new thread that starts from a finished point in another thread's history.
  Work done in a fork can be merged back into the thread it came from.

  Background:
    Given a connected environment with the thread "Plan billing" whose last agent run finished

  @mc
  Scenario: Forking from the latest finished point
    When a client forks "Plan billing"
    Then a new thread "Plan billing fork" exists
    And it holds the history of "Plan billing" up to its last finished run

  @mc
  Scenario: Forking from a chosen run
    Given "Plan billing" has three finished runs
    When a client forks "Plan billing" at its second run with the title "Try Stripe"
    Then the thread "Try Stripe" holds the history through the second run only

  @mc
  Scenario: A run that has not finished cannot be forked
    Given the agent is still working in "Plan billing"
    When a client forks "Plan billing" at the running run
    Then the fork is rejected because only finished runs can be used

  @mc
  Scenario: A thread with nothing finished cannot be forked
    Given the thread "Empty" has no finished runs
    When a client forks "Empty"
    Then the fork is rejected with "No stable source run was found."

  @mc
  Scenario: A fork does not start an agent until it is used
    When a client forks "Plan billing"
    Then no agent session is started for the fork
    And the fork's context is carried over when its first message is sent

  @mc
  Scenario: A fork on the same agent continues the agent's own conversation
    Given "Plan billing" ran on Codex
    When the user sends the first message in a fork of "Plan billing" on Codex
    Then the agent continues from its own copy of the conversation

  @mc
  Scenario: A fork on another agent receives a written account of the history
    Given "Plan billing" ran on Codex
    When the user sends the first message in a fork of "Plan billing" on Claude
    Then Claude receives a transcript of the history ahead of the message

  @mc
  Scenario: A long history leaves out the message that does not fit
    Given "Plan billing" has more history than fits in a handoff
    When the user sends the first message in a fork on another agent
    Then the first request and the newest messages are kept whole
    And the message that does not fit is left out

  @mc
  Scenario: A fork outlives the thread it came from
    Given "Try Stripe" is a fork of "Plan billing"
    When "Plan billing" is deleted
    Then "Try Stripe" still holds its history

  @mc
  Scenario: Merging a fork back
    Given "Try Stripe" is a fork of "Plan billing" with a finished run
    When a client merges "Try Stripe" back into "Plan billing"
    Then the next message in "Plan billing" carries a summary of the work done in "Try Stripe"

  @mc
  Scenario: Only a fork can be merged back into its parent
    Given "Other work" was not forked from "Plan billing"
    When a client merges "Other work" back into "Plan billing"
    Then the merge is rejected because "Other work" is not a fork of "Plan billing"

  @mc
  Scenario: A newer merge replaces one that has not been delivered
    Given "Try Stripe" was merged back into "Plan billing" but no message has been sent since
    When "Try Stripe" is merged back again after more work
    Then only the newer merge is carried with the next message

  @mc
  Scenario: Switching agents mid-thread carries the conversation
    Given "Plan billing" ran on Codex
    When the user switches "Plan billing" to Claude and sends a message
    Then Claude receives the conversation so far ahead of the message

  @mc
  Scenario: Returning to an earlier agent only bridges what it missed
    Given "Plan billing" ran on Codex and then on Claude
    When the user switches "Plan billing" back to Codex and sends a message
    Then Codex resumes its own conversation
    And receives only what happened while Claude was working

  @desktop @mobile @backlog-mobile
  Scenario: Forking from a response in the conversation
    When the user forks "Plan billing" from the agent's latest response
    Then "Plan billing fork" opens

  @desktop @mobile @backlog-mobile
  Scenario: A failed fork is reported
    Given the environment rejects the fork
    When the user forks "Plan billing" from a response
    Then the user is told "Failed to fork this response."

  @backlog @mobile
  Scenario Outline: A response offers forking only when it can be forked
    Given the agent's response <situation>
    When the user looks at the response
    Then forking from it <offered>

    Examples:
      | situation                                  | offered     |
      | belongs to a run and its agent can fork it | is offered  |
      | belongs to an agent that cannot fork       | is not offered |
      | does not belong to a run                   | is not offered |

  @desktop @mobile @backlog-mobile
  Scenario: A fork that has not reached this client yet
    Given the fork was created but its thread has not reached this client
    When the user forks "Plan billing" from a response
    Then the user is told to reconnect and open the fork from the thread list

  @desktop @mobile @backlog-mobile
  Scenario: Seeing a thread's relatives
    Given "Try Stripe" and "Try Paddle" are forks of "Plan billing"
    When the user looks at the relatives of "Plan billing"
    Then both forks are listed with how many are running

  @desktop @mobile @backlog-mobile
  Scenario: Opening the parent of a fork
    Given the user is viewing "Try Stripe"
    When the user opens its parent thread
    Then "Plan billing" opens

  @desktop @mobile @backlog-mobile
  Scenario: A relative that is no longer available
    Given the parent of "Try Stripe" was deleted
    When the user looks at the relatives of "Try Stripe"
    Then the parent is shown as unavailable

  @desktop @mobile @backlog-mobile
  Scenario: Merging back needs finished work
    Given "Try Stripe" has no finished run
    When the user looks at merging "Try Stripe" back
    Then merging is unavailable until a run in the fork completes

  @desktop @mobile @backlog-mobile
  Scenario: Merging back from the fork opens the parent
    Given "Try Stripe" has a finished run
    When the user merges "Try Stripe" back into "Plan billing"
    Then "Plan billing" opens

  @desktop @mobile @backlog-mobile
  Scenario: The conversation shows where a fork came from
    Given the user is viewing "Try Stripe"
    When the user reads the start of the conversation
    Then it says the thread was forked from "Plan billing"
    And the user can open the source conversation from there

  @backlog @desktop
  Scenario: A thread's relatives include its subagents and the threads it exchanged context with
    Given "Plan billing" started the subagent "Tax tests" in a thread of its own
    And context was transferred between "Plan billing" and the thread "Research"
    When the user looks at the relatives of "Plan billing"
    Then "Tax tests" is listed as a subagent
    And "Research" is listed as a context transfer

  @backlog @desktop
  Scenario: A thread is never its own relative
    Given context was transferred from "Plan billing" to "Plan billing"
    When the user looks at the relatives of "Plan billing"
    Then "Plan billing" is not listed

  @backlog @desktop
  Scenario: Relatives are listed with the parent first and then the newest
    Given "Try Stripe" is a fork of "Plan billing"
    And "Try Stripe" has the forks "Webhooks" and "Refunds", made in that order
    When the user looks at the relatives of "Try Stripe"
    Then "Plan billing" is listed first
    And "Refunds" is listed before "Webhooks"

  @backlog @desktop
  Scenario: Relatives do not move when their threads get new messages
    Given the relatives of "Plan billing" are listed
    When a relative receives a message or changes status
    Then the relatives stay in the order they were in

  @backlog @desktop
  Scenario: A relative that is no longer available is listed last
    Given "Try Stripe" has the fork "Webhooks" and a fork that was deleted
    When the user looks at the relatives of "Try Stripe"
    Then the deleted fork is listed after "Webhooks"
    And it says "This related thread is unavailable"

  @backlog @desktop
  Scenario: Relatives from archived threads are listed too
    Given "Try Stripe" is a fork of "Plan billing" and "Plan billing" is archived
    When the user looks at the relatives of "Try Stripe"
    Then "Plan billing" is listed with its current title

  @backlog @desktop
  Scenario: Subagents that have finished are kept under Previous agents
    Given "Plan billing" has the subagent "Tax tests" still working
    And "Plan billing" has the finished subagents "Docs" and "Lint", and "Lint" failed
    When the user looks at the relatives of "Plan billing"
    Then "Tax tests" is listed with the other relatives
    And "Docs" and "Lint" are under a closed "Previous agents" heading showing 2 and "1 failed"
    When the user opens the "Previous agents" heading
    Then "Docs" and "Lint" are listed

  @backlog @desktop
  Scenario: A long list of relatives is shown a part at a time
    Given "Plan billing" has 20 forks
    When the user looks at the relatives of "Plan billing"
    Then the first 6 are listed and the user is offered "Show 12 more"
    When the user asks for more
    Then 12 more are listed

  @backlog @desktop
  Scenario: A subagent relative shows how long it has worked and what it did
    Given "Plan billing" has the subagent "Tax tests" that started 3 minutes ago
    When the user looks at the relatives of "Plan billing"
    Then "Tax tests" is listed with how long it has worked
    When the user points at it
    Then its model, provider, status, latest word or result and project are shown

  @backlog @desktop
  Scenario: A fork can be merged back while its latest turn waits for its checkpoint
    Given "Try Stripe" is a fork whose latest turn has finished and is capturing its checkpoint
    When the user looks at merging "Try Stripe" back
    Then that latest turn is the one merged
    And an older checkpointed turn is not offered in its place

  @backlog @desktop
  Scenario: A fork cannot be merged back while a newer turn is starting or running
    Given "Try Stripe" has a finished run and a newer run that is starting
    When the user looks at merging "Try Stripe" back
    Then merging is unavailable until that run settles

  @backlog @desktop
  Scenario: The user disconnects a thread's agent session from its relatives
    Given "Plan billing" has an agent session that is neither stopped nor failed
    When the user chooses "Disconnect agent session" from the thread's lineage actions
    Then the agent session is stopped
    And the thread and its history are kept

  @backlog @desktop
  Scenario: A thread without a live agent session has nothing to disconnect
    Given the agent session of "Plan billing" is stopped
    When the user looks at the lineage actions of "Plan billing"
    Then "Disconnect agent session" is not offered
