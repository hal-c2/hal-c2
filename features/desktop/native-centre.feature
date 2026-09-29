# Sources:
#   apps/desktop-qt/src/native/ThreadStore.cpp (reload)
#   apps/desktop-qt/src/native/ThreadDiff.cpp (requestRevert, canRevert)
#   apps/desktop-qt/src/native/TimelineModel.cpp (checkpointOf, copy)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   Shared domain: timeline/*.feature owns what the thread shows and checkpoints.feature the
#   revert itself, including the Qt shell's two ways into it; this file owns the retry path.
#   centre-view.feature owns what the centre brick shows.

Feature: The desktop shell rewinds and retries a thread
  A reply with no checkpoint offers no revert, and the shell follows a thread again after its
  node stopped sending it.

  Background:
    Given a connected environment with the project "shop"

  Rule: A reply without a checkpoint offers no revert

    # Product behaviour, kept here because timeline/checkpoints.feature's Background already
    # gives the thread three turns with checkpoints.
    @desktop
    Scenario: A reply whose turn left no checkpoint cannot be reverted to
      Given a thread in "shop" whose first turn left no checkpoint
      Then the first turn's reply offers no rewind

  Rule: A thread whose node stopped sending it can be tried again

    @desktop
    Scenario: Retrying follows the thread again once its node sends it
      Given the user is looking at a thread in "shop"
      And the agent has answered "The cart has tax."
      When the node stops sending the thread
      Then the thread says its node cannot be reached
      When the user retries the thread
      Then the thread is still unreachable
      When the node can send the thread again
      And the user retries the thread
      Then the thread follows its node again
      And the answer "The cart has tax." is still shown
