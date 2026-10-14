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
    Scenario: The settings edit each action's prompt and reset it
      Given the user opens the settings of "planner"
      When the user changes the prompt of "Reschedule" and resets "Give feedback"
      Then the prompt of "Reschedule" is saved as changed and "Give feedback" as the plugin's

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The settings name a model and project the MC no longer offers
      Given "planner" runs its actions on the model "claude-retired" in the project "gone"
      When the user opens the planner's settings
      Then the planner's model reads "claude-retired" and its default project "gone"

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
    Scenario: Only the latest change to a task says whether it synced
      Given "planner" syncs "acme/api" both ways
      And GitHub answers renaming #7 to "Rate limiting" late, refusing it
      When the user renames #7's task to "Rate limiting", then to "Rate limits" before GitHub answers
      Then #7's task is named "Rate limits" and marked as synced

    @mc
    Scenario: A change GitHub answers after its task was unlinked does not mark the task
      Given "planner" syncs "acme/api" both ways
      And GitHub answers renaming #7 to "Rate limiting" late, refusing it
      When the user renames #7's task to "Rate limiting", then unlinks it before GitHub answers
      Then "Rate limiting" is linked to no issue and not marked as not synced

    @mc
    Scenario: A look at GitHub that began before a change to a task does not undo it
      Given "planner" syncs "acme/api" both ways
      And #7's task was imported as "Rate limits"
      And GitHub lists #7 as "Rate limits" late
      When the user renames #7's task to "Rate limiting" while the plugin looks at GitHub
      Then #7's task is named "Rate limiting" and marked as synced

    @mc
    Scenario: The user makes a task into an issue
      Given the plan has "Docs" in "api"
      When the user creates an issue for "Docs" in "acme/api"
      Then GitHub is asked to create the issue "Docs"
      And "Docs" is linked to the new issue

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
      When "dana" runs "/planner validate" with the second "API" task's id in Slack
      Then a "Validate progress" run of the second "API" task starts

    @mc
    Scenario: The slash command asks which action a word shared by two means
      Given the user added the actions "Check API" and "Check docs" on the whole plan
      When "dana" runs "/planner check" in Slack
      Then only "dana" is asked to run "Check API" or "Check docs" by its id
      And no run starts

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
