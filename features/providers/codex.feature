# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-codex.md
#   docs/internals/providers.md (Codex async questions, shadow homes, update ownership)
#   apps/server-ex/lib/hal_c2/codex/provider.ex, apps/server-ex/lib/hal_c2/codex/thread_runtime.ex
#   apps/server-ex/lib/hal_c2/orchestration.ex (provider.uploadFeedback)
#   apps/server-ex/lib/hal_c2/provider_updates.ex (@openai/codex advisory)
#   apps/server-ex/lib/hal_c2/provider_usage_limits/codex.ex (account/rateLimits/read, reset credits)
#   apps/server-ex/lib/hal_c2/text_generation.ex (codex exec)
#   apps/server/src/provider/Layers/CodexProvider.ts, apps/server/src/provider/Layers/CodexSessionRuntime.ts
#   apps/server/src/provider/Drivers/CodexDriver.ts, apps/server/src/provider/Drivers/CodexHomeLayout.ts
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts
#   apps/server/src/codexModelOptions.ts (fast mode as a service tier)
#   packages/effect-codex-app-server/src/protocol.ts, client.ts, errors.ts, _internal/stdio.ts
#     (the app-server wire client: unknown requests, the 32-request limit, framing, exit)
#   apps/server/src/provider/Layers/codexUsageLimits.ts, apps/server/src/provider/Layers/codexResetCredit.ts
#   apps/server/src/provider/CodexDeveloperInstructions.ts, apps/server/src/provider/CodexTurnTokenUsage.ts
#   apps/server/src/provider/CodexToolPresentation.ts, apps/server/src/provider/Layers/codexLaunchArgs.ts
#   packages/contracts/src/rpc.ts (provider.uploadFeedback, provider.consumeResetCredit)

