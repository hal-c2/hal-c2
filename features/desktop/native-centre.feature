# Sources:
#   apps/desktop-qt/src/native/ThreadStore.cpp (reload, revert)
#   apps/tui/src/components/ChatView.tsx (Reverted to turn N.)
#   apps/desktop-qt/src/native/TimelineModel.cpp (checkpointOf, copy)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/desktop-qt/src/native/ThreadDiff.cpp (the diff panel's revert, whose toasts these match)
#   Shared domain: timeline/*.feature owns what the thread shows; this file owns the Qt shell's
#   rewind and retry paths. centre-view.feature owns what the centre brick shows.

Feature: The desktop shell rewinds and retries a thread
  The shell's thread store rewinds a thread to a reply's checkpoint through its node and
  follows a thread again after its node stopped sending it.

  Background:
    Given a connected environment with the project "shop"

  Rule: A reply's turn can be reverted to

    @desktop
    Scenario: Reverting can keep the files as they are
      Given a thread in "shop" whose three turns each left a checkpoint
      When the user rewinds the conversation to turn 1 and keeps the files
      Then the replies of turns 2 and 3 are gone
      And the node is asked to leave the files as they are
      And the user is told "Reverted to turn 1."

    @desktop
    Scenario: A revert the node refuses says why and keeps the turns
      Given a thread in "shop" whose three turns each left a checkpoint
      And the node refuses rewinds with "Interrupt the current turn before rewinding."
      When the user reverts to turn 1 from its reply
      Then the user sees an "error" toast "Could not revert to turn 1" saying "Interrupt the current turn before rewinding."
      And the conversation still has its three turns

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
