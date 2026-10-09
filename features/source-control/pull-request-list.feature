# Sources:
#   docs/user/source-control.md (Pull requests page)
#   packages/contracts/src/pullRequest.ts (PullRequestListInput, PullRequestListResult, PullRequestProviderSummary, PullRequestUnavailableError)
#   packages/contracts/src/rpc.ts (pullRequests.list, pullRequests.listStats, pullRequests.summary, pullRequests.invalidate, pullRequests.subscribeRefreshes)
#   apps/server-ex/lib/hal_c2/pull_requests.ex (list, list_stats, summary, invalidate)
#   apps/server-ex/lib/hal_c2/pull_requests/refreshes.ex
#   apps/web/src/components/pullRequest/pullRequestList.logic.ts
#   apps/web/src/components/pullRequest/PullRequestListFilters.tsx
#   apps/web/src/components/pullRequest/PullRequestListEmptyState.tsx
#   apps/web/src/components/pullRequest/PullRequestListRow.tsx
#   apps/web/src/components/pullRequest/pullRequestProjectFilter.logic.ts
#   apps/web/src/components/pullRequest/pullRequestListPreferences.ts
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Pull requests)
#   apps/desktop-qt/parity/features.backlog.test.ts (right panel pull request list)
#   apps/desktop-qt/src/native/PullRequestListController.cpp

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
    And "acme/api" reports its own error with the host's reason, phrased for the user

  @backlog-desktop
  Scenario: A project the host could not read is named once with a retry
    Given "acme/api" cannot be read
    When the user opens the pull requests page
    Then the page says "acme/api could not be read" once, without the host's raw text
    And the user can retry from the page

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
  Scenario: A pull request no thread works on offers to start one
    Given the user is on the pull requests page
    When the user opens #7 from the pull requests page
    Then the user is offered to start a thread on #7

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
