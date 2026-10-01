# Sources:
#   apps/desktop-qt/src/native/McClient.cpp (protocol-3 socket: subscriptions, rpc, reconnect)
#   apps/desktop-qt/src/native/ShellStore.cpp (the shell shape folded into project and thread rows)
#   apps/desktop-qt/src/native/NativeShell.cpp (ready once the MC's first snapshot is in)
#   apps/desktop-qt/src/main.cpp (scripted runs start on NativeShell::ready)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake MC)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (the protocol the shell speaks)
#   packages/client-runtime/src/v3/clusterSocket.ts (the TypeScript twin of the shell's client)
#   Shared domain: desktop/shell-host.feature starts the MC and hands the shell its token.

Feature: The desktop shell talks to its MC itself
  The Qt shell holds its own connection to the desktop's MC, as the TUI does, and sends the
  sidebar's and the composer's actions to it.

  Background:
    Given the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title |
      | t1 | p1      | One   |
    And the MC has the project "p1" titled "proj-1"

  Rule: The shell connects with the MC's access token and follows the shell shape

    @desktop
    Scenario: The shell connects with the MC's own access token
      When the desktop shell connects to its MC with the token "mc-token"
      Then the MC was reached with the token "mc-token"
      And the shell subscribed to the MC's "shell" shape

    @desktop
    Scenario: The MC's updates reach the shell's sidebar
      Given the desktop shell is connected to its MC
      When the MC updates the thread "t1" with the title "Renamed"
      Then the sidebar's "active" section lists "Renamed"

    @desktop
    Scenario: A thread the MC deletes leaves the shell's sidebar
      Given the desktop shell is connected to its MC
      When the MC deletes the thread "t1"
      Then the sidebar's "active" section is empty

  Rule: The shell starts on the MC's first snapshot

    @desktop
    Scenario: Before the first snapshot the shell sends nothing for threads it has not seen
      Given the MC holds back its snapshot
      And the desktop shell connects to its MC
      When the user settles "env-a:t1"
      Then the MC receives no commands

    @desktop
    Scenario: A scripted run starts once the MC's first snapshot is in
      Given a scripted run is waiting for the desktop app
      And the MC holds back its snapshot
      And the desktop shell connects to its MC
      Then the scripted run has not started
      When the MC sends its snapshot
      Then the scripted run starts once

  # The shell owns the sidebar and the composer from the start: there is no page to hand
  # them over from, to tell, or to publish a sidebar of its own.
  @dropped @desktop
  Rule: The page keeps the sidebar and the composer until the MC's first snapshot

    Scenario: The first snapshot hands the sidebar and the composer to the shell
      Given the MC holds back its snapshot
      And the desktop shell connects to its MC
      When the MC sends its snapshot
      Then the shell tells the page it owns the sidebar and the composer

    Scenario: Before the first snapshot the page is told nothing when it asks
      Given the MC holds back its snapshot
      And the desktop shell connects to its MC
      When the page asks who owns the sidebar
      Then the page has not been told who owns the sidebar

    Scenario: A page that loads after the hand-over asks and is told
      Given the desktop shell is connected to its MC
      And the page forgets who owns the sidebar
      When the page asks who owns the sidebar
      Then the shell tells the page it owns the sidebar and the composer

    Scenario: The page's own sidebar no longer replaces the shell's
      Given the desktop shell is connected to its MC
      When the page publishes its own sidebar
      Then the sidebar's "active" section lists "One"

  Rule: A dropped connection comes back on its own

    @desktop
    Scenario: The shell reconnects and subscribes again after the connection drops
      Given the desktop shell is connected to its MC
      When the MC drops the connection
      Then the shell reconnects to the MC
      And the shell subscribed to the MC's "shell" shape again

    @desktop
    Scenario: An action while the MC is unreachable fails with a toast
      Given the desktop shell is connected to its MC
      And the MC stops accepting connections
      When the MC drops the connection
      And the user settles "env-a:t1"
      Then the user sees an "error" toast "Failed to settle thread" saying "not connected"
