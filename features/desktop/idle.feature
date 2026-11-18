# Sources:
#   apps/desktop-ljos/shell/src/schedule.rs (native work at a time, each fire counted by its name)
#   apps/desktop-ljos/shell/src/clock.rs (the wall clock jumping, the machine waking)
#   apps/desktop-ljos/shell/src/controllers/client_activity.rs (the client lease)
#   apps/desktop-ljos/shell/src/controllers/scheduled_tasks.rs
#   apps/desktop-ljos/shell/src/sidebar_model.rs (when a thread's age next reads otherwise)
#   apps/desktop-ljos/shell/src/controllers/toasts.rs (a toast's expiry)

Feature: An idle desktop does no work
  The desktop works when something asks it to: input, a message from the MC, or a moment at which
  something it shows reads otherwise. Nothing polls, so a desktop left alone uses no CPU and the
  machine can sleep.

  Rule: Nothing wakes a desktop left alone

    # Left alone starts once the desktop has done what it was asked: offering to reconnect when no
    # MC answered, writing down what the user opened.
    @backlog @desktop
    Scenario: A desktop with no MC wakes zero times
      Given the desktop is open with no MC to connect to
      And the desktop has done what it was asked
      When an hour passes with no input
      Then nothing woke the desktop
      And nothing is scheduled to wake the desktop

    # The lease tells the MC a desktop is still here; the update check looks for a new version.
    # They are the only work a connected desktop schedules for itself. A thread last active weeks
    # ago reads "3w ago" all hour, so no label of it turns.
    @backlog @desktop
    Scenario: A connected desktop wakes only to renew its lease and check for updates
      Given the desktop is connected to its MC and shows a thread last active 3 weeks ago
      And the desktop has done what it was asked
      When an hour passes with no input and no message
      Then nothing but the client lease and the update check woke the desktop

  Rule: What the desktop calls off never happens

    # A notice that goes by itself schedules its going; dismissing it first calls that off.
    @backlog @desktop
    Scenario: Work the desktop scheduled and then called off never runs
      Given the desktop shows a notice "Copied" that goes by itself in 5 seconds
      When the user dismisses the toast "Copied"
      And 10 seconds pass
      Then the notice's going never ran
      And nothing is scheduled to wake the desktop
