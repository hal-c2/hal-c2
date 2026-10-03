# Sources:
#   apps/server-ex/lib/hal_c2/links.ex, apps/server-ex/lib/hal_c2/links/connection.ex,
#   apps/server-ex/lib/hal_c2/links/rows.ex (linked rows in the shell)
#   apps/server-ex/lib/mix/tasks/hal_c2.link.ex
#   apps/desktop-qt/src/native/ConnectionsController.cpp (linking from the desktop's Connections settings)
#   apps/desktop-qt/src/native/ShellStore.cpp (the desktop's shell with its links' rows)
#   apps/server-ex/lib/hal_c2/web/socket.ex (rpc and shapes by environment, shell links)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (routed shapes by environment, shell.links)
#   apps/server-ex/lib/hal_c2/links.ex route/1 (this MC, a cluster member, or a link)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.linkEnvironment, hal-c2.unlinkEnvironment, hal-c2.environmentLinks)
#   Shared domain: cluster.feature holds machines that join one cluster; pairing.feature holds
#   the pairing links a link is made from.

Feature: Linking an MC to environments outside its cluster
  An MC can pair with another MC it is not clustered with and keep that link. Its
  clients then reach the linked environment through it, so a client that only talks to
  its own MC still works with threads that run elsewhere. A link whose token the other
  environment stops accepting says so and waits to be paired again.

  Background:
    Given a running MC
    And another MC "beast" outside the MC's cluster

  @mc
  Scenario: The user links the MC from its command line
    When the user runs the link task with a pairing link from "beast"
    Then the MC lists "beast" as a linked environment that is online
    And the MC's clients see "beast" among its links

  @mc
  Scenario: A pairing link that was already used is refused
    Given a pairing link from "beast" that was already used
    When the user links the MC with it
    Then linking is refused because the pairing link is invalid or expired
    And the MC has no links

  @mc
  Scenario: A client runs a terminal on a linked environment through its MC
    Given the MC is linked to "beast"
    When a client of the MC attaches a terminal on "beast"
    And it types "echo linked" and a return in that terminal
    Then it receives "linked" from the terminal on "beast"

  @mc
  Scenario: A client follows a linked environment's terminals through its MC
    Given the MC is linked to "beast"
    And a client of the MC follows the terminals on "beast"
    When a client of the MC attaches a terminal on "beast"
    Then the client following them sees the new terminal

  @mc
  Scenario: A client follows a thread on a linked environment through its MC
    Given the MC is linked to "beast"
    And a thread that lives on "beast"
    When a client of the MC follows that thread by its environment
    Then it receives the thread's snapshot and goes live
    And a change to the thread on "beast" reaches the client

  @mc
  Scenario: A client resumes a linked environment's thread from the offset it last saw
    Given the MC is linked to "beast"
    And a thread that lives on "beast"
    And a client of the MC followed that thread by its environment and stopped
    And the thread on "beast" changed since
    When the client follows that thread again from the offset it last saw
    Then it receives only the change it missed, then goes live

  # Shapes and RPCs named by environment go where HalC2.Links.route/1 says: this MC, a
  # cluster member, or a link. Which shapes may be named so is recorded in
  # parity/protocol.feature.
  @mc
  Scenario: A client follows a linked environment's git status through its MC
    Given the MC is linked to "beast"
    And a git checkout on "beast"
    When a client of the MC follows the status of that checkout on "beast"
    Then it receives the checkout's status from "beast"
    And a change in that checkout on "beast" reaches the client

  @mc
  Scenario: A client runs a git action on a linked environment through its MC
    Given the MC is linked to "beast"
    And a git checkout on "beast" with a file that is not committed
    When a client of the MC commits it with a git action on "beast"
    Then the client sees the git action start and finish
    And the commit is in the checkout on "beast"

  @mc
  Scenario: A client follows a linked environment's config through its MC
    Given the MC is linked to "beast"
    When a client of the MC asks for the config of "beast"
    Then it receives the config of "beast" with its providers and editors

  # The desktop's clone toasts follow a clone started on a linked environment this way.
  @mc
  Scenario: A client follows a linked environment's project clones through its MC
    Given the MC is linked to "beast"
    And a client of the MC follows the project clones of "beast"
    When a client of the MC starts cloning a repository on "beast"
    Then the client is told of that clone by "beast"

  @mc
  Scenario Outline: A client calls <method> on a linked environment through its MC
    Given the MC is linked to "beast"
    And a git checkout on "beast"
    When a client of the MC calls <method> on that checkout on "beast"
    Then it receives <answer> from "beast"

    Examples:
      | method               | answer                    |
      | vcs.listRefs         | the checkout's branches   |
      | projects.listEntries | the checkout's files      |
      | projects.readFile    | the file's contents       |
      | projects.searchEntries | the files matching a query |

  # The desktop's right panel and thread menus reach a linked thread this way.
  @mc
  Scenario: A client changes and reads a thread on a linked environment through its MC
    Given the MC is linked to "beast"
    When a client of the MC creates a thread on "beast" and renames it
    Then the thread on "beast" has the new title
    And the client reads the thread's diff from "beast"
    And none of it ran on the MC

  # "beast-2" stands for a member of the cluster of "beast" that this test cannot run: it
  # is listed on "beast" and never answers, so "beast" saying that its MC is
  # unavailable shows that the request reached "beast" and was routed there.
  @mc
  Scenario: A client reaches another MC of a linked cluster through the link
    Given "beast" has a cluster member "beast-2"
    And the MC is linked to "beast"
    When a client of the MC calls "beast-2"
    Then "beast" answers that the MC of "beast-2" is unavailable
    And a client of the MC that follows the status of a checkout on "beast-2" is told the same

  @mc
  Scenario: A member that joins a linked cluster is reached once its shell lists it
    Given the MC is linked to "beast"
    And a client of the MC follows the shell with its links' rows
    When "beast" gains a cluster member "beast-2"
    And the client sees "beast-2" under the link to "beast"
    And a client of the MC calls "beast-2"
    Then "beast" answers that the MC of "beast-2" is unavailable

  @mc
  Scenario: A request for a linked environment that is down fails at once
    Given the MC is linked to "beast"
    When "beast" stops
    And the MC lists "beast" as a linked environment that is unreachable
    Then a client of the MC calling "beast" is told "beast" is unreachable
    And a client of the MC that follows the status of a checkout on "beast" is told "beast" is unreachable

  # The MC checks its own client's scopes, and the linked environment checks the link's.
  @mc
  Scenario: A link reaches only what its pairing grants on the other side
    Given the MC is linked to "beast" with only orchestration:read
    And a git checkout on "beast" with a file that is not committed
    When a client of the MC commits it with a git action on "beast"
    Then "beast" refuses the git action saying orchestration:operate is required

  # So a client can show what it may only view there as read-only.
  @mc
  Scenario: A link lists what its pairing grants on the other side
    Given the MC is linked to "beast" with only orchestration:read
    When a client of the MC asks for the shell
    Then its link to "beast" lists orchestration:read as its only scope

  @mc
  Scenario: A client needs the same scope for a linked environment as for its own MC
    Given the MC is linked to "beast"
    And a device paired with the MC with only orchestration:read
    When the device starts a git action on "beast"
    Then the MC refuses the device saying orchestration:operate is required

  @mc
  Scenario: A link survives the MC restarting
    Given the MC is linked to "beast"
    When the MC restarts
    Then the MC lists "beast" as a linked environment that is online

  @mc
  Scenario: A removed link no longer reaches the environment
    Given the MC is linked to "beast"
    When the user removes the link to "beast"
    Then the MC has no links
    And a client of the MC calling "beast" is told the environment is unknown

  # Lending: the desktop shell passed its page's saved environments to the MC, which held the
  # links only in memory. The shell pairs environments as MC links itself now, so nothing is
  # lent (desktop/native-terminal.feature).
  @dropped @mc
  Scenario: A client lends the MC the access it already has
    Given a client of the MC that already has access to "beast"
    When it lends that access to the MC
    Then the MC lists "beast" as a linked environment that is online
    And a client of the MC attaches a terminal on "beast"

  @dropped @mc
  Scenario: Lent access lasts only while the MC runs
    Given a client of the MC that already has access to "beast"
    And it lends that access to the MC
    When the MC restarts
    Then the MC has no links

  @dropped @mc
  Scenario: Taking lent access back leaves a paired link alone
    Given the MC is linked to "beast"
    And a client of the MC that already has access to "beast"
    When it lends that access to the MC
    And it takes that access back
    Then the MC lists "beast" as a linked environment that is online

  @dropped @mc
  Scenario: Taking lent access back removes the link
    Given a client of the MC that already has access to "beast"
    And it lends that access to the MC
    When it takes that access back
    Then the MC has no links

  @mc
  Scenario: A link whose token is no longer accepted waits to be paired again
    Given the MC is linked to "beast"
    When "beast" revokes every paired client
    Then the MC lists "beast" as a linked environment whose access is refused
    And a client of the MC calling "beast" is told to pair it again

  @mc
  Scenario: Pairing a refused link again brings it back online
    Given the MC is linked to "beast"
    And "beast" revokes every paired client
    And the MC lists "beast" as a linked environment whose access is refused
    When the MC is linked to "beast"
    Then the MC lists "beast" as a linked environment that is online

  @mc
  Scenario: A link to an environment that stops answering is reported unreachable
    Given the MC is linked to "beast"
    When "beast" stops
    Then the MC lists "beast" as a linked environment that is unreachable

  @shared @backlog-mobile
  Scenario: The user links the MC from its connection settings
    Given the user has a pairing link from "beast"
    When the user adds it as a linked environment in the connection settings
    Then the connection settings list "beast" as linked and online
    And the user can remove the link there

  # A client that asks for the shell with its links' rows ("links": true) gets each linked
  # environment's MCs and rows under its link, since a linked environment's MC names can
  # collide with the cluster's; nothing is merged into the cluster's own rows. The MC
  # follows a linked environment's shell only while some client asks for it.
  @mc @desktop
  Scenario: A client sees a linked environment's threads in its MC's shell
    Given the MC is linked to "beast"
    And a thread that lives on "beast"
    When a client of the MC asks for the shell with its links' rows
    Then the thread is listed under the link to "beast"
    And the MC of "beast" is listed online under its link
    And none of the rows of "beast" are among the cluster's own

  @mc @desktop
  Scenario: A change to a linked thread reaches the client as that row alone
    Given the MC is linked to "beast"
    And a thread that lives on "beast"
    And a client of the MC follows the shell with its links' rows
    When the thread on "beast" is renamed to "Renamed on beast"
    Then the client receives only that thread's new row under the link to "beast"

  @mc @desktop
  Scenario: A linked environment's threads stay listed as offline while it is unreachable
    Given the MC is linked to "beast"
    And a thread that lives on "beast"
    And a client of the MC follows the shell with its links' rows
    When "beast" becomes unreachable
    Then the client is told the MC of "beast" is offline under its link
    And a client of the MC that asks for the shell with its links' rows sees the thread under the link to "beast", offline

  @mc @desktop
  Scenario: Removing a link takes its threads out of the shell
    Given the MC is linked to "beast"
    And a thread that lives on "beast"
    And a client of the MC follows the shell with its links' rows
    When the user removes the link to "beast"
    Then the client's links no longer include "beast"
    And the MC no longer follows the shell of "beast"

  @mc
  Scenario: A client that does not ask for its links' rows gets the shell as before
    Given the MC is linked to "beast"
    And a thread that lives on "beast"
    When a client of the MC asks for the shell
    Then its links carry only their environment, origin, granted scopes and whether they are online
    And the MC does not follow the shell of "beast"

  @mc
  Scenario: The MC lets go of a linked environment's shell once no client asks for its rows
    Given the MC is linked to "beast"
    And a client of the MC follows the shell with its links' rows
    When the client stops following the shell
    Then the MC no longer follows the shell of "beast"
