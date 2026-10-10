# Sources:
#   apps/mobile/src/features/files/ (tree, search, previews, copy, save or share, attachments)
#   apps/mobile/src/features/files/ThreadFilesRouteScreen.tsx
#   apps/mobile/src/features/files/FileTreeBrowser.tsx
#   apps/mobile/src/features/files/SourceFileSurface.tsx
#   apps/mobile/src/components/FilePreview.tsx, apps/mobile/src/lib/attachmentDownload.ts (documents opened in another app)
#   apps/mobile/src/lib/attachmentDocument.ts, localAttachmentPreview.ts, composerAttachmentFiles.ts, composerAttachmentPreviewRetention.ts, mediaActions.ts (source reads, draft copies, share in progress)
#   apps/mobile/src/components/MediaVideoPlayer.tsx, VideoAttachmentTile.tsx, VideoThumbnailImage.tsx, MediaSourceCaption.tsx, apps/mobile/src/lib/videoThumbnails.ts (video stills and playback)
#   apps/mobile/src/components/VideoPreviewModal.tsx, VideoPreviewModal.ios.tsx (full-screen video preview, loading, failure, closing)
#   apps/mobile/src/components/FilePreviewModal.tsx, FilePreview.tsx, FilePreview.ios.tsx, MediaImagePreview.tsx (full-screen picture and document preview)
#   apps/mobile/src/components/AudioFilePreview.tsx (audio controls)
#   docs/internals/mobile-navigation.md (AVKit video, Quick Look previews)
#   apps/mobile/modules/hal-c2-native-controls/ios/HalC2NativeVideoPresentation.swift (audio session while a video is open)
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
  Scenario: Folders are listed before files and numbers sort naturally
    Given the workspace has the folder "docs" and the files "part2.md", "part10.md" and "README.md"
    When the user opens the thread's files
    Then "docs" is listed before the files
    And "part2.md" is listed before "part10.md"

  @backlog @mobile
  Scenario: Top-level folders start open and deeper folders start closed
    Given the workspace has "src/lib/util.ts"
    When the user opens the thread's files
    Then the contents of "src" are listed
    And the contents of "src/lib" are not listed until the user opens it

  @backlog @mobile
  Scenario: Files the project ignores are shown less prominently
    Given the workspace has an ignored folder "dist"
    When the user opens the thread's files
    Then "dist" is listed in a quieter style than the other folders

  @backlog @mobile
  Scenario: The user searches the workspace by file name
    When the user searches files for "cart"
    Then "src/cart.ts" is listed

  @backlog @mobile
  Scenario Outline: A file search matches the way the user remembers the name
    Given the workspace has "src/cartTotal.ts"
    When the user searches files for "<query>"
    Then "src/cartTotal.ts" is listed

    Examples:
      | query       |
      | cart total  |
      | total       |
      | src cart    |
      | crttl       |

  @backlog @mobile
  Scenario: A search lists the folders around each match
    Given the workspace has "src/lib/cart.ts"
    When the user searches files for "cart"
    Then "src", "src/lib" and "src/lib/cart.ts" are listed
    And folders that hold no match are not listed

  @backlog @mobile
  Scenario: Every word of a file search has to match
    Given the workspace has "src/cart.ts" and "src/price.ts"
    When the user searches files for "cart price"
    Then no file is listed

  @backlog @mobile
  Scenario: A search that matches too many files asks for a narrower one
    Given more than 200 files in the workspace match "a"
    When the user searches files for "a"
    Then the first 200 matches are listed
    And the user is told more results are available and to refine the search

  @backlog @mobile
  Scenario: A search that matches nothing says so
    When the user searches files for "zzzz"
    Then the user is told no files were found and to try a different search

  @backlog @mobile
  Scenario: A file tree that cannot be loaded can be tried again
    Given listing the workspace fails
    When the user opens the thread's files
    Then the user is told files are unavailable
    When the user chooses to try again
    Then the workspace tree is listed

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
  Scenario: Copying a partial file copies only what was loaded and says so
    Given the user opened a very large log file
    When the user opens the file's actions
    Then the user is offered to copy the preview and not the contents
    When the user copies the preview
    Then the loaded part of the file is on the clipboard

  @backlog @mobile
  Scenario: A large table shows only its first rows and columns
    Given "prices.csv" has more than 100 rows and more than 30 columns
    When the user shows it as a table
    Then the first 100 rows and 30 columns are shown
    And the user is told the table is limited and that the source shows the rest

  @backlog @mobile
  Scenario: A PDF can be opened full screen
    Given the user opened "spec.pdf"
    When the user chooses to open the PDF
    Then "spec.pdf" is shown full screen

  @backlog @mobile
  Scenario: A web page file can be opened in the phone's browser
    Given the user opened "index.html"
    When the user chooses to open it in the browser
    Then "index.html" opens in the phone's browser

  @backlog @mobile
  Scenario Outline: A preview that cannot be drawn says why instead of staying blank
    Given the user opened "<file>"
    When the phone cannot draw it
    Then the user is told "<title>"

    Examples:
      | file       | title               |
      | shot.png   | Image unavailable   |
      | index.html | Preview failed      |

  @backlog @mobile
  Scenario: A picture can be opened full screen from its preview
    Given the user opened "shot.png"
    When the user taps the picture
    Then "shot.png" is shown full screen

  @backlog @mobile
  Scenario: Touching and holding a picture offers its media actions
    Given the user opened "shot.png"
    When the user touches and holds the picture
    Then the user is offered the actions for the picture

  @backlog @mobile
  Scenario: A Markdown preview shows images that sit next to the file
    Given "docs/guide.md" embeds the picture "diagram.png" from its own folder
    When the user opens "docs/guide.md" as a preview
    Then the picture is shown in the preview

  @backlog @mobile
  Scenario: A Markdown preview says when an image cannot be shown
    Given "docs/guide.md" embeds a picture that cannot be read
    When the user opens "docs/guide.md" as a preview
    Then the preview says the image is unavailable with its description

  @backlog @mobile
  Scenario: A link in a Markdown preview opens outside the app
    Given "docs/guide.md" links to "https://example.com"
    When the user opens "docs/guide.md" as a preview
    And the user follows the link
    Then "https://example.com" opens in the phone's browser

  @backlog @mobile
  Scenario Outline: A file opens in the view that suits it
    When the user opens "<file>"
    Then it is shown as <view>

    Examples:
      | file        | view    |
      | index.html  | preview |
      | shot.png    | preview |
      | demo.mp4    | preview |
      | song.mp3    | preview |
      | src/cart.ts | source  |

  @backlog @mobile
  Scenario: A draft attachment can be read before the message is sent
    Given the draft for "Fix checkout" has the attached file "notes.md"
    When the user opens the attachment
    Then "notes.md" is shown as a preview with its size and that it is a draft attachment
    And the user can switch to its source and turn word wrap on

  @backlog @mobile
  Scenario: A draft attachment too large to load fully is marked partial
    Given the draft has an attached text file larger than 1 MB
    When the user opens the attachment
    Then the first megabyte is shown
    And the user is told the preview is limited and to save or share the file to read it in full

  @backlog @mobile
  Scenario: A draft attachment that cannot be previewed offers to save or share it
    Given the draft has an attached file the phone cannot preview
    When the user opens the attachment
    Then the user is told there is no preview for this file
    And the user is offered to save or share it

  @backlog @mobile
  Scenario: A draft attachment can be removed from the draft where it is read
    Given the user opened a draft attachment "notes.md"
    When the user removes it from the draft
    Then "notes.md" is no longer attached to the draft

  @backlog @mobile
  Scenario: A draft attachment can be opened in the phone's own file viewer
    Given the user opened a draft attachment "notes.pdf"
    When the user chooses to open it in the file viewer
    Then "notes.pdf" opens in the phone's file viewer

  @backlog @mobile
  Scenario: A document the phone cannot open says so
    Given the user opened a PDF attachment
    When the phone cannot open the document
    Then the user is told the document could not be opened

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
  Scenario: A document opens in another app on Android while it is being fetched
    Given the phone is an Android phone
    When the user opens "report.pdf" from a thread
    Then the user is told the document is opening
    And the user can cancel before it opens
    And "report.pdf" opens in the app the phone uses for PDFs

  @backlog @mobile
  Scenario Outline: A document that cannot be opened says why
    Given the phone is an Android phone
    When the user opens "report.docx" from a thread and <problem>
    Then the user is told "<message>"

    Examples:
      | problem                                  | message                                                                            |
      | no app on the phone can show that format | No app on this device can show this format. Save or share it to open it elsewhere. |
      | the file cannot be fetched or shown      | The file could not be opened. Check the connection and try again.                  |

  @backlog @mobile
  Scenario: A file deleted by the agent says it no longer exists
    Given the user opened "src/old.ts"
    When the agent deletes "src/old.ts"
    And the user refreshes the file
    Then the user is told the file no longer exists

  @backlog @mobile
  Scenario: A file that cannot be read can be tried again
    Given "src/cart.ts" cannot be read because "My MacBook" answered with an error
    When the user opens "src/cart.ts"
    Then the user is told the preview is unavailable because the file may be missing, unsupported or unavailable
    When the user chooses to try again
    Then "src/cart.ts" is read again

  @backlog @mobile
  Scenario: Files seen before are browsable offline
    Given the user browsed "src" earlier
    And "My MacBook" is unreachable
    When the user opens the thread's files
    Then the last known tree for "src" is shown

  @backlog @mobile
  Scenario: Source code stays readable when it cannot be coloured
    Given colouring "src/cart.ts" fails
    When the user opens "src/cart.ts"
    Then the lines of "src/cart.ts" are shown without colour

  @backlog @mobile
  Scenario: Reopening a source file within minutes does not colour it again
    Given the user read "src/cart.ts" a minute ago
    When the user opens "src/cart.ts" again
    Then it is shown coloured without waiting

  @backlog @mobile
  Scenario: A file is read ahead while the user lingers on it in the tree
    Given the user is looking at the file tree
    When the user presses a source file in the tree
    Then the file is read before the preview opens
    And pressing it again while it is being read does not read it twice

  @backlog @mobile
  Scenario: Pictures, videos and web pages are not read ahead
    Given the user is looking at the file tree
    When the user presses "shot.png" in the tree
    Then nothing is read until the preview opens

  @backlog @mobile
  Scenario: A very large file is not coloured ahead of time
    Given "src/big.ts" is larger than 256 KB
    When the user presses it in the tree
    Then the file is read ahead without being coloured

  @backlog @mobile
  Scenario: Selecting text in a very large file keeps all of it selectable
    Given the user opened a text attachment with thousands of tokens
    When the user selects text in it
    Then every line, including the line breaks, can be selected

  @backlog @mobile
  Scenario: On a tablet the files stay beside the file being read
    Given the phone is a tablet wide enough for a sidebar
    When the user opens "src/cart.ts" and then picks "src/price.ts" in the files list
    Then "src/price.ts" replaces "src/cart.ts" in the same screen
    And going back returns to the thread in one step

  @backlog @mobile
  Scenario: The file navigator can be hidden and shown on a tablet
    Given the phone is a tablet wide enough for a sidebar
    And the user is reading "src/cart.ts"
    When the user hides the file navigator
    Then only the file is shown
    When the user shows the file navigator
    Then the files list is shown beside the file

  @backlog @mobile
  Scenario: A file can lead straight back to the chat
    Given the user opened "src/cart.ts" from a link in the thread
    When the user returns to the chat
    Then the thread "Fix checkout" is shown

  @backlog @mobile
  Scenario: The user adds a file to the draft from the files browser
    Given the user opened "src/cart.ts"
    When the user adds it to the message
    Then the draft mentions "src/cart.ts"

  @backlog @mobile
  Scenario: A file link with a line opens the file at that line
    When the user follows a link to "src/cart.ts" line 42 in "Fix checkout"
    Then "src/cart.ts" is shown at line 42

  @backlog @mobile
  Scenario: A link to a file outside the workspace opens it on its own
    Given the agent's reply links to "/home/sam/notes/todo.txt" on "My MacBook"
    When the user follows the link
    Then "todo.txt" is shown with its directory as the subtitle and not under the project
    And the file cannot be added to the draft as a workspace file

  @backlog @mobile
  Scenario Outline: A link whose path cannot be a workspace file is refused
    When the user follows a link to "<path>" in "Fix checkout"
    Then the user is told the file path is invalid

    Examples:
      | path             |
      | ../secrets.txt   |
      | ~/notes/todo.txt |

  @backlog @mobile
  Scenario: An absolute link inside the workspace opens as the workspace file
    Given the workspace of "Fix checkout" is "/home/sam/shop"
    When the user follows a link to "/home/sam/shop/src/cart.ts"
    Then "src/cart.ts" is shown from the thread's workspace

  @backlog @mobile
  Scenario: A new task's project files can be browsed before the thread exists
    Given the user is writing a new task for the project "shop" and has not sent it
    When the user opens the project's files
    Then the files of "shop" are listed
    And a file can be added to the new task's draft from there

  @backlog @mobile
  Scenario: A video preview keeps playing when its link would expire
    Given the user is watching "demo.mp4"
    When the time-limited link the video was loaded from expires
    Then the video keeps playing

  @backlog @mobile
  Scenario: A video that cannot be played says so and offers to save or share it
    When the user opens "demo.mp4"
    And the phone cannot play the video
    Then the user is told the video could not be played
    And the user is offered to save or share it

  @backlog @mobile
  Scenario: The user saves a picture or video from the files browser to the photo library
    Given the user opened "shot.png"
    When the user saves the file to the photo library
    Then "shot.png" is in the phone's photo library

  @backlog @mobile
  Scenario: Saving to the photo library asks for permission and says so when refused
    Given the user opened "shot.png"
    And the phone has not allowed HAL-C2 to add to the photo library
    When the user saves the file to the photo library
    Then the user is asked to allow HAL-C2 to add to the photo library
    When the user refuses
    Then the user is told the file was not saved

  @backlog @mobile
  Scenario: A web page whose source cannot be read as text still shows the page
    Given the user opened "report.html" and it is shown as a page
    When the user switches to its source and the file is not text the phone can read
    Then the user is told the file could not be read
    When the user switches back to the page
    Then the page is shown again

  @backlog @mobile
  Scenario: Showing the source of a file opened a while ago still works
    Given the user opened "README.md" from a thread and left it open until its link expired
    When the user switches to its source
    Then the source is shown

  @backlog @mobile
  Scenario: A draft attachment whose copy has gone missing says to attach it again
    Given the draft has the attached file "notes.md"
    And the phone no longer holds the copy of "notes.md" that the draft kept
    When the user opens the attachment
    Then the user is told the attachment is no longer available and to attach the file again

  @backlog @mobile
  Scenario: A draft attachment is still found after the app was updated
    Given the draft has the attached file "notes.md"
    And the app was updated and the phone moved the app's storage
    When the user opens the attachment
    Then "notes.md" is shown

  @backlog @mobile
  Scenario: A draft attachment stays readable while it is being shown or shared
    Given the user is sharing the draft attachment "notes.md" out
    When the user removes "notes.md" from the draft
    Then the other app still receives "notes.md"
    And the phone's copy is removed once the share has finished

  @backlog @mobile
  Scenario: A share that is already opening is not started a second time
    Given the user chose to save or share "report.pdf"
    When the user chooses it again before the share sheet has opened
    Then the share sheet opens once
    And the choice reads that the share sheet is opening

  @backlog @mobile
  Scenario: Leaving a file stops a share that has not opened yet
    Given the user chose to save or share "report.pdf"
    When the user leaves the file before the share sheet has opened
    Then no share sheet opens
    And the user is not told the share failed

  @backlog @mobile
  Scenario: A video shows its first frame and a play mark before it plays
    Given a message carries the video "demo.mp4"
    Then the message shows a still of the video's first frame with a play mark and the name "demo.mp4"
    And the video has not started loading

  @backlog @mobile
  Scenario: Video stills are made one at a time and kept for the next look
    Given a thread has several videos
    When the user scrolls through them
    Then the stills are made one after another
    When the user scrolls back to a video already shown
    Then its still appears again without being made twice

  @backlog @mobile
  Scenario: A video that is slow to answer does not hold up the others
    Given one video is on an environment that cannot be reached
    And another video is on an environment that answers
    When the user scrolls through them
    Then the other video's still appears
    And the unreachable video is shown without a still and can still be tried

  @backlog @mobile
  Scenario: A video still is not made while its screen is behind another
    Given a thread has a video
    When the user opens a file over the thread
    Then no still is made for the thread's video until the thread is shown again

  @backlog @mobile
  Scenario: A video pauses when the user leaves its screen
    Given the user is watching "demo.mp4"
    When the user opens another screen
    Then the video is paused

  @backlog @mobile
  Scenario: A video pauses when the app is not in front
    Given the user is watching "demo.mp4" in the thread
    When the user switches to another app
    Then the video is paused

  @backlog @mobile
  Scenario: A video shown full screen is not paused by the phone's own full-screen view
    Given the user is watching "demo.mp4" in the phone's full-screen player
    When the phone hands the app to its full-screen player
    Then the video keeps playing

  @backlog @mobile
  Scenario: A video pauses while its share sheet is opening
    Given the user is watching "demo.mp4"
    When the user chooses to save or share it
    Then the video is paused until the share sheet is dismissed

  @backlog @mobile
  Scenario: A video that stopped working can be tried again
    Given the user opened "demo.mp4" and the phone cannot play it
    Then the user is told "Video unavailable"
    When the user chooses "Retry"
    Then the video is asked for again with a fresh link

  @backlog @mobile
  Scenario: A video waiting for its link shows that it is loading
    Given the link for "demo.mp4" is still being fetched
    Then the video shows that it is loading
    And the play mark appears once the link arrives

  @backlog @mobile
  Scenario: A picture or video's original reference can be read and selected
    Given the user opened an image from "https://example.com/very/long/path/logo.png" full screen
    Then the address is shown under the picture
    And the address can be selected
    And a long address scrolls instead of pushing the picture away

  @backlog @mobile
  Scenario: An audio file shows its position and length
    Given the user opened "theme.mp3"
    Then the position and the length of the audio are shown as minutes and seconds
    And the controls are unavailable until the audio has loaded

  @backlog @mobile
  Scenario Outline: Audio can be skipped by fifteen seconds
    Given the user opened "theme.mp3" and it is <where>
    When the user chooses "<control>"
    Then the audio moves <result>

    Examples:
      | where                 | control            | result                           |
      | 40 seconds in         | Back 15 seconds    | to 25 seconds in                 |
      | 5 seconds in          | Back 15 seconds    | to the start                     |
      | 10 seconds from its end | Forward 15 seconds | to its end                     |

  @backlog @mobile
  Scenario: Playing audio that has finished plays it again from the start
    Given the user listened to "theme.mp3" to its end
    When the user chooses to play
    Then the audio plays from the start

  @backlog @mobile
  Scenario: Audio that cannot be played says so and can be tried again
    Given the phone cannot play "theme.mp3"
    Then the user is told the audio could not be played and to try again or save it to open in another app
    When the user chooses to try again
    Then the audio is loaded again

  @backlog @mobile
  Scenario: A video opened full screen says it is loading until its link is ready
    Given a message carries the video "demo.mp4" on "My MacBook"
    When the user opens the video full screen before its link is ready
    Then the preview shows its name and that the video is loading
    When the link is ready
    Then the video starts playing

  @backlog @mobile
  Scenario: A video's preview closes when the user leaves its screen
    Given the user is watching "demo.mp4" full screen
    When the app moves to another screen
    Then the video preview closes

  @backlog @mobile
  Scenario: A video the environment cannot be reached for says to reconnect
    Given "My MacBook" is not connected
    When the user opens "demo.mp4" from a message in a thread on "My MacBook"
    Then the user is told to reconnect to the environment and open the video again
    And the preview closes

  @backlog @mobile
  Scenario: A draft video that cannot be read says why in its preview
    Given the draft carries a video whose file can no longer be read
    When the user opens the draft video
    Then the preview says the video could not be loaded
    And the preview still offers to close

  @backlog @mobile
  Scenario: A full-screen video can be saved or shared from its preview
    Given the user is watching "demo.mp4" full screen
    When the user chooses "Save or share video"
    Then the share sheet opens for the video
    And the choice is not offered again until the share sheet is dismissed

  @backlog @mobile
  Scenario: A video's sound plays with the phone on silent
    Given the phone's ringer is switched to silent
    When the user watches "demo.mp4" full screen
    Then the video's sound plays

  @backlog @mobile
  Scenario: Closing a video leaves other audio as it was
    Given music from another app is playing
    When the user watches "demo.mp4" full screen and closes it
    Then the music is still playing

  @backlog @mobile
  Scenario: A full-screen picture can be zoomed and swiped away
    Given the user is looking at "shot.png" full screen
    When the user double taps the picture
    Then the picture zooms in
    When the user swipes the picture away
    Then the full-screen picture closes

  @backlog @mobile
  Scenario: A full-screen picture's name and media actions stay above it
    Given the user is looking at "shot.png" full screen
    Then the name "shot.png" is shown above the picture
    And the media actions and a button to close the picture are shown beside it

  @backlog @mobile
  Scenario: A file preview asks for a fresh link before it is handed to the phone's viewer
    Given the user opened "report.pdf" from a thread after the app was suspended for a long time
    When the preview is about to open
    Then the file's link is renewed first
    And "report.pdf" opens from the renewed link

  @backlog @mobile
  Scenario: A file preview that cannot get its link says to reconnect
    Given "My MacBook" is not connected
    When the user opens "report.pdf" from a thread on "My MacBook"
    Then the user is told "Could not open preview" and to reconnect to the environment and try again
    And the preview closes

  @backlog @mobile
  Scenario: A file preview closes when its screen is no longer the one in front
    Given the user opened a file preview from a thread
    When the user moves to another screen
    Then the preview closes
