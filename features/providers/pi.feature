# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-pi.md
#   docs/internals/providers.md (Pi RPC mode, forks through the CLI in the destination directory)
#   apps/server-ex/lib/hal_c2/pi.ex, apps/server-ex/lib/hal_c2/pi/thread_runtime.ex (Pi RPC mode)
#   apps/server/src/provider/Layers/PiProvider.ts, apps/server/src/provider/Drivers/PiDriver.ts
#   apps/server/src/orchestration-v2/Adapters/PiAdapterV2.ts, apps/server/src/orchestration-v2/Adapters/PiRpc.ts
#   apps/server/src/orchestration-v2/Adapters/piHalC2McpInjection.ts, apps/server/src/provider/PiCommands.ts
#   apps/server/src/orchestration-v2/Adapters/piHalC2McpExtensionSource.ts (approval hook, HAL-C2 tools bridge, OpenRouter output cap)
#   apps/server/src/provider/Layers/piThinkingCapabilities.ts, apps/server/src/textGeneration/PiTextGeneration.ts

@plugin-pi @mc
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

  # Health states of PiProvider.ts checkPiProviderStatus.
  @backlog
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

  @backlog
  Scenario: Pi stays available when its models and commands cannot be refreshed
    Given Pi discovery of its models and commands fails
    When the user refreshes provider status
    Then Pi stays available with the "Pi default" model
    And Pi is shown with a message that the live session will retry startup

  Scenario: Pi stays usable when discovery cannot finish
    Given Pi discovery needs interactive input
    When the user refreshes provider status
    Then Pi stays available with the "Pi default" model
    And the first thread lets Pi handle its startup prompt

  Scenario: Pi thinking levels follow the model
    Given the Pi model supports thinking levels up to extra high
    When the user opens the options for that model
    Then off, minimal, low, medium, high and extra high are offered
    And Pi's configured level is marked as the default

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

  Scenario: Forking a Pi thread copies the native conversation into the new workspace
    Given a Pi thread with three turns
    When the user forks from the second turn into a new worktree
    Then the new thread continues Pi's conversation through the second turn in that worktree

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

  # PiCommands.ts: Pi's command list omits its terminal built-ins, and Pi only expands
  # skills written as leading "/skill:name" commands.
  @backlog
  Scenario: Pi offers /compact although Pi does not list it
    When the user types a slash in a Pi thread
    Then "/compact" is offered

  @backlog
  Scenario: Sending /compact compacts the Pi conversation
    When the user sends "/compact" to a Pi thread
    Then Pi compacts its conversation
    And the work log shows the compaction

  @backlog
  Scenario: Sending /compact with instructions passes them to Pi
    When the user sends "/compact keep the database notes" to a Pi thread
    Then Pi compacts its conversation following "keep the database notes"

  @backlog
  Scenario: Skill mentions are moved to the start for Pi
    Given Pi has the skills "deploy" and "review"
    When the user sends "please $review this and then $deploy it" to a Pi thread
    Then Pi receives "/skill:review /skill:deploy please this and then it"

  @backlog
  Scenario: A dollar word that is not a Pi skill is left as written
    Given Pi has the skill "deploy"
    When the user sends "the price is $5 and $deploy it" to a Pi thread
    Then Pi receives "/skill:deploy the price is $5 and it"

  @backlog
  Scenario: A skill mentioned twice is expanded once
    Given Pi has the skill "deploy"
    When the user sends "$deploy and again $deploy" to a Pi thread
    Then Pi receives one "/skill:deploy" at the start

  # piHalC2McpInjection.ts: the arguments HAL-C2 owns, in their "--flag" and "--flag=value" forms.
  @backlog
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

  @backlog
  Scenario: A launch argument meant for a Pi extension is passed on to Pi
    Given a Pi extension takes the argument "--plan-depth 3"
    When the user adds the launch argument "--plan-depth 3" to Pi
    Then the setting is accepted
    And Pi starts with "--plan-depth 3"

  @backlog
  Scenario: Pi starts with the user's own extensions, skills, settings and logins
    Given the user's Pi installation has extensions, skills, project instructions and saved logins
    When a Pi thread starts
    Then Pi loads all of them as it does in its own terminal app

  @backlog
  Scenario: Pi writing titles and commit messages runs without tools, extensions or a saved session
    Given Pi's launch arguments name an extension and a tool list
    When Pi writes a thread title
    Then Pi runs with every tool and extension turned off
    And no Pi session file is left behind

  @backlog
  Scenario: Pi never inherits another session's HAL-C2 credential
    Given the MC itself was started by an agent that holds a HAL-C2 tools credential
    When a Pi thread starts
    Then Pi receives only the credential of its own thread

  # PiRpc.ts: Pi's own output shares the channel HAL-C2 talks to it on.
  @backlog
  Scenario: Stray output from a Pi extension does not break the session
    Given a Pi extension prints text that is not part of Pi's protocol
    When the user sends a message to Pi
    Then the stray text is ignored
    And the turn finishes normally

  @backlog
  Scenario: A single Pi message larger than 8 MiB is dropped
    When Pi sends one message larger than 8 MiB
    Then that message is dropped
    And the session keeps running

  @backlog
  Scenario: Text containing Unicode line separators reaches the thread intact
    When Pi answers with text that contains the characters U+2028 and U+2029
    Then the reply shows the whole text

  @backlog
  Scenario Outline: A Pi request that goes wrong says what failed
    Given a Pi thread is starting
    When <problem>
    Then the user is told "<message>"

    Examples:
      | problem                                          | message                                                  |
      | Pi does not answer a request within its deadline | Pi RPC get_state failed: timed out after 15000ms.        |
      | Pi exits with code 2 before answering            | Pi RPC get_state failed: pi process exited with code 2.  |
      | Pi closes its output before answering            | Pi RPC get_state failed: pi process closed stdout.       |

  @backlog
  Scenario: A long Pi failure detail is cut to 200 characters
    When Pi refuses a request with an explanation of 5,000 characters
    Then the failure the user sees carries its first 200 characters followed by an ellipsis

  @backlog
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

  @backlog
  Scenario: A Pi that fails while starting is not left running
    When Pi starts but the session cannot finish setting up
    Then the Pi process is stopped

  # piHalC2McpExtensionSource.ts: the extension HAL-C2 loads into Pi for approvals and its tools.
  @backlog
  Scenario: A Pi tool the user declines is blocked with a reason Pi can read
    Given the thread runs Pi in approval required
    When Pi asks to run a command and the user declines
    Then the command does not run
    And Pi is told "bash was declined in HAL-C2."

  @backlog
  Scenario: Pi's approval request shows what the tool was asked to do
    Given the thread runs Pi in approval required
    When Pi asks to run "npm test"
    Then the approval is titled "Allow bash?"
    And it shows the command Pi wants to run

  @backlog
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

  @backlog
  Scenario: HAL-C2's instructions do not stop a Pi slash command from expanding
    Given Pi has the prompt command "/review"
    When the user sends "/review the last change" to a Pi thread
    Then Pi receives the message unchanged and expands "/review"
    And HAL-C2's own instructions reach Pi as part of its system prompt

  # Works around Pi asking OpenRouter for more output than the context can hold.
  @backlog
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

  @backlog
  Scenario: A message an extension command handles without the agent still ends its turn
    Given a Pi extension handles "/stats" without starting agent work
    When the user sends "/stats" to a Pi thread
    Then the turn finishes once Pi is idle
    And it is not left running

  @backlog
  Scenario: Pi going silent after a message stops the session
    Given Pi accepted a message but never reports whether it is working
    When three checks of Pi's state fail
    Then the Pi process is stopped
    And the turn fails

  @backlog
  Scenario: A notice from a Pi extension shows in the work log
    When a Pi extension shows the warning "Lint found 3 problems"
    Then the work log shows "Lint found 3 problems" as a warning

  @backlog
  Scenario Outline: A Pi extension's text prompt can be answered with nothing
    When a Pi extension asks the user for <kind>
    Then the user can type an answer or choose "Submit empty value"
    And choosing it sends an empty answer to the extension

    Examples:
      | kind               |
      | a line of text     |
      | a longer text edit |

  @backlog
  Scenario: A Pi extension's text edit shows what is there now
    When a Pi extension asks the user to edit a text that already has content
    Then the request shows that content under "Current value:"

  @backlog
  Scenario: An empty choice from a Pi extension can still be picked
    When a Pi extension offers a list whose choices include an empty one
    Then that choice is offered as "Empty value"

  @backlog
  Scenario: Dismissing a Pi extension's dialog cancels it for the extension
    Given a Pi extension asked the user to pick from a list
    When the user dismisses the request
    Then the extension is told the dialog was cancelled

  @backlog
  Scenario: An answer that could not reach Pi can be sent again
    Given a Pi extension asked the user a question
    When the user's answer cannot be delivered to Pi
    Then the question stays open for another answer

  @backlog
  Scenario: Answering a Pi request that is no longer open is refused
    When a client answers the Pi request "r9" that is not open
    Then the answer is refused with "No pending Pi extension request r9"

  @backlog
  Scenario: A failing Pi extension is named in the work log
    Given the Pi extension "auto-lint" fails while a tool runs
    When the turn continues
    Then the work log shows a failed entry titled "auto-lint"
    And it says during which step the extension failed and why

  @backlog
  Scenario: A Pi extension failing between turns is shown on the next turn
    Given a Pi extension failed while no turn was running
    When the user sends the next message
    Then that turn's work log shows the extension's failure

  @backlog
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

  @backlog
  Scenario: Stopping a Pi thread while it compacts restarts Pi
    Given Pi is compacting the conversation
    When the user stops the turn
    Then Pi is given 2 seconds to stop the compaction and is then restarted
    And the thread can take the next message

  @backlog
  Scenario Outline: A Pi retry shows its attempt and how it ended
    When Pi's request to the model fails and <outcome>
    Then the work log shows <shown>

    Examples:
      | outcome                         | shown                                                            |
      | Pi waits to try again           | the attempt number, the most attempts allowed and the wait      |
      | Pi gives no reason for it       | "Pi provider request failed."                                    |
      | every attempt fails             | the turn failing with Pi's last error, or "Pi auto-retry failed." |

  @backlog
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

  @backlog
  Scenario: A model at capacity is reported in the thread's error banner
    When the model Pi uses answers that it is at capacity due to high demand
    Then the thread's error says "Provider overloaded: The model is currently at capacity due to high demand."

  @backlog
  Scenario: Choosing "Pi default" again restores Pi's own model and thinking level
    Given a Pi thread whose model the user changed from "Pi default" to another model
    When the user chooses "Pi default" again
    Then Pi goes back to the model and thinking level it started with

  @backlog
  Scenario: A Pi model named without its provider is refused
    When a turn asks Pi for the model "sonnet"
    Then the turn is refused with "Pi model 'sonnet' must use provider/model format"

  @backlog
  Scenario: The thread's title becomes the Pi session's name
    Given a Pi thread titled "Fix flaky login test"
    When the thread next talks to Pi
    Then Pi's session is named "Fix flaky login test"
    And Pi's own session list shows it under that name

  @backlog
  Scenario: A file Pi cannot take as an image is handed over as a saved path
    When the user attaches a PDF to a Pi message
    Then Pi receives the line "[Attachment saved at" followed by the file's path

  @backlog
  Scenario Outline: A message sent while Pi works joins the run or starts one
    Given a Pi turn that <state>
    When the user steers the thread with "also update the docs"
    Then <outcome>

    Examples:
      | state                                  | outcome                                        |
      | is still working                       | the message is queued into the running work    |
      | went idle just before the steer landed | the message starts new work in the same turn   |

  @backlog
  Scenario: Steering a Pi thread with /compact compacts instead of prompting
    Given a Pi turn is running
    When the user steers the thread with "/compact"
    Then Pi compacts its conversation
    And "/compact" is not sent to the model as a message

  @backlog
  Scenario: A message that only starts with /compact is an ordinary message
    When the user sends "/compacted logs look wrong" to a Pi thread
    Then Pi receives it as an ordinary message

  @backlog
  Scenario: Pi's own subagents show as entries in the thread
    Given Pi has its subagent extension
    When Pi hands three tasks to its own subagents
    Then the thread shows one entry per task with its progress and result
    And no child thread is created for them

  @backlog
  Scenario: A tool Pi was running when the user stopped shows as stopped
    Given Pi is running a command
    When the user stops the turn
    Then the command shows as interrupted, not failed

  @backlog
  Scenario Outline: Long Pi texts are cut to a limit
    When Pi sends <text> longer than its limit
    Then the thread keeps its first <limit> characters

    Examples:
      | text                                   | limit  |
      | the input of a tool awaiting approval  | 4,000  |
      | the reason a compaction failed         | 1,000  |
      | the detail of an extension's failure   | 2,000  |
      | the current value of a text edit       | 2,000  |
      | the progress line of one of its subagents | 200 |
      | the result of one of its subagents     | 10,000 |

  @backlog
  Scenario: Pi's skills not loading in time do not hold up the thread
    Given Pi does not list its skills within 4 seconds
    When a Pi thread starts
    Then the thread is ready without them
    And the skills are looked up again the first time the user mentions one

  @backlog
  Scenario: Reopening a Pi session that does not answer within a minute stops Pi
    Given a Pi thread with history
    When Pi does not finish reopening that session within 60 seconds
    Then the Pi process is stopped
    And the user is told the session could not be opened

  @backlog
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

  @backlog
  Scenario: Forking a Pi thread does not run the user's extensions or tools
    Given a Pi thread whose installation has extensions
    When the user forks the thread
    Then the copy of Pi's conversation is made with extensions and tools turned off

  @backlog
  Scenario: A restarted Pi thread shows only the conversation Pi still has
    Given a Pi thread that was reverted to its first turn
    When the MC restarts and the thread is read back from Pi's session file
    Then only the turns on Pi's current branch are shown

  @backlog
  Scenario: Pi is updated through npm
    Given the pi command on the MC was installed with npm
    When the user updates Pi from HAL-C2
    Then the Pi package is updated by npm
    And a Pi that npm does not own can only be updated by hand

  # PiAdapterV2.ts: how Pi's tools, extension requests and session files read in the thread.
  @backlog
  Scenario Outline: Pi's tool calls are shown by kind
    When Pi runs its <tool> tool
    Then the thread shows <entry>

    Examples:
      | tool                         | entry                                                          |
      | bash                         | a command with what was run, its output and its exit code      |
      | edit                         | a file change naming the file                                  |
      | write                        | a file change naming the file                                  |
      | edit, without naming a file  | a plain tool call named after the tool, with what it was given |
      | grep                         | a plain tool call named after the tool, with what it was given |

  @backlog
  Scenario Outline: A Pi subagent entry shows how it ended
    Given Pi handed a task to one of its own subagents
    When the subagent <ends>
    Then its entry is shown as <state>

    Examples:
      | ends                               | state       |
      | has not finished                   | running     |
      | finishes                           | completed   |
      | is aborted                         | interrupted |
      | exits with a code other than zero  | failed      |
      | stops on an error                  | failed      |

  @backlog
  Scenario: Requests that only dress Pi's own terminal are ignored
    When a Pi extension sets a status line, a widget, the window title or the editor's text
    Then nothing is shown in the thread
    And the turn carries on

  @backlog
  Scenario: Allowing a Pi request for the session does not cover a different request
    Given the user allowed a Pi extension's confirmation for the session
    When the extension asks to confirm something with a different title or message
    Then the user is asked again
    And the same confirmation asked again is allowed without asking

  @backlog
  Scenario: A steer Pi refuses does not end the turn
    Given a Pi turn is running
    When Pi refuses a message the user steered the thread with
    Then the turn keeps running and its output keeps arriving
    And the turn is not reported as failed

  @backlog
  Scenario: A model error Pi recovers from by compacting is not a failure
    Given the model refused a Pi request because the conversation was too long
    When Pi compacts the conversation and says it will try again
    Then the turn is not reported as failed
    And a compaction that will not try again leaves an earlier failure in place

  @backlog
  Scenario: A HAL-C2 tool that fails is reported to Pi as a failure
    When a HAL-C2 tool Pi called answers with an error
    Then Pi receives the tool's text marked as an error

  @backlog
  Scenario Outline: A Pi session that is not kept in its own file is refused
    When <problem>
    Then the thread fails to start with "<message>"

    Examples:
      | problem                                               | message                                      |
      | Pi reports no file for the session                    | get_state returned no persisted sessionFile  |
      | Pi reuses the previous thread's file for a new thread | Pi did not create a distinct session file    |
