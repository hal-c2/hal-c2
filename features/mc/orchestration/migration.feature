# Sources:
#   apps/server-ex/lib/hal_c2/import/v2.ex (Node V2 orchestration_events import)
#   apps/server-ex/lib/mix/tasks/hal_c2.import.ex (the manual import task)
#   apps/server-ex/lib/hal_c2/import/v1_thread.ex (version 1 threads)
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex (legacy_summary, the imported history)
#   apps/server/src/orchestration-v2/LegacyV1ThreadImporter.ts,
#     apps/server/src/serverRuntimeStartup.ts (legacyThreadMigration startup phase),
#     apps/server/src/orchestration-v2/ContextHandoffService.ts (legacy import summary)
#   apps/server/src/orchestration-v2/Orchestrator.ts (imported history handed over until a run completes)
#   apps/server/src/persistence/Migrations/054_OrchestrationV2.ts
#   apps/server/src/persistence/Migrations/024_BackfillProjectionThreadShellSummary.ts,
#     025_CleanupInvalidProjectionPendingApprovals.ts, 044_ClearAutomaticProjectModelDefaults.ts,
#     046_RepairAutomaticSettlementTimestamps.ts (repairs the import must not undo)
#   V2 events replayed: thread.*, run.*, run-attempt.*, turn-item.updated, message.updated,
#     provider-session.attached, provider-session.updated, provider-session.detached,
#     provider-thread.updated, thread.visited, thread.marked-unread
Feature: Bringing history over from the Node server
  An operator can import a Node server's orchestration history into an MC, so
  projects and threads carry over. The import only reads the source.

  Background:
    Given a snapshot of a Node server's database with V2 orchestration history

  @mc
  Scenario: Importing a Node server's history
    When the operator imports the snapshot into an MC
    Then every project and thread stream of the snapshot exists on the MC
    And the operator is told how many streams, events and bytes went in and were kept

  @mc
  Scenario: The source is never written
    When the operator imports the snapshot into an MC
    Then the snapshot is opened read-only and is unchanged afterwards

  @mc
  Scenario: Streaming text is stored as changes, not repeated copies
    Given the snapshot stored a streamed reply as 500 full copies of the growing message
    When the operator imports the snapshot into an MC
    Then the MC keeps only what changed between the copies
    And the imported message reads the same as in the Node server

  @mc
  Scenario: An update that changes nothing is dropped
    Given the snapshot records the same thread state twice in a row
    When the operator imports the snapshot into an MC
    Then only one change is kept for it

  @mc
  Scenario: A provider session belongs to a thread only while attached
    Given the snapshot attaches a provider session to "t1", updates it, detaches it, then updates it again
    When the operator imports the snapshot into an MC
    Then the update after detaching does not change "t1"

  @mc
  Scenario: The latest provider thread becomes the thread's active one
    Given the snapshot updates provider thread "p2" of "t1" after "p1"
    When the operator imports the snapshot into an MC
    Then "t1" has "p2" as its active provider thread

  @mc
  Scenario: A provider thread queued for a future run does not become active
    Given the snapshot records a queued placeholder provider thread for "t1"
    When the operator imports the snapshot into an MC
    Then "t1" keeps its previous active provider thread

  @mc
  Scenario: Imported visits and unread marks do not reorder threads
    Given the snapshot records a visit to "t1" after its last activity
    When the operator imports the snapshot into an MC
    Then the activity time of "t1" is its last real activity

  @mc
  Scenario: Streams are imported one at a time
    Given the snapshot holds thousands of threads
    When the operator imports the snapshot into an MC
    Then the MC imports them in order of first activity, holding one thread in memory at a time

  @mc
  Scenario: The import is started by the operator, not at startup
    Given an MC starts next to a Node server's database
    Then nothing is imported until the operator runs the import

  @mc
  Scenario: Threads the Node server kept as version 1 events are migrated by the import
    Given the snapshot holds a thread logged by the version 1 orchestrator
    When the operator imports the snapshot into an MC
    Then the thread is migrated with its transcript, pull request link and attachments

  # The Node server migrates version 1 threads as it starts and reports progress to
  # clients. The MC imports only when the operator runs the import (above), so this
  # conflicts with that decision; a maintainer should keep or drop it.
  @mc @backlog
  Scenario: A version 1 database is migrated on startup
    Given the Node server's database holds threads from the version 1 orchestrator
    When the MC starts on it
    Then the threads are migrated with their transcripts, pull request links and attachments
    And clients see migration progress with the number of threads while it runs

  # The scenarios below describe how the Node server migrates version 1 threads as it
  # starts. They share the keep-or-drop decision of the scenario above.
  @mc @backlog
  Scenario: Version 1 threads are listed before their transcripts are migrated
    Given the Node server's database holds many threads from the version 1 orchestrator
    When the MC starts on it
    Then every thread is listed at once with its latest message and latest user message
    And the full transcripts are brought over afterwards, oldest listed first, without holding up startup

  @mc @backlog
  Scenario: Opening a version 1 thread migrates its transcript first
    Given a version 1 thread is listed and its transcript is not migrated yet
    When a client opens the thread or sends it a command
    Then the whole transcript is migrated before the thread is read or changed
    And migrating it again adds no message twice

  @mc @backlog
  Scenario: A transcript that fails to migrate does not stop the others
    Given the transcript of one version 1 thread cannot be migrated
    When the MC migrates transcripts in the background
    Then that thread records "Transcript hydration failed; retry on next open."
    And the other threads' transcripts are still migrated
    And the failed transcript is tried again when the thread is next opened

  @mc @backlog
  Scenario: Clients are told when the version 1 migration has finished
    Given the MC started on a database with 12 version 1 threads still to migrate
    Then clients are told a legacy thread migration of 12 threads is running
    And they are told it is complete once the last transcript is in
    And a start with nothing left to migrate announces no migration

  @mc @backlog
  Scenario Outline: A version 1 thread with unusable details is migrated with defaults
    Given a version 1 thread has <detail>
    When the thread is migrated
    Then it has <default>

    Examples:
      | detail                                    | default                              |
      | a blank title                             | the title "Untitled thread"          |
      | no model selection or one that is damaged | Codex with its default model         |
      | a permission mode the MC does not know    | full access                          |
      | an interaction mode other than plan       | the default interaction mode         |
      | a blank branch or worktree                | no branch or worktree                |
      | a damaged pull request link               | no linked pull request               |
      | damaged attachments on a message          | that message without attachments     |
      | a reply that was still streaming          | that reply marked interrupted        |
      | system or tool messages                   | only its user and assistant messages |

  @mc @backlog
  Scenario: A linked pull request of a version 1 thread joins its pull request list once
    Given a version 1 thread has a linked pull request that is also in its list of pull requests
    When the thread is migrated
    Then the pull request appears once in the thread's pull requests

  @mc @backlog
  Scenario: Threads migrated by an earlier version gain the details added since
    Given a version 1 thread was migrated before pins, snoozes and pull request lists were carried over
    When the MC starts
    Then the thread gains its pin, snooze, unsettle time, pull requests and place in the active order from the version 1 data
    And a detail the user has changed since the migration is left as it is

  @mc @backlog
  Scenario: A deleted version 1 thread stays deleted after migration
    Given a version 1 thread was deleted before the migration
    When the thread is migrated
    Then it is recorded as deleted and is not listed

  # Legacy: apps/server/src/persistence/Migrations/046_RepairAutomaticSettlementTimestamps.ts.
  # The Node server repaired only its projection, not the recorded events, so a snapshot
  # taken before that repair still carries the sweep time in its settle events.
  @backlog @mc
  Scenario: A thread the Node server settled automatically is imported settled at its last activity
    Given the snapshot settled "t1" automatically at a sweep time long after its last activity
    When the operator imports the snapshot into an MC
    Then "t1" is settled at the time of its last user message or turn activity
    And it is not settled at the sweep time

  # Legacy: apps/server/src/persistence/Migrations/044_ClearAutomaticProjectModelDefaults.ts
  @backlog @mc
  Scenario: A project default model the Node server chose by itself is not imported as the user's choice
    Given the snapshot holds a project whose default model was set only when it was created
    And the user never changed that default
    When the operator imports the snapshot into an MC
    Then the project has no default model
    But a project whose default model the user set keeps it

  # Legacy: apps/server/src/persistence/Migrations/024_BackfillProjectionThreadShellSummary.ts,
  # 025_CleanupInvalidProjectionPendingApprovals.ts
  @backlog @mc
  Scenario: An approval that can no longer be answered is not pending after the import
    Given the snapshot holds an approval request that was already answered or that the provider reported as stale
    And an approval answer with no request before it
    When the operator imports the snapshot into an MC
    Then the thread shows no pending approval for them
    And its needs-attention count agrees with the approvals it still shows

  @mc
  Scenario: A migrated version 1 thread hands its history to the next run
    Given a thread was migrated from the version 1 orchestrator
    When the user sends its first message after the migration
    Then the provider receives the imported conversation as context, keeping the newest messages that fit in 32,000 characters

  @mc
  Scenario: An older message that does not fit the handoff budget is shortened from its start
    Given a migrated version 1 thread whose newest messages already fill most of 32,000 characters
    When the user sends its first message after the migration
    Then the newest message that no longer fits whole keeps its end, cut at a word, and is marked as cut
    And messages older than that are left out

  # Legacy: apps/server/src/orchestration-v2/Orchestrator.ts (shouldPrepareLegacyImportHandoff)
  @backlog @mc
  Scenario: A migrated thread hands its history over again until a run completes
    Given a thread was migrated from the version 1 orchestrator
    And its first run after the migration failed before the agent answered
    When the user sends another message
    Then the provider receives the imported conversation as context again
    And once a run has completed, later messages no longer carry it
