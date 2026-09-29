# Sources:
#   apps/desktop-qt/src/native/ThreadStore.cpp (reload)
#   apps/desktop-qt/src/native/ThreadDiff.cpp (requestRevert, confirmRevert: the one revert)
#   apps/desktop-qt/qml/HalC2/Bricks/RevertDialog.qml (Keep files, Revert files too)
#   apps/tui/src/components/ChatView.tsx (Reverted to turn N.)
#   apps/desktop-qt/src/native/TimelineModel.cpp (checkpointOf, copy)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   Shared domain: timeline/*.feature owns what the thread shows and checkpoints.feature the
#   revert itself; this file owns the Qt shell's two ways into it and the retry path.
#   centre-view.feature owns what the centre brick shows.

Feature: The desktop shell rewinds and retries a thread
  A reply's Revert and the diff panel's ask the same question and rewind the same way, and
  the shell follows a thread again after its node stopped sending it.

  Background:
    Given a connected environment with the project "shop"

  Rule: A reply and the diff panel revert the same way

    @desktop
    Scenario Outline: Either way in asks first, then keeps or restores the files
      Given a thread in "shop" with three finished turns
      When the user asks to revert to turn 1 from <where>
      And the user confirms with "<answer>"
      Then turns 2 and 3 are removed from the conversation
      And <files>
      And the user is told "Reverted to turn 1."

      Examples:
        | where          | answer           | files                                            |
        | its reply      | Keep files       | the node is asked to leave the files as they are |
        | its reply      | Revert files too | the workspace files match the end of turn 1      |
        | the diff panel | Keep files       | the node is asked to leave the files as they are |
        | the diff panel | Revert files too | the workspace files match the end of turn 1      |

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
