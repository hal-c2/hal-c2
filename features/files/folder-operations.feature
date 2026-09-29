# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/FolderExplorer.qml
#   apps/desktop-qt/qml/HalC2/Bricks/FolderOperationDialog.qml
#   apps/desktop-qt/src/LocalFolderModel.cpp
#   apps/desktop-qt/src/ShellBridge.cpp (localFolderImportEnabled)
#   apps/desktop-qt/examples/folders/shell.qml
#   apps/desktop-qt/tests/native/tst_FolderExplorer.cpp
#   apps/desktop-qt/tests/native/tst_LocalFolderModel.cpp
#
# Desktop status: the FolderExplorer brick delivers all of this natively, but only the
# examples/folders shell places it, not DefaultShell. tst_FolderExplorer and
# tst_LocalFolderModel test the model and dialogs; no test runs these scenarios yet.

Feature: Managing folders on disk from the desktop app
  The desktop app can browse local folders and create, rename, move, or trash them. It
  never overwrites anything and never moves a folder that a project still points at.

  Background:
    Given the desktop app is connected to its own local environment
    And the user manages the folder "/home/sam/code"

  @desktop @backlog-desktop
  Scenario: Folder management is only offered for the local environment
    Given the desktop app shows an environment on another machine
    When the user opens the folder explorer
    Then the user is told folder management needs a connected local environment

  @desktop @backlog-desktop
  Scenario: The explorer starts at the project the user is looking at
    Given the user is looking at a thread in the project at "/home/sam/code/shop"
    When the user opens the folder explorer
    Then the explorer shows "/home/sam/code/shop"

  @desktop @backlog-desktop
  Scenario Outline: Folders that are too broad or unsafe cannot be chosen to manage
    When the user chooses to manage <folder>
    Then the user is told to choose an existing local folder other than home or a filesystem root

    Examples:
      | folder                      |
      | the home folder             |
      | the filesystem root         |
      | a link to another folder    |
      | a folder that does not exist |

  @desktop @backlog-desktop
  Scenario: Files are shown but cannot be changed
    When the user selects the file "notes.txt"
    Then the user is told files are shown read-only

  @desktop @backlog-desktop
  Scenario: Creating a folder
    When the user creates the folder "api" in "/home/sam/code"
    Then "/home/sam/code/api" exists
    And the user is told the folder was updated on disk

  @desktop @backlog-desktop
  Scenario: Renaming a folder keeps its contents
    Given "/home/sam/code/old" holds "a.txt"
    When the user renames "old" to "new"
    Then "/home/sam/code/new/a.txt" exists
    And "/home/sam/code/old" does not exist

  @desktop @backlog-desktop
  Scenario: Moving a folder keeps its contents
    Given "/home/sam/code/tmp" holds "a.txt"
    When the user moves "tmp" into "/home/sam/code/archive"
    Then "/home/sam/code/archive/tmp/a.txt" exists

  @desktop @backlog-desktop
  Scenario: Moving a folder into itself is refused
    When the user moves "archive" into "/home/sam/code/archive/2025"
    Then the user is told a folder cannot be moved into itself or one of its descendants

  @desktop @backlog-desktop
  Scenario Outline: Names that would overwrite or escape are refused
    When the user <operation> using "<name>"
    Then the user is told "<message>"
    And nothing on disk changes

    Examples:
      | operation                   | name     | message                                                                    |
      | creates a folder            | shop     | A file or folder already exists with that name.                            |
      | renames "old"               | a/b      | Enter one folder name, without path separators or leading/trailing whitespace. |
      | moves "tmp" into a folder   | archive  | The destination already exists. Nothing was overwritten.                   |

  @desktop @backlog-desktop
  Scenario Outline: Folders that are or contain a project cannot be renamed, moved or trashed
    Given "/home/sam/code/clients/shop" is a registered project
    When the user tries to <operation> "<folder>"
    Then the user is told the location is protected because threads may still use that path

    Examples:
      | operation         | folder                     |
      | rename            | /home/sam/code/clients/shop |
      | move              | /home/sam/code/clients     |
      | move to the Trash | /home/sam/code/clients     |

  @desktop @backlog-desktop
  Scenario: An ordinary folder inside a project can still be changed
    Given "/home/sam/code/shop" is a registered project
    When the user renames "/home/sam/code/shop/tmp" to "scratch"
    Then "/home/sam/code/shop/scratch" exists

  @desktop @backlog-desktop
  Scenario: Trashing a folder requires typing its name
    When the user asks to move "tmp" to the Trash
    Then the user is told it moves the folder to the system Trash and keeps projects and conversations
    And the Trash cannot be confirmed until the user types "tmp"

  @desktop @backlog-desktop
  Scenario: A trashed folder can be recovered from the system Trash
    When the user moves "tmp" to the Trash and confirms with its name
    Then "/home/sam/code/tmp" is in the system Trash
    And the user is told the folder moved to the system Trash

  @desktop @backlog-desktop
  Scenario: A folder that cannot be trashed is left in place
    Given the system Trash is unavailable
    When the user moves "tmp" to the Trash and confirms with its name
    Then the user is told it could not be moved and was not permanently deleted
    And "/home/sam/code/tmp" still exists

  @desktop @backlog-desktop
  Scenario: Cancelling a folder operation leaves the disk unchanged
    When the user starts renaming "old" and cancels
    Then "/home/sam/code/old" still exists

  @desktop @backlog-desktop
  Scenario: A managed folder replaced by a link is no longer managed
    Given the user manages "/home/sam/code"
    When "/home/sam/code" is replaced by a link to another folder
    Then the user is told the selected root is no longer a plain local folder

  @backlog @desktop
  Scenario: Opening a managed folder as a project
    When the user opens "/home/sam/code/api" as a project
    Then the project "api" is listed
    And a draft thread opens in "api"
