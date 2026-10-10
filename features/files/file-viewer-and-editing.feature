# Sources:
#   apps/server-ex/lib/hal_c2/workspace.ex (read_file, write_file, path checks)
#   apps/server/src/workspace/WorkspaceFileSystem.ts, WorkspacePaths.ts (read limits, binary guard, path checks)
#   apps/server-ex/lib/hal_c2/editors.ex (shell.openInEditor)
#   apps/web/src/components/files/FilePreviewPanel.tsx
#   apps/web/src/components/chat/ThreadDetailsPanel.tsx, OpenInPicker.tsx, OpenInPicker.logic.ts (open the workspace)
#   apps/web/src/remoteOpen.ts (SSH deep links for a remote environment; remoteOpenTargets not sent by the MC)
#   apps/desktop/src/ipc/methods/window.ts (probeRemoteEditors: which local editors can work over SSH)
#   apps/web/src/components/files/FileBreadcrumbs.tsx
#   apps/web/src/components/files/useFileSaveCoordinator.ts, projectFilesQueryState.ts (follow the agent's changes)
#   apps/web/src/components/files/FilePreviewPanel.tsx (explorer visibility, rendered preference, open in preview browser)
#   apps/web/src/fileContextMenu.ts, apps/web/src/editorPreferences.ts, apps/web/src/editorLabels.ts
#   apps/web/src/components/files/fileSaveCoordinator.ts
#   apps/web/src/components/files/fileEditorDismissal.ts
#   apps/web/src/components/files/filePreviewMode.ts
#   apps/web/src/components/files/filePath.ts
#   apps/web/src/components/files/fileContentRevision.ts
#   apps/web/src/components/files/AttachmentFilePreview.tsx (attachments shown like files: Draft origin, remove, download)
#   apps/web/src/components/chat/ExpandedImageDialog.tsx, ExpandedImagePreview.tsx (images from the conversation)
#   apps/web/src/components/chat/ZoomableImage.tsx (zoom limits, keyboard zoom, dragging, arrow keys)
#   apps/web/src/components/chat/ChatComposer.tsx (opening a draft attachment)
#   packages/shared/src/filePreview.ts (preview kinds: image, pdf, markdown, html, text, media)
#   packages/shared/src/delimitedPreview.ts (table preview limits, quoting, delimiter by type or name)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (draft attachments listed, not opened)
#   apps/tui/src/components/FilesView.tsx
#   apps/tui/src/features.backlog.test.ts (workspace-file-actions)
#   apps/mobile/src/features/files/ThreadFilesRouteScreen.tsx
#   apps/mobile/src/features/files/SourceFileSurface.tsx
#   apps/mobile/src/features/files/WorkspaceFilePreviewError.tsx
#   packages/contracts/src/filesystem.ts (ProjectReadFileInput, ProjectWriteFileInput, ProjectFileError)
#   packages/client-runtime/src/state/projectCommands.ts (optimisticFile)
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

    # Legacy: apps/server/src/workspace/WorkspaceFileSystem.ts (readFile: base64 limited to images and the image size cap)
    @mc @backlog
    Scenario Outline: A file can be read as base64 only when it is an image within the size limit
      Given "<path>" in "shop" is <file>
      When a client reads "<path>" from "shop" as base64
      Then <result>

      Examples:
        | path             | file                     | result                                                              |
        | assets/logo.png  | an image of 2 MB         | the image bytes are returned                                        |
        | assets/huge.png  | an image of 30 MB        | only its size is returned, with no bytes, and it is marked truncated |
        | data/export.zip  | an archive               | the MC answers that the file is binary and cannot be read as text    |

    # Legacy: apps/server/src/workspace/WorkspaceFileSystem.test.ts (rejects an image-named symlink to a non-image target)
    @mc @backlog
    Scenario: A link named like an image does not make another file readable as an image
      Given "shop" holds "preview.png" as a link to the binary file "database.sqlite"
      When a client reads "preview.png" from "shop" as base64
      Then the MC answers that the file is binary and cannot be read as text

    # Legacy: apps/server/src/workspace/WorkspaceFileSystem.ts (readFile: non-blocking open, stat check)
    @mc @backlog
    Scenario: A named pipe in the project is refused instead of waiting for it
      Given "shop" holds a named pipe "queue.fifo" nobody writes to
      When a client reads "queue.fifo" from "shop"
      Then the MC answers that "queue.fifo" is not a file without waiting

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

    # Legacy: packages/shared/src/filePreview.ts (decodeFilePreviewText)
    @backlog @desktop
    Scenario Outline: A file that is not text says why it is not shown
      Given "<path>" in "shop" <content>
      When the user opens "<path>"
      Then the file is not shown as text
      And the user is told "<message>"

      Examples:
        | path          | content                                  | message                                                                |
        | assets/a.dat  | contains null bytes                      | This file contains binary data and cannot be shown as text.            |
        | notes/old.txt | is written in a non-UTF-8 text encoding  | This file is not UTF-8 text. Open it in another app to view its contents. |

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

    # Legacy: packages/shared/src/delimitedPreview.ts (parseDelimitedPreview limits)
    @backlog @desktop
    Scenario: A large table shows only its first rows and columns
      Given "data/orders.csv" has more than 100 rows and more than 30 columns
      When the user opens "data/orders.csv" rendered
      Then the first 100 rows and 30 columns are shown
      And the user is told the table is limited and that the source shows the rest

    # Legacy: packages/shared/src/delimitedPreview.ts (parseDelimitedPreview quoting, byte order mark)
    @backlog @desktop
    Scenario: A table keeps quoted commas, doubled quotes and multi-line cells in one cell
      Given "data/orders.csv" has a cell reading "Smith, Jane" and a cell holding two lines
      When the user opens "data/orders.csv" rendered
      Then each of those is shown as a single cell
      And a leading byte order mark is not shown as text

    # Legacy: packages/shared/src/delimitedPreview.ts (filePreviewDelimiter)
    @backlog @desktop
    Scenario Outline: Which files are shown as a table
      When the user opens "<path>" of type "<type>" rendered
      Then <outcome>

      Examples:
        | path          | type                      | outcome                                  |
        | data/a.csv    | text/csv                  | the file is shown as a comma table       |
        | data/a.tsv    | text/tab-separated-values | the file is shown as a tab table         |
        | data/a.csv    | application/json          | the file is not shown as a table         |
        | data/a.csv    | text/plain                | the file is shown as a comma table       |
        | data/a.txt    | text/plain                | the file is not shown as a table         |

    @desktop @backlog-desktop
    Scenario: An open file gets most of the Files tab
      When the user opens "src/app.ts"
      Then the file viewer is taller than the file tree

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

    @backlog @desktop
    Scenario: An open file follows the agent's changes
      Given the user is reading "src/app.ts" with no edits of their own
      When the agent changes "src/app.ts"
      Then the viewer shows the new contents
      And an image the agent rewrites is shown as it is now, not from a cached copy

    @backlog @desktop
    Scenario: Media and documents are not read again when the workspace changes
      Given the user is previewing "assets/logo.png"
      When the agent changes another file
      Then "assets/logo.png" is not fetched again

    @backlog @desktop
    Scenario: A path that becomes a file is noticed while it is open
      Given the user opened "build" and it is a folder
      When the agent replaces the folder "build" with a file
      Then the viewer shows the file's contents

    @backlog @desktop
    Scenario: Opening a file at a line shows its source even when the rendered view is preferred
      Given the user prefers the rendered Markdown view
      When the user opens "docs/guide.md" at line 12
      Then the Markdown source is shown with line 12 in view

    @backlog @desktop
    Scenario Outline: A line selection in a file is let go of without a comment
      Given the user selected lines 10 to 12 of "src/cart.ts" and left the comment form closed
      When the user <action>
      Then the lines are no longer selected

      Examples:
        | action                                         |
        | clicks outside the file                        |
        | presses Escape while the file's text is focused |

    @backlog @desktop
    Scenario: A comment in progress is not dropped by a click outside the file
      Given the user is writing a comment on lines 10 to 12 of "src/cart.ts"
      When the user clicks outside the file
      Then the comment form and its text are still there

    @backlog @desktop
    Scenario Outline: The file tree beside a file is shown only for project files
      Given the user chose to <preference> the file tree
      When the user opens <file>
      Then the file tree is <shown>

      Examples:
        | preference | file                                    | shown   |
        | show       | "src/app.ts"                            | shown   |
        | hide       | "src/app.ts"                            | hidden  |
        | show       | a file outside the project on the host  | hidden  |
        | show       | an attachment                           | hidden  |

    @backlog @desktop
    Scenario: A folder in the path trail lists what is in it
      Given the user is looking at "src/lib/cart.ts"
      When the user opens the folder "lib" in the path trail
      Then the files and folders of "lib" are listed, folders first
      And the folder that is open is marked

    @backlog @desktop
    Scenario Outline: A folder in the path trail explains why it lists nothing
      Given <state>
      When the user opens the folder "lib" in the path trail
      Then the user is told "<message>"

      Examples:
        | state                                          | message                                                                 |
        | "lib" is empty                                 | This folder is empty.                                                   |
        | "lib" was deleted after the file was opened    | This folder is no longer available.                                     |
        | the project index is partial and has nothing in "lib" | No entries from this folder are available in the partial workspace index. |

    @backlog @desktop
    Scenario: A folder in the path trail that fails to load can be retried
      Given listing "lib" fails once
      When the user opens the folder "lib" in the path trail
      Then the user is told the folder could not be loaded
      When the user retries
      Then the files of "lib" are listed

    @backlog @desktop
    Scenario Outline: A web page or document can be opened in the preview browser
      Given the environment can serve "<file>" to the preview
      When the user opens "<file>" in the preview browser
      Then "<file>" is shown in the preview browser

      Examples:
        | file              |
        | public/index.html |
        | docs/manual.pdf   |

    @backlog @desktop
    Scenario: A file that cannot be opened in the preview browser says so
      Given the environment cannot serve "public/index.html" to the preview
      When the user opens "public/index.html" in the preview browser
      Then the user is told the file could not be opened in the browser with the reason

    @backlog @desktop
    Scenario: The preferred editor gives way when it is no longer available
      Given the user's preferred editor is "Zed" and it is no longer installed
      And the environment has the editors "VS Code" and "Sublime Text"
      When the user opens "src/app.ts" in the preferred editor
      Then "VS Code" opens "src/app.ts"
      And "VS Code" is the preferred editor from then on

    @backlog @desktop
    Scenario Outline: Revealing a file is named after the host's file manager
      Given the environment's host is <host>
      When the user opens the menu of "src/app.ts"
      Then the reveal action reads "<label>"

      Examples:
        | host                            | label                     |
        | macOS                           | Reveal in Finder          |
        | Windows                         | Reveal in File Explorer   |
        | Linux                           | Reveal in Files           |
        | Linux where reveal runs through Windows (WSL) | Reveal in File Explorer |

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

    # Legacy: apps/desktop/src/ipc/methods/window.ts (probeRemoteEditors)
    @backlog @desktop
    Scenario: Only editors on this computer that can work over SSH are offered for a remote environment
      Given the thread's environment is on another machine reachable over SSH
      And this computer has "VS Code" and "Zed" installed that can open folders over SSH
      And this computer has "Sublime Text" installed which cannot
      When the user looks at the editors offered for the thread's workspace
      Then "VS Code" and "Zed" are offered
      And "Sublime Text" is not offered

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

    @backlog @desktop
    Scenario: A save that failed is tried again when the file is closed
      Given writing "src/app.ts" failed after an edit
      And writing "src/app.ts" works again
      When the user closes the file
      Then the edit is written to "src/app.ts"

    @backlog @desktop
    Scenario: An edit made while a save is under way is saved too
      Given a save of "src/app.ts" is being written
      When the user makes another edit
      Then the file ends up with both edits
      And the file is not shown as saved until the last edit is written

    # Legacy: packages/client-runtime/src/state/projectCommands.ts (optimisticFile), apps/web/src/components/files/projectFilesQueryState.ts
    @backlog @desktop
    Scenario: A saved edit stays on screen while the file is read again
      Given the user saved an edit to "src/app.ts" while an older read of it was still under way
      When the older read finishes
      Then the viewer keeps showing the saved edit
      And it shows the file as the environment has it once the new read arrives

    @backlog @desktop
    Scenario: Ticking a task in a document that changed underneath leaves the file alone
      Given "TODO.md" has the unticked task "Ship cart"
      And the user is looking at the rendered view
      And the agent has since rewritten "TODO.md" so the task moved
      When the user ticks "Ship cart"
      Then "TODO.md" is not changed

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

    # Legacy: apps/server/src/workspace/WorkspacePaths.ts (resolveRelativePathWithinRoot)
    @mc @backlog
    Scenario Outline: The project's own folder is not a file path
      When a client <action> "<path>" in "shop"
      Then the MC answers that the path is outside the project

      Examples:
        | action | path |
        | reads  | .    |
        | writes | .    |
        | writes | src/.. |

    # Legacy: apps/server/src/workspace/WorkspacePaths.ts (normalizeWorkspaceRoot: not a directory)
    @mc @backlog
    Scenario: A project whose folder was replaced by a file reports it
      Given the folder of "shop" was replaced by a file
      When a client lists the files of "shop"
      Then the MC answers that the project folder is not a folder

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

    @backlog @desktop
    Scenario: A large image says which of the images it is
      Given a message carries three images
      When the user opens the second image
      Then its name is shown with "(2/3)"

    @backlog @desktop
    Scenario: Stepping past the last image comes back to the first
      Given a message carries three images and the user opened the third
      When the user steps to the next image
      Then the first image is shown
      When the user steps to the previous image
      Then the third image is shown

    @backlog @desktop
    Scenario: A single image has nothing to step through
      Given a message carries one image
      When the user opens it
      Then no previous or next image is offered
      And the arrow keys do nothing

    @backlog @desktop
    Scenario: The arrow keys step through the images
      Given a message carries three images and the user opened the second
      When the user presses the right arrow key
      Then the third image is shown
      When the user presses the left arrow key twice
      Then the first image is shown

    @backlog @desktop
    Scenario Outline: A large image is zoomed with the pointer
      Given the user opened an image that fits the window
      When the user <acts>
      Then the image is <result>

      Examples:
        | acts                                          | result                                          |
        | clicks it                                     | zoomed to twice its fitted size                 |
        | clicks it again                               | back to its fitted size                         |
        | turns the wheel up over a point               | zoomed in around that point                     |
        | turns the wheel down at its fitted size       | left at its fitted size                         |
        | pinches or holds Control and turns the wheel  | zoomed faster than the wheel alone              |

    @backlog @desktop
    Scenario: A large image cannot be zoomed beyond eight times its fitted size
      Given the user opened an image that fits the window
      When the user zooms in as far as it will go
      Then the image is eight times its fitted size
      And zooming further changes nothing

    @backlog @desktop
    Scenario Outline: A large image is zoomed with the keyboard
      Given the user opened an image with focus on it
      When the user presses <key>
      Then the image <result>

      Examples:
        | key           | result                                      |
        | Enter         | zooms to twice its fitted size or returns   |
        | Space         | zooms to twice its fitted size or returns   |
        | plus          | zooms in one step                           |
        | minus         | zooms out one step                          |
        | 0             | returns to its fitted size                  |

    @backlog @desktop
    Scenario: A zoomed image is dragged to look around
      Given the user zoomed an opened image
      When the user drags it with the mouse
      Then the part of the image shown moves with the pointer
      And letting go does not zoom the image back out

    @backlog @desktop
    Scenario: The arrow keys look around a zoomed image and step through images otherwise
      Given a message carries three images and the user opened the second
      When the user zooms in and presses the right arrow key
      Then the zoomed image moves to show more to its right
      When the user returns the image to its fitted size and presses the right arrow key
      Then the third image is shown

    @backlog @desktop
    Scenario: Stepping to another image starts at its fitted size
      Given a message carries three images and the user zoomed the second
      When the user steps to the next image
      Then the third image is shown at its fitted size

    @backlog @desktop
    Scenario: The zoom is announced
      Given the user opened an image
      When the user zooms to twice its fitted size
      Then "200% zoom" is announced to assistive technology

    @backlog @desktop
    Scenario Outline: A large image or video is closed from where the user is
      Given the user opened an image from the conversation
      When the user <closes>
      Then the viewer closes
      And focus returns to what the user opened it from

      Examples:
        | closes                           |
        | presses Escape                   |
        | clicks beside the image          |
        | uses the close button            |

    @backlog @desktop
    Scenario: Escape closes a menu of the viewer before the viewer
      Given the user opened an image and right-clicked it to open its menu
      When the user presses Escape
      Then the menu closes
      And the image is still open

    @backlog @desktop
    Scenario Outline: A large image that cannot be loaded says so
      Given the user opened an image whose picture cannot be loaded and <original>
      Then the viewer says "<message>"

      Examples:
        | original                                      | message                                                   |
        | that has an address on the web                | This image could not be loaded.                           |
        | that has no address on the web                | Image unavailable. The file may have been moved or deleted. |

    @backlog @desktop
    Scenario: A large image that cannot be loaded offers its original
      Given the user opened an image whose picture cannot be loaded
      And the image has an address on the web
      Then the viewer offers to open the original

    @backlog @desktop
    Scenario: A large video starts playing
      Given a message carries a video
      When the user opens the video
      Then it starts playing in the viewer

    @backlog @desktop
    Scenario: The arrow keys belong to a video that has focus
      Given a message carries a video and an image and the user opened the video
      When the user presses the right arrow key with focus on the video
      Then the key is left to the video and the viewer stays on the video

    @backlog @desktop
    Scenario: A Snap Shot's text is read in the large view and the picture comes back
      Given the user opened a Snap Shot that has accessibility data
      When the user chooses to show its extracted text
      Then the text takes the picture's place
      When the user chooses to show the screenshot
      Then the picture is shown again

    @backlog @desktop
    Scenario Outline: A Snap Shot offers the form of what it captured
      Given the user opened a Snap Shot whose accessibility data is <format>
      Then the control to see it reads "<label>"

      Examples:
        | format | label                    |
        | text   | Show extracted text      |
        | JSON   | Show accessibility JSON  |

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

    @backlog @desktop @mobile
    Scenario Outline: An attachment that cannot be fetched says why and can be retried
      Given <state>
      When the user opens the attachment
      Then the user is told "<message>"
      When the environment is reachable again and the user retries
      Then the attachment is shown

      Examples:
        | state                                         | message                                  |
        | the environment is unreachable                | Reconnect to the environment and try again. |
        | the environment no longer has the attachment  | The attachment is unavailable.           |

    @backlog @desktop
    Scenario: A failed save of an attachment is reported
      Given the user is viewing an attachment of a sent message
      And the environment cannot be reached
      When the user saves it
      Then the user is told the file could not be saved with the reason

    @backlog @desktop
    Scenario: An attachment opened long ago is fetched with fresh access
      Given the user opened an attachment as a rendered page an hour ago
      When the user switches to its source
      Then the source is shown without the user reconnecting

    @backlog @desktop
    Scenario: A page that cannot be read as text can still be shown rendered
      Given the attachment "page.html" is not valid text
      When the user switches to its source
      Then the user is told the source could not be loaded
      When the user switches back to the rendered page
      Then the page is shown

    @backlog @desktop
    Scenario Outline: Copying an attachment's text
      Given the user is viewing a text attachment that is <size>
      When the user copies it
      Then the clipboard holds <copied>

      Examples:
        | size                    | copied                                        |
        | within the preview limit | all of its text                              |
        | over the preview limit  | only the part shown, and the action says so   |
