# Sources:
#   apps/mobile/src/features/threads/thread-list-v2-items.tsx (swipe actions, long-press menu)
#   apps/mobile/src/features/threads/threadListV2.ts (drag between sections)
#   apps/mobile/src/state/thread-order.ts, apps/mobile/src/features/threads/threadOrder.ts (drop labels, arrangement held until confirmed)
#   apps/mobile/src/features/threads/CustomSnoozeSheet.shared.tsx, customSnoozeDate.ts (custom snooze choice)
#   apps/mobile/src/features/home/ (dismissal restore on failure, archive blocked while running)
#   apps/mobile/src/features/archive/ArchivedThreadsScreen.tsx (Archived thread options)
#   docs/internals/mobile-navigation.md (back gesture over horizontal scroll)
#   apps/mobile/app.config.ts (Android predictive back)
#   apps/mobile/plugins/withAndroidPredictiveBackCompat
#   apps/mobile/src/lib/copyTextWithHaptic.ts, apps/mobile/src/components/CopyTextButton.tsx (copy feedback)
#   apps/mobile/src/components/ControlPillMenu.android.tsx (long press opens a menu with feedback, tap keeps working)
# The thread actions themselves are specified in features/threads/ (settle.feature,
# snooze.feature, pinning-and-order.feature). This file covers how a phone user reaches them.

