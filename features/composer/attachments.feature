# Sources:
#   docs/user/composer.md (attachments, large pastes, images, prompt stash files)
#   apps/server-ex/lib/hal_c2/attachments.ex (upload URL, claim, size limits, pending expiry)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (image picker, file drop, attachment removal)
#   apps/tui/src/composerAttachments.ts (image paths in prompts and editor output)
#   apps/tui/src/components/ChatView.tsx (clipboard image paste, image-only prompts, files browser attach)
#   apps/web/src/chatAttachment.ts (message and attachment limits)
#   apps/web/src/components/chat/ChatComposer.tsx (paste, drop, upload and folder toasts)
#   apps/web/src/components/ChatView.tsx (failed uploads block sending)
#   packages/contracts/src/rpc.ts (attachments upload URL and claim)
#   apps/web/src/components/chat/ChatComposer.tsx (Paste as Text shortcut bypasses auto-attachment)
#   apps/web/src/components/chat/SnapShotAttachmentDetails.tsx (source app, window and accessibility data)

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

  @tui
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
