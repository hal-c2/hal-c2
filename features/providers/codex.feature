# Sources:
#   https://github.com/pingdotgg/t3code/pull/28040
#   https://github.com/pingdotgg/t3code/pull/30322
#   https://github.com/pingdotgg/t3code/pull/29280
#   https://github.com/pingdotgg/t3code/pull/23033
#   https://github.com/pingdotgg/t3code/pull/29168
#   https://github.com/pingdotgg/t3code/pull/29582
#   https://github.com/pingdotgg/t3code/pull/25322
#   https://github.com/pingdotgg/t3code/pull/25224
#   https://github.com/pingdotgg/t3code/pull/24257
#   https://github.com/pingdotgg/t3code/pull/23284
#   https://github.com/pingdotgg/t3code/pull/24978
#   https://github.com/pingdotgg/t3code/pull/27924
#   https://github.com/pingdotgg/t3code/pull/25225
#   https://github.com/pingdotgg/t3code/pull/24467
#   https://github.com/pingdotgg/t3code/pull/23160
#   https://github.com/pingdotgg/t3code/pull/24600
#   https://github.com/pingdotgg/t3code/pull/21787
#   https://github.com/pingdotgg/t3code/pull/23840
#   https://github.com/pingdotgg/t3code/pull/24200
#   https://github.com/pingdotgg/t3code/pull/23361
#   https://github.com/pingdotgg/t3code/pull/19936
#   https://github.com/pingdotgg/t3code/pull/24737
#   https://github.com/pingdotgg/t3code/pull/19154
#   https://github.com/pingdotgg/t3code/pull/20537
#   https://github.com/pingdotgg/t3code/pull/15623
#   https://github.com/pingdotgg/t3code/pull/18991
#   https://github.com/pingdotgg/t3code/pull/18415
#   https://github.com/pingdotgg/t3code/pull/21366
#   https://github.com/pingdotgg/t3code/pull/18548
#   https://github.com/pingdotgg/t3code/pull/18248
#   https://github.com/pingdotgg/t3code/pull/20991
#   https://github.com/pingdotgg/t3code/pull/15839
#   https://github.com/pingdotgg/t3code/pull/17501
#   https://github.com/pingdotgg/t3code/pull/19733
#   https://github.com/pingdotgg/t3code/pull/17265
#   https://github.com/pingdotgg/t3code/pull/15945
#   https://github.com/pingdotgg/t3code/pull/16236
#   https://github.com/pingdotgg/t3code/pull/17026
#   https://github.com/pingdotgg/t3code/pull/17027
#   https://github.com/pingdotgg/t3code/pull/17040
#   https://github.com/pingdotgg/t3code/pull/19368
#   https://github.com/pingdotgg/t3code/pull/17663
#   https://github.com/pingdotgg/t3code/pull/18200
#   https://github.com/pingdotgg/t3code/pull/15546
#   https://github.com/pingdotgg/t3code/pull/15592
#   https://github.com/pingdotgg/t3code/pull/13547
#   https://github.com/pingdotgg/t3code/pull/14290
#   https://github.com/pingdotgg/t3code/pull/14304
#   https://github.com/pingdotgg/t3code/pull/13328
#   https://github.com/pingdotgg/t3code/pull/13481 (the 0.156 floor and its support ranges)
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
#   https://github.com/pingdotgg/t3code/pull/15389
#   https://github.com/pingdotgg/t3code/pull/25426
#   https://github.com/pingdotgg/t3code/pull/22541
#   https://github.com/pingdotgg/t3code/pull/21750
#   https://github.com/pingdotgg/t3code/pull/26188
#   https://github.com/pingdotgg/t3code/pull/25611
#   https://github.com/pingdotgg/t3code/pull/23938
#   https://github.com/pingdotgg/t3code/pull/27931
#   https://github.com/pingdotgg/t3code/pull/19066
#   https://github.com/pingdotgg/t3code/pull/23388
#   https://github.com/pingdotgg/t3code/pull/21443
#   https://github.com/pingdotgg/t3code/pull/27281
#   https://github.com/pingdotgg/t3code/pull/22308
#   https://github.com/pingdotgg/t3code/pull/23234
#   https://github.com/pingdotgg/t3code/pull/26286
#   https://github.com/pingdotgg/t3code/pull/27399
#   https://github.com/pingdotgg/t3code/pull/24664
#   https://github.com/pingdotgg/t3code/pull/28604
#   https://github.com/pingdotgg/t3code/pull/29026
#   https://github.com/pingdotgg/t3code/pull/29068
#   https://github.com/pingdotgg/t3code/pull/25341
#   https://github.com/pingdotgg/t3code/pull/31277
#   https://github.com/pingdotgg/t3code/pull/30004
#   https://github.com/pingdotgg/t3code/pull/21045
#   https://github.com/pingdotgg/t3code/pull/29618

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

  @shared
  Scenario: A plan Codex marked finished can still be implemented
    Given Codex proposed a plan and marked it finished
    Then the plan is offered for implementation
    When the user implements the plan
    Then a new run starts from that plan

  Scenario: Codex can use the HAL-C2 tools
    Given the project allows the HAL-C2 tools
    When a Codex turn starts
    Then Codex can call the HAL-C2 tools for this thread

  # Upstream #28604: Codex sessions never got the thread id Claude sessions get, so a tool started
  # from a Codex agent's shell could not find its thread.
  @backlog
  Scenario: A command a Codex agent runs knows which thread it belongs to
    Given the Codex thread "t1" and the Codex thread "t2" share one Codex process
    When the agent of "t1" runs a command in its shell
    Then the command's environment names "t1" as its thread
    And the shell environment the user set in Codex's config is kept

  # Upstream #29026: Codex ran the blocking thread wait inside Code Mode, where the model kept
  # working around the wait.
  # Upstream #29068: the direct-only server is named apart from the other HAL-C2 tools, and waits
  # recorded under the earlier name are still shown as waits.
  @backlog
  Scenario: Codex calls the thread wait as a tool of its own
    Given the project allows the HAL-C2 tools
    When a Codex turn starts
    Then Codex can call "hal_c2_thread_wait" directly, outside Code Mode
    And Codex's other HAL-C2 tools stay where they were
    And a wait Codex makes is shown as the thread waiting

  Scenario: Codex keeps its own subagents unless the subagents setting says otherwise
    Given the project allows the HAL-C2 tools
    When a Codex turn starts
    Then Codex is started with its subagent features left on

  Scenario: Codex's subagents are off when agents use HAL-C2 workers
    Given the project allows the HAL-C2 tools
    And the subagents setting is HAL-C2 workers
    When a Codex turn starts
    Then Codex is started with its subagent features turned off
    And Codex is told to delegate with "delegate_task"

  # Codex takes its features only when its thread starts; the turns' instructions follow them.
  Scenario: A Codex thread keeps the subagents choice it started with
    Given the project allows the HAL-C2 tools
    And the subagents setting is HAL-C2 workers
    When a Codex turn starts
    And the subagents setting is the provider's own
    And the user sends another message to the Codex thread
    Then every Codex turn of the thread is told to delegate with "delegate_task"

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

  # Upstream #15839: MCP servers in Codex's launch arguments are kept beside HAL-C2's own
  @backlog
  Scenario: MCP servers named in Codex's launch arguments stay alongside HAL-C2's
    Given the Codex instance's launch arguments add the MCP server "docs"
    When a Codex thread starts, resumes, forks or is rolled back
    Then Codex has both "docs" and HAL-C2's tools

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

  Scenario: Two Codex accounts keep their own usage limits
    Given a shared Codex home and a second Codex instance with its own shadow home
    And the user signs in to the second instance
    When both Codex instances' usage has been checked
    And a turn on the second Codex instance reports its usage
    Then each Codex account keeps its own usage limits

  Scenario: The user can switch a Codex thread to another account
    Given two Codex instances share a Codex home
    When the user picks the other account from the thread's model picker
    Then the thread continues on that account without moving its history

  # Upstream #24664: two instances whose CODEX_HOME was set only in their environment variables
  # counted as one home, so switching between them resumed the thread in the wrong home.
  Scenario: Codex instances with different CODEX_HOME variables are different homes
    Given the Codex instances "work" and "personal" leave their home blank
    And their environment variables set CODEX_HOME to "~/work-codex" and "~/personal-codex"
    When the user switches a "work" thread to "personal"
    Then the conversation is handed over to "personal"
    And "personal" does not try to resume the "work" session

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

  # Upstream #27924: when a write to the app-server failed while its output stayed open, pending
  # and later requests waited forever and the session was never retired.
  @backlog @priority-high
  Scenario: Codex requests fail at once when the app-server stops taking input
    Given a Codex turn is running
    When the Codex app-server stops accepting input but keeps its output open
    Then the turn fails with the write error instead of waiting
    And later requests to that app-server fail with the same error
    And the next Codex turn starts a new app-server

  # Upstream #26188: after the shared app-server was killed (an OOM killer took its whole
  # scope), every later Codex turn failed until the server restarted.
  Scenario Outline: Codex starts a new app-server after its old one was killed
    Given the Codex app-server was killed by a signal
    When the user <action>
    Then a new Codex app-server is started
    And the turn runs

    Examples:
      | action                                        |
      | sends a follow-up on a thread that used Codex |
      | starts a new Codex thread                     |
      | delegates a task to Codex                     |

  # Upstream #26188: a turn running when the app-server is killed fails at once instead of hanging.
  Scenario: A turn running when Codex's app-server is killed fails at once
    Given a Codex turn is running
    When the Codex app-server is killed by a signal
    Then the turn fails within seconds
    And the next Codex turn starts a new app-server

  # Upstream #25224: Codex answering a new run's start with an earlier run's turn left the new run running forever.
  Scenario: A turn start that Codex answers with an earlier run's turn is not taken as started
    Given a Codex thread whose earlier run had a turn
    When a new run starts a turn and Codex answers with the earlier run's turn
    Then the new run does not take that turn as its own
    And the new run is not left running

  # Upstream #25611: Codex ending a turn with serverOverloaded failed work that could resume.
  @backlog
  Scenario: Codex reporting it is overloaded is retried in the same conversation
    Given a Codex turn is running
    When Codex ends the turn because its servers are overloaded
    Then the MC retries the turn in the same Codex conversation without resending the message
    And the run stays active while it waits

  # Upstream #25611: the retries wait 2 to 30 seconds, at most five of them.
  @backlog
  Scenario: Codex overload retries give up after five attempts
    Given every Codex retry ends because its servers are overloaded
    Then the MC waits between 2 and 30 seconds before each retry
    And after five retries the run fails

  # Upstream #25611: Stop and steering reach the retried turn.
  @backlog
  Scenario Outline: A Codex turn waiting to retry an overload still takes <action>
    Given a Codex turn is waiting to retry after Codex was overloaded
    When the user <does>
    Then <result>

    Examples:
      | action  | does                     | result                                      |
      | Stop    | stops the turn           | no retry is started and the run ends        |
      | a steer | steers "also check docs" | the retried turn receives "also check docs" |

  # Upstream #19733: the reader ends the session on a line above 128 MiB.
  @backlog
  Scenario: A Codex message larger than 128 MiB ends the session
    Given a Codex turn is running
    When Codex sends a message larger than 128 MiB
    Then the turn fails saying Codex sent a message too large to read
    And requests waiting on Codex fail too

  Scenario: Codex stopping on a usage limit names the limit and the reset
    When Codex stops because the weekly limit is used up
    Then the thread says the weekly limit is used up and when it resets
    And it says to send the message again after the reset

  # Upstream #17501: retry exhaustion on HTTP 429 was a generic error.
  Scenario: Codex giving up after repeated 429 responses is a usage limit
    When Codex ends a turn after too many failed attempts that each answered 429
    Then the thread is marked as limited
    And the run does not fail as a provider error

  Scenario: A Codex error that only mentions 429 in passing is not a usage limit
    When Codex ends a turn with an error whose message mentions 14290 tokens
    Then the turn fails as an ordinary error, not a usage limit

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

  # Upstream #20991: an unset effort follows the model's default instead of being forced to medium
  Scenario: A Codex turn with no reasoning chosen runs at the model's own default
    Given a Codex model whose default reasoning is "high"
    And the thread has no reasoning level chosen
    When the user sends a message
    Then the turn runs at "high"
    And a reasoning level the user picks is used instead, in plan mode too

  # Upstream #27931: with ChatGPT sign-in, models newer than the installed CLI came without reasoning choices.
  @backlog @priority-high
  Scenario: A model newer than the installed Codex still offers its reasoning levels
    Given Codex is signed in with a ChatGPT account
    And the account's model catalog lists a model the installed Codex does not know yet
    When the user opens the options for that model
    Then the reasoning levels the catalog lists for it are offered

  Scenario: Codex subagents appear as child threads
    When Codex starts a subagent
    Then the subagent's work is shown as a child of the turn
    And the user can open the subagent's own thread

  # Upstream #24467: a native Codex child thread copied its parent's reasoning effort.
  @backlog @priority-low
  Scenario Outline: A Codex subagent's thread shows its own reasoning effort
    Given a Codex thread with reasoning effort "high"
    When Codex starts a subagent <reported>
    Then the subagent's thread shows <shown>

    Examples:
      | reported                       | shown                     |
      | that reports effort "low"      | reasoning effort "low"    |
      | that reports no effort         | no reasoning effort       |

  Scenario: Codex auto mode uses Codex's automatic reviewer
    Given the thread runs Codex in auto mode
    When Codex wants to run a command outside its sandbox
    Then Codex's automatic reviewer decides instead of asking the user

  Scenario: A signed-out Codex explains how to sign in
    Given the Codex CLI on the MC is not signed in
    When the user opens the provider list
    Then Codex is shown as not signed in with a hint to run the Codex login command

  # Message states of the Codex health check (CodexProvider.ts checkCodexProviderStatus).
  Scenario Outline: Codex that cannot be started is explained
    Given the Codex binary path is <path>
    And the Codex command cannot be started
    When the user opens the provider list
    Then Codex is shown as unavailable with the message "<message>"

    Examples:
      | path             | message                                                                                                                                                         |
      | the default      | Could not start Codex CLI (`codex`). Check Settings → Providers → Codex → Binary path on the server. Installing ChatGPT or Codex desktop may not add codex to PATH. |
      | "/opt/bad/codex" | Could not start Codex CLI (`/opt/bad/codex`). Check Settings → Providers → Codex → Binary path on the server. Make sure the configured executable exists and can be run. |

  Scenario: Codex that starts but fails its check shows why
    Given the Codex command starts but its status check fails with "invalid response"
    When the user opens the provider list
    Then Codex is shown as installed but unavailable with the message "Codex app-server provider probe failed: invalid response."

  Scenario: Codex that does not answer its status check in time says so
    Given the Codex command starts but does not answer its status check
    When the user opens the provider list
    Then Codex is shown as unavailable with the message "Timed out while checking Codex app-server provider status."

  # Codex's check starts its app server and reads the account, models and skills, so it
  # gets twice the budget other providers' checks get (pingdotgg/t3code#15945).
  @backlog
  Scenario Outline: A slow but healthy Codex is not shown as unavailable
    Given the Codex command answers its status check after <seconds> seconds
    When the MC checks Codex
    Then Codex is shown as <status>

    Examples:
      | seconds | status                                                                                       |
      | 15      | available                                                                                    |
      | 21      | unavailable with the message "Timed out while checking Codex app-server provider status."    |

  Scenario: A Codex that has not been checked yet says so
    Given the MC has just started and has not checked Codex yet
    When the user opens the provider list
    Then Codex is shown with a warning that its status has not been checked in this session yet

  Scenario: A client connected at boot is told Codex's checked status
    Given a client is subscribed before Codex is checked
    When the MC's boot check of Codex runs
    Then the client is told Codex's checked status without asking again

  Scenario: A disabled Codex says it is disabled in settings
    Given Codex is turned off in the provider settings
    When the user opens the provider list
    Then Codex is shown with the message "Codex is disabled in HAL-C2 settings."

  Scenario: Codex shows the signed-in account and plan
    Given Codex is signed in with a ChatGPT Pro subscription
    When Codex's usage has been checked
    Then Codex shows the account's email and its ChatGPT Pro plan

  # Upstream #24978: after a downgrade the badge kept the plan cached in Codex's login token.
  @mc
  Scenario Outline: Codex's plan follows its usage read after the plan changes
    Given Codex's account says ChatGPT Pro from its cached login
    And Codex's usage read reports <usage plan>
    When Codex's usage has been checked
    Then Codex shows the <shown> plan

    Examples:
      | usage plan      | shown        |
      | ChatGPT Free    | ChatGPT Free |
      | no plan         | ChatGPT Pro  |
      | an unknown plan | ChatGPT Pro  |

  # Upstream #23361: a turn stopped by a ChatGPT sharing limit showed Codex's raw error. OpenAI's
  # partner guidelines give each limit its own recovery.
  @backlog @shared
  Scenario Outline: A turn stopped by a ChatGPT plan limit says how to recover
    Given Codex is signed in with <plan>
    When a turn stops because the plan's limit for other apps is reached
    Then the thread shows the ChatGPT limit with "<action>"

    Examples:
      | plan                               | action                  |
      | a personal ChatGPT plan            | Manage usage            |
      | a ChatGPT Business workspace       | Copy request for admin  |

  # Upstream #25341: Codex reports a used-up ChatGPT sharing allowance as a stream disconnect,
  # which failed the thread with no way to recover.
  @mc @shared @priority-high @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A sharing limit reported as a disconnect leaves the thread limited, not failed
    Given Codex is signed in with a personal ChatGPT plan
    When a turn stops with "stream disconnected before completion: The ChatGPT user has reached their Subscription Sharing usage limit."
    Then the thread is marked limited, not failed
    And without a reset time from the sharing limit, the user is offered a manual retry
    And an ordinary Codex usage reset is not taken as the sharing limit's reset

  # Upstream #25341: one limit showed two stacked notices on the desktop.
  # Upstream #31277: the phone showed the same two notices; it now shows one, aligned.
  @backlog @shared
  Scenario: A ChatGPT sharing limit shows one notice above the composer
    Given a turn stopped at a ChatGPT sharing limit
    Then one usage-limit notice shows above the composer
    And its "Manage usage" or "Copy request for admin" action sits inside that notice
    And screen readers announce the notice

  # Upstream #23361: ChatGPT Business usage limits offer a copyable admin request.
  @backlog @shared
  Scenario: Copying the request for a workspace admin confirms it
    Given a turn stopped at a ChatGPT Business workspace limit
    When the user chooses "Copy request for admin"
    Then the request for the admin is copied
    And the user is told "Request copied · Send it to your workspace admin."

  # Upstream #24200: the top Pro plan is now called Pro 500.
  Scenario: A ChatGPT Pro 500 plan is shown by name
    Given Codex is signed in with the ChatGPT plan Codex reports as "promax"
    When Codex's usage has been checked
    Then Codex shows the account's email and its "ChatGPT Pro 500 Subscription" plan

  # Upstream #24200: OpenAI renamed its plans; Codex accounts showed the old names.
  Scenario Outline: Codex shows the ChatGPT plan by its current name
    Given Codex is signed in with the ChatGPT plan Codex reports as "<plan>"
    When Codex's account is read
    Then Codex shows the plan as "<name>"

    Examples:
      | plan                        | name                                 |
      | prolite                     | ChatGPT Pro 100 Subscription         |
      | pro                         | ChatGPT Pro 200 Subscription         |
      | team                        | ChatGPT Business Subscription        |
      | self_serve_business_prolite | ChatGPT Business Premium Subscription |

  Scenario: A ChatGPT plan HAL-C2 does not know still signs the account in
    Given Codex is signed in with a ChatGPT plan named by a newer Codex
    When Codex's account is read
    Then Codex shows as signed in and its plan is shown by the plan's own name

  @backlog @shared @priority-low
  Scenario: The Ultrafast service tier is offered for a model that lists it
    Given the selected Codex model lists the "ultrafast" service tier
    When the user opens the service tier choices
    Then "Ultrafast" is offered with the description "Even faster, more expensive"

  # Upstream #18200. Codex shares one model catalog cache between every client on the
  # machine, and the plain CLI's catalog has no Ultrafast. Codex started by the MC asks for
  # HAL-C2's own catalog, and the probe waits briefly for that refresh before it lists.
  @backlog @mc @plugin-codex @priority-low
  Scenario: Ultrafast stays offered after another Codex client refreshes the catalog
    Given the ChatGPT account is entitled to the Ultrafast tier
    And another Codex client on the machine wrote a model catalog without it
    When the MC checks Codex's models
    Then the models still list the Ultrafast tier
    And a thread set to Ultrafast stays on Ultrafast

  @backlog @mc @plugin-codex @priority-low
  Scenario: Ultrafast is no longer offered once the account loses it
    Given the ChatGPT account was entitled to the Ultrafast tier and no longer is
    When the MC checks Codex's models
    Then the models no longer list the Ultrafast tier

  # Upstream #15623: Codex inheriting Fast from its global config showed the catalog's Standard default.
  @backlog @shared @priority-low
  Scenario: A Fast tier set in Codex's own config shows as selected
    Given Codex's global config sets the service tier to fast
    When the user opens the service tier choices for a model that offers Fast
    Then Fast is shown as selected
    And a model that does not offer Fast keeps its own default

  # Upstream #20537: slow model discovery threw away a successful account check.
  Scenario: A signed-in Codex stays signed in when its model list is slow to arrive
    Given Codex's account check succeeds
    And Codex's model list does not arrive before the check's deadline
    When the user opens the provider list
    Then Codex is shown as signed in with a warning
    And the last model list Codex gave is still offered

  # Upstream #19154: a bare Codex binary passed its probes while every Code Mode call failed.
  @backlog @priority-low
  Scenario: A Codex on the path without its Code Mode host is passed over for the managed install
    Given the codex command on the MC's path has no "codex-code-mode-host" beside it
    When the MC picks the Codex to run
    Then it runs the managed Codex installation instead

  # Upstream #22308: a failed managed Codex download was reported as a disk problem.
  @backlog @priority-low
  Scenario Outline: A managed Codex download that fails over the network says to check the connection
    Given the MC is installing its managed Codex
    When the download <failure>
    Then the installation fails asking the user to check their internet connection
    And the user is not told to check disk space

    Examples:
      | failure                         |
      | is cut off part way             |
      | is answered with HTTP 404       |
      | is still running at 45 minutes  |

  # Upstream #30004: a raised managed Codex pin never reached existing installs, and the old
  # Codex compacted after every tool call on a model its catalog did not know.
  @backlog @priority-high
  Scenario: A managed Codex older than the MC's pinned version is updated in the background
    Given the managed Codex installed is older than the version the MC pins
    When the MC starts
    Then the pinned version is installed in the background
    And threads keep running on the installed Codex until the new one is verified and takes over
    And a failed update leaves the installed Codex in place

  Scenario: Codex signed in with an API key says so
    Given Codex is signed in with an OpenAI API key
    When Codex's usage has been checked
    Then Codex shows that it uses an OpenAI API key

  # A ChatGPT account signed in through HAL-C2 rather than the Codex CLI. Its credentials
  # move to the environment the user picks; the primary environment runs the sign-in.
  # Contradicts provider-setup.feature "Only providers that support it sign in from HAL-C2"
  # (Codex "does not sign in here"), which is untagged and passes today. Reconcile when
  # this backlog item is cleared.
  @backlog @mc
  Scenario: Codex connects a ChatGPT account from HAL-C2 without a Codex CLI login
    Given the user has a ChatGPT plan and Codex is not signed in on the environment
    When the user connects ChatGPT to Codex
    And the user approves the sign-in with OpenAI
    Then Codex on the environment is signed in with that account

  @backlog @mc
  Scenario: A ChatGPT account connected on one environment can be moved to another
    Given the user connected a ChatGPT account on the primary environment
    When the user chooses another environment for that Codex account
    Then the other environment's Codex is signed in with the account

  @backlog @mc
  Scenario: Disconnecting a ChatGPT account signs its Codex out
    Given Codex is connected with a ChatGPT account
    When the user disconnects the account
    Then Codex on that environment is no longer signed in with it

  # Upstream #23160: a signed-out HAL-C2-managed Codex can switch to the Codex CLI's own login from Settings.
  @backlog @shared @mc
  Scenario: A signed-out managed Codex can switch to the Codex CLI's own login
    Given a Codex instance whose ChatGPT account was connected through HAL-C2
    And its account is remembered but no longer signed in
    When the user chooses to use the existing Codex CLI in its provider settings
    Then the instance uses the Codex CLI's own login from then on

  @backlog @shared @priority-low
  Scenario: A connected ChatGPT account's email is hidden until the user reveals it
    Given Codex is connected with a ChatGPT account
    Then the account's email is not shown
    When the user asks to show it
    Then the email is shown

  @backlog @shared @priority-low
  Scenario: The first ChatGPT connection explains that plan usage counts against the plan
    Given the user has never connected a ChatGPT account
    When the user connects one
    Then HAL-C2 explains that using Codex counts against the ChatGPT plan's usage

  # Upstream #30322: a ChatGPT account connected through HAL-C2 has no service tier choices, and
  # the model picker did not say why Fast was missing.
  @backlog @shared @priority-low
  Scenario: A ChatGPT account connected through HAL-C2 explains why Fast is not offered
    Given Codex uses a ChatGPT account connected through HAL-C2
    When the user opens the model picker
    Then the picker says the plan connection offers no faster service tiers
    And it points to using the Codex CLI's own login to get them
    And the explanation can be read by focusing it from the keyboard

  # Upstream #29280: a rejected ChatGPT sign-in left a saved connection the user could reconnect
  # but never remove.
  @backlog @mc @shared
  Scenario: A ChatGPT connection whose sign-in never finished can be removed
    Given Codex has two ChatGPT connections whose sign-in was rejected and one signed-in account
    When the user removes one of the unfinished connections
    Then it is gone after a reload, and the other unfinished connection can still be reconnected
    And the signed-in account and its credentials are kept
    And a signed-in account offers no such removal
    When the user removes the last unfinished connection
    Then connecting a new ChatGPT account is offered

  # Upstream #21750: a callback address pasted without its scheme still finishes the sign-in.
  @backlog @mc
  Scenario Outline: A pasted ChatGPT sign-in callback address is checked by where it points
    Given the user is connecting ChatGPT to Codex and the browser could not reach the sign-in callback
    When the user pastes the callback address <pasted>
    Then <outcome>

    Examples:
      | pasted                                                 | outcome                                 |
      | "http://localhost:1455/auth/callback?code=abc"         | the sign-in finishes                    |
      | "localhost:1455/auth/callback?code=abc"                | the sign-in finishes                    |
      | "  localhost:1455/auth/callback?code=abc" with spaces  | the sign-in finishes                    |
      | "localhost:9999/auth/callback?code=abc"                | the address is refused as not the callback |
      | "example.com:1455/auth/callback?code=abc"              | the address is refused as not the callback |

  # Upstream #22541: a patch touching several files listed only the first.
  @mc @shared @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A Codex change to several files lists every file
    When Codex applies one patch that edits "a.ts", adds "b.ts", deletes "e.ts" and renames "c.ts" to "d.ts"
    Then the change in the timeline lists "a.ts", "b.ts", "e.ts" and "d.ts"
    And the rename shows it came from "c.ts"
    And the change shows every file's diff

  Scenario: Codex offers its compact and feedback commands in the composer
    When the user types a slash in a Codex thread
    Then "/compact" and "/feedback" are offered

  # CodexSessionRuntime.ts isRecoverableThreadResumeError: "not found", "missing thread",
  # "no such thread", "unknown thread", "does not exist" and "no rollout found".
  Scenario: A Codex conversation that Codex can no longer find starts a fresh one
    Given a Codex thread whose native conversation Codex has since forgotten
    When the user sends a message
    Then the message runs in a new Codex conversation
    And the thread keeps its history in HAL-C2

  Scenario: A Codex resume that fails for another reason is reported
    Given resuming the Codex thread fails with an error that is not about a missing conversation
    When the user sends a message
    Then the user sees that error
    And no new Codex conversation is started

  # Upstream #21045: a conversation another Codex client held open was silently replaced with a
  # fresh one, leaving its native history behind.
  @backlog @priority-high
  Scenario: A Codex conversation open in another Codex client is not replaced
    Given the Codex app has the thread's Codex conversation open on the same Codex home
    When the user sends a message
    Then the turn fails telling the user to quit the other Codex client and try again
    And no new Codex conversation is started

  Scenario: Ordinary Codex thread sources do not crash a running turn
    When Codex announces a thread with the source "vscode"
    Then the active turn continues without a runtime failure

  Scenario: Codex's memory consolidation is not shown as a subagent
    When Codex consolidates its memories in the background during a turn
    Then the thread shows no subagent for it
    And its activity does not appear in the thread's work log

  # Likely already implemented: apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (collaborationMode)
  Scenario: Codex is told its mode on every turn
    Given a Codex thread that was in plan mode and is resumed in default mode
    When the user sends a message
    Then Codex is told it is in default mode and that plan mode no longer applies

  Scenario: The orchestration instructions are given to Codex in default mode only
    Given the "hal-c2" server is attached to a Codex thread
    When the user sends a message in plan mode and then one in default mode
    Then Codex receives HAL-C2's orchestration instructions with the second message only

  # Upstream #18415: Codex threads get the whole orchestration instructions
  Scenario: Codex receives the whole orchestration instructions
    Given a Codex thread in default mode
    When its first turn starts
    Then Codex is given every part of HAL-C2's orchestration instructions
    And none is cut away by Codex's limit on the length of one instruction

  # Upstream #13547: a model catalog's own default-mode text replaced the instructions sent
  # inside the collaboration mode, so HAL-C2's details went missing on newer models.
  Scenario: A model whose catalog replaces default mode still gets HAL-C2's runtime details
    Given the "hal-c2" server is attached to a Codex thread on a model whose catalog replaces default mode
    When the user sends a message in default mode
    Then Codex is told the runtime, the model's name and slug, and the PR linking rules

  # Upstream #24737: copies of Codex's own Plan and Default prompts drifted from the installed
  # Codex, and a Default turn without the HAL-C2 server never left an earlier Plan mode.
  Scenario: Codex brings its own plan and default mode instructions
    When the user sends a message in plan mode on a Codex thread
    Then the turn names Codex's plan collaboration mode
    And HAL-C2 sends no copy of Codex's mode instructions of its own

  # Upstream #24737: a Default turn without the HAL-C2 server never left an earlier Plan mode.
  Scenario: A default-mode turn leaves plan mode even without the HAL-C2 server
    Given a Codex thread without the "hal-c2" server whose last turn was in plan mode
    When the user sends a message in default mode
    Then the turn names Codex's default collaboration mode
    And Codex may edit files again

  # Upstream #13547: Codex drops additionalContext when it compacts, and resends an entry
  # only once its value changes.
  Scenario: Codex gets HAL-C2's runtime and tool instructions again after compacting the thread
    Given the "hal-c2" server is attached to a Codex thread
    When Codex compacts the thread's context
    Then the next message carries HAL-C2's runtime and tool instructions again

  # Upstream #17265: unfinished Codex compactions settle when their turn ends; failed and stopped labels win.
  @shared @backlog-desktop @backlog-mobile @backlog-tui
  Scenario Outline: A compaction Codex never finished ends with its turn
    Given Codex started compacting the thread and never reported the compaction finished
    When the turn <ends>
    Then the compaction no longer reads as running
    And it reads "<label>"

    Examples:
      | ends                   | label   |
      | is stopped by the user | Stopped |
      | fails                  | Failed  |

  # Upstream #27399: a Codex hook that stopped the turn on purpose left only "Stopped by the provider".
  @backlog @shared
  Scenario: A turn a Codex hook stopped says why
    Given a Codex hook stops the running turn with the reason "Run /handoff before compacting"
    When Codex ends the turn as interrupted
    Then the turn reads as stopped with "Run /handoff before compacting"

  # Upstream #27399
  @backlog
  Scenario: The user's own stop reason wins over a Codex hook's
    Given a Codex hook stopped the running turn with a reason
    When the user stops the turn as well
    Then the turn reads as stopped by the user

  Scenario: Codex is not told about browser or device tools it does not have
    Given the "hal-c2" server is attached to a Codex thread without browser or device tools
    When the user sends a message
    Then Codex's instructions do not describe browser or device tools

  # codexLaunchArgs.ts: the variable overrides the instance's arguments, and text generation
  # (codex exec) takes over only the configuration and feature flags among them.
  Scenario: A launch arguments variable on the MC overrides the instance's arguments
    Given the MC's environment sets HAL_C2_CODEX_LAUNCH_ARGS
    And the Codex instance has other launch arguments configured
    When a Codex session starts
    Then Codex is started with the variable's arguments only

  # The outline "Codex launch arguments apply wherever Codex is started" configures only
  # configuration arguments; this one adds a session-only flag. The MC already filters them
  # (HalC2.Codex.Provider.exec_args/1 from text_generation.ex); it waits for its steps.
  Scenario: Codex's title writer leaves out the launch arguments only a Codex session takes
    Given the Codex instance has the launch arguments "--config model_provider=local --enable web_search --full-auto"
    When Codex writes a title for a new thread
    Then the title writer is started with "--config model_provider=local" and "--enable web_search"
    And "--full-auto" is left out

  # CodexToolPresentation.ts: how Codex's browser and computer tools appear in the work log.
  # The MC serves app icons (mc/platform/attachments-and-assets.feature); nothing yet derives
  # the surface, source and icon of a Codex tool call.
  Scenario: Codex's browser tool calls are shown as browser work with the page's icon
    When Codex uses its browser tool on "https://example.com/docs"
    Then the work log entry is marked as browser work
    And it shows the page's address and favicon

  Scenario: A page address that is not http or https gets no page icon
    When Codex uses its browser tool on a page whose address is "file:///etc/passwd"
    Then the work log entry shows no page address or favicon

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

  Scenario: Codex's computer tool calls are shown with the application they drive
    When Codex uses its computer tool on the application "Finder"
    Then the work log entry is marked as computer work
    And it names "Finder" and shows its application icon

  Scenario: Computer tool calls on the same application are grouped under one source
    When Codex makes two computer tool calls on the same application
    Then both work log entries are grouped under that application

  Scenario: Codex's computer tool without a named application is called Computer Use
    When Codex uses its computer tool and reports no application
    Then the work log entry names "Computer Use"
    And shows no application icon

  # CodexAdapterV2.ts: what an approval says, how tool calls and searches are shown.
  @mc
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

  # Upstream #24257: a permission request naming only glob or special paths showed as a command approval.
  Scenario Outline: A Codex request for file access by pattern is a file approval
    When Codex asks for extra access to <access> naming only "<path>"
    Then the approval shows as <kind>
    And Codex is answered as before

    Examples:
      | access      | path      | kind                   |
      | write files | /w/out/** | a file change approval |
      | read files  | /w/in/**  | a file read approval   |

  @mc
  Scenario: A Codex approval for many files lists the first 20 and counts the rest
    When Codex asks without a reason to change 23 files
    Then the approval lists the first 20 files in path order
    And it ends with "+3 more"

  # Upstream #18248: Codex's approval request carries no file names, only the change it belongs
  # to; the files come from when Codex started that change.
  Scenario: A Codex approval names the files Codex said it would change
    Given Codex started a change to edit "src/cart.ts" and delete "src/old.ts"
    When Codex asks without a reason to approve that change, naming no files
    Then the approval lists "src/cart.ts" to edit and "src/old.ts" to delete

  @mc
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

  @mc
  Scenario: HAL-C2 introduces itself to Codex by name
    When a Codex session starts
    Then Codex is told the client is "hal_c2_desktop" titled "HAL-C2 Desktop"

  @mc
  Scenario: Codex is asked not to send a diff after every change
    When a Codex session starts
    Then HAL-C2 opts out of Codex's "turn/diff/updated" notifications
    And changed files are still shown from the file changes Codex reports

  @mc
  Scenario: A Codex tool call on an MCP server names the server and the tool
    When Codex calls the tool "search" on the MCP server "docs"
    Then the tool call is shown as "docs.search" with its arguments
    And its result is shown when the call finishes

  @mc
  Scenario: A failed Codex MCP tool call shows the server's error
    When a tool Codex called on an MCP server fails
    Then the tool call is shown as failed with the error the server gave

  @backlog @mc
  Scenario: A new Codex thread waits briefly for MCP servers that are still starting
    Given the user has an MCP server that takes five seconds to start
    When a new Codex thread starts its first turn
    Then Codex waits up to ten seconds for it
    And the server's tools are in the first turn
    But a server that takes longer is left out of the first turn and joins a later one
    And the user can still stop the turn while Codex waits

  @mc
  Scenario Outline: A Codex web search shows what Codex did on the web
    When Codex <action>
    Then the web search entry shows <shown>

    Examples:
      | action                   | shown                              |
      | searches the web         | the queries it searched for        |
      | opens a page             | the address of the page            |
      | looks for text in a page | the text and the page's address    |

  @mc
  Scenario: Leaving auto mode on a Codex thread returns approvals to the user
    Given a Codex thread that ran a turn in auto mode
    When the user changes the thread to approval required and sends a message
    Then Codex is told the user reviews approvals
    And Codex asks the user instead of its automatic reviewer

  @mc
  Scenario: Codex is asked for detailed summaries of its reasoning
    When a Codex turn starts
    Then Codex is asked for detailed reasoning summaries
    And the summaries and any raw reasoning Codex sends are shown as the turn's thinking

  # codexModelOptions.ts: an explicit service tier wins; the older fast mode switch means "fast".
  @mc
  Scenario Outline: A Codex thread runs on the service tier chosen for it
    Given a Codex thread whose model selection has <selection>
    When the user sends a message
    Then the turn is sent to Codex <tier>

    Examples:
      | selection                              | tier                          |
      | the service tier "fast"                | on the "fast" service tier    |
      | fast mode on and no service tier       | on the "fast" service tier    |
      | fast mode off and no service tier      | without naming a service tier |

  @mc
  Scenario: Codex without the HAL-C2 tools is given no HAL-C2 instructions
    Given a Codex thread that has no "hal-c2" server attached
    When the user sends a message in default mode
    Then Codex receives no instructions from HAL-C2 beyond the message

  @mc
  Scenario: A Codex reconnect shows which attempt it is on
    Given a Codex turn is running
    When Codex reports "Reconnecting... 2/5" and says it will retry
    Then the turn shows a retry on attempt 2 of 5
    And the turn keeps running

  @mc
  Scenario: A Codex retry that names no attempt is counted
    Given a Codex turn is running
    When Codex reports twice that it will retry without saying which attempt it is on
    Then the turn shows a retry on attempt 2 with no known maximum

  @mc
  Scenario: A Codex failure shows Codex's fuller explanation when it gives one
    When a Codex turn fails with a short message and additional details
    Then the turn's failure shows the additional details

  @mc
  Scenario: A Codex installed as a Windows command script starts
    Given the MC runs on Windows
    And the codex command is a command script rather than a program
    When a Codex session starts
    Then Codex starts and answers as it does from a program

  @mc
  Scenario: A Codex home that cannot be prepared for an account fails the turn
    Given a Codex instance whose own home cannot be prepared from the shared one
    When the user sends a message
    Then the turn fails with "Failed to materialize the Codex shadow home."
    And Codex is not started against the shared home instead

  @mc
  Scenario: A Codex usage limit learns its reset time when Codex reports it late
    Given a Codex turn stopped on a usage limit before Codex said when the limit resets
    When Codex then reports its usage windows
    Then the stopped turn shows the reset time from those windows

  @mc
  Scenario: A Codex usage limit's reset time does not move once it is known
    Given a Codex turn stopped on a usage limit that resets at 14:00
    When Codex later reports usage windows with another reset time
    Then the stopped turn still says it resets at 14:00

  @mc
  Scenario: Codex repeating its final answer does not show it twice
    When Codex sends the same final answer twice in one turn
    Then the thread shows that answer once

  @mc
  Scenario: An empty second final answer from Codex adds nothing to the thread
    When Codex sends a final answer and then an empty one in the same turn
    Then the thread shows the first answer only

  @mc
  Scenario: Two Codex messages without a phase are both shown
    When Codex sends two messages without a phase with the same text in one turn
    Then the thread shows both messages

  # Upstream #19066: images Codex generated were saved but never shown in the reply.
  @backlog @priority-high
  Scenario: An image Codex generates is shown under its reply
    Given Codex generates an image with its image tool during a turn
    When the turn finishes
    Then the image is shown under Codex's final reply
    And an image the reply already shows is not shown twice

  # Upstream #19066: an image that finished after the turn ended was lost.
  @backlog
  Scenario: An image Codex finishes after its last message still joins the reply
    Given Codex is still generating an image when it sends its final reply
    When the image is saved
    Then the image is shown under that reply

  # Upstream #19066: images saved on a Windows host did not load on other devices.
  @backlog @shared
  Scenario Outline: A Codex image saved on a Windows MC loads on every client
    Given the MC runs on Windows
    And Codex saved a generated image at "<path>"
    When the user reads the reply on the desktop, the phone or the terminal
    Then the image loads

    Examples:
      | path                                  |
      | C:\Users\ana\.codex\images\fox.png    |
      | \\fileserver\share\images\fox.png     |

  # Upstream #23284: an image a Codex tool returned as a data address was saved but not shown.
  @backlog @shared
  Scenario: An image a Codex tool returns is shown with the tool call
    Given a Codex tool call returns an image as embedded image data
    When the user expands the tool call
    Then the image is shown
    And no image data text is shown

  # Upstream #23388: newer Codex builds send partial answers, which were dropped.
  @backlog
  Scenario: A partial answer from Codex is kept apart from its final answer
    When Codex sends a partial answer and then a final answer with the same text in one turn
    Then the thread keeps the partial answer
    And the final answer is shown once

  # Upstream #23388: a Codex history holding a partial answer could not be read.
  @backlog @priority-high
  Scenario Outline: The user <action> a Codex thread whose history holds a partial answer
    Given a Codex thread's history holds a partial answer
    When the user <action> the thread
    Then it succeeds with the whole history

    Examples:
      | action  |
      | forks   |
      | resumes |
      | reads   |

  @mc
  Scenario: A Codex question with blanks is still askable
    When Codex asks a question with no heading, no text and unlabelled choices
    Then the question is shown under "Question" asking "Choose an answer."
    And its choices are labelled "Option 1", "Option 2" and so on

  @mc
  Scenario: A request from a Codex tool that HAL-C2 cannot show is declined
    When a tool's server asks the user for something HAL-C2 has no way to present
    Then the request is declined without asking the user
    And the turn goes on

  @mc
  Scenario: A tool's request that arrives when no turn is running is declined
    Given no Codex turn is running in the thread
    When a tool's server asks the user for access
    Then the request is declined without asking the user

  @mc
  Scenario: Resuming a Codex thread does not load its whole history
    Given a Codex thread with a long conversation
    When the MC resumes it to run a new message
    Then Codex is asked to resume without sending back its earlier turns

  @mc
  Scenario: A Codex turn that finishes while it is being stopped is recorded as interrupted
    Given the user stopped a running Codex turn
    When Codex reports the turn completed before it acknowledges the stop
    Then the turn ends as interrupted

  @mc
  Scenario: Stopping a Codex turn that has not started yet waits for it to start
    Given a Codex turn was sent and Codex has not started it yet
    When the user stops the turn
    Then the stop is delivered as soon as Codex starts the turn

  @mc
  Scenario: A queued Codex turn that never starts cannot be stopped
    Given a Codex turn was sent and Codex does not start it
    When the user stops the turn and 10 seconds pass
    Then the stop fails with "Codex did not start the queued turn within 10 seconds; Stop could not be delivered."

  @mc
  Scenario: A Codex turn that does not stop within 10 seconds is settled as interrupted
    Given the user stopped a running Codex turn
    When Codex has not ended the turn after 10 seconds
    Then the turn ends as interrupted
    And what Codex sends for that turn afterwards is not added to the thread

  @mc
  Scenario: A Codex tool call marked persistent outlives its turn
    Given Codex started a tool call marked persistent and another that is not
    When the turn completes with both still open
    Then the other tool call is closed with the turn
    And the persistent tool call stays running

  @mc
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

  @mc
  Scenario: A Codex subagent's thread opens with the task it was given
    When Codex starts a subagent with a task
    Then the subagent's thread starts with that task as its first message
    And the subagent's final answer is shown as its result on the parent's turn

  @mc
  Scenario: A Codex subagent's commentary is not taken for its result
    When a Codex subagent sends commentary and then a final answer
    Then the subagent's result is the final answer

  @mc
  Scenario: A later message Codex sends a subagent appears in the subagent's thread
    Given a Codex subagent that finished its first task
    When Codex sends the subagent another message
    Then the message appears in the subagent's thread as coming from the parent
    And the subagent is shown as running again

  @mc
  Scenario: A late report does not reopen a finished Codex subagent
    Given a Codex subagent that completed
    When Codex reports an older state for that subagent
    Then the subagent stays completed

  # Upstream #25322: stopping the subagent's late turn waited on its own reply and froze every Codex thread for 10 seconds.
  @backlog @mc @priority-high
  Scenario: A subagent turn that starts after its parent stopped does not hold up other Codex threads
    Given a Codex run was stopped while one of its subagents was still working
    And another Codex thread shares the same app-server
    When the subagent starts another turn and HAL-C2 stops it
    Then the other thread keeps receiving its events without a pause

  # Upstream #29168: the wake text cut the command at 200 and its output at 1,000 UTF-16 units, so an
  # emoji at a cut left a lone surrogate, Codex never answered the turn start, and the wake hung.
  Scenario: A background command whose output is cut through an emoji still wakes the agent
    Given a Codex agent started a background command that finishes after the turn settled
    And its command or the start of its output's last 1,000 characters falls inside an emoji
    When the command finishes
    Then the agent is woken with the command and its output tail, cut before or after the emoji, not through it
    And the wake turn starts and finishes

  # Upstream #28040: an error code missing from the schema made Codex's failure notifications
  # undecodable, so the run stayed running with no error.
  Scenario: A Codex turn that fails with an error code HAL-C2 does not know fails
    Given a ChatGPT-account Codex rejects the thread's model with the code "modelNotFound"
    When the user sends a turn
    Then the turn fails with Codex's message
    And the thread does not stay working

  # Upstream #23840: a parent that ended its turn stayed idle when its native subagent finished
  # later, until the user sent a message.
  Scenario: A Codex subagent that finishes after its parent's turn wakes the parent
    Given a Codex turn started a subagent and then finished
    When the subagent finishes
    Then the parent thread starts a turn with the subagent's result
    And the result is kept in the parent's history

  # Upstream #23840: a finished native subagent does not wake a parent that was interrupted, is still
  # running a turn, or is itself a subagent.
  Scenario Outline: A finished Codex subagent does not wake a parent that <case>
    Given a Codex subagent whose parent <case>
    When the subagent finishes
    Then the parent does not start another turn for it

    Examples:
      | case                         |
      | was interrupted by the user  |
      | is still running a turn      |
      | is itself a Codex subagent   |

  # Upstream #21787: a running Codex kept its launch-time sign-in and failed with expired tokens
  # once the saved sign-in was renewed.
  @backlog @priority-low
  Scenario: A Codex turn keeps working after its ChatGPT sign-in is renewed
    Given a Codex turn is running on a ChatGPT sign-in
    When the sign-in's token expires and is renewed
    Then the same turn carries on with the renewed sign-in
    And a sign-in to another account is not used by that Codex

  @mc
  Scenario: Stopping a Codex turn stops its subagents
    Given a Codex turn with two subagents at work
    When the user stops the turn
    Then both subagents' turns are stopped
    And both subagents are shown as interrupted

  # Upstream #21366: a failed root turn ends its run at once while its subagents carry on in their
  # own threads; an interrupted turn still waits, since Stop interrupts the subagents too.
  Scenario: A failed Codex turn does not hold the thread for its subagents
    Given a Codex turn with two subagents at work
    When the turn fails while the subagents keep working
    Then the run ends as failed and the subagents carry on
    And the thread no longer shows the agent thinking
    And the next message the user sends starts a new turn instead of waiting in the queue

  @mc
  Scenario: A Codex subagent that starts work under a stopped turn is interrupted
    Given a Codex turn that was stopped
    When one of its subagents starts another turn
    Then that subagent's turn is interrupted at once

  # packages/effect-codex-app-server: the wire contract with the Codex app-server.
  @mc
  Scenario: A request from Codex that HAL-C2 does not know is refused, not left hanging
    When Codex sends a request with a method HAL-C2 does not handle
    Then Codex receives error -32601 "Method not found:" followed by the method
    And the turn goes on

  @mc
  Scenario: Codex cannot pile up more than 32 open requests on the MC
    Given 32 requests from Codex are waiting on the user
    When Codex sends another request
    Then Codex receives error -32001 "Too many Codex requests are already active."
    And the 32 waiting requests are unaffected

  # Upstream #23234: each stop over a waiting approval held one of Codex's 32 request slots forever.
  @backlog @mc @priority-high
  Scenario: Approvals still reach the user after many Codex turns were stopped while waiting
    Given 32 Codex turns on one Codex instance were stopped while an approval waited
    When a Codex turn in another thread asks for an approval
    Then the approval is shown to the user

  # Upstream #23234: Codex settling a request frees the MC's wait on it.
  @mc
  Scenario: A request Codex settles itself is no longer waited on
    Given the MC is waiting on the user for a Codex approval
    When Codex reports that the request is resolved
    Then the MC stops waiting on it without answering Codex
    And answering that approval afterwards fails as no longer pending

  @mc
  Scenario: A message from Codex that HAL-C2 cannot read does not end the turn
    Given a Codex turn is running
    When Codex sends a notification in a shape HAL-C2 does not know
    Then the notification is skipped
    And the turn goes on with the messages that follow

  @mc
  Scenario Outline: Codex's messages are read whole however they arrive
    When Codex's output arrives <how>
    Then each message is read once and complete

    Examples:
      | how                                        |
      | with one message split across two reads    |
      | with several messages in one read          |
      | with Windows line endings                  |
      | with blank lines between messages          |

  @mc
  Scenario: Codex writing a lot to its error output does not stall the turn
    Given a Codex turn is running
    When Codex writes more to its error output than the system buffers
    Then Codex keeps running and the turn goes on

  @mc
  Scenario: A request to Codex that is open when Codex exits fails instead of hanging
    Given the MC is waiting on Codex for an answer
    When Codex exits with code 1
    Then the request fails with "Codex App Server process exited with code 1"

  # Upstream #23938: Codex exiting before it started showed only its exit code.
  @backlog @priority-high
  Scenario: Codex that exits before it starts says why
    Given the Codex command exits with code 1 after printing "Error: Missing optional dependency @openai/codex-darwin-arm64"
    When the MC checks Codex or starts a turn with it
    Then the provider status and the failed turn both end with "Error: Missing optional dependency @openai/codex-darwin-arm64"

  # Upstream #24600: requests hung when Codex closed its output but kept running.
  @backlog @priority-high
  Scenario: A request to Codex fails soon after Codex closes its output while still running
    Given the MC is waiting on Codex for an answer
    When Codex closes its output and keeps running
    Then within a quarter of a second the request fails saying Codex's input ended
    And an exit Codex reports within that time keeps its code

  @mc
  Scenario: Output from Codex that is not a protocol message ends the session
    Given a Codex turn is running
    When Codex writes a line to its output that is not a protocol message
    Then the connection to Codex is closed
    And the turn fails instead of waiting on Codex

  @mc
  Scenario: Accounts sharing a Codex home keep their own login
    Given a shared Codex home and a second Codex instance with its own shadow home
    When the second instance is prepared
    Then its login and its model cache are its own files and are never linked to the shared home
    And its logs, memories and temporary files stay in its own home
    And everything else in the shared home is reached through links

  @mc
  Scenario: A Codex account's home repairs links that point to the wrong place
    Given a Codex instance's shadow home has a link that no longer points into the shared home
    When the instance is prepared
    Then the link points into the shared home again
    And folders the shared home was missing are created

  @mc
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

  # Upstream #18991: Finder metadata no longer blocks shadow-home setup
  Scenario: A Finder ".DS_Store" does not stop a Codex account's home being set up
    Given a Codex account's home folder holds only a ".DS_Store" file left by Finder
    When the account is set up
    Then its home is set up as if the folder were empty

  # Upstream #17663: Codex 0.160 writes the lock at its home's root; a shadow home used
  # on its own kept a real one and the instance stayed disabled.
  Scenario: A Codex account's own sqlite maintenance lock is replaced by the shared one
    Given a Codex instance's shadow home holds its own ".sqlite-maintenance.lock" file
    When the instance is prepared
    Then the lock is replaced by a link to the shared home's lock
    And the instance is enabled

  # Upstream #26286: Codex 0.165 keeps one writer per thread through lock files in
  # "thread-writer-locks"; a shadow home with its own folder let two Codex processes write one thread.
  Scenario: Accounts sharing a Codex home share its thread writer locks
    Given a shared Codex home and a second Codex instance with its own shadow home
    When the second instance is prepared
    Then its "thread-writer-locks" folder is a link to the shared home's

  # Upstream #26286: a lock still in the shadow home's own folder may belong to a live writer.
  Scenario Outline: A Codex account's own thread writer locks are replaced only when no thread is locked
    Given a Codex instance's shadow home has its own "thread-writer-locks" folder holding <locks>
    When the instance is prepared
    Then <outcome>
    And the instance is enabled

    Examples:
      | locks          | outcome                                                                        |
      | no thread lock | the folder is replaced by a link to the shared home's                          |
      | a thread lock  | the folder is kept with a warning, and replaced once its locks are gone        |

  # Upstream #26286: Codex 0.166 guards its login with "auth.lock", which is each account's own.
  Scenario: A Codex account's login lock is its own
    Given a Codex instance's shadow home has "auth.lock" as a link to the shared home's
    When the instance is prepared
    Then the link is removed and the account keeps its own "auth.lock"
    And the instance is enabled

  @mc
  Scenario: Codex skills that cannot be read in 20 seconds are reported
    Given Codex does not answer when asked for the project's skills
    When 20 seconds pass
    Then reading the skills fails naming the project folder
    And the provider's status is not held up by it

  @mc
  Scenario: A slow model manifest does not delay Codex's status
    Given the model manifest cannot be fetched
    When the MC checks Codex
    Then Codex's status is reported from the manifest the MC already has

  # Statuses are the MC's: broken, unsupported, graceful (shown as limited), supported or unknown.
  # Prereleases and versions no range names stay unknown.
  Scenario Outline: The version Codex runs decides whether this HAL-C2 release supports it
    Given Codex version "<version>" is installed
    When the MC checks Codex
    Then Codex is reported as "<status>" for this HAL-C2 release

    Examples:
      | version         | status  |
      | 0.128.0         | broken  |
      | 0.129.0-alpha.1 | unknown |

  # The floor follows T3 Code's Codex policy (its #13481). Below 0.149 Codex does not send
  # Thread.projectId, so no session can start and the version is broken. 0.149 to 0.155 are
  # outside the supported range.
  Scenario Outline: The Codex version sets its support level for this HAL-C2 release
    Given Codex version "<version>" is installed
    When the MC checks Codex
    Then Codex is reported as "<status>" for this HAL-C2 release

    Examples:
      | version | status      |
      | 0.129.0 | broken      |
      | 0.148.0 | broken      |
      | 0.149.0 | unsupported |
      | 0.155.0 | unsupported |
      | 0.156.0 | supported   |

  # Upstream #21443: a Codex too old for app-server failed its probe with no version, so no advisory.
  @mc
  Scenario: A Codex too old to start its app-server still reports its version
    Given the installed Codex prints version "0.1.4161006"
    And Codex exits with code 1 when its app-server starts
    When the MC checks Codex
    Then Codex is reported as "broken" for this HAL-C2 release with version "0.1.4161006"
    And the user is offered the update before the probe's failure message

  # Upstream #21443: the version is read the same way when the probe fails.
  @mc
  Scenario Outline: A Codex whose app-server fails reports what its version command says
    Given Codex exits with code 1 when its app-server starts
    And its version command <answer>
    When the MC checks Codex
    Then Codex is reported as "<status>" with <version>

    Examples:
      | answer                             | status  | version                   |
      | prints "codex-cli 0.159.0-alpha.1" | unknown | version "0.159.0-alpha.1" |
      | exits with code 1                  | unknown | no version                |
      | does not answer within 4 seconds   | unknown | no version                |

  # Upstream #27281: a broken Codex version failed turns with a protocol decode error.
  Scenario: A turn on a broken Codex version says to update Codex
    Given the installed Codex is version "0.144.3", which this HAL-C2 release marks broken
    When the user sends a turn to Codex
    Then the turn fails with "Codex 0.144.3 does not work with this HAL-C2 release. Update Codex to >=0.159.0, then retry."

  # Upstream #27281: after updating Codex, the next message in the same thread runs on it.
  Scenario: The next message after updating a broken Codex runs on the new version
    Given a turn failed because the installed Codex version is broken
    And the user updated Codex to a supported version
    When the user sends another message in the same thread
    Then the turn runs on the updated Codex

  Scenario: A thread whose Codex session was archived outside HAL-C2 resumes it
    Given the native Codex session of a thread was archived by Codex itself
    When the user sends a turn
    Then the MC unarchives that same session and resumes it once
    And an unrelated resume error is shown as it is

  # Upstream #29582: rollback resumed an unloaded Codex thread without the archived-session recovery
  # sending a message had, so the whole restore failed and no files came back.
  Scenario: A checkpoint restores after the thread's Codex session was archived outside HAL-C2
    Given the native Codex session of a thread was archived by Codex itself
    And Codex no longer has the thread loaded
    When the user restores the thread to an earlier checkpoint
    Then the MC unarchives that same session, and the conversation and files are restored

  # Upstream #29618: forking sent the fork straight to the archived session and failed, though
  # resuming it already unarchived and retried.
  Scenario: Forking a thread whose Codex session was archived outside HAL-C2
    Given the native Codex session of a thread was archived by Codex itself
    When the user forks the thread
    Then the MC unarchives that session and the fork starts with the thread's conversation

  @backlog @mc @plugin-codex @priority-high
  Scenario: Stop ends a Codex command after its thread was settled
    Given Codex left a command running and the thread was settled
    And Codex has since unloaded the thread
    When the user presses Stop
    Then the command counts as already stopped
    And the running banner clears

  # Upstream #19936: a dead command stayed running after Codex closed its native thread.
  Scenario: A Codex command left running is interrupted when Codex closes the thread
    Given Codex left a command running in a finished turn
    When Codex closes its native thread
    Then the command is shown as interrupted
    And the turn stays completed
    And a late completion for that command does not bring it back

  @backlog @mc @shared @plugin-codex
  Scenario Outline: /goal drives Codex's own goal
    When the user sends "<input>" in a Codex thread
    Then the thread uses Codex's goal for it
    And while a goal is active, Codex's follow-up turns stay in the same run and the thread stays Working

    Examples:
      | input                |
      | /goal ship the fix   |
      | /goal pause          |
      | /goal resume         |
      | /goal clear          |
      | /goal                |

  # Upstream #25426: a Codex goal that Codex does not continue within its window is paused as the run ends.
  @backlog @shared
  Scenario: A Codex goal Codex does not continue is paused when the run ends
    Given a Codex thread is working toward a goal
    When the run ends and Codex does not continue the goal within five seconds
    Then the goal shows as paused
    And a turn Codex starts for it later is stopped

  # Upstream #25426: setting a Codex goal flashed "Goal paused", and its first turn got the bare objective.
  @backlog @priority-low
  Scenario: Setting a Codex goal starts work on it without a paused flash
    When the user sends "/goal ship the fix" in a Codex thread
    Then the goal never shows as paused while it starts
    And Codex is asked to start working toward "ship the fix"

  # Upstream #23033: an oversized objective reached Codex as a generic start failure, and retrying it
  # could clear the previous goal first.
  @backlog @shared
  Scenario: A goal over Codex's 4,000-character limit is refused before Codex is asked
    Given a Codex thread is working toward "ship the fix"
    When the user sends "/goal" with an objective of 4,100 characters
    Then the turn fails saying the objective has 4,100 characters and must be at most 4,000
    And the message stays in the thread
    And the thread is still working toward "ship the fix"

  Rule: An MCP app a Codex tool returns runs inside the thread

    # Upstream #16236: a tool result pointing at a ui:// resource is an MCP app.
    @backlog @shared
    Scenario: An MCP app opens inline in the thread
      Given a Codex tool call returned an MCP app
      When the user looks at the tool call
      Then the app is shown and running in the thread
      And the user can open it full screen and close it again

    # Upstream #25225: Codex marks a write deferred to an app's form as a failed tool result.
    @backlog @shared
    Scenario: An MCP app from a tool call marked failed is still shown
      Given a Codex tool call returned an MCP app with a result marked as an error
      When the user looks at the tool call
      Then the app is shown and running in the thread
      And the tool call still shows that it failed

    @backlog @shared
    Scenario Outline: An MCP app asks before it does anything that is not reading
      Given an MCP app is open in a Codex thread
      When the app <action>
      Then the user is asked to approve it first

      Examples:
        | action                                  |
        | calls a tool that is not read only      |
        | sends a message to the thread           |
        | downloads a file                        |

    @backlog @shared @priority-low
    Scenario: What an MCP app tells the model goes with the next message
      Given an MCP app in a Codex thread gave the model some context
      When the user sends the next message
      Then that context goes with it, cut to 16 KiB
      And a fork of the thread keeps it and a rollback past it drops it

    @backlog @shared @priority-low
    Scenario: An MCP app in a thread whose session stopped says so
      Given the Codex session of a thread with an MCP app has stopped
      When the user opens the app
      Then the app says the session has stopped
      And no session is started for it

    @backlog @priority-low
    Scenario: Deleting a thread removes its MCP apps' documents
      Given a Codex thread with an MCP app
      When the user deletes the thread
      Then the app's stored documents are removed with it

    # Upstream #17026: a Confluence result's canvas stayed white under dark text.
    @backlog @shared @mc @priority-low
    Scenario: An MCP app follows the app's light or dark appearance
      Given an MCP app is open in a Codex thread
      When the user switches the app between light and dark
      Then the MCP app's page and its text follow the appearance
      And an MCP app stored in the thread before this works the same

    # Upstream #17027: Jira's app threw on reading cookies in its sandbox and vanished.
    @backlog @shared @mc @priority-low
    Scenario: An MCP app that reads cookies in its sandbox still shows
      Given a Codex tool call returned an MCP app that reads its cookies while it starts
      When the user looks at the tool call
      Then the app is shown with its content
      And the app sees no cookies and keeps none it sets

    # Upstream #18548: an app went full screen on load and again right after the user left it.
    @backlog @desktop @mobile @priority-high
    Scenario: An MCP app goes full screen only after the user taps inside it
      Given an MCP app is open in a Codex thread
      When the app asks to go full screen without the user touching it
      Then the app stays in the thread
      When the user taps inside the app and it asks again
      Then the app opens full screen
      And the user can always leave full screen, and the app cannot go back without another tap

    # Upstream #17040: a short card left a large gap under a fixed 420 point frame.
    @backlog @mobile @priority-low
    Scenario Outline: An MCP app in a thread on the phone is as tall as its content
      Given an MCP app in a Codex thread reports content <height> points tall
      When the user reads the thread on the phone
      Then the app's card is <shown> points tall

      Examples:
        | height | shown                              |
        | 150    | 150                                |
        | 900    | 420, and the app scrolls inside it |
