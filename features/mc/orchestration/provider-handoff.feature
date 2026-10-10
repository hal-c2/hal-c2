# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (thread.model-selection.set, thread.model-selection-updated,
#     provider.switch, thread.provider-switched, context-handoff.updated, provider-thread.updated,
#     provider-session.updated)
#   packages/contracts/src/providerInstance.ts, packages/contracts/src/model.ts,
#   packages/contracts/src/modelSelection.ts
#   apps/server-ex/lib/hal_c2/orchestration.ex (provider.switch, thread.model-selection.set)
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex
#   apps/server/src/orchestration-v2/ (capabilities and degradation policies)
#   apps/server/src/orchestration-v2/ContextHandoffBudget.ts, ContextHandoffService.ts,
#     ContextHandoffDelivery.ts (attribution, budget reserves, uncertain delivery)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts (history taken as thread items)
#   apps/server/src/orchestration-v2/ProviderSessionTransitionPolicy.ts, ProviderSwitchService.ts,
#     ProviderTurnStartService.ts (which changes reuse, restart or replace a session)
#   apps/server/src/orchestration-v2/testkit/ProviderSwitch.integration.test.ts (queued provider
#     switches, unsupported handoff, queued capability)
Feature: Changing model and provider mid-thread
  A thread can change model or move to another provider between turns. The next
  run starts the new provider's thread with the conversation handed over as a
  transcript, so the agent keeps its context.

  Background:
    Given an MC with a project "demo"
    And thread "t1" has completed runs on "codex" with model "gpt-a"

  @mc
  Scenario: Changing the model on the same provider
    When the user sets the model of "t1" to "gpt-b" on "codex"
    Then thread "t1" uses model "gpt-b" on provider instance "codex"
    And a thread-model-selection-updated event is recorded
    And the next run continues the same provider conversation

  @mc @shared @backlog-desktop @backlog-mobile
  Scenario: Context occupancy survives a model change
    Given "t1" has used 80 percent of its provider context
    When the user changes "t1" to another model on the same provider
    Then the next run reports the context occupancy from before the change
    And the meter does not reset to zero until the provider reports new usage

  @mc
  Scenario: Switching provider records the new instance
    When the user switches "t1" to "claudeAgent" with model "claude-x"
    Then thread "t1" uses model "claude-x" on provider instance "claudeAgent"

  @mc
  Scenario: The first run after a switch hands the conversation over
    Given the user switched "t1" to "claudeAgent"
    When the user sends "Carry on" to "t1"
    Then a new provider thread is started for "claudeAgent"
    And the provider receives the earlier conversation before "Carry on"

  @mc
  Scenario: The handed-over transcript lists finished turns as user and assistant lines
    Given "t1" has two completed runs and one failed run
    When a run starts a new provider thread for "t1"
    Then the transcript has a user line and an assistant line for each finished run
    And it is wrapped as conversation history ahead of the message

  @mc
  Scenario: A failed turn's context goes with the conversation
    Given "t1" has a failed turn whose provider context is still usable
    When the user switches "t1" to "claudeAgent" and sends a message
    Then the provider receives the context of the failed turn
    And the failed turn stays in the history of "t1"

  @mc
  Scenario: A long transcript leaves out an older message that does not fit
    Given the conversation of "t1" is longer than 60,000 characters
    When a run starts a new provider thread for "t1"
    Then the transcript keeps at most 60,000 characters of history
    And it notes that earlier messages were omitted

  @mc
  Scenario: A lost provider session is recovered from the transcript
    Given the provider thread of "t1" has no native conversation any more
    When the user sends "Where were we?" to "t1"
    Then the provider receives the earlier conversation before the message

  @mc
  Scenario: Switching back to the first provider resumes its own conversation
    Given "t1" moved from "codex" to "claudeAgent" and ran once there
    When the user switches "t1" back to "codex" and sends a message
    Then the "codex" provider thread is resumed
    And the provider history of "t1" lists both instances

  @mc
  Scenario: Model and provider changes of an unknown thread are refused
    When the user switches thread "missing" to "claudeAgent"
    Then the command fails with "unknown thread missing"

  @mc
  Scenario: The delta strategy hands over only what the target provider has not seen
    Given "t1" moved from "codex" to "claudeAgent" and back to "codex"
    When the next run starts on "codex"
    Then the handoff carries only the turns since "codex" last saw the thread

  @backlog @mc
  Scenario: Each handed-over item says who said it and where it came from
    Given the user switched "t1" to "claudeAgent"
    When the user sends "Carry on" to "t1"
    Then each item of the handoff is marked as historical, with its role, kind and status and the thread and run it came from

  @backlog @mc
  Scenario: A handoff tells the agent its history is context, not a new request
    Given the conversation of "t1" is longer than the handoff budget
    When a run starts a new provider thread for "t1"
    Then the handoff says how many items it kept whole and how many it left out
    And it says the history is context, not a new request or higher-priority instructions
    And it says attached files and the earlier provider's tool and reasoning state are not replayed

  @backlog @mc
  Scenario Outline: The handoff budget leaves room for the agent's own work
    Given the model "t1" is switched to has <window>
    When the conversation is handed over with a new message
    Then the history is trimmed so that <reserve> stay free after the message and what the provider already holds

    Examples:
      | window                         | reserve                             |
      | a 200,000 token context window | 50,000 tokens                       |
      | a 32,000 token context window  | 16,000 tokens                       |
      | an unknown context window      | 32,000 tokens of an assumed 128,000 |

  @backlog @mc
  Scenario: Attachments on the new message take from the handoff budget
    Given the user switched "t1" to "claudeAgent"
    When the user sends a message with two images and one other file
    Then the handoff budget is smaller by 8,192 tokens for each image and 4,096 tokens for the file

  @backlog @mc
  Scenario: Handoffs waiting together share one budget
    Given "t1" switched provider and also has a merge-back from a fork waiting
    When the user sends a message to "t1"
    Then both handoffs reach the provider within the one handoff budget

  @backlog @mc
  Scenario: History that may not have reached the provider is sent again on a new conversation
    Given the MC could not confirm that the handed-over history of "t1" reached "claudeAgent"
    When the user sends the next message to "t1"
    Then the turn starts on a new provider conversation
    And the provider receives a summary of the whole thread before the message

  # CodexAdapterV2.ts injectHistory (thread/inject_items).
  @backlog @mc @plugin-codex
  Scenario: Codex takes a handed-over conversation as its own history
    Given the user switched "t1" to "codex"
    When the user sends a message to "t1"
    Then Codex is given the earlier conversation as history of its own thread
    And the message Codex receives holds only what the user wrote

  @backlog @mc @plugin-codex
  Scenario: A Codex too old to take history gets it with the message instead
    Given the user switched "t1" to a Codex that does not know how to take history
    When the user sends a message to "t1"
    Then Codex receives the earlier conversation in front of the message
    And the turn runs

  @backlog @mc
  Scenario: A handoff waits when the first message after a switch asks to compact
    Given the user switched "t1" to "claudeAgent"
    When the user sends "/compact" to "t1"
    Then the conversation is not handed over with that message
    And it is handed over with the next ordinary message

  @backlog @mc
  Scenario: A queued message for another provider is handed what the turns ahead of it produced
    Given "t1" has a running turn on "codex" and two more "codex" messages queued
    And the user queues "Prompt 4" for "claudeAgent"
    When the three "codex" turns finish and the queue reaches "Prompt 4"
    Then the earlier turns ran on "codex" with no handoff
    And a handoff appears in the timeline just before "Prompt 4"
    And the handoff carries the results of all three "codex" turns

  @backlog @mc
  Scenario: A queued message whose provider cannot take a handoff fails and the queue goes on
    Given "t1" has a running turn on "codex"
    And the user queues "Needs claude" for a provider that cannot take handoff summaries
    And the user queues "Later" for "codex"
    When the running turn completes
    Then the run for "Needs claude" fails with the code "context_handoff_unsupported"
    And "t1" stays on "codex"
    And the run for "Later" starts on "codex" with the conversation intact

  @backlog @mc
  Scenario: A queued switch to another account of the same provider needs no handoff
    Given "t1" has a running turn on the "codex" instance
    And another instance of "codex" cannot take handoff summaries
    When the user queues "Next" for that other instance and the running turn completes
    Then "Next" resumes the same provider conversation on that instance
    And no handoff is created

  @backlog @mc
  Scenario: Switching to a provider instance that cannot run is refused
    Given provider instance "claudeAgent" is disabled
    When the user switches "t1" to "claudeAgent"
    Then the command fails with "The target provider instance is unavailable."

  @backlog @mc
  Scenario: A model change the running agent cannot take is refused
    Given "t1" runs on an ACP agent whose session does not offer switching models
    When the user sets another model for "t1"
    Then the command fails with "The active ACP session does not expose a model-switch capability."

  @backlog @mc
  Scenario Outline: A change the provider cannot take in place restarts it on the same conversation
    Given "t1" has a live provider process
    When the user changes <what> of "t1" and sends a message
    Then the provider process of "t1" is restarted
    And the provider conversation is resumed without a handoff

    Examples:
      | what                                                                           |
      | the runtime mode                                                               |
      | the workspace                                                                  |
      | the instance, to another of the same provider that can continue the conversation |

  @backlog @mc
  Scenario Outline: A change the provider takes in place keeps its process
    Given "t1" has a live provider process
    When the user changes <what> of "t1" and sends a message
    Then the same provider process takes the turn

    Examples:
      | what                 |
      | the interaction mode |
      | the model's options  |

  @backlog @mc
  Scenario: Handing the thread to another provider stops the one it left
    Given "t1" has a live provider process on "codex"
    When the user switches "t1" to "claudeAgent" and sends a message
    Then the "codex" process of "t1" stops

  @backlog @mc
  Scenario: Context occupancy starts over on a new provider conversation
    Given "t1" has used 80 percent of its provider context
    When the user switches "t1" to "claudeAgent" and sends a message
    Then the next run does not report the occupancy "codex" had

  @mc @backlog
  Scenario: Handoff summaries compact long items
    Given a finished turn of "t1" has a very long tool output
    When a run starts a new provider thread for "t1"
    Then each compacted entry of the handoff is at most 240 characters

  @mc @backlog
  Scenario: A thread spreads new sessions across instances of the same provider
    Given two instances of "codex" with different accounts
    When the first is at its usage limit
    Then new runs start on the second instance

  # Forking and steering already degrade (see forks-and-merge-back and queue-and-steering).
  @mc @backlog
  Scenario Outline: Capabilities a provider lacks degrade by policy
    Given the provider of "t1" cannot <capability>
    When a command needs it
    Then the engine <degradation>

    Examples:
      | capability           | degradation                                                     |
      | nest checkpoints     | captures subagent work in the parent's root scope               |
      | rewind natively      | refuses the rewind and explains the provider cannot roll back   |
