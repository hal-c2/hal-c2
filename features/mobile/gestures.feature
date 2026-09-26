# Sources:
#   apps/mobile/src/features/threads/thread-list-v2-items.tsx (swipe actions, long-press menu)
#   apps/mobile/src/features/threads/threadListV2.ts (drag between sections)
#   apps/mobile/src/features/home/ (dismissal restore on failure, archive blocked while running)
#   apps/mobile/src/features/archive/ArchivedThreadsScreen.tsx (Archived thread options)
#   docs/internals/mobile-navigation.md (back gesture over horizontal scroll)
#   apps/mobile/app.config.ts (Android predictive back)
#   apps/mobile/plugins/withAndroidPredictiveBackCompat
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
  Scenario: Pulling down archived threads refreshes them
    Given the user is looking at archived threads
    When the user pulls down on the list
    Then the phone asks the environments for fresh archived threads
