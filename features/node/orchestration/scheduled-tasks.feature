# Sources:
#   apps/server-ex/lib/hal_c2/scheduled_tasks.ex (scheduledTasks.list, scheduledTasks.upsert,
#     scheduledTasks.delete, scheduledTasks.setEnabled, scheduledTasks.runNow, watchers)
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (list_scheduled_tasks, schedule_task,
#     update_scheduled_task, delete_scheduled_task, run_scheduled_task_now)
#   apps/server/src/scheduledTasks/ScheduledTaskService.ts, Schedule.ts and their tests
#   packages/contracts/src/scheduledTask.ts, rpc.ts (scheduledTasks.subscribe)
#   V2 commands issued: message.dispatch (queue_after_active, scheduledTaskId), and a
#     thread launch with an initial message
Feature: Scheduled tasks
  A scheduled task sends a prompt on a schedule, either into a thread it is bound
  to or as the first message of a new thread each time.

  Background:
    Given a node with a project "demo"
    And the local time zone of the node is used for times of day

  @node
  Scenario: Creating a task with defaults
    When a client saves a new task "Nightly review" every 1 hour in "demo"
    Then the task is enabled, has never run, has run 0 times and is due in 1 hour
    And it was created by the user from the web

  @node
  Scenario Outline: Only valid schedules are accepted
    When a client saves a task with schedule <schedule>
    Then it fails with "The schedule is not valid."

    Examples:
      | schedule                         |
      | every 30 seconds                 |
      | every "ten" milliseconds         |
      | at time of day "24:00"           |
      | at time of day "9:5"             |
      | of an unknown type               |

  @node
  Scenario Outline: A fixed time runs at the next matching local time
    Given it is <now> local time on a <today>
    When a client saves a task at "<time>" on <days>
    Then the task is next due <next>

    Examples:
      | now   | today     | time  | days             | next                   |
      | 08:00 | Monday    | 09:00 | every day        | Monday at 09:00        |
      | 10:00 | Monday    | 09:00 | every day        | Tuesday at 09:00       |
      | 10:00 | Friday    | 9:00  | Mondays only     | next Monday at 09:00   |

  @node
  Scenario: Tasks are listed oldest first
    Given tasks "a" then "b" were created
    When a client lists the tasks
    Then it receives "a" then "b"

  @node
  Scenario: Editing a task that was deleted meanwhile fails
    Given a client opened task "a" for editing and it was then deleted
    When the client saves its edit as an edit of an existing task
    Then it fails with "Schedule task not found."
    And no task is recreated

  @node
  Scenario: Keeping the schedule keeps the pending run
    Given task "a" is due at 09:00
    When a client renames task "a" without changing its schedule
    Then task "a" is still due at 09:00

  @node
  Scenario: Changing the schedule aims the next run afresh
    Given task "a" runs every hour and is due at 09:00
    When a client changes it to every 2 hours at 08:30
    Then task "a" is due at 10:30

  @node
  Scenario: Disabling a task clears its next run and enabling it aims a new one
    When a client disables task "a"
    Then task "a" has no next run
    When a client enables task "a"
    Then task "a" has a next run

  @node
  Scenario: Deleting a task
    When a client deletes task "a"
    Then task "a" is no longer listed

  @node
  Scenario Outline: Unknown tasks are refused
    When a client <action> task "missing"
    Then it fails with "Schedule task not found."

    Examples:
      | action  |
      | deletes |
      | enables |
      | runs now |

  @node
  Scenario: A task bound to a thread queues its prompt there
    Given task "a" is bound to thread "t1"
    When task "a" becomes due
    Then its prompt is sent to "t1" to start after any active turn
    And the message records that it came from task "a"

  @node
  Scenario: An unbound task starts a new thread each time
    Given task "a" is not bound to a thread and uses a new worktree
    When task "a" becomes due
    Then a new thread titled like the task is launched in "demo" with the task's model and modes
    And its first message is the task's prompt, recorded as coming from task "a"

  @node
  Scenario: A finished run records its outcome
    When task "a" runs and the prompt is delivered
    Then task "a" last ran successfully, its run count grows by 1 and its next run is aimed

  @node
  Scenario: A failed run records the error
    Given task "a" is bound to a thread that no longer exists
    When task "a" runs
    Then task "a" last failed with the reason and its run count grows by 1

  @node
  Scenario: Running now answers with the finished task
    When a client runs task "a" now
    Then the answer is task "a" after the run, with its outcome

  @node
  Scenario: A task cannot run twice at once
    Given task "a" is running
    When a client runs task "a" now
    Then it fails with "Schedule task is already running."

  @node
  Scenario: A due task that is still running is not started again
    Given task "a" is running and becomes due again
    Then no second run starts

  @node
  Scenario: A task deleted during its run ends quietly
    Given a client ran task "a" now and deleted it during the run
    When the run ends
    Then the client is told "Schedule task not found."

  @node
  Scenario: A fixed-time run missed by more than 10 minutes is skipped
    Given task "a" was due at 09:00 and the node was asleep until 09:30
    When the node checks its schedule
    Then task "a" does not run and is next due at its following slot

  @node
  Scenario: An interval run missed while asleep runs when the node wakes
    Given task "a" runs every hour and was due while the node was asleep
    When the node checks its schedule
    Then task "a" runs

  @node
  Scenario: The schedule is checked at least once a minute
    Given the next task is due in 3 hours
    Then the node checks its schedule again within a minute

  @node
  Scenario: A run cut short by a restart is recorded as failed
    Given task "a" was running when the node stopped
    When the node starts
    Then task "a" last failed with "The server stopped during this run."

  @node
  Scenario: Tasks survive a restart
    Given task "a" exists
    When the node restarts
    Then task "a" is listed with its schedule and history

  @node
  Scenario: Watchers see every change
    Given a client watches the scheduled tasks
    When task "a" is saved, runs or is deleted
    Then the client receives the updated task list each time

  @node
  Scenario: An agent schedules a task bound to its own thread
    Given thread "caller" in "demo" has a turn running
    When the agent of "caller" schedules "Check CI" every hour
    Then the task is bound to "caller", uses its model and modes, and was created by an agent through MCP

  @node
  Scenario: An agent's task title defaults to the start of its prompt
    When an agent schedules a task without a title
    Then the title is the first 60 characters of the prompt

  @node
  Scenario: Unbinding a task from the thread makes it launch fresh worktrees
    Given thread "caller" has a task bound to it
    When the agent of "caller" updates the task to not be bound to its thread
    Then each run launches a new worktree from origin's main

  @node
  Scenario: Agents see and change only their project's tasks
    Given a task belongs to another project
    When the agent of "caller" lists, updates, deletes or runs it
    Then it is not listed and every change is refused

  @node
  Scenario: A time that only differs in padding keeps the pending run
    Given task "a" at "9:00" is due at 09:00
    When a client saves it with time "09:00"
    Then task "a" is still due at 09:00

  @node
  Scenario: A stored legacy task under a minute runs every minute
    Given a stored task from an older version runs every 30 seconds
    When the node loads it
    Then it runs every minute rather than being refused
