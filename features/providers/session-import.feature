# Sources:
#   https://github.com/pingdotgg/t3code/pull/27515
#   https://github.com/pingdotgg/t3code/pull/19161
#   apps/server-ex/lib/hal_c2/agent_sessions.ex (agentSessions.scan, agentSessions.import)
#   apps/server-ex/lib/hal_c2/acp/sessions.ex (server.listAcpRegistrySessions, server.importAcpRegistrySession,
#     server.deleteAcpRegistrySession, capability checks, error codes)
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex (a follow-up resumes the native session)
#   apps/server/src/agentSessions.ts, apps/web/src/components/settings/AcpSessionManagementSection.tsx
#   packages/contracts/src/agentSessions.ts
# The wizard's import step is specified in features/navigation/welcome-wizard.feature and the
# ACP session panel in features/settings/providers-panel.feature; this file is the provider side.
# Carrying a native session to another machine is specified in providers/portable-sessions.feature.

@mc
Feature: Importing native agent sessions
  Conversations the user had with an agent outside HAL-C2 can become HAL-C2 threads. Each
  provider plugin that keeps its own history says where it lives and how to resume it;
  the imported thread continues the native session on its next message.

  Background:
    Given a connected environment

  Scenario Outline: Native history is found and grouped by the directory it ran in
    Given <provider> has sessions in "~/code/shop" and "~/code/blog"
    When the MC scans for agent history
    Then "shop" and "blog" are offered as projects with their session counts from <provider>

    Examples:
      | provider    |
      | Claude Code |
      | Codex       |

  Scenario: A custom agent home is scanned
    Given CLAUDE_CONFIG_DIR points at "~/work-claude"
    When the MC scans for agent history
    Then Claude sessions under "~/work-claude" are found

  Scenario Outline: Directories that should not become projects are not offered
    Given Codex has sessions in <directory>
    When the MC scans for agent history
    Then that directory is not offered

    Examples:
      | directory                          |
      | a directory that no longer exists  |
      | the home directory                 |
      | the temporary directory            |
      | the Downloads directory            |
      | a git worktree of another checkout |
      | a HAL-C2 worktree                 |

  Scenario: A directory that is already a project is marked as imported
    Given the project "shop" is rooted at "~/code/shop"
    When the MC scans for agent history
    Then "shop" is offered as already imported

  Scenario: Very large histories are scanned in part and say so
    Given Codex has more sessions than a scan reads
    When the MC scans for agent history
    Then the newest sessions are offered
    And the scan says it was truncated

  Scenario: Importing a project turns its last 30 days of sessions into threads
    Given "shop" has Claude sessions from last week and from two months ago
    When the user imports "shop"
    Then last week's sessions become threads with their visible messages
    And the session from two months ago is not imported

  # Upstream #19161: tool and hidden records used up the history budget and skipped the session.
  @backlog @plugin-claude
  Scenario: A long Claude session that is mostly tool records is imported
    Given a Claude session of "shop" whose records are mostly tool calls and attachments
    And its visible conversation fits the import's history limit
    When the user imports "shop"
    Then the session becomes a thread with its visible messages, title and model
    And it is matched to "shop" by the directory it first ran in

  Scenario: An imported thread continues its native session
    Given a Claude session imported as a thread
    When the user sends a message in the thread
    Then Claude resumes the original session

  Scenario: A thread without a resumable model uses the provider's default model
    Given a Claude session whose only replies were Claude's own local errors
    When the user imports its project
    Then the thread uses Claude's default model

  Scenario: Importing a project whose directory changed is refused
    Given the user scanned "shop" at "~/code/shop"
    And "shop" has since moved to "~/work/shop"
    When the user imports "shop"
    Then the user is told the project changed directories and to scan again

  Scenario: Importing into a project that does not exist is refused
    When the user imports sessions into a project that was deleted
    Then the user is told the project does not exist

  Scenario: Importing an ACP agent's session twice finds the same thread
    Given the user imported a Gemini session as a thread
    When the user imports the same session again
    Then the existing thread is returned and no new thread is made

  Scenario: An imported ACP session starts supervised
    When the user imports a Gemini session
    Then the thread is supervised and uses the agent's default model

  Scenario Outline: ACP session management follows what the agent supports
    Given an ACP agent that <lacks>
    When the user <action>
    Then the user is told "<message>"

    Examples:
      | lacks                                 | action                        | message                                             |
      | cannot load or resume sessions        | imports one of its sessions   | The ACP agent cannot load or resume sessions.       |
      | cannot list sessions                  | lists its sessions            | The ACP agent does not support session/list.        |
      | cannot delete sessions                | deletes one of its sessions   | The ACP agent does not support session/delete.      |

  Scenario: An ACP agent that is not signed in says so
    Given an ACP agent that is not signed in
    When the user lists its sessions
    Then the user is told to sign in to the agent

  Scenario: An imported ACP session cannot be deleted while its thread exists
    Given a Gemini session imported as a thread
    When the user deletes the native session
    Then the user is told "Delete the imported HAL-C2 thread before deleting its native ACP session."

  Scenario: A native session can be deleted once its thread is deleted
    Given a Gemini session imported as a thread
    When the user deletes the thread and then the native session
    Then the native session is deleted

  Scenario: ACP sessions for a project on another MC are refused
    When the user lists an ACP agent's sessions for a project that is not on this MC
    Then the user is told "The project is not on this MC."

  @backlog
  Scenario Outline: Other providers' native history can be imported
    Given <provider> has native sessions for "shop"
    When the user imports "shop"
    Then those sessions become threads that resume on the next message

    Examples:
      | provider    |
      | Cursor      |
      | OpenCode    |
      | Grok        |
      | Pi          |
      | Antigravity |

  # Upstream #27515: Pi's terminal sessions could not be imported; the scan only knew Claude Code and Codex.
  @backlog @plugin-pi
  Scenario Outline: Pi's sessions are found where that Pi instance keeps them
    Given an enabled Pi instance whose environment sets <setting>
    When the MC scans for agent history
    Then the Pi sessions in <folder> are offered, kept per project or all in one folder

    Examples:
      | setting                                 | folder                 |
      | PI_CODING_AGENT_SESSION_DIR to "~/pi-s" | "~/pi-s"               |
      | only PI_CODING_AGENT_DIR to "~/pi"      | "~/pi/sessions"        |
      | neither                                 | "~/.pi/agent/sessions" |

  @backlog @plugin-pi
  Scenario: An imported Pi session with branches becomes the thread of its active branch
    Given a Pi session whose history branched after a rewind
    When the user imports it
    Then the thread holds the active branch, from its last entry back to the start
    And the next message continues that Pi session

  @backlog
  Scenario: A provider plugin declares where its history lives
    Given a provider plugin that declares a history location and a resume method
    When the MC scans for agent history
    Then that plugin's sessions are offered alongside Claude and Codex
