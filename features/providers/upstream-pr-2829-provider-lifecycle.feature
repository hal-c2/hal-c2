# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   upstream commits 4fafbbee7, d6c539e79, bfb3501d5, 4408bf5a4,
#     1e844a3d0, 3cb31a1bc, 13aec8a2c, 52db643b9, 4812e1299,
#     6107b6632, 1d1b3bc5a, 541b6b997, cbe13c403, 86e34874f,
#     1d6bc0e73, 7bc65c08d, 430dfd159, d861582f2
#   apps/server/src/orchestration-v2/Adapters/
#   apps/server-ex/lib/hal_c2/{acp,codex,claude}/
Feature: Provider lifecycle and capability boundaries
  Provider plugins may differ internally, but the node must keep startup,
  stopping, permissions, workspaces and session credentials predictable.

  @node @backlog @plugin-cursor
  Scenario: A sandboxed Cursor thread keeps its helper after a full-access turn
    Given a Cursor thread in sandboxed mode has a running helper
    When another Cursor thread runs in full access
    And the sandboxed thread runs again
    Then its helper is still available
    And its sandbox boundary is unchanged

  @node @backlog @plugin-cursor
  Scenario: Cursor retries text generation without sandboxing when required
    Given Cursor text generation fails only because its sandbox blocks generation
    When the node retries the request
    Then the retry removes only the blocking sandbox restriction
    And the thread records the retry

  @node @backlog @plugin-opencode
  Scenario: OpenCode accepts its current server-ready message
    Given the node starts an OpenCode server
    When OpenCode emits its current v2 ready line
    Then the node marks the server ready
    And the first prompt is admitted

  @node @backlog @plugin-opencode
  Scenario: OpenCode stream end fails the active turn
    Given an OpenCode turn is streaming
    When the event stream ends unexpectedly
    Then the turn fails
    And the thread can accept a later message

  @node @backlog @plugin-opencode
  Scenario: OpenCode prompt admission is correlated to its own run
    Given two OpenCode prompts are admitted close together
    When the first prompt reports an idle event
    Then the second run remains active
    And the first event cannot settle the second run

  @node @backlog @plugin-opencode
  Scenario: Stopping OpenCode releases descendants
    Given an OpenCode run has descendant provider processes
    When the user stops the run
    Then the descendants receive stop requests
    And the node reports any descendant that could not stop

  @node @backlog @plugin-cursor
  Scenario: Cursor metadata does not write into the workspace
    Given Cursor needs metadata for a thread
    When the node prepares the metadata
    Then it is stored outside the user's workspace
    And the workspace has no generated metadata files

  @node @backlog @plugin-cursor
  Scenario: Cursor receives project skills and rules
    Given project "demo" has provider skills and rules
    When a Cursor turn starts in "demo"
    Then Cursor receives the project's skills and rules

  @node @backlog @plugin-cursor
  Scenario: Cursor preserves its native runtime chunks
    Given Cursor emits runtime chunks while a turn runs
    When the node stores the turn
    Then the chunks remain available to the provider adapter
    And later chunks do not overwrite earlier chunks

  @node @backlog @plugin-codex
  Scenario: Codex receives configured launch arguments
    Given the Codex provider has configured launch arguments
    When a Codex session starts
    Then the process receives those arguments

  @node @backlog @plugin-claude
  Scenario: Claude resumes after compaction
    Given a Claude session reports a compaction boundary
    When the next turn starts
    Then Claude resumes with the compacted conversation
    And the node preserves the post-compaction token usage

  @node @backlog @plugin-claude
  Scenario: Claude structured questions have one normalized answer
    Given Claude asks a structured question with multiple choices
    When the user answers it
    Then the provider receives one normalized answer
    And the question is marked answered once

  @node @backlog @plugin-claude
  Scenario: Claude can ask a question in plan mode
    Given Claude is in plan mode
    When Claude asks the user a question
    Then the question is shown
    And the plan remains waiting for the answer

  @node @backlog @plugin-claude
  Scenario: Claude session approvals are not reused after release
    Given Claude was granted a session approval
    When the Claude session is released
    And a new session asks for the same action
    Then the new session asks again

  @node @backlog @plugin-grok @plugin-cursor @plugin-opencode @plugin-antigravity @plugin-acp-registry
  Scenario: ACP provider capabilities are opt-in per provider flavor
    Given an ACP provider flavor does not advertise terminals
    When the agent requests a terminal
    Then the request is rejected as unsupported
    And the provider is not given an unadvertised capability

  @node @backlog @plugin-grok @plugin-cursor @plugin-opencode @plugin-antigravity @plugin-acp-registry
  Scenario: ACP child messages and summaries remain in the child
    Given an ACP provider creates a native child session
    When the child sends messages and a final summary
    Then those items appear in the child thread
    And the parent receives only the child result

  @node @backlog @plugin-grok @plugin-cursor @plugin-opencode @plugin-antigravity @plugin-acp-registry
  Scenario: ACP authentication is enforced before activation
    Given an ACP provider requires authentication
    When a thread tries to activate it without credentials
    Then activation fails with an authentication error
    And no provider session is created

  @node @backlog @plugin-grok
  Scenario: Grok does not finish while a monitor is still in the foreground run
    Given Grok reports a monitor update during its turn
    When the monitor reports progress again
    Then the run remains working
    And it finishes only on Grok's completion signal

  @node @backlog @plugin-antigravity
  Scenario: Antigravity stays inside the workspace
    Given an Antigravity thread has a workspace root
    When it requests a path outside that root
    Then the request is rejected

  @node @backlog
  Scenario: Provider launch paths expand the user's home directory
    Given a provider executable is configured as "~/bin/provider"
    When the provider starts
    Then the process uses the expanded absolute path
