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

Feature: Browsing pull requests
  The pull requests page gathers pull requests from every project in the workspace, with
  filters for who is involved, state, drafts, reviews, checks, labels and authors.

  Background:
    Given a connected environment with the GitHub projects "acme/shop" and "acme/api"
    And the GitHub CLI is installed and signed in

  @node
  Scenario Outline: Listing by involvement
    When the user lists pull requests <involvement>
    Then only pull requests <which> are listed

    Examples:
      | involvement           | which                                   |
      | from all involvement  | in either project                       |
      | the user is reviewing | where the user's review is requested    |
      | the user authored     | the user opened                         |

  @node
  Scenario Outline: Listing by state
    When the user lists <state> pull requests
    Then every listed pull request is <state>

    Examples:
      | state  |
      | open   |
      | closed |
      | merged |

  @node
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

  @node
  Scenario: Searching every host
    When the user searches pull requests for "tax label:bug"
    Then the search runs on GitHub for each project
    And matching pull requests are listed

  @node
  Scenario: A long list carries on where it left off
    Given "acme/shop" has 200 open pull requests
    When the user loads more pull requests
    Then the next pull requests follow without repeating any

  @node
  Scenario: Diff sizes and review counts arrive after the list
    When the user lists open pull requests
    Then the rows arrive first and their line counts follow

  @node
  Scenario: A project on another host is shown as not browsable yet
    Given the project "infra" has its remote on GitLab
    When the user lists pull requests
    Then GitLab is listed as not configured with "This host cannot be browsed here yet."

  @backlog @node
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

  @node
  Scenario Outline: The list explains why a host cannot be read
    Given <condition>
    When the user lists pull requests
    Then "acme/shop" reports it is unavailable because <reason>

    Examples:
      | condition                               | reason                                          |
      | the GitHub CLI is not installed         | the GitHub CLI is required and how to install it |
      | the GitHub CLI is not signed in         | the user should run gh auth login and retry     |

  @node
  Scenario: One failing project does not hide the others
    Given "acme/api" cannot be read
    When the user lists pull requests
    Then the pull requests of "acme/shop" are listed
    And "acme/api" reports its own error

  @node
  Scenario: Clients hear when the list changed
    Given the user is looking at the pull request list
    When someone merges a pull request from HAL-C2
    Then the client is told to refresh the list

  @node
  Scenario: Forgetting cached answers
    When the user refreshes the pull request list by hand
    Then the node reads the pull requests afresh

  @backlog @desktop @mobile
  Scenario: The pull requests page with its filters
    When the user opens the pull requests page
    Then pull requests from every project are listed with state, involvement, project and filter choices
    And the user's filter choices are kept for next time

  @backlog @desktop @mobile
  Scenario: Nothing under these filters
    Given no pull request matches the chosen filters
    When the user opens the pull requests page
    Then the user is told "Nothing under these filters" and to widen the filters

  @backlog @desktop
  Scenario: A pull request list beside the thread
    When the user adds a pull requests tab to the right panel
    Then the open pull requests of the project are listed
    And opening one shows its review
