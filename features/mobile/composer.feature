# Sources:
#   apps/mobile/src/features/threads/ (composer send modes, queued messages, command popover)
#   apps/mobile/src/features/settings/SettingsKeyboardRouteScreen.tsx (Return key behaviour)
#   apps/mobile/src/state/composer-attachment-uploads.ts (upload progress, retry)
#   apps/mobile/src/state/attachments.ts
#   apps/mobile/src/state/edit-pending-thread-message.ts
#   apps/mobile/src/native/HalC2ComposerEditor
#   apps/mobile/modules/hal-c2-composer-editor
#   apps/mobile/src/features/files/ (attachment screen, remove from draft)
#   apps/mobile-qt/qml/HalC2/Mobile/ThreadScreen.qml (the shared Composer brick on a phone: stop, model and effort, drafts)
#   apps/desktop-qt/qml/HalC2/Bricks/TurnRequests.qml (the queue the shared Composer stacks)
# Drafting, sending, queueing and steering are specified in features/composer/. This file
# covers the phone twist: the on-screen keyboard, touch attachments and small-screen sheets.

Feature: Writing to an agent from a phone
  The composer must stay usable with an on-screen keyboard, accept attachments from the
  phone's own sources, and never lose a draft when the app is interrupted.

  Background:
    Given the phone is paired with "My MacBook"
    And the user is in the thread "Fix checkout"

  @backlog @mobile
  Scenario: The composer stays above the on-screen keyboard
    When the user starts typing a message
    Then the message being written stays visible above the keyboard
    And the latest messages stay visible above the composer

  @backlog @mobile
  Scenario: Dismissing the keyboard keeps the draft
    Given the user has typed "add a test"
    When the user dismisses the keyboard
    Then the draft still reads "add a test"

  @mobile
  Scenario: A draft survives the app being closed
    Given the user has typed "add a test"
    When the app is closed and reopened
    Then the draft in "Fix checkout" still reads "add a test"

  @backlog @mobile
  Scenario Outline: The Return key does what the user chose on a hardware keyboard
    Given the user set the Return key to "<setting>"
    When the user presses <keys> in the composer
    Then <outcome>

    Examples:
      | setting         | keys         | outcome                    |
      | Send message    | Return       | the message is sent        |
      | Send message    | Shift-Return | a new line is inserted     |
      | Insert new line | Return       | a new line is inserted     |
      | Insert new line | Cmd-Return   | the message is sent        |

  @backlog @mobile
  Scenario Outline: A message sent while the agent works can run later, steer or restart
    Given the agent is working on a turn
    When the user sends "also update docs" to <mode>
    Then <outcome>

    Examples:
      | mode                          | outcome                                         |
      | run after the current turn    | the message waits until the current turn ends   |
      | steer now                     | the agent receives the message during the turn  |
      | restart the turn              | the current turn stops and a new one starts     |

  @mobile
  Scenario: The user stops the agent from the composer
    Given the agent is working on a turn
    When the user stops the agent
    Then the turn ends

  # The phone hosts the shared Composer, so its queue stacks as the desktop's does
  # (features/composer/queue-and-steer.feature).
  @mobile
  Scenario: A delegated task's result waits under its title behind the queued messages
    Given the agent is working on a turn
    And the message "also update docs" is waiting for the current turn
    And the result of the delegated task "Tax tests" is waiting for the current turn
    Then the composer lists "also update docs" with "Tax tests finished" waiting behind it

  @backlog @mobile
  Scenario: The user edits a queued message before it runs
    Given the message "also update docs" is waiting for the current turn
    When the user edits it to "also update the changelog"
    Then "also update the changelog" runs after the current turn

  @backlog @mobile
  Scenario: The user cancels a queued message
    Given the message "also update docs" is waiting for the current turn
    When the user cancels it
    Then it does not run

  @backlog @mobile
  Scenario Outline: The user attaches from the phone's own sources
    When the user attaches <item> from <source>
    Then the draft shows the attachment
    And the attachment uploads to "My MacBook"

    Examples:
      | item         | source            |
      | a photo      | the photo library |
      | a video      | the photo library |
      | a PDF        | the files app     |

  # New behaviour: the React Native app offers the photo library and files but no camera.
  @backlog @mobile
  Scenario: The user takes a photo and attaches it
    When the user takes a photo from the composer
    Then the draft shows the photo
    And the photo uploads to "My MacBook"

  @backlog @mobile
  Scenario: Cancelling the camera leaves the draft unchanged
    When the user opens the camera from the composer but cancels
    Then the draft has no new attachment

  @backlog @mobile
  Scenario: Denied photo access explains how to recover
    Given the user has denied photo library access
    When the user tries to attach a photo
    Then the user is told photo access is needed
    And the user is offered to open the system settings

  @backlog @mobile
  Scenario: Upload progress is shown until the attachment is ready
    When the user attaches a large video
    Then the attachment shows how much has uploaded
    And the message cannot be sent until the upload finishes

  @backlog @mobile
  Scenario: A failed upload can be retried
    Given an attachment failed to upload
    When the user retries the upload
    Then the attachment uploads to "My MacBook"

  @backlog @mobile
  Scenario: Uploads continue after the user leaves the thread
    Given an attachment is uploading
    When the user goes back to the home screen
    Then the upload still completes

  @backlog @mobile
  Scenario: The user removes an attachment from the draft
    Given the draft has a photo attached
    When the user opens the photo and removes it from the draft
    Then the draft has no attachments

  @backlog @mobile
  Scenario: A pasted image larger than the limit is refused
    When the user pastes an image larger than 10 MB
    Then the image is not attached
    And the user is told the image is too large

  @backlog @mobile
  Scenario: Long pasted text becomes an attachment
    When the user pastes a long log into the composer
    Then the log is attached as a text file instead of filling the composer

  @backlog @mobile
  Scenario: Pasted text too large for a message is refused
    When the user pastes text larger than a message can carry
    Then the user is told the pasted text is too large

  @backlog @mobile
  Scenario Outline: Typing a trigger offers matching items to insert
    When the user types "<trigger>" in the composer
    Then the user is offered matching <items>

    Examples:
      | trigger | items         |
      | /       | commands      |
      | $       | skills        |
      | @       | files         |
      | #       | pull requests |

  @mobile
  Scenario: The user changes the model and reasoning level from the composer
    When the user picks the model "Opus" with high reasoning
    Then the next message is sent to "Opus" with high reasoning

  @mobile
  Scenario: The user picks the model's other options from the composer
    When the user picks the model "Opus" with the 1M context window and fast mode on
    Then the next message is sent to "Opus" with the 1M context window and fast mode on

  @backlog @mobile
  Scenario: A message written with no connection is sent once the connection returns
    Given "My MacBook" is unreachable
    When the user sends "add a test"
    Then the message is shown as waiting to send
    When "My MacBook" becomes reachable
    Then the message is sent

  @backlog @mobile
  Scenario: A usage limit is explained above the composer
    Given the provider has hit its usage limit for the thread
    Then the user is told when the limit resets
    And the user is offered to snooze the thread until the reset
