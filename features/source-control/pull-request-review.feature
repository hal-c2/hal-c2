# Sources:
#   docs/user/source-control.md (Pull requests page, Mark files viewed)
#   docs/internals/pull-request-file-revisions.md
#   packages/contracts/src/pullRequest.ts (PullRequestDetail, PullRequestChecks, PullRequestActivity, PullRequestThreadComments, PullRequestSubmitReviewInput, PullRequestReaction, PullRequestFilesViewed, PullRequestDiff)
#   packages/contracts/src/rpc.ts (pullRequests.detail, pullRequests.preview, pullRequests.checks, pullRequests.activity, pullRequests.threadComments, pullRequests.diffFileContents, pullRequests.filesViewed, pullRequests.setFilesViewed, pullRequests.comment, pullRequests.updateComment, pullRequests.submitReview, pullRequests.replyToThread, pullRequests.setThreadResolution, pullRequests.setReaction, pullRequests.update)
#   apps/server-ex/lib/hal_c2/pull_requests.ex (detail, checks, activity, comment, submit_review, set_reaction, files_viewed, update)
#   apps/server-ex/lib/hal_c2/web/router.ex (POST /api/pull-requests/diff)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (github-media-assets)
#   apps/web/src/components/pullRequest/PullRequestDetailPanel.tsx
#   apps/web/src/components/pullRequest/PullRequestCodeTab.tsx
#   apps/web/src/components/pullRequest/PullRequestReviewForm.tsx
#   apps/web/src/components/pullRequest/PullRequestReviewAnnotation.tsx
#   apps/web/src/components/pullRequest/PullRequestComposer.tsx
#   apps/web/src/components/pullRequest/PullRequestCommentForm.tsx
#   apps/web/src/components/pullRequest/PullRequestReactions.tsx
#   apps/web/src/components/pullRequest/PullRequestChecksPopover.tsx
#   apps/web/src/components/pullRequest/pullRequestFilesViewed.logic.ts
#   apps/web/src/components/pullRequest/PullRequestMarkdown.tsx
#   apps/web/src/components/pullRequest/pullRequestEditing.logic.ts

