# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-claude.md
#   docs/internals/providers.md (Claude homes, update ownership)
#   apps/server-ex/lib/hal_c2/claude/provider.ex, apps/server-ex/lib/hal_c2/claude/thread_runtime.ex, apps/server-ex/lib/hal_c2/claude/session.ex
#   apps/server-ex/lib/hal_c2/provider_updates.ex (claudeAgent advisory, claude update)
#   apps/server-ex/lib/hal_c2/provider_usage_limits/claude.ex (get_usage)
#   apps/server-ex/lib/hal_c2/text_generation.ex (claude -p)
#   apps/server/src/provider/Layers/ClaudeProvider.ts, apps/server/src/provider/ClaudeModelCatalog.ts, apps/server/src/provider/ClaudeModelManifest.ts, apps/server-ex/priv/model-manifest.json
#   apps/server/src/provider/Drivers/ClaudeDriver.ts, apps/server/src/provider/Drivers/ClaudeHome.ts
#   apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts
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

  Scenario: Claude offers the models of the bundled model manifest
    When the user opens the model picker for Claude
    Then the manifest's Claude models are offered in its order
    And models the manifest marks as legacy are labelled legacy

  Scenario: Claude models that need a newer CLI are not offered
    Given the installed Claude is older than a model requires
    When the user opens the model picker for Claude
    Then that model is not offered

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

  @backlog
  Scenario: Several Claude accounts can run side by side
    Given the user adds a second Claude instance with its own config directory
    When the user signs in to the CLI with that config directory
    Then each instance uses its own account and history

  @backlog
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

  @backlog
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

  @backlog
  Scenario: A resumed Claude subagent keeps its continuation in its own thread
    Given Claude resumed a subagent after the MC restarted
    When the user opens the subagent's thread
    Then the thread shows the message that resumed it
    And the parent thread does not

  @shared @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A Claude monitor shows as background work, not as a command
    Given Claude starts a monitor in the thread
    Then the thread lists the monitor as background work
    And the monitor is not shown as a command

  @backlog
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
