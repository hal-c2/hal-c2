# Sources:
#   docs/user/thread-sidebar.md (Link a pull request, agent-managed metadata)
#   apps/web/src/hooks/usePullRequestLinking.ts
#   apps/web/src/hooks/useSupportsMultiplePullRequests.ts
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
