# Sources:
#   https://github.com/pingdotgg/t3code/pull/24571
#   https://github.com/pingdotgg/t3code/pull/21122
#   https://github.com/pingdotgg/t3code/pull/20948
#   https://github.com/pingdotgg/t3code/pull/15937 (dropped)
#   https://github.com/pingdotgg/t3code/pull/15925 (dropped: the MC runs no numbered migrations)
#   https://github.com/pingdotgg/t3code/pull/19435
#   https://github.com/pingdotgg/t3code/pull/19436
#   apps/server-ex/lib/hal_c2/store.ex (event log, snapshots, compression, read-only readers, WAL checkpoints)
#   apps/server-ex/lib/hal_c2/patch.ex (set, append, unset, delete, quiet)
#   apps/server-ex/lib/hal_c2/stream_state.ex (folded state, snapshot migration, hot and cold)
#   apps/server-ex/lib/hal_c2/streams/server.ex (snapshot every 500 events, sidebar debounce,
#     calls that wait for the store however long it takes)
#   apps/server-ex/lib/hal_c2/orchestration/turn_watch.ex (a run whose runtime exits is abandoned)
#   hal-c2/hal-c2#644 (a slow disk abandoned running turns)
#   apps/server-ex/lib/hal_c2/shell.ex (cluster-wide sidebar rows)
#   apps/server-ex/lib/hal_c2/search.ex (message index backfill)
#   apps/server-ex/lib/hal_c2/projection.ex
#   apps/server-ex/lib/hal_c2/projection/check.ex (checking and rebuilding projections)
#   apps/server-ex/lib/hal_c2/store/compaction.ex, store/compactor.ex (compacting the log)
#   apps/server-ex/lib/hal_c2/doctor.ex (hal-c2-service doctor)
#   apps/server/src/persistence/Migrations (TypeScript migrations, replaced by the MC's store)
#   apps/server/src/orchestration-v2/ProjectionMaintenance.ts, ProjectionStore.ts (checking and
#     rebuilding projections, compacting the log)
#   docs/internals/overview.md (event sourcing)
#   https://github.com/pingdotgg/t3code/pull/27629
#   https://github.com/pingdotgg/t3code/pull/29806

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

  # Upstream #24571: a brief lock on the database failed an otherwise healthy run.
  @backlog @mc
  Scenario: A provider event write retries after a brief database lock
    Given a turn is running in the thread
    And another writer holds the database lock past its timeout once
    When the agent reports an event
    Then the event is stored on a later try and the turn goes on
    And a write that fails for any other reason fails at once

  # A write that waited a minute for a busy disk exited the runtime making it, and
  # the run was abandoned as one whose session had ended.
  @mc
  Scenario: A slow store slows a running turn instead of ending it
    Given a turn is running in the thread, about to answer
    And the store's writer is stalled
    When the agent answers and ends its turn
    Then the MC logs that the store is slow
    And the turn completes once the store catches up

  @mc
  Scenario: A turn can be stopped while the store is slow
    Given a turn is running in the thread
    And the store's writer is stalled
    When the user asks to stop the turn
    Then the MC logs that the store is slow
    And the turn is interrupted once the store catches up

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

  # Memory holds the hot part of a thread: every run, and the items and messages of
  # its latest and unfinished runs. Older runs' are read from disk when asked for.
  @mc
  Scenario: A long thread keeps its older runs on disk
    Given a thread has finished 8 runs of 3 items while memory holds 2
    Then the MC holds only the latest runs' items in memory
    When a client subscribes to the thread
    Then the client receives every entity of a fold of the log
    And the thread's older runs are read from disk after a restart

  # hal-c2.threadRows answers a page at a time, so a long thread's never builds whole.
  @mc
  Scenario: A client reads a long thread's entities a page at a time
    Given a thread has finished 8 runs of 3 items while memory holds 2
    When a client reads the thread's entities 5 at a time
    Then it took more than one page, each entity once in the order they were created

  # One from before paging asks without `after`, and would take a first page for all of it.
  @mc
  Scenario: A client from before paging still reads a long thread whole
    Given a thread has finished 8 runs of 3 items while memory holds 2
    And pages of 5 rows
    When a client from before paging reads the thread's entities
    Then it got each entity once in the order they were created, in one reply

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

  # Upstream #21122: opening a large database no longer reads every table for planner
  # statistics; an 11 GB copy opened in 50 to 66 ms instead of 108 s. The MC opens its
  # store with no ANALYZE or PRAGMA optimize, so it reads no statistics in and gathers none.
  @mc @priority-high
  Scenario: Opening a large store does not hold up startup
    Given a store with no table statistics
    When the MC starts
    Then it opens the store without reading through its tables
    And it accepts clients within a second of opening the store

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

  # T3 Code's #15937 has an older server skip event types a newer build wrote when a client
  # resumes past them. The MC's log holds patches, not typed events, and an older MC refuses
  # a newer store outright (above), so there is nothing to skip.
  # Upstream #15937: an older server skips event types a newer build wrote when a client resumes past them
  @dropped @mc
  Scenario: A thread resumes past an event a newer build wrote
    Given a thread's log holds an event of a type only a newer build knows
    When a client resumes the thread from before that event
    Then the event is skipped and the thread finishes syncing

  # The doctor runs these checks (below).
  @mc
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

  @mc @priority-high
  Scenario: Projections are rebuilt from the log
    Given the projections of the MC are damaged
    When the projections are rebuilt
    Then every thread, run, message and timeline item is derived again from the log
    And timeline items keep the order they first had
    And the check against the log passes

  # Upstream #19435: superseded history is compacted in the background
  # Upstream keeps the oldest event of each message as well as the newest
  # (pingdotgg/t3code#19435): a client adds a message where it first sees it. A pull
  # request link is a field of its thread here, compacted with the thread's other updates.
  @mc
  Scenario: Compacting the log removes only what a replay no longer needs
    Given a thread was renamed, pinned, linked to pull requests and visited many times and its messages streamed in many updates
    And the thread was deleted
    When the log is compacted
    Then of the thread's updates only its creation and its deletion are kept
    And the oldest and the newest update of each message are kept
    And its runs and every timeline item update stay in the log
    And rebuilding the projections gives the same threads as before

  # Upstream #19435: superseded history is compacted in the background
  @mc @priority-high
  Scenario: A visit does not compact away the rename that carries the thread's activity time
    Given a thread was renamed and then visited
    When the log is compacted
    Then the rename stays in the log
    And of the visits and marks as unread only the newest is kept

  # Upstream #19435: superseded history is compacted in the background
  @mc @priority-high
  Scenario: A client resuming from before a compaction ends in the same state
    Given a client last read the log at an offset before many messages were streamed
    And the log was compacted since
    When the client resumes from its offset
    Then it ends with the same threads and messages, in the same order, as a client that read every event

  # Upstream #19435: superseded history is compacted in the background
  @mc @priority-low
  Scenario: The log is compacted in the background
    When the MC has been running for one minute
    Then the log is compacted
    And it is compacted again every six hours after that
    And the space it frees is given back to the disk a little at a time while the MC runs

  # Upstream also counts the receipts it removed; the MC's log holds none.
  @mc @priority-low
  Scenario: Compacting the log reports what it removed and what can be reclaimed
    Given a message was streamed in many updates
    When the log is compacted
    Then it reports how many events it removed
    And how many bytes the store can now give back

  # Upstream #19435: superseded history is compacted in the background
  @mc
  Scenario: Compacting a long log does not hold up other work
    Given a log with many thousands of events
    When the log is compacted while clients send commands
    Then the commands are accepted between the batches of 50 events it works through

  # Upstream #29806: compaction removed only superseded events and an upstream log reached 12 GB,
  # so upstream now prunes every event its projections applied more than a day ago and dropped
  # checking and rebuilding projections from the log.
  # Dropped: the MC's log is its source of truth. Projections are rebuilt and checked from it
  # (the rebuild and doctor scenarios in this file) and a thread move ships its stream, so the
  # MC compacts superseded patches instead of pruning applied ones.
  @dropped @mc
  Scenario: Events the projections applied more than a day ago are pruned
    Given the projections applied a thread's events more than a day ago
    When the log is pruned
    Then those events are removed from the log
    But the thread's newest event and its creation are kept
    And at least the last day of events is kept

  # Upstream #29806: a client resuming from before what the log still holds loads a snapshot
  # instead of replaying only part of the history.
  @backlog @mc @priority-high
  Scenario: A client resuming from before what the log still holds loads a snapshot
    Given a client last read a thread at an offset the log no longer holds
    When the client resumes from its offset
    Then it receives a snapshot of the thread and follows on from there
    And it ends in the same state as a client that stayed connected

  # Upstream #19436: t3 doctor reclaims database space
  @mc @priority-low
  Scenario: The doctor command reclaims the space of a store that cannot shrink online
    Given a store created before it could give space back to the disk while running
    When the user runs the MC's doctor command with "--fix"
    Then the projections are checked, the log is compacted and the projections are checked again
    And the store is switched to give space back while running and is shrunk
    And it reports the store's size before and after and how many events it removed
    And a second run reports "Nothing to repair"

  # Upstream #19436: t3 doctor reclaims database space
  @mc
  Scenario Outline: The doctor command asks before it repairs
    Given a log with events no replay needs
    When the user runs the MC's doctor command <how>
    Then <outcome>

    Examples:
      | how                          | outcome                                                    |
      | in a terminal                | the user chooses the repairs, with the recommended ones chosen |
      | with "--dry-run"             | the repairs are listed and nothing changes                 |
      | with "--dry-run" and "--fix" | the repairs are listed and nothing changes                 |

  # Upstream #19436: t3 doctor reclaims database space
  @mc @priority-high
  Scenario: The doctor command does not repair a store that is open
    Given an MC or a client has the store open
    When the user runs the MC's doctor command with "--fix"
    Then it refuses and changes nothing

  # Upstream #19436: t3 doctor reclaims database space
  @mc @backlog @priority-low
  Scenario: The doctor command pauses this home's background service while it repairs
    Given the MC runs as a background service for this home
    When the user runs the MC's doctor command with "--fix"
    Then the service is stopped for the repair and started again afterwards, even when the repair fails
    And a service that was disabled is not enabled
    And services for other homes are left alone

  # Upstream #20948 lets t3 doctor delete, by opt-in, the database T3 Code kept for rolling
  # back to before 0.1.0. The MC keeps no second database: what HAL-C2 moved in from lives in
  # the old home, which HAL-C2 never changes.
  # Upstream #27629: on Windows deleting that database failed while doctor held it open.
  @dropped @mc
  Scenario: The doctor command offers to delete the database kept for rolling back
    Given a store kept beside the current one only for rolling back to an older version
    When the user runs the MC's doctor command
    Then it offers to delete that store, unchosen, warning that the older version would start empty

  # The TypeScript server's numbered projection migrations. The MC stores entity
  # patches, and its state format migrates snapshots in place instead.
  # Upstream #15925: a migration id clash stops startup with a clear error
  @dropped @mc
  Scenario: The server runs numbered projection migrations on startup
    Given a database from an older server
    When the server starts
    Then it applies each pending migration in order
