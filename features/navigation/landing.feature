# Sources:
#   apps/web/src/routes/_chat.index.tsx (IndexDraftLanding: the draft, the hero, the retry)
#   apps/web/src/routes/_chat.index.tsx (HostedStaticOnboardingState), apps/web/src/routes/__root.tsx (the local environment off counts as no server)
#   apps/web/src/components/Sidebar.logic.ts (sortScopedProjectsForSidebar, "updated_at")
#   apps/web/src/hooks/useHandleNewThread.ts (a project's draft is reused)
#   apps/web/src/components/ThreadRouteView.tsx (a missing thread or draft goes to the index)
#   apps/desktop-qt/src/native/DraftController.cpp (land: the draft, `landing`, landing.retry)
#   apps/desktop-qt/src/native/NavigationController.cpp (home, the open thread going away)
#   apps/desktop-qt/src/native/SidebarModel.cpp (mostRecentProject)
#   apps/desktop-qt/qml/HalC2/Bricks/HomePage.qml (no projects, the failure and Try again)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   files/adding-projects.feature owns the add-project invitation itself. The phone opens on its
#   thread list (mobile/home-and-thread-list.feature) and the terminal client asks the user to
#   pick a thread (tui/layout.feature), so these are the desktop's.

Feature: A window with no thread lands on a new thread
  With no thread open the desktop does what the web's start page does: once the MC has
  reported every environment's projects it opens a new thread in the most recently active
  project, in place of where the user was, so the first screen is a prompt and not a dead end.
  Every way of ending up with no thread lands there, and landing again reuses the project's
  draft. With no projects the user is asked to add one.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's MC "mc-a" serves the environment "env-a"

  Rule: With projects, the most recent one's draft opens

    Background:
      Given the MC has these threads:
        | id | project | title  | createdAt            |
        | t1 | p1      | First  | 2026-09-23T09:30:00Z |
        | t3 | p2      | Third  | 2026-09-23T09:50:00Z |
      And the MC has the project "p1" titled "proj-1"
      And the MC has the project "p2" titled "proj-2"

    @desktop
    Scenario: Opening the app lands on a new thread in the most recent project
      When the desktop shell is connected to its MC
      Then the window shows a new draft in "proj-2"
      And the header shows a new thread in "proj-2"
      And the user can not go back

    @desktop
    Scenario: Leaving the thread lands on the same draft again
      Given the desktop shell is connected to its MC
      And the user opens "env-a:t1" from the sidebar
      When the user leaves the thread
      Then the window shows a new draft in "proj-2"
      And the desktop keeps 1 draft

    @desktop
    Scenario: The open thread going away lands on a new thread
      Given the desktop shell is connected to its MC
      And the user opens "env-a:t3" from the sidebar
      When the MC deletes the thread "t3"
      Then the window shows a new draft in "proj-1"

    @desktop
    Scenario: A new window lands on the same draft
      Given the desktop shell is connected to its MC
      When the user opens a new window
      Then the new window shows the first window's draft
      And the desktop keeps 1 draft

    @desktop
    Scenario: A new thread that can not be started says so and tries again
      Given the desktop can not keep its drafts
      When the desktop shell is connected to its MC
      Then the window says it couldn't start a new thread
      And the desktop keeps 0 drafts
      When the desktop can keep its drafts again
      And the user tries again
      Then the window shows a new draft in "proj-2"

  Rule: With no projects, the user is asked to add one

    @desktop
    Scenario: With no projects the window stays home
      When the desktop shell is connected to its MC
      Then the window shows home
      And the desktop keeps 0 drafts

    @desktop
    Scenario: The first project added lands on its draft
      Given the desktop shell is connected to its MC
      When the MC has the project "p1" titled "proj-1"
      Then the window shows a new draft in "proj-1"

  Rule: With no environment at all, the user is asked to connect one

    @backlog @desktop
    Scenario: With the local environment off and nothing else connected the window asks for a connection
      Given the local environment is turned off and no other environment is saved
      When the user opens the app
      Then the window says "Connect to a computer running HAL-C2"
      And it says the local environment is turned off and can be turned back on in Connections
      And it offers "Open Connections", which opens the connections settings

    @backlog @desktop
    Scenario: With the local environment off a saved environment lands on a new thread as usual
      Given the local environment is turned off and the environment "studio" is saved with projects
      When the user opens the app
      Then the window shows a new draft in the most recent project of "studio"

    # The hosted web app has no server of its own; the native clients always start from an MC or a saved one.
    @dropped @desktop
    Scenario: The hosted web app with nothing connected explains how to add a machine
      Given the user opens the hosted web app with no environment saved
      Then the page says "Connect to a computer running HAL-C2"
      And it says to add the machine with a pairing link, or to sign in to HAL-C2 Connect where that is offered
