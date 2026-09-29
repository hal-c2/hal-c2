# Sources:
#   apps/desktop-qt/src/native/ThreadStore.cpp (reload, revert)
#   apps/tui/src/components/ChatView.tsx (Reverted to turn N.)
#   apps/desktop-qt/src/native/TimelineModel.cpp (checkpointOf, copy)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/components/ChatView.tsx (Failed to revert thread state.)
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
      Given a thread in "shop" with three finished turns
      When the user rewinds the conversation to turn 1 and keeps the files
      Then turns 2 and 3 are removed from the conversation
      And the node is asked to leave the files as they are
      And the user is told "Reverted to turn 1."

    @desktop
    Scenario: A revert the node refuses says why and keeps the turns
      Given a thread in "shop" with three finished turns
      And the node refuses rewinds with "Interrupt the current turn before rewinding."
      When the user reverts the thread to the checkpoint after turn 1
      Then the user sees an "error" toast "Failed to revert thread state." saying "Interrupt the current turn before rewinding."
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
