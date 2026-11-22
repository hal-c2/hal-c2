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
  other and talk. One whose agent asks the user something shows a question mark. The
  office grows with the people in it, so everyone has a desk.

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
    Scenario: A message too long for plugins to hear whole is still a talk
      Given threads "Lead" and "Reviewer" in the project "api"
      When the agent of "Lead" sends "Reviewer" a message of 5,000 characters
      Then the office has a "message" talk from "Lead" to "Reviewer" saying "…"

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
      Given the office has 8 waiting threads
      When they all take a break at once
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
    Scenario: Waiting and idle people stay at their desks and now and then take a break
      Given the office has a thread working, typing
      When the thread is waiting
      Then its person sits back at its desk
      And now and then, at random, it walks to the break room for a short while
      And drinks coffee, plays the arcade, sits on the couch or chats there
      And then walks back to its desk, sometimes with a cup

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Waiting people slack off on their screens
      Given the office has a thread waiting, at its desk
      Then most of the time its screen shows solitaire, snake, falling blocks, a cat video, a meme or some shopping
      And which one is picked at random, and changes every few seconds
      And the screen changes at most once a second
      When the thread is idle
      Then its screen shows one only now and then
      When the thread is working, typing
      Then its screen shows its work again

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A person asking the user something does not slack off
      Given the office has a thread asking, at its desk
      Then its screen never shows a game, a video, a meme or shopping

    # The page ticks every 40 ms while anyone walks and every 200 ms otherwise.
    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A whiteboard fills at the same pace whether anyone walks or not
      Given the office has a thread working, planning, at a whiteboard
      When 2.4 seconds pass with people walking, and again with nobody walking
      Then the whiteboard fills by a fifth each time

    # Only screens showing work follow the clock.
    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Quiet screens stay still
      Given the office has 16 threads idle, at their desks
      When the office runs for a while
      Then a screen showing the idle screen does not change

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The break room never holds more than its cap
      Given the office has 70 threads waiting
      When the office runs for a while
      Then most of them sit at their desks
      And never more than 8 of them are on a break at once

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone walking back from a break keeps its place until it is out
      Given the break room holds 8 people on a break
      When one of them ends its break and walks back to its desk
      Then nobody else goes on a break until it has left the break room

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A break counts from when the person sits down
      Given the office has 40 threads working, typing
      When 30 more threads come in waiting, and movers carry in their desks
      Then none of them goes on a break before it has sat at its desk for at least 15 seconds

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Some people take breaks more often than others
      Given the office has 40 threads idle
      When the office runs for a while
      Then some of them never leave their desks and some take several breaks
      And the breaks go to different places in the break room

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Two agents that talk walk up to each other
      Given the office has threads "Lead" and "Reviewer"
      When the office has a "message" talk from "Lead" to "Reviewer" saying "Please look at the diff"
      Then the person of "Lead" walks up next to the person of "Reviewer", beside it rather than above or below it
      And they face each other and "Please look at the diff" shows in a speech bubble
      And afterwards "Lead" goes back to what it was doing

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A person spoken to on its way stops only on a spot nobody else has
      Given "Lead" talks to "Reviewer" just as "Reviewer" walks over another person's spot
      Then "Reviewer" walks on past that spot before it stops to listen
      And "Lead" talks from beside it, on a spot of its own
      And nobody else is sent to the spot "Reviewer" listens on until it has replied

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: People take part in one talk at a time
      Given "Lead" and "Reviewer" each have a talk for the other at the same moment
      Then one of the talks runs to its end before the other starts
      And when "Coder" has a talk for "Reviewer" while "Lead" is talking to it
      Then "Coder" waits until "Lead" has had its reply
      And afterwards nobody keeps a spot for either talk

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
    Scenario: The office grows by pods when people outnumber its desks
      Given the page is 1200 by 760
      And the office has 40 threads, at its 40 desks outside the review corner
      When it has 41 threads
      Then the office has two rows of four pods, 64 desks, as deep as before
      And the 41st person has a desk in a new pod
      And everyone else keeps their desk
      And the office is drawn again once, for its new size

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office grows into the grid of pods that shows it biggest
      Given the page is 1600 by 900
      When the office has 70 threads
      Then its pods are in the grid that fits the page at the biggest scale
      And it shows bigger than in rows of three pods
      When the page is 700 by 1300
      Then the office has fewer pods to a row than before
      And everyone keeps their desk and walks there from where they were

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario Outline: An office of six pods is two rows of three in an ordinary window
      Given the page is <width> by <height>
      When the office has 12 threads
      Then the office has two rows of three pods, 48 desks

      Examples:
        | width | height |
        | 1024  | 700    |
        | 1200  | 760    |
        | 1920  | 1080   |

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A tall, narrow view stacks the pods in one column
      Given the page is 300 by 1000
      When the office has 12 threads and a reviewer
      Then the office is one column of six pods
      And the review corner is the top pod, where the reviewer sits

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Two people talking keep their places through a resize
      Given "Lead" is talking to "Reviewer" in the break room
      When the page is resized to a grid with fewer pods to a row
      Then both still hold their tiles and nobody else is sent there
      And the talk carries on to its end

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone resting at its desk through a resize takes its break as planned
      Given the office has 16 threads waiting, each sitting at its desk until its next break
      When the page is resized to a grid with fewer pods to a row
      Then whoever still sits at its desk waits for the same next break as before
      And whoever has a desk somewhere else waits 15 to 45 seconds from when it sits there

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone stepping through the door when the office is resized walks on
      Given a person is stepping through the door into the break room
      When the page is resized to a grid with fewer pods to a row
      Then it carries on stepping through the door where the door is now
      And it is never put back on the office's floor

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone stepping out of the door when the office is resized walks on
      Given a person is stepping out of the break room through the door
      When the page is resized to a grid with fewer pods to a row
      Then it carries on stepping out of the door where the door is now
      And it walks on to its desk

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone stepping where a resize puts a wall steps from the floor
      Given a person is stepping off a tile where the smaller office's south wall will be
      When the page is resized to a grid with more pods to a row
      Then it goes on from the nearest floor, never from inside the wall

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A resize that moves the break room over the office keeps the office out of it
      Given the page is 1200 by 760 and the office has 70 threads working, in rows of four pods
      When the page is 300 by 1000, and the break room's wall moves west of where they sit
      Then nobody who was in the office is in the break room
      And they step to the office's floor by the wall and walk to their desks

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A resize that keeps the best grid leaves the office as it is
      Given the page is 1600 by 900 and the office has 70 threads
      When the page is 1700 by 950 and then 1550 by 880
      Then the office is not built or drawn again
      And nobody moves

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office shrinks once a pod's worth of desks would still be free
      Given the page is 1200 by 760
      And the office has 70 threads, in three rows of four pods
      When it has 57 threads
      Then the office keeps its twelve pods
      When it has 56 threads
      Then the people in the last three pods move to desks in the others
      And the movers carry those pods' desks out
      And then the office is three rows of three pods
      And nobody is left standing where the office ended

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A resize while the office shrinks
      Given the page is 1600 by 900 and the office has 70 threads
      When it has 40 threads
      And the page is 700 by 1300 before the office has shrunk
      Then the office shrinks to the grid for its smaller size in the new view
      And everyone is at a desk of their own, on the floor

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A resize that keeps the grid while the office shrinks still shrinks it for the new view
      Given the page is 1150 by 900 and the office has 70 threads, in three rows of four pods
      When it has 40 threads, and the office closes down to nine pods
      And the page is 1450 by 900, where twelve pods are still best four to a row
      Then the office closes down to eight pods instead, as fits the wider view best

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone listening in a pod the office closes finishes the talk first
      Given the page is 1200 by 760 and the office has 70 threads, in three rows of four pods
      And "Lead" is talking to someone who sits in one of the last three pods
      When it has 56 threads, that listener among them
      Then the listener keeps the tile it listens on until it has replied
      And then walks to its new desk, and the office shrinks to three rows of three pods
      And no tile stays claimed for the talk or past the office's new end

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office closes a pod only once nobody listens at one of its seats
      Given the page is 1200 by 760 and the office has 70 threads, in three rows of four pods
      And "Lead" is talking to someone who sits in one of the last three pods
      When it has 56 threads, that listener among them
      And the movers carry out every desk in the last three pods, the listener's too, before it has replied
      Then the office keeps its twelve pods until the talk ends
      And then shrinks to three rows of three pods

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office shrinks only once nobody listens in the rows it loses
      Given the page is 900 by 900 and the office has 70 threads, in four rows of three pods
      And "Lead" is talking to someone standing on the floor by the last row of pods
      When it has 56 threads, that listener among them
      And the movers carry out every desk in the last row of pods before it has replied
      Then the office keeps its twelve pods until the talk ends
      And then shrinks to three rows of three pods

    # The floor is built again on a resize, and everyone routed afresh, so someone can be
    # sent to the tile a speaker talks from.
    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A speaker whose side someone else took talks from another side
      Given "Lead" is telling "C" "Got a minute?"
      When someone else is sent to the tile "Lead" talks from
      Then "Lead" walks to the nearest other free side of "C", not round it, and says its line from there
      And nobody stops on a tile someone else stands on

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A speaker with no free side left by the listener ends the talk
      Given "Lead" is telling "C" "Got a minute?"
      When every tile beside "C" is taken by someone else
      Then the talk ends and "C" holds no tile for it

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: An office emptied before its new desks arrive shrinks at once
      Given the office is empty
      When it has 75 threads
      And it is empty again before any desk is carried in
      Then the office is back to six pods straight away

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office grows for reviewers only once the review corner is full
      Given the office has 40 threads and 8 reviewers, in six pods
      When a ninth reviewer comes in
      Then the office has more pods

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer at an ordinary desk counts as one of those
      Given the office has 40 threads at its 40 desks outside the review corner
      When one of them turns out to be a reviewer, delegated to by a new reviewer
      And then another thread comes in
      Then the office grows, so everyone has a desk

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: The office is never smaller than six pods
      Given the page is 1200 by 760
      And the office has 75 threads
      When it has 2 threads
      Then the office shrinks back to two rows of three pods, 48 desks

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: People coming and going within the office's size do not redraw it
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
    Scenario: A full office says it is being set up until everyone in it is drawn
      Given the office has 40 threads
      When the office page opens
      Then its header is laid out and the office says "Setting up the office…"
      And the page keeps drawing frames while the people are drawn a few at a time
      When everyone is drawn
      Then the office shows with each person at a desk, and the message is gone
      When it has another thread
      Then the office does not say it is being set up again

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: An office that has not arrived yet is not being set up
      Given the office page is open on a machine whose office has not arrived
      Then the office says "Waiting for the office…"
      When its office arrives with no threads
      Then the office says "Nobody is in the office. Threads show up here as they work."

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Another machine's office is set up afresh, with its people already at their desks
      Given the office page is open and set up on a machine with 4 threads
      When the user picks another machine with 6 threads
      Then the office says it is being set up until those 6 are drawn
      When the user picks the first machine again
      Then the office says it is being set up, and its 4 people are at their desks, not walking in

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
    Scenario: A person and a mover that meet head-on walk through each other
      Given a person and a mover carrying a desk walk into each other on open floor
      Then they walk straight through each other and both get where they are going
      And neither steps aside, waits or goes around

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A talk heard before both are in the office waits for them
      Given the office has "Lead" and not yet its new worker
      When the office has a "delegate" talk from "Lead" to that worker
      And the worker joins the office while the office still has the talk
      Then "Lead" walks up to the worker and says it, once

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
    # stay; the team sits split until the worker leaves, or gives its floor desk up to
    # a thread that needs it.
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
    Scenario: Nobody but reviewers sits in the review corner
      Given the office has 40 threads
      Then none of them sits in the review corner
      When it has 42 threads and a reviewer
      Then the office grows
      And none of the threads sits in the review corner
      And the reviewer sits in the review corner

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone in the review corner who is no reviewer leaves it
      Given the office has 2 reviewers in the review corner
      When one of them is a reviewer no more
      Then it sits on the floor and the other keeps its corner desk

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Reviewers past the corner sit on the floor, and every other thread keeps a desk
      Given the office has 10 reviewers and 8 teams of 5 threads, the reviewers listed first
      Then every thread in the teams has a desk on the floor
      And 8 of the reviewers sit in the review corner and the other 2 at desks on the floor

    # A reviewer on a floor desk counts as a desk the office needs, so the office grows
    # rather than take it away. Should a thread still find no desk, a reviewer on a floor
    # desk gives its desk up.
    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer on a floor desk keeps it when threads fill the floor
      Given the office has 10 reviewers, 8 in the review corner and 2 on the floor
      When a reviewer in the corner leaves and 40 threads come in
      Then the office grows
      And every thread has a desk on the floor
      And every reviewer keeps its desk

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer listening at a floor desk keeps it when the floor fills
      Given the office has 9 reviewers, 8 in the review corner and 1 on the floor, and 39 threads
      And a thread is talking to the reviewer on the floor, who listens at its desk
      When another thread comes in
      Then the office grows and the thread sits at a desk of its own
      And the reviewer keeps its desk
      And nobody stands on a tile someone else holds while they find their desks

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A desk given away while someone listens at it is theirs until the talk ends
      Given a thread is talking to a reviewer, who listens at its floor desk
      When that desk goes to another thread
      Then the reviewer stays at it until the talk ends
      And the thread waits beside the pod meanwhile
      And sits down at the desk as soon as the talk ends

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Someone reading who leaves the review corner on a full floor gets a floor desk
      Given the office has 40 threads and a reviewer reading at a shelf
      When the reviewer is a reviewer no more
      Then the office grows and it has a desk on the floor
      And it reads on at the shelf

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

    # Reviewers hot-desk: the review corner's desks belong to no project.
    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: A reviewer's desk shows no project
      Given the project "api" has the monogram "AP" in blue in the sidebar
      And the office has 9 reviewers in "api" and a thread in "api"
      Then the desks of the 8 reviewers in the review corner show no project
      And neither does the desk of the reviewer at the pod next to it
      And the thread's desk shows "AP" in blue

    @desktop @mobile @backlog-desktop @backlog-mobile
    Scenario: Hovering a person shows its project's icon and that it is reviewing
      Given the office has a reviewer in "api"
      When the user hovers its person
      Then the card shows the project's sidebar icon beside "api · reviewing"