Feature: Reviewing a pull request
  Opening a pull request shows its description, conversation, checks and code. The user
  can comment, review line by line, react, edit, and keep track of the files they viewed.

  Background:
    Given a connected environment with the GitHub project "acme/shop"
    And the open pull request 42 by "octocat"

  @mc
  Scenario: Reading a pull request
    When the user opens pull request 42
    Then the user sees its title, description, branches, author, labels, reviewers and mergeability
    And whether its branch is behind the base

  @mc
  Scenario: Reading the conversation
    When the user opens the conversation of pull request 42
    Then comments, reviews and events are listed in order

  @mc
  Scenario: Outdated review threads are kept apart
    Given a review thread on pull request 42 refers to code that has since changed
    When the user reads the review threads
    Then that thread is listed among the outdated ones

  @mc
  Scenario Outline: Checks report their state
    Given a check on pull request 42 is <state>
    When the user reads the checks of pull request 42
    Then that check is reported as <state>

    Examples:
      | state           |
      | pending         |
      | action-required |
      | success         |
      | failure         |
      | skipped         |
      | neutral         |
      | cancelled       |

  @mc
  Scenario: Commenting on a pull request
    When the user comments "Looks good" on pull request 42
    Then the comment appears in the conversation

  @mc
  Scenario: An empty comment is refused
    When the user comments with only spaces on pull request 42
    Then the user is told "A comment cannot be empty."

  @mc
  Scenario: Editing one's own comment
    Given the user commented "Looks god" on pull request 42
    # "edits it to" is the composer's queued-message step; this one edits a PR comment.
    When the user edits the comment to "Looks good"
    Then the comment reads "Looks good"

  @mc
  Scenario: Editing the title and description
    Given the user may edit pull request 42
    When the user changes its title to "Add tax to the cart"
    Then pull request 42 has the new title

  @mc
  Scenario: Saving an edit without changes
    When the user saves the title and description of pull request 42 unchanged
    Then the user is told "Nothing was changed."

  @mc
  Scenario Outline: Submitting a review with line comments
    Given the user left a comment on line 12 of "src/cart.ts" in pull request 42
    When the user submits the review as <verdict>
    Then the review and its line comment arrive on GitHub together

    Examples:
      | verdict         |
      | comment         |
      | approve         |
      | request changes |

  @mc
  Scenario: A review needs something to say
    When the user submits a comment review with no summary and no line comments
    Then the user is told "A review needs a summary or at least one comment."

  @mc
  Scenario: Replying to a review thread
    Given a review thread on line 12 of "src/cart.ts"
    When the user replies "Fixed"
    Then the reply is added to that thread

  @mc
  Scenario: Resolving a review thread
    Given an unresolved review thread
    When the user resolves it
    Then the thread is resolved

  @mc
  Scenario: Reopening a resolved review thread
    Given a resolved review thread
    When the user unresolves it
    Then the thread is open again

  @mc
  Scenario: Adding a reaction
    When the user reacts with a heart to the description of pull request 42
    Then the heart count goes up by one and includes the user

  @mc
  Scenario: Removing a reaction
    Given the user reacted with a heart to the description of pull request 42
    When the user reacts with a heart again
    Then the user's heart is removed

  @mc
  Scenario: Marking a file viewed on GitHub
    When the user marks "src/cart.ts" viewed in pull request 42
    Then GitHub records "src/cart.ts" as viewed for the user

  @mc
  Scenario: Unmarking a viewed file
    Given "src/cart.ts" is marked viewed in pull request 42
    When the user marks it not viewed
    Then GitHub records "src/cart.ts" as not viewed

  @mc
  Scenario: A viewed file that changed again is flagged
    Given "src/cart.ts" is marked viewed in pull request 42
    When the author pushes a change to "src/cart.ts"
    Then the file is reported as changed since it was viewed

  @backlog @mc
  Scenario: Hosts without viewed marks keep them in the environment
    Given a GitLab project with the open merge request 5
    When the user marks "src/cart.ts" viewed in merge request 5
    Then the environment keeps the mark with the revision it was made against
    And the file reads as viewed in HAL-C2

  # Blocked: needs "Hosts without viewed marks keep them in the environment" first.
  @backlog @blocked @mc
  Scenario: A file missing from the host's answer is not treated as deleted
    Given the user marked "src/cart.ts" viewed in a GitLab merge request
    When the host answers without "src/cart.ts"
    Then the mark is kept

  @mc
  Scenario: A large diff arrives in slices
    Given pull request 42 changes 450 files
    When the user opens its code
    Then the files arrive in slices and every file's line counts are known

  @mc
  Scenario: Reviewing the code of one commit
    When the user scopes the code of pull request 42 to one of its commits
    Then only that commit's changes are shown

  @mc
  Scenario: Reading a whole changed file
    When the user expands the unchanged lines around a change in "src/cart.ts"
    Then the file's contents on both sides are shown

  @desktop @mobile @backlog-mobile
  Scenario: The review page
    When the user opens pull request 42
    Then the description, conversation, checks and code are shown on its review page
    And a viewed file collapses and the viewed count goes up

  @desktop @mobile @backlog-mobile
  Scenario: Unmarking a viewed file on the review page
    Given "src/cart.ts" is marked viewed in pull request 42
    When the user opens pull request 42
    And the user marks "src/cart.ts" not viewed on the review page
    Then "src/cart.ts" expands and the viewed count goes down

  @desktop @mobile @backlog-mobile
  Scenario: A viewed mark the host refuses is taken back
    Given GitHub refuses viewed marks on pull request 42
    When the user opens pull request 42
    And the user marks "src/cart.ts" viewed on the review page
    Then "src/cart.ts" is not marked viewed on the review page
    And the user sees an "error" toast "Could not mark the file viewed"

  @desktop @mobile @backlog-mobile
  Scenario: Commenting and reviewing from the review page
    When the user opens pull request 42
    And the user comments "Looks good" on the review page
    Then "Looks good" appears in the review page's conversation
    When the user approves pull request 42 on the review page
    Then the user sees a "success" toast "Approved"

  @desktop @mobile @backlog-mobile
  Scenario: The review page refuses what cannot be sent
    When the user opens pull request 42
    And the user comments with only spaces on the review page
    Then the review page says "A comment cannot be empty."
    When the user requests changes on the review page with no summary
    Then the review page says "A review needs a summary or at least one comment."
    And nothing was sent to pull request 42

  @desktop @mobile @backlog-mobile
  Scenario: Resolving and reopening a thread from the review page
    Given an unresolved review thread on pull request 42
    When the user opens pull request 42
    And the user resolves the thread on the review page
    Then the review page shows the thread resolved
    When the user unresolves the thread on the review page
    Then the review page shows the thread open

  @desktop @mobile @backlog-mobile
  Scenario: The review page while the environment is unreachable
    Given the user opened pull request 42
    When the environment of "Tax work" becomes unreachable
    Then the review page still shows pull request 42 and sends nothing
    When the environment of "Tax work" is reachable again
    Then the user can comment on the review page again

  @desktop @mobile @backlog-mobile
  Scenario: Copying the number of the reviewed pull request
    Given the user opened pull request 42
    When the user copies the pull request number
    Then the clipboard holds "#42"
    And the user sees a "success" toast "PR number copied"

  @desktop @mobile @backlog-mobile
  Scenario: The pull request number cannot be copied
    Given the user opened pull request 42
    And the clipboard cannot be written
    When the user copies the pull request number
    Then the user sees an "error" toast "Failed to copy PR number"

  @backlog @mobile
  Scenario: The phone reviews without the code
    When the user opens pull request 42 on the phone
    Then the conversation and checks are shown without the diff

  @backlog @mc
  Scenario: Images in a private pull request are fetched by the MC
    Given the description of pull request 42 holds an image uploaded to GitHub
    When the user reads the description
    Then the MC fetches the image with its GitHub credentials
    And the client never receives the GitHub token
