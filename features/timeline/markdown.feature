# Sources:
#   apps/web/src/components/ChatMarkdown.tsx (code block header, Copy code, line wrap, table expand and copy, streaming)
#   apps/web/src/components/ChatMarkdown.tsx (fence file names, collapsible sections, template cards, file chips and their menu and failure toasts, website icons, pull request links)
#   apps/web/src/markdown-links.ts (file link modifier click, PDFs in the browser, inline code paths)
#   apps/web/src/components/media/MediaActions.tsx, MediaVideoPlayer.tsx, OpenMediaLink.tsx, mediaContent.ts (media menu, save and copy, video states)
#   apps/web/src/components/ChatView.logic.ts (codexArtifactTemplatePromptToAppend)
#   apps/web/src/components/chat/externalLinkContextMenu.ts (Link to thread, Unlink from thread)
#   apps/web/src/index.css (.chat-markdown: headings, lists, quotes, inline code, code blocks, tables)
#   apps/web/src/markdown-clipboard.ts (Copy as Markdown, Copy as CSV)
#   packages/shared/src/favicon.ts, hostClassification.ts (site icons: light and dark variants, no private hosts)
#   apps/web/src/markdown-github-alerts.ts (Note, Tip, Important, Warning, Caution)
#   apps/web/src/markdown-list-indentation.ts (a list item over-indented on its first line stays text)
#   apps/web/src/markdown-incremental.ts (a reply being written parses only what changed)
#   apps/web/src/workspaceBasenameLookup.ts (a link naming only a file finds it in the project)
#   packages/client-runtime/src/markdownLinks.ts, markdownImages.ts, mediaSource.ts, mediaReference.ts, mediaActions.ts (what is a file link, what is media)
#   packages/client-runtime/src/codexArtifactTemplates.ts, codexFileCitations.ts, codexMarkdownDirectives.ts (template cards, file citations)
#   apps/mobile/src/features/threads/ThreadFeed.tsx, ThreadMarkdownImage.tsx (images and videos embedded in a reply, unavailable images)
#   apps/mobile/src/features/threads/markdownImageSize.ts, markdownCodeHighlightState.ts (image size limits, colouring only for a named language)
#   apps/mobile/src/lib/markdownLinks.ts, nativeMarkdownText.ts (how a link, a file mention, a skill and a path in code are shown in a reply)
#   apps/mobile/modules/hal-c2-markdown-text (chips in text, copy without inline icons, selection handle colour)
#   apps/desktop-qt/qml/HalC2/Bricks/Markdown.qml
#   apps/desktop-qt/qml/HalC2/Bricks/js/markdown.js (escaping, safe links, streaming segments)
#   apps/desktop-qt/tests/tst_Markdown.qml
#   apps/desktop-qt/tests/native/features/MarkdownSteps.cpp

