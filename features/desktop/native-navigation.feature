# Sources:
#   apps/desktop-qt/src/native/NavigationController.cpp (the route, back stack and restore)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (title, settings and cluster from `route`)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   Shared domain: settings/search-and-navigation.feature owns leaving settings and moving
#   between sections, navigation/windows.feature the window title, and
#   composer/sending-turns.feature that the composer acts on the thread the window shows.
#   This file owns that the Qt shell decides where the window is.

Feature: The desktop shell decides where the window is
  Once connected, the Qt shell owns the route: the thread, draft, new thread, settings section,
  pull requests or usage the window shows. It keeps where the user came from so back returns
  there, remembers the last route across restarts, and titles the window.

  Background:
    Given the time is "2026-09-23T10:00:00Z"
    And the desktop's node "node-a" serves the environment "env-a"
    And the node has these threads:
      | id | project | title  | createdAt            |
      | t1 | p1      | First  | 2026-09-23T09:50:00Z |
      | t2 | p1      | Second | 2026-09-23T09:40:00Z |
    And the node has the project "p1" titled "proj-1"
    And the desktop shell is connected to its node
    And the window shows a new draft in "proj-1"

  Rule: The shell moves the window

    @desktop
    Scenario: Opening a thread from the sidebar
      When the user opens "env-a:t1" from the sidebar
      Then the window shows "env-a:t1"
      And the window is titled "First"
      And the sidebar marks "env-a:t1" as open

    @desktop
    Scenario: Opening a draft from the sidebar
      Given the user starts a new thread in "proj-1"
      And the user opens "env-a:t1" from the sidebar
      When the user opens the draft from the sidebar
      Then the window shows the draft
      And the window is titled "New thread"
      And the sidebar marks the draft as open

    @desktop
    Scenario: A new thread opens the project's draft
      Given the user opens "env-a:t1" from the sidebar
      When the user starts a new thread in "proj-1"
      Then the window shows a new draft in "proj-1"
      And the sidebar marks the draft as open

    # The embedded page is gone; nothing but the shell opens drafts.
    @dropped @desktop
    Scenario: A draft the page opens by itself is the shell's too
      When the page lands on its own draft "d9" for the thread "t9" in "p1"
      Then the window shows the draft "d9"
      And the sidebar marks the draft "d9" as open
      And the desktop keeps the draft "d9"

    @desktop
    Scenario: Opening pull requests
      When the user opens pull requests
      Then the window shows pull requests
      And the window is titled "Pull requests"

    @desktop
    Scenario: Opening usage
      When the user opens usage
      Then the window shows usage
      And the window is titled "Usage"

  Rule: Back returns to where the user was

    @desktop
    Scenario: Leaving settings goes back to the thread
      Given the user opens "env-a:t1" from the sidebar
      When the user opens settings
      Then the window shows settings
      And the user can go back
      When the user goes back from settings
      Then the window shows "env-a:t1"

  # The embedded page is gone, and with it its own links, back button and reloads.
  @dropped
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
      When the user goes back
      Then the window shows a new draft in "proj-1"
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
      And the desktop shell is connected to its node
      Then the window shows "env-a:t2"

    @desktop
    Scenario: A thread deleted while the desktop was closed is not reopened
      Given the user opens "env-a:t2" from the sidebar
      When the desktop quits and starts again
      And the node deletes the thread "t2"
      And the desktop shell is connected to its node
      Then the window shows a new draft in "proj-1"

    # Only the page could go anywhere before the node's first snapshot; the shell's sidebar
    # lists nothing until then, so the last route is the only one to restore.
    @dropped @desktop
    Scenario: Where the user goes while the desktop starts wins over the last route
      Given the user opens "env-a:t2" from the sidebar
      When the desktop quits and starts again
      And the page's own link takes it to "env-a:t1"
      And the desktop shell is connected to its node
      Then the window shows "env-a:t1"