Feature: Touch gestures on a phone
  Swipes and long presses reach the thread actions without opening the thread. Every swipe
  has a way back, and a swipe that fails on the environment puts the row back.

  Background:
    Given the phone is paired with an environment that supports settling threads

  @backlog @mobile
  Scenario Outline: Swiping a thread offers the action that fits its state
    Given a thread is <state>
    When the user swipes the thread to reveal its actions
    Then the main action offered is "<primary>"
    And the user is also offered to snooze it

    Examples:
      | state    | primary   |
      | active   | Settle    |
      | settled  | Un-settle |
      | snoozed  | Wake      |

  @backlog @mobile
  Scenario: A full swipe commits the main action
    Given a thread is active
    When the user swipes the thread all the way across
    Then the thread is settled

  @backlog @mobile
  Scenario: A full swipe on a settled thread un-settles it
    Given a thread is settled
    When the user swipes the thread all the way across
    Then the thread is active again

  @backlog @mobile
  Scenario: A full swipe on a snoozed thread wakes it
    Given a thread is snoozed until tomorrow
    When the user swipes the thread all the way across
    Then the thread is no longer snoozed

  @backlog @mobile
  Scenario: An environment without settling offers archive instead
    Given the environment predates settling threads
    When the user swipes an active thread to reveal its actions
    Then the main action offered is "Archive"

  @backlog @mobile
  Scenario Outline: Snoozing by swipe offers preset times
    Given a thread is active
    When the user swipes the thread and chooses to snooze it until <preset>
    Then the thread is snoozed until <preset>

    Examples:
      | preset       |
      | in 1 hour    |
      | in 3 hours   |
      | this evening |
      | tomorrow     |
      | next week    |

  @backlog @mobile
  Scenario: Snoozing by swipe accepts a custom date and time
    Given a thread is active
    When the user swipes the thread and snoozes it until a custom date and time
    Then the thread is snoozed until that date and time

  @backlog @mobile
  Scenario: The custom snooze choice starts an hour ahead or at two hours
    Given a thread is active
    When the user opens the custom snooze choice
    Then the date and time start one hour from now
    When the user switches to a duration
    Then the duration starts at 2 hours

  @backlog @mobile
  Scenario Outline: A custom snooze duration is read the way the user types it
    Given a thread is active
    When the user snoozes it for a custom duration of "<typed>" <unit>
    Then <outcome>

    Examples:
      | typed | unit    | outcome                                                    |
      | 1,5   | hours   | the thread is snoozed for 90 minutes                       |
      | 1.5   | hours   | the thread is snoozed for 90 minutes                       |
      | 0     | hours   | the user is told to enter a positive duration              |
      | soon  | days    | the user is told to enter a positive duration              |

  @backlog @mobile
  Scenario: A custom snooze date in the past is refused with a reason
    Given a thread is active
    When the user chooses a custom date and time that has already passed
    Then the thread is not snoozed
    And the user is told to choose a date and time in the future

  @backlog @mobile
  Scenario: Backing out of the snooze choice leaves the thread alone
    Given a thread is active
    When the user swipes the thread to snooze it but dismisses the choice
    Then the thread is still active

  @backlog @mobile
  Scenario: A swiped row that the environment rejects comes back
    Given the environment will reject settling the thread
    When the user swipes the thread all the way across
    Then the thread returns to its place in the list
    And the user is told the action failed

  @backlog @mobile
  Scenario: Archiving is refused while the agent is working
    Given the environment predates settling threads
    And a thread has a turn running
    When the user tries to archive the thread
    Then the thread is not archived
    And the user is told to wait for the agent or stop it first

  @backlog @mobile
  Scenario: Swipes do not trigger while the list is scrolling
    Given the user is scrolling the thread list
    When the user's finger moves sideways over a thread
    Then no thread action is revealed

  @backlog @mobile
  Scenario: A two-finger trackpad swipe reveals thread actions on a tablet
    Given the user has a trackpad attached to a tablet
    When the user swipes sideways with two fingers over a thread
    Then the thread's actions are revealed

  @backlog @mobile
  Scenario Outline: Long pressing a thread offers its actions
    Given a thread is <state>
    When the user long presses the thread
    Then the user is offered to "<action>"

    Examples:
      | state   | action                     |
      | active  | Settle                     |
      | active  | Snooze                     |
      | active  | Pin                        |
      | pinned  | Unpin                      |
      | active  | Rename                     |
      | active  | Regenerate title           |
      | active  | Copy thread ID             |
      | active  | New thread on branch       |
      | active  | Arrange threads            |
      | active  | Delete                     |
      | settled | Un-settle                  |
      | snoozed | Wake thread                |

  @backlog @mobile
  Scenario: Deleting from the long-press menu asks first
    When the user chooses to delete a thread from its long-press menu
    Then the user is asked to confirm
    When the user cancels
    Then the thread is still listed

  @backlog @mobile
  Scenario: Regenerating a title shows progress until the new title lands
    When the user asks to regenerate a thread's title
    Then the thread shows that its title is regenerating
    And the new title replaces the old one when it arrives

  @backlog @mobile
  Scenario Outline: Dragging a thread between sections changes its state
    Given a thread is <from>
    When the user drags the thread into the <to> section
    Then the thread is <result>

    Examples:
      | from    | to      | result              |
      | active  | settled | settled             |
      | pinned  | active  | unpinned            |
      | settled | active  | active again        |
      | snoozed | active  | no longer snoozed   |

  @backlog @mobile
  Scenario: Dragging within a section reorders threads
    Given two pinned threads "A" then "B"
    When the user drags "B" above "A"
    Then the pinned threads are ordered "B" then "A"

  @backlog @mobile
  Scenario Outline: A dragged thread says what dropping it will do
    Given a thread is <from>
    When the user drags the thread over the <to> section
    Then the drop is labelled "<label>"

    Examples:
      | from    | to      | label    |
      | active  | pinned  | Pin      |
      | pinned  | active  | Unpin    |
      | active  | settled | Settle   |
      | settled | active  | Unsettle |
      | snoozed | active  | Unsnooze |
      | pinned  | pinned  | Reorder  |

  @backlog @mobile
  Scenario: A thread cannot be dropped on the snoozed section
    Given a thread is active
    When the user drags the thread over the snoozed section
    Then dropping it there does nothing

  @backlog @mobile
  Scenario: A rearranged list keeps its new order until the environment confirms it
    Given two active threads "A" then "B"
    When the user drags "B" above "A"
    Then the list shows "B" then "A" at once
    And the list does not flicker back to "A" then "B" while the environment is still saving the order

  @backlog @mobile
  Scenario: Threads cannot be moved again while an arrangement is being saved
    Given the user dragged "B" above "A" and the environment has not confirmed it
    Then no thread offers to move up or down
    When the environment confirms the new order
    Then the threads offer to move up or down again

  @backlog @mobile
  Scenario: An arrangement is let go when the list changes underneath it
    Given the user dragged "B" above "A" and the environment has not confirmed it
    When another device pins "C" before the environment confirms
    Then the list shows the environment's order

  @backlog @mobile
  Scenario: Long pressing an archived thread offers to unarchive or delete it
    Given the user is looking at archived threads
    When the user long presses an archived thread
    Then the user is offered to unarchive it
    And the user is offered to delete it

  @backlog @mobile
  Scenario: Swiping from the edge goes back to the previous screen
    Given the user opened a thread from the home screen
    When the user swipes from the leading edge of the screen
    Then the home screen shows

  @backlog @mobile
  Scenario: A thread chosen while the back swipe is still finishing opens
    Given the user is swiping back from a thread to the home screen
    When the user taps another thread before the swipe has finished
    Then the tapped thread opens once the home screen has settled

  @backlog @mobile
  Scenario: Tapping a thread again while it opens does not open it twice
    Given the user taps a thread on the home screen
    When the user taps the same thread again before it has opened
    Then one thread screen is open
    And going back returns to the home screen

  @backlog @mobile
  Scenario: The back swipe wins over a sideways-scrolling code block
    Given the user is reading a thread with a wide code block scrolled to its start
    When the user swipes from the leading edge over the code block
    Then the user goes back instead of scrolling the code block

  @backlog @mobile
  Scenario: A code block scrolled away from its start still scrolls first
    Given the user is reading a thread with a wide code block scrolled to the middle
    When the user swipes toward the start over the code block
    Then the code block scrolls toward its start

  @backlog @mobile
  Scenario: Android predictive back previews the screen it returns to
    Given the user is on an Android phone with predictive back
    And the user opened a thread from the home screen
    When the user starts the system back gesture
    Then the home screen is previewed behind the thread
    When the user releases the gesture without completing it
    Then the thread stays open

  @backlog @mobile
  Scenario: A snooze time that passed while the choice was open is refused
    Given the user opened the snooze choices for a thread an hour ago
    When the user picks a snooze time that has already passed
    Then the thread is not snoozed
    And the user is told to choose another time

  @backlog @mobile
  Scenario: An environment without settling offers archive in the long-press menu
    Given the environment predates settling threads
    When the user long presses an active thread
    Then the user is offered to "Archive"
    And the user is not offered to "Settle" or "Snooze"

  @backlog @mobile
  Scenario Outline: The long-press menu of a settled thread leaves out the moves that do not apply
    Given a thread is <state>
    When the user long presses the thread
    Then the user is not offered to "Move up" or "Move down"

    Examples:
      | state   |
      | settled |
      | snoozed |

  @backlog @mobile
  Scenario Outline: Long pressing an unsent task offers to remove it
    Given the list holds <task>
    When the user long presses it
    Then the user is offered to "<action>"

    Examples:
      | task                                              | action  |
      | a task waiting to be sent when the phone reconnects | Delete  |
      | a task that was written but not started           | Discard |

  @backlog @mobile
  Scenario: A custom snooze choice is never applied to a different thread
    Given the user opened the custom snooze choice for "Fix cart"
    When "Fix cart" is deleted on another device and the list refreshes
    Then the custom snooze choice closes
    And no other thread is snoozed

  @backlog @mobile
  Scenario: Pulling down archived threads refreshes them
    Given the user is looking at archived threads
    When the user pulls down on the list
    Then the phone asks the environments for fresh archived threads

  @backlog @mobile
  Scenario: Copying text gives a light tap
    When the user copies text from the app
    Then the text is on the clipboard
    And the phone gives a light physical tap

  @backlog @mobile
  Scenario: A phone that cannot give a tap still copies
    Given the phone cannot give physical feedback
    When the user copies text from the app
    Then the text is on the clipboard

  @backlog @mobile
  Scenario: A copy the phone refuses is reported and not confirmed
    Given the phone refuses to write to the clipboard
    When the user copies text from the app
    Then the user is told "Could not copy" and to try again
    And the copy control does not show that it copied

  @backlog @mobile
  Scenario: The copy control confirms for a moment
    When the user copies text from the app with the copy control
    Then the control shows that it copied
    And a moment later it offers to copy again

  @backlog @mobile
  Scenario: A long press that opens a menu is felt and still lets the tap work
    Given the user is on an Android phone
    When the user long presses a control that offers a menu
    Then the phone gives a medium tap of feedback and the menu opens
    When the user taps the same control
    Then the control does what a tap does and no menu opens
