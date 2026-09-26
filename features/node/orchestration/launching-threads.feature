# Sources:
#   packages/contracts/src/rpc.ts (orchestration.launchThread)
#   packages/contracts/src/orchestrationV2.ts (thread.create, message.dispatch, prepared-run.release,
#     prepared-run.progress, prepared-run.fail, run.created, run.updated)
#   apps/server-ex/lib/t3/orchestration.ex (launch_thread, release_prepared, fail_prepared)
#   apps/server-ex/lib/t3/worktree_setup.ex
#   apps/server/src/orchestration-v2/ (launch and prepared run handling)
Feature: Launching a thread with its first message
  Launching creates a thread in the project root, an existing worktree, or a new
  worktree, and sends its first message. A new worktree is prepared before the
  agent starts, so the first run waits as preparing until the workspace is ready.

  Background:
    Given a node with a project "demo" rooted at a git repository

  @node
  Scenario: Launching in the project root starts the first turn
    When a client launches a thread in "demo" at the project root with message "Hello"
    Then a new thread exists in "demo"
    And the launch reports the thread was not resumed
    And a run for "Hello" starts

  @node
  Scenario: Launching in the project root on a named branch records the branch
    When a client launches a thread in "demo" at the project root on branch "main"
    Then the new thread records branch "main"

  @node
  Scenario: Launching in an existing worktree records its path and branch
    When a client launches a thread in "demo" in existing worktree "/work/x" on branch "feature/x"
    Then the new thread records worktree "/work/x" and branch "feature/x"

  @node
  Scenario: Launching without a first message only creates the thread
    When a client launches a thread in "demo" with no message
    Then a new thread exists in "demo"
    And the thread has no runs

  @node
  Scenario: Launching a thread id that already exists resumes it
    Given thread "t1" exists in "demo"
    When a client launches thread "t1" with message "Again"
    Then the launch reports the thread was resumed
    And "Again" is sent to "t1" like any other message

  @node
  Scenario: The first message's command id derives from the launch command
    When a client launches a thread with command "c1" and message "Hello"
    Then the first message is dispatched as command "c1:initial-message"

  @node
  Scenario: Launching with title generation titles the thread from its first message
    When a client launches a thread with message "Refactor the parser" asking for a generated title
    Then the thread is later retitled with a generated title

  @node
  Scenario: Title generation is retried with backoff before giving up
    Given the text generation model fails twice and then succeeds
    When a client launches a thread asking for a generated title
    Then the thread is retitled after the third attempt

  @node
  Scenario: A generated placeholder title is ignored
    Given the text generation model answers "New thread"
    When a client launches a thread asking for a generated title
    Then the thread keeps its original title

  @node
  Scenario: A thread without text or attachments is not titled
    When a client launches a thread with an empty message asking for a generated title
    Then no title is generated

  @node
  Scenario: Launching in a new worktree holds the first run until the worktree is ready
    When a client launches a thread in "demo" in a new worktree with message "Hello"
    Then the first run is preparing
    And no turn starts yet

  @node
  Scenario: A prepared worktree releases the waiting run
    Given a launched thread's first run is preparing its worktree
    When the worktree and its setup script are ready
    Then the run starts with the message it was waiting with
    And a baseline checkpoint is captured before the turn

  @node
  Scenario: A worktree that cannot be prepared fails the waiting run
    Given a launched thread's first run is preparing its worktree
    When adding the worktree fails
    Then the run is failed
    And the thread can take its next message

  @node
  Scenario: Cancelling worktree preparation cancels the waiting run
    Given a launched thread's first run is preparing its worktree
    When the user cancels the setup before the agent starts
    Then the run is cancelled
    And the new worktree is removed

  @node
  Scenario: Releasing a run that is not preparing is refused
    Given thread "t1" has a run that already started
    When the node releases that run as prepared
    Then it fails with "the run is not waiting for its workspace"

  @node
  Scenario: Launching in a new worktree of a project not on this node is refused
    When a client launches a thread in a new worktree of a project this node does not have
    Then it fails with "The project is not on this node."

  @node
  Scenario: Attachments of a launch are claimed by the new thread
    Given the user uploaded "shot.png" but has not sent it
    When a client launches a thread with message "Look" attaching "shot.png"
    Then "shot.png" belongs to the new thread
    And the first message carries the attachment

  @node
  Scenario: Clients drive prepared runs with commands
    Given a launched thread's first run is preparing its worktree
    When a client reports progress for the worktree phase and then the setup phase
    And a client releases the prepared run
    Then the run records each phase and then starts

  @node
  Scenario: A client fails a prepared run with a provider failure
    Given a launched thread's first run is preparing its worktree
    When a client fails the prepared run with a failure description
    Then the run is failed with that description

  @node
  Scenario: A run preparing its worktree when the node restarts is interrupted
    Given a launched thread's first run is preparing its worktree
    When the node restarts
    Then the run is interrupted
    And no setup progress is reported for that thread
