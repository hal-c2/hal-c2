# Sources:
#   docs/user/composer.md (attachments, large pastes, images, prompt stash files)
#   apps/server-ex/lib/hal_c2/attachments.ex (upload URL, claim, size limits, pending expiry)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (image picker, file drop, clipboard paste, attachment removal)
#   apps/tui/src/composerAttachments.ts (image paths in prompts and editor output)
#   apps/tui/src/components/ChatView.tsx (clipboard image paste, image-only prompts, files browser attach)
#   apps/web/src/chatAttachment.ts (message and attachment limits)
#   apps/web/src/components/chat/ChatComposer.tsx (paste, drop, upload and folder toasts)
#   apps/web/src/components/ChatView.tsx (failed uploads block sending)
#   apps/web/src/components/ChatView.tsx, apps/web/src/components/chat/workspaceFileDrop.ts (dropping files anywhere over the conversation)
#   packages/contracts/src/rpc.ts (attachments upload URL and claim)
#   apps/web/src/components/chat/ChatComposer.tsx (Paste as Text shortcut bypasses auto-attachment)
#   apps/web/src/components/chat/SnapShotAttachmentDetails.tsx (source app, window and accessibility data)
#   apps/web/src/components/chat/composerAttachmentFiles.ts (which pasted and dropped files are taken, image
#     types, what the server accepts)
#   apps/web/src/components/composerContextPresentation.tsx (a draft file's upload state, preview, attach again)
#   apps/web/src/composerDraftStore.ts (files whose upload a restart interrupted)
#   apps/web/src/lib/attachmentUploadQueue.ts (upload limit per MC, timeout, failure reasons, kept files)
#   apps/web/src/lib/imageCompression.ts (HEIC conversion, size ceilings, downscale ladder)
#   apps/web/src/components/chat/composerSubmission.ts (what a message without text sends)
#   packages/client-runtime/src/textPaste.ts (when a paste is folded into a file, its name)

