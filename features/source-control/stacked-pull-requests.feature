# Sources:
#   docs/user/source-control.md (GitHub stacks)
#   packages/contracts/src/pullRequest.ts (PullRequestStack, expectedStackHeads)
#   packages/contracts/src/rpc.ts (pullRequests.stack, pullRequests.runAction)
#   apps/server-ex/lib/hal_c2/pull_requests/github_stack.ex
#   apps/server-ex/lib/hal_c2/pull_requests/sync.ex (stack layers)
#   apps/web/src/components/pullRequest/PullRequestStackMenu.tsx
#   apps/web/src/components/pullRequest/PullRequestStackHeader.tsx
#   apps/web/src/components/pullRequest/PullRequestStackLayers.tsx
#   apps/web/src/components/pullRequest/PullRequestStackLayerContent.tsx
#   apps/web/src/components/pullRequest/PullRequestStackPopover.tsx
#   apps/web/src/components/pullRequest/pullRequestStackSnapshot.ts, apps/web/src/state/usePullRequestStack.ts
#   apps/web/src/components/pullRequest/pullRequestStackSnapshot.test.ts (saved stacks across threads, hosts and repositories)
#   apps/web/src/components/pullRequest/pullRequestDetail.logic.ts (allowsSinglePullRequestMerge)
#   apps/server/src/pullRequest/githubStackActions.ts
#   apps/server/src/pullRequest/GitHubPullRequestCli.ts (getPullRequestStack)

