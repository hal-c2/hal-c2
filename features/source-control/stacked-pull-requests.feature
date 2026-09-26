# Sources:
#   docs/user/source-control.md (GitHub stacks)
#   packages/contracts/src/pullRequest.ts (PullRequestStack, expectedStackHeads)
#   packages/contracts/src/rpc.ts (pullRequests.stack, pullRequests.runAction)
#   apps/server-ex/lib/t3/pull_requests/github_stack.ex
#   apps/server-ex/lib/t3/pull_requests/sync.ex (stack layers)
#   apps/web/src/components/pullRequest/PullRequestStackMenu.tsx
#   apps/web/src/components/pullRequest/PullRequestStackHeader.tsx
#   apps/web/src/components/pullRequest/PullRequestStackLayers.tsx
#   apps/web/src/components/pullRequest/PullRequestStackLayerContent.tsx
#   apps/web/src/components/pullRequest/PullRequestStackPopover.tsx

Feature: Stacked pull requests
  GitHub stacks are pull requests layered on one another. T3 Code shows the layers,
  merges a layer with everything below it, and rebases the whole stack bottom up.

  Background:
    Given a connected environment with the GitHub project "acme/shop"
    And the stack onto "main" of pull requests 41, 42 and 43, bottom to top

  @node
  Scenario: Reading a pull request's stack
    When the user asks for the stack of pull request 42
    Then the layers 41, 42 and 43 are listed in order with their heads

  @node
  Scenario: Merging a layer merges the open layers below it
    When the user merges the stack at pull request 42 by squash
    Then pull requests 41 and 42 are merged or queued
    And pull request 43 stays open

  @node
  Scenario: Rebasing the stack bottom up
    When the user rebases the stack
    Then 41, 42 and 43 are rebased in that order onto "main" on GitHub
    And the local checkout is not touched

  @node
  Scenario: A stack that changed since the user looked is not touched
    Given someone pushed to pull request 42 after the user read the stack
    When the user merges the stack at pull request 43
    Then the merge is refused and nothing is merged

  @node
  Scenario: A stack action needs the heads the user saw
    When a stack merge is asked for without the layers' heads
    Then it is refused with "This stack action is not supported or has no expected head revision."

  @node
  Scenario: A stack is only updated by rebase
    When the user updates the stack's branches by merge
    Then the action is refused

  @node
  Scenario: A partly failed rebase keeps the layers that finished
    Given rebasing pull request 43 will conflict
    When the user rebases the stack
    Then 41 and 42 stay rebased
    And the user is told how many layers finished before the failure

  @node
  Scenario: Linking a layer links the stack
    When the user links pull request 42 to the thread "Tax work"
    Then "Tax work" also lists 41 and 43 as layers of its stack

  @node
  Scenario: An unlinked layer stays out of later syncs
    Given pull request 43 was linked to "Tax work" through its stack
    When the user unlinks pull request 43
    Then the next sync does not bring 43 back

  @backlog @desktop @mobile
  Scenario: Confirming a stack merge shows scope and strategy
    When the user chooses to merge the stack at pull request 42
    Then the user is asked to confirm merging 2 pull requests into "main" with the chosen method

  @backlog @desktop @mobile
  Scenario: Confirming a stack rebase warns it rewrites history
    When the user chooses to rebase the stack
    Then the user is warned that branch history is rewritten and checks may restart

  @backlog @desktop @mobile
  Scenario: The thread's pull request shows its stack
    Given pull request 42 is linked to "Tax work"
    When the user looks at "Tax work"
    Then its pull request shows it is layer 2 of 3

  @backlog @desktop @mobile
  Scenario: A stack that could not be refreshed says it may be stale
    Given the last stack refresh failed
    When the user looks at the stack
    Then the stack is marked as possibly stale with a way to retry
