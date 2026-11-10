# Sources:
#   apps/server-ex/lib/hal_c2/plugins/kinds.ex (Extension observe/2 and shape_run/2)
#   apps/server-ex/lib/hal_c2/plugins/feed.ex (a running extension's feed of turns, dropped events counted)
#   apps/server-ex/lib/hal_c2/plugins.ex (observe/1, shape_run/1: asked as a new conversation starts, each plugin apart from the asker, with its saved settings)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (turn.started, turn.item with an answer's text, turn.finished; end_item/5: a background command that ended after its turn; the calls a stopped or abandoned turn closed; a turn's usage)
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (a Codex turn and a goal's run, started by Codex's own writer; end_background; a turn keeps only the usage Codex reports of it)
#   apps/server-ex/lib/hal_c2/claude/thread_runtime.ex (end_work: a background command stopped between turns)
#   apps/server-ex/lib/hal_c2/orchestration/native_subagent.ex (a subagent the provider started, as a turn.item; its calls, marked as a subagent's)
#   apps/server-ex/lib/hal_c2/orchestration/run_shape.ex (a conversation's shape, kept on its provider thread, a native fork's inherited)
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex (a native fork carries its source's shape; fresh_start/2: a resume that started afresh is a new conversation)
#   apps/server-ex/lib/hal_c2/orchestration.ex (new_run: another instance with the same home takes over the conversation and its shape)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (Host.steer, Host.notice, Host.generate, Host.history: the provider each turn ran on, the turns before one)
#   apps/server-ex/lib/hal_c2/text_generation.ex (for_plugin/2: the text model, with what it used)
#   apps/server-ex/lib/hal_c2/claude/thread_runtime.ex (--disallowedTools), apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (features off at thread/start)
#   packages/contracts/src/orchestrationV2.ts (system_notice pluginId and actions, providerToolName)
#   apps/desktop-qt/src/native/TimelineModel.cpp, apps/desktop-qt/qml/HalC2/Bricks/Timeline.qml (a notice's Stop, a folded group's StopRunRole)
#   apps/desktop-qt/src/native/ComposerController.cpp (interrupt: a Stop naming its run stops only that run)
#   hal-c2/hal-c2#1399 (the TokenEconomizer port these hooks are for)

Feature: Plugins that watch and shape turns
  An MC extension can follow what agents do and act on it. With `turns:observe` it hears
  each turn start, every tool call with what it returned, and the turn's end with the
  tokens the context holds, and it can read the turns a thread ran before. With
  `runs:shape` it is asked, as a provider conversation starts, for context to put ahead
  of the first message and for tools to turn off for the whole conversation, so the
  provider's prompt cache is never broken mid-conversation. With `threads:steer` it
  sends a message into the turn it names, with `threads:notice` it shows a notice in a
  turn that offers to stop it, and with `textGeneration` it asks the user's text model
  for an answer and learns what that used.

  @mc
  Scenario: A plugin hears a turn start, its tool calls, and its end, in order
    Given a plugin that hears turns
    When a Claude thread runs a turn that calls a tool
    Then the plugin hears the turn start as a new conversation
    And it hears the tool call by Claude's own name for the tool, with what it returned
    And it hears what Claude answered
    And it hears the turn end last

  @mc
  Scenario Outline: A plugin hears every provider's turns start and end
    Given a plugin that hears turns
    When a <provider> thread runs a turn
    Then the plugin hears a new <provider> conversation start, then the turn end

    Examples:
      | provider |
      | Claude   |
      | Codex    |
      | OpenCode |

  @mc
  Scenario: A plugin hears a subagent the agent starts, in the turn that starts it
    Given a plugin that hears turns
    When a Codex thread runs a turn that starts a subagent
    Then the plugin hears the subagent start in that turn, before it ends

  @mc
  Scenario: A plugin hears a subagent's tool calls in the turn that runs it, marked as a subagent's
    Given a plugin that hears turns
    When a Claude thread runs a turn in which a subagent calls a tool
    Then the plugin hears the subagent's tool call in that turn, marked as a subagent's

  @mc
  Scenario: A plugin hears Codex use the tools no thread shows as calls
    Given a plugin that hears turns
    When a Codex thread runs a turn that views an image, makes one and waits on its agents
    Then the plugin hears each use in that turn, by Codex's name for the tool

  @mc
  Scenario: A plugin hears a Codex turn end with only the usage Codex reported of it
    Given a plugin that hears turns
    And a Codex thread working on a turn
    When Codex reports the turn used 5 tokens
    And then reports the usage of an earlier turn and of another thread, and the turn ends
    Then the plugin hears the turn end with 5 tokens used

  @mc
  Scenario: A plugin without turns:observe hears nothing of a turn
    Given a plugin that would hear turns but was not granted "turns:observe"
    When a Claude thread runs a turn that calls a tool
    Then the plugin hears nothing

  @mc
  Scenario: A plugin reads the turns a thread ran, oldest first
    Given a plugin that hears turns
    And a Claude thread that ran two turns
    When the plugin reads the thread's turns
    Then it gets both turns, oldest first, each with its tool calls

  @mc
  Scenario: A plugin that hears of a turn late reads the turns before it, with the provider each ran on
    Given a plugin that hears turns
    And a Claude thread that ran three turns
    When the plugin reads one turn from before the thread's last turn
    Then it gets the thread's second turn, which ran on Claude

  @mc
  Scenario Outline: A plugin hears a command a turn left running in the background end after the turn
    Given a plugin that hears turns
    And a <provider> thread whose turn left a command running in the background
    When the user stops the turn
    Then the plugin hears the command end interrupted after the turn, in the turn it ran in

    Examples:
      | provider |
      | Claude   |
      | Codex    |

  @mc
  Scenario: A plugin adds context to a new conversation and turns a tool off for all of it
    Given a plugin that shapes runs with the context "Keep answers short." and "WebFetch" off
    When a Claude thread runs two turns
    Then Claude gets "Keep answers short." ahead of the first message only
    And Claude ran both turns without "WebFetch"
    And the plugin was asked once

  @mc
  Scenario Outline: What a plugin can turn off depends on the provider
    Given a plugin that shapes runs with the context "Keep answers short." and "<off>" off
    When a <provider> thread runs a turn
    Then the plugin was told the provider's tools are turned off by <unit>
    And <provider> gets "Keep answers short." ahead of the first message only
    And <provider> ran the turn with <result>

    Examples:
      | provider | off           | unit         | result                  |
      | Claude   | WebFetch      | tool name    | "WebFetch" off          |
      | Codex    | collaboration | capability   | its subagent tools off  |
      | OpenCode | anything      | nothing      | every tool it had       |

  @mc
  Scenario: A plugin's context comes ahead of the goal a new Codex conversation starts with
    Given a plugin that shapes runs with the context "Keep answers short." and "collaboration" off
    When a Codex thread works toward the goal "ship the fix", then runs a turn
    Then Codex is asked to work toward "ship the fix" after "Keep answers short."
    And the turn after the goal comes without "Keep answers short."

  @mc
  Scenario Outline: A plugin that fails while shaping a conversation leaves it as it was
    Given a plugin that <fails> when asked to shape a run
    When a Claude thread runs a turn
    Then Claude gets the message as the user wrote it
    And the turn completes unshaped

    Examples:
      | fails                                 |
      | raises                                |
      | dies with a process it linked         |
      | answers with what is not JSON         |

  @mc
  Scenario: A fork that continues a shaped conversation keeps its shape
    Given a plugin that shapes runs with the context "Keep answers short." and "collaboration" off
    And a Codex thread that ran a turn
    When the thread is forked and the fork runs a turn
    Then Codex forks its own conversation with its subagent tools still off
    And the fork's message comes without "Keep answers short."
    And the plugin was asked once

  @mc
  Scenario: Another Claude account with the same home keeps the shape of the conversation it takes over
    Given a plugin that shapes runs with the context "Keep answers short." and "WebFetch" off
    And a Claude thread that ran a turn
    When its next turn runs on another Claude account with the same home
    Then that account resumes the conversation without "WebFetch"
    And the plugin was asked once

  @mc
  Scenario Outline: A plugin hears how each call of a turn that <ended> ended, before the turn's end
    Given a plugin that hears turns
    And a Claude thread working on a turn with a command running
    When <what>
    Then the plugin hears the command end <status>, then the turn end

    Examples:
      | ended               | what                         | status      |
      | was stopped         | the user stops the turn      | interrupted |
      | lost its runtime    | the turn's runtime dies      | failed      |

  @mc
  Scenario: A plugin steers the turn it names while that turn works
    Given a plugin on turns granted "threads:steer"
    And a Claude thread working on a turn
    When the plugin steers that turn with "Use the cache"
    Then Claude gets "Use the cache" in that turn

  @mc
  Scenario: A plugin's steer of a turn that ended is refused and kept nowhere
    Given a plugin on turns granted "threads:steer"
    And a Claude thread whose turn ended
    When the plugin steers that turn with "Too late"
    Then the plugin is told the turn cannot take it
    And no turn is queued and no message kept for "Too late"

  @mc
  Scenario: A plugin's steer that names no turn is refused and starts none
    Given a plugin on turns granted "threads:steer"
    And a Claude thread whose turn ended
    When the plugin steers the thread with "Unnamed", naming no turn
    Then the plugin is told the turn cannot take it
    And no turn is queued and no message kept for "Unnamed"

  @mc
  Scenario: A plugin's notice sits in the turn it is about and offers to stop it
    Given a plugin on turns granted "threads:notice"
    And a Claude thread working on a turn
    When the plugin shows the notice "The agent is repeating itself." titled "Loop" with a way to stop the turn
    Then the turn shows the notice "Loop" from the plugin, offering to stop the turn

  @desktop @mobile @backlog-mobile
  Scenario: A plugin's notice offers Stop while its turn works
    Given a plugin's notice in a turn that is working, offering to stop it
    Then the notice shows a Stop action
    When the turn ends
    Then the notice no longer offers to stop it

  @desktop @mobile @backlog-mobile
  Scenario: A notice folded behind later tool calls still offers Stop
    Given a plugin's notice in a turn that is working, offering to stop it
    When the turn runs another command after the notice
    Then the folded tool calls still offer Stop
    When the turn ends
    Then the folded tool calls no longer offer Stop

  @desktop @mobile @backlog-mobile
  Scenario: A notice's Stop stops only the turn it is in
    Given a plugin's notice in a turn that is working, offering to stop it
    When the thread moves on to its next turn before the notice redraws
    Then the notice's Stop stops nothing

  @tui @backlog-tui
  Scenario: A plugin's notice tells the terminal user how to stop its turn
    Given a plugin's notice in a turn that is working, offering to stop it
    Then the notice says which key stops the turn

  @mc
  Scenario: A plugin asks the text model and learns what the answer used
    Given a plugin on turns granted "textGeneration"
    When the plugin asks the text model for a "summary"
    Then it gets a summary
    And it is told the tokens the provider said the answer used

  @mc
  Scenario Outline: A plugin's call on turns without its permission is refused
    Given a plugin on turns granted "turns:observe"
    And a Claude thread whose turn ended
    When the plugin tries <call>
    Then the MC refuses the call naming "<permission>"
    And the refusal is recorded on the plugin

    Examples:
      | call                        | permission     |
      | to steer the turn           | threads:steer  |
      | to show a notice            | threads:notice |
      | to ask the text model       | textGeneration |
