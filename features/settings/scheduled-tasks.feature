# Sources:
#   apps/server-ex/lib/hal_c2/scheduled_tasks.ex (store, timer, missed runs, run status)
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (list_scheduled_tasks, schedule_task, update_scheduled_task, delete_scheduled_task, run_scheduled_task_now)
#   apps/server-ex/lib/hal_c2/web/socket.ex (scheduledTasks subscription)
#   apps/server-ex/test/mc_parity_test.exs (scheduledTasks.* aligned)
#   packages/contracts/src/scheduledTask.ts (interval and fixed_time schedules, workspace strategies)
#   packages/contracts/src/rpc.ts (scheduledTasks.list, scheduledTasks.upsert, scheduledTasks.delete, scheduledTasks.setEnabled, scheduledTasks.runNow, scheduledTasks.subscribe)
#   apps/web/src/components/settings/ScheduledTasksSettings.tsx
#   apps/web/src/components/settings/scheduledTasksSettings.logic.ts
#   apps/web/src/components/WorktreeBaseBranchPicker.tsx
#   apps/desktop-qt/src/native/ScheduledTasksController.cpp
#   apps/desktop-qt/qml/HalC2/Bricks/ScheduledTaskEditor.qml
#   apps/desktop-qt/qml/HalC2/Bricks/js/scheduledTasks.js
#   apps/tui/src/host/sections/scheduledTasks.ts (the terminal client's list and editor)

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
    Scenario: Pausing a task stops its runs and resuming schedules it again
      Given a task that runs every hour
      When the user pauses the task
      Then the task has no next run
      When the user resumes the task
      Then the task has a next run again

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

    @shared @backlog-mobile
    Scenario: The last weekday of a task cannot be turned off
      Given a new task that runs only on Wednesday
      When the user turns Wednesday off and saves it
      Then the task still runs on Wednesday

    @shared @backlog-mobile
    Scenario: Editing a task with a sub-minute interval says saving raises it
      Given a task saved by an older version that runs every 10 seconds
      When the user edits it
      Then the editor says saving raises the interval to a minute
      And saving it runs every minute

    @shared @backlog-mobile
    Scenario: An open editor says when its task was deleted elsewhere
      Given a task "Check Sentry"
      When the user edits the task and another client deletes it
      Then the editor says the task no longer exists

    @shared @backlog-mobile
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

    @shared @backlog-mobile
    Scenario: A link to a task that is gone says so
      When the user follows a link to a task that was deleted
      Then the user is told the task is unavailable

    @shared @backlog-mobile
    Scenario: Scheduled tasks on a disconnected environment offer to reconnect
      Given the environment "laptop" is disconnected
      When the user opens scheduled tasks for "laptop"
      Then the user is offered to reconnect "laptop"
