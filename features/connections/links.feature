# Sources:
#   apps/server-ex/lib/hal_c2/links.ex, apps/server-ex/lib/hal_c2/links/connection.ex
#   apps/server-ex/lib/mix/tasks/hal_c2.link.ex
#   apps/server-ex/lib/hal_c2/web/socket.ex (rpc and shapes by environment, shell links)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (terminal shapes by environment, shell.links)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.linkEnvironment, hal-c2.unlinkEnvironment, hal-c2.environmentLinks)
#   Shared domain: cluster.feature holds machines that join one cluster; pairing.feature holds
#   the pairing links a link is made from.

Feature: Linking a node to environments outside its cluster
  A node can pair with another node it is not clustered with and keep that link. Its
  clients then reach the linked environment through it, so a client that only talks to
  its own node still works with threads that run elsewhere.

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

  @backlog @shared
  Scenario: The user links the node from its connection settings
    Given the user has a pairing link from "beast"
    When the user adds it as a linked environment in the connection settings
    Then the connection settings list "beast" as linked and online
    And the user can remove the link there
