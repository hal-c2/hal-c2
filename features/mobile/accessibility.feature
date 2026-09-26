# Sources:
#   apps/mobile/src/features/threads/thread-list-v2-items.tsx (swipe accessibility hint)
#   apps/mobile/src/features/threads/ThreadArrangementSheet.tsx (Move up and Move down actions)
#   apps/mobile/src/features/home/thread-swipe-actions.tsx
#   apps/mobile/src/features/threads/ThreadQueueControl.tsx
#   apps/mobile/src/features/voice-input/ComposerDictationControl.tsx
#   apps/mobile/src/components/SegmentedControl.tsx (font scaling limits)
#   apps/mobile/src/features/usage/UsageRouteScreen.tsx (range labels read in full)
#   apps/mobile/src/features/settings/appearance/
# Desktop and TUI accessibility are specified with their domains. This file covers screen
# readers, text size and motion on phones and tablets.

Feature: Accessibility on phones and tablets
  Everything a sighted touch user can do is reachable with a screen reader, a larger text
  size, or reduced motion, without hidden gestures being the only way in.

  @backlog @mobile
  Scenario: A thread row announces its title, project and status
    Given the thread "Fix checkout" in "shop" is waiting for approval
    When a screen reader focuses the thread
    Then it announces "Fix checkout", "shop" and that the thread needs approval

  @backlog @mobile
  Scenario: A thread row explains its swipe actions to a screen reader
    Given an active thread
    When a screen reader focuses the thread
    Then it hints that the thread opens and that settle and snooze actions are available

  @backlog @mobile
  Scenario Outline: Swipe actions are offered as screen reader actions
    Given a thread is <state>
    When a screen reader user opens the thread's actions
    Then "<action>" is offered without swiping

    Examples:
      | state   | action    |
      | active  | Settle    |
      | active  | Snooze    |
      | settled | Un-settle |
      | snoozed | Wake      |

  @backlog @mobile
  Scenario: Threads can be reordered without dragging
    Given the user is arranging threads with a screen reader
    When the user chooses "Move up" on the second pinned thread
    Then it becomes the first pinned thread

  @backlog @mobile
  Scenario: Queued messages can be reordered and removed without dragging
    Given two messages are queued
    When a screen reader user opens the actions for the second queued message
    Then the user is offered to move it, steer with it or remove it

  @backlog @mobile
  Scenario Outline: Controls read their full meaning, not their short label
    When a screen reader focuses the usage range "<short>"
    Then it announces "<spoken>"

    Examples:
      | short | spoken         |
      | 24h   | Past 24 hours  |
      | 7d    | Past 7 days    |
      | 90d   | Past 90 days   |

  @backlog @mobile
  Scenario: Upload state is announced on attachments
    Given an attachment is uploading
    When a screen reader focuses the attachment
    Then it announces the attachment name and that it is uploading

  @backlog @mobile
  Scenario: A failed upload offers retry to a screen reader
    Given an attachment failed to upload
    When a screen reader focuses the attachment
    Then it hints that the upload can be retried

  @backlog @mobile
  Scenario: Dictation state is announced
    Given a screen reader is on
    When the user starts dictating
    Then the screen reader announces that recording started
    And the user can cancel dictation from the screen reader

  @backlog @mobile
  Scenario: Messages grow with the system text size
    Given the user set the system text size to the largest accessibility size
    When the user reads a thread
    Then message text is shown at the larger size
    And no message text is cut off

  @backlog @mobile
  Scenario: Compact controls stay usable at large text sizes
    Given the user set the system text size to the largest accessibility size
    When the user looks at a segmented choice such as the usage range
    Then every option stays readable and tappable

  # New behaviour: the React Native app does not guarantee this today.
  @backlog @mobile
  Scenario: Reduced motion replaces sliding transitions
    Given the user turned on reduced motion
    When the user opens a thread
    Then the thread appears without a sliding animation

  @backlog @mobile
  Scenario: Working indicators do not animate continuously with reduced motion
    Given the user turned on reduced motion
    And an agent is working
    Then the working status is shown without continuous animation

  @backlog @mobile
  Scenario: Collapsible sections announce whether they are expanded
    Given the snoozed shelf is collapsed
    When a screen reader focuses the snoozed shelf
    Then it announces that the shelf is collapsed and can be expanded

  @backlog @mobile
  Scenario: Status is never conveyed by colour alone
    Given a thread failed and another is done
    Then each thread shows its status in words as well as colour

  # New behaviour: the React Native app does not guarantee this today.
  @backlog @mobile
  Scenario: Tap targets are large enough to hit
    When the user looks at any action in the thread list or composer
    Then its touch area is at least 44 points square
