# Sources:
#   apps/server-ex/lib/hal_c2/agent_sessions.ex (agentSessions.scan, agentSessions.import)
#   apps/server/src/project/AgentSessionScanner.ts and its import service
#   apps/server/src/project/AgentSessionImporter.ts (modified or moved threads), AgentSessionJson.ts (streaming selection and limits)
#   apps/server/src/orchestration/decider.ts (thread.history.import, reserved import: message ids),
#     apps/server/src/orchestration/projector.ts (imported messages survive a rewind)
#   packages/contracts/src/ (AgentSessionScanResult, AgentSessionImportProjectNotFoundError,
#     AgentSessionImportProjectChangedError)
#   Entities written: thread (historyOrigin v1_import, settled), provider-thread with the
#     native session reference, messages
Feature: Importing history from agents already used on this machine
  Claude Code and Codex keep a transcript per session. The MC finds the folders
  those sessions ran in, offers them as projects, and imports a project's recent
  sessions as settled threads that resume the native session on a follow-up.

  Background:
    Given Claude Code and Codex transcripts exist on this machine

  @mc @plugin-claude @plugin-codex
  Scenario: Scanning groups sessions by the folder they ran in
    Given 3 sessions ran in "~/code/app" and 1 in "~/code/lib"
    When a client scans for agent sessions
    Then it receives candidates "app" with 3 threads and "lib" with 1, newest first
    And each candidate names the agents that used it and when it was last active

  @mc
  Scenario Outline: Some folders are never offered
    Given sessions ran in <folder>
    When a client scans for agent sessions
    Then that folder is not a candidate

    Examples:
      | folder                             |
      | the home folder itself             |
      | the temporary folder               |
      | a folder under Downloads           |
      | the HAL-C2 home                        |
      | a HAL-C2 worktree                      |
      | a linked git worktree              |
      | a folder that no longer exists     |

  @mc
  Scenario: A folder that is already a project is marked imported
    Given project "demo" has the folder "~/code/app"
    When a client scans for agent sessions
    Then candidate "app" is marked already imported with project "demo"

  @mc
  Scenario: Candidates carry the repository identity
    Given "~/code/app" is a git repository cloned from a remote
    When a client scans for agent sessions
    Then candidate "app" carries a key for that remote shared by every clone

  @mc
  Scenario: A very large number of transcripts is capped
    Given more than 5,000 Codex transcripts exist
    When a client scans for agent sessions
    Then only the newest 5,000 are read and the result is marked truncated

  @mc
  Scenario: Importing turns recent sessions into settled threads
    Given project "demo" has the folder "~/code/app" with 2 sessions from this week
    When a client imports agent sessions for "demo"
    Then 2 threads exist in "demo", settled, created by the system, with their visible messages
    And each is marked as imported history
    And the import reports 2 imported and 0 skipped

  @mc
  Scenario: An imported thread resumes the native session
    Given a Claude session was imported as a thread
    When the user sends a follow-up in that thread
    Then the provider resumes the original Claude session

  @mc
  Scenario: Sessions older than 30 days are not imported
    Given project "demo" has one session from 40 days ago
    When a client imports agent sessions for "demo"
    Then no thread is created for it

  @mc
  Scenario: Importing twice does not duplicate threads
    Given agent sessions of "demo" were imported
    When a client imports them again
    Then no new threads are created

  @mc
  Scenario: At most 100 sessions are imported and the rest reported skipped
    Given project "demo" has 120 recent sessions
    When a client imports agent sessions for "demo"
    Then the newest 100 are imported and 20 are reported skipped

  @mc
  Scenario: Long sessions keep the first prompt and the last messages
    Given a session has 500 visible messages
    When it is imported
    Then its thread holds the first user prompt followed by the latest messages, 200 in all

  # Neither server keeps a blank prompt (both skip it), so its title comes from the next one.
  @mc
  Scenario Outline: Imported titles
    Given a session <title source>
    When it is imported
    Then its thread title is <title>

    Examples:
      | title source                               | title                                      |
      | has a title Claude generated               | that title                                 |
      | has no title and a multi-line first prompt | the first line of the prompt, up to 100 characters |
      | has no title and a blank first prompt      | the first line of the next prompt          |

  @mc
  Scenario: Imported threads use the session's model
    Given a Codex session ran on "gpt-5.4"
    When it is imported
    Then its thread's model is "gpt-5.4" on "codex"

  @mc
  Scenario: Only what the user saw is imported
    Given a Claude session has side-chain, meta and compaction summary records
    When it is imported
    Then those records are not messages of the thread

  @mc @plugin-codex
  Scenario: Codex prompts are imported as the user typed them
    Given a Codex session records each prompt both as typed and with setup text
    When it is imported
    Then each user message is the typed prompt only

  @mc
  Scenario Outline: Sessions that cannot be resumed are skipped
    Given a session <problem>
    When its project is imported
    Then it is counted as skipped

    Examples:
      | problem                        |
      | has no session id              |
      | has no user prompt             |
      | has a malformed Claude session id |

  @mc
  Scenario: Importing into an unknown project fails
    When a client imports agent sessions for project "nowhere"
    Then it fails with "Project 'nowhere' does not exist."

  @mc
  Scenario: Importing into a project that moved folders fails
    Given the client scanned "demo" at "~/code/app" and the project now points elsewhere
    When the client imports expecting "~/code/app"
    Then it fails with "Project 'demo' changed directories. Scan for projects again."

  @mc
  Scenario: Oversized transcript lines are skipped unread
    Given a transcript contains a tool result line larger than 4 MB
    When it is imported
    Then the line is skipped and the rest of the session is imported

  # Legacy: apps/server/src/project/AgentSessionImporter.ts (AgentSessionThreadModifiedError, AgentSessionThreadProjectConflictError)
  @mc @backlog
  Scenario Outline: An imported thread the user has since used or moved is left alone
    Given a session was imported as a thread and <change>
    When a client imports the agent sessions of "demo" again
    Then the thread is not overwritten
    And the session is counted as skipped

    Examples:
      | change                                              |
      | the user continued it in HAL-C2                     |
      | the thread now belongs to another project           |

  # Legacy: apps/server/src/project/AgentSessionJson.ts (createTranscriptJsonReader), AgentSessionScanner.ts (readTranscript)
  @mc @backlog
  Scenario Outline: A damaged record in a transcript costs only that record
    Given a session's transcript has one line that <damage>
    When a client imports the agent sessions of "demo"
    Then the session is imported with its other messages
    And that line is not a message of the thread

    Examples:
      | damage                                        |
      | is cut off in the middle of its JSON          |
      | is not JSON at all                            |
      | has no message in it that the MC understands  |

  # Legacy: apps/server/src/project/AgentSessionJson.ts (TranscriptJsonLimitError, depth 128)
  @mc @backlog
  Scenario: A transcript with a record nested absurdly deep is skipped whole
    Given a session's transcript has a record nested more than 128 levels deep
    When a client imports the agent sessions of "demo"
    Then that session is counted as skipped
    And no part of it is imported

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (readTranscript, sameTranscriptIdentity)
  @mc @backlog
  Scenario: A transcript that changes while it is being read is not imported
    Given an agent is still writing a session's transcript
    When a client imports the agent sessions of "demo" and the transcript changes during the read
    Then that session is counted as skipped
    And no half-read thread is created

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (MAX_IMPORTED_TRANSCRIPT_BYTES, MAX_IMPORT_HISTORY_BYTES, MAX_IMPORT_RECORDS)
  @mc @backlog
  Scenario Outline: A transcript past its import budget is skipped whole
    Given a session's transcript <excess>
    When a client imports the agent sessions of "demo"
    Then that session is counted as skipped
    And no part of it is imported

    Examples:
      | excess                                                 |
      | is larger than 4 GiB                                   |
      | holds more than 32 MiB of messages after filtering     |
      | has more than 100,000 records                          |

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (importReadLock)
  @mc @backlog
  Scenario: Imports from several clients read one transcript at a time
    Given two clients import agent sessions at the same moment
    Then the transcripts are read one after another, not together
    And both imports finish with their own results

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (MAX_TRANSCRIPT_SCAN_BYTES, MAX_METADATA_BYTES_PER_SOURCE, MAX_DISCOVERY_OPERATIONS_PER_SOURCE)
  @mc @backlog
  Scenario: Scanning a huge history stops at its read budget instead of reading everything
    Given an agent home holds tens of thousands of transcripts and a transcript whose folder is not in its first megabyte
    When a client scans for agent sessions
    Then the scan reads only a bounded amount of each source, newest first
    And a transcript whose folder was not found is not offered
    And the result says it was truncated

  # Legacy: apps/server/src/orchestration/decider.ts (reserved imported-session message ids)
  @mc @backlog
  Scenario: A new message cannot take an id from the imported-history namespace
    Given an imported thread "t1" exists
    When a client sends a message to "t1" with the id "import:session-1:0"
    Then the command fails with "Message id 'import:session-1:0' uses the reserved imported-session namespace."

  # Legacy: apps/server/src/orchestration/projector.ts (retainThreadMessagesAfterRevert)
  @mc @backlog
  Scenario: Rewinding a thread keeps the history imported before its first turn
    Given an imported thread "t1" that the user continued for two turns
    When a client rewinds "t1" to before its first new turn
    Then the imported messages are still in "t1"
    And the messages of the two new turns are gone

  # Legacy: apps/server/src/orchestration/decider.ts (thread.history.import)
  @mc @backlog
  Scenario Outline: History is imported only into a thread that is active and empty
    Given thread "t1" <state>
    When a client imports history into "t1"
    Then the command fails with "Thread 't1' must be active and empty before history can be imported."

    Examples:
      | state                         |
      | already has a message         |
      | is archived                   |
      | has a provider session        |
      | has a pending request         |

  # Legacy: apps/server/src/orchestration/decider.ts (thread.history.import)
  @mc @backlog
  Scenario: A history import with no messages is refused
    Given thread "t1" is active and empty
    When a client imports history into "t1" with no messages
    Then the command fails with "Thread history imports require at least one message."

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (excludedProjectAncestors, extractCwd, isHalC2ManagedWorktree)
  @mc @backlog
  Scenario Outline: Scratch and leftover folders are not offered
    Given sessions ran in <folder>
    When a client scans for agent sessions
    Then that folder is not a candidate

    Examples:
      | folder                                                                  |
      | a scratch folder Codex made under "~/Documents/Codex"                    |
      | a folder under the old HAL-C2 home "~/.hal-c2"                           |
      | a folder under the old T3 Code home "~/.t3"                              |
      | a link that leads into a HAL-C2 worktree folder                          |
      | a folder a transcript names with a relative path                         |

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (readGitIdentity: submodules)
  @mc @backlog
  Scenario: A submodule checkout is offered like any other repository
    Given sessions ran in "~/code/app/vendor/lib", which is a submodule checkout
    When a client scans for agent sessions
    Then "lib" is a candidate

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (collectCandidates: resolveProviderInstanceEnabled)
  @mc @backlog
  Scenario: A disabled agent account is not scanned
    Given the Claude account "work" is disabled and its home holds sessions
    When a client scans for agent sessions
    Then those sessions are not offered

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (selectMetadataTranscripts)
  @mc @backlog
  Scenario: A busy account does not hide another account's sessions from a capped scan
    Given the Claude account "work" has 5,000 newer transcripts than the account "personal"
    When a client scans for agent sessions
    Then sessions of "personal" are offered as well as those of "work"

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (collectCandidates: seenHomes, instance order)
  @mc @backlog
  Scenario: Accounts that share one home are scanned once under the default account
    Given the Claude account "work" uses the same home as the default Claude account
    When a client scans for agent sessions
    Then each session is offered once
    And importing it creates a thread of the default Claude account

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (resolveClaudeConfigDir, collectCandidates)
  @mc @backlog
  Scenario Outline: Where an account's sessions are looked for
    Given a Claude account <setup>
    When a client scans for agent sessions
    Then its sessions are looked for under <home>

    Examples:
      | setup                                                                                      | home                  |
      | with the home folder "~/work-claude" set and CLAUDE_CONFIG_DIR set elsewhere in its environment | "~/work-claude"       |
      | with no home folder but CLAUDE_CONFIG_DIR "~/env-claude" in its own environment               | "~/env-claude"        |
      | with nothing set and CLAUDE_CONFIG_DIR "~/host-claude" in the MC's environment                | "~/host-claude"       |
      | with nothing set anywhere                                                                  | "~/.claude"           |

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (scan: directoryIdentity merges aliases)
  @mc @backlog
  Scenario: Different spellings of one folder are one candidate
    Given sessions were recorded under "~/code/app" and under "~/links/app", a link to the same folder
    When a client scans for agent sessions
    Then there is one candidate "app" counting the sessions of both

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (directoryIdentity)
  @mc @backlog
  Scenario: Folders that differ only in case stay apart on a disk that tells them apart
    Given "~/code/App" and "~/code/app" are different folders on a case-sensitive disk
    And sessions ran in each
    When a client scans for agent sessions
    Then "App" and "app" are separate candidates

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (scan: importedProjectsByRoot)
  @mc @backlog
  Scenario: A project is recognised through a link to its folder and keeps its own path
    Given project "demo" has the folder "~/code/app"
    And sessions were recorded under "~/links/app", a link to that folder
    When a client scans for agent sessions
    Then the candidate is marked already imported with project "demo"
    And the candidate's path is "~/code/app"

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (readCwd)
  @mc @backlog
  Scenario: A transcript is placed by a folder named after its first records
    Given a transcript whose first records hold only history and name the folder "~/code/app" in a later record
    When a client scans for agent sessions
    Then the transcript counts toward "app"

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (prepareRecentThreads: transcript.mtimeMs > nowMs)
  @mc @backlog
  Scenario: A transcript dated in the future is not imported
    Given project "demo" has a session whose transcript was last changed tomorrow
    When a client imports agent sessions for "demo"
    Then no thread is created for it

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (importedSessions, Duplicate), AgentSessionImporter.ts
  @mc @backlog
  Scenario: A session copied into two transcript files is imported once without being counted skipped
    Given project "demo" has the same Claude session in two transcript files
    When a client imports agent sessions for "demo"
    Then one thread exists for the session
    And the import reports 1 imported and 0 skipped

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (prepareRecentThreads: snapshotCwd)
  @mc @backlog
  Scenario: A transcript replaced by one from another folder is not imported into this project
    Given a client scanned "demo" at "~/code/app"
    And a transcript counted for "demo" was replaced before the import by one that ran in "~/code/lib"
    When the client imports agent sessions for "demo"
    Then that session is counted as skipped

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (normalizeTimestamp, parseAgentSessionRecords)
  @mc @backlog
  Scenario: A message with no readable time takes the transcript's last change time
    Given a session has a message whose time is missing or not a date
    When it is imported
    Then that message is dated with the transcript's last change time

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (session_meta: hasCodexSessionId)
  @mc @backlog @plugin-codex
  Scenario: A forked Codex session is imported under its own id
    Given a Codex session was forked and its transcript begins with its ancestor's session metadata
    When it is imported
    Then the thread resumes the id the transcript names first

  # Legacy: apps/server/src/project/AgentSessionImporter.ts (providerInstanceId from the session's home)
  @mc @backlog
  Scenario: An imported session stays with the account whose home holds it
    Given a Claude session is in the home of the account "work"
    When it is imported
    Then the thread belongs to the account "work"
    And a follow-up resumes the session through that account

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (MAX_IMPORT_BYTES, MAX_IMPORT_TRANSCRIPTS, MAX_IMPORT_RECORDS)
  @mc @backlog
  Scenario: An import stops taking sessions once it has read its overall budget
    Given project "demo" has recent sessions whose transcripts together hold more than 4 GiB or 100,000 records
    When a client imports agent sessions for "demo"
    Then the sessions that fit are imported
    And every later session is counted as skipped without being read
