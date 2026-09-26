# Sources:
#   apps/server-ex/lib/hal_c2/workspace.ex (index, list_entries)
#   apps/web/src/components/files/FileBrowserPanel.tsx
#   apps/web/src/components/files/useDirectoryEntries.ts
#   apps/web/src/components/files/fileTreeDragMention.ts
#   apps/web/src/fileContextMenu.ts
#   apps/tui/src/components/FilesView.tsx
#   apps/tui/src/components/ChatView.tsx (Browse files)
#   apps/tui/src/fileTree.ts
#   apps/mobile/src/features/files/FileTreeBrowser.tsx
#   apps/mobile/src/features/files/useFileTreeEntries.ts
#   packages/contracts/src/filesystem.ts (ProjectListEntriesInput, ProjectEntry)
#   packages/contracts/src/rpc.ts (projects.listEntries)

Feature: Exploring project files
  The user can walk a project's files from any client without leaving the thread.

  Background:
    Given a connected environment with the project "shop"
    And "shop" holds "src/app.ts", "src/lib/cart.ts", "README.md" and an ignored "node_modules" folder

  @node
  Scenario: Listing a folder returns its immediate children including ignored ones
    When a client lists the folder "" of "shop"
    Then "src", "README.md" and "node_modules" are returned
    And "node_modules" is marked as ignored

  @node
  Scenario: Listing a folder never shows git's own folder
    When a client lists the top folder of "shop"
    Then ".git" is not returned

  @node
  Scenario: Asking to list git's own folder is refused
    When a client lists the folder ".git" of "shop"
    Then the node answers with a folder listing failure

  @node
  Scenario: Listing the whole project walks its tracked and untracked files
    Given "shop" is a git repository with an untracked "draft.md"
    When a client lists every entry of "shop"
    Then "src/lib/cart.ts" and "draft.md" are returned
    And nothing under "node_modules" is returned

  @node
  Scenario: Listing a folder that is not a repository skips build and dependency folders
    Given "shop" is not a git repository and holds "dist/app.js" and "_build/x.beam"
    When a client lists every entry of "shop"
    Then nothing under "dist" or "_build" is returned

  @node
  Scenario: A very large project lists a capped set and says so
    Given "shop" holds more than 25,000 files
    When a client lists every entry of "shop"
    Then 25,000 entries are returned
    And the result is marked as truncated

  @node
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

  @backlog @desktop @mobile
  Scenario: Expanding a folder loads its children on demand
    When the user expands "src"
    Then "app.ts" and "lib" are shown under "src"

  @backlog @desktop
  Scenario: Expanding and collapsing every folder at once
    When the user expands every folder
    Then "cart.ts" is visible
    When the user collapses every folder
    Then only the top level is visible

  @backlog @desktop
  Scenario: Filtering the tree can hide entries that do not match
    When the user filters the tree by "cart" and hides non-matches
    Then only "src/lib/cart.ts" and its folders are shown
    When the user stops filtering
    Then the full tree is shown again

  @backlog @desktop
  Scenario: The tree follows the file open in the viewer
    When the user opens "src/lib/cart.ts" from a message
    Then the tree reveals and selects "src/lib/cart.ts"

  @backlog @desktop
  Scenario: The tree refreshes when the agent changes files
    When the agent creates "src/checkout.ts"
    Then "src/checkout.ts" appears in the tree

  @backlog @desktop
  Scenario: A file can be sent to the composer as a mention
    When the user adds "src/app.ts" to the chat
    Then the composer mentions "src/app.ts"

  @backlog @desktop
  Scenario: Adding a file to the chat without an open chat is refused
    Given no chat is open for "shop"
    When the user adds "src/app.ts" to the chat
    Then the user is told to open a chat for this project and try again

  @backlog @desktop
  Scenario Outline: File actions available from a file entry
    When the user chooses to <action> "src/app.ts"
    Then <outcome>

    Examples:
      | action                     | outcome                                          |
      | open                       | the file opens in the viewer                     |
      | reveal in its folder       | the system file manager shows the file           |
      | open with the editor       | the file opens in the user's editor              |
      | copy a mention of          | a mention of "src/app.ts" is on the clipboard    |

  @backlog @desktop @mobile
  Scenario: A folder that fails to load can be retried
    Given listing "src" fails once
    When the user expands "src"
    Then the user is told the folder could not be loaded
    When the user retries
    Then "app.ts" is shown under "src"
