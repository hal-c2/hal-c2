# Sources:
#   https://github.com/pingdotgg/t3code/pull/29567
#   https://github.com/pingdotgg/t3code/pull/25988
#   https://github.com/pingdotgg/t3code/pull/24392
#   https://github.com/pingdotgg/t3code/pull/26563
#   https://github.com/pingdotgg/t3code/pull/24688
#   https://github.com/pingdotgg/t3code/pull/26060
#   https://github.com/pingdotgg/t3code/pull/23129
#   https://github.com/pingdotgg/t3code/pull/23725
#   https://github.com/pingdotgg/t3code/pull/25486
#   https://github.com/pingdotgg/t3code/pull/23466
#   https://github.com/pingdotgg/t3code/pull/26730
#   https://github.com/pingdotgg/t3code/pull/23138
#   https://github.com/pingdotgg/t3code/pull/21543
#   https://github.com/pingdotgg/t3code/pull/23225
#   https://github.com/pingdotgg/t3code/pull/20894
#   https://github.com/pingdotgg/t3code/pull/23548
#   https://github.com/pingdotgg/t3code/pull/22110
#   https://github.com/pingdotgg/t3code/pull/24406
#   https://github.com/pingdotgg/t3code/pull/19701
#   https://github.com/pingdotgg/t3code/pull/12274
#   https://github.com/pingdotgg/t3code/pull/18087
#   https://github.com/pingdotgg/t3code/pull/22090
#   https://github.com/pingdotgg/t3code/pull/18133
#   https://github.com/pingdotgg/t3code/pull/13835
#   https://github.com/pingdotgg/t3code/pull/14954
#   https://github.com/pingdotgg/t3code/pull/12583
#   https://github.com/pingdotgg/t3code/pull/18312
#   https://github.com/pingdotgg/t3code/pull/20977
#   https://github.com/pingdotgg/t3code/pull/20094
#   https://github.com/pingdotgg/t3code/pull/15886
#   https://github.com/pingdotgg/t3code/pull/14785
#   https://github.com/pingdotgg/t3code/pull/19945
#   https://github.com/pingdotgg/t3code/pull/18434
#   https://github.com/pingdotgg/t3code/pull/20440
#   https://github.com/pingdotgg/t3code/pull/17344
#   https://github.com/pingdotgg/t3code/pull/19162
#   https://github.com/pingdotgg/t3code/pull/16162
#   https://github.com/pingdotgg/t3code/pull/18124
#   https://github.com/pingdotgg/t3code/pull/18267
#   https://github.com/pingdotgg/t3code/pull/18455
#   https://github.com/pingdotgg/t3code/pull/18463
#   https://github.com/pingdotgg/t3code/pull/19375
#   https://github.com/pingdotgg/t3code/pull/18451
#   https://github.com/pingdotgg/t3code/pull/18126
#   https://github.com/pingdotgg/t3code/pull/18347
#   https://github.com/pingdotgg/t3code/pull/18608
#   https://github.com/pingdotgg/t3code/pull/18402
#   https://github.com/pingdotgg/t3code/pull/18900
#   https://github.com/pingdotgg/t3code/pull/17667
#   https://github.com/pingdotgg/t3code/pull/17645
#   https://github.com/pingdotgg/t3code/pull/22189
#   https://github.com/pingdotgg/t3code/pull/22255
#   https://github.com/pingdotgg/t3code/pull/22917
#   https://github.com/pingdotgg/t3code/pull/25829
#   https://github.com/pingdotgg/t3code/pull/21631
#   https://github.com/pingdotgg/t3code/pull/21632
#   https://github.com/pingdotgg/t3code/pull/30418
#   https://github.com/pingdotgg/t3code/pull/30411
#   https://github.com/pingdotgg/t3code/pull/30383
#   https://github.com/pingdotgg/t3code/pull/30425
#   https://github.com/pingdotgg/t3code/pull/27798
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
#   apps/web/src/components/pullRequest/PullRequestSummaryTab.tsx, PullRequestTimelineTab.tsx
#   apps/web/src/components/pullRequest/PullRequestCommentBody.tsx, pullRequestFileOrder.logic.ts
#   apps/web/src/components/pullRequest/pullRequestDetail.logic.ts, pullRequestReviewStore.ts
#   apps/web/src/components/pullRequest/usePullRequestFilesViewed.ts
#   apps/web/src/components/pullRequest/pullRequestFilesViewed.logic.ts
#   apps/server/src/persistence/PullRequestFilesViewed.ts
#   apps/server/src/persistence/Migrations/053_PullRequestFilesViewed.ts
#   apps/web/src/components/pullRequest/PullRequestMarkdown.tsx
#   apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts, PullRequestMarkdownEditor.tsx
#   apps/web/src/components/pullRequest/pullRequestReactions.logic.ts, PullRequestGhosts.tsx
#   apps/web/src/components/pullRequest/PullRequestSummaryTab.test.tsx, pullRequestSummaryScroll.logic.ts
#   apps/web/src/components/pullRequest/pullRequestDiff.logic.test.ts, pullRequestDetail.logic.test.ts
#   apps/web/src/components/pullRequest/pullRequestEditing.logic.ts
#   apps/server/src/pullRequest/GitHubPullRequestCli.ts (diff, expansion, threads, viewed marks)
#   apps/server/src/pullRequest/gitHubPullRequestJson.ts (files API patch, dismissed reviews)
#   apps/server/src/pullRequest/gitHubConditionalChecks.ts
#   apps/server/src/pullRequest/pullRequestChecks.ts
#   apps/server/src/pullRequest/pullRequestViewedFiles.ts
#   apps/server/src/pullRequest/PullRequestService.ts (refusals)
#   apps/server/src/pullRequest/GitLabPullRequestCli.ts, gitLabMergeRequestJson.ts
#   apps/server/src/pullRequest/BitbucketPullRequestApi.ts, bitbucketDiffRevisions.ts
#   apps/server/src/pullRequest/AzureDevOpsPullRequestCli.ts, AzureDevOpsPullRequestProvider.ts, azureDevOpsDiff.ts
#   apps/server/src/pullRequest/azureDevOpsPullRequestJson.ts, bitbucketPullRequestJson.ts (comment filters, threads)
#   apps/server/src/pullRequest/ForgejoPullRequestProvider.ts, forgejoPullRequestJson.ts (reactions, checks, threads)
#   packages/shared/src/gitPatchPath.ts (file names with control characters in a patch header)
#   https://github.com/pingdotgg/t3code/pull/21988
#   https://github.com/pingdotgg/t3code/pull/22053
#   https://github.com/pingdotgg/t3code/pull/23638
#   https://github.com/pingdotgg/t3code/pull/22374
#   https://github.com/pingdotgg/t3code/pull/25916
#   https://github.com/pingdotgg/t3code/pull/26064
#   https://github.com/pingdotgg/t3code/pull/26177
#   https://github.com/pingdotgg/t3code/pull/26073
#   https://github.com/pingdotgg/t3code/pull/26349
#   https://github.com/pingdotgg/t3code/pull/22382
#   https://github.com/pingdotgg/t3code/pull/23468
#   https://github.com/pingdotgg/t3code/pull/25195
#   https://github.com/pingdotgg/t3code/pull/31741
#   https://github.com/pingdotgg/t3code/pull/30352
#   https://github.com/pingdotgg/t3code/pull/30524
#   https://github.com/pingdotgg/t3code/pull/30397
#   https://github.com/pingdotgg/t3code/pull/30423
#   https://github.com/pingdotgg/t3code/pull/28728
#   https://github.com/pingdotgg/t3code/pull/30549
#   https://github.com/pingdotgg/t3code/pull/30747
#   https://github.com/pingdotgg/t3code/pull/30857
#   https://github.com/pingdotgg/t3code/pull/30717
#   https://github.com/pingdotgg/t3code/pull/23588
#   https://github.com/pingdotgg/t3code/pull/29907
#   https://github.com/pingdotgg/t3code/pull/30704
#   https://github.com/pingdotgg/t3code/pull/29774

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

  # Upstream #20894: replies to a review finding showed as separate cards in Comments and Timeline.
  @backlog @desktop
  Scenario: Replies to a review finding are shown with it
    Given a review finding on pull request 42 has two replies
    When the user reads the conversation of pull request 42
    Then the finding is shown first with its replies after it in order
    And filtering or loading more of the conversation keeps them together

  # Upstream #20894: a resolved finding folds with its replies.
  @backlog @desktop @priority-low
  Scenario: A resolved finding folds with its replies
    Given a resolved review finding on pull request 42 has replies
    When the user reads the conversation of pull request 42
    Then the finding and its replies are folded together
    When the finding is reopened
    Then it unfolds
    But a fold the user chose stays when the conversation refreshes

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

  # Upstream #30704: task lists in a description were read only, even to someone who may edit it.
  @backlog @mc @shared
  Scenario: Ticking a task in a pull request description saves it
    Given the description of pull request 42 has the unchecked task "update the docs"
    And the user may edit pull request 42
    When the user ticks "update the docs"
    Then the description of pull request 42 on the host has it checked
    And a user who may not edit the description sees the task without a way to tick it

  # Upstream #30704: the phone waits for the host's answer before the description can be edited again.
  @backlog @mobile @priority-low
  Scenario: The phone edits a description only once the host has answered the last save
    Given the user ticked a task in the description of pull request 42 on the phone
    Then editing the description waits until the host has answered that save
    And a description read from what the phone kept offline does not count as that answer

  # Upstream #18087: Enter during input method composition does not submit a pull request title.
  @backlog @desktop
  Scenario: Confirming input method text does not save the title
    Given the user is editing the title of pull request 42 with a Japanese input method
    When the user presses Enter to confirm the composed characters
    Then the characters are inserted into the title
    And the title is not saved yet

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
  Scenario Outline: An author cannot decide on their own pull request
    Given pull request 42 is the user's own
    And the user left a comment on line 12 of "src/cart.ts" in pull request 42
    When the user submits the review as <verdict>
    Then the user is told "<refusal>"

    Examples:
      | verdict         | refusal                                                |
      | approve         | You cannot approve your own change request.            |
      | request changes | You cannot request changes on your own change request. |

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

  # Upstream #26349: shift-clicking a file's Viewed mark gives the files between it and the last
  # one marked the same state, in the order they are shown.
  @backlog @desktop
  Scenario Outline: Shift-clicking a Viewed mark marks a run of files
    Given pull request 42 shows "a.ts", "b.ts", "c.ts" and "d.ts" in that order, <start>
    And the user last clicked the Viewed mark of "a.ts"
    When the user shift-clicks the Viewed mark of "d.ts"
    Then "a.ts" to "d.ts" are all <state> and folded to match

    Examples:
      | start             | state      |
      | none viewed       | viewed     |
      | all viewed        | not viewed |

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

  @backlog @mc
  Scenario: Viewed marks kept in the environment belong to one reader
    Given the user marked "src/cart.ts" viewed in a GitLab merge request as "alice"
    When the user signs in to the same host as "bob" and opens that merge request
    Then "src/cart.ts" does not read as viewed
    And "alice" still sees "src/cart.ts" as viewed when they sign in again

  @backlog @mc
  Scenario: Viewed marks kept in the environment belong to one host
    Given the user marked "src/cart.ts" viewed in merge request 5 of "group/project" on gitlab.com
    When the user opens merge request 5 of "group/project" on a self-managed GitLab
    Then "src/cart.ts" does not read as viewed

  @backlog @mc
  Scenario: A host that does not say who the reader is has one reader
    Given a host that does not say who the signed-in user is
    And the user marked "src/cart.ts" viewed in merge request 5
    When the user opens merge request 5 again
    Then "src/cart.ts" reads as viewed

  @backlog @mc
  Scenario: Unmarking a file kept in the environment forgets it
    Given the user marked "src/cart.ts" viewed in a GitLab merge request
    When the user marks "src/cart.ts" not viewed
    Then the environment keeps no mark for "src/cart.ts"
    And the file is not reported as changed after the author pushes to it

  @backlog @mc
  Scenario: Marking a file again replaces the version it was viewed at
    Given the user marked "src/cart.ts" viewed in a GitLab merge request
    And the author pushes a change to "src/cart.ts"
    When the user marks "src/cart.ts" viewed again
    Then the file is no longer reported as changed since it was viewed

  @backlog @mc
  Scenario: A mark made when the host could not give the file's version stays cleared
    Given the host cannot say what version "src/cart.ts" is at
    When the user marks "src/cart.ts" viewed in a GitLab merge request
    Then "src/cart.ts" reads as viewed
    And "src/cart.ts" is not reported as changed when the host later gives a version for it

  @backlog @mc
  Scenario: A file the merge request deletes can be marked viewed once
    Given the merge request deletes "src/legacy.ts"
    When the user marks "src/legacy.ts" viewed
    Then "src/legacy.ts" reads as viewed
    And "src/legacy.ts" is not reported as changed on later reads

  @backlog @mc
  Scenario: Marking several files viewed on GitLab is all or nothing
    Given the user marks "a.ts", "b.ts" and "c.ts" viewed together in a GitLab merge request
    When the environment fails to store the mark for "c.ts"
    Then none of the three files read as viewed

  # Upstream #14954: GitHub can store the first marks of a batch that fails, and the clients kept
  # showing those files unviewed; the marks are read again after the failure.
  @mc @desktop @mobile @backlog-desktop @backlog-mobile
  Scenario: Files a failed batch did mark viewed on GitHub show as viewed
    Given the user marks "a.ts" and "b.ts" viewed together in GitHub pull request 42
    When GitHub stores the mark for "a.ts" and refuses "b.ts"
    Then the user is told the marks could not all be saved
    And "a.ts" reads as viewed and "b.ts" does not, without reopening the pull request

  @mc
  Scenario: A large diff arrives in slices
    Given pull request 42 changes 450 files
    When the user opens its code
    Then the files arrive in slices and every file's line counts are known

  # Upstream #22374: GitLab merge requests showed no added and removed lines.
  @backlog @mc @shared
  Scenario: A GitLab merge request shows its line counts
    Given GitLab merge request 5 adds 12 lines and removes 4 across 3 files
    When the user opens merge request 5
    Then it shows 12 added and 4 removed lines
    And each of the 3 files shows its own added and removed lines

  # Upstream #13835: a turn finishing anywhere in the environment reset the open pull request's
  # code to the top; it now refreshes in the background and keeps the reader's place.
  @backlog @desktop @mobile
  Scenario: The pull request's code keeps its place when a turn finishes
    Given the user is reading the code of pull request 42 halfway down
    When a turn finishes in another thread of the environment
    Then the code of pull request 42 stays where the user was

  # Upstream #22917: a refresh that brought back the same diff emptied the files.
  @backlog @desktop @mobile @priority-high
  Scenario: Refreshing a pull request whose diff did not change keeps its files
    Given the user is reading the code of pull request 42, which changes 12 files
    When pull request 42 is refreshed and its diff is unchanged
    Then the code still shows the 12 files
    And it never says the pull request has no file changes

  @mc
  Scenario: Reviewing the code of one commit
    When the user scopes the code of pull request 42 to one of its commits
    Then only that commit's changes are shown

  @mc
  Scenario: Reading a whole changed file
    When the user expands the unchanged lines around a change in "src/cart.ts"
    Then the file's contents on both sides are shown

  # Upstream #23638: GitHub moves a pull request's base to the base branch's tip, so expanding read
  # the old side from there and the patch no longer matched it.
  @mc
  Scenario: Unchanged lines expand from the merge base after the base branch moved on
    Given main gained lines in "src/cart.ts" after pull request 42 branched from it
    When the user expands the unchanged lines around a change in "src/cart.ts"
    Then the unchanged lines are shown
    And the old side is "src/cart.ts" as it was at the merge base, not at main's tip

  # Upstream #29774: a file renamed in a GitHub, GitLab or Azure DevOps pull request showed as an
  # ordinary change under its new name, and expanding it read the new name at the merge base.
  @mc @desktop @backlog-desktop
  Scenario Outline: A file the pull request renamed on <host> shows as a rename
    Given pull request 42 on <host> renamed "src/cart.ts" to "src/basket.ts" <edited>
    When the user reads the code of pull request 42
    Then "src/basket.ts" is shown as renamed from "src/cart.ts" <shown>
    And expanding its unchanged lines reads the old side from "src/cart.ts"

    Examples:
      | host         | edited               | shown                 |
      | GitHub       | and changed one line | with that line's change |

    @backlog
    Examples: Hosts the MC has no provider for yet
      | host         | edited               | shown                 |
      | GitLab       | without changing it  | with no changes         |
      | Azure DevOps | and changed one line | with that line's change |

  # Upstream #12583: a line comment on expanded context outside the host's hunks made the host
  # reject the whole review; such lines no longer take comments.
  @backlog @mc @desktop @mobile
  Scenario: An expanded line outside the pull request's changes takes no review comment
    Given the user expanded the unchanged lines around a change in "src/cart.ts"
    When the user tries to comment on an expanded line outside the pull request's changes
    Then no comment is anchored there
    And a review with the user's other line comments is still accepted by the host

  # Upstream #12583: a comment on a removed line keeps its side instead of moving to the
  # same-numbered line on the other side.
  @mc @desktop @mobile @backlog-desktop @backlog-mobile @priority-low
  Scenario: A comment on a removed line stays on the removed line
    Given line 12 of "src/cart.ts" was removed in pull request 42 and a different line 12 was added
    When the user comments on the removed line 12 and submits the review
    Then the comment arrives on the removed line

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

  # Legacy: apps/web/src/components/pullRequest/pullRequestFilesViewed.logic.test.ts (shows the press ahead of the host's answer, counts presses included)
  @backlog @desktop
  Scenario: A tick shows at once and counts before the host has answered
    Given the user is reading the code of pull request 42 and the host has answered which files are viewed
    When the user ticks "src/cart.ts" and un-ticks "src/tax.ts"
    Then "src/cart.ts" shows as viewed and "src/tax.ts" as not viewed straight away
    And the viewed count already includes the changes

  # Legacy: apps/web/src/components/pullRequest/pullRequestFilesViewed.logic.test.ts (keeps a press the host cannot have heard yet)
  @backlog @desktop
  Scenario: A tick made while a read is on its way is not put back by that read
    Given the user is reading the code of pull request 42 and a read of the marks is on its way
    When the user un-ticks "src/cart.ts" before the read answers
    And the read answers with "src/cart.ts" still viewed
    Then "src/cart.ts" still shows as not viewed

  # Legacy: apps/web/src/components/pullRequest/pullRequestFilesViewed.logic.test.ts (drops a tick once a read has answered for it)
  @backlog @desktop
  Scenario: A file pushed to after it was ticked reads as changed, not as viewed
    Given the user ticked "src/cart.ts" in pull request 42
    And the author pushed to "src/cart.ts" before the next read of the marks came back
    When the host answers that the viewed mark was dismissed
    Then "src/cart.ts" shows as not viewed and as changed since it was viewed
    And no refresh is needed to see it

  # Legacy: apps/web/src/components/pullRequest/pullRequestFilesViewed.logic.test.ts (toFileViewedBatch, puts the checkbox back for everything the request answers for)
  @backlog @desktop
  Scenario: Ticks and un-ticks go out together and a refusal puts back only those
    Given the user ticked "src/cart.ts" and un-ticked "src/tax.ts" and both went to the host as one request
    And the user ticked "src/api.ts" after that request went out
    When the host refuses the request
    Then "src/cart.ts" and "src/tax.ts" show as the host last said
    And "src/api.ts" still shows as the user left it

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

  @desktop @mobile @backlog-mobile @priority-low
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

  @backlog @desktop
  Scenario: A pull request that was opened from the list appears at once
    Given the user saw pull request 42 in the pull request list
    When the user opens pull request 42
    Then its number, title and state are shown before the rest has been read
    And the rest fills in place

  @backlog @desktop
  Scenario: A pull request read before is shown while it is read again
    Given the user read pull request 42 earlier in this session
    When the user opens pull request 42 again
    Then what was read before is shown while the host is asked again
    And a different pull request's earlier answer is never shown in its place

  # Upstream #27798: a pull request the client already held still opened on a spinner.
  @backlog @shared
  Scenario Outline: A pull request opened from <where> shows what the client holds at once
    Given the client holds pull request 42 of "acme/shop" from an earlier read
    When the user opens it from <where>
    Then its summary is shown at once and refreshed in place
    And a held pull request of another host, repository or number is never shown for it

    Examples:
      | where              |
      | a link in a thread |
      | a thread's card    |
      | a stack card       |
      | a tab              |

  # Upstream #27798: resting on a row reads its detail, so the click opens without a ghost.
  @backlog @desktop @priority-low
  Scenario: Resting on a pull request in the list reads it before the click
    When the pointer or the keyboard focus rests on pull request 42 in the list for 150 ms
    Then pull request 42 is read
    And passing over rows without resting reads nothing
    And a hover card for a listed pull request asks the host nothing

  # Legacy: apps/web/src/components/pullRequest/PullRequestGhosts.tsx (detail ghost seeded from the list entry)
  @backlog @desktop
  Scenario: A pull request opened from the list already shows what the list knew
    Given the list showed pull request 42 by "octocat", updated an hour ago, from "feature/tax" into "main", with 3 files and 12 added and 4 removed lines
    When the user opens pull request 42
    Then before the rest has been read it shows the repository, number, title and author
    And it shows when it was updated, the branches, the file count and the line counts
    And the user can copy the command that checks it out and the branch names
    And the tab the user was on is still the one marked

  # Legacy: apps/web/src/components/pullRequest/PullRequestGhosts.tsx (checks: wait for detail to claim success)
  @backlog @desktop
  Scenario Outline: Checks are not claimed to pass before they have been read
    Given the list showed pull request 42 with its checks <known>
    When the user opens pull request 42 before the rest has been read
    Then the checks are shown as <shown>

    Examples:
      | known                  | shown                      |
      | failing                | failing                    |
      | still running          | still running              |
      | passing                | not yet known              |

  # Legacy: apps/web/src/components/pullRequest/PullRequestGhosts.tsx (Reviewers / Labels rows say None)
  @backlog @desktop
  Scenario: A pull request the list showed with no reviewers or labels says so before the rest is read
    Given the list showed pull request 42 with no reviewers and no labels
    When the user opens pull request 42 before the rest has been read
    Then reviewers says "None"
    And labels says "None"

  # Legacy: apps/web/src/components/pullRequest/PullRequestSummaryTab.test.tsx (toggles checks from their heading)
  @backlog @desktop
  Scenario: Checks start folded in the summary and open from their heading
    Given the user opens pull request 42
    Then the checks are folded
    When the user chooses the heading of the checks
    Then the checks are listed
    When the user chooses it again
    Then they are folded again

  # Legacy: apps/web/src/components/pullRequest/PullRequestSummaryTab.test.tsx (resets sections for another pull request)
  @backlog @desktop
  Scenario: Sections the user folded or opened are put back when another pull request is opened
    Given the user opened the checks of pull request 42 and folded its description
    When the user opens pull request 43
    Then the sections of pull request 43 are in their usual state

  # Legacy: apps/web/src/components/pullRequest/PullRequestSummaryTab.test.tsx (keeps an unsaved description when collapsed and reopened)
  @backlog @desktop
  Scenario: Folding the description does not lose words being written in it
    Given the user is editing the description of pull request 42 and has changed it
    When the user folds the description and opens it again
    Then the unsaved words are still there

  # Legacy: apps/web/src/components/pullRequest/pullRequestSummaryScroll.logic.ts, pullRequestSummaryScroll.logic.test.ts
  @backlog @desktop
  Scenario: Folding a long section keeps its heading where the user was looking
    Given the user has scrolled so that the heading of a long section is pinned at the top
    When the user folds that section
    Then its heading stays where it was and the user is not thrown to another place

  @backlog @desktop
  Scenario: The conversation arrives after the rest
    When the user opens pull request 42
    Then the description and checks are shown before the conversation has been read
    And the conversation is shown as it arrives

  @backlog @desktop
  Scenario: A conversation that cannot be read can be tried again
    Given the host cannot give the conversation of pull request 42
    When the user opens pull request 42
    Then the description is shown and the conversation says it is unavailable with a way to try again

  @backlog @desktop
  Scenario: Reviewers show where each of them landed
    Given "hubot" approved pull request 42, "mona" requested changes and "octo" was asked to review
    When the user opens pull request 42
    Then reviewers lists "hubot", "mona" and "octo"
    And "hubot" is marked as approving and "mona" as requesting changes
    And "octo" has no verdict

  @mc @desktop @backlog-desktop
  Scenario: A team asked to review is a reviewer of its own
    Given the team "acme/core" was asked to review pull request 42 on GitHub
    And a user whose login is "core" approved it
    When the user opens pull request 42
    Then reviewers lists "acme/core" with its name and avatar, and "core" apart from it
    And only "core" is marked as approving
    And the team is listed before the conversation has loaded

  @backlog @desktop
  Scenario: Only a reviewer's last word counts
    Given "hubot" approved pull request 42 and later requested changes
    When the user opens pull request 42
    Then "hubot" is marked as requesting changes

  @backlog @desktop
  Scenario: A dismissed review leaves no verdict
    Given "hubot" approved pull request 42 and the review was dismissed
    When the user opens pull request 42
    Then "hubot" is shown without a verdict

  @backlog @desktop
  Scenario: A verdict given before the last push says it may be out of date
    Given "hubot" approved pull request 42 and the branch has commits made since
    When the user opens pull request 42
    Then "hubot" is marked as having approved earlier code

  @backlog @desktop
  Scenario: Reviews with no author are told apart
    Given two reviews of pull request 42 were written by deleted accounts
    When the user opens pull request 42
    Then each of them is listed as its own reviewer

  @backlog @desktop
  Scenario: A pull request nobody has reviewed says so
    Given pull request 42 has no reviewers and no reviews
    When the user opens pull request 42
    Then reviewers says "None"

  @backlog @desktop
  Scenario: Reviews can only be asked for where the host takes them
    Given the host cannot say who may review
    When the user opens pull request 42
    Then no way to ask for a review is offered

  @backlog @desktop
  Scenario: Asking for a review is disabled with the reason when it is not allowed
    Given the user has only read access to "acme/shop"
    When the user opens pull request 42
    Then asking for a review is shown but cannot be used, and says why

  # Upstream #14785: the reason a review or label change is unavailable can be reached from the keyboard.
  @backlog @desktop @priority-low
  Scenario: The reason a reviewer or label change is unavailable can be reached from the keyboard
    Given the user cannot change reviewers or labels on a pull request
    When the user moves to the disabled control with Tab
    Then the reason it is unavailable is read out and shown

  @backlog @desktop
  Scenario: Labels are shown only where they can mean something
    Given the host has no labels and pull request 42 carries none
    When the user opens pull request 42
    Then no labels row is shown

  @backlog @desktop
  Scenario: A pull request without labels on a host with labels says so
    Given pull request 42 carries no labels
    When the user opens pull request 42
    Then labels says "None"

  @backlog @desktop
  Scenario: An empty description invites one
    Given the user may edit pull request 42 and its description is empty
    When the user opens pull request 42
    Then the description says "Describe this pull request"

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts (splitPullRequestBody, attachmentFromLine)
  @backlog @desktop @priority-low
  Scenario Outline: A video linked on a line of its own plays where it was written
    Given the description of pull request 42 has <video> on a line of its own between two paragraphs
    When the user reads the description
    Then the video plays between the two paragraphs
    And both paragraphs are still shown

    Examples:
      | video                                                                    |
      | https://github.com/user-attachments/assets/1a1842fb-6383-492f-873c-57aa0033fa6c |
      | https://example.com/demo.mp4?raw=1                                       |
      | https://example.com/demo.webm                                            |
      | https://example.com/clip.mov                                             |
      | a video tag naming https://example.com/demo.mp4 across several lines     |

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.test.ts (leaves ordinary links alone, keeps dropped images, leaves inline tags, refuses non-web sources)
  @backlog @desktop @priority-low
  Scenario Outline: Only a video on a line of its own is played, everything else reads as written
    Given a comment on pull request 42 has <written>
    When the user reads the comment
    Then <shown>

    Examples:
      | written                                                     | shown                                              |
      | a link to https://example.com/page on a line of its own     | it stays a link and no video plays                 |
      | a dropped image on a line of its own                        | it is shown as an image and no video plays         |
      | a video tag in the middle of a sentence                     | the sentence is shown as written and no video plays |
      | a video tag that is never closed, then more words           | the words after it are still shown and no video plays |
      | a video tag whose source is not a web address               | no video plays                                     |

  # Upstream #25988: a video on its own line inside an HTML table was lifted out of its cell, so
  # GitHub's usual before/after layout came out stacked at full width with the header row alone.
  @backlog @desktop @mobile @priority-low
  Scenario: Before and after videos laid out in a table stay side by side
    Given the description of pull request 42 has a table headed "Before" and "After"
    And each of its cells holds a video uploaded to GitHub on a line of its own
    When the user reads the description
    Then the table keeps its header row above two equal columns
    And each video plays in its own cell

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.test.ts (never lifts a video out of code)
  @backlog @desktop @priority-low
  Scenario Outline: A video link inside code is shown as code, not played
    Given a comment on pull request 42 has a video link inside <code>
    When the user reads the comment
    Then the link is shown as part of the code
    And no video plays

    Examples:
      | code                                  |
      | a fence of backticks                  |
      | a fence of tildes                     |
      | text indented by four spaces          |
      | a fence that names a language         |

    # Upstream #30352: a description written in GitHub's web editor has CRLF line endings, and its
    # fences were not seen, so the block was cut around a video player.
    Examples:
      | code                                          |
      | a fence written with CRLF line endings        |

  # Upstream #31741: GitCafe writes uploaded screenshots as links to its own site's root, and every
  # one showed "Image unavailable".
  @backlog @desktop @mobile @priority-low
  Scenario: A GitCafe attachment in a description is shown from GitCafe
    Given a GitCafe pull request whose description has an image at "/api/attachments/attach_1"
    When the user reads the description
    Then the image is shown from the GitCafe site of the repository
    And it is not looked for as a file on the user's machine

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdown.tsx (GitHubVideo), apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts (GITHUB_ASSET_PATTERN)
  @backlog @desktop @priority-low
  Scenario: A video that GitHub hosts plays through a link the MC signs
    Given the description of pull request 42 has a video uploaded to GitHub on a line of its own
    When the user reads the description
    Then the video plays from a link the MC signed for the user's host

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdown.tsx (GitHubVideo)
  @backlog @desktop @priority-low
  Scenario: A GitHub video still plays when the MC cannot sign it
    Given the MC cannot sign GitHub media
    And the description of pull request 42 has a video uploaded to GitHub on a line of its own
    When the user reads the description
    Then the video plays from the plain address the description holds

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdown.tsx (GitHubVideo onRetry, originalUrl)
  @backlog @desktop @priority-low
  Scenario: A GitHub video that stopped playing can be retried or opened where it lives
    Given a GitHub video in the description of pull request 42 stopped playing
    When the user retries it
    Then the MC signs a fresh link and the video plays from it
    When the user asks for the original
    Then the address the description holds is opened

  # Upstream #22110: links a bot wrote as HTML in a comment could not be followed on the phone.
  @backlog @desktop @mobile
  Scenario Outline: A link written as HTML in a comment can be followed only when it is a web or mail address
    Given a comment on pull request 42 holds an HTML anchor "Preview" to "<address>"
    When the user reads the comment
    Then "Preview" <outcome>

    Examples:
      | address                       | outcome                             |
      | https://preview.example.dev   | opens "https://preview.example.dev" |
      | mailto:ops@example.com        | opens a mail to "ops@example.com"   |
      | javascript:alert(1)           | is plain text                       |

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts (remarkPullRequestAutolinks)
  @backlog @desktop
  Scenario: A number in a description or comment links to that issue or pull request
    Given the description of pull request 42 says "Fixes #12 and follows #7"
    When the user reads the description
    Then "#12" links to issue 12 of the repository and "#7" to issue 7
    And the words around them are unchanged

  # Upstream #30524: GitLab references were plain text; they now link in GitLab's own grammar.
  @backlog @desktop @mobile @priority-low
  Scenario Outline: A GitLab reference in a description or comment links where GitLab would
    Given a GitLab merge request of "acme/shop" whose description says "<written>"
    When the user reads the description
    Then "<written>" <outcome>

    Examples:
      | written          | outcome                                        |
      | #12              | links to issue 12 of "acme/shop"               |
      | !5               | links to merge request 5 of "acme/shop"        |
      | api!9            | links to merge request 9 of "acme/api"         |
      | group/sub/lib#2  | links to issue 2 of "group/sub/lib"            |
      | 1a2b3c4d5e6f     | links to that commit and reads "1a2b3c4"       |
      | @tobias          | links to the page of "tobias"                  |
      | @all             | is plain text                                  |

  # Upstream #30524: a merge request reference opens in the app with its preview.
  @backlog @desktop @priority-low
  Scenario: A GitLab merge request reference opens in the app
    Given a GitLab merge request whose description says "Follows !5"
    When the user follows "!5"
    Then merge request 5 opens in the app with its preview

  # Upstream #26060: a description written on GitHub ran its lines together, since one newline was not a break.
  @backlog @desktop @mobile
  Scenario Outline: A single newline in a description breaks the line where its host does
    Given the description of a pull request on <host> has two lines separated by one newline
    When the user reads the description
    Then the two lines are shown <shown>

    Examples:
      | host         | shown                         |
      | GitHub       | on separate lines             |
      | Forgejo      | on separate lines             |
      | Azure DevOps | on separate lines             |
      | GitLab       | run together in one paragraph |
      | Bitbucket    | run together in one paragraph |

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts (remarkPullRequestAutolinks)
  @backlog @desktop
  Scenario: A full commit hash links to the commit and is shown shortened
    Given a comment on pull request 42 says "Reverted in 0123456789abcdef0123456789abcdef01234567"
    When the user reads the comment
    Then the hash is shown as its first seven characters
    And it links to that commit in the repository

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts (remarkPullRequestAutolinks, AUTOLINK_IGNORED_TYPES)
  @backlog @desktop
  Scenario Outline: A number that is part of something else is not turned into a link
    Given a comment on pull request 42 has <written>
    When the user reads the comment
    Then no link to the repository is made from it

    Examples:
      | written                                              |
      | "abc#12" in a word                                   |
      | "#12abc" running into a word                         |
      | "#0" or "#012"                                       |
      | "#12" inside a link the author wrote                 |
      | "#12" inside code                                    |

    # Upstream #26177: a reference glued to a preceding "." or "-" no longer links.
    Examples:
      | written                                              |
      | "foo.#12" glued to a period                          |
      | "foo-#12" glued to a hyphen                          |

  # Upstream #26177: long runs of "." or ".-" made reference linking quadratic, and anyone could
  # freeze the client with a comment on a public repository.
  @backlog @desktop @mobile
  Scenario: A comment with a long run of periods opens at once and still links its references
    Given a comment on pull request 42 has 50,000 periods, then 50,000 ".-" pairs, then "#1"
    When the user reads the comment
    Then the comment is shown at once
    And "#1" links to issue 1 of the repository
      | a hash that is shorter or longer than a full commit  |
      | a commit hash glued to a word                        |

  @backlog @desktop
  Scenario Outline: A description or comment that could not be saved says so
    Given the host refuses to save <what> of pull request 42
    When the user tries to save <what>
    Then the user sees an "error" toast "<toast>"
    And the words the user wrote are kept

    Examples:
      | what            | toast                          |
      | the description | Could not save the description |
      | a comment       | Could not save the comment     |
      | the title       | The title could not be saved   |

  @backlog @desktop
  Scenario: A title that could not be saved gives the host's reason
    Given the host refuses the new title of pull request 42 saying "Titles cannot be empty."
    When the user tries to save a new title
    Then the user sees an "error" toast "The title could not be saved"
    And the toast says "Titles cannot be empty."

  # Legacy: apps/web/src/components/pullRequest/pullRequestEditing.logic.test.ts (canEditPullRequestChangeRequest)
  @backlog @desktop
  Scenario Outline: Who is offered the title and description to rewrite
    Given pull request 42 was opened by "octocat" on a host that can rewrite change requests
    And the reader is <reader>
    When the user opens pull request 42
    Then its title and description <result>

    Examples:
      | reader                                                     | result              |
      | "octocat"                                                  | can be edited       |
      | "OctoCat", the same login spelled with other capitals      | can be edited       |
      | "hubot", who may merge it                                  | can be edited       |
      | "hubot", who may close it but not merge it                 | cannot be edited    |
      | someone the host could not name, who may merge it          | can be edited       |
      | someone the host could not name, who may not merge it      | cannot be edited    |

  # Legacy: apps/web/src/components/pullRequest/pullRequestEditing.logic.test.ts (canEditPullRequestComment)
  @backlog @desktop
  Scenario Outline: Which comments are offered to the reader to rewrite
    Given the reader is "octocat" on a host that can rewrite comments
    And pull request 42 holds <comment>
    When the user opens pull request 42
    Then the comment <result>

    Examples:
      | comment                                          | result              |
      | a comment by "octocat"                           | can be edited       |
      | a remark on a line by "octocat"                  | can be edited       |
      | a comment by "OCTOCAT"                           | can be edited       |
      | a comment by "hubot"                             | cannot be edited    |
      | a comment the host attributes to nobody          | cannot be edited    |
      | the summary a review came with, by "octocat"     | cannot be edited    |

  # The host's own answer replaces the guess from authorship and merge access, but never
  # widens what the host can do at all. Resolve can only be narrowed per conversation.
  @backlog @desktop
  Scenario Outline: A host that says per item what the reader may do is believed
    Given the reader is "octocat" on a host that can rewrite comments and resolve conversations
    And the host says of <item> that the reader <answer>
    When the user opens pull request 42
    Then <item> <result>

    Examples:
      | item                                  | answer            | result                     |
      | a comment by "hubot"                  | may edit it       | can be edited              |
      | a comment by "octocat"                | may not edit it   | cannot be edited           |
      | the description of pull request 42    | may edit it       | can be edited              |
      | an unresolved conversation            | may not resolve it | is not offered to resolve |

  @backlog @desktop
  Scenario: A host's per-conversation answer cannot widen who may resolve
    Given the reader may not resolve conversations on pull request 42's repository
    And the host says of an unresolved conversation that the reader may resolve it
    When the user opens pull request 42
    Then the conversation is not offered to resolve

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdownEditor.tsx (Write/Preview)
  @backlog @desktop
  Scenario: Words being written can be previewed as they will read
    Given the user is editing the description of pull request 42
    When the user switches to the preview
    Then the words are shown as they will read, with their formatting
    When the user switches back to writing
    Then the words are still there to change

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdownEditor.tsx ("Nothing to preview.")
  @backlog @desktop
  Scenario: Previewing nothing says so
    Given the user is editing a comment on pull request 42 and has written nothing
    When the user switches to the preview
    Then it says "Nothing to preview."

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdownEditor.tsx (Mod+Enter saves, Escape cancels)
  @backlog @desktop
  Scenario Outline: Words being edited are saved or abandoned from the keyboard
    Given the user is editing the description of pull request 42 and has changed it
    When the user presses <keys>
    Then <result>

    Examples:
      | keys           | result                                       |
      | Ctrl+Enter     | the change is saved                          |
      | Cmd+Enter      | the change is saved                          |
      | Escape         | the editing ends and the old words are kept  |

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdownEditor.tsx (saving state, keyboard repeat)
  @backlog @desktop
  Scenario: Nothing can be cancelled or saved twice while a save is under way
    Given the user saved an edit of the description of pull request 42 and the host has not answered
    Then the save control says "Saving..."
    When the user presses Escape or holds Ctrl+Enter
    Then nothing is cancelled and the change is saved only once

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdownEditor.tsx (allowEmpty)
  @backlog @desktop
  Scenario Outline: A description may be cleared but a comment may not
    Given the user is editing <what> of pull request 42
    When the user clears the words
    Then saving <result>

    Examples:
      | what            | result               |
      | the description | is offered           |
      | a comment       | is not offered       |

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdownEditor.tsx (draft reseeds)
  @backlog @desktop
  Scenario: Words being edited are replaced when the saved words change underneath
    Given the user is editing the description of pull request 42
    When the description changes on the host and the user's client reads it
    Then the editor holds the description as the host now has it

  # Legacy: apps/web/src/components/pullRequest/PullRequestReactions.tsx, pullRequestReactions.logic.ts (order)
  @backlog @desktop @priority-low
  Scenario: Reactions are listed in one fixed order, only those given
    Given the description of pull request 42 has a rocket, a thumbs-up and a heart
    When the user reads the description
    Then the reactions are listed as thumbs-up, heart, rocket
    And each shows how many people gave it

  # Legacy: apps/web/src/components/pullRequest/pullRequestReactions.logic.ts (reactionTooltip)
  @backlog @desktop @priority-low
  Scenario Outline: A reaction says who gave it
    Given <who> gave a heart to a comment on pull request 42
    When the user looks at the heart
    Then it says "<says>"

    Examples:
      | who                                                   | says                                         |
      | "octocat"                                             | octocat reacted with heart emoji             |
      | "octocat" and "hubot"                                 | octocat and hubot reacted with heart emoji   |
      | "octocat", "hubot" and "mona"                         | octocat, hubot, and mona reacted with heart emoji |
      | "octocat", "hubot", "mona", "linus" and "ada"         | octocat, hubot, mona, and 2 others reacted with heart emoji |
      | the user and "octocat"                                | You and octocat reacted with heart emoji     |

  # Legacy: apps/web/src/components/pullRequest/pullRequestReactions.logic.ts (reactors named only when fewer than the count)
  @backlog @desktop @priority-low
  Scenario: A reaction by people the host did not name still counts them
    Given 12 people gave a heart to a comment on pull request 42 and the host named only some of them
    When the user looks at the heart
    Then it counts 12
    And it names the people it knows and says how many others there are

  # Legacy: apps/web/src/components/pullRequest/PullRequestReactions.tsx (optimistic, pending dropped)
  @backlog @desktop
  Scenario: Reacting shows at once and is replaced by what the host reports
    Given the user may react to a comment on pull request 42
    When the user gives a heart and the host has not answered
    Then the heart shows as the user's with the count raised by one
    When the host's count of hearts changes
    Then the count shown is the host's

  # Legacy: apps/web/src/components/pullRequest/PullRequestReactions.tsx (error toast)
  @backlog @desktop @priority-low
  Scenario: A reaction that could not be saved is taken back and says so
    Given the host refuses the reaction
    When the user gives a heart to a comment on pull request 42
    Then the user sees an "error" toast "The reaction could not be saved"
    And the heart is not the user's

  # Legacy: apps/web/src/components/pullRequest/PullRequestReactions.tsx (cannot react)
  @backlog @desktop @priority-low
  Scenario Outline: Where the user cannot react the reactions are only shown
    Given the user cannot react to a comment on pull request 42 and it has <reactions>
    When the user looks at the comment
    Then <result>

    Examples:
      | reactions       | result                                               |
      | 2 hearts        | the hearts are shown but cannot be pressed           |
      | no reactions    | no reactions are shown and none can be added         |

  # Legacy: apps/web/src/components/pullRequest/PullRequestReactions.tsx (picker, subjectId)
  @backlog @desktop @priority-low
  Scenario: A reaction can be added to the description or to one comment
    Given the user may react on pull request 42
    When the user adds a rocket to the description
    And the user adds a rocket to one comment
    Then the description and that comment each show one rocket from the user
    And no other comment does

  # Upstream #22090: the count read backwards as progress; it is now finished out of total, with
  # skipped, failed and cancelled checks counted as finished.
  @backlog @desktop
  Scenario: Checks as one line
    Given 16 checks of pull request 42 where 7 run, 1 failed and 2 were skipped
    When the user reads the checks of pull request 42
    Then they are summarised as "9 of 16 finished · 1 failed"

  # Upstream #23548: the sidebar read 29 of 30 finished while the detail still showed three
  # running, since each read the checks its own way and kept whichever answer came last.
  @backlog @desktop @mobile
  Scenario: The sidebar and the pull request's detail agree on its checks
    Given a thread links pull request 42, whose checks have just finished
    When the user opens pull request 42's detail from the thread
    Then the detail and the sidebar count the same finished checks
    And an older answer that arrives later does not bring back checks that had finished

  @backlog @desktop
  Scenario Outline: A summary of the checks is said in words
    Given pull request 42 has <checks>
    When the user reads the checks of pull request 42
    Then they are summarised as "<summary>"

    Examples:
      | checks                            | summary                          |
      | no checks                         | No checks reported               |
      | 5 checks that all passed          | All checks passed                |
      | 5 checks of which 3 passed, 2 skipped or neutral | 3 of 5 passing   |
      | 4 checks of which 1 awaits action | 1 of 4 awaiting action           |
      | 3 checks of which 2 failed        | 2 of 3 failing                   |

  @backlog @desktop
  Scenario: Failing outranks running
    Given pull request 42 has checks of which one failed and others still run
    When the user reads the checks of pull request 42
    Then the checks are reported as failing

  @backlog @desktop
  Scenario: A cancelled check counts as failed
    Given a check of pull request 42 was cancelled
    When the user reads the checks of pull request 42
    Then the checks are reported as failing

  # Upstream #12274: failed checks are listed first.
  @backlog @desktop
  Scenario: Checks that need attention come first
    Given pull request 42 has passing, failing, running and cancelled checks
    When the user opens the checks of pull request 42
    Then the failing, cancelled and action-required checks come first, then the running ones
    And the completed ones are folded behind "Show all"

  @backlog @desktop
  Scenario: Completed checks can be shown and folded again
    Given pull request 42 has passing checks
    When the user chooses "Show all" in the checks of pull request 42
    Then the completed checks are listed
    And the choice reads "Show less"

  @backlog @desktop
  Scenario: A check opens on the host
    Given a check of pull request 42 has a details page
    When the user opens the details of the check
    Then the browser opens the check's page

  # Upstream #18434: Forgejo and Gitea give a check's link as a path, resolved against the pull request's address.
  @backlog @mc @desktop
  Scenario: A Forgejo or Gitea check opens though the host names it by path
    Given pull request 42 is on a Forgejo server and a check's details page is given as "/acme/shop/actions/runs/12/jobs/37"
    When the user opens the details of the check
    Then the browser opens that page on the Forgejo server

  @backlog @desktop
  Scenario: A check page that cannot be opened says so
    Given a check of pull request 42 has a details page and the browser cannot be opened
    When the user opens the details of the check
    Then the user sees an "error" toast "Unable to open check details"

  @backlog @desktop
  Scenario: Checks are read when they are asked for
    Given pull request 42 is shown in the list with its checks not yet read
    When the user opens the checks of pull request 42 from the list
    Then "Loading checks…" is shown until they arrive
    And "No checks reported" is shown if there are none

  @backlog @desktop
  Scenario: Checks that may be out of date say so
    Given the checks of pull request 42 were read before the last push
    When the user opens pull request 42
    Then the checks say "Check details are out of date."
    And the checks can be refreshed

  @backlog @desktop
  Scenario: Stale checks are not handed to an agent
    Given the checks of pull request 42 are out of date and one of them failed
    When the user chooses to fix the findings from its review
    Then the failing check is not quoted in the request

  @backlog @desktop
  Scenario: The conversation can be read newest or oldest first
    Given pull request 42 has 5 comments
    When the user opens pull request 42
    Then the conversation reads "Comments (5)" with the newest comment first
    When the user chooses to read the oldest first
    Then the oldest comment comes first

  @backlog @desktop
  Scenario: A long conversation is read ten comments at a time
    Given pull request 42 has 35 comments
    When the user opens pull request 42
    Then the 10 most recent comments are shown with "Show 10 older comments (25 hidden)"
    When the user chooses to show older comments
    Then 10 more comments are shown
    And the conversation offers "Show only 10 recent comments"

  # Upstream #17645 replaced the folded bot group with a filter whose choice is remembered.
  @backlog @desktop @priority-low
  Scenario: Bot comments are hidden until the user shows them
    Given pull request 42 has comments by people and 3 comments by bots
    When the user opens pull request 42
    Then the people's comments are listed
    And the conversation says "3 hidden"
    When the user chooses to show bot comments
    Then the bots' comments join the people's in time order

  # Upstream #30418: GitLab author names were plain text.
  # Upstream #30411: GitLab comments had no link back to their note.
  @backlog @mc @shared @priority-low
  Scenario Outline: A GitLab merge request links <what> to GitLab
    Given a merge request on the GitLab at "https://git.acme.dev:8443"
    When the user reads it
    Then <what> links to <where>

    Examples:
      | what                                   | where                                         |
      | each author's name, a bot's included   | their profile on "https://git.acme.dev:8443"  |
      | each comment's time                    | that comment on the merge request's own page  |

  # Upstream #30383: GitLab's bot accounts were never hidden by the filter.
  @backlog @mc @priority-low
  Scenario: Comments by GitLab bot accounts are hidden with the bot comments
    Given a GitLab merge request has comments by a person and by a project access token bot
    And bot comments are hidden
    When the user opens the merge request
    Then only the person's comment is listed
    And a person whose name ends in "bot" is not taken for a bot

  # Upstream #25829: a bot's approval was hidden with the other bot comments.
  @backlog @desktop @mobile
  Scenario: A bot's approval or request for changes is shown with bot comments hidden
    Given the bot "macroscope" approved pull request 42 and another bot requested changes
    And bot comments are hidden
    When the user opens pull request 42
    Then both reviews are listed
    And the bots' other comments stay hidden

  # Upstream #25829: a reviewer's verdict was only a ring of colour around their picture.
  @backlog @desktop @mobile @priority-low
  Scenario: Each reviewer shows their verdict by shape, not only colour
    Given "macroscope" approved pull request 42 and "sam" requested changes
    When the user looks at the reviewers of pull request 42
    Then "macroscope" is marked with a check and "sam" with a cross

  @backlog @desktop @priority-low
  Scenario: Shown bot comments are read in pages with the rest
    Given pull request 42 has 5 comments by people and 25 comments by bots
    And the user shows bot comments
    When the user opens pull request 42
    Then the 10 most recent comments of either kind are shown with "Show 10 older comments (20 hidden)"

  @backlog @desktop @priority-low
  Scenario: The comment filter carries across pull requests
    Given the user showed bot comments on pull request 42
    When the user opens pull request 43
    Then pull request 43 shows its bot comments too

  @backlog @desktop @priority-low
  Scenario: A filter that hides every comment says so
    Given pull request 42 has only comments by bots
    When the user opens pull request 42
    Then the conversation says every comment is hidden by the filter

  # Legacy: apps/web/src/components/pullRequest/pullRequestDetail.logic.test.ts (drops a body that is nothing but a bot's HTML comment)
  @backlog @desktop @priority-low
  Scenario: A comment that is only a bot's hidden marker shows no words
    Given a bot commented on pull request 42 with only an HTML comment
    When the user opens the timeline of pull request 42
    Then that comment is listed without any words

  # Legacy: apps/web/src/components/pullRequest/pullRequestDetail.logic.test.ts (keeps one that says more)
  @backlog @desktop @priority-low
  Scenario: A bot's hidden marker is not shown above the words it came with
    Given a bot commented on pull request 42 with an HTML comment followed by "Needs a test."
    When the user opens the timeline of pull request 42
    Then the comment reads "Needs a test."
    And no marker is shown

  # Legacy: apps/web/src/components/pullRequest/pullRequestDetail.logic.test.ts (calls a comment markdown and a commit headline plain text)
  @backlog @desktop
  Scenario: A commit headline is read as written, a comment as formatted text
    Given a commit of pull request 42 is headed "fix: drop *legacy* path"
    And a comment says "this is *important*"
    When the user opens the timeline of pull request 42
    Then the headline shows its asterisks and is not emphasised
    And the comment shows "important" emphasised

  @backlog @desktop @priority-low
  Scenario: Finished conversations are hidden until the user shows them
    Given pull request 42 has 2 resolved review threads and a dismissed review
    When the user opens pull request 42
    Then they are not listed and the conversation says "3 hidden"
    When the user chooses to show resolved or dismissed comments
    Then they join the conversation in time order, each folded
    And each says "Resolved" or "Review dismissed" when opened

  @backlog @desktop
  Scenario: A pull request nobody has commented on says so
    Given pull request 42 has no comments
    When the user opens pull request 42
    Then the conversation says "No comments yet."

  @backlog @desktop
  Scenario: A conversation cut short says so
    Given pull request 42 has more comments than the page reads in one go
    When the user opens pull request 42
    Then the user is told the most recent comments are here and the rest can be read on the host

  @backlog @desktop
  Scenario: A review that only decides has no empty body
    Given "hubot" approved pull request 42 without a summary
    When the user opens pull request 42
    Then the approval is shown as a verdict without a comment body

  @backlog @desktop
  Scenario: A remark in a review can be handed to an agent
    Given a review of pull request 42 remarked "Handle the empty cart"
    When the user opens pull request 42
    Then that remark offers "Fix in a thread"
    But an approval or a remark with no words does not

  # Upstream #23468: Azure DevOps wrote a file comment's path with a leading slash, so it named no
  # file in the diff and "Fix in a thread" pointed the agent at a root path.
  @backlog @mc @desktop
  Scenario Outline: An Azure DevOps file comment names the path the diff shows
    Given an Azure DevOps comment on pull request 42 is pinned to the path "<azure path>"
    When the user opens pull request 42
    Then the comment is <shown>

    Examples:
      | azure path  | shown                                         |
      | /src/app.ts | pinned to "src/app.ts", as the diff names it  |
      | /           | a general comment, not pinned to a file       |

  @backlog @desktop
  Scenario: The timeline lists what happened to the pull request
    Given pull request 42 was opened, received 2 commits and a comment, and was merged
    When the user opens the timeline of pull request 42
    Then it lists the merge, the comment, the commits and the opening, newest first

  # Upstream #23588: the timeline ordered events by the text of their times.
  @backlog @desktop
  Scenario: The timeline orders events by when they happened, however the host wrote the time
    Given pull request 42 was commented on at "2026-07-05T00:30:00Z"
    And it received a commit at "2026-07-05T01:00:00+02:00"
    When the user opens the timeline of pull request 42
    Then the comment is listed before the commit

  @backlog @desktop
  Scenario: The timeline can be read oldest first
    Given the user is reading the timeline of pull request 42
    Then the timeline says "Newest first"
    When the user asks to show the oldest activity first
    Then the timeline lists the opening first
    And the timeline says "Oldest first"

  @backlog @desktop
  Scenario: A merged pull request is not also reported as closed
    Given the host reports pull request 42 as both merged and closed
    When the user opens the timeline of pull request 42
    Then the timeline says "Pull request merged"
    And it does not say "Pull request closed"

  @backlog @desktop
  Scenario: Comments between commits fold into conversations
    Given pull request 42 has 3 comments by 2 people between two commits
    When the user opens the timeline of pull request 42
    Then the 3 comments are one entry reading "3 comments" and "2 authors"
    And the commits stay entries of their own on either side of it
    When the user opens that entry
    Then each of the 3 comments is read in full

  @backlog @desktop
  Scenario: A verdict in the timeline is not folded into a conversation
    Given "hubot" approved pull request 42 in the middle of a conversation
    When the user opens the timeline of pull request 42
    Then the approval is an entry of its own naming "hubot" and "approved"
    And the conversation is split around it

  # Upstream #23138: the phone's timeline read Bitbucket's and GitCafe's lowercase verdicts as comments.
  @backlog @desktop @mobile
  Scenario Outline: A verdict reads the same in the timeline whichever host spelled it
    Given pull request 42 is on <host>, which reports a review of "hubot" as "<state>"
    When the user opens the timeline of pull request 42
    Then the entry for "hubot" reads <verdict>, as the overview of pull request 42 does

    Examples:
      | host      | state             | verdict           |
      | GitHub    | APPROVED          | approved          |
      | Bitbucket | approved          | approved          |
      | GitCafe   | changes_requested | changes requested |
      | GitCafe   | commented         | commented         |

  # Upstream #29567: Forgejo and Gitea keep a dismissed review's original state and set dismissed,
  # which was ignored, so a dismissed verdict still read as active.
  @backlog @mc @desktop @mobile @priority-low
  Scenario Outline: A dismissed Forgejo review no longer counts as its verdict
    Given a <verdict> review of pull request 42 on Forgejo was dismissed
    When the user opens pull request 42
    Then the review reads as dismissed
    And pull request 42 is not reported as <status> because of it

    Examples:
      | verdict         | status            |
      | request changes | changes requested |
      | approval        | approved          |

  @backlog @desktop
  Scenario: A verdict's words stay visible in the timeline
    Given "mona" requested changes on pull request 42 saying "Handle the empty cart"
    When the user opens the timeline of pull request 42
    Then the entry for "mona" shows "Handle the empty cart" without being opened

  @backlog @desktop
  Scenario: A verdict that the later commits overtook is shown as overtaken in the timeline
    Given "hubot" approved pull request 42 before its latest commit
    When the user opens the timeline of pull request 42
    Then the approval is shown muted
    And its explanation says it was given before the latest commits

  @backlog @desktop
  Scenario: A commit in the timeline opens the code of that commit
    Given pull request 42 has the commit "a1b2c3d" "Handle empty carts" adding 12 lines and removing 3
    When the user opens the timeline of pull request 42
    Then the commit is listed with its headline, "a1b2c3d", when it was made and "+12 -3"
    When the user opens that commit
    Then the code of pull request 42 is scoped to that commit

  @backlog @desktop @priority-low
  Scenario: A commit with no headline is called untitled
    Given pull request 42 has a commit whose message has no headline
    When the user opens the timeline of pull request 42
    Then that commit is listed as "Untitled commit"

  @backlog @desktop
  Scenario: A commit the host gave no line counts for shows none
    Given the host gave no line counts for a commit of pull request 42
    When the user opens the timeline of pull request 42
    Then that commit is listed without line counts

  @backlog @desktop
  Scenario: A commit shows who authored it
    Given a commit of pull request 42 was authored by "octocat" and "hubot"
    When the user opens the timeline of pull request 42
    Then that commit is shown with its authors

  @backlog @desktop
  Scenario: An entry of the timeline can be opened on the host
    Given a comment on pull request 42 has a page of its own on the host
    When the user opens the timeline of pull request 42
    Then that comment offers to open its activity on the host
    And the opening and a commit, which have no such page, do not

  @backlog @desktop
  Scenario: A comment is edited from the timeline
    Given the user wrote a comment on pull request 42
    When the user opens the timeline of pull request 42
    And the user opens that conversation
    And the user edits their comment and saves it
    Then the comment reads as edited in the timeline

  @backlog @desktop
  Scenario: The timeline counts what it lists
    Given pull request 42 has 3 comments, 2 commits and 1 approval
    When the user opens the timeline of pull request 42
    Then its header counts 3 comments, 2 commits and 1 approval

  @backlog @desktop
  Scenario: The timeline counts are unavailable when the conversation cannot be read
    Given the host cannot give the conversation of pull request 42
    When the user opens the timeline of pull request 42
    Then the header says the comments and the commits are unavailable
    And no count is shown for either

  @backlog @desktop
  Scenario: The timeline counts are not shown while the conversation is being read
    Given the conversation of pull request 42 has not arrived yet
    When the user opens the timeline of pull request 42
    Then the header's counts are shown as pending until it arrives

  @backlog @desktop
  Scenario: One composer comments and reviews
    Given the user may comment on and approve pull request 42
    When the user opens the composer
    Then it offers to comment and to review
    And it opens on commenting when no review has been started

  @backlog @desktop
  Scenario: The composer opens on the review once one has been started
    Given the user left a line comment on pull request 42 that is still pending
    When the user opens the composer
    Then it opens on the review
    And the review says "1" pending comment

  @backlog @desktop
  Scenario: The composer offers only what the user may do
    Given the user may not comment on pull request 42 but may approve it
    When the user opens the composer
    Then it offers only the review

  @backlog @desktop
  Scenario: A pull request nobody may act on has no composer
    Given the user may neither comment on nor decide pull request 42
    When the user opens pull request 42
    Then no composer is offered

  @backlog @desktop
  Scenario: Posting a comment from the composer
    When the user comments "Looks good" from the composer of pull request 42
    Then the composer closes
    And "Looks good" appears in the conversation of pull request 42

  @backlog @desktop
  Scenario: Posting a comment with the keyboard
    Given the user wrote "Looks good" in the composer of pull request 42
    When the user presses the send shortcut of the platform
    Then the comment is posted once
    And holding the keys down does not post it again

  # Upstream #30747: typing "@" in a pull request composer suggests the repository's people.
  @backlog @desktop @mobile
  Scenario: A pull request composer completes a mention
    Given "tobias" may be mentioned in "acme/shop"
    When the user types "Thanks @to" in a comment on pull request 42
    Then "tobias" is suggested
    When the user picks "tobias"
    Then the comment reads "Thanks @tobias "

  # Upstream #30747: the suggestions open only where a mention can start, and close without closing
  # the composer.
  @backlog @desktop @mobile
  Scenario Outline: Where a pull request composer suggests people
    When the user types "<text>" in a comment on pull request 42
    Then <outcome>

    Examples:
      | text          | outcome                       |
      | @             | the repository's people are suggested |
      | see @to       | people matching "to" are suggested    |
      | mail me@to    | no one is suggested                   |

  # Upstream #30747: closing the suggestions leaves the comment being written.
  @backlog @desktop
  Scenario: Dismissing mention suggestions keeps the composer open
    Given people are suggested for "@to" in a comment on pull request 42
    When the user presses Escape
    Then the suggestions close
    And the comment still reads "@to" with the composer open

  # Upstream #30747: GitLab searches no one for fewer than three characters, so short queries narrow
  # the full list instead.
  @backlog @mc @priority-low
  Scenario: A short mention on GitLab still finds people
    Given a GitLab project with the member "tobias"
    When the user types "@to" in a comment on one of its merge requests
    Then "tobias" is suggested

  # Upstream #30857: "#" completes the repository's issues and pull requests, "!" GitLab's merge
  # requests.
  @backlog @desktop @mobile
  Scenario Outline: A pull request composer completes a reference
    Given <host> project "acme/shop" has <item>, updated recently
    When the user types "<typed>" in a comment on one of its change requests
    Then <item> is suggested
    When the user picks it
    Then the comment reads "<inserted> "

    Examples:
      | host     | item                                   | typed       | inserted |
      | a GitHub | issue 123 "Tax rounding"               | see #12     | see #123 |
      | a GitHub | pull request 140 "Tax fix"             | see #tax    | see #140 |
      | a GitLab | merge request 123 "Tax rounding"       | see !12     | see !123 |

  # Upstream #30857: an exact number comes first, then numbers that start with it, then titles.
  @backlog @mc
  Scenario: Reference suggestions put the exact number first
    Given "acme/shop" has issue 12, pull request 120 and issue 5 titled "Fix 12 regressions"
    When the user types "#12" in a comment on pull request 42
    Then issue 12 is suggested first, then pull request 120, then issue 5

  # Upstream #30857: hosts that cannot search references suggest none.
  @backlog @mc @priority-low
  Scenario: A host that cannot search references suggests none
    Given a Forgejo project
    When the user types "#12" in a comment on one of its pull requests
    Then nothing is suggested
    And "#12" stays as typed

  @backlog @desktop @priority-high
  Scenario: A comment that could not be posted keeps its words
    Given the host refuses comments on pull request 42
    When the user comments "Looks good" from the composer of pull request 42
    Then the user sees an "error" toast "Could not post the comment"
    And the composer still holds "Looks good"

  @backlog @desktop
  Scenario Outline: Sending a review says what was sent
    Given the user wrote a summary for pull request 42
    When the user submits the review as <verdict>
    Then the user sees a "success" toast "<toast>"
    And the composer closes

    Examples:
      | verdict         | toast                 |
      | comment         | Review submitted      |
      | approve         | Pull request approved |
      | request changes | Changes requested     |

  @backlog @desktop @priority-high
  Scenario: A review that could not be sent keeps its draft
    Given the host refuses reviews on pull request 42
    And the user wrote a summary and a line comment for pull request 42
    When the user submits the review
    Then the user sees an "error" toast "The review could not be submitted"
    And the summary and the line comment are still held

  # Upstream #22382: the toast for a refused review gave no reason; it now carries the host's own,
  # cut to 320 characters, or a hint when the host gives nothing readable.
  @backlog @desktop
  Scenario: A refused review says why the host refused it
    Given GitHub refuses reviews on pull request 42 saying "Review cannot be requested from pull request author"
    When the user submits the review
    Then the user sees an "error" toast "The review could not be submitted"
    And the toast says "Review cannot be requested from pull request author"

  @backlog @desktop
  Scenario: A review is sent once
    Given the user submitted the review of pull request 42
    When the user presses submit again while the host is still answering
    Then no second review is sent
    And the verdict cannot be changed until it answers

  @backlog @desktop
  Scenario: Remarks added while a review is sent wait for the next one
    Given the user submitted the review of pull request 42 with one line comment
    When the user adds another line comment before the host answers
    Then the next review holds only the second line comment

  @backlog @desktop
  Scenario: A review is held per pull request
    Given the user wrote a review summary for pull request 42
    When the user opens pull request 43
    Then the summary is not shown there
    When the user opens pull request 42 again
    Then the summary is back

  # Legacy: apps/web/src/components/pullRequest/pullRequestReviewStore.test.ts (keeps drafts on different hosts separate)
  @backlog @desktop
  Scenario: A review is held per host as well as per number
    Given the user wrote a review summary and a line comment for pull request 7 of "owner/repo" on "github.com"
    When the user opens pull request 7 of "owner/repo" on "github.example.com"
    Then neither the summary nor the line comment is shown there
    When the user sends or discards the review there
    Then the review of "github.com" is still held

  # Legacy: apps/web/src/components/pullRequest/pullRequestReviewStore.test.ts (does not clear a summary revised while submission is in flight)
  @backlog @desktop
  Scenario: A summary revised while the review is being sent is kept
    Given the user sent the review of pull request 42 with the summary "Submitted body"
    When the user changes the summary to "Revised body" before the host answers
    And the host accepts the review
    Then the summary reads "Revised body"

  @backlog @desktop
  Scenario: Only the verdicts the user may give are offered
    Given the user may comment and approve pull request 42 but not request changes
    When the user opens the review in the composer
    Then the verdicts offered are comment and approve

  @backlog @desktop
  Scenario: An approval needs no words
    Given the user wrote nothing for pull request 42
    When the user opens the review in the composer
    Then submitting as a comment is not possible
    And submitting as an approval is

  @backlog @desktop @mobile @priority-low
  Scenario Outline: The review summary says it is optional only when it is
    Given the user is reviewing pull request 42 as <verdict> with <comments>
    Then the empty summary reads "<placeholder>"

    Examples:
      | verdict  | comments            | placeholder                                  |
      | approve  | no line comments    | Summary (optional)                           |
      | comment  | one line comment    | Summary (optional)                           |
      | comment  | no line comments    | Summarize your review or add line comments   |

  @backlog @desktop @mobile @priority-low
  Scenario: A single verdict is not offered as a choice
    Given pull request 42 is the user's own on GitHub, so comment is the only verdict
    When the user opens the review in the composer
    Then no verdict picker is shown

  @backlog @desktop
  Scenario: A line comment alone is a review
    Given the user left a line comment on pull request 42 and wrote no summary
    When the user opens the review in the composer
    Then the review can be submitted as a comment

  # Upstream #18455 brought this to the phone's review sheet.
  @backlog @desktop @mobile @priority-low
  Scenario: Forgejo asks for a summary when requesting changes
    Given the open Forgejo pull request 7
    And the user left a line comment on it and wrote no summary
    When the user opens the review in the composer
    Then the summary asks to be written "to request changes"
    And requesting changes is not possible until a summary is written

  @backlog @desktop
  Scenario: Pending line comments can be discarded together
    Given the user left 3 line comments on pull request 42 that are still pending
    When the user discards the pending line comments
    Then the review holds no line comments

  @backlog @desktop
  Scenario: A pending line comment says it is not sent yet
    Given the user left a line comment on line 12 of "src/cart.ts"
    When the user reads the diff of pull request 42
    Then the comment is shown on line 12 as pending until the review is submitted
    And it can be discarded on its own

  @backlog @desktop
  Scenario: A line comment is added to the review or handed to an agent
    Given the user selected line 12 of "src/cart.ts" in the diff of pull request 42
    When the user writes "Handle empty carts" in the line comment
    Then the line comment offers to be added to the review
    And it offers to be handed to an agent

  # Upstream #19701: selecting lines no longer depends on the host letting the user comment.
  @backlog @desktop
  Scenario: Lines of a pull request the user cannot comment on can still be handed to an agent
    Given the host does not let the user comment on lines of pull request 42
    When the user selects line 12 of "src/cart.ts" in the diff of pull request 42
    And the user writes "Handle empty carts" in the line comment
    Then the line comment offers to be handed to an agent
    And it does not offer to be added to the review
    When the user hands it to an agent
    Then the agent's composer holds the comment and line 12 of "src/cart.ts"
    And nothing is sent to the host

  @backlog @desktop
  Scenario: A line comment is cancelled
    Given the user began a line comment on line 12 of "src/cart.ts"
    When the user cancels it
    Then no comment is left on line 12 and the selected lines are cleared

  @backlog @desktop
  Scenario: A line comment is begun from the line or from a selection
    Given the user may comment on lines of pull request 42
    When the user presses the comment button beside line 12 of "src/cart.ts"
    Then a line comment is begun on line 12
    When the user instead drags over lines 12 to 15
    Then a line comment is begun on those lines

  @backlog @desktop
  Scenario: One line comment is begun at a time
    Given the user began a line comment on line 12 of "src/cart.ts"
    When the user looks for another line to comment on
    Then no second line comment can be begun until the first is added or cancelled

  @backlog @desktop
  Scenario: A line comment is not offered where the user may not comment
    Given the user may not comment on lines of pull request 42
    When the user reads the diff of pull request 42
    Then no line can be selected for a comment

  # Upstream #18463: Forgejo's details left out the head commit a line comment is tied to,
  # so tapping a line on a Forgejo or Gitea pull request did nothing.
  @backlog @mc @priority-low
  Scenario: A Forgejo pull request takes line comments on its latest commit
    Given the open Forgejo pull request 7 whose latest commit is "abc1234"
    When a client reads the details of pull request 7
    Then they name "abc1234" as its head commit
    And a line comment the user leaves on it is tied to "abc1234"

  @backlog @desktop
  Scenario: A whitespace-ignoring diff drops a comment in progress
    Given the user began a line comment on line 12 of "src/cart.ts"
    When the user hides whitespace changes
    Then the line comment in progress is dropped and the selection cleared

  # Upstream #16162: hiding whitespace hides lines, not counts, as on GitHub.
  @backlog @desktop @priority-low
  Scenario: Hiding whitespace changes keeps each file's line counts
    Given "src/cart.ts" in pull request 42 has +115 −63, some of it only re-indented
    When the user hides whitespace changes
    Then the re-indented lines are hidden
    And "src/cart.ts" still reads +115 −63, matching the pull request's total

  @backlog @desktop
  Scenario: A review conversation is open until resolved
    Given pull request 42 has an unresolved conversation of 3 comments and a resolved one of 1
    When the user reads the diff of pull request 42
    Then the open one is expanded saying "Open · 3 comments"
    And the resolved one is a single line saying "Resolved · 1 comment" until it is opened

  @backlog @desktop
  Scenario: A conversation on code that has changed says it is outdated
    Given a conversation on pull request 42 refers to code that has since changed
    When the user reads the diff of pull request 42
    Then the conversation says "outdated"

  @backlog @desktop
  Scenario: A long review conversation is read a page at a time
    Given a conversation on pull request 42 has more comments than its card carries
    When the user opens that conversation in the diff
    Then it offers "Load more comments"
    When the user loads more
    Then the next comments are added after the ones shown
    And what was loaded is kept while the pull request is refreshed

  @backlog @desktop
  Scenario: Loading more comments of a conversation can fail
    Given the host cannot give more comments of a conversation on pull request 42
    When the user loads more comments
    Then the user sees an "error" toast "More comments could not be loaded"
    And the comments shown stay

  @backlog @desktop
  Scenario: A reply is written under the conversation
    Given the user may reply to conversations on pull request 42
    When the user chooses to reply and writes "Fixed" and sends it
    Then the reply is added to the conversation
    And the reply box is closed and empty

  @backlog @desktop @priority-high
  Scenario: A reply that could not be posted keeps its words
    Given the host refuses replies on pull request 42
    When the user replies "Fixed" to a conversation
    Then the user sees an "error" toast "Reply could not be posted"
    And the reply box still holds "Fixed"

  @backlog @desktop
  Scenario: Replying can be cancelled or sent from the keyboard
    Given the user began a reply to a conversation of pull request 42
    When the user presses the send shortcut of the platform
    Then the reply is sent
    When the user begins another reply and presses Escape
    Then the reply box closes without sending anything

  @backlog @desktop
  Scenario: A conversation cannot be replied to where the user may not
    Given the user may not reply to conversations on pull request 42
    When the user reads the diff of pull request 42
    Then the conversations offer no reply

  @backlog @desktop
  Scenario: A conversation that could not be resolved says so
    Given the host refuses to change the state of a conversation on pull request 42
    When the user resolves it
    Then the user sees an "error" toast "The conversation could not be updated"
    And the conversation stays open

  @backlog @desktop
  Scenario: A comment in a conversation can be edited by its author
    Given the user wrote a comment in a conversation on pull request 42
    When the user edits it and saves
    Then the conversation shows the new words
    And comments by others offer no edit

  @backlog @desktop
  Scenario: A comment in a conversation that could not be saved keeps the editor open
    Given the host refuses the edit of a comment in a conversation on pull request 42
    When the user edits it and saves
    Then the user sees an "error" toast "The comment could not be saved"
    And the editor is still open with the new words

  @backlog @desktop
  Scenario: Only one conversation change is in flight
    Given the user is resolving a conversation on pull request 42
    When the user replies to another conversation before it finishes
    Then the second change is not started

  @backlog @desktop
  Scenario: Conversations that are not on the diff are listed apart
    Given 2 conversations of pull request 42 sit on lines the diff does not show
    When the user reads the diff of pull request 42
    Then "Conversations not on the current diff" lists them with a count of 2
    And they are closed until opened
    And a conversation with several comments on one file is listed under that file once

  # Upstream #30425: GitLab comments on a whole file or on an image never became conversations.
  @backlog @mc @shared @priority-low
  Scenario Outline: A GitLab comment on <target> is a conversation
    Given a GitLab merge request has an unresolved comment on <target> of "src/cart.ts"
    When the user reads the merge request
    Then the comment is listed apart as a conversation on "src/cart.ts" that can be replied to and resolved
    And it counts as an unresolved finding

    Examples:
      | target       |
      | a whole file |
      | an image     |

  @backlog @desktop
  Scenario: Conversations are not on the diff loaded so far while it is still arriving
    Given the diff of pull request 42 has more files to arrive
    And a conversation sits on a file that has not arrived
    When the user reads the diff
    Then the list of conversations says "Conversations not on the diff loaded so far"

  @backlog @desktop
  Scenario: Conversations are listed while one commit is read
    Given the code of pull request 42 is scoped to one commit
    When the user reads the diff
    Then no conversation is shown on a line
    And every conversation is listed apart

  @backlog @desktop
  Scenario: A commit's diff cannot take line comments
    Given the code of pull request 42 is scoped to one commit
    When the user reads the diff
    Then no line can be selected for a comment
    And the diff explains that a comment is anchored to the whole change and offers "All commits"

  @backlog @desktop
  Scenario: The scope falls back to the whole change when its commit leaves
    Given the code of pull request 42 is scoped to a commit
    When the author force-pushes and the commit is no longer part of the change
    And the user refreshes pull request 42
    Then the code is scoped to all commits again

  # Upstream #25916: the Code tab still asked for the diff of a commit the pull request dropped.
  @backlog @desktop @mobile
  Scenario: A commit the pull request dropped is not asked for
    Given the code of pull request 42 is scoped to a commit
    When the author force-pushes and the commit is no longer part of the change
    Then the scope reads "All commits"
    And the diff of the dropped commit is not asked for

  @backlog @desktop
  Scenario: A change with no commits cannot stay scoped to one
    Given the code of pull request 42 is scoped to a commit
    When the host reports no commits for pull request 42
    Then the code is scoped to all commits

  @backlog @desktop
  Scenario: Commits are offered ten at a time
    Given pull request 42 has 25 commits
    When the user opens the scope of its code
    Then "All commits" and the 10 most recent commits are offered, each with its headline and short id
    And "Show more (15 left)" offers the next ten

  @backlog @desktop
  Scenario: The scope is offered only where there are commits to choose
    Given the host reports no commits for pull request 42
    When the user reads its code
    Then no scope is offered

  @backlog @desktop
  Scenario: A pull request with no file changes says so
    Given pull request 42 changes no files
    When the user reads its code
    Then the code says "This pull request has no file changes."

  @backlog @desktop
  Scenario: A commit with no file changes says so
    Given the code of pull request 42 is scoped to a commit that changes no files
    When the user reads its code
    Then the code says "This commit has no file changes."
    And the scope can still be changed

  @backlog @desktop
  Scenario: A diff that cannot be read says why
    Given the host cannot give the diff of pull request 42
    When the user reads its code
    Then the code says why the diff cannot be read
    And the scope can still be changed

  # Upstream #19945: a pull request diff that fails to load says why in plain words.
  @backlog @desktop
  Scenario Outline: A pull request diff that fails to load explains the failure
    Given the host <failure> when the user opens a pull request's code
    Then the code says <explanation>
    And it offers "Try again" and opening the pull request on the host
    And the technical details stay folded until the user opens them

    Examples:
      | failure                  | explanation                                    |
      | rate limits the request  | the host is limiting requests and to try later |
      | fails for another reason | the changes could not be loaded                |

  @backlog @desktop
  Scenario: A page of files that fails after others arrived keeps the files
    Given 100 files of pull request 42 arrived and the next page failed
    When the user reads its code
    Then the 100 files stay shown
    And the end of them says "The rest of this diff could not be loaded."
    And "Retry" asks for the next page again

  @backlog @desktop
  Scenario: A diff arriving in pages counts the files so far
    Given the diff of pull request 42 has more files to arrive
    When the user reads its code
    Then the files are counted as "100+ files"
    And the next page is asked for as the user reaches the end of the files, saying "Loading more files..."
    And the count has no "+" once every file has arrived

  @backlog @desktop
  Scenario: A diff the viewer cannot structure is shown as text
    Given the host gave a patch for pull request 42 that cannot be read as file changes
    When the user reads its code
    Then the patch is shown as plain text with the reason beside it
    And the rest of the change that could be read stays above it

  @backlog @desktop
  Scenario: A diff with withheld content says part of it was not shown
    Given the host withheld part of the diff of pull request 42, such as a binary file or a change too large
    When the user reads its code
    Then the code warns "Some of this diff was not shown"
    And says the host withheld part of it

  @backlog @desktop
  Scenario: A file the host withheld keeps the line counts the host reported
    Given the host withheld the changes of "dist/bundle.js" but reported 500 added and 20 removed lines
    When the user reads the diff of pull request 42
    Then "dist/bundle.js" is listed with "+500 -20"
    And it is not drawn as an empty change

  # Legacy: packages/shared/src/gitPatchPath.ts (quoteGitPatchPath, unquoteGitPatchPath)
  # Likely already implemented: apps/server-ex/lib/hal_c2/pull_requests/github.ex (quote_path)
  @backlog @desktop @priority-high
  Scenario: A changed file whose name holds a tab, a quote or a newline keeps its own name
    Given pull request 42 changes a file whose name contains a tab, a double quote and a newline
    When the user reads its code
    Then the file is listed under that exact name
    And its changes are not attached to a shorter name or to a second, made-up file

  @backlog @desktop
  Scenario: Files are read source first
    Given pull request 42 changes "src/cart.ts", "src/cart.test.ts" and "pnpm-lock.yaml"
    When the user reads the diff of pull request 42
    Then "src/cart.ts" comes first
    And "src/cart.test.ts" follows it
    And "pnpm-lock.yaml" comes last

  @backlog @desktop
  Scenario: Source files are read after the files they import
    Given "src/checkout.ts" imports "src/cart.ts" and both are changed by pull request 42
    When the user reads the diff of pull request 42
    Then "src/cart.ts" comes before "src/checkout.ts"

  # Legacy: apps/web/src/components/pullRequest/pullRequestFileOrder.logic.test.ts (follows a chain the whole way down, cycles)
  @backlog @desktop
  Scenario: A chain of imports is read from its far end, and files that import each other by path
    Given "src/a.ts" imports "src/b.ts", which imports "src/c.ts", and all are changed by pull request 42
    And "src/x.ts" and "src/y.ts" import each other and are changed too
    When the user reads the diff of pull request 42
    Then "src/c.ts" comes before "src/b.ts" and "src/b.ts" before "src/a.ts"
    And "src/x.ts" and "src/y.ts" are read in the order of their paths

  # Legacy: apps/web/src/components/pullRequest/pullRequestFileOrder.logic.test.ts (resolves a specifier ...)
  @backlog @desktop
  Scenario Outline: An import is followed however it is written
    Given "src/ui/page.ts" imports <written> and the changed file it names is "<file>"
    When the user reads the diff of pull request 42
    Then "<file>" comes before "src/ui/page.ts"

    Examples:
      | written                    | file                 |
      | "../lib/cart"              | src/lib/cart.ts      |
      | "../lib"                   | src/lib/index.ts     |
      | "../lib/cart.js"           | src/lib/cart.ts      |
      | require("../lib/cart")     | src/lib/cart.ts      |
      | an import that names nothing, of "../lib/cart" | src/lib/cart.ts |

  # Legacy: apps/web/src/components/pullRequest/pullRequestFileOrder.logic.test.ts (ambiguous last segment)
  @backlog @desktop
  Scenario: An import that could mean two files is not guessed at
    Given "src/ui/page.ts" imports "cart" and two changed files are named "cart.ts" in different folders
    When the user reads the diff of pull request 42
    Then neither "cart.ts" is read first because of that import

  # Legacy: apps/web/src/components/pullRequest/pullRequestFileOrder.logic.test.ts (keeps the tiers apart, orders tests by the source they cover)
  @backlog @desktop
  Scenario: A test is read after the source it covers, and a test with no source after those that have one
    Given pull request 42 changes "src/cart.ts", "src/cart.test.ts", "src/tax.ts", "src/tax.test.ts" and "src/orphan.test.ts"
    When the user reads the diff of pull request 42
    Then the source files are read first
    And "src/cart.test.ts" and "src/tax.test.ts" follow, in the order of the sources they cover
    And "src/orphan.test.ts" comes after them

  # Upstream #23129: a test named after a source with a dot in its name, like
  # "cart.logic.test.ts", never found its source and sorted last.
  @backlog @desktop @priority-low
  Scenario: A test of a source with a dotted name is read after that source
    Given pull request 42 changes "src/a.logic.ts", "src/b.ts", "src/c.tsx", "src/a.logic.test.ts", "src/b.test.ts" and "src/c.browser.test.tsx"
    When the user reads the diff of pull request 42
    Then the tests are read as "src/a.logic.test.ts", "src/b.test.ts", "src/c.browser.test.tsx"

  # Legacy: apps/web/src/components/pullRequest/pullRequestFileOrder.logic.test.ts (orders the same diff the same way whatever order it arrives in)
  @backlog @desktop
  Scenario: The order of the files does not depend on the order the host sent them in
    Given the host sends the files of pull request 42 in two different orders on two reads
    When the user reads the diff each time
    Then the files are read in the same order both times

  @backlog @desktop
  Scenario Outline: Generated and test files are told apart by their names
    Given pull request 42 changes "<path>"
    When the user reads the diff of pull request 42
    Then "<path>" is read <place> the source files

    Examples:
      | path                          | place  |
      | src/__snapshots__/cart.snap   | after  |
      | dist/index.js                 | after  |
      | assets/app.min.js             | after  |
      | src/api.generated.ts          | after  |
      | go.sum                        | after  |
      | tests/cart.ts                 | after  |
      | src/cart.spec.ts              | after  |

  @backlog @desktop
  Scenario: A viewed count names where the marks are kept
    Given pull request 42 changes 4 files and the user marked 3 viewed
    When the user reads its code
    Then the code says "3 / 4 viewed"

  @backlog @desktop
  Scenario: A viewed count says the marks are kept by HAL-C2 on hosts without their own
    Given a GitLab merge request that changes 4 files and the user marked 3 viewed
    When the user reads its code
    Then the code says "3 / 4 viewed in HAL-C2"
    And its explanation says the host keeps no record and the marks follow the user between connected apps
    And that the host's own web UI will not show them

  @backlog @desktop
  Scenario: Marks that could not be read say so
    Given the host cannot give the viewed marks of pull request 42
    When the user reads its code
    Then the code warns "Your ticks could not be read"
    And the boxes show what was last read, empty if nothing was
    And the host's reason is given

  @backlog @desktop
  Scenario: A viewed count that covers only part of the change says so
    Given pull request 42 changes more files than the host reports marks for in one read
    When the user reads its code
    Then the code warns "This count covers only part of the change"
    And some boxes start empty

  @backlog @desktop
  Scenario: A viewed count is not shown for a change with no files
    Given pull request 42 changes no files
    When the user reads its code
    Then no viewed count is shown

  @backlog @desktop
  Scenario: Refreshing the pull request reads the code and the marks again
    Given the user is reading the code of pull request 42
    When the user refreshes pull request 42
    Then the diff starts again from its first page
    And the viewed marks are read again, so a push since the last read flags a viewed file as changed

  @backlog @desktop
  Scenario: Files can all be collapsed or expanded
    Given the user is reading the code of pull request 42 with several files
    When the user collapses all files
    Then every file is folded to its header
    And the control offers to expand all files

  # Legacy: apps/web/src/components/pullRequest/pullRequestDiff.logic.test.ts (keeps a file the reader folded closed as the next slice arrives)
  @backlog @desktop
  Scenario: A file the reader folded stays folded while more files arrive
    Given the user is reading the code of pull request 42 and more files are still to arrive
    And the user folded "src/cart.ts"
    When the next files arrive
    Then "src/cart.ts" is still folded
    And the files that arrived are open

  @backlog @desktop
  Scenario: The file tree lists only the files that arrived
    Given the diff of pull request 42 has more files to arrive
    When the user opens the file tree
    Then it lists the files that arrived
    And it offers "Load more files" to bring the rest in

  # Upstream #18133: a file and a folder at the same path crashed the file tree; both are listed
  # and each opens its own diff.
  @backlog @desktop
  Scenario: A file replaced by a folder of the same name can be read
    Given pull request 42 deletes the file "office" and adds "office/config.ts"
    When the user reads the code of pull request 42
    Then the file tree lists both "office" and "office/config.ts"
    And choosing either shows its own diff

  @backlog @desktop
  Scenario: The file tree remembers whether it was open
    Given the user opened the file tree while reading the code of a pull request
    When the user reads the code of another pull request
    Then the file tree is open
  # Upstream #26730: the diff listed test files after all source while the tree kept them in their folders.
  @backlog @desktop @mobile
  Scenario: A pull request's diff lists its files in the file tree's order
    Given pull request 42 changes "src/cart.ts", "src/cart.test.ts" and "lib/tax.ts"
    When the user reads the code of pull request 42
    Then the diff shows the files in the same order as the file tree
    And "src/cart.test.ts" is shown with the other files of "src"

  # Upstream #26730: test files can be hidden from a pull request's diff and its tree.
  @backlog @desktop
  Scenario: Hiding test files from a pull request's diff
    Given pull request 42 changes "src/cart.ts", "src/cart.test.ts" and "fixtures/cart.json"
    When the user hides test files while reading its code
    Then only "src/cart.ts" is in the diff and the file tree
    And the user is told 2 test files are hidden

  # Upstream #26730: the count of hidden test files is the way back.
  @backlog @desktop
  Scenario: The count of hidden test files shows them again
    Given the user hid test files while reading the code of pull request 42
    When the user chooses "2 test files hidden"
    Then the test files are in the diff and the file tree again

  # Upstream #26730: hiding test files is one remembered choice for pull request diffs and thread diffs.
  @backlog @desktop
  Scenario: Hidden test files stay hidden in the next diff the user reads
    Given the user hid test files while reading the code of pull request 42
    When the user opens the diff of a thread's changes, or the code of another pull request
    Then test files are hidden there too

  # Upstream #26730: a file asked for by a link stays visible with test files hidden.
  @backlog @desktop
  Scenario: A test file a link points to is shown while test files are hidden
    Given the user hid test files
    When the user follows a link to the diff of "src/cart.test.ts" in pull request 42
    Then the diff of "src/cart.test.ts" is shown


  # Upstream #18126 gives the phone the code, file diffs and line comments as well; see
  # "The review page" and the scenarios after it, which carry @mobile.
  @dropped @mobile
  Scenario: The phone reviews without the code
    When the user opens pull request 42 on the phone
    Then the conversation and checks are shown without the diff

  # Upstream #18347. Badges that bots stamp into a description (review buttons, shields,
  # QR codes) are not attachments. Inline in the description and comments they still show.
  @backlog @mobile @priority-low
  Scenario Outline: Bot badges are left out of a pull request's attachments
    Given the description of pull request 42 has a screenshot and an image from <bot>
    When the user opens pull request 42 on the phone
    Then its attachments show only the screenshot
    And the description still shows both images where they were written

    Examples:
      | bot                                     |
      | static.devin.ai/assets/                 |
      | cursor.com/assets/images/               |
      | img.shields.io/                         |
      | storage.googleapis.com/coderabbit_public_assets/ |

  @backlog @mobile @priority-low
  Scenario: A screenshot uploaded to a bot's service is still an attachment
    Given the description of pull request 42 has an image from "cursor.com/artifacts/"
    When the user opens pull request 42 on the phone
    Then its attachments show that image

  # Upstream #23466: an image written as "![shot](https://)" replaced the whole pull request with
  # an error screen.
  @backlog @mobile
  Scenario: A pull request with a broken image address stays readable
    Given the description of pull request 42 has a screenshot and an image whose address is "https://"
    When the user opens pull request 42 on the phone
    Then the description is shown
    And its attachments show only the screenshot

  @mc
  Scenario: Images in a private pull request are fetched by the MC
    Given the description of pull request 42 holds an image uploaded to GitHub
    When the user reads the description
    Then the MC fetches the image with its GitHub credentials
    And the client never receives the GitHub token

  # Upstream #21631: media uploaded in a pull request of another repository than the checkout
  # never loaded.
  # Upstream #21632: neither did media in a pull request of an organization enforcing SAML single
  # sign-on.
  @mc
  Scenario Outline: Images and videos in a pull request <where> are shown
    Given the description of pull request 42 <where> holds an image and a video uploaded to GitHub
    When the user reads the description
    Then the image and the video are shown, fetched in the pull request's own repository
    And the client never receives the GitHub token

    Examples:
      | where                                                    |
      | of a repository other than the thread's checkout         |
      | of an organization that asks for single sign-on to media |

  @mc
  Scenario Outline: A host that cannot do part of a review refuses it
    Given an open change request on <host>
    When the user tries to <request>
    Then the user is told "<message>"

    Examples:
      | host         | request                 | message                                                |
      | Azure DevOps | post a comment          | This host cannot post a comment on a change request.   |
      | Azure DevOps | comment on a line       | This host cannot comment on a line of a change request. |
      | Azure DevOps | reply to a conversation | This host cannot reply to a review conversation.       |
      | Azure DevOps | resolve a conversation  | This host cannot resolve a review conversation.        |
      | Azure DevOps | approve                 | This host cannot approve a change request.             |
      | Azure DevOps | react to a comment      | This host has no reactions.                            |
      | Bitbucket    | react to a comment      | This host has no reactions.                            |
      | Forgejo      | reply to a conversation | This host cannot reply to a review conversation.       |
      | Forgejo      | resolve a conversation  | This host cannot resolve a review conversation.        |

  @mc
  Scenario: A reader may comment and decide on a pull request they did not open
    Given the user has only read access to "acme/shop"
    When the user looks at what they may do on pull request 42
    Then commenting, approving and requesting changes are offered

  @mc
  Scenario: A reader who neither wrote nor opened the pull request cannot resolve a conversation
    Given the user has only read access to "acme/shop"
    And an unresolved review thread
    When the user resolves it
    Then the user is told "You need write access on this repository, or to have opened this change request, to resolve a review conversation."

  @mc
  Scenario: The author may resolve a conversation with read access only
    Given pull request 42 is the user's own
    And the user has only read access to "acme/shop"
    And an unresolved review thread
    When the user resolves it
    Then the thread is resolved

  @mc
  Scenario: A reply cannot be empty
    Given a review thread on line 12 of "src/cart.ts"
    When the user replies with only spaces
    Then the user is told "A reply cannot be empty."

  @mc
  Scenario Outline: Something that belongs to another pull request is refused
    Given a comment that belongs to pull request 7
    When the user tries to <request> as part of pull request 42
    Then the user is told "The named subject did not belong to the named pull request."

    Examples:
      | request                       |
      | react to it                   |
      | edit it                       |
      | load more replies of its thread |

  @mc
  Scenario Outline: A very long conversation is cut short and says so
    Given a pull request on <host> whose conversation runs to more than ten full pages
    When the user opens its conversation
    Then the pages read so far are shown
    And the conversation says it was cut short

    Examples:
      | host      |
      | GitHub    |

    @backlog
    Examples: Hosts the MC has no provider for yet
      | host      |
      | GitLab    |
      | Bitbucket |

  @mc
  Scenario: A dismissed review says why it was dismissed
    Given a review on pull request 42 that was dismissed with the reason "Superseded by the rewrite"
    When the user opens the conversation of pull request 42
    Then the review is shown as dismissed with that reason

  @mc
  Scenario: A pull request with more than five hundred files reports its viewed marks as cut short
    Given pull request 42 changes 650 files
    When the user reads which files they have viewed
    Then the marks of the first 500 files are returned
    And the answer says it was cut short

  @backlog @mc
  Scenario: A viewed mark survives a host that cannot report file versions
    Given the user marked "src/cart.ts" viewed in a GitLab merge request
    And GitLab cannot say which version of "src/cart.ts" the head has
    When the user reads which files they have viewed
    Then "src/cart.ts" is still viewed
    And reading the marks does not fail

  @backlog @mc
  Scenario: A file that changed again is flagged where marks are kept in the environment
    Given the user marked "src/cart.ts" viewed in a GitLab merge request
    When the author pushes a change to "src/cart.ts"
    Then the file is reported as changed since it was viewed

  @backlog @mc
  Scenario: A run of viewed marks reads the host's file versions once
    Given a Bitbucket pull request that changes 40 files
    When the user marks 12 files viewed one after another
    Then the host is asked for the pull request's patch once for the whole run

  @backlog @mc
  Scenario: A viewed mark cannot be saved while the environment's record is unreachable
    Given the environment cannot reach its record of viewed files
    When the user marks "src/cart.ts" viewed in a GitLab merge request
    Then the user is told "This environment could not reach its record of which files you have seen."

  @mc
  Scenario: A diff position the pull request never handed out is refused
    When a client asks for the diff of pull request 42 from a position it was not given
    Then the user is told "The diff cursor was not one this pull request handed out."

  @mc
  Scenario: A commit that is not a commit id is refused
    When a client asks for the code of pull request 42 at the commit "../main"
    Then the user is told "The named commit was not a commit sha."

  @mc
  Scenario: A page of changes that was cut off is a failure, not a short diff
    Given the host's answer for one page of the changed files of pull request 42 is cut off part-way
    When the user opens its code
    Then the read fails
    And the diff is not shown as complete

  @mc
  Scenario: A file whose changes the host withheld is listed with its line counts
    Given the host withholds the changes of "db/seed.sql" in pull request 42 because they are too large
    When the user opens its code
    Then "db/seed.sql" is listed with its added and removed line counts and no changes

  @mc
  Scenario Outline: A changed file that cannot be expanded says why
    Given <situation>
    When the user expands the unchanged lines around a change in "<path>"
    Then the user is told "<message>"

    Examples:
      | situation                                                    | path         | message                                                       |
      | "db/seed.sql" is larger than one megabyte                    | db/seed.sql  | The diff file 'db/seed.sql' exceeds the 1 MB expansion limit. |
      | "logo.png" is a binary file                                  | logo.png     | The diff file 'logo.png' is binary.                           |
      | the host reports no usable base and head for pull request 42 | src/cart.ts  | Pull request #42 reported no usable base and head revisions.  |

  @mc
  Scenario: A file added by a root commit expands without an old side
    Given the commit being reviewed is the first commit of the repository and adds "README.md"
    When the user expands the unchanged lines of "README.md"
    Then the file's contents are shown without asking for a parent version

  # Upstream #20440: only files the pull request, or the selected commit, changes can be expanded.
  @mc
  Scenario: A file the pull request does not change cannot be expanded
    Given pull request 42 does not change "config/secrets.yml"
    When a client asks for the contents of "config/secrets.yml" as a file of pull request 42
    Then it is told the file was not found

  @backlog @mc @priority-low
  Scenario: A large Azure DevOps change arrives in slices bounded by size and effort
    Given an Azure DevOps pull request whose change is larger than one slice may carry
    When the user opens its code
    Then each slice stops at its size and effort ceiling
    And the next slice carries on from where the last one stopped

  @backlog @mc @priority-low
  Scenario: A file too heavy to compare is listed without its changes on Azure DevOps
    Given an Azure DevOps pull request changes a file too large to compare
    When the user opens its code
    Then the file is listed in its place without its changes
    And the other files are shown with theirs

  @backlog @mc @priority-low
  Scenario: Azure DevOps being unreachable fails the diff instead of hiding every file
    Given the connection to Azure DevOps fails while its code is being read
    When the user opens the code of an Azure DevOps pull request
    Then the read fails
    And the files are not listed as unreadable one by one

  @backlog @mc @priority-low
  Scenario: A file Azure DevOps will not hand over keeps its place in the list
    Given Azure DevOps refuses to hand over the contents of one changed file
    When the user opens the code of the pull request
    Then that file is listed in its place without its changes

  @backlog @mc
  Scenario: Re-reading the checks of an unchanged pull request spends no rate limit
    Given the checks of pull request 42 on GitHub were read a moment ago
    And nothing about pull request 42 has changed since
    When the user reads the checks again
    Then GitHub answers that nothing changed and the earlier checks are returned

  @mc
  Scenario: Checks are read in full where the host does not support conditional reads
    Given a GitHub host that does not support conditional reads of check results
    When the user reads the checks of pull request 42
    Then the checks are read in full each time

  @mc
  Scenario: A re-run of a check replaces the earlier run where it stood
    Given a check "build" ran twice on pull request 42 and the second run is newer
    When the user reads the checks of pull request 42
    Then "build" is listed once with the state of the newer run
    And it stays at the position of the first run

  # Upstream #24406: a cancelled GitCafe run kept the pull request failing after its rerun passed.
  @backlog @mc @priority-low
  Scenario: A passing re-run on GitCafe clears the failure it replaced
    Given the check "build" of a GitCafe pull request failed and its re-run passed
    And another app's check also named "build" failed
    When the user reads the pull request's checks
    Then the first app's "build" is listed once as passing
    And the other app's "build" is still listed as failing
    And the pull request's checks are failing only because of that one

  # Upstream #20094: the newest run of a check is chosen by its time, however the host wrote it.
  @mc
  Scenario: The newest run of a check wins however its time is written
    Given a check passed at "2026-10-16T12:00:00Z"
    And it failed again at "2026-10-16T12:00:00.500Z"
    When the user reads the pull request's checks
    Then the check is shown as failed

  # Upstream #17344: a workflow on push and pull_request runs a check twice on one commit;
  # the run that finished first hid the one still going, and the watch said all passed.
  @mc
  Scenario Outline: A GitHub check with a run still going is pending
    Given the check "Checks / check" of pull request 42 has a finished passing run and a run that <live>
    When the checks of pull request 42 are read, in either order
    Then "Checks / check" is listed once as pending
    And a watch on pull request 42 does not wake the agent with "All checks passed"

    Examples:
      | live                          |
      | is still running              |
      | is queued with no start time  |

  @mc
  Scenario: Checks with the same name from different workflows are told apart
    Given the workflows "CI" and "Release" each have a check named "build"
    When the user reads the checks of pull request 42
    Then the checks are listed as "CI / build" and "Release / build"

  @mc
  Scenario: Checks whose workflow and job names run together the same way stay apart
    Given pull request 42 has the check "Linux tests" of workflow "Build", which failed
    And the check "tests" of workflow "Build Linux", which passed
    When the user reads the checks of pull request 42
    Then both checks are listed, and the failure is not hidden by the newer pass

  @mc
  Scenario: Workflows of a fork pull request awaiting approval are shown as needing action
    Given pull request 42 comes from a fork and its workflows are awaiting approval
    When the user reads the checks of pull request 42
    Then the waiting workflows are listed as action-required
    And the pull request is not reported as passing

  @backlog @mc
  Scenario: A pipeline waiting on a person is neutral, not a failure
    Given the pipeline of a GitLab merge request is waiting for someone to start a manual job
    When the user reads its checks
    Then the pipeline is reported as neutral

  @backlog @mc
  Scenario Outline: Each host's merge check is read as mergeable, conflicting or not yet known
    Given a <host> pull request whose host says <answer>
    When the user opens it
    Then its mergeability is "<mergeability>"

    Examples:
      | host         | answer                                        | mergeability |
      | GitLab       | it can be merged                              | mergeable    |
      | GitLab       | it cannot be merged                           | conflicting  |
      | GitLab       | it has conflicts, even if it can be merged    | conflicting  |
      | GitLab       | it has not been checked yet                   | unknown      |
      | GitLab       | it is being checked                           | unknown      |
      | Azure DevOps | the merge succeeded                           | mergeable    |
      | Azure DevOps | the merge has conflicts                       | conflicting  |
      | Azure DevOps | the merge failed                              | conflicting  |
      | Azure DevOps | a policy rejected it                          | conflicting  |
      | Azure DevOps | the merge is queued or not set                | unknown      |
      | Forgejo      | it is mergeable                               | mergeable    |
      | Forgejo      | it is not mergeable                           | conflicting  |
      | Forgejo      | it says nothing                               | unknown      |

  @backlog @mc @priority-low
  Scenario Outline: A Bitbucket pull request is mergeable only when it has no conflicting paths
    Given a Bitbucket pull request whose conflicts list has <paths>
    When the user opens it
    Then its mergeability is "<mergeability>"

    Examples:
      | paths             | mergeability |
      | no conflicting paths | mergeable    |
      | a conflicting path   | conflicting  |

  # Upstream #28728: a GitLab pipeline was one "Pipeline" check, so a failure could not say which job
  # broke; each job is now its own check.
  @backlog @mc @priority-low
  Scenario: Each job of a GitLab pipeline is its own check
    Given a GitLab merge request's pipeline has the stage "test" with the jobs "unit" and "lint"
    And "unit" failed
    When the user reads its checks
    Then "test / unit" is listed as a failure linking to its log
    And "test / lint" is listed beside it

  # Upstream #28728: a job allowed to fail is neutral, and a retried job counts by its latest run.
  @backlog @mc @priority-low
  Scenario Outline: How a GitLab job is listed as a check
    Given a GitLab merge request's pipeline has a job that <job>
    When the user reads its checks
    Then <listed>

    Examples:
      | job                                    | listed                                  |
      | is allowed to fail and failed          | the job is neutral                      |
      | failed, then passed when retried       | the job is listed once, as a success    |
      | waits to be run by hand                | the job is neutral                      |

  # Upstream #28728: what GitLab does not return whole stays one check.
  @backlog @mc @priority-low
  Scenario Outline: A GitLab pipeline whose jobs cannot all be read keeps a coarser check
    Given a GitLab merge request's pipeline where <case>
    When the user reads its checks
    Then <listed>

    Examples:
      | case                                       | listed                                          |
      | a stage has more than 100 jobs             | that stage is one check with GitLab's stage state |
      | its stages cannot be read                  | the pipeline is one check named "Pipeline"      |

  # Upstream #28728: a trigger job is listed once, by its child pipeline, not again as a stage job.
  @backlog @mc @priority-low
  Scenario: A GitLab trigger job whose child failed is listed once
    Given a GitLab merge request's pipeline has the trigger job "deploy / child-pipeline" whose child pipeline failed
    When the user reads its checks
    Then "deploy / child-pipeline" is listed once, as a failure

  # Upstream #24392: opening a GitLab merge request read it twice, for its detail and again for
  # its checks, spending the shared GitLab request budget.
  @backlog @mc @priority-low
  Scenario: Opening a GitLab merge request reads it once for its detail and its checks
    Given a GitLab merge request was not read in the last minute
    When the user opens it and its checks are shown
    Then GitLab is asked for the merge request once
    And a change the user makes to it, or a refresh, reads it afresh

  # Upstream #24688: a trigger job passes once it starts its child pipeline, so a failed child
  # read as "All checks passed".
  @backlog @mc @priority-low
  Scenario Outline: A GitLab child pipeline is its own check
    Given the pipeline of a GitLab merge request has a trigger job "deploy" that started a child pipeline
    And the child pipeline failed, and the trigger job <allowed> to fail
    When the user reads its checks
    Then "deploy" is listed beside "Pipeline" as <result>, linking to the child pipeline

    Examples:
      | allowed    | result    |
      | is not     | a failure |
      | is allowed | neutral   |

  # Upstream #25195: a pipeline waiting on a delayed job read as neutral, as if it had finished.
  @backlog @mc @priority-low
  Scenario Outline: A GitLab pipeline state is read as a check state
    Given the pipeline of a GitLab merge request is "<state>"
    When the user reads its checks
    Then the pipeline is reported as <result>

    Examples:
      | state     | result    |
      | success   | success   |
      | failed    | failure   |
      | canceled  | cancelled |
      | skipped   | skipped   |
      | scheduled | pending   |
      | running   | pending   |
      | created   | pending   |

    # Upstream #21543: a pipeline still being cancelled was listed as pending.
    Examples: Being cancelled
      | state     | result    |
      | canceling | cancelled |

  @backlog @mc @priority-low
  Scenario: A GitLab merge request without a pipeline has no checks
    Given a GitLab merge request that never ran a pipeline
    When the user reads its checks
    Then no check is listed
    And the checks are not reported as failing or passing

  @backlog @mc @priority-low
  Scenario Outline: A Bitbucket build status is read as a check state
    Given a commit of a Bitbucket pull request has a build in the state "<state>"
    When the user reads its checks
    Then that build is reported as <result>

    Examples:
      | state      | result    |
      | SUCCESSFUL | success   |
      | FAILED     | failure   |
      | STOPPED    | cancelled |
      | INPROGRESS | pending   |
      | anything else | neutral |

  @backlog @mc @priority-low
  Scenario: Votes on a Bitbucket pull request read as reviews
    Given on a Bitbucket pull request "alice" approved and "bob" was only added as a reviewer
    When the user reads the conversation
    Then "alice" appears with a review
    And "bob" does not

  @backlog @mc @priority-low
  Scenario: A locked GitLab merge request is still open
    Given a GitLab merge request whose discussion is locked
    When the user lists it
    Then it is listed as open

  @mc
  Scenario: A GitHub review is sent as one request so nothing shows before the verdict
    Given the user wrote 3 line comments and a summary for pull request 42
    When the user submits the review with the verdict "comment"
    Then GitHub receives the comments, the summary and the verdict in one request
    And nobody else sees any of them before that request is accepted

  @backlog @mc @priority-low
  Scenario: A GitLab review is posted piece by piece with the approval last
    Given the user wrote 3 line comments and a summary for a GitLab merge request
    When the user submits the review with the verdict "approve"
    Then the line comments are posted first, then the summary, then the approval

  @backlog @mc @priority-low
  Scenario: A GitLab review that fails part-way is never an approval
    Given the user wrote 3 line comments and a summary for a GitLab merge request
    And GitLab refuses the second line comment
    When the user submits the review with the verdict "approve"
    Then the user is told the review failed
    And the first line comment stays posted
    And the merge request is not approved

  # Upstream #30549: GitLab merge requests can be reviewed with "Request changes", sent before the
  # comments so an older server refuses it before anything is posted.
  @backlog @mc @shared @priority-low
  Scenario: A GitLab review can request changes
    Given the user wrote 3 line comments and a summary for a GitLab merge request
    When the user submits the review with the verdict "request changes"
    Then the user is added as a reviewer and requests changes, before the comments and summary are posted
    And the merge request reads "Changes requested"

  # Upstream #30549: GitLab refuses a mutation with its reasons in the answer, which now reach the user.
  @backlog @mc @priority-low
  Scenario: A GitLab server that refuses to request changes says why and posts nothing
    Given the user wrote 3 line comments for a GitLab merge request on a server older than GitLab 18.9
    When the user submits the review with the verdict "request changes"
    Then the user is told GitLab's reason
    And none of the line comments is posted

  # Upstream #30549: a reviewer requesting changes outranks an approval, as on GitHub.
  @backlog @mc @priority-low
  Scenario: A GitLab reviewer requesting changes outranks an approval
    Given a GitLab merge request approved by "mona" on which "hubot" requested changes
    When the user reads its review state
    Then it is "changes requested"

  # Upstream #30423: a GitLab thread on a line a later push changed still showed as current.
  @backlog @mc @priority-low
  Scenario: A GitLab thread on code that has since changed is outdated
    Given a GitLab merge request has a thread on a line that a later push changed
    When the user reads the review threads
    Then that thread is listed among the outdated ones
    And a thread whose position matches the latest diff is current

  # Upstream #30423: without what to compare, a thread stays current, as before.
  @backlog @mc @priority-low
  Scenario: A GitLab thread stays current when the merge request's diff cannot be read
    Given the detail of a GitLab merge request cannot be read
    When the user reads its review threads
    Then no thread is listed as outdated

  # Upstream #30397: a thread started on the GitLab merge request itself, not on a line, came through
  # as a plain comment that "Fix findings" left out.
  @backlog @mc @priority-low
  Scenario: An unresolved GitLab overview thread is a finding
    Given a GitLab merge request has an unresolved thread started on the merge request itself
    When the user chooses to fix the findings of its review
    Then that thread is among the findings handed over
    And its replies are not listed as findings of their own

  @backlog @mc @priority-low
  Scenario Outline: A part of a GitLab conversation that cannot be read leaves the rest
    Given GitLab cannot answer the request for <part> of a merge request
    When the user opens its conversation
    Then the other parts of the conversation are shown
    And <consequence>

    Examples:
      | part                | consequence                                  |
      | its notes           | the conversation is marked as cut short      |
      | its discussions     | the conversation is marked as cut short      |
      | its commits         | no commits are listed                        |
      | its reactions       | the comments are shown without reactions     |

  @mc @priority-high
  Scenario Outline: Words the user typed never travel on a command line
    Given the user types "<words>"
    When the user <action> through the MC on <host>
    Then the words reach the host through its standard input rather than its arguments
    And the words are not in any error that is reported

    Examples:
      | words        | action                       | host      |
      | LGTM         | submits a review             | GitHub    |
      | tax label:bug | searches pull requests       | GitHub    |

    @backlog
    Examples: Hosts the MC has no provider for yet
      | words        | action                       | host      |
      | true         | comments on a pull request   | GitLab    |
      | 42           | edits a comment              | GitLab    |

  @backlog @mc
  Scenario: A very large page of a diff is returned whole and not kept in memory
    Given a page of the diff of pull request 42 is larger than the MC keeps
    When a client reads that page twice
    Then both answers carry the whole page
    And the host is asked both times

  @backlog @mc
  Scenario: Ticking off a file does not make the MC read the diff again
    Given the diff of pull request 42 was read a moment ago
    When the user marks "src/cart.ts" viewed
    Then the next read of the diff comes without asking the host

  @backlog @mc
  Scenario: The environment remembers a bounded number of file versions per pull request
    Given pull request 42 has more than 1000 files the user marked viewed on a host that keeps none
    When the user marks another file viewed
    Then the MC keeps the versions of at most 1000 files, the ones asked about most recently

  @mc
  Scenario Outline: A host that cannot rewrite <what> refuses the edit
    Given an open change request on a host that does not support editing <what>
    When the user rewrites the <what>
    Then the user is told "<message>"
    And nothing is sent to the host

    Examples:
      | what                       | message                                 |
      | title and description      | This host cannot rewrite a change request. |
      | comments                   | This host cannot rewrite a comment.        |

  @mc
  Scenario: A comment cannot be edited into nothing
    Given the user commented "Looks good" on pull request 42
    When the user edits the comment to only spaces
    Then the user is told "A comment cannot be empty."
    And the comment still reads "Looks good"

  # Legacy: apps/server/src/pullRequest/gitHubPullRequestJson.ts (REACTORS_PER_GROUP, toReactions)
  @mc
  Scenario: A reaction names a handful of the people who gave it and counts the rest
    Given twelve people reacted with a heart to a comment on pull request 42
    When the user opens the conversation of pull request 42
    Then the heart shows a count of 12
    And at most ten of the people who reacted are named

  # Legacy: apps/server/src/pullRequest/gitHubPullRequestJson.ts (toReviewDecisionWithReviews)
  @mc
  Scenario Outline: A pull request's verdict is taken from the reviewers' last words when the host gives none
    Given the host reports no review decision for pull request 42
    And <reviews>
    When the user opens pull request 42
    Then the verdict of the pull request is <verdict>

    Examples:
      | reviews                                                    | verdict         |
      | "hubot" last approved it and nobody asked for changes      | approved        |
      | "hubot" last approved it and "mona" last asked for changes | needing changes |

  # Legacy: apps/server/src/pullRequest/gitLabMergeRequestJson.ts, azureDevOpsPullRequestJson.ts, bitbucketPullRequestJson.ts, forgejoPullRequestJson.ts (comment filters)
  @backlog @mc
  Scenario Outline: What the host wrote itself, deleted, never published or left empty is not part of the conversation
    Given a pull request on <host> whose conversation holds a comment that <comment>
    When the user opens its conversation
    Then that comment is not listed
    And the other comments are listed in order

    Examples:
      | host         | comment                                                |
      | GitLab       | the host wrote about its own activity                  |
      | Azure DevOps | the host wrote about its own activity                  |
      | Azure DevOps | was deleted                                            |
      | Azure DevOps | has no words                                           |
      | Bitbucket    | was deleted                                            |
      | Bitbucket    | is a draft that was never published                    |
      | Bitbucket    | has no words                                           |
      | Forgejo      | belongs to a review that was started and not submitted |
      | Forgejo      | is only the request for a review                       |

  # Legacy: apps/server/src/pullRequest/azureDevOpsPullRequestJson.ts (decodeThreadsJson)
  @backlog @mc @priority-low
  Scenario: An Azure DevOps thread tied to a file is a line comment and the others are plain comments
    Given an Azure DevOps pull request with one thread on "src/cart.ts" and one thread on no file
    When the user opens its conversation
    Then the thread on "src/cart.ts" is listed as a comment on that file
    And the other thread is listed as a plain comment
    And the replies of each thread follow it oldest first

  # Legacy: apps/server/src/pullRequest/bitbucketPullRequestJson.ts (buildReviewThreads)
  @backlog @mc @priority-low
  Scenario: A Bitbucket reply to a reply belongs to the conversation of the comment that began it
    Given a Bitbucket line comment, a reply to it, and a reply to that reply
    When the user opens the review threads
    Then the three comments form one thread, in order
    And the thread is placed on the line of the first comment

  # Legacy: apps/server/src/pullRequest/bitbucketPullRequestJson.ts (buildReviewThreads: orphan reply)
  @backlog @mc @priority-low
  Scenario: A Bitbucket reply whose original cannot be read stays in the conversation without a thread of its own
    Given a Bitbucket reply whose parent comment was deleted
    When the user opens the conversation
    Then the reply is listed with the other comments
    And no review thread is made of it

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestProvider.ts (getChangeRequestActivity)
  @backlog @mc @priority-low
  Scenario: An Azure DevOps conversation that cannot be found or read says it was cut short
    Given Azure DevOps cannot say where the conversation of pull request 42 is kept
    When the user opens the conversation of pull request 42
    Then no comments are listed
    And the conversation says it was cut short
    And no review threads or commits are listed

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestProvider.ts, azureDevOpsDiff.ts (cursor)
  @backlog @mc @priority-low
  Scenario: Slices of an Azure DevOps change stay on the push they began with
    Given the user is reading the code of an Azure DevOps pull request in slices
    And the author pushes again between two slices
    When the next slice is read
    Then it carries on from the push the first slice was read at
    And no file is repeated or skipped

  # Legacy: apps/server/src/pullRequest/azureDevOpsDiff.ts (cursor parsing)
  @backlog @mc @priority-low
  Scenario: A position that is not one the MC handed out starts an Azure DevOps diff from the top
    Given a client holds a diff position that did not come from Azure DevOps
    When it asks for the next slice of an Azure DevOps pull request
    Then the diff starts again from its first file

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestCli.ts (change pages ceiling), azureDevOpsPullRequestJson.ts (folders)
  @backlog @mc @priority-low
  Scenario: An Azure DevOps change list longer than the MC will follow says it was cut short
    Given an Azure DevOps pull request whose list of changed files runs past the longest list the MC follows
    When the user opens its code
    Then the files read are listed
    And the diff says it is incomplete

  @backlog @mc @priority-low
  Scenario: A folder in an Azure DevOps change is not listed as a file
    Given an Azure DevOps pull request whose change includes a folder
    When the user opens its code
    Then only the files inside it are listed

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestCli.ts (getPullRequestDetail: checksTruncated)
  @mc
  Scenario: More checks than one read holds are all read before the pull request is called passing
    Given pull request 42 has 130 checks and the first 100 of them passed
    And the 101st failed
    When the user reads the checks of pull request 42
    Then all 130 checks are read
    And the pull request is reported as failing

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestCli.ts (getPullRequestDetail: head changed while reading checks)
  @mc
  Scenario: Checks are not put together across a push made while they were being read
    Given pull request 42 has more checks than one read holds
    And the author pushes while the rest of the checks are being read
    When the user reads the checks of pull request 42
    Then the read fails with "Pull request head changed while reading checks."
    And the checks of the older push are not shown as the checks of the new one

  # Legacy: apps/server/src/pullRequest/gitHubPullRequestJson.ts (commitStats: parents)
  @mc
  Scenario: A merge commit of the base into the branch shows no line counts of its own
    Given the branch of pull request 42 has a commit that merged the base branch in
    When the user opens the timeline of pull request 42
    Then that commit is listed without line counts
    And the other commits keep theirs

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestProvider.ts (rendersEmpty, dismissalsByReviewId)
  @mc
  Scenario: A dismissed review whose words are only a hidden marker shows the reason it was dismissed
    Given a bot review on pull request 42 that was dismissed with the reason "Superseded"
    And the review's own text is only an HTML comment
    When the user opens the conversation of pull request 42
    Then the review is shown with the reason "Superseded"

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestProvider.ts (withAvatar, loginAvatarUrl)
  @mc
  Scenario Outline: An author the host gave no picture for gets the host's picture for their login, apps excepted
    Given a comment on pull request 42 by <author>, for whom the host sent no picture
    When the user opens the conversation of pull request 42
    Then <result>

    Examples:
      | author                      | result                                            |
      | "octocat"                   | the picture GitHub keeps for "octocat" is used    |
      | the app "dependabot[bot]"   | no picture is made up, and the author is a bot    |

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts (setReaction)
  @backlog @mc @priority-low
  Scenario: Taking back a reaction that is already gone is not an error
    Given the user's heart on a comment of a GitLab merge request was already removed elsewhere
    When the user takes the heart back
    Then nothing fails
    And the comment shows no heart from the user

  # Legacy: apps/server/src/pullRequest/ForgejoPullRequestProvider.ts (setReaction, reviewCommentId)
  @backlog @mc @priority-low
  Scenario: A reaction to a Forgejo review goes to the comment the review made
    Given a Forgejo review with the words "Looks good"
    When the user reacts with a heart to the review
    Then the heart is given to the comment that review made on the host

  @backlog @mc @priority-low
  Scenario: A Forgejo review that made no comment cannot be reacted to
    Given a Forgejo review the host reports no comment for
    When the user reacts with a heart to the review
    Then the user is told "Forgejo did not return a comment ID for this review."

  # Legacy: apps/server/src/pullRequest/forgejoPullRequestJson.ts (forgejoChecks)
  @backlog @mc @priority-low
  Scenario Outline: A Forgejo commit status is read as a check state
    Given a commit status on Forgejo that is "<status>"
    When the user reads the checks of the pull request
    Then the check is reported as <state>

    Examples:
      | status  | state   |
      | success | passing |
      | failure | failing |
      | error   | failing |
      | pending | pending |
      | warning | pending |

  # Legacy: apps/server/src/pullRequest/forgejoPullRequestJson.ts (forgejoReviewThread)
  @backlog @mc @priority-low
  Scenario: A Forgejo line comment on a removed line is placed on the old side, and resolved when the host says so
    Given a Forgejo line comment made on a line the pull request removed
    And the host names who resolved it
    When the user opens the review threads
    Then the thread is placed on the old side of that line
    And it is resolved

  # Legacy: apps/server/src/pullRequest/ForgejoPullRequestProvider.ts (getChangeRequestActivity: 500 items)
  @backlog @mc @priority-low
  Scenario: A Forgejo conversation longer than five hundred entries says it was cut short
    Given a Forgejo pull request whose comments, reviews and line comments run past five hundred entries
    When the user opens its conversation
    Then the first five hundred are shown
    And the conversation says it was cut short

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts (getDiffRefs: GitLabDiffRefsUnavailableError)
  @backlog @mc @priority-low
  Scenario: A GitLab merge request with no diff revisions cannot take line comments
    Given a GitLab merge request that reports no diff revisions
    When the user submits a review with a line comment on it
    Then the user is told "The merge request reported no diff revisions."
    And nothing is posted

  # Upstream #15886: merge request changes load on GitLab before 15.7.
  @backlog @mc @priority-low
  Scenario: A merge request on an older GitLab shows its changes
    Given a GitLab server older than 15.7
    When the user opens a merge request's code
    Then its changes are shown
    And a merge request too large to list in full is shown as partial

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts (getCommitDiffRefs: GitLabDiffCommitParentUnavailableError)
  @backlog @mc
  Scenario: A file a first commit changed but did not add cannot be expanded
    Given a GitLab commit with no parent that changes "src/cart.ts" and does not add it
    When the user expands the unchanged lines of "src/cart.ts" in that commit
    Then the user is told the commit reported no parent revision

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts, bitbucketPullRequestJson.ts, forgejoPullRequestProvider (update title or description alone)
  @mc
  Scenario Outline: Changing one of title and description leaves the other as it was
    Given an open change request on <host> with a title and a description
    When the user changes only its <field>
    Then only the <field> is sent to the host
    And the other one still reads as before

    Examples:
      | host      | field       |
      | GitHub    | title       |
      | GitHub    | description |

    @backlog
    Examples: Hosts the MC has no provider for yet
      | host      | field       |
      | GitLab    | title       |
      | GitLab    | description |
      | Bitbucket | title       |
      | Forgejo   | description |

  # Upstream review guides (#18124) need the change request's head commit; GitLab and
  # Bitbucket details dropped it, and Bitbucket reports it as a short hash.
  @backlog @mc @priority-low
  Scenario Outline: A review guide is written at the change request's head commit on every host
    Given an open change request on <host> whose head commit is "<head>"
    When the user asks for a review guide of it
    Then the guide is written against the checkout of "<head>"

    Examples:
      | host                                        | head                                     |
      | GitLab                                      | 772a4f2c0d0f4d9e8a6b1c3e5f7a9b0c1d2e3f40 |
      | GitLab, from a fork                         | afce4da7b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6 |
      | Bitbucket                                   | 5a3ec8a077d5e1f2a3b4c5d6e7f8a9b0c1d2e3f4 |
      | Bitbucket, which reports it as 5a3ec8a077d5 | 5a3ec8a077d5e1f2a3b4c5d6e7f8a9b0c1d2e3f4 |

    # Upstream #20977: Azure DevOps details named no head commit, so every guide was refused; the
    # head is the newest iteration's source commit, also when its changed files cannot be read.
    Examples: Azure DevOps
      | host                                        | head                                     |
      | Azure DevOps, from its newest pushed commit | 9c1e2f4a7b3d5e6f8a9b0c1d2e3f4a5b6c7d8e9f |

  # Upstream #29907: a failing checkout hook in the repository made every review guide fail.
  @backlog @mc @priority-low
  Scenario: A review guide is written whatever the repository's checkout hooks do
    Given the repository has a checkout hook that fails
    When the user asks for a review guide of an open change request
    Then the guide is written
    And a thread worktree made in that repository still runs the hook

  @backlog @shared @mc @priority-low
  Scenario: Review guides are hidden until the beta is turned on
    Given "Review guides (beta)" is off in Settings → Source Control
    When the user opens pull request 42
    Then there is no Guide tab, no "Write guide" in its menu and no notice that a guide is ready
    When the user turns "Review guides (beta)" on
    Then pull request 42 has a Guide tab
    And Settings → Source Control offers the guide model and the guide instructions

  @backlog @shared @mc @priority-low
  Scenario: A guide is written on demand and the user hears when it is done
    Given "Review guides (beta)" is on
    When the user chooses "Write guide" in the menu of pull request 42 and leaves the page
    Then the user is told when the guide is ready, or that it failed
    And the guide is kept for pull request 42 and its menu offers "Rewrite guide"

  # Upstream #26073: a failed guide showed the provider's raw output, pushing Try again out of reach.
  @backlog @shared @priority-low
  Scenario: A failed review guide says so briefly and can be tried again
    Given "Review guides (beta)" is on
    And writing the guide for pull request 42 failed with a long provider output
    When the user opens its Guide tab
    Then the tab says "Could not write a review guide" and points to the guide model setting
    And "Try again" can be reached without scrolling through the output
    And the provider's output is in collapsed technical details
    And a failed rewrite of an existing guide is reported the same way
    When a new commit is pushed to pull request 42
    Then the guide is shown as stale

  @backlog @mc @priority-low
  Scenario: A guide tours every changed file and notes only changed lines
    When the MC writes a guide for pull request 42
    Then the guide is a list of stops in reading order
    And every changed file is in some stop
    And every excerpt and note sits on changed lines
    And the guide's instructions can shape what comes first, but not the format or the coverage

  # Upstream #23725: an excerpt spanning two earlier ones in a stop grew the first and left the
  # second, so the lines they shared showed twice.
  @backlog @mc @priority-low
  Scenario: Excerpts in a stop that touch are shown as one
    Given a guide stop cites "src/report.ts" lines 8 to 14, then 16 to 20, then 13 to 17
    When the MC stores the guide
    Then the stop shows one excerpt of "src/report.ts", lines 8 to 20

  # Upstream #23225: a guide took a cached diff page as complete before the fresh one arrived.
  @backlog @shared @priority-low
  Scenario: A guide reads the pull request's current diff, not one cached from an earlier revision
    Given the client has the diff of pull request 42 from an earlier revision
    And a new revision changes "api.ts" and adds "new.ts"
    When the user opens the guide for the new revision
    Then its stops show "api.ts" as the new revision has it
    And "new.ts" is not reported missing

  # Upstream #25486: a guide kept behind the phone's Overview went on refreshing every five seconds.
  @backlog @mobile @priority-low
  Scenario: A guide the user switched away from stops refreshing until it is shown again
    Given the user is reading the guide of pull request 42 on the phone
    When the user switches to the pull request's overview
    Then the guide is no longer refreshed while it is hidden
    And switching back shows the kept guide and refreshes it once

  # Upstream #26064: switching tabs on the phone moved the page up by the header's height.
  @backlog @mobile @priority-low
  Scenario: Switching a pull request's tabs on the phone keeps the page where it was
    Given the user is reading pull request 42 on the phone with its header partly scrolled away
    When the user switches between its overview, guide and activity
    Then the header and title stay where they were

  # Upstream #21988: a textconv diff driver rewrote the hunks a guide was measured against, so its
  # excerpts were dropped.
  @backlog @mc @priority-low
  Scenario: A guide keeps its excerpts in a file a text conversion driver changes
    Given the repository shows "notes.docx" through a text conversion diff driver
    And pull request 42 changes "notes.docx"
    When the MC writes a guide for pull request 42
    Then the guide's excerpts of "notes.docx" sit on its changed lines

  # Upstream #22053: paths git quotes, with spaces or escaped characters, lost their excerpts.
  @backlog @mc @priority-low
  Scenario Outline: A guide keeps its excerpts in a file whose name git quotes
    Given pull request 42 changes "<file>"
    When the MC writes a guide for pull request 42
    Then the guide has excerpts of "<file>" on its changed lines

    Examples:
      | file                  |
      | docs/release notes.md |
      | src/café.ts           |
      | src/"quoted".ts       |

  # Upstream #30717: excerpts lost CRLF and missing-final-newline endings, hiding a change to the
  # end of a file and expanding to the wrong old lines.
  @backlog @desktop @priority-low
  Scenario Outline: A guide's excerpt keeps how its lines end
    Given pull request 42 <change>
    When the user reads the guide's excerpt of "notes.txt"
    Then <shown>
    And expanding the excerpt shows the file's earlier lines as they were

    Examples:
      | change                                          | shown                                                    |
      | adds a final newline to "notes.txt"             | the old side is marked as having no newline at the end   |
      | removes the final newline of "notes.txt"        | the new side is marked as having no newline at the end   |
      | changes a line of "notes.txt", written with CRLF | the excerpt keeps the file's CRLF endings                |

  @backlog @mc @priority-low
  Scenario Outline: Which providers can write a guide
    Given the guide model is from <provider>
    When the user asks for a guide of pull request 42
    Then <outcome>

    Examples:
      | provider | outcome                                         |
      | Claude   | the guide is written                            |
      | Codex    | the guide is written                            |
      | Cursor   | the user is told the provider cannot write one  |
      | OpenCode | the user is told the provider cannot write one  |

  @backlog @mc @priority-low
  Scenario: Each layer of a stack is guided from its parent branch
    Given pull request 43 is stacked on pull request 42
    When the MC writes a guide for pull request 43
    Then the guide covers only the changes since pull request 42's branch

  # Upstream #18312: in a fork checkout the guide's base came from the fork's stale origin, so
  # unrelated commits reached the guide; the base now comes from the remote that is the repository.
  @backlog @mc @priority-low
  Scenario: A guide written in a fork checkout covers only the pull request's change
    Given the project is a checkout of a fork whose "origin" lags behind the upstream repository
    And pull request 42 targets the upstream repository
    When the MC writes a guide for pull request 42
    Then only the pull request's changes are in the guide

  # Upstream #18312: with no remote matching the pull request's repository the guide fails.
  @backlog @mc @priority-low
  Scenario: A guide is refused when no remote is the pull request's repository
    Given no remote of the checkout points at the repository of pull request 42
    When the user asks for a guide of pull request 42
    Then the guide fails without asking a provider
    And no guide is kept for pull request 42

  @backlog @shared @priority-low
  Scenario: Comments on a guide's excerpt join the pending review
    Given the user is reading the guide of pull request 42
    When the user comments on a line of a stop's excerpt
    Then the comment joins the pending review the Code tab collects
    And "Finish review" on the last stop opens the composer with the pending comments

  @backlog @shared @priority-low
  Scenario: Asking about a stop opens a thread beside the guide
    Given the user is reading stop 2 of the guide of pull request 42
    When the user chooses "Ask about this stop"
    Then a new thread opens with the pull request and the stop as context
    And the guide stays open beside it at stop 2

  # Upstream #18267 brought the Guide tab to the phone; the tab itself is @shared above.
  @backlog @mobile @priority-low
  Scenario: A stale guide stays readable on the phone without its code
    Given the guide of pull request 42 was written before its latest push
    When the user reads the guide on the phone
    Then its stops and notes are shown
    And its code excerpts are hidden until the guide is rewritten

  @backlog @mobile @priority-low
  Scenario: Only a user who may write a guide is offered to write one on the phone
    Given the user may read pull request 42 but not ask for its guide
    When the user opens its Guide tab on the phone
    Then the guide is not offered to be written

  @backlog @mobile @priority-low
  Scenario: The phone keeps the guide's stop when its layout changes
    Given the user is reading stop 2 of the guide of pull request 42 on a foldable phone
    When the user unfolds the phone
    Then stop 2 is still shown
    When the user opens the code of a stop's excerpt
    Then the diff opens at the excerpt's lines

  @backlog @mc @priority-low
  Scenario: A watched GitLab merge request is seen to move when its head does
    Given the user is watching a GitLab merge request
    When a new commit is pushed to its source branch
    Then the watch reports that the merge request's head moved

  # Upstream #22189: a pull request's added and removed lines are split into what kind of file
  # they touch, so the size of the real change shows apart from tests and lockfile churn.
  Rule: How much of a pull request is code

    @backlog @desktop
    Scenario: A pull request's line counts are split by the kind of file
      Given pull request 42 adds and removes lines in source files, tests, mocks and a lockfile
      When the user points at the added and removed lines of pull request 42
      Then they are split into Code, Tests, Mocks and Generated, adding up to the total

    @backlog @mc
    Scenario Outline: Changed files are sorted by kind from their paths
      Given pull request 42 changes "<path>"
      When the MC splits pull request 42's lines by kind
      Then the lines of "<path>" count as <kind>

      Examples:
        | path                            | kind      |
        | src/cart.ts                     | Code      |
        | src/cart.test.ts                | Tests     |
        | pkg/cart_test.go                | Tests     |
        | tests/test_cart.py              | Tests     |
        | src/__mocks__/cart.ts           | Mocks     |
        | fixtures/cart.json              | Mocks     |
        | pnpm-lock.yaml                  | Generated |
        | src/api.generated.ts            | Generated |
        | README.md                       | Docs      |
        | docs/guide.rst                  | Docs      |
        | requirements.txt                | Code      |
        | CMakeLists.txt                  | Code      |

      # Upstream #26563: Convex _generated/ output and evaluation files counted as Code.
      Examples: Generated output and evaluations
        | path                            | kind      |
        | convex/_generated/api.ts        | Generated |
        | src/cart.eval.ts                | Tests     |
        | evals/checkout.ts               | Tests     |

    @backlog @mc
    Scenario: A split that would not add up to the total is not offered
      Given the host lists only some of the files pull request 42 changes
      When a client asks how pull request 42's lines split by kind
      Then no split is given and the plain total stands

    @backlog @mc @priority-low
    Scenario: Only the totals per kind cross the wire
      Given pull request 42 changes 300 files
      When a client asks how pull request 42's lines split by kind
      Then the answer holds one added and removed count per kind and no file list

    # Upstream #22255: the pull request view loads the split as it opens; rows in long lists
    # ask the host only when the user points at them.
    @backlog @desktop
    Scenario: The pull request view has its split ready when it opens
      When the user opens pull request 42
      And points at its added and removed lines
      Then the split shows at once

    # Upstream #22255
    @backlog @desktop @priority-low
    Scenario: Rows of the pull request list ask for their split only when pointed at
      Given the pull request list shows 40 pull requests
      When the user points at the line counts of one row
      Then that row shows its split
      And the host was asked for the split of that pull request alone

    # Upstream #22255: the thread's details show the split of its linked pull request.
    @backlog @desktop
    Scenario: A thread's details show its pull request's split under its files
      Given the thread is linked to pull request 42
      When the user opens the thread's details
      Then the split of pull request 42 shows under its changed files

    # Upstream #22189: the phone's changed files say the same split, and hiding
    # test files hides mocks and fixtures too.
    # Upstream #22255: same change as #22189.
    @backlog @mobile
    Scenario: The phone's changed files of a pull request show its split
      When the user opens the changed files of pull request 42 on the phone
      Then they say how many lines are Code, Tests, Mocks, Generated and Docs

    @backlog @mobile @priority-low
    Scenario: Hiding test files on the phone hides mocks and fixtures too
      Given pull request 42 changes "src/cart.ts", "src/cart.test.ts" and "fixtures/cart.json"
      When the user hides test files on the phone
      Then only "src/cart.ts" is listed
