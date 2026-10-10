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
  Scenario: Marking several files viewed is all or nothing
    Given the user marks "a.ts", "b.ts" and "c.ts" viewed together in a GitLab merge request
    When the environment fails to store the mark for "c.ts"
    Then none of the three files read as viewed

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
  @backlog @desktop
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
  @backlog @desktop
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

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.test.ts (never lifts a video out of code)
  @backlog @desktop
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

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdown.tsx (GitHubVideo), apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts (GITHUB_ASSET_PATTERN)
  @backlog @desktop
  Scenario: A video that GitHub hosts plays through a link the MC signs
    Given the description of pull request 42 has a video uploaded to GitHub on a line of its own
    When the user reads the description
    Then the video plays from a link the MC signed for the user's host

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdown.tsx (GitHubVideo)
  @backlog @desktop
  Scenario: A GitHub video still plays when the MC cannot sign it
    Given the MC cannot sign GitHub media
    And the description of pull request 42 has a video uploaded to GitHub on a line of its own
    When the user reads the description
    Then the video plays from the plain address the description holds

  # Legacy: apps/web/src/components/pullRequest/PullRequestMarkdown.tsx (GitHubVideo onRetry, originalUrl)
  @backlog @desktop
  Scenario: A GitHub video that stopped playing can be retried or opened where it lives
    Given a GitHub video in the description of pull request 42 stopped playing
    When the user retries it
    Then the MC signs a fresh link and the video plays from it
    When the user asks for the original
    Then the address the description holds is opened

  # Legacy: apps/web/src/components/pullRequest/pullRequestMarkdown.logic.ts (remarkPullRequestAutolinks)
  @backlog @desktop
  Scenario: A number in a description or comment links to that issue or pull request
    Given the description of pull request 42 says "Fixes #12 and follows #7"
    When the user reads the description
    Then "#12" links to issue 12 of the repository and "#7" to issue 7
    And the words around them are unchanged

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
  @backlog @desktop
  Scenario: Reactions are listed in one fixed order, only those given
    Given the description of pull request 42 has a rocket, a thumbs-up and a heart
    When the user reads the description
    Then the reactions are listed as thumbs-up, heart, rocket
    And each shows how many people gave it

  # Legacy: apps/web/src/components/pullRequest/pullRequestReactions.logic.ts (reactionTooltip)
  @backlog @desktop
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
  @backlog @desktop
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
  @backlog @desktop
  Scenario: A reaction that could not be saved is taken back and says so
    Given the host refuses the reaction
    When the user gives a heart to a comment on pull request 42
    Then the user sees an "error" toast "The reaction could not be saved"
    And the heart is not the user's

  # Legacy: apps/web/src/components/pullRequest/PullRequestReactions.tsx (cannot react)
  @backlog @desktop
  Scenario Outline: Where the user cannot react the reactions are only shown
    Given the user cannot react to a comment on pull request 42 and it has <reactions>
    When the user looks at the comment
    Then <result>

    Examples:
      | reactions       | result                                               |
      | 2 hearts        | the hearts are shown but cannot be pressed           |
      | no reactions    | no reactions are shown and none can be added         |

  # Legacy: apps/web/src/components/pullRequest/PullRequestReactions.tsx (picker, subjectId)
  @backlog @desktop
  Scenario: A reaction can be added to the description or to one comment
    Given the user may react on pull request 42
    When the user adds a rocket to the description
    And the user adds a rocket to one comment
    Then the description and that comment each show one rocket from the user
    And no other comment does

  @backlog @desktop
  Scenario: Checks as one line
    Given 16 checks of pull request 42 where 7 run and 1 failed
    When the user reads the checks of pull request 42
    Then they are summarised as "7 of 16 running · 1 failed"

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

  @backlog @desktop
  Scenario: Bot comments are kept out of the way
    Given pull request 42 has comments by people and 3 comments by bots
    When the user opens pull request 42
    Then the people's comments are listed
    And the bots' comments are behind "3 bot comments" until the user opens them

  @backlog @desktop
  Scenario: Many bot comments are also read in pages
    Given pull request 42 has 25 comments by bots
    When the user opens the bot comments of pull request 42
    Then the 10 most recent are shown with "Show 10 older bot comments (15 hidden)"

  # Legacy: apps/web/src/components/pullRequest/pullRequestDetail.logic.test.ts (drops a body that is nothing but a bot's HTML comment)
  @backlog @desktop
  Scenario: A comment that is only a bot's hidden marker shows no words
    Given a bot commented on pull request 42 with only an HTML comment
    When the user opens the timeline of pull request 42
    Then that comment is listed without any words

  # Legacy: apps/web/src/components/pullRequest/pullRequestDetail.logic.test.ts (keeps one that says more)
  @backlog @desktop
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

  @backlog @desktop
  Scenario: Finished conversations are folded
    Given pull request 42 has 2 resolved review threads and a dismissed review
    When the user opens pull request 42
    Then they are behind "3 resolved or dismissed comments"
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

  @backlog @desktop
  Scenario: The timeline lists what happened to the pull request
    Given pull request 42 was opened, received 2 commits and a comment, and was merged
    When the user opens the timeline of pull request 42
    Then it lists the merge, the comment, the commits and the opening, newest first

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

  @backlog @desktop
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

  @backlog @desktop
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

  @backlog @desktop
  Scenario: A review that could not be sent keeps its draft
    Given the host refuses reviews on pull request 42
    And the user wrote a summary and a line comment for pull request 42
    When the user submits the review
    Then the user sees an "error" toast "The review could not be submitted"
    And the summary and the line comment are still held

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

  @backlog @desktop
  Scenario: A line comment alone is a review
    Given the user left a line comment on pull request 42 and wrote no summary
    When the user opens the review in the composer
    Then the review can be submitted as a comment

  @backlog @desktop
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

  @backlog @desktop
  Scenario: A whitespace-ignoring diff drops a comment in progress
    Given the user began a line comment on line 12 of "src/cart.ts"
    When the user hides whitespace changes
    Then the line comment in progress is dropped and the selection cleared

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

  @backlog @desktop
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
  @backlog @desktop
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

  @backlog @desktop
  Scenario: The file tree remembers whether it was open
    Given the user opened the file tree while reading the code of a pull request
    When the user reads the code of another pull request
    Then the file tree is open

  @backlog @mobile
  Scenario: The phone reviews without the code
    When the user opens pull request 42 on the phone
    Then the conversation and checks are shown without the diff

  @mc
  Scenario: Images in a private pull request are fetched by the MC
    Given the description of pull request 42 holds an image uploaded to GitHub
    When the user reads the description
    Then the MC fetches the image with its GitHub credentials
    And the client never receives the GitHub token

  @backlog @mc
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
      | GitLab       | request changes         | This host cannot request changes on a change request.  |
      | Forgejo      | reply to a conversation | This host cannot reply to a review conversation.       |
      | Forgejo      | resolve a conversation  | This host cannot resolve a review conversation.        |

  @backlog @mc
  Scenario: A reader may comment and decide on a pull request they did not open
    Given the user has only read access to "acme/shop"
    When the user looks at what they may do on pull request 42
    Then commenting, approving and requesting changes are offered

  @backlog @mc
  Scenario: A reader who neither wrote nor opened the pull request cannot resolve a conversation
    Given the user has only read access to "acme/shop"
    And an unresolved review thread
    When the user resolves it
    Then the user is told "You need write access on this repository, or to have opened this change request, to resolve a review conversation."

  @backlog @mc
  Scenario: The author may resolve a conversation with read access only
    Given pull request 42 is the user's own
    And the user has only read access to "acme/shop"
    And an unresolved review thread
    When the user resolves it
    Then the thread is resolved

  @backlog @mc
  Scenario: A reply cannot be empty
    Given a review thread on line 12 of "src/cart.ts"
    When the user replies with only spaces
    Then the user is told "A reply cannot be empty."

  @backlog @mc
  Scenario Outline: Something that belongs to another pull request is refused
    Given a comment that belongs to pull request 7
    When the user tries to <request> as part of pull request 42
    Then the user is told "The named subject did not belong to the named pull request."

    Examples:
      | request                       |
      | react to it                   |
      | edit it                       |
      | load more replies of its thread |

  @backlog @mc
  Scenario Outline: A very long conversation is cut short and says so
    Given a pull request on <host> whose conversation runs to more than ten full pages
    When the user opens its conversation
    Then the pages read so far are shown
    And the conversation says it was cut short

    Examples:
      | host      |
      | GitHub    |
      | GitLab    |
      | Bitbucket |

  @backlog @mc
  Scenario: A dismissed review says why it was dismissed
    Given a review on pull request 42 that was dismissed with the reason "Superseded by the rewrite"
    When the user opens the conversation of pull request 42
    Then the review is shown as dismissed with that reason

  @backlog @mc
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

  @backlog @mc
  Scenario: A diff position the pull request never handed out is refused
    When a client asks for the diff of pull request 42 from a position it was not given
    Then the user is told "The diff cursor was not one this pull request handed out."

  @backlog @mc
  Scenario: A commit that is not a commit id is refused
    When a client asks for the code of pull request 42 at the commit "../main"
    Then the user is told "The named commit was not a commit sha."

  @backlog @mc
  Scenario: A page of changes that was cut off is a failure, not a short diff
    Given the host's answer for one page of the changed files of pull request 42 is cut off part-way
    When the user opens its code
    Then the read fails
    And the diff is not shown as complete

  @backlog @mc
  Scenario: A file whose changes the host withheld is listed with its line counts
    Given the host withholds the changes of "db/seed.sql" in pull request 42 because they are too large
    When the user opens its code
    Then "db/seed.sql" is listed with its added and removed line counts and no changes

  @backlog @mc
  Scenario Outline: A changed file that cannot be expanded says why
    Given <situation>
    When the user expands the unchanged lines around a change in "<path>"
    Then the user is told "<message>"

    Examples:
      | situation                                                    | path         | message                                                       |
      | "db/seed.sql" is larger than one megabyte                    | db/seed.sql  | The diff file 'db/seed.sql' exceeds the 1 MB expansion limit. |
      | "logo.png" is a binary file                                  | logo.png     | The diff file 'logo.png' is binary.                           |
      | the host reports no usable base and head for pull request 42 | src/cart.ts  | Pull request #42 reported no usable base and head revisions.  |

  @backlog @mc
  Scenario: A file added by a root commit expands without an old side
    Given the commit being reviewed is the first commit of the repository and adds "README.md"
    When the user expands the unchanged lines of "README.md"
    Then the file's contents are shown without asking for a parent version

  @backlog @mc
  Scenario: A large Azure DevOps change arrives in slices bounded by size and effort
    Given an Azure DevOps pull request whose change is larger than one slice may carry
    When the user opens its code
    Then each slice stops at its size and effort ceiling
    And the next slice carries on from where the last one stopped

  @backlog @mc
  Scenario: A file too heavy to compare is listed without its changes on Azure DevOps
    Given an Azure DevOps pull request changes a file too large to compare
    When the user opens its code
    Then the file is listed in its place without its changes
    And the other files are shown with theirs

  @backlog @mc
  Scenario: Azure DevOps being unreachable fails the diff instead of hiding every file
    Given the connection to Azure DevOps fails while its code is being read
    When the user opens the code of an Azure DevOps pull request
    Then the read fails
    And the files are not listed as unreadable one by one

  @backlog @mc
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

  @backlog @mc
  Scenario: Checks are read in full where the host does not support conditional reads
    Given a GitHub host that does not support conditional reads of check results
    When the user reads the checks of pull request 42
    Then the checks are read in full each time

  @backlog @mc
  Scenario: A re-run of a check replaces the earlier run where it stood
    Given a check "build" ran twice on pull request 42 and the second run is newer
    When the user reads the checks of pull request 42
    Then "build" is listed once with the state of the newer run
    And it stays at the position of the first run

  @backlog @mc
  Scenario: Checks with the same name from different workflows are told apart
    Given the workflows "CI" and "Release" each have a check named "build"
    When the user reads the checks of pull request 42
    Then the checks are listed as "CI / build" and "Release / build"

  @backlog @mc
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

  @backlog @mc
  Scenario Outline: A Bitbucket pull request is mergeable only when it has no conflicting paths
    Given a Bitbucket pull request whose conflicts list has <paths>
    When the user opens it
    Then its mergeability is "<mergeability>"

    Examples:
      | paths             | mergeability |
      | no conflicting paths | mergeable    |
      | a conflicting path   | conflicting  |

  @backlog @mc
  Scenario: A GitLab merge request's pipeline is its one check
    Given a GitLab merge request has a pipeline of 12 jobs
    When the user reads its checks
    Then the pipeline is listed as one check named "Pipeline" with a link to it
    And the jobs behind it are not listed

  @backlog @mc
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
      | scheduled | neutral   |
      | running   | pending   |
      | created   | pending   |

  @backlog @mc
  Scenario: A GitLab merge request without a pipeline has no checks
    Given a GitLab merge request that never ran a pipeline
    When the user reads its checks
    Then no check is listed
    And the checks are not reported as failing or passing

  @backlog @mc
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

  @backlog @mc
  Scenario: Votes on a Bitbucket pull request read as reviews
    Given on a Bitbucket pull request "alice" approved and "bob" was only added as a reviewer
    When the user reads the conversation
    Then "alice" appears with a review
    And "bob" does not

  @backlog @mc
  Scenario: A locked GitLab merge request is still open
    Given a GitLab merge request whose discussion is locked
    When the user lists it
    Then it is listed as open

  @backlog @mc
  Scenario: A GitHub review is sent as one request so nothing shows before the verdict
    Given the user wrote 3 line comments and a summary for pull request 42
    When the user submits the review with the verdict "comment"
    Then GitHub receives the comments, the summary and the verdict in one request
    And nobody else sees any of them before that request is accepted

  @backlog @mc
  Scenario: A GitLab review is posted piece by piece with the approval last
    Given the user wrote 3 line comments and a summary for a GitLab merge request
    When the user submits the review with the verdict "approve"
    Then the line comments are posted first, then the summary, then the approval

  @backlog @mc
  Scenario: A GitLab review that fails part-way is never an approval
    Given the user wrote 3 line comments and a summary for a GitLab merge request
    And GitLab refuses the second line comment
    When the user submits the review with the verdict "approve"
    Then the user is told the review failed
    And the first line comment stays posted
    And the merge request is not approved

  @backlog @mc
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

  @backlog @mc
  Scenario Outline: Words the user typed never travel on a command line
    Given the user types "<words>"
    When the user <action> through the MC on <host>
    Then the words reach the host through its standard input rather than its arguments
    And the words are not in any error that is reported

    Examples:
      | words        | action                       | host      |
      | true         | comments on a pull request   | GitLab    |
      | 42           | edits a comment              | GitLab    |
      | LGTM         | submits a review             | GitHub    |
      | tax label:bug | searches pull requests       | GitHub    |

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

  @backlog @mc
  Scenario Outline: A host that cannot rewrite <what> refuses the edit
    Given an open change request on a host that does not support editing <what>
    When the user rewrites the <what>
    Then the user is told "<message>"
    And nothing is sent to the host

    Examples:
      | what                       | message                                 |
      | title and description      | This host cannot rewrite a change request. |
      | comments                   | This host cannot rewrite a comment.        |

  @backlog @mc
  Scenario: A comment cannot be edited into nothing
    Given the user commented "Looks good" on pull request 42
    When the user edits the comment to only spaces
    Then the user is told "A comment cannot be empty."
    And the comment still reads "Looks good"

  # Legacy: apps/server/src/pullRequest/gitHubPullRequestJson.ts (REACTORS_PER_GROUP, toReactions)
  @backlog @mc
  Scenario: A reaction names a handful of the people who gave it and counts the rest
    Given twelve people reacted with a heart to a comment on pull request 42
    When the user opens the conversation of pull request 42
    Then the heart shows a count of 12
    And at most ten of the people who reacted are named

  # Legacy: apps/server/src/pullRequest/gitHubPullRequestJson.ts (toReviewDecisionWithReviews)
  @backlog @mc
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
  @backlog @mc
  Scenario: An Azure DevOps thread tied to a file is a line comment and the others are plain comments
    Given an Azure DevOps pull request with one thread on "src/cart.ts" and one thread on no file
    When the user opens its conversation
    Then the thread on "src/cart.ts" is listed as a comment on that file
    And the other thread is listed as a plain comment
    And the replies of each thread follow it oldest first

  # Legacy: apps/server/src/pullRequest/bitbucketPullRequestJson.ts (buildReviewThreads)
  @backlog @mc
  Scenario: A Bitbucket reply to a reply belongs to the conversation of the comment that began it
    Given a Bitbucket line comment, a reply to it, and a reply to that reply
    When the user opens the review threads
    Then the three comments form one thread, in order
    And the thread is placed on the line of the first comment

  # Legacy: apps/server/src/pullRequest/bitbucketPullRequestJson.ts (buildReviewThreads: orphan reply)
  @backlog @mc
  Scenario: A Bitbucket reply whose original cannot be read stays in the conversation without a thread of its own
    Given a Bitbucket reply whose parent comment was deleted
    When the user opens the conversation
    Then the reply is listed with the other comments
    And no review thread is made of it

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestProvider.ts (getChangeRequestActivity)
  @backlog @mc
  Scenario: An Azure DevOps conversation that cannot be found or read says it was cut short
    Given Azure DevOps cannot say where the conversation of pull request 42 is kept
    When the user opens the conversation of pull request 42
    Then no comments are listed
    And the conversation says it was cut short
    And no review threads or commits are listed

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestProvider.ts, azureDevOpsDiff.ts (cursor)
  @backlog @mc
  Scenario: Slices of an Azure DevOps change stay on the push they began with
    Given the user is reading the code of an Azure DevOps pull request in slices
    And the author pushes again between two slices
    When the next slice is read
    Then it carries on from the push the first slice was read at
    And no file is repeated or skipped

  # Legacy: apps/server/src/pullRequest/azureDevOpsDiff.ts (cursor parsing)
  @backlog @mc
  Scenario: A position that is not one the MC handed out starts an Azure DevOps diff from the top
    Given a client holds a diff position that did not come from Azure DevOps
    When it asks for the next slice of an Azure DevOps pull request
    Then the diff starts again from its first file

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestCli.ts (change pages ceiling), azureDevOpsPullRequestJson.ts (folders)
  @backlog @mc
  Scenario: An Azure DevOps change list longer than the MC will follow says it was cut short
    Given an Azure DevOps pull request whose list of changed files runs past the longest list the MC follows
    When the user opens its code
    Then the files read are listed
    And the diff says it is incomplete

  @backlog @mc
  Scenario: A folder in an Azure DevOps change is not listed as a file
    Given an Azure DevOps pull request whose change includes a folder
    When the user opens its code
    Then only the files inside it are listed

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestCli.ts (getPullRequestDetail: checksTruncated)
  @backlog @mc
  Scenario: More checks than one read holds are all read before the pull request is called passing
    Given pull request 42 has 130 checks and the first 100 of them passed
    And the 101st failed
    When the user reads the checks of pull request 42
    Then all 130 checks are read
    And the pull request is reported as failing

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestCli.ts (getPullRequestDetail: head changed while reading checks)
  @backlog @mc
  Scenario: Checks are not put together across a push made while they were being read
    Given pull request 42 has more checks than one read holds
    And the author pushes while the rest of the checks are being read
    When the user reads the checks of pull request 42
    Then the read fails with "Pull request head changed while reading checks."
    And the checks of the older push are not shown as the checks of the new one

  # Legacy: apps/server/src/pullRequest/gitHubPullRequestJson.ts (commitStats: parents)
  @backlog @mc
  Scenario: A merge commit of the base into the branch shows no line counts of its own
    Given the branch of pull request 42 has a commit that merged the base branch in
    When the user opens the timeline of pull request 42
    Then that commit is listed without line counts
    And the other commits keep theirs

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestProvider.ts (rendersEmpty, dismissalsByReviewId)
  @backlog @mc
  Scenario: A dismissed review whose words are only a hidden marker shows the reason it was dismissed
    Given a bot review on pull request 42 that was dismissed with the reason "Superseded"
    And the review's own text is only an HTML comment
    When the user opens the conversation of pull request 42
    Then the review is shown with the reason "Superseded"

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestProvider.ts (withAvatar, loginAvatarUrl)
  @backlog @mc
  Scenario Outline: An author the host gave no picture for gets the host's picture for their login, apps excepted
    Given a comment on pull request 42 by <author>, for whom the host sent no picture
    When the user opens the conversation of pull request 42
    Then <result>

    Examples:
      | author                      | result                                            |
      | "octocat"                   | the picture GitHub keeps for "octocat" is used    |
      | the app "dependabot[bot]"   | no picture is made up, and the author is a bot    |

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts (setReaction)
  @backlog @mc
  Scenario: Taking back a reaction that is already gone is not an error
    Given the user's heart on a comment of a GitLab merge request was already removed elsewhere
    When the user takes the heart back
    Then nothing fails
    And the comment shows no heart from the user

  # Legacy: apps/server/src/pullRequest/ForgejoPullRequestProvider.ts (setReaction, reviewCommentId)
  @backlog @mc
  Scenario: A reaction to a Forgejo review goes to the comment the review made
    Given a Forgejo review with the words "Looks good"
    When the user reacts with a heart to the review
    Then the heart is given to the comment that review made on the host

  @backlog @mc
  Scenario: A Forgejo review that made no comment cannot be reacted to
    Given a Forgejo review the host reports no comment for
    When the user reacts with a heart to the review
    Then the user is told "Forgejo did not return a comment ID for this review."

  # Legacy: apps/server/src/pullRequest/forgejoPullRequestJson.ts (forgejoChecks)
  @backlog @mc
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
  @backlog @mc
  Scenario: A Forgejo line comment on a removed line is placed on the old side, and resolved when the host says so
    Given a Forgejo line comment made on a line the pull request removed
    And the host names who resolved it
    When the user opens the review threads
    Then the thread is placed on the old side of that line
    And it is resolved

  # Legacy: apps/server/src/pullRequest/ForgejoPullRequestProvider.ts (getChangeRequestActivity: 500 items)
  @backlog @mc
  Scenario: A Forgejo conversation longer than five hundred entries says it was cut short
    Given a Forgejo pull request whose comments, reviews and line comments run past five hundred entries
    When the user opens its conversation
    Then the first five hundred are shown
    And the conversation says it was cut short

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts (getDiffRefs: GitLabDiffRefsUnavailableError)
  @backlog @mc
  Scenario: A GitLab merge request with no diff revisions cannot take line comments
    Given a GitLab merge request that reports no diff revisions
    When the user submits a review with a line comment on it
    Then the user is told "The merge request reported no diff revisions."
    And nothing is posted

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts (getCommitDiffRefs: GitLabDiffCommitParentUnavailableError)
  @backlog @mc
  Scenario: A file a first commit changed but did not add cannot be expanded
    Given a GitLab commit with no parent that changes "src/cart.ts" and does not add it
    When the user expands the unchanged lines of "src/cart.ts" in that commit
    Then the user is told the commit reported no parent revision

  # Legacy: apps/server/src/pullRequest/GitLabPullRequestCli.ts, bitbucketPullRequestJson.ts, forgejoPullRequestProvider (update title or description alone)
  @backlog @mc
  Scenario Outline: Changing one of title and description leaves the other as it was
    Given an open change request on <host> with a title and a description
    When the user changes only its <field>
    Then only the <field> is sent to the host
    And the other one still reads as before

    Examples:
      | host      | field       |
      | GitLab    | title       |
      | GitLab    | description |
      | Bitbucket | title       |
      | Forgejo   | description |
