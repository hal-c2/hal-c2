# Sources:
#   apps/server-ex/lib/t3/mcp.ex (POST /mcp, per-thread bearer credentials, JSON-RPC methods)
#   apps/server-ex/lib/t3/mcp/tools.ex (advertised tools, caller access rules, escalation checks)
#   apps/server-ex/priv/mcp_tools.json, priv/mcp_instructions.md (exported from the Node server)
#   apps/server/src/mcp/McpSessionRegistry.ts (credential idle expiry and revocation)
#   apps/server/src/mcp/toolkits/ (tool definitions and OrchestratorMcpFailure codes)
Feature: The T3 Code MCP server agents receive
  Every agent running in a thread gets an MCP server named "t3-code" so it can
  work with T3 itself. Each call acts as the thread whose agent made it, and an
  agent can never reach beyond its own project or give a thread more power than
  its own.

  Background:
    Given a node with a project "demo"
    And thread "caller" in "demo" runs on "codex" in full-access mode and default interaction mode
    And "caller" has a turn running on "codex"

  @node
  Scenario: A thread's agent gets its own credential for the server
    When a run of "caller" starts on "codex"
    Then the agent is given the "t3-code" server with a bearer credential for "caller" on "codex"
    And asking again for "caller" on "codex" gives the same credential

  @node
  Scenario: Credentials differ per provider instance of a thread
    When "caller" is given credentials for "codex" and for "claudeAgent"
    Then the two credentials are different

  @node
  Scenario Outline: A request without a valid credential is refused
    When an MCP request arrives <credential>
    Then it is answered with status 401 and error "invalid_mcp_credential"

    Examples:
      | credential                         |
      | with no authorization              |
      | with an unknown bearer credential  |
      | with a non-bearer authorization    |

  @node
  Scenario: A project can keep the server from its agents
    Given project "demo" turns agent access to T3 off
    When a run of "caller" starts
    Then the agent is given no "t3-code" server

  @node
  Scenario: Initializing reports the server and the instructions for agents
    When the agent of "caller" initializes the MCP session
    Then the answer names server "t3-code", offers tools and includes T3's agent instructions
    And the protocol version is the one the agent asked for

  @node
  Scenario: The agent can ping the server
    When the agent of "caller" sends a ping
    Then it receives an empty result

  @node
  Scenario: Notifications get no answer
    When the agent of "caller" sends a notification without an id
    Then the server accepts it with status 202 and no body

  @node
  Scenario: An unknown method is reported as not found
    When the agent of "caller" calls method "resources/list"
    Then it receives JSON-RPC error -32601 "Method not found: resources/list"

  @node
  Scenario: An unreadable request is a parse error
    When the agent of "caller" sends a body that is not JSON
    Then it receives status 400 with JSON-RPC error -32700

  @node
  Scenario: The node advertises the same tools as the Node server
    When the agent of "caller" lists the tools
    Then every thread, queue, project, worktree, pull request, schedule, delegation, preview and device tool is listed

  @node
  Scenario: A tool failure is a readable error result, not a protocol error
    When the agent of "caller" reads a thread that does not exist
    Then the tool result is marked as an error
    And it carries code "thread_not_found" with a message

  @node
  Scenario: A tool the node does not implement is refused by name
    When the agent of "caller" calls a tool "t3_teleport"
    Then it fails with code "capability_denied" and "t3_teleport is not available on this node."

  @node
  Scenario: A deleted thread's credential no longer acts
    Given "caller" was deleted
    When its agent calls any tool
    Then it fails with code "thread_not_found" and "The calling thread was not found."

  @node
  Scenario: Threads of other projects are invisible
    Given thread "other" belongs to project "elsewhere"
    When the agent of "caller" reads "other"
    Then it fails with code "thread_not_found"

  @node
  Scenario Outline: Changing things needs a caller that is itself running
    Given "caller" <state>
    When the agent of "caller" sends a message to another thread of "demo"
    Then it fails with code "parent_not_active"

    Examples:
      | state                                        |
      | has no run starting, running or waiting       |
      | is archived                                  |
      | is running on a different provider instance   |

  @node
  Scenario: Reading does not need a running caller
    Given "caller" has no active run
    When the agent of "caller" lists the threads of "demo"
    Then it receives them

  @node
  Scenario Outline: A caller never gives a thread broader modes than its own
    Given "caller" runs in <caller mode>
    And thread "target" in "demo" runs in <target mode>
    When the agent of "caller" changes "target"
    Then it fails with code "<code>"

    Examples:
      | caller mode                          | target mode                      | code                               |
      | approval-required runtime mode       | auto-accept-edits runtime mode   | runtime_mode_escalation_denied     |
      | auto-accept-edits runtime mode       | auto runtime mode                | runtime_mode_escalation_denied     |
      | auto runtime mode                    | full-access runtime mode         | runtime_mode_escalation_denied     |
      | plan interaction mode                | default interaction mode         | interaction_mode_escalation_denied |

  @node
  Scenario: A caller may change a thread with narrower modes
    Given "caller" runs in full-access runtime mode
    And thread "target" in "demo" runs in approval-required runtime mode
    When the agent of "caller" changes "target"
    Then the change is made

  @node
  Scenario Outline: Environment-wide changes need a full-access, default-mode caller
    Given "caller" runs in <mode>
    When the agent of "caller" <change>
    Then it fails with code "capability_denied"

    Examples:
      | mode                           | change                               |
      | auto runtime mode              | creates a project                    |
      | plan interaction mode          | launches a thread                    |
      | approval-required runtime mode | updates the environment preferences  |

  @node
  Scenario: An idle credential expires
    Given the agent of "caller" has made no call for longer than the idle limit and has no turn in progress
    When it calls a tool
    Then the call is refused with "invalid_mcp_credential"

  @node
  Scenario: Stopping a provider session revokes its credentials
    Given the provider session of "caller" stops
    When the old agent calls a tool with its credential
    Then the call is refused with "invalid_mcp_credential"
