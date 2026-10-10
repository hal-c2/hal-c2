# Sources:
#   apps/server-ex/lib/hal_c2/workspace.ex (index, list_entries)
#   apps/web/src/components/files/FileBrowserPanel.tsx
#   apps/web/src/components/files/useDirectoryEntries.ts
#   apps/web/src/components/files/fileTreeDragMention.ts
#   apps/web/src/fileContextMenu.ts
#   apps/tui/src/components/FilesView.tsx
#   apps/server/src/workspace/WorkspaceEntries.ts, WorkspaceSearchIndex.ts (listing limits, ignored files, scan timeout)
#   apps/server/src/workspace/WorkspaceEntries.test.ts (tracked paths under an ignore rule, .convex)
#   apps/tui/src/components/ChatView.tsx (Browse files)
#   apps/tui/src/fileTree.ts
#   apps/mobile/src/features/files/FileTreeBrowser.tsx
#   apps/mobile/src/features/files/useFileTreeEntries.ts
#   packages/contracts/src/filesystem.ts (ProjectListEntriesInput, ProjectEntry)
#   packages/contracts/src/rpc.ts (projects.listEntries)
#   apps/desktop-qt/src/native/WorkspaceFiles.cpp, FileTreeModel.cpp
#   apps/desktop-qt/qml/HalC2/Bricks/FilesPanel.qml
#   apps/desktop-qt/tests/native/features/PanelSteps.cpp

