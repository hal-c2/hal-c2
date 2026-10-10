# Sources:
#   docs/user/source-control.md (Pull requests page)
#   packages/contracts/src/pullRequest.ts (PullRequestListInput, PullRequestListResult, PullRequestProviderSummary, PullRequestUnavailableError)
#   packages/contracts/src/rpc.ts (pullRequests.list, pullRequests.listStats, pullRequests.summary, pullRequests.invalidate, pullRequests.subscribeRefreshes)
#   apps/server-ex/lib/hal_c2/pull_requests.ex (list, list_stats, summary, invalidate)
#   apps/server-ex/lib/hal_c2/pull_requests/refreshes.ex
#   apps/web/src/hooks/useLiveRefresh.ts, apps/web/src/hooks/usePullRequestChecksRefresh.ts (when an open view reads again)
#   apps/web/src/components/pullRequest/pullRequestList.logic.ts
#   apps/web/src/state/pullRequests.ts (which snapshot of a pull request wins when views disagree)
#   apps/web/src/components/pullRequest/PullRequestListFilters.tsx
#   apps/web/src/components/pullRequest/PullRequestListEmptyState.tsx
#   apps/web/src/components/pullRequest/PullRequestListRow.tsx
#   apps/web/src/components/pullRequest/PullRequestRow.tsx, pullRequestListLines.ts
#   apps/web/src/components/pullRequest/pullRequestProjectFilter.logic.ts
#   apps/web/src/components/pullRequest/pullRequestListPreferences.ts
#   apps/web/src/routes/_chat.pull-requests.tsx (paging, search, carried rows, server scope, panel shortcuts, links)
#   apps/web/src/components/pullRequest/pullRequestProjectAssignment.logic.ts, pullRequestProjectFilter.logic.test.ts
#   apps/web/src/components/pullRequest/pullRequestPresentation.test.ts (state and conflict presentation)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Pull requests)
#   apps/desktop-qt/parity/features.backlog.test.ts (right panel pull request list)
#   apps/desktop-qt/src/native/PullRequestListController.cpp
#   apps/server/src/sourceControl/SourceControlRateLimit.ts (host pauses)
#   apps/server/src/sourceControl/githubGraphQlBudget.ts (GitHub read quota reserve)
#   apps/server/src/sourceControl/GitHubCli.ts (rate limit answers, quota per credential)
#   apps/server/src/pullRequest/PullRequestService.ts (withRateLimitBackoff)
#   apps/server/src/pullRequest/PullRequestService.ts (list, cursors, cache and coalescing)
#   apps/server/src/pullRequest/GitHubPullRequestCli.ts (listPullRequests, search, fallback)
#   apps/server/src/pullRequest/GitLabPullRequestCli.ts, gitLabMergeRequestJson.ts
#   apps/server/src/pullRequest/ForgejoPullRequestProvider.ts
#   apps/server/src/pullRequest/AzureDevOpsPullRequestCli.ts, azureDevOpsPullRequestJson.ts, AzureDevOpsPullRequestProvider.ts
#   apps/server/src/pullRequest/gitHubPullRequestJson.ts (team review requests)
#   apps/server/src/pullRequest/BitbucketPullRequestApi.ts, bitbucketPullRequestJson.ts
#   apps/server/src/sourceControl/gitLabMergeRequests.ts, forgejoPullRequests.ts, azureDevOpsPullRequests.ts, bitbucketPullRequests.ts (draft markers, web addresses)
#   apps/web/src/components/ChatView.tsx (a pull request tab beside a thread on an environment that cannot read pull requests)

