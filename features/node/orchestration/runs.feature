# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (message.dispatch, message.updated, run.created,
#     run.updated, run-attempt.created, run-attempt.updated, node.updated, turn-item.updated,
#     provider-session.attached, provider-session.updated, provider-session.detach,
#     provider-session.detached, provider-thread.updated, provider-turn.updated,
#     checkpoint-scope.created, run.interrupt)
#   packages/contracts/src/rpc.ts (orchestration.dispatchCommand, provider.uploadFeedback)
#   apps/server-ex/lib/hal_c2/orchestration.ex (dispatch_message, new_run, start_turn, release_session)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex
#   apps/server/src/orchestration-v2/ (run lifecycle)
#   apps/server/src/provider/Errors.ts (ProviderInstanceNotFoundError),
#     apps/server/src/provider/Services/ProviderInstanceRegistry.ts
#   docs/internals/glossary.md
Feature: Runs and turns
  Sending a message to an idle thread starts a run. The engine records the
  message, the run, its attempt and its root node, starts the provider turn, and
  writes what the provider streams back as turn items until the root completes.

  Background:
    Given a node with a project "demo" rooted at a git repository
    And thread "t1" exists in "demo" with provider "codex"

  @node
  Scenario: A message to an idle thread starts a run
    When the user sends "Add a test" to "t1"
    Then "t1" has a run with ordinal 1 that is starting
    And the run has an attempt and a root turn node
    And the user message "Add a test" is recorded with a turn-start turn item
    And the dispatch answers with the thread's stream sequence

  @node
  Scenario: Run ordinals count up per thread
    Given "t1" has completed one run
    When the user sends another message to "t1"
    Then the new run has ordinal 2

  @node
  Scenario: A message to an unknown thread is refused
    When the user sends "Hi" to thread "missing"
    Then the command fails with "unknown thread missing"

  @node
  Scenario: A message to a thread whose provider instance is unknown is refused
    Given thread "t2" exists in "demo" with provider instance "removed_instance"
    And the node has no provider instance "removed_instance"
    When the user sends "Hi" to "t2"
    Then the provider instance is reported as unavailable
    And no turn starts on any other provider

  @node
  Scenario: The first run of a thread opens a provider session and provider thread
    When the user sends "Hi" to "t1"
    Then "t1" has a provider session for "codex" that is ready
    And "t1" has a provider thread for "codex" recording run ordinal 1
    And "t1" has one root checkpoint scope rooted at its working directory

  @node
  Scenario: A later run reuses the provider thread and moves the checkpoint scope to it
    Given "t1" has completed one run
    When the user sends another message to "t1"
    Then the provider thread records run ordinal 2
    And the root checkpoint scope follows the new run

  @node
  Scenario: A stopped provider session is ready again for the next run
    Given the provider session of "t1" was stopped while idle
    When the user sends "Hi" to "t1"
    Then the provider session of "t1" is ready
    And the provider resumes its earlier conversation

  @node
  Scenario: A run uses the message's model selection over the thread's
    Given "t1" uses model "gpt-a"
    When the user sends "Hi" to "t1" choosing model "gpt-b"
    Then the run records model "gpt-b"

  @node
  Scenario: A run works in the thread's worktree when it has one
    Given "t1" is in worktree "/work/x"
    When the user sends "Hi" to "t1"
    Then the turn runs in "/work/x"

  @node @backlog
  Scenario: A worktree that was removed is recreated before the turn starts
    Given "t1" is in worktree "/work/x" and that folder no longer exists
    When the user sends "Hi" to "t1"
    Then the worktree is recreated from the branch of "t1"
    And only then does the turn start

  @node
  Scenario: A run works in the project root when the thread has no worktree
    When the user sends "Hi" to "t1"
    Then the turn runs in the root of "demo"

  @node
  Scenario: A baseline checkpoint is captured before the first turn
    When the user sends "Hi" to "t1"
    Then a checkpoint for ordinal 0 exists before the turn starts

  @node
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

  @node
  Scenario: Assistant text streams into a message that ends when the turn item finishes
    Given "t1" has a running turn
    When the provider streams assistant text in several chunks
    Then one assistant message grows with each chunk
    And the message stops streaming when the provider finishes it

  @node
  Scenario Outline: Streaming mode decides how often assistant text is written
    Given project "demo" streams responses by "<mode>"
    And "t1" has a running turn
    When the provider streams assistant text
    Then the text is written <cadence>

    Examples:
      | mode      | cadence                                                             |
      | paragraph | a paragraph or closed code fence at a time, at most every 400 ms    |
      | turn      | only at a boundary such as the end of the item                       |

  @node
  Scenario: Paragraph streaming is the default
    Given project "demo" has no response streaming setting
    When a turn streams assistant text
    Then the text is written a paragraph at a time

  @node
  Scenario: Tool output streams without waiting for a paragraph
    Given "t1" has a running turn
    When a command the agent runs prints output
    Then the output is written as it arrives

  @node
  Scenario: A completed turn completes the run and captures a checkpoint
    Given "t1" has a running turn
    When the provider completes the turn
    Then the run is completed
    And a ready checkpoint for the run exists with the files it changed
    And the run has a checkpoint turn item

  @node
  Scenario: Items still running when the turn ends are closed
    Given "t1" has a running turn with a web search still running
    When the provider completes the turn
    Then no turn item of the run is still running

  @node
  Scenario: A failed turn records the error on the provider session
    Given "t1" has a running turn
    When the provider fails the turn with "rate limited"
    Then the run is failed
    And the provider session's last error is "rate limited"

  @node
  Scenario: A provider that dies while starting the turn fails the run
    Given the provider process exits while "t1" starts a turn
    Then the run is failed with "The provider stopped while starting the turn."
    And "t1" can take its next message

  @node @backlog
  Scenario: Opening the provider session is retried before the run fails
    Given opening the provider session fails the first time
    When the user sends "Hi" to "t1"
    Then the node opens the session again
    And the run fails only once the retries are used up

  @node @shared @backlog
  Scenario: A failed turn keeps the output it had already produced
    Given the provider streamed part of its answer to "t1" and then failed
    When the failure is recorded
    Then the partial answer stays in the failed run
    And the run is marked failed

  @node @shared @backlog
  Scenario: A provider retry is recorded as a retry
    Given the provider retries a failed request during a turn of "t1"
    When the retry is recorded
    Then the turn's work log shows a provider retry
    And no second user turn is created

  @node
  Scenario: The next queued message starts when a run ends
    Given "t1" has a running turn and a queued message "Next"
    When the provider completes the turn
    Then a run for "Next" starts
    And the remaining queued messages move up one place

  @node
  Scenario: Interrupting the running turn
    Given "t1" has a running turn
    When the user interrupts the run
    Then the run is interrupted

  @node
  Scenario: Interrupting when nothing is running is refused
    When the user interrupts the run of idle thread "t1"
    Then the command fails with "no running turn"

  @node
  Scenario: Stopping the provider session of an idle thread
    Given "t1" is idle with a provider session
    When the user stops the session of "t1"
    Then the provider session is removed from "t1"
    And the provider process for "t1" stops

  @node
  Scenario: Stopping the provider session while a turn runs is refused
    Given "t1" has a running turn
    When the user stops the session of "t1"
    Then the command fails with "Interrupt the current turn before stopping the session."

  @node
  Scenario: Starting again after the session was stopped resumes the provider conversation
    Given the user stopped the session of "t1"
    When the user sends "Hi" to "t1"
    Then a provider session is opened again and resumes the provider thread

  @node @plugin-codex
  Scenario: Sending feedback about a thread goes to Codex
    Given "t1" has run a Codex turn
    When the user uploads feedback for "t1"
    Then the feedback is sent to Codex

  @node
  Scenario: Feedback for a thread with no provider session yet is refused
    When the user uploads feedback for a thread with no runs
    Then it fails with "No provider session has run in this thread yet."

  @node
  Scenario: Feedback for a provider that does not accept it is refused
    Given "t1" has run a Claude turn
    When the user uploads feedback for "t1"
    Then it fails with "Provider 'claudeAgent' does not support feedback uploads."
