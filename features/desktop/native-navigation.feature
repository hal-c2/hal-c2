# Sources:
#   apps/desktop-qt/src/native/NavigationController.cpp (the route, back stack and restore)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (title, settings and cluster from `route`)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/shell/HalC2ShellBridge.tsx (follows `route.follow`, reports `route.open`)
#   apps/web/src/shell/shellRoute.ts (the page's paths as routes)
#   Shared domain: navigation/focus.feature owns what leaving settings means; this file owns
#   that the Qt shell decides where the window is and the page follows.

Feature: The desktop shell decides where the window is
  Once connected, the Qt shell owns the route: the thread, draft, new thread, settings section,
  pull requests or usage the window shows. It keeps where the user came from so back returns
  there, remembers the last route across restarts, and titles the window. The page still draws
  the centre, so it is told where to go, and where its own links take it the shell adopts.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title  | createdAt            |
      | t1 | p1      | First  | 2026-09-23T09:50:00Z |
      | t2 | p1      | Second | 2026-09-23T09:40:00Z |
    And the page groups "env-a:p1" as the project "proj-1"
    And the desktop shell is connected to its node

  Rule: The shell moves the window and the page follows

    @desktop
    Scenario: Opening a thread from the sidebar
      When the user opens "env-a:t1" from the sidebar
      Then the window shows "env-a:t1"
      And the page is asked to open "env-a:t1"
      And the window is titled "First"
      And the sidebar marks "env-a:t1" as open

    @desktop
    Scenario: Opening a draft from the sidebar
      When the user opens the draft "d1" from the sidebar
      Then the window shows the draft "d1"
      And the page is asked to open the draft "d1"
      And the window is titled "New thread"
      And the sidebar marks the draft "d1" as open

    @desktop
    Scenario: A new thread lands in the page's draft
      When the user starts a new thread in "proj-1"
      Then the window shows a new thread in "proj-1"
      And the page is asked to open a new thread in "proj-1"
      When the page lands on the new draft "d9"
      Then the window shows the draft "d9"
      And the sidebar marks the draft "d9" as open

    @desktop
    Scenario: Opening pull requests
      When the user opens pull requests
      Then the window shows pull requests
      And the page is asked to open pull requests
      And the window is titled "Pull requests"

    @desktop
    Scenario: Opening usage
      When the user opens usage
      Then the window shows usage
      And the page is asked to open usage
      And the window is titled "Usage"

    @desktop
    Scenario: The window title follows the thread's title
      Given the user opens "env-a:t1" from the sidebar
      When the node updates the thread "t1" with the title "Renamed"
      Then the window is titled "Renamed"

  Rule: Back returns to where the user was

    @desktop
    Scenario: Leaving settings goes back to the thread
      Given the user opens "env-a:t1" from the sidebar
      When the user opens settings
      Then the window shows settings
      And the page is asked to open settings
      And the user can go back
      When the user goes back from settings
      Then the window shows "env-a:t1"
      And the page is last asked to open "env-a:t1"

    @desktop
    Scenario: Moving between settings sections is one step
      Given the user opens "env-a:t1" from the sidebar
      And the user opens settings
      When the user picks the settings section "/settings/providers"
      Then the window shows the settings section "/settings/providers"
      When the user goes back from settings
      Then the window shows "env-a:t1"

    @desktop
    Scenario: Back with nowhere to return to goes home
      Given the user opens settings
      And the user can not go back
      When the user goes back from settings
      Then the window shows home

  Rule: Where the page's own links take it, the shell adopts

    @desktop
    Scenario: A link in the page opens a thread
      When the page's own link takes it to "env-a:t2"
      Then the window shows "env-a:t2"
      And the sidebar marks "env-a:t2" as open
      And the page is not told where to go

    @desktop
    Scenario: The page's own back returns along the shell's history
      Given the user opens "env-a:t1" from the sidebar
      And the user opens "env-a:t2" from the sidebar
      And the user can go back
      When the page goes back to "env-a:t1"
      Then the window shows "env-a:t1"
      And the user can not go back

    @desktop
    Scenario: A reloaded page is told where the window is
      Given the user opens "env-a:t1" from the sidebar
      When the page reloads
      Then the page is asked to open "env-a:t1"

  Rule: The window reopens where the user left it

    @desktop
    Scenario: Reopening the desktop returns to the last thread
      Given the user opens "env-a:t2" from the sidebar
      When the desktop quits and starts again
      And the page lands on the new draft "d9"
      And the desktop shell is connected to its node
      Then the window shows "env-a:t2"
      And the page is asked to open "env-a:t2"

    @desktop
    Scenario: A thread deleted while the desktop was closed is not reopened
      Given the user opens "env-a:t2" from the sidebar
      When the desktop quits and starts again
      And the node deletes the thread "t2"
      And the page lands on the new draft "d9"
      And the desktop shell is connected to its node
      Then the window shows the draft "d9"
      And the page is not told where to go

    @desktop
    Scenario: Where the user goes while the desktop starts wins over the last route
      Given the user opens "env-a:t2" from the sidebar
      When the desktop quits and starts again
      And the page's own link takes it to "env-a:t1"
      And the desktop shell is connected to its node
      Then the window shows "env-a:t1"
      And the page is not told where to go

  Rule: The composer acts on the thread the window shows

    @desktop
    Scenario: Stop interrupts the thread the window shows
      Given the node updates the thread "t2" with:
        | activeRunId | run-2 |
      And the composer shows "env-a:t1"
      When the user opens "env-a:t2" from the sidebar
      And the user stops the turn
      Then the node receives a "run.interrupt" command for "t2"

    @desktop
    Scenario: A send the page's composer has not caught up with goes through the page
      Given the composer shows "env-a:t1" with the plain prompt "hello"
      When the user opens "env-a:t2" from the sidebar
      And the user sends "hello"
      Then the node receives no commands
      And the action "composer.submit" reaches the page
