# Sources:
#   docs/orchestration-v2/thread-lineage-and-context-transfer.md
#   docs/orchestration-v2/feature-lifecycles.md (fork, merge back, provider switch)
#   docs/internals/context-handoffs.md
#   apps/web/src/components/chat/ThreadRelationshipsControl.tsx
#   apps/web/src/components/ChatView.tsx (Fork from this response)
#   packages/contracts/src/orchestrationV2.ts (thread.fork, thread.merge_back, provider.switch, thread.provider-switched, context-transfer.created, context-transfer.updated, context-handoff.updated)
#   apps/server-ex/lib/t3/orchestration/fork.ex
#   apps/server-ex/lib/t3/orchestration/handoff.ex

Feature: Forking threads and merging work back
  A fork is a new thread that starts from a finished point in another thread's history.
  Work done in a fork can be merged back into the thread it came from.

  Background:
    Given a connected environment with the thread "Plan billing" whose last agent run finished

  @node
  Scenario: Forking from the latest finished point
    When a client forks "Plan billing"
    Then a new thread "Plan billing fork" exists
    And it holds the history of "Plan billing" up to its last finished run

  @node
  Scenario: Forking from a chosen run
    Given "Plan billing" has three finished runs
    When a client forks "Plan billing" at its second run with the title "Try Stripe"
    Then the thread "Try Stripe" holds the history through the second run only

  @node
  Scenario: A run that has not finished cannot be forked
    Given the agent is still working in "Plan billing"
    When a client forks "Plan billing" at the running run
    Then the fork is rejected because only finished runs can be used

  @node
  Scenario: A thread with nothing finished cannot be forked
    Given the thread "Empty" has no finished runs
    When a client forks "Empty"
    Then the fork is rejected with "No stable source run was found."

  @node
  Scenario: A fork does not start an agent until it is used
    When a client forks "Plan billing"
    Then no agent session is started for the fork
    And the fork's context is carried over when its first message is sent

  @node
  Scenario: A fork on the same agent continues the agent's own conversation
    Given "Plan billing" ran on Codex
    When the user sends the first message in a fork of "Plan billing" on Codex
    Then the agent continues from its own copy of the conversation

  @node
  Scenario: A fork on another agent receives a written account of the history
    Given "Plan billing" ran on Codex
    When the user sends the first message in a fork of "Plan billing" on Claude
    Then Claude receives a transcript of the history ahead of the message

  @node
  Scenario: A long history is trimmed from the oldest end
    Given "Plan billing" has more history than fits in a handoff
    When the user sends the first message in a fork on another agent
    Then the newest part of the history is kept

  @node
  Scenario: A fork outlives the thread it came from
    Given "Try Stripe" is a fork of "Plan billing"
    When "Plan billing" is deleted
    Then "Try Stripe" still holds its history

  @node
  Scenario: Merging a fork back
    Given "Try Stripe" is a fork of "Plan billing" with a finished run
    When a client merges "Try Stripe" back into "Plan billing"
    Then the next message in "Plan billing" carries a summary of the work done in "Try Stripe"

  @node
  Scenario: Only a fork can be merged back into its parent
    Given "Other work" was not forked from "Plan billing"
    When a client merges "Other work" back into "Plan billing"
    Then the merge is rejected because "Other work" is not a fork of "Plan billing"

  @node
  Scenario: A newer merge replaces one that has not been delivered
    Given "Try Stripe" was merged back into "Plan billing" but no message has been sent since
    When "Try Stripe" is merged back again after more work
    Then only the newer merge is carried with the next message

  @node
  Scenario: Switching agents mid-thread carries the conversation
    Given "Plan billing" ran on Codex
    When the user switches "Plan billing" to Claude and sends a message
    Then Claude receives the conversation so far ahead of the message

  @backlog @node
  Scenario: Returning to an earlier agent only bridges what it missed
    Given "Plan billing" ran on Codex and then on Claude
    When the user switches "Plan billing" back to Codex and sends a message
    Then Codex resumes its own conversation
    And receives only what happened while Claude was working

  @backlog @desktop @mobile
  Scenario: Forking from a response in the conversation
    When the user forks "Plan billing" from the agent's latest response
    Then "Plan billing fork" opens

  @backlog @desktop @mobile
  Scenario: A failed fork is reported
    Given the environment rejects the fork
    When the user forks "Plan billing" from a response
    Then the user is told "Failed to fork this response."

  @backlog @desktop @mobile
  Scenario: A fork that has not reached this client yet
    Given the fork was created but its thread has not reached this client
    When the user forks "Plan billing" from a response
    Then the user is told to reconnect and open the fork from the thread list

  @backlog @desktop @mobile
  Scenario: Seeing a thread's relatives
    Given "Try Stripe" and "Try Paddle" are forks of "Plan billing"
    When the user looks at the relatives of "Plan billing"
    Then both forks are listed with how many are running

  @backlog @desktop @mobile
  Scenario: Opening the parent of a fork
    Given the user is viewing "Try Stripe"
    When the user opens its parent thread
    Then "Plan billing" opens

  @backlog @desktop @mobile
  Scenario: A relative that is no longer available
    Given the parent of "Try Stripe" was deleted
    When the user looks at the relatives of "Try Stripe"
    Then the parent is shown as unavailable

  @backlog @desktop @mobile
  Scenario: Merging back needs finished work
    Given "Try Stripe" has no finished run
    When the user looks at merging "Try Stripe" back
    Then merging is unavailable until a run in the fork completes

  @backlog @desktop @mobile
  Scenario: Merging back from the fork opens the parent
    Given "Try Stripe" has a finished run
    When the user merges "Try Stripe" back into "Plan billing"
    Then "Plan billing" opens

  @backlog @desktop @mobile
  Scenario: The conversation shows where a fork came from
    Given the user is viewing "Try Stripe"
    When the user reads the start of the conversation
    Then it says the thread was forked from "Plan billing"
    And the user can open the source conversation from there