Feature: Stacked pull requests
  GitHub stacks are pull requests layered on one another. HAL-C2 shows the layers,
  merges a layer with everything below it, and rebases the whole stack bottom up.

  Background:
    Given a connected environment with the GitHub project "acme/shop"
    And the stack onto "main" of pull requests 41, 42 and 43, bottom to top

  @mc
  Scenario: Reading a pull request's stack
    When the user asks for the stack of pull request 42
    Then the layers 41, 42 and 43 are listed in order with their heads

  @mc
  Scenario: Merging a layer merges the open layers below it
    When the user merges the stack at pull request 42 by squash
    Then pull requests 41 and 42 are merged or queued
    And pull request 43 stays open

  @mc
  Scenario: Rebasing the stack bottom up
    When the user rebases the stack
    Then 41, 42 and 43 are rebased in that order onto "main" on GitHub
    And the local checkout is not touched

  @mc
  Scenario: A stack that changed since the user looked is not touched
    Given someone pushed to pull request 42 after the user read the stack
    When the user merges the stack at pull request 43
    Then the merge is refused and nothing is merged

  @mc
  Scenario: A stack action needs the heads the user saw
    When a stack merge is asked for without the layers' heads
    Then it is refused with "This stack action is not supported or has no expected head revision."

  @mc
  Scenario: A stack is only updated by rebase
    When the user updates the stack's branches by merge
    Then the action is refused

  @mc
  Scenario: A partly failed rebase keeps the layers that finished
    Given rebasing pull request 43 will conflict
    When the user rebases the stack
    Then 41 and 42 stay rebased
    And the user is told how many layers finished before the failure

  @mc
  Scenario: Linking a layer links the stack
    When the user links pull request 42 to the thread "Tax work"
    Then "Tax work" also lists 41 and 43 as layers of its stack

  @mc
  Scenario: An unlinked layer stays out of later syncs
    Given pull request 43 was linked to "Tax work" through its stack
    When the user unlinks pull request 43
    Then the next sync does not bring 43 back

  @desktop @mobile @backlog-mobile
  Scenario: Confirming a stack merge shows scope and strategy
    When the user chooses to merge the stack at pull request 42
    Then the user is asked to confirm merging 2 pull requests into "main" with the chosen method

  @desktop @mobile @backlog-mobile
  Scenario: Confirming a stack rebase warns it rewrites history
    When the user chooses to rebase the stack
    Then the user is warned that branch history is rewritten and checks may restart

  @desktop @mobile @backlog-mobile
  Scenario: The thread's pull request shows its stack
    Given pull request 42 is linked to "Tax work"
    When the user looks at "Tax work"
    Then its pull request shows it is layer 2 of 3

  @desktop @mobile @backlog-mobile
  Scenario: A stack that could not be refreshed says it may be stale
    Given the last stack refresh failed
    When the user looks at the stack
    Then the stack is marked as possibly stale with a way to retry

  @backlog @desktop
  Scenario: A row's stack opens its layers from the top down
    Given the list shows pull request 42 as layer 2 of 3
    When the user opens its stack
    Then the stack is headed with its own number as "Stack #<number>"
    And the layers 43, 42 and 41 are listed top to bottom with their titles, numbers and states
    And the layer being looked at is marked
    And the base branch "main" is shown beneath them

  @backlog @desktop
  Scenario: Opening a layer from the stack goes to that pull request
    Given the stack of pull request 42 is open from its row
    When the user chooses layer 43
    Then pull request 43 is shown
    And the stack closes

  @backlog @desktop
  Scenario: A stack is read only when it is opened
    Given the list shows twenty rows that belong to stacks
    When the user opens the list
    Then no stack is read until the user opens one

  @backlog @desktop
  Scenario: A stack on its way says so
    Given the stack of pull request 42 has not been read yet
    When the user opens its stack
    Then it says "Loading stack…"

  @backlog @desktop
  Scenario: A pull request that has left its stack says so
    Given pull request 42 was taken out of its stack since the list was read
    When the user opens its stack
    Then it says "This pull request is no longer in a stack."

  @backlog @desktop
  Scenario: A stack that cannot be read says why and can be retried
    Given reading the stack of pull request 42 fails
    When the user opens its stack
    Then the reason is shown
    And "Retry stack refresh" is offered

  @backlog @desktop
  Scenario: A stack being refreshed shows what was saved
    Given a thread of the user is linked to pull request 42 with a saved stack
    When the user opens the stack while it is being read again
    Then the saved layers are shown, marked "Refreshing…"

  @backlog @desktop
  Scenario: A stack that failed to refresh keeps the saved layers
    Given a thread of the user is linked to pull request 42 with a saved stack
    And reading the stack fails
    When the user opens the stack
    Then the saved layers are shown, marked "May be stale"
    And the notice says "Stack data may be stale. We couldn’t refresh it."

  @backlog @desktop
  Scenario: A fresh answer that the stack is gone wins over saved layers
    Given a thread of the user is linked to pull request 42 with a saved stack
    And the host now says pull request 42 is in no stack
    When the user opens the stack
    Then no layers are shown

  @backlog @desktop
  Scenario: A stack's layers take their titles from the threads that saved them
    Given a thread saved layers 41 and 42 with their titles and draft state
    When the saved stack is shown
    Then layers 41 and 42 carry those titles and draft state

  # Legacy: apps/web/src/components/pullRequest/pullRequestStackSnapshot.test.ts (does not borrow stacks across hosts or repositories)
  @backlog @desktop
  Scenario Outline: A saved stack is only borrowed for the same pull request on the same host and repository
    Given a thread saved a stack for pull request 42 of "acme/web" on "github.com"
    When the user opens the stack of <pull request>
    Then no saved layers are shown

    Examples:
      | pull request                                      |
      | pull request 42 of "acme/web" on another host     |
      | pull request 42 of "other/web" on "github.com"    |
      | pull request 42 whose host is not known           |

  # Legacy: apps/web/src/components/pullRequest/pullRequestStackSnapshot.test.ts (honors a newer saved removal across linked threads)
  @backlog @desktop
  Scenario: A thread that saw the stack gone later outweighs one that saved it earlier
    Given one thread saved a stack for pull request 42 at ten o'clock
    And another thread linked to pull request 42 saved that it is in no stack at eleven o'clock
    When the saved stack is shown
    Then no layers are shown

  @backlog @desktop
  Scenario: A lookup that failed with no saved stack can be retried from the review
    Given the host has stacks and reading the stack of pull request 42 fails
    And no thread saved its stack
    When the user looks at the pull request's review
    Then "Retry stack lookup" is offered

  @backlog @desktop
  Scenario Outline: A single merge waits until the stack is known
    Given the environment can act on stacks
    And <lookup>
    When the user looks at pull request 42's review
    Then merging the pull request on its own is <offered>

    Examples:
      | lookup                                      | offered     |
      | its stack has not been read yet             | not offered |
      | reading its stack failed                    | not offered |
      | it is in a stack                            | not offered |
      | it is read to be in no stack                | offered     |

  @backlog @desktop
  Scenario: An environment that cannot act on stacks merges single pull requests as before
    Given the environment cannot act on stacks
    When the user looks at pull request 42's review
    Then merging the pull request on its own is offered without waiting for any stack

  @backlog @desktop
  Scenario: Merging the stack is offered up to the layer being looked at
    Given pull request 42 is open and ready, with 41 below it open and ready
    When the user looks at pull request 42's review
    Then the stack offers "Merge stack (2)"
    And pointing at it says it merges the stack through #42 into "main" (2 pull requests)

  @backlog @desktop
  Scenario: Layers already merged are not counted in a stack merge
    Given layer 41 is already merged
    When the user looks at pull request 42's review
    Then the stack offers "Merge stack (1)"

  @backlog @desktop
  Scenario Outline: A stack merge is not available when it could not succeed
    Given <condition>
    When the user looks at pull request 42's review
    Then merging the stack is not available
    And the stack says "Every layer being merged must be open and ready for review."

    Examples:
      | condition                                          |
      | layer 41, below, is a draft                        |
      | layer 41, below, is closed                         |

  @backlog @desktop
  Scenario: A stack merge needs every layer's head to be known
    Given the host did not report the head of layer 41
    When the user looks at pull request 42's review
    Then merging the stack is not available

  @backlog @desktop
  Scenario: A rebase of the stack needs every unmerged layer open and known
    Given layer 42 is closed without merging
    When the user opens the stack's actions
    Then rebasing the stack is not available

  @backlog @desktop
  Scenario: A stack's actions wait for a fresh read
    Given the stack shown is still being read or could not be read
    When the user looks at the stack's actions
    Then merging and rebasing the stack are not offered until the stack has been read

  @backlog @desktop
  Scenario: Merging the stack needs the permission to merge
    Given the user may not merge pull request 42
    When the user opens the stack's actions
    Then "Merge stack" is not offered

  @backlog @desktop
  Scenario: Rebasing the stack needs its own permission
    Given the host does not let the user rebase the stack
    When the user opens the stack's actions
    Then "Rebase stack" is not offered

  @backlog @desktop
  Scenario: Confirming a stack merge names the layers and the method
    Given the merge method is "squash"
    When the user chooses "Merge stack"
    Then the user is asked "Merge 2 pull requests?"
    And told that #42 and its unmerged layers below will be merged into "main" using squash
    And told that GitHub checks the rules before merging or queueing them and rebases the remaining stack afterwards
    And the layers are listed

  @backlog @desktop
  Scenario: Confirming a stack rebase names the layers
    When the user chooses "Rebase stack"
    Then the user is asked "Rebase 3 pull requests?"
    And told the remote branches are rebased from bottom to top onto "main", rewriting branch history and maybe restarting checks
    And told that if a layer fails, earlier updates remain

  @backlog @desktop
  Scenario: A stack action that is running cannot be repeated or dismissed
    Given the user confirmed a stack merge and it is running
    Then the confirmation button reads "Working…"
    And it cannot be pressed again, cancelled or closed

  @backlog @desktop
  Scenario Outline: A stack action tells the user how it ended
    Given the user confirmed <action>
    When <result>
    Then the user is told <toast>
    And the stack and the review are read again

    Examples:
      | action        | result                  | toast                                                                                     |
      | a stack merge | GitHub accepts it       | "Stack merge request completed" and that GitHub merged the stack or queued it             |
      | a stack rebase| GitHub accepts it       | "Stack rebased"                                                                           |
      | a stack merge | it fails                | "Stack operation did not complete" with the reason                                        |
      | a stack rebase| it fails                | "Stack operation did not complete" with the reason                                        |

  @backlog @mc
  Scenario: A stack merge is submitted as one merge with the head the user saw
    When the user merges the stack at pull request 43 by squash
    Then GitHub is asked once to merge pull request 43 by squash at the head the user reviewed
    And the layers below it are merged by that one request

  @backlog @mc
  Scenario: A stack merge GitHub puts in its merge queue is not reported as merged
    Given GitHub's merge queue accepts the stack merge
    When the user merges the stack at pull request 42
    Then the stack merge is accepted as submitted
    And the MC does not claim the layers are merged yet

  @backlog @mc
  Scenario: A stack merge GitHub later rejects says so
    Given GitHub accepts the stack merge and later reports that it failed
    When the user merges the stack at pull request 43
    Then the user is told "GitHub refused the stack merge. Check the stack's branch rules and merge requirements."
    And no layer is reported as merged

  @backlog @mc
  Scenario: A stack merge that is still running after five minutes is not reported as done
    Given GitHub is still working on the stack merge after five minutes
    When the user merges the stack at pull request 43
    Then the user is told "The merge is still running on GitHub. Check its status there before submitting another request."
    And the MC stops polling instead of waiting without limit

  @backlog @mc
  Scenario: A running stack merge is polled with a growing pause
    Given GitHub reports the stack merge as pending
    When the user merges the stack at pull request 43
    Then the MC asks GitHub again after one second, then two, four and eight
    And it never waits more than ten seconds between asks

  @backlog @mc
  Scenario: Draft layers above the chosen layer do not hold the merge back
    Given the stack also has draft pull requests 44 and 45 above pull request 43
    When the user merges the stack at pull request 43
    Then pull requests 41, 42 and 43 are merged
    And pull requests 44 and 45 stay open

  @backlog @mc
  Scenario: A draft layer at or below the chosen layer refuses the merge
    Given pull request 42 is a draft
    When the user merges the stack at pull request 43
    Then the merge is refused with "This operation is not supported for this stack."
    And nothing is merged

  @backlog @mc
  Scenario: A layer that is already merged cannot start a stack merge
    Given pull request 41 is already merged
    When the user merges the stack at pull request 41
    Then the merge is refused with "This operation is not supported for this stack."

  @backlog @mc
  Scenario Outline: A stack action that no longer matches the stack names what changed
    Given <situation>
    When the user <action>
    Then the user is told "<message>"
    And nothing is changed on GitHub

    Examples:
      | situation                                         | action                         | message                                              |
      | pull request 42 left the stack after it was read  | merges the stack at 42         | The stack changed. Refresh it before trying again.   |
      | the stack was replaced by another stack           | rebases the stack              | The stack changed. Refresh it before trying again.   |
      | a layer was merged after the user looked          | rebases the stack              | The stack changed. Refresh it before trying again.   |

  @backlog @mc
  Scenario: A stack rebase is refused before anything changes when a fork cannot be pushed to
    Given pull request 43 comes from a fork whose owner does not allow maintainer updates
    And the user has no write access to that fork
    When the user rebases the stack
    Then the user is told "You cannot update every branch in this stack. Check write access and fork maintainer permissions before retrying."
    And no layer is rebased, including the ones below pull request 43

  @backlog @mc
  Scenario: A fork that allows maintainer updates can be rebased
    Given pull request 43 comes from a fork whose owner allows maintainer updates
    When the user rebases the stack
    Then pull request 43 is rebased with the other layers

  @backlog @mc
  Scenario: Layers that are already current are left alone in a rebase
    Given pull request 41 is already up to date with "main"
    When the user rebases the stack
    Then pull request 41 is not rebased again
    And pull requests 42 and 43 are rebased

  @backlog @mc
  Scenario: A push to a layer during a stack rebase stops it and keeps the finished layers
    Given someone pushes to pull request 43 while the stack is being rebased
    When the user rebases the stack
    Then the rebase stops at pull request 43 without rebasing the pushed revision
    And the user is told "The stack changed at PR #43 after 2 layers. Earlier updates remain on GitHub. Refresh it before trying again."

  @backlog @mc
  Scenario: A push to a layer already rebased is not built on
    Given someone pushes to pull request 41 after it was rebased but before pull request 42 was
    When the user rebases the stack
    Then pull request 42 is not rebased onto the new revision
    And the user is told which layer changed and how many finished before it

  @backlog @mc
  Scenario: A rebase that fails on one layer says which layer and how many finished
    Given GitHub refuses to rebase pull request 43
    When the user rebases the stack
    Then the user is told "Stack rebase stopped at PR #43 after 2 layers. Earlier updates remain on GitHub; resolve the failing layer before retrying."

  @backlog @mc
  Scenario: Only the top layer of a stack can start a rebase
    When the user rebases the stack from pull request 42
    Then it is refused because the stack no longer matches
    And nothing is rebased

  @backlog @mc
  Scenario: A host without stacks reports no stack
    Given GitHub does not offer stacks for "acme/shop"
    When the user asks for the stack of pull request 42
    Then pull request 42 has no stack
    And no error is shown

  @backlog @mc
  Scenario: A stack lookup that fails for another reason keeps the stack last synced
    Given the stack of pull request 42 was synced earlier
    And GitHub fails with something other than "not found" when asked for the stack again
    When the stack of pull request 42 is refreshed
    Then the last synced stack stays
    And the refresh can be tried again

  @backlog @mc
  Scenario: An unreadable stack answer is reported and changes nothing
    Given GitHub answers a stack action with something the MC cannot read
    When the user merges the stack at pull request 43
    Then the user is told "GitHub returned an unreadable stack operation response."
    And nothing is changed
