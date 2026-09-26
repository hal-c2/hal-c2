# Sources:
#   docs/user/source-control.md (Pull requests page, Mark files viewed)
#   docs/internals/pull-request-file-revisions.md
#   packages/contracts/src/pullRequest.ts (PullRequestDetail, PullRequestChecks, PullRequestActivity, PullRequestThreadComments, PullRequestSubmitReviewInput, PullRequestReaction, PullRequestFilesViewed, PullRequestDiff)
#   packages/contracts/src/rpc.ts (pullRequests.detail, pullRequests.preview, pullRequests.checks, pullRequests.activity, pullRequests.threadComments, pullRequests.diffFileContents, pullRequests.filesViewed, pullRequests.setFilesViewed, pullRequests.comment, pullRequests.updateComment, pullRequests.submitReview, pullRequests.replyToThread, pullRequests.setThreadResolution, pullRequests.setReaction, pullRequests.update)
#   apps/server-ex/lib/t3/pull_requests.ex (detail, checks, activity, comment, submit_review, set_reaction, files_viewed, update)
#   apps/server-ex/lib/t3/web/router.ex (POST /api/pull-requests/diff)
#   apps/server-ex/test/t3/features_backlog_test.exs (github-media-assets)
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

  @node
  Scenario: Reading a pull request
    When the user opens pull request 42
    Then the user sees its title, description, branches, author, labels, reviewers and mergeability
    And whether its branch is behind the base

  @node
  Scenario: Reading the conversation
    When the user opens the conversation of pull request 42
    Then comments, reviews and events are listed in order

  @node
  Scenario: Outdated review threads are kept apart
    Given a review thread on pull request 42 refers to code that has since changed
    When the user reads the review threads
    Then that thread is listed among the outdated ones

  @node
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

  @node
  Scenario: Commenting on a pull request
    When the user comments "Looks good" on pull request 42
    Then the comment appears in the conversation

  @node
  Scenario: An empty comment is refused
    When the user comments with only spaces on pull request 42
    Then the user is told "A comment cannot be empty."

  @node
  Scenario: Editing one's own comment
    Given the user commented "Looks god" on pull request 42
    # "edits it to" is the composer's queued-message step; this one edits a PR comment.
    When the user edits the comment to "Looks good"
    Then the comment reads "Looks good"

  @node
  Scenario: Editing the title and description
    Given the user may edit pull request 42
    When the user changes its title to "Add tax to the cart"
    Then pull request 42 has the new title

  @node
  Scenario: Saving an edit without changes
    When the user saves the title and description of pull request 42 unchanged
    Then the user is told "Nothing was changed."

  @node
  Scenario Outline: Submitting a review with line comments
    Given the user left a comment on line 12 of "src/cart.ts" in pull request 42
    When the user submits the review as <verdict>
    Then the review and its line comment arrive on GitHub together

    Examples:
      | verdict         |
      | comment         |
      | approve         |
      | request changes |

  @node
  Scenario: A review needs something to say
    When the user submits a comment review with no summary and no line comments
    Then the user is told "A review needs a summary or at least one comment."

  @node
  Scenario: Replying to a review thread
    Given a review thread on line 12 of "src/cart.ts"
    When the user replies "Fixed"
    Then the reply is added to that thread

  @node
  Scenario: Resolving a review thread
    Given an unresolved review thread
    When the user resolves it
    Then the thread is resolved

  @node
  Scenario: Reopening a resolved review thread
    Given a resolved review thread
    When the user unresolves it
    Then the thread is open again

  @node
  Scenario: Adding a reaction
    When the user reacts with a heart to the description of pull request 42
    Then the heart count goes up by one and includes the user

  @node
  Scenario: Removing a reaction
    Given the user reacted with a heart to the description of pull request 42
    When the user reacts with a heart again
    Then the user's heart is removed

  @node
  Scenario: Marking a file viewed on GitHub
    When the user marks "src/cart.ts" viewed in pull request 42
    Then GitHub records "src/cart.ts" as viewed for the user

  @node
  Scenario: Unmarking a viewed file
    Given "src/cart.ts" is marked viewed in pull request 42
    When the user marks it not viewed
    Then GitHub records "src/cart.ts" as not viewed

  @node
  Scenario: A viewed file that changed again is flagged
    Given "src/cart.ts" is marked viewed in pull request 42
    When the author pushes a change to "src/cart.ts"
    Then the file is reported as changed since it was viewed

  @backlog @node
  Scenario: Hosts without viewed marks keep them in the environment
    Given a GitLab project with the open merge request 5
    When the user marks "src/cart.ts" viewed in merge request 5
    Then the environment keeps the mark with the revision it was made against
    And the file reads as viewed in T3 Code

  @backlog @node
  Scenario: A file missing from the host's answer is not treated as deleted
    Given the user marked "src/cart.ts" viewed in a GitLab merge request
    When the host answers without "src/cart.ts"
    Then the mark is kept

  @node
  Scenario: A large diff arrives in slices
    Given pull request 42 changes 450 files
    When the user opens its code
    Then the files arrive in slices and every file's line counts are known

  @node
  Scenario: Reviewing the code of one commit
    When the user scopes the code of pull request 42 to one of its commits
    Then only that commit's changes are shown

  @node
  Scenario: Reading a whole changed file
    When the user expands the unchanged lines around a change in "src/cart.ts"
    Then the file's contents on both sides are shown

  @backlog @desktop @mobile
  Scenario: The review page
    When the user opens pull request 42
    Then the description, conversation, checks and code are shown on its review page
    And a viewed file collapses and the viewed count goes up

  @backlog @mobile
  Scenario: The phone reviews without the code
    When the user opens pull request 42 on the phone
    Then the conversation and checks are shown without the diff

  @backlog @node
  Scenario: Images in a private pull request are fetched by the node
    Given the description of pull request 42 holds an image uploaded to GitHub
    When the user reads the description
    Then the node fetches the image with its GitHub credentials
    And the client never receives the GitHub token
