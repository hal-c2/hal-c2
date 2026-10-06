# Sources:
#   apps/desktop-qt/src/native/LocalCache.cpp (the client's SQLite cache: thread list rows, thread copies and their cursors)
#   apps/desktop-qt/src/native/ShellStore.cpp (the kept thread list, `have`, changed rows and resets)
#   apps/desktop-qt/src/native/ThreadStore.cpp, TimelineModel.cpp (restoring a thread, resuming it, trimming what is kept)
#   apps/desktop-qt/src/native/NativeShell.cpp (showing what was kept before the MC answers)
#   apps/desktop-qt/src/native/OnboardingController.cpp (the first-run gate of a device that finished setup)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (a `sub`'s offset, handle, window and have)
#   apps/server-ex/lib/hal_c2/streams/server.ex (resuming a log from an offset, starting over on another handle)
#   apps/server-ex/lib/hal_c2/shell.ex (row versions: epoch and rev)
#   Shared domain: connection-health.feature holds reconnects within one run;
#   mobile/offline-and-lifecycle.feature holds what a phone tells the user about cached data;
#   mc/platform/websocket-protocol.feature holds the MC's side of resuming.

Feature: What a client keeps between runs
  A client keeps the thread list and the threads the user opened on its own disk. It shows
  them before its MC answers, without passing them for live, and asks the MC only for what
  changed since. Losing what it kept loses nothing: the MC sends it again.

  Background:
    Given a connected environment with the project "shop"

  @desktop @mobile @backlog-mobile
  Scenario: The thread list and the open thread show before the MC answers
    Given the user was reading a thread in "shop" when the app quit
    When the app starts while its MC is not answering
    Then the thread list shows what the client kept
    And the thread shows the conversation it kept
    And the first-run screen does not cover them
    And neither is shown as live

  # The desktop's host starts its MC after the window is up, and only then says where it is.
  @desktop
  Scenario: A desktop app shows what it kept while its MC is still starting
    Given the user was reading a thread in "shop" when the app quit
    When the app starts and has not been told where its MC is
    Then the thread list shows what the client kept
    And the thread shows the conversation it kept
    And the first-run screen does not cover them
    And neither is shown as live

  @desktop @mobile @backlog-mobile
  Scenario: What a client kept of one MC is not shown for another
    Given the user was reading a thread in "shop" when the app quit
    When the app starts pointed at another MC
    Then nothing the client kept of the first MC is shown

  @desktop @mobile @backlog-mobile
  Scenario: A restarted client is sent only what its thread lacks
    Given the user was reading a thread in "shop" when the app quit
    And the agent answered "Shipping is next." meanwhile
    When the app starts again
    Then the client asks for the thread from where its copy stands
    And the MC sends only what the client lacks
    And the thread shows "Shipping is next." after the conversation it kept

  @desktop @mobile @backlog-mobile
  Scenario: A thread whose MC keeps another log starts over
    Given the user was reading a thread in "shop" when the app quit
    And the thread moved to an MC that keeps another log
    When the app starts again
    Then the MC sends the thread whole
    And the thread shows the conversation it kept
    And the client resumes from the new log after a reconnect

  @desktop @mobile @backlog-mobile
  Scenario: A restarted client is sent only the thread list rows that changed
    Given the app quit with the threads "Tax line" and "Checkout" in the list
    And the thread "Shipping" was created while the app was closed
    When the app starts again
    Then the client says which thread list it holds
    And the MC sends only the row of "Shipping"
    And the thread list shows "Tax line", "Checkout" and "Shipping"

  @desktop @mobile @backlog-mobile
  Scenario: A thread list its MC no longer vouches for is replaced
    Given the app quit with the threads "Tax line" and "Checkout" in the list
    And the MC restarted and lost "Checkout" while the app was closed
    When the app starts again
    Then the MC sends its whole thread list
    And the thread list shows "Tax line" but not "Checkout"

  @desktop @mobile @backlog-mobile
  Scenario: A thread deleted while the app was closed is not kept
    Given the user was reading a thread in "shop" when the app quit
    And the thread was deleted while the app was closed
    When the app starts again
    Then the thread list no longer shows the thread
    And the client keeps nothing of its conversation

  @desktop @mobile @backlog-mobile
  Scenario: Kept threads are not shown as reachable once the credential is refused
    Given the user was reading a thread in "shop" when the app quit
    And the environment refuses the client's credential
    When the app starts again
    Then the thread shows the conversation it kept
    And the thread says its MC cannot be reached

  @desktop @mobile @backlog-mobile
  Scenario: A thread the user left is kept as its newest turns
    Given the user loaded the earlier turns of a long thread in "shop"
    When the user leaves the thread for more than five minutes and returns
    Then the thread comes back as its newest turns without being sent again
    And its earlier turns can be loaded again

  @desktop @mobile @backlog-mobile
  Scenario: Losing what the client kept loses nothing
    Given the user was reading a thread in "shop" when the app quit
    And what the client kept was deleted
    When the app starts again
    Then the MC sends its whole thread list
    And the MC sends the thread whole
    And the thread shows the conversation it kept
