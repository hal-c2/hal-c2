# Sources:
#   https://github.com/pingdotgg/t3code/pull/23219
#   https://github.com/pingdotgg/t3code/pull/23690
#   https://github.com/pingdotgg/t3code/pull/23192
#   https://github.com/pingdotgg/t3code/pull/27743
#   https://github.com/pingdotgg/t3code/pull/24982
#   https://github.com/pingdotgg/t3code/pull/23747
#   https://github.com/pingdotgg/t3code/pull/12292
#   https://github.com/pingdotgg/t3code/pull/21464
#   https://github.com/pingdotgg/t3code/pull/16662
#   https://github.com/pingdotgg/t3code/pull/15634
#   https://github.com/pingdotgg/t3code/pull/20278
#   https://github.com/pingdotgg/t3code/pull/30174
#   https://github.com/pingdotgg/t3code/pull/30652
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

  # Upstream #23747: an origin URL written on the remote's section header line was missed, or the next remote's was used.
  @mc @backlog
  Scenario: A remote URL on its section's header line is the repository identity
    Given "~/code/app" has the git config line '[remote "origin"] url = git@github.com:a/b.git' followed by an "upstream" remote
    When a client scans for agent sessions
    Then candidate "app" carries the key for "git@github.com:a/b.git"

  # Upstream #30174: a "bare = true" continued onto the next line with a backslash was missed, so
  # the linked checkouts of that bare repository were skipped as ordinary linked worktrees.
  @mc @backlog @priority-low
  Scenario Outline: A linked checkout of a bare repository is offered
    Given an agent session ran in "~/code/app", a linked checkout of a bare repository
    And the bare repository's git config writes "bare = true" <how>
    When a client scans for agent sessions
    Then "app" is a candidate

    Examples:
      | how                                                       |
      | on one line                                               |
      | continued onto the next line                              |
      | continued onto a last line that has no newline at its end |

  # Upstream #23690: a git config that never opens (a FIFO, or a macOS-protected folder) pinned a
  # shared file worker per scan until the whole server stopped answering.
  @mc @backlog @priority-high
  Scenario Outline: A scan is not held up by a git config that never opens
    Given "~/code/app" has <config>
    When a client scans for agent sessions four times
    Then every scan finishes within a few seconds
    And candidate "app" is listed without a repository identity
    And the MC keeps answering other requests

    Examples:
      | config                                             |
      | a FIFO at ".git/config"                            |
      | a ".git/config" the MC is not allowed to read      |

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

  # Upstream #23219: the first follow-up to an imported Claude Code session tried to create the
  # session again and failed with "Session ID … is already in use".
  @mc @backlog @plugin-claude @priority-high
  Scenario: The first message to an imported Claude session resumes it
    Given a Claude Code terminal conversation was imported as a thread
    When the user sends the first follow-up in that thread
    Then the provider resumes the original Claude session on that first send
    And the thread shows no "already in use" failure

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

  # Upstream #15634: bulk import skips a native session another thread already owns, archived
  # and deleted owners included, and counts it as neither imported nor failed.
  @mc @backlog @priority-high
  Scenario Outline: A session a thread already runs is not imported again
    Given thread "t1" in "demo" already runs the agent session "s1" and is <state>
    When a client imports agent sessions for "demo"
    Then no new thread is created for "s1"
    And "s1" is counted as neither imported nor failed

    Examples:
      | state    |
      | active   |
      | archived |
      | deleted  |

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

  # Upstream #27743: long imports dropped their older messages without saying so.
  @mc @backlog
  Scenario Outline: An imported thread says how many older messages it left out
    Given a session has <count> visible messages
    When it is imported
    Then its thread <notice>

    Examples:
      | count | notice                                                                   |
      | 205   | starts with a notice that 5 messages were left out, before the first prompt |
      | 200   | starts with no notice                                                     |

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

  # Upstream #12292: imports ignored a user's rename; an empty rename restores the fallback.
  @backlog @mc @plugin-claude
  Scenario: An imported Claude session keeps the title the user gave it
    Given a Claude session the user renamed "Cart totals" and Claude later titled "Fix rounding"
    When it is imported
    Then its thread title is "Cart totals"

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

  # Upstream #20278: imported Codex threads are titled after the user's request
  @backlog @mc @plugin-codex
  Scenario: An imported Codex thread is titled after what the user asked
    Given a Codex session whose first message starts with injected setup instructions before the user's request
    When the session is imported
    Then the thread's title comes from the user's request, not the setup instructions

  # Upstream #20278: a first message that is only setup does not title the thread
  @backlog @mc @plugin-codex
  Scenario: An imported Codex thread whose first message is only setup is titled from the next one
    Given a Codex session whose first message holds only injected setup instructions
    When the session is imported
    Then the thread's title comes from the next message the user wrote

  # Upstream #24982: imports ignored the name a user saved for a Codex conversation.
  @backlog @mc @plugin-codex
  Scenario: An imported Codex thread keeps the name the user saved in Codex
    Given a Codex conversation the user renamed "Renamed chat", then "Cart totals", then to a blank name
    When it is imported
    Then its thread title is "Cart totals"
    And a Codex conversation with no saved name is titled from its messages as before

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
  @mc @backlog @priority-high
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
  @mc @backlog @priority-low
  Scenario: A transcript with a record nested absurdly deep is skipped whole
    Given a session's transcript has a record nested more than 128 levels deep
    When a client imports the agent sessions of "demo"
    Then that session is counted as skipped
    And no part of it is imported

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (readTranscript, sameTranscriptIdentity)
  @mc @backlog @priority-low
  Scenario: A transcript that changes while it is being read is not imported
    Given an agent is still writing a session's transcript
    When a client imports the agent sessions of "demo" and the transcript changes during the read
    Then that session is counted as skipped
    And no half-read thread is created

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (MAX_IMPORTED_TRANSCRIPT_BYTES, MAX_IMPORT_HISTORY_BYTES, MAX_IMPORT_RECORDS)
  @mc @backlog @priority-low
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
  @mc @backlog @priority-low
  Scenario: Imports from several clients read one transcript at a time
    Given two clients import agent sessions at the same moment
    Then the transcripts are read one after another, not together
    And both imports finish with their own results

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (MAX_TRANSCRIPT_SCAN_BYTES, MAX_METADATA_BYTES_PER_SOURCE, MAX_DISCOVERY_OPERATIONS_PER_SOURCE)
  @mc @backlog @priority-low
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
  @mc @backlog @priority-high
  Scenario: Rewinding a thread keeps the history imported before its first turn
    Given an imported thread "t1" that the user continued for two turns
    When a client rewinds "t1" to before its first new turn
    Then the imported messages are still in "t1"
    And the messages of the two new turns are gone

  # Legacy: apps/server/src/orchestration/decider.ts (thread.history.import)
  @mc @backlog @priority-high
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
  @mc @backlog @priority-low
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
  @mc @backlog @priority-low
  Scenario: A submodule checkout is offered like any other repository
    Given sessions ran in "~/code/app/vendor/lib", which is a submodule checkout
    When a client scans for agent sessions
    Then "lib" is a candidate

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (collectCandidates: resolveProviderInstanceEnabled)
  @mc @backlog @priority-low
  Scenario: A disabled agent account is not scanned
    Given the Claude account "work" is disabled and its home holds sessions
    When a client scans for agent sessions
    Then those sessions are not offered

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (selectMetadataTranscripts)
  @mc @backlog @priority-low
  Scenario: A busy account does not hide another account's sessions from a capped scan
    Given the Claude account "work" has 5,000 newer transcripts than the account "personal"
    When a client scans for agent sessions
    Then sessions of "personal" are offered as well as those of "work"

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (collectCandidates: seenHomes, instance order)
  @mc @backlog @priority-low
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
  @mc @backlog @priority-low
  Scenario: Folders that differ only in case stay apart on a disk that tells them apart
    Given "~/code/App" and "~/code/app" are different folders on a case-sensitive disk
    And sessions ran in each
    When a client scans for agent sessions
    Then "App" and "app" are separate candidates

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (scan: importedProjectsByRoot)
  @mc @backlog @priority-low
  Scenario: A project is recognised through a link to its folder and keeps its own path
    Given project "demo" has the folder "~/code/app"
    And sessions were recorded under "~/links/app", a link to that folder
    When a client scans for agent sessions
    Then the candidate is marked already imported with project "demo"
    And the candidate's path is "~/code/app"

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (readCwd)
  @mc @backlog @priority-low
  Scenario: A transcript is placed by a folder named after its first records
    Given a transcript whose first records hold only history and name the folder "~/code/app" in a later record
    When a client scans for agent sessions
    Then the transcript counts toward "app"

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (prepareRecentThreads: transcript.mtimeMs > nowMs)
  @mc @backlog @priority-low
  Scenario: A transcript dated in the future is not imported
    Given project "demo" has a session whose transcript was last changed tomorrow
    When a client imports agent sessions for "demo"
    Then no thread is created for it

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (importedSessions, Duplicate), AgentSessionImporter.ts
  @mc @backlog @priority-low
  Scenario: A session copied into two transcript files is imported once without being counted skipped
    Given project "demo" has the same Claude session in two transcript files
    When a client imports agent sessions for "demo"
    Then one thread exists for the session
    And the import reports 1 imported and 0 skipped

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (prepareRecentThreads: snapshotCwd)
  @mc @backlog @priority-low
  Scenario: A transcript replaced by one from another folder is not imported into this project
    Given a client scanned "demo" at "~/code/app"
    And a transcript counted for "demo" was replaced before the import by one that ran in "~/code/lib"
    When the client imports agent sessions for "demo"
    Then that session is counted as skipped

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (normalizeTimestamp, parseAgentSessionRecords)
  @mc @backlog @priority-low
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

  # Upstream #30652: a Codex rewind writes a new transcript that builds on the one it replaces; only
  # the newest was read, so the imported thread began at the last rewind.
  @mc @backlog @plugin-codex
  Scenario: A rewound Codex session is imported with what came before the rewind
    Given a Codex session was rewound four times, leaving five transcripts that each build on the last
    When it is imported
    Then one thread is imported with the messages from before the rewinds, then those after
    And the import stays within its usual history and size budgets

  # Upstream #30652: a broken chain keeps today's import of the newest transcript.
  @mc @backlog @plugin-codex @priority-low
  Scenario: A rewound Codex session whose earlier transcript is gone imports the newest alone
    Given a rewound Codex session whose earlier transcript is missing
    When it is imported
    Then the thread holds the newest transcript's messages

  # Upstream #16662: Codex subagent, review and other child sessions were imported as threads of
  # their own and used up the budget before their parents.
  @mc @backlog @plugin-codex
  Scenario: Codex subagent sessions are not imported as threads of their own
    Given a folder holds 100 recent Codex subagent sessions and 4 older top-level sessions
    When a client imports agent sessions for "demo"
    Then the 4 top-level sessions are imported
    And the subagent sessions are neither imported nor counted

  # Legacy: apps/server/src/project/AgentSessionImporter.ts (providerInstanceId from the session's home)
  @mc @backlog
  Scenario: An imported session stays with the account whose home holds it
    Given a Claude session is in the home of the account "work"
    When it is imported
    Then the thread belongs to the account "work"
    And a follow-up resumes the session through that account

  # Legacy: apps/server/src/project/AgentSessionScanner.ts (MAX_IMPORT_BYTES, MAX_IMPORT_TRANSCRIPTS)
  # Upstream #23192: the 100,000-record limit is each transcript's own, not a budget they share.
  @mc @backlog @priority-low
  Scenario: An import stops taking sessions once it has read its overall budget
    Given project "demo" has recent sessions whose transcripts together hold more than 4 GiB
    When a client imports agent sessions for "demo"
    Then the sessions that fit are imported
    And every later session is counted as skipped without being read

  # Upstream #23192: transcripts shared one 100,000-record allowance, so the last of four valid
  # conversations was skipped until a retry.
  @mc @backlog @priority-low
  Scenario: Each transcript gets its own record limit
    Given project "demo" has Codex transcripts of 20,000, 20,000, 20,000 and 58,000 records
    When a client imports agent sessions for "demo"
    Then all four conversations are imported

  # Upstream #21464: large Windows file ids collided, so a replaced transcript looked imported.
  @backlog @mc @priority-low
  Scenario: A transcript replaced at the same path is imported again on Windows
    Given an imported session's transcript is replaced by another of the same size and time
    And Windows gives the two files ids that differ only past 2^53
    When the MC scans for sessions
    Then the replacement is imported
