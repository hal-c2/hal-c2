# Sources:
#   https://github.com/pingdotgg/t3code/pull/30187
#   https://github.com/pingdotgg/t3code/pull/32231
#   https://github.com/pingdotgg/t3code/pull/32389
#   https://github.com/pingdotgg/t3code/pull/24388
#   https://github.com/pingdotgg/t3code/pull/27539
#   https://github.com/pingdotgg/t3code/pull/27521
#   https://github.com/pingdotgg/t3code/pull/27514
#   https://github.com/pingdotgg/t3code/pull/27513
#   https://github.com/pingdotgg/t3code/pull/22463
#   https://github.com/pingdotgg/t3code/pull/23741
#   https://github.com/pingdotgg/t3code/pull/23235
#   https://github.com/pingdotgg/t3code/pull/20521
#   https://github.com/pingdotgg/t3code/pull/21356
#   https://github.com/pingdotgg/t3code/pull/23052
#   https://github.com/pingdotgg/t3code/pull/18498
#   https://github.com/pingdotgg/t3code/pull/21762
#   https://github.com/pingdotgg/t3code/pull/18933
#   https://github.com/pingdotgg/t3code/pull/15529
#   https://github.com/pingdotgg/t3code/pull/15368
#   https://github.com/pingdotgg/t3code/pull/15791
#   https://github.com/pingdotgg/t3code/pull/19070
#   https://github.com/pingdotgg/t3code/pull/18639
#   https://github.com/pingdotgg/t3code/pull/18643
#   https://github.com/pingdotgg/t3code/pull/17851
#   https://github.com/pingdotgg/t3code/pull/17853
#   https://github.com/pingdotgg/t3code/pull/17835
#   https://github.com/pingdotgg/t3code/pull/17834
#   https://github.com/pingdotgg/t3code/pull/17840
#   https://github.com/pingdotgg/t3code/pull/17852
#   https://github.com/pingdotgg/t3code/pull/17214
#   https://github.com/pingdotgg/t3code/pull/17220
#   https://github.com/pingdotgg/t3code/pull/17206
#   https://github.com/pingdotgg/t3code/pull/17190
#   https://github.com/pingdotgg/t3code/pull/17194
#   https://github.com/pingdotgg/t3code/pull/13839
#   https://github.com/pingdotgg/t3code/pull/16661
#   https://github.com/pingdotgg/t3code/pull/16210
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/21822
#   https://github.com/pingdotgg/t3code/pull/28400
#   https://github.com/pingdotgg/t3code/pull/29768
#   https://github.com/pingdotgg/t3code/pull/30025
#   https://github.com/pingdotgg/t3code/pull/23901
#   docs/user/providers-pi.md
#   docs/internals/providers.md (Pi RPC mode, forks through the CLI in the destination directory)
#   apps/server-ex/lib/hal_c2/pi.ex, apps/server-ex/lib/hal_c2/pi/thread_runtime.ex (Pi RPC mode)
#   apps/server/src/provider/Layers/PiProvider.ts, apps/server/src/provider/Drivers/PiDriver.ts
#   apps/server/src/orchestration-v2/Adapters/PiAdapterV2.ts, apps/server/src/orchestration-v2/Adapters/PiRpc.ts
#   apps/server/src/orchestration-v2/Adapters/piHalC2McpInjection.ts, apps/server/src/provider/PiCommands.ts
#   apps/server/src/orchestration-v2/Adapters/piHalC2McpExtensionSource.ts (approval hook, HAL-C2 tools bridge, OpenRouter output cap)
#   apps/server/src/provider/Layers/piThinkingCapabilities.ts, apps/server/src/textGeneration/PiTextGeneration.ts