Feature: Formatted messages
  Messages are written in Markdown. The timeline shows headings, lists, quotes, code and
  tables formatted, lets the user copy code and tables, and never lets a message's text
  load anything or pass itself off as something it is not.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  @shared @backlog-mobile
  Scenario: A reply shows its formatting
    When the agent answers with a heading, a list, a quote, a code block and a table
    Then the heading and the list are shown as text
    And the quote, the code block and the table are each shown in their own form

  @shared @backlog-mobile
  Scenario: The user copies a code block
    Given the agent's reply has a code block
    When the user copies the code block
    Then the code block's source is on the clipboard
    And the code block shows it was copied

  @shared @backlog-mobile @backlog-tui
  Scenario: Line wrap in a code block can be turned off and on
    Given the agent's reply has a code block with a long line
    When the user turns line wrap off for the code block
    Then the long line scrolls sideways
    When the user turns line wrap on for the code block
    Then the long line wraps

  @shared @backlog-mobile
  Scenario Outline: The user copies a table
    Given the agent's reply has a table
    When the user copies the table as <format>
    Then the table is on the clipboard as <format>

    Examples:
      | format   |
      | Markdown |
      | CSV      |

  @shared @backlog-mobile
  Scenario: Table cells can be collapsed and expanded
    Given the agent's reply has a table with a long cell
    When the user collapses the table cells
    Then the long cell stays on one line
    When the user expands the table cells
    Then the long cell wraps

  @shared @backlog-mobile
  Scenario: Markup in a message is shown as it was written
    When the agent answers with HTML and an image
    Then the HTML is shown as written
    And the image is a link to its address and nothing is loaded from the web

  @shared @backlog-mobile
  Scenario: A link to a script is not a link
    When the agent answers with a link to "javascript:alert(1)"
    Then the link's text is shown and nothing can be opened

  @shared @backlog-mobile @backlog-tui
  Scenario: A reply being written keeps what is already shown
    Given the agent is writing a reply of several paragraphs
    When the reply grows by another paragraph
    Then the paragraphs already shown are not drawn again

  @shared @backlog-mobile
  Scenario: A code block is shown as code while it is written
    Given the agent is writing a code block
    Then the code written so far is shown as a code block
    When the agent closes the code block
    Then the same code block is shown, finished

  @shared @backlog-mobile
  Scenario Outline: A GitHub alert shows its kind
    When the agent answers with a "<marker>" alert
    Then the quote is titled "<title>"

    Examples:
      | marker    | title     |
      | NOTE      | Note      |
      | TIP       | Tip       |
      | IMPORTANT | Important |
      | WARNING   | Warning   |
      | CAUTION   | Caution   |

  @shared @backlog-mobile
  Scenario: A user message keeps its line breaks
    Given the user's message has two lines
    Then the message is shown on two lines

  @desktop @mobile @backlog
  Scenario Outline: A code block is headed by the file name its fence gives
    Given the agent's reply has a code block whose fence reads <fence>
    Then the code block is headed "<heading>"

    Examples:
      | fence                  | heading      |
      | ts title="src/cart.ts" | src/cart.ts  |
      | ts filename=cart.ts    | cart.ts      |
      | ts file='src/cart.ts'  | src/cart.ts  |
      | ts src/cart.ts         | src/cart.ts  |

  @desktop @mobile @backlog
  Scenario: A collapsible section in a reply opens and closes
    Given the agent's reply has a collapsible section titled "Full log"
    Then the section is closed and shows "Full log"
    When the user opens the section
    Then its content is shown
    When the user closes the section
    Then its content is hidden

  @desktop @mobile @backlog
  Scenario: A collapsible section without a title is called "Details"
    Given the agent's reply has a collapsible section with no title
    Then the section shows "Details"

  @desktop @backlog
  Scenario: A Codex template card puts its skill into the draft
    Given the agent's reply offers the "Google Slides" template
    When the user chooses "Use template"
    Then the draft gains the prompt for that template's skill
    And the composer has focus

  @desktop @backlog
  Scenario: A template that is already in the draft is not added twice
    Given the agent's reply offers the "Google Slides" template
    And the draft already carries that template's prompt
    When the user chooses "Use template"
    Then the draft is unchanged
    And the composer has focus

  @desktop @backlog
  Scenario: A template cannot be added while the composer is busy
    Given the agent's reply offers the "Google Slides" template
    And the composer cannot take text right now
    When the user chooses "Use template"
    Then the user is told "Unable to add to chat"

  # Legacy: packages/client-runtime/src/codexArtifactTemplates.ts (codexArtifactTemplatePresentationLabel)
  @backlog @desktop @mobile
  Scenario Outline: A Codex template card names the kind of template it is
    When the agent's reply offers the "Hello World" template of the kind <kind>
    Then the card reads "Hello World" with the label "<label>"

    Examples:
      | kind           | label                  |
      | document       | Document template      |
      | presentation   | Presentation template  |
      | google-sheets  | Google Sheet template  |
      | slack          | Slack template         |

  # Legacy: packages/client-runtime/src/codexArtifactTemplates.ts (resolveCodexArtifactTemplate),
  # packages/client-runtime/src/codexMarkdownDirectives.ts (malformed directives stay literal)
  @backlog @desktop @mobile
  Scenario Outline: A template or file citation the reply wrote wrongly stays as written
    When the agent's reply holds <text>
    Then the reply shows it as it was written
    And no template card or file chip is made from it

    Examples:
      | text                                                                                     |
      | a template card with no skill directory                                                  |
      | a template card whose skill is not named "artifact-template-…"                           |
      | a template card whose skill directory is a relative path                                 |
      | a template card in code formatting                                                       |
      | a file citation with no path                                                             |
      | a file citation in code formatting                                                       |

  # Legacy: packages/client-runtime/src/codexFileCitations.ts, codexMarkdownDirectives.ts
  @backlog @desktop @mobile
  Scenario: A file Codex cites is shown as a file chip with its line
    When the agent's reply cites the file "outputs/report.xlsx" at line 7
    Then the reply shows a file chip reading "report.xlsx · L7"
    And following the chip opens "outputs/report.xlsx" at line 7

  # Legacy: packages/client-runtime/src/codexFileCitations.ts (markdownDestinationPath),
  # packages/client-runtime/src/codexMarkdownDirectives.test.ts (path round trips)
  @backlog @desktop @mobile
  Scenario Outline: A cited file whose path has awkward characters still opens that file
    When the agent's reply cites the file <path> at line 7
    Then following the chip opens <path> at line 7

    Examples:
      | path                              |
      | "C:\Users\test\[draft]\report.md" |
      | "\\server\share\report.md"        |
      | "/tmp/report%5C.md"               |
      | "notes #2/plan?.md"               |

  # Legacy: packages/client-runtime/src/codexMarkdownDirectives.ts (renderCodexDirectivesForCopy)
  @backlog @desktop @mobile
  Scenario: Copying a reply copies its file citations and template cards as plain text
    Given the agent's reply cites "outputs/report.xlsx" and offers the "Hello World" document template
    When the user copies the reply
    Then the clipboard holds a link named "report.xlsx" to "outputs/report.xlsx"
    And the clipboard holds "Hello World (Document template)"

  # Legacy: packages/client-runtime/src/markdownLinks.ts (inlineCodeFilePathCandidate)
  @backlog @desktop @mobile
  Scenario Outline: A path-shaped word in code formatting is a file chip unless it is a web host
    When the agent's reply holds <code> in code formatting
    Then <code> is <shown>

    Examples:
      | code                  | shown                            |
      | "./run.sh"            | a file chip                      |
      | "conf.d/app.conf"     | a file chip                      |
      | "Makefile:12"         | a file chip                      |
      | "github.com/org/repo" | left as code                     |
      | "localhost/api"       | left as code                     |
      | "192.168.1.5/admin"   | left as code                     |
      | "two words/here.ts"   | left as code                     |
      | "src/index.ts:12:4"   | a file chip                      |

  # Legacy: packages/client-runtime/src/markdownLinks.ts (parseMarkdownFileLink)
  @backlog @desktop @mobile
  Scenario Outline: A link in a reply is a file only when its destination looks like one
    When the agent's reply links to "<destination>"
    Then the link is <shown>

    Examples:
      | destination                       | shown                       |
      | /Users/me/shop/src/cart.ts        | a file link                 |
      | /etc/hosts                        | a file link                 |
      | Makefile                          | a file link                 |
      | C:\work\shop\src\cart.ts          | a file link                 |
      | file:///work/shop/src/cart.ts#L9  | a file link to line 9       |
      | file://build-box/share/out.log    | a file link on that share   |
      | /settings/profile                 | not a file link             |
      | mailto:dev@example.com            | not a file link             |
      | https://example.com/cart.ts       | not a file link             |
      | #install                          | not a file link             |

  # Legacy: packages/client-runtime/src/markdownLinks.ts (workspaceRelativeFilePath)
  @backlog @desktop @mobile
  Scenario: A file in a Windows project is told from the project's folder whatever the case
    Given the project folder is "C:\Work\Shop"
    When the agent's reply links to "c:\work\shop\SRC\cart.ts"
    Then the file is named relative to the project as "SRC/cart.ts"

  # Legacy: packages/client-runtime/src/mediaSource.ts (imageEmbed, mediaMimeType)
  @backlog @desktop @mobile
  Scenario: An image embedded from an address without a file extension is still an image
    When the agent's reply embeds an image from "https://example.com/render?id=7"
    Then the image is shown in the reply

  # Legacy: packages/client-runtime/src/mediaSource.ts (resolveMediaSource)
  @backlog @desktop @mobile
  Scenario: A link to a file that is neither an image nor a video is not previewed as media
    Given the agent's reply links to the file "notes/plan.txt"
    When the user follows the link
    Then "notes/plan.txt" opens as a file, not as a large preview

  # Legacy: packages/client-runtime/src/mediaReference.ts (mediaReferenceFileName, mediaFileReference)
  @backlog @desktop
  Scenario Outline: An image or video's saved name follows its file or address
    Given the project folder is "/work/shop"
    When the agent's reply embeds <media>
    And the user chooses to save it from the media's menu
    Then the saved file is named <name>

    Examples:
      | media                               | name          |
      | "/work/shop/assets/logo.png"        | "logo.png"    |
      | "https://example.com/my%20clip.mp4" | "my clip.mp4" |

  # Legacy: packages/client-runtime/src/mediaReference.ts (mediaFileReference compares paths lexically)
  @backlog @desktop
  Scenario Outline: Copying a relative path is offered only for media inside the project
    Given the project folder is "/work/shop"
    When the agent's reply embeds the image <path>
    And the user opens the media's menu
    Then copying the relative path is <offered>

    Examples:
      | path                               | offered         |
      | "/work/shop/assets/a/../logo.png"  | offered         |
      | "/work/other/logo.png"             | not offered     |
      | "/work/shop"                       | not offered     |

  @desktop @backlog
  Scenario Outline: A file named in a reply is shown as a chip naming where it is
    Given the project folder is "/work/shop"
    When the agent's reply links to <link>
    Then the reply shows a file chip reading "<label>"

    Examples:
      | link                                       | label            |
      | src/cart.ts                                | cart.ts          |
      | src/cart.ts#L12                            | cart.ts · L12    |
      | src/cart.ts:12:4                           | cart.ts · L12:C4 |
      | src/cart.ts, with test/cart.ts also linked | cart.ts · src    |

  @desktop @backlog
  Scenario: A path in code formatting becomes a file chip only when it looks like a path
    When the agent's reply holds "src/cart.ts:12" and "origin/main" and "node.meta" in code formatting
    Then "src/cart.ts:12" is shown as a file chip
    And "origin/main" and "node.meta" stay as code

  @desktop @backlog
  Scenario Outline: Following a file link follows the user's modifier key
    Given the agent's reply links to the file "src/cart.ts"
    When the user clicks the file link <how>
    Then "src/cart.ts" opens <where>

    Examples:
      | how                                | where                          |
      | plainly                            | beside the conversation        |
      | while holding Command or Control   | in the user's editor           |

  @desktop @backlog
  Scenario: A linked PDF opens in the in-app browser instead of the editor
    Given the agent's reply links to the file "docs/manual.pdf"
    When the user follows the link
    Then "docs/manual.pdf" opens in the in-app browser beside the thread

  @desktop @backlog
  Scenario: A link that names only a file finds the file in the project
    Given "shop" holds "src/lib/cart-total.ts"
    And the agent's reply links to the file "cart-total.ts"
    When the user follows the link
    Then "src/lib/cart-total.ts" opens beside the conversation

  @desktop @backlog
  Scenario: A link whose bare name fits two files by case alone opens neither
    Given "shop" holds "src/Cart.ts" and "src/cart.ts"
    And the agent's reply links to the file "CART.ts"
    When the user follows the link
    Then neither "src/Cart.ts" nor "src/cart.ts" is picked for the user

  @desktop @backlog
  Scenario: The latest of two quick file link clicks is the one that opens
    Given the agent's reply links to the files "cart-total.ts" and "order.ts"
    When the user follows the link to "cart-total.ts" and at once the link to "order.ts"
    Then "order.ts" opens beside the conversation
    And "cart-total.ts" is not opened afterwards

  @desktop @backlog
  Scenario: A linked image or video opens as a preview
    Given the agent's reply links to the file "assets/logo.png"
    When the user follows the link
    Then "assets/logo.png" opens as a large preview

  @backlog @mobile
  Scenario Outline: An image in a reply is shown in the reply
    Given the agent's reply embeds an image from <source>
    When the user reads the reply
    Then the image is shown in the reply
    When the user taps the image
    Then it opens as a large preview

    Examples:
      | source                                |
      | a web address                         |
      | a file in the thread's workspace      |
      | a file on the host by its full path   |

  @backlog @mobile
  Scenario Outline: An image in a reply that cannot be shown says so
    Given the agent's reply embeds an image from <source>
    When the user reads the reply
    Then the reply shows that the image is unavailable
    And nothing is fetched for it

    Examples:
      | source                                              |
      | a path in the home folder                           |
      | an address that is only an anchor                   |
      | a relative path in a thread with no workspace       |

  @backlog @mobile
  Scenario Outline: An image in a reply is shown no larger than the thread can hold
    Given the agent's reply embeds an image <size>
    When the user reads the reply
    Then the image is shown <shown>

    Examples:
      | size                                    | shown                                                |
      | that is small enough for the thread     | at its own size                                      |
      | that is wider than the thread           | as wide as the thread, keeping its proportions       |
      | that is taller or wider than 480 points | within 480 points each way, keeping its proportions  |

  @backlog @mobile
  Scenario Outline: A code block is coloured only when its fence names a language
    Given the agent's reply has a code block whose fence reads <fence>
    When the user reads the reply
    Then the code block is shown <colouring>

    Examples:
      | fence | colouring              |
      | ts    | coloured as TypeScript |
      |       | as plain text          |

  @backlog @mobile
  Scenario: A code block still being written keeps the colours of its finished lines
    Given the agent is writing a code block whose fence reads "ts"
    And its first three lines are coloured
    When the agent adds a fourth line
    Then the first three lines stay coloured while the new line waits to be coloured
    And the block does not flash back to plain text

  @backlog @mobile
  Scenario: A video embedded in a reply plays on request
    Given the agent's reply embeds the video "demo.mp4" from the thread's workspace
    When the user reads the reply
    Then "demo.mp4" is shown as a video
    When the user taps it
    Then it plays in a large preview

  @desktop @backlog
  Scenario Outline: A file chip's menu offers what its file can do
    Given the agent's reply links to <file>
    When the user opens the file chip's menu
    Then the menu offers <offered>
    And the menu offers copying its relative path and its full path

    Examples:
      | file                                           | offered                                                     |
      | the image "assets/logo.png"                    | a preview, opening in the editor and revealing it           |
      | the page "public/index.html" with a browser    | opening in the editor, in the in-app browser and revealing  |
      | the file "src/cart.ts"                         | opening in the editor and revealing it                      |

  @desktop @backlog
  Scenario Outline: A file link that cannot be opened says why
    Given the agent's reply links to the file "src/cart.ts"
    And <failure>
    When the user opens it from the file chip's menu
    Then the user is told "<title>"

    Examples:
      | failure                                      | title                          |
      | the editor cannot open it                    | Unable to open file            |
      | the in-app browser cannot open it            | Unable to open file in browser |
      | the file manager cannot reveal it            | Unable to reveal file          |

  @desktop @backlog
  Scenario: A copied path confirms what was copied
    Given the agent's reply links to the file "src/cart.ts"
    When the user copies its relative path from the file chip's menu
    Then the user is told "Relative path copied" with "src/cart.ts"

  @desktop @backlog
  Scenario: A copied path that cannot reach the clipboard says so
    Given the agent's reply links to the file "src/cart.ts"
    And the clipboard refuses the copy
    When the user copies its full path from the file chip's menu
    Then the user is told "Failed to copy full path" with the reason

  @desktop @backlog
  Scenario: A link to a website carries the site's icon
    When the agent's reply links to "https://example.com/docs" with the text "the docs"
    Then the link is shown with the icon of "example.com"
    And hovering the link shows "https://example.com/docs"

  @desktop @backlog
  Scenario: A site whose icon cannot load is shown with a generic link icon
    Given the icon of "example.com" cannot be loaded
    When the agent's reply links to "https://example.com/docs" with the text "the docs"
    Then the link is shown with a generic link icon
    And the icon is not asked for again for "example.com"

  # Legacy: packages/shared/src/favicon.ts (faviconUrlForOrigin), packages/shared/src/hostClassification.ts (isPublicFaviconHost)
  @desktop @backlog
  Scenario Outline: A link to a private or reserved address never asks a public service for its icon
    When the agent's reply links to "<link>" with the text "the page"
    Then the link is shown with a generic link icon
    And no public icon service is told about "<host>"

    Examples:
      | link                          | host              |
      | http://localhost:3000/        | localhost         |
      | http://192.168.1.20/admin     | 192.168.1.20      |
      | http://10.0.0.5:8080/         | 10.0.0.5          |
      | https://build.internal/runs/1 | build.internal    |
      | https://box.example.test/     | box.example.test  |
      | http://[fd00::1]/             | fd00::1           |

  # Legacy: packages/shared/src/favicon.ts (toolActivityFaviconUrl)
  @desktop @backlog
  Scenario: A website's icon follows the light or dark appearance when the site has one for each
    Given the agent used a website that offers separate light and dark icons
    When the timeline is shown in the dark appearance
    Then the work entry shows the site's dark icon
    When the timeline is shown in the light appearance
    Then the work entry shows the site's light icon

  @desktop @backlog
  Scenario: A link to a pull request opens beside the conversation
    Given the project's repository has pull request 42
    When the user follows a link to pull request 42 in the agent's reply
    Then pull request 42 opens beside the conversation
    And the page can still be opened in a browser from there

  @desktop @backlog
  Scenario Outline: A pull request link can be tied to the thread from the reply
    Given the agent's reply links to pull request 42
    And pull request 42 is <state> this thread
    When the user opens the link's menu
    Then the menu offers "<action>"

    Examples:
      | state                  | action             |
      | not yet linked to      | Link to thread     |
      | already linked to      | Unlink from thread |

  @desktop @backlog
  Scenario Outline: A pull request link that cannot be changed says so
    Given the agent's reply links to pull request 42
    When the user chooses "<action>" from the link's menu and the MC refuses
    Then the user is told "<title>" with the reason

    Examples:
      | action             | title                          |
      | Link to thread     | Unable to link pull request    |
      | Unlink from thread | Unable to unlink pull request  |

  @desktop @backlog
  Scenario: A link's menu leaves out the in-app browser when there is none
    Given the thread has no in-app browser
    When the user opens the menu of a web link in a reply
    Then the menu offers opening in the system browser and copying the link
    And the menu does not offer opening in the in-app browser

  @desktop @backlog
  Scenario Outline: Selected text in a reply copies as Markdown
    Given the agent's reply holds <content>
    When the user selects it and copies
    Then the clipboard holds <markdown>

    Examples:
      | content                                      | markdown                                                         |
      | a heading and a paragraph                    | the heading marked with "#" and the paragraph                    |
      | a numbered list starting at 3                | the list numbered from 3                                         |
      | a task list with one done and one open item  | the items marked "[x]" and "[ ]"                                 |
      | a code block containing three backticks      | a fence longer than the backticks inside, with its language      |
      | a table with a right-aligned column          | a Markdown table keeping the alignment and escaping pipes        |
      | a link to "javascript:alert(1)"              | the link's text without the link                                 |
      | an image                                     | the image as its description and address                         |

  @desktop @mobile @backlog
  Scenario: A list item with too much space after its marker is still text
    When the agent answers with a list item whose text follows its marker after five spaces
    Then the item's text is shown as text in the list
    And it is not shown as a code block

  @desktop @backlog
  Scenario: Selecting one code block copies its plain code
    Given the agent's reply holds a code block
    When the user selects exactly that code block and copies
    Then the clipboard holds the code without a fence

  @desktop @backlog
  Scenario: An image or video in a reply shows where it comes from on hover
    Given the agent's reply embeds the image "assets/logo.png" from the thread's workspace
    When the user holds the pointer over the image
    Then a tip shows the file's full path
    Given the agent's reply embeds the video from "https://example.com/demo.mp4"
    When the user holds the pointer over the video
    Then a tip shows "https://example.com/demo.mp4"

  @desktop @backlog
  Scenario Outline: An image or video in a reply has a menu of what it can do
    Given the agent's reply embeds <media>
    When the user opens the media's menu
    Then the menu offers <offered>

    Examples:
      | media                                                      | offered                                                                                         |
      | the image "assets/logo.png" from the thread's workspace    | copying its full path and its relative path, opening it in the file viewer, saving and copying the image |
      | the image from "https://example.com/logo.png"              | copying its URL, saving and copying the image                                                   |
      | the video "media/demo.mp4" from the thread's workspace     | copying its full path and its relative path, opening it in the file viewer and saving the video |
      | a video that is not available                              | saving the video, which cannot be chosen                                                        |

  @desktop @backlog
  Scenario: The media menu is opened from the keyboard
    Given the agent's reply embeds an image
    And the image has the keyboard focus
    When the user presses the menu key, or Shift and F10
    Then the image's menu opens at the image

  @desktop @backlog
  Scenario Outline: Copying a media path or address confirms what was copied
    Given the agent's reply embeds <media>
    When the user chooses "<action>" from the media's menu
    Then the clipboard holds <copied>
    And the user is told "<toast>"

    Examples:
      | media                                                   | action             | copied                          | toast        |
      | the image "assets/logo.png" in "/work/shop"             | Copy full path     | "/work/shop/assets/logo.png"    | Path copied  |
      | the image "assets/logo.png" in "/work/shop"             | Copy relative path | "assets/logo.png"               | Path copied  |
      | the image from "https://example.com/logo.png"           | Copy URL           | "https://example.com/logo.png"  | URL copied   |

  @desktop @backlog
  Scenario: Saving an image or video says it is preparing, then that the download started
    Given the agent's reply embeds the image "assets/logo.png" from the thread's workspace
    When the user chooses "Save image" from the media's menu
    Then the user is told "Preparing image download…"
    And that notice becomes "Download started" when the file is handed over
    And the saved file is named "logo.png"

  @desktop @backlog
  Scenario: Copying an image puts a picture on the clipboard
    Given the agent's reply embeds a JPEG image
    When the user chooses "Copy image" from the media's menu
    Then the user is told "Copying image…", then "Image copied"
    And the clipboard holds the picture as a PNG

  @desktop @backlog
  Scenario Outline: A media action that cannot finish says why
    Given the agent's reply embeds <media>
    And <problem>
    When the user chooses "<action>" from the media's menu
    Then the user is told "<title>" with the reason

    Examples:
      | media                      | problem                                                | action     | title                     |
      | an image on the host       | the environment is not connected                       | Save image | Could not save image      |
      | an image on the web        | the address answers with a web page, not an image       | Copy image | Could not copy image      |
      | an image on the host       | the image has more than 64 million pixels              | Copy image | Could not copy image      |
      | a video on the host        | the file cannot be fetched                             | Save video | Could not save video      |

  @desktop @backlog
  Scenario: A media menu stays single while it is open
    Given the agent's reply embeds an image
    And the image's menu is open
    When the user asks for the menu again
    Then no second menu opens

  @desktop @dropped
  Scenario: Copying an image says when the browser forbids it
    # The legacy web client had to explain missing clipboard access or cross-origin rules of a
    # browser tab; the desktop writes to the system clipboard and fetches through the MC.
    Given the browser cannot write images to the clipboard
    When the user chooses "Copy image" from the media's menu
    Then the menu item is not available

  @desktop @backlog
  Scenario: A video that cannot be played offers a retry and its original
    Given the agent's reply embeds a video whose file cannot be played
    When the user reads the reply
    Then the video is replaced by "Video unavailable" with its name
    And it offers "Retry video" and a way to open the original
    When the user chooses "Retry video"
    Then the button says "Retrying…" until the video is loaded again

  @desktop @backlog
  Scenario Outline: The way to open an unavailable video's original depends on where it came from
    Given the agent's reply embeds a video from <source> that cannot be played
    Then the way out reads "<label>"

    Examples:
      | source                                    | label            |
      | a web address                             | Open original    |
      | a file in the thread's workspace          | Open in browser  |
      | a copy the app holds in memory            | Download video   |

  @desktop @backlog
  Scenario: A video that is not near the screen does not load yet
    Given the agent's reply embeds a video far above the part of the thread on screen
    Then nothing of the video is fetched
    When the user scrolls it to within a short distance of the screen
    Then the video's first frame is loaded

  @desktop @backlog
  Scenario: A video keeps its place when its address is renewed
    Given a video from the thread's workspace is playing
    When the MC hands out a new address for the same file
    Then the video keeps playing from the same moment

  @desktop @backlog
  Scenario: A changed video file is picked up once playback stops
    Given a video from the thread's workspace is playing
    When the file on disk changes
    Then the video keeps playing the old file
    When the user pauses it
    Then the video shows the changed file

  @desktop @backlog
  Scenario: A video stops when the window is hidden
    Given a video from the thread's workspace is playing
    When the window is hidden
    Then the video is paused

  @desktop @backlog
  Scenario: A video shown full screen keeps playing when the window is hidden
    Given a video is playing full screen
    When the window is hidden
    Then the video keeps playing

  @desktop @backlog
  Scenario: A video thumbnail opens its player
    Given the agent's reply shows a video as a still picture with a play mark
    When the user chooses the play mark
    Then the video opens in a large player

  @backlog @mobile
  Scenario: A link to a website in a reply is shown with its host
    When the agent's reply links to "https://example.com/docs?q=1" with the text "the docs"
    Then the link reads "the docs" and shows the host "example.com"

  @backlog @mobile
  Scenario Outline: A link to GitHub carries GitHub's mark
    When the agent's reply links to "<host>"
    Then the link <mark>

    Examples:
      | host                       | mark                            |
      | https://github.com/o/r     | is marked with GitHub's mark    |
      | https://gist.github.com/x  | is marked with GitHub's mark    |
      | https://notgithub.com/x    | is shown with the generic mark  |

  @backlog @mobile
  Scenario Outline: A link to a file in a reply is named after the file
    When the agent's reply links to "<link>" with the text "see here"
    Then the link reads "<label>" with the icon of its file type

    Examples:
      | link                               | label         |
      | file:///repo/README.md#L12         | README.md:12  |
      | src/main.ts#L18C2                  | main.ts:18:2  |
      | apps/mobile/src/index.ts:10        | index.ts:10   |
      | docs/My%20Folder/checklist.xml     | checklist.xml |

  @backlog @mobile
  Scenario: A path in code formatting is a file link and the same path in prose is not
    When the agent's reply reads "/tmp/frame.png" in plain text and again in code formatting
    Then only the path in code formatting is a link to the file

  @backlog @mobile
  Scenario: A link keeps its destination when its text is code
    When the agent's reply links to "https://example.com/docs" with the text "src/main.ts" in code formatting
    Then the link opens "https://example.com/docs"

  @backlog @mobile
  Scenario: A path to a screen of the app is not shown as a link to a file
    When the agent's reply links to "/chat/settings"
    Then the text is shown without a link

  @backlog @mobile
  Scenario: A web address without a scheme in a reply is opened as a web address
    When the agent's reply links to "//cdn.example.com/clip.mp4"
    Then the link opens "https://cdn.example.com/clip.mp4" and not a file on the phone

  @backlog @mobile
  Scenario: A mention of a file does not take the punctuation after it
    When the agent's reply reads "Inspect @src/Checkout.tsx. Use @hal-c2/contracts."
    Then "@src/Checkout.tsx" is shown as a chip naming "Checkout.tsx" and the full stop stays outside it
    And "@hal-c2/contracts" stays text

  @backlog @mobile
  Scenario: Copying a chip in a reply copies what it stands for
    Given the agent's reply shows a skill chip "$ui" and a file chip "Checkout.tsx" for "@src/Checkout.tsx"
    When the user selects and copies the text of the reply
    Then the clipboard holds "$ui" and "@src/Checkout.tsx", not the chips' short labels

  @backlog @mobile
  Scenario: Copying a reply leaves out the small icon beside a file or a link
    Given the agent's reply says "Open src/Checkout.tsx, then read the docs on example.com."
    And the file and the link each show a small icon before their text
    When the user selects and copies the whole reply
    Then the clipboard holds the sentence with no icon character and no extra space in front of the file or the link

  @backlog @mobile
  Scenario: The handles of a text selection follow the theme
    Given the user selected text in a reply
    When the phone switches between the light and the dark theme
    Then the selection's handles take the colours of the new theme
    And the highlight behind the selected text is unchanged

  @backlog @mobile
  Scenario: Tapping elsewhere clears the text selected in a reply
    Given the user selected a sentence of a reply
    When the user taps outside that reply
    Then the selection is cleared

  @backlog @mobile
  Scenario: Select all is offered while only part of a reply is selected
    Given the user selected one word of a reply
    When the selection menu opens
    Then it offers to select all of the reply's text
    When the whole reply is selected
    Then the menu no longer offers to select all

  @backlog @mobile
  Scenario: A skill the thread's provider offers is shown as a chip in a reply
    Given the provider offers the skill "ui" named "UI"
    When the agent's reply reads "Use $ui for this."
    Then "$ui" is shown as a chip labelled "UI"

  @backlog @mobile
  Scenario: Text that only looks like a skill stays text in a reply
    Given the provider does not offer a skill called "unknown"
    When the agent's reply reads "Use $unknown for this."
    Then "$unknown" is shown as plain text