Feature: Exploring project files
  The user can walk a project's files from any client without leaving the thread.

  Background:
    Given a connected environment with the project "shop"
    And "shop" holds "src/app.ts", "src/lib/cart.ts", "README.md" and an ignored "node_modules" folder

  @mc
  Scenario: Listing a folder returns its immediate children including ignored ones
    When a client lists the folder "" of "shop"
    Then "src", "README.md" and "node_modules" are returned
    And "node_modules" is marked as ignored

  @mc
  Scenario: Listing a folder never shows git's own folder
    When a client lists the top folder of "shop"
    Then ".git" is not returned

  @mc
  Scenario: Asking to list git's own folder is refused
    When a client lists the folder ".git" of "shop"
    Then the MC answers with a folder listing failure

  @mc
  Scenario: Listing the whole project walks its tracked and untracked files
    Given "shop" is a git repository with an untracked "draft.md"
    When a client lists every entry of "shop"
    Then "src/lib/cart.ts" and "draft.md" are returned
    And nothing under "node_modules" is returned

  @mc
  Scenario: Listing a folder that is not a repository skips build and dependency folders
    Given "shop" is not a git repository and holds "dist/app.js" and "_build/x.beam"
    When a client lists every entry of "shop"
    Then nothing under "dist" or "_build" is returned

  # Legacy: apps/server/src/workspace/WorkspaceEntries.test.ts (excludes tracked paths that match ignore rules)
  @mc @backlog
  Scenario: A tracked file that an ignore rule now covers is not listed
    Given "shop" is a git repository that tracks ".convex/local-storage/data.json" and "src/keep.ts"
    And ".gitignore" now ignores ".convex/"
    When a client lists every entry of "shop"
    Then "src/keep.ts" is returned
    And nothing under ".convex" is returned

  # Legacy: apps/server/src/workspace/WorkspaceEntries.test.ts (excludes .convex in non-git workspaces)
  @mc @backlog
  Scenario: A local Convex data folder is not listed even without a repository
    Given "shop" is not a git repository and holds ".convex/local-storage/data.json" and "src/keep.ts"
    When a client lists every entry of "shop"
    Then "src/keep.ts" is returned
    And nothing under ".convex" is returned

  @mc
  Scenario: A very large project lists a capped set and says so
    Given "shop" holds more than 25,000 files
    When a client lists every entry of "shop"
    Then 25,000 entries are returned
    And the result is marked as truncated

  # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (list: directory must be inside the workspace)
  @mc @backlog
  Scenario: A folder that is really a link to somewhere outside the project is not listed
    Given "shop" holds a link "outside" to a folder elsewhere on the machine
    When a client lists the folder "outside" of "shop"
    Then the MC answers with a folder listing failure
    And nothing from the linked folder is returned

  # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (list: only files and folders)
  @mc @backlog
  Scenario: Links and special files are not listed as entries
    Given "shop" holds a link to a file and a named pipe next to "README.md"
    When a client lists the folder "" of "shop"
    Then "README.md" is returned
    And the link and the named pipe are not

  # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (list: check-ignore in batches, optional)
  @mc @backlog
  Scenario: A folder of thousands of entries still reports which are ignored
    Given a folder of "shop" holds 5,000 entries and 2,500 of them are ignored
    When a client lists that folder
    Then every entry is returned and the 2,500 are marked as ignored

  # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (list: ignore classification is optional)
  @mc @backlog
  Scenario: A folder is listed even when git cannot say what is ignored
    Given "shop" is not a git repository or git is not installed
    When a client lists the folder "" of "shop"
    Then its entries are returned with none marked as ignored

  # Legacy: apps/server/src/workspace/WorkspaceSearchIndex.ts (withDirectoryAncestors)
  @mc @backlog
  Scenario: A listing includes the folders that hold the files it returns
    Given "shop" holds "src/lib/deep/cart.ts"
    When a client lists every entry of "shop"
    Then "src", "src/lib" and "src/lib/deep" are returned as folders

  # Legacy: apps/server/src/workspace/WorkspaceSearchIndex.ts (scan timeout), WorkspaceEntries.ts
  @mc @backlog
  Scenario: A project too slow to scan answers with an error instead of waiting
    Given scanning the files of "shop" does not finish within 15 seconds
    When a client lists every entry of "shop"
    Then the MC answers that the project's files did not finish scanning in time

  @mc
  Scenario: A written file shows up in the next listing
    When a client writes "src/new.ts" in "shop"
    And a client lists every entry of "shop"
    Then "src/new.ts" is returned

  @tui
  Scenario: The terminal client browses the project's files as a tree
    When the user browses files
    Then folders are listed before files
    And each folder can be expanded and collapsed

  @tui
  Scenario: Closing the file browser returns to the conversation
    Given the user is browsing files
    When the user closes the file browser
    Then the conversation is shown again

  @tui
  Scenario: A project the terminal client cannot list says so
    Given the environment cannot list "shop"
    When the user browses files
    Then the user is told the files could not be listed

  @desktop @mobile @backlog-mobile
  Scenario: Expanding a folder loads its children on demand
    When the user expands "src"
    Then "app.ts" and "lib" are shown under "src"

  @desktop
  Scenario: Expanding and collapsing every folder at once
    When the user expands every folder
    Then "cart.ts" is visible
    When the user collapses every folder
    Then only the top level is visible

  @desktop
  Scenario: Filtering the tree can hide entries that do not match
    When the user filters the tree by "cart" and hides non-matches
    Then only "src/lib/cart.ts" and its folders are shown
    When the user stops filtering
    Then the full tree is shown again

  @desktop
  Scenario: The tree follows the file open in the viewer
    When the user opens "src/lib/cart.ts" from a message
    Then the tree reveals and selects "src/lib/cart.ts"

  @desktop
  Scenario: The tree refreshes when the agent changes files
    When the agent creates "src/checkout.ts"
    Then "src/checkout.ts" appears in the tree

  @desktop
  Scenario: A file can be sent to the composer as a mention
    When the user adds "src/app.ts" to the chat
    Then the composer mentions "src/app.ts"

  @desktop
  Scenario: Adding a file to the chat without an open chat is refused
    Given no chat is open for "shop"
    When the user adds "src/app.ts" to the chat
    Then the user is told to open a chat for this project and try again

  @backlog @desktop
  Scenario: Adding a file to a chat that cannot take input says so
    Given the chat for "shop" is open but not ready to accept input
    When the user adds "src/app.ts" to the chat
    Then the user is told the chat is not ready to accept input right now

  @backlog @desktop
  Scenario Outline: Copying a mention reports how it went
    Given the clipboard <state>
    When the user copies a mention of "src/app.ts"
    Then the user is told <result>

    Examples:
      | state             | result                                              |
      | accepts the text  | the mention was copied, with the path               |
      | refuses the text  | the mention could not be copied, with the reason    |

  @backlog @desktop
  Scenario: The tree and the open file can be refreshed by hand
    Given the tree and the open file were changed on disk outside HAL-C2
    When the user refreshes the files
    Then the tree lists the change
    And the open file shows its new contents
    And an active filter is applied to the new listing

  @backlog @desktop
  Scenario: Choosing a file in the tree does not clear the user's filter
    Given the user filtered the tree by "cart"
    When the user opens "src/lib/cart.ts" from the filtered tree
    Then the file opens and the filter stays as typed
    But opening the same file from a message clears the filter and reveals it

  @desktop
  Scenario Outline: File actions available from a file entry
    When the user chooses to <action> "src/app.ts"
    Then <outcome>

    Examples:
      | action                     | outcome                                          |
      | open                       | the file opens in the viewer                     |
      | reveal in its folder       | the system file manager shows the file           |
      | open with the editor       | the file opens in the user's editor              |
      | copy a mention of          | a mention of "src/app.ts" is on the clipboard    |

  @desktop @mobile @backlog-mobile
  Scenario: A folder that fails to load can be retried
    Given listing "src" fails once
    When the user expands "src"
    Then the user is told the folder could not be loaded
    When the user retries
    Then "app.ts" is shown under "src"

  @desktop
  Scenario: A project the desktop cannot list can be retried
    Given the environment cannot list "shop"
    When the user opens the Files tab
    Then the user is told the files could not be listed
    When the environment can list "shop" again
    And the user retries
    Then the top of "shop" is shown
