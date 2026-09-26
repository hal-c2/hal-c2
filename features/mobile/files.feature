# Sources:
#   apps/mobile/src/features/files/ (tree, search, previews, copy, save or share, attachments)
#   apps/mobile/src/features/files/ThreadFilesRouteScreen.tsx
#   apps/mobile/src/features/files/FileTreeBrowser.tsx
#   apps/mobile/src/features/files/SourceFileSurface.tsx
#   docs/internals/mobile-navigation.md (AVKit video, Quick Look previews)
# Workspace files are specified in features/source-control/ and the files domain. This file
# covers browsing and previewing them on a phone.

Feature: Browsing a thread's files on a phone
  The user can browse and search the thread's workspace, read files with a sensible
  preview, and hand them to other apps.

  Background:
    Given the phone is paired with "My MacBook"
    And the user is in the thread "Fix checkout"

  @backlog @mobile
  Scenario: The user browses the workspace tree
    When the user opens the thread's files
    Then the top-level folders and files of the workspace are listed
    When the user opens the folder "src"
    Then the files in "src" are listed

  @backlog @mobile
  Scenario: The user searches the workspace by file name
    When the user searches files for "cart"
    Then "src/cart.ts" is listed

  @backlog @mobile
  Scenario: The user refreshes the file tree
    Given the agent has created "src/tax.ts" since the tree was loaded
    When the user refreshes the files
    Then "src/tax.ts" is listed

  @backlog @mobile
  Scenario: An empty workspace says so
    Given the thread's workspace has no files
    When the user opens the thread's files
    Then the user is told the workspace is empty

  @backlog @mobile
  Scenario: A thread without a workspace cannot show files
    Given the thread has no active workspace
    When the user opens the thread's files
    Then the user is told files are unavailable because there is no workspace

  @backlog @mobile
  Scenario Outline: The user switches how a file is shown
    Given the user opened "<file>"
    When the user shows it as <view>
    Then the file is shown as <view>

    Examples:
      | file        | view     |
      | README.md   | preview  |
      | README.md   | source   |
      | prices.csv  | table    |
      | prices.csv  | source   |

  @backlog @mobile
  Scenario: The user toggles word wrap
    Given the user opened a source file with long lines
    When the user turns word wrap on
    Then long lines wrap
    When the user turns word wrap off
    Then long lines scroll sideways

  @backlog @mobile
  Scenario Outline: Media files open in a native preview
    When the user opens "<file>"
    Then "<file>" is shown as <preview>

    Examples:
      | file       | preview                 |
      | shot.png   | an image                |
      | demo.mp4   | a playable video        |
      | spec.pdf   | a PDF                   |
      | index.html | a web page              |

  @backlog @mobile
  Scenario: A file too large to load fully is marked partial
    When the user opens a very large log file
    Then the start of the file is shown
    And the user is told it is a partial file

  @backlog @mobile
  Scenario Outline: The user copies from a file
    Given the user opened "src/cart.ts"
    When the user copies the <what>
    Then the <what> is on the clipboard

    Examples:
      | what          |
      | path          |
      | contents      |

  @backlog @mobile
  Scenario: A file with no preview offers to save or share it
    When the user opens a file the phone cannot preview
    Then the user is told there is no preview for this file
    And the user is offered to save or share it

  @backlog @mobile
  Scenario: A file deleted by the agent says it no longer exists
    Given the user opened "src/old.ts"
    When the agent deletes "src/old.ts"
    And the user refreshes the file
    Then the user is told the file no longer exists

  @backlog @mobile
  Scenario: Files seen before are browsable offline
    Given the user browsed "src" earlier
    And "My MacBook" is unreachable
    When the user opens the thread's files
    Then the last known tree for "src" is shown

  @backlog @mobile
  Scenario: The user adds a file to the draft from the files browser
    Given the user opened "src/cart.ts"
    When the user adds it to the message
    Then the draft mentions "src/cart.ts"

  @backlog @mobile
  Scenario: A video preview keeps playing when its link would expire
    Given the user is watching "demo.mp4"
    When the time-limited link the video was loaded from expires
    Then the video keeps playing
