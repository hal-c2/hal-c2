# Sources:
#   docs/user/source-control.md (merge, auto-merge, revert, fork workflows, reviewers, labels)
#   packages/contracts/src/pullRequest.ts (PullRequestAction, PullRequestMergeMethod, PullRequestUpdateMethod, PullRequestCapabilities, PullRequestViewerPermissions)
#   packages/contracts/src/rpc.ts (pullRequests.runAction, pullRequests.reviewerCandidates, pullRequests.requestReviewers, pullRequests.labelCandidates, pullRequests.setLabels)
#   apps/server-ex/lib/hal_c2/pull_requests.ex (run_action, reviewer_candidates, request_reviewers, label_candidates, set_labels, refusals)
#   apps/web/src/components/pullRequest/PullRequestDetailPanel.tsx
#   apps/web/src/components/pullRequest/PullRequestReviewerPicker.tsx
#   apps/web/src/components/pullRequest/PullRequestLabelPicker.tsx
#   apps/web/src/components/pullRequest/PullRequestCandidatePicker.tsx
#   apps/web/src/components/pullRequest/pullRequestDetail.logic.ts

Feature: Acting on a pull request
  From the review the user can merge, change draft state, close and reopen, update the
  branch, arrange auto-merge, revert, approve fork workflows, ask for reviews and set labels.
  The host decides who may do what, and the refusal says why.

  Background:
    Given a connected environment with the GitHub project "acme/shop"
    And the open pull request 42
    And the user has write access to "acme/shop"

  @mc
  Scenario Outline: Merging with a method
    When the user merges pull request 42 with the <method> method
    Then pull request 42 is merged by <method>

    Examples:
      | method |
      | merge  |
      | squash |
      | rebase |

  @mc
  Scenario: Marking a draft ready for review
    Given pull request 42 is a draft
    When the user marks it ready for review
    Then pull request 42 is no longer a draft

  @mc
  Scenario: Returning a pull request to draft
    When the user returns pull request 42 to draft
    Then pull request 42 is a draft

  @mc
  Scenario: Closing a pull request
    When the user closes pull request 42
    Then pull request 42 is closed

  @mc
  Scenario: Reopening a closed pull request
    Given pull request 42 is closed
    When the user reopens it
    Then pull request 42 is open

  @backlog @mc
  Scenario: Bitbucket cannot reopen a declined pull request
    Given a Bitbucket pull request that was declined
    When the user looks at its actions
    Then reopening is not offered

  @mc
  Scenario Outline: Updating a branch that is behind its base
    Given pull request 42 is behind its base
    When the user updates its branch by <method>
    Then pull request 42 is up to date with its base

    Examples:
      | method |
      | merge  |
      | rebase |

  @mc
  Scenario: Arranging auto-merge
    Given pull request 42 has pending checks
    When the user enables auto-merge
    Then GitHub will merge pull request 42 once it is ready

  @mc
  Scenario: Cancelling auto-merge
    Given auto-merge is enabled on pull request 42
    When the user disables auto-merge
    Then pull request 42 will not be merged by itself

  @mc
  Scenario: Reverting a merged pull request
    Given pull request 42 has merged
    When the user reverts it
    Then a new pull request that reverts 42 is opened

  @mc
  Scenario: Approving workflows for a fork
    Given pull request 42 comes from a fork and its workflows wait for approval
    When the user approves its workflows
    Then the workflows start

  @mc
  Scenario Outline: Actions the user is not allowed to take are refused with the reason
    Given the user has only read access to "acme/shop"
    When the user tries to <action> pull request 42
    Then the user is told "<message>"

    Examples:
      | action           | message                                                                  |
      | merge            | You need write access on this repository to merge.                       |
      | revert           | You need write access on this repository to open a revert pull request. |
      | enable auto-merge on | You need write access on this repository to have it merged for you once it is ready. |

  @mc
  Scenario: A permission the host says nothing about is assumed granted
    Given GitHub does not report whether the user may close pull request 42
    When the user looks at its actions
    Then closing is offered

  @mc
  Scenario: Asking people for a review
    When the user asks "hubot" and the team "acme/core" to review pull request 42
    Then both are listed as requested reviewers

  @mc
  Scenario: The author is never suggested as a reviewer
    Given pull request 42 was opened by "octocat"
    When the user searches reviewers for "octo"
    Then "octocat" is not suggested

  @mc
  Scenario: Asking for a review without write access
    Given the user has only read access to "acme/shop"
    When the user asks "hubot" to review pull request 42
    Then the user is told "You need write access on this repository to ask for a review."

  @mc
  Scenario: Adding and removing labels
    Given pull request 42 has the label "bug"
    When the user adds "tax" and removes "bug"
    Then pull request 42 has only the label "tax"

  @mc
  Scenario: Changing labels without triage access
    Given the user has only read access to "acme/shop"
    When the user adds the label "tax" to pull request 42
    Then the user is told "You need triage access on this repository to change its labels."

  @backlog @mc
  Scenario Outline: Auto-merge on other hosts
    Given an open change request on <host>
    When the user enables auto-merge
    Then <host> will merge it once it is ready

    Examples:
      | host         |
      | GitLab       |
      | Azure DevOps |

  @backlog @mc
  Scenario: Changing a comment on Azure DevOps happens on the host
    Given a comment the user wrote on an Azure DevOps pull request
    When the user wants to edit it
    Then the user is sent to Azure DevOps to change it

  @desktop @mobile @backlog-mobile
  Scenario: Merging from the review
    When the user merges pull request 42 from its review with the default merge method
    Then the review shows pull request 42 as merged
