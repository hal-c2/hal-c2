# Sources:
#   apps/mobile/src/features/threads/ (composer send modes, queued messages, command popover)
#   apps/mobile/src/features/threads/ThreadQueueControl.tsx (queued messages: editing, held queue, empty)
#   apps/mobile/src/features/threads/use-composer-command-menu.ts, ComposerCommandPopover.tsx (triggers, skills, empty and loading texts)
#   apps/mobile/src/features/threads/ComposerFeedback.tsx (feedback notice)
#   apps/mobile/src/features/threads/ThreadSettingsSheet.tsx, ThreadSettingsRows.shared.tsx (model sheet)
#   apps/mobile/src/features/threads/use-thread-settings-sheet-presentation.ts (keyboard around the settings sheet)
#   apps/mobile/src/features/threads/NewTaskDraftScreen.tsx (start blocks: model, /usage-limits)
#   apps/mobile/src/features/settings/SettingsKeyboardRouteScreen.tsx (Return key behaviour)
#   apps/mobile/src/state/composer-attachment-uploads.ts (upload progress, retry)
#   apps/mobile/src/state/attachments.ts
#   apps/mobile/src/lib/composerImages.ts (photo and file pickers, clipboard paste, photo conversion)
#   apps/mobile/src/lib/composerFiles.test.ts (file size judged by the copied bytes, empty files, no partial copies, picker failures)
#   apps/mobile/src/components/ProviderIcon.tsx, OverlayPortal.tsx, AndroidAnchoredMenu.tsx (provider icons, menus that keep the keyboard open)
#   apps/mobile/src/lib/attachmentUpload.ts (pending upload reuse, expiry, release, missing local copy)
#   apps/mobile/src/lib/composerAttachmentUploadQueue.ts (only a failed upload blocks sending)
#   apps/mobile/src/state/edit-pending-thread-message.ts
#   apps/mobile/src/state/use-model-option-memory.ts (options remembered per model)
#   apps/mobile/src/state/use-thread-composer-state.ts, queued-run-edit.ts (send limits and alerts, queued edit failures, /feedback)
#   apps/mobile/src/state/use-selected-thread-requests.ts (an answer waits for its uploads)
#   apps/mobile/src/lib/modelOptions.ts (model not set up, providers left out, new task model order)
#   apps/mobile/src/lib/composerContext.ts, composerContextClipboard.ts (context sending, pasting between drafts)
#   apps/mobile/src/lib/composerAttachmentUploadQueue.ts, attachmentUpload.ts (upload limits, legacy hosts)
#   apps/mobile/src/components/ComposerEditor.tsx, ComposerContextSheet.tsx, ComposerContextAttachment.tsx (reference taps)
#   apps/mobile/src/native/HalC2ComposerEditor
#   apps/mobile/modules/hal-c2-composer-editor
#   apps/mobile/modules/hal-c2-markdown-text (context clipboard config: a sent message's references copy back as references)
#   apps/mobile/src/features/files/ (attachment screen, remove from draft)
#   apps/mobile-qt/qml/HalC2/Mobile/ThreadScreen.qml (the shared Composer brick on a phone: stop, model and effort, drafts)
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

  @backlog @mobile
  Scenario Outline: The send control names what sending will do
    Given <situation>
    Then the send control reads "<label>"

    Examples:
      | situation                                                           | label                  |
      | the agent is idle and the message leaves at once                    | Send                   |
      | the agent is idle but the message must wait for a connection        | Queue                  |
      | the agent is working and the follow-up setting is queue             | Queue                  |
      | the agent is working and the follow-up setting is steer             | Steer                  |
      | the user is editing a queued message                                | Update queued message  |

  @backlog @mobile
  Scenario: An agent that cannot take a steer is only offered the queue
    Given the agent is working on a turn
    And the agent's provider cannot steer a running turn
    And the follow-up setting is steer
    Then the send control reads "Queue"
    And the user is not offered another way to send the follow-up

  @mobile
  Scenario: The user stops the agent from the composer
    Given the agent is working on a turn
    When the user stops the agent
    Then the turn ends

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
  Scenario Outline: A photo the providers cannot read is converted when it is attached
    When the user attaches <photo> from the photo library
    Then <result>

    Examples:
      | photo                           | result                                                              |
      | a HEIC photo named "photo.HEIC" | it is attached as a JPEG named "photo.jpg"                          |
      | a JPEG of 14 MB                 | it is attached as a JPEG scaled so its longest side is 2048 pixels  |
      | a PNG, GIF or WebP under 10 MB  | it is attached byte for byte, so transparency and animation survive |

  @backlog @mobile
  Scenario Outline: A photo that cannot be attached says why and the rest of the selection still attaches
    Given the user selects "<name>" and "other.jpg" from the photo library
    When "<name>" <problem>
    Then "other.jpg" is attached
    And the user is told "<message>"

    Examples:
      | name      | problem                            | message                                         |
      | scan.heic | cannot be read by the phone        | Failed to read 'scan.heic'.                     |
      | scan.heic | is still over 10 MB once converted | 'scan.heic' exceeds the 10 MB attachment limit. |
      | notes.bin | is not a photo or a video          | Unsupported file type for 'notes.bin'.          |

  @backlog @mobile
  Scenario: The photo library only offers photos where the environment takes no files
    Given the environment accepts images but no other files
    When the user opens the photo library from the composer
    Then only photos can be chosen

  @backlog @mobile
  Scenario Outline: A full draft does not open the photo library or the files app
    Given the draft already carries 100 attachments
    When the user chooses to attach from <source>
    Then <source> is not opened
    And the user is told "<message>"

    Examples:
      | source            | message                                           |
      | the photo library | You can attach up to 100 attachments per message. |
      | the files app     | You can attach up to 100 files per message.       |

  @backlog @mobile
  Scenario: Files chosen beyond the room left in the draft are not attached
    Given the draft already carries 98 attachments
    When the user chooses 5 files from the files app
    Then the first 2 files are attached
    And the user is told "You can attach up to 100 files per message."

  @backlog @mobile
  Scenario: A file the environment would refuse is refused when it is chosen
    Given "My MacBook" accepts files of at most 25 MB
    When the user chooses "disk.img" of 40 MB and "notes.txt" from the files app
    Then "notes.txt" is attached
    And the user is told "'disk.img' exceeds the 25 MB attachment limit."

  @backlog @mobile
  Scenario: A file is never attached above 50 MB however much the environment would take
    Given "My MacBook" accepts files of at most 80 MB
    When the user chooses "archive.zip" of 51 MB from the files app
    Then the user is told "'archive.zip' exceeds the 50 MB attachment limit."
    And nothing is attached

  @backlog @mobile
  Scenario: An empty file is said to be empty and not too large
    When the user chooses "empty.txt" with no content from the files app
    Then the user is told "'empty.txt' is empty or could not be read."
    And nothing is attached

  @backlog @mobile
  Scenario: A file that grew after it was chosen is judged by its real size
    Given the files app reported "log.txt" as 1 KB
    And "log.txt" is 30 MB when the phone copies it
    And "My MacBook" accepts files of at most 25 MB
    When the user chooses "log.txt"
    Then the user is told "'log.txt' exceeds the 25 MB attachment limit."
    And nothing is attached
    And no partial copy of "log.txt" is left on the phone

  @backlog @mobile
  Scenario: A file that fails to copy leaves no partial copy behind
    Given the phone runs out of space while copying "report.pdf"
    When the user chooses "report.pdf" from the files app
    Then the user is told the file could not be attached
    And no partial copy of "report.pdf" is left on the phone

  @backlog @mobile
  Scenario: A photo or video the phone cannot fetch says why and the picker lets go
    Given the user chose a video that is stored in the phone's cloud photo library
    When the phone cannot download it
    Then the user is told what the phone reported, such as "Could not download video from iCloud."
    And nothing is attached
    And an update that was waiting may restart the app once the user is back

  @backlog @mobile
  Scenario: A picture chosen from the files app is treated as a picture
    When the user chooses "IMG_4997.PNG" from the files app
    Then the draft shows it as a picture and not as a document

  @backlog @mobile
  Scenario: A file chosen without a name is still attached
    When the user chooses a file from the files app whose provider reports no name
    Then the file is attached named "file"

  @backlog @mobile
  Scenario: Upload progress is shown until the attachment is ready
    When the user attaches a large video
    Then the attachment shows how much has uploaded
    And only a failed upload stops the message from being sent

  @backlog @mobile
  Scenario: A failed upload can be retried
    Given an attachment failed to upload
    When the user retries the upload
    Then the attachment uploads to "My MacBook"

  @backlog @mobile
  Scenario: A message sent while an attachment is still uploading goes out when the upload finishes
    Given the draft has a large video attached that is still uploading
    When the user sends the message
    Then the message is shown as waiting to send
    And the message is delivered to "My MacBook" once the upload finishes

  @backlog @mobile
  Scenario: A message delivered again does not upload its attachments again
    Given "bug.png" was uploaded to "My MacBook" for a message that was not delivered
    When the app delivers the message again
    Then "bug.png" is not uploaded a second time

  @backlog @mobile
  Scenario: An upload the environment let expire is sent again from the phone
    Given "design.pdf" was uploaded to "My MacBook" for a message that was not delivered
    And "My MacBook" has since discarded the upload
    When the app delivers the message
    Then "design.pdf" is uploaded again from the phone's own copy
    And the message is delivered

  @backlog @mobile
  Scenario: An upload made to one environment is not reused for another
    Given "bug.png" was uploaded to "My MacBook" for a message that was not delivered
    When the user sends the message to a project on another environment
    Then "bug.png" is uploaded to that environment

  @backlog @mobile
  Scenario: A waiting message the user deletes takes its uploads with it
    Given a message with "design.pdf" is waiting to send and its upload has started
    When the user deletes the waiting message
    Then the upload is stopped
    And "My MacBook" is asked to discard what had already arrived

  @backlog @mobile
  Scenario: An attachment whose copy on the phone is gone has to be attached again
    Given the draft has "bug.png" attached
    And the phone no longer has the app's own copy of "bug.png"
    When the user sends the message
    Then the message is not delivered
    And the user is told "'bug.png' is no longer available. Attach the image again."

  @backlog @mobile
  Scenario: Removing an attachment never deletes the user's original file
    Given the draft has "report.pdf" attached from the files app
    When the user removes "report.pdf" from the draft
    Then the phone's copy made for the draft is deleted
    And the original "report.pdf" in the files app is untouched

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
  Scenario Outline: A paste the composer cannot take says why
    Given <clipboard>
    When the user pastes into the composer
    Then nothing is added to the draft
    And the user is told "<message>"

    Examples:
      | clipboard                                          | message                                                     |
      | the clipboard holds empty text                     | Clipboard is empty.                                         |
      | the clipboard holds neither text nor an image      | Clipboard does not contain pasteable text or image content. |
      | the clipboard holds an image the phone cannot read | Clipboard image is unavailable.                             |
      | a full draft and the clipboard holds an image      | You can attach up to 100 images per message.                |

  @backlog @mobile
  Scenario: A copied picture with its caption pastes the picture only
    Given the clipboard holds a picture and its caption text
    When the user pastes into the composer
    Then the picture is attached
    And the caption is not added to the draft

  @backlog @mobile
  Scenario: Long pasted text becomes an attachment
    When the user pastes a long log into the composer
    Then the log is attached as a text file instead of filling the composer

  @backlog @mobile
  Scenario: Pasted text too large for a message is refused
    When the user pastes text larger than a message can carry
    Then the user is told the pasted text is too large

  # The shortcut is Cmd-Shift-V on an iPad and Ctrl-Shift-V on an Android device.
  @backlog @mobile
  Scenario: Paste as Text on a hardware keyboard keeps a long paste in the draft
    Given a hardware keyboard is attached
    And the clipboard holds a long log
    When the user presses the Paste as Text shortcut in the composer
    Then the log is inserted into the draft where it can be edited
    And nothing is attached
    And the user can undo the paste in one step

  @backlog @mobile
  Scenario: Paste as Text still refuses a paste that would overfill the draft
    Given a hardware keyboard is attached
    And the draft is within a few characters of the longest a message can be
    When the user presses the Paste as Text shortcut with more text than fits
    Then the user is told the pasted text is too large
    And the draft and the selection are unchanged

  @backlog @mobile
  Scenario: Paste as Text pastes copied references as their text
    Given the clipboard holds references copied from another draft
    When the user presses the Paste as Text shortcut in the composer
    Then the draft gets the text of the references
    And no reference or file is brought along

  @backlog @mobile
  Scenario: Paste as Text does nothing in a composer that is read only
    Given the composer is read only
    When the user presses the Paste as Text shortcut
    Then the draft is unchanged
    And the user is not told anything

  @backlog @mobile
  Scenario: Backspace next to a reference removes the whole reference
    Given the draft references "src/cart.ts" in the middle of the text
    When the user puts the caret after the reference and presses Backspace
    Then the whole reference is removed at once
    And the rest of the text is unchanged

  @backlog @mobile
  Scenario: Delete in front of a reference removes the whole reference
    Given the draft references "src/cart.ts" in the middle of the text
    When the user puts the caret before the reference and presses Delete
    Then the whole reference is removed at once

  @backlog @mobile
  Scenario: A long prompt hint stays on one line
    Given the composer is empty
    And the text size or the width of the composer leaves too little room for its hint
    Then the hint is cut short with an ellipsis on one line
    And the composer does not grow to two lines
    When the composer is widened
    Then the whole hint is shown again

  @backlog @mobile
  Scenario: Pictures dropped onto the composer are attached
    Given the user drags pictures from another app onto the composer on an iPad
    When the user drops them
    Then the pictures are attached to the draft
    And nothing is inserted into the text

  @backlog @mobile
  Scenario: Nothing is dropped onto a composer that is read only
    Given the composer is read only
    When the user drops a picture or text onto it
    Then the draft is unchanged

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

  @backlog @mobile
  Scenario Outline: Provider commands are offered only at the start of a message
    When the user types "<typed>" in the composer
    Then <outcome>

    Examples:
      | typed           | outcome                                   |
      | /compact        | the provider command "compact" is offered |
      | please /compact | no provider command is offered            |
      | please /model   | the built-in model command is offered     |

  @backlog @mobile
  Scenario: Compacting is offered only once the thread has a conversation
    Given the thread has no messages yet
    When the user types "/compact" in the composer
    Then the provider command "compact" is not offered

  @backlog @mobile
  Scenario Outline: Commands that need an existing thread are not offered in a new task
    Given the user is writing a new task and no thread exists yet
    When the user types "/<command>" in the composer
    Then "/<command>" is not offered

    Examples:
      | command      |
      | usage-limits |
      | feedback     |

  @backlog @mobile
  Scenario: Plan and default commands are not offered for an agent without plan mode
    Given the selected agent has no separate plan mode
    When the user types "/p" in the composer
    Then "/plan" and "/default" are not offered
    And "/model" is still offered

  @backlog @mobile
  Scenario: Another thread or a pull request is attached as context from the composer
    Given the environment has the thread "Auth refactor"
    When the user chooses "Auth refactor" after typing "@" in the composer
    Then the draft references "Auth refactor" and carries it as context

  @backlog @mobile
  Scenario Outline: A draft that already carries the most context refuses more
    Given the draft already carries the most context items it can
    When the user chooses <item> as context
    Then the user is told there are too many context items
    And the draft is unchanged

    Examples:
      | item                  |
      | another thread        |
      | a pull request        |

  @backlog @mobile
  Scenario: A thread that is already attached can be referenced again at the limit
    Given the draft already carries the most context items it can
    And "Auth refactor" is one of them
    When the user chooses "Auth refactor" after typing "@" in the composer
    Then the draft references "Auth refactor" again
    And no new context item is added

  @backlog @mobile
  Scenario: Choosing the usage limits command opens the limits instead of sending
    Given the selected agent has limits that HAL-C2 can show
    When the user chooses "/usage-limits"
    Then the command is removed from the draft
    And the thread's usage limits are shown

  @backlog @mobile
  Scenario Outline: Choosing a built-in command changes the thread instead of sending
    Given the Build and Plan toggle setting is on
    When the user chooses the built-in command "<command>" from the composer
    Then <outcome>
    And "<command>" is removed from the draft

    Examples:
      | command  | outcome                                  |
      | /plan    | the thread switches to planning          |
      | /default | the thread switches back to building     |
      | /model   | the user is asked to choose a model      |

  @backlog @mobile
  Scenario: A skill offered among the slash commands is named as a skill
    Given the provider offers the skill "review"
    When the user types "/skill" in the composer
    Then "skill:review" is offered
    When the user chooses it
    Then the draft references the skill "review"

  @backlog @mobile
  Scenario: Each skill is offered once, and only if it is enabled and the user may run it
    Given the provider reports the skill "review" from two places
    And the provider reports a disabled skill "old-review" and a skill "internal" the user may not run
    When the user types "$" in the composer
    Then "review" is offered once
    And "old-review" and "internal" are not offered

  @backlog @mobile
  Scenario: A skill is found by its name, its display name or its description
    Given the provider offers the skill "lint-fix" described as "Tidy the changed files"
    When the user types "$tidy" in the composer
    Then "lint-fix" is offered
    When the user types "$lint" in the composer
    Then "lint-fix" is offered first

  @backlog @mobile
  Scenario: Typing only the skill sign lists no more than twenty skills
    Given the provider offers 30 skills
    When the user types "$" in the composer
    Then 20 skills are offered
    When the user types "$a" in the composer
    Then every skill matching "a" is offered, best match first

  @backlog @mobile
  Scenario Outline: A suggestion list with nothing to offer says why
    When the user types "<typed>" in the composer and <situation>
    Then the suggestion list says "<message>"

    Examples:
      | typed | situation                                      | message                                         |
      | $zzz  | no skill matches                               | No skills found.                                |
      | @zzz  | no file or folder matches                      | No matching files or folders.                   |
      | /zzz  | no command matches                             | No matching commands.                           |
      | #zzz  | no pull request matches                        | No matching pull requests.                      |
      | #     | the project has no repository on a code host   | Pull requests are unavailable for this project. |

  @backlog @mobile
  Scenario Outline: A suggestion list that is still looking says so
    When the user types "<typed>" in the composer and the <items> have not come back yet
    Then the suggestion list says "<message>"

    Examples:
      | typed  | items         | message           |
      | @cart  | files         | Searching files…  |
      | #login | pull requests | Loading…          |

  @backlog @mobile
  Scenario: A suggestion list whose search failed shows the failure instead of items
    Given the environment cannot read pull requests for the project
    When the user types "#" in the composer
    Then the suggestion list shows why pull requests could not be read
    And no pull request is offered

  @backlog @mobile
  Scenario: A Codex feedback notice can be dismissed unless it is still sending
    Given the user sent "/feedback The agent stopped early" in a Codex thread
    Then the feedback notice cannot be dismissed while the feedback is being sent
    When the feedback has been sent
    Then the user can copy the feedback thread id
    And the user can dismiss the notice

  @backlog @mobile
  Scenario Outline: The keyboard comes back after the settings sheet only if it was up
    Given the keyboard is <before> while the user writes in the composer
    When the user opens the thread's settings and closes them again
    Then the keyboard is <after>

    Examples:
      | before | after |
      | up     | up    |
      | down   | down  |

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

  @backlog @mobile
  Scenario: The usage limits command says when the agent does not report limits
    Given the selected agent does not report usage limits
    When the user chooses "/usage-limits"
    Then the user is told usage limits are unavailable
    And the user is told this provider does not currently report limits

  @backlog @mobile
  Scenario: A queued message that is being edited cannot be edited or steered again
    Given the agent is working and "also update docs" is queued
    And the user is editing "also update docs" in the composer
    When the user opens the queued messages
    Then "also update docs" is marked as being edited
    And it cannot be edited or steered until the edit ends

  @backlog @mobile
  Scenario: Managing the queue closes once nothing is waiting
    Given the agent is working and "also update docs" is queued
    And the user has the queued messages open
    When the queued message starts running or is removed
    Then the queued messages close
    And the user is back in the thread

  @backlog @mobile
  Scenario: A queue held after a restart is resumed from the queued messages
    Given "also update docs" was queued when "My MacBook" restarted
    When the user opens the queued messages
    Then the user is told the queue is held after restart
    When the user resumes the queue
    Then "also update docs" runs after the current turn

  @backlog @mobile
  Scenario: An empty queue says nothing is waiting
    Given no message is queued in the thread
    When the user opens the queued messages
    Then the user is told no messages are waiting in this queue

  @backlog @mobile
  Scenario: A model choice made in the model sheet applies only when saved
    Given the composer is using "Sonnet"
    When the user picks "Opus" with high reasoning in the model sheet
    And the user cancels the sheet
    Then the composer is still using "Sonnet"

  @backlog @mobile
  Scenario: Saving the model sheet applies the model and its options together
    Given the composer is using "Sonnet"
    When the user picks "Opus" with high reasoning in the model sheet
    And the user saves the sheet
    Then the composer uses "Opus" with high reasoning

  @backlog @mobile
  Scenario: Models the provider has retired are hidden until asked for
    Given the provider lists a legacy model "Opus 3" that the thread is not using
    When the user opens the model sheet
    Then "Opus 3" is not listed
    When the user chooses to show legacy models
    Then "Opus 3" is listed with a legacy label

  @backlog @mobile
  Scenario: A legacy model that is in use or a favourite is still listed
    Given "Opus 3" is a legacy model and the thread is using it
    When the user opens the model sheet
    Then "Opus 3" is listed

  @backlog @mobile
  Scenario Outline: The model sheet says why it has nothing to show
    Given <situation>
    When the user opens the model sheet
    Then the user is told "<message>"

    Examples:
      | situation                                    | message              |
      | the user has no favourite models             | No favorite models   |
      | the search matches no model                  | No matching models   |
      | no provider has an available model           | No available models  |

  @backlog @mobile
  Scenario: Other providers' models are folded away until the user looks for them
    Given the user has models from several providers
    When the user opens the model sheet
    Then only the thread's provider is expanded
    When the user searches the models for "gpt"
    Then every provider with a matching model is expanded

  @backlog @mobile
  Scenario: Pulling the model sheet down refreshes the models
    When the user pulls down on the model sheet
    Then the environment is asked for its models again

  @backlog @mobile
  Scenario: A refresh that fails says so and keeps the models
    Given the environment cannot list its models
    When the user pulls down on the model sheet
    Then the user is told the models could not be refreshed
    And the models already shown stay

  @backlog @mobile
  Scenario: A model whose provider is no longer set up cannot be saved
    Given the thread's model belongs to a provider that is no longer available
    When the user saves the model sheet
    Then the model sheet is not saved
    And the user is told the model is unavailable and to select another

  @backlog @mobile
  Scenario: A new task cannot start on an Antigravity model that is not set up
    Given the new task's model is an Antigravity model that "My MacBook" has not set up
    When the user starts the task
    Then the task is not started
    And the user is told the Antigravity model is unavailable and to set up Antigravity or choose another model

  @backlog @mobile
  Scenario: A new task whose model is not available points to the model settings
    Given the new task's model is no longer offered by "My MacBook"
    Then the composer says the model is unavailable
    When the user chooses that notice
    Then the model settings open

  @backlog @mobile
  Scenario: The usage limits command typed into a new task is not sent to the agent
    Given the user is writing a new task and the agent reports usage limits
    When the user starts the task with the message "/usage-limits"
    Then the task is not started
    And the user is told to send the command inside a thread or open the usage limits in settings

  @backlog @mobile
  Scenario: An answer with files still uploading is not sent and says how to carry on
    Given the answer to an agent's question has a file that has not finished uploading
    When the user sends the answer
    Then nothing is sent
    And the user is told to wait for uploads to finish or retry failed uploads

  @backlog @mobile
  Scenario: A message with more attachments than one message can carry is not sent
    Given the draft has more than 100 attachments
    When the user sends the message
    Then nothing is sent
    And the user is told to remove attachments until there are at most 100

  @backlog @mobile
  Scenario: A message whose context is too large is not sent
    Given the draft carries more referenced context than a message can hold
    When the user sends the message
    Then nothing is sent
    And the user is told the context is too much and why

  @backlog @mobile
  Scenario: A review comment cannot be added to a draft that holds too many context items
    Given the draft already holds the most context items a message can carry
    When the user adds a review comment to the draft
    Then the user is told to remove some context from the draft
    And the comment is not added

  @backlog @mobile
  Scenario: A model that has not been set up cannot be sent to
    Given the thread uses an Antigravity model that "My MacBook" has not set up
    When the user sends "add a test"
    Then nothing is sent
    And the user is told to set Antigravity up on the desktop or choose another model

  @backlog @mobile
  Scenario: Attaching files is refused by an environment that takes none
    Given "My MacBook" does not accept file attachments
    When the user attaches a file
    Then the file is not attached
    And the user is told the server does not support file attachments

  @backlog @mobile
  Scenario: A photo that cannot be added does not stop the others
    When the user picks three photos and one of them cannot be read
    Then the two readable photos are attached
    And the user is told that a photo or video could not be attached

  @backlog @mobile
  Scenario: Pasted text that cannot be attached says how to carry on
    When the user pastes text that cannot be attached
    Then the user is told to remove an attachment or paste less text and try again

  @backlog @mobile
  Scenario: A queued message cannot be saved empty
    Given the user is editing the queued message "also update docs"
    When the user clears the text and saves
    Then the user is told a queued message cannot be left empty
    And the message is not changed

  @backlog @mobile
  Scenario: A queued message edit with too many attachments is refused
    Given the user is editing a queued message that already has attachments
    When the user adds attachments that bring the total above 100
    And saves
    Then the user is told to remove attachments until there are at most 100
    And the message is not changed

  @backlog @mobile
  Scenario: A queued message edit the environment refuses stays in the composer
    Given the user is editing the queued message "also update docs"
    When the environment refuses the edit
    Then the user is told the message may already have started
    And the edit is still in the composer

  @backlog @mobile
  Scenario: A queued message that starts running while it is edited keeps the edit when the draft was empty
    Given the user is editing the queued message "also update docs"
    And the composer's own draft is empty
    When the message starts running on another device
    Then the edit mode ends
    And the edited text is in the composer
    And the user is told the message already started and the edit is back in the composer

  @backlog @mobile
  Scenario: A queued message that starts running while it is edited drops the edit when the draft had text
    Given the user is editing the queued message "also update docs"
    And the composer's own draft holds "also check lint"
    When the message starts running on another device
    Then the edit mode ends
    And the composer still reads "also check lint"
    And the user is told the message already started so the edit was discarded

  @backlog @mobile
  Scenario: A queued message edit does not come back after the app restarts
    Given the user is editing the queued message "also update docs" and has changed its text
    When the app restarts
    Then the composer is not in edit mode
    And the composer holds the draft the user had before the edit

  @backlog @mobile
  Scenario: /feedback in a Codex thread sends feedback to OpenAI from the phone
    Given a Codex thread that has run a turn
    When the user sends "/feedback The agent stopped early"
    Then the draft is cleared and the user sees that feedback is being sent to OpenAI
    And once it is sent the user sees the feedback thread id

  @backlog @mobile
  Scenario: /feedback before the first Codex turn is refused on the phone
    Given a Codex thread with no messages yet
    When the user sends "/feedback"
    Then the user is told to start a Codex thread by sending a message before submitting feedback
    And nothing is sent

  @backlog @mobile
  Scenario: Attachments upload a few at a time
    Given the draft has ten large attachments
    When the draft starts uploading them
    Then at most three of them upload at once
    And the rest wait and start as earlier ones finish

  @backlog @mobile
  Scenario: Uploads interrupted by a lost connection start again when it returns
    Given an attachment is uploading to "My MacBook"
    When the connection to "My MacBook" is lost
    Then the upload stops and the attachment stays in the draft
    When the connection returns
    Then the attachment uploads again from the phone's own copy
    And the message is not blocked by the interruption

  @backlog @mobile
  Scenario: An upload that failed is tried again once the connection returns
    Given an attachment failed to upload to "My MacBook"
    When the connection to "My MacBook" is lost and then returns
    Then the attachment uploads again without the user retrying it

  @backlog @mobile
  Scenario: An environment that takes no image uploads is sent the images with the message
    Given "My MacBook" does not accept uploads ahead of sending
    And the draft has "bug.png" attached
    When the user sends the message
    Then "bug.png" travels inside the message itself
    And nothing is uploaded ahead of it

  @backlog @mobile
  Scenario: A host that cannot read message context is sent it as text
    Given "My MacBook" is too old to take referenced context with a message
    And the draft references "src/cart.ts"
    When the user sends the message
    Then the message carries the reference and its content as text
    And a message still waiting to send keeps its references until it is delivered

  @backlog @mobile
  Scenario: Tapping a file reference in the draft opens that file
    Given the draft references "src/cart.ts"
    When the user taps the reference
    Then "src/cart.ts" opens in the thread's files

  @backlog @mobile
  Scenario: Tapping a reference whose path is only a basename opens the full path
    Given the draft references "src/cart.ts", shown as "cart.ts"
    When the user taps the reference
    Then "src/cart.ts" opens, not a file named "cart.ts" elsewhere in the workspace

  @backlog @mobile
  Scenario: Tapping a document in the draft opens it in the file screen
    Given the draft has the document "notes.docx" attached
    When the user taps its reference
    Then "notes.docx" opens in the file screen
    And pictures, videos and PDFs keep opening in their own viewers

  @backlog @mobile
  Scenario Outline: Tapping a reference shows what it carries
    Given the draft carries <reference>
    When the user taps the reference
    Then the user reads <shown>
    And the user can close it or remove the reference from the draft

    Examples:
      | reference                                  | shown                                                       |
      | a terminal excerpt of lines 10 to 24       | the excerpt's text, its terminal and "Lines 10–24"          |
      | a review comment on a diff                 | the comment with the lines it was made on                   |
      | a pull request                             | its number, state, title and branches                       |
      | a preview annotation                       | the page, comment, selection and requested changes          |
      | a page element                             | the element, its selector, source, markup and styles        |
      | a thread                                   | the thread's title                                          |
      | a skill                                    | the skill's name and description                            |

  @backlog @mobile
  Scenario: A skill without a description says so
    Given the draft references a skill that has no description
    When the user taps the reference
    Then the user reads "No description is available for this skill."

  @backlog @mobile
  Scenario: A thread reference opens the thread
    Given the draft references the thread "Auth refactor"
    When the user taps the reference and chooses to open the thread
    Then the thread "Auth refactor" opens

  @backlog @mobile
  Scenario: A pull request reference opens the pull request in the browser
    Given the draft references the pull request 41 "Add login"
    When the user taps the reference and chooses to open the pull request
    Then pull request 41 opens in the phone's browser

  @backlog @mobile
  Scenario: A pull request that cannot be opened says to try again when connected
    Given the draft references the pull request 41 "Add login"
    When the user chooses to open the pull request and the phone cannot open it
    Then the user is told "Could not open pull request" and to try again when connected

  @backlog @mobile
  Scenario: A picture or PDF reference opens with its save and share choices
    Given the draft has "bug.png" attached
    When the user taps its reference
    Then "bug.png" opens in the image viewer
    And the viewer offers to save or share it

  @backlog @mobile
  Scenario: A reference whose content was not copied with it says how to recover
    Given the draft holds a reference that arrived without its content
    When the user taps the reference
    Then the user reads that the reference was copied without its content
    And the user is told to copy it again from the original message or remove it

  @backlog @mobile
  Scenario: A reference of a kind this version does not know is kept and sent
    Given the draft holds a reference of a kind this version of the app does not show
    When the user taps the reference
    Then the user is told this kind of context is not supported by this version
    And the reference is sent with the message exactly as it was

  @backlog @mobile
  Scenario Outline: A referenced attachment says why it cannot be shown
    Given the draft references the attachment "bug.png"
    And <problem>
    When the user taps the reference
    Then the user reads "<message>"

    Examples:
      | problem                                                  | message                                         |
      | the phone's own copy of the attachment is gone           | The local file is unavailable. Attach it again. |
      | the attachment is only on "My MacBook", which is offline | Attachment unavailable. Reconnect and try again |

  @backlog @mobile
  Scenario: A referenced attachment can be opened or shared from its reference
    Given the draft references the attachment "report.pdf"
    When the user taps the reference and chooses to open or share the attachment
    Then the attachment is fetched if the phone does not hold it
    And the phone's share sheet offers it

  @backlog @mobile
  Scenario: An attachment that cannot be fetched for sharing says to reconnect
    Given the draft references the attachment "report.pdf", held only on "My MacBook"
    And "My MacBook" is not connected
    When the user chooses to open or share the attachment
    Then the user is told "Could not open attachment": "Reconnect to the environment and try again."

  @backlog @mobile
  Scenario: A reference can be removed from the draft where it is read
    Given the draft references "src/cart.ts" in the middle of the text
    When the user taps the reference and removes it from the draft
    Then the reference is gone and the rest of the text is unchanged

  @backlog @mobile
  Scenario: A reference cannot be removed while the composer is read only
    Given the composer is read only
    When the user taps a reference
    Then the reference's details open
    And no way to remove it is offered

  @backlog @mobile
  Scenario: References in a resting composer start writing instead of opening
    Given the composer is resting with a draft full of references
    When the user taps a reference
    Then the composer opens for writing
    And no reference's details open
    When the user taps the same reference in the open composer
    Then its details open

  @backlog @mobile
  Scenario: Copying references from the draft and pasting them into another draft brings them along
    Given the draft references "src/cart.ts" and has "bug.png" attached
    When the user copies that part of the draft and pastes it into another thread's draft
    Then the other draft references "src/cart.ts" with the same text
    And the other draft has its own copy of "bug.png" attached

  @backlog @mobile
  Scenario: Copying part of a sent message and pasting it into a draft brings its references along
    Given the user sent "Compare @src/cart.ts with the screenshot" with "src/cart.ts" referenced and "bug.png" attached
    When the user selects that sentence in the sent message and copies it
    And the user pastes it into a draft
    Then the draft holds "src/cart.ts" as a reference with its content
    And the draft has its own copy of "bug.png" attached

  @backlog @mobile
  Scenario: Only the references inside the selected part of a sent message are pasted
    Given the user sent "See @src/cart.ts and then @src/pay.ts" with both files referenced
    When the user selects only the words up to "@src/cart.ts" and copies them
    And the user pastes into a draft
    Then the draft references "src/cart.ts"
    And the draft does not reference "src/pay.ts"

  @backlog @mobile
  Scenario: Copying a preview annotation from a sent message brings its screenshot along
    Given the user sent a message that carries a preview annotation with its screenshot
    When the user selects the annotation in the sent message and copies it
    And the user pastes into a draft
    Then the draft holds the annotation with its screenshot

  @backlog @mobile
  Scenario: The composer waits while pasted references bring their files
    Given the user pastes references that carry a file held on "My MacBook"
    When the file is being brought into the draft
    Then the user sees that context is being copied
    And the composer cannot be edited or sent until the copy ends

  @backlog @mobile
  Scenario: Leaving the draft stops a paste that is still bringing files
    Given the user pastes references that carry a file held on "My MacBook"
    When the user opens another thread before the file arrives
    Then the file is not added to any draft
    And nothing the paste had already copied is left on the phone

  @backlog @mobile
  Scenario: Pasting references whose files cannot be brought along keeps the references
    Given the user copied references that carry "trace.log" from an environment that is now offline
    When the user pastes them into a draft
    Then the text and references are pasted
    And the references without their files are marked unavailable
    And the user is told to reconnect to the source environment and copy them again

  @backlog @mobile
  Scenario: A paste that brings more than the draft can hold is refused
    Given the draft already holds the most context items a message can carry
    When the user pastes references into it
    Then nothing is pasted
    And the user is told to remove some attachments or context items and paste again

  @backlog @mobile
  Scenario: A copy of more references than the clipboard can carry says so
    Given the draft holds references whose content is too large to put on the clipboard together
    When the user copies all of them
    Then the user is told the selection is too large to copy and to select fewer items

  @backlog @mobile
  Scenario: A picture that is still uploading can be copied into another draft
    Given the draft has "bug.png" attached and it is still uploading
    When the user copies its reference and pastes it into another draft
    Then the other draft has its own copy of "bug.png" from the phone's copy
    And it uploads from there

  @backlog @mobile
  Scenario: Pasted references are given new identities
    Given the draft references "src/cart.ts"
    When the user copies the reference and pastes it into the same draft
    Then the draft holds two separate references to "src/cart.ts"
    And removing one leaves the other

  @backlog @mobile
  Scenario: Undoing the removal of a reference brings back what it carried
    Given the draft references "src/cart.ts" and carries a preview annotation with its screenshot
    When the user deletes the annotation and then undoes
    Then the annotation is back with its screenshot
    And the references that were not removed are unchanged

  @backlog @mobile
  Scenario: A screenshot stays while its annotation remains
    Given the draft carries a preview annotation with its screenshot
    When the user deletes the screenshot's own reference but keeps the annotation
    Then the annotation keeps its screenshot

  @backlog @mobile
  Scenario: Removing a reference removes what it carried
    Given the draft carries the reference "trace.log" with its attached file
    When the user deletes the reference from the draft text
    Then the reference's content is no longer sent with the message

  @backlog @mobile
  Scenario Outline: The phone leaves out models of providers that cannot be used
    Given a provider on "My MacBook" is <state>
    When the user opens the model sheet
    Then the provider's models are not listed

    Examples:
      | state                              |
      | turned off in settings             |
      | not installed                      |
      | signed out                         |

  @backlog @mobile
  Scenario: A model the user already uses stays listed after the provider's catalog drops it
    Given the thread uses "Sonnet 4" and the provider no longer lists it
    When the user opens the model sheet
    Then "Sonnet 4" is listed under the provider as the model in use

  @backlog @mobile
  Scenario Outline: A new task starts on the first of these that can be used
    Given <available> can be used on "My MacBook"
    When the user starts a new task
    Then the task's model is <chosen>

    Examples:
      | available                                                                   | chosen                         |
      | the draft's model, the project's default and the last model used            | the draft's model              |
      | the project's default and the last model used                               | the project's default          |
      | the last model used and the environment's default                           | the last model used            |
      | only the environment's default                                              | the environment's default      |
      | only a model that is not the environment's default                          | the first model that can be used |

  @backlog @mobile
  Scenario: A remembered model of a provider that was signed out is not used for a new task
    Given the last model used was from a provider that has since been signed out
    When the user starts a new task
    Then the task starts on a model of a provider that is signed in

  @backlog @mobile
  Scenario: The options chosen for a model come back when that model is chosen again
    Given the user chose "Opus 4" with high effort in "Fix checkout"
    When the user later chooses "Opus 4" in another thread or a new task
    Then "Opus 4" is chosen with high effort
    When the user closes and opens the app
    And the user chooses "Opus 4" in a new task
    Then "Opus 4" is still chosen with high effort

  @backlog @mobile
  Scenario: Options remembered for one model are not applied to another model
    Given the user chose "Opus 4" with high effort
    When the user chooses "Sonnet 4" in a new task
    Then "Sonnet 4" starts with its own default options

  @backlog @mobile
  Scenario: A retired model is never chosen on the user's behalf
    Given the project's default model is a legacy model
    When the user starts a new task
    Then the task does not start on the legacy model
    When the user chooses the legacy model in the model sheet
    Then the task starts on the legacy model

  @backlog @mobile
  Scenario: An Antigravity model is kept when its catalog changes
    Given the thread uses an Antigravity model that "My MacBook" no longer lists
    When the user opens the thread
    Then the thread still shows the Antigravity model
    And the model is marked as unavailable
    And the model is not replaced by another model without the user choosing one

  @backlog @mobile
  Scenario Outline: A provider is shown with its own icon
    Given a model or thread uses <provider>
    Then it is shown with the <provider> icon

    Examples:
      | provider     |
      | Codex        |
      | Claude       |
      | Cursor       |
      | Grok         |
      | OpenCode     |
      | Antigravity  |
      | Pi           |

  @backlog @mobile
  Scenario: A provider icon follows the app's light or dark appearance
    Given a model uses Cursor
    When the app is dark
    Then the Cursor icon is drawn light
    When the app is light
    Then the Cursor icon is drawn dark

  @backlog @mobile
  Scenario: An ACP agent shows the agent's own icon once it has loaded
    Given the ACP agent "Gemini CLI" has an icon in the official registry
    Then the agent is shown with a generic agent icon until its own icon has loaded
    When the icon has loaded
    Then the agent is shown with its own icon

  @backlog @mobile
  Scenario: An ACP agent whose icon cannot be loaded keeps the generic icon
    Given the ACP agent "Gemini CLI" has an icon that cannot be loaded
    Then the agent is shown with the generic agent icon

  @backlog @mobile
  Scenario: A menu opened from the composer keeps the keyboard open on Android
    Given the user is writing in the composer on an Android phone with the keyboard open
    When the user opens the model or mode menu above the composer
    Then the menu is shown
    And the keyboard stays open
