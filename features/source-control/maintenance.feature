# Sources:
#   plugins/maintenance/plugin.json (settings, permissions, page, thread kind)
#   plugins/maintenance/mc/maintenance.ex (starting runs, the prompt's rules, publishing, scheduling)
#   plugins/maintenance/mc/report.ex (report shape, redaction, the pull request body)
#   plugins/maintenance/mc/runs.ex (how a run moves)
#   plugins/maintenance/mc/schedule.ex (when a scheduled run is due)
#   plugins/maintenance/skill/SKILL.md (the maintain skill its agents follow)
#   plugins/maintenance/ui/MaintenancePage.qml, MaintenanceHeader.qml, MaintenanceRowMark.qml
#   apps/server-ex/lib/hal_c2/plugins/host.ex (projects, pull requests, threads for plugins)
#   docs/user/maintenance.md
#
# The MC scenarios run from apps/server-ex with
#   mise exec -- mix features source-control/maintenance.feature
# (steps in test/steps/source_control/maintenance_steps.exs). The page, header and
# row mark are covered by the QML tests in plugins/maintenance/test against a fake MC
# part; desktop tst_Features steps are the follow-up that takes the @backlog-desktop
# tags off.

@plugin-maintenance
Feature: Repository maintenance
  The maintenance plugin runs the maintain skill on the repositories it follows, on
  a schedule or when the user asks. Each run is a thread of the agent the user
  picked. A fix run works on a maintenance branch in a worktree of its own and never
  on the default branch; a report run changes nothing. The agent reports, per
  category, what it applied, what it deferred and the command a human would run,
  and the gate it ran. The report is the pull request's body, and publishing says
  whether the branch stays in HAL-C2, waits for the user to open its pull request,
  or is opened at once.

  Background:
    Given an MC running the maintenance plugin
    And the project "api" whose remote is "acme/api" on GitHub
    And "maintenance" maintains "acme/api"

  Rule: A run is a thread of the configured agent

    @mc @desktop @backlog-desktop
    Scenario: Running now starts a fix run on a maintenance branch
      When the user runs maintenance on "acme/api" now
      Then a maintenance run is running in a thread of the configured agent
      And its thread works in a new worktree of "api" on a branch "maintenance/<today>" from "main"
      And its prompt names the maintain skill shipped with the plugin
      And its prompt keeps it off "main", one commit per category behind the gates, with major bumps deferred

    @mc
    Scenario: A repository's own maintain skill is preferred
      Given "api" has its own maintain skill in ".agents/skills/maintain"
      When the user runs maintenance on "acme/api" now
      Then its prompt names the maintain skill in ".agents/skills/maintain"

    @mc
    Scenario: A report run works in the checkout and changes nothing
      Given "maintenance" runs in "report" mode
      When the user runs maintenance on "acme/api" now
      Then its thread works in the checkout of "api"
      And its prompt tells it to change nothing

    @mc
    Scenario: A security-only run covers only open advisories
      Given "maintenance" fixes only security advisories
      When the user runs maintenance on "acme/api" now
      Then the run covers only "security-alerts"
      And its prompt asks for the smallest upgrade that resolves each advisory

    @mc
    Scenario: The repository's own instructions are added to its prompt
      Given "maintenance" has the instructions "Run make check as the gate." for "acme/api"
      When the user runs maintenance on "acme/api" now
      Then its prompt includes "Run make check as the gate."

    @mc @desktop @backlog-desktop
    Scenario: A run is skipped while a maintenance pull request is open
      Given "acme/api" has an open pull request from "maintenance/2026-10-26"
      When the user runs maintenance on "acme/api" now
      Then the run is skipped, naming that pull request
      And no maintenance thread starts

    @mc
    Scenario: A second run of a repository waits for the first
      Given a maintenance run on "acme/api"
      When the user runs maintenance on "acme/api" now
      Then the run is refused, told "has a maintenance run going already"

    @mc
    Scenario: A repository without a project is refused
      When the user runs maintenance on "acme/web" now
      Then the run is refused, told "No project on this MC has acme/web as its remote"

  Rule: The agent reports through the plugin's tool

    @mc @desktop @backlog-desktop
    Scenario: A fix run that applied commits waits for the user
      Given a maintenance run on "acme/api"
      And its agent committed "chore(deps): bump lodash to 4.17.21" on its branch
      When its agent reports the commit, a deferred major bump and a passing gate
      Then the run waits for the user to open its pull request
      And nothing was pushed
      And its report keeps the deferred bump with its command

    @mc
    Scenario: A run that changed nothing is done
      Given a maintenance run on "acme/api"
      When its agent reports nothing applied in every category
      Then the run is done

    @mc
    Scenario: A report run that claims commits is sent back
      Given "maintenance" runs in "report" mode
      And a maintenance run on "acme/api"
      When its agent reports a commit
      Then the maintenance agent is told "This run is in report mode"
      And the maintenance run is still running

    @mc
    Scenario: A report must cover every category of the run
      Given a maintenance run on "acme/api"
      When its agent reports only "deps"
      Then the maintenance agent is told "Report on every category of this run"
      And the maintenance run is still running

    @mc
    Scenario: Secrets in a report are redacted
      Given a maintenance run on "acme/api"
      When its agent reports a finding quoting the token "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
      Then the report says "[redacted]" where the token was

    @mc
    Scenario: A turn that ends without a report fails the run
      Given a maintenance run on "acme/api"
      When its agent's turn ends without reporting
      Then the maintenance run failed, saying it finished without reporting

  Rule: Publishing is the user's choice

    @mc @desktop @backlog-desktop
    Scenario: Opening a waiting run's pull request pushes its branch
      Given a maintenance run on "acme/api" waiting with a commit
      When the user opens its pull request
      Then its branch is pushed to "acme/api"
      And a pull request is opened from its branch into "main" with the report as its body
      And the run is published with the pull request's address

    @mc
    Scenario: A refused pull request keeps the run waiting
      Given a maintenance run on "acme/api" waiting with a commit
      And GitHub refuses to open the maintenance pull request
      When the user opens its pull request
      Then the run waits again, saying why it was refused

    @mc
    Scenario: Publishing automatically opens the pull request as the agent reports
      Given "maintenance" publishes "automatic"
      And a maintenance run on "acme/api"
      And its agent committed "chore(deps): bump lodash to 4.17.21" on its branch
      When its agent reports the commit, a deferred major bump and a passing gate
      Then the run is published with the pull request's address
      And the maintenance agent is told the pull request is open

    @mc
    Scenario: Keeping runs in HAL-C2 pushes nothing
      Given "maintenance" publishes "local"
      And a maintenance run on "acme/api"
      And its agent committed "chore(deps): bump lodash to 4.17.21" on its branch
      When its agent reports the commit, a deferred major bump and a passing gate
      Then the run is kept in HAL-C2
      And nothing was pushed

    @mc
    Scenario: A kept run can still become a pull request
      Given "maintenance" publishes "local"
      And a maintenance run on "acme/api" kept with a commit
      When the user opens its pull request
      Then the run is published with the pull request's address

  Rule: The user can stop, dismiss and rerun

    @mc @desktop @backlog-desktop
    Scenario: Cancelling a run stops its agent and refuses its report
      Given a maintenance run on "acme/api"
      When the user cancels the run
      Then the maintenance run is cancelled
      And a report from its agent is refused

    @mc @desktop @backlog-desktop
    Scenario: A dismissed run leaves the page and frees the repository
      Given a maintenance run on "acme/api" waiting with a commit
      When the user dismisses the run
      Then the run is no longer listed
      And the user can run maintenance on "acme/api" again

    @mc
    Scenario: Running again after a run ended starts a new run
      Given a maintenance run on "acme/api" that is done
      When the user runs maintenance on "acme/api" now
      Then a maintenance run is running in a thread of the configured agent
      And both runs are listed

  Rule: Scheduled runs start on their own

    @mc
    Scenario: A slot missed while the MC was off runs once when it is back
      Given "maintenance" runs every day at "06:00"
      And the MC last ran maintenance on "acme/api" for a slot long ago
      When the plugin starts again
      Then a scheduled maintenance run starts on "acme/api"

    @mc
    Scenario: A repository just added waits for its first slot
      Given "maintenance" runs every day at "06:00"
      When the plugin starts again
      Then no maintenance thread starts
      And "acme/api" shows when its next run is

  Rule: Settings are checked when saved

    @mc
    Scenario Outline: A save that cannot work is refused
      When the user saves the maintenance settings with <setting>
      Then the save is refused, told "<reason>"

      Examples:
        | setting                       | reason                      |
        | the repository "not a repo"   | give each as owner/name     |
        | the time "25:00"              | give the time of day        |
        | the category "lint"           | categories: pick from       |
        | the mode "yolo"               | must be one of the choices  |
        | the publishing "push-to-main" | must be one of the choices  |
        | an empty prompt               | the prompt cannot be empty  |
