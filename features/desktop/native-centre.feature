# Sources:
#   apps/desktop-qt/src/native/ThreadDiff.cpp (requestRevert, canRevert)
#   apps/desktop-qt/src/native/TimelineModel.cpp (checkpointOf, copy)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   Shared domain: timeline/*.feature owns what the thread shows (streaming.feature the retry)
#   and checkpoints.feature the revert itself, including the Qt shell's two ways into it.
#   centre-view.feature owns what the centre brick shows.

Feature: The desktop shell offers no rewind without a checkpoint
  A reply with no checkpoint offers no revert.

  Background:
    Given a connected environment with the project "shop"

  Rule: A reply without a checkpoint offers no revert

    # Product behaviour, kept here because timeline/checkpoints.feature's Background already
    # gives the thread three turns with checkpoints.
    @desktop
    Scenario: A reply whose turn left no checkpoint cannot be reverted to
      Given a thread in "shop" whose first turn left no checkpoint
      Then the first turn's reply offers no rewind
