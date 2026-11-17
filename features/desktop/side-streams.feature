# Sources:
#   apps/desktop-ljos/shell/src/streams.rs (each of the shell's threads hands the window its news through a named stream of fixed size)
#   apps/desktop-ljos/shell/src/mc.rs (the MC's messages wait for room rather than being dropped)
#   apps/desktop-ljos/mc/src/driver.rs (what the shell sends its MC waits in a bounded queue too)
#   apps/desktop-ljos/shell/src/device/mod.rs (a device screen's newest picture replaces the one the window has not drawn)
#   apps/desktop-ljos/shell/src/folders/watch.rs (file changes are gathered per file, and an overflow rereads the folder)
#   apps/desktop-ljos/shell/tests/features (runs these scenarios against a fake MC)
#   Shared domain: desktop/native-connection.feature connects the shell to its MC.

Feature: What the shell's own threads hand its window is bounded
  The desktop shell's own threads (its MC connection, device screens, the folder watcher, helper
  processes) hand their news to the window through queues of a fixed size, each with a name. A
  flood from any of them neither grows the app without bound nor freezes the window, and someone
  watching the running app can see what each queue holds and what it gave up.

  Background:
    Given the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title |
      | t1 | p1      | One   |
    And the MC has the project "p1" titled "proj-1"
    And someone is watching the shell's queues

  Rule: A burst from the MC is handled over several frames and none of it is lost

    @desktop
    Scenario: A burst of updates from the MC reaches the sidebar over several frames
      Given the desktop shell is connected to its MC
      And the window handles at most 50 messages from each queue a frame
      When the MC sends 500 updates to the thread "t1", the last titled "Last"
      Then the sidebar's "active" section lists "Last"
      And the shell handled the MC's messages over more than one frame
      And the MC's queue never held more than it has room for
      And no message from the MC was dropped

    @desktop
    Scenario: The MC waits while the window draws no frames
      Given the desktop shell is connected to its MC
      And the window draws no frames
      When the MC sends 3000 updates to the thread "t1", the last titled "Last"
      Then the MC's queue fills to its size and grows no further
      When the window draws frames again
      Then the sidebar's "active" section lists "Last"
      And no message from the MC was dropped

  Rule: A device screen shows its newest picture

    @desktop
    Scenario: A screen's pictures the window has not drawn give way to its newest
      Given the desktop shell is connected to its MC
      And a device screen is open
      And the window draws no frames
      When the device screen decodes 20 pictures
      Then one notice of a new picture waits for the window
      And 19 of the screen's notices were replaced by newer ones
      When the window draws frames again
      Then nothing waits for the window in the device screens' queue

  Rule: Someone watching the app sees every queue

    @desktop
    Scenario: Each of the shell's queues is listed with its size and counts
      Given the desktop shell is connected to its MC
      When the MC updates the thread "t1" with the title "Renamed"
      Then the shell's queues are listed with these sizes:
        | queue             | size |
        | mc                | 1024 |
        | mc-streams        | 256  |
        | mc-calls          | 1    |
        | folders           | 1024 |
        | device-frames     | 16   |
        | plugins           | 1    |
        | plugin-downloads  | 16   |
        | local-transcriber | 64   |
        | theme             | 1    |
        | shell-files       | 1    |
        | settings          | 1    |
        | desktop-update    | 1    |
        | local-cache       | 1    |
        | snap-shot         | 1    |
        | clock             | 1    |
      And the "mc" queue counts what was sent to the window and what the window handled
