# Sources:
#   https://github.com/pingdotgg/t3code/pull/24605
#   https://github.com/pingdotgg/t3code/pull/24609
#   https://github.com/pingdotgg/t3code/pull/20881
#   https://github.com/pingdotgg/t3code/pull/22849
#   https://github.com/pingdotgg/t3code/pull/20180
#   https://github.com/pingdotgg/t3code/pull/18772
#   https://github.com/pingdotgg/t3code/pull/18771
#   https://github.com/pingdotgg/t3code/pull/20358
#   https://github.com/pingdotgg/t3code/pull/19938
#   https://github.com/pingdotgg/t3code/pull/18075
#   https://github.com/pingdotgg/t3code/pull/13328
#   https://github.com/pingdotgg/t3code/pull/10607
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/13523 (one-click updates through `grok update`)
#   apps/server-ex/lib/hal_c2/acp.ex (grok agent, permission-mode args, supportsTextGeneration)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (permission requests, session/cancel, background tasks and subagents)
#   apps/server-ex/lib/hal_c2/usage/transcripts.ex (Grok transcripts)
#   apps/server/src/provider/Layers/GrokProvider.ts, apps/server/src/provider/Drivers/GrokDriver.ts, apps/server/src/provider/acp/GrokAcpSupport.ts
#   apps/server/src/orchestration-v2/Adapters/GrokAdapterV2.ts, apps/server/src/provider/Drivers/GrokSkills.ts
#   apps/server/src/provider/Layers/grokUsageLimits.ts, apps/server/src/textGeneration/GrokTextGeneration.ts
#   apps/server/src/provider/acp/XAiAcpExtension.ts, apps/server/src/orchestration-v2/Adapters/XAiBackgroundTasks.ts
#     (x.ai/task_backgrounded, x.ai/task_completed, background subagent notices, persistent monitors)
#   apps/server/src/provider/acp/XAiBackgroundTasks.ts (how background tasks are listed and ended)
#   https://github.com/pingdotgg/t3code/pull/14486
#   https://github.com/pingdotgg/t3code/pull/22709
#   https://github.com/pingdotgg/t3code/pull/24246