Feature: Attaching images and files to a message
  The user adds images and files to a turn by choosing, dropping, pasting or
  naming them. Limits are enforced before anything is sent, and an attachment
  that cannot be added says why.

  Background:
    Given a project with an open thread

  @desktop
  Scenario: The user attaches an image by choosing it
    When the user chooses "screenshot.png" to attach
    Then the draft carries "screenshot.png"
    And sending the message sends the image with it

  @desktop
  Scenario: The user attaches images by dropping them on the composer
    When the user drops "a.png" and "b.jpg" onto the composer
    Then the draft carries both images

  @backlog @desktop
  Scenario: Files dragged anywhere over the conversation can be dropped to attach
    When the user drags "a.png" and the folder "src/components" from the desktop over the conversation
    Then the conversation says "Drop files to attach"
    When the user drops them there
    Then the draft carries "a.png" and references the folder "src/components"

  @backlog @desktop
  Scenario: The drop hint goes when the drag leaves or is not of files
    Given the user is dragging "a.png" over the conversation
    When the drag leaves the conversation
    Then the conversation no longer says "Drop files to attach"
    And dragging selected text over the conversation never shows it

  @desktop @tui
  Scenario: Removing an attachment takes it out of the draft
    Given the draft carries "screenshot.png"
    When the user removes "screenshot.png"
    Then the draft carries no attachments
    And the typed text is unchanged

  @tui
  Scenario Outline: A pasted image path becomes an attachment and the rest stays as text
    When the user pastes <pasted> into the prompt
    Then "<file>" is attached
    And the prompt text reads "<remaining>"

    Examples:
      | pasted                            | file         | remaining    |
      | '/home/me/shots/bug.png'          | bug.png      |              |
      | '~/shots/my bug.png' look at this | my bug.png   | look at this |
      | docs/diagram.webp                 | diagram.webp |              |

  @tui
  Scenario: An image copied to the clipboard is pasted as an attachment
    Given the terminal can read images from the clipboard
    When the user pastes an image
    Then a clipboard image is attached to the draft

  @desktop
  Scenario Outline: A copied picture pasted into the prompt is attached
    When the user pastes a copied picture into the prompt with <keys>
    Then the draft carries "image.png"

    Examples:
      | keys         |
      | mod+v        |
      | shift+insert |

  @desktop
  Scenario Outline: A file copied in a file manager pasted into the prompt is attached
    When the user pastes "<file>" copied with <text> into the prompt
    Then the draft carries "<file>"

    Examples:
      | file       | text                     |
      | schema.sql | no text                  |
      | schema.sql | its path as text         |
      | schema.sql | its URL as text          |
      | café.sql   | its encoded URL as text  |

  @tui @desktop @backlog-desktop
  Scenario Outline: An image that cannot be attached is refused with a reason
    When the user tries to attach <image>
    Then nothing is attached
    And the user is told "<message>"

    Examples:
      | image                                | message                                 |
      | a 12 MB photo                        | Image exceeds the 10MB attachment limit. |
      | an empty image file                  | Image file is empty.                    |
      | a file that is not a supported image | Select a supported image file.          |
      | an image that is already attached    | bug.png is already attached.            |
      | a 101st image                        | You can attach up to 100 images.        |

  @mc
  Scenario Outline: The MC refuses uploads over its size limit
    When a client asks to upload a <kind> of <size>
    Then the MC refuses with "Attachments may be at most <limit> MB."

    Examples:
      | kind  | size  | limit |
      | image | 11 MB | 10    |
      | file  | 51 MB | 50    |

  @mc
  Scenario: An upload that is never sent is cleaned up after a day
    Given a client uploaded "notes.pdf" but never sent a message with it
    When more than 24 hours pass
    Then the MC discards the unclaimed upload

  @desktop @mobile @backlog-mobile
  Scenario: A failed upload blocks sending until it is retried or removed
    Given the upload of "design.pdf" failed
    When the user tries to send the message
    Then the user is asked to retry or remove failed uploads before sending
    When the user retries the upload and it succeeds
    Then the message can be sent

  @desktop
  Scenario: A very large paste becomes a text file attachment
    When the user pastes 40 KiB of log output
    Then the paste is attached as a text file instead of being inserted
    And the user is told the paste was attached
    When the user removes the attachment and pastes the log as plain text instead
    Then the text is inserted into the draft where it can be edited

  # Legacy: packages/client-runtime/src/textPaste.ts (pastedTextDisposition, nextPastedTextFileName, wouldTextPasteExceedLimit)
  @backlog @desktop
  Scenario Outline: A paste is folded into a text file when it is big or would not fit
    When the user pastes <paste>
    Then the paste is <result>

    Examples:
      | paste                                                       | result                       |
      | 20 000 characters of text that take over 32 KiB as UTF-8    | attached as a text file      |
      | 20 000 plain characters                                     | inserted as text             |
      | a short line that would take the draft over its text limit  | attached as a text file      |
      | a large log while the draft cannot take another attachment  | inserted as text             |

  # Legacy: packages/client-runtime/src/textPaste.ts (nextPastedTextFileName)
  @backlog @desktop
  Scenario: Several folded pastes in one draft get distinct names
    Given the draft already carries "pasted-text.txt"
    When the user pastes another large log
    Then it is attached as "pasted-text-2.txt"
    And the next one is "pasted-text-3.txt"
    And a name differing only in case counts as taken

  @desktop
  Scenario: Dropping a folder references its path
    Given the environment is local
    When the user drops the folder "src/components" onto the composer
    Then the draft references the folder "src/components"

  @desktop
  Scenario: Dropping a folder into a remote environment is refused
    Given the environment is remote
    When the user drops a folder onto the composer
    Then the user is told folders cannot be dropped into remote environments
    And the user is told to type the folder path instead

  @desktop
  Scenario: Paste as Text keeps a very large paste in the draft
    When the user pastes 40 KiB of log output with Paste as Text
    Then the text is inserted into the draft where it can be edited
    And nothing is attached

  @desktop
  Scenario: A Snap Shot attachment names the window it came from
    Given the draft carries a Snap Shot of the "Terminal" window titled "npm test"
    When the user looks at the attachment
    Then it names the app "Terminal" and the window "npm test"

  @desktop
  Scenario Outline: The user checks what text a Snap Shot captured
    Given the draft carries a Snap Shot <captured>
    When the user opens the Snap Shot's accessibility data
    Then the user sees <shown>

    Examples:
      | captured                                       | shown                                              |
      | with the window's accessibility text           | the captured text                                  |
      | with accessibility elements that have no names | that the elements have no readable names or values |
      | without accessibility data                     | that the app did not provide accessibility data    |

  @backlog @desktop
  Scenario: A message takes at most 100 attachments, images and files together
    Given the draft carries 100 attachments
    When the user attaches "notes.pdf"
    Then "notes.pdf" is not attached
    And the user is told "You can attach up to 100 files per message."

  @backlog @desktop
  Scenario: An image in a format no provider reads is refused, not attached as a file
    When the user attaches the image "scan.tiff"
    Then nothing is attached
    And the user is told "'scan.tiff' is not a supported image type. Attach GIF, HEIC, HEIF, JPEG, PNG, or WebP images."

  @backlog @desktop
  Scenario Outline: An image the system gives no type for is recognised by its name
    When the user attaches "<name>" and the system reports <reported>
    Then "<name>" is attached as <kind>

    Examples:
      | name       | reported            | kind     |
      | photo.heic | no type             | an image |
      | shot.png   | a generic file type | an image |
      | clip.mov   | no type             | a video  |
      | data.xyz   | no type             | a file   |

  @backlog @desktop
  Scenario: An image over the size limit is scaled down to fit instead of being refused
    When the user attaches a 12 MB photo
    Then the photo is attached at a size under 10 MB
    And a photo already under the limit is attached unchanged

  @backlog @desktop
  Scenario Outline: An image that cannot be made to fit says why
    When the user attaches "huge.png" and <problem>
    Then nothing is attached
    And the user is told "<message>"

    Examples:
      | problem                                  | message                                                     |
      | it is still too large after scaling down | 'huge.png' is too large to attach, even after compression.  |
      | it is not a readable image               | 'huge.png' could not be read as an image.                   |

  # Legacy: apps/web/src/lib/imageCompression.ts (prepareImageForAttachment, MAX_COMPRESSIBLE_SOURCE_BYTES, MAX_HEIC_DECODE_PIXELS)
  @backlog @desktop
  Scenario: A HEIC photo is attached as a JPEG
    When the user attaches "IMG_2041.heic"
    Then "IMG_2041.jpg" is attached
    And it fits within the size limit

  @backlog @desktop
  Scenario Outline: A photo too big to even try scaling down is refused
    When the user attaches <photo>
    Then nothing is attached
    And the user is told "<message>"

    Examples:
      | photo                                   | message                                                     |
      | a 60 MB photo "huge.png"                | 'huge.png' is too large to attach, even after compression.  |
      | a HEIC photo "wide.heic" of 100 million pixels | 'wide.heic' is too large to attach, even after compression.  |

  @backlog @desktop
  Scenario: A HEIC file that cannot be decoded says it could not be read
    When the user attaches "broken.heic" that is not a readable image
    Then nothing is attached
    And the user is told "'broken.heic' could not be read as an image."

  @backlog @desktop
  Scenario: A very large photo is scaled to a longest side of 2048 pixels before quality is given up
    When the user attaches a 6000 by 4000 pixel photo over the size limit
    Then the attached photo's longest side is at most 2048 pixels

  @backlog @desktop
  Scenario: A message is not sent while a pasted image is still being scaled down
    Given the user pasted a large image that is still being prepared
    When the user sends the message
    Then nothing is sent
    And the user sees an "info" toast "Still compressing a pasted image." saying "Send again once its thumbnail appears."

  @backlog @desktop
  Scenario: A file that is empty or unreadable is refused
    When the user attaches the empty file "notes.txt"
    Then nothing is attached
    And the user is told "'notes.txt' is empty or could not be read."

  @backlog @desktop
  Scenario: Removing an image the text refers to asks first
    Given the draft carries "cart.png" and its text refers to that image twice
    When the user removes "cart.png"
    Then the user is asked "Remove cart.png from the message? It is referenced in your text; removing it also removes every reference."
    When the user confirms
    Then the draft carries no attachments and its text no longer refers to the image

  @backlog @desktop
  Scenario: Pasting text copied with a picture attaches the picture and keeps the text
    When the user pastes a clipboard that holds a picture and text
    Then the picture is attached
    But a clipboard that holds text and a file that is not a picture pastes only the text

  @backlog @desktop
  Scenario: A paste too large to carry at all is refused
    Given the draft cannot take another attachment
    When the user pastes more text than a message can carry
    Then nothing is pasted
    And the user sees an "error" toast "Pasted text is too large for this message" saying "Remove some text or an attachment, then paste again."

  @backlog @desktop
  Scenario: A paste larger than the MC accepts as a file is refused
    When the user pastes more text than the MC accepts as one file
    Then nothing is pasted
    And the user sees an "error" toast "Pasted text is too large to attach" saying "Reduce the clipboard contents or save a smaller excerpt as a file."

  @backlog @desktop
  Scenario: A large paste says how to keep it as text
    When the user pastes 40 KiB of log output
    Then the user is told the paste was attached, its size, and the shortcut that pastes it as text instead

  @backlog @desktop
  Scenario: Something dropped while the composer cannot take it is refused
    Given the composer is busy
    When the user drops a file from the file tree onto the composer
    Then the user sees an "error" toast "Unable to add to chat" saying "The composer is busy; try again once it is ready."

  @backlog @desktop
  Scenario: A dropped folder whose path cannot be read says what to do instead
    Given the environment is local
    When the user drops the folder "assets" and its path cannot be read
    Then the user sees an "error" toast "Couldn't get the path of "assets"" saying "Type the folder path with @ instead."

  @backlog @desktop
  Scenario: A draft file shows its upload as it goes
    When the user attaches "design.pdf"
    Then the file is shown with its size and how far the upload has got
    When the upload fails
    Then the file is marked as failed with the reason

  @backlog @desktop
  Scenario: A draft file opens for a look before it is sent
    Given the draft carries "design.pdf" and the video "demo.mp4"
    When the user opens "design.pdf" from the draft
    Then the file is shown in the file viewer
    When the user opens "demo.mp4" from the draft
    Then the video plays

  @backlog @desktop
  Scenario: A long attachment name is shortened in the middle and keeps its ending
    When the user attaches "quarterly-revenue-forecast-final-reviewed-v12.xlsx"
    Then its name is shown shortened in the middle, still ending in ".xlsx"

  @backlog @desktop
  Scenario: A file whose upload a restart interrupted has to be attached again
    Given "design.pdf" was still uploading when the app was closed
    When the user opens the draft again
    Then "design.pdf" is listed as needing to be attached again
    And resting on it reads "design.pdf was not saved with this draft. Attach it again to send it."

  @backlog @desktop
  Scenario Outline: An interrupted file blocks sending until it is attached again or removed
    Given the draft lists <files> whose upload a restart interrupted
    When the user tries to send the message
    Then nothing is sent
    And the user is told "<message>"

    Examples:
      | files     | message                                           |
      | one file  | Attach the interrupted file again or remove it    |
      | two files | Attach the interrupted files again or remove them |

  @backlog @desktop
  Scenario: Attaching an interrupted file again takes its old place
    Given the draft carries 100 attachments, one of them "design.pdf" whose upload a restart interrupted
    When the user attaches "design.pdf" again
    Then "design.pdf" uploads in the place it had
    And the draft still carries 100 attachments

  @backlog @desktop
  Scenario Outline: Files wait for an MC that can take them
    Given the draft carries "design.pdf"
    And <situation>
    When the user tries to send the message
    Then nothing is sent
    And the user is told "<message>"

    Examples:
      | situation                                             | message                                                                           |
      | the MC has not yet said what it accepts               | Waiting for the server before file attachments can send                           |
      | the MC stopped accepting files                        | This server does not accept file attachments right now. Remove the files to send. |
      | the MC now accepts only files smaller than this one   | that "design.pdf" is larger than the MC accepts                                   |

  @backlog @desktop
  Scenario: An MC that takes no files says so when one is attached
    Given the MC accepts images but no other files
    When the user attaches "design.pdf"
    Then nothing is attached
    And the user is told "This server does not support file attachments."
    But an image can still be attached and sent

  @backlog @desktop
  Scenario: Files already uploaded are kept when the MC stops taking uploads
    Given "design.pdf" finished uploading and "trace.log" is still uploading
    When the MC stops accepting uploads
    Then the draft still carries "design.pdf"
    And "trace.log" is no longer uploading

  # Legacy: apps/web/src/lib/attachmentUploadQueue.ts (MAX_UPLOADS_PER_ENVIRONMENT, UPLOAD_TIMEOUT_MS)
  @backlog @desktop
  Scenario: At most three files upload to one MC at a time
    Given the user attaches five files to a thread on "studio"
    Then three of them upload at once
    And the other two wait their turn and start as earlier ones finish

  @backlog @desktop
  Scenario: A stalled upload to one MC does not hold up uploads to another
    Given three uploads to "studio" are stalled
    When the user attaches a file to a thread on "laptop"
    Then the file uploads to "laptop" right away

  @backlog @desktop
  Scenario: An upload that has gone five minutes without finishing is marked as timed out
    Given the upload of "design.pdf" has run for five minutes
    Then "design.pdf" is marked as failed with "Upload timed out"
    And the user can retry it or remove it

  @backlog @desktop
  Scenario: A file the draft kept but the MC has since discarded must be attached again
    Given the draft carries "design.pdf" that was uploaded and the MC has discarded the upload since
    When the user opens the draft
    Then "design.pdf" is marked as failed with "Uploaded file expired. Remove it and attach it again."

  @backlog @desktop
  Scenario: A kept file that cannot be checked while the MC is away is checked again on retry
    Given the draft carries "design.pdf" that was uploaded
    And the MC cannot be reached when the app checks it
    Then "design.pdf" is marked as failed with "Uploaded file could not be verified. Retry when the server reconnects."
    When the MC is reachable again and the user retries
    Then "design.pdf" is kept without being uploaded again

  @backlog @desktop
  Scenario: A file whose original is gone says so instead of uploading
    Given the draft carries "design.pdf" whose original file can no longer be read
    When its upload is due to start
    Then "design.pdf" is marked as failed with "Original file is no longer available"

  @backlog @desktop
  Scenario: A file waiting to upload to an MC that is not connected says so
    Given the user attaches "design.pdf" to a thread on "studio" while "studio" is not connected
    Then "design.pdf" is marked as failed with "Not connected"
    And the user can retry it once "studio" is connected

  @backlog @desktop
  Scenario: An upload the MC would not begin says it could not start
    Given the MC refuses to prepare an upload for "design.pdf"
    When the user attaches "design.pdf"
    Then "design.pdf" is marked as failed with "Upload could not start"
    And the user can retry it or remove it

  @backlog @desktop
  Scenario: An image attached to a draft that already has text is placed in the text
    Given the user has typed "compare this with"
    When the user pastes the image "cart.png" at the end of the text
    Then the draft's text refers to "cart.png" where the caret was
    And "cart.png" is attached to the draft

  @backlog @desktop
  Scenario: An image attached to an empty draft is not written into the text
    Given the composer is empty
    When the user pastes the image "cart.png"
    Then "cart.png" is attached to the draft
    And the draft's text is still empty

  @backlog @desktop
  Scenario Outline: An image attached while the composer takes no typing is still shown in the draft
    Given the composer is empty and <state>
    When the user drops the image "cart.png" on the composer
    Then "cart.png" is attached and the draft's text refers to it

    Examples:
      | state                                  |
      | the environment is still connecting    |
      | an approval is waiting for the user    |
      | the user has not chosen a project yet  |

  @backlog @desktop
  Scenario: A draft image that could not be kept on this device says it may be lost
    Given the app could not keep a copy of the draft image "cart.png"
    When the user looks at the draft
    Then "cart.png" is marked with "Draft attachment could not be saved locally and may be lost on navigation."
    And the image can still be sent