@plugin-codex @mc
Feature: Codex
  Codex runs as a bundled provider plugin through the codex app-server protocol. The
  MC reads Codex's own model list, maps HAL-C2's access modes to Codex's approval
  and sandbox policies, and keeps Codex's login where Codex keeps it.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Codex is offered when the codex command is on the MC's path
    Given the codex command is installed on the MC
    When the user opens the provider list
    Then Codex is listed as ready with its installed version

  Scenario: Codex is not offered when the codex command is missing
    Given the codex command is not installed on the MC
    When the user opens the provider list
    Then Codex is not offered as a provider

  Scenario: Codex models come from Codex itself
    Given Codex reports the models "GPT-6 Astra" and "GPT-6 Luna"
    When the MC has read the Codex model list
    Then both models are offered in the model picker with Codex's default marked

  Scenario: A default model is offered until Codex's list has been read
    Given the MC has just started and has not read the Codex model list yet
    When the user opens the model picker for Codex
    Then a single default Codex model is offered

  Scenario: Updating Codex uses the installer that owns it
    Given Codex was installed with npm and is outdated
    When the user updates Codex
    Then Codex is updated through npm and the new version is shown

  # A compatibility advisory can recommend a release other than the latest; npm is
  # the one installer that can pin it (provider_updates.ex targeted/2).
  Scenario: Codex installed with npm can install a chosen version
    Given Codex was installed with npm and is outdated
    When the user installs Codex "0.60.0"
    Then Codex is installed at "0.60.0" through npm

  Scenario Outline: Codex approvals are answered from HAL-C2
    Given the thread runs Codex with approval required
    When Codex asks to <action>
    Then the user is asked to approve it
    And the user's decision is sent back to Codex

    Examples:
      | action                        |
      | run a command                 |
      | change a file                 |
      | widen its sandbox permissions |

  Scenario Outline: Codex approval decisions keep their scope
    Given Codex asked to run a command
    When the user answers <decision>
    Then Codex <result>

    Examples:
      | decision              | result                                      |
      | allow once            | runs the command this time only             |
      | allow for the session | runs matching commands for the session      |
      | decline               | skips the command and continues             |
      | cancel                | stops the turn                              |

  Scenario: Codex questions are asked in HAL-C2
    When Codex asks the user a question with choices
    Then the question is shown with its choices
    And the user's answer is sent back to Codex

  Scenario: A Codex question can be dismissed
    Given Codex asked the user a question
    When the user dismisses the question
    Then Codex is told the question was not answered

  Scenario: A Codex turn can be steered while it runs
    Given a Codex turn is running
    When the user sends a follow-up message
    Then Codex receives the message during the running turn

  Scenario: Codex's plan and task list are shown during the turn
    Given the thread is in plan mode on Codex
    When Codex updates its plan
    Then the task list shows each step and its status
    And the finished plan is shown as a proposed plan

  @shared @backlog-mobile
  Scenario: A plan Codex marked finished can still be implemented
    Given Codex proposed a plan and marked it finished
    Then the plan is offered for implementation
    When the user implements the plan
    Then a new run starts from that plan

  Scenario: Codex can use the HAL-C2 tools
    Given the project allows the HAL-C2 tools
    When a Codex turn starts
    Then Codex can call the HAL-C2 tools for this thread

  Scenario: Codex starts with the launch arguments configured for it
    Given the Codex instance has launch arguments configured
    When a Codex session starts
    Then Codex is started with those arguments

  Scenario: Launch arguments that cannot be read fail the turn and say why
    Given the Codex instance has launch arguments with a quote that is never closed
    When the user sends a message to a Codex thread
    Then the turn fails saying the launch arguments have a quote that is never closed

  Scenario Outline: Codex launch arguments apply wherever Codex is started
    Given the Codex instance has launch arguments configured
    When <occasion>
    Then Codex is started with those arguments

    Examples:
      | occasion                              |
      | the MC checks Codex's version         |
      | Codex writes a title for a new thread |

  Scenario: Reverting a Codex turn rolls Codex back too
    Given a Codex thread with three turns
    When the user reverts to the end of the first turn
    Then Codex's own thread is rolled back to that point

  Scenario: Reverting a Codex turn works after Codex restarts
    Given a Codex thread with three turns
    And Codex's app-server restarted after the first turn
    When the user reverts to the end of the first turn
    Then Codex's own thread is rolled back to that point
    And the revert is reported as complete

  Scenario: Forking a Codex thread forks Codex's thread
    Given a Codex thread with three turns
    When the user forks from the second turn
    Then a new thread continues from a fork of Codex's thread at the second turn

  Scenario: Feedback about a Codex thread is sent to OpenAI
    Given a Codex thread has run at least one turn on this MC
    When the user sends feedback "The agent stopped early"
    Then the conversation and Codex logs are uploaded to OpenAI
    And the user is given the feedback thread id

  Scenario: Feedback before any Codex turn has run is refused
    Given a Codex thread that has not run a turn yet
    When the user sends feedback
    Then the user is told no Codex session has run yet

  Scenario: Codex writes thread titles and commit messages
    Given Codex is picked for text generation
    When a commit needs a message
    Then Codex writes it in a read-only sandbox

  Scenario: Several Codex accounts share one Codex home
    Given a shared Codex home and a second Codex instance with its own shadow home
    When the user signs in to the second instance
    Then both instances see the same Codex sessions and settings
    And each keeps its own login and model list

  # Blocked: needs "Several Codex accounts share one Codex home" first.
  @backlog @blocked
  Scenario: The user can switch a Codex thread to another account
    Given two Codex instances share a Codex home
    When the user picks the other account from the thread's model picker
    Then the thread continues on that account without moving its history

  # Blocked: needs "Several Codex accounts share one Codex home" first.
  @backlog @blocked
  Scenario: Accounts with a different Codex home are not offered for an existing thread
    Given a Codex instance with a separate Codex home
    When the user opens the model picker in an existing Codex thread
    Then that instance is not offered for the thread

  Scenario: Answering a question while Codex keeps working
    Given Codex asked a question and kept working
    When the user answers it
    Then the answer reaches the running turn as a new message

  Scenario: An answer after Codex finished starts a new turn
    Given Codex asked a question and then finished the turn
    When the user answers it
    Then the answer starts a new turn

  Scenario: A question Codex did not wait on can be dismissed
    Given Codex asked a question and kept working
    When the user dismisses it
    Then the question is closed without an answer

  Scenario: A question in a thread imported from the Node server can be dismissed
    Given a thread imported with a Codex question that is not answered yet
    When the user dismisses it
    Then the question is closed without an answer

  Scenario: Unanswered Codex questions survive a reconnect
    Given Codex asked a question that is not answered yet
    When the client reconnects to the MC
    Then the question is still waiting for an answer

  Scenario Outline: Codex tools can ask for access to another app
    Given a Codex tool asks for access to "Linear"
    When the user grants access <scope>
    Then the tool gets access <scope>

    Examples:
      | scope                 |
      | for this request      |
      | for this session      |
      | permanently           |

  Scenario: Declining an app access request lets the tool continue without it
    Given a Codex tool asks for access to "Linear"
    When the user declines
    Then the tool is told access was declined

  Scenario: Codex exiting mid-turn is reported
    Given a Codex turn is running
    When the Codex app-server exits unexpectedly
    Then the turn fails saying Codex exited unexpectedly

  Scenario: Codex stopping on a usage limit names the limit and the reset
    When Codex stops because the weekly limit is used up
    Then the thread says the weekly limit is used up and when it resets
    And it says to send the message again after the reset

  Scenario: A workspace plan out of credits says who can fix it
    Given the Codex account is on a workspace plan with no credits left
    When Codex stops on a usage limit
    Then the thread says the workspace owner needs to add credits

  Scenario Outline: Codex model options
    When the user opens the options for a Codex model that supports <option>
    Then the user can choose <choices>

    Examples:
      | option       | choices                                               |
      | reasoning    | none, minimal, low, medium, high, extra high, max     |
      | service tier | standard or fast                                      |

  Scenario: Codex subagents appear as child threads
    When Codex starts a subagent
    Then the subagent's work is shown as a child of the turn
    And the user can open the subagent's own thread

  Scenario: Codex auto mode uses Codex's automatic reviewer
    Given the thread runs Codex in auto mode
    When Codex wants to run a command outside its sandbox
    Then Codex's automatic reviewer decides instead of asking the user

  Scenario: A signed-out Codex explains how to sign in
    Given the Codex CLI on the MC is not signed in
    When the user opens the provider list
    Then Codex is shown as not signed in with a hint to run the Codex login command

  # Message states of the Codex health check (CodexProvider.ts checkCodexProviderStatus).
  @backlog
  Scenario Outline: Codex that cannot be started is explained
    Given the Codex binary path is <path>
    And the Codex command cannot be started
    When the user opens the provider list
    Then Codex is shown as unavailable with the message "<message>"

    Examples:
      | path             | message                                                                                                                                                         |
      | the default      | Could not start Codex CLI (`codex`). Check Settings → Providers → Codex → Binary path on the server. Installing ChatGPT or Codex desktop may not add codex to PATH. |
      | "/opt/bad/codex" | Could not start Codex CLI (`/opt/bad/codex`). Check Settings → Providers → Codex → Binary path on the server. Make sure the configured executable exists and can be run. |

  @backlog
  Scenario: Codex that starts but fails its check shows why
    Given the Codex command starts but its status check fails with "invalid response"
    When the user opens the provider list
    Then Codex is shown as installed but unavailable with the message "Codex app-server provider probe failed: invalid response."

  @backlog
  Scenario: Codex that does not answer its status check in time says so
    Given the Codex command starts but does not answer its status check
    When the user opens the provider list
    Then Codex is shown as unavailable with the message "Timed out while checking Codex app-server provider status."

  @backlog
  Scenario: A Codex that has not been checked yet says so
    Given the MC has just started and has not checked Codex yet
    When the user opens the provider list
    Then Codex is shown with a warning that its status has not been checked in this session yet

  @backlog
  Scenario: A disabled Codex says it is disabled in settings
    Given Codex is turned off in the provider settings
    When the user opens the provider list
    Then Codex is shown with the message "Codex is disabled in HAL-C2 settings."

  Scenario: Codex shows the signed-in account and plan
    Given Codex is signed in with a ChatGPT Pro subscription
    When Codex's usage has been checked
    Then Codex shows the account's email and its ChatGPT Pro plan

  Scenario: Codex signed in with an API key says so
    Given Codex is signed in with an OpenAI API key
    When Codex's usage has been checked
    Then Codex shows that it uses an OpenAI API key

  Scenario: Codex offers its compact and feedback commands in the composer
    When the user types a slash in a Codex thread
    Then "/compact" and "/feedback" are offered

  # CodexSessionRuntime.ts isRecoverableThreadResumeError: "not found", "missing thread",
  # "no such thread", "unknown thread", "does not exist" and "no rollout found".
  @backlog
  Scenario: A Codex conversation that Codex can no longer find starts a fresh one
    Given a Codex thread whose native conversation Codex has since forgotten
    When the user sends a message
    Then the message runs in a new Codex conversation
    And the thread keeps its history in HAL-C2

  @backlog
  Scenario: A Codex resume that fails for another reason is reported
    Given resuming the Codex thread fails with an error that is not about a missing conversation
    When the user sends a message
    Then the user sees that error
    And no new Codex conversation is started

  @backlog
  Scenario: Codex's memory consolidation is not shown as a subagent
    When Codex consolidates its memories in the background during a turn
    Then the thread shows no subagent for it
    And its activity does not appear in the thread's work log

  # Likely already implemented: apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (collaborationMode)
  @backlog
  Scenario: Codex is told its mode on every turn
    Given a Codex thread that was in plan mode and is resumed in default mode
    When the user sends a message
    Then Codex is told it is in default mode and that plan mode no longer applies

  @backlog
  Scenario: The orchestration instructions are given to Codex in default mode only
    Given the "hal-c2" server is attached to a Codex thread
    When the user sends a message in plan mode and then one in default mode
    Then Codex receives HAL-C2's orchestration instructions with the second message only

  @backlog
  Scenario: Codex is not told about browser or device tools it does not have
    Given the "hal-c2" server is attached to a Codex thread without browser or device tools
    When the user sends a message
    Then Codex's instructions do not describe browser or device tools

  # codexLaunchArgs.ts: the variable overrides the instance's arguments, and text generation
  # (codex exec) takes over only the configuration and feature flags among them.
  @backlog
  Scenario: A launch arguments variable on the MC overrides the instance's arguments
    Given the MC's environment sets HAL_C2_CODEX_LAUNCH_ARGS
    And the Codex instance has other launch arguments configured
    When a Codex session starts
    Then Codex is started with the variable's arguments only

  # The outline "Codex launch arguments apply wherever Codex is started" configures only
  # configuration arguments; this one adds a session-only flag. The MC already filters them
  # (HalC2.Codex.Provider.exec_args/1 from text_generation.ex); it waits for its steps.
  @backlog
  Scenario: Codex's title writer leaves out the launch arguments only a Codex session takes
    Given the Codex instance has the launch arguments "--config model_provider=local --enable web_search --full-auto"
    When Codex writes a title for a new thread
    Then the title writer is started with "--config model_provider=local" and "--enable web_search"
    And "--full-auto" is left out

  # CodexToolPresentation.ts: how Codex's browser and computer tools appear in the work log.
  # The MC serves app icons (mc/platform/attachments-and-assets.feature); nothing yet derives
  # the surface, source and icon of a Codex tool call.
  @backlog
  Scenario: Codex's browser tool calls are shown as browser work with the page's icon
    When Codex uses its browser tool on "https://example.com/docs"
    Then the work log entry is marked as browser work
    And it shows the page's address and favicon

  @backlog
  Scenario: A page address that is not http or https gets no page icon
    When Codex uses its browser tool on a page whose address is "file:///etc/passwd"
    Then the work log entry shows no page address or favicon

  @backlog
  Scenario Outline: A Codex browser is named by its family
    When Codex uses its browser tool through <reported>
    Then the work log entry names the browser "<shown>"

    Examples:
      | reported              | shown          |
      | Google Chrome         | Chrome         |
      | Chromium              | Chrome         |
      | Microsoft Edge        | Microsoft Edge |
      | Firefox Developer     | Firefox        |
      | Safari                | Safari         |
      | the in-app browser    | Browser        |
      | nothing               | Browser        |

  @backlog
  Scenario: Codex's computer tool calls are shown with the application they drive
    When Codex uses its computer tool on the application "Finder"
    Then the work log entry is marked as computer work
    And it names "Finder" and shows its application icon

  @backlog
  Scenario: Computer tool calls on the same application are grouped under one source
    When Codex makes two computer tool calls on the same application
    Then both work log entries are grouped under that application

  @backlog
  Scenario: Codex's computer tool without a named application is called Computer Use
    When Codex uses its computer tool and reports no application
    Then the work log entry names "Computer Use"
    And shows no application icon

  # CodexAdapterV2.ts: what an approval says, how tool calls and searches are shown.
  @backlog @mc
  Scenario Outline: A Codex approval says what it is for
    When Codex asks to <action> and gives <given>
    Then the approval shows <shown>

    Examples:
      | action        | given                           | shown                                       |
      | run a command | a reason                        | Codex's reason                              |
      | run a command | no reason                       | the command                                 |
      | change files  | a reason                        | Codex's reason                              |
      | change files  | no reason                       | each file with what would be done to it     |
      | change files  | no reason and a file to move    | the file's old path and its new path        |
      | change files  | no reason and no files, a root  | the folder Codex wants to write under       |

  @backlog @mc
  Scenario: A Codex approval for many files lists the first 20 and counts the rest
    When Codex asks without a reason to change 23 files
    Then the approval lists the first 20 files in path order
    And it ends with "+3 more"

  @backlog @mc
  Scenario Outline: An older Codex's approval requests are answered too
    Given a Codex that asks for approvals in its older form
    When Codex asks to <action> and the user answers <decision>
    Then Codex is told "<answer>"

    Examples:
      | action        | decision              | answer               |
      | run a command | allow once            | approved             |
      | run a command | allow for the session | approved_for_session |
      | run a command | decline               | denied               |
      | run a command | cancel                | abort                |
      | apply a patch | allow once            | approved             |
      | apply a patch | cancel                | abort                |

  @backlog @mc
  Scenario: HAL-C2 introduces itself to Codex by name
    When a Codex session starts
    Then Codex is told the client is "hal_c2_desktop" titled "HAL-C2 Desktop"

  @backlog @mc
  Scenario: Codex is asked not to send a diff after every change
    When a Codex session starts
    Then HAL-C2 opts out of Codex's "turn/diff/updated" notifications
    And changed files are still shown from the file changes Codex reports

  @backlog @mc
  Scenario: A Codex tool call on an MCP server names the server and the tool
    When Codex calls the tool "search" on the MCP server "docs"
    Then the tool call is shown as "docs.search" with its arguments
    And its result is shown when the call finishes

  @backlog @mc
  Scenario: A failed Codex MCP tool call shows the server's error
    When a tool Codex called on an MCP server fails
    Then the tool call is shown as failed with the error the server gave

  @backlog @mc
  Scenario Outline: A Codex web search shows what Codex did on the web
    When Codex <action>
    Then the web search entry shows <shown>

    Examples:
      | action                   | shown                              |
      | searches the web         | the queries it searched for        |
      | opens a page             | the address of the page            |
      | looks for text in a page | the text and the page's address    |

  @backlog @mc
  Scenario: Leaving auto mode on a Codex thread returns approvals to the user
    Given a Codex thread that ran a turn in auto mode
    When the user changes the thread to approval required and sends a message
    Then Codex is told the user reviews approvals
    And Codex asks the user instead of its automatic reviewer

  @backlog @mc
  Scenario: Codex is asked for detailed summaries of its reasoning
    When a Codex turn starts
    Then Codex is asked for detailed reasoning summaries
    And the summaries and any raw reasoning Codex sends are shown as the turn's thinking

  # codexModelOptions.ts: an explicit service tier wins; the older fast mode switch means "fast".
  @backlog @mc
  Scenario Outline: A Codex thread runs on the service tier chosen for it
    Given a Codex thread whose model selection has <selection>
    When the user sends a message
    Then the turn is sent to Codex <tier>

    Examples:
      | selection                              | tier                          |
      | the service tier "fast"                | on the "fast" service tier    |
      | fast mode on and no service tier       | on the "fast" service tier    |
      | fast mode off and no service tier      | without naming a service tier |

  @backlog @mc
  Scenario: Codex without the HAL-C2 tools is given no HAL-C2 instructions
    Given a Codex thread that has no "hal-c2" server attached
    When the user sends a message in default mode
    Then Codex receives no instructions from HAL-C2 beyond the message

  @backlog @mc
  Scenario: A Codex reconnect shows which attempt it is on
    Given a Codex turn is running
    When Codex reports "Reconnecting... 2/5" and says it will retry
    Then the turn shows a retry on attempt 2 of 5
    And the turn keeps running

  @backlog @mc
  Scenario: A Codex retry that names no attempt is counted
    Given a Codex turn is running
    When Codex reports twice that it will retry without saying which attempt it is on
    Then the turn shows a retry on attempt 2 with no known maximum

  @backlog @mc
  Scenario: A Codex failure shows Codex's fuller explanation when it gives one
    When a Codex turn fails with a short message and additional details
    Then the turn's failure shows the additional details

  @backlog @mc
  Scenario: A Codex installed as a Windows command script starts
    Given the MC runs on Windows
    And the codex command is a command script rather than a program
    When a Codex session starts
    Then Codex starts and answers as it does from a program

  @backlog @mc
  Scenario: A Codex home that cannot be prepared for an account fails the turn
    Given a Codex instance whose own home cannot be prepared from the shared one
    When the user sends a message
    Then the turn fails with "Failed to materialize the Codex shadow home."
    And Codex is not started against the shared home instead

  @backlog @mc
  Scenario: A Codex usage limit learns its reset time when Codex reports it late
    Given a Codex turn stopped on a usage limit before Codex said when the limit resets
    When Codex then reports its usage windows
    Then the stopped turn shows the reset time from those windows

  @backlog @mc
  Scenario: A Codex usage limit's reset time does not move once it is known
    Given a Codex turn stopped on a usage limit that resets at 14:00
    When Codex later reports usage windows with another reset time
    Then the stopped turn still says it resets at 14:00

  @backlog @mc
  Scenario: Codex repeating its final answer does not show it twice
    When Codex sends the same final answer twice in one turn
    Then the thread shows that answer once

  @backlog @mc
  Scenario: An empty second final answer from Codex adds nothing to the thread
    When Codex sends a final answer and then an empty one in the same turn
    Then the thread shows the first answer only

  @backlog @mc
  Scenario: A Codex question with blanks is still askable
    When Codex asks a question with no heading, no text and unlabelled choices
    Then the question is shown under "Question" asking "Choose an answer."
    And its choices are labelled "Option 1", "Option 2" and so on

  @backlog @mc
  Scenario: A request from a Codex tool that HAL-C2 cannot show is declined
    When a tool's server asks the user for something HAL-C2 has no way to present
    Then the request is declined without asking the user
    And the turn goes on

  @backlog @mc
  Scenario: A tool's request that arrives when no turn is running is declined
    Given no Codex turn is running in the thread
    When a tool's server asks the user for access
    Then the request is declined without asking the user

  @backlog @mc
  Scenario: Resuming a Codex thread does not load its whole history
    Given a Codex thread with a long conversation
    When the MC resumes it to run a new message
    Then Codex is asked to resume without sending back its earlier turns

  @backlog @mc
  Scenario: A Codex turn that finishes while it is being stopped is recorded as interrupted
    Given the user stopped a running Codex turn
    When Codex reports the turn completed before it acknowledges the stop
    Then the turn ends as interrupted

  @backlog @mc
  Scenario: Stopping a Codex turn that has not started yet waits for it to start
    Given a Codex turn was sent and Codex has not started it yet
    When the user stops the turn
    Then the stop is delivered as soon as Codex starts the turn

  @backlog @mc
  Scenario: A queued Codex turn that never starts cannot be stopped
    Given a Codex turn was sent and Codex does not start it
    When the user stops the turn and 10 seconds pass
    Then the stop fails with "Codex did not start the queued turn within 10 seconds; Stop could not be delivered."

  @backlog @mc
  Scenario: A Codex turn that does not stop within 10 seconds is settled as interrupted
    Given the user stopped a running Codex turn
    When Codex has not ended the turn after 10 seconds
    Then the turn ends as interrupted
    And what Codex sends for that turn afterwards is not added to the thread

  @backlog @mc
  Scenario: A Codex tool call marked persistent outlives its turn
    Given Codex started a tool call marked persistent and another that is not
    When the turn completes with both still open
    Then the other tool call is closed with the turn
    And the persistent tool call stays running

  @backlog @mc
  Scenario Outline: A Codex subagent shows the state Codex reports for it
    When Codex reports a subagent as <reported>
    Then the subagent is shown as <shown>

    Examples:
      | reported           | shown       |
      | waiting to start   | pending     |
      | running            | running     |
      | interrupted        | interrupted |
      | completed          | completed   |
      | errored            | failed      |
      | shut down          | cancelled   |
      | not found          | failed      |

  @backlog @mc
  Scenario: A Codex subagent's thread opens with the task it was given
    When Codex starts a subagent with a task
    Then the subagent's thread starts with that task as its first message
    And the subagent's final answer is shown as its result on the parent's turn

  @backlog @mc
  Scenario: A Codex subagent's commentary is not taken for its result
    When a Codex subagent sends commentary and then a final answer
    Then the subagent's result is the final answer

  @backlog @mc
  Scenario: A later message Codex sends a subagent appears in the subagent's thread
    Given a Codex subagent that finished its first task
    When Codex sends the subagent another message
    Then the message appears in the subagent's thread as coming from the parent
    And the subagent is shown as running again

  @backlog @mc
  Scenario: A late report does not reopen a finished Codex subagent
    Given a Codex subagent that completed
    When Codex reports an older state for that subagent
    Then the subagent stays completed

  @backlog @mc
  Scenario: Stopping a Codex turn stops its subagents
    Given a Codex turn with two subagents at work
    When the user stops the turn
    Then both subagents' turns are stopped
    And both subagents are shown as interrupted

  @backlog @mc
  Scenario: A Codex subagent that starts work under a stopped turn is interrupted
    Given a Codex turn that was stopped
    When one of its subagents starts another turn
    Then that subagent's turn is interrupted at once

  # packages/effect-codex-app-server: the wire contract with the Codex app-server.
  @backlog @mc
  Scenario: A request from Codex that HAL-C2 does not know is refused, not left hanging
    When Codex sends a request with a method HAL-C2 does not handle
    Then Codex receives error -32601 "Method not found:" followed by the method
    And the turn goes on

  @backlog @mc
  Scenario: Codex cannot pile up more than 32 open requests on the MC
    Given 32 requests from Codex are waiting on the user
    When Codex sends another request
    Then Codex receives error -32001 "Too many Codex requests are already active."
    And the 32 waiting requests are unaffected

  @backlog @mc
  Scenario: A message from Codex that HAL-C2 cannot read does not end the turn
    Given a Codex turn is running
    When Codex sends a notification in a shape HAL-C2 does not know
    Then the notification is skipped
    And the turn goes on with the messages that follow

  @backlog @mc
  Scenario Outline: Codex's messages are read whole however they arrive
    When Codex's output arrives <how>
    Then each message is read once and complete

    Examples:
      | how                                        |
      | with one message split across two reads    |
      | with several messages in one read          |
      | with Windows line endings                  |
      | with blank lines between messages          |

  @backlog @mc
  Scenario: Codex writing a lot to its error output does not stall the turn
    Given a Codex turn is running
    When Codex writes more to its error output than the system buffers
    Then Codex keeps running and the turn goes on

  @backlog @mc
  Scenario: A request to Codex that is open when Codex exits fails instead of hanging
    Given the MC is waiting on Codex for an answer
    When Codex exits with code 1
    Then the request fails with "Codex App Server process exited with code 1"

  @backlog @mc
  Scenario: Output from Codex that is not a protocol message ends the session
    Given a Codex turn is running
    When Codex writes a line to its output that is not a protocol message
    Then the connection to Codex is closed
    And the turn fails instead of waiting on Codex

  @backlog @mc
  Scenario: Accounts sharing a Codex home keep their own login
    Given a shared Codex home and a second Codex instance with its own shadow home
    When the second instance is prepared
    Then its login and its model cache are its own files and are never linked to the shared home
    And its logs, memories and temporary files stay in its own home
    And everything else in the shared home is reached through links

  @backlog @mc
  Scenario: A Codex account's home repairs links that point to the wrong place
    Given a Codex instance's shadow home has a link that no longer points into the shared home
    When the instance is prepared
    Then the link points into the shared home again
    And folders the shared home was missing are created

  @backlog @mc
  Scenario Outline: A Codex account's home that would lose data is refused
    Given a Codex instance with its own shadow home where <situation>
    When the instance is prepared
    Then preparing fails saying <reason>
    And no file is overwritten

    Examples:
      | situation                                             | reason                                                   |
      | the shadow home is the shared home itself             | the shadow home must be different from the shared home   |
      | a real file sits where a link to the shared home belongs | the entry already exists and is not a link            |
      | the login file is a link                              | the login must be a real file, not a link                |

  @backlog @mc
  Scenario: Codex skills that cannot be read in 20 seconds are reported
    Given Codex does not answer when asked for the project's skills
    When 20 seconds pass
    Then reading the skills fails naming the project folder
    And the provider's status is not held up by it

  @backlog @mc
  Scenario: A slow model manifest does not delay Codex's status
    Given the model manifest cannot be fetched
    When the MC checks Codex
    Then Codex's status is reported from the manifest the MC already has
