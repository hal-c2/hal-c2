# Sources:
#   plugins/planner/plugin.json (settings, actions and their prompts, permissions, page, thread kind)
#   plugins/planner/mc/planner.ex (the plan, views, agent runs, proposals, agent tools)
#   plugins/planner/mc/sync.ex (GitHub issues, milestones, sub-issues, dependencies and boards)
#   plugins/planner/ui/PlannerPage.qml, PlannerSettings.qml, PlannerHeader.qml, PlannerRowMark.qml
#   plugins/planner/mc/slack.ex (status updates, proposals and slash commands in Slack)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (Host.issues, Host.pull_requests, Host.launch_thread, Host.slack)
#   docs/user/planner.md

@plugin-planner
Feature: Planner
  The planner plugin keeps a plan of tasks and milestones for an MC's projects: dates,
  dependencies, progress and who does what, shown as a Gantt chart, a board or a list,
  in views the user saves. Agents act on it through actions whose prompts the user
  edits, such as validating progress, rescheduling or giving feedback, and what they
  want to change comes back as a proposal the user accepts. Tasks can follow GitHub
  issues, milestones and boards, and the pull requests that close them, and the plan
  talks to a Slack channel through the MC's Slack connection.

  Background:
    Given an MC running the plugin "planner"
    And the project "api" whose remote is "acme/api" on GitHub

  Rule: The plan holds tasks, milestones and how they depend on each other

    @mc
    Scenario: The user adds a task with dates
      When the user adds the task "Rate limits" in "api" from "2026-10-19" to "2026-10-30"
      Then the plan has "Rate limits" from "2026-10-19" to "2026-10-30", not started

    @mc
    Scenario: A milestone has a date and no length
      When the user adds the milestone "Beta" on "2026-11-30"
      Then the plan has the milestone "Beta" on "2026-11-30"

    @mc
    Scenario: A task can be a subtask of another
      Given the plan has the task "Rate limits"
      When the user adds the task "Limit storage" under "Rate limits"
      Then "Limit storage" is a subtask of "Rate limits"

    @mc
    Scenario: A task that starts before the one it waits for has ended is marked
      Given the plan has "Schema" from "2026-10-19" to "2026-10-23"
      And the plan has "API" from "2026-10-21" to "2026-10-30"
      When the user makes "API" wait for "Schema"
      Then "API" is marked as starting before "Schema" ends

    @mc
    Scenario: A task cannot wait for itself through other tasks
      Given "API" waits for "Schema"
      When the user makes "Schema" wait for "API"
      Then the user is told that would make "Schema" wait for itself
      And "Schema" waits for nothing

    @mc
    Scenario: A task with no title, or fields that are not an object, is refused
      Given the plan has the task "Rate limits"
      When a client adds a task with no title
      Then the planner answers "A task needs a title."
      When a client changes "Rate limits" with fields that are not an object
      Then the planner answers "Give the fields as an object."
      And the plan holds only "Rate limits"

    @mc
    Scenario: A pull request or issue that is not a repository and a number is neither linked nor unlinked
      Given "Rate limits" is linked to #12 of "acme/api"
      When a client links "Rate limits" to a pull request and to an issue whose repository is not text
      Then the planner answers "link gives just one of: a pullRequest or an issue as {repository, number}, or a threadId."
      When a client unlinks from "Rate limits" a pull request whose repository is not text
      Then the planner answers "unlink gives the pull request as {repository, number}."
      When a client unlinks from "Rate limits" an issue it does not name
      Then the planner answers "unlink gives the issue as {repository, number}."
      And "Rate limits" is linked to #12

    @mc
    Scenario: A link to two things at once is refused rather than half made
      Given the plan has the task "Rate limits"
      When a client links "Rate limits" to the pull request #12 and the issue #7 of "acme/api" at once
      Then the planner answers "link gives just one of: a pullRequest or an issue as {repository, number}, or a threadId."
      And "Rate limits" is linked to no pull request and no issue

    @mc
    Scenario: A client that still shows a task's old issue does not unlink its new one
      Given "Rate limits" is linked to the issue #7 of "acme/api"
      And another client relinks "Rate limits" to the issue #8
      When a client that still shows #7 unlinks it from "Rate limits"
      Then "Rate limits" is linked to the issue #8

    # A look and the pushes follow one task per issue.
    @mc
    Scenario: A task cannot be linked to an issue another task has
      Given "Rate limits" is linked to the issue #7 of "acme/api"
      When a client links "Docs" to the issue #7
      Then the planner answers "Rate limits already has the issue acme/api#7."
      And "Docs" is linked to no pull request and no issue

    @mc
    Scenario: A task moves from one milestone to another in one step
      Given the milestones "Beta" and "Launch", with "Beta" waiting for "API"
      When the user moves "API" from "Beta" to "Launch"
      Then "Launch" waits for "API" and "Beta" no longer does

    @mc
    Scenario: A move to something that is not a milestone changes neither
      Given the milestones "Beta" and "Launch", with "Beta" waiting for "API"
      When the user moves "API" from "Beta" to "Schema"
      Then the user is told there is no milestone "Schema"
      And "Beta" still waits for "API"

    @mc
    Scenario: A task past its due date that is not done is late
      Given today is "2026-10-31"
      And the plan has "API" due "2026-10-30" and in progress
      Then "API" is marked late

    @mc
    Scenario: Removing a task keeps its subtasks and drops what waited on it
      Given "Limit storage" is a subtask of "Rate limits"
      And "Docs" waits for "Rate limits"
      When the user removes "Rate limits"
      Then "Limit storage" has no parent
      And "Docs" waits for nothing

    @mc
    Scenario: A task's progress follows its subtasks until the user sets it
      Given "Rate limits" has the subtasks "Limit storage", done, and "Limit API", not started
      Then "Rate limits" is 50% done
      When the user sets "Rate limits" to 80% done
      Then "Rate limits" is 80% done

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A task that ends before its baseline says how many days early
      Given the plan has "API" ending 3 days before its baseline
      When the user opens the task "API"
      Then its panel says it ends 3 days before its baseline

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The chart reaches back to a baseline long before the plan
      Given the plan has the milestone "Launch" due 200 days after its baseline
      When the user is on the view "Timeline"
      Then the chart reaches back to the baseline of "Launch"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A task names a project the MC no longer offers
      Given the plan has "API" in the project "gone"
      When the user opens the task "API"
      Then its project reads "gone"

    @mc
    Scenario: A baseline keeps the dates to compare against
      Given the plan has "API" from "2026-10-21" to "2026-10-30"
      When the user saves a baseline
      And "API" moves to end on "2026-11-04"
      Then "API" shows it ends 5 days after its baseline

    @mc
    Scenario: The plan survives a restart of the plugin
      Given the plan has the task "Rate limits"
      When "planner" is restarted
      Then the plan has the task "Rate limits"

    @mc
    Scenario: Every client of the MC sees a change to the plan
      Given two clients watch the plan
      When the user moves "API" to start on "2026-10-26"
      Then both clients see "API" start on "2026-10-26"

  Rule: Views show the plan the way each user wants it

    @mc
    Scenario: A new plan has a timeline, a board and a list
      When the user opens the plan for the first time
      Then it has the views "Timeline", "Board" and "All tasks"

    @mc
    Scenario: The user saves a view of their own
      When the user saves the view "Backend this month" as a Gantt chart of "api" grouped by owner, zoomed to weeks, without done tasks
      Then every client has the view "Backend this month" with that layout, filter, grouping and zoom

    @mc
    Scenario: A view that is not valid is refused
      When the user saves a view grouped by "colour"
      Then the user is told "colour" is not something a view can group by

    @mc
    Scenario: The user removes a view
      Given the view "Backend this month"
      When the user removes "Backend this month"
      Then no client has the view "Backend this month"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The Gantt chart draws tasks, milestones, dependencies and today
      Given the plan has "Schema" from "2026-10-19" to "2026-10-23", "API" waiting for it, and the milestone "Beta"
      When the user switches to the "Planner" tab with the view "Timeline"
      Then "Schema" and "API" are bars on the timeline with an arrow from "Schema" to "API"
      And "Beta" is a milestone marker and today is marked

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Dragging a bar reschedules the task
      Given the plan has "API" from "2026-10-21" to "2026-10-30"
      When the user drags the bar of "API" one week later on the "Timeline"
      Then "API" is moved to "2026-10-28" to "2026-11-06"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A milestone without a date has no marker
      Given the plan has the milestone "Beta" without a due date
      When the user switches to the "Planner" tab with the view "Timeline"
      Then "Beta" is listed with no marker on the timeline

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Dragging the end of a bar changes when the task ends
      Given the plan has "API" from "2026-10-21" to "2026-10-30"
      When the user drags the end of the bar of "API" to "2026-11-03"
      Then "API" ends on "2026-11-03"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The board moves a task between states
      Given the plan has "API" not started
      When the user drags "API" to "In progress" on the "Board"
      Then "API" is in progress

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The board shows dropped work
      Given the plan has "Docs" dropped
      When the user switches to the "Planner" tab with the view "Board"
      Then "Docs" is under "Dropped" on the board

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The board grouped by parent moves a subtask to another parent
      Given the plan has "Routes" under "API" and "Pages" under "Web"
      And the "Board" is grouped by "parent"
      When the user drags "Routes" to "Web" on the "Board"
      Then "Routes" is moved under "Web"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The board grouped by milestone moves a task to another milestone
      Given the milestones "Beta" and "Launch", with "Beta" waiting for "API"
      And the "Board" is grouped by "milestone"
      When the user drags "API" to "Launch" on the "Board"
      Then "Launch" waits for "API" and "Beta" no longer does

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The board not grouped shows every task in one column
      Given the plan has "API" not started and "Docs" dropped
      And the "Board" is grouped by "none"
      When the user switches to the "Planner" tab with the view "Board"
      Then "API" and "Docs" are in the one column of the board

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The list shows the fields the view picks
      Given the view "All tasks" shows the owner and the due date
      When the user opens "All tasks"
      Then each task's owner and due date are columns of the list

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user edits a view and saves it
      Given the user is on the view "Timeline"
      When the user groups it by project, zooms to months and saves it
      Then "Timeline" is grouped by project at months on every client

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user filters a view without saving it
      Given the user is on the view "All tasks"
      When the user types "limits" in the filter
      Then only tasks matching "limits" are shown
      And "All tasks" is marked as changed until it is saved or reverted

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user picks a view with the keyboard
      Given the user is on the view "Timeline"
      When the user tabs from the view "Timeline" to "Board" and presses Enter
      Then the planner shows the view "Board"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario Outline: The user opens a task from the keyboard on <view>
      Given the plan has "API"
      When the user focuses "API" on "<view>" and presses Enter
      Then the panel of "API" is open and "API" is marked as focused

      Examples:
        | view      |
        | Timeline  |
        | Board     |
        | All tasks |

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A group folds and unfolds from the keyboard
      Given the plan has "API"
      And the "All tasks" is grouped by "status"
      When the user focuses the group "To do" on "All tasks" and presses Space
      Then "API" is hidden until the user presses Space again

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The list scrolls sideways to columns wider than it
      Given the view "All tasks" shows every field
      When the user scrolls the list sideways to its end
      Then the column of the last field is shown

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user edits a task from any view
      Given the plan has "API"
      When the user opens "API" and sets its owner to "dana" and its due date to "2026-11-06"
      Then "API" is owned by "dana" and due "2026-11-06"

  Rule: Agents act on the plan through actions whose prompts the user edits

    @mc
    Scenario: The plugin comes with actions
      When the user opens the settings of "planner"
      Then the actions "Validate progress", "Reschedule", "Give feedback", "Break down", "Write status update" and "Start work" are there, each with its prompt

    @mc
    Scenario: Running an action starts a thread with its prompt filled in
      Given the action "Validate progress" has the prompt "Check {{item.title}}, due {{item.due}}."
      When the user runs "Validate progress" on "API", due "2026-10-30"
      Then a thread in "api" starts with the configured agent and "Check API, due 2026-10-30."
      And the run of "Validate progress" on "API" is running

    @mc
    Scenario: A plan action is told the whole plan
      Given the action "Reschedule" has the prompt "Today is {{today}}. The plan:\n{{plan}}"
      When the user runs "Reschedule"
      Then its thread starts with today's date and every task with its dates, state and dependencies

    @mc
    Scenario: The user adds an action of their own
      When the user adds the action "Find risks" on the whole plan with the prompt "List the risks in {{plan}}"
      Then "Find risks" can be run on the plan

    @mc
    Scenario: An action's prompt can be reset to the plugin's
      Given the user changed the prompt of "Reschedule"
      When the user resets the prompt of "Reschedule"
      Then the next run of "Reschedule" uses the plugin's prompt

    @mc
    Scenario: An action with an empty prompt is refused
      When the user saves the action "Reschedule" with an empty prompt
      Then the save is refused saying the prompt of "Reschedule" cannot be empty

    @mc
    Scenario: An action on a task with no project runs in the default project
      Given the default project of "planner" is "api"
      And the plan has "Write launch post" in no project
      When the user runs "Give feedback" on "Write launch post"
      Then its thread starts in "api"

    @mc
    Scenario: An action with nowhere to run says so
      Given "planner" has no default project
      And the plan has "Write launch post" in no project
      When the user runs "Give feedback" on "Write launch post"
      Then the user is told to give "Write launch post" a project or set a default project

    @mc
    Scenario: The agent of an action can read the plan
      Given the run of "Reschedule" is running
      When its agent reads the plan
      Then it gets every task with its dates, state, progress, dependencies and links

    @mc
    Scenario: An agent whose turn ends without reporting fails its run
      Given the run of "Validate progress" on "API" is running
      When the agent's turn ends without a report
      Then the run is failed saying the agent reported nothing

    @mc
    Scenario: A failed run can be tried again
      Given the run of "Validate progress" on "API" failed
      When the user retries it
      Then a new thread starts for "Validate progress" on "API"

    @mc
    Scenario: A run the plugin stopped during can still report
      Given the run of "Reschedule" is running
      When "planner" is restarted
      Then the run is failed saying the plugin stopped while it ran
      And its agent can still report

  Rule: What an agent wants to change is a proposal the user accepts

    @mc
    Scenario: A reschedule comes back as a proposal
      Given the run of "Reschedule" is running
      When its agent reports moving "API" to end on "2026-11-06" because "Schema slipped"
      Then the run proposes moving "API" to end on "2026-11-06" with the reason
      And "API" still ends on "2026-10-30"

    @mc
    Scenario: The user accepts some of a proposal
      Given the run of "Reschedule" proposes moving "API" and "Docs"
      When the user dismisses the change to "Docs" and applies the run
      Then "API" is moved and "Docs" is not
      And the run is applied

    @mc
    Scenario: A proposal can add subtasks
      Given the run of "Break down" on "Rate limits" is running
      When its agent reports the subtasks "Limit storage" and "Limit API", the second waiting for the first
      And the user applies the run
      Then "Rate limits" has the subtasks "Limit storage" and "Limit API", the second waiting for the first

    @mc
    Scenario: A change to a task removed since the proposal is not applied
      Given the run of "Reschedule" proposes moving "Docs"
      And the user has removed "Docs"
      When the user applies the run
      Then the change to "Docs" is marked as no longer applicable

    @mc
    Scenario: A proposal that would make a task wait for itself goes back to the agent
      Given the run of "Reschedule" is running
      And "API" waits for "Schema"
      When its agent reports making "Schema" wait for "API"
      Then the agent is told that would make "Schema" wait for itself
      And the run is still running

    @mc
    Scenario: A proposal that names a task not in the plan goes back to the agent
      Given the run of "Reschedule" is running
      When its agent reports making "API" wait for the task "routes"
      Then the agent is told there is no task "routes"
      And the run is still running

    @mc
    Scenario: A proposal that links a task to two things at once goes back to the agent
      Given the run of "Reschedule" is running
      When its agent reports linking "API" to the pull request #12 and the issue #7 of "acme/api" at once
      Then the agent is told "Change 1: link gives in fields just one of: a pullRequest or an issue as {repository, number}."
      And the run is still running

    @mc
    Scenario: A proposal linking a task to an issue another task has goes back to the agent
      Given "API" is linked to the issue #7 of "acme/api"
      And the run of "Reschedule" is running
      When its agent reports linking "Docs" to the issue #7 of "acme/api"
      Then the agent is told "Change 1: API already has the issue acme/api#7."
      And the run is still running

    @mc
    Scenario: A proposal linking an issue another task has is not applied
      Given the run of "Reschedule" is running
      And its agent proposes linking "Docs" to the issue #7 of "acme/api"
      And "API" is linked to the issue #7 of "acme/api"
      When the user applies the run
      Then the link of "Docs" is marked as no longer applicable, as "API" has the issue
      And "Docs" is linked to no pull request and no issue

    @mc
    Scenario: An issue a proposal links with a state that is not text is still told to the next action
      Given the run of "Reschedule" is running
      And its agent proposes linking "Docs" to the issue #7 of "acme/api" with a state that is not text
      And the user applies the run
      When the user runs "Reschedule"
      Then its thread is told "Docs" is linked to the open issue #7 of "acme/api"

    @mc
    Scenario: An action set to apply its changes applies them as it reports
      Given "Validate progress" applies its changes without asking
      And the run of "Validate progress" on "API" is running
      When its agent reports "API" is 60% done
      Then "API" is 60% done
      And the run is applied

    @mc
    Scenario: The user discards a proposal
      Given the run of "Reschedule" proposes moving "API"
      When the user discards the run
      Then "API" is not moved and the run is gone

    @mc
    Scenario: Only the latest finished runs are kept
      Given the planner keeps the 2 latest finished runs
      And the run of "Reschedule" proposes moving "API"
      When "Give feedback", "Write status update" and "Reschedule" each run and report nothing to change
      Then the runs are the proposal of "Reschedule" and the last two that finished

    @mc
    Scenario: Feedback lands on the tasks it is about
      Given the run of "Give feedback" is running
      When its agent reports the feedback "No owner yet" on "Docs" and "The order looks right" on the plan
      Then "Docs" has the feedback "No owner yet"
      And the run's summary has "The order looks right"

    @mc
    Scenario: The user dismisses feedback
      Given "Docs" has the feedback "No owner yet"
      When the user dismisses that feedback
      Then "Docs" has no feedback

    @mc
    Scenario: A status update keeps a history of how the plan is going
      Given the run of "Write status update" is running
      When its agent reports the plan is "at risk" with "Schema slipped three days"
      And the user applies the run
      Then the plan's latest update is "at risk" with "Schema slipped three days"
      And the earlier updates are kept

    @mc
    Scenario: The user writes a status update themselves
      When the user posts the update "on track" with "Beta still holds"
      Then the plan's latest update is "on track" with "Beta still holds"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A proposal shows on the Gantt chart before it is applied
      Given the run of "Reschedule" proposes moving "API" to end on "2026-11-06"
      When the user opens the run on the "Planner" tab
      Then the bar "API" would have is drawn beside its current one
      And the run list counts only the changes the user keeps
      And the user can dismiss the change, apply the run or discard it

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: An action's thread shows its run above the conversation
      Given the run of "Reschedule" proposes moving "API"
      When the user opens the run's thread
      Then the action, the state of its run and the apply action are shown above the conversation

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A proposal of only a status update can be applied
      Given the run of "Write status update" proposes only that the plan is "at-risk"
      When the user opens the run's thread
      Then the run can be applied from its thread and from the "Planner" tab
      And the run list says it proposes a status update

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A late answer to an apply stays with the run it applied
      Given the run of "Reschedule" proposes moving "API"
      And the run of "Validate progress" proposes moving "API"
      When the user applies "Reschedule" from its thread and opens the thread of "Validate progress" before the MC answers
      And the MC refuses to apply "Reschedule"
      Then the thread of "Validate progress" can be applied and shows no problem

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A run on another MC names that MC's task
      Given a second MC also runs "planner", whose run of "Validate progress" proposes moving its own "Rollout"
      When the user opens that MC's run on the "Planner" tab
      Then the run is listed with that MC's name and "Rollout"
      And its change names "Rollout"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: An action's thread is marked in the thread list
      Given "planner" shows its threads in the thread list
      When the user runs "Reschedule"
      Then its thread is listed with the planner mark and the state of its run
      And its mark says so when the run proposes only a status update

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A task's thread keeps the task mark once its run is discarded
      Given "planner" shows its threads in the thread list
      And the work on "API" is done
      When its run is discarded
      Then its thread is listed with the mark "Task"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario Outline: A task's thread stops following the plan once it no longer shows the task
      Given the agent works on "API" in its thread, which shows the task above the conversation
      When <change>
      Then the header no longer follows the plan

      Examples:
        | change                                             |
        | the user opens the thread of a run of "Reschedule" |
        | the work on "API" is discarded                     |

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings edit each action's prompt and reset it
      Given the user opens the settings of "planner"
      When the user changes the prompt of "Reschedule" and resets "Give feedback"
      Then the prompt of "Reschedule" is saved as changed and "Give feedback" as the plugin's

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: What the user changes while the settings save is kept
      Given the user opens the settings of "planner"
      When the user changes the prompt of "Reschedule" and saves, then changes it again before the settings are read back
      Then the prompt of "Reschedule" holds the second change, left to save

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings save again only once the last save is read back
      Given the user opens the settings of "planner"
      When the user saves a change to the prompt of "Reschedule", then undoes it and tries to save again before the settings are read back
      Then the prompt of "Reschedule" is the plugin's again, left to save

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: A save whose read-back fails is what the next save starts from
      Given the user opens the settings of "planner"
      When the user saves a change to the prompt of "Reschedule", then undoes it before a read-back that fails
      Then the prompt of "Reschedule" is the plugin's again, left to save

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings name a model and project the MC no longer offers
      Given "planner" runs its actions on the model "claude-retired" in the project "gone"
      When the user opens the planner's settings
      Then the planner's model reads "claude-retired" and its default project "gone"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings take no count the MC refuses
      Given the user opens the planner's settings
      When the user types "0" as the actions at once and as the minutes between looks at GitHub
      Then neither setting is changed

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings do not save while a count reads what it cannot be
      Given the user opens the planner's settings
      When the user changes the prompt of "Reschedule", clears the actions at once and saves
      Then nothing is saved, and the settings say "Actions at once must be a whole number of at least 1."

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: Starting work is always on one task
      When the user opens the planner's settings
      Then "Start work" can only be on a task, while "Reschedule" can be on a task or the plan

  Rule: Work on a task is a thread linked to it

    @mc
    Scenario: Starting work on a task opens a thread in a worktree of its project
      When the user runs "Start work" on "API"
      Then a thread in a new worktree of "api" starts working on "API"
      And the thread is linked to "API"
      And "API" is in progress

    @mc
    Scenario: Work that cannot start leaves its task as it was
      Given "planner" runs its actions with an agent this MC does not have
      When the user starts work on "API"
      Then the run is failed saying there is no such agent
      And "API" is not started and no thread is linked to it

    @mc
    Scenario: Work whose thread cannot be set up fails rather than holding its turn
      Given the MC cannot set up worktrees
      When the user starts work on "API"
      Then the run is failed saying its thread could not start
      And "API" is not started and no thread is linked to it

    @mc
    Scenario: Work waiting its turn fails if its task is removed first
      Given "planner" runs one action at a time
      And the user started work on "API"
      And the user starts work on "Docs", which waits its turn
      When "Docs" is removed and the work on "API" ends
      Then the work on "Docs" is failed saying its task was removed

    @mc
    Scenario: The agent working on a task reports its progress
      Given the user started work on "API"
      When its agent reports "API" is 40% done with the note "Endpoints done, tests next"
      Then "API" is 40% done with that note

    @mc
    Scenario: The agent working on a task links the pull request it opened
      Given the user started work on "API"
      When its agent links the pull request #12 of "acme/api"
      Then "API" is linked to #12

    @mc
    Scenario: A pull request the agent links with a state that is not text is still told to the next action
      Given the user started work on "API"
      And its agent links the pull request #12 of "acme/api" with a state that is not text
      When the user runs "Reschedule"
      Then its thread is told "API" is linked to the open pull request #12 of "acme/api"

    @mc
    Scenario: A thread not linked to the plan gets no planner tools
      When an agent in a thread "planner" did not start lists its tools
      Then no planner tool is offered

    @mc
    Scenario: The user offers the plan to every thread
      Given "planner" offers the plan to every thread
      When an agent in any thread lists its tools
      Then it can read the plan but not change it

  Rule: Tasks follow pull requests and GitHub issues

    @mc
    Scenario: A task done when its pull requests merge
      Given "API" is linked to #12 of "acme/api"
      When #12 is merged
      And the plugin looks at GitHub
      Then "API" is done

    @mc
    Scenario: A pull request linked as merged moves its task when the plugin looks
      Given "API" is linked to #12 of "acme/api" as merged
      And #12 is merged
      When the plugin looks at GitHub
      Then "API" is done

    @mc
    Scenario: A task the user reopens after its pull request merged stays open
      Given "API" is linked to #12 of "acme/api"
      And #12 is merged
      And the plugin looks at GitHub
      When the user reopens "API"
      And the plugin looks at GitHub
      Then "API" is to do

    @mc
    Scenario: A pull request linked with a state that is not text is still told to the next action
      Given "API" is linked to #12 of "acme/api" with a state that is not text
      When the user runs "Reschedule"
      Then its thread is told "API" is linked to the open pull request #12 of "acme/api"

    @mc
    Scenario: A task's progress counts its merged pull requests
      Given "API" is linked to #12 and #13 of "acme/api", and #12 is merged
      When the plugin looks at GitHub
      Then "API" is 50% done

    @mc
    Scenario: A task follows a pull request past the first page of the repository's list
      Given "API" is linked to #12 of "acme/api"
      And "acme/api" has 500 pull requests updated since #12
      When #12 is merged
      And the plugin looks at GitHub
      Then "API" is done

    @mc
    Scenario: Following a task's pull request reads no further than the page it is on
      Given "API" is linked to #12 of "acme/api"
      And "acme/api" has 500 pull requests updated before #12
      When #12 is merged
      And the plugin looks at GitHub
      Then "API" is done
      And the plugin read no page of "acme/api"'s pull requests past #12

    @mc
    Scenario: A merged pull request is not looked for again
      Given "API" is linked to #12 of "acme/api"
      And #12 is merged
      When the plugin looks at GitHub
      And the plugin looks at GitHub
      Then "API" is done
      And the plugin did not list "acme/api"'s pull requests again

    @mc
    Scenario: A pull request one task saw merge still moves another task linked to it later
      Given "API" is linked to #12 of "acme/api"
      And #12 is merged
      And the plugin looks at GitHub
      When "Docs" is linked to the merged #12 of "acme/api"
      And the plugin looks at GitHub
      Then "Docs" is done

    @mc
    Scenario: A pull request linked from a repository no project checks out still moves its task when it merges
      Given "API" is linked to #12 of "acme/web"
      When #12 of "acme/web" is merged
      And the plugin looks at GitHub
      Then "API" is done

    @mc
    Scenario: Open issues of a followed repository become tasks
      Given "planner" follows the issues of "acme/api"
      And "acme/api" has the open issue #7 "Rate limits" assigned to "dana" with the label "backend"
      When the plugin looks at GitHub
      Then the plan has "Rate limits" linked to #7, owned by "dana" with the label "backend"

    @mc
    Scenario: Only issues with the planner label are followed when one is set
      Given "planner" follows the issues of "acme/api" labelled "roadmap"
      And "acme/api" has the open issues #7 labelled "roadmap" and #8 without it
      When the plugin looks at GitHub
      Then the plan has #7 and not #8

    @mc
    Scenario: The planner label matches whatever its case on GitHub
      Given "planner" follows the issues of "acme/api" labelled "RoadMap"
      And "acme/api" has the open issues #7 labelled "roadmap" and #8 without it
      When the plugin looks at GitHub
      Then the plan has #7 and not #8

    @mc
    Scenario: Milestones become milestones of the plan
      Given "planner" follows the issues of "acme/api"
      And "acme/api" has the milestone "Beta" due "2026-11-30" holding #7
      When the plugin looks at GitHub
      Then the plan has the milestone "Beta" on "2026-11-30" waiting for #7's task

    @mc
    Scenario: Sub-issues and blocking issues become subtasks and dependencies
      Given "planner" follows the issues of "acme/api"
      And #9 is a sub-issue of #7, and #7 is blocked by #5
      When the plugin looks at GitHub
      Then #9's task is a subtask of #7's, and #7's task waits for #5's

    @mc
    Scenario: A sub-issue taken out of its parent on GitHub leaves its parent in the plan
      Given "planner" follows the issues of "acme/api"
      And #9's task was imported as a subtask of #7's
      When #9 is taken out of #7 on GitHub
      And the plugin looks at GitHub
      Then #9's task is not a subtask

    @mc
    Scenario: A sub-issue moved under an issue the plan does not follow leaves its old parent
      Given "planner" follows the issues of "acme/api"
      And #9's task was imported as a subtask of #7's
      When #9 is moved on GitHub from #7 to "acme/web" #3, which the plan does not follow
      And the plugin looks at GitHub
      Then #9's task is not a subtask

    @mc
    Scenario: A task the user put under another while GitHub's answer was on its way never ends up under its own child
      Given "planner" follows the issues of "acme/api"
      And the tasks of #9 and #7 were imported, neither a subtask of the other
      And GitHub lists #7 as a sub-issue of #9 late
      When the user puts #9's task under #7's while the plugin looks at GitHub
      Then #9's task is a subtask of #7's, and #7's task is not a subtask

    @mc
    Scenario: A parent and sub-issue swapped on GitHub swap in the plan in one look
      Given "planner" follows the issues of "acme/api"
      And #9's task was imported as a subtask of #7's
      When #7 is moved on GitHub under #9, which leaves it
      And the plugin looks at GitHub
      Then #7's task is a subtask of #9's, and #9's task is not a subtask

    # Taken one at a time, each issue's new relations meet the other's old ones and make
    # a loop, so the look judges them together.
    @mc
    Scenario: A parent and sub-issue swapped on GitHub along with the dependency between them swap in the plan in one look
      Given "planner" follows the issues of "acme/api"
      And #9's task was imported as a subtask of #7's, and #7's task waits for #9's
      When #7 is moved on GitHub under #9, and #9 is blocked by #7 instead
      And the plugin looks at GitHub
      Then #7's task is a subtask of #9's, and #9's task waits for #7's

    @mc
    Scenario: An issue moved out of a milestone on GitHub stops holding it up
      Given "planner" follows the issues of "acme/api"
      And the tasks of #7 and #8 were imported in the milestone "Beta"
      When #7 is moved out of "Beta" on GitHub, leaving #8 in it
      And the plugin looks at GitHub
      Then the milestone "Beta" waits for #8's task and not #7's

    @mc
    Scenario: A milestone whose last issue left on GitHub stops waiting for it
      Given "planner" follows the issues of "acme/api"
      And the tasks of #7 and #8 were imported in the milestone "Beta"
      When #7 and #8 are moved out of "Beta" on GitHub
      And the plugin looks at GitHub
      Then the milestone "Beta" waits for no task

    @mc
    Scenario: The pull requests that close an issue are linked to its task
      Given "planner" follows the issues of "acme/api"
      And #7 is closed by the pull request #12
      When the plugin looks at GitHub
      Then #7's task is linked to #12

    # The issue is GitHub's word on its task: still open after the pull request merged,
    # it was reopened or is not done, and a task done would close it again.
    @mc
    Scenario: An open issue whose closing pull request merged already becomes a task to do
      Given "planner" follows the issues of "acme/api"
      And #7 is closed by the pull request #12, which merged already
      When the plugin looks at GitHub
      Then #7's task is linked to #12
      And #7's task is to do

    @mc
    Scenario: An issue reopened after its closing pull request merged keeps its task to do
      Given "planner" follows the issues of "acme/api"
      And #7 is closed by the pull request #12
      And the plugin looks at GitHub
      When #12 is merged
      And #7 is reopened on GitHub, still closed by #12
      And the plugin looks at GitHub
      Then #7's task is to do

    @mc
    Scenario: A pull request linked by hand to an open issue's task still makes it done when it merges
      Given "planner" follows the issues of "acme/api"
      And #7 is closed by the pull request #12
      And the plugin looks at GitHub
      And "Issue 7" is linked to #14 of "acme/api"
      When #12 is merged
      And #14 is merged
      And the plugin looks at GitHub
      Then #7's task is done

    @mc
    Scenario: A pull request that no longer closes an issue leaves its task, one linked by hand stays
      Given "planner" follows the issues of "acme/api"
      And #7 is closed by the pull request #12
      And the plugin looks at GitHub
      And "Issue 7" is linked to #14 of "acme/api"
      When #7 is no longer closed by #12 on GitHub
      And the plugin looks at GitHub
      Then #7's task is linked to #14 and not #12

    @mc
    Scenario: A closed issue's task is done
      Given #7's task is in progress
      When #7 is closed on GitHub
      And the plugin looks at GitHub
      Then #7's task is done

    @mc
    Scenario: A closed issue whose reason changes on GitHub moves its task between done and dropped
      Given #7's task is in progress
      And #7 is closed on GitHub
      And the plugin looks at GitHub
      When #7 is closed on GitHub as not planned
      And the plugin looks at GitHub
      Then #7's task is dropped

    @mc
    Scenario: A closed issue GitHub has not changed since the last look is not read again
      Given #7's task is in progress
      And #7 is closed on GitHub
      And the plugin looks at GitHub
      When the plugin looks at GitHub again, with nothing there changed since
      Then #7's task is done
      And that look read no issue alone

    @mc
    Scenario: A closed issue renamed on GitHub since the last look is renamed from the issues changed since
      Given #7's task is in progress
      And #7 is closed on GitHub
      And the plugin looks at GitHub
      When the closed #7 is renamed on GitHub to "Rate limiting" with the description "Shipped in 2.4"
      And the plugin looks at GitHub again
      Then #7's task is named "Rate limiting" with the notes "Shipped in 2.4"
      And that look read no issue alone

    @mc
    Scenario: A closed issue reopened on GitHub without the planner label is to do again
      Given "planner" follows the issues of "acme/api" labelled "roadmap"
      And "acme/api" has the open issue #7 "Rate limits" assigned to "dana" with the label "roadmap"
      And the plugin looks at GitHub
      And #7 is closed on GitHub
      And the plugin looks at GitHub
      When #7 is reopened on GitHub without the label
      And the plugin looks at GitHub again
      Then #7's task is to do
      And that look read no issue alone

    @mc
    Scenario: A task linked again to the closed issue it has stays as the user set it
      Given #7's task is in progress
      And #7 is closed on GitHub
      And the plugin looks at GitHub
      When the user reopens #7's task
      And a client links #7's task to #7 again
      And the plugin looks at GitHub
      Then #7's task is to do

    @mc
    Scenario: An issue edited on GitHub updates its task's title and notes
      Given "planner" follows the issues of "acme/api"
      And #7's task was imported as "Rate limits"
      When #7 is renamed on GitHub to "Rate limiting" with the description "Per token, not per IP"
      And the plugin looks at GitHub
      Then #7's task is named "Rate limiting" with the notes "Per token, not per IP"

    @mc
    Scenario: Dates come from the board's fields
      Given "planner" follows the board "acme/3" with "Start date" and "Target date" as its dates
      And #7 is on "acme/3" from "2026-10-20" to "2026-11-02"
      When the plugin looks at GitHub
      Then #7's task is from "2026-10-20" to "2026-11-02"

    @mc
    Scenario: A date cleared on the board is cleared from the task
      Given "planner" follows the board "acme/3" with "Start date" and "Target date" as its dates
      And #7 was imported from "acme/3" with the dates "2026-10-20" to "2026-11-02"
      When the "Target date" of #7 is cleared on "acme/3"
      And the plugin looks at GitHub
      Then #7's task starts on "2026-10-20" and has no due date

    # A field renamed or deleted on the board, or one that holds no dates, says nothing
    # about the task's dates: they stay until the settings name a date field it has.
    @mc
    Scenario: A date field the board no longer has leaves the task's dates
      Given "planner" follows the board "acme/3" with "Start date" and "Target date" as its dates
      And #7 was imported from "acme/3" with the dates "2026-10-20" to "2026-11-02"
      When "acme/3" renames its "Target date" field to "Due date"
      And the plugin looks at GitHub
      Then #7's task is from "2026-10-20" to "2026-11-02"

    @mc
    Scenario: The settings offer the open boards of the projects' owners
      Given "acme" has the boards "acme/3" "Roadmap" and "acme/4" "Old roadmap", which is closed
      When the settings of "planner" list the boards
      Then they offer "acme/3" "Roadmap" and not "acme/4"

    @mc
    Scenario: The settings offer the date fields of the chosen board
      Given the board "acme/3" has the fields "Status", "Start date" and "Target date"
      When the settings of "planner" read the fields of "acme/3"
      Then they offer "Start date" and "Target date" as its dates

    @mc
    Scenario: Boards gh may not list say how to let it
      Given gh is signed in without the "project" scope
      When the settings of "planner" list the boards
      Then they say gh needs the "project" scope

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user picks the board and its date fields from lists in the settings
      Given "acme" has the board "acme/3" "Roadmap" with the date fields "Begins" and "Ends"
      When the user opens the planner's settings
      And the user picks the board "Roadmap" with "Begins" and "Ends" as its dates
      Then "planner" is saved following "acme/3" with "Begins" and "Ends" as its dates

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings unmap a date field of the board
      Given "acme" has the board "acme/3" "Roadmap" with the date fields "Begins" and "Ends"
      And "planner" follows the board "acme/3" with "Begins" and "Ends" as its dates
      When the user opens the planner's settings
      And the user picks None for the board's start date
      Then "planner" is saved with no field for its start date

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings say why the board's date fields could not be read
      Given "planner" follows the board "acme/9" with "Begins" and "Ends" as its dates
      When the user opens the planner's settings
      Then beside its date fields the settings say "acme/9 was not found."
      And the date fields are typed in as "Begins" and "Ends"

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario Outline: A screen reader names the planner's settings when the board's date fields are <dates>
      Given "acme" has the board "acme/3" "Roadmap" with the date fields "Begins" and "Ends"
      And "planner" follows the board "<board>" with "Begins" and "Ends" as its dates
      When the user opens the planner's settings
      Then the board's date fields are <dates>
      And a screen reader names the settings:
        | Actions at once                |
        | Only issues labelled           |
        | Start date field               |
        | Target date field              |
        | Look at GitHub every (minutes) |
        | Slash command                  |

      Examples:
        | board  | dates              |
        | acme/3 | picked from a list |
        | acme/9 | typed in           |

    @mc
    Scenario Outline: With two-way sync a change to a task reaches GitHub
      Given "planner" syncs "acme/api" both ways with the board "acme/3"
      When the user <change> #7's task
      Then GitHub is asked to <effect>

      Examples:
        | change                         | effect                                         |
        | marks as done                  | close #7 as completed                          |
        | renames to "Rate limiting"     | rename #7 to "Rate limiting"                   |
        | moves to end on "2026-11-09"   | set "Target date" of #7 on "acme/3" to "2026-11-09" |
        | makes wait for #5's task       | mark #7 as blocked by #5                       |

    # The plan keeps the state a push gave the issue, so a move on GitHub after it moves
    # the task.
    @mc
    Scenario Outline: A task <status> here whose issue is reopened on GitHub before the next look is to do again
      Given "planner" syncs "acme/api" both ways
      And the user marks #7's task as <status>
      When #7 is reopened on GitHub
      And the plugin looks at GitHub
      Then #7's task is to do

      Examples:
        | status  |
        | done    |
        | dropped |

    @mc
    Scenario: A task reopened here whose issue is closed again on GitHub before the next look is done again
      Given "planner" syncs "acme/api" both ways
      And #7 is closed on GitHub
      And the plugin looks at GitHub
      And the user reopens #7's task
      When #7 is closed on GitHub
      And the plugin looks at GitHub
      Then #7's task is done

    @mc
    Scenario: A task not on the board the plan switches to is added to it before its dates are set
      Given "planner" syncs "acme/api" both ways with the board "acme/3"
      And the board "acme/4" holds #5 and not #7
      When "planner" switches to the board "acme/4"
      And the plugin looks at GitHub
      And the user moves #7's task to end on "2026-11-09"
      Then GitHub is asked to add #7 to "acme/4" and set its "Target date" to "2026-11-09"

    @mc
    Scenario: An issue taken off the board is added back before its dates are set
      Given "planner" syncs "acme/api" both ways with the board "acme/3"
      And the board "acme/3" holds #5 and not #7
      When the plugin looks at GitHub
      And the user moves #7's task to end on "2026-11-09"
      Then GitHub is asked to add #7 to "acme/3" and set its "Target date" to "2026-11-09"

    # A board item is empty when it is added, and what the board holds is what the next
    # look reads, so it is given all of the task's dates, not only the one that changed.
    @mc
    Scenario: An issue added to the board is given all of its task's dates
      Given "planner" syncs "acme/api" both ways with the board "acme/3"
      And the board "acme/3" holds #5 and not #7
      When the plugin looks at GitHub
      And the user moves #7's task to end on "2026-11-09"
      Then GitHub is asked to add #7 to "acme/3" and set its "Target date" to "2026-11-09"
      And its "Start date" on "acme/3" is set to "2026-10-20" too

    # Part of a board says nothing of the issues on the rest of it.
    @mc
    Scenario: An issue past the part of the board that was read keeps its place on it
      Given "planner" syncs "acme/api" both ways with the board "acme/3"
      And the board "acme/3" has more items than the plugin reads, and #7 is past them
      When the plugin looks at GitHub
      And the user moves #7's task to end on "2026-11-09"
      Then GitHub is asked to set "Target date" of #7 on "acme/3" to "2026-11-09"

    @mc
    Scenario: A task relinked to another issue is added to the board before its dates are set
      Given "planner" syncs "acme/api" both ways with the board "acme/3"
      When the user relinks #7's task to #8
      And the user moves #8's task to end on "2026-11-09"
      Then GitHub is asked to add #8 to "acme/3" and set its "Target date" to "2026-11-09"

    # GitHub holds an issue in one milestone, so a move between two is one change.
    @mc
    Scenario: A task moved between imported milestones is moved on GitHub
      Given "planner" syncs "acme/api" both ways
      And #7 is in the milestone "Beta" and #9 in "Launch" on GitHub
      When the user moves "Issue 7" from "Beta" to "Launch"
      Then GitHub is asked once to move #7 to the milestone "Launch"

    # GitHub keeps the move that reaches it last, which can be one the user has moved the
    # task on from, so a move GitHub takes after the next one is set right.
    @mc
    Scenario: A task moved on again before GitHub takes its first move ends in the milestone it was moved to last
      Given "planner" syncs "acme/api" both ways
      And #7 is in the milestone "Beta", #9 in "Launch" and #12 in "Release" on GitHub
      And GitHub takes moving #7 to "Launch" late and to "Release" at once
      When the user moves "Issue 7" from "Beta" to "Launch", then to "Release" before GitHub answers
      Then GitHub has #7 in the milestone "Release" last

    # A move between milestones is asked of GitHub by the milestone the task moved to, so
    # a task that leaves that one before it asks still leaves the one GitHub has it in.
    @mc
    Scenario: A task moved to a milestone and out of it before GitHub answers leaves the milestone it was in
      Given "planner" syncs "acme/api" both ways
      And #7 is in the milestone "Beta", #9 in "Launch" and #12 in "Release" on GitHub
      And GitHub takes moving #7 to "Release" late
      When the user moves "Issue 7" from "Beta" to "Release", then "Issue 9" from "Launch" to "Release" and out of it, before GitHub answers
      Then GitHub is asked once to move #9 out of its milestone

    # GitHub takes other milestones' moves while a milestone's change is on its way, so a
    # task moved out and back meanwhile is moved back on GitHub.
    @mc
    Scenario: A task moved out of a milestone and back while the milestone's change is on its way to GitHub moves back on GitHub
      Given "planner" syncs "acme/api" both ways
      And #7 is in the milestone "Beta", #9 in "Launch" and #12 in "Release" on GitHub
      And GitHub takes moving #9 to "Beta" late
      When the user moves "Issue 9" from "Launch" to "Beta", then "Issue 7" from "Beta" to "Release" and back, before GitHub answers
      Then GitHub is asked last to move #7 to the milestone "Beta"

    # GitHub has the issue where it was until it takes the move, which a look can read.
    @mc
    Scenario: A task moved to another milestone stays there when the plugin looks at GitHub before the move takes
      Given "planner" syncs "acme/api" both ways
      And #7 is in the milestone "Beta" and #9 in "Launch" on GitHub
      And GitHub takes moving #7 to "Launch" late
      When the user moves "Issue 7" from "Beta" to "Launch" and the plugin looks at GitHub before GitHub answers
      Then #7's task is in the milestone "Launch" and not "Beta"

    # GitHub can take a task's first move after its move back, and the milestone it moved
    # to first then asks GitHub to move it back again, so a look in between does not take
    # the task out of the milestone it moved back to.
    @mc
    Scenario: A task moved back before GitHub takes its first move stays back when the plugin looks at GitHub in between
      Given "planner" syncs "acme/api" both ways
      And #7 is in the milestone "Beta" and #9 in "Launch" on GitHub
      And GitHub takes moving #7 to "Launch" late
      And GitHub takes moving #7 to "Beta" late
      When the user moves "Issue 7" from "Beta" to "Launch" and back, GitHub takes the move back first, and the plugin looks at GitHub once it takes the first move
      Then #7's task is in the milestone "Beta" and not "Launch"

    # A refused move stands until the milestone's next change, so a look does not put the
    # task back in the milestone GitHub still has its issue in.
    @mc
    Scenario: A task GitHub refused to move to another milestone stays where the user moved it
      Given "planner" syncs "acme/api" both ways
      And #7 is in the milestone "Beta" and #9 in "Launch" on GitHub
      And GitHub refuses changes to #7
      When the user moves "Issue 7" from "Beta" to "Launch"
      And the plugin looks at GitHub
      Then #7's task is in the milestone "Launch" and not "Beta"
      And the milestone "Launch" is marked as not synced

    @mc
    Scenario: A dependency on a task without an issue stays in the plan
      Given "planner" syncs "acme/api" both ways
      And the plan has "Docs" in "api"
      When the user makes #7's task wait for "Docs"
      Then GitHub is not asked to mark #7 as blocked
      And #7's task is marked as synced

    @mc
    Scenario: With import only, a change to a task stays in the plan
      Given "planner" follows the issues of "acme/api" without syncing back
      When the user marks #7's task as done
      Then GitHub is not asked to change #7

    @mc
    Scenario: A change GitHub refuses is kept and marked
      Given "planner" syncs "acme/api" both ways
      And GitHub refuses changes to #7
      When the user renames #7's task to "Rate limiting"
      Then #7's task is named "Rate limiting" and marked as not synced, with GitHub's reason

    @mc
    Scenario: A change GitHub refused goes again with the task's next one
      Given "planner" syncs "acme/api" both ways
      And GitHub refuses changes to #7
      And the user renames #7's task to "Rate limiting"
      And GitHub takes changes to #7 again
      When the user labels #7's task "api"
      Then GitHub is asked to rename #7 to "Rate limiting" and label it "api" at once
      And GitHub is never asked to change #7's assignees
      And #7's task is named "Rate limiting" and marked as synced

    @mc
    Scenario: A dependency GitHub refused to drop goes again with the task's next change
      Given "planner" syncs "acme/api" both ways
      And #7 is blocked by #5 on GitHub
      And GitHub refuses to unblock #7
      And the user makes #7's task wait for nothing
      And GitHub takes unblocking #7 again
      When the user renames #7's task to "Rate limiting"
      Then GitHub is asked a second time to unblock #7 from #5
      And #7's task is named "Rate limiting" and marked as synced

    @mc
    Scenario Outline: Removing a task drops its relation to another on GitHub
      Given "planner" syncs "acme/api" both ways
      And <relation>
      When the user removes "Issue 5"
      Then GitHub is asked to <effect>

      Examples:
        | relation                                    | effect             |
        | #7 is blocked by #5 on GitHub               | unblock #7 from #5 |
        | #7's task was imported as a subtask of #5's | take #7 out of #5  |

    @mc
    Scenario: A dependency on a removed task GitHub refused to drop goes again with the task's next change
      Given "planner" syncs "acme/api" both ways
      And #7 is blocked by #5 on GitHub
      And GitHub refuses to unblock #7
      And the user removes "Issue 5"
      And GitHub takes unblocking #7 again
      When the user renames #7's task to "Rate limiting"
      Then GitHub is asked a second time to unblock #7 from #5
      And #7's task is named "Rate limiting" and marked as synced

    @mc
    Scenario: A task stays marked as not synced until its refused change takes
      Given "planner" syncs "acme/api" both ways
      And #7 is blocked by #5 on GitHub
      And GitHub refuses to unblock #7
      And the user makes #7's task wait for nothing
      When the user renames #7's task to "Rate limiting"
      Then #7's task is marked as not synced

    # An earlier push may have taken without the plugin hearing, say it stopped first.
    @mc
    Scenario: A dependency GitHub no longer has is taken as dropped
      Given "planner" syncs "acme/api" both ways
      And #7 is blocked by #5 on GitHub
      And GitHub answers unblocking #7 that #5 no longer blocks it
      When the user makes #7's task wait for nothing
      Then #7's task is marked as synced

    @mc
    Scenario: An owner GitHub refused goes again with the task's next change
      Given "planner" syncs "acme/api" both ways
      And GitHub refuses changes to #7
      And the user makes "dana" the owner of #7's task
      And GitHub takes changes to #7 again
      When the user renames #7's task to "Rate limiting"
      Then GitHub is asked to rename #7 to "Rate limiting" and assign it to "dana" at once
      And #7's task is named "Rate limiting" and marked as synced

    @mc
    Scenario: Only the latest change to a task says whether it synced
      Given "planner" syncs "acme/api" both ways
      And GitHub answers renaming #7 to "Rate limiting" late, refusing it
      When the user renames #7's task to "Rate limiting", then to "Rate limits" before GitHub answers
      Then #7's task is named "Rate limits" and marked as synced

    # The owner waits for GitHub to answer the rename, then goes with the name, as GitHub
    # refused it; GitHub takes that push.
    @mc
    Scenario: A change made while an earlier one waits on GitHub sends both
      Given "planner" syncs "acme/api" both ways
      And GitHub answers renaming #7 to "Rate limiting" late, refusing it
      When the user renames #7's task to "Rate limiting", then makes "dana" its owner before GitHub answers
      Then GitHub is asked to rename #7 to "Rate limiting" and assign it to "dana" at once
      And #7's task is named "Rate limiting" and marked as synced

    # GitHub keeps the change that reaches it last, so a change waits for GitHub to answer
    # the one before it.
    @mc
    Scenario: A rename made while an earlier one waits on GitHub is the one GitHub keeps
      Given "planner" syncs "acme/api" both ways
      And GitHub takes renaming #7 to "Rate limiting" late and to "Rate limits" at once
      When the user renames #7's task to "Rate limiting", then to "Rate limits" before GitHub answers
      Then GitHub names #7 "Rate limits" last
      And #7's task is named "Rate limits" and marked as synced

    @mc
    Scenario: A change GitHub answers after its task was unlinked does not mark the task
      Given "planner" syncs "acme/api" both ways
      And GitHub answers renaming #7 to "Rate limiting" late, refusing it
      When the user renames #7's task to "Rate limiting", then unlinks it before GitHub answers
      Then "Rate limiting" is linked to no issue and not marked as not synced

    # The relink pushes nothing: no project on the MC has "acme/web".
    @mc
    Scenario: A change GitHub answers after its task was relinked to another issue does not mark the task
      Given "planner" syncs "acme/api" both ways
      And GitHub answers renaming #7 to "Rate limiting" late, refusing it
      When the user renames #7's task to "Rate limiting", then relinks it to "acme/web" #3 before GitHub answers
      Then "Rate limiting" is linked to "acme/web" #3 and not marked as not synced

    @mc
    Scenario: A look at GitHub that began before a change to a task does not undo it
      Given "planner" syncs "acme/api" both ways
      And #7's task was imported as "Rate limits"
      And GitHub lists #7 as "Rate limits" late
      When the user renames #7's task to "Rate limiting" while the plugin looks at GitHub
      Then #7's task is named "Rate limiting" and marked as synced

    @mc
    Scenario: A look at GitHub while a change to a task waits on GitHub does not undo it
      Given "planner" syncs "acme/api" both ways
      And GitHub answers renaming #7 to "Rate limiting" late, taking it
      When the user renames #7's task to "Rate limiting", then the plugin looks at GitHub before GitHub answers
      Then #7's task is named "Rate limiting" and marked as synced

    @mc
    Scenario: The plan can be read while a change to a task waits on the MC's projects
      Given "planner" syncs "acme/api" both ways
      And the MC is slow to read its projects' git remotes
      When the user renames #7's task to "Rate limiting" while the MC reads them
      Then the plan could be read meanwhile
      And GitHub is asked to rename #7 to "Rate limiting"

    @mc
    Scenario: The user makes a task into an issue
      Given the plan has "Docs" in "api"
      When the user creates an issue for "Docs" in "acme/api"
      Then GitHub is asked to create the issue "Docs"
      And "Docs" is linked to the new issue

    @mc
    Scenario: An issue made from a task has the task's labels
      Given the plan has "Docs" in "api" labelled "docs"
      When the user creates an issue for "Docs" in "acme/api"
      Then GitHub is asked to create the issue "Docs" labelled "docs"

    # GitHub makes an issue open and on no board, so the plugin asks for the rest.
    @mc
    Scenario: An issue created for a done task is closed
      Given "planner" syncs "acme/api" both ways
      And the plan has "Docs" in "api", done
      When the user creates an issue for "Docs" in "acme/api"
      Then GitHub is asked to close #13 as completed

    @mc
    Scenario: An issue created for a dated task gets its dates on the board
      Given "planner" syncs "acme/api" both ways with the board "acme/3"
      And the plan has "Docs" in "api"
      When the user creates an issue for "Docs" in "acme/api"
      Then GitHub is asked to add #13 to "acme/3" and set its "Target date" to "2026-11-02"
      And its "Start date" on "acme/3" is set to "2026-10-26" too

    @mc
    Scenario: With import only, an issue created for a done task stays as it was made
      Given "planner" follows the issues of "acme/api" without syncing back
      And the plan has "Docs" in "api", done
      When the user creates an issue for "Docs" in "acme/api"
      Then GitHub is not asked to change #13

    # GitHub relates a new issue to no other, so the plugin asks it to.
    @mc
    Scenario Outline: A task given an issue keeps the tasks it is tied to
      Given "planner" syncs "acme/api" both ways
      And the plan has "Docs" in "api"
      And the user <ties>
      When the user creates an issue for "Docs" in "acme/api"
      And the plugin looks at GitHub, which has taken what it was asked
      Then <tied>

      Examples:
        | ties                            | tied                             |
        | makes "Docs" wait for "Issue 7" | "Docs" still waits for "Issue 7" |
        | makes "Issue 7" wait for "Docs" | "Issue 7" still waits for "Docs" |
        | puts "Docs" under "Issue 7"     | "Docs" is a subtask of "Issue 7" |
        | puts "Issue 7" under "Docs"     | "Issue 7" is a subtask of "Docs" |

    # GitHub relates issues, not tasks, so the ties go from the issue a task had to the
    # one it has now. The look names #7's task after #8, and #7, still open, comes back
    # as a task of its own, tied to nothing.
    @mc
    Scenario Outline: A task linked to another issue moves its ties to it
      Given "planner" syncs "acme/api" both ways
      And the plan has "Docs" in "api"
      And the user <ties>
      And the user creates an issue for "Docs" in "acme/api"
      When the user relinks #7's task to #8
      Then GitHub is asked to <drop>
      And GitHub is asked to <add>
      When the plugin looks at GitHub, which has taken what it was asked
      Then <tied>
      And "Issue 7" is tied to no other task

      Examples:
        | ties                            | drop                | add              | tied                             |
        | makes "Docs" wait for "Issue 7" | unblock #13 from #7 | block #13 by #8  | "Docs" still waits for "Issue 8" |
        | makes "Issue 7" wait for "Docs" | unblock #7 from #13 | block #8 by #13  | "Issue 8" still waits for "Docs" |
        | puts "Docs" under "Issue 7"     | take #13 out of #7  | put #13 under #8 | "Docs" is a subtask of "Issue 8" |
        | puts "Issue 7" under "Docs"     | take #7 out of #13  | put #8 under #13 | "Issue 8" is a subtask of "Docs" |

    @mc
    Scenario: A dependency dropped after the task it waits for was relinked leaves the issue it has now
      Given "planner" syncs "acme/api" both ways
      And the plan has "Docs" in "api"
      And the user creates an issue for "Docs" in "acme/api"
      And the user makes "Docs" wait for "Issue 7"
      And GitHub is asked to block #13 by #7
      And the user relinks #7's task to #8
      When the user makes #13's task wait for nothing
      Then GitHub is asked to unblock #13 from #8
      When the plugin looks at GitHub, which has taken what it was asked
      Then GitHub has #13 blocked by no issue
      And "Docs" waits for nothing

    # A task with no issue is in the plan alone, so what waits for it or sits under it
    # leaves its old issue on GitHub.
    @mc
    Scenario Outline: A task unlinked from its issue takes its ties off it
      Given "planner" syncs "acme/api" both ways
      And the plan has "Docs" in "api"
      And the user <ties>
      And the user creates an issue for "Docs" in "acme/api"
      When the user unlinks #7's task from its issue
      Then GitHub is asked to <drop>
      And <tied>

      Examples:
        | ties                            | drop                | tied                             |
        | makes "Docs" wait for "Issue 7" | unblock #13 from #7 | "Docs" still waits for "Issue 7" |
        | puts "Docs" under "Issue 7"     | take #13 out of #7  | "Docs" is a subtask of "Issue 7" |

    @mc
    Scenario: A repository with no project on the MC is reported
      Given "planner" follows the issues of "acme/web"
      When the plugin looks at GitHub
      Then the plugin reports that no project has "acme/web"

    @mc
    Scenario: A board the gh login may not read is reported
      Given "planner" follows the board "acme/3"
      And gh is signed in without the "project" scope
      When the plugin looks at GitHub
      Then the plugin reports that gh needs the "project" scope
      And the tasks it has are kept

    @mc
    Scenario: An issue list or board too long to read whole is reported
      Given "planner" follows the issues of "acme/api" and the board "acme/3"
      And "acme/api" has more open issues, and "acme/3" more items, than the plugin reads
      When the plugin looks at GitHub
      Then the plugin reports that only part of "acme/api" and of "acme/3" was read

    @backlog @mc
    Scenario: Issues from other hosts become tasks
      Given "planner" follows the issues of a repository on GitLab
      When the plugin looks at it
      Then its open issues become tasks

  Rule: The plan talks to a Slack channel

    Background:
      Given the MC is connected to Slack as the bot "HAL"
      And "planner" posts to the Slack channel "#planning"

    @mc
    Scenario: Status updates are posted to the channel
      When the user posts the update "Docs slip a week" saying the plan is at risk
      Then "#planning" gets "Docs slip a week" marked at risk

    @mc
    Scenario: An applied status update from an agent is posted too
      Given "Write status update" proposed the update "On track" saying the plan is on track
      When the user applies it
      Then "#planning" gets "On track" marked on track

    @mc
    Scenario: A proposal waiting for the user is announced
      When "Reschedule" proposes 3 changes
      Then "#planning" is told "Reschedule" has 3 changes waiting in HAL-C2

    @mc
    Scenario: Announcing proposals can be turned off
      Given "planner" does not announce proposals in Slack
      When "Reschedule" proposes 3 changes
      Then nothing is posted to "#planning"

    @mc
    Scenario: A reply to a posted update becomes feedback on the plan
      Given the update "Docs slip a week" was posted to "#planning"
      When "dana" replies "Can API wait too?" in its thread
      Then the plan has the feedback "Can API wait too?" from "dana" in Slack

    @mc
    Scenario: An update keeps its Slack post when the answer to a later post is heard first
      Given Slack is down while the updates "Docs slip a week" and "API is back" are posted
      When the planner hears "API is back" was posted, then that "Docs slip a week" was posted before it
      And "dana" replies "Can API wait too?" in its thread
      Then the plan has the feedback "Can API wait too?" from "dana" in Slack

    @mc
    Scenario: The slash command answers with how the plan stands
      Given "API" is late and "Docs" is in progress
      When "dana" runs "/planner status" in Slack
      Then only "dana" is shown that "API" is late, "Docs" is in progress, and the latest health

    @mc
    Scenario: The slash command runs an action on a task
      When "dana" runs "/planner validate API" in Slack
      Then a "Validate progress" run of "API" starts
      And only "dana" is told it started

    @mc
    Scenario: The slash command names what it cannot find
      When "dana" runs "/planner validate Nothing" in Slack
      Then only "dana" is told no task is called "Nothing"

    @mc
    Scenario: The slash command asks which task a title shared by two means
      Given the plan has a second task called "API"
      When "dana" runs "/planner validate API" in Slack
      Then only "dana" is asked to run "Validate progress" on one of the "API" tasks by its id
      And no run starts
      When "dana" runs "/planner run validate" with the second "API" task's id in Slack
      Then a "Validate progress" run of the second "API" task starts

    @mc
    Scenario: The slash command asks which action a word shared by two means
      Given the user added the actions "Check API" and "Check docs" on the whole plan
      When "dana" runs "/planner check" in Slack
      Then only "dana" is asked to run "Check API" or "Check docs" by its id
      And no run starts

    @mc
    Scenario: An action saved with a space before its label still runs by its first word
      Given the user added the action " Check risks" on the whole plan
      When "dana" runs "/planner check" in Slack
      Then a " Check risks" run of the plan starts

    @mc
    Scenario: The slash command's answer names each action the way that runs it
      When "dana" runs "/planner nothing" in Slack
      And "dana" runs the line its answer gives for "Write status update"
      Then a "Write status update" run of the plan starts

    @mc
    Scenario: Without a Slack connection updates stay in the plan
      Given the MC is not connected to Slack
      When the user posts the update "Docs slip a week" saying the plan is at risk
      Then the plan has the update "Docs slip a week"
      And the plugin reports that Slack is not connected

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user picks the planner's Slack channel in its settings
      Given the MC is connected to Slack
      When the user opens the planner's settings
      Then the channels the bot is in are offered for "Post to Slack channel"
