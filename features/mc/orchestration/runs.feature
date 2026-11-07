# Sources:
#   https://github.com/pingdotgg/t3code/pull/27252
#   https://github.com/pingdotgg/t3code/pull/23313
#   https://github.com/pingdotgg/t3code/pull/19646
#   https://github.com/pingdotgg/t3code/pull/24299
#   https://github.com/pingdotgg/t3code/pull/23169
#   https://github.com/pingdotgg/t3code/pull/22846
#   https://github.com/pingdotgg/t3code/pull/16303
#   https://github.com/pingdotgg/t3code/pull/19023
#   https://github.com/pingdotgg/t3code/pull/19131
#   https://github.com/pingdotgg/t3code/pull/15571
#   https://github.com/pingdotgg/t3code/pull/15442
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/24172
#   https://github.com/pingdotgg/t3code/pull/26782
#   https://github.com/pingdotgg/t3code/pull/28520
#   packages/contracts/src/orchestrationV2.ts (message.dispatch, message.updated, run.created,
#     run.updated, run-attempt.created, run-attempt.updated, node.updated, turn-item.updated,
#     provider-session.attached, provider-session.updated, provider-session.detach,
#     provider-session.detached, provider-thread.updated, provider-turn.updated,
#     checkpoint-scope.created, run.interrupt)
#   packages/contracts/src/rpc.ts (orchestration.dispatchCommand, provider.uploadFeedback)
#   apps/server-ex/lib/hal_c2/orchestration.ex (dispatch_message, new_run, begin_turn, release_session)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (begin_turn, interrupt)
#   apps/server-ex/proof/models/turns.maude
#   apps/server/src/orchestration-v2/ (run lifecycle)
#   apps/server/src/orchestration-v2/RunExecutionService.ts (interrupt outcome, open subagents, bare
#     compact command, preparation failure, events of threads sharing a provider process)
#   apps/server/src/orchestration-v2/Orchestrator.ts (interrupt request item)
#   apps/server/src/orchestration-v2/assistantStreaming.ts (what paragraph streaming holds back)
#   apps/server/src/orchestration-v2/EventSink.ts (late updates of an attempt that was replaced)
#   apps/server/src/orchestration-v2/ProviderFailure.ts (failure messages, redaction, retry titles)
#   apps/server/src/orchestration-v2/ProviderAdapterRegistry.ts (sign-in changes block session starts)
#   apps/server/src/orchestration-v2/ProviderTurnStartService.ts (sign-out and compact commands)
#   apps/server/src/orchestration-v2/ProviderSessionManager.ts (workspace checks, sign-out closes sessions)
#   apps/server/src/provider/Errors.ts (ProviderInstanceNotFoundError),
#     apps/server/src/provider/Services/ProviderInstanceRegistry.ts
#   docs/internals/glossary.md
Feature: Runs and turns
  Sending a message to an idle thread starts a run. The engine records the
  message, the run, its attempt and its root node, starts the provider turn, and
  writes what the provider streams back as turn items until the root completes.

  Background:
    Given an MC with a project "demo" rooted at a git repository
    And thread "t1" exists in "demo" with provider "codex"

  @mc
  Scenario: A message to an idle thread starts a run
    When the user sends "Add a test" to "t1"
    Then "t1" has a run with ordinal 1 that is starting
    And the run has an attempt and a root turn node
    And the user message "Add a test" is recorded with a turn-start turn item
    And the dispatch answers with the thread's stream sequence

  @mc
  Scenario: Run ordinals count up per thread
    Given "t1" has completed one run
    When the user sends another message to "t1"
    Then the new run has ordinal 2

  @mc
  Scenario: A message to an unknown thread is refused
    When the user sends "Hi" to thread "missing"
    Then the command fails with "unknown thread missing"

  @mc
  Scenario: A message to a thread whose provider instance is unknown is refused
    Given thread "t2" exists in "demo" with provider instance "removed_instance"
    And the MC has no provider instance "removed_instance"
    When the user sends "Hi" to "t2"
    Then the provider instance is reported as unavailable
    And no turn starts on any other provider

  @mc
  Scenario: The first run of a thread opens a provider session and provider thread
    When the user sends "Hi" to "t1"
    Then "t1" has a provider session for "codex" that is ready
    And "t1" has a provider thread for "codex" recording run ordinal 1
    And "t1" has one root checkpoint scope rooted at its working directory

  @mc
  Scenario: A later run reuses the provider thread and moves the checkpoint scope to it
    Given "t1" has completed one run
    When the user sends another message to "t1"
    Then the provider thread records run ordinal 2
    And the root checkpoint scope follows the new run

  @mc
  Scenario: A stopped provider session is ready again for the next run
    Given the provider session of "t1" was stopped while idle
    When the user sends "Hi" to "t1"
    Then the provider session of "t1" is ready
    And the provider resumes its earlier conversation

  @mc
  Scenario: A run uses the message's model selection over the thread's
    Given "t1" uses model "gpt-a"
    When the user sends "Hi" to "t1" choosing model "gpt-b"
    Then the run records model "gpt-b"

  @mc
  Scenario: A run works in the thread's worktree when it has one
    Given "t1" is in worktree "/work/x"
    When the user sends "Hi" to "t1"
    Then the turn runs in "/work/x"

  @mc
  Scenario: A worktree that was removed is recreated before the turn starts
    Given "t1" is in worktree "/work/x" and that folder no longer exists
    When the user sends "Hi" to "t1"
    Then the worktree is recreated from the branch of "t1"
    And only then does the turn start

  @mc
  Scenario: A run works in the project root when the thread has no worktree
    When the user sends "Hi" to "t1"
    Then the turn runs in the root of "demo"

  @mc
  Scenario: A baseline checkpoint is captured before the first turn
    When the user sends "Hi" to "t1"
    Then a checkpoint for ordinal 0 exists before the turn starts

  @mc
  Scenario Outline: Provider output becomes turn items
    Given "t1" has a running turn
    When the provider reports <output>
    Then the run has a "<item>" turn item

    Examples:
      | output                      | item              |
      | assistant text              | assistant_message |
      | reasoning                   | reasoning         |
      | a command it ran            | command_execution |
      | a file it changed           | file_change       |
      | a web search                | web_search        |
      | a dynamic tool call         | dynamic_tool      |
      | a proposed plan             | proposed_plan     |
      | a to-do list                | todo_list         |

  @mc
  Scenario: Assistant text streams into a message that ends when the turn item finishes
    Given "t1" has a running turn
    When the provider streams assistant text in several chunks
    Then one assistant message grows with each chunk
    And the message stops streaming when the provider finishes it

  @mc
  Scenario Outline: Streaming mode decides how often assistant text is written
    Given project "demo" streams responses by "<mode>"
    And "t1" has a running turn
    When the provider streams assistant text
    Then the text is written <cadence>

    Examples:
      | mode      | cadence                                                             |
      | paragraph | a paragraph or closed code fence at a time, at most every 400 ms    |
      | turn      | only at a boundary such as the end of the item                       |

  @mc
  Scenario: Paragraph streaming is the default
    Given project "demo" has no response streaming setting
    When a turn streams assistant text
    Then the text is written a paragraph at a time

  @mc
  Scenario: Reasoning streams by the same mode as the reply
    Given project "demo" streams responses by "paragraph"
    And "t1" has a running turn
    When the provider streams reasoning text
    Then the reasoning is written a paragraph at a time, at most every 400 ms
    And by "turn" it is written only when the reasoning is finished

  @mc
  Scenario Outline: Paragraph streaming holds back text whose shape could still change
    Given project "demo" streams responses by "paragraph"
    And "t1" has a running turn
    When the provider has streamed <text so far>
    Then <what is written>

    Examples:
      | text so far                                             | what is written                                   |
      | a paragraph and half of the next line                   | only the paragraph is written                     |
      | a paragraph and an opened code block with blank lines   | nothing inside the open code block is written     |
      | a code block nested in a list item, then its close      | the text up to and including the close is written |
      | a first paragraph with no blank line after it yet       | nothing is written                                |

  @mc
  Scenario: The held-back tail is written when the reply finishes
    Given project "demo" streams responses by "paragraph"
    And the provider streamed a reply that ends without a blank line
    When the provider finishes the reply
    Then the whole reply is written at once, whatever was held back

  # Upstream #19023: a held-back reply written at turn end stays where it was said.
  @mc
  Scenario: A held-back reply cut off by a steer keeps its place
    Given the agent's reply is partly held back
    And the user steers the turn before the reply finishes
    When the turn ends and the held-back reply is written
    Then the reply appears before the steer and what followed it, where the agent said it

  @mc
  Scenario: Tool output streams without waiting for a paragraph
    Given "t1" has a running turn
    When a command the agent runs prints output
    Then the output is written as it arrives

  @mc
  Scenario: A completed turn completes the run and captures a checkpoint
    Given "t1" has a running turn
    When the provider completes the turn
    Then the run is completed
    And a ready checkpoint for the run exists with the files it changed
    And the run has a checkpoint turn item

  @mc
  Scenario: Items still running when the turn ends are closed
    Given "t1" has a running turn with a web search still running
    When the provider completes the turn
    Then no turn item of the run is still running

  @mc
  Scenario: A failed turn records the error on the provider session
    Given "t1" has a running turn
    When the provider fails the turn with "rate limited"
    Then the run is failed
    And the provider session's last error is "rate limited"

  @mc
  Scenario: A provider that dies while starting the turn fails the run
    Given the provider process exits while "t1" starts a turn
    Then the run is failed with "The provider stopped while starting the turn."
    And "t1" can take its next message

  @mc
  Scenario: A provider that dies while starting the turn says why
    Given the provider process exits saying "Config files in mise.toml are not trusted." while "t1" starts a turn
    Then the run is failed, and its error ends with "It said:\nConfig files in mise.toml are not trusted."

  # Upstream #16303: known reasons a provider refused a turn were hidden behind a generic failure.
  @backlog @mc @priority-low
  Scenario Outline: A turn the provider refuses to start says why
    Given the provider refuses to start the turn of "t1" because <cause>
    Then the run is failed with "<message>"
    And the provider's own details are not shown as the message

    Examples:
      | cause                                 | message                                                    |
      | an attached file could not be read    | An attachment could not be read. Attach it again.          |
      | it is still running the previous turn | The previous turn is still running. Wait for it to finish. |

  # Upstream #23169: a full disk or a database error failed the run while the provider kept
  # working, and every follow-up failed because the old provider turn was still running.
  @backlog @mc @priority-high
  Scenario: A run whose events cannot be recorded stops its provider turn
    Given "t1" has a running turn
    When the MC fails to record the turn's events
    Then the run is failed and the provider turn is interrupted together
    And "t1" can take its next message in the same provider conversation

  # Upstream #19646: a run whose failure could not be written stayed running after storage recovered.
  @backlog @mc @priority-high
  Scenario: A run failure that could not be recorded is recorded once storage recovers
    Given "t1" has a running turn
    When the MC fails to record the turn's events and then fails to record the run's failure
    And the database recovers
    Then the run is recorded as failed at the time it failed
    And "t1" no longer shows a running turn

  # Upstream #23169: a follow-up first stops the provider turn an earlier failed run left running.
  @backlog @mc
  Scenario: A follow-up first stops a provider turn an earlier failed run left running
    Given an earlier run of "t1" failed while its provider turn kept running
    When the user sends "t1" another message
    Then the left-over provider turn is interrupted first
    And the new turn runs in the same provider conversation

  # Upstream #22846: the failure path wrote a turn that had already completed or failed as
  # interrupted, and wrote it even when the interrupt itself failed.
  @backlog @mc @priority-high
  Scenario Outline: A run whose events cannot be recorded keeps how its provider turn ended
    Given the provider turn of "t1" <state>
    When the MC fails to record the turn's events and interrupts the provider turn
    Then the provider turn reads as <outcome>

    Examples:
      | state                    | outcome                                         |
      | had already completed    | completed                                       |
      | had already failed       | failed                                          |
      | was still running        | interrupted                                     |
      | could not be interrupted | running, so the next message stops it first     |

  @mc
  Scenario: A provider session that cannot be opened fails the run
    Given the provider's session cannot be opened while "t1" starts a turn
    Then the run is failed
    And "t1" can take its next message

  # Upstream #19131: a run fails when its provider stream ends without a terminal event
  @mc @priority-high
  Scenario: A provider stream that ends without ending its turn fails the run
    Given "t1" has a running turn with a subagent still running
    When the provider's event stream ends without saying the turn ended
    Then the run and its subagents are failed
    And "t1" can take its next message
    But a stream the MC ends because it is shutting down leaves the run for recovery

  # A delete, or a start that gave up waiting on the provider, ends a run while its
  # provider turn still starts or ends; that end stands.
  @mc
  Scenario: A turn that ends after its thread was deleted stays cancelled
    Given "t1" has a running turn
    When the provider ends the turn while "t1" is deleted
    Then the run of "t1" stays cancelled

  @mc
  Scenario: A turn that starts after its thread was deleted stays cancelled
    When "t1" is deleted while its turn starts
    Then the run of "t1" stays cancelled

  @mc
  Scenario: A turn that starts after its start gave up stays failed
    Given the start of a turn in "t1" gave up while a second message waits
    When the provider starts the first turn anyway
    Then the first run of "t1" stays failed and the second runs alone

  # Whether and how often to retry is each provider plugin's own behaviour; the core
  # only waits for the plugin to give up.
  @mc
  Scenario: A provider plugin's own retries run before the run fails
    Given a provider whose plugin retries opening its session
    And opening the session fails the first time
    When the user sends "Hi" to "t1"
    Then the plugin opens the session again
    And the run fails only once the plugin gives up

  @mc @shared @backlog-mobile @priority-high
  Scenario: A failed turn keeps the output it had already produced
    Given the provider streamed part of its answer to "t1" and then failed
    When the failure is recorded
    Then the partial answer stays in the failed run
    And the run is marked failed

  @backlog @mc
  Scenario: Late updates from an attempt that was replaced are ignored
    Given a turn of "t1" was restarted as a new attempt
    When the first attempt reports a late change to the run or to its provider conversation
    Then the run keeps following the new attempt
    And the provider conversation the new attempt claimed is not changed

  @mc @shared @backlog-mobile
  Scenario: A provider retry is recorded as a retry
    Given the provider retries a failed request during a turn of "t1"
    When the retry is recorded
    Then the turn's work log shows a provider retry
    And no second user turn is created

  @mc
  Scenario Outline: A provider retry says how it ended
    Given the provider is retrying a failed request during a turn of "t1"
    When <ending>
    Then the retry's entry in the turn's work log reads "<title>"
    And the turn has only that one entry for the failure

    Examples:
      | ending                                       | title                  |
      | the retry succeeds                           | Provider recovered     |
      | the provider gives up                        | Provider error         |
      | the provider gives up on its usage limit     | Usage limit reached    |
      | the user stops the turn while it is retrying | Provider retry stopped |

  # Upstream #26782: a database that could not be written during a turn read as "Provider turn failed."
  @backlog @mc @priority-high
  Scenario Outline: A failed turn says what the user can do about it
    When a turn of "t1" fails because <cause>
    Then the run fails with "<message>"

    Examples:
      | cause                                                   | message                                                                                                                  |
      | the provider's session could not be opened              | The provider session could not be opened. Check that the provider is installed and signed in, then retry the turn.       |
      | the provider's conversation could not be resumed        | The provider conversation could not be resumed. Retry the turn; if it keeps failing, check the provider and server logs. |
      | the provider could not start the turn                   | The provider could not start this turn. Retry the turn; if it keeps failing, check the provider setup and server logs.   |
      | the provider's event stream closed mid-turn             | The provider event stream closed unexpectedly. Retry the turn; if it keeps failing, check the provider and server logs.  |
      | the MC cannot tell whether handed-over history arrived  | HAL-C2 could not confirm whether conversation history reached the provider. Retry the turn to recover the session.       |
      | the MC cannot write its database while recording it     | The MC could not write its database. Check free disk space and that its data folder is writable, then retry the turn.    |
      | of an internal error the provider did not explain       | Provider turn failed.                                                                                                    |

  @mc @priority-high
  Scenario Outline: A failure message never shows credentials
    When the provider fails a turn of "t1" with a message holding <secret>
    Then the failure the thread records shows <shown>

    Examples:
      | secret                                         | shown                                    |
      | a URL with a user name, password and query     | the URL without its credentials or query |
      | a bearer or basic authorization value          | "[REDACTED]" in place of the value       |
      | an API key, token, password or secret          | "[REDACTED]" in place of the value       |
      | a prefixed key, client secret or refresh token | "[REDACTED]" in place of the value       |
      | a URL that cannot be read                      | "[REDACTED_URL]" in place of the URL     |
  # Upstream #23313: values under keys like "client_secret" or "clientSecret" survived, being no bare key word.
  @mc @priority-high
  Scenario Outline: A failure message hides values under compound credential keys
    When the provider fails a turn of "t1" with a message holding <text>
    Then the failure the thread records shows <shown>

    Examples:
      | text                                                 | shown                                          |
      | client_secret=abc refresh_token=def                  | client_secret=[REDACTED] refresh_token=[REDACTED] |
      | {"client_secret":"abc"}                              | {"client_secret":"[REDACTED]"}                 |
      | clientSecret: abc                                    | clientSecret: [REDACTED]                       |
      | max_tokens=4096 input_tokens: 12                     | max_tokens=4096 input_tokens: 12               |


  @mc @priority-low
  Scenario: A very long failure message is cut short
    When the provider fails a turn of "t1" with a message longer than 4,096 characters
    Then the failure the thread records is at most 4,096 characters and ends with "…"

  @backlog @mc
  Scenario: A turn cannot start while its provider's sign-in is changing
    Given the user is signing in to or out of the provider of "t1"
    When the user sends "Hi" to "t1"
    Then the run fails with "This provider's sign-in is changing. Try again after it finishes."

  @backlog @mc
  Scenario: A sign-in change holds back every instance that shares the login
    Given two instances of a provider share one saved login
    When the user signs out of the first while a turn is starting on the second
    Then the second's turn fails with "This provider's sign-in is changing. Try again after it finishes."

  @backlog @mc
  Scenario: Signing out of a provider stops the sessions of that instance
    Given "t1" is idle with a provider session
    When the user signs out of the provider instance of "t1"
    Then the provider process for "t1" stops
    And sessions on other instances keep running

  @backlog @mc
  Scenario: A sign-out sent as a message is handled by the MC, not the agent
    Given the provider of "t1" has a sign-out command
    When the user sends that command by itself to "t1"
    Then the provider instance is signed out and the run completes with "Provider signed out"
    And the command is not sent to the agent

  @backlog @mc
  Scenario: A sign-out sent as a message signs out the provider the thread last ran on
    Given "t1" last ran on one provider instance and the user has since picked another
    When the user sends the sign-out command by itself to "t1"
    Then the instance "t1" last ran on is signed out

  @backlog @mc
  Scenario: A sign-out sent as a message that fails says why
    Given the provider of "t1" cannot be signed out
    When the user sends the sign-out command by itself to "t1"
    Then the run fails with "Provider sign-out failed" and the provider's reason

  @mc
  Scenario: Compacting a thread with no conversation is refused
    Given "t1" has no conversation yet
    When the user sends "/compact" to "t1"
    Then the run fails with "Cannot compact an empty thread" and "Start a conversation before compacting this thread."
    And no provider process is started for it

  # Upstream #24172: a fork's first /compact was refused as an empty thread.
  @backlog @mc
  Scenario Outline: A fork's first compact compacts the history it inherited
    Given "t2" is a <kind> fork of "t1" with no turns of its own
    When the user sends "/compact" to "t2"
    Then the provider is asked to compact the history "t2" inherited

    Examples:
      | kind     |
      | native   |
      | portable |

  # Upstream #24172: a fork's first /compact is refused only when its handoff carries no messages.
  @backlog @mc
  Scenario: A portable fork whose handoff carries no messages cannot compact
    Given "t2" is a portable fork of "t1" whose handoff carries no messages
    When the user sends "/compact" to "t2"
    Then the run fails with "Cannot compact an empty thread"

  @mc @priority-high
  Scenario: A workspace that is missing or is not a folder fails the turn before the provider starts
    Given the workspace of "t1" is not a worktree and its folder is gone
    When the user sends "Hi" to "t1"
    Then the run fails
    And no provider process is started for it

  @mc
  Scenario: The next queued message starts when a run ends
    Given "t1" has a running turn and a queued message "Next"
    When the provider completes the turn
    Then a run for "Next" starts
    And the remaining queued messages move up one place

  @mc
  Scenario: Interrupting the running turn
    Given "t1" has a running turn
    When the user interrupts the run
    Then the run is interrupted

  @mc
  Scenario: Interrupting a run that already ended leaves the turn running now alone
    Given "t1" has a running turn after a run that ended
    When the user interrupts the run that ended
    Then the command fails with "no running turn"
    And the running turn is still running

  @mc
  Scenario: Interrupting when nothing is running is refused
    When the user interrupts the run of idle thread "t1"
    Then the command fails with "no running turn"

  @mc
  Scenario: Stopping the provider session of an idle thread
    Given "t1" is idle with a provider session
    When the user stops the session of "t1"
    Then the provider session is removed from "t1"
    And the provider process for "t1" stops

  @mc
  Scenario: Stopping the provider session while a turn runs is refused
    Given "t1" has a running turn
    When the user stops the session of "t1"
    Then the command fails with "Interrupt the current turn before stopping the session."

  @mc
  Scenario: Starting again after the session was stopped resumes the provider conversation
    Given the user stopped the session of "t1"
    When the user sends "Hi" to "t1"
    Then a provider session is opened again and resumes the provider thread

  @mc @plugin-codex
  Scenario: Sending feedback about a thread goes to Codex
    Given "t1" has run a Codex turn
    When the user uploads feedback for "t1"
    Then the feedback is sent to Codex

  @mc
  Scenario: Feedback for a thread with no provider session yet is refused
    When the user uploads feedback for a thread with no runs
    Then it fails with "No provider session has run in this thread yet."

  @mc
  Scenario: Feedback for a provider that does not accept it is refused
    Given "t1" has run a Claude turn
    When the user uploads feedback for "t1"
    Then it fails with "Provider 'claudeAgent' does not support feedback uploads."

  @mc @priority-high
  Scenario: An interrupt is recorded as a request and then as its outcome
    Given "t1" has a running turn
    When the user interrupts the run giving the reason "wrong branch"
    Then the run records an item titled "Interrupt requested" saying "wrong branch"
    And once the provider stops, an item titled "Interrupted" saying "Stopped by user"

  # Upstream #24299: every interrupt said "Run interrupted by user", even one an agent asked for.
  @mc
  Scenario Outline: An interrupt's outcome says who stopped the run
    Given "t1" has a running turn
    When <who>
    Then once the provider stops, an item titled "Interrupted" says "<says>"

    Examples:
      | who                                                     | says                                 |
      | the user presses Stop                                   | Stopped by user                      |
      | an agent stops it through HAL-C2's tools                | Stopped by an agent                  |
      | an agent stops it through HAL-C2's tools with "wrong branch" | Stopped by an agent: wrong branch |
      | an agent cancels its delegated task                          | Stopped by an agent                  |
      | the provider ends the run with no stop asked for        | Stopped by the provider              |

  @mc @priority-low
  Scenario: An interrupt without a reason says only that it was requested
    Given "t1" has a running turn
    When the user interrupts the run without a reason
    Then the run records an item titled "Interrupt requested" saying "Interrupt requested"

  @backlog @mc
  Scenario: Interrupting a run that has no provider conversation is refused
    Given "t1" has a run that never reached a provider conversation
    When the user interrupts that run
    Then the command fails saying the run is not interruptible

  # A failure the provider itself reports is not this case: there the subagents carry on in their
  # own threads (providers/codex.feature, "A failed Codex turn does not hold the thread for its
  # subagents"). Here the provider process is gone, so nothing can report the subagent again.
  @mc
  Scenario Outline: A turn that does not complete ends the provider subagents it left open
    Given "t1" has a running turn with a provider subagent still at work
    When the turn ends because <cause>
    Then the subagent, its item on the turn and the work in its own thread end as <status>
    And nothing of the subagent is left streaming

    Examples:
      | cause                        | status      |
      | the user interrupts it       | interrupted |
      | its provider process exits   | failed      |
      | its thread is deleted        | cancelled   |

  @backlog @mc
  Scenario Outline: Only a bare compact command compacts the conversation
    When the user sends <message> to "t1"
    Then <outcome>

    Examples:
      | message                               | outcome                                         |
      | "/compact"                            | the provider is asked to compact, not to answer |
      | " /COMPACT "                          | the provider is asked to compact, not to answer |
      | "/compact" with "shot.png" attached   | the provider receives it as an ordinary message |

  @backlog @mc
  Scenario: Compacting on a provider that cannot compact fails the run
    Given "t1" runs on a provider that offers no context compaction
    When the user sends "/compact" to "t1"
    Then the run fails with "This provider does not support context compaction."
    And "t1" can take its next message

  @backlog @mc
  Scenario: A run the MC cannot prepare fails with a short message
    Given the MC hits an internal error while getting the run of "t1" ready
    When the user sends "Hi" to "t1"
    Then the run fails with "Run preparation failed."
    And the internal error text is not shown on the run

  @backlog @mc @priority-high
  Scenario: Output of another thread on a shared provider process stays off this run
    Given "t1" and thread "t2" share one provider process and both have a running turn
    When the provider reports output for the turn of "t2"
    Then nothing is recorded on the run of "t1"
    And the output is recorded on the run of "t2"

  # Upstream #15442: Stop recovers a run whose provider is gone
  @mc @priority-high
  Scenario: Stop settles a run whose provider disappeared before it finished
    Given a run is still active because its provider vanished before reporting an end
    When the user stops the thread
    Then the run is settled as stopped with its partial output kept
    And its pending requests are closed and its checkpoint is captured
    And a late result from the provider cannot undo the stop or replace a newer attempt

  # Upstream #28520: a run whose provider turn had already completed stayed running through Stop and
  # Force stop, and every later message stayed queued until the server restarted.
  @backlog @mc @shared @priority-high
  Scenario Outline: Stopping a run whose provider turn already finished ends it
    Given "t1" has a run still running whose provider turn already completed
    When the user chooses "<stop>"
    Then the run ends as interrupted
    And the next message to "t1" starts a run

    Examples:
      | stop       |
      | Stop       |
      | Force stop |

  # Upstream #27252: under kernel memory throttling every provider froze for hours; Stop waited on
  # the provider with no time limit and queued every later action of the thread behind it.
  @backlog @mc @shared @priority-high
  Scenario: A Stop the agent does not answer within 15 seconds says so and offers Force stop
    Given "t1" has a running turn whose provider does not answer
    When the user presses Stop
    Then the thread says "Stopping" until the turn really ends
    And after 15 seconds it says "Agent not responding to Stop" and offers "Force stop"
    And the turn is not marked stopped while the agent may still be running
    And later actions on "t1" are not held behind the Stop

  # Upstream #27252
  @backlog @mc @shared @priority-high
  Scenario: Force stop ends the turn and kills the thread's own agent
    Given the user was offered "Force stop" for "t1"
    When the user chooses "Force stop"
    Then the agent of "t1" and its processes are killed, even while the kernel throttles them
    And the turn ends saying "Force stopped by user"
    And the next message to "t1" starts a fresh provider session

  # Upstream #27252: Codex and OpenCode serve every thread of an instance from one process.
  @backlog @mc @shared
  Scenario Outline: Force stop leaves a shared provider process running while other threads work in it
    Given "t1" and <others> share one provider process
    When the user force stops "t1"
    Then the turn of "t1" ends
    And <outcome>

    Examples:
      | others                       | outcome                                                                          |
      | two threads that are working | the process keeps running and the user is told it still serves 2 working threads |
      | only idle threads            | the process is released and the idle threads reopen it on their next turn        |

  # Upstream #27252: killing processes stays a user decision.
  @mc
  # Deleting a project with force=true also ends its threads' processes, as part of
  # deleting them; that is the delete's own decision, not a force stop.
  Scenario: HAL-C2's tools offer agents no force stop
    When an agent looks for a way to force stop a thread through HAL-C2's tools
    Then none is offered

  # Upstream #15571: an interrupted provider start cleans up its session
  @mc @priority-high
  Scenario: Stopping during a slow provider start leaves no session behind
    Given a provider session is still starting
    When the user stops the thread before the start completes
    Then the half-started provider session is cleaned up
