# Sources:
#   https://github.com/pingdotgg/t3code/pull/29741
#   https://github.com/pingdotgg/t3code/pull/29755
#   https://github.com/pingdotgg/t3code/pull/23954
#   https://github.com/pingdotgg/t3code/pull/29355
#   https://github.com/pingdotgg/t3code/pull/32403
#   https://github.com/pingdotgg/t3code/pull/27519
#   https://github.com/pingdotgg/t3code/pull/27144
#   https://github.com/pingdotgg/t3code/pull/22883
#   https://github.com/pingdotgg/t3code/pull/24050
#   https://github.com/pingdotgg/t3code/pull/23621
#   https://github.com/pingdotgg/t3code/pull/26639
#   https://github.com/pingdotgg/t3code/pull/21363
#   https://github.com/pingdotgg/t3code/pull/21353
#   https://github.com/pingdotgg/t3code/pull/22777
#   https://github.com/pingdotgg/t3code/pull/21454
#   https://github.com/pingdotgg/t3code/commit/a12d6ed9428d8e64d76ca86d178abbf564b57cee
#   https://github.com/pingdotgg/t3code/pull/20878
#   https://github.com/pingdotgg/t3code/pull/16198
#   https://github.com/pingdotgg/t3code/pull/14778
#   https://github.com/pingdotgg/t3code/pull/21069
#   https://github.com/pingdotgg/t3code/pull/10987
#   https://github.com/pingdotgg/t3code/pull/14510
#   https://github.com/pingdotgg/t3code/pull/18308
#   https://github.com/pingdotgg/t3code/pull/21497
#   https://github.com/pingdotgg/t3code/pull/18735
#   https://github.com/pingdotgg/t3code/pull/13859
#   https://github.com/pingdotgg/t3code/pull/19677
#   https://github.com/pingdotgg/t3code/pull/16249
#   https://github.com/pingdotgg/t3code/pull/18389
#   https://github.com/pingdotgg/t3code/pull/19719
#   https://github.com/pingdotgg/t3code/pull/19854
#   https://github.com/pingdotgg/t3code/pull/20080
#   https://github.com/pingdotgg/t3code/pull/20120
#   https://github.com/pingdotgg/t3code/pull/20400
#   https://github.com/pingdotgg/t3code/pull/17923
#   https://github.com/pingdotgg/t3code/pull/16950
#   https://github.com/pingdotgg/t3code/pull/19337
#   https://github.com/pingdotgg/t3code/pull/19401
#   https://github.com/pingdotgg/t3code/pull/15618
#   https://github.com/pingdotgg/t3code/pull/15824
#   https://github.com/pingdotgg/t3code/pull/13807
#   https://github.com/pingdotgg/t3code/pull/13909
#   https://github.com/pingdotgg/t3code/pull/12449 (a link to the project folder opens the Files explorer)
#   https://github.com/pingdotgg/t3code/pull/13795
#   https://github.com/pingdotgg/t3code/pull/11477
#   https://github.com/pingdotgg/t3code/pull/22787
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
#   apps/desktop-qt/qml/HalC2/Bricks/TextEditMenu.qml (the right-click menu on a reply's text)
#   apps/desktop-qt/qml/HalC2/Bricks/js/markdown.js (escaping, safe links, streaming segments)
#   apps/desktop-qt/src/native/CodeHighlighter.cpp, native/syntax (code colours: syntect with bat's syntaxes, the Pierre themes)
#   apps/tui/src/host/codeColours.ts (code colours on the terminal: OpenTUI's tree-sitter and its grammars)
#   apps/desktop-qt/tests/tst_Markdown.qml
#   apps/desktop-qt/tests/native/features/MarkdownSteps.cpp
#   https://mermaid.js.org/intro/syntax-reference.html (Mermaid diagrams in a reply)
#   https://github.com/hal-c2/hal-c2/issues/843
#   https://github.com/pingdotgg/t3code/pull/12615
#   https://github.com/pingdotgg/t3code/pull/15067
#   https://github.com/pingdotgg/t3code/pull/15509
#   https://github.com/pingdotgg/t3code/pull/15520
#   https://github.com/pingdotgg/t3code/pull/22120
#   https://github.com/pingdotgg/t3code/pull/22153
#   https://github.com/pingdotgg/t3code/pull/22621
#   https://github.com/pingdotgg/t3code/pull/25246
#   https://github.com/pingdotgg/t3code/pull/25432
#   https://github.com/pingdotgg/t3code/pull/25802
#   https://github.com/pingdotgg/t3code/pull/21472
#   https://github.com/pingdotgg/t3code/pull/21403
#   https://github.com/pingdotgg/t3code/pull/28072
#   https://github.com/pingdotgg/t3code/pull/26449
#   https://github.com/pingdotgg/t3code/pull/26871
#   https://github.com/pingdotgg/t3code/pull/26095
#   https://github.com/pingdotgg/t3code/pull/26398
#   https://github.com/pingdotgg/t3code/pull/22875
#   https://github.com/pingdotgg/t3code/pull/22893
#   https://github.com/pingdotgg/t3code/pull/22367
#   https://github.com/pingdotgg/t3code/pull/27794
#   https://github.com/pingdotgg/t3code/pull/29079
#   https://github.com/pingdotgg/t3code/pull/28637
#   https://github.com/pingdotgg/t3code/pull/30762
#   https://github.com/pingdotgg/t3code/pull/30606

