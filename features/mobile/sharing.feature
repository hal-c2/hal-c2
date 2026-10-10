# Sources:
#   apps/mobile/src/features/sharing/ (incoming share inbox, project choice, warnings, retry)
#   apps/mobile/src/features/threads/NewTaskDraftScreen.tsx (share import: cancel, retry, unavailable share, skipped files)
#   apps/mobile/src/state/use-composer-drafts.ts (undoComposerDraftMergeState: a cancelled import keeps later edits)
#   apps/mobile/src/features/files/ (useFileChipShare, mediaActions: save or share, copy path)
#   apps/mobile/src/lib/attachmentDownload.ts (share availability, file names, day-old temporary copies)
#   apps/mobile/src/lib/mediaActions.ts (save or share, copy path, open in file viewer)
#   apps/mobile/src/features/threads/fileChipMenu.ts, useFileChipShare.ts (which choices a file link's menu offers)
#   apps/mobile/app.config.ts (share extension: text, one URL, up to 8 media or files)
#   docs/internals/mobile-navigation.md (Quick Look copies bytes before sharing)
# Composer attachments are specified in features/composer/. This file covers the phone's
# system share sheet in both directions.

Feature: Sharing into and out of the phone app
  Other apps can share text, links, images and files into a new task. Files and media the
  agent produced can be shared out to other apps.

  Background:
    Given the phone is paired with "My MacBook" with the projects "shop" and "docs"

  @backlog @mobile
  Scenario Outline: Sharing into the app starts a task with the shared content
    When the user shares <content> to HAL-C2 from another app
    Then a new task opens with <content> in its draft

    Examples:
      | content             |
      | some text           |
      | a web link          |
      | three photos        |
      | a video             |
      | a PDF               |

  @backlog @mobile
  Scenario: The user chooses which project receives shared content
    When the user shares two photos to HAL-C2
    Then the user is asked which project should receive the 2 images
    When the user chooses "docs"
    Then the new task in "docs" has the 2 images attached

  @backlog @mobile
  Scenario: Backing out of the project choice releases the shared content
    Given the user shared two photos and is choosing a project
    When the user dismisses the choice
    Then no draft keeps the shared photos

  @backlog @mobile
  Scenario: A dismissed share is not offered again while the app stays open
    Given the user shared two photos and dismissed the project choice
    When the app is brought to the front again
    Then the user is not asked again which project should receive the photos

  @backlog @mobile
  Scenario: Shares that are waiting are offered one after the other
    Given the user shared a photo and then some text before choosing a project
    When the user finishes with the first project choice
    Then the user is asked which project should receive the next share

  @backlog @mobile
  Scenario: Content shared while the app is open is offered when the user returns to it
    Given the app is open in the background
    When the user shares a photo to HAL-C2 from another app
    And the user switches to the app
    Then the user is asked which project should receive the photo

  @backlog @mobile
  Scenario: Shared text and links are combined into one message
    When the user shares a web link and then the same web link again with some text
    Then the new task's draft holds the link once and the text after it, each on its own paragraph

  @backlog @mobile
  Scenario: Sharing the same content twice starts two tasks
    Given the user shared a photo and chose a project for it
    When the user shares the same photo again
    Then the user is asked again which project should receive it

  @backlog @mobile
  Scenario: Sharing more items than a task can take keeps the first eight
    When the user shares ten photos to HAL-C2 on an iPhone
    Then the new task has eight photos attached

  @backlog @mobile
  Scenario: Unsupported shared items are skipped with a warning
    When the user shares a photo and a file the composer cannot accept
    Then the new task has the photo attached
    And the user is told one shared item was not supported

  @backlog @mobile
  Scenario: Content the composer cannot take at all is refused once
    When the user shares only a file the composer cannot accept
    Then the user is told the shared content is not supported
    And no task is started
    And the user is not asked again about it when the app returns to the front

  @backlog @mobile
  Scenario Outline: A shared item that breaks a limit is skipped and says why
    When the user shares <item> to HAL-C2
    Then the new task does not have <item> attached
    And the user is told <reason>

    Examples:
      | item                                        | reason                                       |
      | a photo larger than 10 MB                   | the photo exceeds the 10 MB attachment limit |
      | an image type the agents cannot read        | the image is not a supported image type      |
      | a file larger than a file attachment may be | the file is too large to attach              |
      | an empty file                               | the file is empty or could not be read       |
      | a file whose size cannot be determined      | the size of the file could not be determined |

  @backlog @mobile
  Scenario: Shared files are skipped when the environment takes no files
    Given "My MacBook" accepts images but no file attachments
    When the user shares a photo and a PDF to HAL-C2 and chooses "shop"
    Then the new task has the photo attached
    And the user is told the PDF was skipped because the server does not support files

  @backlog @mobile
  Scenario: A shared file with no name is given one
    When the user shares a photo that arrives with no file name
    Then the photo is attached under a name made from its kind and its place in the share

  @backlog @mobile
  Scenario: Sharing a file from another app never removes the original
    Given another app shares a document from its own storage without copying it
    When the user chooses "shop" and the import finishes or fails
    Then the original document is still in the other app

  @backlog @mobile
  Scenario: Shared content already given to another project cannot be given to a second
    Given the shared photos were already given to the new task in "shop"
    When the user tries to give them to the new task in "docs"
    Then the user is told the shared content is already reserved for another project
    And "shop" keeps the photos

  @backlog @mobile
  Scenario: A shared file that cannot be read is reported
    When the user shares a file the phone cannot read
    Then the user is told the shared file could not be read

  @backlog @mobile
  Scenario: A failed import can be retried or dismissed
    Given importing shared content failed
    Then the user is told the shared content could not be imported
    When the user retries
    Then the import runs again

  @backlog @mobile
  Scenario: A failed import can be cancelled and leaves the draft as it was
    Given the draft of the new task held "Fix the cart" before the share arrived
    And importing shared content into it failed
    When the user cancels the import
    Then the draft holds "Fix the cart" again without the shared content
    And the shared content is released so another project can receive it

  @backlog @mobile
  Scenario: Cancelling an import keeps what the user wrote and chose in the meantime
    Given the draft of the new task held "Fix the cart" before the share arrived
    And the shared content was imported into it and then importing failed
    And the user has since added " and the footer" and changed the model
    When the user cancels the import
    Then the draft holds "Fix the cart and the footer" without the shared content
    And the model the user chose is kept

  @backlog @mobile
  Scenario: A cancelled import that cannot restore the draft safely can be tried again
    Given importing shared content failed and the user cancelled the import
    And the draft could not be restored
    Then the user is told the import could not be cancelled and why
    When the user chooses to retry the cancel
    Then the cancel is attempted again
    When the user instead chooses to retry the import
    Then the shared content is imported again

  @backlog @mobile
  Scenario: Shared content that is no longer waiting leaves the task editable
    Given the user opens a new task for shared content that was already taken elsewhere
    Then the user is told the shared content is no longer waiting
    And the user can keep editing the new task

  @backlog @mobile
  Scenario: Shared files that do not fit the draft are skipped and counted
    Given the draft of the new task is already at the attachment limit
    When shared files are imported into it
    Then the user is told how many shared files were skipped because the draft reached the attachment limit
    And the files that did fit are attached

  @backlog @mobile
  Scenario: Shared content is imported once the environment's attachment support is known
    Given the user shared a file and "My MacBook" has not yet said which attachments it takes
    When "My MacBook" reports what it takes
    Then the file is imported into the new task

  @backlog @mobile
  Scenario: Shared content survives the app being killed during import
    Given the user shared a photo to HAL-C2
    And the app was closed before the import finished
    When the user opens the app
    Then the import finishes into a new task
    And the photo is attached only once

  @backlog @mobile
  Scenario: A saved share that cannot be read does not hide the others
    Given two shares are waiting and the saved copy of one cannot be read
    When the user opens the app
    Then the readable share is offered
    And the unreadable one is ignored

  @backlog @mobile
  Scenario: Sharing into the app with no paired environment asks the user to pair first
    Given the phone has no paired environments
    When the user shares a photo to HAL-C2
    Then the user is asked to add an environment
    And the photo is kept until a project can receive it

  @backlog @mobile
  Scenario Outline: The user shares an agent's file out of the app
    Given the agent produced "report.pdf" in the thread
    When the user chooses to <action> "report.pdf"
    Then <outcome>

    Examples:
      | action              | outcome                                          |
      | save or share       | the system share sheet offers "report.pdf"       |
      | copy the full path  | the full path is on the clipboard                |
      | copy the relative path | the path relative to the workspace is on the clipboard |
      | open it in a viewer | "report.pdf" opens in the phone's file viewer     |

  @backlog @mobile
  Scenario Outline: A file link offers only the choices that fit where it points
    Given the agent's reply links <link>
    When the user chooses the link's file menu
    Then the menu offers <offered>

    Examples:
      | link                                                   | offered                                                        |
      | a PDF inside the thread's workspace                    | the full path, the relative path, the viewer and save or share |
      | a file inside the workspace of a type the host does not preview | the full path, the relative path and the viewer |
      | a PDF by its full path outside the workspace           | the full path, the viewer and save or share                    |
      | a path in the home folder or above the workspace       | no menu, because the link is not a file the app can open       |

  @backlog @mobile
  Scenario: Sharing an image out does not change the draft it came from
    Given the draft has a photo attached
    When the user shares the photo out and another app edits it
    Then the photo in the draft is unchanged

  @backlog @mobile
  Scenario: Sharing a file out while offline explains how to recover
    Given "My MacBook" is unreachable
    When the user tries to share "report.pdf" out
    Then the user is told the file could not be shared
    And the user is told to reconnect to the environment and try again

  @backlog @mobile
  Scenario: A phone that cannot save or share files says so before downloading anything
    Given the phone offers no way to save or share files
    When the user tries to share "report.pdf" out
    Then the user is told "Saving and sharing files is unavailable on this device."
    And "report.pdf" is not downloaded

  @backlog @mobile
  Scenario: A share sheet that does not open can be tried again
    When the user shares "report.pdf" out and the share sheet does not open
    Then the user is told "Could not open the share sheet. Try again."
    And the user can share "report.pdf" again

  @backlog @mobile
  Scenario Outline: A file with an awkward name is shared under a name the phone can store
    Given the agent produced a file named <name>
    When the user shares it out
    Then the other app receives it named <shared>

    Examples:
      | name                                              | shared                                                     |
      | "out/report.pdf"                                  | "report.pdf"                                               |
      | "..."                                             | "attachment"                                               |
      | a name longer than the phone's file system allows | the same name cut to fit and still ending in its extension |

  @backlog @mobile
  Scenario: Temporary copies made for sharing are removed after a day
    Given a temporary copy made for sharing is more than a day old
    And a copy made today and a copy still being shared are on the phone
    When the user shares or previews another file
    Then the day-old copy is removed
    And the other two copies are kept

  @backlog @mobile
  Scenario: The user copies a link to a pull request or the thread id
    Given the thread has an open pull request
    When the user copies the pull request link
    Then the pull request link is on the clipboard
