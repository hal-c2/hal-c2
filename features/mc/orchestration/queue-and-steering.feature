# Sources:
#   https://github.com/pingdotgg/t3code/pull/27141
#   https://github.com/pingdotgg/t3code/pull/27221
#   https://github.com/pingdotgg/t3code/pull/16926
#   https://github.com/pingdotgg/t3code/pull/21473
#   https://github.com/pingdotgg/t3code/pull/15691
#   https://github.com/pingdotgg/t3code/pull/17773
#   https://github.com/pingdotgg/t3code/pull/20184
#   https://github.com/pingdotgg/t3code/pull/18824
#   https://github.com/pingdotgg/t3code/pull/19210
#   https://github.com/pingdotgg/t3code/pull/13764 (covered: the MC sends queued runs, so a thread the user is not viewing still sends when its turn ends)
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/25837
#   https://github.com/pingdotgg/t3code/pull/17885
#   apps/server-ex/priv/mcp_tools.json (hal_c2_thread_interrupt, holdQueue)
#   packages/contracts/src/orchestrationV2.ts (message.dispatch dispatchMode and deliveryIntent,
#     queued-run.cancel, queued-run.edit, queued-run.reorder, queued-message.promote-to-steer,
#     queue.resume, run.updated, message.updated, turn-item.updated)
#   apps/server-ex/lib/hal_c2/orchestration.ex (decide_message, queue_run, steer, restart_promoted, session_call)
#   apps/server/src/orchestration-v2/ (dispatch mode resolution)
#   apps/server/src/orchestration-v2/Orchestrator.ts (dispatchSteerIntoRun; a steer for a
#     completed run starts immediately)
#   apps/server/src/orchestration-v2/CommandPolicy.ts, QueuedRunOrder.ts (steer and restart
#     targets, delegated task results ahead of queued messages)
#   apps/server/src/orchestration-v2/EffectWorker.ts (provider-turn.steer failure handling)
#   apps/server/src/orchestration-v2/ProviderTurnControlService.ts (a restart waits for the interrupted turn)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts, ClaudeAdapterV2.ts (steerTurn
#     with attachments)
#   apps/server/src/orchestration-v2/testkit/ProviderSwitch.integration.test.ts (queued capability)
#   docs/user/ (composer queue and steer guidance)
Feature: Queueing, steering and restarting
  While a turn is active, a new message either steers it, waits in the thread's
  queue, or interrupts it and goes first. The engine decides from the message's
  delivery intent, its dispatch mode, and whether the provider can be steered.

  Background:
    Given an MC with a project "demo"
    And thread "t1" exists in "demo"

  @mc
  Scenario Outline: An automatic message steers a running turn when its provider can take it
    Given "t1" has a <status> turn on "<provider>"
    When the user sends "Also check the docs" to "t1" with automatic delivery
    Then the message joins the active run as a steer
    And the run has a user message turn item marked as a steer

    Examples:
      | status  | provider    |
      | running | codex       |
      | waiting | codex       |
      | running | claudeAgent |

  @mc
  Scenario: An automatic message queues behind a turn whose provider cannot be steered
    Given "t1" has a running turn on "grok"
    When the user sends "Next" to "t1" with automatic delivery
    Then "Next" waits in the queue at position 1

  @mc
  Scenario: An automatic message queues while the turn is still starting
    Given "t1" has a turn that is starting on "codex"
    When the user sends "Next" to "t1" with automatic delivery
    Then "Next" waits in the queue

  # Upstream #15691: automatic messages queue in the gap between a run's provider turns instead of being rejected.
  @backlog @mc
  Scenario: An automatic message queues while a run is between provider turns
    Given "t1" has an active run whose provider turn has finished and whose next turn has not started
    When the user sends "Next" to "t1" with automatic delivery
    Then "Next" waits in the queue
    And the message is not rejected

  @mc
  Scenario Outline: Queueing needs the provider the message is queued for to support a queue
    Given "t1" has a running turn on a provider that <active>
    When the user queues "Next" for a provider that <selected>
    Then the message <result>
    And "t1" stays on the model of the running turn

    Examples:
      | active                  | selected                | result                                              |
      | cannot queue messages   | can queue messages      | waits in the queue                                  |
      | can queue messages      | cannot queue messages   | is refused saying queued messages are not supported |

  @mc
  Scenario: A message sent to queue after the active turn always queues
    Given "t1" has a running turn on "codex"
    When the user sends "Later" to "t1" to queue after the active turn
    Then "Later" waits at the end of the queue

  @backlog @mc @plugin-claude
  Scenario: A steer leaves Claude's running subagents running
    Given "t1" has a running turn on "claudeAgent" with a subagent it started in the foreground
    When the user sends "Also" to "t1" as a steer
    Then the subagent moves to the background and keeps running
    And "Also" joins the running turn
    And the subagent's result wakes "t1" when it finishes

  @backlog @mc @plugin-codex
  Scenario: A Codex steer with a different model selection joins the running turn
    Given "t1" has a running turn on "codex" with subagents running
    When the user sends "Also" to "t1" as a steer with a different reasoning effort
    Then "Also" joins the running turn instead of restarting it
    And the subagents keep running
    And the new selection is used from the next turn

  @mc
  Scenario: An explicit steer that the provider cannot take interrupts and goes first
    Given "t1" has a running turn on "grok" and a queued message "Old"
    When the user sends "Now" to "t1" as a steer
    Then "Now" is first in the queue and "Old" moves to position 2
    And the running turn is interrupted
    And a run for "Now" starts when the interrupted run ends

  # The provider a message names takes the thread over (provider-handoff.feature), so it
  # never joins a turn the previous provider runs.
  @mc
  Scenario: A message for another provider waits for the running turn instead of steering it
    Given "t1" has a running turn on "codex"
    When the user sends "Over to Claude" for "claudeAgent" to "t1" with automatic delivery
    Then "Over to Claude" waits at the end of the queue
    And "Over to Claude" runs on "claudeAgent"

  @mc
  Scenario: An explicit steer for another provider interrupts the running turn and goes first
    Given "t1" has a running turn on "codex"
    When the user sends "Over to Claude" for "claudeAgent" to "t1" as a steer
    Then "Over to Claude" is first in the queue
    And the running turn is interrupted
    And a run for "Over to Claude" starts when the interrupted run ends
    And "Over to Claude" runs on "claudeAgent"

  # A client that sends behind its own sends still in flight compares against a thread
  # those sends have not moved yet, so its provider.switch can be missing.
  @mc
  Scenario: A message for another provider moves the thread over when its run starts
    Given "t1" has a running turn on "codex"
    And the user sent "Over to Claude" for "claudeAgent" to "t1" with automatic delivery
    And thread "t1" is on "codex"
    When the running turn completes
    Then the run for "Over to Claude" starts with ordinal 2
    And thread "t1" is on "claudeAgent"

  # What the MC queued for the agent before the agent switched provider (#1048).
  @mc
  Scenario: A delegated result queued before a switch runs on the provider the thread switched to
    Given "t1" has a running turn on "codex"
    And a delegated task result for "t1" waits in the queue
    When the agent of "t1" switches it to "claudeAgent"
    And the running turn completes
    Then the turn for the woken agent runs on "claudeAgent"
    And thread "t1" is on "claudeAgent"

  # A provider's wake finishes that provider's background work; it is no choice of provider.
  @mc
  Scenario: A provider's wake after a switch runs on that provider and leaves the switch standing
    Given "t1" has a running turn on "codex"
    And a background wake from "codex" for "t1" waits in the queue
    When the agent of "t1" switches it to "claudeAgent"
    And the running turn completes
    Then the turn for the woken agent runs on "codex"
    And thread "t1" is on "claudeAgent"

  @mc
  Scenario: A provider's wake on a switched idle thread runs on that provider and leaves the switch standing
    Given "t1" has a running turn on "codex"
    And the running turn completes
    When the agent of "t1" switches it to "claudeAgent"
    And a background wake from "codex" for "t1" arrives while no turn is running
    Then the turn for the woken agent runs on "codex"
    And thread "t1" is on "claudeAgent"
    When the woken turn completes
    And the user sends "Where were we?" to "t1" with automatic delivery
    Then "Where were we?" runs on "claudeAgent"
    And Claude receives the woken turn as earlier conversation before "Where were we?"

  @mc
  Scenario Outline: A restart interrupts the active turn and goes first
    Given "t1" has a running turn and a queued message "Old"
    When the user sends "Instead" to "t1" <how>
    Then "Instead" is first in the queue
    And the running turn is interrupted
    And a run for "Instead" starts when the interrupted run ends

    Examples:
      | how                          |
      | with restart delivery        |
      | to restart the active turn   |

  @mc
  Scenario: A restart whose interrupted turn never ends fails instead of running two turns
    Given "t1" has a running turn
    When the user sends "Instead" to "t1" to restart the active turn and the provider never ends the interrupted turn
    Then the restart fails saying the provider turn did not end before the restart
    And no second turn is started alongside the first

  # Upstream #27141: Antigravity ignored the cancel of a restarted turn; Stop then looked only for
  # the new attempt's turn, found none, and the old turn blocked every later message.
  @backlog @mc @priority-high
  Scenario: Stopping during a restart also stops the turn the provider did not give up
    Given "t1" has a running turn on a provider that ignores a request to end its turn
    And the user sent "Instead" to "t1" to restart the active turn
    When the user stops "t1" before the run for "Instead" reaches the provider
    Then the old turn is stopped as by a normal Stop
    And the next message the user sends to "t1" starts a turn

  @mc
  Scenario: A steer the provider refuses while its turn runs is reported to the sender
    Given "t1" has a running turn on "codex"
    And the provider refuses the steer
    When the user tries to send "Also" to "t1" as a steer
    Then the send fails saying Codex did not take the message into its running turn
    And "Also" is neither queued nor added to the running turn

  # The session stopped after the runtime was found, so the steer is refused
  # as if no session had been found, instead of crashing the dispatch.
  @mc
  Scenario: A steer whose session stopped is refused while its turn runs
    Given "t1" has a running turn on "codex"
    And the session of "t1" stops as it is asked to steer
    When the user tries to send "Also" to "t1" as a steer
    Then the send fails saying its session stopped
    And "Also" was not queued and the turn of "t1" is still running

  @mc
  Scenario: A steer sent twice at once reaches the provider once
    Given "t1" has a running turn on "codex"
    When the user's client sends the steer "Also" to "t1" twice at once
    Then the first send succeeds
    And the repeat is told "Also" is still being sent
    And Codex is asked to take "Also" once
    And "Also" is in the running turn once
    And sending "Also" again now succeeds

  # Nobody hears a message was sent while the provider can still refuse it.
  @mc
  Scenario: A steer sent twice at once that the provider refuses is reported to both sends
    Given "t1" has a running turn on "codex"
    And the provider refuses the steer
    When the user's client sends the steer "Also" to "t1" twice at once
    Then the first send fails saying Codex did not take the message into its running turn
    And the repeat is told "Also" is still being sent
    And "Also" is neither queued nor added to the running turn

  # A refusal can still drop the message once its turn ended.
  @mc
  Scenario: A repeat of a steer whose turn ended while the provider was asked is still being sent
    Given "t1" has a running turn on "codex"
    And the provider is holding the steer "Also" sent to "t1"
    And the running turn of "t1" ends
    When the user's client sends the steer "Also" again
    Then the repeat is told "Also" is still being sent

  # No send is left to answer for it, so a retry does not wait for one.
  @mc
  Scenario: A steer an MC restart cut off reads as sent
    Given "t1" has a running turn on "codex"
    And the provider is holding the steer "Also" sent to "t1"
    When the MC restarts while its runtime for "t1" is stuck on the provider
    Then sending "Also" again now succeeds

  @mc
  Scenario: A steer the provider takes as its turn ends is shown before its answer
    Given "t1" has a running turn on "codex" that ends as it takes a steer
    When the user sends "Also" to "t1" as a steer
    Then "Also" is in the turn ahead of the answer to it

  @mc
  Scenario Outline: A steer carries the message's files and images to the provider
    Given "t1" has a running turn on "<provider>"
    When the user steers "t1" with "Look at this" and an attached screenshot
    Then the running turn answers "Look at this" having seen the screenshot

    Examples:
      | provider    |
      | codex       |
      | claudeAgent |

  @mc
  Scenario: A queued message keeps its own run id and takes the next ordinal when it starts
    Given "t1" has a running turn and a queued message "Next" with ordinal 3
    When the running turn completes
    Then the run for "Next" starts with ordinal 3
    And its user message turn item is marked as a queued turn

  @mc
  Scenario: Cancelling a queued message
    Given "t1" has a running turn and queued messages "A", "B" and "C"
    When the user cancels queued message "B"
    Then "B" is cancelled
    And "A" and "C" are at positions 1 and 2

  @mc
  Scenario: Cancelling a run that is not queued changes nothing
    Given "t1" has a running turn
    When the user cancels the running turn as if it were queued
    Then the running turn is unchanged

  @mc
  Scenario: Editing a queued message changes its text
    Given "t1" has a queued message "Tpyo"
    When the user edits the queued message to "Typo"
    Then the queued message reads "Typo"

  @mc
  Scenario: Editing a message that already started changes nothing
    Given "t1" has a run for "Started" that is running
    When the user edits that message as if it were queued
    Then the message still reads "Started"

  @mc
  Scenario: Editing a queued message can replace its attachments and context
    Given "t1" has a queued message with an attached screenshot
    When the user edits the queued message removing the screenshot and adding a file reference
    Then the queued message carries only the file reference

  @mc @backlog
  Scenario: An image added while editing a queued message keeps the earlier image intact
    Given "t1" has a queued message with the image "before.png"
    When the user edits the queued message adding the image "after.png"
    Then the queued message carries both images
    And "before.png" still reads as it did

  @mc
  Scenario: Reordering a queued message before another
    Given "t1" has queued messages "A", "B" and "C"
    When the user moves "C" before "A"
    Then the queue order is "C", "A", "B"

  @mc
  Scenario: Reordering without a known target moves the message to the end
    Given "t1" has queued messages "A", "B" and "C"
    When the user moves "A" before a message that is not queued
    Then the queue order is "B", "C", "A"

  @mc
  Scenario: Promoting a queued message steers the running turn when possible
    Given "t1" has a running turn on "codex" and a queued message "Hurry"
    When the user promotes "Hurry" to a steer
    Then the queued run for "Hurry" is cancelled and leaves the queue
    And "Hurry" joins the running turn as a promoted steer

  @mc
  Scenario: Promoting a queued message on a provider that cannot steer interrupts and goes first
    Given "t1" has a running turn on "grok" and queued messages "A" and "Hurry"
    When the user promotes "Hurry" to a steer
    Then "Hurry" is first in the queue
    And the running turn is interrupted

  @mc
  Scenario: Promoting a queued message for another provider interrupts the running turn and goes first
    Given "t1" has a running turn on "codex" and a message "Hurry" queued for "claudeAgent"
    When the user promotes "Hurry" to a steer
    Then "Hurry" is first in the queue
    And the running turn is interrupted
    And "Hurry" runs on "claudeAgent"

  # Upstream #16926: a queued message promoted to a steer after Stop could land on the stopping
  # run and be lost.
  @mc
  Scenario Outline: A turn being stopped cannot be steered into
    Given "t1" has a running turn on "codex" and a queued message "Next"
    And the user stopped the running turn of "t1" and the provider is still stopping it
    When the user tries to <action>
    Then the command is refused
    And "Next" is still queued and held

    Examples:
      | action                              |
      | promote "Next" to a steer           |
      | send "Also" to "t1" as a steer      |
      | send "Instead" to "t1" with restart |

  # Upstream #16926: an ordinary send during the Stop waits in the queue instead of steering,
  # and, sent by the user, resumes the queue the Stop held.
  @mc
  Scenario: A message sent while a turn is being stopped queues behind earlier messages
    Given "t1" has a running turn on "codex" and a queued message "Next"
    And the user stopped the running turn of "t1" and the provider is still stopping it
    When the user sends "Also" to "t1"
    Then "Also" is queued after "Next" without steering the stopping turn
    And "Next" starts once the turn has stopped

  @mc
  Scenario: Queued messages wait after an MC restart until the user resumes the queue
    Given "t1" had a queued message when the MC restarted
    Then the queued message is held
    And no run starts for it

  @mc
  Scenario: Resuming the queue starts the next queued message
    Given "t1" has held queued messages "A" and "B"
    When the user resumes the queue of "t1"
    Then no queued message is held
    And a run for "A" starts

  @mc @shared
  Scenario: A usage limit keeps the queue as it was
    Given "t1" has a running turn and queued messages "one" and "two"
    When the provider stops "t1" because its usage limit was reached
    Then "one" and "two" stay queued in their original order
    And neither is discarded or sent early

  # Upstream #21473: a run started by a message the user sent releases the hold, so only a
  # run the user did not start leaves it.
  @mc
  Scenario: A held queue does not start when a run the user did not start ends
    Given "t1" has a held queued message "A"
    When another agent's message reaches "t1" and its run ends
    Then "A" is still queued

  # Runs are numbered in the order they start: checkpoints, handoffs and windowed
  # history count by it.
  # Upstream #17773: queued messages land after a resume that ran before them
  # Upstream #21473: the newer message the user sent releases the hold, so "A" starts after it
  # without a resume, still numbered after it.
  @mc
  Scenario: A held queued message starts on its own after a newer message the user sent
    Given "t1" has a held queued message "A"
    When the user sends "Something else" to "t1" and its run ends
    Then the run for "A" starts with ordinal 3
    And the run for "Something else" has ordinal 2
    And the thread's latest run is the run for "A"

  @mc
  Scenario: A queued delegated task result runs before the user's queued messages
    Given "t1" has a running turn and a queued message "Next"
    And a delegated task of "t1" finished, so its result is queued after "Next"
    When the running turn completes
    Then the turn carrying the task result starts first
    And "Next" starts after it

  @mc
  Scenario Outline: A queued delegated task result cannot be handled like a queued message
    Given "t1" has a running turn and a queued delegated task result
    When the user tries to <action> the queued result
    Then the command fails with "<message>"

    Examples:
      | action                  | message                                                      |
      | promote it to a steer   | Automatic completion deliveries cannot be promoted to Steer. |
      | move it in the queue    | Automatic completion deliveries cannot be reordered.         |
      | edit                    | Automatic completion deliveries cannot be edited.            |

  @mc
  Scenario: A restart goes ahead of the user's queued messages but behind a queued task result
    Given "t1" has a queued delegated task result and a queued message "Next"
    When the user sends "Instead" to "t1" with restart delivery
    Then the turn carrying the task result starts when the interrupted run ends
    And "Instead" and "Next" wait behind it in that order

  @mc
  Scenario: A queued message cannot be moved ahead of a queued delegated task result
    Given "t1" has a queued delegated task result and a queued message "Next"
    When the user moves "Next" before the queued result
    Then the command fails with "Queued messages cannot be reordered ahead of automatic completion delivery."

  @mc
  Scenario: Cancelling a queued delegated task result gives up waking the agent for it
    Given "t1" has a running turn and a queued result for delegated tasks "one" and "two"
    When the user cancels the queued result
    Then it leaves the queue
    And the agent of "t1" is not woken again for "one" or "two"
    And their results can still be read from each task's status

  # Upstream #21473: a message the user sends releases a held queue, so nothing queued after it
  # inherits the hold.
  @mc
  Scenario: A message the user sends resumes a held queue
    Given "t1" has a held queued message "A"
    When the user sends "B" to "t1" and its turn stays running
    Then no queued message is held
    And a delegated task result queued behind "B" is not held
    And "A" starts after the run for "B" ends

  # Upstream #21473: a Stop holds the queue as a restart does.
  @mc
  Scenario: Stopping a turn holds the queue
    Given "t1" has a running turn and a queued message "A"
    When the user stops the turn
    Then "A" is held
    And no run starts for it until the user resumes the queue or sends a message

  # An agent stops a turn for the user (hal_c2_thread_interrupt): its Stop holds the queue too.
  @mc
  Scenario: An agent's interrupt holds the queue
    Given an agent is working in thread "caller" in "demo"
    And "t1" has a running turn and a queued message "A"
    When the agent of "caller" interrupts "t1"
    Then "A" is held
    And no run starts for it until the user resumes the queue or sends a message

  # An orchestrating agent may stop a turn and let the next queued message go on.
  @mc
  Scenario: An agent's interrupt can let the queue run
    Given an agent is working in thread "caller" in "demo"
    And "t1" has a running turn and a queued message "A"
    When the agent of "caller" interrupts "t1" and lets its queue run
    Then "A" starts once the turn has stopped

  # Upstream #21473: only the user coming back releases the hold.
  @mc
  Scenario Outline: What is not the user sending a message leaves the queue held
    Given "t1" has a held queued message "A"
    When <what> reaches "t1"
    Then "A" is still held

    Examples:
      | what                                             |
      | a steer the user sent                            |
      | the prompt of a scheduled task the user created  |
      | the MC continuing the thread after a usage limit |
      | the MC continuing the thread after it restarted  |

  # Upstream #21473: messages held because the worktree could not be set up would otherwise start
  # in the project checkout.
  @mc
  Scenario: A queue held because the worktree could not be set up stays held when the user sends
    Given "t1" has a held queued message "A" because its worktree could not be set up
    When the user sends "B" to "t1"
    Then "A" is still held until "t1" has a worktree

  # Only what the user queues waits on a held queue: what the agent is sent still wakes it.
  @mc
  Scenario Outline: What the agent is sent while the queue is held still wakes it
    Given "t1" has a held queued message "A"
    When <what> reaches "t1" while no turn is running
    Then a turn for it starts
    And "A" is still queued

    Examples:
      | what                        |
      | a delegated task result     |
      | a background command's end  |
      | another agent's message     |

  # Upstream #27221: messages from agents, MCP tools and scheduled tasks that arrived while the
  # thread was busy joined the hold, and nobody ever resumed it (165 issue dispatches sat held).
  @backlog @mc @priority-high
  Scenario Outline: A held message no person wrote starts once the thread completes a run
    Given "t1" has a held queued message "A" the user wrote
    And <source> queued "B" on "t1" while a turn was running
    When the newest run of "t1" completes
    Then "B" starts in queue order
    And "A" is still held for the user

    Examples:
      | source           |
      | another agent    |
      | an MCP tool      |
      | a scheduled task |

  # Upstream #27221
  @backlog @mc @priority-high
  Scenario Outline: A run that did not complete releases nothing held
    Given another agent's message "B" is held on "t1"
    When <ending>
    Then "B" is still held

    Examples:
      | ending                                                  |
      | the newest run of "t1" fails                            |
      | the user stops a run that then completes anyway         |
      | an older run of "t1" is completed again for bookkeeping |

  # Upstream #17885: a Claude wake queued while a run was settling took on an older held user
  # message, so it never started and its subagents stayed Running after they finished.
  @backlog @mc @plugin-claude @priority-high
  Scenario: A provider's wake queued while a run settles starts past an older held message
    Given "t1" on Claude has a held queued message "A"
    And a run of "t1" is settling
    When a Claude background task of "t1" finishes and its wake is queued
    Then a turn for the wake starts once the run has settled
    And "A" is still queued

  # Upstream #17885: a wake does not pass the hold once the user has stopped the run.
  @backlog @mc @plugin-claude
  Scenario: A provider's wake does not pass a held message once the user stopped the run
    Given "t1" on Claude has a held queued message "A"
    And the user stopped the running turn of "t1"
    When a Claude background task of "t1" finishes and its wake is queued
    Then neither the wake nor "A" starts until the user resumes the queue

  @mc
  Scenario: A queued message that could not start says so in the timeline
    Given "t1" has a running turn and a queued message "Next"
    When the running turn completes and the provider for "Next" cannot be started
    Then the run for "Next" fails
    And the timeline shows an error titled "Queued provider could not start" with the reason

  @mc
  Scenario: A steer that arrives after its turn finished starts a new turn
    Given "t1" had a running turn that completed
    When a steer the user sent for that turn reaches the MC afterwards
    Then the message is not lost
    And it starts a new turn of "t1"

  @mc
  Scenario Outline: A steer or restart must name the thread's active turn
    Given "t1" has a running turn and an older turn that <state>
    When the user sends "Now" to "t1" as a <delivery> of the older turn
    Then the command is refused
    And the running turn is not disturbed

    Examples:
      | state           | delivery |
      | completed       | restart  |
      | was interrupted | steer    |
      | was interrupted | restart  |

  @mc
  Scenario Outline: Compacting and signing out cannot be steered into a turn
    Given "t1" has a running turn on "codex"
    When the user sends "<command>" by itself to "t1" as a steer
    Then the command fails with "<message>"

    Examples:
      | command  | message                                                                                          |
      | /compact | Context compaction must run as a separate turn. Queue it or wait for the active turn to finish. |
      | /logout  | Signing out must run as a separate turn. Queue it or wait for the active turn to finish.        |

  @mc
  Scenario Outline: A turn that is compacting or signing out cannot be steered
    Given "t1" has a running turn started by "<command>" sent by itself
    When the user sends "Also check the docs" to "t1" as a steer
    Then the command fails with "<message>"

    Examples:
      | command  | message                                                            |
      | /compact | Wait for context compaction to finish before steering the thread. |
      | /logout  | Wait for sign-out to finish before steering the thread.           |

  # Upstream #20184 queues these steers instead of refusing them, so the message is no
  # longer stuck in the composer. Replaces the scenario above once the MC carries it.
  @mc @backlog
  Scenario Outline: A steer sent while a thread compacts or signs out is queued
    Given "t1" has a running turn started by "<command>" sent by itself
    When the user sends "Also check the docs" to "t1" as a steer
    Then "Also check the docs" is queued to run after the active turn
    And it runs once the "<command>" turn finishes

    Examples:
      | command  |
      | /compact |
      | /logout  |

  @shared @backlog
  Scenario: The composer offers to queue while the thread compacts
    Given the user's follow-up behaviour is to steer
    And "t1" is running "/compact"
    When the user writes a follow-up, with or without the steer modifier held
    Then the composer's send action queues it

  # Upstream #25837: Send now on a queued message during a compaction did nothing; it now stops
  # the compaction and runs the message next, leaving the context uncompacted.
  @mc @backlog @priority-high
  Scenario Outline: Sending a queued message now during a compaction skips the compaction
    Given "t1" is running "/compact" and "<message>" is queued
    When the user sends "<message>" now
    Then the compaction stops and the context is left as it was
    And a turn starts with "<message>" next

    Examples:
      | message        |
      | Check the docs |
      | /goal ship it  |

  @mc
  Scenario: A queued message cannot be edited down to nothing
    Given "t1" has a queued message "Next" with no attachments
    When the user edits the queued message to empty text
    Then the command fails saying the queued run cannot be edited to an empty message
    And the queued message still reads "Next"

  @mc
  Scenario Outline: The queue of an archived thread cannot be worked
    Given "t1" has a queued message "Next" and is archived
    When a client tries to <action>
    Then the command fails with "Thread t1 is not active."

    Examples:
      | action                           |
      | promote "Next" to a steer        |
      | resume the queue of "t1"         |
