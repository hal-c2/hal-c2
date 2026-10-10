# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-opencode.md
#   docs/internals/providers.md (OpenCode server per thread, full-access replies once)
#   apps/server-ex/lib/hal_c2/acp.ex (opencode acp, models split into subProvider)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex, apps/server-ex/lib/hal_c2/acp/opencode.ex (rewind, fork)
#   apps/server/src/provider/Layers/OpenCodeProvider.ts, apps/server/src/provider/Drivers/OpenCodeDriver.ts
#   apps/server/src/provider/opencodeRuntime.ts, apps/server/src/provider/OpenCodeServerOwner.ts
#   apps/server/src/orchestration-v2/Adapters/OpenCodeAdapterV2.ts
#   apps/server-ex/priv/model-manifest.json (compatibility: opencode ranges)
#   apps/server/src/provider/providerCompatibility.ts
#   apps/server/src/provider/Layers/openCodeUsageLimits.ts, apps/server/src/textGeneration/OpenCodeTextGeneration.ts

@plugin-opencode @mc
Feature: OpenCode
  OpenCode reaches the models of every upstream provider it is connected to. The MC
  runs OpenCode locally, or connects to an OpenCode server the user already runs.

  Background:
    Given a connected environment with the project "shop"

  Scenario: OpenCode does nothing until the user enables it
    Given OpenCode is installed but not enabled
    When the MC starts
    Then no OpenCode process is started

  Scenario: OpenCode lists the models of its connected providers
    Given OpenCode is connected to OpenAI and Anthropic
    When the user enables OpenCode
    Then the model picker offers the OpenAI and Anthropic models through OpenCode
    And each model is grouped under its upstream provider

  Scenario: OpenCode is only offered when the opencode command is installed
    Given the opencode command is not installed on the MC
    When the user opens the list of agents to enable
    Then OpenCode is not offered

  Scenario: OpenCode permission requests become approvals
    Given the thread runs OpenCode with approval required
    When OpenCode asks to edit a file
    Then the user is asked to approve it

  Scenario: OpenCode in full access is never asked about anything
    Given the thread runs OpenCode with full access
    When OpenCode asks to run a command
    Then the request is granted without asking the user

  Scenario: OpenCode writes thread titles and commit messages
    Given OpenCode is picked for text generation
    When a new thread needs a title
    Then OpenCode writes it with every tool refused

  Scenario: Refreshing providers picks up a changed OpenCode login
    Given the user connected a new upstream provider in OpenCode
    When the user refreshes provider status
    Then the new provider's models are offered

  Scenario: OpenCode older than the supported version is refused
    Given the installed OpenCode is older than 1.14.19
    When the user enables OpenCode
    Then OpenCode is shown as too old with the version to upgrade to

  @backlog
  Scenario: OpenCode can use an external server
    Given the user runs an OpenCode server elsewhere
    When the user sets its URL and password on the OpenCode instance
    Then OpenCode threads run on that server

  Scenario: A wrong password for an external OpenCode server is explained
    Given the OpenCode instance points at a server with the wrong password
    When the user refreshes provider status
    Then OpenCode says the server rejected authentication and to check the URL and password

  Scenario: An unreachable external OpenCode server is explained
    Given the OpenCode instance points at a server that is not running
    When the user refreshes provider status
    Then OpenCode says it could not reach the server at that URL

  Scenario: Clearing the server URL goes back to a local OpenCode
    Given the OpenCode instance uses an external server
    When the user clears the server URL
    Then OpenCode threads run on a local OpenCode again

  Scenario: OpenCode with no connected providers is a warning
    Given OpenCode has no upstream providers connected
    When the user refreshes provider status
    Then OpenCode is shown with a warning that no providers are connected

  # Health states of OpenCodeProvider.ts (probeFailureMessage, version probe).
  @backlog
  Scenario Outline: A local OpenCode that cannot run explains why
    Given the opencode command fails with <failure>
    When the user refreshes provider status
    Then OpenCode is shown with the message "<message>"

    Examples:
      | failure                     | message                                                                                                                      |
      | an invalid code signature   | macOS killed the OpenCode process due to an invalid code signature. The binary may be corrupted — try reinstalling OpenCode. |
      | a macOS quarantine block    | macOS is blocking the OpenCode binary (quarantine). Run `xattr -d com.apple.quarantine $(which opencode)` to fix this.       |
      | the command not being found | OpenCode CLI (`opencode`) is not installed or not on PATH.                                                                   |

  @backlog
  Scenario: An OpenCode whose version cannot be read is refused
    Given the opencode command prints no version
    When the user refreshes provider status
    Then OpenCode says it could not determine the version and that 1.14.19 or newer is required

  @backlog
  Scenario: An OpenCode version check that does not finish is reported
    Given the opencode version check does not finish in time
    When the user refreshes provider status
    Then OpenCode says its CLI version probe timed out

  @backlog
  Scenario: A disabled OpenCode with a server URL says the URL is kept
    Given OpenCode is turned off and its instance has a server URL
    When the user opens the provider list
    Then OpenCode is shown with the message "OpenCode is disabled in HAL-C2 settings. A server URL is configured."

  @backlog
  Scenario: An OpenCode that has not been checked yet says so
    Given the MC has just started and has not checked OpenCode yet
    When the user opens the provider list
    Then OpenCode is shown with a warning that its status has not been checked in this session yet

  Scenario Outline: OpenCode approvals follow the access mode
    Given the thread runs OpenCode in <mode>
    When OpenCode wants to <action>
    Then it is <outcome>

    Examples:
      | mode              | action                  | outcome                   |
      | approval required | read a source file      | allowed without asking    |
      | approval required | read the .env file      | asked for approval        |
      | approval required | read .env.example       | allowed without asking    |
      | approval required | edit a file             | asked for approval        |
      | auto-accept edits | edit a file             | allowed without asking    |
      | auto-accept edits | run a command           | asked for approval        |
      | full access       | work outside the project| allowed without asking    |

  Scenario Outline: OpenCode approval decisions
    Given OpenCode asked to run a command
    When the user answers <decision>
    Then OpenCode <result>

    Examples:
      | decision              | result                                          |
      | allow once            | runs it this time only                          |
      | allow for the session | runs matching commands without asking again     |
      | decline               | does not run it                                 |

  Scenario: OpenCode reasoning variants and agents are offered as options
    When the user opens the options for an OpenCode model
    Then the model's reasoning variants are offered
    And OpenCode's primary agents are offered with "build" as the default

  Scenario: OpenCode plan mode uses OpenCode's plan agent
    When the user switches an OpenCode thread to plan mode
    Then the turn runs with OpenCode's plan agent

  Scenario: An OpenCode turn can be steered while it runs
    Given an OpenCode turn is running
    When the user sends a follow-up message
    Then OpenCode receives the message during the running turn

  Scenario: A running OpenCode command shows what it runs and its output so far
    Given an OpenCode turn is running
    Then the running command reads "ls" with the output "a.txt"

  Scenario: Reverting an OpenCode turn rewinds OpenCode's session
    Given an OpenCode thread with three turns
    When the user reverts to the end of the first turn
    Then OpenCode's session is rewound to that point

  Scenario: Forking an OpenCode thread forks OpenCode's session
    Given an OpenCode thread with three turns
    When the user forks from the second turn
    Then the new thread continues from a fork of OpenCode's session

  Scenario: OpenCode Go limits are shown for a local OpenCode
    Given OpenCode is signed in to OpenCode Go and runs locally
    When the user opens the limits view
    Then OpenCode Go shows its session, weekly and monthly windows

  Scenario: OpenCode Go limits are unsupported on an external server
    Given the OpenCode instance uses an external server
    When the user opens the limits view
    Then OpenCode's limits are shown as unsupported

  Scenario: An existing thread keeps its OpenCode model when it leaves the catalog
    Given an OpenCode thread uses a model that OpenCode no longer lists
    When the user opens the thread
    Then the thread still shows its model
    And if OpenCode rejects the model the user can pick another and retry

  Scenario: An OpenCode older than the supported range is flagged as known broken
    Given OpenCode 1.14.10 is installed
    When the MC checks its providers
    Then OpenCode is reported as a known broken version for this HAL-C2 release
    And the user is told to use OpenCode 1.14.19 or newer

  Scenario: OpenCode in the supported range carries no compatibility warning
    Given OpenCode 1.14.19 is installed
    When the MC checks its providers
    Then OpenCode carries no compatibility warning

  # OpenCode has no background tasks; its subagents finish inside the turn.
  Scenario: A command OpenCode leaves running ends with its turn
    When OpenCode ends a turn with a command still running
    Then the command it left running ends with the turn

  @backlog
  Scenario: A current OpenCode server is accepted as ready
    Given the MC starts an OpenCode server of the supported version
    When OpenCode reports that the server is ready
    Then the first prompt is sent to it

  Scenario: An OpenCode event stream that ends fails the turn
    Given an OpenCode turn is streaming
    When the event stream ends unexpectedly
    Then the turn fails saying OpenCode exited unexpectedly
    And the thread takes the next message

  @backlog
  Scenario: An idle report for an earlier prompt does not end a later run
    Given two OpenCode prompts were sent close together
    When OpenCode reports the first prompt idle
    Then the second run is still working

  @backlog
  Scenario: Stopping an OpenCode run stops its descendant processes
    Given an OpenCode run has descendant processes
    When the user stops the run
    Then the descendant processes are asked to stop
    And the MC reports any that could not be stopped

  Scenario: An OpenCode server whose owner crashed is stopped
    Given an OpenCode server was started for a thread
    When the provider process that owned it crashes
    Then the OpenCode server is stopped
    And no OpenCode process stays owned by the thread

  # OpenCodeServerOwner.ts: one lazy local server per instance, shared by status checks,
  # model listing and text generation, stopped 30 seconds after its last user.
  @backlog
  Scenario: Status checks and title writing share one local OpenCode server
    Given OpenCode runs locally
    When the MC refreshes OpenCode's status and a thread title is written at the same time
    Then both use the same OpenCode server process

  @backlog
  Scenario: An OpenCode server nobody uses is stopped after 30 seconds
    Given the MC started a local OpenCode server for a status check
    When 30 seconds pass without anything using it
    Then the OpenCode server is stopped

  @backlog
  Scenario: Using the OpenCode server again keeps it from being stopped
    Given a local OpenCode server is waiting to be stopped as idle
    When a thread title needs it before the 30 seconds pass
    Then the server is kept and used

  @backlog
  Scenario: A local OpenCode server that exited is started again on next use
    Given the local OpenCode server exited on its own
    When the MC refreshes OpenCode's status
    Then a new OpenCode server is started for it

  # OpenCodeAdapterV2.ts: OpenCode has no sandbox, so its permission rules are the only guard.
  @backlog
  Scenario Outline: OpenCode tools that never need approval
    Given the thread runs OpenCode in approval required
    When OpenCode wants to <action>
    Then it is allowed without asking

    Examples:
      | action                       |
      | ask the user a question      |
      | search file names            |
      | search file contents         |
      | use the language server      |
      | update its to-do list        |
      | start a subagent             |
      | load a skill                 |

  @backlog
  Scenario Outline: OpenCode running where nobody can approve
    Given an OpenCode run that no user can answer and that <network> use the network
    When OpenCode wants to <action>
    Then it is <outcome>

    Examples:
      | network | action                      | outcome |
      | may     | read the .env file          | denied  |
      | may     | read .env.example           | allowed |
      | may     | run a command               | denied  |
      | may     | fetch a web page            | allowed |
      | may not | fetch a web page            | denied  |
      | may not | search the web              | denied  |

  @backlog
  Scenario: OpenCode running where nobody can approve may use the extra folders it was given
    Given an OpenCode run that no user can answer may write to the project and to one folder outside it
    When OpenCode works in that folder
    Then it is allowed
    And work in any other folder outside the project is denied

  @backlog
  Scenario: An OpenCode subagent works under the thread's access mode
    Given the thread runs OpenCode in approval required
    When an OpenCode subagent wants to edit a file
    Then the user is asked for approval in the parent thread
    And the subagent keeps the limits its own agent adds

  @backlog
  Scenario: A request from a subagent OpenCode has not announced yet is not lost
    Given an OpenCode subagent asks for approval before OpenCode says which run it belongs to
    When OpenCode names the subagent's parent shortly after
    Then the approval reaches the thread that started the subagent

  @backlog
  Scenario: The question OpenCode asks is not also shown as a tool call
    When OpenCode asks the user a question
    Then the thread shows the question to answer
    And no separate tool entry for it

  @backlog
  Scenario Outline: Answering an OpenCode request is refused when it cannot be applied
    When a client <answers>
    Then the answer is refused with "<message>"

    Examples:
      | answers                                         | message                                          |
      | answers the request "r9" that is not open       | No pending OpenCode request r9                   |
      | answers the question "q1" without any answers   | OpenCode question request q1 requires answers    |
      | answers the approval "a1" without a decision    | OpenCode approval request a1 requires a decision |

  @backlog
  Scenario: An answer OpenCode does not take within 10 seconds is given up
    Given OpenCode asked for approval
    When the user's answer is not accepted by OpenCode within 10 seconds
    Then sending the answer is abandoned
    And the user is told the answer did not go through

  @backlog
  Scenario: A request answered once is not raised again
    Given the user answered an OpenCode approval
    When OpenCode repeats the same request after its event stream reconnects
    Then the thread does not ask again

  @backlog
  Scenario: An OpenCode slash command runs as OpenCode's own command
    Given OpenCode offers the command "/review"
    When the user sends "/review the last change" to an OpenCode thread
    Then OpenCode runs its "review" command with "the last change"

  @backlog
  Scenario Outline: A slash message OpenCode cannot run as a command is sent as a message
    Given <situation>
    When the user sends "/review the last change" to an OpenCode thread
    Then OpenCode receives it as an ordinary message

    Examples:
      | situation                                                  |
      | OpenCode offers no command named "/review"                 |
      | OpenCode does not list its commands within 10 seconds      |
      | listing OpenCode's commands fails                          |

  @backlog
  Scenario: An OpenCode command that never starts fails the turn
    Given OpenCode offers the command "/review"
    When the user sends "/review" and OpenCode does not start it within 10 seconds
    Then the turn fails saying "OpenCode command admission did not complete within 10 seconds."

  @backlog
  Scenario: Sending /compact summarizes the OpenCode session
    When the user sends "/compact" by itself to an OpenCode thread
    Then OpenCode summarizes its session
    And the work log shows "Context compacted" once

  @backlog
  Scenario: An OpenCode summary that fails fails the turn
    When the user sends "/compact" by itself and OpenCode cannot summarize the session
    Then the turn fails with OpenCode's reason

  @backlog
  Scenario: OpenCode compacting on its own is shown once per turn
    When OpenCode compacts its session by itself during a turn
    Then the work log shows "Context compacted" once for that turn

  @backlog
  Scenario Outline: OpenCode's token usage says how complete it is
    When an OpenCode turn finishes and <situation>
    Then the turn's token usage is reported as <completeness>

    Examples:
      | situation                                             | completeness |
      | every step reported its tokens                        | complete     |
      | the event stream reconnected during the turn          | partial      |
      | OpenCode reported no tokens                           | unavailable  |

  @backlog
  Scenario: A step's tokens are counted once
    When OpenCode reports the tokens of one step several times
    Then the turn's token usage counts that step once

  @backlog
  Scenario Outline: An OpenCode turn that cannot start says why
    When <attempt>
    Then it is refused with "<message>"

    Examples:
      | attempt                                                              | message                                                                                       |
      | a turn is sent with no text and no usable attachment                 | OpenCode turns require text or at least one valid attachment                                  |
      | a turn asks for the model "sonnet"                                   | OpenCode model 'sonnet' must use provider/model format                                        |
      | a steer is sent with no text and no attachment                       | OpenCode steering requires text or an attachment                                              |
      | a turn is sent after the event stream ended                          | OpenCode event stream has ended; reconnect the provider session before starting another turn. |

  @backlog
  Scenario: An OpenCode server that exits says its exit code
    Given an OpenCode turn is running on a local server
    When the OpenCode server exits with code 1
    Then the turn fails saying "OpenCode server exited unexpectedly (1)."

  @backlog
  Scenario: An OpenCode failure that names no session fails every running turn
    Given two OpenCode turns are running on one server
    When OpenCode reports an error without saying which session it belongs to
    Then both turns fail with that error

  @backlog
  Scenario: An OpenCode failure without details gets a plain message
    When OpenCode reports that a session failed without saying why
    Then the turn fails saying "OpenCode session failed without an error payload."

  @backlog
  Scenario: A stopped OpenCode turn shows as stopped, not failed
    Given an OpenCode turn is running
    When the user stops the turn and OpenCode reports it aborted
    Then the turn is shown as interrupted

  @backlog
  Scenario Outline: Stopping an OpenCode turn that OpenCode does not stop
    Given an OpenCode turn is running
    When the user stops the turn and <situation>
    Then <outcome>

    Examples:
      | situation                                             | outcome                                                    |
      | OpenCode says the turn had already finished           | the stop succeeds                                          |
      | OpenCode does not answer the stop within 10 seconds   | the stop fails and the turn is not shown as interrupted    |
      | OpenCode refuses the stop while the turn still runs   | the stop fails and the turn is not shown as interrupted    |

  @backlog
  Scenario: Stopping OpenCode's subagents is bounded
    Given an OpenCode run started more than eight subagents
    When the user stops the run
    Then the subagents are stopped eight at a time
    And the stop gives up after 15 seconds and reports the first one that could not be stopped

  @backlog
  Scenario Outline: OpenCode refuses a revert or fork it cannot carry out
    Given <situation>
    When the user <action>
    Then it is refused with a message that <says>

    Examples:
      | situation                                        | action                  | says                                                      |
      | an OpenCode turn is running                      | reverts an earlier turn | the thread cannot be rolled back while a turn is active   |
      | OpenCode no longer has the message to return to  | reverts to that turn    | the OpenCode rewind boundary is no longer available       |
      | OpenCode's rewound session kept the wrong turns  | reverts to that turn    | OpenCode did not preserve the requested rewind boundary   |
      | an OpenCode turn is running                      | forks the thread        | the thread cannot be forked while a turn is active        |
      | the turn to fork from is unknown to OpenCode     | forks from that turn    | the fork boundary turn was not found                      |

  @backlog
  Scenario: A reverted OpenCode thread stays reverted after a restart
    Given an OpenCode thread that was reverted to its first turn
    When the MC restarts and reads the thread back from OpenCode
    Then the turns after the first are not shown again

  @backlog
  Scenario: OpenCode's session carries the thread's name
    When a thread "t1" starts on OpenCode
    Then its OpenCode session is titled "HAL-C2 t1"

  @backlog
  Scenario Outline: The HAL-C2 tools are offered only to a local OpenCode
    Given OpenCode runs <where>
    When a thread starts on OpenCode
    Then the HAL-C2 tools are <offered>

    Examples:
      | where                         | offered                                   |
      | on the MC's own local server  | added to OpenCode under the name "hal-c2" |
      | on an external server         | not added                                 |

  @backlog
  Scenario: Closing a thread on an external OpenCode server stops its sessions there
    Given a thread runs on an external OpenCode server
    When the thread's OpenCode session is closed
    Then its sessions and their subagents on that server are stopped
    And the server itself keeps running
    And a session that does not stop within a second does not hold up closing

  @backlog
  Scenario Outline: Updating OpenCode uses the installer that owns it
    Given the opencode command on the MC <installed>
    When the user updates OpenCode from HAL-C2
    Then <update>

    Examples:
      | installed                                         | update                                    |
      | is OpenCode's own install under the user's home   | OpenCode's own upgrade command is run     |
      | was installed with npm                            | the opencode-ai package is updated by npm |

  @backlog
  Scenario: OpenCode's skills and commands are read for the project being worked in
    Given the project has the OpenCode skill "deploy" and the command "/review"
    When the user opens the skill and command lists in an OpenCode thread
    Then "deploy" and "/review" are offered

  @backlog
  Scenario: OpenCode commands that do not load in 10 seconds are left out
    Given OpenCode does not answer when asked for its commands
    When 10 seconds pass
    Then the project's OpenCode skills are still offered
    And no OpenCode commands are offered

  @backlog
  Scenario: OpenCode skills and commands that cannot be read in 20 seconds are reported
    Given the OpenCode server for the project does not answer
    When 20 seconds pass
    Then reading fails naming the project folder
    And the failure is not remembered as an empty list

  # OpenCodeAdapterV2.ts: how OpenCode's own tools, permissions and to-dos read in the thread.
  @backlog
  Scenario Outline: OpenCode's tool calls are shown by kind
    When OpenCode <does>
    Then the thread shows <shown>

    Examples:
      | does                                                     | shown                                    |
      | runs a shell command                                     | a command with its output and exit code  |
      | edits, writes or patches a file                          | a file change with the file and its diff |
      | fetches a web page or searches the web                   | a web search with what it looked for     |
      | reads a file, searches files or asks the language server | a file search with what it looked for    |
      | uses any other tool                                      | a tool call with its input and output    |

  @backlog
  Scenario Outline: OpenCode's approval kind follows the permission it asks for
    Given the thread runs OpenCode in approval required
    When OpenCode asks for permission to <action>
    Then the user is asked to approve <kind>

    Examples:
      | action                          | kind          |
      | edit, write or patch a file     | a file change |
      | read or search files            | a file read   |
      | work outside the project folder | a file read   |
      | do anything else                | a command     |

  @backlog
  Scenario: An OpenCode approval says which permission and patterns it covers
    Given the thread runs OpenCode in approval required
    When OpenCode asks for the "bash" permission for "npm test" and "npm run build"
    Then the approval is titled "bash"
    And it lists "npm test" and "npm run build" on separate lines

  @backlog
  Scenario: An OpenCode approval without patterns names only the permission
    Given the thread runs OpenCode in approval required
    When OpenCode asks for the "bash" permission without saying what for
    Then the approval's text is "bash"

  @backlog
  Scenario Outline: An OpenCode question with blanks is still readable
    When OpenCode asks a question whose <part> is blank
    Then <shown>

    Examples:
      | part               | shown                                                |
      | heading            | the question is headed by its position, "Question 1" |
      | text               | the heading is shown as the question                 |
      | option label       | the option reads "Option"                            |
      | option description | the option's label is shown as its description       |

  @backlog
  Scenario: OpenCode's to-do list is shown and finishes with its last item
    When OpenCode updates its to-do list with one item in progress and one done
    Then the thread shows a "Todo list" with one step running and one done
    And the list is finished only once every item is done

  @backlog
  Scenario: An OpenCode to-do without text is numbered
    When OpenCode's second to-do has no text
    Then it reads "Todo 2"

  @backlog
  Scenario: Text OpenCode marks as not for the user is never shown
    When OpenCode adds text to its conversation that it marks as generated for itself or to be ignored
    Then the thread does not show that text
    And it is still left out when the conversation is read back from OpenCode

  @backlog
  Scenario: An OpenCode subagent's thread opens with its task and names its model
    When OpenCode starts a subagent with a task
    Then a child thread opens once OpenCode names the subagent's session
    And its first message is the task the subagent was given
    And it shows the model the subagent ran with, or the parent's when OpenCode names none

  @backlog
  Scenario: A failure inside an OpenCode subagent fails only that subagent
    Given an OpenCode run with a subagent at work
    When OpenCode reports an error for the subagent's session
    Then the subagent's turn fails with that error
    And the parent thread's OpenCode session is not marked as failed

  @backlog
  Scenario Outline: OpenCode requests that cannot be carried out say why
    When <problem>
    Then the request fails with "<message>"

    Examples:
      | problem                                                 | message                                               |
      | a steer reaches OpenCode after the turn "t1" has ended  | OpenCode turn t1 is not active                        |
      | a turn starts on a session "s1" the MC no longer tracks | OpenCode session s1 is not registered                 |
      | OpenCode answers creating a session with nothing at all | OpenCode session.create returned no response payload. |

  @backlog
  Scenario: OpenCode's protocol log records the shape of events, never their content
    Given protocol logging is on
    When OpenCode streams text, tool input and tool output
    Then the protocol log records each event's direction, kind and structure
    And it holds none of the text, input or output

  @backlog
  Scenario: A protocol log that cannot be written does not disturb the OpenCode turn
    Given protocol logging is on and the log cannot be written
    When an OpenCode turn runs
    Then the turn runs normally
    And the MC logs the warning "Failed to write native OpenCode event log."

  # OpenCodeDriver.ts: a status check starts an OpenCode server, so it runs only when asked for.
  @backlog
  Scenario: OpenCode's status is checked when asked, not on the background interval
    Given OpenCode is enabled and the background health check interval is on
    When the interval passes, or the user changes an OpenCode setting
    Then no OpenCode status check is run and no OpenCode server is started for one
    But OpenCode's status is checked when the user refreshes provider status
