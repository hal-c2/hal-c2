# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-claude.md
#   docs/internals/providers.md (Claude homes, update ownership)
#   apps/server-ex/lib/hal_c2/claude/provider.ex, apps/server-ex/lib/hal_c2/claude/thread_runtime.ex, apps/server-ex/lib/hal_c2/claude/session.ex
#   apps/server-ex/lib/hal_c2/provider_updates.ex (claudeAgent advisory, claude update)
#   apps/server-ex/lib/hal_c2/provider_usage_limits/claude.ex (get_usage)
#   apps/server-ex/lib/hal_c2/text_generation.ex (claude -p)
#   apps/server/src/provider/Layers/ClaudeProvider.ts, apps/server/src/provider/ClaudeModelCatalog.ts, apps/server/src/provider/ClaudeModelManifest.ts, apps/server-ex/priv/model-manifest.json
#   @anthropic-ai/claude-agent-sdk sdk.d.ts (ModelInfo, SDKControlInitializeResponse.models: the models Claude Code lists at initialize)
#   apps/server/src/provider/Drivers/ClaudeDriver.ts, apps/server/src/provider/Drivers/ClaudeHome.ts
#   apps/server/src/provider/Drivers/ClaudeExecutable.ts (Windows launcher scripts)
#   apps/server/src/provider/Drivers/ClaudeSkills.ts, apps/server/src/provider/Drivers/ClaudeSkillDispatch.ts (skill folders, overrides, mentions)
#   apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts
#   apps/server/src/claudeModelOptions.ts (context window, thinking and effort options)
#   apps/server/src/orchestration-v2/testkit/fixtures/claude_result_is_error, claude_local_bash_task
#   apps/server/src/provider/Layers/claudeUsageLimits.ts

