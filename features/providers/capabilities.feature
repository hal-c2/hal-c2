# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   apps/server-ex/lib/hal_c2/orchestration.ex (steerable?, driver_for, follow-up queueing)
#   apps/server-ex/lib/hal_c2/orchestration/entities.ex (steers?), apps/server-ex/lib/hal_c2/pi/thread_runtime.ex (steer)
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex (native forks for codex/claudeAgent/pi/opencode, transcript otherwise, 60 000 character cap)
#   apps/server-ex/lib/hal_c2/orchestration/fork.ex (thread.fork, thread.merge_back)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (rollback starts a fresh session, refuses while a turn runs)
#   apps/server-ex/lib/hal_c2/text_generation.ex (which providers write titles, commits and PRs)
#   apps/server/src/orchestration-v2/Adapters/*AdapterV2.ts (per-provider capabilities), packages/contracts/src/server.ts
#   apps/web/src/components/chat/ChatComposer.tsx (capability-gated controls)
#   docs/user/providers-claude.md, docs/user/providers-codex.md, docs/user/providers-opencode.md,
#   docs/user/providers-pi.md, docs/user/providers-antigravity.md, docs/user/providers-acp.md, docs/user/cursor.md

@mc
Feature: Provider capabilities
  Providers differ in what they can do mid-conversation. Each provider plugin declares
  its capabilities, and HAL-C2 degrades the same way for every provider that lacks one:
  the control is hidden or the action falls back, never silently dropped.

  Background:
    Given a connected environment with the project "shop"

  Scenario Outline: A follow-up during a running turn steers providers that can be steered
    Given a <provider> thread with a running turn
    When the user sends a follow-up message
    Then <outcome>

    Examples:
      | provider | outcome                                          |
      | Codex    | the message joins the running turn               |
      | Claude   | the message joins the running turn               |
      | Grok     | the message waits until the running turn ends    |
      | OpenCode | the message joins the running turn               |
      | Cursor   | the message waits until the running turn ends    |
      | Pi       | the message joins the running turn               |

  Scenario: A steer that arrives after the turn ended is sent as a normal message
    Given a Codex thread whose turn is finishing
    When the user's steer reaches the MC after the turn ended
    Then the message starts the next turn

  Scenario Outline: A fork continues the provider's own conversation where it can
    Given a <provider> thread with three turns
    When the user forks the thread after the second turn
    Then the fork's first turn <how>

    Examples:
      | provider | how                                                      |
      | Codex    | continues a copy of Codex's own thread cut after turn 2  |
      | Claude   | resumes Claude's session at turn 2 as a new session      |
      | Grok     | starts with a transcript of the first two turns          |
      | OpenCode | continues a fork of OpenCode's session cut before turn 3 |

  Scenario: Switching provider mid-thread hands over a transcript
    Given a Codex thread with history
    When the user switches the thread to Claude and sends a message
    Then Claude receives a transcript of the history ahead of the message

  Scenario: A long transcript keeps its newest part
    Given a thread whose history is longer than a provider's handover limit
    When the thread moves to another provider
    Then the transcript keeps the newest history and drops the oldest

  Scenario: Merging a fork back hands the fork's new work to the parent
    Given a fork with two turns the parent has not seen
    When the user merges the fork back
    Then the parent's next turn receives the fork's new work as a transcript

  Scenario: A newer merge from the same fork replaces an unused one
    Given a merge from a fork that the parent has not used yet
    When the user merges the same fork back again
    Then only the newer merge reaches the parent

  Scenario: Merging back a thread that is not a fork is refused
    When the user merges back a thread that was not forked from the parent
    Then the user is told the thread is not a fork of the parent

  Scenario: Rewinding an ACP thread starts the next turn fresh
    Given a Grok thread with three turns
    When the user rewinds to the first turn
    Then the next turn starts a new Grok session without the old conversation

  Scenario: Rewinding an ACP thread while it runs is refused
    Given a Grok thread with a running turn
    When the user rewinds the thread
    Then the user is told "Interrupt the current turn before rewinding."

  Scenario Outline: Titles, commit messages and PR text are written by providers that can
    Given the text-generation model is on <provider>
    When a new thread needs a title
    Then <outcome>

    Examples:
      | provider | outcome                                            |
      | Codex    | Codex writes it in a read-only run                 |
      | Claude   | Claude writes it in a one-shot run                 |
      | Grok     | Grok writes it with every tool refused             |
      | OpenCode | OpenCode writes it with every tool refused         |
      | Cursor   | Cursor writes it with every tool refused           |

  Scenario Outline: Controls a provider does not support are hidden
    Given a <provider> thread
    When the user looks at the composer
    Then <control> is not offered

    Examples:
      | provider    | control                     |
      | Grok        | the plan/build toggle       |
      | OpenCode    | the plan/build toggle       |
      | Antigravity | the plan/build toggle       |
      | Pi          | the plan/build toggle       |
      | Cursor      | forking the thread          |
      | Grok        | forking the thread          |
      | Antigravity | forking the thread          |
      | Grok        | rewinding the thread        |

  Scenario Outline: Providers that cannot steer interrupt and restart instead
    Given a <provider> thread with a running turn
    When the user sends a follow-up and asks to steer
    Then the running turn is interrupted and restarted with the message

    Examples:
      | provider    |
      | Cursor      |
      | Antigravity |

  @backlog
  Scenario: Antigravity refuses a rewind of the conversation
    Given an Antigravity thread with three turns
    When the user rewinds to the first turn
    Then the files are restored and the user is told the conversation cannot be rewound

  Scenario Outline: Proposed plans are shown for providers that make them
    Given a <provider> thread in plan mode
    When the provider finishes a plan
    Then the plan is shown for the user to accept or refine

    Examples:
      | provider |
      | Grok     |

    # The Cursor and OpenCode rows are split out: the MC captures no proposed plan from them yet.
    @backlog
    Examples: Not yet on the MC
      | provider |
      | Cursor   |
      | OpenCode |

  @backlog
  Scenario Outline: Subagent work is shown as child work
    Given a <provider> thread
    When the provider runs a subagent
    Then the subagent's work is shown under the turn that started it

    Examples:
      | provider    |
      | Claude      |
      | Codex       |
      | Cursor      |
      | Grok        |
      | OpenCode    |
      | Antigravity |

  @shared @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: An ACP subagent's messages stay in its own thread
    Given an ACP agent starts a native child session
    When the child sends messages and a final summary
    Then they appear in the child's thread
    And the parent receives only the child's result

  @shared @backlog
  Scenario: An ACP edit carries its replaced lines
    Given an ACP agent edits a file by giving the old text and the new text
    When the user looks at the change
    Then the diff shows the replaced lines
    And the diff is not empty just because the agent sent no patch

  @backlog
  Scenario: A registry agent declares its capabilities through its plugin
    Given a registry agent that declares it can be steered
    When the user sends a follow-up during its turn
    Then the message joins the running turn
