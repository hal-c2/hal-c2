# Sources:
#   plugins/code-review/plugin.json (settings, permissions, pages, thread kinds)
#   plugins/code-review/mc/code_review.ex (watching, triggers, review runs, findings, publishing)
#   plugins/code-review/ui/ReviewsPage.qml, ReviewHeader.qml, ReviewRowMark.qml, ReviewSettings.qml
#   apps/server-ex/lib/hal_c2/pull_requests.ex (list, detail, submitReview through gh)
#   plugins/code-review/mc/checkout.ex (a pull request's worktree)
#   docs/user/code-review.md

@plugin-code-review
Feature: Agent code review
  The code-review plugin has an agent review pull requests on the user's source control
  host. The user picks the host, which repositories it watches and when it starts, the
  agent and the prompt it gets, and what happens with what it finds. Reviews show up as
  a page, as threads that look like reviews, or both.

  Background:
    Given an MC running the plugin "code-review" with GitHub as its host
    And the project "api" whose remote is "acme/api" on GitHub

  Rule: The user decides what is watched and when a review starts

    @mc
    Scenario: A watched repository's new pull request is reviewed automatically
      Given "code-review" watches "acme/api" automatically
      When the pull request #12 is opened on "acme/api"
      Then a review of #12 starts with the configured agent

    @mc
    Scenario: A repository that is not watched is left alone
      Given "code-review" watches "acme/web" automatically
      When the pull request #12 is opened on "acme/api"
      Then no review starts

    @mc
    Scenario: In selective mode nothing is reviewed until the user asks
      Given "code-review" watches "acme/api" selectively
      When the pull request #12 is opened on "acme/api"
      Then no review starts
      And #12 is listed as ready to review

    @mc
    Scenario: The user starts a review of one pull request
      Given "code-review" watches "acme/api" selectively
      When the user asks for a review of #12
      Then a review of #12 starts

    @mc
    Scenario Outline: A selective trigger starts a review
      Given "code-review" watches "acme/api" selectively with the trigger "<trigger>"
      When <event>
      Then a review of #12 starts

      Examples:
        | trigger              | event                                                    |
        | review requested     | the user is requested as a reviewer of #12               |
        | label                | #12 gets the label "agent-review"                        |
        | comment command      | someone comments "/review" on #12                         |

    @mc
    Scenario: The same commit is not reviewed twice
      Given #12 was reviewed at its current head commit
      When "code-review" looks at "acme/api" again
      Then no new review of #12 starts

    @mc
    Scenario: A new push is reviewed again when the user wants that
      Given "code-review" reviews new pushes
      And #12 was reviewed at an older head commit
      When "code-review" looks at "acme/api" again
      Then a new review of #12 starts for the new head commit

    @mc
    Scenario: A new push is left alone when the user does not want re-reviews
      Given "code-review" does not review new pushes
      And #12 was reviewed at an older head commit
      When "code-review" looks at "acme/api" again
      Then no new review of #12 starts
      And #12 is listed as changed since its review

    @mc
    Scenario Outline: Filters keep some pull requests out of automatic review
      Given "code-review" watches "acme/api" automatically and <filter>
      When <pull request> is opened on "acme/api"
      Then no review starts

      Examples:
        | filter                                 | pull request                         |
        | skips drafts                           | the draft pull request #12           |
        | ignores the author "dependabot[bot]"   | #12 by "dependabot[bot]"             |
        | skips changes over 2000 lines          | #12 changing 5000 lines              |

    @mc
    Scenario: No more reviews run at once than the user allows
      Given "code-review" runs at most 2 reviews at once
      When four watched pull requests are opened
      Then two reviews run and two wait their turn

  Rule: The agent and its prompt are the user's to set

    @mc
    Scenario: The settings offer the MC's agents and the repositories of its projects
      When the settings of "code-review" are opened
      Then the MC's agents are offered with their models
      And "acme/api" is offered as a repository to watch

    @mc
    Scenario: A review runs with the provider, model and mode the user picked
      Given "code-review" reviews with Claude on "claude-sonnet-5-5" in the "auto-accept-edits" mode
      When #12 is reviewed
      Then its thread runs Claude with that model and mode

    @mc
    Scenario: The review prompt is the user's template filled in for the pull request
      Given the review prompt template is "Review {{pr.title}} against {{pr.base}}. Focus on security."
      When #12 "Add rate limits" into "main" is reviewed
      Then the agent is asked "Review Add rate limits against main. Focus on security."
      And it is told how to report what it finds

    @mc
    Scenario: A repository's own review instructions are added to the prompt
      Given "acme/api" has extra review instructions "Never approve schema changes"
      When #12 is reviewed
      Then the agent's prompt includes "Never approve schema changes"

    @mc
    Scenario: The repository's REVIEW.md is followed when the user wants that
      Given "code-review" reads REVIEW.md
      And the head of #12 has a REVIEW.md saying "Check the changelog"
      When #12 is reviewed
      Then the agent's prompt includes "Check the changelog"

    @mc
    Scenario Outline: A REVIEW.md the prompt cannot take is left out of it
      Given "code-review" reads REVIEW.md
      And the head of #12 has a REVIEW.md that <is>
      When #12 is reviewed
      Then the agent's prompt does not include "<text>"

      Examples:
        | is                                          | text                  |
        | links to a file outside its repository      | outside the checkout  |
        | is longer than a prompt takes               | a very long REVIEW.md |

    @mc
    Scenario: The prompt template can be reset to the plugin's default
      Given the user changed the review prompt template
      When the user resets the review prompt
      Then the next review uses the plugin's default prompt

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Resetting the prompt leaves the user's other changes unsaved
      Given the user opens the settings of "code-review"
      And the user changed the review prompt and turned off REVIEW.md
      When the user resets the review prompt
      Then only the prompt is saved
      And REVIEW.md is still turned off, waiting to be saved

    @mc
    Scenario: The agent reviews the pull request's own code
      When #12 is reviewed
      Then its thread works in a checkout of the head of #12
      And the user's own checkout of "api" is not touched

  Rule: What the agent finds is structured

    @mc
    Scenario: The agent reports a verdict, a summary and line comments
      Given a review of #12 is running
      When the agent reports the verdict "changes requested" with two comments on "src/limits.ts"
      Then the review of #12 is finished with that verdict, summary and comments

    @mc
    Scenario: A review whose agent never reports is finished as failed
      Given a review of #12 is running
      When the agent's turn ends without a report
      Then the review of #12 is failed saying the agent gave no findings

    @mc
    Scenario: A review whose agent fails can be tried again
      Given the review of #12 failed
      When the user retries the review of #12
      Then a new review of #12 starts

    @mc
    Scenario: Retrying a review that is running leaves the run it has
      Given a review of #12 is running
      When the user retries the review of #12
      Then the review of #12 is still running in the same thread

    @mc
    Scenario: A running review cannot be discarded
      Given a review of #12 is running
      When the user discards the review of #12
      Then the user is told the review of #12 is running
      And the review of #12 is still running in the same thread

    @mc
    Scenario: A review the plugin stopped during can be tried again, and still takes its findings
      Given a review of #12 is running
      When "code-review" is restarted
      Then the review of #12 is failed saying the plugin stopped while it ran
      And its agent can still report what it found

    @mc
    Scenario: A review whose agent is not on the MC leaves no checkout behind
      Given "code-review" reviews with an agent the MC does not have
      When the user asks for a review of #12
      Then the review of #12 is failed saying there is no such agent
      And no checkout of #12 is left

    @mc
    Scenario Outline: A comment on a file whose name git quotes stays on its line
      Given the head of #12 adds the file "<file>"
      And a review of #12 is running
      When the agent reports a comment on line 1 of "<file>"
      Then the comment sits on line 1 of "<file>"

      Examples:
        | file              |
        | src/café.ts       |
        | src/with space.ts |

    @mc
    Scenario: A comment on a line the pull request does not change is kept as a general comment
      When the agent reports a comment on a line that is not in the diff of #12
      Then the comment is kept in the review's summary instead of on the line

  Rule: The user decides what happens with the findings

    @mc
    Scenario Outline: The publishing mode decides what reaches the host
      Given the publishing mode for "acme/api" is "<mode>"
      When the review of #12 finishes with two comments
      Then <outcome>

      Examples:
        | mode      | outcome                                                                     |
        | local     | nothing can be posted to "acme/api" and the review stays in HAL-C2          |
        | draft     | the review waits for the user to publish it                                 |
        | automatic | the review is posted to #12 as a review with both line comments             |

    @mc
    Scenario: The user publishes a draft review with the comments they kept
      Given the review of #12 is waiting with three comments
      When the user dismisses one comment and publishes the review
      Then #12 gets a review with the two remaining comments and the verdict
      And the review of #12 is marked as published

    @mc
    Scenario: A review is posted on the commit it reviewed, not one pushed since
      Given the review of #12 is waiting to be published
      And #12 gets a new push
      When the user publishes the review of #12
      Then #12 gets a review of the commit that was reviewed

    @mc
    Scenario: A verdict can be posted as a plain comment instead of a decision
      Given the user posts verdicts as comments
      When the user publishes the review of #12 with the verdict "changes requested"
      Then #12 gets a commented review rather than a request for changes

    @mc
    Scenario: A failed publish keeps the review
      Given the review of #12 is waiting to be published
      And GitHub refuses the review
      When the user publishes the review of #12
      Then the user is told GitHub's reason
      And the review of #12 is still waiting with its comments

    @mc
    Scenario: A review being posted is not posted twice
      Given the publishing mode for "acme/api" is "automatic"
      And GitHub is slow to take reviews
      When the review of #12 finishes with two comments
      And the user publishes the review of #12 while it is being posted
      Then the user is told the review is already being posted
      And once GitHub has it, #12 has one review and it is marked as published

    @mc
    Scenario: A post that comes back after the review ran again leaves the new run alone
      Given the publishing mode for "acme/api" is "automatic"
      And GitHub is slow to take reviews
      When the review of #12 finishes with two comments
      And the user retries the review of #12 while it is being posted
      And the post of the earlier run comes back
      Then the new review of #12 is not marked as published

    @mc
    Scenario: Turning code-review off calls off a post it has not finished
      Given the publishing mode for "acme/api" is "automatic"
      And GitHub is slow to take reviews
      When the review of #12 finishes with two comments
      And "code-review" is turned off while the review of #12 is being posted
      Then the post to GitHub is called off
      And once "code-review" is turned back on, the review of #12 is waiting to be published

  Rule: Reviews show up where the user wants them

    @mc
    Scenario Outline: The display setting decides whether review threads are listed
      Given "code-review" shows reviews as "<display>"
      When #12 is reviewed
      Then its thread is <listed>

      Examples:
        | display | listed                        |
        | page    | not listed with the threads   |
        | threads | listed with the threads       |
        | both    | listed with the threads       |

    @mc
    Scenario: A review thread's clients follow the state of its review
      Given a review of #12 is running
      When the agent reports the verdict "changes requested" with two comments on "src/limits.ts"
      Then the clients of its thread see a review of #12 waiting with the verdict "changes requested"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The reviews page lists reviews by state
      Given reviews of #12 running, #13 waiting to be published and #14 failed
      When the user switches to the "Reviews" tab
      Then #12, #13 and #14 are listed with their states

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The reviews page shows a review's findings and publishes them
      Given the review of #13 is waiting with two comments
      When the user opens the review of #13 on the "Reviews" page
      Then its verdict, summary and comments are shown
      And the user can publish it or dismiss comments

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A review thread shows the pull request and the verdict above the conversation
      Given the review of #13 finished with the verdict "approved"
      When the user opens the review's thread
      Then the pull request, the verdict and the publish action are shown above the conversation

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A review thread is marked as a review in the thread list
      Given "code-review" shows reviews as "threads"
      When #12 is reviewed
      Then its thread is listed with the review mark and the state of the review

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user starts a review from the reviews page
      Given "code-review" watches "acme/api" selectively
      When the user starts a review of #12 from the "Reviews" tab
      Then the review of #12 is listed as running

  Rule: The host is the user's choice

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings offer each source control host
      When the user opens the settings of "code-review"
      Then GitHub, GitLab, Forgejo, Bitbucket and Azure DevOps are offered as hosts
      And only GitHub can be chosen today

    @mc
    Scenario: GitHub reviews use the gh login of the MC's machine
      Given gh is not signed in on the MC's machine
      When "code-review" looks at "acme/api"
      Then "code-review" reports that gh needs to sign in
      And no review starts

    @backlog @mc
    Scenario Outline: Other hosts can be reviewed
      Given "code-review" uses <host> as its host
      When a watched pull request is opened there
      Then a review of it starts

      Examples:
        | host         |
        | GitLab       |
        | Forgejo      |
        | Bitbucket    |
        | Azure DevOps |
