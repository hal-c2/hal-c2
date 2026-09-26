# Sources:
#   apps/server-ex/lib/t3/agent_sessions.ex (agentSessions.scan, agentSessions.import)
#   apps/server/src/project/AgentSessionScanner.ts and its import service
#   packages/contracts/src/ (AgentSessionScanResult, AgentSessionImportProjectNotFoundError,
#     AgentSessionImportProjectChangedError)
#   Entities written: thread (historyOrigin v1_import, settled), provider-thread with the
#     native session reference, messages
Feature: Importing history from agents already used on this machine
  Claude Code and Codex keep a transcript per session. The node finds the folders
  those sessions ran in, offers them as projects, and imports a project's recent
  sessions as settled threads that resume the native session on a follow-up.

  Background:
    Given Claude Code and Codex transcripts exist on this machine

  @node @plugin-claude @plugin-codex
  Scenario: Scanning groups sessions by the folder they ran in
    Given 3 sessions ran in "~/code/app" and 1 in "~/code/lib"
    When a client scans for agent sessions
    Then it receives candidates "app" with 3 threads and "lib" with 1, newest first
    And each candidate names the agents that used it and when it was last active

  @node
  Scenario Outline: Some folders are never offered
    Given sessions ran in <folder>
    When a client scans for agent sessions
    Then that folder is not a candidate

    Examples:
      | folder                             |
      | the home folder itself             |
      | the temporary folder               |
      | a folder under Downloads           |
      | the T3 home                        |
      | a T3 worktree                      |
      | a linked git worktree              |
      | a folder that no longer exists     |

  @node
  Scenario: A folder that is already a project is marked imported
    Given project "demo" has the folder "~/code/app"
    When a client scans for agent sessions
    Then candidate "app" is marked already imported with project "demo"

  @node
  Scenario: Candidates carry the repository identity
    Given "~/code/app" is a git repository cloned from a remote
    When a client scans for agent sessions
    Then candidate "app" carries a key for that remote shared by every clone

  @node
  Scenario: A very large number of transcripts is capped
    Given more than 5,000 Codex transcripts exist
    When a client scans for agent sessions
    Then only the newest 5,000 are read and the result is marked truncated

  @node
  Scenario: Importing turns recent sessions into settled threads
    Given project "demo" has the folder "~/code/app" with 2 sessions from this week
    When a client imports agent sessions for "demo"
    Then 2 threads exist in "demo", settled, created by the system, with their visible messages
    And each is marked as imported history
    And the import reports 2 imported and 0 skipped

  @node
  Scenario: An imported thread resumes the native session
    Given a Claude session was imported as a thread
    When the user sends a follow-up in that thread
    Then the provider resumes the original Claude session

  @node
  Scenario: Sessions older than 30 days are not imported
    Given project "demo" has one session from 40 days ago
    When a client imports agent sessions for "demo"
    Then no thread is created for it

  @node
  Scenario: Importing twice does not duplicate threads
    Given agent sessions of "demo" were imported
    When a client imports them again
    Then no new threads are created

  @node
  Scenario: At most 100 sessions are imported and the rest reported skipped
    Given project "demo" has 120 recent sessions
    When a client imports agent sessions for "demo"
    Then the newest 100 are imported and 20 are reported skipped

  @node
  Scenario: Long sessions keep the first prompt and the last messages
    Given a session has 500 visible messages
    When it is imported
    Then its thread holds the first user prompt followed by the latest messages, 200 in all

  @node
  Scenario Outline: Imported titles
    Given a session <title source>
    When it is imported
    Then its thread title is <title>

    Examples:
      | title source                               | title                                      |
      | has a title Claude generated               | that title                                 |
      | has no title and a multi-line first prompt | the first line of the prompt, up to 100 characters |
      | has no title and a blank first prompt      | "Imported thread"                          |

  @node
  Scenario: Imported threads use the session's model
    Given a Codex session ran on "gpt-5.4"
    When it is imported
    Then its thread's model is "gpt-5.4" on "codex"

  @node
  Scenario: Only what the user saw is imported
    Given a Claude session has side-chain, meta and compaction summary records
    When it is imported
    Then those records are not messages of the thread

  @node @plugin-codex
  Scenario: Codex prompts are imported as the user typed them
    Given a Codex session records each prompt both as typed and with setup text
    When it is imported
    Then each user message is the typed prompt only

  @node
  Scenario Outline: Sessions that cannot be resumed are skipped
    Given a session <problem>
    When its project is imported
    Then it is counted as skipped

    Examples:
      | problem                        |
      | has no session id              |
      | has no user prompt             |
      | has a malformed Claude session id |

  @node
  Scenario: Importing into an unknown project fails
    When a client imports agent sessions for project "nowhere"
    Then it fails with "Project 'nowhere' does not exist."

  @node
  Scenario: Importing into a project that moved folders fails
    Given the client scanned "demo" at "~/code/app" and the project now points elsewhere
    When the client imports expecting "~/code/app"
    Then it fails with "Project 'demo' changed directories. Scan for projects again."

  @node
  Scenario: Oversized transcript lines are skipped unread
    Given a transcript contains a tool result line larger than 4 MB
    When it is imported
    Then the line is skipped and the rest of the session is imported
