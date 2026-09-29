# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   upstream commits 7e0f72466, 7c2be4f574, b3360b5155, 22aeee2709,
#     90dbd558d6, b396b6d5fd, de7ebd93a0, 639d65cdf3, dad3a97a10,
#     117f678baf, f56ec3d96f, 4e05c14cd6, 85c787d997, 987897be15,
#     fc4faae678 (MCP and delegated-work controls)
#   apps/server/src/mcp/
#   (agent search, queue edits, question answers, fork/merge, attachment ownership and
#     credential revocation are covered by mcp-thread-tools.feature,
#     mcp-queue-project-and-pull-request-tools.feature and mcp-server.feature)
#   packages/contracts/src/orchestrationV2.ts
#   apps/server-ex/lib/hal_c2/orchestration/
Feature: Control-plane operations remain durable
  Agents and clients can use the same thread operations through the node's
  control plane. A control-plane request must have the same ownership and
  lifecycle rules as a request from the main client.

  @node @backlog
  Scenario: An agent launches a thread in the requested workspace
    Given an agent has access to project "demo"
    When it launches a thread for branch "feature/demo"
    Then the thread is created in "demo"
    And its worktree is based on "feature/demo"

  @node @backlog
  Scenario: An agent can update thread metadata without changing its history
    Given thread "t1" has completed runs
    When an agent renames "t1" and changes its organization
    Then the metadata changes are stored
    And the completed runs remain unchanged

  @node @backlog
  Scenario: An agent can run a scheduled task immediately
    Given scheduled task "lint" belongs to project "demo"
    When an agent runs "lint" now
    Then one run starts immediately
    And the next scheduled due time is unchanged

  @node @backlog @plugin-claude
  Scenario: Rotating MCP credentials reopens the provider query
    Given a Claude query is using MCP credentials
    When those credentials rotate
    Then Claude reopens its query with the new credentials
    And the old credentials are not used for later tool calls

  @node @backlog
  Scenario: A recursive screenshot payload is not echoed forever
    Given an MCP tool returns screenshot metadata containing a recursive screenshot field
    When the node sends the tool result to the provider
    Then recursive screenshot metadata is omitted
    And the tool result remains readable

  @node @backlog
  Scenario: A control request with an incompatible protocol is rejected
    Given a client connects with an incompatible orchestration protocol
    When it sends a control request
    Then the node rejects the connection request
    And no command is applied

  @node @backlog
  Scenario: A receipt is committed with its event projection
    Given a client sends an idempotent orchestration command
    When the node accepts it
    Then the event, projection and receipt commit together
    And retrying the receipt does not apply the command twice