Feature: Formatted messages
  Messages are written in Markdown. The timeline shows headings, lists, quotes, code and
  tables formatted, lets the user copy code and tables, and never lets a message's text
  load anything or pass itself off as something it is not.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  @shared @backlog-mobile @priority-high
  Scenario: A reply shows its formatting
    When the agent answers with a heading, a list, a quote, a code block and a table
    Then the heading and the list are shown as text
    And the quote, the code block and the table are each shown in their own form

  # Upstream #22777: Arabic and Hebrew read and line up right to left. Each block takes the
  # direction of most of its words, each word voting by its first letter, inline code not voting
  # and a tie going to the first word, so a few English terms do not flip a line.
  @shared @backlog
  Scenario Outline: Each block of a reply reads in the direction of most of its words
    When the agent answers with the <block> "<text>"
    Then the <block> reads <direction>, its bullets, numbers or rule on that side

    Examples:
      | block     | text                              | direction     |
      | paragraph | StrictMode: يعيد الـ render مرتين | right to left |
      | list      | اكتب دالة `sumBy` تجمع القيم      | right to left |
      | paragraph | Run `npm test` before you push    | left to right |

  # Upstream #26095: a mostly Arabic paragraph with one long English sentence had more English
  # words and read left to right. Each sentence now votes by its words, and the block goes the way
  # most of its sentences do; "index.ts" or "v1.2" do not end a sentence.
  @shared @backlog
  Scenario: A paragraph of mostly right-to-left sentences reads right to left
    When the agent answers with a paragraph of three Arabic sentences and one long English sentence
    And the paragraph has more English words than Arabic ones
    Then the paragraph reads right to left

  # Upstream #22777: Arabic and Hebrew text reads and navigates right to left, with code kept left to right.
  @shared @backlog
  Scenario: Code inside right-to-left text stays left to right
    When the agent answers in Arabic with "fetch()" in inline code and a code block after it
    Then "fetch()" and the code block read left to right

  # Upstream #22777: Arabic and Hebrew text reads right to left, including a thread title.
  @shared @backlog @priority-low
  Scenario: A thread title reads in its own direction
    Given a thread titled in Hebrew
    Then the sidebar, the thread's header and the command palette show the title right to left
    And a title too long to fit is cut at its end

  # Upstream #24050: the same word-majority rule now covers what sits around a message, and code
  # and links in a message or question do not vote.
  @shared @backlog
  Scenario Outline: Right-to-left text around a message reads right to left
    When the user writes <text> in Hebrew
    Then <shown> reads right to left and lines up on the right

    Examples:
      | text                                 | shown                                                 |
      | a comment on a cited passage         | the comment box, the citation chip and its popover    |
      | a comment on a diff line             | the comment box and the saved comment                 |
      | a message with images and files      | the message, its images and file rows starting on the right |

  # Upstream #24050
  @shared @backlog
  Scenario: A question set reads in the direction of most of its text
    Given the agent asks two questions in Hebrew, with options holding a code block and "Node.js"
    Then each header, option label and description reads in its own direction
    And the question card, its choices and their numbers sit on the right
    And the card does not flip side while the user steps through the questions

  @shared @backlog @priority-low
  Scenario: An ordered list past 99 keeps its whole numbers
    When the agent answers with an ordered list numbered 96 to 103
    Then every item shows its whole number, from "96." to "103."

  @shared @backlog
  Scenario Outline: A table right under a line of text is shown as a table
    When the agent answers with a line of text and, on the next line with no blank line between, a table <where>
    Then the table is shown as a table and not as a run-on paragraph

    Examples:
      | where                 |
      | at the top level      |
      | inside a quote        |
      | inside a list item    |

  @shared @backlog
  Scenario: Character references in a reply are shown as their characters
    When the agent answers with "Tom &amp; Jerry &copy; 2026"
    Then the reply reads "Tom & Jerry © 2026"

  @mobile @backlog @priority-low
  Scenario: Long pressing a link in a reply opens only the link's menu
    When the user long presses a link in the agent's reply
    Then the link's menu opens
    And no text is selected and no table or code block menu opens with it

  @shared @backlog-mobile @priority-high
  Scenario: The user copies a code block
    Given the agent's reply has a code block
    When the user copies the code block
    Then the code block's source is on the clipboard
    And the code block shows it was copied

  # A reply's text that is not a link has the menu of text that cannot be
  # changed; a link keeps its own.
  @desktop
  Scenario: A reply's selected text is copied from its right-click menu
    Given the agent answers "Refunds reuse the old rate."
    When the user selects "Refunds" in the reply
    And the user chooses "Copy" from the reply's right-click menu
    Then the clipboard holds "Refunds"

  @desktop
  Scenario: A reply's right-click menu cannot change the reply
    Given the agent answers "Refunds reuse the old rate."
    When the user right-clicks the reply's text
    Then the menu offers "Copy" and "Select All" only

  # Inline code is one tinted run with no spaces added around it. Only a
  # span too long for a phone's line may break, and then only after a slash
  # or a hyphen.
  @desktop @mobile @backlog-mobile
  Scenario: Inline code stays whole and reads as written
    Given the agent answers "The MC lives in `apps/server-ex`, so run (`mix test`)."
    Then the reply's words read "The MC lives in apps/server-ex, so run (mix test)."
    And "apps/server-ex" stays on one line however narrow the timeline is
    When the user selects "apps/server-ex" in the reply
    And the user chooses "Copy" from the reply's right-click menu
    Then the clipboard holds "apps/server-ex"
  # Upstream #26639: a double-click on inline code selected only up to a hyphen.
  @shared @backlog
  Scenario: A double-click on inline code selects all of it
    Given the agent answers "Run `migration-gate` again."
    When the user double-clicks "migration" in the reply
    Then "migration-gate" is selected
    And a double-click on "again" still selects only that word


  @desktop
  Scenario: Select All in a code block's right-click menu selects its code
    Given the agent's reply has a code block
    When the user chooses "Select All" from the code block's right-click menu
    Then the code block's source is selected

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

  # Passes today; upstream #26449 removed the collapsed mode, see the backlog scenario below.
  @shared @backlog-mobile
  Scenario: Table cells can be collapsed and expanded
    Given the agent's reply has a table with a long cell
    When the user collapses the table cells
    Then the long cell stays on one line
    When the user expands the table cells
    Then the long cell wraps

  # Upstream #20878: an expanded table kept its full width, so wrapped columns ran out of view.
  # Upstream #26449: every table opens this way, whatever the word wrap setting and the width.
  @shared @backlog
  Scenario: A wide table fits the conversation with its cells wrapped
    Given the agent's reply has a table wider than the conversation, with long prose cells
    When the user looks at the reply
    Then every column fits in the conversation's width, headings wrapping with the cells at word boundaries
    And only a word too long to break still needs scrolling sideways

  # Upstream #26449: tables have no collapsed mode any more; every table wraps its cells and
  # fits the conversation. This replaces "Table cells can be collapsed and expanded".
  @shared @backlog @priority-low
  Scenario: A table offers no collapsed mode
    Given the agent's reply has a table with a long cell
    When the user looks at the reply
    Then the long cell wraps
    And the table offers no way to collapse its cells

  # Upstream #26449: a short link label such as "#9514" is not broken inside a narrow column.
  @shared @backlog @priority-low
  Scenario: A short link in a narrow table column stays whole
    Given the agent's reply has a table whose narrow column links "#9514"
    When the user looks at the reply
    Then "#9514" is shown on one line

  @shared @backlog-mobile
  Scenario: Markup in a message is shown as it was written
    When the agent answers with HTML and an image
    Then the HTML is shown as written
    And the image is a link to its address and nothing is loaded from the web

  # Upstream #13807: a trailing "_" or "~" is part of a bare web address.
  # Upstream #27794: the same fix again, for bare and "www." addresses only; explicit links and
  # emphasis keep their own rules.
  @shared @backlog
  Scenario Outline: A bare web address in a reply keeps a trailing underscore or tilde
    When the reply contains the bare address "<address>"
    Then the link is "<address>" in full

    Examples:
      | address                                 |
      | https://example.com/foo_                |
      | https://localhost/a~                    |
      | https://example.com/a_b_                |

  # Upstream #13807: sentence punctuation after a bare web address is left outside the link.
  @shared @backlog
  Scenario Outline: Punctuation after a bare web address stays outside the link
    When the reply contains the bare address "<address>" followed by "<punctuation>"
    Then the link is "<address>"
    And "<punctuation>" is shown after it

    Examples:
      | address               | punctuation |
      | https://example.com/a | .           |
      | https://example.com/a | ...         |
      | http://localhost:3000 | ,           |

  @shared @backlog-mobile
  Scenario: A link to a script is not a link
    When the agent answers with a link to "javascript:alert(1)"
    Then the link's text is shown and nothing can be opened

  @shared @backlog-mobile @backlog-tui @priority-high
  Scenario: A reply being written keeps what is already shown
    Given the agent is writing a reply of several paragraphs
    When the reply grows by another paragraph
    Then the paragraphs already shown are not drawn again

  @shared @backlog-mobile @priority-high
  Scenario: A code block is shown as code while it is written
    Given the agent is writing a code block
    Then the code written so far is shown as a code block
    When the agent closes the code block
    Then the same code block is shown, finished

  @shared @backlog-mobile @priority-low
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

  # The same renderer draws diagrams in pages and the file viewer
  # (features/space/markdown.feature).
  # https://github.com/hal-c2/hal-c2/issues/843
  @shared @backlog-mobile @priority-low
  Scenario: A Mermaid diagram in a reply is drawn
    When the agent answers with a "mermaid" code block holding a flowchart
    Then on the desktop and the phone the flowchart is drawn in place of the code block
    And in the terminal the diagram is drawn in characters, or its source is shown, named as a "flowchart" diagram
    And the user can switch to the diagram's source and copy it

  # https://github.com/hal-c2/hal-c2/issues/843
  @shared @backlog-mobile @priority-low
  Scenario: A Mermaid diagram that cannot be drawn shows its source and says why
    When the agent answers with a "mermaid" code block holding a flowchart with an unclosed bracket
    Then the diagram's source is shown as a code block
    And the user is told where the mistake is
    And nothing claims the diagram is still being drawn

  # Upstream #27519: a D2 or Mermaid diagram opened smaller than it was drawn inline, since the
  # viewer never grew an image past its own size.
  @backlog @shared @priority-low
  Scenario Outline: An opened diagram fills the image viewer
    When the user opens <image> from a reply in the image viewer
    Then it <fit>

    Examples:
      | image                                       | fit                                        |
      | an SVG diagram with only a view box         | is scaled up to fill the viewer            |
      | a drawn Mermaid diagram                     | is scaled up to fill the viewer            |
      | a small screenshot                          | is shown no larger than its own size       |

  # Upstream #16198: maths in Mermaid labels is drawn.
  @backlog @desktop @mobile @priority-low
  Scenario: Maths in a Mermaid diagram's labels is drawn
    Given the agent replies with a Mermaid diagram whose node label holds "$x^2$"
    When the reply is shown
    Then the node's label shows the formula drawn as maths

  # Upstream #21472: Mermaid diagrams follow the theme without being drawn again.
  @backlog @shared @priority-low
  Scenario: A theme change recolours Mermaid diagrams without drawing them again
    Given a reply with a drawn Mermaid flowchart
    When the user switches between the light and the dark theme
    Then the diagram takes the new theme's colours without being drawn again

  # Upstream #21472: a wide left-to-right flowchart is scaled down to fit, never turned upright.
  @backlog @shared @priority-low
  Scenario: A Mermaid diagram keeps the direction it was written in
    Given the agent replies with a wide left-to-right Mermaid flowchart
    When the reply is shown in a narrow column
    Then the flowchart is drawn left to right, scaled down to fit

  # Upstream #21472: links and images inside a diagram are not followed or loaded.
  @backlog @shared
  Scenario: Links and images in a Mermaid diagram are not loaded
    Given the agent replies with a Mermaid diagram whose nodes hold a link and an image
    When the reply is shown
    Then the diagram is drawn without the link or the image

  # Upstream #18308: completed Mermaid blocks are drawn while the reply still streams.
  # https://github.com/hal-c2/hal-c2/issues/843
  @shared @backlog-mobile
  Scenario: A Mermaid diagram being written is drawn once it is finished
    When the agent is still writing a "mermaid" code block
    Then the code written so far is shown as a code block
    When the agent closes the code block
    Then the diagram is drawn

  # Upstream #18735: chat markdown can draw LaTeX formulas, behind a setting that is off by default.
  @backlog @shared @priority-low
  Scenario: Formulas in a reply are drawn when math rendering is on
    Given the user turned on math rendering
    When the agent replies with an inline formula and a formula on its own lines
    Then both formulas are drawn as math
    And with math rendering off they are shown as the agent wrote them

  # Upstream #18735: a selection across a drawn formula copies its TeX, not the drawn symbols.
  @backlog @shared @priority-low
  Scenario: Copying a drawn formula gives its TeX
    Given math rendering is on and a reply holds a drawn formula
    When the user selects the formula and copies it
    Then the clipboard holds the formula's TeX source

  # Upstream #23954: Tab stopped on every equation, even ones that fit, to offer scrolling.
  @backlog @shared @priority-low
  Scenario: Only a formula too wide to fit takes a keyboard stop
    Given math rendering is on and a reply holds one formula that fits and one wider than the reply
    When the user moves through the reply with Tab
    Then focus stops on the wide formula, which then scrolls with the arrow keys
    And it skips the formula that fits

  # Upstream #18735: dollar amounts and unfinished formulas stay as text.
  @backlog @shared @priority-low
  Scenario: A price is not mistaken for a formula
    Given math rendering is on
    When the agent writes "it costs $5 and $10"
    Then the text is shown as written, not as math
    And a formula the agent is still writing is shown as text until it is finished

  # Upstream #22367: a horizontal rule blended into dark themes, in replies and in the composer.
  @backlog @shared @priority-low
  Scenario: A horizontal rule stays visible in a dark theme
    Given the user picked a dark theme
    When a reply or the composer holds a horizontal rule
    Then the rule is visible against the background without being selected

  # Upstream #22875: copying a table changed the bars inside its formulas.
  @backlog @shared @priority-low
  Scenario Outline: A copied table keeps its formulas as written
    Given math rendering is on and a reply's table has a cell with a formula of <bars>
    When the user copies the table as Markdown and pastes it back
    Then the cell's formula is exactly as the agent wrote it

    Examples:
      | bars                     |
      | absolute value bars      |
      | escaped double norm bars |

  # Upstream #29355: the phone turned "<br>" in a table cell into a space, so items ran together,
  # and copying lost the breaks.
  @backlog @shared @priority-low
  Scenario: A line break in a table cell is kept and copied back as "<br>"
    Given the agent's reply has a table cell "Apples<br>Pears"
    When the user looks at the reply
    Then the cell shows "Apples" and "Pears" on separate lines
    When the user copies the table as Markdown
    Then the cell reads "Apples<br>Pears"

  # Upstream #22893: an escaped backslash right before "\(" broke the message.
  @backlog @shared @priority-low
  Scenario: An escaped backslash before a formula opener is shown as a backslash
    Given math rendering is on
    When the agent writes "\\\(x^2\)"
    Then the message shows a backslash followed by the text as written
    And the thread still opens

  # Upstream #22883: a formula ending in a comma stayed as text, and its dollars could pair with later ones.
  @backlog @shared @priority-low
  Scenario Outline: A formula that ends in a comma is drawn
    Given math rendering is on
    When the agent writes "<text>"
    Then <outcome>

    Examples:
      | text                         | outcome                                         |
      | where $x = 1,$ and $f(x),$   | "x = 1," and "f(x)," are drawn as math          |
      | with $$a,$$ and $$ b,$$.     | "a," and "b," are drawn and " and " stays text  |
      | it costs $5,$10              | the text is shown as written, not as math       |


  @shared @backlog-mobile @priority-high
  Scenario: A user message keeps its line breaks
    Given the user's message has two lines
    Then the message is shown on two lines

  @desktop @mobile @backlog @priority-low
  Scenario Outline: A code block is headed by the file name its fence gives
    Given the agent's reply has a code block whose fence reads <fence>
    Then the code block is headed "<heading>"

    Examples:
      | fence                  | heading      |
      | ts title="src/cart.ts" | src/cart.ts  |
      | ts filename=cart.ts    | cart.ts      |
      | ts file='src/cart.ts'  | src/cart.ts  |
      | ts src/cart.ts         | src/cart.ts  |

  # Upstream #28072: the phone rendered every fold in a chat reply open; it now starts closed.
  @desktop @mobile @backlog
  Scenario: A collapsible section in a reply opens and closes
    Given the agent's reply has a collapsible section titled "Full log"
    Then the section is closed and shows "Full log"
    When the user opens the section
    Then its content is shown
    When the user closes the section
    Then its content is hidden

  @desktop @mobile @backlog @priority-low
  Scenario: A collapsible section without a title is called "Details"
    Given the agent's reply has a collapsible section with no title
    Then the section shows "Details"

  # Upstream #28072: folds honour "open", nest, and a fold still streaming runs to the reply's end;
  # tags inside code stay text.
  @desktop @mobile @backlog
  Scenario Outline: A collapsible section in a reply follows how it was written
    Given the agent's reply has <section>
    Then <shown>

    Examples:
      | section                                                      | shown                                                |
      | a collapsible section marked open                            | the section starts open                              |
      | a collapsible section inside another one                     | each section opens and closes on its own             |
      | a collapsible section whose end has not streamed yet         | the section holds the rest of the reply, closed      |
      | a collapsible section written inside a code block            | the code block shows the tags as text                |

  @desktop @backlog @priority-low
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
  @backlog @desktop @mobile @priority-low
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

  # Upstream #26871: a full stop after a file chip could wrap onto the next line by itself.
  @backlog @shared @priority-low
  Scenario: Punctuation after a file chip stays on the chip's line
    Given the agent's reply ends a sentence with a file chip followed by a full stop
    When the chip reaches the end of a line
    Then the full stop wraps with the chip and is never alone at the start of a line
    And ordinary links and code in the reply wrap as before

  # Legacy: packages/client-runtime/src/codexFileCitations.ts (markdownDestinationPath),
  # packages/client-runtime/src/codexMarkdownDirectives.test.ts (path round trips)
  @backlog @desktop @mobile @priority-low
  Scenario Outline: A cited file whose path has awkward characters still opens that file
    When the agent's reply cites the file <path> at line 7
    Then following the chip opens <path> at line 7

    Examples:
      | path                              |
      | "C:\Users\test\[draft]\report.md" |
      | "\\server\share\report.md"        |
      | "/tmp/report%5C.md"               |
      | "notes #2/plan?.md"               |

  # Upstream #25802: a relative link with non-ASCII folder or file names was a web link.
  @backlog @shared
  Scenario: A relative link in any script is a file chip
    When the agent's reply holds "[exam](pastexam/線性代數/考試.pdf)"
    Then it is shown as a file chip for "pastexam/線性代數/考試.pdf", not as a web link

  # Upstream #28637: route file names from Next.js, SvelteKit and TanStack Router, and npm scope
  # folders, were not file links unless written with "./".
  @backlog @shared
  Scenario Outline: A relative link with routing punctuation is a file chip
    When the agent's reply holds "[<name>](<path>)"
    Then it is shown as a file chip for "<path>", not as a web link

    Examples:
      | name                  | path                                     |
      | page.tsx              | app/(marketing)/page.tsx                 |
      | posts.$postId.tsx     | app/routes/posts.$postId.tsx             |
      | +page.svelte          | src/routes/+page.svelte                  |
      | [slug].tsx            | pages/blog/[slug].tsx                    |
      | index.ts              | node_modules/@scope/pkg/index.ts         |

  # Upstream #28637: a bare name with "@" stays an address, not a file.
  @backlog @shared
  Scenario: A bare e-mail address as a link target is not a file chip
    When the agent's reply holds "[write](me@example.com)"
    Then it is not shown as a file chip

  # Legacy: packages/client-runtime/src/codexMarkdownDirectives.ts (renderCodexDirectivesForCopy)
  @backlog @desktop @mobile
  Scenario: Copying a reply copies its file citations and template cards as plain text
    Given the agent's reply cites "outputs/report.xlsx" and offers the "Hello World" document template
    When the user copies the reply
    Then the clipboard holds a link named "report.xlsx" to "outputs/report.xlsx"
    And the clipboard holds "Hello World (Document template)"

  # Upstream #14778: a copied task list keeps its nested items and code blocks where they were.
  @backlog @shared @priority-low
  Scenario: A selected task list is copied with its nesting intact
    Given a reply holds a task list with nested items and a code block under one item
    When the user selects the list and copies it
    Then the copied Markdown nests each item under its parent
    And the code block stays under its item

  # Upstream #29755: copying a selection dropped blank lines inside a code block in a list item or
  # quote, and after a fence written inside a longer fence.
  @backlog @shared @priority-low
  Scenario Outline: A copied code block keeps its blank lines when it sits <where>
    Given a reply holds a Python code block with two blank lines before "def main():", <where>
    When the user selects the reply and copies it
    Then the copied code keeps both blank lines and its trailing spaces

    Examples:
      | where                                                     |
      | right under a numbered list item                          |
      | in a loose list item                                      |
      | in a quote                                                |
      | after a fence written inside it, in a longer fence        |

  # Upstream #16249: selected text that spans a Mermaid diagram copies the diagram's source.
  @backlog @desktop
  Scenario: Copying a selection across a Mermaid diagram copies its source
    Given a reply with a sentence, a Mermaid diagram and another sentence
    When the user selects from the first sentence to the last and copies
    Then the clipboard holds both sentences with the diagram's fenced Mermaid source between them

  @backlog @desktop @mobile @plugin-codex @priority-low
  Scenario: A follow-up suggestion from Codex shows its label, not its markup
    When Codex ends its reply with the follow-up suggestion "Prepare print version"
    Then the reply shows "Prepare print version"
    And neither the directive's markup nor its hidden prompt is shown
    And copying the reply copies "Prepare print version"
    But a follow-up suggestion with no label or no prompt, in code, or still streaming stays as written

  # Legacy: packages/client-runtime/src/markdownLinks.ts (inlineCodeFilePathCandidate)
  @backlog @desktop @mobile
  Scenario Outline: A path-shaped word in code formatting is a file chip unless it is a web host or a model id
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
      | "z-ai/glm-5.3"        | left as code                     |
      | "Qwen/Qwen2.5-Coder"  | left as code                     |
      | "vendor/jquery-3.6.0.min.js" | a file chip              |

    # Upstream #32403: a bare C++ source with a line, such as "allocator.cc:217", was read as a host
    # and port; ".cc" now reads as a file when a line follows and as a host otherwise.
    Examples:
      | code                  | shown                            |
      | "allocator.cc:217"    | a file chip                      |
      | "example.cc/docs"     | left as code                     |

    # Upstream #30762: a shortened path such as "/tmp/claude-1000/..." became a chip that asked for a
    # file named "..." and showed it could not be read.
    Examples:
      | code                       | shown        |
      | "/tmp/claude-1000/..."     | left as code |
      | "src/…/cart.ts:12"         | left as code |
      | "../shop/.env"             | a file chip  |

  # Legacy: packages/client-runtime/src/markdownLinks.ts (parseMarkdownFileLink)
  @backlog @desktop @mobile @priority-low
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
      | file://build-box/share/out.log    | not a file link             |
      | /settings/profile                 | not a file link             |
      | mailto:dev@example.com            | not a file link             |
      | https://example.com/cart.ts       | not a file link             |
      | #install                          | not a file link             |

  # Upstream a12d6ed9428d8e64d76ca86d178abbf564b57cee: a network path in a reply made Windows open an SMB session to its host
  # and send the user's credentials, with no click. Network paths (\\h, //h, /\h) now resolve only
  # inside the thread's project, so a project on a share keeps working.
  @backlog @desktop @mobile @mc @priority-high
  Scenario Outline: A network path outside the project is never looked up
    Given the thread's project is "C:\work\shop"
    When the agent's reply <uses> "<path>"
    Then <outcome>
    And the machine running the MC never opens a connection to "attacker.test"

    Examples:
      | uses                 | path                               | outcome                                   |
      | embeds an image from | file://attacker.test/share/cat.jpg | the image is blocked                      |
      | embeds an image from | \\\\attacker.test\share\cat.jpg    | the image is blocked                      |
      | links to             | //attacker.test/share/notes.md     | it is not a file link and nothing is read |
      | links to             | /\\attacker.test\share\notes.md    | it is not a file link and nothing is read |

  # Upstream a12d6ed9428d8e64d76ca86d178abbf564b57cee: network paths resolve only inside the thread's project,
  # so a project on a network share still opens its files.
  @backlog @desktop @mobile @mc
  Scenario: A file link inside a project on a network share still opens
    Given the thread's project is "\\build-box\share\shop"
    When the agent's reply links to "\\build-box\share\shop\src\cart.ts"
    Then the link is a file link to "src/cart.ts"

  # Upstream a12d6ed9428d8e64d76ca86d178abbf564b57cee: network paths resolve only inside the thread's project,
  # so the MC refuses a network path outside it for a file read or media.
  @backlog @mc @priority-high
  Scenario: The MC refuses a network path outside the project for a file read or media
    Given the thread's project is "C:\work\shop"
    When a client asks for the file "\\attacker.test\share\cat.jpg" as media or to read it
    Then the MC refuses it without touching the path
    And it never looks up details of a network path for a file chip

  # Legacy: apps/web/src/markdown-links.ts (workspace root links route to the explorer)
  @backlog @desktop @mobile
  Scenario: A link in a reply to the project's own folder opens the Files explorer
    Given the agent's reply links to the folder of the project "shop"
    When the user clicks the link
    Then the Files explorer opens on the project's top folder
    And no file read is attempted for it

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

  # Upstream #29741: a reply's image of a workspace file kept the copy fetched first, so an image
  # the agent rewrote under the same name showed its old picture for an hour.
  @backlog @shared
  Scenario: An image the agent rewrites under the same name shows its new picture
    Given an earlier reply shows the workspace image "wau.png"
    When the agent rewrites "wau.png" with a command, a file edit, a tool call or a subagent
    And shows it again in a later reply
    Then both replies show the new picture
    But an image whose file did not change is not downloaded again

  # Upstream #22787: an image alone on its line keeps that line instead of joining the label
  # above it; inline images in a sentence stay inline.
  @backlog @shared
  Scenario: An image alone on its line is shown below its label
    When the agent's reply has a line "**Command palette**" with an image alone on the next line
    Then the image is shown below "Command palette", not beside it

  # Upstream #22787: an image inside a sentence stays inline.
  @backlog @shared
  Scenario: An image inside a sentence stays in the sentence
    When the agent's reply has a sentence with a badge image in the middle of it
    Then the badge is shown inline within the sentence

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

  @backlog @desktop @mobile
  Scenario: A host image the connection may not read says to pair again
    Given the client's connection to the MC may not read the host's files
    When the agent's reply embeds the image "/work/shop/assets/logo.png"
    Then the image says it is unavailable because this connection cannot read host files
    And it says to pair again with a new link to view it
    And the client never asked the MC for the file
    But an image that fails while the client is offline still says only that it is unavailable

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

  # Upstream #14510: a repository-relative path in a subfolder project repeated the project's
  # folder; when that path is missing the project's own file opens, and a real file still wins.
  @desktop @backlog
  Scenario Outline: A file named from the repository root opens in a project that is a subfolder
    Given the project "shop" is the folder "apps/shop" of its repository and holds "src/cart.ts"
    And <nested>
    And the agent's reply links to "apps/shop/src/cart.ts"
    When the user follows the link
    Then <opened> opens beside the conversation

    Examples:
      | nested                                    | opened                            |
      | "shop" holds no "apps/shop/src/cart.ts"   | "src/cart.ts"                     |
      | "shop" also holds "apps/shop/src/cart.ts" | "apps/shop/src/cart.ts" in "shop" |

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

  # The desktop's large preview is the Files tab, which a Ctrl-click on the
  # link opens too (ThreadView.qml openLink).
  @desktop
  Scenario: A linked image opens as a preview
    Given the agent's reply links to the file "assets/logo.png"
    When the user opens the menu on the link
    And the user chooses "Open file" from the link's menu
    Then "assets/logo.png" opens as a large preview

  # Upstream #13859: Android image previews kept the window size from when they opened.
  @backlog @mobile @priority-low
  Scenario: An open image preview follows the window when it changes size
    Given the user has opened an image preview on an Android phone
    When the user unfolds the phone or puts the app in split screen
    Then the image and its pan limits fit the new window size

  # The desktop links no video player (Qt Multimedia): it offers the video to
  # open in the browser.
  @desktop @backlog @priority-low
  Scenario: A linked video opens as a preview
    Given the agent's reply links to the file "media/intro.mp4"
    When the user follows the link
    Then "media/intro.mp4" opens as a large preview

  # Upstream #26398: a picture with a dark-scheme source showed "Image unavailable" in a dark theme.
  @backlog @desktop
  Scenario Outline: A picture written for light and dark themes shows the one for the theme
    Given the agent's reply has a picture with one image for a light color scheme and one for a dark
    When the user reads the reply in a <theme> theme
    Then the reply shows the <theme> image

    Examples:
      | theme |
      | light |
      | dark  |

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

  # Colours come from the fence's language, under its usual names and short forms; a fence that
  # names none, or one the app does not know, shows the code as it is.
  @shared @backlog-mobile
  Scenario Outline: A code block is coloured only when its fence names a language
    Given the agent's reply has a code block whose fence reads "<fence>"
    When the user reads the reply
    Then the code block is shown <colouring>

    Examples:
      | fence   | colouring              |
      | ts      | coloured as TypeScript |
      |         | as plain text          |
      | klingon | as plain text          |

    # OpenTUI's tree-sitter ships no Python, Elixir or QML grammar, so the terminal
    # client shows these plain until it carries them.
    @backlog-tui
    Examples:
      | fence | colouring          |
      | py    | coloured as Python |
      | exs   | coloured as Elixir |
      | qml   | coloured as QML    |

  # Upstream #27144: plain-text code blocks drew their own near-white text whatever the theme's text colour.
  @backlog @shared @priority-low
  Scenario Outline: A plain-text code block uses the theme's text colour
    Given the user's theme has a muted grey text colour
    And the agent's reply has a code block whose fence reads "<fence>"
    When the user reads the reply
    Then the code block's text is the theme's grey text colour

    Examples:
      | fence     |
      | text      |
      | plaintext |
      |           |

  @shared @backlog-mobile
  Scenario: A code block still being written keeps the colours of its finished lines
    Given the agent is writing a code block whose fence reads "ts"
    And its first three lines are coloured
    When the agent adds a fourth line
    Then the first three lines stay coloured while the new line waits to be coloured
    And the block does not flash back to plain text

  @shared @backlog-mobile
  Scenario: Code follows the theme without being read again
    Given the appearance is Light
    And the agent's reply has a code block whose fence reads "ts"
    And the code block is shown coloured as TypeScript
    When the user switches the app from light to dark
    Then the code block is coloured for the dark theme
    And its code was not read again

  @backlog @mobile
  Scenario: A video embedded in a reply plays on request
    Given the agent's reply embeds the video "demo.mp4" from the thread's workspace
    When the user reads the reply
    Then "demo.mp4" is shown as a video
    When the user taps it
    Then it plays in a large preview

  # Upstream #21363: audio in a reply or attached to a message plays where it is,
  # instead of only in the file viewer.
  # Upstream #21353: same change as #21363.
  @backlog @shared
  Scenario Outline: Audio <where> plays in the conversation
    Given <given>
    When the user plays "note.wav" in the conversation
    Then it plays there, showing its length and how far it has played
    When the user opens its name
    Then "note.wav" opens in the file viewer

    Examples:
      | where                  | given                                                         |
      | in a reply             | the agent's reply embeds the audio "note.wav" from the workspace |
      | inside a sentence      | the agent's reply mentions the audio "note.wav" mid-sentence  |
      | attached to a message  | the user's message carries the attached "note.wav"            |

  # Upstream #21363: a recording streamed without a known length stayed loading for good.
  @backlog @shared @priority-low
  Scenario: Audio whose length is not known yet still plays
    Given the agent's reply embeds a recording whose length is not known until it has played
    When the user plays it
    Then it plays, showing how far it has played
    And its length is shown once it is known

  # Upstream #21353: on the phone, documents the agent shares open in the viewer; tables open
  # as tables.
  @backlog @shared
  Scenario Outline: A file the agent shares opens in the file viewer
    Given the agent's reply links to "<file>" in the workspace
    When the user opens it
    Then "<file>" opens in the file viewer <shown>

    Examples:
      | file          | shown              |
      | docs/spec.pdf | as a document      |
      | data/q3.csv   | as a table         |

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

  # Upstream #18389: Open in editor and copy on a basename file chip use the file the chip resolves to.
  @backlog @desktop
  Scenario: A file chip named by its basename opens that file in the editor
    Given a reply cites "cart.ts:12" and the only such file is "src/lib/cart.ts"
    When the user opens the chip in the editor
    Then "src/lib/cart.ts" opens at line 12
    And copying the chip's path copies "src/lib/cart.ts"

  # Upstream #21403: the phone opened a file of that name at the project's top, which did not
  # exist, and dropped the line.
  @backlog @mobile
  Scenario Outline: A file link on the phone opens the file it names
    Given the project "shop" holds "src/math.ts" and the agent's reply links to <link>
    When the user taps the link on the phone
    Then "src/math.ts" opens at line 12

    Examples:
      | link                       |
      | "math.ts:12"               |
      | "src/math.ts:12"           |
      | "~/code/shop/src/math.ts:12" |

  # Upstream #21403: a link to a folder said "File unavailable" on the phone.
  @backlog @mobile
  Scenario: A folder link on the phone opens the file browser on that folder
    Given the agent's reply links to "src/"
    When the user taps the link on the phone
    Then the file browser opens on "src"

  @backlog @mc @shared @priority-low
  Scenario Outline: A file chip shows what the path really is
    Given the agent's reply names <path>, which is <what>
    When the reply is shown
    Then the chip shows the icon of <kind>
    And its tooltip gives the file's size when it is a file

    Examples:
      | path        | what                        | kind        |
      | "Makefile"  | a file without an extension | a file      |
      | "src/v1.2"  | a folder with a dot         | a folder    |
      | ".env"      | a dotfile                   | a file      |

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

  # Upstream #21497: relative paths are copied relative to the thread's workspace.
  @desktop @backlog
  Scenario: A relative path is copied from the thread's own workspace
    Given the thread works in a worktree of "shop"
    And the agent's reply links to "src/cart.ts" in that worktree
    When the user copies its relative path from the file chip's menu
    Then "src/cart.ts" is copied, not a path from the project's folder

  @desktop @backlog
  Scenario: A copied path that cannot reach the clipboard says so
    Given the agent's reply links to the file "src/cart.ts"
    And the clipboard refuses the copy
    When the user copies its full path from the file chip's menu
    Then the user is told "Failed to copy full path" with the reason

  @desktop @backlog @priority-low
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
      | link                                    | host                           |
      | http://localhost:3000/                  | localhost                      |
      | http://192.168.1.20/admin               | 192.168.1.20                   |
      | http://10.0.0.5:8080/                   | 10.0.0.5                       |
      | https://build.internal/runs/1           | build.internal                 |
      | https://box.example.test/               | box.example.test               |
      | http://[fd00::1]/                       | fd00::1                        |
      | https://grafana.internal.acme-corp.com/ | grafana.internal.acme-corp.com |
      | http://nas.lan/                         | nas.lan                        |
      | http://wiki.corp/                       | wiki.corp                      |

  @desktop @backlog @priority-low
  Scenario: A public site's icon is asked for by its name alone
    When the agent's reply links to "https://example.com:8443/docs" with the text "the docs"
    Then the public icon service is told only "example.com", without the port

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

  # Upstream #10987: Azure DevOps and nested GitLab pull request links opened in the browser; they
  # now open in the panel.
  @desktop @backlog
  Scenario Outline: A pull request link on any host opens beside the conversation
    Given a message links "<url>"
    When the user follows the link
    Then the pull request opens beside the conversation

    Examples:
      | url                                                      |
      | https://dev.azure.com/acme/shop/_git/api/pullrequest/42  |
      | https://gitlab.com/acme/platform/web/-/merge_requests/42 |

  # Upstream #10987: an Azure DevOps link resolves to the project whose Azure project matches,
  # not the first repository with that name.
  @desktop @backlog @priority-low
  Scenario: An Azure DevOps link opens in the project whose Azure project matches
    Given projects "Payments" and "Billing" both have an Azure DevOps repository "api"
    When the user follows a link to a pull request in the "Billing" Azure project's "api"
    Then the pull request opens for the "Billing" project

  @desktop @backlog @priority-low
  Scenario Outline: A pull request link opened with a modifier goes to the browser
    Given the project's repository has pull request 42
    When the user <opens> a link to pull request 42
    Then pull request 42 opens in the system browser
    And it does not open beside the conversation

    Examples:
      | opens                          |
      | Ctrl or Cmd-clicks             |
      | middle-clicks                  |

  @desktop @backlog @priority-low
  Scenario: Pull request links can always open on the hosting site
    Given the user turned off "Open pull requests in HAL-C2" in the browser settings
    When the user follows a link to pull request 42 from a reply, a reference, the sidebar or the composer
    Then pull request 42 opens like any other link, following where links open
    When the user turns the setting back on
    Then pull request links open beside the conversation again

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

  # Upstream #11477: a task checkbox belongs to its own list item, not to a nested one.
  @desktop @backlog
  Scenario: A parent item with a checked child copies as a plain bullet
    Given the agent's reply is a plain item with a checked item nested under it
    When the user selects both and copies
    Then the clipboard holds "- Parent" and the nested "- [x] Child"

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

  @desktop @backlog @priority-low
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

  # Upstream #25246: Escape closed the whole enlarged image while a popup inside it was open.
  @desktop @backlog @priority-low
  Scenario: Escape closes a popup inside an enlarged image before the image
    Given the user enlarged an image from the agent's reply
    And a popup inside the enlarged image is open
    When the user presses Escape
    Then the popup closes and the image stays enlarged
    When the user presses Escape again
    Then the image closes and the keyboard is back on the image in the reply

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

  # Upstream #23621: an image given inline as data could not be copied or saved; the app said it
  # could not be fetched.
  @desktop @backlog
  Scenario Outline: An image given inline as data can be copied and saved
    Given the agent's reply embeds an image given inline as data
    When the user chooses "<action>" from the media's menu
    Then <outcome>

    Examples:
      | action     | outcome                               |
      | Copy image | the clipboard holds the picture        |
      | Save image | the picture is saved                   |

  # Upstream #29079: Save image and Copy image fetched the image again, and failed for a host
  # that lets the image show but refuses other reads.
  @desktop @backlog
  Scenario Outline: An image the reply shows can be copied and saved even when its host refuses other reads
    Given the agent's reply shows an image from a host that refuses cross-site reads
    When the user chooses "<action>" from the media's menu
    Then <outcome>

    Examples:
      | action     | outcome                         |
      | Copy image | the clipboard holds the picture |
      | Save image | the picture is saved            |

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

  @desktop @backlog @priority-low
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

  # Upstream #30606: a path the agent named before creating it stayed "missing" for the thread, so
  # the folder it then made kept a file's icon.
  @backlog @shared @priority-low
  Scenario: A path named before it existed shows what it became within a minute
    Given the agent's reply links to "src/widgets" before that folder exists
    When the agent creates "src/widgets" as a folder
    Then within 60 seconds the link shows a folder's icon, without the user reloading

  @backlog @mobile
  Scenario: A path in code formatting is a file link and the same path in prose is not
    When the agent's reply reads "/tmp/frame.png" in plain text and again in code formatting
    Then only the path in code formatting is a link to the file

  @backlog @mobile @priority-low
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

  # Upstream #13795: bare addresses with a port or a one-word host were not links.
  @backlog @shared @priority-low
  Scenario Outline: A bare address with a port or a one-word host in a reply is one link
    When the agent's reply contains "<address>"
    Then "<address>" is shown as one link

    Examples:
      | address               |
      | http://localhost:5173 |
      | http://devbox:3000/api |

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

  @backlog @mobile @priority-low
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

  # Upstream #25432: a skill in a sent message opens the same details as the composer's chip.
  @backlog @desktop
  Scenario: A skill chip in a message shows the same details as in the composer
    Given the provider offers the skill "ui" described as "Build UI" with its instructions in "SKILL.md"
    And a sent message or a reply shows the skill chip "$ui"
    When the user rests on the chip
    Then "Build UI" and "View instructions" are shown, as for the chip in the composer
    When the user chooses "View instructions"
    Then "SKILL.md" opens in the thread's files

  # Upstream #22120: tapping a skill chip in a message opens its instructions.
  @backlog @mobile
  Scenario: Tapping a skill chip in a reply opens the skill's instructions
    Given the provider offers the skill "ui" with its instructions in "SKILL.md"
    And the agent's reply shows the skill chip "$ui"
    When the user taps the chip
    Then the skill's "SKILL.md" opens in the thread's files

  # Upstream #22120: a skill chip's long-press menu is the skill's, not a web link's.
  @backlog @mobile
  Scenario: Long pressing a skill chip offers its instructions and copying the skill
    Given the agent's reply shows the skill chip "$ui" for the skill named "UI"
    When the user long presses the chip
    Then a menu titled "UI" offers "View instructions" and "Copy skill"
    And it does not offer to share a link
    When the user chooses "Copy skill"
    Then the clipboard holds "$ui"

  # Upstream #22120: View instructions cannot be chosen for a skill with no file.
  @backlog @mobile @priority-low
  Scenario: A skill without an instructions file cannot show its instructions
    Given the agent's reply shows the skill chip "$ui" for a skill with no instructions file
    When the user long presses the chip
    Then "View instructions" cannot be chosen

  # Upstream #22621: a thread link in a message is shown as the same chip as an attached
  # thread, with its project's icon and the thread's current title.
  @backlog @shared
  Scenario: A link to a thread in a reply is shown as a thread chip
    Given the thread "Fix checkout" is in the project "shop"
    When the agent's reply links to "Fix checkout" with the text "that thread"
    Then the link is shown as a chip titled "Fix checkout" with the icon of "shop"
    And following it opens "Fix checkout"

  # Upstream #22621: a link to a thread that is gone says so.
  @backlog @shared @priority-low
  Scenario: A link to a thread that no longer exists says so
    Given the agent's reply links to a thread that has been deleted
    When the user points at the link
    Then it says "Thread no longer available"

  # Upstream #22153: a thread link's long-press menu names the thread and offers opening it
  # and copying the link, never sharing an app-internal address.
  @backlog @mobile
  Scenario: Long pressing a thread link offers to open the thread or copy the link
    Given the agent's reply links to the thread "Fix checkout" on another environment
    When the user long presses the link
    Then a menu titled "Fix checkout" offers "Open thread" and "Copy link"
    And it does not offer to share the link
    When the user chooses "Open thread"
    Then "Fix checkout" opens

  # Upstream #22153: a copied thread link is understood when pasted back into a message.
  @backlog @mobile @priority-low
  Scenario: A copied thread link is still a link to that thread
    Given the user copied the link to "Fix checkout" from a reply's menu
    When the user pastes it into a message and sends it
    Then the sent message links to "Fix checkout"

  # Upstream #25802: the phone read the backslashes of a Windows image path as escapes.
  @backlog @shared
  Scenario: Windows paths stay intact in links and images
    Given a message with an image destination like C:\Users\me\shot.png
    When it is shown
    Then the path is used as written, not read as escapes

  # Upstream #21069: a backslash inside a drive path is kept even before punctuation; escapes
  # outside paths still work, and collapsed thinking previews follow the same rule.
  # Upstream #21454: the phone's own renderer lost them as well.
  @backlog @shared
  Scenario Outline: Windows paths in a message's text keep their backslashes
    When the agent's reply reads "<text>"
    Then the reply shows "<shown>"

    Examples:
      | text                         | shown                        |
      | Look in C:\Users\me\.t3\data | Look in C:\Users\me\.t3\data |
      | Open C:\a\_b                 | Open C:\a\_b                 |
      | A \*literal\* star           | A *literal* star             |

  @backlog @shared @priority-low
  Scenario: A descriptive file link keeps its words
    Given a reply says "This function [validates the input](/repo/src/example.ts:12)."
    When the reply is shown
    Then the prose stays, beside the usual file chip
    And a link labelled with a file name or path keeps the compact chip

  # Dropped: upstream added this repair (#15520) and reverted it in #15824; malformed
  # links render as the agent wrote them.
  @dropped @shared
  Scenario: A local file link missing its closing bracket is repaired for display
    Given a reply contains "[file](<local/path/file.md)"
    When the reply is shown
    Then the link opens the file as a normal file link
    And the stored message and its copied text stay as the agent wrote them

  @backlog @mc
  Scenario: A media link under the home directory resolves
    Given a reply links media as "~/Downloads/repro.mp4"
    When the media is requested
    Then the path expands to the environment's home before project-relative resolution

  # Upstream #19677: missing media names the remote host and the absolute path that was checked.
  @backlog @shared
  Scenario: A media link that is not found says where it was looked for
    Given a reply links "shots/after.png" on the environment "server"
    And the file is not there
    Then the media says it was not found on "server" at its full path