@plugin-pi @mc @priority-low
# Pi has no built-in subagents, so the subagents setting (features/settings/subagents.feature) has nothing to turn off here.
Feature: Pi
  Pi uses the user's existing Pi installation with its own models, logins, extensions,
  skills and session files. Pi is early access.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Pi does nothing until the user enables it
    Given Pi is installed but not enabled
    When the MC starts
    Then no Pi process is started

  Scenario: Pi is only offered when the pi command is installed
    Given the pi command is not installed on the MC
    When the user opens the list of agents to enable
    Then Pi is not offered

  # The MC runs Pi in its own RPC mode, as the TS server does (PiAdapterV2), not through pi-acp.
  Scenario: Pi runs in its own RPC mode
    Given Pi is installed and enabled
    When the user sends a message to Pi
    Then the turn runs on the user's own Pi installation

  Scenario: A custom Pi binary path is used
    Given Pi's binary path is set to "/opt/pi/bin/pi"
    When the user sends a message to Pi
    Then that Pi binary runs the turn

  Scenario: Pi older than 0.80.5 is refused
    Given the installed Pi is 0.79.0
    When the user refreshes provider status
    Then Pi is shown as unsupported with a hint to update to 0.80.5 or newer

  Scenario: Pi launch arguments that change how HAL-C2 runs Pi are refused
    When the user adds the launch argument "--mode json" to Pi
    Then the setting is refused with a message that HAL-C2 owns that part of Pi

  Scenario: Pi with no usable models explains how to sign in
    Given Pi reports no models
    When the user refreshes provider status
    Then Pi says to sign in with Pi in a terminal or configure an API key

  # Upstream #27513: Pi showed as ready while its launch arguments pinned a model with no
  # credentials, so every turn on "Pi default" failed without saying why.
  Scenario: Pi whose default model has no credentials says so
    Given Pi's launch arguments pin "openai/gpt-5" and Pi holds only an Anthropic key
    When the user refreshes provider status
    Then Pi stays ready, with its other models still offered
    And Pi's provider details name "openai/gpt-5" and say its provider has no credentials

  # Health states of PiProvider.ts checkPiProviderStatus.
  Scenario Outline: Pi's health states are explained
    Given <situation>
    When the user refreshes provider status
    Then Pi is shown with the message "<message>"

    Examples:
      | situation                                          | message                                                                                                       |
      | Pi is turned off in the provider settings          | Pi is disabled in HAL-C2 settings.                                                                            |
      | the MC is still looking for the pi command         | Checking Pi CLI availability...                                                                               |
      | the pi command is not installed                    | Pi CLI (`pi`) is not installed or not on PATH. Install with `npm install -g @earendil-works/pi-coding-agent`. |
      | the pi command is found but cannot be run          | Failed to execute Pi CLI health check.                                                                        |
      | the pi version check does not finish in time       | Pi CLI is installed but timed out while running `pi --version`.                                               |
      | the pi version check exits with an error           | Pi CLI is installed but failed to run.                                                                        |
      | pi prints no version                               | HAL-C2 could not determine the Pi version. Pi 0.80.5 or newer is required.                                    |

  # Upstream #28400: "pi --version" had 4 seconds, so a healthy CLI that started slowly showed as
  # unavailable. The sign-in check keeps its 4 seconds.
  Scenario: A Pi whose version check takes 8 seconds is not shown as unavailable
    Given Pi takes 8 seconds to print its version
    When the user refreshes provider status
    Then Pi is not reported as timed out

  Scenario: Pi stays available when its models and commands cannot be refreshed
    Given Pi discovery of its models and commands fails
    When the user refreshes provider status
    Then Pi stays available with the "Pi default" model
    And Pi is shown with a message that the live session will retry startup

  # Upstream #18498: models Pi no longer lists are not restored
  Scenario: A model Pi no longer offers is removed
    Given Pi listed the models "alpha" and "beta"
    When Pi's models are discovered again and only "alpha" is listed
    Then only "alpha" is offered by Pi
    And a discovery that fails or does not finish keeps both

  Scenario: Pi stays usable when discovery cannot finish
    Given Pi discovery needs interactive input
    When the user refreshes provider status
    Then Pi stays available with the "Pi default" model
    And the first thread lets Pi handle its startup prompt

  # Upstream #15529: Pi model discovery waits up to 30 seconds for slow extensions
  Scenario: Pi's extension models are found when its extensions load slowly
    Given Pi takes 20 seconds to load its extensions
    When the user refreshes provider status
    Then the models Pi's extensions add are offered
    And discovery that takes longer than 30 seconds falls back to "Pi default"

  Scenario: Pi thinking levels follow the model
    Given the Pi model supports thinking levels up to extra high
    When the user opens the options for that model
    Then off, minimal, low, medium, high and extra high are offered
    And Pi's configured level is marked as the default

  # Upstream #32389: switching models between turns let Pi apply the new model's default
  # thinking level over the one the user had chosen.
  Scenario: A thinking level the user chose is kept when the Pi model changes
    Given a Pi thread runs model "A" with thinking set to high by the user
    When the user switches the thread to model "B" and sends the next message
    Then Pi runs the turn on "B" with thinking high
    And switching back to Pi's default model with Pi's default thinking uses that model's own level

  Scenario Outline: Pi access modes decide which tools ask first
    Given the thread runs Pi in <mode>
    When Pi wants to <action>
    Then it is <outcome>

    Examples:
      | mode              | action           | outcome                 |
      | approval required | read a file      | allowed without asking  |
      | approval required | edit a file      | asked for approval      |
      | approval required | run a command    | asked for approval      |
      | auto-accept edits | edit a file      | allowed without asking  |
      | auto-accept edits | run a command    | asked for approval      |
      | full access       | run a command    | allowed without asking  |

  Scenario: Auto mode is not offered for Pi
    When the user opens the access picker in a Pi thread
    Then auto is not offered

  Scenario: Older Pi threads saved in auto behave as approval required
    Given a Pi thread saved with auto mode
    When the user opens the thread
    Then it shows and behaves as approval required

  Scenario: Changing the access mode restarts Pi on the same conversation
    Given a Pi thread with history
    When the user switches the thread to full access
    Then Pi restarts and continues the same native conversation

  Scenario: Allowing a Pi tool for the session stops further prompts for it
    Given Pi asked to run the same command twice
    When the user allows it for the session the first time
    Then the second request is allowed without asking

  Scenario: Pi extension dialogs appear in the composer
    When a Pi extension asks the user to pick from a list
    Then the choices appear in the composer and the answer goes back to the extension

  # Upstream #29768: an error from a folder extension was titled "index", after its entry file.
  Scenario Outline: A Pi extension's error names the extension
    Given the Pi extension at "<path>" throws during a turn
    Then the turn shows an error titled "<title>"

    Examples:
      | path                                     | title     |
      | ~/.pi/agent/extensions/notes/index.ts    | notes     |
      | ~/.pi/agent/extensions/lint.ts           | lint      |

  Scenario: A Pi thread can be resumed in the Pi terminal app
    Given a Pi thread in HAL-C2
    When the user opens the same session in Pi's own terminal app
    Then the conversation continues there from the same session file

  Scenario: Reverting a Pi turn rewinds Pi's session file
    Given a Pi thread with three turns
    When the user reverts to the end of the first turn
    Then Pi continues from the first turn

  Scenario: Reverting a Pi turn works past a turn the user stopped
    Given a Pi thread with a stopped turn followed by a finished turn
    When the user reverts to before the stopped turn
    Then Pi continues from the turn before it
    And the stopped turn is not used as Pi's history

  # Upstream #20521: a turn stopped before HAL-C2 saw its place in Pi's session made reverts and
  # forks past it fail, though Pi had kept the prompt.
  Scenario Outline: A Pi turn stopped before it was recorded can still be gone past
    Given a Pi thread whose second turn was stopped before Pi reported its place in the session
    And a third turn finished after it
    When the user <action> the end of the third turn
    Then Pi continues from the third turn

    Examples:
      | action        |
      | reverts to    |
      | forks from    |

  Scenario: Forking a Pi thread copies the native conversation into the new workspace
    Given a Pi thread with three turns
    When the user forks from the second turn into a new worktree
    Then the new thread continues Pi's conversation through the second turn in that worktree

  # Upstream #23052: forking a finished turn failed while the next one ran, since the running
  # turn had no session entry captured yet.
  Scenario: A finished Pi turn can be forked while the next turn runs
    Given a Pi thread whose second turn is running
    When the user forks from the first turn
    Then the new thread continues Pi's conversation through the first turn only

  # A steer is a user message inside the running turn in Pi's session, so cutting a fork at
  # the first user message after the fork point's own dropped the steer and its answer.
  Scenario Outline: A forked Pi turn keeps the steer it took
    Given a Pi thread whose first turn took the steer "and the tests"
    And the Pi thread's next turn <next>
    When the user forks from the first turn
    Then the new thread continues Pi's conversation through the steer

    Examples:
      | next            |
      | has not started |
      | is running      |

  Scenario: Pi skills appear in the skill menu
    Given Pi loads the project skill "deploy"
    When the user opens the skill menu in a Pi thread
    Then "deploy" is offered and uses Pi's own skill expansion

  Scenario: Pi retries and compactions show in the work log
    When Pi retries a failed request and later compacts the conversation
    Then the work log shows the retry and the compaction

  Scenario: The context meter follows Pi's usage reports
    When Pi reports its context usage while answering
    Then the context meter shows Pi's reported usage

  Scenario: Pi delegates work to child threads through the HAL-C2 tools
    When Pi delegates a task
    Then the task appears as a child thread in the subagent view

  Scenario: Pi exiting mid-turn is reported
    Given a Pi turn is running
    When the Pi process exits unexpectedly
    Then the turn fails saying Pi exited unexpectedly

  # Upstream #18639: Pi turn-start prompts are queued while native extension work is running
  Scenario: A message sent while Pi resumes extension work on its own is queued
    Given Pi has resumed extension work before HAL-C2 heard that it woke
    When the user sends a message in the Pi thread
    Then Pi takes the message after its current work
    And the turn does not fail with "Agent is already processing"

  # Upstream #18643: HAL-C2 tool schemas load for models behind completions gateways
  @backlog
  Scenario: HAL-C2 tools are usable by a Pi model behind an OpenAI-compatible completions gateway
    Given Pi runs a model through an "openai-completions" gateway
    When the Pi model calls "hal_c2_thread_read"
    Then the call runs and its result reaches the model
    And tools the user excluded with "--exclude-tools" are still left out

  # Upstream #21822: a tool schema with no properties at all was refused by some models.
  @backlog @priority-low
  Scenario: A HAL-C2 tool that takes no arguments is usable by a Pi model
    Given Pi runs a model that refuses tool schemas without a properties list
    When the Pi model calls a HAL-C2 tool that takes no arguments
    Then the call runs and its result reaches the model

  # PiCommands.ts: Pi's command list omits its terminal built-ins, and Pi only expands
  # skills written as leading "/skill:name" commands.
  Scenario: Pi offers /compact although Pi does not list it
    When the user types a slash in a Pi thread
    Then "/compact" is offered

  Scenario: Sending /compact compacts the Pi conversation
    Given a Pi thread that has answered a message
    When the user sends "/compact" to a Pi thread
    Then Pi compacts its conversation
    And the work log shows the compaction

  Scenario: Sending /compact with instructions passes them to Pi
    When the user sends "/compact keep the database notes" to a Pi thread
    Then Pi compacts its conversation following "keep the database notes"

  # Upstream #17194: Pi loads every selected skill without losing prompt text
  Scenario: Every skill a Pi message mentions is loaded and the message keeps its words
    Given Pi has the skills "deploy" and "review"
    When the user sends "please $review this and then $deploy it" to a Pi thread
    Then Pi loads both "review" and "deploy"
    And Pi receives the user's text as written, with any images it carries

  # Upstream #17194: Pi loads every selected skill without losing prompt text
  Scenario: A dollar word that is not a Pi skill is left as written
    Given Pi has the skill "deploy"
    When the user sends "the price is $5 and $deploy it" to a Pi thread
    Then Pi loads "deploy" and nothing for "$5"

  # Upstream #17194: Pi loads every selected skill without losing prompt text
  Scenario: A skill mentioned twice is expanded once
    Given Pi has the skill "deploy"
    When the user sends "$deploy and again $deploy" to a Pi thread
    Then Pi loads "deploy" once

  # piHalC2McpInjection.ts: the arguments HAL-C2 owns, in their "--flag" and "--flag=value" forms.
  Scenario Outline: A Pi launch argument HAL-C2 cannot honour is refused with its reason
    When the user sets Pi's launch arguments to "<arguments>"
    Then the setting is refused with the message "<message>"

    Examples:
      | arguments           | message                                                                           |
      | --session abc       | Pi launch argument '--session' is controlled by HAL-C2 and cannot be overridden.  |
      | --mode=json         | Pi launch argument '--mode' is controlled by HAL-C2 and cannot be overridden.     |
      | --no-session        | Pi launch argument '--no-session' is controlled by HAL-C2 and cannot be overridden. |
      | -p                  | Pi launch argument '-p' is controlled by HAL-C2 and cannot be overridden.         |
      | --resume            | Pi launch argument '--resume' is controlled by HAL-C2 and cannot be overridden.   |
      | --fork abc          | Pi launch argument '--fork' is controlled by HAL-C2 and cannot be overridden.     |
      | -- fix the tests    | Pi launch arguments cannot include positional prompts.                            |
      | fix the tests       | Pi launch arguments cannot include positional prompt 'fix'.                       |
      | --model             | Pi launch argument '--model' requires a value.                                    |
      | -z                  | Pi launch argument '-z' is not supported by HAL-C2.                               |

  Scenario: A launch argument meant for a Pi extension is passed on to Pi
    Given a Pi extension takes the argument "--plan-depth 3"
    When the user adds the launch argument "--plan-depth 3" to Pi
    Then the setting is accepted
    And Pi starts with "--plan-depth 3"

  Scenario: Pi starts with the user's own extensions, skills, settings and logins
    Given the user's Pi installation has extensions, skills, project instructions and saved logins
    When a Pi thread starts
    Then Pi loads all of them as it does in its own terminal app

  # Upstream #27539: in a folder Pi has not trusted, Pi quietly skipped the project's own settings,
  # extensions and skills.
  Scenario: A Pi session in a folder Pi does not trust says what Pi skipped
    Given Pi has not trusted the project's folder
    When a Pi thread runs its first turn, new or resumed
    Then the thread shows one notice naming the folder and what Pi skipped
    And the notice says how to trust the folder with "/trust" in Pi's terminal app

  Scenario: Pi writing titles and commit messages runs without tools, extensions or a saved session
    Given Pi's launch arguments name an extension and a tool list
    When Pi writes a thread title
    Then Pi runs with every tool and extension turned off
    And no Pi session file is left behind

  # Upstream #19070: Pi text generation names the model it could not load and that extensions are off for it.
  Scenario: Pi failing to write a title says which model it could not load
    Given the text-generation model is one only a Pi extension provides
    When Pi is asked for a thread title
    Then the failure names that model
    And says extensions are not loaded when Pi writes titles and commit messages

  # Upstream #23741: an empty Pi reply that came with a turn error reported a generic failure; it now names the error.
  Scenario: Pi failing to write a title shows the provider's error
    Given Pi ends a title request with no text and the error "model overloaded"
    When Pi is asked for a thread title
    Then the failure reads "Pi could not generate text: model overloaded"

  @priority-high
  Scenario: Pi never inherits another session's HAL-C2 credential
    Given the MC itself was started by an agent that holds a HAL-C2 tools credential
    When a Pi thread starts
    Then Pi receives only the credential of its own thread

  # PiRpc.ts: Pi's own output shares the channel HAL-C2 talks to it on.
  Scenario: Stray output from a Pi extension does not break the session
    Given a Pi extension prints text that is not part of Pi's protocol
    When the user sends a message to Pi
    Then the stray text is ignored
    And the turn finishes normally

  Scenario: A single Pi message larger than 8 MiB is dropped
    When Pi sends one message larger than 8 MiB
    Then that message is dropped
    And the session keeps running

  Scenario: Text containing Unicode line separators reaches the thread intact
    When Pi answers with text that contains the characters U+2028 and U+2029
    Then the reply shows the whole text

  Scenario Outline: A Pi request that goes wrong says what failed
    Given a Pi thread is starting
    When <problem>
    Then the user is told "<message>"

    Examples:
      | problem                                          | message                                                  |
      | Pi exits with code 2 before answering            | Pi RPC get_state failed: pi process exited with code 2.  |

    @backlog
    Examples: deadlines and closed output
      | problem                                          | message                                                  |
      | Pi does not answer a request within its deadline | Pi RPC get_state failed: timed out after 15000ms.        |
      | Pi closes its output before answering            | Pi RPC get_state failed: pi process closed stdout.       |

  Scenario: A long Pi failure detail is cut to 200 characters
    When Pi refuses a request with an explanation of 5,000 characters
    Then the failure the user sees carries its first 200 characters followed by an ellipsis

  Scenario: Requests waiting on Pi fail at once when Pi dies
    Given HAL-C2 is waiting for Pi to answer several requests
    When the Pi process exits
    Then every waiting request fails immediately instead of waiting out its deadline

  @backlog
  Scenario: What Pi writes to its error output is never logged
    When Pi writes text to its error output
    Then the logs record only how much was written
    And never the text, which may hold credentials or prompt text

  @backlog
  Scenario Outline: Stopping Pi also stops what its extensions started
    Given the MC runs on <platform>
    And a Pi extension started a helper process
    When the Pi session is stopped
    Then Pi and the helper process are both gone
    And <manner>

    Examples:
      | platform | manner                                                          |
      | Linux    | Pi is asked to stop and is killed if still alive a second later |
      | macOS    | Pi is asked to stop and is killed if still alive a second later |
      | Windows  | the whole process tree is ended at once                         |

  # Upstream #30025: Pi's input was closed before it was asked to stop, so Pi quit mid-shutdown and
  # an extension's shutdown work never finished.
  @backlog
  Scenario: Stopping Pi lets its extensions finish their shutdown work
    Given a Pi extension does work of its own when its session shuts down
    When the Pi session is stopped
    Then Pi is asked to stop before its input is closed
    And the extension's shutdown work finishes before Pi exits

  Scenario: A Pi that fails while starting is not left running
    When Pi starts but the session cannot finish setting up
    Then the Pi process is stopped

  # piHalC2McpExtensionSource.ts: the extension HAL-C2 loads into Pi for approvals and its tools.
  Scenario: A Pi tool the user declines is blocked with a reason Pi can read
    Given the thread runs Pi in approval required
    When Pi asks to run a command and the user declines
    Then the command does not run
    And Pi is told "bash was declined in HAL-C2."

  Scenario: Pi's approval request shows what the tool was asked to do
    Given the thread runs Pi in approval required
    When Pi asks to run "npm test"
    Then Pi's approval is titled "Allow bash?"
    And it shows the command Pi wants to run

  Scenario Outline: Pi's approval kind follows the tool
    Given the thread runs Pi in approval required
    When Pi asks to use its <tool> tool
    Then the user is asked to approve <kind>

    Examples:
      | tool  | kind          |
      | edit  | a file change |
      | write | a file change |
      | bash  | a command     |
      | other | a command     |

  @backlog
  Scenario: Pi still asks for approval when the HAL-C2 tools cannot be offered
    Given the thread runs Pi in approval required
    And the thread has no HAL-C2 tools credential
    When Pi wants to run a command
    Then the user is asked for approval

  @backlog
  Scenario Outline: Pi is told when the HAL-C2 tools are unavailable
    Given <situation>
    When a Pi thread starts
    Then Pi shows the warning "<warning>"
    And the thread still runs

    Examples:
      | situation                                            | warning                                                                             |
      | the thread has no HAL-C2 tools address or credential | hal-c2 MCP unavailable: HAL_C2_MCP_URL or HAL_C2_MCP_BEARER_TOKEN is missing.       |
      | the HAL-C2 tools refuse the connection               | hal-c2 MCP unavailable: followed by the reason                                      |
      | the HAL-C2 tools do not answer within 10 seconds     | hal-c2 MCP unavailable: followed by the reason                                      |

  @backlog
  Scenario: Pi tries the HAL-C2 tools again when its session starts
    Given the HAL-C2 tools could not be reached when Pi loaded
    When the Pi session starts
    Then Pi connects to the HAL-C2 tools again before warning that they are unavailable

  @backlog
  Scenario: The HAL-C2 tools appear in Pi under the hal-c2 name
    When a Pi thread starts with the HAL-C2 tools
    Then Pi lists each of them as "mcp__hal-c2__" followed by the tool's name

  # Upstream #32231: the file that gives Pi the HAL-C2 tools was truncated and rewritten in place,
  # so a Pi session starting during the write loaded an empty or partial extension.
  @backlog
  Scenario: A Pi session that starts while another writes the HAL-C2 tools still gets them
    Given one Pi thread is writing out the HAL-C2 tools for Pi
    When another Pi session starts at that moment
    Then it loads the HAL-C2 tools whole, as they were before the write or after it

  @backlog
  Scenario: HAL-C2's instructions do not stop a Pi slash command from expanding
    Given Pi has the prompt command "/review"
    When the user sends "/review the last change" to a Pi thread
    Then Pi receives the message unchanged and expands "/review"
    And HAL-C2's own instructions reach Pi as part of its system prompt

  # Upstream #18933: HAL-C2's guidance no longer overrides other Pi extensions' prompt changes
  @backlog
  Scenario: HAL-C2's instructions leave other Pi extensions' prompt changes in place
    Given a Pi extension adds its own context files and skills to the system prompt
    When a Pi thread starts a turn
    Then Pi's system prompt holds both that extension's additions and HAL-C2's instructions

  # Works around Pi asking OpenRouter for more output than the context can hold.
  Scenario Outline: Pi's output budget on OpenRouter is capped at 32,768 tokens
    Given a Pi thread uses <model>
    When Pi asks the model for up to <asked> output tokens
    Then the request goes out asking for <sent>

    Examples:
      | model                            | asked   | sent    |
      | an OpenRouter model              | 128,000 | 32,768  |
      | an OpenRouter model              | 8,000   | 8,000   |
      | a model from another provider    | 128,000 | 128,000 |

  @backlog
  Scenario: Pi working when no turn is running is stopped
    Given a Pi thread with no turn running
    When Pi starts agent work that HAL-C2 did not ask for
    Then the Pi session is stopped
    And the thread says "Pi started agent work outside an active HAL-C2 turn. The session was stopped to prevent invisible tool execution."

  Scenario: A message an extension command handles without the agent still ends its turn
    Given a Pi extension handles "/stats" without starting agent work
    When the user sends "/stats" to a Pi thread
    Then the turn finishes once Pi is idle
    And the Pi turn is not left running

  Scenario: An extension command settles quickly though Pi was slow to list its commands
    Given a Pi extension handles "/stats" without starting agent work
    And Pi lists its commands only after the session's first lookup gave up
    When the user sends "/stats" to a Pi thread
    Then the turn finishes as a command does, once Pi is briefly idle

  Scenario: A message Pi's extensions take a while to start on is not ended as idle
    Given Pi's extensions work for a few seconds before Pi's agent starts on "slow start"
    When the user sends "slow start" to a Pi thread
    Then that turn waits for Pi's agent and runs to its end

  Scenario: A Pi prompt template its extensions take a while to start on is not ended as idle
    Given Pi's extensions work for a few seconds before Pi's agent starts on the prompt template "/review"
    When the user sends "/review the cart" to a Pi thread
    Then that turn waits for Pi's agent and runs to its end

  Scenario: Pi going silent after a message stops the session
    Given Pi accepted a message but never reports whether it is working
    When three checks of Pi's state fail
    Then the Pi process is stopped
    And the silent turn fails

  Scenario: A notice from a Pi extension shows in the work log
    When a Pi extension shows the warning "Lint found 3 problems"
    Then the work log shows "Lint found 3 problems" as a warning

  Scenario Outline: A Pi extension's text prompt can be answered with nothing
    When a Pi extension asks the user for <kind>
    Then the user can type an answer or choose "Submit empty value"
    And choosing it sends an empty answer to the extension

    Examples:
      | kind               |
      | a line of text     |
      | a longer text edit |

  # Upstream #23235: a blank placeholder became the question, which failed the whole turn while
  # Pi kept waiting on its dialog.
  Scenario: A Pi extension's text question with a blank placeholder asks its title
    When a Pi extension asks for a line of text titled "What should I do?" with a blank placeholder
    Then the user is asked "What should I do?"
    And the turn keeps running until the answer goes back to the extension

  # Upstream #22463: a Pi select, editor or placeholder-less input dialog showed its whole title
  # twice, as the header and again as the question, and a long title ran past the card.
  Scenario Outline: A Pi extension dialog with only a title shows it once
    When a Pi extension <asks> titled "Merge target" with nothing else to say
    Then the question reads "Merge target" once, under the header "Question"

    Examples:
      | asks                                      |
      | asks the user to pick from a list         |
      | asks the user to edit a text              |
      | asks for a line of text with no placeholder |

  # Upstream #22463: an input dialog with a placeholder keeps its title as the header.
  Scenario: A Pi text question with a placeholder keeps its title as the header
    When a Pi extension asks for a line of text titled "Branch" with the placeholder "feature/…"
    Then the question's header is "Branch"

  # Upstream #17206: Pi editor dialogs prefill the answer composer. The MC sends the whole text
  # as the question's initialAnswer; the clients still have to start the composer from it.
  @shared @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A Pi extension's text edit starts the answer from what is there now
    When a Pi extension asks the user to edit a text that already has content
    Then the whole text fills the answer composer, ready to edit
    And the answer goes back to the extension with its spaces and line breaks as typed

  # Upstream #21762: an empty Pi select value no longer fails the question
  Scenario: An empty choice from a Pi extension can still be picked
    When a Pi extension offers a list whose choices include an empty one
    Then that choice is offered as "Empty value"

  Scenario: Dismissing a Pi extension's dialog cancels it for the extension
    Given a Pi extension asked the user to pick from a list
    When the user dismisses the request
    Then the extension is told the dialog was cancelled

  Scenario: An answer that could not reach Pi can be sent again
    Given a Pi extension asked the user a question
    When the user's answer cannot be delivered to Pi
    Then the question stays open for another answer

  Scenario: Answering a Pi request that is no longer open is refused
    When a client answers the Pi request "r9" that is not open
    Then the answer is refused with "No pending Pi extension request r9"

  Scenario: A failing Pi extension is named in the work log
    Given the Pi extension "auto-lint" fails while a tool runs
    When the turn continues
    Then the work log shows a failed entry titled "auto-lint"
    And it says during which step the extension failed and why

  Scenario: A Pi extension failing between turns is shown on the next turn
    Given a Pi extension failed while no turn was running
    When the user sends the next message
    Then that turn's work log shows the extension's failure

  # The run's prompt waits for Pi's compaction to end, and with it the history it hands
  # over. Showing an extension's failure from between turns is not Pi taking either, so a
  # handoff still counts that history as unconfirmed (#1363 review).
  Scenario: A prompt waiting on Pi's compaction does not confirm its handoff
    Given Pi is compacting a thread's conversation after an extension failed between turns
    When the thread comes back to Pi from Codex while Pi still compacts
    Then the run shows the extension's failure while its prompt waits
    And the history it hands over is still unconfirmed

  # Taking over Pi's wake replays what Pi said before it began compacting: Pi's own work,
  # not Pi taking the prompt, so the history it hands over stays unconfirmed too.
  Scenario: A prompt that takes over a compacting Pi wake does not confirm its handoff
    Given a Pi extension has woken Pi, which compacts after its first words
    When the thread comes back to Pi from Codex while Pi still compacts
    Then the run shows the wake's work while its prompt waits
    And the history it hands over is still unconfirmed

  # A prompt that takes over a wake Pi is still at goes to Pi as a follow-up. Pi answers
  # that it queued it, at once or late, and delivers it only once the wake's work stops:
  # until then what Pi does is still the wake's work, so it confirms no handoff; Pi
  # delivering the prompt does.
  Scenario Outline: A prompt that follows a running Pi wake confirms its handoff once Pi delivers it
    Given a Pi extension has woken Pi, which runs a command once a message follows it, answering it "<answered>"
    When the thread comes back to Pi from Codex while the wake runs
    Then the run shows the wake's command before Pi takes its prompt
    And the history it hands over stays unconfirmed until Pi takes the prompt

    Examples:
      | answered |
      | at once  |
      | late     |

  Scenario Outline: A Pi compaction shows how it ended
    When Pi's compaction of the conversation <ends>
    Then the work log entry reads "<title>"
    And <detail>

    Examples:
      | ends                   | title                     | detail                                                         |
      | is still running       | Compacting context...     | it is shown as running                                         |
      | finishes               | Context compacted         | it carries Pi's summary and the token count before compaction  |
      | fails                  | Context compaction failed | it carries Pi's reason, or "Pi context compaction failed."     |
      | is stopped by the user | Context compaction stopped | it is shown as stopped, not failed                            |

  Scenario: Stopping a Pi thread while it compacts restarts Pi
    Given Pi is compacting the conversation
    When the user stops the turn
    Then Pi is given 2 seconds to stop the compaction and is then restarted
    And the thread can take the next message

  # Upstream #24388: a message sent while Pi compacted its context could be rejected and lost.
  # Pi 1.4 rejects every prompt, steers included, while it compacts.
  Scenario Outline: A message sent while Pi compacts is delivered once compaction ends
    Given Pi is compacting the conversation <when>
    When the user <sends> "now add the tests" while it does
    Then Pi receives "now add the tests" once, after the compaction ends
    And Pi never gets a message whose turn the user stops before then

    Examples:
      | when                    | sends                |
      | after a finished turn   | sends                |
      | inside the running turn | steers the turn with |

  Scenario Outline: A Pi retry shows its attempt and how it ended
    When Pi's request to the model fails and <outcome>
    Then the work log shows <shown>

    Examples:
      | outcome                         | shown                                                            |
      | Pi waits to try again           | the attempt number, the most attempts allowed and the wait      |
      | Pi gives no reason for it       | the error "Pi provider request failed."                          |
      | every attempt fails             | the turn failing with Pi's last error, or "Pi auto-retry failed." |

  Scenario Outline: A Pi failure without a reason gets a plain message
    When Pi <fails> without giving a reason
    Then the user is told "<message>"

    Examples:
      | fails                                | message                         |
      | reports a model error                | Pi reported a model error.      |
      | rejects the user's message           | Pi rejected the prompt.         |
      | cannot compact when asked by a steer | Pi compact failed.              |
      | is stopped while a turn runs         | Pi process was stopped.         |
      | exits while a turn runs              | Pi process exited unexpectedly. |

  Scenario: A model at capacity is reported in the thread's error banner
    When the model Pi uses answers that it is at capacity due to high demand
    Then the thread's error says "Provider overloaded: The model is currently at capacity due to high demand."

  Scenario: Choosing "Pi default" again restores Pi's own model and thinking level
    Given a Pi thread whose model the user changed from "Pi default" to another model
    When the user chooses "Pi default" again
    Then Pi goes back to the model and thinking level it started with

  Scenario: A Pi model named without its provider is refused
    When a turn asks Pi for the model "sonnet"
    Then the turn is refused with "Pi model 'sonnet' must use provider/model format"

  Scenario: The thread's title becomes the Pi session's name
    Given a Pi thread titled "Fix flaky login test"
    When the thread next talks to Pi
    Then Pi's session is named "Fix flaky login test"
    And Pi's own session list shows it under that name

  Scenario: A file Pi cannot take as an image is handed over as a saved path
    When the user attaches a PDF to a Pi message
    Then Pi receives the line "[Attachment saved at" followed by the file's path

  # Upstream #21356: Pi silently skipped an attachment whose saved copy could not be found.
  @mc @plugin-pi
  Scenario: Pi is told when an attachment's saved copy cannot be found
    Given the saved copy of "notes.pdf" attached to a Pi message cannot be found
    When the message reaches Pi
    Then Pi is told "notes.pdf" is unavailable

  Scenario Outline: A message sent while Pi works joins the run or starts one
    Given a Pi turn that <state>
    When the user steers the thread with "also update the docs"
    Then <outcome>

    Examples:
      | state                                  | outcome                                        |
      | is still working                       | the message is queued into the running work    |
      | went idle just before the steer landed | the message starts new work in the same turn   |

  Scenario: A message Pi refuses while it works is an error for its sender
    Given a Pi turn that is still working
    When the user steers the thread with a message Pi refuses
    Then the sender hears Pi did not take the message
    And the Pi turn runs on without it

  Scenario: Two messages Pi declines once its run settled are each sent on their own
    Given a Pi turn that went idle just before two steers landed
    When the user steers the thread with two messages at once that Pi declines
    Then each message is sent on its own after the turn

  Scenario: A message Pi never answers once its run settled stays in the turn
    Given a Pi turn that went idle just before the steer landed
    When the user steers the thread with a message Pi never answers
    Then the turn ends with the message in it

  Scenario: A message Pi exits on is sent on its own once the turn failed
    Given a Pi turn that is still working
    When the user steers the thread with a message Pi exits on
    Then the message is sent on its own after the turn

  Scenario: A message Pi has not answered when the user stops the turn is not sent again
    Given a Pi turn that is still working
    When the user steers the thread with a message Pi holds and stops the turn
    Then the stopped turn ends with the message in it and no new turn starts

  Scenario: A message Pi declines after the user stopped its settled turn is not sent again
    Given a Pi turn that went idle just before the steer landed
    When the user steers the thread with a message Pi declines after the turn is stopped
    Then the stopped turn ends with the message in it and no new turn starts

  # Upstream #27514: Pi started a message waiting in its own queue as soon as Stop aborted the turn,
  # and the next turn sent it to the model again.
  @backlog
  Scenario: Stopping a Pi turn drops what waits in Pi's own queue
    Given Pi 0.84.4 or newer holds a steer in its own queue
    When the user stops the turn
    Then Pi's queue is cleared before the turn is aborted
    And the stopped turn shows a notice listing the message Pi never read
    And the next turn does not send that message
    And messages HAL-C2 queued for the thread stay queued

  Scenario: Steering a Pi thread with /compact compacts instead of prompting
    Given a Pi turn is running
    When the user steers the thread with "/compact"
    Then Pi compacts its conversation
    And "/compact" is not sent to the model as a message

  Scenario: Stopping a turn while a steered compaction runs does not hold up the next turn
    Given a Pi turn that is still working while Pi compacts slowly
    When the user steers the thread with "/compact" and stops the turn before Pi finishes compacting
    Then the steer is answered and the turn is stopped
    And the next Pi turn finishes

  Scenario: A stopped steered compaction that finishes during the next turn does not show there
    Given a Pi turn that is still working while Pi compacts for a few seconds
    When the user steers the thread with "/compact" and stops the turn before Pi finishes compacting
    Then the steer is answered and the turn is stopped
    When the next Pi turn runs while Pi finishes the stopped compaction and then compacts again
    Then the next turn shows only its own compaction

  Scenario: A turn sent while a stopped compaction finishes waits for it instead of settling as idle
    Given a Pi turn that is still working while Pi compacts for a few seconds
    When the user steers the thread with "/compact" and stops the turn before Pi finishes compacting
    Then the steer is answered and the turn is stopped
    When the user sends a message Pi starts only once the stopped compaction ends
    Then that turn waits for the compaction and runs to its end

  Scenario: A stopped steered compaction that fails without an end does not hide the next compaction
    Given a Pi turn that is still working while Pi's compaction fails slowly without an end event
    When the user steers the thread with "/compact" and stops the turn before Pi finishes compacting
    Then the steer is answered and the turn is stopped
    When Pi's failed answer has landed and the user sends "/compact"
    Then Pi compacts its conversation
    And the work log shows the compaction

  Scenario: A message that only starts with /compact is an ordinary message
    When the user sends "/compacted logs look wrong" to a Pi thread
    Then Pi receives it as an ordinary message

  Scenario: Pi's own subagents show as entries in the thread
    Given Pi has its subagent extension
    When Pi hands three tasks to its own subagents
    Then the thread shows one entry per task with its progress and result
    And no child thread is created for them

  # Upstream #27521: a tool Pi ran through another tool, such as a script's calls, showed as unrelated work.
  @backlog
  Scenario: A tool Pi calls through another tool shows under its caller
    Given Pi runs a script that calls two tools
    When the tools start, update and finish
    Then both tools show inside the script's entry in the work log
    And a tool Pi calls on its own shows at the top of the turn

  Scenario: A tool Pi was running when the user stopped shows as stopped
    Given Pi is running a command
    When the user stops the turn
    Then the command shows as interrupted, not failed

  Scenario Outline: Long Pi texts are cut to a limit
    When Pi sends <text> longer than its limit
    Then the thread keeps its first <limit> characters

    Examples:
      | text                                   | limit  |
      | the input of a tool awaiting approval  | 4,000  |
      | the reason a compaction failed         | 1,000  |
      | the detail of an extension's failure   | 2,000  |
      | the current value of a text edit       | 2,000  |

  Scenario Outline: Long texts from Pi's own subagents are cut to a limit
    When Pi sends <text> longer than its limit
    Then the thread keeps its first <limit> characters

    Examples:
      | text                                      | limit  |
      | the progress line of one of its subagents | 200    |
      | the result of one of its subagents        | 10,000 |

  Scenario: Pi's skills not loading in time do not hold up the thread
    Given Pi does not list its skills within 4 seconds
    When a Pi thread starts
    Then the thread is ready without them
    And the skills are looked up again the first time the user mentions one

  Scenario: Reopening a Pi session that does not answer within a minute stops Pi
    Given a Pi thread with history
    When Pi does not finish reopening that session within 60 seconds
    Then the Pi process is stopped
    And the user is told the session could not be opened

  Scenario: A Pi extension can refuse reopening a session
    Given a Pi extension cancels switching sessions
    When the user opens a Pi thread with history
    Then the thread fails to start saying "A Pi extension cancelled the session switch"

  @backlog
  Scenario Outline: Pi refuses a revert or fork it cannot carry out
    Given <situation>
    When the user <action>
    Then it is refused with "<message>"

    Examples:
      | situation                                             | action                  | message                                                |
      | a Pi turn is running                                  | reverts an earlier turn | Cannot roll back while a Pi turn is active             |
      | the turn to return to was never recorded in Pi's file | reverts to that turn    | Pi rollback target has no captured session-tree entry  |
      | a Pi extension cancels the rewind                     | reverts an earlier turn | A Pi extension cancelled the session fork              |
      | a Pi turn is running                                  | forks the thread        | Cannot fork while a Pi turn is active                  |
      | the Pi thread has no session file yet                 | forks the thread        | Pi fork source has no session file                     |
      | the turn to fork from is unknown                      | forks from that turn    | Pi fork target turn is missing                         |
      | the turn to fork from was never recorded in Pi's file | forks from that turn    | Pi fork boundary has no captured session-tree entry    |
      | Pi does not write a new session file for the fork     | forks the thread        | Pi fork did not create a distinct session file         |

  Scenario: Forking a Pi thread does not run the user's extensions or tools
    Given a Pi thread whose installation has extensions
    When the user forks the Pi thread
    Then the copy of Pi's conversation is made with extensions and tools turned off

  @backlog
  Scenario: A restarted Pi thread shows only the conversation Pi still has
    Given a Pi thread that was reverted to its first turn
    When the MC restarts and the thread is read back from Pi's session file
    Then only the turns on Pi's current branch are shown

  Scenario: Pi is updated through npm
    Given the pi command on the MC was installed with npm
    When the user updates Pi from HAL-C2
    Then the Pi package is updated by npm
    And a Pi that npm does not own can only be updated by hand

  # PiAdapterV2.ts: how Pi's tools, extension requests and session files read in the thread.
  Scenario Outline: Pi's tool calls are shown by kind
    When Pi runs its <tool> tool
    Then the thread shows <entry>

    Examples:
      | tool                         | entry                                                          |
      | bash                         | a command with what was run, its output and its exit code      |
      | edit                         | a file change naming the file Pi edited                       |
      | write                        | a file change naming the file Pi edited                       |
      | edit, without naming a file  | a plain tool call named after the tool, with what it was given |
      | grep                         | a plain tool call named after the tool, with what it was given |

  Scenario Outline: A Pi subagent entry shows how it ended
    Given Pi handed a task to one of its own subagents
    When Pi's subagent <ends>
    Then its entry is shown as <state>

    Examples:
      | ends                               | state       |
      | has not finished                   | running     |
      | finishes                           | completed   |
      | is aborted                         | interrupted |
      | exits with a code other than zero  | failed      |
      | stops on an error                  | failed      |

  # Upstream #23901 moved the status line out of this list: Pi extension statuses are now shown.
  Scenario: Requests that only dress Pi's own terminal are ignored
    When a Pi extension sets a widget, the window title or the editor's text
    Then nothing is shown in the thread
    And the turn carries on

  # Upstream #23901: Pi extensions publish keyed status text, which was thrown away.
  @backlog @shared
  Scenario: A Pi extension's status shows above the composer
    When a Pi extension sets its status "plan" to "Planning step 2 of 4"
    Then the thread shows "Planning step 2 of 4" above the composer, on the phone in its floating control
    When the extension sets "plan" to "Planning step 3 of 4"
    Then that status reads "Planning step 3 of 4" in place of the old one
    When the extension clears "plan"
    Then the status is gone

  # Upstream #23901: statuses outlive a failed turn the session can reuse, and go with the session.
  @backlog @priority-low
  Scenario: A Pi extension's status lasts as long as its session
    Given a Pi extension set a status in the thread
    When a turn fails and Pi's session can still be used
    Then the status is still shown, and an idle thread does not read "Working"
    But once Pi's session ends, or the MC restarts with that session dead, the status is gone

  Scenario: Allowing a Pi request for the session does not cover a different request
    Given the user allowed a Pi extension's confirmation for the session
    When the extension asks to confirm something with a different title or message
    Then the user is asked again
    And the same confirmation asked again is allowed without asking

  Scenario: A steer Pi refuses does not end the turn
    Given a Pi turn is running
    When Pi refuses a message the user steered the thread with
    Then the turn keeps running and its output keeps arriving
    And the turn is not reported as failed

  Scenario: A model error Pi recovers from by compacting is not a failure
    Given the model refused a Pi request because the conversation was too long
    When Pi compacts the conversation and says it will try again
    Then the turn is not reported as failed
    And a compaction that will not try again leaves an earlier failure in place

  @backlog
  Scenario: A HAL-C2 tool that fails is reported to Pi as a failure
    When a HAL-C2 tool Pi called answers with an error
    Then Pi receives the tool's text marked as an error

  Scenario: A Pi session with no file of its own is refused
    When Pi reports no file for the session
    Then the thread fails to start with "get_state returned no persisted sessionFile"

  @backlog
  Scenario: A Pi session that reuses another thread's file is refused
    When Pi reuses the previous thread's file for a new thread
    Then the thread fails to start with "Pi did not create a distinct session file"

  # HalC2.Plugins.Kinds: another instance runs with its own settings, home and account,
  # so its turn needs its own process rather than the first instance's.
  Scenario: A turn on another instance of Pi starts its own process
    Given Pi is installed and enabled
    And the user sends a message to Pi
    And a second instance "pi-work" of it with a binary of its own
    When the next message goes to "pi-work"
    Then a process of "pi-work" runs that turn in place of the first instance's
    And another message to "pi-work" stays in that process

  # Upstream #16210: Pi thread titles use the linked pull request's context
  @mc @plugin-pi
  Scenario: A Pi thread title takes the linked pull request into account
    Given a Pi thread is linked to a pull request
    When Pi writes the thread's title
    Then the pull request's context is part of what Pi is asked

  # Upstream #16661: discovered Pi models keep their provider identity
  @mc @shared @plugin-pi @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: Pi's discovered models show and search by their underlying provider
    Given Pi discovered models from the providers "openai" and "anthropic"
    When the user opens the model picker and searches for "anthropic"
    Then the models from that provider are listed with its name

  # Upstream #17214: Pi extension wakes get an owned continuation turn
  @mc @plugin-pi
  Scenario: Work a Pi extension starts after a turn settled runs as its own turn
    Given a Pi thread whose last turn has finished
    When a Pi extension wakes Pi to continue on its own
    Then the thread gets a new turn that shows Pi's work
    And Pi is not prompted a second time for it

  # Upstream #17214: a joining prompt claims the outstanding extension wake
  @mc @plugin-pi
  Scenario: A message sent while an extension's wake is pending joins that work
    Given a Pi extension has woken Pi after the last turn
    When the user sends a message to the Pi thread before the wake's turn starts
    Then the message's turn shows the extension's work and the reply to the message

  # Upstream #17214: rollback does not replay output from a discarded session
  @mc @plugin-pi
  Scenario: Reverting a Pi thread does not replay work from the discarded conversation
    Given a Pi extension has woken Pi after the last turn
    When the user reverts the Pi thread to an earlier turn
    Then the revert is refused until the woken work is settled or stopped
    And nothing from the discarded conversation appears in the thread afterwards

  # Upstream #17220: Pi discovers the optional tools on demand
  @backlog @mc @plugin-pi
  Scenario Outline: Pi is offered the HAL-C2 tools the way its version can find them
    Given Pi <version> is installed
    When a Pi thread starts
    Then <how>
    And tool selections the user made with Pi's tool flags keep applying by tool name

    Examples:
      | version         | how                                                                                            |
      | 0.99 or newer   | Pi finds the optional HAL-C2 tools by searching, and the delegation tools are offered directly |
      | older than 0.99 | every HAL-C2 tool is offered directly                                                          |

  # Upstream #17190: Pi discovers workspace skills and commands
  @mc @plugin-pi
  Scenario: Pi offers the skills and commands of the thread's own workspace
    Given the project "web" has its own Pi skill "release" and prompt template "triage"
    When the user opens the skill menu in a Pi thread of "web"
    Then "release" and "triage" are offered
    And a Pi thread of another project does not offer them

  # Upstream #17190: Pi discovers workspace skills and commands
  @mc @plugin-pi
  Scenario: A workspace whose Pi commands cannot be found keeps the ones it had
    Given a Pi thread of "web" offered the skill "release"
    When finding the workspace's Pi commands fails
    Then "release" is still offered

  # Upstream #13839: Pi native session rewinds are reconciled
  @mc @plugin-pi
  Scenario: A rewind made inside Pi drops the abandoned turns from the thread
    Given a Pi thread with three turns
    When a Pi extension rewinds Pi's session to the end of the first turn
    Then the thread no longer counts the second and third turns as Pi's history
    And reverting the thread afterwards only offers turns Pi still has

  # Upstream #17851: Pi tool images and structured results are preserved. The MC stores the
  # image with the thread and lists it in the tool item's attachments; the clients still have
  # to draw a tool item's attachments.
  @mc @shared @plugin-pi @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: An image a Pi tool returns is shown as an image
    When a Pi tool returns a screenshot alongside structured results
    Then the tool call shows the screenshot as an image, not as text
    And its structured results are kept in the tool's details

  # Upstream #17853: Pi native abort outcomes are preserved
  @mc @plugin-pi
  Scenario: A turn Pi aborts on its own reads as interrupted
    When Pi aborts a turn itself, for an extension, a compaction or a session replacement
    Then the turn reads as interrupted, not completed
    And the next turn Pi starts reads as its own outcome

  # Upstream #17835: thinking defaults are specific to each model
  @mc @plugin-pi
  Scenario: Only the model Pi is set to marks Pi's thinking level as its default
    Given Pi is set to model "a" at thinking level high
    When the user opens the thinking options for Pi model "b"
    Then no level is marked as Pi's default for "b"
    And for "a" high is marked as the default

  # Upstream #17834: Pi shell command exit codes are preserved
  @mc @plugin-pi
  Scenario Outline: A Pi shell command keeps its exit code
    When Pi runs <shell> on a Pi version that reports the exit code <where>
    Then the step shows as a command with exit code 2

    Examples:
      | shell              | where                              |
      | a bash command     | in its structured result           |
      | a bash command     | in its details, as older Pi does   |
      | a PowerShell command | in its structured result         |

  # Upstream #17840: extension approvals expire and cancel
  @backlog @mc @plugin-pi
  Scenario: A Pi extension's approval goes away when Pi stops waiting for it
    Given a Pi extension asked the user to approve with a time limit
    When the time limit passes, or the Pi process dies, before the user answers
    Then the approval is no longer pending
    And an answer the user sends afterwards is refused and not remembered

  # Upstream #17852: known read-only tools skip approval
  @backlog @mc @plugin-pi
  Scenario Outline: Pi asks before HAL-C2's tools only when they change something
    Given the thread runs Pi in approval required
    When Pi calls <tool>
    Then it is <outcome>

    Examples:
      | tool                                             | outcome                |
      | a HAL-C2 tool marked read-only                   | allowed without asking |
      | a HAL-C2 tool that changes something             | asked for approval     |
      | a read-only tool from another MCP server         | asked for approval     |

  # Upstream #15368: extension notifications were a "notify" tool call folded into the work log.
  @shared @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A Pi extension notification shows as a notice in the thread
    When a Pi extension sends the notification "Lint finished\n3 warnings"
    Then the thread shows a notice with both lines
    And it is not folded into the tool calls

  # Upstream #15791: ids built from the per-turn ordinal let one thread's notice replace another's.
  Scenario: Pi notices in two threads stay apart
    Given Pi threads "t1" and "t2" each send a notification as the first item of a turn
    When the user opens each thread
    Then "t1" shows its own notice
    And "t2" shows its own notice

  # Upstream #30187: Pi renews expired logins in the background as it starts, and the MC stopped
  # its short-lived Pi processes mid-renewal, leaving a spent token so the next sign-in failed.
  Scenario: A short-lived Pi process does not spend the user's login renewal
    Given the user's Pi login has expired and is renewed with a single-use token
    When the MC starts Pi only to check its status, write a title or fork a session
    Then that Pi process starts without refreshing its catalog or logins
    And the user's next Pi turn still signs in
