# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   packages/contracts/src/orchestrationV2.ts (thread.pull-request.link, thread.pull-request.unlink,
#     thread.pull-request-link.sync, thread.pull-request.sync, thread.pull-request-synced,
#     thread.metadata.update linkedPullRequest)
#   apps/server-ex/lib/hal_c2/orchestration.ex (pull request link fields)
#   apps/server-ex/lib/hal_c2/pull_requests.ex
#   apps/server/src/orchestration-v2/ (pull request projector)
#   apps/server/src/orchestration-v2/ThreadPullRequestService.ts (branch discovery triggers, settled
#     threads, other repositories, missing worktrees, stale results)
#   apps/server/src/orchestration/PullRequestSyncReactor.ts (sweep cadence, stack auto-link)
#   apps/server/src/pullRequest/linkedThreads.ts (pullRequests.linkedThreads)
#   apps/server/src/pullRequest/pullRequestSyncKey.ts (checkout-scoped reference to host-level key)
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

  @mc
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

  @backlog @mc
  Scenario Outline: The MC looks for a branch's pull request when the thread changes
    When <trigger>
    Then the MC looks for the pull request of the branch of "t1"

    Examples:
      | trigger                                   |
      | "t1" is created                           |
      | "t1" is unarchived                        |
      | the branch or worktree of "t1" is changed |
      | the user un-settles "t1"                  |
      | a turn of "t1" ends                       |
      | a checkpoint of "t1" is captured          |
      | a minute passes                           |

  @backlog @mc
  Scenario: Threads on the same branch and worktree cost one branch look-up
    Given thread "t2" exists in "demo" on branch "feature/x" in the same worktree as "t1"
    When the MC looks for branch pull requests
    Then the host is asked about "feature/x" once
    And both "t1" and "t2" record the pull request it answered

  # Settled threads are otherwise left alone: threads/pull-request-links.feature.
  @backlog @mc
  Scenario: A settled thread with no branch pull request is looked up when the MC starts
    Given thread "t1" is settled and records no branch pull request
    And pull request "acme/app#7" exists for "feature/x"
    When the MC starts
    Then thread "t1" records "acme/app#7" as its branch pull request

  @backlog @mc
  Scenario: The start-up look-up for a settled thread gives up after five failures
    Given thread "t1" is settled and records no branch pull request
    And the host cannot be reached
    When the MC starts and five look-ups for "t1" have failed
    Then the MC no longer looks for the branch pull request of "t1" on its periodic sweep

  @backlog @mc
  Scenario: A pull request that belongs to another repository is not recorded
    Given the branch "feature/x" has a pull request in a repository that is not the one of "demo"
    When the MC looks for branch pull requests
    Then thread "t1" records no branch pull request

  @backlog @mc
  Scenario: A project that is not a recognised repository gets no branch look-up
    Given the folder of "demo" has no remote the MC recognises
    When the MC looks for branch pull requests
    Then the host is not asked about "feature/x"

  @backlog @mc
  Scenario: Discovery reads from the project folder when the worktree is gone
    Given thread "t1" is in a worktree that has been removed
    When the MC looks for branch pull requests
    Then the pull request of "feature/x" is looked up from the folder of "demo"

  # A thread in the project folder shares its checkout, so a branch that stops
  # showing a pull request there says nothing about work that already landed.
  @backlog @mc
  Scenario Outline: A branch that stops showing a pull request keeps only finished ones
    Given thread "t1" has no worktree of its own and records "acme/app#7" as its branch pull request
    And "acme/app#7" is <state>
    When the MC looks for branch pull requests and finds none for "feature/x"
    Then thread "t1" <outcome>

    Examples:
      | state  | outcome                                              |
      | merged | still records "acme/app#7" as its branch pull request |
      | closed | still records "acme/app#7" as its branch pull request |
      | open   | records no branch pull request                       |

  @backlog @mc
  Scenario: A thread in its own worktree drops the branch pull request once the branch shows none
    Given thread "t1" is in its own worktree and records the merged "acme/app#7" as its branch pull request
    When the MC looks for branch pull requests and finds none for "feature/x"
    Then thread "t1" records no branch pull request

  @backlog @mc
  Scenario: A finished legacy link gives way to the branch's new open pull request
    Given thread "t1" has only the legacy single link, to the merged "acme/app#7"
    And a new pull request "acme/app#9" is open for "feature/x"
    When the MC looks for branch pull requests
    Then the linked pull request of "t1" is "acme/app#9"

  @backlog @mc
  Scenario: An open legacy link is not replaced by the branch's pull request
    Given thread "t1" has only the legacy single link, to the open "acme/app#7"
    And a new pull request "acme/app#9" is open for "feature/x"
    When the MC looks for branch pull requests
    Then the linked pull request of "t1" is still "acme/app#7"

  @backlog @mc
  Scenario Outline: A discovery result that went stale during the look-up is thrown away
    Given the MC found "acme/app#7" for the branch of "t1"
    And <change> before the result was recorded
    When the look-up finishes
    Then thread "t1" records no branch pull request from that look-up

    Examples:
      | change                                       |
      | the branch came to show another pull request |
      | "acme/app#7" changed state                   |
      | the folder of "demo" was changed             |
      | project "demo" was deleted                   |

  @backlog @mc
  Scenario: One branch look-up that fails does not stop the others
    Given thread "t2" exists in "demo" on branch "feature/y" with pull request "acme/app#8"
    And the look-up for "feature/x" fails
    When the MC looks for branch pull requests
    Then thread "t2" records "acme/app#8" as its branch pull request

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario: Threads sharing a pull request cost one host read per sweep
    Given pull request "acme/app#12" is linked to "t1" and to "t2"
    When the sync sweep runs
    Then the host is asked about "acme/app#12" once
    And both "t1" and "t2" show the state it answered

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario: A pull request linked to a thread is read without waiting for the next sweep
    When a client links pull request "acme/app#12" to "t1"
    Then the MC reads "acme/app#12" from the host and records its state on "t1"

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario Outline: Closed and settled pull requests are read on a slow cadence
    Given pull request "acme/app#12" is linked to "t1" and its last read said <state>
    And "t1" is <thread>
    When the sync sweep runs <after> after the last read
    Then the host <asked> about "acme/app#12"

    Examples:
      | state  | thread    | after      | asked          |
      | open   | active    | a minute   | is asked       |
      | open   | settled   | a minute   | is not asked   |
      | open   | settled   | 15 minutes | is asked       |
      | closed | active    | a minute   | is not asked   |
      | closed | active    | 15 minutes | is asked       |

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario: A closed pull request that was reopened is noticed
    Given pull request "acme/app#12" is linked to "t1" and its last read said closed
    And "acme/app#12" was reopened on the host
    When the sync sweep runs 15 minutes after the last read
    Then thread "t1" shows "acme/app#12" as open

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario: Archived threads' pull requests are not read
    Given pull request "acme/app#12" is linked only to the archived thread "t1"
    When the sync sweep runs
    Then the host is not asked about "acme/app#12"

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario: A host that cannot be reached leaves the last known state in place
    Given pull request "acme/app#12" is linked to "t1" with the state "open"
    And the host cannot be reached
    When the sync sweep runs
    Then thread "t1" still shows "acme/app#12" as open
    And no event is recorded
    And the sweep goes on to the other linked pull requests

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario: A stack the host failed to report is asked for again on the next sweep
    Given pull request "acme/app#12" changed state on the host
    And the host answers the state of "acme/app#12" but fails to report its stack
    When the sync sweep runs
    Then thread "t1" has not recorded the new state
    When the host recovers and the sync sweep runs again
    Then thread "t1" shows the new state and the layers of the stack

  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/sync.ex
  @mc @backlog
  Scenario: A refresh asked for during a host read is not lost
    Given the MC is reading "acme/app#12" from the host
    When a client asks to refresh "acme/app#12"
    And the read in flight finishes
    Then the next sweep reads "acme/app#12" again, even if its last read was a minute ago

  @mc @backlog
  Scenario: Asking which threads are linked to a pull request lists live and archived ones
    Given pull request "acme/app#12" on "github.com" is linked to thread "t1"
    And pull request "acme/app#12" on "github.com" is linked to the archived thread "t2"
    And thread "t3" was deleted and still carries a link to "acme/app#12"
    When a client asks which threads are linked to "acme/app#12" on "github.com"
    Then "t1" and "t2" are listed
    And "t3" is not listed

  @mc @backlog
  Scenario: Linked threads are listed most recently updated first
    Given "t1" and "t2" are both linked to pull request "acme/app#12"
    And "t2" was updated more recently than "t1"
    When a client asks which threads are linked to "acme/app#12"
    Then "t2" comes before "t1"

  @mc @backlog
  Scenario Outline: A pull request is told apart from lookalikes in other places
    Given thread "t9" is linked to a pull request <other>
    When a client asks which threads are linked to pull request 12 of "acme/app" on "github.com"
    Then "t9" is not listed

    Examples:
      | other                                      |
      | numbered 13 in "acme/app" on "github.com"  |
      | numbered 12 in "acme/web" on "github.com"  |
      | numbered 12 in "acme/app" on "gitlab.com"  |
      | numbered 12 in "acme/app" on "forge.test:4000" |

  @mc @backlog
  Scenario: A stack layer the user dismissed from a thread does not make the thread linked
    Given pull request "acme/app#12" is a layer of the stack of "t1"
    And the user dismissed it from "t1"
    When a client asks which threads are linked to "acme/app#12"
    Then "t1" is not listed

  @mc @backlog
  Scenario: A thread that only has the legacy single link is still listed
    Given thread "t1" carries only the legacy single link to "acme/app#12"
    When a client asks which threads are linked to "acme/app#12" on "github.com"
    Then "t1" is listed

  @mc @backlog
  Scenario: Linked threads that cannot be read are reported
    Given the MC cannot read its thread records
    When a client asks which threads are linked to "acme/app#12"
    Then the request fails with "Could not load linked threads."

  @mc @backlog
  Scenario Outline: A reference tied to a checkout gets the host it belongs to
    Given the project's checkout is on <provider>
    When a client names pull request <number> of "<repository>" <host>
    Then the pull request is identified as number <number> of "<identified>" on "<identified host>"

    Examples:
      | provider     | number | repository | host                        | identified               | identified host |
      | GitHub       | 7      | acme/web   | without a host              | acme/web                 | github.com      |
      | GitHub       | 7      | acme/web   | on "gitlab.com"             | acme/web                 | gitlab.com      |
      | Azure DevOps | 7      | web        | without a host              | org/project/_git/web     | dev.azure.com   |

  @mc @backlog
  Scenario Outline: An Azure DevOps reference only names the checkout's own repository
    Given the project's checkout is the Azure DevOps repository "web" of "org/project"
    When a client names pull request 7 of "<repository>" <host>
    Then the pull request is not identified

    Examples:
      | repository | host                      |
      | other      | without a host            |
      | web        | on "unrelated.test"       |

  @mc @backlog
  Scenario Outline: Every spelling of an Azure DevOps host names the same pull request
    Given the project's checkout was cloned from "<remote>"
    When a client names pull request 7 of "web"
    Then the pull request is identified as number 7 of "org/project/_git/web" on "dev.azure.com"

    Examples:
      | remote                                                         |
      | https://dev.azure.com/org/project/_git/web                     |
      | git@ssh.dev.azure.com:v3/org/project/web                       |
      | org@vs-ssh.visualstudio.com:v3/org/project/web                 |
      | https://org.visualstudio.com/defaultcollection/project/_git/web |
