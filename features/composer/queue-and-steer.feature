# Sources:
#   https://github.com/pingdotgg/t3code/pull/27310
#   https://github.com/pingdotgg/t3code/pull/23240
#   https://github.com/pingdotgg/t3code/pull/24248
#   https://github.com/pingdotgg/t3code/pull/25232
#   https://github.com/pingdotgg/t3code/pull/24972
#   https://github.com/pingdotgg/t3code/pull/25128
#   https://github.com/pingdotgg/t3code/pull/19007
#   https://github.com/pingdotgg/t3code/pull/18999
#   https://github.com/pingdotgg/t3code/pull/20929
#   https://github.com/pingdotgg/t3code/pull/18834
#   https://github.com/pingdotgg/t3code/pull/22790
#   docs/user/composer.md (follow-up behaviour, queued messages, editing a queued message)
#   apps/server-ex/lib/hal_c2/orchestration.ex (queued runs, steer, restart dispatch, queue hold)
#   apps/web/src/components/chat/QueuedRunsControl.tsx
#   apps/web/src/components/chat/ComposerPrimaryActions.tsx (queue, steer, stop)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (stop while running, steer or queue, mod+Enter)
#   apps/desktop-qt/tests/tst_Composer.qml
#   apps/desktop-qt/src/native/ComposerController.cpp (the queue in the turn, cancel, steer and edit)
#   apps/desktop-qt/qml/HalC2/Bricks/TurnRequests.qml (the queue card, a queued message's attachments)
#   apps/web/src/session-logic.ts (getUserQueuedThreadRuns: the agent's own queued runs are not the user's)
#   apps/tui/src/components/ChatView.tsx (Esc interrupts)
#   apps/tui/qml/HalC2/Tui/ShellKeymap.qml (a held Esc does not repeat)
#   apps/tui/qml/HalC2/Tui/Timeline.qml (the held queue, ^X q and the palette resume it)
#   packages/shared/src/keybindings.ts (composer.sendAlternate, thread.steerQueuedMessage, thread.editQueuedMessage)
#   packages/contracts/src/orchestrationV2.ts (queued-run.cancel, queued-run.edit, queued-run.reorder, queued-message.promote-to-steer, queue.resume, run.interrupt)
#   packages/contracts/src/settings.ts (followUpBehavior)
#   https://github.com/pingdotgg/t3code/pull/14725
#   https://github.com/pingdotgg/t3code/pull/15417
#   https://github.com/pingdotgg/t3code/pull/25468
#   https://github.com/pingdotgg/t3code/pull/25593
#   https://github.com/pingdotgg/t3code/pull/25426
#   https://github.com/pingdotgg/t3code/pull/25169
#   https://github.com/pingdotgg/t3code/pull/25846
#   https://github.com/pingdotgg/t3code/pull/25837
#   https://github.com/pingdotgg/t3code/pull/26159
#   https://github.com/pingdotgg/t3code/pull/26355
#   https://github.com/pingdotgg/t3code/pull/25877
#   https://github.com/pingdotgg/t3code/pull/21594

