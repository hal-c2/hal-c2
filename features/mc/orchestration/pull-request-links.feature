# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (thread.pull-request.link, thread.pull-request.unlink,
#     thread.pull-request-link.sync, thread.pull-request.sync, thread.pull-request-synced,
#     thread.metadata.update linkedPullRequest)
#   apps/server-ex/lib/hal_c2/orchestration.ex (pull request link fields)
#   apps/server-ex/lib/hal_c2/pull_requests.ex
#   apps/server/src/orchestration-v2/ (pull request projector)
Feature: Pull requests linked to a thread
  A thread can carry several pull requests: ones the user or an agent linked,
  the one discovered for its branch, and the layers of a native stack. The
  engine keeps these links; host state arrives through quiet syncs that do not
  count as activity.

  Background:
    Given an MC with a project "demo"
    And thread "t1" exists in "demo" on branch "feature/x"

  @mc
  Scenario: Linking a pull request adds it to the thread
    When a client links pull request 12 of "acme/app" on "github.com" to "t1"
    Then thread "t1" lists pull request "acme/app#12"
    And the thread's activity time moves to the link time

  @mc
  Scenario: Linking the same pull request twice changes nothing
    Given pull request "acme/app#12" is linked to "t1"
    When a client links pull request "acme/app#12" to "t1" again
    Then thread "t1" lists pull request "acme/app#12" once
    And no event is recorded

  @mc
  Scenario: A first manual link keeps the branch's pull request beside it
    Given the MC discovered pull request "acme/app#7" for the branch of "t1"
    And "t1" has no visible linked pull requests
    When the user links pull request "acme/app#12" to "t1"
    Then thread "t1" lists pull requests "acme/app#7" and "acme/app#12"

  @mc
  Scenario: Unlinking a pull request removes it
    Given pull request "acme/app#12" was linked to "t1" by the user
    When a client unlinks pull request "acme/app#12" from "t1"
    Then thread "t1" no longer lists "acme/app#12"

  @mc
  Scenario: Unlinking a pull request that is not linked changes nothing
    When a client unlinks pull request "acme/app#99" from "t1"
    Then no event is recorded

  @mc @backlog
  Scenario: A settled thread whose pull request merged is not an active pull request thread
    Given "t1" links pull request "acme/app#12" and settled after it merged
    When the MC refreshes pull request state
    Then "t1" is not listed among the threads with an active pull request

  @mc
  Scenario: Unlinking a stack layer leaves a tombstone so the sync does not add it back
    Given pull request "acme/app#13" is linked to "t1" as a layer of a native stack
    When a client unlinks pull request "acme/app#13" from "t1"
    Then thread "t1" does not show "acme/app#13"
    And a later stack sync does not link "acme/app#13" again

  @mc
  Scenario Outline: A user or agent can bring back an unlinked stack layer
    Given pull request "acme/app#13" was unlinked from the stack of "t1"
    When <who> links pull request "acme/app#13" to "t1"
    Then thread "t1" shows "acme/app#13" again

    Examples:
      | who       |
      | the user  |
      | an agent  |

  @mc
  Scenario: The legacy single link follows the visible links
    Given pull request "acme/app#12" is the thread's legacy linked pull request
    When a client unlinks pull request "acme/app#12" from "t1"
    Then thread "t1" has no legacy linked pull request

  @mc
  Scenario: A legacy metadata update replaces the previous single link
    Given pull request "acme/app#12" is linked to "t1" through metadata
    When a client updates the metadata of "t1" with linked pull request "acme/app#14"
    Then thread "t1" lists "acme/app#14"
    And thread "t1" no longer lists "acme/app#12"

  @mc
  Scenario: A host sync updates a link's state without counting as activity
    Given pull request "acme/app#12" is linked to "t1"
    When the MC syncs the host state of "acme/app#12" as merged
    Then the link shows state merged
    And the thread's activity time is unchanged

  @mc
  Scenario: A host sync for a pull request that is no longer linked changes nothing
    When the MC syncs the host state of "acme/app#99" for "t1"
    Then no event is recorded

  @mc
  Scenario: Branch discovery records the branch's pull request
    When the MC discovers pull request "acme/app#7" for the branch of "t1"
    Then thread "t1" records "acme/app#7" as its branch pull request

  @mc
  Scenario Outline: Branch discovery is refused when the thread changed first
    Given the MC started discovering the pull request for "t1"
    And <change> before discovery finished
    When the discovery result is applied
    Then the command fails with "Thread t1 changed before pull request discovery."

    Examples:
      | change                                      |
      | the thread's branch changed                  |
      | the thread's worktree changed                |
      | the project's workspace root changed         |
      | the thread's linked pull request changed     |

  @mc
  Scenario: Branch discovery is refused for an archived thread
    Given thread "t1" is archived
    When the MC applies a discovered pull request for "t1"
    Then the command fails with "Thread t1 is archived."
