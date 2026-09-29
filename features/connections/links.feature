# Sources:
#   apps/server-ex/lib/hal_c2/links.ex, apps/server-ex/lib/hal_c2/links/connection.ex,
#   apps/server-ex/lib/hal_c2/links/rows.ex (linked rows in the shell)
#   apps/server-ex/lib/mix/tasks/hal_c2.link.ex
#   apps/desktop-qt/src/native/ConnectionsController.cpp (linking from the desktop's Connections settings)
#   apps/desktop-qt/src/native/ShellStore.cpp (the desktop's shell with its links' rows)
#   apps/server-ex/lib/hal_c2/web/socket.ex (rpc and shapes by environment, shell links)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (stream and terminal shapes by environment, shell.links)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.linkEnvironment, hal-c2.unlinkEnvironment, hal-c2.environmentLinks)
#   Shared domain: cluster.feature holds machines that join one cluster; pairing.feature holds
#   the pairing links a link is made from.

Feature: Linking a node to environments outside its cluster
  A node can pair with another node it is not clustered with and keep that link. Its
  clients then reach the linked environment through it, so a client that only talks to
  its own node still works with threads that run elsewhere. A link whose token the other
  environment stops accepting says so and waits to be paired again.

  Background:
    Given a running node
    And another node "beast" outside the node's cluster

  @node
  Scenario: The user links the node from its command line
    When the user runs the link task with a pairing link from "beast"
    Then the node lists "beast" as a linked environment that is online
    And the node's clients see "beast" among its links

  @node
  Scenario: A pairing link that was already used is refused
    Given a pairing link from "beast" that was already used
    When the user links the node with it
    Then linking is refused because the pairing link is invalid or expired
    And the node has no links

  @node
  Scenario: A client runs a terminal on a linked environment through its node
    Given the node is linked to "beast"
    When a client of the node attaches a terminal on "beast"
    And it types "echo linked" and a return in that terminal
    Then it receives "linked" from the terminal on "beast"

  @node
  Scenario: A client follows a linked environment's terminals through its node
    Given the node is linked to "beast"
    And a client of the node follows the terminals on "beast"
    When a client of the node attaches a terminal on "beast"
    Then the client following them sees the new terminal

  @node
  Scenario: A client follows a thread on a linked environment through its node
    Given the node is linked to "beast"
    And a thread that lives on "beast"
    When a client of the node follows that thread by its environment
    Then it receives the thread's snapshot and goes live
    And a change to the thread on "beast" reaches the client

  @node
  Scenario: A client resumes a linked environment's thread from the offset it last saw
    Given the node is linked to "beast"
    And a thread that lives on "beast"
    And a client of the node followed that thread by its environment and stopped
    And the thread on "beast" changed since
    When the client follows that thread again from the offset it last saw
    Then it receives only the change it missed, then goes live

  @node
  Scenario: A link survives the node restarting
    Given the node is linked to "beast"
    When the node restarts
    Then the node lists "beast" as a linked environment that is online

  @node
  Scenario: A removed link no longer reaches the environment
    Given the node is linked to "beast"
    When the user removes the link to "beast"
    Then the node has no links
    And a client of the node calling "beast" is told the environment is unknown

  # Lending: the desktop shell passed its page's saved environments to the node, which held the
  # links only in memory. The shell pairs environments as node links itself now, so nothing is
  # lent (desktop/native-terminal.feature).
  @dropped @node
  Scenario: A client lends the node the access it already has
    Given a client of the node that already has access to "beast"
    When it lends that access to the node
    Then the node lists "beast" as a linked environment that is online
    And a client of the node attaches a terminal on "beast"

  @dropped @node
  Scenario: Lent access lasts only while the node runs
    Given a client of the node that already has access to "beast"
    And it lends that access to the node
    When the node restarts
    Then the node has no links

  @dropped @node
  Scenario: Taking lent access back leaves a paired link alone
    Given the node is linked to "beast"
    And a client of the node that already has access to "beast"
    When it lends that access to the node
    And it takes that access back
    Then the node lists "beast" as a linked environment that is online

  @dropped @node
  Scenario: Taking lent access back removes the link
    Given a client of the node that already has access to "beast"
    And it lends that access to the node
    When it takes that access back
    Then the node has no links

  @node
  Scenario: A link whose token is no longer accepted waits to be paired again
    Given the node is linked to "beast"
    When "beast" revokes every paired client
    Then the node lists "beast" as a linked environment whose access is refused
    And a client of the node calling "beast" is told to pair it again

  @node
  Scenario: Pairing a refused link again brings it back online
    Given the node is linked to "beast"
    And "beast" revokes every paired client
    And the node lists "beast" as a linked environment whose access is refused
    When the node is linked to "beast"
    Then the node lists "beast" as a linked environment that is online

  @node
  Scenario: A link to an environment that stops answering is reported unreachable
    Given the node is linked to "beast"
    When "beast" stops
    Then the node lists "beast" as a linked environment that is unreachable

  @shared @backlog-mobile @backlog-tui
  Scenario: The user links the node from its connection settings
    Given the user has a pairing link from "beast"
    When the user adds it as a linked environment in the connection settings
    Then the connection settings list "beast" as linked and online
    And the user can remove the link there

  # A client that asks for the shell with its links' rows ("links": true) gets each linked
  # environment's nodes and rows under its link, since a linked environment's node names can
  # collide with the cluster's; nothing is merged into the cluster's own rows. The node
  # follows a linked environment's shell only while some client asks for it.
  @node @desktop
  Scenario: A client sees a linked environment's threads in its node's shell
    Given the node is linked to "beast"
    And a thread that lives on "beast"
    When a client of the node asks for the shell with its links' rows
    Then the thread is listed under the link to "beast"
    And the node of "beast" is listed online under its link
    And none of the rows of "beast" are among the cluster's own

  @node @desktop
  Scenario: A change to a linked thread reaches the client as that row alone
    Given the node is linked to "beast"
    And a thread that lives on "beast"
    And a client of the node follows the shell with its links' rows
    When the thread on "beast" is renamed to "Renamed on beast"
    Then the client receives only that thread's new row under the link to "beast"

  @node @desktop
  Scenario: A linked environment's threads stay listed as offline while it is unreachable
    Given the node is linked to "beast"
    And a thread that lives on "beast"
    And a client of the node follows the shell with its links' rows
    When "beast" becomes unreachable
    Then the client is told the node of "beast" is offline under its link
    And a client of the node that asks for the shell with its links' rows sees the thread under the link to "beast", offline

  @node @desktop
  Scenario: Removing a link takes its threads out of the shell
    Given the node is linked to "beast"
    And a thread that lives on "beast"
    And a client of the node follows the shell with its links' rows
    When the user removes the link to "beast"
    Then the client's links no longer include "beast"
    And the node no longer follows the shell of "beast"

  @node
  Scenario: A client that does not ask for its links' rows gets the shell as before
    Given the node is linked to "beast"
    And a thread that lives on "beast"
    When a client of the node asks for the shell
    Then its links carry only their environment, origin and whether they are online
    And the node does not follow the shell of "beast"

  @node
  Scenario: The node lets go of a linked environment's shell once no client asks for its rows
    Given the node is linked to "beast"
    And a client of the node follows the shell with its links' rows
    When the client stops following the shell
    Then the node no longer follows the shell of "beast"
