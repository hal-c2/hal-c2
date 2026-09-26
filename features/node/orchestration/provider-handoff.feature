# Sources:
#   packages/contracts/src/orchestrationV2.ts (thread.model-selection.set, thread.model-selection-updated,
#     provider.switch, thread.provider-switched, context-handoff.updated, provider-thread.updated,
#     provider-session.updated)
#   packages/contracts/src/providerInstance.ts, packages/contracts/src/model.ts,
#   packages/contracts/src/modelSelection.ts
#   apps/server-ex/lib/t3/orchestration.ex (provider.switch, thread.model-selection.set)
#   apps/server-ex/lib/t3/orchestration/handoff.ex
#   apps/server/src/orchestration-v2/ (capabilities and degradation policies)
Feature: Changing model and provider mid-thread
  A thread can change model or move to another provider between turns. The next
  run starts the new provider's thread with the conversation handed over as a
  transcript, so the agent keeps its context.

  Background:
    Given a node with a project "demo"
    And thread "t1" has completed runs on "codex" with model "gpt-a"

  @node
  Scenario: Changing the model on the same provider
    When the user sets the model of "t1" to "gpt-b" on "codex"
    Then thread "t1" uses model "gpt-b" on provider instance "codex"
    And a thread-model-selection-updated event is recorded
    And the next run continues the same provider conversation

  @node
  Scenario: Switching provider records the new instance
    When the user switches "t1" to "claudeAgent" with model "claude-x"
    Then thread "t1" uses model "claude-x" on provider instance "claudeAgent"

  @node
  Scenario: The first run after a switch hands the conversation over
    Given the user switched "t1" to "claudeAgent"
    When the user sends "Carry on" to "t1"
    Then a new provider thread is started for "claudeAgent"
    And the provider receives the earlier conversation before "Carry on"

  @node
  Scenario: The handed-over transcript lists finished turns as user and assistant lines
    Given "t1" has two completed runs and one failed run
    When a run starts a new provider thread for "t1"
    Then the transcript has a user line and an assistant line for each finished run
    And it is wrapped as conversation history ahead of the message

  @node
  Scenario: A long transcript keeps its newest part
    Given the conversation of "t1" is longer than 60,000 characters
    When a run starts a new provider thread for "t1"
    Then the transcript is at most 60,000 characters
    And it notes that earlier messages were omitted

  @node
  Scenario: A lost provider session is recovered from the transcript
    Given the provider thread of "t1" has no native conversation any more
    When the user sends "Where were we?" to "t1"
    Then the provider receives the earlier conversation before the message

  @node
  Scenario: Switching back to the first provider resumes its own conversation
    Given "t1" moved from "codex" to "claudeAgent" and ran once there
    When the user switches "t1" back to "codex" and sends a message
    Then the "codex" provider thread is resumed
    And the provider history of "t1" lists both instances

  @node
  Scenario: Model and provider changes of an unknown thread are refused
    When the user switches thread "missing" to "claudeAgent"
    Then the command fails with "unknown thread missing"

  @node
  Scenario: The delta strategy hands over only what the target provider has not seen
    Given "t1" moved from "codex" to "claudeAgent" and back to "codex"
    When the next run starts on "codex"
    Then the handoff carries only the turns since "codex" last saw the thread

  @node @backlog
  Scenario: Handoff summaries compact long items
    Given a finished turn of "t1" has a very long tool output
    When a run starts a new provider thread for "t1"
    Then each compacted entry of the handoff is at most 240 characters

  @node @backlog
  Scenario: A thread spreads new sessions across instances of the same provider
    Given two instances of "codex" with different accounts
    When the first is at its usage limit
    Then new runs start on the second instance

  # Forking and steering already degrade (see forks-and-merge-back and queue-and-steering).
  @node @backlog
  Scenario Outline: Capabilities a provider lacks degrade by policy
    Given the provider of "t1" cannot <capability>
    When a command needs it
    Then the engine <degradation>

    Examples:
      | capability           | degradation                                                     |
      | nest checkpoints     | captures subagent work in the parent's root scope               |
      | rewind natively      | refuses the rewind and explains the provider cannot roll back   |
