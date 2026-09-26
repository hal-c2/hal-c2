# Sources:
#   AGENTS.md (What the fork adds: threads move between machines, including the agent's own session)
#   apps/server-ex/lib/hal_c2/agent_sessions.ex (Claude under CLAUDE_CONFIG_DIR or ~/.claude,
#     projects/*/*.jsonl; Codex under CODEX_HOME or ~/.codex, sessions/YYYY/MM/DD/rollout-*.jsonl;
#     the working directory each record carries)
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex (native forks for codex, claudeAgent and pi;
#     the transcript otherwise)
#   apps/server-ex/lib/hal_c2/plugins/kinds.ex (the native_sessions capability)
#   apps/server-ex/lib/hal_c2/claude/protocol.ex, apps/server-ex/lib/hal_c2/claude/thread_runtime.ex
#     (--resume, --fork-session, nativeThreadRef)
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (thread/resume, thread/fork, cwd override)
#   apps/server-ex/lib/hal_c2/pi.ex, apps/server-ex/lib/hal_c2/pi/thread_runtime.ex (session files,
#     pi --fork in the destination directory)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex, apps/server-ex/lib/hal_c2/acp/sessions.ex
#     (session/resume, session/load, canLoad and canResume)
#   apps/server-ex/lib/hal_c2/acp/antigravity.ex (each instance's profile lives in the node's data)
#   apps/server-ex/lib/hal_c2/usage/transcripts.ex (Grok's sessions/**/updates.jsonl)
#   packages/cursor-acp/src/agent.ts (each session is a Cursor SDK agent, resumed by its id; no load)
#   Upstream: code.claude.com/docs/en/sessions and /claude-directory (transcripts keyed by the
#     encoded working directory; resume by id or by transcript path; a duplicate id is not found),
#     openai/codex codex-rs app-server thread/resume (path and cwd overrides; a rollout missing from
#     the state database is found by its file name), pi-mono docs/sessions.md and
#     docs/session-format.md (the header's cwd; a missing cwd is refused), Gemini CLI session
#     management (chats kept per project), opencode.ai/docs/cli (opencode export and import).
#   Shared domain: threads/moving-between-machines.feature owns the move itself, its refusals and
#   its export file; threads/migration-and-handoffs.feature owns the handoff transcript and its
#   budget; providers/session-import.feature owns importing history made outside HAL-C2.
#
# Decisions recorded here:
#   - A carried session is copied, never moved: the source machine's copy stays where the provider
#     keeps it, and HAL-C2 never deletes or rewrites anything in a provider's own history there.
#   - The copy is placed where the destination's provider instance looks for sessions of the
#     destination project, with every recorded working directory rewritten to the destination path.
#   - Where the provider can branch a session (Claude, Codex, Pi), the destination continues as a
#     new session branched from the carried copy. The copy stays as it arrived, and no two
#     sessions on one machine ever share an id.
#   - An agent that cannot branch, and whose destination already holds an older copy of the same
#     session, gets the handoff instead of an overwrite.
#   - Claude Code's own file history is not carried; HAL-C2's checkpoints cover rewinding.
#   - Anything uncertain falls back to the handoff: the thread always moves, and only how the agent
#     continues changes.

Feature: Carrying an agent's own session to another machine
  When a thread moves, its provider's native session can move with it, so the agent on the
  destination continues the conversation it was having. Each provider keeps its sessions
  somewhere different; its plugin says where, how a copy is placed on another machine, and
  how the agent resumes it. A provider that cannot carry its session hands the conversation
  over instead.

  Background:
    Given a cluster of the machines "laptop" and "desktop"
    And the project "shop" is at "~/code/shop" on "laptop" and at "~/src/shop" on "desktop"
    And the thread "Alpha" lives on "laptop" in "shop"

  @node
  Scenario Outline: A provider's session is carried to the destination
    Given "Alpha" runs on <provider> with a native session on "laptop"
    And <provider> keeps that session in <where it lives>
    When "Alpha" moves to "desktop"
    Then a copy of the session is placed in <where the copy goes>
    And on the next message the agent on "desktop" <resumes>
    And it is not sent a transcript of the conversation

    @plugin-claude
    Examples: Claude
      | provider | where it lives                                                                                                     | where the copy goes                                                                                                        | resumes                                                                  |
      | Claude   | a transcript under projects/ named by the working directory, with its sub-agent transcripts and saved tool results | the destination's Claude home under projects/ named by "~/src/shop", with its sub-agent transcripts and saved tool results | continues a new session branched from the copy, found by the copy's path |

    @plugin-codex
    Examples: Codex
      | provider | where it lives                                     | where the copy goes                                           | resumes                                                              |
      | Codex    | a rollout file under sessions/ by date in its home | the destination's Codex home under sessions/ by the same date | continues a new thread forked from the copy, working in "~/src/shop" |

    @plugin-pi
    Examples: Pi
      | provider | where it lives                                                          | where the copy goes                                        | resumes                                                               |
      | Pi       | a session file under its sessions folder named by the working directory | the destination's Pi sessions folder named by "~/src/shop" | continues a new session forked from the copy, started in "~/src/shop" |

    @backlog @plugin-acp-registry
    Examples: ACP agents that keep sessions in files, such as Gemini
      | provider | where it lives                               | where the copy goes                                  | resumes                            |
      | Gemini   | a chat file under its home, kept per project | the destination's Gemini home, kept for "~/src/shop" | loads the copy by the session's id |

    @backlog @plugin-opencode
    Examples: OpenCode
      | provider | where it lives                                          | where the copy goes                                                           | resumes                                |
      | OpenCode | its own session store, exported with its session export | the destination's OpenCode, through its session import, bound to "~/src/shop" | resumes the imported session by its id |

    @backlog @plugin-antigravity
    Examples: Antigravity
      | provider    | where it lives                                                     | where the copy goes                                           | resumes                              |
      | Antigravity | the profile HAL-C2 keeps for that Antigravity instance on "laptop" | the profile of the matching Antigravity instance on "desktop" | resumes the copy by the session's id |

  @node
  Scenario Outline: A provider whose session cannot be carried hands the conversation over
    Given "Alpha" runs on <provider> with a native session on "laptop"
    When "Alpha" moves to "desktop"
    Then no session is copied to "desktop"
    And on the next message a new <provider> session starts on "desktop" with the handoff
    And the user was told before the move that <provider> will get a summary of the conversation

    @plugin-cursor
    Examples: Cursor keeps each session as an agent inside the Cursor SDK, in a place it does not declare
      | provider |
      | Cursor   |

    @plugin-grok
    Examples: Grok declares neither where its sessions live nor that it can resume one
      | provider |
      | Grok     |

    @plugin-acp-registry
    Examples: ACP agents that cannot load or resume a session, or do not declare where they keep them
      | provider             |
      | a registry ACP agent |

  @node
  Scenario Outline: The recorded working directory is rewritten in the copy
    Given "Alpha" runs on <provider> and its session records "~/code/shop" as <record>
    When "Alpha" moves to "desktop"
    Then the copy records "~/src/shop" as <record>
    And the session on "laptop" still records "~/code/shop"

    @plugin-claude
    Examples: Claude
      | provider | record                               |
      | Claude   | the working directory of every entry |

    @plugin-codex
    Examples: Codex
      | provider | record                                                |
      | Codex    | the working directory of the session and of each turn |

    @plugin-pi
    Examples: Pi
      | provider | record                                        |
      | Pi       | the working directory in the session's header |

  @node
  Scenario: A provider plugin declares how its sessions are carried
    Given a provider plugin that declares native sessions
    And it declares where a session lives and how a copy is placed for another project
    When a thread on it moves to another machine
    Then its session is carried the way the plugin declares

  @node
  Scenario: A provider plugin without native sessions hands the conversation over
    Given a provider plugin that does not declare native sessions
    When a thread on it moves to another machine
    Then the next message on the destination starts a new session with the handoff

  @node
  Scenario: A session in the destination's newer provider continues natively
    Given "Alpha" runs on Codex and "desktop" has a newer Codex than "laptop"
    When "Alpha" moves to "desktop"
    And the user sends a message in "Alpha"
    Then the agent on "desktop" continues the carried session

  @node
  Scenario: A destination provider that cannot read the session falls back to the handoff
    Given "Alpha" runs on Claude and "desktop" has an older Claude than "laptop"
    And the older Claude cannot open the session written by the newer one
    When "Alpha" moves to "desktop"
    And the user sends a message in "Alpha"
    Then a new Claude session starts on "desktop" with the handoff
    And the user is told Claude on "desktop" could not continue the session and is older than on "laptop"

  @node
  Scenario Outline: The copy follows the destination's custom agent home
    Given the <provider> instance on "desktop" keeps its sessions under <setting> "~/work-agent"
    And "Alpha" runs on <provider> with a native session on "laptop" in the default home
    When "Alpha" moves to "desktop"
    Then the copy is placed under "~/work-agent" on "desktop"
    And the agent on "desktop" continues the carried session

    @plugin-claude
    Examples: Claude
      | provider | setting           |
      | Claude   | CLAUDE_CONFIG_DIR |

    @plugin-codex
    Examples: Codex
      | provider | setting    |
      | Codex    | CODEX_HOME |

    @plugin-pi
    Examples: Pi
      | provider | setting                     |
      | Pi       | PI_CODING_AGENT_SESSION_DIR |

  @node
  Scenario: A session in a custom home on the source is found there
    Given the Claude instance on "laptop" keeps its sessions under CLAUDE_CONFIG_DIR "~/work-claude"
    And "Alpha" runs on that instance
    When "Alpha" moves to "desktop"
    Then the session is copied from "~/work-claude" on "laptop"
    And the copy is placed in the Claude home of the instance "Alpha" runs on at "desktop"

  @node
  Scenario: The source keeps its copy of the session
    Given "Alpha" runs on Claude with a native session on "laptop"
    When "Alpha" moves to "desktop"
    Then the session is still in the Claude home on "laptop", unchanged
    And the user can still resume it with Claude Code on "laptop"

  @node
  Scenario: The source's copy is not offered for import after the thread moved
    Given "Alpha" moved to "desktop" with its Claude session
    When "laptop" scans for agent history
    Then the session of "Alpha" is marked as already imported

  @node
  Scenario: A session moved twice continues from the latest machine
    Given the cluster also has the machine "server", with "shop" at "~/shop"
    And "Alpha" moved from "laptop" to "desktop" with its Codex session
    And the user worked in "Alpha" on "desktop"
    When "Alpha" moves to "server"
    And the user sends a message in "Alpha"
    Then the agent on "server" continues the conversation including the work on "desktop"
    And the copies on "laptop" and "desktop" are still there, unchanged

  @node
  Scenario: A session moved back does not overwrite the copy the machine already had
    Given "Alpha" moved from "laptop" to "desktop" with its Claude session
    And the user worked in "Alpha" on "desktop"
    When "Alpha" moves back to "laptop"
    Then "laptop" holds both its original copy of the session and the one from "desktop"
    And the agent on "laptop" continues the conversation including the work on "desktop"

  @backlog @node @plugin-acp-registry
  Scenario: An agent that cannot branch a session is handed the conversation rather than overwrite a copy
    Given "Alpha" runs on Gemini and moved from "laptop" to "desktop" with its session
    And the user worked in "Alpha" on "desktop"
    When "Alpha" moves back to "laptop"
    Then the copy of the session "laptop" already had is left as it was
    And on the next message a new Gemini session starts on "laptop" with the handoff

  @node @plugin-claude
  Scenario: Claude Code's own file history is not carried
    Given "Alpha" runs on Claude and Claude Code kept file backups for its session
    When "Alpha" moves to "desktop"
    Then the file backups stay on "laptop"
    And rewinding "Alpha" on "desktop" uses HAL-C2's checkpoints

  @node
  Scenario: A thread file carries the agent's session the same way a move does
    Given "Alpha" runs on Codex with a native session
    When the user exports "Alpha" on "laptop" and imports the file on "desktop"
    Then the session is placed on "desktop" as a move would place it
    And the agent on "desktop" continues the carried session
