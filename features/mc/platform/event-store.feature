# Sources:
#   apps/server-ex/lib/hal_c2/store.ex (event log, snapshots, compression, read-only readers, WAL checkpoints)
#   apps/server-ex/lib/hal_c2/patch.ex (set, append, unset, delete, quiet)
#   apps/server-ex/lib/hal_c2/stream_state.ex (folded state, snapshot migration)
#   apps/server-ex/lib/hal_c2/streams/server.ex (snapshot every 500 events, sidebar debounce)
#   apps/server-ex/lib/hal_c2/shell.ex (cluster-wide sidebar rows)
#   apps/server-ex/lib/hal_c2/search.ex (message index backfill)
#   apps/server-ex/lib/hal_c2/projection.ex
#   apps/server/src/persistence/Migrations (TypeScript migrations, replaced by the MC's store)
#   apps/server/src/orchestration-v2/ProjectionMaintenance.ts, ProjectionStore.ts (checking and
#     rebuilding projections, compacting the log)
#   docs/internals/overview.md (event sourcing)

Feature: The MC's event store and projections
  Every change to a project or thread is an entity patch appended to one SQLite log.
  Folded stream state, sidebar rows and the search index are derived from that log.

  Background:
    Given a running MC with a project and a thread

  @mc
  Scenario: Every change is appended with an MC-wide offset
    When a thread changes twice
    Then both changes are in the log with increasing offsets
    And clients resume from those offsets

  @mc
  Scenario: Streaming text stores only what was appended
    Given an assistant message is streaming
    When more text arrives for it
    Then the log records only the new text

  @mc
  Scenario: An identical change is not written again
    When a thread entity is written with the same value it already has
    Then no event is added to the log

  @mc
  Scenario: Visiting a thread does not count as activity
    Given a thread last active an hour ago
    When the user visits the thread
    Then the visit is recorded
    And the thread's last activity time does not move

  # Neither server deletes a queued message (cancel marks its run cancelled); stopping
  # a provider session is the MC's entity delete.
  @mc
  Scenario: Deleting an entity removes it from the folded state
    Given a thread with an attached provider session
    When the provider session is stopped
    Then the thread's state no longer contains it

  @mc
  Scenario: Large patches are stored compressed
    When a command writes more than a kilobyte of output
    Then the patch is compressed in the store
    And reading it back gives the original output

  @mc
  Scenario: A slow reader never blocks writes
    Given a client is reading a large thread history
    When the thread keeps changing
    Then the changes are appended without waiting for the reader

  # A thread's first use reads its history. Writes queue up on a slow disk, and a
  # thread that waited its turn behind them could not be created in time.
  @mc
  Scenario: A thread starts while the store's writer is busy
    Given the store's writer is busy
    When a thread is used for the first time
    Then it starts without waiting for the writer

  @mc
  Scenario: The MC snapshots a stream every 500 events
    When a thread receives 500 more events
    Then the MC writes a snapshot of its folded state

  @mc
  Scenario: A lost snapshot is rebuilt from the log
    Given a thread's snapshot is missing
    When a client subscribes to the thread
    Then the MC folds the log again
    And the client receives the same state

  @mc
  Scenario: Snapshots from an older state format are migrated
    Given a thread's snapshot was written by an older MC
    When the MC loads the thread
    Then the snapshot is migrated to the current format

  @mc
  Scenario: History survives a restart
    When the MC restarts
    Then every project and thread is back with its full history

  @mc
  Scenario: Sidebar rows are kept in the store
    When a thread's title changes
    Then its sidebar row is updated in the store
    And rows changing quickly are sent to clients at most every 250 milliseconds

  @mc
  Scenario: Missing sidebar rows are rebuilt in the background
    Given threads written before the sidebar table existed
    When the MC starts
    Then it rebuilds their rows without delaying startup

  @mc
  Scenario: Messages written before the search index are indexed once
    Given threads written before the message index existed
    When the MC starts
    Then their finished messages are indexed once
    And search finds them

  # A checkpoint syncs the database file, which can take seconds on a busy disk.
  @mc
  Scenario: The WAL is checkpointed beside the writer, not by it
    When a thread changes twice
    Then the store's writer never checkpoints the WAL itself
    And a checkpoint from its own connection copies the changes into the database
    And that connection closes when the store stops

  @mc
  Scenario: The store records its schema version
    When an MC opens its store
    Then the store carries the schema version it was written with

  @mc
  Scenario: A store from a newer MC is refused rather than misread
    Given a store written by a newer MC schema
    When an older MC opens it
    Then it refuses to start and names the version it found

  # The Node server builds these checks but nothing in it runs them yet; see the audit's
  # "Uncertain" list before implementing.
  @mc @backlog
  Scenario Outline: Checking the projections against the log reports what is wrong
    Given <fault>
    When the projections are checked against the log
    Then the check fails and names <report>

    Examples:
      | fault                                                       | report                                 |
      | a thread in the log has no projection                       | the missing thread                     |
      | a projection exists for a thread the log never created      | the unexpected thread                  |
      | a thread's stored projection can no longer be read          | the unreadable thread                  |
      | a fork's source thread can no longer be read                | the source and the fork as unreadable  |
      | the projections stopped at an earlier sequence than the log | the sequence they are at and the log's |
      | the projections were written by another projection format   | the format version it found            |

  @mc @backlog
  Scenario: Projections are rebuilt from the log
    Given the projections of the MC are damaged
    When the projections are rebuilt
    Then every thread, run, message and timeline item is derived again from the log
    And timeline items keep the order they first had
    And the check against the log passes

  @mc @backlog
  Scenario: Compacting the log removes only what a replay no longer needs
    Given a thread was renamed, pinned and visited many times and its messages streamed in many updates
    When the log is compacted
    Then only the newest state of the thread and of each message is kept
    And the thread's creation and every timeline item update stay in the log
    And rebuilding the projections gives the same threads as before

  @mc @backlog
  Scenario: Compacting the log reports what it removed and what can be reclaimed
    When the log is compacted
    Then it reports how many events and receipts it removed
    And how many bytes the store can now give back

  @mc @backlog
  Scenario: Compacting a long log does not hold up other work
    Given a log with many thousands of events
    When the log is compacted while clients send commands
    Then the commands are accepted between the batches of 500 events it works through

  # The TypeScript server's numbered projection migrations. The MC stores entity
  # patches, and its state format migrates snapshots in place instead.
  @dropped @mc
  Scenario: The server runs numbered projection migrations on startup
    Given a database from an older server
    When the server starts
    Then it applies each pending migration in order
