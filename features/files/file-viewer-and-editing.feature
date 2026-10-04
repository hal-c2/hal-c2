# Sources:
#   apps/server-ex/lib/hal_c2/workspace.ex (read_file, write_file, path checks)
#   apps/server-ex/lib/hal_c2/editors.ex (shell.openInEditor)
#   apps/web/src/components/files/FilePreviewPanel.tsx
#   apps/web/src/components/chat/ThreadDetailsPanel.tsx, OpenInPicker.tsx, OpenInPicker.logic.ts (open the workspace)
#   apps/web/src/remoteOpen.ts (SSH deep links for a remote environment; remoteOpenTargets not sent by the MC)
#   apps/web/src/components/files/FileBreadcrumbs.tsx
#   apps/web/src/components/files/fileSaveCoordinator.ts
#   apps/web/src/components/files/fileEditorDismissal.ts
#   apps/web/src/components/files/filePreviewMode.ts
#   apps/web/src/components/files/filePath.ts
#   apps/web/src/components/files/fileContentRevision.ts
#   apps/web/src/components/files/AttachmentFilePreview.tsx (attachments shown like files: Draft origin, remove, download)
#   apps/web/src/components/chat/ExpandedImageDialog.tsx, ExpandedImagePreview.tsx (images from the conversation)
#   apps/web/src/components/chat/ChatComposer.tsx (opening a draft attachment)
#   packages/shared/src/filePreview.ts (preview kinds: image, pdf, markdown, html, text, media)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (draft attachments listed, not opened)
#   apps/tui/src/components/FilesView.tsx
#   apps/tui/src/features.backlog.test.ts (workspace-file-actions)
#   apps/mobile/src/features/files/ThreadFilesRouteScreen.tsx
#   apps/mobile/src/features/files/SourceFileSurface.tsx
#   apps/mobile/src/features/files/WorkspaceFilePreviewError.tsx
#   packages/contracts/src/filesystem.ts (ProjectReadFileInput, ProjectWriteFileInput, ProjectFileError)
#   packages/contracts/src/rpc.ts (projects.readFile, projects.writeFile, shell.openInEditor, assets.createUrl)
#   apps/desktop-qt/src/native/WorkspaceFiles.cpp (openFile, truncatedNotice, revealLine, wrap)
#   apps/desktop-qt/qml/HalC2/Bricks/FilesPanel.qml
#   apps/desktop-qt/tests/native/features/PanelSteps.cpp

