# Sources:
#   apps/server-ex/lib/t3/import/v2.ex (Node V2 orchestration_events import)
#   apps/server-ex/lib/mix/tasks/t3.import.ex (the manual import task)
#   apps/server/src/orchestration-v2/LegacyV1ThreadImporter.ts,
#     apps/server/src/serverRuntimeStartup.ts (legacyThreadMigration startup phase),
#     apps/server/src/orchestration-v2/ContextHandoffService.ts (legacy import summary)
#   apps/server/src/persistence/Migrations/054_OrchestrationV2.ts
#   V2 events replayed: thread.*, run.*, run-attempt.*, turn-item.updated, message.updated,
#     provider-session.attached, provider-session.updated, provider-session.detached,
#     provider-thread.updated, thread.visited, thread.marked-unread
Feature: Bringing history over from the Node server
  An operator can import a Node server's orchestration history into a node, so
  projects and threads carry over. The import only reads the source.

  Background:
    Given a snapshot of a Node server's database with V2 orchestration history

  @node
  Scenario: Importing a Node server's history
    When the operator imports the snapshot into a node
    Then every project and thread stream of the snapshot exists on the node
    And the operator is told how many streams, events and bytes went in and were kept

  @node
  Scenario: The source is never written
    When the operator imports the snapshot into a node
    Then the snapshot is opened read-only and is unchanged afterwards

  @node
  Scenario: Streaming text is stored as changes, not repeated copies
    Given the snapshot stored a streamed reply as 500 full copies of the growing message
    When the operator imports the snapshot into a node
    Then the node keeps only what changed between the copies
    And the imported message reads the same as in the Node server

  @node
  Scenario: An update that changes nothing is dropped
    Given the snapshot records the same thread state twice in a row
    When the operator imports the snapshot into a node
    Then only one change is kept for it

  @node
  Scenario: A provider session belongs to a thread only while attached
    Given the snapshot attaches a provider session to "t1", updates it, detaches it, then updates it again
    When the operator imports the snapshot into a node
    Then the update after detaching does not change "t1"

  @node
  Scenario: The latest provider thread becomes the thread's active one
    Given the snapshot updates provider thread "p2" of "t1" after "p1"
    When the operator imports the snapshot into a node
    Then "t1" has "p2" as its active provider thread

  @node
  Scenario: A provider thread queued for a future run does not become active
    Given the snapshot records a queued placeholder provider thread for "t1"
    When the operator imports the snapshot into a node
    Then "t1" keeps its previous active provider thread

  @node
  Scenario: Imported visits and unread marks do not reorder threads
    Given the snapshot records a visit to "t1" after its last activity
    When the operator imports the snapshot into a node
    Then the activity time of "t1" is its last real activity

  @node
  Scenario: Streams are imported one at a time
    Given the snapshot holds thousands of threads
    When the operator imports the snapshot into a node
    Then the node imports them in order of first activity, holding one thread in memory at a time

  @node
  Scenario: The import is started by the operator, not at startup
    Given a node starts next to a Node server's database
    Then nothing is imported until the operator runs the import

  @node @backlog
  Scenario: A version 1 database is migrated on startup
    Given the Node server's database holds threads from the version 1 orchestrator
    When the node starts on it
    Then the threads are migrated with their transcripts, pull request links and attachments
    And clients see migration progress with the number of threads while it runs

  @node @backlog
  Scenario: A migrated version 1 thread hands its history to the next run
    Given a thread was migrated from the version 1 orchestrator
    When the user sends its first message after the migration
    Then the provider receives the imported conversation as context, keeping the newest messages that fit in 32,000 characters

  @node @backlog
  Scenario: An older message that does not fit the handoff budget is shortened from its start
    Given a migrated version 1 thread whose newest messages already fill most of 32,000 characters
    When the user sends its first message after the migration
    Then the newest message that no longer fits whole keeps its end, cut at a word, and is marked as cut
    And messages older than that are left out
