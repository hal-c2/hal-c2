# Sources:
#   docs/user/thread-sidebar.md (Link a pull request, agent-managed metadata)
#   apps/web/src/hooks/usePullRequestLinking.ts
#   apps/web/src/hooks/useSupportsMultiplePullRequests.ts
#   apps/web/src/components/ChatView.tsx (relinking to the branch's new pull request, the panel that follows it)
#   apps/web/src/components/chat/ThreadDetailsPrRow.tsx, ThreadDetailsPrRows.tsx (the next step, merge confirmation, Show N more)
#   packages/contracts/src/orchestrationV2.ts (thread.pull-request.link, thread.pull-request.unlink, thread.pull-request-link.sync, thread.pull-request.sync, thread.pull-request-synced)
#   apps/server-ex/lib/hal_c2/orchestration.ex (pull-request link, unlink, sync)
#   apps/server-ex/lib/hal_c2/pull_requests/discovery.ex

Feature: Linking pull requests to threads
  A thread follows the pull request for its branch on its own. The user or the agent can
  point it at a different pull request, or unlink one.

  Background:
    Given a connected environment with the thread "Cart totals" on the branch "feature/cart"

  @mc
  Scenario: A thread finds the pull request for its branch
    Given a pull request is opened for "feature/cart"
    When the environment looks for pull requests
    Then "Cart totals" is linked to that pull request
    And no client needs to be open for this to happen

  @mc
  Scenario: Archived threads are not linked to new pull requests
    Given "Cart totals" is archived
    When the environment finds a pull request for "feature/cart"
    Then "Cart totals" is not linked to it

  @mc
  Scenario: Linking a different pull request by hand keeps the branch pull request beside it
    Given "Cart totals" is linked to the pull request for "feature/cart"
    When the user links "Cart totals" to pull request 42
    Then "Cart totals" is linked to pull request 42 and the branch pull request

  @mc
  Scenario: Linking the same pull request twice changes nothing
    Given "Cart totals" is linked to pull request 42
    When the user links "Cart totals" to pull request 42 again
    Then "Cart totals" has one link to pull request 42

  @mc
  Scenario: Unlinking a pull request
    Given "Cart totals" is linked to pull request 42
    When the user unlinks pull request 42 from "Cart totals"
    Then "Cart totals" is no longer linked to pull request 42

  @mc
  Scenario: An unlinked layer of a stack stays unlinked
    Given "Cart totals" is linked to a stack of pull requests
    When the user unlinks one layer of the stack
    And the environment refreshes the stack
    Then that layer is not linked again

  @mc
  Scenario: A user can bring back a stack layer they unlinked
    Given the user unlinked a layer of the stack from "Cart totals"
    When the user links that layer again
    Then "Cart totals" is linked to that layer

  @mc
  Scenario: The agent links the pull request it opened
    Given the agent in "Cart totals" opened pull request 43
    When the agent links pull request 43 to its thread
    Then "Cart totals" is linked to pull request 43

  @desktop @mobile @backlog-mobile
  Scenario: Choosing a different pull request from a pull request link
    Given "Cart totals" shows a link to pull request 41
    When the user links pull request 41 to the thread from that link
    Then "Cart totals" is linked to pull request 41

  @desktop @mobile @backlog-mobile
  Scenario: Unlinking returns the thread to its branch pull request
    Given "Cart totals" was linked by hand to pull request 41
    When the user unlinks pull request 41 from the thread
    Then "Cart totals" shows the pull request for "feature/cart" again

  @mc
  Scenario: Settled threads keep their links
    Given "Cart totals" is settled and linked to pull request 42
    When a new pull request is opened for "feature/cart"
    Then "Cart totals" stays linked to pull request 42

  @desktop @mobile @backlog-mobile
  Scenario: An environment that cannot find pull requests says it needs an update
    Given the environment does not look for branch pull requests
    When the user looks at "Cart totals"
    Then the user is told to update the server to see branch pull requests

  @backlog @desktop
  Scenario Outline: A thread whose pull request is finished follows the new one opened for its branch
    Given "Cart totals" is linked to pull request 42, which was <ended>
    And pull request 57 is open for "feature/cart" and the folder is on "feature/cart"
    When the user opens "Cart totals"
    Then "Cart totals" becomes linked to pull request 57

    Examples:
      | ended  |
      | merged |
      | closed |

  @backlog @desktop
  Scenario: A finished pull request is kept while the folder is on another branch
    Given "Cart totals" is linked to pull request 42, which was merged
    And the folder is on "main", which has an open pull request of its own
    When the user opens "Cart totals"
    Then "Cart totals" stays linked to pull request 42

  @backlog @desktop
  Scenario: A side panel showing the finished pull request moves to the new one
    Given "Cart totals" is linked to the merged pull request 42 and the side panel shows it
    When "Cart totals" follows the new pull request 57 for its branch
    Then the side panel shows pull request 57
    But a side panel showing a different pull request is left on it

  @backlog @desktop
  Scenario: A thread that could not be moved to its new pull request says so
    Given "Cart totals" is linked to the merged pull request 42 and pull request 57 is open for its branch
    When the environment refuses to link pull request 57
    Then the user sees an "error" toast "Unable to update the thread pull request" with the reason
    And the link is tried again the next time the thread is opened

  @backlog @desktop
  Scenario Outline: The thread's pull request offers the one step that moves it toward merging
    Given "Cart totals" is linked to pull request 42, which is <state>
    When the user looks at the thread's pull request in its details
    Then <offer>

    Examples:
      | state                                              | offer                                                    |
      | open and in conflict with its base                 | it offers "Resolve", which resolves the conflicts in a new thread |
      | a draft the user may mark ready                    | it offers "Ready", which marks it ready for review       |
      | a draft the user may not mark ready                | it offers no step                                        |
      | open with failing checks                           | it offers "Fix", which fixes the failing checks in a new thread |
      | open with checks still running                     | it offers no step and shows the checks running           |
      | open, clean and passing, and the user may merge it | it offers "Merge"                                        |
      | open and passing on a host with no merge method the user may use | it offers no step                          |
      | merged                                             | it offers no step                                        |

  @backlog @desktop
  Scenario: Merging from the thread's details asks first and names the method
    Given "Cart totals" is linked to pull request 42, which may be merged by squash
    When the user chooses "Merge" for it in the thread's details
    Then the user is asked "Merge pull request?" and told it merges #42 using squash
    And nothing is merged unless the user confirms

  @backlog @desktop
  Scenario: A merge that was being confirmed is withdrawn when the pull request stops being mergeable
    Given the user is being asked whether to merge pull request 42 from the thread's details
    When the checks of pull request 42 start running again
    Then the question goes away
    And the user is asked again from the start once the checks pass

  @backlog @desktop
  Scenario: The thread's details show its current pull request and fold the rest away
    Given "Cart totals" is linked to pull requests 42, 43 and 44 and 42 is the one for its branch
    When the user looks at the thread's details
    Then only pull request 42 is listed and the user is offered "Show 2 more"
    When the user chooses "Show 2 more"
    Then pull requests 43 and 44 are listed too and the user is offered "Show less"

  @backlog @desktop
  Scenario: Pointing at the thread's pull request summarises it
    Given "Cart totals" is linked to the open pull request 42 "Fix cart totals" from "feature/cart" into "main"
    When the user rests the pointer on it in the thread's details
    Then the summary names its title, number, state, both branches, its checks and how many files and lines it changes
