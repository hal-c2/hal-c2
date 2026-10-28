# Sources:
#   plugins/issue-tracker/plugin.json (settings, permissions, page)
#   plugins/issue-tracker/mc/issue_tracker.ex (looking, triage runs, proposals, implementing)
#   plugins/issue-tracker/mc/triage.ex (report shape, what applying a proposal asks GitHub for)
#   plugins/issue-tracker/ui/IssuesPage.qml, IssueTrackerSettings.qml
#   apps/server-ex/lib/hal_c2/issues.ex (issues through gh: list, detail, update, comment)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (issues, projects, providers, threads for plugins)
#   docs/user/issue-tracker.md
#
# The MC scenarios run from apps/server-ex with
#   mise exec -- mix features source-control/issue-tracker.feature
# (steps in test/steps/source_control/issue_tracker_steps.exs). The page is covered
# by the QML tests in plugins/issue-tracker/test against a fake MC part; desktop
# tst_Features steps are the follow-up that takes the @backlog-desktop tags off.

@plugin-issue-tracker
Feature: Issue tracker
  The issue-tracker plugin is the triage queue in front of a repository's GitHub
  issues. It lists the open issues of the repositories it follows, and agents the
  user picks prioritise them, draft follow-up questions for their reporters, and
  summarise them. What an agent wants to change comes back as a proposal: nothing
  reaches GitHub until the user applies it. From an issue, the implementing agent
  starts work in a thread of its own and is asked to open a pull request that
  closes the issue.

  Background:
    Given an MC running the plugin "issue-tracker" over GitHub issues
    And the project "api" whose remote is "acme/api" on GitHub
    And "issue-tracker" follows "acme/api"

  Rule: The queue lists what GitHub has

    @mc @desktop @backlog-desktop
    Scenario: The open issues of a followed repository are listed
      Given "acme/api" has the open issues #7 "Add limits" and #9 "Flaky test"
      When the tracker looks at GitHub
      Then #7 and #9 are listed with their titles, authors and labels

    @mc
    Scenario: Only issues with the followed label are listed
      Given "issue-tracker" follows only issues labelled "triage"
      And "acme/api" has the open issue #7 labelled "triage" and #9 without it
      When the tracker looks at GitHub
      Then GitHub is asked only for issues labelled "triage"
      And #7 is listed and #9 is not

    @mc
    Scenario: With no repositories chosen, every GitHub project on the MC is followed
      Given "issue-tracker" follows no repositories in particular
      And "acme/api" has the open issues #7 "Add limits" and #9 "Flaky test"
      When the tracker looks at GitHub
      Then #7 and #9 are listed with their titles, authors and labels

    @mc @desktop @backlog-desktop
    Scenario: A repository GitHub cannot be read for says so, and the rest still list
      Given "issue-tracker" also follows "acme/web"
      And "acme/api" has the open issues #7 "Add limits" and #9 "Flaky test"
      And the issues of "acme/web" cannot be read
      When the tracker looks at GitHub
      Then #7 and #9 are listed with their titles, authors and labels
      And the tracker says "acme/web" could not be read

    @mc @desktop @backlog-desktop
    Scenario: Looking again is the user's to ask for
      Given "acme/api" has the open issues #7 "Add limits" and #9 "Flaky test"
      And the tracker has looked at GitHub
      When the user asks the plugin to look now
      Then the tracker looks at GitHub again

    @mc @desktop @backlog-desktop
    Scenario: An issue opens with its body and where it stands
      Given "acme/api" has the open issue #7, blocked by #5, in the milestone "Beta"
      When the user opens #7
      Then they get #7 with its body, milestone and the issue blocking it

  Rule: Triage agents propose; the user decides what reaches GitHub

    @mc @desktop @backlog-desktop
    Scenario: The prioritising agent ranks a repository's queue
      Given "acme/api" has the open issues #7 "Add limits" and #9 "Flaky test"
      And the tracker has looked at GitHub
      When the user asks for "acme/api" to be prioritised
      Then a prioritising run is running in a thread of the configured agent
      And its thread is asked with the queue of "acme/api" filled in

    @mc
    Scenario: A prioritising report waits as a proposal
      Given a prioritising run on "acme/api"
      When its agent reports #9 before #7, #9 "high" and #7 "low", each with a reason
      Then the run is proposed with that order and those priorities
      And GitHub is asked for nothing

    @mc @desktop @backlog-desktop
    Scenario: Applying a prioritising proposal sets the priority labels
      Given a proposed prioritising run with #9 "high" and #7 "low"
      When the user applies the proposal
      Then GitHub is asked to label #9 "backend" and "priority: high"
      And GitHub is asked to label #7 "priority: low"
      And the triage run is applied

    @mc @desktop @backlog-desktop
    Scenario: The follow-up agent drafts a question for an issue's reporter
      Given #7 "Add limits" by "dana" says "Limits would be nice."
      When the user asks for a follow-up on #7
      Then a follow-up run is running in a thread of the configured agent
      And its thread is asked with #7, its body and its reporter filled in

    @mc @desktop @backlog-desktop
    Scenario: Applying a follow-up proposal posts its comment
      Given a proposed follow-up run on #7 with the comment "Which limits, and per what?"
      When the user applies the proposal
      Then GitHub is asked to comment "Which limits, and per what?" on #7
      And the triage run is applied

    @mc
    Scenario: A follow-up report on another issue is sent back
      Given a follow-up run on #7
      When its agent reports a comment for #9
      Then the triage agent is told "Report on acme/api#7 and nothing else."
      And the triage run is still running

    @mc
    Scenario: A follow-up that finds nothing missing has nothing to apply
      Given a follow-up run on #7
      When its agent reports that #7 is ready to work on, with no comment
      Then the run is done with that summary
      And GitHub is asked for nothing

    @mc @desktop @backlog-desktop
    Scenario: The summarising agent summarises an issue and names its duplicates
      Given "acme/api" has the open issues #7 "Add limits" and #11 "Rate limiting"
      And the tracker has looked at GitHub
      When the user asks for #7 to be summarised
      Then a summarising run is running in a thread of the configured agent
      And its thread is asked with #7 and the other open titles filled in

    @mc
    Scenario: A summarising report shows its summary and duplicates as a proposal
      Given a summarising run on #7
      When its agent reports a summary of #7 naming #11 its duplicate
      Then the run is proposed with the summary and #11 named
      And GitHub is asked for nothing

    @mc @desktop @backlog-desktop
    Scenario: A proposal the user dismisses reaches nothing
      Given a proposed follow-up run on #7 with the comment "Which limits, and per what?"
      When the user dismisses the proposal
      Then the run is discarded
      And GitHub is asked for nothing

    @mc
    Scenario: A triage agent that ends its turn without reporting fails its run
      Given a follow-up run on #7
      When its agent's turn ends and it never reported
      Then the run is failed, saying it finished without reporting

    @mc
    Scenario: A triage thread reads the queue through the plugin's tools
      Given a prioritising run on "acme/api"
      When its agent reads the queue with the "issue_tracker_read" tool
      Then it gets the open issues the plugin last saw, with their bodies left out

    @mc
    Scenario: An implementing thread cannot report a triage proposal
      Given an implementing thread on #7
      Then it is offered the read tool but not the report tool

    @mc @desktop @backlog-desktop
    Scenario: Each triage action runs on the agent access picked for it
      Given the prioritising agent must ask before acting and the follow-up agent runs automatically
      And "acme/api" has the open issues #7 "Add limits" and #9 "Flaky test"
      And the tracker has looked at GitHub
      When the user asks for "acme/api" to be prioritised
      Then that thread runs with "approval-required"
      When the user asks for a follow-up on #7
      Then that thread runs with "auto"

    @mc
    Scenario: A proposal that only partly reaches GitHub says which part failed
      Given a proposed prioritising run with #9 "high" and #7 "low"
      And GitHub refuses to label #7
      When the user applies the proposal
      Then GitHub is asked to label #9 "backend" and "priority: high"
      And the run stays proposed, told #7 failed

    @mc
    Scenario: Applying again after a partial failure posts nothing twice
      Given a proposed summarising run on #7 with a comment and the label "summary"
      And GitHub refuses to label #7
      When the user applies the proposal
      Then GitHub is asked to comment "The short of it: per-key limits." on #7
      And the run stays proposed, told #7 failed
      When GitHub accepts labelling #7 again
      And the user applies the proposal
      Then GitHub is asked to label #7 "backend" and "summary"
      And the comment was posted exactly once
      And the triage run is applied

  Rule: Implementing an issue is work in a thread of its own

    @mc @desktop @backlog-desktop
    Scenario: Implementing starts the implementing agent on the issue
      Given #7 "Add limits" by "dana" says "Limits would be nice."
      When the user asks to implement #7
      Then a thread in a new worktree of "api" starts on #7
      And it is asked to open a pull request that closes #7

    @mc @desktop @backlog-desktop
    Scenario: The last implementing thread of an issue shows beside it
      Given an implementing thread on #7 whose turn has finished
      Then #7 shows its implementing thread done

    @mc
    Scenario: Implementing the same issue again starts fresh work
      Given an implementing thread on #7 whose turn has finished
      When the user asks to implement #7
      Then another thread in a new worktree of "api" starts on #7

    @mc
    Scenario: Implementing an issue of a repository with no project on the MC says so
      When the user asks to implement #3 of "acme/web"
      Then no implementing thread starts
      And the user is told to add a checkout of "acme/web" as a project

  Rule: Settings the plugin refuses stay unsaved

    @mc @desktop @backlog-desktop
    Scenario Outline: Settings that name nothing to follow or no agent are refused
      When the user saves the settings with <setting>
      Then the save is refused, told "<reason>"

      Examples:
        | setting                             | reason                                          |
        | a repository "acme"                 | repositories: give each as owner/name.         |
        | no agent for prioritising           | prioritising: name the agent that runs it.      |
        | an empty follow-up prompt           | followUpPrompt: the prompt cannot be empty.     |
        | looking every 0 minutes             | pollMinutes: look at most once a minute.        |

  Rule: The other clients come later

    @backlog-mobile @backlog-tui @mobile @tui
    Scenario: The queue and its proposals show on the phone and in the terminal
      Given #7 is listed with a proposed follow-up
      Then the phone and the terminal show the queue, the proposal, and applying it posts its comment