Feature: Follow-ups while the agent is working
  A message sent while a turn is running either waits in the queue or steers
  the running turn. Queued messages can be reordered, edited, promoted and
  removed, and the user can always stop the running turn.

  Background:
    Given a thread whose agent is working on a turn

  @mc
  Scenario: A message sent to the queue during a turn waits for the thread to be idle
    When the user queues "also update the docs"
    Then "also update the docs" is queued behind the running turn
    And it starts once the thread is idle

  @mc
  Scenario Outline: Steering joins the running turn only where the provider can take it
    Given the thread runs on <provider>
    When the user steers the running turn with "use the new API"
    Then <outcome>

    Examples:
      | provider | outcome                                                                  |
      | Codex    | the running turn receives "use the new API"                              |
      | Claude   | the running turn receives "use the new API"                              |
      | OpenCode | the running turn receives "use the new API"                              |
      | Grok     | the running turn is interrupted and "use the new API" runs next          |

  @mc
  Scenario: A steer the provider rejects is refused, not quietly queued
    Given the provider rejects the steer
    When the user tries to steer the running turn with "stop and summarize"
    Then the user is told the provider did not take the message
    And "stop and summarize" is neither queued nor part of the running turn
    And the running turn keeps working

  @mc
  Scenario: Restarting with a message interrupts the turn and runs the message next
    Given "later" is queued
    When the user restarts the turn with "start over with tests first"
    Then the running turn is interrupted
    And "start over with tests first" runs before "later"

  @desktop
  Scenario Outline: The follow-up setting decides what sending during a turn does
    Given the follow-up behaviour setting is "<setting>"
    When the user <action> "<message>"
    Then "<message>" <outcome>

    Examples:
      | setting | action                    | message | outcome                     |
      | queue   | sends                     | tweak   | is queued                   |
      | queue   | sends the opposite way    | tweak   | steers the running turn     |
      | steer   | sends                     | tweak   | steers the running turn     |
      | steer   | sends the opposite way    | tweak   | is queued                   |

  # Upstream #20929: when sending needs Mod+Enter, Mod+Enter follows the follow-up setting
  # and Mod+Shift+Enter sends the opposite way.
  @desktop
  Scenario Outline: Sending with Mod+Enter during a turn follows the follow-up setting
    Given the send shortcut setting is "Mod+Enter"
    And the follow-up behaviour setting is "<setting>"
    When the user presses <keys> with "tweak" typed during a turn
    Then "tweak" <outcome>

    Examples:
      | setting | keys            | outcome                 |
      | steer   | Mod+Enter       | steers the running turn |
      | steer   | Mod+Shift+Enter | is queued               |
      | queue   | Mod+Enter       | is queued               |
      | queue   | Mod+Shift+Enter | steers the running turn |

  @mobile @priority-high
  Scenario: The phone sends a follow-up the other way than its setting
    Given the follow-up behaviour setting is "queue"
    When the user sends "tweak" the opposite way from the phone
    Then "tweak" steers the running turn

  @mc
  Scenario: Reordering the queue changes what runs next
    Given "a", "b" and "c" are queued in that order
    When the user moves "c" before "a"
    Then the queue order is "c", "a", "b"

  @mc
  Scenario: Editing a queued message replaces its text before it runs
    Given "fix typo" is queued
    When the user edits it to "fix all typos"
    Then the queued message reads "fix all typos"
    And it keeps its place in the queue

  # Upstream #25877: loading a long queued message into the composer pushed the chat column out
  # of place, leaving the composer mid-screen.
  @backlog @desktop @priority-low
  Scenario: Editing a long queued message keeps the composer at the bottom
    Given a turn is running and a long message is queued
    When the user chooses to edit the queued message
    Then the composer stays at the bottom of the window
    And only the conversation scrolls

  @desktop
  Scenario: Editing the last queued message from the composer and cancelling restores the prior draft
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    Then the composer holds "fix typo"
    When the user cancels the edit
    Then the composer holds "unrelated draft" again
    And the queued message still reads "fix typo"

  @mc
  Scenario Outline: Promoting a queued message steers the running turn
    Given the thread runs on <provider>
    And "check the logs" is queued
    When the user promotes it to a steer
    Then <outcome>
    And "check the logs" is no longer waiting in the queue

    Examples:
      | provider | outcome                                                          |
      | Codex    | the running turn receives "check the logs"                       |
      | Claude   | the running turn receives "check the logs"                       |
      | OpenCode | the running turn receives "check the logs"                       |
      | Grok     | the running turn is interrupted and "check the logs" runs next   |

  @mc
  Scenario: Removing a queued message cancels it
    Given "never mind" is queued
    When the user removes it from the queue
    Then "never mind" never runs

  @mc
  Scenario: The queue is held after an MC restart until the user resumes it
    Given "later" was queued when the MC restarted
    When the MC comes back
    Then the queue is held and "later" does not start on its own
    When the user resumes the queue
    Then "later" starts

  @desktop
  Scenario: Stopping the running turn from an empty composer
    Given the composer is empty
    When the user chooses to stop
    Then the running turn is interrupted

  @desktop
  Scenario: A shortcut bound to stop interrupts the running turn
    Given "thread.stop" is bound to mod+shift+.
    When the user presses mod+shift+.
    Then the running turn is interrupted

  @tui
  Scenario: Escape clears the draft first, then stops the turn
    Given the user has typed "wait"
    When the user presses Escape
    Then the draft is empty
    And the turn is still running
    When the user presses Escape again
    Then the running turn is interrupted

  @tui
  Scenario: Holding Escape to close a picker leaves the turn running
    When the user clicks "All projects"
    And the user holds Escape
    Then the turn is still running

  @desktop
  Scenario: Queued messages are listed in the order they run
    Given "check the logs" and "update the docs" are queued
    Then the composer lists the queued messages "check the logs" and "update the docs"

  # Upstream #18999: queued follow-ups that quote the agent show the quoted text, not the citation link.
  # Upstream #19007: the phone's queue sheet shows the quote as text too.
  @backlog @desktop @mobile
  Scenario: A queued message that quotes the agent shows the quoted words
    Given the user queued a message quoting "the cart total is wrong" from the agent's reply
    Then the queued message reads "the cart total is wrong", not a link
    And editing it gives back the message with its quote

  @desktop
  Scenario Outline: What the MC queued for the agent itself waits under what it stands for
    Given "check the logs" is queued
    And the MC queued <its own> for the agent
    Then the composer lists only the queued message "check the logs"
    And the composer shows "<summary>" waiting behind it

    Examples:
      | its own                                                            | summary                     |
      | a delegated task's result                                          | Tax tests finished          |
      | a delegated task's result stored before results were notifications | Tax tests finished          |
      | the agent's own wake-up                                            | Background activity updated |

  @desktop
  Scenario: Removing a queued message cancels its run
    Given "check the logs" and "update the docs" are queued
    When the user removes "check the logs" from the queue
    Then the MC is asked to cancel the queued run of "check the logs"

  @desktop
  Scenario: A removal the MC refuses is reported
    Given "check the logs" and "update the docs" are queued
    And the MC refuses "queued-run.cancel" with "run already started"
    When the user removes "check the logs" from the queue
    Then the user sees an "error" toast "Failed to remove the queued message." saying "run already started"

  @desktop
  Scenario: A queued message can steer the running turn
    Given "check the logs" and "update the docs" are queued
    When the user steers the running turn with the queued "update the docs"
    Then the MC is asked to steer the running turn with the queued run of "update the docs"

  @desktop
  Scenario: A steer the MC refuses is reported
    Given "check the logs" and "update the docs" are queued
    And the MC refuses "queued-message.promote-to-steer" with "provider cannot steer"
    When the user steers the running turn with the queued "update the docs"
    Then the user sees an "error" toast "Failed to steer with the queued message." saying "provider cannot steer"

  @desktop
  Scenario: Saving an edited queued message changes it and gives the draft back
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    And the user sends "fix all typos" from the composer
    Then the MC is asked to change the queued run of "fix typo" to "fix all typos"
    And the composer holds "unrelated draft" again

  # Upstream #25169: starting or ending an edit let a second save go out while the first was
  # still on its way, and the older one could land last.
  @shared @backlog-tui @priority-high
  Scenario: A second save of a queued message waits for the first
    Given "fix typo" is queued
    And the user saved "fix all typos" over it and the MC has not answered yet
    When the user edits it again and saves "fix every typo"
    Then "fix every typo" is sent only after the MC answered the first save
    And the queued message ends as "fix every typo"

  @desktop
  Scenario: An edit the MC refuses stays in the composer
    Given "fix typo" is queued
    And the MC refuses "queued-run.edit" with "run already started"
    When the user starts editing the last queued message from the start of the composer
    And the user sends "fix all typos" from the composer
    Then the user sees an "error" toast "Could not save the edited queued message." saying "run already started"
    And the composer holds "fix all typos"

  @desktop
  Scenario: An edit whose message starts running is kept when the draft was empty
    Given "fix typo" is queued
    When the user starts editing the last queued message from the start of the composer
    And the user changes the edit to "fix all typos"
    And the queued run of "fix typo" starts
    Then the user sees an "info" toast "Queued message is no longer queued" saying "Your unsaved edit was kept in the composer."
    And the composer holds "fix all typos"

  @desktop
  Scenario: An edit whose message starts running is dropped when the draft had text
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    And the user changes the edit to "fix all typos"
    And the queued run of "fix typo" starts
    Then the user sees a "warning" toast "Queued message is no longer queued" saying "Your unsaved edit was discarded."
    And the composer holds "unrelated draft" again

  @desktop
  Scenario: A queued message's attachments are listed and open full size
    Given "fix typo" is queued with the file "notes.md"
    Then the queue shows "notes.md" on "fix typo"
    When the user opens "notes.md" from the queue
    Then the attachment viewer shows "notes.md"

  @desktop
  Scenario: Editing a queued message can drop its attachments
    Given "fix typo" is queued with the file "notes.md"
    When the user starts editing the last queued message from the start of the composer
    Then the composer lists the attachment "notes.md"
    When the user removes the attachment "notes.md"
    And the user sends "fix typo" from the composer
    Then the MC is asked to change the queued run of "fix typo" to "fix typo" without attachments

  # Upstream #18834: references picked while editing a queued message stay with that message
  @backlog @desktop @mobile
  Scenario: A reference picked while editing a queued message is saved with it
    Given the user is editing a queued message
    When the user adds a reference to pull request 42 and saves the edit
    Then the queued message carries the reference to pull request 42
    And the composer's own draft does not

  # Replaced by "Leaving the thread keeps the edit" below (upstream #24972).
  @dropped @desktop
  Scenario: Leaving the thread ends the edit
    Given "fix typo" is queued
    And the user has typed "unrelated draft"
    When the user starts editing the last queued message from the start of the composer
    And the user switches to thread B and back to thread A
    Then the composer holds "unrelated draft" again
    And the queued message still reads "fix typo"

  # Upstream #24972: leaving the thread dropped an open edit of a queued message.
  # Replaces the scenario above.
  @desktop @mobile @backlog-mobile
  Scenario: Leaving the thread keeps the edit
    Given "fix typo" is queued
    When the user starts editing the last queued message from the start of the composer
    And the user changes the edit to "fix all typos"
    And the user switches to thread B and back to thread A
    Then the user is still editing the queued message, reading "fix all typos"

  # Upstream #25128: a slow save from before leaving the thread ended the edit begun after
  # coming back, and cleared its draft.
  @desktop @mobile @backlog-mobile
  Scenario: A save that finishes after a newer edit began leaves the newer edit alone
    Given the user saved "fix all typos" over the queued "fix typo" and the MC has not answered yet
    And the user switched to thread B and back to thread A
    When the user edits the queued message again to "fix every typo"
    And the first save finishes
    Then the user is still editing the queued message, reading "fix every typo"

  # Upstream #25468: a queued edit ends when its run leaves the queue, even with its thread closed.
  # Upstream #24972: the same on the desktop, and the message names the thread.
  @desktop @mobile @backlog-mobile
  Scenario: An edit whose message starts while its thread is closed ends then
    Given the user is editing the queued "fix typo" with a change
    And the user has gone to another thread
    When the queued run of "fix typo" starts
    Then the edit has ended
    And the changed edit waits in the thread's composer if it was empty, with a message naming the thread

  # Upstream #25468: an unchanged edit whose run starts closes without a message.
  # Upstream #25232: the phone discards an untouched queued edit when its run starts.
  @desktop @mobile @backlog-mobile @priority-low
  Scenario: An unchanged edit whose message starts running closes quietly
    Given "fix typo" is queued
    When the user starts editing the last queued message from the start of the composer
    And the queued run of "fix typo" starts
    Then the edit has ended
    And no message about the edit is shown

  # Upstream #25468: deleting the thread ends its open queued edit.
  @desktop @mobile @backlog-mobile
  Scenario: Deleting a thread ends its queued edit
    Given the user is editing a queued message in thread A
    When thread A is deleted
    Then the edit has ended

  # Upstream #25593: editing a queued message is unavailable while the agent's question is open.
  @desktop @mobile @priority-high
  Scenario: A queued message cannot be edited while a question is open
    Given "fix typo" is queued
    And the agent has asked the user a question
    Then editing "fix typo" is unavailable, saying "Answer the question to edit queued messages"
    And the edit-latest shortcut does nothing

  # Upstream #25593: an edit already open when a question arrives comes back once it is answered.
  @desktop @mobile @backlog-mobile
  Scenario: An edit open when a question arrives comes back after the answer
    Given the user is editing the queued "fix typo"
    When the agent asks which database to use
    And the user answers it
    Then the user is editing the queued "fix typo" again

  @desktop @priority-high
  Scenario Outline: The send control says what sending will do
    Given the draft reads "tweak"
    And <situation>
    Then the send control is named "<name>"

    Examples:
      | situation                                                   | name                  |
      | the running turn has finished                               | Submit message        |
      | a turn is running and the follow-up behaviour is "steer"    | Steer message         |
      | a turn is running and the follow-up behaviour is "queue"    | Queue message         |
      | the user is editing a queued message                        | Update queued message |

  @backlog @desktop
  Scenario: The send control says how to send the other way
    Given the follow-up behaviour setting is "queue"
    And the draft reads "tweak"
    When the user rests on the send control
    Then the user reads that a click queues and a Ctrl or Cmd click steers
    When the user holds Ctrl or Cmd
    Then the send control is named "Steer message"

  @backlog @desktop
  Scenario Outline: A send control that cannot be used says why
    Given the draft reads "tweak"
    And <situation>
    Then the send control cannot be used and says "<reason>"

    Examples:
      | situation                                      | reason                   |
      | the environment is disconnected                | Environment disconnected |
      | the environment is still connecting            | Connecting               |
      | the thread's worktree is still being prepared  | Preparing worktree       |
      | the message is on its way to the MC            | Submitting message       |
      | a queued message's edit is being saved         | Updating queued message  |

  @desktop
  Scenario: A running turn with nothing to send offers only Stop
    Given the composer is empty
    Then the send control is replaced by a control that stops the turn
    When the user types "tweak" into the composer
    Then the send control is back

  @desktop @priority-low
  Scenario: The queue can be folded away and says how much it holds
    Given "a" and "b" are queued
    Then the queue is headed "Queued" with the count 2
    When the user folds the queue away
    Then "a" and "b" are hidden and the count is still shown

  @desktop @priority-high
  Scenario: A queued message is listed before the MC confirms it
    Given the MC has not yet confirmed a message the user queued
    Then the message is listed in the queue as being saved
    And it cannot be edited, reordered, steered or removed until the MC confirms it

  # Upstream #25846: reordering left the web and phone queues (drag, arrow keys, move up and
  # down); it was not worth its weight. The MC's reorder command and the agents' queue tool
  # keep it, so old event logs replay.
  @dropped @desktop
  Scenario: A queued message is moved with the arrow keys
    Given "a", "b" and "c" are queued in that order
    When the user focuses the handle of "c" and presses Up twice
    Then the queue order is "c", "a", "b"

  # Upstream #25846: a queued message offers Send now first, then edit and remove; no position
  # numbers and no way to reorder it.
  @shared @backlog-tui @priority-high
  Scenario: A queued message offers to send it now, edit it or remove it
    Given "a" and "b" are queued
    When the user looks at "b" in the queue
    Then the user is offered to send "b" now, to edit it and to remove it
    And the user is not offered to move "b" in the queue

  # Upstream #26355: a message sent now from the queue showed both in the turn and still in the
  # queue, and queued messages showed in the timeline before they were sent.
  @mc @shared @backlog-desktop @backlog-mobile @backlog-tui @priority-high
  Scenario: A queued message sent now is shown once
    Given "a", "b" and "c" are queued while a turn runs
    When the user sends "a" now and then sends "b" now
    Then "a" and "b" are each shown once in the conversation and no longer in the queue
    And "c" is still queued and not shown in the conversation

  # Upstream #26355: a message that went back to the queue can be sent now again.
  @backlog @mc @shared
  Scenario: A queued message that returned to the queue can be sent now again
    Given the user sent "a" now from the queue and it went back to the queue
    When the user sends "a" now again
    Then "a" is shown once in the conversation and no longer in the queue

  # Upstream #25846: Send now is offered only when it can send.
  @backlog @shared
  Scenario: Send now is not offered when the message cannot be sent now
    Given "a" is queued
    And the provider can neither take a steer nor be stopped for "a"
    Then the user is not offered to send "a" now

  # Upstream #25837: Send now during a compaction is offered even where the provider cannot
  # steer, and skips the compaction.
  @backlog @shared @priority-high
  Scenario: Send now during a compaction offers to skip it
    Given the thread is compacting its context and "a" is queued
    Then the user is offered to skip the compaction and send "a"

  # Upstream #27310: a message queued by Compact and send could not be edited until the
  # compaction ended, and then went out with its old text.
  @backlog @desktop @priority-high
  Scenario: A message queued by Compact and send can be edited while the compaction runs
    Given the user chose "Compact and send" for "a" on a stale thread
    When the user edits the queued "a" to "b" while the compaction runs
    Then the edit is saved at once
    And "b" is sent once the compaction ends

  # Upstream #26159: queued messages say who sent them, as sent messages do.
  @backlog @shared
  Scenario Outline: A queued message says who sent it
    Given <sender> queued "a"
    Then the queued "a" <presentation>

    Examples:
      | sender                      | presentation                                                 |
      | an automation               | is folded to one line naming the automation, and can open it |
      | the agent of another thread | is folded to one line naming that thread, and can open it    |
      | HAL-C2 itself               | says "Sent by HAL-C2"                                        |
      | a guest                     | shows the guest's name                                       |

  # Upstream #26159: every queued message shows when it was queued.
  @backlog @shared @priority-low
  Scenario: A queued message shows when it was queued
    Given "a" is queued
    When the user rests on "a" in the queue
    Then the user sees when "a" was queued

  # Upstream #22790: a stopped thread offers Send now on a held queued message instead of a
  # disabled Steer; a running thread keeps Steer.
  @shared @backlog-tui @priority-high
  Scenario: A queued message on a stopped thread is offered to send now
    Given "a", "b" and "c" are queued and held, and the turn is no longer running
    When the user looks at "b" in the queue
    Then the user is offered to send "b" now instead of steering it

  # Upstream #22790: sending a held queued message now starts that message first.
  @mc @priority-high
  Scenario: Sending a held queued message now starts it and keeps the rest in order
    Given "a", "b" and "c" are queued and held, and the turn is no longer running
    When the user sends "b" now
    Then a turn starts with "b"
    And the queue holds "a" then "c"

  # Upstream #22790: a send now that races a turn that started meanwhile leaves the message queued.
  @mc
  Scenario: Sending a queued message now after another turn started keeps it queued
    Given "a" and "b" are queued and held, and the turn is no longer running
    And another turn starts before the MC handles the user's request
    When the user's request to send "b" now arrives
    Then "b" stays queued
    And no second turn is started

  # Upstream #22790: the steer-queued-message shortcut acts on the selected message whether or
  # not a turn is running.
  # Upstream #24248: the keybindings guide now says mod+Shift+Enter sends the first queued message when the thread is stopped.
  @backlog @desktop
  Scenario: The steer shortcut sends the selected queued message now on a stopped thread
    Given "a" and "b" are queued and held, and the turn is no longer running
    And "b" is selected in the queue
    When the user presses the shortcut that steers the queued message
    Then a turn starts with "b"

  @desktop @priority-high
  Scenario: One queue action at a time
    Given "a" and "b" are queued
    When the user removes "a" and the MC has not answered yet
    Then "b" cannot be edited, steered or removed until it has

  @desktop
  Scenario: A queued message being edited is marked in the queue
    Given "fix typo" is queued with an image
    When the user starts editing it in the composer
    Then the queue marks "fix typo" as being edited and offers to cancel the edit

  @desktop @tui
  Scenario: A held queue says its messages are safe
    Given "later" was queued when the MC restarted
    When the MC comes back
    Then the queue is headed "Queue held" and says "Messages stay saved until you resume."

  @desktop @tui
  Scenario: A held queue is resumed from the composer
    Given "later" was queued when the MC restarted
    And the MC comes back
    When the user resumes the queue
    Then the MC is asked to resume the queue

  @desktop
  Scenario: A resume that the MC refuses is reported
    Given "later" was queued when the MC restarted
    And the MC comes back
    And the MC refuses "queue.resume" with "thread is archived"
    When the user resumes the queue
    Then the user sees an "error" toast "Failed to resume the queue." saying "thread is archived"

  @desktop
  Scenario: A resume while reconnecting is refused with a warning
    Given "later" was queued when the MC restarted
    And the MC comes back
    And the MC stops accepting connections
    And the MC drops the connection
    When the user resumes the queue
    Then the user sees a "warning" toast "Not connected: queue not resumed" saying "Reconnecting to the environment. Try again once it is connected."
    And the MC is not asked to resume the queue
    When the user resumes the queue
    Then the user sees the toast "Not connected: queue not resumed" once

  @desktop
  Scenario: A resume warning dismissed and shown again is one fresh warning
    Given "later" was queued when the MC restarted
    And the MC comes back
    And the MC stops accepting connections
    And the MC drops the connection
    When the user resumes the queue
    Then the user sees the toast "Not connected: queue not resumed" once
    When the user dismisses the toast "Not connected: queue not resumed"
    And the user resumes the queue
    Then the user sees the toast "Not connected: queue not resumed" once
    And the MC is not asked to resume the queue

  @desktop
  Scenario: A held queue that only waits on the provider can be resumed
    Given a provider wake was queued when the MC restarted
    When the MC comes back
    Then the queue is headed "Queue held" and says "Messages stay saved until you resume."
    When the user resumes the queue
    Then the MC is asked to resume the queue

  # The terminal's other route: ^X q is "the user resumes the queue" above.
  @tui
  Scenario: A held queue is resumed from the terminal's command palette
    Given "later" was queued when the MC restarted
    When the MC comes back
    Then the queue is shown as held
    When the user resumes the queue from the command palette
    Then the MC is asked to resume the queue

  # Upstream #14725: steers keep the newest next-turn selection
  @mc @priority-high
  Scenario: Steers keep the newest next-turn selection
    Given a provider that steers live but cannot restart the turn
    When the user steers with one model or thinking level, then steers back to the running one
    Then the saved next-turn selection is the newest choice
    And a steer that misses the turn starts the follow-up on that choice

  # Upstream #23240: steering with a queued message used the thread's old model, not the one
  # picked when the message was queued.
  @mc @priority-high
  Scenario: Steering with a queued message keeps the model picked for it
    Given the thread runs on Codex
    And the user picked Claude and queued "use the new API"
    When the user steers with the queued "use the new API"
    Then Claude answers "use the new API"
    And the thread stays on Claude

  # Upstream #15417: removing a queued message on mobile is tappable
  @mobile @priority-high
  Scenario: A queued message can be removed on the phone
    When the user removes a queued message on the phone
    Then the queued message is cancelled

  # Blocked on the MC driving goals at all: "/goal drives Codex's own goal"
  # (providers/codex.feature) and "Claude's goal shows as a work state"
  # (providers/claude.feature) have to land first.
  @blocked
  Rule: A goal command takes over the running turn on Codex and Claude

    # Upstream #25426: a new goal, or /goal resume, sent into a running turn stops it and runs first.
    @backlog @mc @shared @plugin-codex @plugin-claude @priority-high
    Scenario Outline: A goal sent while the agent works stops the turn and runs first
      Given the thread runs on <provider>
      When the user sends "<command>" from the composer, the queue's Steer or a HAL-C2 tool
      Then the running turn stops
      And "<command>" runs next, ahead of the rest of the queue

      Examples:
        | provider | command            |
        | Codex    | /goal ship the fix |
        | Codex    | /goal resume       |
        | Claude   | /goal ship the fix |

    # Upstream #25426: clear and pause stop only a turn the goal drives.
    @backlog @mc @plugin-codex @plugin-claude
    Scenario Outline: Clearing or pausing a goal stops only the goal's own turn
      Given the thread runs on Codex
      And <turn>
      When the user sends "<command>"
      Then <outcome>

      Examples:
        | turn                                          | command     | outcome                                  |
        | the goal drives the running turn              | /goal clear | the running turn stops                   |
        | the goal drives the running turn              | /goal pause | the running turn stops                   |
        | a turn the user started is running            | /goal clear | the running turn keeps working           |
        | the turn is only finishing its background work | /goal clear | the background work keeps running        |

    # Upstream #25426: an explicit queue still queues a goal.
    @backlog @mc
    Scenario: A goal the user queues on purpose waits its turn
      When the user queues "/goal ship the fix"
      Then "/goal ship the fix" is queued behind the running turn

    # Upstream #25426: a goal on any other provider keeps the old behaviour.
    @backlog @mc @priority-low
    Scenario: A goal on another provider does not stop the turn
      Given the thread runs on OpenCode
      When the user sends "/goal ship the fix"
      Then the running turn keeps working

    # Upstream #25426: the goal's Clear stays available while the agent works; Resume waits.
    @backlog @shared
    Scenario: A goal can be cleared while the agent works
      Given the agent is working toward a goal
      Then the user can clear the goal
      And resuming a paused goal waits until the turn ends

    # Upstream #25426: setting or clearing a goal is not echoed back as a reply.
    @backlog @mc @shared @plugin-codex @plugin-claude
    Scenario: Setting or clearing a goal shows its state, not an echoed reply
      When the user sets a goal and later clears it
      Then the thread shows the goal's state
      And no "Goal set", "Goal cleared" or "Goal paused" reply appears in the conversation
      And "No goal set" still answers a goal command with nothing to act on

    # Upstream #21594: a goal's token count just under a million read "1000k".
    @backlog @shared @priority-low
    Scenario Outline: A goal's token count is rounded before its unit is picked
      Given the agent is working toward a goal with a budget of 2,000,000 tokens
      When the goal has used <used> tokens
      Then the goal reads "<shown> / 2m tokens"

      Examples:
        | used      | shown |
        | 999,499   | 999k  |
        | 999,500   | 1m    |
        | 1,000,000 | 1m    |
