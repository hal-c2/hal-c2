# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   apps/server-ex/lib/hal_c2/web/protocol.ex (protocol 3 frames)
#   apps/server-ex/lib/hal_c2/web/socket.ex (subscriptions, buffering, resync, state migration)
#   apps/server-ex/lib/hal_c2/web/router.ex (/ws upgrade)
#   apps/server-ex/lib/hal_c2/streams/server.ex (handles, replay, what changed since, chunks, idle stop)
#   apps/server-ex/lib/hal_c2/streams/view.ex (the kinds and window a client holds)
#   apps/server-ex/lib/hal_c2/shell.ex (row versions)
#   apps/server-ex/test/hal_c2/scenarios_test.exs (all executable scenarios except access)
#   packages/client-runtime/src/v3/clusterSocket.ts (resubscribe from offset, resync)
#   packages/client-runtime/src/v3/session.ts (unserved methods fail as unsupported)
#   packages/client-runtime/src/connection/compatibility.ts (protocol negotiation)
#   packages/contracts/src/rpc.ts (server.upsertKeybinding, server.removeKeybinding)
#   apps/server/src/ws.ts (protocol refusal on /ws, bounded compatibility projection, debounced provider status, themes)
#   apps/server/src/rpcInitialItems.memory.test.ts (delivered history is released)
#   apps/server/src/serverLifecycleEvents.ts (latest welcome and ready replayed, sequence numbers)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.upsertKeybinding, hal-c2.removeKeybinding)
#   docs/user/updating.md (When versions don't match)
#   docs/internals/connection-runtime.md (transport health and data freshness)
#   apps/server/src/orchestration/LiveStreamBudget.ts (1,000 items / 8 MiB per subscription)
#   apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts, ThreadStream.ts (merging the
#     progress of a running tool call for live subscribers)

