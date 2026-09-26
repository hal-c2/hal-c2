# Sources:
#   apps/tui/src/components/FilesView.tsx, FilesView.test.tsx
#   apps/tui/src/fileTree.ts, fileTree.test.ts
#   apps/tui/src/diffSplit.ts (filetypeForPath highlighting)
#   apps/tui/src/components/ChatView.tsx (Browse files, Attach image)
#   apps/tui/src/connection.ts (readFileBase64) needs base64 reads; apps/server-ex/lib/hal_c2/workspace.ex read_file
#     returns text only and refuses binary files, so attaching from the browser is backlog on hal-c2.
#   apps/tui/src/hooks/useKeyBindings.ts (files mode)
#   apps/tui/src/features.backlog.test.ts (project-lifecycle, project-scripts, workspace-file-actions,
#     preview-surface)
#   Shared domain: files/ owns the explorer, project scripts and actions; preview/ owns previews.

Feature: Browsing workspace files and projects in the terminal
  The user can look through the thread's workspace, read a file with highlighting, and pick
  an image to attach, all from the keyboard.

  Background:
    Given the terminal client is open on a thread whose workspace is "~/code/shop"

  @tui
  Scenario: Browse files lists the workspace as a tree
    When the user chooses "Browse files" from the command palette
    Then the workspace name is shown above a tree of folders and files

  @tui
  Scenario: Opening a folder shows what is inside it
    Given the file browser is open
    When the user moves to the folder "src" and presses "Enter"
    Then the files inside "src" are listed

  @tui
  Scenario: Going back leaves the current folder
    Given the file browser is inside "src"
    When the user goes up to ".."
    Then the workspace root is listed again

  @tui
  Scenario: Opening a file shows it with syntax highlighting
    Given the file browser is open
    When the user opens "src/app.ts"
    Then the file's name is shown above its contents
    And the contents are highlighted as TypeScript

  @tui
  Scenario: Esc steps back out of a file and then out of the browser
    Given the user is reading "src/app.ts" in the file browser
    When the user presses "Esc"
    Then the tree is shown again
    And pressing "Esc" once more returns to the conversation

  @tui
  Scenario: An empty workspace says there are no files
    Given the workspace has no files
    When the user browses files
    Then the browser says there are no files

  @tui
  Scenario: A listing that fails shows the error
    Given the workspace cannot be listed
    When the user browses files
    Then the browser shows the error

  @tui
  Scenario: A file that cannot be read shows the error
    Given "secret.bin" cannot be read
    When the user opens "secret.bin"
    Then the browser shows the read error

  @backlog @tui
  Scenario: The user attaches an image by picking it from the workspace
    When the user chooses "Attach image" from the command palette
    Then the file browser opens and says Enter attaches the selection
    And choosing "assets/logo.png" attaches it to the prompt

  @tui
  Scenario: Attach image is not offered when the prompt is full
    Given the prompt already has the most attachments a turn allows
    When the user opens the command palette
    Then "Attach image" is not offered

  @tui
  Scenario: Windows paths group into the same tree
    Given the workspace listing uses backslash separators
    Then the tree groups them into the same folders as forward slashes

  @backlog @tui
  Scenario: The user renames a project or changes its default model
    When the user renames the project "shop" to "storefront"
    Then the project is listed as "storefront"

  @backlog @tui
  Scenario: Projects on several environments group as one
    Given the project "shop" exists on two environments
    Then the thread list groups both under one "shop"

  @backlog @tui
  Scenario: The user removes a project
    When the user removes the project "shop"
    Then "shop" and its threads leave the thread list
    And the project folder on disk is untouched

  @backlog @tui
  Scenario: The user runs the project's preferred script
    Given "shop" has the preferred script "dev"
    When the user runs the project script
    Then "dev" runs in a terminal and its progress shows there

  @backlog @tui
  Scenario: The user picks another project script
    Given "shop" has the scripts "dev", "test" and "lint"
    When the user runs "test"
    Then "test" runs in a terminal

  @backlog @tui
  Scenario: A failing project script is reported
    When a project script exits with an error
    Then the terminal shows the failure and the status line reports it

  @backlog @tui
  Scenario: The user adds or edits a project script
    When the user adds the script "build" to "shop"
    Then "build" is offered with the other scripts

  @backlog @tui
  Scenario: Image and Markdown files preview in the browser
    When the user opens "README.md" in the file browser
    Then it is shown as rendered Markdown

  @backlog @tui
  Scenario: The user edits and saves a file with conflict handling
    Given the user is editing "src/app.ts"
    And the file changed on disk since it was opened
    When the user saves
    Then the client warns about the conflict instead of overwriting

  @backlog @tui
  Scenario: The user opens a file in their editor
    When the user opens "src/app.ts" in their editor
    Then the file opens in the user's editor

  @backlog @tui
  Scenario: The user lists and opens preview URLs
    Given the dev server announced "http://localhost:5173"
    When the user opens the preview list
    Then "http://localhost:5173" is listed and can be opened or copied

  @backlog @tui
  Scenario: The user refreshes and closes a preview
    Given a preview is open
    When the user closes it
    Then it leaves the preview list

  @backlog @tui
  Scenario: A script's auto-open URL appears as a preview
    Given a project script is set to open its URL
    When the script prints its URL
    Then the URL is added to the preview list
