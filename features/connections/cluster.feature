# Sources:
#   apps/server-ex/lib/hal_c2/cluster.ex (identity, members, joining, runtime TLS distribution)
#   apps/server-ex/lib/hal_c2/cluster/epmd.ex (member names to addresses, no port mapper)
#   apps/server-ex/lib/hal_c2/cluster/discovery.ex (reconnecting, strategies)
#   apps/server-ex/lib/hal_c2/cluster/tailscale.ex, cluster/static.ex (discovery strategies)
#   apps/server-ex/lib/hal_c2/tailscale_serve.ex (invites over Tailscale Serve)
#   apps/server-ex/lib/hal_c2/cluster/command.ex, lib/mix/tasks/hal_c2.cluster.ex (status, invite, join, remove)
#   apps/server-ex/rel/env.sh.eex, mise-tasks/mc/_default (boot flags)
#   apps/server-ex/lib/hal_c2/shell.ex (cluster-wide sidebar, offline peers)
#   apps/server-ex/lib/hal_c2/environment.ex (descriptor cluster list)
#   apps/server-ex/lib/hal_c2/web/router.ex (/api/cluster, /.well-known/hal-c2/environment, forwarded uploads)
#   apps/server-ex/lib/hal_c2/rpc.ex, packages/contracts/src/cluster.ts (cluster.status/invite/join/remove)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.createPairingLink), apps/server-ex/lib/hal_c2/web.ex (address/1:
#     the address an invite or a pairing link names)
#   apps/tui/src/host/clusterState.ts, apps/tui/src/host/settingsState.ts (the terminal's cluster)
#   apps/tui/src/clusterClient.ts (one list over the cluster's machines, a project keyed by its machine)
#   packages/client-runtime/src/v3/session.ts (mcMembers: the sidebar stream says when a machine comes or goes)
#   apps/desktop-qt/src/ClusterController.cpp, apps/desktop-qt/qml/HalC2/Bricks/ClusterSettings.qml (the desktop's cluster)
#   apps/server-ex/lib/hal_c2/devices/proxy.ex (device hub of any MC)
#   apps/server-ex/lib/hal_c2/web/protocol.ex, web/socket.ex (streams by MC or by environment)
#   packages/client-runtime/src/v3/clusterSocket.ts (one socket per cluster)
#   packages/client-runtime/src/v3/clusterMembers.ts (registering members that join later)
#   packages/client-runtime/src/connection/compatibility.ts (descriptorServesEnvironment)

