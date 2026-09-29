# Sources:
#   packages/contracts/src/checkpointDiff.ts (TurnCountRange, getTurnDiff, getFullThreadDiff)
#   packages/contracts/src/rpc.ts (orchestration.getTurnDiff, orchestration.getFullThreadDiff)
#   apps/server-ex/lib/hal_c2/checkpoint.ex (turn_diff, capture, start_ref)
#   apps/server-ex/lib/hal_c2/orchestration.ex (orchestration.getTurnDiff, orchestration.getFullThreadDiff)
#   apps/web/src/components/DiffPanel.tsx (Latest turn, Turn N)
#   apps/tui/src/components/ChatView.tsx (diff scopes)
#   apps/tui/src/components/DiffViewer.tsx
#   apps/tui/src/connection.ts (getTurnDiff, getFullThreadDiff)
#   apps/desktop-qt/src/native/ThreadDiff.cpp (turn picker, loading, retry)
#   apps/desktop-qt/src/native/DiffModel.cpp (collapsed large files, split view)
#   apps/desktop-qt/qml/HalC2/Bricks/DiffPanel.qml
#   apps/desktop-qt/tests/native/features/PanelSteps.cpp

Feature: What each turn changed
  Every finished turn leaves a hidden checkpoint of the checkout, so the user can see what
  one turn changed or everything the thread has changed since it began.

  Background:
    Given a connected environment with the thread "Tax work" in the git project "shop"
    And the agent finished 3 turns in "Tax work" that each edited files

  @node
  Scenario: Each finished turn leaves a checkpoint
    When the user lists the checkpoints of "Tax work"
    Then there is one checkpoint for each of the 3 turns
    And the user's branches and staging area are unchanged by them

  @node @tui
  Scenario: Seeing what one turn changed
    When the user opens the diff of turn 2
    Then only the changes the agent made during turn 2 are shown

  @node @tui
  Scenario: Seeing everything the thread changed
    When the user opens all changes of "Tax work"
    Then the changes of turns 1 to 3 are shown together against the checkout before turn 1

  @tui
  Scenario: The terminal client opens on all changes and steps through turns
    When the user opens the diff in the terminal client
    Then all changes are shown first
    And the user can step to each turn's own diff

  @node
  Scenario: Whitespace-only changes are hidden unless asked for
    Given turn 3 only re-indented "src/cart.ts"
    When the user opens the diff of turn 3
    Then no changes are shown
    But asking to keep whitespace shows the re-indentation

  @node @tui
  Scenario: A turn that changed nothing
    Given turn 2 only answered a question
    When the user opens the diff of turn 2
    Then the user is told there are no changes

  @node
  Scenario: A turn without a finished checkpoint
    Given turn 4 is still running
    When the user opens the diff of turn 4
    Then the user is told turn 4 has no checkpoint

  @tui
  Scenario: A diff that cannot be loaded says so
    Given the node cannot read the checkpoints of "Tax work"
    When the user opens the diff in the terminal client
    Then the diff viewer reports an error instead of an empty diff

  @node
  Scenario: Imported threads keep their diffs
    Given "Tax work" was imported with checkpoints made by the previous server
    When the user opens the diff of turn 2
    Then turn 2's changes are shown

  @desktop @mobile @backlog-mobile
  Scenario: Picking a turn's diff from the thread
    When the user opens the diff of the latest turn
    Then the changes of turn 3 are shown
    And the user can switch to any earlier turn or to all changes

  @desktop @mobile @backlog-mobile
  Scenario: A turn's diff that cannot be loaded can be asked for again
    Given the node cannot read the checkpoints of "Tax work"
    When the user opens the diff of the latest turn
    Then the user is told the diff could not be loaded
    When the node can read the checkpoints again
    And the user asks for the diff again
    Then the changes of turn 3 are shown

  @desktop
  Scenario: A large file's changes start collapsed and can be expanded
    Given turn 3 changed 5000 lines of "src/rates.ts"
    When the user opens the diff of the latest turn
    Then "src/rates.ts" is listed collapsed
    When the user expands "src/rates.ts" in the diff
    Then the 5000 lines of "src/rates.ts" are shown
    When the user collapses "src/rates.ts" in the diff
    Then "src/rates.ts" is listed collapsed

  @desktop
  Scenario: Every file of a diff can be collapsed and expanded at once
    When the user opens the diff of the latest turn
    And the user collapses every file in the diff
    Then only the files' headers are shown
    When the user expands every file in the diff
    Then every file's lines are shown

  @desktop
  Scenario: A diff can be shown side by side or as one column
    Given turn 3 rewrote a line of "src/cart.ts"
    When the user opens the diff of the latest turn
    And the user shows the diff side by side
    Then the removed and added line of "src/cart.ts" are shown side by side
    When the user shows the diff as one column
    Then the removed and added line of "src/cart.ts" are shown one above the other
