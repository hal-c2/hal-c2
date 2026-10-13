# Sources:
#   apps/server-ex/lib/hal_c2/plugins/host.ex (Host.issues, gated by issues:read and issues:write)
#   apps/server-ex/lib/hal_c2/issues.ex (issues, milestones, sub-issues, dependencies and boards through gh)
#   apps/server-ex/lib/hal_c2/plugins/package.ex (permission ids and their labels)
#   packages/contracts/src/plugin.ts (PluginPermissionId)
#   GitHub REST and GraphQL: issues, milestones, sub-issues, issue dependencies, Projects v2

Feature: Issues, milestones and boards for MC plugins
  A plugin that plans or tracks work reads and changes a repository's issues, milestones,
  sub-issues and dependencies, and the boards (GitHub Projects) they sit on, through the
  host API, as it does pull requests. Reading needs `issues:read` and changing needs
  `issues:write`. Repositories on GitHub are served through the gh login of the MC's
  machine; other hosts are refused for now.

  Background:
    Given an MC with the project "api" whose remote is "acme/api" on GitHub

  @mc
  Scenario: A plugin lists a repository's issues with what planning needs
    Given "acme/api" has the open issue #7 in the milestone "Beta", blocked by #5, with the sub-issue #9 and closed by the pull request #12
    When a plugin granted "issues:read" lists the open issues of "acme/api"
    Then #7 is listed with its milestone, the issue blocking it, its sub-issues and the pull request that closes it

  @mc
  Scenario: A plugin reads one issue
    When a plugin granted "issues:read" reads #7 of "acme/api"
    Then it gets #7 with its title, body, state, labels, assignees and parent

  @mc
  Scenario: A plugin lists and changes milestones
    Given a plugin granted "issues:read" and "issues:write"
    When it sets the due date of the milestone "Beta" of "acme/api" to "2026-11-30"
    Then the milestones of "acme/api" list "Beta" due on "2026-11-30"

  @mc
  Scenario Outline: A plugin changes an issue
    Given a plugin granted "issues:write"
    When it <change> on #7 of "acme/api"
    Then GitHub is asked to <effect>

    Examples:
      | change                         | effect                               |
      | creates the issue "Add limits" | create the issue "Add limits"        |
      | closes it as completed         | close #7 as completed                |
      | sets its labels to "backend"   | set the labels of #7 to "backend"    |
      | adds #9 as a sub-issue         | add #9 as a sub-issue of #7          |
      | marks it blocked by #5         | mark #7 as blocked by #5             |
      | comments "On track"            | comment "On track" on #7             |

  @mc
  Scenario: A plugin reads a board and the fields of its items
    Given the board "acme/3" has the fields "Start date", "Target date" and "Status"
    And #7 of "acme/api" is on "acme/3" starting "2026-10-20" with the target "2026-11-02"
    When a plugin granted "issues:read" reads the board "acme/3"
    Then #7 is an item of "acme/3" with those dates

  @mc
  Scenario: A plugin sets a field of a board item by the field's name
    Given a plugin granted "issues:write"
    When it sets "Target date" of #7 on the board "acme/3" to "2026-11-09"
    Then GitHub is asked to set that field of the item to "2026-11-09"

  @mc
  Scenario: A board the gh login may not read asks for the project scope
    Given gh is signed in without the "project" scope
    When a plugin granted "issues:read" reads the board "acme/3"
    Then it is told to run "gh auth refresh -s project"

  @mc
  Scenario: Changing issues without issues:write is refused
    Given a plugin granted only "issues:read"
    When it closes #7 of "acme/api"
    Then the MC refuses the call naming "issues:write"
    And the refusal is recorded on the plugin

  @mc
  Scenario: Issues on a host the MC cannot read yet are refused
    Given the project "web" whose remote is "acme/web" on GitLab
    When a plugin granted "issues:read" lists the open issues of "acme/web"
    Then it is told that issues on that host cannot be read yet

  @backlog @mc
  Scenario: A git host plugin serves the issues of its host
    Given the git host plugin "gitea" is enabled with a base URL
    When a plugin granted "issues:read" lists the open issues of a repository on that host
    Then the issues come from "gitea"