Feature: Clustering one person's machines
  MCs on one person's machines form a cluster. A machine joins with an invite from
  any member, over whatever network reaches it: a LAN, a tailnet, another VPN. Members pin
  each other's certificates and talk over mutually authenticated TLS, and a client paired
  with any member reaches every member's environment through that one connection. Nobody
  sets up MC names, cookies, boot flags or certificates, and nothing restarts.

  @mc
  Scenario: An MC is ready to cluster without any setup
    When an MC starts
    Then it has its own certificate, named after its environment
    And it listens for members over TLS on the cluster port without a port mapper
    And its cluster has only itself

  @mc
  Scenario: A machine joins another with a pairing link
    Given two MCs that are not clustered
    When the user joins the second to the first with a pairing link from the first
    Then each lists the other as a member
    And they are connected without restarting
    And the command lists both machines as connected

  @mc
  Scenario: Joining needs a link that grants access
    Given two MCs that are not clustered
    When the user joins the second with a standard pairing link from the first that names the first's certificate
    Then the join is refused because the link does not grant access:write
    And neither lists the other

  @mc
  Scenario: An invite names the machine it is from
    Given two MCs that are not clustered
    When the first makes a cluster invite
    Then the invite carries the fingerprint of the first's certificate

  # Two MCs on one machine, such as an installed one and a development one, share its
  # tailnet name, and only one of them can have the default HTTPS port.
  @mc
  Scenario: An invite over Tailscale takes another port when another MC holds the default one
    Given two MCs that are not clustered
    And Tailscale serves the second at the machine's tailnet HTTPS name
    When the first makes a cluster invite over Tailscale
    Then the invite points at the tailnet name on the first's own port
    And the tailnet HTTPS name still reaches the second

  # A link that names no certificate gives the joining machine nothing to check the answer
  # against, so whoever answers it could name any machines as members.
  @mc
  Scenario: Only a cluster invite joins a cluster
    Given two MCs that are not clustered
    When the user joins the second with an admin pairing link from the first that names no certificate
    Then the join is refused because the link is not a cluster invite

  @mc
  Scenario: A machine that answers an invite in another's place is not trusted
    Given two MCs that are not clustered
    When the user joins the second with an invite from the first that names another certificate
    Then the join is refused because the machine that answered is not the one the invite is from
    And the second lists no other member

  @mc
  Scenario: A joining machine takes the other members from the cluster, not from the answer to its invite
    Given two MCs that are not clustered
    When the second joins with an invite from the first whose answer was changed on the way to add a machine
    Then the second connects to the first
    And the second does not list the added machine

  @mc
  Scenario: An MC started without cluster support refuses to join
    Given an MC started without the cluster boot flags
    When the user joins it to another machine
    Then the join is refused saying the MC was not started for clustering

  @mc
  Scenario: A client joins its machine to another's cluster and removes it again
    Given two MCs that are not clustered
    When a client of the first asks it for a cluster invite
    And a client of the second joins it with that invite
    Then the client sees both machines connected
    When a client of the first removes the second
    Then the client sees the first alone again

  @mc
  Scenario: Only a client that manages access sees or changes the cluster
    Given two MCs that are not clustered
    When a client paired with a standard link asks the first for a cluster invite
    Then the MC refuses both, saying access is required

  @mc
  Scenario: A machine that joins one member reaches every member
    Given a cluster of two members
    When a third machine joins through the second member
    Then all three are connected to each other

  @mc
  Scenario: An MC that is not a member is turned away
    Given a member of a cluster and an MC that never joined it
    When the MC tries to connect to the member
    Then the TLS handshake fails
    And it never joins the cluster

  @mc
  Scenario: Members find each other again after restarting
    Given a cluster of two members
    When both restart
    Then they connect again at the addresses they reported

  # Two MCs on one machine (the installed one and a developer's) cannot both have the
  # cluster port. An update restarts every member at once, so the one without it has
  # to come back where the others last reached it.
  @mc
  Scenario: Members that could not have the cluster port keep the ports they took
    Given a cluster of two members that found the cluster port taken
    When both restart
    Then they connect again on the ports they took

  # An update can move a member onto the cluster port (a release's own one, or one that
  # was taken before), where the others never recorded it. With no tailnet and no
  # HAL_C2_PEERS, the hosts they recorded are all they have to look at.
  @mc
  Scenario: Members that move to the cluster port are found at the hosts they had
    Given a cluster of two members that found the cluster port taken
    When the cluster port is free again and both restart
    Then they connect again on the cluster port

  @mc
  Scenario Outline: A discovery strategy finds a member the others lost track of
    Given a cluster of two members whose recorded addresses are out of date
    And <strategy> lists the second member's address
    When the first member looks for its peers
    Then it connects to the second member within about ten seconds

    Examples:
      | strategy     |
      | the tailnet  |
      | HAL_C2_PEERS |

  @mc
  Scenario: Members on different HAL-C2 versions do not connect
    Given a cluster of two members
    When the second restarts on another HAL-C2 version
    Then the second cannot connect to the first
    And the second lists the first as not connected, with the version the first runs

  @mc
  Scenario: Members connect again once they run the same version
    Given a cluster of two members
    And the second restarts on another HAL-C2 version
    When the first moves to that version in place
    Then the two are connected again

  @mc
  Scenario: A machine on another HAL-C2 version cannot join
    Given two MCs that are not clustered, the second on another HAL-C2 version
    When the user joins the second to the first with a pairing link from the first
    Then the join is refused because the machines run different versions
    And neither lists the other

  @mc
  Scenario: A member removed from the cluster can no longer connect
    Given a cluster of three members
    When the user removes the third member on the first
    Then no member admits the third any more
    And the first two stay connected

  @mc
  Scenario: A removed member's projects and threads leave the sidebar
    Given a cluster of three members
    And the first two list a project of the third
    When the user removes the third member on the first
    Then the first two no longer list the third or its project

  @mc
  Scenario: The sidebar lists every member's projects and threads
    Given a client connected to one member of a two-machine cluster
    When it follows the shell
    Then it sees projects and threads from both machines
    And each row names the machine it lives on

  @mc
  Scenario: A member going offline keeps its rows, marked offline
    Given a client follows the shell of a two-machine cluster
    When the other machine goes to sleep
    Then its threads stay listed
    And they are marked offline

  @mc
  Scenario: A member coming back is marked online again
    Given a member's rows are marked offline
    When that member reconnects
    Then its rows are marked online

  @mc
  Scenario: The environment descriptor lists the cluster
    When a client reads a member's environment descriptor
    Then it lists every member's environment id and label

  @mc
  Scenario: A thread on another member streams through the connected MC
    Given a client connected to the first member
    When it follows a thread that lives on the second member
    Then the thread streams over the client's one socket

  @mc
  Scenario: A client follows a thread on another member by its environment
    Given a client connected to the first member
    When it follows a thread that lives on the second member by that member's environment
    Then the thread streams over the client's one socket

  # A phone paired with the laptop its user sits at stops working when the laptop sleeps;
  # the laptop's client asks the server of the cluster for the link instead.
  @mc
  Scenario: A client connected to one member gets a pairing link for another
    Given a client that manages access is connected to the first member
    And Tailscale names the second member's machine "garden-box.tail5e3a.ts.net"
    When it asks the second member for a pairing link over Tailscale
    Then Tailscale serves the second member over HTTPS at "garden-box.tail5e3a.ts.net"
    And the link comes with the second member's tailnet address
    And the link pairs a device with the second member, not the first

  @mc
  Scenario: A request for an offline member fails without closing the socket
    Given the second member is offline
    When a client asks for something only the second member can serve
    Then that request fails saying the MC is unavailable
    And the socket stays up

  @mc
  Scenario: An upload is forwarded to the MC that issued its link
    Given an upload link issued by the second member
    When a client uploads to the first member with that link
    Then the first member forwards the upload to the second

  @mc
  Scenario: An upload for a member that left fails
    Given an upload link issued by a member that is no longer connected
    When a client uploads with it
    Then the upload fails as a bad gateway

  @mc
  Scenario: A device on another member streams through the connected MC
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
    Then the MC is asked for a cluster invite
    And the invite link is copied
    And settings show the invite link

  @tui
  Scenario: An invite only this machine can open says so
    Given the MC listens only on loopback
    When the user picks "Invite a machine to this cluster" in the command palette
    Then the user is warned that only this machine can open the invite

  @tui
  Scenario: A user joins this machine to another's cluster with an invite
    When the user picks "Join another machine's cluster…" in the command palette
    And the user pastes the invite "http://studio:3773/pair#token=abc" and presses Enter
    Then the MC is asked to join with "http://studio:3773/pair#token=abc"
    And the status line says "Joined the cluster."
    And settings list "studio" as connected

  @tui
  Scenario: A join the MC refuses says why
    Given the MC refuses joins saying "The pairing link cannot add machines to a cluster; make a cluster invite instead."
    When the user picks "Join another machine's cluster…" in the command palette
    And the user pastes the invite "http://studio:3773/pair#token=abc" and presses Enter
    Then the status line says "Join failed: The pairing link cannot add machines to a cluster; make a cluster invite instead."

  @tui
  Scenario: Esc leaves the join prompt without joining
    When the user picks "Join another machine's cluster…" in the command palette
    And the user presses "Esc"
    Then the prompt has the keys again
    And the MC was not asked to join

  @tui
  Scenario: A user removes a member from the terminal
    Given this machine is clustered with "laptop", which is connected
    When the user picks "Remove laptop from the cluster" in the command palette
    Then the MC is asked to remove "env-laptop"
    And the status line says "Removed laptop from the cluster."

  @tui
  Scenario: A cluster read that lands after a removal does not bring the member back in the terminal
    Given this machine is clustered with "laptop", which is connected
    And the terminal has read the cluster
    And the MC is slow to read its cluster
    When the user picks "Remove laptop from the cluster" in the command palette
    And the MC answers
    Then the terminal's cluster no longer lists "laptop"

  # The MC says on the sidebar's stream when a machine comes or goes, so the terminal reads
  # the cluster again then, not only when it reconnects or settings open.
  @tui
  Scenario: A machine that joins while the terminal is open is followed without asking
    Given this machine is clustered with "laptop", which is connected
    And the terminal has read the cluster
    When "studio" joins the cluster
    Then the terminal's cluster lists "studio" as connected

  # A project's id is its machine's own: machines set up from one copy of the data share them.
  @tui
  Scenario: Projects that share an id on two machines stay separate in the terminal
    Given this machine and "studio" of its cluster each have a project with the id "p1"
    When the terminal follows the cluster's projects
    Then the project is listed once for each machine
    And a thread started in the project on "studio" is started on "studio"
    And a thread started in the project on "This machine" is started on "This machine"

  # The terminal follows each connected machine with a client of its own, so the rows of a
  # machine it has not reached since it started are missing, and those of one that went
  # offline since are listed as if it were there. The MC's sidebar carries both (shell.ex).
  @backlog @tui
  Scenario: Threads on an offline machine are listed as unavailable in the terminal
    Given this machine is clustered with "laptop", which is offline
    When the terminal starts
    Then the threads on "laptop" are listed as unavailable
    And actions that need "laptop" are unavailable

  @desktop
  Scenario: The desktop's settings show this machine's cluster
    Given this machine is clustered with "studio", which is connected, and "laptop", which is offline
    And the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    Then the MC is asked for its cluster status
    And the cluster page lists "studio" as connected and "laptop" as offline

  @desktop
  Scenario: A user invites a machine from the desktop
    Given the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the user makes a cluster invite
    Then the MC is asked for a cluster invite
    And the invite link is copied
    And the cluster page shows the invite link

  @desktop
  Scenario: The desktop says when only this machine can open an invite
    Given the MC listens only on loopback
    And the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the user makes a cluster invite
    Then the user is warned that only this machine can open the invite

  @desktop
  Scenario: A user joins the desktop's machine to another's cluster with an invite
    Given the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the user joins with "http://studio:3773/pair#token=abc"
    Then the MC is asked to join with "http://studio:3773/pair#token=abc"
    And the cluster page says "Joined the cluster."
    And the cluster page lists "studio" as connected

  @desktop
  Scenario: A join the MC refuses says why on the desktop
    Given the MC refuses joins saying "The pairing link cannot add machines to a cluster; make a cluster invite instead."
    And the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the user joins with "http://studio:3773/pair#token=abc"
    Then the cluster page says "Join failed: The pairing link cannot add machines to a cluster; make a cluster invite instead."

  @desktop
  Scenario: A user removes a member from the desktop
    Given this machine is clustered with "laptop", which is connected
    And the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the user removes "laptop" from the cluster
    Then the MC is asked to remove "env-laptop"
    And the cluster page says "Removed laptop from the cluster."

  @desktop
  Scenario: A cluster read that lands after a removal does not bring the member back
    Given this machine is clustered with "laptop", which is connected
    And the desktop shell is connected to its MC
    And the MC is slow to read its cluster
    When the user opens Cluster in the desktop's settings
    And the user removes "laptop" from the cluster
    And the MC answers
    Then the cluster page does not list "laptop"

  @desktop
  Scenario: A cluster the MC can no longer read is not shown as it was
    Given this machine is clustered with "laptop", which is connected
    And the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the MC can no longer read its cluster, saying "The MC is shutting down."
    And the user goes back from settings
    And the user opens Cluster in the desktop's settings
    Then the cluster page shows the error "The MC is shutting down." instead of the machines

  @desktop
  Scenario: Back leaves the desktop's cluster page
    Given the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the user goes back from settings
    Then the cluster page closes

  @desktop
  Scenario: Another settings section takes the cluster page's place
    Given the desktop shell is connected to its MC
    When the user opens Cluster in the desktop's settings
    And the user picks the settings section "/settings/general"
    Then the cluster page closes
    And the window shows the settings section "/settings/general"

  @shared @backlog-mobile
  Scenario: A member that joins later appears in the client without pairing again
    Given a client paired with a cluster of two machines
    When a third machine joins the cluster
    Then the client lists the third machine's environment within a minute
    And reaches it with the same credential

  @shared @backlog-mobile
  Scenario: A member that left stays until the user removes it
    Given a client lists a machine that has left the cluster
    Then the machine stays listed
    And the user can remove it like any environment

  # The desktop is paired with one MC, its own, so it has no second machine to hand an
  # invite to. A machine joins from its own Cluster page with an invite made on another
  # (the scenarios above), which needs no command line either.
  @dropped @desktop
  Scenario: A user adds a machine to the cluster from settings
    Given the app is paired with two machines that are not clustered
    When the user adds one to the other's cluster from settings
    Then the app asks the first for a pairing link that grants access and gives it to the second
    And the two machines join without the command line

  # Not built. Members on different versions do not connect at all, so updating one member
  # cuts it off from the rest until each of them is updated on the machine itself or by a
  # client paired with it; a client that reaches a member only through the cluster cannot
  # update it. That is acceptable while HAL-C2 has one user; it is not after that.
  @backlog @mc
  Scenario: Updating one member of a cluster updates the others
    Given a cluster of two members
    When the user updates the first to a new version
    Then the second moves to that version too
    And the two are connected on it

  @backlog @mc
  Scenario: A member that was away while the cluster moved to a new version is updated from another member
    Given a cluster of two members
    And the second was offline while the first moved to a new version
    When the second comes back
    Then the first gives it the new version over the cluster
    And the second moves to it and connects without anyone pairing with it

  @backlog @shared
  Scenario: A member on another version says so where the cluster is listed
    Given the cluster lists a member that last reported another HAL-C2 version
    When the user looks at the cluster in settings
    Then the member shows as not connected with the version it runs
    And the user is told both machines must run the same version to connect

  # The hardened join, not built. Today the invite's token and the joining machine's
  # description cross the network the way the link's origin carries them. Over HTTPS or a
  # tailnet nobody else reads or changes them. Over plain HTTP on a shared network, someone
  # on the path can take the token before it is used, or put their own machine's
  # certificate in the joining machine's place, and the inviter admits them. The invite's
  # fingerprint only protects the joining machine (the three scenarios on invites above).
  @backlog @mc
  Scenario: A join proves it holds the invite without sending the invite's secret
    Given a cluster invite from the first of two MCs that are not clustered
    When the second joins with it over a network someone else can read
    Then the invite's secret never crosses the network
    And the first admits the second because its request was made with that secret

  @backlog @mc
  Scenario: Someone who changes a join on the way cannot put their own machine in its place
    Given a cluster invite from the first of two MCs that are not clustered
    When the second joins with it and someone on the network swaps in their own certificate
    Then the first refuses the request because it no longer matches the invite's secret
    And the first admits nobody

  @backlog @mc
  Scenario: The inviter proves who it is before the joining machine describes itself
    Given a cluster invite from the first of two MCs that are not clustered
    When the second joins with it
    Then the second talks only to a machine holding the certificate the invite names
    And a machine answering in the first's place learns nothing about the second

  @backlog @mc
  Scenario: Members on one network find each other without being told where
    Given a cluster of two members on one LAN whose addresses changed
    When both are online
    Then each finds the other by announcing itself on the LAN
