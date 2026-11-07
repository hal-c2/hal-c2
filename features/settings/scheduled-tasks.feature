# Sources:
#   https://github.com/pingdotgg/t3code/pull/24149
#   https://github.com/pingdotgg/t3code/pull/23414
#   https://github.com/pingdotgg/t3code/pull/25291
#   https://github.com/pingdotgg/t3code/pull/26070
#   https://github.com/pingdotgg/t3code/pull/24046
#   https://github.com/pingdotgg/t3code/pull/23244
#   https://github.com/pingdotgg/t3code/pull/23282
#   https://github.com/pingdotgg/t3code/pull/20447
#   https://github.com/pingdotgg/t3code/pull/21026
#   https://github.com/pingdotgg/t3code/pull/18820
#   https://github.com/pingdotgg/t3code/pull/18144
#   https://github.com/pingdotgg/t3code/pull/15085
#   https://github.com/pingdotgg/t3code/pull/15087
#   https://github.com/pingdotgg/t3code/pull/15088
#   https://github.com/pingdotgg/t3code/pull/22899
#   https://github.com/pingdotgg/t3code/pull/25070
#   https://github.com/pingdotgg/t3code/pull/22194
#   https://github.com/pingdotgg/t3code/pull/22234
#   apps/server-ex/lib/hal_c2/scheduled_tasks.ex (store, timer, missed runs, run status)
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (list_scheduled_tasks, schedule_task, update_scheduled_task, delete_scheduled_task, run_scheduled_task_now)
#   apps/server-ex/lib/hal_c2/web/socket.ex (scheduledTasks subscription)
#   apps/server-ex/test/mc_parity_test.exs (scheduledTasks.* aligned)
#   packages/contracts/src/scheduledTask.ts (interval and fixed_time schedules, workspace strategies)
#   packages/contracts/src/rpc.ts (scheduledTasks.list, scheduledTasks.upsert, scheduledTasks.delete, scheduledTasks.setEnabled, scheduledTasks.runNow, scheduledTasks.subscribe)
#   apps/web/src/components/settings/ScheduledTasksSettings.tsx
#   apps/web/src/components/settings/scheduledTasksSettings.logic.ts
#   apps/web/src/components/settings/scheduledTasksSettings.logic.test.ts
#   apps/web/src/components/chat/ThreadAutomationsPanel.tsx (the tasks bound to a thread, in its details)
#   apps/web/src/components/WorktreeBaseBranchPicker.tsx
#   apps/desktop-qt/src/native/ScheduledTasksController.cpp
#   apps/desktop-qt/qml/HalC2/Bricks/ScheduledTaskEditor.qml
#   apps/desktop-qt/qml/HalC2/Bricks/js/scheduledTasks.js
#   apps/tui/src/host/sections/scheduledTasks.ts (the terminal client's list and editor)
#   https://github.com/pingdotgg/t3code/pull/28104
#   https://github.com/pingdotgg/t3code/pull/26658
#   https://github.com/pingdotgg/t3code/pull/22158