Feature: Viewing and editing files
  The user can read any text file in a project, preview media, and make small edits that
  save themselves. Paths never escape the project.

  Background:
    Given a connected environment with the project "shop"
    And "shop" holds the text file "src/app.ts"

  Rule: Reading

    @mc
    Scenario: Reading a text file returns its contents
      When a client reads "src/app.ts" from "shop"
      Then the file's contents are returned
      And the result is not marked as truncated

    @mc
    Scenario: A file larger than one megabyte is returned in part
      Given "logs/big.log" in "shop" is 3 MB
      When a client reads "logs/big.log" from "shop"
      Then the first megabyte is returned
      And the result is marked as truncated

    @mc
    Scenario Outline: Files that cannot be shown as text are refused
      When a client reads "<path>" from "shop" as text
      Then the MC answers that "<path>" <reason>

      Examples:
        | path           | reason              |
        | assets/logo.db | is not a text file  |
        | src            | is not a file       |

    @mc
    Scenario: A binary file can be read as base64
      Given "assets/logo.png" is an image in "shop"
      When a client reads "assets/logo.png" from "shop" as base64
      Then the image bytes are returned

    @mc
    Scenario: A file on the host outside the project can be read by its full path
      Given the host has the file "/home/sam/notes/todo.txt"
      When a client reads "/home/sam/notes/todo.txt" from "shop"
      Then the file's contents are returned
      And the file is marked as one that cannot be written back

    @tui
    Scenario: The terminal client shows an opened file with syntax colouring
      When the user browses files and opens "src/app.ts"
      Then the contents of "src/app.ts" are shown with syntax colouring
      And the user can scroll through the file and go back to the tree

    @tui
    Scenario: The terminal client marks an empty file as empty
      Given "src/empty.ts" in "shop" is empty
      When the user browses files and opens "src/empty.ts"
      Then the user is told the file is empty

    @tui
    Scenario: A file the terminal client cannot read says so
      Given reading "src/app.ts" fails
      When the user browses files and opens "src/app.ts"
      Then the user is told the file could not be read

    @desktop @mobile @backlog-mobile
    Scenario: A partial preview says how much of the file is shown
      Given "logs/big.log" in "shop" is 3 MB
      When the user opens "logs/big.log"
      Then the user is told the preview is limited to the first 1 MB of the file

    @backlog @desktop @mobile
    Scenario Outline: Media files are previewed instead of shown as text
      When the user opens "<path>"
      Then the file is previewed as <kind>

      Examples:
        | path             | kind     |
        | assets/logo.png  | an image |
        | media/intro.mp4  | a video  |
        | media/theme.mp3  | audio    |
        | docs/manual.pdf  | a document |
        | public/index.html | a web page |

    @backlog @desktop @mobile
    Scenario: A media preview that fails to load can be retried
      Given loading "media/theme.mp3" fails once
      When the user opens "media/theme.mp3"
      Then the user is told the audio could not be loaded
      When the user retries
      Then the audio plays

    @desktop @tui
    Scenario Outline: Rendered files can be switched to their source and back
      When the user opens "<path>"
      Then the file is shown rendered
      When the user switches to the source
      Then the file's text is shown
      When the user switches back
      Then the file is shown rendered

      Examples:
        | path            |
        | README.md       |
        | data/orders.csv |
        | public/index.html |

    @desktop
    Scenario: The rendered or source choice is remembered on this device
      Given the user chose to see Markdown source
      When the user opens "docs/guide.md"
      Then the Markdown source is shown

    @desktop
    Scenario: Word wrap can be turned on and off
      When the user turns word wrap on for "src/app.ts"
      Then long lines wrap
      When the user turns word wrap off
      Then long lines scroll sideways

    @desktop
    Scenario: The path trail lets the user jump to a sibling file
      Given the user is looking at "src/lib/cart.ts"
      When the user picks "app.ts" from the files in "src"
      Then "src/app.ts" opens

    @desktop
    Scenario: A requested line is revealed even when it is past the end of the file
      Given "src/app.ts" has 40 lines
      When the user opens "src/app.ts" at line 90
      Then line 40 is revealed

    @desktop
    Scenario: A file that fails to load can be retried
      Given reading "src/app.ts" fails once
      When the user opens "src/app.ts"
      Then the user is told the file could not be read
      When the user retries
      Then the contents of "src/app.ts" are shown

    @desktop
    Scenario: Closing a file returns to the tree
      When the user opens "src/app.ts"
      And the user closes the file
      Then no file is open and the tree is shown

    @desktop @tui
    Scenario: A file opens in the user's editor on the environment
      Given the environment has the editor "VS Code"
      When the user opens "src/app.ts" in "VS Code"
      Then "VS Code" opens "src/app.ts" on the environment

    @desktop
    Scenario: The thread's workspace opens in the preferred editor from the thread's details
      Given the user has picked "VS Code" as their preferred editor
      When the user opens the thread's workspace in an editor from the thread's details
      Then "VS Code" opens the thread's workspace folder on the environment
      And "VS Code" stays the preferred editor for next time

    @backlog @desktop
    Scenario: A remote environment's workspace opens in the local editor over SSH
      Given the thread's environment is on another machine reachable over SSH as "devbox"
      When the user opens the thread's workspace in "VS Code"
      Then the local "VS Code" opens the workspace on "devbox" over SSH

    @backlog @desktop
    Scenario: A remote environment with no SSH route cannot open an editor
      Given the thread's environment is on another machine with no SSH route
      When the user looks at opening the thread's workspace in an editor
      Then opening is unavailable and the user is told no SSH route is known

  Rule: Editing

    @mc
    Scenario: Writing a file creates any missing folders
      When a client writes "src/new/deep.ts" in "shop"
      Then "src/new/deep.ts" exists with the written contents

    @desktop @tui
    Scenario: Edits save themselves shortly after the user stops typing
      Given the user is editing "src/app.ts"
      When the user types a change and pauses
      Then the change is written to "src/app.ts"

    @desktop
    Scenario: Closing the file saves pending edits first
      Given the user typed a change in "src/app.ts" that is not saved yet
      When the user closes the file
      Then the change is written to "src/app.ts"

    @desktop
    Scenario Outline: Some files open read-only
      When the user opens <file>
      Then the file cannot be edited

      Examples:
        | file                                    |
        | a file larger than one megabyte         |
        | a file outside the project on the host  |

    @desktop
    Scenario: Ticking a Markdown task writes the file
      Given "TODO.md" has the unticked task "Ship cart"
      When the user ticks "Ship cart" in the rendered view
      Then "TODO.md" records "Ship cart" as done
      When the user unticks "Ship cart"
      Then "TODO.md" records "Ship cart" as open

    @desktop @tui
    Scenario: A failed save is reported and the edit is kept
      Given writing "src/app.ts" fails
      When the user edits "src/app.ts"
      Then the user is told the file could not be saved
      And the edit is still in the editor

  Rule: Paths stay inside the project

    @mc
    Scenario Outline: Paths that leave the project are refused
      When a client <action> "<path>" in "shop"
      Then the MC answers that the path is outside the project

      Examples:
        | action | path                 |
        | reads  | ../secrets.txt       |
        | writes | ../secrets.txt       |
        | writes | /etc/hosts           |
        | reads  | link-to-home/.bashrc |

    @mc
    Scenario: A project whose folder was deleted reports it
      Given the folder of "shop" was deleted
      When a client lists the files of "shop"
      Then the MC answers that the project folder does not exist

  Rule: Viewing attachments

    @backlog @desktop @mobile
    Scenario Outline: An attachment opens in a viewer for its kind
      Given the user has attached "<file>" to a draft
      When the user opens the attachment from the draft
      Then it is shown as <shown>

      Examples:
        | file        | shown                                       |
        | receipt.png | an image                                    |
        | invoice.pdf | a document the user can page through        |
        | notes.md    | rendered Markdown that can switch to source |
        | build.log   | text                                        |

    @backlog @desktop @mobile
    Scenario: An attachment in a sent message opens in the same viewer
      Given a sent message carries the attachment "invoice.pdf"
      When the user opens the attachment from the conversation
      Then "invoice.pdf" is shown as a document from the environment

    @backlog @desktop @mobile
    Scenario: Images in the conversation open large and can be stepped through
      Given a message carries three images
      When the user opens the second image
      Then it is shown large
      And the user can step to the previous and next image

    @backlog @desktop @mobile
    Scenario: An attachment is shown as it was captured, not as the project's file of that name
      Given the user attached "src/app.ts" and has since changed the project's "src/app.ts"
      When the user opens the attachment
      Then the captured contents are shown

    @desktop
    Scenario: An attachment can be removed from the draft while it is open
      Given the user is viewing an attachment of a draft
      When the user removes it
      Then the viewer closes and the attachment leaves the draft

    @backlog @desktop @mobile
    Scenario: An attachment can be saved to this device
      Given the user is viewing an attachment of a sent message
      When the user saves it
      Then the file is downloaded under its own name
