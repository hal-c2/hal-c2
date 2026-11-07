# Sources:
#   https://github.com/pingdotgg/t3code/pull/16909
#   https://github.com/pingdotgg/t3code/pull/19751
#   https://github.com/pingdotgg/t3code/pull/16741
#   https://github.com/pingdotgg/t3code/pull/16718
#   https://github.com/pingdotgg/t3code/pull/16337
#   https://github.com/pingdotgg/t3code/pull/16336
#   https://github.com/pingdotgg/t3code/pull/16335
#   https://github.com/pingdotgg/t3code/pull/15219
#   https://github.com/pingdotgg/t3code/pull/15947
#   https://github.com/pingdotgg/t3code/pull/15907
#   https://github.com/pingdotgg/t3code/pull/16219
#   https://github.com/pingdotgg/t3code/pull/2829
#   apps/server-ex/lib/hal_c2/mcp.ex (POST /mcp, per-thread bearer credentials, JSON-RPC methods)
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (advertised tools, caller access rules, escalation checks)
#   apps/server-ex/lib/hal_c2/claude/thread_runtime.ex (a turn whose MCP server changed resumes in a new process)
#   apps/server-ex/priv/mcp_tools.json, priv/mcp_instructions.md (exported from the Node server)
#   apps/server/src/mcp/McpSessionRegistry.ts (credential idle expiry and revocation)
#   apps/server/src/orchestration-v2/ProviderSessionManager.ts (when a session's credential is made,
#     kept, replaced and revoked)
#   apps/server/src/mcp/toolkits/ (tool definitions and OrchestratorMcpFailure codes)
#   apps/server/src/mcp/AcpMcpStdioBridge.ts, AcpMcpOverAcpBridge.ts (acp-mcp-bridge, acp-mcp-call,
#     MCP over the ACP connection)
#   apps/server/src/mcp/McpHttpServer.ts, McpSessionRegistry.ts, McpProviderSession.ts
#   apps/server/src/orchestration-v2/Adapters/AcpAdapterV2.ts (the server given to ACP sessions)
#   apps/server/src/provider/HalC2OrchestrationInstructions.ts (instructions in ACP prompts)
#   apps/server/src/provider/RuntimeInstructions.ts, apps/server/src/provider/userInputAttachments.ts
#   (runtime info and pull-request linking instructions; first-run and system-prompt delivery)
Feature: The HAL-C2 MCP server agents receive
  Every agent running in a thread gets an MCP server named "hal-c2" so it can
  work with HAL-C2 itself. Each call acts as the thread whose agent made it, and an
  agent can never reach beyond its own project or give a thread more power than
  its own.

  Background:
    Given an MC with a project "demo"
    And thread "caller" in "demo" runs on "codex" in full-access mode and default interaction mode
    And "caller" has a turn running on "codex"

  @mc
  Scenario: A thread's agent gets its own credential for the server
    When a run of "caller" starts on "codex"
    Then the agent is given the "hal-c2" server with a bearer credential for "caller" on "codex"
    And asking again for "caller" on "codex" gives the same credential

  @mc
  Scenario: A Codex agent's server allows a tool call longer than the longest wait
    When a run of "caller" starts on "codex"
    Then the agent's "hal-c2" server allows a tool call to run longer than an hour

  @mc
  Scenario: A Claude agent's tool timeout allows a tool call longer than the longest wait
    Then a Claude agent's tool timeout is longer than an hour

  @mc
  Scenario: A wait is cut short of the limit of a provider that cannot raise it
    Then a wait by an agent on "codex" may last an hour
    And a wait by an agent on "claudeAgent" may last an hour
    And a wait by an agent on an ACP provider may not reach a minute

  @mc @plugin-claude
  Scenario: A renewed credential replaces the old one in a running Claude thread
    Given the agent of a running Claude thread uses the "hal-c2" server
    When the thread's credential is renewed
    Then the agent keeps its tools with the new credential
    And the old credential is refused from then on

  @mc @plugin-claude
  Scenario: Claude's MCP credential never appears in process diagnostics
    Given the agent of a running Claude thread uses the "hal-c2" server
    When a client asks for the MC's process diagnostics
    Then Claude's launch and process diagnostics contain no MCP credential

  @mc
  Scenario: Credentials differ per provider instance of a thread
    When "caller" is given credentials for "codex" and for "claudeAgent"
    Then the two credentials are different

  @mc
  Scenario Outline: A request without a valid credential is refused
    When an MCP request arrives <credential>
    Then it is answered with status 401 and error "invalid_mcp_credential"

    Examples:
      | credential                         |
      | with no authorization              |
      | with an unknown bearer credential  |
      | with a non-bearer authorization    |

  @mc
  Scenario: A project can keep the server from its agents
    Given project "demo" turns agent access to HAL-C2 off
    When a run of "caller" starts
    Then the agent is given no "hal-c2" server

  @mc
  Scenario: Initializing reports the server and the instructions for agents
    When the agent of "caller" initializes the MCP session
    Then the answer names server "hal-c2", offers tools and includes HAL-C2's agent instructions
    And the protocol version is the one the agent asked for

  @mc
  Scenario: The agent can ping the server
    When the agent of "caller" sends a ping
    Then it receives an empty result

  @mc
  Scenario: Notifications get no answer
    When the agent of "caller" sends a notification without an id
    Then the server accepts it with status 202 and no body

  @mc
  Scenario: An unknown method is reported as not found
    When the agent of "caller" calls method "resources/list"
    Then it receives JSON-RPC error -32601 "Method not found: resources/list"

  @mc
  Scenario: An unreadable request is a parse error
    When the agent of "caller" sends a body that is not JSON
    Then it receives status 400 with JSON-RPC error -32700

  @mc
  Scenario: The MC advertises the same tools as the Node server
    When the agent of "caller" lists the tools
    Then every thread, queue, project, worktree, pull request, schedule, delegation, preview and device tool is listed

  @mc
  Scenario: A tool failure is a readable error result, not a protocol error
    When the agent of "caller" reads a thread that does not exist
    Then the tool result is marked as an error
    And it carries code "thread_not_found" with a message

  @mc
  Scenario: The capabilities an agent is told are small enough to read
    Given provider "codex" offers 600 models, each with its own option descriptors
    When the agent of "caller" asks for the orchestrator capabilities
    Then each provider lists at most 25 models, each with an id and a label
    And "codex" reports 600 models in all and that its list is cut short
    And no listed model carries option descriptors
    And the answer is under 20000 characters, where with every option descriptor it is over 100000

  @mc
  Scenario Outline: The capabilities can be narrowed to what the agent is choosing between
    Given provider "codex" offers 600 models, each with its own option descriptors
    When the agent of "caller" asks for the orchestrator capabilities with <arguments>
    Then <result>

    Examples:
      | arguments                                    | result                                                           |
      | providerInstanceId "codex"                   | "codex" is the only provider and lists all 600 models            |
      | model "bulk-model-7"                         | only "bulk-model-7" is listed, with its option descriptors       |
      | query "MODEL 12"                             | the listed models are those whose id or label contains the text  |
      | providerInstanceId "codex" and includeOptions | every listed model carries its option descriptors                |
      | providerInstanceId "nowhere"                 | it fails with code "invalid_request"                             |
      | model 7                                      | each provider lists at most 25 models, each with an id and a label |

  @mc
  Scenario: A tool the MC does not implement is refused by name
    When the agent of "caller" calls a tool "hal_c2_teleport"
    Then it fails with code "capability_denied" and "hal_c2_teleport is not available on this MC."

  @mc
  Scenario: A deleted thread's credential no longer acts
    Given "caller" was deleted
    When its agent calls any tool
    Then it fails with code "thread_not_found" and "The calling thread was not found."

  @mc
  Scenario: Archiving a thread revokes its agent's credential
    Given the agent of "caller" holds a credential
    When "caller" is archived
    Then a call with that credential is refused with "invalid_mcp_credential"

  @mc
  Scenario: A thread that leaves its provider session and comes back keeps its credential
    Given the agent of "caller" holds a credential
    When "caller" leaves its provider session to change workspace and a run of "caller" starts again
    Then the agent is given the same credential

  @mc
  Scenario: Releasing a session that was replaced leaves the new session's credential working
    Given the provider session of "caller" was replaced by a new one that holds the thread's credential
    When the old session is released
    Then the agent of the new session can still call tools

  @mc
  Scenario: A credential made for a session that failed to open is revoked
    Given a credential was made for "caller" and its provider session then failed to open
    When a tool is called with that credential
    Then the call is refused with "invalid_mcp_credential"

  @mc
  Scenario: Browser and device tools are withheld when the access settings cannot be read
    Given the settings that grant agents browser and device access cannot be read
    When a run of "caller" starts
    Then the agent's credential carries neither the browser nor the device capability

  @mc
  Scenario: Threads of other projects are invisible
    Given thread "other" belongs to project "elsewhere"
    When the agent of "caller" reads "other"
    Then it fails with code "thread_not_found"

  @mc
  Scenario Outline: Changing things needs a caller that is itself running
    Given "caller" <state>
    When the agent of "caller" sends a message to another thread of "demo"
    Then it fails with code "parent_not_active"

    Examples:
      | state                                        |
      | has no run starting, running or waiting       |
      | is archived                                  |
      | is running on a different provider instance   |

  # Upstream #19751: a background subagent outlives its parent's turn and calls tools with
  # the parent thread's credential. The thread lists it as background work while it runs.
  @backlog @mc
  Scenario: A caller whose background subagent still runs can still change things
    Given "caller" has no active run
    And "caller" lists a subagent of its own provider instance running in the background
    When that subagent sends a message to another thread of "demo"
    Then the message is sent

  @backlog @mc
  Scenario Outline: Background work that is not the caller's does not keep it running
    Given "caller" has no active run
    And "caller" lists a subagent running in the background that <owner>
    When the agent of "caller" sends a message to another thread of "demo"
    Then it fails with code "parent_not_active"

    Examples:
      | owner                                                       |
      | an earlier provider of the thread started                    |
      | runs on a different provider instance than the caller        |
      | has no known owner                                           |

  @backlog @mc
  Scenario: Stopping the background work ends the caller's standing
    Given "caller" has no active run and a subagent running in the background
    When the user stops the background work of "caller"
    And the agent of "caller" sends a message to another thread of "demo"
    Then it fails with code "parent_not_active"

  @backlog @mc
  Scenario: Delegating still needs a running caller
    Given "caller" has no active run and a subagent running in the background
    When that subagent delegates a task
    Then it fails with code "parent_not_active"

  @mc
  Scenario: Reading does not need a running caller
    Given "caller" has no active run
    When the agent of "caller" lists the threads of "demo"
    Then it receives them

  @mc
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

  @mc
  Scenario: A caller may change a thread with narrower modes
    Given "caller" runs in full-access runtime mode
    And thread "target" in "demo" runs in approval-required runtime mode
    When the agent of "caller" changes "target"
    Then the change is made

  @mc
  Scenario Outline: Environment-wide changes need a full-access, default-mode caller
    Given "caller" runs in <mode>
    When the agent of "caller" <change>
    Then it fails with code "capability_denied"

    Examples:
      | mode                           | change                               |
      | auto runtime mode              | creates a project                    |
      | plan interaction mode          | launches a thread                    |
      | approval-required runtime mode | updates the environment preferences  |

  @mc
  Scenario: An idle credential expires
    Given the agent of "caller" has made no call for longer than the idle limit and has no turn in progress
    When it calls a tool
    Then the call is refused with "invalid_mcp_credential"

  @mc
  Scenario: Stopping a provider session revokes its credentials
    Given the provider session of "caller" stops
    When the old agent calls a tool with its credential
    Then the call is refused with "invalid_mcp_credential"

  @mc
  Scenario: An ACP agent that takes servers over HTTP gets the server with its credential in a header
    Given an ACP agent that advertises HTTP MCP servers
    When a session of "caller" starts on it
    Then the agent is given the "hal-c2" server by address with its credential as an authorization header

  @mc
  Scenario: An ACP agent that takes no HTTP servers gets the server through a local command
    Given an ACP agent that advertises no HTTP MCP servers
    When a session of "caller" starts on it
    Then the agent is given the "hal-c2" server as a local command speaking over standard input and output
    And the credential and address reach that command through its environment, never its command line

  @mc
  Scenario: An ACP agent that can carry MCP over its own connection is offered it there too
    Given an ACP agent that can carry MCP messages over the ACP connection
    When a session of "caller" starts on it
    Then the agent is also offered the "hal-c2" server over the ACP connection under the id "hal-c2"

  @mc
  Scenario: The agent's terminal can find the way to call HAL-C2 tools
    When a session of "caller" starts on an ACP agent
    Then the agent's environment names the MCP address, the credential and the command to run the call
    And the agent's instructions say to call the tools from its terminal when its tools are absent

  @mc
  Scenario: The local command relays an agent's requests to the MC
    Given the local command runs with the MCP address and credential of "caller"
    When the agent writes a request on its input
    Then the MC's answer is written to its output as one line
    And acknowledgements without a body write nothing

  @mc
  Scenario: The local command keeps the MCP session the MC gave it
    Given the MC answered the agent's initialization with a session and a protocol version
    When the agent sends its next request
    Then the request carries that session and protocol version

  @mc
  Scenario: The local command waits for the session to be initialized
    When the agent sends a request before its initialization has been answered
    Then the request is held until the initialization has finished
    And the agent's own responses to the MC are not held

  @mc
  Scenario: A streamed answer reaches the agent event by event
    Given the MC answers a request as a stream of events
    When the local command relays it
    Then each event is written to the agent's output as one line

  @mc
  Scenario Outline: The MC being unwell is reported to the agent that asked
    Given the MC answers with an HTTP error <status>
    When the agent had sent <message>
    Then <result>

    Examples:
      | status | message         | result                                                                                       |
      | 502    | a request       | the agent receives error -32603 "HAL-C2 MCP endpoint responded with HTTP 502." for that request |
      | 401    | a notification  | nothing is written, since a notification expects no answer                                   |

  @mc
  Scenario: A line that is not a message is a parse error
    When the agent writes a line that is not valid JSON to the local command
    Then it receives error -32700 "Parse error"

  @mc
  Scenario Outline: The local command refuses to start without what it needs
    Given the local command is started <without>
    Then it ends with status 2 saying what is missing

    Examples:
      | without                            |
      | with no MCP address                |
      | with no credential                 |

  @mc
  Scenario: A tool can be called from a terminal in one command
    Given the terminal has the MCP address and credential of "caller"
    When "call orchestrator_capabilities with {}" is run
    Then the tool's result is printed as JSON
    And the call used a fresh authenticated MCP session

  @mc
  Scenario Outline: A terminal tool call that cannot be made says why
    When the terminal call is made <how>
    Then it ends with a non-zero status and <message>

    Examples:
      | how                                       | message                                                        |
      | with arguments that are not a JSON object | says the arguments must be a JSON object                       |
      | to an MC that rejects the initialization  | says "HAL-C2 MCP endpoint rejected initialization."            |
      | for a tool that fails                     | says "HAL-C2 MCP tool call failed" with the reason             |

  @mc
  Scenario: Only the HAL-C2 server is offered over the ACP connection
    Given an ACP agent connects to an MCP server over the ACP connection
    When it names a server other than "hal-c2"
    Then the connection is refused with "Unknown ACP MCP server" and the name

  @mc
  Scenario: An ACP session holds at most 16 MCP connections
    Given an ACP agent has 16 MCP connections open over the ACP connection
    When it opens another
    Then it is refused with "Too many MCP-over-ACP connections."

  @mc
  Scenario: A message over 8 MiB is refused over the ACP connection
    When an ACP agent sends an MCP message larger than 8 MiB over the ACP connection
    Then it is refused with "MCP-over-ACP message exceeds 8 MiB."
    And the connection stays usable for smaller messages

  @mc
  Scenario: Closing an MCP connection over ACP ends its MCP session on the MC
    Given an ACP agent has an MCP connection open over the ACP connection
    When it disconnects
    Then the MC's MCP session for it is ended
    And a session the MC no longer has is not an error

  @mc
  Scenario: Ending an ACP session closes all its MCP connections
    Given an ACP agent has several MCP connections open over the ACP connection
    When its session ends
    Then every one of them is closed

  @mc
  Scenario: ACP prompts carry HAL-C2's instructions only when they change
    Given an ACP agent of "caller" has the "hal-c2" server
    When the agent receives its first prompt, then another in the same mode, then one after the mode changed
    Then the instructions are in the first prompt and in the one after the change, but not in the second

  @mc
  Scenario: A slash command stays at the start of an ACP prompt
    When the user sends "/compact" to an ACP agent of "caller"
    Then the prompt is sent without HAL-C2's instructions in front of it

  # Runtime and pull-request instructions of apps/server/src/provider/RuntimeInstructions.ts,
  # given to Cursor, OpenCode, Claude and ACP agents.
  @mc
  Scenario: The agent is told which harness and model it is running as
    Given "caller" runs on "claude" with the model "Opus" and high reasoning effort
    When a run of "caller" starts
    Then the agent's instructions say it is running in HAL-C2 through the Claude Code harness as "Opus" with high reasoning effort
    And they say there is no need to mention this unless asked

  @mc
  Scenario: The model is left out of the runtime instructions when the provider picks it
    Given "caller" runs on a provider whose model is chosen automatically
    When a run of "caller" starts
    Then the agent's instructions name the harness but no model

  @mc
  Scenario: The agent is told it can embed images and videos by absolute path
    When a run of "caller" starts
    Then the agent's instructions say it can embed images and videos in its answer using Markdown with absolute file paths

  @mc
  Scenario: The agent is told to link every pull request it opens
    Given the "hal-c2" server is attached to "caller"
    When a run of "caller" starts
    Then the agent's instructions require linking every pull request it creates or updates to the thread, each layer of a stack included
    And they tell it to list the thread's pull requests before finishing
    And they forbid linking unrelated pull requests
    And they tell it to report a link that failed

  @mc
  Scenario: Agents without a system prompt receive the orchestration instructions on a thread's first run only
    Given "caller" runs on an agent that has no system prompt of its own
    And the "hal-c2" server is attached to "caller"
    When the user sends the first message of "caller" and then a second one
    Then the orchestration instructions are in front of the first message
    And the second message is sent without them

  @mc
  Scenario: Orchestration instructions are not given to an agent that has no HAL-C2 server
    Given "caller" runs on an agent that has no system prompt of its own
    And the "hal-c2" server is not attached to "caller"
    When the user sends the first message of "caller"
    Then the message is sent without the orchestration instructions

  @mc
  Scenario: Agents with a system prompt receive the orchestration instructions in it
    Given "caller" runs on an agent that takes a system prompt
    And the "hal-c2" server is attached to "caller"
    When a run of "caller" starts
    Then the orchestration instructions are in the agent's system prompt
    And the user's messages are sent as written

  @mc
  Scenario: Browser tools withheld from an agent are refused and not promised to it
    Given the user withholds agent browser access from "demo"
    When a run of "caller" starts
    Then the agent's credential carries no browser capability
    And a call to a "preview_" tool fails with code "capability_denied"
    And the instructions the agent receives do not tell it that browser tools exist

  @mc
  Scenario: Changing browser access gives a running thread a new credential
    Given the agent of "caller" holds a credential made while browser access was allowed
    When the user withholds agent browser access from "demo" and a run of "caller" starts
    Then the agent is given a new credential without the browser capability
    And the old credential is refused from then on

  @mc
  Scenario: A credential refused at the door is never cached
    When an MCP request arrives with an unknown bearer credential
    Then the answer asks for a bearer credential
    And it forbids storing the answer

  @backlog @mc
  Scenario: Thread tools take any thread in the environment
    Given threads in two projects
    When an agent reads, updates or messages a thread of the other project
    Then the tool targets it
    And listing covers one project, the one named or else the caller's
    And writing to another thread needs the caller's live run and modes no broader than the target's

  @backlog @mc @shared
  Scenario: An agent asks for a secret through a private card
    Given an agent needs a credential
    When it asks for a secret with a label and a reason
    Then a card in its thread asks the user for the value
    And saving it gives the agent a one-use reference, never the value
    And the transcript never holds the value

  @backlog @mc @priority-low
  Scenario: A delegation to a provider whose probe failed tries it again once
    Given the cached state of a provider says it was not found
    And the user has since fixed it
    When an agent delegates a task or creates threads on that provider
    Then the MC probes the provider once more and goes on if it is healthy
    And healthy providers are not probed again

  @backlog @mc
  Scenario: A tool is limited to the callers it declares
    Given a thread runs in a supervised or plan mode
    When its agent starts a thread in another project
    Then the call is allowed
    And the new thread never gets a higher access or interaction mode than the caller has

  @backlog @mc
  Scenario: An agent outside HAL-C2 signs in to an MC's server
    Given the user pointed Claude Code or another agent at the MC's MCP address
    When the agent asks to connect
    Then it is sent through a sign-in where the user approves access with a pairing code or as an administrator
    And the user chooses how much access it gets, from read only to full access
    And the agent can then use the tools that access allows

  @backlog @mc @priority-low
  Scenario: A hosted agent can sign in with an https callback
    Given a hosted agent such as ChatGPT registers an https callback address
    Then it is accepted and the callback must match exactly
    And a loopback callback matches on any port
    And an http callback off loopback is refused
    And a client that asks for a secret is registered as a public client proved by PKCE

  @backlog @shared @priority-low
  Scenario: Copying an environment's MCP address
    Given the user has an environment saved
    When the user chooses to copy its MCP address
    Then the address is copied with an example command for adding it to an agent

  # Upstream #16909: plain http routes (LAN, Tailscale) get the action too.
  @backlog @shared
  Scenario Outline: The MCP address copied is the route the client reaches the environment by
    Given the user's environment "studio" is reached over <routes>
    When the user chooses to copy its MCP address
    Then the copied address is <address>

    Examples:
      | routes                                                      | address                       |
      | plain http at "http://studio.lan:3773", connected            | on "http://studio.lan:3773"   |
      | "https://studio.ts.net" not connected and "http://10.0.0.5:3773" connected | on "http://10.0.0.5:3773" |
      | "https://studio.ts.net" and "http://10.0.0.5:3773", neither connected | on the first ranked of them, "https://studio.ts.net" |
