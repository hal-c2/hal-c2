# Sources:
#   apps/server-ex/lib/hal_c2/cluster.ex (identity, members, joining, runtime TLS distribution)
#   apps/server-ex/lib/hal_c2/cluster/epmd.ex (member names to addresses, no port mapper)
#   apps/server-ex/lib/hal_c2/cluster/discovery.ex (reconnecting, strategies)
#   apps/server-ex/lib/hal_c2/cluster/tailscale.ex, cluster/static.ex (discovery strategies)
#   apps/server-ex/lib/hal_c2/cluster/command.ex, lib/mix/tasks/hal_c2.cluster.ex (status, invite, join, remove)
#   apps/server-ex/rel/env.sh.eex, mise-tasks/node/_default (boot flags)
#   apps/server-ex/lib/hal_c2/shell.ex (cluster-wide sidebar, offline peers)
#   apps/server-ex/lib/hal_c2/environment.ex (descriptor cluster list)
#   apps/server-ex/lib/hal_c2/web/router.ex (/api/cluster, /.well-known/hal-c2/environment, forwarded uploads)
#   apps/server-ex/lib/hal_c2/rpc.ex, packages/contracts/src/cluster.ts (cluster.status/invite/join/remove)
#   apps/tui/src/host/clusterState.ts, apps/tui/src/host/settingsState.ts (the terminal's cluster)
#   apps/server-ex/lib/hal_c2/devices/proxy.ex (device hub of any node)
#   packages/client-runtime/src/v3/clusterSocket.ts (one socket per cluster)
#   packages/client-runtime/src/v3/clusterMembers.ts (registering members that join later)
#   packages/client-runtime/src/connection/compatibility.ts (descriptorServesEnvironment)

Feature: Clustering one person's machines
  Nodes on one person's machines form a cluster. A machine joins with a pairing link from
  any member, over whatever network reaches it: a LAN, a tailnet, another VPN. Members pin
  each other's certificates and talk over mutually authenticated TLS, and a client paired
  with any member reaches every member's environment through that one connection. Nobody
  sets up node names, cookies, boot flags or certificates, and nothing restarts.

  @node
  Scenario: A node is ready to cluster without any setup
    When a node starts
    Then it has its own certificate, named after its environment
    And it listens for members over TLS on the cluster port without a port mapper
    And its cluster has only itself

  @node
  Scenario: A machine joins another with a pairing link
    Given two nodes that are not clustered
    When the user joins the second to the first with a pairing link from the first
    Then each lists the other as a member
    And they are connected without restarting
    And the command lists both machines as connected

  @node
  Scenario: Joining needs a link that grants access
    Given two nodes that are not clustered
    When the user joins the second with a standard pairing link from the first
    Then the join is refused because the link does not grant access:write
    And neither lists the other

  @node
  Scenario: A node started without cluster support refuses to join
    Given a node started without the cluster boot flags
    When the user joins it to another machine
    Then the join is refused saying the node was not started for clustering

  @node
  Scenario: A client joins its machine to another's cluster and removes it again
    Given two nodes that are not clustered
    When a client of the first asks it for a cluster invite
    And a client of the second joins it with that invite
    Then the client sees both machines connected
    When a client of the first removes the second
    Then the client sees the first alone again

  @node
  Scenario: Only a client that manages access sees or changes the cluster
    Given two nodes that are not clustered
    When a client paired with a standard link asks the first for a cluster invite
    Then the node refuses both, saying access is required

  @node
  Scenario: A machine that joins one member reaches every member
    Given a cluster of two members
    When a third machine joins through the second member
    Then all three are connected to each other

  @node
  Scenario: A node that is not a member is turned away
    Given a member of a cluster and a node that never joined it
    When the node tries to connect to the member
    Then the TLS handshake fails
    And it never joins the cluster

  @node
  Scenario: Members find each other again after restarting
    Given a cluster of two members
    When both restart
    Then they connect again at the addresses they reported

  @node
  Scenario Outline: A discovery strategy finds a member the others lost track of
    Given a cluster of two members whose recorded addresses are out of date
    And <strategy> lists the second member's address
    When the first member looks for its peers
    Then it connects to the second member within about ten seconds

    Examples:
      | strategy     |
      | the tailnet  |
      | HAL_C2_PEERS |

  @node
  Scenario: A member removed from the cluster can no longer connect
    Given a cluster of three members
    When the user removes the third member on the first
    Then no member admits the third any more
    And the first two stay connected

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

  @tui
  Scenario: Settings show this machine's cluster
    Given this machine is clustered with "studio", which is connected, and "laptop", which is offline
    When the user opens settings in the terminal client
    Then the cluster group lists "studio" as connected and "laptop" as offline

  @tui
  Scenario: A user invites a machine from the terminal
    When the user picks "Invite a machine to this cluster" in the command palette
    Then the node is asked for a cluster invite
    And the invite link is copied
    And settings show the invite link

  @tui
  Scenario: An invite only this machine can open says so
    Given the node listens only on loopback
    When the user picks "Invite a machine to this cluster" in the command palette
    Then the user is warned that only this machine can open the invite

  @tui
  Scenario: A user joins this machine to another's cluster with an invite
    When the user picks "Join another machine's cluster…" in the command palette
    And the user pastes the invite "http://studio:3773/pair#token=abc" and presses Enter
    Then the node is asked to join with "http://studio:3773/pair#token=abc"
    And the status line says "Joined the cluster."
    And settings list "studio" as connected

  @tui
  Scenario: A join the node refuses says why
    Given the node refuses joins saying "The pairing link cannot add machines to a cluster; make a cluster invite instead."
    When the user picks "Join another machine's cluster…" in the command palette
    And the user pastes the invite "http://studio:3773/pair#token=abc" and presses Enter
    Then the status line says "Join failed: The pairing link cannot add machines to a cluster; make a cluster invite instead."

  @tui
  Scenario: Esc leaves the join prompt without joining
    When the user picks "Join another machine's cluster…" in the command palette
    And the user presses "Esc"
    Then the prompt has the keys again
    And the node was not asked to join

  @tui
  Scenario: A user removes a member from the terminal
    Given this machine is clustered with "laptop", which is connected
    When the user picks "Remove laptop from the cluster" in the command palette
    Then the node is asked to remove "env-laptop"
    And the status line says "Removed laptop from the cluster."

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
  Scenario: A user adds a machine to the cluster from settings
    Given the app is paired with two machines that are not clustered
    When the user adds one to the other's cluster from settings
    Then the app asks the first for a pairing link that grants access and gives it to the second
    And the two machines join without the command line

  @backlog @node
  Scenario: Members on one network find each other without being told where
    Given a cluster of two members on one LAN whose addresses changed
    When both are online
    Then each finds the other by announcing itself on the LAN
