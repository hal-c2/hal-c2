# Sources:
#   apps/server-ex/lib/hal_c2/web/protocol.ex (protocol 3 frames)
#   apps/server-ex/lib/hal_c2/web/socket.ex (subscriptions, buffering, resync, state migration)
#   apps/server-ex/lib/hal_c2/web/router.ex (/ws upgrade)
#   apps/server-ex/lib/hal_c2/streams/server.ex (replay window, snapshot chunks, idle stop)
#   apps/server-ex/test/hal_c2/scenarios_test.exs (all executable scenarios except access)
#   packages/client-runtime/src/v3/clusterSocket.ts (resubscribe from offset, resync)
#   packages/client-runtime/src/v3/session.ts (unserved methods fail as unsupported)
#   packages/client-runtime/src/connection/compatibility.ts (protocol negotiation)
#   packages/contracts/src/rpc.ts (server.upsertKeybinding, server.removeKeybinding)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.upsertKeybinding, hal-c2.removeKeybinding)
#   docs/user/updating.md (When versions don't match)
#   docs/internals/connection-runtime.md (transport health and data freshness)

Feature: The protocol 3 WebSocket
  Clients speak one JSON protocol over one WebSocket per node. They subscribe to shapes,
  receive a snapshot and then live changes, and call RPCs on any node of the cluster.

  Background:
    Given a running node
    And a paired client

  @node
  Scenario: A new connection is greeted with the protocol version and node name
    When the client opens a socket with a valid credential
    Then the first frame names protocol 3 and the node it reached

  @node
  Scenario: A socket without a credential is refused
    When a client opens a socket without a ticket or token
    Then the upgrade is refused as unauthorized

  @node
  Scenario: A socket ticket works once
    Given the client minted a socket ticket
    When it opens a socket with that ticket twice
    Then the first socket opens
    And the second is refused

  @node
  Scenario: A subscription starts with a snapshot and then goes live
    When the client subscribes to a thread from the beginning
    Then it receives the thread's snapshot in parts until done
    And then a frame saying the subscription is live
    And later changes arrive live as events

  @node
  Scenario: A client resumes a thread from the offset it last saw
    Given the client saw a thread up to some offset and disconnected
    And fewer than 2000 events were written since
    When it subscribes again from that offset
    Then it receives only the events it missed

  @node
  Scenario: A client too far behind gets a snapshot instead of a replay
    Given the client saw a thread up to some offset and disconnected
    And more than 2000 events were written since
    When it subscribes again from that offset
    Then it receives a fresh snapshot of the thread

  @node
  Scenario: A client that falls far behind is told to resync
    Given the client subscribed to a busy thread
    When more than 8 MB of changes wait unsent for that subscription
    Then the node sends a resync for that subscription
    And the client subscribes again from its last offset

  @node
  Scenario: Changes to one entity are merged while the client is busy
    Given the client subscribed to a thread
    When one message changes many times before the socket drains
    Then the client receives the merged change once

  @node
  Scenario: A client subscribes to one stream once per socket
    Given the client subscribed to a thread
    When it subscribes to the same thread again on that socket
    Then only the second subscription fails as already subscribed

  @node
  Scenario: A client stops following one thread and keeps the other
    Given the client follows two threads
    When it drops the first subscription
    And both threads change
    Then nothing more arrives for the first thread
    And the second thread keeps streaming

  @node
  Scenario: Two clients on one node share settings with optimistic writes
    Given two clients follow the node's config
    When the first client writes settings at the version it read
    Then the second client sees the new settings
    And a write from the second client at the old version is refused as stale

  @node
  Scenario: A keybinding change comes back as the whole rule list
    Given the client follows the node's config
    When it adds a keybinding and then removes it
    Then each change arrives as the complete list of rules

  @node
  Scenario Outline: A client calling the contract's keybinding method <method> is answered
    Given the client follows the node's config
    When it calls <method>
    Then the node answers with the complete list of rules

    Examples:
      | method                  |
      | server.upsertKeybinding |
      | server.removeKeybinding |

  @node
  Scenario: The sidebar follows a thread through create, archive and unarchive
    Given the client follows the shell
    When it creates a thread, archives it and unarchives it
    Then the sidebar and the archived list follow each step

  @node
  Scenario: Scheduled task changes push the whole list
    Given the client follows the node's scheduled tasks
    When it adds a task, enables it and deletes it
    Then every change pushes the complete task list

  @node
  Scenario: Methods the node does not serve fail on their own
    When the client calls several methods the node does not serve
    Then each call fails saying the method is not served by this node yet
    And the socket stays open for other calls

  @node
  Scenario Outline: Malformed client frames are answered with an error and the socket stays up
    When the client sends <frame>
    Then the node answers with the error "<reason>"
    And the socket stays open

    Examples:
      | frame                                   | reason              |
      | text that is not JSON                   | invalid json        |
      | a frame of an unknown type              | unknown message     |
      | a subscription to an unknown shape      | unknown shape       |
      | a subscription naming an unknown node   | unknown node        |
      | an RPC for an unknown environment       | unknown environment |

  @node
  Scenario: Names from the client never create new node names
    When a client sends any node name it likes
    Then the node only accepts names of nodes already in its cluster

  @node
  Scenario: A ping is answered with a pong
    When the client sends a ping
    Then the node answers with a pong

  @node
  Scenario: A slow RPC never blocks streaming
    Given the client follows a thread
    When it calls an RPC that takes a long time
    Then events for the thread keep arriving while the call runs

  @node
  Scenario: An RPC runs on the node that owns its environment
    Given a cluster of two nodes
    When a client connected to the first node calls an RPC for an environment of the second
    Then the second node runs it
    And the answer comes back over the client's one socket

  @node
  Scenario: An RPC that runs for more than ten minutes times out
    When the client calls an RPC that never finishes
    Then it fails after ten minutes
    And the socket stays open

  @node
  Scenario: A thread stream with no subscribers stops after five minutes
    Given nobody follows a thread for five minutes
    Then the node stops its stream process
    And the next subscription starts it again from the store

  @node
  Scenario: Open sockets survive a hot upgrade
    Given the client follows the shell and a thread
    When the node loads a new version in place
    Then the socket stays connected
    And its subscriptions keep streaming

  @node
  Scenario: A client reconnecting after a drop resubscribes every shape
    Given the client followed the shell and two threads
    When its socket drops and it connects again
    Then it resubscribes each thread from its last offset
    And it takes the shell whole

  @backlog @shared
  Scenario: A client refuses a server speaking an unknown protocol
    Given an environment whose descriptor declares an unsupported protocol
    When a client tries to connect
    Then it is blocked before opening a socket
    And it says which side to update

  @node
  Scenario: A client with a newer protocol than the node is refused with an update message
    Given a client speaking a protocol newer than the node's
    When it opens a socket
    Then the node refuses with a message naming the node to update

  @node
  Scenario: A node revoking a session closes that session's open sockets
    Given a client session has an open socket
    When an administrator revokes that session
    Then the node closes the socket
    And the client cannot reconnect with that session