@plugin-claude @mc
Feature: Claude
  Claude Code runs as a bundled provider plugin. The MC drives the local claude CLI,
  so sign-in, subscription and API keys stay with the CLI on the machine that runs it.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Claude is offered when the claude command is on the MC's path
    Given the claude command is installed on the MC
    When the user opens the provider list
    Then Claude is listed as ready with its installed version

  Scenario: Claude is not offered when the claude command is missing
    Given the claude command is not installed on the MC
    When the user opens the provider list
    Then Claude is not offered as a provider

  Scenario: An outdated Claude shows that an update is available
    Given the installed Claude is older than the latest published version
    When the user opens the provider list
    Then Claude shows that an update is available and how it will be installed

  Scenario: Updating Claude uses the installer that owns it
    Given Claude was installed by its own native installer and is outdated
    When the user updates Claude
    Then Claude updates itself and the new version is shown

  Scenario: Claude that no installer owns can only be updated by hand
    Given Claude was installed in a way the MC cannot identify
    When the user opens the update details for Claude
    Then the user is told to update Claude by hand

  Scenario: Claude's models come from the installed Claude Code
    Given the installed Claude lists its models
    When the MC has read the Claude model list
    Then Claude Code's models are offered in its order with its default marked
    And a thread saved on a model's full id shows the model that covers it

  Scenario: A model Claude Code lists keeps the options the manifest adds to it
    Given the installed Claude lists its models
    When the MC has read the Claude model list
    Then a listed model the manifest knows offers Claude Code's reasoning levels and ultrathink
    And a listed model the manifest does not know offers only Claude Code's reasoning levels

  Scenario: A model Claude Code lists runs even when the manifest asks for a newer Claude
    Given the installed Claude lists a model the manifest gates on a newer version
    When the user sends a message to Claude on that model
    Then Claude answers it on that model

  Scenario: Claude offers the models of the bundled model manifest until Claude Code lists its own
    Given the installed Claude does not list its models
    When the MC has read the Claude model list
    Then the manifest's Claude models are offered in its order
    And models the manifest marks as legacy are labelled legacy

  Scenario: Claude models that need a newer CLI are not offered
    Given the installed Claude is older than a model requires
    When the user opens the model picker for Claude
    Then that model is not offered

  @backlog
  Scenario: A Claude too old for a model says which version unlocks it
    Given the installed Claude "2.0.10" is older than the version a model requires
    When the user opens the provider list
    Then Claude shows "Claude Code v2.0.10 is too old for" that model
    And is told to upgrade to the version the model requires or newer

  @backlog
  Scenario: A Claude whose version cannot be read still names the version a model needs
    Given the installed Claude does not report its version
    When the user opens the provider list
    Then Claude shows "Claude Code the installed version is too old for" the model needing the lowest version
    And is told to upgrade to that version or newer

  @backlog
  Scenario Outline: Claude's health states are explained
    Given <situation>
    When the user opens the provider list
    Then Claude is shown with the message "<message>"

    Examples:
      | situation                                          | message                                                                           |
      | the claude command is not on the path              | Claude Agent CLI (`claude`) was not found on PATH.                                |
      | the claude command is found but cannot be run      | Failed to execute Claude Agent CLI health check.                                  |
      | the claude version check exits with an error       | Claude Agent CLI is installed but failed to run.                                  |
      | the claude version check does not finish in time   | Claude Agent CLI is installed but failed to run. Timed out while running command. |
      | claude runs but does not report its sign-in        | Could not verify Claude authentication status from initialization result.         |
      | Claude is turned off in the provider settings      | Claude is disabled in HAL-C2 settings.                                            |
      | the MC has not checked Claude yet since it started | Claude provider status has not been checked in this session yet.                  |

  Scenario: A Claude thread switches model between turns
    Given a Claude thread has answered on "claude-sonnet-5"
    When the user sends the next message on "claude-opus-5"
    Then Claude answers it on "claude-opus-5"
    And the conversation continues in the same Claude session

  Scenario: Claude shows the signed-in account
    Given the Claude CLI is signed in with a subscription
    When Claude's usage has been checked
    Then Claude shows the account's email and plan

  Scenario: A Claude turn streams its answer and its thinking
    When the user sends a message to Claude
    Then the answer appears as it is written
    And Claude's thinking is shown separately

  Scenario Outline: Claude tool calls are shown by kind
    When Claude uses the <tool> tool
    Then the timeline shows a <kind> step

    Examples:
      | tool      | kind           |
      | Edit      | file change    |
      | Write     | file change    |
      | Bash      | command        |
      | WebSearch | web            |
      | WebFetch  | web            |

  Scenario: A Claude turn can be steered while it runs
    Given a Claude turn is running
    When the user sends a follow-up message
    Then Claude receives the message during the running turn

  Scenario: Work Claude does by itself between turns is a run of its own
    Given a Claude turn has finished
    When Claude answers a finished background task by itself
    Then the thread shows a running run that Claude started, with Claude's answer
    When Claude finishes that work
    Then that run completes and the user's run stays completed

  Scenario: Claude's proposed plan becomes a plan the user can implement
    Given the thread is in plan mode on Claude
    When Claude finishes planning
    Then the plan is shown as a proposed plan
    And the user can implement it

  Scenario: Claude's questions are asked in HAL-C2
    When Claude asks the user a multiple choice question
    Then the question is shown with its choices
    And the user's answer is sent back to Claude

  Scenario: Claude can use the HAL-C2 tools
    Given the project allows the HAL-C2 tools
    When a Claude turn starts
    Then Claude can call the HAL-C2 tools for this thread

  Scenario: Reverting a Claude turn restores the conversation to that point
    Given a Claude thread with three turns
    When the user reverts to the end of the first turn
    Then Claude continues from the first turn as if the later turns never happened

  Scenario: Forking a Claude thread continues from the fork point in a new thread
    Given a Claude thread with three turns
    When the user forks from the second turn
    Then a new thread continues Claude's session from the second turn

  Scenario: Claude writes thread titles and commit messages
    Given Claude is picked for text generation
    When a new thread needs a title
    Then Claude writes the title without using any tools

  Scenario: Claude's rate-limit notices update the limits view
    When Claude reports that a usage window is nearly used up during a turn
    Then the limits view shows the new usage for that window

  Scenario: Several Claude accounts can run side by side
    Given the user adds a second Claude instance with its own config directory
    When the user signs in to the CLI with that config directory
    Then each instance uses its own account and history

  Scenario: Claude models come from the fetched model manifest
    When the model manifest lists a new Claude model
    Then the new model is offered after the next refresh

  Scenario: A Claude model that needs a newer CLI is explained
    Given the installed Claude is older than a model requires
    When the user picks that model
    Then the user is told which Claude version the model needs

  Scenario Outline: Claude model options
    Given the installed Claude can run every model in the manifest
    When the user opens the options for a Claude model that supports <option>
    Then the user can choose <choices>

    Examples:
      | option         | choices                                                   |
      | reasoning      | low, medium, high, extra high, max, ultracode, ultrathink |
      | fast mode      | on or off                                                 |
      | context window | 200k or 1M                                                |

  Scenario Outline: A Claude turn runs with the model options the user picked
    Given the installed Claude can run every model in the manifest
    When the user sends a message to Claude on a model with <option> set to "<value>"
    Then Claude is started with <started>

    Examples:
      | option         | value      | started                                            |
      | reasoning      | high       | the effort "high"                                  |
      | reasoning      | ultracode  | the effort "xhigh" and the setting "ultracode" on  |
      | reasoning      | ultrathink | no effort, and the message asks it to ultrathink   |
      | fast mode      | on         | the setting "fastMode" on                          |
      | thinking       | off        | the setting "alwaysThinkingEnabled" off            |
      | context window | 1m         | a model id ending in "[1m]"                        |

  Scenario: Claude compacts the conversation after the configured size
    Given the Claude instance compacts after 200000 tokens
    When the conversation grows past that size
    Then Claude compacts the conversation and the timeline says so

  Scenario: Resuming a long Claude conversation offers to compact first
    Given a Claude thread whose history is close to the context limit
    When the user resumes the Claude thread
    Then the user can compact and continue, keep the full history, or never be asked again

  Scenario: Claude subagents appear as child work in the timeline
    When Claude starts a subagent
    Then the subagent's work is grouped under the step that started it

  Scenario: A resumed Claude subagent keeps its continuation in its own thread
    Given Claude resumed a subagent after the MC restarted
    When the user opens the subagent's thread
    Then the thread shows the message that resumed it
    And the parent thread does not

  @shared @backlog-desktop @backlog-mobile
  Scenario: A Claude monitor shows as background work, not as a command
    Given Claude starts a monitor in the thread
    Then the thread lists the monitor as background work
    And the monitor is not shown as a command

  Scenario: Claude continues from the compacted conversation after compaction
    Given Claude compacted the conversation of a thread
    When the user sends the next message
    Then Claude continues from the compacted conversation
    And the context meter keeps the usage Claude reported after compaction

  Scenario: Claude can ask a question while planning
    Given the thread is in plan mode on Claude
    When Claude asks the user a question
    Then the question is shown
    And the plan stays pending until the user answers

  Scenario: Claude skills and slash commands are offered in the composer
    Given Claude reports the skill "review" and the command "/init"
    When the user types a slash in the composer
    Then "review" and "/init" are offered

  Scenario: Reverting a Claude thread is refused while a turn runs
    Given a Claude turn is running
    When the user tries to revert to an earlier turn
    Then the revert is refused until the turn ends

  Scenario: A signed-out Claude CLI explains how to sign in
    Given the Claude CLI on the MC is not signed in
    When the user sends a message to Claude
    Then the turn fails saying to run the Claude sign-in command on that machine

  @mc @backlog
  Scenario Outline: An API error Claude reports as a finished turn fails the run
    Given Claude ends a turn reporting the API error <status> as its result
    Then the run fails instead of completing
    And the failure carries the code "api_error_<status>" and is a provider error
    And the error text appears once in the thread

    Examples:
      | status |
      | 401    |
      | 529    |

  @mc @backlog
  Scenario: A turn that failed with an API error does not poison the Claude session
    Given the last Claude turn of a thread failed with an API error
    When the user sends the next message
    Then Claude answers it in the same session
    And the new run completes

  @mc @backlog
  Scenario: A command Claude runs in the background is not a subagent
    Given Claude runs a long command as a background task
    Then the thread shows the command and its output
    And no child thread or subagent is created for it

  Scenario: Claude can be disabled and enabled again
    When the user disables Claude
    Then Claude is not offered in the model picker
    When the user enables Claude
    Then Claude is offered again

  Scenario: A Claude instance can route through OpenRouter or another router
    Given a Claude instance with its own config directory and a router's endpoint and token in its environment
    And the router's model id is added as a custom model
    When the user sends a message with that model
    Then the turn runs through the router with that model

  Scenario: Claude usage windows include a per-model weekly window
    Given Claude is signed in with a subscription
    When the user opens the limits view
    Then Claude shows its session and weekly windows and a weekly window for the limited model

  @backlog @mc
  Scenario Outline: The Claude context meter is sized by the model's context window
    When a Claude turn runs on <model>
    Then the context meter is out of <size> tokens
    And what is used counts the input, cached and output tokens Claude reported

    Examples:
      | model                                  | size      |
      | Opus 4.6                               | 1,000,000 |
      | Opus 4.7                               | 1,000,000 |
      | a model with the 1M context window set | 1,000,000 |
      | any other model                        | 200,000   |

  @backlog @mc
  Scenario Outline: Claude is asked for summaries of its thinking unless they were turned off
    Given <setup>
    When the user sends a message to Claude
    Then Claude is <asked> for summaries of its thinking

    Examples:
      | setup                                                                   | asked     |
      | a Claude instance with no launch arguments                              | asked     |
      | a model with thinking set to off                                        | not asked |
      | a Claude instance with the launch argument "--thinking-display omitted" | not asked |

  @backlog @mc
  Scenario: Claude starts with the launch arguments configured for it
    Given the Claude instance has launch arguments configured
    When the user sends a message to Claude
    Then Claude is started with those arguments

  @backlog @mc
  Scenario Outline: A permission flag in Claude's launch arguments wins over the thread's mode
    Given the Claude instance has the launch argument "<argument>"
    And a Claude thread in supervised
    When the user sends a message
    Then Claude runs with the "<mode>" permission mode

    Examples:
      | argument                       | mode              |
      | --permission-mode acceptEdits  | acceptEdits       |
      | --dangerously-skip-permissions | bypassPermissions |

  @backlog @mc
  Scenario: A Claude run that may only read is given only its reading tools
    Given a Claude run that may only read the workspace and never asks for approval
    When the run starts
    Then Claude can use only its tools for reading and searching files

  @backlog @mc
  Scenario: A read-only Claude run can call only the HAL-C2 tools that read
    Given a Claude run that may only read the workspace and has the HAL-C2 tools
    When the run starts
    Then HAL-C2 tools that only read, such as listing threads, are allowed without asking
    And HAL-C2 tools that start threads or schedule tasks are not allowed

  @backlog @mc
  Scenario: Claude can open the files attached to a message
    When the user sends Claude a message with an attached file
    Then Claude is given access to the folder the MC saved the file in

  @backlog @mc
  Scenario: A skill mentioned in a message runs as Claude's own skill
    Given the project has the Claude skill "review"
    When the user sends "Please $review the diff" to Claude
    Then Claude runs its "review" skill
    And the rest of the message still reaches Claude

  @backlog @mc
  Scenario Outline: A skill Claude will not run for the user stays as text
    Given the project has the Claude skill "review" and <state>
    When the user sends "Please $review the diff" to Claude
    Then Claude receives the message as plain text

    Examples:
      | state                                        |
      | the skill is switched off                    |
      | the skill is marked not user-invocable       |
      | the skill was removed since the last message |

  @backlog @mc
  Scenario Outline: A Claude approval says what kind of permission the tool wants
    Given a Claude thread in supervised
    When Claude asks to use <tool>
    Then the user is asked for permission to <permission>

    Examples:
      | tool                                 | permission    |
      | Bash                                 | run a command |
      | Edit, MultiEdit, NotebookEdit, Write | change files  |
      | Read, Glob, Grep or LS               | read files    |
      | a tool HAL-C2 does not know          | run a command |

  @backlog @mc
  Scenario: A Claude approval names the tool and what it would act on
    Given a Claude thread in supervised
    When Claude asks to run the command "npm test"
    Then the approval reads "Bash: npm test"
    And a longer summary is cut at 400 characters

  @backlog @mc
  Scenario: Cancelling a Claude approval stops the turn
    Given a Claude thread waiting on a command approval
    When the user cancels the approval
    Then Claude is told the user cancelled the tool
    And the turn is interrupted instead of carrying on without the tool

  @backlog @mc
  Scenario: A Claude web search shows what was searched and what it found
    When Claude searches the web for "tax rates 2026"
    Then the search step shows the query
    And it lists the titles and addresses of the pages found

  @backlog @mc
  Scenario: An image Claude reads from the workspace can be previewed from the tool call
    When Claude reads the image "docs/mock.png" in the workspace
    Then the tool call carries the image's path so the client can show it

  @backlog @mc
  Scenario Outline: A Claude turn that gives up says why
    When Claude ends a turn because <reason>
    Then the run fails with "<message>"

    Examples:
      | reason                                         | message                                                                        |
      | it kept getting API errors                     | Claude gave up after repeated API errors.                                      |
      | its tool calls kept coming out malformed       | Claude gave up after repeated malformed tool calls.                            |
      | the turn's token budget ran out                | Claude stopped: the turn's token budget was exhausted.                         |
      | it could not produce the structured output     | Claude could not produce the requested structured output.                      |
      | a deferred tool is no longer available         | Claude could not resume a deferred tool call: the tool is no longer available. |
      | the turn could not be set up                   | Claude could not start the turn.                                               |
      | a usage limit blocked the request              | Claude stopped: a usage limit blocked the request.                             |
      | the context refilled straight after compaction | Claude stopped: the context refilled too quickly after compaction.             |
      | the prompt is larger than the context window   | Claude stopped: the prompt exceeds the model's context window.                 |
      | an image could not be processed                | Claude stopped: an image in the conversation could not be processed.           |
      | the model returned an error                    | Claude stopped: the model returned an error.                                   |
      | the API was overloaded                         | Claude API is overloaded (529). Try again shortly.                             |
      | the API rate limit was reached                 | Claude API rate limit reached. Try again later.                                |

  @backlog @mc
  Scenario: A failed Claude turn does not show Claude's internal diagnostics
    When Claude ends a turn with an error and a diagnostic record of its own
    Then the failure shows the error
    And the diagnostic record is not shown

  @backlog @mc
  Scenario: A Claude turn aborted mid-tool is interrupted even when Claude calls it a success
    Given the user stopped a Claude turn while a tool was running
    When Claude reports the turn as finished successfully but aborted
    Then the run is interrupted, not completed

  @backlog @mc
  Scenario: A Claude API retry shows its attempt and its wait
    Given a Claude turn is running
    When Claude retries a failed API request
    Then the turn's work log shows the retry with its attempt, the most attempts allowed and the wait before it
    And each later retry of that request updates the same entry

  @backlog @mc
  Scenario: A Claude turn with no answer of its own shows Claude's result as the answer
    When Claude ends a turn with a result but without writing an answer
    Then the result's text is shown as Claude's answer

  @backlog @mc
  Scenario: Claude switching model after a refusal is noted without failing the turn
    Given a Claude turn is running
    When Claude says it fell back to another model after a refusal
    Then the thread shows Claude's notice
    And the turn carries on

  @backlog @mc
  Scenario Outline: A Claude turn paused on a usage limit says which limit and how long
    Given a Claude turn is running
    When Claude is refused by its <window> limit, which resets in <wait>
    Then the thread says "Claude usage limit reached. This turn is paused until the <label> limit resets in <shown>."

    Examples:
      | window          | wait               | label        | shown  |
      | five hour       | 40 minutes         | 5-hour       | 40m    |
      | weekly          | 3 hours            | 7-day        | 3h     |
      | weekly Opus     | 2 hours 5 minutes  | 7-day Opus   | 2h 5m  |
      | weekly Sonnet   | 26 hours           | 7-day Sonnet | 26h    |
      | overage         | 90 seconds         | overage      | 2m     |

  @backlog @mc
  Scenario Outline: A usage limit pause leaves out a wait it cannot trust
    Given a Claude turn is running
    When Claude is refused by its weekly limit, which <reset>
    Then the thread says "Claude usage limit reached. This turn is paused until the 7-day limit resets."

    Examples:
      | reset                              |
      | has no reset time                  |
      | should already have reset          |
      | resets more than 30 days from now  |

  @backlog @mc
  Scenario: A usage limit pause is announced once for each limit in a turn
    Given a Claude turn is paused on its five hour limit
    When Claude reports the same refusal again and a warning about its weekly limit
    Then the thread still shows one pause notice
    And the warning adds no notice

  @backlog @mc
  Scenario: A Claude turn ended by several usage limits resumes after the last of them
    When Claude ends a turn refused by a limit that resets at 14:00 and another that resets at 18:00
    Then the run fails with "Claude usage limit reached. Send the message again once the limit resets."
    And the thread's reset time is 18:00

  @backlog @mc
  Scenario: A Claude usage limit with an unknown reset records no reset time
    When Claude ends a turn refused by a limit that resets at 14:00 and another with no reset time
    Then the thread is marked as limited without a reset time

  @backlog @mc
  Scenario: A Claude question without a heading is labelled by its number
    When Claude asks two questions and the second has no heading
    Then the second question is headed "Question 2"

  @backlog @mc
  Scenario: Several choices for one Claude question reach Claude as one answer
    Given Claude asked a question that allows several answers
    When the user picks "Unit tests" and "Docs"
    Then Claude receives "Unit tests, Docs" as the answer

  @backlog @mc
  Scenario: Claude's task list is shown with each step's status
    When Claude writes a task list with a finished step, a step in progress and a step not started
    Then the task list shows the three steps as completed, running and pending
    And the list is completed once every step is completed

  @backlog @mc
  Scenario: A newer Claude task list replaces the unfinished one before it
    Given Claude's task list still has unfinished steps
    When Claude writes a new task list
    Then the earlier list is marked superseded
    And a list that had already completed stays completed

  @backlog @mc
  Scenario: A Claude subagent's task list does not replace the thread's
    Given Claude's task list is shown in the thread
    When a subagent writes a task list of its own
    Then the thread's task list is unchanged

  @backlog @mc
  Scenario: A Claude subagent's thread opens with the task it was given
    When Claude starts a subagent with the task "Check the tests"
    Then the subagent's thread starts with "Check the tests" as its first message
    And the tools the subagent uses appear in the subagent's thread
    And the subagent's own messages do not appear in the parent thread

  @backlog @mc
  Scenario: A Claude subagent's progress is shown in its own thread
    Given Claude has a subagent running
    When Claude reports the subagent's progress
    Then the subagent's thread shows the progress as the subagent's thinking
    And the subagent's result is shown as its answer when it finishes

  @backlog @mc
  Scenario Outline: A Claude subagent ends the way Claude says it ended
    Given Claude has a subagent running
    When Claude reports the subagent <reported>
    Then the subagent is <status>

    Examples:
      | reported                | status    |
      | completed with a result | completed |
      | stopped                 | cancelled |
      | ended any other way     | failed    |

  @backlog @mc
  Scenario: A Claude subagent launched in the background is not finished by its launch
    When Claude launches a subagent in the background and the launch returns at once
    Then the subagent stays running until Claude reports it finished

  @backlog @mc
  Scenario: A message to a finished Claude subagent sets it running again
    Given a Claude subagent completed with "3 files"
    When Claude sends that subagent another message
    Then the subagent is running again without its earlier result

  @backlog @mc
  Scenario: Late progress does not reopen a finished Claude subagent
    Given a Claude subagent completed with "3 files"
    When a progress report for it arrives afterwards
    Then the subagent stays completed with "3 files"

  @backlog @mc
  Scenario: Claude is not prompted again for work it already did by itself
    Given Claude answered a finished background task by itself after a turn ended
    When the thread runs a turn for that work
    Then the run shows what Claude already wrote
    And Claude is sent no new message for it

  @backlog @mc
  Scenario: A wake with nothing from Claude to show completes at once
    Given the thread is asked to run a turn for work Claude did by itself
    And Claude wrote nothing for it
    Then the run completes without asking Claude anything

  @backlog @mc
  Scenario: A Claude turn that does not stop within 10 seconds is settled as interrupted
    Given the user stopped a running Claude turn
    When Claude has not ended the turn after 10 seconds
    Then the run is interrupted anyway
    And the thread can take its next message

  @backlog @mc
  Scenario: Claude's stream ending after a stop is an interruption, not a failure
    Given the user stopped a running Claude turn
    When Claude's process ends without reporting the turn
    Then the run is interrupted
    And it is not reported as a failed turn

  @backlog @mc
  Scenario: Reverting a Claude thread to before its first turn starts a fresh Claude session
    Given a Claude thread with three turns
    When the user reverts to before the first turn and sends a message
    Then Claude starts a new session that remembers none of the turns

  @backlog @mc
  Scenario: Claude installed through npm on Windows starts
    Given the MC runs on Windows and "claude" on its path is npm's launcher script
    When the user sends a message to Claude
    Then the MC starts the Claude program that script points to
    And the turn runs

  @backlog @mc
  Scenario Outline: Claude's config directory is chosen in a fixed order
    Given the Claude instance's config directory is <instance setting>
    And the MC's environment <inherited>
    When the user sends a message to Claude
    Then Claude uses <directory>

    Examples:
      | instance setting | inherited                                      | directory                    |
      | "/work/claude"   | sets another Claude config directory           | "/work/claude"               |
      | empty            | sets the Claude config directory "/env/claude" | "/env/claude"                |
      | empty            | sets no Claude config directory                | ".claude" in the user's home |

  @backlog @mc
  Scenario: An empty config directory and the default one are the same Claude home
    Given one Claude instance has no config directory set and another is set to "~/.claude"
    When a thread started on the first is moved to the second
    Then Claude continues the same conversation

  @backlog @mc
  Scenario: A Claude instance with its own config directory still finds its saved login on macOS
    Given the MC runs on macOS
    And a Claude instance with its own config directory was signed in from a terminal
    When the user sends a message to that instance
    Then Claude runs signed in

  @backlog @mc
  Scenario: A signed-out Claude instance names the config directory to sign in with
    Given a Claude instance with its own config directory is not signed in
    When the user sends a message to that instance
    Then the turn fails saying to run "claude auth login" on the MC's machine
    And the message names the folder to run it from and the config directory to set
    And says to start a new thread afterwards, or to check the instance's credentials when it uses an API key

  @backlog @mc
  Scenario Outline: Claude skills are read from Claude's own folders
    Given a skill "review" in <folder>
    When the user opens the skill list in a Claude thread
    Then "review" is <offered>

    Examples:
      | folder                                         | offered     |
      | the skills folder of Claude's config directory | offered     |
      | the project's .claude/skills                   | offered     |
      | the project's .agents/skills                   | not offered |

  @backlog @mc
  Scenario: A Claude skill whose header cannot be read is left out
    Given the project has the Claude skills "review" and "broken", and the header of "broken" is malformed
    When the user opens the skill list in a Claude thread
    Then "review" is offered and "broken" is not

  @backlog @mc
  Scenario Outline: Claude's skill settings decide which skills the user can run
    Given the project has the Claude skill "review"
    And <settings>
    When the user opens the skill list in a Claude thread
    Then "review" is <state>

    Examples:
      | settings                                                                | state        |
      | the user's Claude settings switch "review" off                          | shown as off |
      | the project's Claude settings switch "review" off                       | shown as off |
      | the user's settings switch it off and the managed policy switches it on | offered      |
      | a settings file switches it off but holds a value Claude cannot read    | offered      |

  @backlog @mc
  Scenario Outline: A dollar sign that is not a skill mention stays as typed
    Given the project has the Claude skill "review"
    When the user sends "<message>" to Claude
    Then Claude receives the message exactly as typed

    Examples:
      | message                    |
      | echo $HOME                 |
      | it costs $5                |
      | a budget of $10k           |
      | the price$review is wrong  |

  @backlog @mc
  Scenario: A Claude skill is known by its folder's name
    Given the project has a Claude skill in the folder "review" whose header names it "Code Review"
    When the user opens the skill list in a Claude thread
    Then the skill is offered as "review"
    And Claude's skill settings switch it on or off under "review"

  @backlog @mc
  Scenario: The user's own Claude skill wins over a project skill of the same name
    Given a skill "review" in the skills folder of Claude's config directory
    And another skill "review" in the project's .claude/skills
    When the user opens the skill list in a Claude thread
    Then "review" is listed once, with the description of the user's own skill

  @backlog @mc
  Scenario: A Claude skill without a header is still offered
    Given the project has a Claude skill "notes" whose file has no header
    When the user opens the skill list in a Claude thread
    Then "notes" is offered without a description

  @backlog @mc
  Scenario Outline: A Claude skill that only the user may start is marked so
    Given the project has the Claude skill "deploy"
    And <cause>
    When the user opens the skill list in a Claude thread
    Then "deploy" is offered and marked as started only by the user

    Examples:
      | cause                                                        |
      | its header says Claude must not start it by itself           |
      | its header says so with "yes" or "on" instead of "true"      |
      | Claude's skill settings set it to user-invocable-only        |

  @backlog @mc
  Scenario Outline: Claude's skill settings are layered from the user's to the organisation's
    Given the project has the Claude skill "review"
    And <lower file> switches "review" off
    And <higher file> switches "review" on
    When the user opens the skill list in a Claude thread
    Then "review" is offered

    Examples:
      | lower file                                  | higher file                                 |
      | the user's Claude settings                  | the project's Claude settings               |
      | the project's Claude settings               | the project's local Claude settings         |
      | the project's local Claude settings         | the repository root's local Claude settings |
      | the repository root's local Claude settings | the organisation's managed Claude settings  |

  @backlog @mc
  Scenario: Only the repository root's local Claude settings reach a nested workspace
    Given a thread's workspace is a folder nested inside a git repository
    And the repository root's shared Claude settings switch the skill "review" off
    When the user opens the skill list in that thread
    Then "review" is offered
    And Claude settings in folders above a workspace that is in no repository are not read either

  @backlog @mc
  Scenario Outline: The organisation's Claude settings are read from each system's own place
    Given the MC runs on <system>
    And the managed Claude settings at <path> switch the skill "review" off
    When the user opens the skill list in a Claude thread
    Then "review" is shown as off

    Examples:
      | system  | path                                                               |
      | macOS   | "/Library/Application Support/ClaudeCode/managed-settings.json"    |
      | Linux   | "/etc/claude-code/managed-settings.json"                           |
      | Windows | "managed-settings.json" in "ClaudeCode" of the program data folder |

  @backlog @mc
  Scenario: Claude settings with comments or trailing commas are still read
    Given the project's Claude settings hold comments and a trailing comma, and switch the skill "review" off
    When the user opens the skill list in a Claude thread
    Then "review" is shown as off

  @backlog @mc
  Scenario: A relative Claude config directory from the MC's environment is taken from the thread's folder
    Given the MC's environment sets the Claude config directory to "claude-config"
    And the Claude instance has no config directory of its own
    When the user opens the skill list in a thread whose folder is "/work/shop"
    Then skills are read from "/work/shop/claude-config/skills"
    And a config directory written with a leading "~" is not expanded to the user's home

  @backlog @mc
  Scenario: A disabled Claude instance offers no skills
    Given the Claude instance is disabled
    When a client asks for the skills of a project folder
    Then no skills are listed and no skill folder is read

  @backlog @mc
  Scenario: A message that mentions several Claude skills runs the last one
    Given the project has the Claude skills "review" and "ship"
    When the user sends "Use $review then $ship now" to Claude
    Then Claude runs the skill "ship" with the rest of the message as its request
    And the earlier mention reaches Claude as "/review"

  @backlog @mc
  Scenario: A Claude skill whose name starts with a digit can be mentioned
    Given the project has the Claude skill "5k-report"
    When the user sends "$5k-report for March" to Claude
    Then Claude runs the skill "5k-report"

  @backlog @mc
  Scenario: Claude's account and command details are read once and reused for five minutes
    Given the MC read a Claude instance's account, commands and agents for a project folder
    When it checks that instance again within five minutes
    Then Claude is not started again to read them
    And refreshing the provider by hand reads them afresh

  @backlog @mc
  Scenario Outline: Claude installed by its own installer updates itself
    Given the claude command lives <location>
    When the user opens Claude's update details
    Then the update command is <command>

    Examples:
      | location                                       | command                                    |
      | in ".local/bin" of the user's home             | Claude's own "claude update"               |
      | under ".local/share/claude" of the user's home | Claude's own "claude update"               |
      | in an npm global install                       | npm installing "@anthropic-ai/claude-code" |
