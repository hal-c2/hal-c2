# Sources:
#   apps/mobile/src/features/sharing/ (incoming share inbox, project choice, warnings, retry)
#   apps/mobile/src/features/files/ (useFileChipShare, mediaActions: save or share, copy path)
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
    When the user shares <content> to T3 Code from another app
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
    When the user shares two photos to T3 Code
    Then the user is asked which project should receive the 2 images
    When the user chooses "docs"
    Then the new task in "docs" has the 2 images attached

  @backlog @mobile
  Scenario: Backing out of the project choice releases the shared content
    Given the user shared two photos and is choosing a project
    When the user dismisses the choice
    Then no draft keeps the shared photos

  @backlog @mobile
  Scenario: Sharing more items than a task can take keeps the first eight
    When the user shares ten photos to T3 Code on an iPhone
    Then the new task has eight photos attached

  @backlog @mobile
  Scenario: Unsupported shared items are skipped with a warning
    When the user shares a photo and a file the composer cannot accept
    Then the new task has the photo attached
    And the user is told one shared item was not supported

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
  Scenario: Shared content survives the app being killed during import
    Given the user shared a photo to T3 Code
    And the app was closed before the import finished
    When the user opens the app
    Then the import finishes into a new task
    And the photo is attached only once

  @backlog @mobile
  Scenario: Sharing into the app with no paired environment asks the user to pair first
    Given the phone has no paired environments
    When the user shares a photo to T3 Code
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
  Scenario: The user copies a link to a pull request or the thread id
    Given the thread has an open pull request
    When the user copies the pull request link
    Then the pull request link is on the clipboard
