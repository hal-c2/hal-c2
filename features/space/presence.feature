# Sources:
#   features/space/beyond-pages.feature (the backlog entry for seeing who else is on a page)
#   spaces-feature-bdd-tests branch, apps/desktop-qt/examples/space/PresenceCluster.qml and
#     features/space/collaboration-agents-and-dots.feature (the prototype; read for ideas only)
#   packages/contracts/src/space.ts (SpacePresenceViewer, subscribeSpacePresence)
#   apps/server-ex/lib/hal_c2/space/presence.ex

@mc @desktop @mobile @tui
Feature: Who else is on a page
  A page open on a client says who else is looking at it right now: the user's other
  devices and any agent working on it. HAL-C2 has no accounts, so every paired device is
  the one user, named by its device. Presence is never written down: it lives only as
  long as the connections it describes, and an MC that restarts has forgotten it.

  Background:
    Given a connected environment
    And the Space "Research" with the page "Roadmap"

  Rule: The open page says who else is on it

    Scenario: Nobody else is on the page
      When the user opens the page "Roadmap"
      Then the page shows nobody else

    Scenario: A device already on the page is shown
      Given the page "Roadmap" is open on the device "Phone"
      When the user opens the page "Roadmap"
      Then the page shows the user also on "Phone"

    Scenario: A device arriving shows up without a refresh
      Given the user opens the page "Roadmap"
      When the device "Phone" opens the page "Roadmap"
      Then the page shows the user also on "Phone"

    Scenario: A device that leaves the page goes away without a refresh
      Given the page "Roadmap" is open on the device "Phone"
      And the user opens the page "Roadmap"
      When the device "Phone" leaves the page "Roadmap"
      Then the page shows nobody else

    Scenario: A device whose connection drops goes away without a refresh
      Given the page "Roadmap" is open on the device "Phone"
      And the user opens the page "Roadmap"
      When the connection of the device "Phone" drops
      Then the page shows nobody else

    Scenario: The user on several devices counts once
      Given the page "Roadmap" is open on the device "Phone"
      And the page "Roadmap" is open on the device "Laptop"
      When the user opens the page "Roadmap"
      Then the page shows one person, also on "Laptop" and "Phone"

    Scenario: An agent working on the page is shown by its thread
      Given a thread "Work"
      And the agent in "Work" is working on the page "Roadmap"
      When the user opens the page "Roadmap"
      Then the page shows the agent of "Work"

    Scenario: An agent is gone from the page when its turn ends
      Given a thread "Work"
      And the agent in "Work" is working on the page "Roadmap"
      And the user opens the page "Roadmap"
      When the turn of the agent in "Work" ends
      Then the page shows nobody else

    Scenario: Another page has its own viewers
      Given the Space's page "Notes"
      And the page "Roadmap" is open on the device "Phone"
      And the user opens the page "Roadmap"
      When the user opens the page "Notes"
      Then the page shows nobody else

    Scenario: A user who leaves a page is gone from it for the others
      Given the page "Roadmap" is open on the device "Phone"
      And the user opens the page "Roadmap"
      When the user leaves the page
      Then the user is no longer on the page "Roadmap"

  @mc
  Rule: The MC tracks viewers per page and writes nothing down

    Scenario: Each client sees the other
      Given the page "Roadmap" is open on the device "Phone"
      When the user opens the page "Roadmap"
      Then the page shows the user also on "Phone"
      And the device "Phone" sees the user also on "This device"

    Scenario: A device with the page open twice counts once until it leaves both
      Given the user opens the page "Roadmap"
      And the page "Roadmap" is open on the device "Phone"
      And the page "Roadmap" is open again on the device "Phone"
      When the device "Phone" leaves the page "Roadmap" once
      Then the page still shows the user also on "Phone"
      When the device "Phone" leaves the page "Roadmap"
      Then the page shows nobody else

    Scenario: A client hears nothing about a page it does not have open
      Given the Space's page "Notes"
      And the user opens the page "Notes"
      When the device "Phone" opens the page "Roadmap"
      Then the user hears nothing about who is on a page

    Scenario: A second connection of the same device tells no one
      Given the user opens the page "Roadmap"
      And the page "Roadmap" is open on the device "Phone"
      And the page shows the user also on "Phone"
      When the page "Roadmap" is open again on the device "Phone"
      Then the user hears nothing about who is on a page

    Scenario: An agent moves with the page it last worked on
      Given the Space's page "Notes"
      And a thread "Work"
      And the agent in "Work" is working on the page "Roadmap"
      And the user opens the page "Roadmap"
      When the agent in "Work" is working on the page "Notes"
      Then the page shows nobody else

    Scenario: An agent writing to a page counts as working on it
      Given a thread "Work"
      And the user opens the page "Roadmap"
      When the agent in "Work" adds the block "Agent note" to "Roadmap"
      Then the page shows the agent of "Work"

    Scenario: An agent refused a page is not on it
      Given a thread "Work"
      And the user opens the page "Roadmap"
      When the agent in "Work" fails to read a page that does not exist
      Then the user hears nothing about who is on a page

    Scenario: An agent that leaves the page alone stops counting
      Given a thread "Work"
      And the agent in "Work" is working on the page "Roadmap"
      And the user opens the page "Roadmap"
      When the agent in "Work" has not touched the page for a while
      Then the page shows nobody else

    Scenario: Presence is not written to the Space
      Given the page "Roadmap" is open on the device "Phone"
      When the user opens the page "Roadmap"
      Then the Space's stream holds nothing about who is on a page

    Scenario: A restarted MC has forgotten who was on a page
      Given a thread "Work"
      And the agent in "Work" is working on the page "Roadmap"
      When the MC restarts
      And the user opens the page "Roadmap"
      Then the page shows nobody else

    Scenario: Clients rejoin the page when the presence service starts again
      Given the page "Roadmap" is open on the device "Phone"
      And the user opens the page "Roadmap"
      When the presence service starts again
      Then the client is told to follow the page's viewers again

  @backlog
  Rule: Still to come

    # Waits on the maintainers deciding what names a person on an MC with no accounts.
    @blocked
    Scenario: Two people on one MC are told apart
      Given the device "Sierra's phone" was paired for the person "Sierra"
      And the page "Roadmap" is open on the device "Sierra's phone"
      When the user opens the page "Roadmap"
      Then the page shows "Sierra" as someone other than the user

    Scenario: The user sees where others are on the page
      Given the page "Roadmap" is open on the device "Phone"
      When the device "Phone" selects a block on the page "Roadmap"
      Then the page marks that block with "Phone"

    Scenario: The user sees someone typing
      Given the page "Roadmap" is open on the device "Phone"
      When someone types in a block on the device "Phone"
      Then the page shows "Phone" is typing there