Feature: Scheduled tasks
  A scheduled task sends a saved prompt to a project on a timer, either at
  fixed times of day or every few minutes. The MC owns the schedule, so tasks
  keep running while no client is open.

  Background:
    Given an MC with a project "api"

  Rule: The MC runs tasks on their schedule

    @mc
    Scenario: A daily task runs at its time of day
      Given a task "Check Sentry" that runs at 09:00 on every day
      When the clock reaches 09:00
      Then the MC sends the task's prompt to the project
      And the task records a successful run

    @mc
    Scenario: A task with an interval runs repeatedly
      Given a task that runs every 15 minutes
      When 30 minutes pass
      Then the task has run twice

    @mc
    Scenario: A fixed time task only runs on its chosen weekdays
      Given a task that runs at 09:00 on weekdays
      When Saturday 09:00 passes
      Then the task does not run
      And its next run is Monday at 09:00

    @mc
    Scenario: A run missed while the machine was off is skipped, not fired late
      Given a task that runs at 09:00
      And the machine was off from 08:00 until 10:30
      When the MC starts again
      Then the task does not run immediately
      And its next run moves to the next 09:00

    # Upstream #28104: a task can run once at a date and time, then has no next run.
    @backlog @mc
    Scenario: A one-time task runs once at its date and time
      Given a task "Release notes" that runs once on Friday at 15:00
      When Friday 15:00 passes
      Then the task has run once
      And it has no next run

    # Upstream #28104: a one-time run missed while the MC was off runs when it is back, like intervals.
    @backlog @mc
    Scenario: A one-time run missed while the machine was off runs when the MC starts
      Given a task that runs once on Friday at 15:00
      And the machine was off from 14:00 until 16:00
      When the MC starts again
      Then the task runs
      And it has no next run

    # Upstream #28104
    @backlog @mc
    Scenario Outline: A one-time task cannot be aimed at the past
      Given it is Friday 16:00
      When the user <action> a task that runs once on Friday at 15:00
      Then it fails with "The run time has passed. Pick a time in the future."

      Examples:
        | action                  |
        | saves an enabled        |
        | resumes a paused        |

    # Upstream #28104: editing the title or prompt of a task that already ran neither fails nor runs it again.
    @backlog @mc
    Scenario: Editing a one-time task that already ran does not run it again
      Given a task that ran once on Friday at 15:00
      When the user changes its prompt on Saturday
      Then the task is saved
      And it does not run again

    # Upstream #28104: a save racing a finishing run keeps the run's next time.
    @backlog @mc
    Scenario: A one-time task saved while its run finishes runs only once
      Given a task that runs once is running
      When the user saves a new prompt for it before the run finishes
      Then the task has run once
      And it has no next run

    @mc
    Scenario Outline: A run goes to the task's thread or a new one
      Given a task <target>
      When the task runs
      Then the prompt <result>

      Examples:
        | target                          | result                          |
        | that names an existing thread   | is sent into that thread        |
        | with no thread                  | starts a new thread for the run |

    @mc
    Scenario: Tasks survive an MC restart
      Given a task that runs every hour
      When the MC restarts
      Then the task is still listed with its schedule and run history

    @mc
    Scenario: A run cut off by shutdown is marked failed
      Given a task is running
      When the MC stops
      Then after restart the task's last run failed with "The server stopped during this run."

    @mc
    Scenario: A run that never finishes is timed out after an hour
      Given a task is running and its prompt is never sent
      When the run's hour passes without it finishing
      Then the task's last run failed with "The run timed out."
      And the task has a next run again

  Rule: The user manages tasks

    @mc
    Scenario: The user runs a task now
      Given a task that runs daily
      When the user runs the task now
      Then the prompt is sent immediately
      And the run count goes up by one

    @mc
    Scenario: A task that is already running cannot be started again
      Given a task is running
      When the user runs the task now
      Then the user is told "Schedule task is already running."

    @mc
    Scenario: Deleting a task during its run ends the run
      Given a task is running and the user waits for it with "run now"
      When the user deletes the task
      Then the run is stopped and the waiting user is told "Schedule task not found."
      And a task made later with the same id starts with no run history

    @mc
    Scenario: Deleting a task stops the turn its run already started
      Given a task whose run's turn is already running in its thread
      When the user deletes the task
      Then the turn its run started is interrupted
      And the run is stopped and the waiting user is told "Schedule task not found."

    @mc
    Scenario: Pausing a task stops its runs and resuming schedules it again
      Given a task that runs every hour
      When the user pauses the task
      Then the task has no next run
      When the user resumes the task
      Then the task has a next run again

    # Upstream #22899: the task list sorts by creation, newest first, so a toggle,
    # run or edit no longer moves a task to the top under the user's pointer.
    @mc @backlog @priority-low
    Scenario: Tasks list newest first and keep their place when toggled
      Given the user created "Check Sentry" and then "Nightly report"
      Then the task list shows "Nightly report" above "Check Sentry"
      When the user pauses "Check Sentry"
      Then the task list still shows "Nightly report" above "Check Sentry"

    @mc
    Scenario: Editing a task without changing its schedule keeps its next run
      Given a task whose next run is in 20 minutes
      When the user changes the task's prompt
      Then the next run is still in 20 minutes

    @mc
    Scenario: A schedule shorter than a minute is refused
      When the user saves a task that runs every 30 seconds
      Then the user is told "The schedule is not valid."

    @mc
    Scenario: Editing a task that no longer exists fails
      Given another client deleted the task "Check Sentry"
      When the user saves changes to "Check Sentry"
      Then the user is told "Schedule task not found."

    @mc
    Scenario: Old tasks with a sub-minute interval can still be cleaned up
      Given a task saved by an older version that runs every 10 seconds
      Then the user can list, pause, edit and delete it

    @mc
    Scenario: Watching clients see task changes live
      Given two clients watch the scheduled tasks
      When one client creates a task
      Then the other client sees the task without refreshing

    @mc
    Scenario: An agent schedules a task for the user
      Given an agent in a thread with the MC's tools
      When the agent schedules a task to run every morning
      Then the task appears in the user's scheduled tasks
      And the task records that an agent created it

  Rule: The scheduled tasks settings

    @shared @backlog-mobile
    Scenario: The user creates a task with the defaults
      When the user starts a new task
      Then it starts in a new worktree from "main" fetched from origin
      And it runs at 09:00 on weekdays with full access
      And its model is the project's default model

    @shared @backlog-mobile
    Scenario Outline: A task runs in the workspace the user chose
      When the user creates a task that uses <workspace>
      Then each run works in <place>

      Examples:
        | workspace                  | place                          |
        | a new worktree             | a fresh worktree from the base |
        | the project checkout       | the project root               |
        | a specific checkout        | the chosen checkout path       |

    @shared @backlog-mobile
    Scenario Outline: An incomplete task cannot be saved
      When the user saves a task <problem>
      Then the user is told "<message>"

      Examples:
        | problem                                     | message                                  |
        | without a prompt                            | Scheduled task is incomplete             |
        | that runs every 0 minutes                   | Invalid interval                         |
        | that uses a specific checkout with no path  | Checkout path is required                |
        | on an environment that is disconnected      | Reconnect this environment before saving |

    @shared @backlog-mobile
    Scenario: Each task shows when it runs next and how it last went
      Given a paused task and a task that failed its last run
      When the user opens scheduled tasks
      Then the paused task says it is paused
      And the failed task shows its last error
      And the failed task is badged "Failed"
      And each task shows its prompt

    # The web said "No environments available" with none paired. A QML client shows settings only
    # once its MC has synced, so its own environment is always there.
    @dropped @shared
    Scenario: With no environment there are no tasks to manage
      When the user opens scheduled tasks with no environment
      Then the user is told no environments are available

    @shared @backlog-mobile
    Scenario: The base branch is picked from the project's branches
      Given the project "api" has the branches "main, release/2.0, feature/login"
      When the user starts a new task and types "rel" as its base branch
      Then the base branches offered are "release/2.0"

    @shared @backlog-mobile @priority-low
    Scenario: The last weekday of a task cannot be turned off
      Given a new task that runs only on Wednesday
      When the user turns Wednesday off and saves it
      Then the task still runs on Wednesday

    @shared @backlog-mobile @priority-low
    Scenario: Editing a task with a sub-minute interval says saving raises it
      Given a task saved by an older version that runs every 10 seconds
      When the user edits it
      Then the editor says saving raises the interval to a minute
      And saving it runs every minute

    # Upstream #26658: the editor kept a task's destination thread without ever showing it.
    @backlog @shared @priority-low
    Scenario Outline: The task editor says where the task's runs go
      Given the task "Check Sentry" <binding>
      When the user edits it
      Then the editor says <destination>

      Examples:
        | binding                          | destination                  |
        | is bound to "Triage"             | its runs go to "Triage"      |
        | starts a new thread for each run | each run starts a new thread |

    @shared @backlog-mobile @priority-low
    Scenario: An open editor says when its task was deleted elsewhere
      Given a task "Check Sentry"
      When the user edits the task and another client deletes it
      Then the editor says the task no longer exists

    @shared @backlog-mobile @priority-low
    Scenario: A slow save does not close a task opened after it
      When the user saves a task and starts another before the save is answered
      Then the first task is saved and the new task stays open

    @shared @backlog-mobile
    Scenario: The list follows the settings scope
      Given tasks in projects "api" and "web"
      When the user views scheduled tasks for project "api"
      Then only the tasks for "api" are listed

    @shared @backlog-mobile
    Scenario: The user deletes a task
      Given a task "Check Sentry"
      When the user deletes the task
      Then it no longer runs and is no longer listed

    @shared @backlog-mobile @priority-low
    Scenario: A link to a task that is gone says so
      When the user follows a link to a task that was deleted
      Then the user is told the task is unavailable

    @shared @backlog-mobile
    Scenario: Scheduled tasks on a disconnected environment offer to reconnect
      Given the environment "laptop" is disconnected
      When the user opens scheduled tasks for "laptop"
      Then the user is offered to reconnect "laptop"

    @backlog @desktop
    Scenario Outline: A task's schedule is described in words
      Given a task that runs <schedule>
      When the user opens scheduled tasks
      Then the task says "<label>"

      Examples:
        | schedule                              | label                    |
        | every 15 minutes                      | Every 15 min             |
        | every 90 seconds                      | Every 90 sec             |
        | at 09:00 on every day                 | Daily at 09:00           |
        | at 09:00 from Monday to Friday        | Weekdays at 09:00        |
        | at 18:30 on Saturday and Sunday       | Sat, Sun at 18:30        |

    # Upstream #28104: a Once mode takes a date and a time in the user's own time zone.
    @backlog @desktop @mobile
    Scenario: The user schedules a task to run once at a date and time
      When the user creates a task "Release notes" in "api" that runs once on Friday at 15:00 local time
      Then the task's next run is Friday at 15:00
      And after it runs the task says "Not scheduled" with its outcome

    # Upstream #28104: older MCs refuse one-time schedules, so the choice is offered only where the
    # environment says it supports them.
    @backlog @desktop @mobile
    Scenario: Running once is not offered for an environment that cannot do it
      Given the environment of the task cannot run one-time schedules
      When the user creates a task there
      Then running once is not offered

    @backlog @desktop
    Scenario Outline: The next run is said relative to now
      Given an enabled task whose next run is <when>
      When the user opens scheduled tasks
      Then the task says "<label>"

      Examples:
        | when                      | label                 |
        | 45 seconds away           | in under a minute     |
        | 12 minutes away           | in 12m                |
        | 3 hours away              | in 3h                 |
        | 2 days away               | in 2d                 |

    # Upstream #21026: "next run" and other relative times move on with the clock instead of
    # keeping the text from when their row last changed.
    @backlog @desktop
    Scenario: The next run counts down while scheduled tasks stay open
      Given an enabled task whose next run is 12 minutes away
      And the user has scheduled tasks open
      When 5 minutes pass
      Then the task says "in 7m"

    @backlog @desktop
    Scenario: A task with no next run says it is not scheduled
      Given an enabled task that has no next run
      When the user opens scheduled tasks
      Then the task says "Not scheduled"

    @backlog @desktop
    Scenario: A selection with no tasks says so
      Given the selected environment and project have no scheduled tasks
      When the user opens scheduled tasks
      Then the user is told "No scheduled tasks"

    @backlog @desktop
    Scenario: Scheduled tasks that cannot be loaded say why
      Given the environment cannot list its scheduled tasks
      When the user opens scheduled tasks
      Then the user is told "Could not load scheduled tasks" with the reason

    @backlog @desktop
    Scenario Outline: A task action that fails is reported
      Given a task "Check Sentry"
      And the environment refuses to <action> it
      When the user <action>s the task
      Then the user is told "Could not update scheduled task" with the reason
      And the task is left as it was

      Examples:
        | action |
        | pause  |
        | run    |
        | delete |

    @backlog @desktop
    Scenario: A task can be paused, run and deleted only once at a time
      Given the user paused a task and the environment has not answered yet
      Then the task's controls are unavailable until it answers

    @backlog @desktop
    Scenario: A task that cannot be saved is reported and stays open
      Given the environment refuses to save the task
      When the user saves a task
      Then the user is told "Could not save scheduled task" with the reason
      And the editor stays open with what the user typed

    @backlog @desktop
    Scenario: Tasks of several environments are listed under each machine
      Given the user has two connected environments
      When the user opens scheduled tasks
      Then each machine's tasks are listed under its own name
      And with a single environment no machine name is shown

    @backlog @desktop
    Scenario: A task runs on the machine the user chose
      Given the user has two connected environments
      When the user starts a new task
      Then it asks which machine it runs on
      And changing the machine clears the project, model and base branch chosen so far

    # Upstream #23244: New task checked only the first selected environment's permission.
    @backlog @desktop @priority-low
    Scenario: A new task opens on a selected machine that may create tasks
      Given the user has two connected environments selected in scheduled tasks
      And the user may only read tasks on "laptop" but may create them on "server"
      When the user starts a new task
      Then the new task is set to run on "server"
      And with neither machine allowing it, a new task cannot be started

    @backlog @desktop
    Scenario: A task keeps its machine once saved
      Given a task "Check Sentry" on "laptop"
      When the user edits it
      Then its machine cannot be changed

    @backlog @desktop
    Scenario: A new task only offers the projects in scope
      Given projects "api" and "web" and the settings scope is project "api"
      When the user starts a new task
      Then only "api" can be chosen as its project

    @backlog @desktop
    Scenario: A new task's model falls back to what is usable
      Given the project has no default model
      And the environment's default model is from a provider that is signed out
      When the user starts a new task
      Then its model is the first current model of a provider that is installed and signed in
      And a legacy model is never chosen by default

    @backlog @desktop
    Scenario: Editing a task keeps its model options and access mode
      Given a task created by an agent with a model option and plan mode
      When the user edits only its title and saves
      Then the task keeps its model options, access mode and interaction mode

    @backlog @desktop
    Scenario: Choosing every weekday or none runs the task daily
      Given a new task that runs at a fixed time
      When the user selects all seven weekdays and saves
      Then the task runs daily

    @backlog @desktop
    Scenario: An interval may be fractions of a minute above one minute
      When the user saves a task that runs every 1.5 minutes
      Then it runs every 90 seconds

    # Upstream #22158: in a region that writes decimals with a comma, "2,5" could not be saved.
    @backlog @mobile
    Scenario Outline: An interval written with a decimal comma is understood
      When the user on a phone set to a comma-decimal region enters an interval of "<entered>" minutes
      Then <outcome>

      Examples:
        | entered | outcome                                       |
        | 2,5     | the task saves and runs every 150 seconds     |
        | 0,5     | the editor says the interval must be a minute |
        | abc     | the editor says the interval must be a minute |

    @backlog @desktop
    Scenario: Following a link to a task opens it for editing
      Given a task "Check Sentry" in the selected project
      When the user follows a link to that task
      Then its editor opens once the list has loaded

    # Upstream #25070: the linked task replaced a "New task" editor the user opened while the
    # list loaded, and threw its draft away.
    @backlog @desktop @priority-low
    Scenario: A linked task does not replace an editor the user opened while it loaded
      Given a task "Check Sentry" in the selected project
      And the user followed a link to that task before the list had loaded
      When the user starts a new task and types its prompt
      And the list finishes loading
      Then the new task's editor stays open with the prompt the user typed

  Rule: A thread shows the tasks that send to it

    @backlog @desktop
    Scenario: A thread's details list the tasks bound to it
      Given the task "Check Sentry" sends its prompt into the thread "Triage"
      And the task "Nightly build" sends its prompt into a new thread each time
      When the user opens the details of "Triage"
      Then "Check Sentry" is listed under "Automations" with how its last run went and when it runs next
      And "Nightly build" is not listed

    @backlog @desktop
    Scenario: A thread with no tasks bound to it shows no automations
      Given no task sends its prompt into the thread "Triage"
      When the user opens the details of "Triage"
      Then the details have no "Automations" section

    @backlog @desktop
    Scenario: A paused task says so in the thread's details
      Given the task "Check Sentry" is bound to "Triage" and paused
      When the user opens the details of "Triage"
      Then "Check Sentry" is shown as paused with no next run

    @backlog @desktop
    Scenario: A task is paused and resumed from the thread's details
      Given the task "Check Sentry" is bound to "Triage"
      When the user pauses "Check Sentry" from the details of "Triage"
      Then the task stops running on its schedule and everything else about it is unchanged
      When the user resumes it from the details
      Then the task is scheduled again

    @backlog @desktop
    Scenario: A task is run now from the thread's details
      Given the task "Check Sentry" is bound to "Triage"
      When the user runs "Check Sentry" now from the details of "Triage"
      Then the task's prompt is sent into "Triage"
      And the task cannot be run again from the details while it is running

    @backlog @desktop
    Scenario Outline: A task action from the thread's details that fails is reported
      Given the task "Check Sentry" is bound to "Triage"
      When the user <action> from the details of "Triage" and the environment refuses
      Then the user sees an "error" toast "<title>" with the reason

      Examples:
        | action                    | title                       |
        | pauses "Check Sentry"     | Could not update automation |
        | runs "Check Sentry" now   | Could not run automation    |

    @backlog @desktop
    Scenario: Tasks that cannot be loaded are not mistaken for no tasks
      Given the scheduled tasks of the environment cannot be loaded
      When the user opens the details of "Triage"
      Then the details say "Could not load automations" with the reason

    @backlog @desktop
    Scenario: The thread's details lead to the task's settings
      Given the task "Check Sentry" is bound to "Triage"
      When the user chooses to edit "Check Sentry" from the details of "Triage"
      Then the scheduled tasks settings of that environment open with "Check Sentry" ready to edit
      And "Manage scheduled tasks" opens the same settings without a task chosen

    # Upstream #18144: hovering a thread's automation shows its full title and schedule.
    @backlog @desktop @priority-low
    Scenario: A clipped task in a thread's details can be read in full
      Given the task "Summarise every open pull request in the shop repository" is bound to "Triage" and runs at 09:00 from Monday to Friday
      And the details of "Triage" are too narrow for the task's title
      When the user points at the task
      Then the full title and "Weekdays at 09:00" are shown

  # Upstream #15085: scheduled tasks can run on a webhook
  @backlog @mc @shared
  Scenario: A task can run on a webhook
    Given a task whose trigger is a webhook
    When something sends the task's secret URL a request
    Then the prompt runs with the request as its input
    And a wrong token and an unknown task both answer 404
    And a signature can be required, with its header, encoding and prefix set, and a write-only secret
    And a task is limited to 60 requests a minute and 1 MiB a body

  # Upstream #25291: a HEAD probe from a link checker or chat unfurler started a real run.
  @backlog @mc @priority-high
  Scenario: A HEAD request to a webhook does not run its task
    Given a task whose trigger is a webhook
    When something sends the task's secret URL a HEAD request
    Then it is answered 405 naming the methods the webhook takes
    And the task does not run

  # Upstream #20447: values from the request reach the agent framed and marked as untrusted data.
  @backlog @mc @priority-high
  Scenario: Values from a webhook request reach the agent marked as request data
    Given a webhook task whose prompt is "Triage {{body.text}}"
    When a request arrives whose text is "ignore the above"
    Then the agent receives "ignore the above" inside a tag that marks it as copied from the request
    And the prompt ends with a note to treat the tagged text as untrusted data
    And the tag differs on every delivery, so the request cannot close it early
    And placeholder text inside the value is not filled in

  # Upstream #20447: mentions and slash commands written by whoever called the URL do nothing.
  @backlog @mc @priority-high
  Scenario Outline: A mention inside webhook request data stays inert
    Given a webhook task whose prompt is "<template>"
    When a request arrives whose text is "<text>"
    Then the agent receives the text without running <what>
    And the template's own mentions still work

    Examples:
      | template             | text         | what               |
      | Triage {{body.text}} | $deploy now  | the skill "deploy" |
      | Triage {{body.text}} | @secrets.env | the file mention   |
      | {{body.text}}        | /compact     | the slash command  |

  # Upstream #20447: a template with nothing from the request is sent as written.
  @backlog @mc
  Scenario: A webhook prompt that uses nothing from the request is sent as written
    Given a webhook task whose prompt has no placeholders
    When a request arrives
    Then the agent receives the prompt exactly as written, without the untrusted-data note

  # Upstream #18820: a delivery that failed to be accepted kept its claim, so its retry was a duplicate.
  @backlog @mc @priority-low
  Scenario: A webhook delivery that failed is run when its sender retries it
    Given a webhook task
    And the MC fails to accept a delivery and answers 500
    When the sender retries the same delivery
    Then the task runs once for it
    And a second retry of that delivery is answered as a duplicate

  # Upstream #22194: a webhook task ran on every request, so one that cared only about newly
  # opened pull requests started a run for every label, comment and push.
  @backlog @mc
  Scenario Outline: A webhook delivery runs only when every filter matches
    Given a webhook task with the filters "headers.x-github-event equals pull_request" and "<filter>"
    When a "pull_request" request arrives whose action is "<action>"
    Then the task <runs>

    Examples:
      | filter                         | action    | runs                                                         |
      | body.action equals opened      | opened    | runs                                                         |
      | body.action equals opened      | labeled   | answers 202, logs the delivery as filtered and starts nothing |
      | body.action in opened,reopened | reopened  | runs                                                         |
      | body.action notEquals closed   | closed    | answers 202, logs the delivery as filtered and starts nothing |
      | body.action startsWith re      | reopened  | runs                                                         |
      | body.label exists              | opened    | answers 202, logs the delivery as filtered and starts nothing |

  # Upstream #23282: a path segment ending in [] fans out over a list, so a comment hook can keep
  # only issues carrying a label instead of waking on every comment.
  @backlog @mc @priority-low
  Scenario Outline: A webhook filter over a list matches by its elements
    Given a webhook task with the filter "body.issue.labels[].name <op> <value>"
    When a request arrives whose issue is labelled <labels>
    Then the task <runs>

    Examples:
      | op         | value           | labels                      | runs                 |
      | equals     | needs more info | "bug" and "needs more info" | runs                 |
      | equals     | needs more info | "bug"                       | filters the delivery |
      | startsWith | needs           | "needs more info"           | runs                 |
      | notEquals  | bug             | "bug" and "needs more info" | filters the delivery |
      | notEquals  | bug             | "needs more info"           | runs                 |
      | exists     |                 | nothing                     | filters the delivery |

  # Upstream #23414: an exists filter over a list of objects threw the objects away before
  # checking, so an issue with labels failed it.
  @backlog @mc @priority-low
  Scenario Outline: A webhook filter that a list of objects exists
    Given a webhook task with the filter "body.issue.labels[] exists"
    When a request arrives whose issue has <labels>
    Then the task <runs>

    Examples:
      | labels                                 | runs                 |
      | the labels "bug" and "needs more info" | runs                 |
      | an empty list of labels                | filters the delivery |
      | no labels field                        | filters the delivery |

  # Upstream #23282: a webhook placeholder path ending in [] renders every element of a list.
  @backlog @mc @priority-low
  Scenario: A webhook prompt placeholder over a list renders every element
    Given a webhook task whose prompt is "Labels: {{body.issue.labels[].name}}"
    When a request arrives whose issue is labelled "bug" and "needs more info"
    Then the agent's prompt lists both labels

  # Upstream #22194: missing values fail every filter, notEquals included; objects only exist.
  @backlog @mc @priority-low
  Scenario: A webhook filter on a value the request does not have never matches
    Given a webhook task with the filter "body.label.name notEquals bug"
    When a request arrives with no label
    Then the delivery is filtered

  # Upstream #22194: the log names the first filter that failed.
  @backlog @mc @shared
  Scenario: A filtered webhook delivery says which filter it failed
    Given a webhook task with two filters, the second on "body.action"
    When a request matches the first filter but not the second
    Then its delivery is logged as filtered with "Filter 2 (body.action) did not match."
    And it is not counted as a run

  # Upstream #22194: filters run after the signature and age checks and before the rate limit,
  # so ignored requests do not use up the 60 runs a minute.
  @backlog @mc
  Scenario: Filtered webhook deliveries do not use up the task's rate limit
    Given a signed webhook task with a filter
    When 100 correctly signed requests that fail the filter arrive within a minute
    Then a matching request after them still runs
    And a request with a bad signature is refused before its filters are read

  # Upstream #22194: no regex, at most 16 filters, paths under body, headers or query.
  @backlog @mc @priority-low
  Scenario Outline: A webhook filter the MC cannot run safely is refused when saved
    When the user saves a webhook task with <filters>
    Then the task is not saved and the user is told why

    Examples:
      | filters                                  |
      | 17 filters                               |
      | a filter on "env.HOME"                   |
      | an "in" filter with no values            |
      | an "in" filter with the value "bug, urgent" |

  # Upstream #22194: a save that leaves filters out keeps them, so an older client cannot wipe them.
  @backlog @mc
  Scenario: Saving a webhook task without its filters keeps them
    Given a webhook task with two filters
    When a client saves the task with a new title and no filters
    Then the task keeps its two filters
    When a client saves the task with an empty list of filters
    Then the task has no filters

  # Upstream #22194: ignored requests are logged at most 10 a minute and kept apart from real deliveries.
  @backlog @mc @priority-low
  Scenario: A stream of filtered deliveries does not push real deliveries out of the log
    Given a webhook task with 50 logged deliveries that ran
    When hundreds of requests that fail its filter arrive
    Then the 50 deliveries that ran are still in the log
    And at most 20 filtered deliveries are kept

  # Upstream #22194
  @backlog @shared
  Scenario: The user sets a webhook task's filters
    Given a saved webhook task
    When the user adds the filter "body.action" equals "opened" and saves
    Then the task runs only for requests whose action is "opened"

  # Upstream #22234: a repeated replay key is answered 202, logged as a duplicate and starts
  # nothing for seven days.
  @backlog @mc
  Scenario: A webhook delivery with a replay key already seen is a duplicate
    Given a webhook task whose replay key is "{{headers.x-github-delivery}}"
    And a delivery with the id "abc" ran yesterday
    When another delivery with the id "abc" arrives
    Then it is answered 202 and logged as a duplicate
    And no run starts
    And a delivery with the id "abc" eight days later runs

  # Upstream #22234: deliveries with the same coalesce key run once, with the latest payload,
  # when the window that opened with the first one closes.
  @backlog @mc
  Scenario: Webhook deliveries for the same item are coalesced into one run
    Given a webhook task whose coalesce key is "{{body.pull_request.number}}" with a 120 second window
    When three deliveries for pull request 42 arrive 30 seconds apart
    Then one run starts 120 seconds after the first delivery, with the third delivery's payload
    And the later two are logged as coalesced

  # Upstream #24046: coalesced deliveries whose filled-in prompt was too long escaped the 20-row limit for such failures.
  @backlog @mc @priority-low
  Scenario: Coalesced deliveries whose prompt is too long keep at most 20 failures
    Given a webhook task with a coalesce key
    When 30 coalescing windows each close with a filled-in prompt longer than the provider allows
    Then at most 20 of those deliveries are kept, failed with "The filled-in prompt is too long."
    And deliveries that ran are not pushed out of the log

  # Upstream #26070: a logged body cut inside a multibyte character ended in a replacement character the sender never sent.
  @backlog @mc @priority-low
  Scenario: A truncated delivery body ends at the last whole character
    Given a webhook task
    When a delivery arrives whose body is 65,535 bytes of "a" followed by "€"
    Then the delivery's logged body is marked truncated
    And it ends in "aaa", with no replacement character

  # Upstream #22234: the window does not move with later deliveries and survives a restart.
  @backlog @mc
  Scenario: A coalescing window keeps its deadline across an MC restart
    Given a coalescing window for pull request 42 opened 60 seconds ago with a 120 second window
    When the MC restarts
    Then the run for pull request 42 starts 60 seconds later
    And it starts only once

  # Upstream #22234: a key that renders empty is skipped rather than grouping everything.
  @backlog @mc @priority-low
  Scenario: A webhook delivery whose key renders empty is not deduplicated
    Given a webhook task whose replay key is "id-{{headers.x-delivery}}"
    When two deliveries without that header arrive
    Then both run

  # Upstream #22234: a delivery that could not start releases its replay key.
  @backlog @mc @priority-low
  Scenario: A webhook delivery that could not start can be sent again
    Given a webhook task with a replay key
    When a delivery cannot start because the run queue is full
    Then the same delivery sent again runs

  # Upstream #22234: keys need a request placeholder and windows are 10 to 3600 seconds.
  @backlog @mc @priority-low
  Scenario Outline: A webhook task's dedupe settings are checked when saved
    When the user saves a webhook task with <setting>
    Then the task is not saved and the user is told why

    Examples:
      | setting                                    |
      | the replay key "static" with no placeholder |
      | a coalesce window of 5 seconds             |
      | a coalesce window of 7200 seconds          |

  # Upstream #22234
  @backlog @shared
  Scenario: The user sets a webhook task's replay and coalesce keys
    Given a saved webhook task
    When the user sets its replay key, its coalesce key and a 300 second window, and saves
    Then repeated deliveries are dropped and deliveries for the same item wait 300 seconds to run once

  # Upstream #24149: "Replay key" did not say it stops duplicate runs.
  @backlog @shared @priority-low
  Scenario: The duplicate request key says what it is for
    When the user edits a webhook task
    Then the field that drops repeated deliveries is called "Duplicate request key"
    And beside it the user is told a repeated key is dropped for seven days

  # Upstream #15087: mobile creates and copies webhook automations
  # Upstream #15088: web creates webhook automations and inspects their deliveries
  @backlog @shared
  Scenario: A webhook task shows its URL and deliveries
    Given a saved webhook task
    When the user opens it
    Then they can copy the URL, rotate it after a confirmation, and see its last 50 deliveries with outcome