Feature: The protocol 3 WebSocket
  Clients speak one JSON protocol over one WebSocket per MC. They subscribe to shapes,
  receive a snapshot and then live changes, and call RPCs on any MC of the cluster.

  Background:
    Given a running MC
    And a paired client

  @mc
  Scenario: A new connection is greeted with the protocol version and MC name
    When the client opens a socket with a valid credential
    Then the first frame names protocol 3, the MC it reached and the environment it serves

  @mc
  Scenario: A socket without a credential is refused
    When a client opens a socket without a ticket or token
    Then the upgrade is refused as unauthorized

  @mc
  Scenario: A socket ticket works once
    Given the client minted a socket ticket
    When it opens a socket with that ticket twice
    Then the first socket opens
    And the second is refused

  @mc
  Scenario: A subscription starts with a snapshot and then goes live
    When the client subscribes to a thread from the beginning
    Then it receives the thread's snapshot in parts until done
    And then a frame saying the subscription is live
    And later changes arrive live as events

  @mc
  Scenario: A client resumes a thread from the offset it last saw
    Given the client saw a thread up to some offset and disconnected
    And fewer than 2000 events were written since
    When it subscribes again from that offset
    Then it receives only the events it missed

  @mc
  Scenario: A client too far behind is sent what changed instead of the log
    Given the client saw a thread up to some offset and disconnected
    And one note grew by more than 2000 events since
    When it subscribes again from that offset
    Then it receives that note once, whole
    And no snapshot

  @mc
  Scenario: A large catch-up arrives in parts that are safe to apply twice
    Given the client saw a thread up to some offset and disconnected
    And more was written since than one frame carries
    When it subscribes again from that offset
    Then it receives what it missed in several frames of whole entities
    And only the last of them moves its offset

  @mc
  Scenario: A client that kept a thread between connections resumes it by its handle
    Given the client saw a thread up to some offset and disconnected
    And fewer than 2000 events were written since
    When it subscribes again with that offset and the handle it was given
    Then it receives only the events it missed

  @mc
  Scenario: An offset kept from another log starts over
    Given the client saw a thread up to some offset and disconnected
    When it subscribes again with that offset and a handle this MC did not give
    Then it receives a fresh snapshot of the thread

  @mc
  Scenario: A client is sent only the kinds of entity it asks for
    Given a thread where the agent is writing a reply
    When the client subscribes to its turn items and the user's messages
    Then the snapshot holds the reply's turn item but neither its message nor its node
    And text added to the reply arrives once, for the turn item

  @mc
  Scenario: A client that falls far behind is told to resync
    Given the client subscribed to a busy thread
    When more than 8 MB of changes wait unsent for that subscription
    Then the MC sends a resync for that subscription
    And the client subscribes again from its last offset

  # Likely already implemented: apps/server-ex/lib/hal_c2/web/socket.ex
  @mc @backlog
  Scenario: A client that falls more than 1,000 changes behind is told to resync
    Given the client subscribed to a busy thread
    When more than 1,000 small changes wait unsent for that subscription
    Then the MC sends a resync for that subscription
    And the client subscribes again from its last offset

  # Likely already implemented: apps/server-ex/lib/hal_c2/web/socket.ex
  @mc @backlog
  Scenario: A long history replayed to a client that keeps up is not a resync
    Given the client subscribed from an offset far behind a thread with 5,000 changes since
    When the MC replays them and the client acknowledges each batch
    Then the client receives every change
    And the MC does not send a resync for that subscription

  @mc
  Scenario: Changes to one entity are merged while the client is busy
    Given the client subscribed to a thread
    When one message changes many times before the socket drains
    Then the client receives the merged change once

  @mc @backlog
  Scenario Outline: Rapid progress of one running tool call reaches a subscriber as its latest state
    Given the client subscribed to a thread where <tool> is running
    When that tool call reports progress many times within 50 milliseconds
    Then the client receives one update holding its latest state
    And two tool calls running side by side each keep their own update

    Examples:
      | tool                     |
      | a command                |
      | a file change            |
      | a file search            |
      | a web search             |
      | a provider-defined tool  |

  @mc @backlog
  Scenario: Merging tool progress never reorders or drops what follows
    Given the client subscribed to a thread where a command is running
    When the command reports progress and then finishes, and a message arrives right after
    Then the client receives the latest progress, then the finished command, then the message
    And nothing waits for the 50 milliseconds to pass once the command has finished

  @mc @backlog
  Scenario: Tool progress held for merging is bounded
    Given the client subscribed to a thread where many tool calls are running
    When 512 progress updates are waiting to be merged
    Then they are merged and sent at once, without waiting for the 50 milliseconds to pass

  @backlog @mc
  Scenario: Long-lived subscriptions do not keep what they already delivered in memory
    Given clients hold several subscriptions open
    When each has been sent its snapshot, its replay and its history
    Then the MC holds none of that delivered history while the subscriptions stay open

  @mc
  Scenario: A client subscribes to one stream once per socket
    Given the client subscribed to a thread
    When it subscribes to the same thread again on that socket
    Then only the second subscription fails as already subscribed

  @mc
  Scenario: A client stops following one thread and keeps the other
    Given the client follows two threads
    When it drops the first subscription
    And both threads change
    Then nothing more arrives for the first thread
    And the second thread keeps streaming

  @mc
  Scenario: Two clients on one MC share settings with optimistic writes
    Given two clients follow the MC's config
    When the first client writes settings at the version it read
    Then the second client sees the new settings
    And a write from the second client at the old version is refused as stale

  @mc
  Scenario: A keybinding change comes back as the whole rule list
    Given the client follows the MC's config
    When it adds a keybinding and then removes it
    Then each change arrives as the complete list of rules

  @mc
  Scenario Outline: A client calling the contract's keybinding method <method> is answered
    Given the client follows the MC's config
    When it calls <method>
    Then the MC answers with the complete list of rules

    Examples:
      | method                  |
      | server.upsertKeybinding |
      | server.removeKeybinding |

  @mc
  Scenario: The sidebar follows a thread through create, archive and unarchive
    Given the client follows the shell
    When it creates a thread, archives it and unarchives it
    Then the sidebar and the archived list follow each step

  @mc
  Scenario: Scheduled task changes push the whole list
    Given the client follows the MC's scheduled tasks
    When it adds a task, enables it and deletes it
    Then every change pushes the complete task list

  @mc
  Scenario: Methods the MC does not serve fail on their own
    When the client calls several methods the MC does not serve
    Then each call fails saying the method is not served by this MC yet
    And the socket stays open for other calls

  @mc
  Scenario Outline: Malformed client frames are answered with an error and the socket stays up
    When the client sends <frame>
    Then the MC answers with the error "<reason>"
    And the socket stays open

    Examples:
      | frame                                            | reason              |
      | text that is not JSON                            | invalid json        |
      | a frame of an unknown type                       | unknown message     |
      | a subscription to an unknown shape               | unknown shape       |
      | a subscription naming an unknown MC              | unknown MC          |
      | a stream subscription for an unknown environment | unknown environment |
      | an RPC for an unknown environment                | unknown environment |

  @mc
  Scenario: Names from the client never create new MC names
    When a client sends any MC name it likes
    Then the MC only accepts names of MCs already in its cluster

  @mc
  Scenario: A ping is answered with a pong
    When the client sends a ping
    Then the MC answers with a pong

  @mc
  Scenario: A slow RPC never blocks streaming
    Given the client follows a thread
    When it calls an RPC that takes a long time
    Then events for the thread keep arriving while the call runs

  @mc
  Scenario: An RPC runs on the MC that owns its environment
    Given a cluster of two MCs
    When a client connected to the first MC calls an RPC for an environment of the second
    Then the second MC runs it
    And the answer comes back over the client's one socket

  @mc
  Scenario: An RPC that runs for more than ten minutes times out
    When the client calls an RPC that never finishes
    Then it fails after ten minutes
    And the socket stays open

  @mc
  Scenario: A thread stream with no subscribers stops after five minutes
    Given nobody follows a thread for five minutes
    Then the MC stops its stream process
    And the next subscription starts it again from the store

  @mc
  Scenario: A write that reaches a stream as it stops still lands
    Given a thread's stream stops just after a writer found it
    When the writer commits to it
    Then the commit is acknowledged
    And the event is in the store

  @mc
  Scenario: Open sockets survive a hot upgrade
    Given the client follows the shell and a thread
    When the MC loads a new version in place
    Then the socket stays connected
    And its subscriptions keep streaming

  @mc
  Scenario: A client reconnecting after a drop resubscribes every shape
    Given the client followed the shell and two threads
    When its socket drops and it connects again
    Then it resubscribes each thread from its last offset
    And it takes the shell whole

  @mc
  Scenario: A client that kept the sidebar is sent only the rows that changed
    Given the client followed the shell and kept its rows with their version
    And one thread was renamed since
    When it follows the shell again with that version
    Then it receives that thread's row and no other

  @mc
  Scenario: A sidebar kept from another run of the MC is replaced
    Given the client followed the shell and kept its rows with their version
    When it follows the shell again with a version the MC never gave
    Then the MC sends every row and says they replace the client's

  @shared @backlog-mobile
  Scenario: A client refuses a server speaking an unknown protocol
    Given an environment whose descriptor declares an unsupported protocol
    When a client tries to connect
    Then it is blocked before opening a socket
    And it says which side to update

  @shared @backlog-mobile
  Scenario: A client skips an event type it does not know
    Given a connected client does not recognize an event type the MC publishes
    When the MC publishes an event of that type
    Then the client skips the event
    And it keeps its connection and processes the later events it knows

  @mc
  Scenario: A client with a newer protocol than the MC is refused with an update message
    Given a client speaking a protocol newer than the MC's
    When it opens a socket
    Then the MC refuses with a message naming the MC to update

  @backlog @mc
  Scenario Outline: A client that does not name a compatible protocol is refused with an update message
    When a client opens a socket <naming>
    Then the MC refuses the upgrade as incompatible before checking its credential
    And the message says to update the client to one that supports the MC's protocol
    And it names the protocol version the MC speaks

    Examples:
      | naming                      |
      | without any protocol version |
      | naming an older protocol    |

  @backlog @mc
  Scenario: A client that only knows the compatibility call gets a bounded transcript
    Given a thread with a very long history
    When an older client asks for the thread's whole projection in one call
    Then the MC answers with a bounded window of the thread's most recent rows
    And the call does not materialise the whole transcript

  @backlog @mc
  Scenario: Provider status changes reach a client in bursts, not one by one
    Given the client follows the MC's lifecycle stream
    When several providers change status within a moment
    Then the client receives one update that holds the latest statuses

  @backlog @mc
  Scenario: Environment themes are sent only to clients that ask for them
    Given one client that asked for environment themes and one that did not
    When a theme file on the MC changes
    Then only the client that asked receives the new themes

  @backlog @mc
  Scenario: A client that follows the lifecycle stream late still gets the latest welcome and ready
    Given the MC has announced welcome and ready more than once
    When a client starts following the MC's lifecycle stream
    Then it first receives the most recent of each kind in announcement order
    And later announcements follow with rising sequence numbers

  @mc
  Scenario: An MC revoking a session closes that session's open sockets
    Given a client session has an open socket
    When an administrator revokes that session
    Then the MC closes the socket
    And the client cannot reconnect with that session
