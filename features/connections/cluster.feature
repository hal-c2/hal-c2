# Sources:
#   apps/server-ex/lib/hal_c2/cluster.ex (cluster CA, mutual TLS distribution, vm.args)
#   apps/server-ex/lib/hal_c2/cluster/tailscale.ex (discovery)
#   apps/server-ex/lib/mix/tasks/hal_c2.cluster.ex (init, invite, join, vm-args)
#   apps/server-ex/lib/hal_c2/shell.ex (cluster-wide sidebar, offline peers)
#   apps/server-ex/lib/hal_c2/environment.ex (descriptor cluster list)
#   apps/server-ex/lib/hal_c2/web/router.ex (/.well-known/hal-c2/environment, forwarded uploads)
#   apps/server-ex/lib/hal_c2/devices/proxy.ex (device hub of any node)
#   packages/client-runtime/src/v3/clusterSocket.ts (one socket per cluster)
#   packages/client-runtime/src/v3/clusterMembers.ts (registering members that join later)
#   packages/client-runtime/src/connection/compatibility.ts (descriptorServesEnvironment)

Feature: Clustering one person's machines
  Nodes on one person's machines form a cluster over mutually authenticated TLS. A client
  paired with any member reaches every member's environment through that one connection.

  @node
  Scenario: The first machine creates a cluster
    When the user creates a cluster on a machine with its tailnet address
    Then the machine has a cluster CA and its own certificate
    And it can boot clustered

  @node
  Scenario: Creating a cluster twice is refused
    Given the machine already has a cluster
    When the user creates a cluster again
    Then it is refused because the machine already has one

  @node
  Scenario: A member invites a new machine with a private bundle
    Given a cluster member that holds the CA key
    When the user invites a new machine by address
    Then a join bundle is written readable only by its owner
    And it contains the new machine's certificate and key

  @node
  Scenario: A new machine joins with its bundle
    Given a join bundle for this machine
    When the user joins with it
    Then the machine becomes a member named after its address

  @node
  Scenario: Asking for boot flags before joining is refused
    Given the machine is not in a cluster
    When the user asks for its cluster boot flags
    Then it is refused because the machine is not in a cluster yet

  @node
  Scenario: Members connect over mutual TLS without a port mapper
    Given two members of one cluster
    When both nodes start
    Then they connect over TLS on the cluster port
    And each listens only on its cluster address

  @node
  Scenario: A node from another cluster is turned away
    Given a node whose certificate was signed by a different cluster CA
    When it tries to connect to a member
    Then the TLS handshake fails
    And it never joins the cluster

  @node
  Scenario: Members find each other on the tailnet
    Given two members on the same tailnet
    When both are online
    Then each discovers the other within about ten seconds

  @node
  Scenario: Members can be listed statically
    Given HALC2_PEERS names a member's node
    When the node starts
    Then it connects to that member without tailnet discovery

  @node
  Scenario: The sidebar lists every member's projects and threads
    Given a client connected to one member of a two-machine cluster
    When it follows the shell
    Then it sees projects and threads from both machines
    And each row names the machine it lives on

  @node
  Scenario: A member going offline keeps its rows, marked offline
    Given a client follows the shell of a two-machine cluster
    When the other machine goes to sleep
    Then its threads stay listed
    And they are marked offline

  @node
  Scenario: A member coming back is marked online again
    Given a member's rows are marked offline
    When that member reconnects
    Then its rows are marked online

  @node
  Scenario: The environment descriptor lists the cluster
    When a client reads a member's environment descriptor
    Then it lists every member's environment id and label

  @node
  Scenario: A thread on another member streams through the connected node
    Given a client connected to the first member
    When it follows a thread that lives on the second member
    Then the thread streams over the client's one socket

  @node
  Scenario: A request for an offline member fails without closing the socket
    Given the second member is offline
    When a client asks for something only the second member can serve
    Then that request fails saying the node is unavailable
    And the socket stays up

  @node
  Scenario: An upload is forwarded to the node that issued its link
    Given an upload link issued by the second member
    When a client uploads to the first member with that link
    Then the first member forwards the upload to the second

  @node
  Scenario: An upload for a member that left fails
    Given an upload link issued by a member that is no longer connected
    When a client uploads with it
    Then the upload fails as a bad gateway

  @node
  Scenario: A device on another member streams through the connected node
    Given a simulator running on the second member
    When a client connected to the first member watches it
    Then the first member relays the stream from the second

  @backlog @shared
  Scenario: A member that joins later appears in the client without pairing again
    Given a client paired with a cluster of two machines
    When a third machine joins the cluster
    Then the client lists the third machine's environment within a minute
    And reaches it with the same credential

  @backlog @shared
  Scenario: A member that left stays until the user removes it
    Given a client lists a machine that has left the cluster
    Then the machine stays listed
    And the user can remove it like any environment

  @backlog @desktop
  Scenario: A user creates and joins a cluster from settings
    When the user invites another machine from settings
    Then the app hands over the join bundle privately
    And the other machine joins without the command line

  @node
  Scenario: A member removed from the cluster can no longer connect
    Given a member whose certificate was revoked
    When it tries to connect
    Then the other members refuse it
