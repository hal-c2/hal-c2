# Sources:
#   https://github.com/pingdotgg/t3code/pull/23198
#   https://github.com/pingdotgg/t3code/pull/29905
#   https://github.com/pingdotgg/t3code/pull/15477
#   https://github.com/pingdotgg/t3code/pull/22902
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/25610
#   https://github.com/pingdotgg/t3code/pull/30401
#   https://github.com/hal-c2/hal-c2/issues/1342
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

  # Another instance of a provider runs in its own home and account, so it cannot resume
  # the session the thread has on the first: it starts its own with the conversation
  # handed over, and the first keeps its session for when the thread comes back.
  @mc
  Scenario: Moving to another instance of the same provider starts a conversation there
    Given a second Codex instance "codex-work" with its own home
    When the user switches "t1" to "codex-work" with model "gpt-5.4"
    Then the next run starts on "codex-work"
    And a new provider thread is started for "codex-work"
    And the provider receives the earlier conversation before "where are we"
    And the run answers on the Codex thread "codex-work-thread-1"
    When the user switches "t1" back to "codex" and sends a message
    Then the run resumes the provider thread "codex" had

  # Before each instance had its own, a thread kept the session of whichever instance of
  # the provider it ran on, under the provider's id.
  @mc
  Scenario: A thread from before instances had their own sessions keeps each instance's conversation
    Given a second Codex instance "codex-work" with its own home
    And "t1" last ran on "codex-work" when instances shared a provider thread
    When the user switches "t1" to "codex-work" with model "gpt-5.4"
    Then the next run starts on "codex-work"
    And the run resumes the provider thread "codex-work" had
    When the user switches "t1" back to "codex" and sends a message
    Then the provider receives the earlier conversation before "where are we"
    And the run answers on the Codex thread "native-thread-1"
    And the session "codex" runs "t1" in is its own

  # Its runs named the shared session too: one another instance ran is still that
  # instance's to fork, after the provider's own instance has taken the shared id over.
  @mc
  Scenario: A fork of a run from before instances had their own sessions forks that instance's conversation
    Given a second Codex instance "codex-work" with its own home
    And the latest run of "t1" ran on "codex-work" when instances shared a provider thread
    When the user switches "t1" back to "codex" and sends a message
    And the user forks "t1" after its second run and sends on "codex-work"
    Then the fork's first turn forks the Codex thread "codex-work-thread-1" after "codex-work-turn-2"
    And the provider thread of "t1" on "codex-work" names that instance's session

  # The provider's own instance starts a new conversation when it takes the shared id
  # back, so its runs from before then are no longer in a conversation it has.
  @mc
  Scenario: A fork of the provider's own run from before instances had their own sessions gets the conversation
    Given a second Codex instance "codex-work" with its own home
    And the latest run of "t1" ran on "codex-work" when instances shared a provider thread
    When the user switches "t1" back to "codex" and sends a message
    And the user forks "t1" after its first run and sends on "codex"
    Then the fork's first turn starts a new Codex thread with the conversation

  # The shared provider thread named only the conversation of the instance that ran
  # there last. Another instance's runs from before are in none it has, even once it has
  # started one of its own.
  @mc
  Scenario: A fork of a run another instance ran before the last one to share the provider thread gets the conversation
    Given a second Codex instance "codex-work" with its own home
    And another Codex instance "codex-other" with its own home
    And the first run of "t1" ran on "codex-other" when instances shared a provider thread
    And the latest run of "t1" ran on "codex-work" when instances shared a provider thread
    When the user switches "t1" to "codex-other" with model "gpt-5.4"
    Then the next run starts on "codex-other"
    And the run answers on the Codex thread "codex-other-thread-1"
    When the user forks "t1" after its first run and sends on "codex-other"
    Then the fork's first turn starts a new Codex thread with the conversation

  @mc
  Scenario: A session carried to a thread from before instances had their own sessions continues on its instance
    Given a second Codex instance "codex-work" with its own home
    And "t1" last ran on "codex-work" when instances shared a provider thread and moved here with its session
    When the user switches "t1" to "codex-work" with model "gpt-5.4"
    Then the next run starts on "codex-work"
    And the run continues the carried Codex session "codex-work-carried"

  # A Codex runtime from before it recorded its instance (updated in place) does not know
  # which account its app-server runs as.
  @mc
  Scenario: A Codex runtime updated in place starts the other instance's Codex for its run
    Given a second Codex instance "codex-work" with its own home
    And the Codex runtime of "t1" was started before it recorded its instance
    When the user switches "t1" to "codex-work" with model "gpt-5.4"
    Then the next run starts on "codex-work"
    And the run answers on the Codex thread "codex-work-thread-1"

  @mc @shared @backlog-desktop @backlog-mobile
  Scenario: Context occupancy survives a model change
    Given "t1" has used 80 percent of its provider context
    When the user changes "t1" to another model on the same provider
    Then the next run reports the context occupancy from before the change
    And the meter does not reset to zero until the provider reports new usage

  # A report that came after its turn ended, and was taken as the running turn's, left
  # that turn's tokens out of the room a handoff has (#1363 review).
  @mc
  Scenario: A late usage report counts for the turn it came from
    Given a Codex turn of "t1" ended before its usage report came
    When Codex reports that turn's usage while the next turn of "t1" runs
    Then the usage counts for the turn it came from, and not the running one

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
  Scenario: A long transcript condenses an older run that does not fit
    Given the conversation of "t1" is longer than 60,000 characters
    When a run starts a new provider thread for "t1"
    Then the transcript keeps at most 60,000 characters of history
    And it notes which runs it condensed

  @mc
  Scenario: A lost provider session is recovered from the transcript
    Given the provider thread of "t1" has no native conversation any more
    When the user sends "Where were we?" to "t1"
    Then the provider receives the earlier conversation before the message

  # Upstream #25610: returning to a provider with no room for the incoming handoff failed and
  # asked the user to compact by hand.
  @mc @priority-high
  Scenario: A handoff that does not fit the resumed conversation starts a fresh one
    Given "t1" moved from "codex" to "claudeAgent" and ran long there
    And the "codex" conversation of "t1" has no room left for what happened since
    When the user switches "t1" back to "codex" and sends a message with an image
    Then a new "codex" conversation starts with as much of the history as fits
    And it receives the user's message and the image
    And later runs of "t1" continue that new conversation

  # Upstream #25610: background commands and native subagents are left running, and the user is
  # told when they keep the conversation from being replaced.
  @mc
  Scenario: A handoff that does not fit waits for background work instead of cutting it off
    Given the "codex" conversation of "t1" has no room left for the incoming handoff
    And a background command started in that conversation is still running
    When the user switches "t1" back to "codex" and sends a message
    Then the background command keeps running
    And the run says the conversation cannot be replaced while that work runs

  # Upstream #30401: a queued message that switched provider ended background agents and commands
  # that a message sent at once would have waited for.
  @backlog @mc
  Scenario Outline: A queued provider switch leaves background work running
    Given "t1" has a background command running in its "claudeAgent" conversation
    And a message queued behind the current run switches "t1" to <target>
    When the current run finishes
    Then the background command keeps running
    And <outcome>

    Examples:
      | target                                 | outcome                                                                     |
      | "codex"                                | the queued message runs on "codex"                                          |
      | another account of "claudeAgent"       | the queue is held, and resuming it once the work has ended runs the message |

  # Upstream #25610: a handoff too big even for a fresh conversation still fails.
  @mc
  Scenario: A message that cannot fit even a fresh conversation fails the run
    Given the user's message alone is larger than the context window of "codex"
    When the user switches "t1" to "codex" and sends it
    Then the run fails saying the message does not fit
    And the "codex" conversation of "t1" is not replaced

  # The window assumed for a provider that never named one is a guess: a message is
  # refused only by a window the provider reported.
  @mc
  Scenario: A message is not refused by a context window the provider never reported
    Given the user's message alone is larger than the context window assumed for "codex"
    When the user switches "t1" to "codex" and sends it
    Then the run reaches "codex" with the message

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

  # A delegated task's result and another agent's message reach a thread as user messages;
  # handed over as the user's, the next agent took them for the user's requests.
  @mc
  Scenario: A handoff does not present what the MC or another agent sent as the user's
    Given "t1" was told by the MC that a task finished and asked something by another agent
    When the user switches "t1" to "claudeAgent" and sends a message
    Then the handoff gives the MC's message as a notice and the other agent's as theirs

  @mc
  Scenario: The user's answers to the agent's questions are handed over
    Given the agent of "t1" asked "Which database?" and the user answered "Postgres"
    When the user switches "t1" to "claudeAgent" and sends a message
    Then the handoff says the agent asked "Which database?" and the user answered "Postgres"

  @mc @priority-high
  Scenario: A handoff tells the agent its history is context, not a new request
    Given the conversation of "t1" is longer than the handoff budget
    When a run starts a new provider thread for "t1"
    Then the handoff says which runs it condensed and what each condensed run keeps
    And it says the history is context, not a new request or higher-priority instructions
    And it says attached files and the earlier provider's tool and reasoning state are not replayed

  @mc
  Scenario Outline: The handoff budget leaves room for the agent's own work
    Given the model "t1" is switched to has <window>
    When the conversation is handed over with a new message
    Then the history is trimmed so that <reserve> stay free after the message and what the provider already holds

    Examples:
      | window                         | reserve                             |
      | a 200,000 token context window | 50,000 tokens                       |
      | a 32,000 token context window  | 16,000 tokens                       |
      | an unknown context window      | 32,000 tokens of an assumed 128,000 |

  @mc
  Scenario: Attachments on the new message take from the handoff budget
    Given the user switched "t1" to "claudeAgent"
    When the user sends a message with two images and one other file
    Then the handoff budget is smaller by 8,192 tokens for each image and a token for each 4 bytes of the file, at most 4,096

  @backlog @mc
  Scenario: Handoffs waiting together share one budget
    Given "t1" switched provider and also has a merge-back from a fork waiting
    When the user sends a message to "t1"
    Then both handoffs reach the provider within the one handoff budget

  # Upstream #22902: a failed native resume put its whole-thread summary in front of an older
  # pending handoff, so under the budget the newest turn's result was dropped.
  @mc @priority-high
  Scenario: A failed resume keeps the latest turn when an older handoff is waiting
    Given "t1" has a handoff from an earlier run still waiting
    And the latest turn of "t1" finished with "Result 3"
    When the next run of "t1" cannot resume its provider conversation
    Then the provider receives the handoffs oldest first, the whole-thread summary after the waiting one
    And "Result 3" is in the history it receives

  # Upstream #22902
  @mc
  Scenario: A failed resume does not resend a missed request after the whole-thread summary
    Given an earlier run of "t1" failed before its provider started a turn
    When the next run of "t1" cannot resume its provider conversation
    Then the missed request reaches the provider once, in its place in the whole-thread summary
    And the thread's first message is still in the history it receives

  @mc @priority-high
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

  # A bare /compact hands nothing over, so the new agent has no conversation of its own
  # to compact, and the run says so rather than run it on an empty one.
  @mc
  Scenario: A handoff waits when the first message after a switch asks to compact
    Given the user switched "t1" to "claudeAgent"
    When the user sends "/compact" to "t1"
    Then the conversation is not handed over with that message
    And the run says the agent has nothing to compact until the conversation goes over
    And it is handed over with the next ordinary message

  # #1342: a slash command that starts work, such as `/goal` or a skill, needs the
  # thread to work from. Claude runs a command only from the last block of a message,
  # so the history goes in a block of its own ahead of it. An ACP agent reads a
  # command only at the start of its prompt, so there the history waits.
  @mc
  Scenario: A slash command that is the first message after a switch to Claude gets the conversation
    Given the user switched "t1" to "claudeAgent"
    When the user sends the command "/goal make the tests pass" to "t1"
    Then Claude gets the conversation in a block ahead of "/goal make the tests pass"
    And the command is the last block of the message
    And Claude sets the goal "make the tests pass"

  # Codex's `/goal <objective>` sends its own prompt for the goal's first turn, and the
  # conversation goes ahead of it: the turn starting confirms the handoff, so history
  # left out then would never be sent.
  @mc @plugin-codex
  Scenario: A goal that is the first message on another Codex gets the conversation
    Given a second Codex instance "codex-work" with its own home
    And the user switches "t1" to "codex-work" with model "gpt-5.4"
    When the user sends the command "/goal fix the tests" to "t1"
    Then Codex gets the conversation ahead of the prompt for the goal "fix the tests"

  # Claude's skill mentions were read in the whole prompt, history included, so a skill
  # the thread mentioned before the switch ran again on the next message.
  @mc
  Scenario: A skill mentioned before a switch to Claude does not run again
    Given "t1" mentioned the Claude skill "review" before the switch
    And the user switched "t1" to "claudeAgent"
    When the user sends the next message to "t1"
    Then Claude gets the conversation and the message as plain text

  @mc
  Scenario: A slash command that is the first message after a switch to an ACP agent goes alone
    Given the user switched "t1" to "opencode"
    When the user sends the command "/review the last change" to "t1"
    Then the ACP agent's prompt starts with "/review the last change"
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

  # Upstream #15477: a handoff between two accounts of the same provider and model is a handoff
  # like any other, its marker naming the account on each side. An account with its own home
  # cannot resume the first account's conversation (see "Moving to another instance of the same
  # provider starts a conversation there"); one sharing the home restarts in place instead.
  @backlog @mc
  Scenario: A queued switch to another account of the same provider hands the conversation over
    Given "t1" has a running turn on the "codex" instance
    And a second Codex instance "codex-work" with its own home
    When the user queues "Next" for "codex-work" and the running turn completes
    Then the run for "Next" starts a new provider thread on "codex-work"
    And a handoff from "codex" to "codex-work" carries the earlier conversation

  @mc @priority-high
  Scenario: Switching to a provider instance that cannot run is refused
    Given provider instance "claudeAgent" is disabled
    When the user switches "t1" to "claudeAgent"
    Then the command fails with "The target provider instance is unavailable."

  @mc @priority-high
  Scenario Outline: A model change the running agent cannot take is refused
    Given "t1" runs on an ACP agent whose session does not offer switching models
    When the user <changes> "t1"
    Then the command fails with "The active ACP session does not expose a model-switch capability."
    And "t1" keeps its model

    Examples:
      | changes                                |
      | sets another model for                 |
      | sends a message on another model to    |

  @backlog @mc
  Scenario Outline: A change the provider cannot take in place restarts it on the same conversation
    Given "t1" has a live provider process
    When the user changes <what> of "t1" and sends a message
    Then the provider process of "t1" is restarted
    And the provider conversation is resumed without a handoff

    Examples:
      | what                                                                                       |
      | the runtime mode                                                                           |
      | the workspace                                                                              |
      | the instance, to another of the same provider that shares its home and so its conversation |

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

  # Upstream #23198: a send to a second Claude instance with its own history left the first
  # instance's session and process running.
  @backlog @mc @plugin-claude @priority-high
  Scenario: Sending to another Claude instance releases the one the thread left
    Given "t1" has a live provider process on the "claude" instance
    And a second Claude instance "claude-work" with its own home
    When the user switches "t1" to "claude-work" and sends a message
    Then the "claude" process of "t1" stops

  # Upstream #23198: background work, Claude's own subagents included, would have been cut off.
  @backlog @mc @plugin-claude @priority-high
  Scenario: Sending to another instance waits for background work on the one the thread left
    Given "t1" on the "claude" instance has a subagent still running in the background
    And a second Claude instance "claude-work" with its own home
    When the user switches "t1" to "claude-work" and sends a message
    Then the send is refused because background work is still running
    And once that work ends, sending again starts "claude-work" and stops "claude"

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

  # Upstream #29905: the handoff and side chat summaries read only a patch's first path, so the
  # receiving agent did not know the other files of a multi-file patch had changed.
  @mc
  Scenario Outline: Context handed to another agent names every file of a multi-file patch
    Given a turn of "t1" changed "src/a.ts", "src/b.ts" and "src/new.ts" in one patch
    When <handoff>
    Then the provider receives a file change naming "src/a.ts", "src/b.ts" and "src/new.ts"

    Examples:
      | handoff                                                     |
      | the user switches "t1" to "claudeAgent" and sends a message |

    # The MC has no side chats yet.
    @backlog
    Examples:
      | handoff                                         |
      | the user asks a question in a side chat of "t1" |

  @mc @backlog @priority-low
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
