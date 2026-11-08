# Sources:
#   https://github.com/pingdotgg/t3code/pull/23174
#   https://github.com/pingdotgg/t3code/pull/18309
#   https://github.com/pingdotgg/t3code/pull/24899
#   https://github.com/pingdotgg/t3code/pull/16750
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
#   docs/user/providers-pi.md, docs/user/providers-muse.md, docs/user/providers-antigravity.md, docs/user/providers-acp.md, docs/user/cursor.md
#   https://github.com/pingdotgg/t3code/pull/14542
#   https://github.com/pingdotgg/t3code/pull/29605
#   https://github.com/pingdotgg/t3code/pull/28409
#   packages/provider-acp/src/server/sessionConfig.ts (acpProviderOptionDescriptors, upstream)

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
      | provider  | outcome                                       |
      | Codex     | the message joins the running turn            |
      | Claude    | the message joins the running turn            |
      | Grok      | the message waits until the running turn ends |
      | OpenCode  | the message joins the running turn            |
      | Cursor    | the message waits until the running turn ends |
      | Pi        | the message joins the running turn            |
      | Muse Code | the message joins the running turn            |
      | custom Muse Code | the message joins the running turn     |

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

  Scenario: A long transcript keeps every request and condenses the older work
    Given a thread whose history is longer than a provider's handover limit
    When the thread moves to another provider
    Then the transcript keeps every request whole, the newest work first, and condenses the older

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
      | Muse Code   | the plan/build toggle       |
      | Muse Code   | rewinding the thread        |

  Scenario Outline: Providers that cannot steer interrupt and restart instead
    Given a <provider> thread with a running turn
    When the user sends a follow-up and asks to steer
    Then the running turn is interrupted and restarted with the message

    Examples:
      | provider    |
      | Cursor      |
      | Antigravity |

  @backlog @priority-low
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
      | Cursor   |
      | Grok     |

    # The OpenCode row is split out: OpenCode's plan agent answers in prose, and neither
    # server captures a proposed plan from it (OpenCodeAdapterV2.ts emitsProposedPlan: false).
    @backlog @priority-low
    Examples: Not yet on the MC
      | provider |
      | OpenCode |

  Scenario Outline: Subagent work is shown as child work
    Given a <provider> thread
    When the provider runs a subagent
    Then the subagent's work is shown under the turn that started it

    Examples:
      | provider    |
      | Claude      |
      | Cursor      |
      | Grok        |
      | OpenCode    |
      | Antigravity |

    # The Codex row is split out: the MC does not project Codex's subagents yet
    # (codex.feature, "Codex subagents appear as child threads").
    @backlog
    Examples: Not yet on the MC
      | provider    |
      | Codex       |

  @shared @backlog-desktop @backlog-mobile @priority-low
  Scenario: An ACP subagent's messages stay in its own thread
    Given an ACP agent starts a native child session
    When the child sends messages and a final summary
    Then they appear in the child's thread
    And the parent receives only the child's result

  @shared @backlog-mc @backlog-desktop @backlog-mobile @priority-low
  Scenario: An ACP edit carries its replaced lines
    Given an ACP agent edits a file by giving the old text and the new text
    When the user looks at the change
    Then the diff shows the replaced lines
    And the diff is not empty just because the agent sent no patch

  # Upstream #29605: the ACP reader threw away text after the last newline when the agent's output
  # closed, so an answer written without one failed its request with "ACP input stream ended".
  @backlog @priority-high
  Scenario: An ACP agent's last message without a trailing newline is still read
    Given an ACP agent answers a pending request without a trailing newline and then closes its output
    When the MC reads the agent's output
    Then the request receives the agent's answer
    And it does not fail as though the agent's output ended unanswered

  # Upstream #28409 (acpProviderOptionDescriptors): an ACP agent's own session options are its
  # models' options, and the one in the thought_level category is the effort. The MC publishes only
  # an ACP session's model list, so an agent's thinking levels, modes and switches never reach the
  # composer.
  @backlog
  Scenario: An ACP agent's own session options are offered with its models
    Given an ACP agent's session offers its own thinking levels, a mode and an on or off option
    When the MC lists the agent's models
    Then each model offers the agent's options under the agent's own ids and names
    And the thinking levels are marked as the model's effort
    And the on or off option is a switch
    And the agent's session modes are one Mode option, unless the agent already offers them as an option
    And the model and collaboration-mode options are left to the model and plan controls

  @backlog @priority-low
  Scenario: A registry agent declares its capabilities through its plugin
    Given a registry agent that declares it can be steered
    When the user sends a follow-up during its turn
    Then the message joins the running turn

  @backlog @shared @mc
  Scenario: Restarting the agent session loads new skills and plugins
    Given a thread whose provider has new skills, plugins or MCP servers
    When the user chooses Restart agent session in the command palette
    Then the thread's provider process is stopped and the conversation stays
    And the next message resumes it on a fresh process with the new setup
    And the folder is scanned again so the slash and dollar menus list the new skills
    And a failure shows an error toast

  # Upstream #16750: a folder's skill scan goes stale after five minutes; the composer rescans
  # it once when it opens there, so a skill added to the project shows up without a restart.
  @backlog @mc @priority-low
  Scenario Outline: Opening the composer rescans a folder's skills only once they are stale
    Given the skills of folder "api" were scanned <age> ago
    And a skill "deploy" was added to "api" since
    When the user opens the composer for a thread working in "api"
    Then <outcome>

    Examples:
      | age        | outcome                                                     |
      | 6 minutes  | "api" is scanned again and the dollar menu offers "deploy"  |
      | 2 minutes  | "api" is not scanned again and "deploy" is not offered yet  |

  # Upstream #23174: a failed rescan that hands back the stale scan no longer counts as fresh
  # for five minutes; the composer asks again after its ten-second wait, up to three times.
  @backlog @shared @priority-low
  Scenario: A rescan that fails and returns the stale skills is tried again shortly
    Given the skills of folder "api" are stale
    And rescanning "api" fails, so the stale skills are returned
    When the user keeps editing the draft for more than ten seconds
    Then "api" is asked for again, up to three times in all
    And once a rescan succeeds the dollar menu offers the skills it found

  # Upstream #18309: a folder's skill scan is published even while the provider's health
  # check fails; commands it cannot read keep the last known ones instead of going empty.
  @backlog
  Scenario: Skills stay offered while the provider's health check fails
    Given Codex's health check fails
    And Codex's skill scan of folder "api" finds the skill "deploy"
    When the user opens the composer for a thread working in "api"
    Then the dollar and slash menus offer "deploy"
    And Codex still shows its health problem

  # Upstream #24899: every thread open sent every provider's skills for every folder; a
  # folder's skills now come only when a composer asks for that folder.
  @backlog @mc @shared
  Scenario: A client is sent the skills of a folder only when it asks for that folder
    Given Codex has scanned the skills of folders "api" and "web"
    When the user opens the composer for a thread working in "api"
    Then the client is sent the skills Codex found in "api"
    And the client is not sent the skills of "web"

  # Upstream #24899
  @backlog @mc
  Scenario: Two composers asking for one folder share its scan
    Given a skill scan of folder "api" is still running
    When another client asks for the skills of "api"
    Then it receives the result of the running scan, not an empty list
    And the scan finishes even if the client that started it disconnects

  # Upstream #24899: a deleted worktree's scan never finished, so its composer retried every
  # 10 seconds forever.
  @backlog @shared @priority-low
  Scenario: A composer stops asking for the skills of a folder that cannot be scanned
    Given the folder of thread "t1" was deleted
    When the user keeps the composer of "t1" open
    Then the skills of the folder are asked for at most 3 times