@plugin-grok @mc @priority-low
Feature: Grok
  Grok runs the local grok CLI as an ACP agent. Sign-in stays with the Grok CLI, or with
  an xAI API key in the instance's environment.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Grok does nothing until the user enables it
    Given Grok is installed but not enabled
    When the MC starts
    Then no Grok process is started

  Scenario: Grok is only offered when the grok command is installed
    Given the grok command is not installed on the MC
    When the user opens the list of agents to enable
    Then Grok is not offered

  Scenario: Enabling Grok lists the models it offers
    Given the grok command is installed and signed in
    When the user enables Grok
    Then Grok's models are offered in the model picker

  # Upstream #22849: every Grok refresh added back cached models the CLI no longer advertised,
  # so a model gateway's models stayed listed after Grok was disconnected from it.
  @backlog @mc @plugin-grok @priority-low
  Scenario: A Grok refresh drops models Grok no longer offers
    Given Grok offered the models of a model gateway
    And Grok was disconnected from the gateway
    When the user refreshes Grok
    Then only the models Grok now offers are in the model picker

  # Upstream #22849
  @backlog @mc @plugin-grok @priority-low
  Scenario Outline: A Grok check that finds no models keeps the last known ones with a warning
    Given Grok offered four models
    When the MC checks Grok and <result>
    Then Grok shows a warning
    And the four models are still offered

    Examples:
      | result                         |
      | Grok lists no models           |
      | Grok fails to start a session  |

  Scenario: A signed-out Grok says so
    Given the grok command is installed but not signed in
    When the user enables Grok
    Then Grok is shown as signed out with a hint to sign in

  # Upstream #20358: a logged-out Grok probe is checked once more before Grok is reported signed out.
  @backlog
  Scenario: A Grok refreshing its sign-in is not reported signed out
    Given Grok's sign-in expired and Grok is refreshing it
    When the MC checks Grok and is told Grok is signed out
    Then the MC checks once more
    And Grok is reported signed in

  Scenario: Grok permission requests become approvals
    Given the thread runs Grok with approval required
    When Grok asks to run a command
    Then the user is asked to approve it
    And the user's decision is sent back to Grok

  Scenario: Stopping a Grok turn cancels it in Grok
    Given a Grok turn is running
    When the user stops the turn
    Then Grok is told to cancel the turn

  Scenario: Grok writes thread titles and commit messages
    Given Grok is picked for text generation
    When a new thread needs a title
    Then Grok writes it with every tool refused

  Scenario: Grok transcripts count toward usage
    Given Grok has written transcripts on this machine
    When the user opens the usage summary
    Then Grok's tokens and cost are included

  Scenario: An xAI API key in the instance's environment signs Grok in
    Given the Grok instance has an xAI API key in its environment
    When the user opens the provider list
    Then Grok shows that it uses an xAI API key

  # Grok's own installer owns the binary, so its own updater is the update command.
  # Upstream #13523: Grok is updated through `grok update`
  @backlog
  Scenario: An outdated Grok is offered an update through Grok's own updater
    Given Grok was installed by its own installer and a newer version is released
    When the MC checks provider versions
    Then Grok is reported behind the latest version with an update command

  # Upstream #13523: Grok is updated through `grok update`
  @backlog
  Scenario: Updating Grok runs its updater against the home its instance uses
    Given Grok was installed by its own installer and this Grok instance has its own Grok home
    When the user updates Grok
    Then Grok's updater runs against that home and not the default one
    And Grok is reported current

  # Upstream #24246: with npm 12 an npm-installed Grok's update succeeded but skipped the step that
  # installs the new binary, so the old Grok kept running.
  @backlog
  Scenario: Updating an npm-installed Grok installs its new binary
    Given Grok was installed with npm 12 and a newer version is released
    When the user updates Grok
    Then the new Grok binary is installed
    And Grok is reported current

  # Upstream #18772: a Homebrew-cask Grok is compared against the cask and upgraded with brew.
  @backlog
  Scenario: A Grok installed as a Homebrew cask is updated through that cask
    Given Grok's executable lives in the Homebrew cask that installed it
    When the user opens Grok's update details
    Then Grok is compared against the version that cask would install
    And the update command upgrades that cask through Homebrew and not Grok's own updater

  # Upstream #18772: a cask the MC cannot prove owns Grok is left to the user.
  @backlog
  Scenario: A Grok in a Homebrew cask that cannot be proven is updated by hand
    Given Grok's executable sits in a Homebrew cask under a different prefix than the brew on the path
    When the user opens Grok's update details
    Then no update command is offered for Grok

  # A binary that cannot be resolved is never handed to an updater it does not belong to.
  # Upstream #13523: Grok is updated through `grok update`
  @backlog
  Scenario: A Grok binary that cannot be resolved is updated by hand
    Given the Grok instance's executable cannot be resolved
    When the MC checks provider versions
    Then Grok is reported behind the latest version with no update command

  # Health states of GrokProvider.ts checkGrokProviderStatus.
  @backlog
  Scenario Outline: Grok's health states are explained
    Given <situation>
    When the user opens the provider list
    Then Grok is shown with the message "<message>"

    Examples:
      | situation                                      | message                                                                           |
      | Grok is turned off in the provider settings    | Grok is disabled in HAL-C2 settings.                                              |
      | the MC is still looking for the grok command   | Checking Grok CLI availability...                                                 |
      | the grok version check does not finish in time | Grok CLI is installed but timed out while running `grok --version`.               |
      | the grok version check exits with an error     | Grok CLI is installed but failed to run.                                          |
      | the grok command is installed but signed out   | Grok CLI is installed but not logged in. Run `grok login`.                        |
      | Grok cannot report its model options           | Grok CLI is installed but ACP initialize failed. Model options may be incomplete. |

  # Upstream #18771: Grok gets up to 20 seconds to answer initialize before it is reported failing.
  @backlog
  Scenario: A Grok that is slow to start is not reported as failing
    Given Grok takes 15 seconds to answer when it starts
    When the MC checks Grok
    Then Grok is reported ready

  @backlog
  Scenario: Grok that cannot report its model options stays usable
    Given the grok command is installed and signed in
    And Grok cannot report its model options
    When the user sends a message to Grok
    Then Grok answers it
    And Grok is listed with a warning, not as unavailable

  # Upstream #18075: health probes run Grok with its auto-updater turned off
  @backlog
  Scenario Outline: Grok's health checks do not start Grok's own updater
    Given the MC's environment lets Grok update itself
    When the MC checks Grok's health by <probe>
    Then Grok runs with its automatic updater turned off
    And Grok's health, sign-in and models are still reported

    Examples:
      | probe                          |
      | reading its version            |
      | listing its models             |
      | starting an agent connection   |
      | listing a project's skills     |

  # Upstream #18075: sessions, text generation and updates keep the caller's environment
  @backlog
  Scenario Outline: Grok updates itself as configured outside health checks
    Given the MC's environment lets Grok update itself
    When <use>
    Then Grok runs with the MC's environment unchanged

    Examples:
      | use                                    |
      | the user sends a message to Grok       |
      | Grok writes a commit message or title  |
      | the user updates Grok                  |

  Scenario: Grok's plan becomes a plan the user can implement
    When Grok proposes a plan
    Then the plan is shown as a proposed plan
    And the user can implement it

  Scenario: Grok's questions are asked in HAL-C2
    When Grok asks the user a question
    Then the question is shown and the answer is sent back to Grok

  Scenario: Grok subagents appear as child work
    When Grok starts a subagent
    Then the subagent's work is grouped under the step that started it

  # Grok runs its subagents in its own process, so they end with it.
  Scenario: Grok's subagent fails with a turn whose runtime crashes
    Given Grok is running a subagent
    When the runtime running the turn of "Work" crashes
    Then the subagent, its node and its turn item have failed

  Scenario: Grok's always-approve command is not offered
    When the user types a slash in a Grok thread
    Then Grok's own always-approve command is not offered
    And "/compact" is offered

  Scenario: Grok reasoning choices come from the model
    When the user opens the options for a Grok model that supports reasoning
    Then the reasoning levels Grok offers for that model are shown

  Scenario: Reverting is not offered for Grok threads
    Given a Grok thread with two turns
    When the user looks at the first turn
    Then reverting to it is not offered

  Scenario: Grok's billing period is shown in the limits view
    Given Grok is signed in with a Grok account
    When the user opens the limits view
    Then Grok shows how much of its billing period is used and when it resets

  Scenario: Grok usage limits are unavailable with an API key or custom endpoint
    Given the Grok instance uses an API key
    When the user opens the limits view
    Then Grok's limits are shown as unsupported

  Scenario: A Grok usage limit stops the turn with a clear reason
    When Grok stops because the account hit its usage limit
    Then the thread says Grok's usage limit was reached

  # Grok keeps background shells and subagents running after its turn, and says when
  # each ends: x.ai/task_completed, or a "Background subagent ... completed" notice.
  Scenario: Grok's background work keeps its session until Grok reports it ended
    Given Grok left a command and a subagent running in the background
    Then "Work" lists the command and the subagent as background work
    And the MC keeps Grok's session of "Work" while they run
    When Grok reports the command and the subagent ended
    Then Grok's command and subagent are completed
    And the MC can release Grok's session of "Work"

  # Grok's background work runs inside the grok process, so ending it ends the process.
  Scenario: Stopping a Grok thread between turns ends its background work and the agent
    Given Grok left a command and a subagent running in the background
    When the user stops "Work"
    Then Grok's command and subagent are interrupted
    And "Work" lists no background work
    And Grok's agent process for "Work" stops

  Scenario: A background task Grok kills ends
    Given Grok left a command and a subagent running in the background
    When the user asks Grok to stop the dev server
    Then Grok's command is cancelled
    And "Work" lists only the subagent as background work

  # Upstream #22709: Grok does not always report a background command's end; the result of
  # polling or killing it ends it too, and it is not listed again afterwards.
  @backlog
  Scenario Outline: A Grok background command ends when its result says so
    Given Grok left a command running in the background
    When <event> and Grok never reports the command ended
    Then Grok's command is completed
    And "Work" lists no background work

    Examples:
      | event                                               |
      | Grok reads the command's output after it finished   |
      | Grok kills the command                              |

  # Upstream #22709: a command's result read alongside a subagent's does not end the subagent.
  @backlog
  Scenario: Reading a command's result does not end a subagent beside it
    Given Grok left a command and a subagent running in the background
    When Grok reads the finished command's output and the subagent's progress together
    Then Grok's command is completed
    And "Work" lists the subagent as background work

  # A persistent monitor watches until the session ends, so nothing waits on it.
  Scenario: A persistent Grok monitor is not background work
    Given Grok left a persistent monitor running
    Then Grok's monitor is not listed as background work

  # Upstream #24609: a Grok monitor was listed as a command and noted as a shell on restart.
  # Replaces the scenario above once the MC carries it.
  @backlog
  Scenario: A persistent Grok monitor is listed as a monitor that does not hold the thread
    Given Grok left a persistent monitor running
    Then "Work" lists the monitor as a monitor in its background work
    And the note after a restart names it as a monitor
    And "Work" does not stay Working for it

  @backlog
  Scenario: Grok monitor updates do not end or hold the turn
    Given Grok reports a monitor update during a turn
    When the monitor reports progress again
    Then the run is still working
    When Grok reports the turn finished while the monitor keeps reporting
    Then the run is settled
    And the monitor is not part of the run

  # Upstream wakes the thread with a turn when a background task finishes.
  @backlog
  Scenario: Finished Grok background work wakes the thread
    Given Grok left a command and a subagent running in the background
    When Grok reports the command and the subagent ended
    Then "Work" runs a turn telling Grok its background work finished

  # Upstream #24605: picking a skill writes "$name", but Grok only expands a leading "/name".
  @backlog
  Scenario Outline: A picked Grok skill at the start of a message runs as Grok's own command
    Given the grok command reports the skill "deploy" for the project
    When the user sends "<message>" to Grok
    Then Grok receives "<received>"

    Examples:
      | message             | received            |
      | $deploy to staging  | /deploy to staging  |
      | please run $deploy  | please run $deploy  |
      | $unknown to staging | $unknown to staging |

  @backlog
  Scenario: Grok skills are the ones the grok command reports
    Given the grok command reports the skill "deploy" for the project
    When the user opens the skill list in a Grok thread
    Then "deploy" is offered
    And a skill Grok says the user cannot start is listed as unavailable

  @backlog
  Scenario: Grok skills that cannot be read are reported, not shown as none
    Given the grok command fails or does not answer in four seconds when asked for its skills
    When the MC reads the Grok skills
    Then reading fails naming the step that failed and the project folder
    And the failure is not remembered as an empty skill list

  @backlog
  Scenario: Choosing Grok's default model keeps the model the session already has
    Given a Grok session that started on the model Grok picked
    When a turn runs with Grok's default model chosen
    Then Grok is not asked to switch models

  @backlog
  Scenario: A reasoning level Grok could not accept is not sent
    Given a Grok thread whose saved reasoning level is not a plain word
    When the user sends a message
    Then the turn runs without that reasoning level

  @backlog
  Scenario: A Grok turn finishes when Grok says so even if its prompt never answers
    Given a Grok turn is running
    When Grok reports the turn complete but never answers the prompt request
    Then the turn completes
    And a completion notice for a subagent's session or for finished background work does not complete it

  @backlog
  Scenario: A background Grok subagent stays running until Grok reports its result
    When Grok starts a subagent in the background and the launching tool call returns
    Then the subagent's thread is still running
    And it finishes when Grok reports the subagent's result

  @backlog
  Scenario: A Grok subagent's result is shown without Grok's own markup
    When a Grok subagent finishes and its result carries Grok's machine tags
    Then the subagent's thread shows the result text without those tags

  @backlog
  Scenario Outline: A Grok monitor that ends says how it ended
    Given a Grok monitor is watching a command
    When the monitor ends <how>
    Then the monitor is shown as <state>

    Examples:
      | how                               | state     |
      | because the command finished      | completed |
      | saying it failed or timed out     | failed    |

  @backlog
  Scenario: A Grok tool without a title is named after what it does
    When Grok runs a tool and gives it no title
    Then the tool call is named after the command, file or search it works on

  # Upstream #20881: a Grok question that allows several answers keeps that.
  @backlog
  Scenario Outline: Grok's questions keep their shape
    When Grok asks a question <shape>
    Then <outcome>

    Examples:
      | shape                                     | outcome                                              |
      | with no options                           | the user is offered "OK" to continue                 |
      | that allows several answers               | the user can pick several options                    |
      | and the user types an answer of their own | Grok receives the typed text as its "Other" answer   |
      | and the turn is stopped before an answer  | Grok is told the question was cancelled              |

  @backlog
  Scenario: Grok stops after its plan is captured
    Given a Grok thread in plan mode
    When Grok presents its plan
    Then the plan is shown for the user to review
    And Grok is told to stop and wait for feedback or a request to implement it

  @backlog
  Scenario: A Grok plan with nothing in it says so
    Given a Grok thread in plan mode
    When Grok leaves plan mode without writing a plan
    Then the plan reads "No plan written yet"

  @backlog
  Scenario: Grok's plan file is shown as the plan while Grok writes it
    Given a Grok thread in plan mode
    When Grok writes the plan file of its own session
    Then the thread's plan follows what Grok wrote
    And a file named "plan.md" that Grok edits in the workspace is shown as an ordinary edit

  @backlog
  Scenario: Checking on a Grok background task shows its latest output
    Given Grok left a command running in the background
    When Grok checks on that command
    Then the check shows the command's latest line of output

  # GrokAdapterV2.ts: what the Grok flavour changes in the shared ACP adapter.
  @backlog
  Scenario: Images are sent to Grok although Grok says it takes none
    Given Grok reports at start-up that it does not take images
    When the user sends a Grok message with a screenshot attached
    Then Grok receives the screenshot as an image with the message

  @backlog
  Scenario: Sending /compact alone to Grok compacts its conversation
    Given a Grok thread with history
    When the user sends "/compact" with no attachments and the turn completes
    Then the work log shows "Context compacted" once

  # Upstream #20180: Grok reports the selected model's context window from its session, so
  # the handoff budget is sized by it instead of an assumed 128,000 tokens.
  @backlog
  Scenario: Switching a thread back to Grok sizes the handoff by Grok's context window
    Given a thread used Grok before and has since run on another provider
    And the Grok model reports a context window larger than 128,000 tokens
    When the user switches the thread back to Grok and sends a message
    Then the history is handed to Grok within that model's window
    And the turn is not refused for lack of context allowance

  # Legacy: apps/server/src/provider/Layers/GrokAdapter (a dead session is retired, then resumed)
  # Upstream #10607: a terminated Grok session is retired so the next turn resumes it
  @backlog
  Scenario: A Grok process that exits between turns is resumed by the next message
    Given the Grok process ends with an error while the conversation is idle
    When the user sends a message on the same conversation
    Then a fresh Grok process loads the saved session and answers
    And the earlier messages stay in the thread

  @backlog
  Scenario: Stopping a running Grok turn ends everything Grok started
    Given a Grok turn is running with background work it started earlier
    When the user stops the turn
    Then the Grok process and every process it started are ended
    And the next message starts a fresh Grok process on the same conversation

  @backlog
  Scenario Outline: A message sent while a Grok turn is open does not end Grok's background work
    Given a Grok turn that <state>
    When the user steers the thread with a new message
    Then <outcome>
    And Grok's session and its background work carry on into the new turn

    Examples:
      | state                                     | outcome                                           |
      | is still answering                        | Grok is asked to cancel only what it is answering |
      | has answered and waits on background work | Grok is not asked to cancel anything              |

  @backlog
  Scenario: A Grok failure that is not a usage limit shows Grok's own message and code
    When Grok refuses a message with an error that is not its rate-limit error
    Then the turn fails with Grok's message and error code
    And it is not reported as a usage limit, even when the message mentions a rate limit

  @backlog
  Scenario: A finished Grok turn closes only the tools that ran inside it
    Given a Grok turn ran a command, started a monitor and started a subagent
    When the turn's answer is complete
    Then the command is shown as finished
    And the monitor and the subagent stay running

  @backlog
  Scenario: A Grok background task whose result never arrives stops holding the turn
    Given Grok said a background task ended but never sent its result
    When 60 seconds pass
    Then the task is shown as finished
    And the turn is no longer held open for it

  @backlog
  Scenario: A Grok turn held for background work ends once that work has been quiet for 3 seconds
    Given a Grok turn whose answer is complete is held open for background work
    When the last of that work has reported and nothing more arrives for 3 seconds
    Then the turn completes
    And a summary Grok sends within those 3 seconds stays in the same turn

  @backlog
  Scenario: A Grok turn waiting for the report on finished background work gives up after 25 seconds
    Given a Grok turn whose answer is complete is held open for Grok's report on a background task that ended
    When 25 seconds pass without that report
    Then the turn is no longer held open for it

  @backlog
  Scenario: A Grok adapter that cannot be set up says so
    When the MC cannot set up the Grok adapter for an instance
    Then the instance fails with "Failed to create Grok ACP adapter."

  # GrokAcpSupport.ts: how HAL-C2 starts and addresses the grok command.
  @backlog
  Scenario: Grok is told that HAL-C2 started it
    When the MC starts the grok command
    Then the command's environment carries "GROK_OAUTH2_REFERRER" set to "hal-c2"

  @backlog
  Scenario: Stopping a Grok turn reaches Grok as an interrupt from the keyboard
    Given a Grok turn is running
    When the user stops the turn
    Then Grok's cancel request carries the cancel trigger "ctrl_c"

  @backlog
  Scenario: A reasoning level chosen with Grok's default model applies to the model the session is on
    Given a Grok session that started on the model Grok picked
    When a turn runs with Grok's default model and a reasoning level chosen
    Then Grok is asked for that reasoning level on the model the session already has

  @backlog
  Scenario: Choosing the same Grok model again without a reasoning level keeps Grok's own reasoning
    Given a Grok session running on a model at the reasoning level Grok chose
    When a turn runs on that model with no reasoning level chosen
    Then Grok is not asked to change its reasoning level

  # XAiAcpExtension.ts: the corners of turn completion.
  @backlog
  Scenario: Each Grok prompt carries an id that Grok's completion notice can name
    When the user sends a message in a Grok thread
    Then the prompt sent to Grok carries a prompt id and a request id of its own

  @backlog
  Scenario: A Grok completion notice that reports a rate limit stops the turn at the usage limit
    Given a Grok turn is running
    When Grok reports the turn complete with a rate limit and never answers the prompt request
    Then the turn fails with "Grok usage limit reached. Try again later."

  @backlog
  Scenario: A Grok completion notice that names no prompt ends the turn only when one prompt is waiting
    Given two prompts are waiting on the same Grok session
    When Grok reports a turn complete without naming a prompt
    Then neither prompt is completed
    And the same notice completes the prompt when only one is waiting

  @backlog
  Scenario: A repeated Grok completion notice does not end the next turn
    Given a Grok turn has completed
    When Grok reports that turn complete again while the next turn is running
    Then the next turn is still running

  @backlog
  Scenario: A Grok completion notice with a reason HAL-C2 does not know ends the turn normally
    Given a Grok turn is running
    When Grok reports the turn complete with a stop reason HAL-C2 does not know
    Then the turn completes as an ordinary end of turn

  @backlog
  Scenario: Stopping a Grok turn whose start-up is stuck still ends the turn
    Given a Grok turn is waiting on a grok command that never finished starting
    When the user stops the turn
    Then the turn ends as cancelled
    And the grok command is not started again to do it

  @backlog
  Scenario Outline: Grok's notices are understood in either spelling
    When Grok sends "<notice>"
    Then HAL-C2 treats it as <meaning>

    Examples:
      | notice                        | meaning                         |
      | x.ai/session/prompt_complete  | the turn completing             |
      | _x.ai/session/prompt_complete | the turn completing             |
      | x.ai/session_notification     | the turn completing             |
      | _x.ai/session_notification    | the turn completing             |
      | _x.ai/session/update          | the turn completing             |
      | x.ai/task_backgrounded        | a task moving to the background |
      | _x.ai/task_backgrounded       | a task moving to the background |
      | x.ai/task_completed           | a background task ending        |
      | _x.ai/task_completed          | a background task ending        |
      | x.ai/ask_user_question        | a question for the user         |
      | _x.ai/ask_user_question       | a question for the user         |
      | x.ai/exit_plan_mode           | a plan to review                |
      | _x.ai/exit_plan_mode          | a plan to review                |

  # XAiAcpExtension.ts: the corners of tool calls, monitors and subagents.
  @backlog
  Scenario Outline: A Grok tool with a placeholder title is given a name that says what it is
    When Grok runs <tool> titled "Tool"
    Then the tool call is named <name>

    Examples:
      | tool                                     | name                                                |
      | a tool that carries a description        | that description                                    |
      | a monitor described as "watch the build" | "Monitor: watch the build"                          |
      | a monitor with no description            | "Monitor"                                           |
      | a subagent task with no description      | "Task"                                              |
      | a check on a background task             | "Task output"                                       |
      | a command of more than 80 characters     | the command's first 77 characters followed by "..." |

  @backlog
  Scenario Outline: A Grok command's result decides whether it is finished
    When Grok reports a command result with <result>
    Then the command is shown as <state>

    Examples:
      | result                        | state       |
      | exit code 0 and no output yet | in progress |
      | exit code 0 and its output    | completed   |
      | a non-zero exit code          | failed      |
      | the text "Exit Code: -1"      | failed      |

  @backlog
  Scenario: A Grok monitor that has only just started is shown as running
    When Grok starts a monitor and the starting tool call returns
    Then the monitor is shown as running, not as finished

  @backlog
  Scenario: Several Grok monitor updates that arrive together are each shown
    Given a Grok monitor is watching a command
    When Grok sends two monitor updates and the monitor's end in one piece of text
    Then both updates are added to the monitor's output
    And the monitor ends

  @backlog
  Scenario: A Grok monitor whose output mentions an error still ends as completed
    Given a Grok monitor whose last lines of output mention an error
    When Grok says the monitor ended cleanly
    Then the monitor is shown as completed

  @backlog
  Scenario: A Grok monitor that ends without saying anything reads "Monitor ended."
    Given a Grok monitor is watching a command
    When Grok says the monitor ended and gives no summary
    Then the monitor's output ends with "Monitor ended."

  @backlog
  Scenario Outline: A Grok background subagent ends the way Grok's notice says
    Given Grok left a subagent running in the background
    When Grok says the subagent <outcome>
    Then the subagent is shown as <state>

    Examples:
      | outcome                | state     |
      | completed successfully | completed |
      | failed                 | failed    |
      | crashed                | failed    |
      | was cancelled          | failed    |
      | was interrupted        | failed    |
      | timed out              | failed    |

  @backlog
  Scenario: A Grok subagent whose name mentions a failure is not failed by its name
    Given Grok left a subagent named "fix failed tests" running in the background
    When Grok says the subagent completed successfully
    Then the subagent is shown as completed

  @backlog
  Scenario: Text that only mentions a subagent does not end one
    Given Grok left a subagent running in the background
    When text passes through the thread that talks about background subagents without being Grok's notice
    Then the subagent is still running

  @backlog
  Scenario: Checking on a Grok task that is still running leaves it running
    Given Grok left a monitor and a subagent running in the background
    When Grok checks on them and the answer gives no final status
    Then both are still running

  @backlog
  Scenario: Checking on several Grok tasks at once finishes only the one the answer names
    Given Grok left two subagents running in the background
    When Grok checks on both and the answer reports the first one finished
    Then the first subagent is finished
    And the second is still running although the answer's text mentions it

  @backlog
  Scenario: A Grok kill that did not go through leaves the task running
    Given Grok left a command running in the background
    When Grok tries to kill it and the kill fails
    Then the command is still listed as background work

  # XAiBackgroundTasks.ts: how Grok's background tasks are listed.
  @backlog
  Scenario Outline: A Grok background task ends the way its reported status says
    Given Grok left a command running in the background
    When Grok reports the command ended with <report>
    Then the command is shown as <state>

    Examples:
      | report                             | state     |
      | the status "completed"             | completed |
      | the status "success"               | completed |
      | the status "failed"                | failed    |
      | the status "error"                 | failed    |
      | the status "killed"                | stopped   |
      | the status "cancelled"             | stopped   |
      | no status and exit code 0          | completed |
      | no status and a non-zero exit code | failed    |

  @backlog
  Scenario: A Grok background command is listed by the first line of its command
    When Grok moves a command of several lines to the background
    Then the background work is listed by the command's first line, cut at 200 characters
    And a background monitor is listed by its description, or as "Monitor" when it has none

  @backlog
  Scenario: A command Grok moves to the background on its own is listed while its tool call is still open
    Given a Grok turn is running a long command
    When Grok moves the command to the background before the tool call finishes
    Then the command is listed as background work

  @backlog
  Scenario: A Grok background task first seen when Grok checks on it is still listed
    Given HAL-C2 never saw Grok start a background command
    When Grok checks on that command and it is running
    Then the command is listed as background work
    And it is not counted as work of the turn that checked on it

  @backlog
  Scenario: A Grok kill that ends some tasks and not others ends only those
    Given Grok left two commands running in the background
    When Grok kills both and only the first is reported killed
    Then the first command is stopped
    And the second is still listed as background work

  # XAiAcpExtension.ts: the corners of questions and plans.
  @backlog
  Scenario: A Grok question that does not say whether it takes several answers takes one
    When Grok asks a question that leaves out whether several answers are allowed
    Then the user can pick one option only

  @backlog
  Scenario: Answers reach Grok in the order Grok asked its questions
    Given Grok asked two questions at once
    When the user answers the second question before the first
    Then Grok receives the answers in the order it asked, each under the question's own text

  @backlog
  Scenario Outline: An option's preview goes back to Grok only for a single choice
    Given Grok asked a question whose options carry previews
    When the user answers a question that allows <choices>
    Then Grok's answer <preview>

    Examples:
      | choices         | preview                             |
      | one answer      | carries the chosen option's preview |
      | several answers | carries no preview                  |

  @backlog
  Scenario: Grok's plan is read from its plan file when Grok presents none
    Given a Grok thread in plan mode whose plan file has been written
    When Grok presents its plan without including the plan's text
    Then the plan shown is the plan file's content

  @backlog
  Scenario Outline: Grok's plan file is recognised wherever Grok keeps its sessions
    Given a Grok thread in plan mode
    When Grok writes "plan.md" <where>
    Then the write <outcome>

    Examples:
      | where                                                         | outcome                      |
      | under the sessions folder of the Grok home the instance sets  | is shown as the plan         |
      | under the sessions folder with different letter case, Windows | is shown as the plan         |
      | at a path that climbs out of the sessions folder with ".."    | is shown as an ordinary edit |

  # features/settings/subagents.feature: the setting is not wired for Grok yet.
  @backlog @mc
  Scenario: Grok's own subagent tool is turned off when agents use HAL-C2 workers
    Given the subagents setting is HAL-C2 workers
    When a Grok session is started
    Then its task tool is passed as disallowed

  # Upstream #13328: restore a compatibility policy for every harness (Grok supported at 1.0.13)
  @backlog
  Scenario Outline: The version Grok runs decides whether this HAL-C2 release supports it
    Given Grok version "<version>" is installed
    When the MC checks Grok
    Then Grok is reported as "<status>" for this HAL-C2 release

    # Statuses are the MC's (see the Claude Code outline). A CLI below 1.0.13 is refused by
    # xAI's backend with 426 Upgrade Required, so it is broken and the warning points at >=1.0.13.
    Examples:
      | version | status  |
      | 0.2.8   | broken  |
      | 1.0.12  | broken  |
      | 1.0.13  | unknown |

  # Upstream #14486: Grok CLIs older than 1.0.13 are marked broken
  @backlog @desktop
  Scenario: A broken Grok's warning names the version to update to
    Given Grok version "0.2.8" is installed
    When the user opens the Providers settings
    Then Grok shows an incompatible-version warning
    And the warning names version 1.0.13 or newer

  # Upstream #19938: a Grok command that finishes before its prompt settles keeps its result;
  # a sparse duplicate update does not turn a failure into success.
  @backlog @shared
  Scenario: A Grok background command that finished early reads as finished
    Given Grok finishes a background command with a failure before its turn ends
    And Grok then sends an update for the command without a result
    When the turn ends
    Then the command reads as failed, not running and not succeeded
