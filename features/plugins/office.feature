# Sources:
#   plugins/office/plugin.json (permissions, settings, the page)
#   plugins/office/mc/office.ex (the MC part: who is in the office, what each does, who talks to whom; the office topic)
#   plugins/office/mc/floor.ex (the office topic's people, reviewers among them, and talks)
#   plugins/code-review/mc/code_review.ex (launch_thread/5: a review thread's plugin mark)
#   plugins/office/ui/OfficePage.qml (the pixel-art office: people, pets, furniture, movers, walking, talking, the review corner, project marks)
#   apps/desktop-qt/qml/HalC2/Bricks/ProjectIcon.qml (the sidebar's project icon a desk mirrors)
#   apps/desktop-qt/src/native/IdentityController.cpp (projectIcons: the icons the page reads)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (threads/1 and watch_threads/1 for plugins)
#   docs/user/office.md
#
# The MC scenarios run from apps/server-ex with
#   mise exec -- mix features plugins/office.feature
# The page is covered by plugins/office/test/tst_OfficePage.qml against a fake MC
# part; desktop tst_Features steps are the follow-up that takes the @backlog-desktop
# tags off. Phones show no plugin pages yet (@backlog-mobile). The terminal client
# draws no pixel art, so the page has no @tui scenarios.

@plugin-office
Feature: Office
  The Office plugin shows a machine's threads as people in a pixel-art office. Each
  thread is a person at a desk, and the workers it delegated to sit near it; some
  workers are cats and dogs. They walk between desks, the whiteboard, the bookshelves
  and the break room, around the furniture and through each other, doing what their
  agents do. When one agent hands work to another or messages it, the two walk up to each
  other and talk. One whose agent asks the user something shows a question mark.

  Background:
    Given an MC running the office plugin

  Rule: The office is the machine's threads, each in the state its agent is in

    @mc
    Scenario: A thread whose agent works is at work, doing what its last tool call did
      Given a thread "Fix the parser" in the project "api"
      When its agent starts a turn and edits a file
      Then the office has "Fix the parser" working, typing
      When its agent runs "mix test"
      Then the office has "Fix the parser" working, testing

    @mc
    Scenario Outline: What a tool call looks like in the office
      Given a thread "Fix the parser" in the project "api"
      When its agent starts a turn and calls <tool>
      Then the office has "Fix the parser" working, <activity>

      Examples:
        | tool              | activity   |
        | "Read"            | reading    |
        | "Grep"            | reading    |
        | "WebSearch"       | browsing   |
        | "TodoWrite"       | planning   |
        | "Bash" to "ls -la" | running   |

    @mc
    Scenario: A thread whose agent asks the user something is asking
      Given a thread "Fix the parser" in the project "api"
      When its agent asks for approval to run a command
      Then the office has "Fix the parser" asking, with the question's kind
      When the user approves it
      Then the office has "Fix the parser" working

    @mc
    Scenario: A thread whose turn ended is idle, and one that failed has failed
      Given a thread "Fix the parser" in the project "api"
      When its agent finishes a turn
      Then the office has "Fix the parser" idle
      When its next turn fails
      Then the office has "Fix the parser" failed

    @mc
    Scenario: A thread holding on to background work is waiting
      Given a thread "Fix the parser" in the project "api"
      When its agent ends its turn waiting on a worker it delegated to
      Then the office has "Fix the parser" waiting

    @mc
    Scenario: A worker a thread delegated to is in the office with its parent
      Given a thread "Lead" in the project "api"
      When its agent delegates "Write the tests" to a worker
      Then the office has the worker "Write the tests" whose parent is "Lead"

    @mc
    Scenario: A thread the code-review plugin started to review a pull request is a reviewer
      Given a review thread "Review #12 Fix login" the code-review plugin started
      Then the office has "Review #12 Fix login" as a reviewer

    @mc
    Scenario: A worker a reviewer delegated to is a reviewer too
      Given a review thread "Review #12 Fix login" the code-review plugin started
      When its agent delegates "Check the tests" to a worker
      Then the office has "Check the tests" as a reviewer

    @mc
    Scenario: A thread titled like a review that no review started is not a reviewer
      Given a thread "Review #12 Fix login" in the project "api"
      Then the office has "Review #12 Fix login", not as a reviewer

    @mc
    Scenario: A thread another plugin started is not a reviewer
      Given a thread "Implement #7" the issue-tracker plugin started to implement an issue
      Then the office has "Implement #7", not as a reviewer

    @mc
    Scenario: Archived, deleted and settled threads have left the office
      Given threads "Kept", "Archived", "Deleted" and "Settled" in the project "api"
      When "Archived" is archived, "Deleted" is deleted and "Settled" is settled
      Then the office has "Kept" and none of the others

    # Settling or archiving a thread leaves its workers' own threads as they are
    # (delegation.feature: a subagent keeps its replies after its parent settles), so
    # the office walks up the lineage itself. A worker asking under a parent the user
    # put away leaves too: putting the parent away puts its work away, and such a
    # question is most often one nobody waits on any more.
    @mc
    Scenario Outline: Workers leave the office with the thread that delegated to them, unless they work
      Given a thread "Lead" with a worker "Tests", a working worker "Build" and an asking worker "Review"
      And the worker "Tests" has a worker "Fixtures"
      When <put away>
      Then the office has "Build" and none of the others

      Examples:
        | put away                 |
        | a client settles "Lead"  |
        | a client archives "Lead" |
        | "Lead" is deleted        |

    @mc
    Scenario Outline: Workers come back with the thread that delegated to them
      Given a thread "Lead" with a worker "Write the tests"
      And <put away>
      And the office does not have "Write the tests"
      When <brought back>
      Then the office has "Lead" and "Write the tests"

      Examples:
        | put away                 | brought back               |
        | a client settles "Lead"  | a client unsettles "Lead"  |
        | a client archives "Lead" | a client unarchives "Lead" |

    @mc
    Scenario: A settled thread whose agent starts working again comes back
      Given a settled thread "Settled" in the project "api"
      When its agent starts a turn
      Then the office has "Settled" working

    @mc
    Scenario: A full office keeps the threads that ask and work
      Given the office plugin seats at most 2 people
      And an idle thread "Idle", a working thread "Busy" and an asking thread "Asks"
      Then the office has "Asks" and "Busy" and not "Idle"

    @mc
    Scenario: A thread idle for longer than the office keeps idle threads has left
      Given the office plugin keeps idle threads for 1 hour
      And a thread "Old" idle for 2 hours and a thread "Recent" idle for a minute
      Then the office has "Recent" and not "Old"

    @mc
    Scenario: A thread idle for longer than the office keeps idle threads has left, even if its row changed since
      Given the office plugin keeps idle threads for 1 hour
      And a thread "Old" idle for 2 hours and a thread "Recent" idle for a minute
      When the agent session of "Old" is stopped for sitting idle, and then a thread "New" is made
      Then the office has "New" and "Recent" and not "Old"

    @mc
    Scenario: A thread that comes to this machine long idle is not in the office
      Given the office plugin keeps idle threads for 1 hour
      When a thread "Moved in" whose last turn ended 2 hours ago comes to this machine, and then a thread "New" is made
      Then the office has "New" and not "Moved in"

    @mc
    Scenario Outline: A long-idle thread brought back is in the office for as long again
      Given the office plugin keeps idle threads for 1 hour
      And a thread "Old" idle for 2 hours that is <put away>
      When the user <brings back> "Old"
      Then the office has "Old" idle

      Examples:
        | put away | brings back |
        | archived | unarchives  |
        | settled  | unsettles   |

    @mc
    Scenario: A renamed project is renamed in the office
      Given a thread "Fix the parser" in the project "api"
      When the project "api" is renamed "billing"
      Then the office has "Fix the parser" in the project "billing"

    @mc
    Scenario: A thread on another machine of the cluster is in that machine's office
      Given a thread "Fix the parser" moved to another machine
      Then the office does not have "Fix the parser"

  Rule: Agents that hand each other work or messages talk

    @mc
    Scenario: Delegating work is a talk from the thread to its worker
      Given a thread "Lead" in the project "api"
      When its agent delegates "Write the tests" to a worker
      Then the office has a "delegate" talk from "Lead" to "Write the tests" saying "Write the tests"

    @mc
    Scenario: A message one thread's agent sends another is a talk
      Given threads "Lead" and "Reviewer" in the project "api"
      When the agent of "Lead" sends "Reviewer" the message "Please look at the diff"
      Then the office has a "message" talk from "Lead" to "Reviewer" saying "Please look at the diff"

    @mc
    Scenario: A worker that ends its turn talks back to its parent with its last message
      Given a thread "Lead" with a worker "Write the tests"
      When the worker ends its turn saying "All 12 tests pass"
      Then the office has a "result" talk from "Write the tests" to "Lead" saying "All 12 tests pass"

    @mc
    Scenario: The office keeps only the newest 40 talks
      Given a thread "Lead" with a worker "Write the tests"
      When its agent sends the worker 50 messages
      Then the office has the newest 40 talks

    @mc
    Scenario: A talk leaves the office ten minutes after it was said
      Given threads "Lead" and "Reviewer" in the project "api"
      When the agent of "Lead" sends "Reviewer" the message "Please look at the diff"
      Then the office has a "message" talk from "Lead" to "Reviewer" saying "Please look at the diff"
      When ten minutes pass with nothing else said or done
      Then the office has no talks

  Rule: The office page draws it

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Every person looks like someone of their own, the same each time
      Given the office has 12 threads
      Then the page draws 12 people with different looks: skin, hair, clothes and accessories
      And they are a mix of women and men
      And a thread drawn again after the page reopens looks as it did

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Some workers are cats and dogs
      Given the office has a thread with 20 workers
      Then some of its workers are drawn as cats and some as dogs
      And every thread that is not a worker is drawn as a person

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Workers sit near the thread that delegated to them
      Given the office has a thread "Lead" with 3 workers
      Then each worker's desk is in the same group of desks as the desk of "Lead"

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: People walk around the furniture and never stop on one spot
      Given the office has 16 working threads
      When the office runs for a while
      Then nobody stands on a desk, a wall or any other furniture
      And no two people stop on the same spot

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A person walks through someone standing in its way
      Given a person's way is crossed by someone standing still
      Then it walks straight through them without stopping
      And the one standing never moves

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Two people walking into each other walk through each other
      Given two people walk into each other on open floor, or swap places
      Then they walk straight through each other and both get where they are going
      And neither steps aside, waits or goes around

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Two people headed for the same spot never both stop there
      Given the office has 16 working threads
      When they all start waiting
      Then each heads for a spot of its own in the break room

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: What a person does follows what its agent does
      Given the office has a thread working, typing
      Then its person sits at its desk using the computer
      When the thread is working, planning
      Then its person walks to a whiteboard and draws on it
      When the thread is working, reading
      Then its person walks to a bookshelf and reads

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Waiting and idle people take a break in the break room
      Given the office has a thread working, typing
      When the thread is waiting
      Then its person walks to the break room and drinks coffee, sits on the couch or chats there
      When the thread is working again
      Then its person walks back to its desk

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Two agents that talk walk up to each other
      Given the office has threads "Lead" and "Reviewer"
      When the office has a "message" talk from "Lead" to "Reviewer" saying "Please look at the diff"
      Then the person of "Lead" walks up next to the person of "Reviewer"
      And they face each other and "Please look at the diff" shows in a speech bubble
      And afterwards "Lead" goes back to what it was doing

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A person spoken to on its way stops only on a spot nobody else has
      Given "Lead" talks to "Reviewer" just as "Reviewer" walks over another person's spot
      Then "Reviewer" walks on past that spot before it stops to listen
      And "Lead" talks from beside it, on a spot of its own

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A person whose agent asks something shows a question mark
      Given the office has a thread "Fix the parser" asking
      Then its person stands at its desk with a question mark over its head
      When the user clicks that person
      Then the thread "Fix the parser" opens

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Hovering a person says who it is and what it does
      Given the office has a thread "Fix the parser" working, testing
      When the user hovers its person
      Then a card names "Fix the parser", its project, its agent and model, and that it is testing

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office keeps its size as people come
      Given the office has 4 threads
      When it has 50 threads
      Then the office is the same size, with room for 48 desks

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office keeps its size as people go
      Given the office has 50 threads
      When it has 2 threads
      Then the office is the same size, with room for 48 desks

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Workers past the 48th desk wait in the break room
      Given the office has 50 threads working, typing
      Then 48 of them have a desk and the other 2 take a break in the break room

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A worker without a desk sits down once a desk is free
      Given the office has 50 threads working, typing, 2 of them without a desk
      And one of the threads with a desk is waiting, and takes a break
      When another thread with a desk leaves
      Then one of the 2 walks from the break room to that desk and sits down
      And the thread with a desk on its break stays on its break

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A worker without a desk waits in the break room whatever it does
      Given the office has 48 threads with a desk
      When it has another thread working, planning
      Then the new person waits in the break room, not at a whiteboard

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: People coming and going do not redraw the office
      Given the office has 4 threads
      When it has 12 threads
      And then it has 2 threads
      Then nothing in the office is drawn again

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The people there when the office opens are already at their desks
      Given the office has 4 threads working, typing
      When the office page opens
      Then each person sits at a desk that is already there

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Movers carry in the desk of a new worker, who walks in and waits for it
      Given the office has 4 threads
      When it has a 5th thread working, typing
      Then the new person walks in through the door
      And a mover walks in carrying a desk, a chair and a computer to the new person's place
      And the new person waits beside the desks until the mover sets them down
      And then sits at the new desk, and the mover leaves

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: People keep their desks as others come and go
      Given the office has a thread "A" with a worker and a thread "B" with 2 workers, sharing a group of desks
      When "A" delegates to another worker
      Then the new worker sits with "A" and everyone else stays at their desk
      When the first worker of "A" leaves
      Then only its desk is carried out and everyone else stays at their desk
      When a team has outgrown its group of desks and gains another worker
      Then the team stays where it is and only the new worker sits at the nearest free desk

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Movers carry out the desks nobody sits at
      Given the office has threads "A" and "B", each with 5 workers
      When "B" and its workers leave the office
      Then movers walk in, pick up their desks, carry them out through the door and leave

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Movers carry several desks in at once among the people
      Given the office has 4 working threads
      When it has 16 working threads
      Then several movers carry desks in at once
      And people and movers walk past each other, never stopping on the same spot

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A desk being carried never covers the person just north of it
      Given a mover carries a desk along open floor
      And someone stands just north of its way
      When the mover walks right past them
      Then the desk it holds in front of it never covers them

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: People and movers get through the door without a jam
      Given the office has 2 threads
      When it has 8 threads
      Then the new people come in one at a time, a step apart
      And nobody stands waiting in the doorway
      And every desk is carried in and every mover leaves

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A talk to someone still outside waits for them to come in
      Given the office has threads "Lead" and "Newcomer", with "Newcomer" still outside the door
      When the office has a "message" talk from "Lead" to "Newcomer"
      Then "Lead" waits until "Newcomer" has come in, however long that takes
      And then walks up to "Newcomer" and says it

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A talk waiting for someone outside lets the speaker's other talks go first
      Given the office has threads "Lead", "Reviewer" and "Newcomer", with "Newcomer" still outside the door
      When the office has a "message" talk from "Lead" to "Newcomer" and then one from "Lead" to "Reviewer"
      Then "Lead" walks up to "Reviewer" and says it while "Newcomer" is still outside
      And the talk to "Newcomer" waits until "Newcomer" has come in

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Talks waiting for people outside never crowd out a talk to someone inside
      Given the office has threads "Lead" and "Reviewer", and three newcomers still outside the door
      When the office has a "message" talk from "Lead" to each newcomer and then one from "Lead" to "Reviewer"
      Then "Lead" walks up to "Reviewer" and says it while the newcomers are still outside

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Newcomers waiting for their desks each wait in a place of their own
      Given the office has no threads
      When it has 16 threads working, typing
      Then each new person waits beside its group of desks, or as near it as there is room, where nobody else waits

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Another machine's office starts with clean whiteboards
      Given the office has a thread working, planning, that has drawn on a whiteboard
      When the user picks another machine
      Then every whiteboard in its office is clean

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office fits its view
      Given the office page is open
      Then the whole office shows and fills the view's width or its height, unless the largest zoom comes first
      When the user zooms in and then picks Fit
      Then the whole office shows again

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Zooming goes in small steps up to a largest size
      Given the office page is open
      When the user zooms in
      Then the office grows by about a quarter, with every art pixel the same size
      When the user zooms in until it can grow no more
      Then zooming in is off

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office holds still while it is not shown
      Given the office page is open
      When the user switches to the Threads tab
      Then the office stops animating until its page is shown again

  Rule: Reviewers sit in a corner of their own

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Reviewers sit in the review corner
      Given the office has 4 threads and a reviewer
      Then the reviewer sits in the review corner, under its sign and by its whiteboard
      And the 4 threads sit on the floor

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer's workers sit with it in the review corner
      Given the office has a reviewer and 2 workers it delegated to
      Then the workers sit in the review corner with it

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Movers carry a new reviewer's desk into the review corner
      Given the office has 2 threads
      When it has a reviewer too
      Then a mover carries a desk into the review corner and the reviewer sits down at it

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Reviewers past the corner's desks sit at the nearest desks on the floor
      Given the office has 10 reviewers
      Then 8 of them sit in the review corner and the other 2 at the pod next to it
      When a reviewer in the corner leaves
      Then the others keep their desks

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer team out of a full corner seats its newcomers by its own desks
      Given the review corner is full and a reviewer with a worker sits at the pod under it
      And the pod beside the corner empties
      When the reviewer delegates to another worker
      Then the new worker sits at the pod under the corner with its team
      And everyone else keeps their desks
      When the team grows past that pod's desks
      Then its newcomers who do not fit sit at the pod beside it, not the one beside the corner

    # A worker can come in before the row of the reviewer that delegated to it, and is
    # no reviewer until then. Seats already taken stay put, so nobody moves while they
    # stay; the team sits split until the worker leaves.
    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A team that turns out to be reviewers keeps its seats on the floor
      Given the office has 2 threads and a worker on the floor whose lead is not in yet
      When its lead comes in as a reviewer, making the worker one too
      Then the worker keeps its desk on the floor and the lead sits in the review corner
      When the lead delegates to another worker
      Then the new worker sits in the review corner with the lead

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer delegated to by a thread that is no reviewer sits in the review corner
      Given the office has a thread with a worker and a reviewer it delegated to
      Then the reviewer sits in the review corner
      And the thread and its other worker sit together on the floor

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer delegated to by a thread that is no reviewer sits next to a full corner
      Given the review corner is full and a thread with a worker sits across the office from it
      When the thread delegates to a reviewer
      Then the reviewer sits at the pod next to the review corner, not by the thread

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A planner that turns out to be a reviewer goes to the review whiteboard
      Given the office has a worker planning whose lead is not in yet
      When its lead comes in as a reviewer, making the worker one too
      Then the worker plans at the review corner's whiteboard and keeps its desk

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Others sit in the review corner only when the floor is full
      Given the office has 40 threads
      Then none of them sits in the review corner
      When it has 42 threads and a reviewer
      Then 2 of the threads and the reviewer sit in the review corner

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The review whiteboard shows a checklist beside a diff
      Given the office has a reviewer working, planning
      Then the reviewer draws a checklist and a diff on the whiteboard in the review corner

  Rule: Each desk shows its project

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A desk shows its project's monogram in its colour
      Given the project "api" has the monogram "AP" in blue in the sidebar
      And the office has a thread in "api"
      Then its desk shows "AP" in blue, in pixels, on the back of its monitor or chair

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A desk shows its project's emoji
      Given the project "fun" has the emoji "🎉" in the sidebar
      And the office has a thread in "fun"
      Then its desk shows "🎉" in pixels

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A desk shows its project's logo in pixels, over its monogram while it loads
      Given the project "logo" has a logo in the sidebar
      And the office has a thread in "logo"
      Then its desk shows the project's monogram in its colour until the logo loads
      And then the logo, a few pixels across

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A desk for a project the sidebar has no icon for shows its first letter
      Given the office has a thread in "web", which has no icon in the sidebar
      Then its desk shows "W", uncoloured

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A project's new icon reaches its desks
      Given the office has a thread in "api"
      When the project "api" gets the monogram "AX" in green
      Then its desk shows "AX" in green, and no other desk is drawn again

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A desk nobody has shows no project
      Given the office has threads "A" and "B"
      When "A" leaves
      Then the desk being carried out shows no project

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Hovering a person shows its project's icon and that it is reviewing
      Given the office has a reviewer in "api"
      When the user hovers its person
      Then the card shows the project's sidebar icon beside "api · reviewing"
