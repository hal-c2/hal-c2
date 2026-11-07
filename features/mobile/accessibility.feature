# Sources:
#   https://github.com/pingdotgg/t3code/pull/21757
#   https://github.com/pingdotgg/t3code/pull/27249
#   https://github.com/pingdotgg/t3code/pull/23348
#   https://github.com/pingdotgg/t3code/pull/23230
#   https://github.com/pingdotgg/t3code/pull/24273
#   https://github.com/pingdotgg/t3code/pull/19239
#   https://github.com/pingdotgg/t3code/pull/13491
#   https://github.com/pingdotgg/t3code/pull/13356
#   https://github.com/pingdotgg/t3code/pull/23888
#   https://github.com/pingdotgg/t3code/pull/23740
#   https://github.com/pingdotgg/t3code/pull/27020
#   https://github.com/pingdotgg/t3code/pull/24088
#   apps/mobile/src/features/threads/thread-list-v2-items.tsx (swipe accessibility hint)
#   apps/mobile/src/features/threads/ThreadArrangementSheet.tsx (Move up and Move down actions)
#   apps/mobile/src/features/home/thread-swipe-actions.tsx
#   apps/mobile/src/features/threads/ThreadQueueControl.tsx
#   apps/mobile/src/features/voice-input/ComposerDictationControl.tsx
#   apps/mobile/src/components/SegmentedControl.tsx (font scaling limits)
#   apps/mobile/src/features/usage/UsageRouteScreen.tsx (range labels read in full)
#   apps/mobile/src/features/settings/appearance/
#   apps/mobile/src/components/VideoAttachmentTile.tsx, MediaActionsMenu.tsx (Play, media actions)
#   apps/mobile/modules/hal-c2-composer-editor/ios/HalC2ComposerEditorView.swift (references as accessibility buttons)
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

  # Upstream #23740: iOS read an environment's two actions as "refresh" and "trash", not as buttons.
  @backlog @mobile @priority-low
  Scenario: An environment's actions are announced as named buttons
    When a screen reader user expands the environment "Office Mac" in the environment list
    Then its actions are announced as the buttons "Reconnect environment" and "Remove environment"

  # Upstream #27020: Copy and Fork under a reply were 28dp on Android.
  @backlog @mobile @priority-low
  Scenario: A reply's actions are large enough to tap
    Given an agent reply in the thread
    Then its Copy and Fork actions are each at least 48dp on Android
    And they grow with the app's text size

  # Upstream #24088: iOS header controls the app turned off still looked usable.
  @backlog @mobile @priority-low
  Scenario: Header controls that cannot be used look and read as unavailable
    Given a draft thread with no working folder
    When the user looks at the thread's header
    Then Terminal and Files are shown and announced as unavailable

  @backlog @mobile
  Scenario Outline: Controls read their full meaning, not their short label
    When a screen reader focuses the usage range "<short>"
    Then it announces "<spoken>"

    Examples:
      | short | spoken         |
      | 24h   | Past 24 hours  |
      | 7d    | Past 7 days    |
      | 90d   | Past 90 days   |

  @backlog @mobile @priority-low
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
  Scenario: Each reference in the draft is a button for a screen reader
    Given the draft references "src/cart.ts" and "Fix checkout"
    When a screen reader moves through the composer
    Then each reference is focused on its own as a button named by its label
    And activating a reference opens its details

  # Upstream #27249: TalkBack read Add attachment, Model and Send before the message field.
  @backlog @mobile
  Scenario Outline: A screen reader reaches the message field before Send
    Given the composer is <state>
    When a screen reader moves through the composer
    Then it reads <order>

    Examples:
      | state                              | order                                           |
      | one line and empty                 | Add attachment, the message field, Model, Send  |
      | expanded with a multi-line draft   | the message field, Add attachment, Model, Send  |
      | holding an attached image          | the message field, Add attachment, the image, Model, Send |

  @backlog @mobile @priority-low
  Scenario: Dictation state is announced
    Given a screen reader is on
    When the user starts dictating
    Then the screen reader announces that recording started
    And the user can cancel dictation from the screen reader

  @backlog @mobile @priority-low
  Scenario: Messages grow with the system text size
    Given the user set the system text size to the largest accessibility size
    When the user reads a thread
    Then message text is shown at the larger size
    And no message text is cut off

  @backlog @mobile @priority-low
  Scenario: Compact controls stay usable at large text sizes
    Given the user set the system text size to the largest accessibility size
    When the user looks at a segmented choice such as the usage range
    Then every option stays readable and tappable

  # Upstream #13356: Android header and icon controls follow the Settings text size, and keep a
  # 48dp touch target.
  @backlog @mobile @priority-low
  Scenario: Android header buttons grow with the app's text size and keep a 48dp touch target
    Given the user set the app's text size to the largest option on Android
    When the user looks at the thread list header
    Then the header buttons grow with the text
    And each button stays at least 48dp to tap

  # New behaviour: the React Native app does not guarantee this today.
  @backlog @mobile @priority-low
  Scenario: Reduced motion replaces sliding transitions
    Given the user turned on reduced motion
    When the user opens a thread
    Then the thread appears without a sliding animation

  @backlog @mobile @priority-low
  Scenario: Working indicators do not animate continuously with reduced motion
    Given the user turned on reduced motion
    And an agent is working
    Then the working status is shown without continuous animation

  # Upstream #24273: reconnecting status dots pulsed without end, even in rows out of sight.
  @backlog @mobile @priority-low
  Scenario: A reconnecting environment's status does not animate
    Given "Office Mac" is reconnecting
    Then its status shows it is reconnecting without continuous animation

  # Upstream #19239: with Remove animations on, the toolbar stayed at its animation's zero opacity.
  # Upstream #23230: with reduced motion the composer's model name could stay transparent, and a
  # settled thread's status label overlapped its Un-settle action.
  @backlog @mobile @priority-low
  Scenario: The composer's buttons show with reduced motion
    Given the user turned on reduced motion
    When the user opens a thread
    Then the composer's buttons are visible

  # Upstream #23888: with Android animations removed, the model picker's rows faded to invisible
  # and still answered taps.
  @backlog @mobile @priority-low
  Scenario: The model picker's choices show with reduced motion
    Given the user turned on reduced motion
    When the user opens the model picker in a thread's settings
    Then every model and option it lists is visible

  # Upstream #21757: with Android's Remove animations on, a thread's settings rows could stay
  # invisible because the first frame of their fade was dropped.
  @backlog @mobile @priority-low
  Scenario: A thread's settings rows show with reduced motion
    Given the user turned on reduced motion
    When the user opens a thread's settings
    Then every row shows at once without fading in
    And closing the settings does not fade them out

  # Upstream #23348: picking a file in Review changes, or going back to the top, still glided with
  # system animations off.
  @backlog @mobile @priority-low
  Scenario: Jumping between reviewed files does not glide with reduced motion
    Given the user turned on reduced motion
    And the user is reviewing the changes of "Fix checkout"
    When the user picks another changed file
    Then the review jumps straight to that file
    And going back to the top jumps straight there too

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

  @backlog @mobile @priority-low
  Scenario: A video is announced as something to play
    Given a message carries the video "demo.mp4"
    When a screen reader focuses the video
    Then it announces "Play demo.mp4" as a button

  @backlog @mobile
  Scenario: A picture's or video's media actions are offered without touching and holding
    Given a message carries the video "demo.mp4"
    When a screen reader user opens the actions for the video
    Then the user is offered to save or share it
    And the user is told that touching and holding offers media actions

  @backlog @mobile
  Scenario: A full-screen picture or video has a media actions button
    Given the user opened a video full screen
    When a screen reader focuses the top of the screen
    Then a button labelled "Media actions" is offered

  # Upstream #13491: a connection field is announced once, by the label it shows.
  @backlog @mobile
  Scenario: A connection field is announced once with its visible label
    Given the user is adding an environment
    When a screen reader focuses a connection field
    Then the field is announced with its label once

  # Upstream #13491: a switch is read as on or off, and follows each change.
  @backlog @mobile
  Scenario: A switch tells a screen reader whether it is on or off
    Given a setting switch is off
    When the user turns it on
    Then a screen reader reads it as on
    When the user turns it off
    Then a screen reader reads it as off
