# Sources:
#   https://chatgpt.com/features/space/ (scheduled pages)
#   spaces-feature-bdd-tests branch, features/space/self-updating-pages-and-schedules.feature
#     and apps/desktop-qt/examples/space/AutomationCard.qml (the prototype; read for ideas only)
#   packages/contracts/src/space.ts (space.page.schedule.set, space.page.schedule.setEnabled,
#     space.page.schedule.runNow, space.page.schedule.remove)
#   apps/server-ex/lib/hal_c2/space/schedule.ex
#   apps/server-ex/lib/hal_c2/scheduled_tasks.ex
#   apps/server-ex/lib/hal_c2/space/sites.ex (a run's Markdown on a published page)
#   apps/server-ex/lib/hal_c2/space/decks.ex (a run's Markdown in a deck made from the page)

Feature: Pages that update themselves
  A page can carry an instruction and a cadence. Each run writes its result into one
  generated part of the page and nowhere else, and the page says when it was last
  written and when it next runs. What the user wrote by hand is never touched.

  Background:
    Given a connected environment
    And the Space "Research" with the page "Status"

  @mc @desktop @mobile @tui
  Rule: The user gives a page its instruction and cadence

    Scenario: The user has a page update itself every few hours
      When the user has "Status" update itself with "Summarise yesterday's threads" every 2 hours
      Then "Status" shows the instruction "Summarise yesterday's threads"
      And "Status" shows it updates every 2 hours
      And "Status" shows when it next runs
      And "Status" has not been written yet

    Scenario: The user has a page update itself at a time of day
      When the user has "Status" update itself with "Summarise yesterday's threads" every day at "07:30"
      Then "Status" shows it updates every day at "07:30"
      And "Status" shows when it next runs

    Scenario: The user changes the instruction and the cadence
      Given "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      When the user has "Status" update itself with "List open questions" every day at "09:00"
      Then "Status" shows the instruction "List open questions"
      And "Status" shows it updates every day at "09:00"

    Scenario: The user pauses a page's updates
      Given "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      When the user pauses the updates of "Status"
      Then "Status" shows its updates are paused
      And "Status" shows no next run

    Scenario: The user resumes a page's updates
      Given "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      And the updates of "Status" are paused
      When the user resumes the updates of "Status"
      Then "Status" shows its updates are not paused
      And "Status" shows when it next runs

    Scenario: The user runs a page's update now
      Given text generation writes "Three threads moved forward"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      When the user runs the update of "Status" now
      Then the generated part of "Status" reads "Three threads moved forward"
      And "Status" shows when it was last written
      And "Status" shows when it next runs

    Scenario: A failed run leaves the page as it was and says so
      Given text generation writes "Three threads moved forward"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      And the update of "Status" has run
      And text generation fails
      When the user runs the update of "Status" now
      Then the generated part of "Status" reads "Three threads moved forward"
      And "Status" shows its last run failed with "the model is overloaded"
      And "Status" shows when it was last written

    Scenario: The user removes the update and keeps what it wrote
      Given text generation writes "Three threads moved forward"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      And the update of "Status" has run
      When the user removes the update of "Status"
      Then "Status" shows no instruction
      And "Status" has no generated part
      And the blocks of "Status" read "Three threads moved forward"
      When the user changes the block "Three threads moved forward" to "Edited by hand"
      Then the blocks of "Status" read "Edited by hand"

    Scenario: The generated part cannot be edited by hand
      Given text generation writes "Three threads moved forward"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      And the update of "Status" has run
      When the user tries to edit the generated part of "Status"
      Then the generated part of "Status" reads "Three threads moved forward"

  @mc
  Rule: What the MC accepts

    Scenario: A page's update needs an instruction
      When the user has "Status" update itself with "" every 2 hours
      Then the page request is refused
      And "Status" shows no instruction

    Scenario: A page's update needs a cadence the scheduler can keep
      When the user has "Status" update itself with "Summarise yesterday's threads" every 0 hours
      Then the page request is refused
      And "Status" shows no instruction

    Scenario: A page's update cannot be run, paused or removed before it is set
      When the user runs the update of "Status" now
      Then the page request is refused
      When the user pauses the updates of "Status"
      Then the page request is refused
      When the user removes the update of "Status"
      Then the page request is refused

    Scenario: A generated part cannot be added by hand
      When the user adds a generated block "Forged" to "Status"
      Then the page request is refused

    Scenario: A page's updates do not appear among the scheduled tasks
      Given "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      When the user lists the scheduled tasks
      Then there are no scheduled tasks

    Scenario: A client watching the Space sees a run land
      Given text generation writes "Three threads moved forward"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      And a second client watching the Space "Research"
      When the user runs the update of "Status" now
      Then the second client sees the generated part "Three threads moved forward"

  @mc
  Rule: Runs write the generated part and nothing else

    Background:
      Given text generation writes "Three threads moved forward"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours

    Scenario: The update runs when it is due
      When the time for the next run of "Status" comes
      Then the generated part of "Status" reads "Three threads moved forward"
      And "Status" shows when it was last written
      And "Status" shows when it next runs

    Scenario: A paused page does not run when it would have been due
      Given the time for the next run of "Status" is noted
      And the updates of "Status" are paused
      When the noted time comes
      Then "Status" has not been written yet

    Scenario: What the user wrote by hand is never touched
      Given "Status" has the blocks "My notes, My plan"
      When the time for the next run of "Status" comes
      Then the blocks of "Status" read "My notes, My plan, Three threads moved forward"
      And only the generated part of "Status" was written by the update

    Scenario: A second run replaces the generated part rather than adding another
      Given the update of "Status" has run
      And text generation writes "Five threads moved forward"
      When the time for the next run of "Status" comes
      Then the blocks of "Status" read "Five threads moved forward"

    Scenario: The generated part stays where the user moved it
      Given "Status" has the blocks "My notes"
      And the update of "Status" has run
      And the generated part of "Status" is moved to the top
      And text generation writes "Five threads moved forward"
      When the user runs the update of "Status" now
      Then the blocks of "Status" read "Five threads moved forward, My notes"

    Scenario: A generated part the user deleted comes back on the next run
      Given the update of "Status" has run
      And the user has deleted the generated part of "Status"
      When the user runs the update of "Status" now
      Then the generated part of "Status" reads "Three threads moved forward"

    Scenario: Comments on the generated part outlive a run
      Given the update of "Status" has run
      And the comment "Which week?" on the generated part of "Status"
      And text generation writes "Five threads moved forward"
      When the user runs the update of "Status" now
      Then the generated part of "Status" has the open comment "Which week?"

    Scenario: Without a provider the run fails and the page is unchanged
      Given "Status" has the blocks "My notes"
      And no text generation provider is available
      When the user runs the update of "Status" now
      Then the blocks of "Status" read "My notes"
      And "Status" shows its last run failed
      And "Status" has not been written yet

    Scenario: A run that comes back empty writes nothing
      Given the update of "Status" has run
      And text generation writes ""
      When the user runs the update of "Status" now
      Then the generated part of "Status" reads "Three threads moved forward"
      And "Status" shows its last run failed

    Scenario: A paused page can still be run by hand
      Given the updates of "Status" are paused
      When the user runs the update of "Status" now
      Then the generated part of "Status" reads "Three threads moved forward"
      And "Status" shows no next run

    Scenario: A run sees the instruction, the page and the recent threads as data
      Given a project with the thread "Work" that talked about a release plan
      And "Status" has the blocks "My notes"
      When the user runs the update of "Status" now
      Then the writer was told "Summarise yesterday's threads"
      And the writer was shown "My notes" as reference data
      And the writer was shown the thread "Work"

    Scenario: A long thread reaches the writer by its latest part
      Given a project with a long thread "Work" that ends with "Ship on Friday"
      When the user runs the update of "Status" now
      Then the writer was shown the end of the thread, "Ship on Friday"

    Scenario: Removing the update keeps a title the run wrote
      Given text generation writes "# Weekly status"
      And the update of "Status" has run
      When the user removes the update of "Status"
      Then the blocks of "Status" read "Weekly status"

    Scenario: Removing the update keeps an image the run wrote first
      Given the image "chart.png" in "Research"
      And text generation writes the image "chart.png" of the Space
      And the update of "Status" has run
      When the user removes the update of "Status"
      Then the first block of "Status" shows the image "chart.png"

    Scenario: A site shows what a run wrote as ordinary blocks
      Given text generation writes "## Weekly status"
      And the update of "Status" has run
      And the page "Status" is published as a site
      When a browser with no pairing opens the site link of the page "Status"
      Then the document has the heading "Weekly status"

    Scenario: A deck from a page reads what a run wrote as ordinary blocks
      Given text generation writes a heading "Weekly status" over the checked item "Shipped"
      And the update of "Status" has run
      When the user makes a deck from the page "Status"
      Then the deck "Status" has the slides:
        | title         | body          |
        | Weekly status | - [x] Shipped |

    Scenario: Removing the update does not put a site behind for an image with no caption
      Given the image "chart.png" in "Research"
      And text generation writes the image "chart.png" of the Space with no caption
      And the update of "Status" has run
      And the page "Status" is published as a site
      When the user removes the update of "Status"
      Then the page "Status" shows its site is up to date

    Scenario: Removing a page's update stops its runs
      Given the time for the next run of "Status" is noted
      And the user has removed the update of "Status"
      When the noted time comes
      Then "Status" has not been written yet

    Scenario: The instruction, the cadence and the last run survive a restart
      Given the update of "Status" has run
      When the MC restarts
      Then "Status" shows the instruction "Summarise yesterday's threads"
      And "Status" shows it updates every 2 hours
      And "Status" shows when it was last written
      And "Status" shows when it next runs

  @mc
  Rule: The trash stops a page's runs

    Background:
      Given text generation writes "Three threads moved forward"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      And the time for the next run of "Status" is noted

    Scenario: A trashed page does not run
      Given the page "Status" is in the trash
      When the noted time comes
      Then "Status" has not been written yet
      And "Status" shows no next run

    Scenario: Trashing a parent page stops its subpages' runs
      Given the page "Roadmap"
      And the page "Status" is moved into "Roadmap"
      And the page "Roadmap" is in the trash
      When the noted time comes
      Then "Status" has not been written yet

    Scenario: A restored page does not run what it missed
      Given the page "Status" is in the trash
      And the noted time has passed
      When the user restores the page "Status"
      Then "Status" has not been written yet
      And "Status" shows when it next runs, after the noted time

    Scenario: A trashed page's update cannot be changed or run
      Given the page "Status" is in the trash
      When the user runs the update of "Status" now
      Then the page request is refused
      When the user resumes the updates of "Status"
      Then the page request is refused

    Scenario: A page trashed while the MC was stopping does not run after the restart
      Given the page "Status" is trashed behind the scheduler's back
      When the MC restarts
      And the noted time comes
      Then "Status" has not been written yet

    Scenario: A run under way when the page is trashed writes nothing
      Given a run of "Status" is under way
      When the user moves the page "Status" to the trash
      And the run of "Status" comes back
      Then "Status" has not been written yet
      And "Status" shows its last run failed with "is in the trash"

    Scenario: Deleting a page for good removes its update
      Given the page "Status" is in the trash
      When the user deletes the page "Status" for good
      Then no update of "Status" remains on the MC

  # Scheduled tasks live in each MC's own file and are not replicated, and a Space lives
  # on one MC, so a page's update exists on one member and cannot fire twice today. The
  # scheduler has no lease to lean on once a Space is shared.
  @mc @backlog @blocked @priority-low
  Rule: Clustered MCs

    # Waits for "A Space is shared across the cluster" in space/beyond-pages.feature.
    Scenario: A page in a Space shared across the cluster runs once
      Given a cluster of two MCs sharing the Space "Research"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      When the time for the next run of "Status" comes
      Then one MC ran the update and the other did not

    # Waits for "A Space is shared across the cluster" in space/beyond-pages.feature.
    Scenario: A shared page keeps updating when the MC that ran it is lost
      Given a cluster of two MCs sharing the Space "Research"
      And "Status" updates itself with "Summarise yesterday's threads" every 2 hours
      When the MC running the update of "Status" is lost
      Then the other MC runs the update when it is next due
