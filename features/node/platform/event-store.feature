# Sources:
#   apps/server-ex/lib/hal_c2/store.ex (event log, snapshots, compression, read-only readers)
#   apps/server-ex/lib/hal_c2/patch.ex (set, append, unset, delete, quiet)
#   apps/server-ex/lib/hal_c2/stream_state.ex (folded state, snapshot migration)
#   apps/server-ex/lib/hal_c2/streams/server.ex (snapshot every 500 events, sidebar debounce)
#   apps/server-ex/lib/hal_c2/shell.ex (cluster-wide sidebar rows)
#   apps/server-ex/lib/hal_c2/search.ex (message index backfill)
#   apps/server-ex/lib/hal_c2/projection.ex
#   apps/server/src/persistence/Migrations (TypeScript migrations, replaced by the node's store)
#   docs/internals/overview.md (event sourcing)

Feature: The node's event store and projections
  Every change to a project or thread is an entity patch appended to one SQLite log.
  Folded stream state, sidebar rows and the search index are derived from that log.

  Background:
    Given a running node with a project and a thread

  @node
  Scenario: Every change is appended with a node-wide offset
    When a thread changes twice
    Then both changes are in the log with increasing offsets
    And clients resume from those offsets

  @node
  Scenario: Streaming text stores only what was appended
    Given an assistant message is streaming
    When more text arrives for it
    Then the log records only the new text

  @node
  Scenario: An identical change is not written again
    When a thread entity is written with the same value it already has
    Then no event is added to the log

  @node
  Scenario: Visiting a thread does not count as activity
    Given a thread last active an hour ago
    When the user visits the thread
    Then the visit is recorded
    And the thread's last activity time does not move

  # Neither server deletes a queued message (cancel marks its run cancelled); stopping
  # a provider session is the node's entity delete.
  @node
  Scenario: Deleting an entity removes it from the folded state
    Given a thread with an attached provider session
    When the provider session is stopped
    Then the thread's state no longer contains it

  @node
  Scenario: Large patches are stored compressed
    When a command writes more than a kilobyte of output
    Then the patch is compressed in the store
    And reading it back gives the original output

  @node
  Scenario: A slow reader never blocks writes
    Given a client is reading a large thread history
    When the thread keeps changing
    Then the changes are appended without waiting for the reader

  @node
  Scenario: The node snapshots a stream every 500 events
    When a thread receives 500 more events
    Then the node writes a snapshot of its folded state

  @node
  Scenario: A lost snapshot is rebuilt from the log
    Given a thread's snapshot is missing
    When a client subscribes to the thread
    Then the node folds the log again
    And the client receives the same state

  @node
  Scenario: Snapshots from an older state format are migrated
    Given a thread's snapshot was written by an older node
    When the node loads the thread
    Then the snapshot is migrated to the current format

  @node
  Scenario: History survives a restart
    When the node restarts
    Then every project and thread is back with its full history

  @node
  Scenario: Sidebar rows are kept in the store
    When a thread's title changes
    Then its sidebar row is updated in the store
    And rows changing quickly are sent to clients at most every 250 milliseconds

  @node
  Scenario: Missing sidebar rows are rebuilt in the background
    Given threads written before the sidebar table existed
    When the node starts
    Then it rebuilds their rows without delaying startup

  @node
  Scenario: Messages written before the search index are indexed once
    Given threads written before the message index existed
    When the node starts
    Then their finished messages are indexed once
    And search finds them

  @node
  Scenario: The store records its schema version
    When a node opens its store
    Then the store carries the schema version it was written with

  @node
  Scenario: A store from a newer node is refused rather than misread
    Given a store written by a newer node schema
    When an older node opens it
    Then it refuses to start and names the version it found

  # The TypeScript server's numbered projection migrations. The node stores entity
  # patches, and its state format migrates snapshots in place instead.
  @dropped @node
  Scenario: The server runs numbered projection migrations on startup
    Given a database from an older server
    When the server starts
    Then it applies each pending migration in order