Feature: Browsing pull requests
  The pull requests page gathers pull requests from every project in the workspace, with
  filters for who is involved, state, drafts, reviews, checks, labels and authors.

  Background:
    Given a connected environment with the GitHub projects "acme/shop" and "acme/api"
    And the GitHub CLI is installed and signed in

  @mc
  Scenario Outline: Listing by involvement
    When the user lists pull requests <involvement>
    Then only pull requests <which> are listed

    Examples:
      | involvement           | which                                   |
      | from all involvement  | in either project                       |
      | the user is reviewing | where the user's review is requested    |
      | the user authored     | the user opened                         |

  @mc
  Scenario Outline: Listing by state
    When the user lists <state> pull requests
    Then every listed pull request is <state>

    Examples:
      | state  |
      | open   |
      | closed |
      | merged |

  @mc
  Scenario Outline: Narrowing the list with filters
    When the user lists open pull requests with <filter>
    Then only pull requests matching <filter> are listed

    Examples:
      | filter                         |
      | drafts only                    |
      | drafts hidden                  |
      | changes requested              |
      | review required                |
      | failing checks                 |
      | passing checks                 |
      | the label "bug"                |
      | the author "octocat"           |
      | the author being the user      |

  @mc
  Scenario: Searching every host
    When the user searches pull requests for "tax label:bug"
    Then the search runs on GitHub for each project
    And matching pull requests are listed

  @mc
  Scenario: A long list carries on where it left off
    Given "acme/shop" has 200 open pull requests
    When the user loads more pull requests
    Then the next pull requests follow without repeating any

  # Legacy: apps/web/src/state/pullRequests.ts (compareSummaries, newestPullRequestObservation)
  @backlog @desktop
  Scenario: A pull request that shows as merged is not shown as open again by a slower read
    Given a view shows pull request 42 as merged
    When a read of pull request 42 that began earlier arrives showing it open
    Then pull request 42 still shows as merged in every view

  @backlog @desktop
  Scenario: The same pull request shows the same status in the list and in its own view
    Given pull request 42 is open in the list and in the thread that links it
    When one of them reads newer status from the host
    Then both show the newer status

  @backlog @desktop
  Scenario: A newer read that omits review or check status keeps what was known
    Given a row shows pull request 42 as approved with passing checks
    When a newer read arrives without review or check status
    Then the row still shows approved with passing checks

  @mc
  Scenario: Diff sizes and review counts arrive after the list
    When the user lists open pull requests
    Then the rows arrive first and their line counts follow

  @mc
  Scenario: A project on another host is shown as not browsable yet
    Given the project "infra" has its remote on GitLab
    When the user lists pull requests
    Then GitLab is listed as not configured with "This host cannot be browsed here yet."

  @backlog @mc
  Scenario Outline: Listing change requests on other hosts
    Given the project "infra" has its remote on <host>
    When the user lists open pull requests
    Then the open change requests of "infra" are listed

    Examples:
      | host         |
      | GitLab       |
      | Forgejo      |
      | Azure DevOps |
      | Bitbucket    |

  @mc
  Scenario Outline: The list explains why a host cannot be read
    Given <condition>
    When the user lists pull requests
    Then "acme/shop" reports it is unavailable because <reason>

    Examples:
      | condition                               | reason                                          |
      | the GitHub CLI is not installed         | the GitHub CLI is required and how to install it |
      | the GitHub CLI is not signed in         | the user should run gh auth login and retry     |

  @mc
  Scenario: One failing project does not hide the others
    Given "acme/api" cannot be read
    When the user lists pull requests
    Then the pull requests of "acme/shop" are listed
    And "acme/api" reports its own error with the host's reason

  # Legacy: apps/server/src/sourceControl/SourceControlRateLimit.ts (check, recordRateLimit, recordSuccess)
  @mc @backlog
  Scenario: A host that rate limits HAL-C2 is left alone for a while
    Given GitHub answers a read with a rate limit and no time to retry
    When the user lists pull requests again straight away
    Then no request goes to GitHub
    And the projects on GitHub report they are paused until the rate limit resets and when
    And the pause is 30 seconds the first time, doubles each time the limit is hit again and never passes 15 minutes
    And the first answer that succeeds ends the pause and the doubling

  # Legacy: apps/server/src/sourceControl/SourceControlRateLimit.ts (retryAtFromHeader)
  @mc @backlog
  Scenario Outline: A host's own retry time sets the length of the pause
    Given the host rate limits a read and says to retry <retry>
    When the user lists pull requests before then
    Then no request goes to the host until that time
    And an earlier time from an older request never shortens a pause that is already longer

    Examples:
      | retry                                |
      | in 120 seconds                       |
      | at a date and time given in full     |

  # Legacy: apps/server/src/sourceControl/SourceControlRateLimit.ts (normalizedKey, CredentialScope)
  @mc @backlog
  Scenario: A pause belongs to one host and one signed-in account
    Given GitHub rate limits the account signed in for "acme/shop"
    When the user lists pull requests
    Then projects on a self-hosted GitHub or on another host are read as usual
    And projects read with another signed-in account on the same host are read as usual

  # Legacy: apps/server/src/pullRequest/PullRequestService.ts (withRateLimitBackoff, interactive)
  # Legacy: apps/server/src/sourceControl/SourceControlRateLimit.ts (check allowPaused)
  @mc @backlog
  Scenario: What the user asks for goes through a pause without ending it
    Given the host is paused after a rate limit
    When the user comments on a pull request or merges it
    Then the request is sent to the host
    And the pause is neither ended nor shortened by that request's answer

  # Legacy: apps/server/src/sourceControl/githubGraphQlBudget.ts (query, observe)
  @mc @backlog
  Scenario: Background reads leave a tenth of GitHub's quota for what the user asks for
    Given GitHub reported that fewer than a tenth of its read quota is left until it resets
    When a background refresh needs to read pull requests
    Then it waits until the quota resets
    But a read the user asked for is still sent while any quota is left

  # Legacy: apps/server/src/sourceControl/githubGraphQlBudget.ts (quota snapshots per credential)
  # Legacy: apps/server/src/sourceControl/GitHubCli.test.ts (keeps quota snapshots separate for verified credentials)
  @mc @backlog
  Scenario: An account that has used up its quota does not hold back another on the same host
    Given GitHub reported that the quota of one signed-in account is used up
    And another account is signed in on the same host with quota left
    When a background refresh reads pull requests with the second account
    Then the read is sent

  # Legacy: apps/server/src/sourceControl/GitHubCli.ts (executeRaw, acceptNotModified)
  # Legacy: apps/server/src/sourceControl/GitHubCli.test.ts (accepts conditional 304 responses and preserves HTTP errors and retry delays)
  @mc @backlog
  Scenario Outline: A refused re-read of unchanged data is told apart from a rate limit
    Given GitHub refuses a re-read of data that may be unchanged with <answer>
    When the user lists pull requests
    Then <outcome>

    Examples:
      | answer                                                     | outcome                                                       |
      | "forbidden" and nothing about a limit                      | the read fails without pausing the host                       |
      | "too many requests" and a time to retry in 120 seconds     | the host is paused for 120 seconds                            |
      | "forbidden", no quota left and a reset time 60 seconds on  | the host is paused until the reset time                       |
      | "forbidden" with text saying the rate limit was exceeded   | the host is paused with the usual back-off                    |
      | "unauthorized"                                             | the user is told to sign in to GitHub again                   |
      | a server error                                             | the read fails with GitHub's status and without pausing it    |

  @mc
  Scenario: Clients hear when the list changed
    Given the user is looking at the pull request list
    When someone merges a pull request from HAL-C2
    Then the client is told to refresh the list

  @mc
  Scenario: Forgetting cached answers
    When the user refreshes the pull request list by hand
    Then the MC reads the pull requests afresh

  @desktop @mobile @backlog-mobile
  Scenario: The pull requests page with its filters
    When the user opens the pull requests page
    Then pull requests from every project are listed with state, involvement, project and filter choices
    And the user's filter choices are kept for next time

  @desktop @mobile @backlog-mobile
  Scenario: Nothing under these filters
    Given no pull request matches the chosen filters
    When the user opens the pull requests page
    Then the user is told "Nothing under these filters" and to widen the filters

  @desktop
  Scenario Outline: The page's filters narrow the list
    Given the user is on the pull requests page
    When the user filters pull requests to <filter>
    Then the <which> pull requests are listed

    Examples:
      | filter        | which     |
      | drafts only   | draft     |
      | drafts hidden | non-draft |
      | merged ones   | merged    |

  @desktop
  Scenario: A workspace without pull requests says so
    Given the projects have no pull requests
    When the user opens the pull requests page
    Then the pull requests page says "No pull requests"

  @desktop
  Scenario: An environment that cannot be reached is named on the page
    Given the environment "env-lab" is offline
    When the user opens the pull requests page
    Then the open pull requests are listed
    And the pull requests page says "env-lab cannot be reached; its pull requests are not listed."

  @desktop
  Scenario: A list the MC cannot read can be retried
    Given the MC cannot list pull requests, saying "gh auth login is required."
    When the user opens the pull requests page
    Then the pull requests page shows the error "gh auth login is required." with a retry
    When the MC can list pull requests again
    And the user retries the pull requests page
    Then the open pull requests are listed

  @desktop
  Scenario: Refreshing the page asks the hosts afresh
    Given the user is on the pull requests page
    When the user refreshes the pull requests page
    Then the MC forgets what it knew and the list is read again

  @desktop
  Scenario: The page follows changes made from HAL-C2
    Given the user is on the pull requests page
    When a pull request is merged from HAL-C2
    Then the page lists it no longer

  @desktop
  Scenario: Leaving the page stops following changes
    Given the user is on the pull requests page
    When the user leaves the pull requests page
    Then the desktop stops listening for pull request changes

  @desktop
  Scenario: Opening a pull request opens the thread working on it
    Given the thread "Fix tax" works on #12
    And the user is on the pull requests page
    When the user opens #12 from the pull requests page
    Then the thread "Fix tax" opens

  @desktop
  Scenario: A pull request no thread works on says so
    Given the user is on the pull requests page
    When the user opens #7 from the pull requests page
    Then the pull requests page says "No thread works on #7 yet."

  @desktop
  Scenario: A pull request opens on its host
    Given the user is on the pull requests page
    When the user opens #12 on GitHub from the pull requests page
    Then the browser opens "https://github.com/acme/shop/pull/12"

  @desktop
  Scenario: A pull request list beside the thread
    When the user adds a pull requests tab to the right panel
    Then the open pull requests of the project are listed
    And opening one shows its review

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (rightPanelUnavailableLabel)
  @backlog @desktop
  Scenario: The side panel cannot be opened before a pull request is chosen
    Given the user is on the pull requests page and has chosen no pull request
    When the user looks at the control for the side panel
    Then it cannot be pressed and says "Select a pull request first"

  # Legacy: apps/web/src/components/pullRequest/PullRequestRow.tsx (selected)
  @backlog @desktop
  Scenario: The pull request that is open is marked in the list
    Given the user opened #12 from the pull requests page
    Then #12 is marked as the current row of the list
    And no other row is

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (copyPullRequestFromShortcut)
  @backlog @desktop
  Scenario Outline: The copy-reference shortcut copies the open pull request's link
    Given a pull request is open in the side panel of the pull requests page
    And <clipboard>
    When the user presses the shortcut to copy the reference
    Then the user sees a "<kind>" toast "<toast>"

    Examples:
      | clipboard                    | kind    | toast                |
      | the clipboard can be written | success | PR link copied       |
      | the clipboard cannot be written | error | Failed to copy PR link |

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (closeActiveSurfaceFromShortcut, toggleRightPanelFromShortcut)
  @backlog @desktop
  Scenario: The side panel shortcuts work on the pull requests page
    Given a pull request is open in the side panel of the pull requests page
    When the user presses the shortcut to close the active tab
    Then that pull request's tab is closed
    And the page is no longer narrowed to it
    When the user presses the shortcut to toggle the side panel
    Then the side panel is shown or hidden

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (status seeded from listed rows)
  @backlog @desktop
  Scenario: A tab shows the state the list knew before the pull request is read
    Given the list shows #12 as merged
    When the user opens #12 in the side panel
    Then its tab shows it as merged before its detail has been read

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (selection resolved from the address: repository, host)
  @backlog @desktop
  Scenario: A link that names only a repository and a number opens it in the project that holds it
    Given the user follows a link to pull request 12 of "acme/shop" that names no server or project
    When the page opens
    Then pull request 12 is open in the side panel
    And it belongs to the project of "acme/shop" on the host the link names

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (a named server still connecting is kept, an unknown one falls back)
  @backlog @desktop
  Scenario Outline: A link that names a server is opened through it, or through another that holds the project
    Given the user follows a link to pull request 12 of "acme/shop" that names a server <state>
    When the page opens
    Then <result>

    Examples:
      | state                     | result                                                              |
      | that is still connecting  | pull request 12 waits for that server and is then opened through it |
      | that the user does not have | pull request 12 is opened through a server that holds "acme/shop" |

  # Legacy: apps/web/src/components/pullRequest/pullRequestProjectFilter.logic.test.ts
  @backlog @desktop
  Scenario: The same repository on two hosts is two project choices
    Given "acme/shop" is a project on "github.com" and another project of that name is on "github.example.com"
    When the user opens the project menu
    Then the two are listed apart, told apart by their hosts

  # Legacy: apps/web/src/components/pullRequest/pullRequestProjectFilter.logic.test.ts (saved worktree selection stays)
  @backlog @desktop
  Scenario: A repository narrowed to by one of its worktrees is listed as that worktree
    Given "acme/shop" is a project and also has a worktree as a project
    And the page was saved narrowed to the worktree
    When the user opens the project menu
    Then "acme/shop" is listed once, as that worktree
    And the narrowing still applies

  @backlog @desktop
  Scenario Outline: A qualifier typed into the search becomes a filter
    Given the user is on the pull requests page
    When the user types "<typed>" into the search
    Then only <which> are listed
    And "<typed>" is not looked for as words

    Examples:
      | typed                    | which                                    |
      | label:bug                | pull requests labelled "bug"             |
      | -label:wip               | pull requests not labelled "wip"         |
      | author:octocat           | pull requests opened by "octocat"        |
      | draft:true               | draft pull requests                      |
      | draft:false              | pull requests that are not drafts        |
      | review:approved          | approved pull requests                   |
      | review:changes_requested | pull requests with changes requested     |
      | review:required          | pull requests still waiting for a review |
      | review:none              | pull requests with no review decision    |
      | checks:success           | pull requests whose checks pass          |
      | status:failing           | pull requests whose checks fail          |

  @backlog @desktop
  Scenario: Words and qualifiers can be typed together
    Given the user is on the pull requests page
    When the user types "tax label:bug" into the search
    Then pull requests labelled "bug" are listed
    And only the word "tax" is searched for

  @backlog @desktop
  Scenario Outline: A qualifier the search cannot apply stays as words
    Given the user is on the pull requests page
    When the user types "<typed>" into the search
    Then "<typed>" is searched for as words
    And no filter is added

    Examples:
      | typed          |
      | draft:maybe    |
      | review:unknown |
      | status:        |
      | -author:octo   |
      | -draft:true    |
      | -review:none   |

  @backlog @desktop
  Scenario Outline: A label qualifier can name several labels
    Given the user is on the pull requests page
    When the user types "<typed>" into the search
    Then <which> are listed

    Examples:
      | typed                | which                                                       |
      | label:bug,docs       | pull requests labelled "bug" or "docs"                      |
      | label:bug label:docs | pull requests labelled both "bug" and "docs"                |
      | -label:bug,docs      | pull requests carrying neither "bug" nor "docs"             |
      | label:"needs design" | pull requests labelled "needs design"                       |
      | label:"needs,triage" | pull requests labelled "needs,triage", not "needs" or "triage" |

  @backlog @desktop
  Scenario Outline: A label written with a colon is read as a label
    Given the user is on the pull requests page
    When the user types "<typed>" into the search
    Then <which> are listed

    Examples:
      | typed            | which                                                   |
      | size:XXL         | pull requests labelled "size:XXL"                       |
      | -area:web        | pull requests not labelled "area:web"                   |
      | size:S,XS        | pull requests labelled "size:S" or "size:XS"            |
      | size:S,size:XS   | pull requests labelled "size:S" or "size:XS"            |

  @backlog @desktop
  Scenario: Quoting a qualifier searches for it as written
    Given the user is on the pull requests page
    When the user types "\"size:XXL\"" into the search
    Then the words "size:XXL" are searched for
    And no label filter is added

  @backlog @desktop
  Scenario: A pasted link is searched for, not read as a label
    Given the user is on the pull requests page
    When the user types "https://github.com/acme/shop/pull/12" into the search
    Then the link is searched for as words
    And no label filter is added

  @backlog @desktop
  Scenario: A qualifier carries at most ten names of at most two hundred characters
    Given the user is on the pull requests page
    When the user types a label qualifier naming twelve labels, one of them 300 characters long
    Then only the first ten names are asked for
    And a name longer than 200 characters is cut to 200

  @backlog @desktop
  Scenario: Author "me" is the account signed in on each host
    Given the user is signed in as "octocat" on GitHub and as "olaf" on GitLab
    And the user is on the pull requests page
    When the user types "author:me" into the search
    Then the pull requests opened by "octocat" on GitHub are listed
    And the merge requests opened by "olaf" on GitLab are listed
    And a pull request opened by "olaf" on GitHub is not listed

  @backlog @desktop
  Scenario: Author "me" on a host that has not said who is signed in
    Given a host has not said which account is signed in
    When the user types "author:me" into the search
    Then pull requests from that host are matched against an author actually named "me"

  @backlog @desktop
  Scenario: Pull requests are grouped by how they involve the user
    Given the user opened #12, is asked to review #20 and has no part in #31
    When the user opens the pull requests page
    Then the groups "Authored", "Review requested" and "Others" are listed in that order
    And #12, #20 and #31 are under them respectively

  @backlog @desktop
  Scenario: A pull request the user opened and is asked to review is under Authored
    Given the user opened #12 and is also asked to review it
    When the user opens the pull requests page
    Then #12 is listed under "Authored" only

  @backlog @desktop
  Scenario: A group nobody belongs to is not shown
    Given the user is asked to review no pull request
    When the user opens the pull requests page
    Then there is no "Review requested" group

  @backlog @desktop
  Scenario: Authorship is judged on each host's own account
    Given the user is "octocat" on GitHub
    And a pull request on a GitHub Enterprise host was opened by "octocat", who is not the user's account there
    When the user opens the pull requests page
    Then the Enterprise pull request is under "Others"

  @backlog @desktop
  Scenario: An older pull request of the user's own is under Authored from the start
    Given the user opened #3, which is older than the first page of the list
    When the user opens the pull requests page
    Then #3 is under "Authored" without waiting for more pages

  @backlog @desktop
  Scenario: Loading more never moves a pull request that is already listed
    Given the page lists pull requests under their groups
    When the user loads more pull requests
    Then the new ones are added at the end of their groups
    And no pull request already listed changes group or place

  @backlog @desktop
  Scenario Outline: Pull requests are ordered by the chosen sort
    Given the user is on the pull requests page
    When the user sorts pull requests by "<sort>"
    Then within each group the pull requests come <order>

    Examples:
      | sort             | order                                                                  |
      | Recently updated | in the order the hosts answered                                        |
      | Newest shown     | from the most recently opened, those with no known date last          |
      | Oldest shown     | from the longest ago opened, those with no known date last            |
      | Largest shown    | from the most changed lines, those not yet measured last              |
      | Smallest shown   | from the fewest changed lines, those not yet measured last            |

  @backlog @desktop
  Scenario: Equally sized pull requests come most recently updated first
    Given #4 and #5 change the same number of lines and #5 was updated more recently
    When the user sorts pull requests by "Smallest shown"
    Then #5 is listed before #4

  @backlog @desktop
  Scenario: Merge readiness is the sort the page starts with
    When the user opens the pull requests page
    Then the pull requests are sorted by "Merge readiness"
    And no sort is kept for next time

  @backlog @desktop
  Scenario: Merge readiness puts what can merge on top
    Given these open pull requests
      | pull request | checks  | review            | conflicts | draft |
      | #1           | failing | none              | no        | no    |
      | #2           | passing | approved          | no        | no    |
      | #3           | passing | none              | no        | no    |
      | #4           | passing | approved          | yes       | no    |
      | #5           | passing | approved          | no        | yes   |
    When the user sorts pull requests by "Merge readiness"
    Then they are listed as #2, #3, then #1 and #5, then #4

  @backlog @desktop
  Scenario: Merge readiness lists finished work after open work
    Given the user shows pull requests in every state
    When the user sorts pull requests by "Merge readiness"
    Then merged and closed pull requests follow the open ones
    And a pull request with a known conflict is last of all

  @backlog @desktop
  Scenario: Within a tier the smaller change comes first
    Given #6 and #7 are both passing and approved, #6 changing 400 lines and #7 changing 20
    And #8 is passing and approved with its size not yet measured
    When the user sorts pull requests by "Merge readiness"
    Then #7 is listed before #6
    And #8 is listed after #6

  @backlog @desktop
  Scenario: Blocked on me lists what the user must act on first
    Given the user opened pull requests in these conditions
      | pull request | condition                      |
      | #10          | approved with passing checks   |
      | #11          | a draft                        |
      | #12          | failing checks                 |
      | #13          | changes requested              |
      | #14          | a conflict with its base       |
      | #15          | merged                         |
    When the user sorts pull requests by "Blocked on me"
    Then the authored pull requests are listed as #14, #13, #12, #11, #10 and #15 in that order

  @backlog @desktop
  Scenario: Blocked on me lists open review requests before finished ones
    Given the user is asked to review an open and a closed pull request
    When the user sorts pull requests by "Blocked on me"
    Then the open one is listed first

  @backlog @desktop
  Scenario Outline: A search keeps the order of its matches
    Given the user has typed words into the search
    When the page is sorted by "<sort>"
    Then the matches are not reordered by that sort

    Examples:
      | sort            |
      | Merge readiness |
      | Blocked on me   |

  @backlog @desktop
  Scenario Outline: A search lists the likeliest match first
    Given pull requests whose <field> matches the search "<search>"
    When the user searches pull requests for "<search>"
    Then the pull request matched through its <field> is listed above those matched less closely

    Examples:
      | search     | field                        |
      | 12         | number, matched exactly      |
      | #12        | number, matched exactly      |
      | tax fix    | title, equal to the search   |
      | tax        | title, containing the search |
      | wizard new | title, holding every word    |
      | fix-tax    | branch                       |
      | octocat    | author                       |
      | shop       | repository                   |
      | wizard     | title, holding one word      |

  @backlog @desktop
  Scenario: Equally good matches come most recently updated first
    Given #8 and #9 both have "tax" in their titles and #9 was updated more recently
    When the user searches pull requests for "tax"
    Then #9 is listed before #8

  @backlog @desktop
  Scenario: A pull request found only through its description
    Given the host matched #5 for "invoice" through its description rather than anything the row shows
    When the user searches pull requests for "invoice"
    Then #5 is listed after the rows whose own title, branch, author or repository match
    And the row says it matched in the description

  @backlog @desktop
  Scenario: A workspace without a project asks for one
    Given the workspace has no project
    When the user opens the pull requests page
    Then the page says "No projects in this workspace"
    And it says "Add a project, and the pull requests from its repository appear here."
    And it offers to add a project
    And it offers no way to check again

  @backlog @desktop
  Scenario: A search on its way says what it is looking for
    Given the user is on the pull requests page
    When the user searches pull requests for "tax"
    Then the list shows placeholders captioned "Searching every host for "tax""

  @backlog @desktop
  Scenario: A search that finds nothing offers to start over
    Given no host knows a pull request matching "wizard"
    When the user searches pull requests for "wizard"
    Then the page says "Nothing matches "wizard""
    And it says "The hosts were searched for it. Try fewer words, or search by number, author or branch."
    And it offers to clear the search and to check again

  @backlog @desktop
  Scenario: A long search is shortened where the page says it back
    Given no host knows a pull request matching a search of 60 characters
    When the user searches pull requests for it
    Then the page repeats the first 48 characters of the search followed by an ellipsis

  @backlog @desktop
  Scenario: Checking again from an empty page asks the hosts afresh
    Given the page lists nothing
    When the user chooses "Check again"
    Then the hosts are asked again
    And the choice reads "Checking..." and cannot be pressed until the answer is in

  @backlog @desktop
  Scenario: An empty page with more pages to read offers them
    Given the first page of the list holds nothing under the user's filters
    And the hosts have further pages
    When the user opens the pull requests page
    Then the page offers "Load more pull requests"
    And choosing it reads the next page

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (loadMore, footer)
  @backlog @desktop
  Scenario: A list with more to read offers the next page below its rows
    Given the page lists 99 pull requests and the hosts have further pages
    Then the page offers "Load more pull requests" below them
    When the user chooses it
    Then the rows stay and the page says "Loading more"
    And the choice cannot be pressed until the hosts have answered
    And the next pull requests follow the ones listed

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (MAX_PAGE_SIZE, "Narrow your search to find more pull requests.")
  @backlog @desktop
  Scenario: A list that cannot be carried on grows by a page at a time and stops at 500
    Given a host that lists without a cursor has 600 open pull requests
    When the user loads more pull requests until the page offers no more
    Then 500 pull requests are listed
    And the page says "Narrow your search to find more pull requests."

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (refreshList regrows to the loaded rows)
  @backlog @desktop
  Scenario: Refreshing a list that was carried on reads as much as was on the page
    Given the user carried the list on until 250 pull requests were listed
    When the user refreshes the page
    Then the list is read again to cover the pull requests that were listed
    And the page does not fall back to its first page

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (SEARCH_DEBOUNCE_MS, local narrowing)
  @backlog @desktop
  Scenario: Typing narrows the rows on screen at once and the hosts are asked when typing pauses
    Given the page lists pull requests
    When the user types "tax" into the search without pausing
    Then the rows on screen narrow to those matching the words as they are typed
    And the hosts are asked once, when the typing pauses
    And the page shows it is updating until they answer

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (a clearing search returns the baseline list)
  @backlog @desktop
  Scenario: Clearing the search brings back the list from before it at once
    Given the user searched pull requests for "tax"
    When the user clears the search
    Then the list from before the search is shown without waiting for the hosts

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (cursors from one question are never carried to a search)
  @backlog @desktop
  Scenario: A search starts at the first page, not where the list had stopped
    Given the user carried the list on for three pages
    When the user searches pull requests for "tax"
    Then the hosts are asked for the first page of what matches
    And nothing is carried on from where the list had stopped

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (showingCarried)
  @backlog @desktop
  Scenario Outline: A new choice narrows the rows on screen while the hosts answer it
    Given the page lists pull requests of several hosts, projects and states
    When the user chooses <choice>
    Then the rows that already fit it stay and the others leave at once
    And the page shows it is updating until the hosts answer

    Examples:
      | choice                |
      | one host              |
      | one project           |
      | the state "Closed"    |

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (carriedToNothing shows the ghost, not an empty claim)
  @backlog @desktop
  Scenario: Rows narrowed to nothing while the hosts answer do not claim there is nothing
    Given the page lists pull requests of one host
    When the user chooses another host whose answer has not arrived
    Then the page shows placeholders
    And it does not say there are no pull requests

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (error banner with rows)
  @backlog @desktop
  Scenario: A failed read keeps the pull requests that were loaded and says so
    Given the page lists pull requests
    When the MC then fails to read them, saying "Rate limit exceeded."
    Then the pull requests stay listed
    And a note says "Rate limit exceeded. Showing the last pull requests loaded." with a retry

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (capability unsupported)
  @backlog @desktop
  Scenario: Servers too old to list pull requests say so and what to do
    Given no connected server can list pull requests
    When the user opens the pull requests page
    Then the page says "Pull requests unavailable"
    And it says "Update your HAL-C2 servers to browse pull requests."

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (capabilityKnown)
  @backlog @desktop
  Scenario: The page does not say pull requests are unavailable before the servers have said
    Given the connected servers have not yet reported what they can do
    When the user opens the pull requests page
    Then the page shows placeholders
    And it does not say pull requests are unavailable

  # Legacy: apps/web/src/components/ChatView.tsx (a pull request tab beside a thread: pullRequestsCapabilityKnown, supportsPullRequests)
  @backlog @desktop
  Scenario Outline: A pull request tab beside a thread says when its environment cannot read pull requests
    Given a thread's right panel has a tab for pull request 42
    And the thread's environment <capability>
    When the user looks at that tab
    Then <shown>

    Examples:
      | capability                               | shown                                                                                                       |
      | is too old to read pull requests         | it says "Pull requests unavailable" and "Update this environment's HAL-C2 server to browse pull requests." |
      | has not yet reported what it can do      | it shows placeholders and does not say pull requests are unavailable                                        |

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (host menu: unreadable host disabled with its reason)
  @backlog @desktop
  Scenario: A host that could not be read stays in the host menu but cannot be chosen
    Given "gitlab.example.com" could not be read, saying "The token has expired."
    When the user opens the host menu
    Then "gitlab.example.com" is listed and cannot be chosen
    And it gives "The token has expired." as its reason
    And a host that gave no reason says "This host could not be read."

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (hosts kept from the unfiltered answer)
  @backlog @desktop
  Scenario: Choosing a host keeps the other hosts in the menu
    Given the list is read from two hosts
    When the user chooses one host
    Then the host menu still offers the other host
    And the user can switch to it

  @backlog @desktop
  Scenario: The filters menu offers a choice for each way to narrow the list
    When the user opens the filters menu
    Then it offers State, Involvement, Author, Labels, Draft, Review, Checks and Project
    And Draft offers "Drafts only" and "Hide drafts"
    And Review offers "Approved", "Changes requested", "Review required" and "No reviews"
    And Checks offers "Passing" and "Failing"

  @backlog @desktop
  Scenario Outline: Choosing between hosts or servers is offered only when there is a choice
    Given the list is read from <sources>
    When the user opens the filters menu
    Then <outcome>

    Examples:
      | sources                         | outcome                                  |
      | one host on one server          | neither Host nor Server is offered       |
      | two hosts on one server         | Host is offered and Server is not        |
      | one host on two servers         | Server is offered and Host is not        |
      | two hosts on two servers        | Host and Server are both offered         |

  @backlog @desktop
  Scenario: A host is named by its provider unless two hosts share one
    Given the workspace has "github.com" and "github.example.com", both GitHub, and one GitLab host
    When the user opens the filters menu
    Then the GitHub hosts are told apart by their host names
    And the GitLab host is called "GitLab"

  @backlog @desktop
  Scenario Outline: The filters menu counts what is narrowing the list
    Given the list is narrowed by <narrowing>
    When the user looks at the filters menu button
    Then it shows the number <count>

    Examples:
      | narrowing                                              | count |
      | nothing beyond open pull requests of all involvement   | none  |
      | the merged state                                       | 1     |
      | the merged state and the author "octocat"              | 2     |
      | one project, drafts hidden and the labels "bug", "ui"  | 4     |

  @backlog @desktop
  Scenario: The author menu lists who wrote the pull requests in view
    Given 14 people wrote the pull requests in view
    When the user opens the author menu
    Then "Anyone" is offered
    And ten authors are listed, those with the most merges loaded first
    And each author says how many merges are loaded

  @backlog @desktop
  Scenario: The author menu can be searched by login or name
    Given "octocat" is named "Octo Cat"
    When the user types "octo cat" in the author menu
    Then "octocat" is listed

  @backlog @desktop
  Scenario: The chosen author is listed first
    Given the user chose the author "zed" among many authors
    When the user opens the author menu
    Then "zed" is listed first and marked

  @backlog @desktop
  Scenario: The author menu says when nobody matches
    When the user types a name nobody has in the author menu
    Then the menu says "No authors found"

  @backlog @desktop
  Scenario: Authors who have nothing in the chosen state are not offered
    Given "mona" wrote only closed pull requests
    When the user opens the author menu with the open state chosen
    Then "mona" is not listed

  @backlog @desktop
  Scenario: The label menu lists the labels in view with their counts
    Given the pull requests in view carry the labels "bug" 5 times and "ui" 2 times
    When the user opens the labels menu
    Then "bug" is listed before "ui", each with its count and its colour
    And the menu says "Any" until a label is chosen, then how many are selected

  @backlog @desktop
  Scenario: A chosen label that nothing in view carries stays in the menu
    Given the user chose the label "legacy" and no pull request in view carries it
    When the user opens the labels menu
    Then "legacy" is still listed and selected

  @backlog @desktop
  Scenario: The label menu says when the view has no labels
    Given no pull request in view carries a label
    When the user opens the labels menu
    Then the menu says "No labels in this view"

  @backlog @desktop
  Scenario: A label cannot be chosen more than ten times
    Given the user has chosen ten labels
    When the user chooses another
    Then the list is narrowed by the first ten only

  @backlog @desktop
  Scenario: One repository checked out twice is one project choice
    Given one server has "acme/shop" checked out as two projects
    When the user opens the project menu
    Then "acme/shop" is listed once

  @backlog @desktop
  Scenario: The same repository on two servers is two project choices
    Given two servers each have "acme/shop"
    When the user opens the project menu
    Then "acme/shop" is listed once for each server, told apart by the server's name

  @backlog @desktop
  Scenario: Projects with the same title are told apart
    Given two different projects are both titled "web"
    When the user opens the project menu
    Then they are told apart by server name when that differs
    And otherwise by folder
    And otherwise by identifier

  @backlog @desktop
  Scenario: A project that could not be read cannot be chosen
    Given the project "acme/old" could not be read this time, saying "gh auth login is required."
    When the user opens the project menu
    Then "acme/old" is listed after the others and marked "Unavailable"
    And pointing at it says "gh auth login is required."
    And it cannot be chosen

  @backlog @desktop
  Scenario: A project that has gone is dropped from the filter once projects are known
    Given the page was opened scoped to a project that no longer exists
    When the workspace's projects have arrived
    Then the page lists pull requests of every project
    And before they arrive the scope is left as it was

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (server menu: onServer, onProject, "All servers", "All projects")
  @backlog @desktop
  Scenario: Choosing a server drops a project that belongs to another one
    Given the page is narrowed to a project of one server
    When the user chooses another server
    Then the pull requests of that server are listed
    And the page is no longer narrowed to the project

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx (onProject brings its environment)
  @backlog @desktop
  Scenario: Choosing a project narrows the page to its server too
    Given the page lists the pull requests of every server
    When the user chooses a project of one server
    Then only that project's pull requests are listed
    And the server menu shows that server

  # Legacy: apps/web/src/routes/_chat.pull-requests.tsx ("All projects" leaves server scope)
  @backlog @desktop
  Scenario: All projects keeps the server and All servers lifts it
    Given the page is narrowed to a project of one server
    When the user chooses "All projects"
    Then the pull requests of every project of that server are listed
    When the user chooses "All servers"
    Then the pull requests of every server are listed

  # Legacy: apps/web/src/components/pullRequest/pullRequestProjectAssignment.logic.test.ts (one server per repository)
  @backlog @desktop
  Scenario: A repository that two servers hold is read from one of them only
    Given two servers both hold "acme/shop"
    When the user opens the pull requests page
    Then the pull requests of "acme/shop" are listed once
    And a server that holds nothing else is not asked about it

  # Legacy: apps/web/src/components/pullRequest/pullRequestProjectAssignment.logic.test.ts (named server preferred, unidentified projects keep every copy)
  @backlog @desktop
  Scenario Outline: Which server lists a repository that two servers hold
    Given two servers both hold <what>
    When the user opens the pull requests page <how>
    Then <result>

    Examples:
      | what                                              | how                                 | result                                                  |
      | "acme/shop"                                       | with no server chosen               | the first server lists it                               |
      | "acme/shop"                                       | with one of the servers chosen      | that server lists it                                    |
      | "ACME/Shop" on one and "acme/shop" on the other   | with no server chosen               | it is one repository and is listed once                 |
      | a project whose repository cannot be identified   | with no server chosen               | each copy is listed, since they are not known to be one |

  # Legacy: apps/web/src/components/pullRequest/pullRequestList.logic.ts (mergeEnvironmentListings)
  @backlog @desktop
  Scenario: Pull requests of several servers are one list, newest update first
    Given two servers each list open pull requests
    When the user opens the pull requests page sorted by most recently updated
    Then the pull requests of both are listed together, the most recently updated first
    And carrying on reads each server from where it stopped

  # Legacy: apps/web/src/components/pullRequest/pullRequestList.logic.ts (project errors scoped to environment, hosts folded)
  @backlog @desktop
  Scenario: A project that could not be read is named under its own server
    Given two servers each have a project with the same identifier
    And only one of them could not be read
    When the user opens the pull requests page
    Then the error is reported for that server's project only
    And the other server's project lists its pull requests

  # Legacy: apps/web/src/components/pullRequest/pullRequestProjectAssignment.logic.test.ts (where a pull request can be acted on)
  @backlog @desktop
  Scenario: A pull request can be acted on through any connected server that holds its repository
    Given two connected servers hold "acme/shop" and a pull request of it is open
    When the user looks at where to act on it
    Then both servers are offered, the one it was opened from first

  # Legacy: apps/web/src/components/pullRequest/pullRequestProjectAssignment.logic.test.ts (none when single or unidentified)
  @backlog @desktop
  Scenario Outline: No choice of server is offered where there is only one
    Given <situation>
    When the user looks at where to act on a pull request
    Then no choice of server is offered

    Examples:
      | situation                                                    |
      | only one connected server holds the repository               |
      | the other server holding it is not connected                 |
      | the project's repository is not known                        |

  @backlog @desktop
  Scenario: A row shows only what the host reported about checks and reviews
    Given a pull request whose host reports no checks and nobody has reviewed
    When the user opens the pull requests page
    Then its row shows no checks and no review verdict

  @backlog @desktop
  Scenario Outline: A row shows the review verdict the host reported
    Given a pull request the host reports as <decision>
    When the user opens the pull requests page
    Then its row shows that it is <decision>

    Examples:
      | decision                 |
      | approved                 |
      | needing changes          |
      | still requiring a review |

  @backlog @desktop
  Scenario: A row marks an open pull request that conflicts with its base
    Given #12 is open, not a draft, and conflicts with "main"
    When the user opens the pull requests page
    Then its row is marked "Conflicts with main"

  @backlog @desktop
  Scenario Outline: A row does not mark a conflict that no longer matters
    Given #12 conflicts with "main" and is <condition>
    When the user opens the pull requests page
    Then its row is not marked as conflicting

    Examples:
      | condition |
      | a draft   |
      | closed    |
      | merged    |

  # Legacy: apps/web/src/components/pullRequest/pullRequestPresentation.test.ts
  @backlog @desktop
  Scenario Outline: A closed or merged pull request keeps its state when the host still flags it as a draft
    Given #12 is <state> and the host still flags it as a draft
    When the user opens the pull requests page
    Then its row is shown as <state>
    And its row is not shown as a draft

    Examples:
      | state  |
      | closed |
      | merged |

  @backlog @desktop
  Scenario: A pull request whose author is gone says "ghost"
    Given a pull request with no author
    When the user opens the pull requests page
    Then its row names the author "ghost"

  @backlog @desktop
  Scenario: Pointing at an author gives the full name
    Given #12 was opened by "octocat", whose name is "Octo Cat"
    When the user points at the author on its row
    Then the page says "Octo Cat (@octocat)"

  @backlog @desktop
  Scenario: A row names its host only when the list spans several
    Given the list holds pull requests from GitHub and GitLab
    When the user opens the pull requests page
    Then each row shows which provider it comes from
    And with only one provider the rows do not say so

  @backlog @desktop
  Scenario: A row names its server only when the list spans several
    Given the list holds pull requests read from two servers
    When the user opens the pull requests page
    Then each row names the server it was read from

  @backlog @desktop
  Scenario: A row shows up to three labels and counts the rest
    Given a pull request with five labels
    When the user opens the pull requests page
    Then its row shows up to three of them and the number left over as "+2"

  @backlog @desktop
  Scenario: A row's number offers its address
    Given the user is on the pull requests page
    When the user right-clicks the number "#12" on a row
    Then the user can copy the pull request's address or open it on its host
    And the row is not opened

  @backlog @desktop
  Scenario Outline: Line counts are read for the rows that need them
    Given the list holds more rows than fit on screen
    When the page is sorted by "<sort>"
    Then line counts are read for <rows>

    Examples:
      | sort             | rows                                  |
      | Merge readiness  | every loaded row                      |
      | Largest shown    | every loaded row                      |
      | Smallest shown   | every loaded row                      |
      | Recently updated | the rows on screen and those near it  |
      | Blocked on me    | the rows on screen and those near it  |

  @backlog @desktop
  Scenario: Line counts are asked for in batches of at most 500 pull requests
    Given the list holds 1,200 loaded rows without line counts
    When line counts are read for every loaded row
    Then they are asked for in several requests of at most 500 pull requests each

  @backlog @desktop
  Scenario: A row whose host listed its line counts is not asked again
    Given the host listed #12 with 40 additions and 2 deletions
    When line counts arrive for the page
    Then #12 keeps the counts it was listed with

  @backlog @desktop
  Scenario: Line counts already shown stay until their replacements arrive
    Given the page shows line counts for 30 rows
    When the list changes and its counts are read again
    Then the counts already shown stay on their rows meanwhile

  @backlog @desktop
  Scenario: A refresh leaves unchanged rows alone
    Given the page lists 100 pull requests and one of them has changed
    When the page refreshes
    Then only the changed row is redrawn

  @backlog @desktop
  Scenario Outline: A row answers the moment an action is sent
    Given the open pull request #12 is listed
    When the user <action> it
    Then its row at once shows <outcome>

    Examples:
      | action             | outcome        |
      | closes             | closed         |
      | merges             | merged         |
      | marks as a draft   | a draft        |

  @backlog @desktop
  Scenario: Reopening shows the pull request open at once
    Given the closed pull request #12 is listed
    When the user reopens it
    Then its row at once shows open

  @backlog @desktop
  Scenario: Marking ready shows it ready at once
    Given the draft pull request #12 is listed
    When the user marks it ready for review
    Then its row at once shows it is no longer a draft

  @backlog @desktop
  Scenario: A pull request that left the chosen state leaves the list at once
    Given #12 is listed under the open state
    When the user closes #12
    Then #12 leaves the list without waiting for the host

  @backlog @desktop
  Scenario: A failed action takes back only its own change
    Given the user closed #12 and then marked #13 as a draft
    When closing #12 fails
    Then #12 is shown as it was
    And #13 is still shown as a draft

  @backlog @desktop
  Scenario: A host's answer that agrees ends the pending change
    Given the user closed #12 and the row shows it closed
    When the host's list says #12 is closed
    Then the pending change is dropped and the host's row is shown

  @backlog @desktop
  Scenario: A late answer that still says open does not undo a close
    Given the user closed #12 a few seconds ago
    When a read that started before the close lands and says #12 is open
    Then #12 is still shown as closed

  @backlog @desktop
  Scenario: A pull request missing from an answer does not settle a pending change
    Given the user closed #12 and the row shows it closed
    When a page of the host's answer arrives without #12
    Then the pending change is kept

  @backlog @desktop
  Scenario: After a minute the host's word wins
    Given the user closed #12 and more than a minute has passed
    When the host's list says #12 is open, having been reopened elsewhere
    Then #12 is shown as open

  @backlog @desktop
  Scenario: A page opened for the first time lists open pull requests
    Given the page has never been used before
    When the user opens the pull requests page
    Then open pull requests of every involvement are listed
    And the sort is "Merge readiness"

  @backlog @desktop
  Scenario: Remembered choices that cannot be read give the defaults
    Given the remembered list choices are damaged or from an older version
    When the user opens the pull requests page
    Then open pull requests of every involvement are listed

  @backlog @desktop
  Scenario: Only list choices are remembered, not the selected pull request
    Given the user selected #12 on the pull requests page
    When the user opens the pull requests page next time
    Then the list choices are as they were left
    And no pull request is selected

  @backlog @desktop
  Scenario: The last list read is shown at once while it is read again
    Given the pull requests page was open a moment ago
    When the user opens the pull requests page again
    Then the rows read last time are shown at once
    And the live answer replaces them in place

  @backlog @desktop
  Scenario: The remembered list holds only the first page
    Given the last list read held 250 pull requests
    When the list is remembered for the next visit
    Then at most 99 of them are kept

  @backlog @desktop
  Scenario: A remembered list is not carried across a change of servers
    Given the list was remembered while two servers were connected
    When the user opens the pull requests page with only one connected
    Then the remembered rows are not shown

  @backlog @desktop
  Scenario: Failures are never remembered
    Given the last list read had an error for the project "acme/api"
    When the user opens the pull requests page again
    Then the remembered list carries no error

  @backlog @desktop
  Scenario: A remembered list that cannot be read is dropped
    Given the remembered list is damaged or from an older version
    When the user opens the pull requests page
    Then the page starts empty and reads the list

  @backlog @desktop
  Scenario: A thread's pull requests are listed newest first with stacks together
    Given a thread is linked to #12 and to a stack of #20, #21 and #22
    And the stack was pushed to more recently than #12
    When the user opens the thread's pull request list
    Then the stack is listed above #12
    And the stack reads from #20 at the base to #22, each layer stepped in once more
    And the base layer says the stack has three layers

  @backlog @mc
  Scenario: Typed search words are matched as plain text
    When the user searches pull requests for "is:merged"
    Then the words "is:merged" are looked for in titles and bodies
    And the search is not narrowed to merged pull requests

  @backlog @mc
  Scenario: The closed list leaves out merged pull requests
    Given "acme/shop" has one closed pull request and one merged pull request
    When the user lists closed pull requests
    Then only the closed pull request is listed

  @backlog @mc
  Scenario: A repository the host's search does not index is still listed
    Given GitHub's search answers nothing at all for "acme/shop"
    When the user lists open pull requests
    Then the open pull requests of "acme/shop" are listed the long way

  @backlog @mc
  Scenario: A list read the long way grows its page instead of carrying on
    Given GitHub's search answers nothing at all for "acme/shop"
    And "acme/shop" has 300 open pull requests
    When the user loads more pull requests
    Then a larger page of up to 1000 pull requests is read
    And the list is not carried on from a cursor

  @backlog @mc
  Scenario: A text search that finds nothing stays empty
    Given no pull request in "acme/shop" matches the words "tax"
    When the user searches pull requests for "tax"
    Then no pull requests are listed for "acme/shop"
    And the repository is not read the long way

  @backlog @mc
  Scenario: A cursor the MC did not hand out refuses the whole list
    When a client lists pull requests carrying on from a cursor it made up
    Then the user is told "The list could not be carried on from where it left off."
    And no pull requests are listed

  @backlog @mc
  Scenario: Carrying on reads only the repositories the cursor names
    Given the first page of the list carried on for "acme/shop" only
    When the user loads more pull requests
    Then only "acme/shop" is read
    And "acme/api" is not asked again

  @backlog @mc
  Scenario: Worktrees of one repository are listed once
    Given "acme/shop" is open as the project and as two worktrees
    When the user lists pull requests
    Then each pull request of "acme/shop" is listed once

  @backlog @mc
  Scenario: The same repository name on two hosts stays two repositories
    Given "acme/shop" exists on github.com and on a self-hosted GitHub
    When the user lists pull requests
    Then the pull requests of both are listed under their own host

  @backlog @mc
  Scenario Outline: A filter the host cannot apply is applied by the MC
    Given a project on <host>
    When the user lists open pull requests with <filter>
    Then only change requests matching <filter> are listed

    Examples:
      | host         | filter            |
      | GitLab       | drafts hidden     |
      | Forgejo      | the label "bug"   |
      | Azure DevOps | the author "alice" |
      | Bitbucket    | review required   |

  @backlog @mc
  Scenario: A remote spelled as an SSH alias is identified by its host
    Given the project "infra" has the remote "git@work-gitlab:acme/infra.git" and "work-gitlab" is an SSH alias of a GitLab server
    When the user lists open pull requests
    Then the open change requests of "infra" are listed

  @backlog @mc
  Scenario: Pull requests carry the stacks they belong to
    Given pull request 42 on github.com is the second layer of a stack
    When the user lists open pull requests
    Then pull request 42 is listed with its place in the stack

  @backlog @mc
  Scenario: A failing stack lookup does not break the list
    Given GitHub cannot answer which stacks the listed pull requests belong to
    When the user lists open pull requests
    Then the pull requests are listed without stack membership

  @backlog @mc
  Scenario: Many repositories are searched in batches
    Given the workspace has 250 repositories on one host
    When the user lists open pull requests
    Then the host is searched for at most 100 repositories per request
    And the batches are read concurrently

  @backlog @mc
  Scenario: A batch the host cannot answer is read one repository at a time
    Given the host cannot answer one search across twelve repositories
    When the user lists open pull requests
    Then each repository is read on its own
    And a repository that fails is reported as "<repository> could not be read."

  @backlog @mc
  Scenario Outline: A long list on another host carries on without repeating or skipping
    Given a project on <host> with 200 open change requests
    When the user loads more change requests
    Then the next change requests follow without repeating or skipping any

    Examples:
      | host         |
      | GitLab       |
      | Forgejo      |
      | Azure DevOps |
      | Bitbucket    |

  @backlog @mc
  Scenario: A row that cannot be read does not end the list early
    Given the host returns one unreadable row in the middle of a page
    When the user lists open pull requests
    Then the readable rows are listed
    And more can still be loaded

  @backlog @mc
  Scenario: Pull requests with the same update time are not lost between pages
    Given several pull requests were updated at the same instant across a page boundary
    When the user loads more pull requests
    Then every one of them is listed exactly once

  @backlog @mc
  Scenario Outline: A host that cannot search text lists without narrowing
    Given a project on <host>
    When the user searches pull requests for "tax"
    Then the open change requests are listed unnarrowed

    Examples:
      | host         |
      | Azure DevOps |
      | Forgejo      |

  @backlog @mc
  Scenario Outline: Search words cannot reshape the request
    Given a project on <host>
    When the user searches pull requests for <words>
    Then the words are searched for as plain text
    And no other filter is added

    Examples:
      | host      | words                  |
      | GitLab    | "tax&state=all"        |
      | Bitbucket | `a" OR state="MERGED`  |

  @backlog @mc
  Scenario: A search of only spaces is no search
    When the user searches pull requests for "   "
    Then the list is not narrowed

  @backlog @mc
  Scenario: A GitLab project in a nested group is addressed by its full path
    Given the project "infra" has its remote on GitLab at "acme/platform/infra"
    When the user lists open merge requests
    Then the merge requests of "acme/platform/infra" are listed

  @backlog @mc
  Scenario Outline: Host states are shown as open, closed or merged
    Given a change request on <host> that the host calls <host state>
    When the user lists change requests
    Then it is shown as <shown as>

    Examples:
      | host         | host state          | shown as |
      | Azure DevOps | active              | open     |
      | Azure DevOps | completed           | merged   |
      | Azure DevOps | abandoned           | closed   |
      | Azure DevOps | a state not known   | open     |
      | Bitbucket    | declined            | closed   |
      | Bitbucket    | superseded          | closed   |
      | GitLab       | locked              | open     |
      | GitLab       | closed with a merge time | merged |

  @backlog @mc
  Scenario: Azure DevOps rows are dated by when they closed
    Given a completed pull request on Azure DevOps that was closed on 5 July
    When the user lists pull requests
    Then the row is dated 5 July

  # Legacy: apps/server/src/sourceControl/azureDevOpsPullRequests.ts (azureDevOpsPullRequestWebUrl)
  @backlog @mc
  Scenario Outline: An Azure DevOps pull request is opened at the host's own link or one built from what it said
    Given pull request 7 on Azure DevOps comes with <given>
    When the user lists pull requests
    Then its link is <link>

    Examples:
      | given                                                                                          | link                                                            |
      | a web link                                                                                     | that web link                                                   |
      | no web link but the repository's web address                                                   | the repository's web address followed by "/pullrequest/7"       |
      | only a programming address under "dev.azure.com/org", project "My App" and repository "web"    | "https://dev.azure.com/org/My%20App/_git/web/pullrequest/7"     |
      | only a programming address under "org.visualstudio.com", project "app" and repository "web"    | "https://org.visualstudio.com/app/_git/web/pullrequest/7"       |
      | nothing but a programming address of another kind                                              | that address as it came                                         |

  # Legacy: apps/server/src/sourceControl/gitLabMergeRequests.ts, forgejoPullRequests.ts, azureDevOpsPullRequests.ts, bitbucketPullRequests.ts
  @backlog @mc
  Scenario Outline: Each host marks a draft in its own way
    Given a change request on <host> that <marking>
    When the user lists change requests
    Then it is shown as <shown>

    Examples:
      | host         | marking                                             | shown        |
      | GitLab       | is flagged as a draft                               | a draft      |
      | GitLab       | is flagged as work in progress, the older name      | a draft      |
      | Forgejo      | is flagged as a draft                               | a draft      |
      | Forgejo      | has no flag and a title starting "[WIP]"            | a draft      |
      | Forgejo      | has no flag and a title starting "WIP:" in any case | a draft      |
      | Forgejo      | has no flag and "WIP:" only in the middle of its title | not a draft |
      | Azure DevOps | is flagged as a draft                               | a draft      |
      | Bitbucket    | is flagged as a draft                               | a draft      |

  @backlog @mc
  Scenario: A host that reports no line counts leaves them out
    Given an open merge request on GitLab
    When the user lists open pull requests
    Then the row shows no added or removed line counts

  @backlog @mc
  Scenario: The last good answer is kept when a refresh fails
    Given pull request 42 was read successfully a minute ago
    And GitHub now fails when asked about it
    When the user opens pull request 42
    Then the last good answer is shown

  @backlog @mc
  Scenario: Reading the same pull request together is one request
    Given three clients ask for the detail of pull request 42 at once
    When the MC reads it
    Then GitHub is asked once and all three clients get the answer

  @backlog @mc
  Scenario: Many summaries are asked for in one batch
    Given a client asks for the summaries of 30 pull requests in quick succession
    When the MC reads them
    Then GitHub is asked in batches of at most 25 pull requests

  @backlog @desktop
  Scenario: A pull request view left open refreshes every five minutes
    Given the user is looking at a pull request or the pull requests page
    When the user keeps it open and keeps working
    Then it is read again about every five minutes

  @backlog @desktop
  Scenario: A pull request view stops refreshing when nobody is there
    Given the user is looking at a pull request or the pull requests page
    And the user has not touched the app for six minutes
    Then it is not read again
    When the user clicks, types, moves the pointer or scrolls
    Then it refreshes again

  @backlog @desktop
  Scenario: A pull request view that is not showing is not refreshed
    Given the user is looking at a pull request or the pull requests page
    When the window is hidden or minimised
    Then it is not read again until the window is shown

  @backlog @desktop
  Scenario: Coming back to the window refreshes the view, at most every ten seconds
    Given the user is looking at a pull request
    When the user returns to the window twice within ten seconds
    Then it is read once

  @backlog @desktop
  Scenario: The first arrival at a view does not read twice
    Given the user opens a pull request for the first time this session
    Then it is read once
    And arriving does not start a second read on top of it

  @backlog @desktop
  Scenario: Returning to a pull request read earlier refreshes it
    Given the user read a pull request earlier this session
    And more than ten seconds have passed
    When the user opens it again
    Then it is read again

  @backlog @desktop
  Scenario Outline: Checks are refreshed faster while they may still change
    Given a thread's open pull request has <checks>
    When the thread is shown
    Then its checks are read again about every <interval>

    Examples:
      | checks                          | interval   |
      | a check that is pending         | 45 seconds |
      | a check that needs an action    | 45 seconds |
      | no checks reported yet          | 45 seconds |
      | only finished checks            | 60 seconds |

  @backlog @desktop
  Scenario: A closed or merged pull request is not refreshed in the background
    Given a thread's pull request is merged
    When the thread is shown
    Then its details and checks are not read again on a timer

  @backlog @desktop
  Scenario: A pull request on a host without checks is not asked for them
    Given a thread's open pull request is on a host that reports no checks
    When the thread is shown
    Then its checks are not read on a timer

  @backlog @desktop
  Scenario: A thread's open pull request refreshes its details every ten minutes
    Given a thread's open pull request is shown beside the thread
    When the user keeps the thread open
    Then the pull request's details are read again about every ten minutes

  @backlog @mc
  Scenario Outline: A pull request read a moment ago is answered without asking the host again
    Given the MC read <what> of pull request 42 <age> ago
    When a client asks for <what> of pull request 42 again
    Then the answer comes without asking the host

    Examples:
      | what                                    | age        |
      | the list of the project's pull requests | 20 seconds |
      | its details and checks                  | 10 seconds |
      | its diff                                | 45 seconds |
      | the diff of one of its commits          | 8 minutes  |
      | which of its files the user has viewed  | 10 seconds |

  @backlog @mc
  Scenario Outline: A read that is older than its allowance goes to the host again
    Given the MC read <what> of pull request 42 <age> ago
    When a client asks for <what> of pull request 42 again
    Then the host is asked again

    Examples:
      | what                                    | age        |
      | the list of the project's pull requests | 40 seconds |
      | its details and checks                  | 20 seconds |
      | its diff                                | 90 seconds |
      | the diff of one of its commits          | 11 minutes |

  @backlog @mc
  Scenario: A failed read is not remembered
    Given the host failed to answer a read of pull request 42
    When a client asks for it again a moment later
    Then the host is asked again instead of repeating the failure

  @backlog @mc
  Scenario: Reads remembered for a short while survive an MC restart
    Given the MC read pull request 42 a few seconds ago
    When the MC restarts
    And a client asks for pull request 42
    Then the answer comes without asking the host

  @backlog @mc
  Scenario: An action on a pull request makes its remembered reads stale
    Given the MC remembers the details, diff and checks of pull request 42
    When the user comments on pull request 42
    Then the next read of pull request 42 asks the host

  @backlog @mc
  Scenario: A folder the MC cannot keep remembered reads in falls back to memory
    Given the MC's folder for remembered pull request reads cannot be used
    When a client asks for pull request 42
    Then the answer is read and remembered in memory only
    And no error is shown

  @backlog @mc
  Scenario: Remembered reads are switched off when they cannot be made stale
    Given the MC cannot record that pull request 42 changed
    When the user comments on pull request 42
    Then reads of pull requests go to the host instead of being remembered
    And the user is not shown an error

  @backlog @mc
  Scenario: A self-hosted project of an unrecognised kind is identified before it is listed
    Given the project "docs" has its remote on "code.example.test", which no built-in rule recognises
    When the user lists pull requests
    Then the MC asks which kind of host "code.example.test" is before listing "docs"
    And its merge requests are listed as GitLab ones from "code.example.test"

  @backlog @mc
  Scenario: Another checkout on the same host identifies it when one is gone
    Given two projects have their remote on "code.example.test"
    And the folder of the first project no longer exists
    When the user lists pull requests
    Then the host is identified through the second project
    And both projects are listed under GitLab

  @backlog @mc
  Scenario: A host that stays unidentified is reported but not read
    Given a project has its remote on a host whose kind cannot be identified
    When the user lists pull requests
    Then that host is reported as one the MC cannot read yet
    And the other hosts are listed as usual

  @backlog @mc
  Scenario: A review request is flagged for the user, spelled any way, but not on their own pull request
    Given the user is "bilal" and a review of pull request 1 is requested of "Bilal"
    And pull request 2 was written by "bilal" and lists "bilal" among its requested reviewers
    When the user lists pull requests
    Then pull request 1 is flagged as awaiting the user's review
    And pull request 2 is not

  @backlog @mc
  Scenario: A summary is made from details the MC already holds
    Given the details of pull request 1 were read a moment ago
    When a client asks for the summary of pull request 1
    Then the summary carries the title, draft flag, line counts, mergeability, review decision and checks of those details
    And the host is not asked again

  @backlog @mc
  Scenario: An older answer never replaces a newer one
    Given the MC holds a summary of pull request 1 updated at 10:05
    When details of pull request 1 updated at 10:00 arrive late
    Then the summary still shows the 10:05 state

  @backlog @mc
  Scenario: A merged pull request just observed settles without another read
    Given the MC saw pull request 1 merge a moment ago
    When a client asks for its state to settle a thread
    Then it is answered as merged without asking the host

  # Legacy: apps/server/src/pullRequest/GitHubPullRequestCli.ts (matchesInvolvement), gitHubPullRequestJson.ts (hasTeamReviewRequest)
  @backlog @mc
  Scenario: On GitHub a review asked of a team is listed among those awaiting the user's review
    Given pull request 1 on GitHub has a review requested of the team "acme/core" and of no person
    When the user lists pull requests where their review is requested
    Then pull request 1 is listed

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestCli.ts (AzureDevOpsViewerUnavailableError)
  @backlog @mc
  Scenario: An Azure DevOps sign-in that names no account cannot be listed for
    Given the Azure CLI answers for the current sign-in with no account
    When the user lists their pull requests on Azure DevOps
    Then the user is told "Azure CLI returned no account for the current sign-in."

  # Legacy: apps/server/src/pullRequest/BitbucketPullRequestApi.ts (BitbucketViewerUnavailableError)
  @backlog @mc
  Scenario: Bitbucket credentials that name no account cannot be listed for
    Given Bitbucket answers for the configured credentials with no account name
    When the user lists their pull requests on Bitbucket
    Then the user is told "Bitbucket returned no account name for the configured credentials."

  # Legacy: apps/server/src/pullRequest/BitbucketPullRequestApi.ts (BitbucketRepositoryUnsupportedError)
  @backlog @mc
  Scenario: A Bitbucket repository that is not a workspace and a name is refused
    Given a project whose Bitbucket repository is not written as workspace/repository
    When the user lists its pull requests
    Then the user is told "A Bitbucket repository is addressed as workspace/repository."

  # Legacy: apps/server/src/pullRequest/AzureDevOpsPullRequestProvider.ts (toChangeRequest: additions 0, deletions 0, labels [])
  @backlog @mc
  Scenario: An Azure DevOps row has no labels and no line counts, since the host keeps neither on the pull request
    Given an open pull request on Azure DevOps
    When the user lists open pull requests
    Then its row shows no labels
    And the row claims no added or removed lines
