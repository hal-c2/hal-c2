# Sources:
#   https://github.github.com/gfm/ (GitHub Flavored Markdown: tables, task lists, strikethrough, autolinks)
#   https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax
#     (headings, quotes, code, links, images, lists, footnotes, alerts, hidden content)
#   https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting
#     (tables, collapsed sections, code blocks, diagrams, mathematical expressions)
#   https://mermaid.js.org/intro/syntax-reference.html (flowchart, sequenceDiagram, stateDiagram-v2, gantt, block-beta)
#   ~/dev/pos-ecs, the maintainer's reference corpus (114 .md files: tables in 60, fenced code with a
#     language in 62, Mermaid in 27, front matter in 19, strikethrough in 3, <details>, task lists and
#     images in 1 each). It is private: the tests carry synthetic files of the same shapes, and run
#     against the corpus itself only where it is checked out.
#   apps/server-ex/lib/hal_c2/space/markdown.ex, apps/server-ex/lib/hal_c2/space/blocks.ex
#   packages/contracts/src/space.ts (SpaceBlock, SpaceWritableBlockKind)

Feature: GitHub Markdown in a page
  A page reads and writes GitHub Markdown. Whatever a page models (headings, paragraphs,
  checklists, callouts, tables, code, diagrams and the rest) is a block of its own kind
  that can be edited where it stands. Whatever a page does not model yet is kept as a
  block of Markdown source, shown as written, so nothing in a file is ever lost: a page
  imported from Markdown exports as the very same file.

  Two things are made uniform, and only these: line ends are written as LF, and the file
  ends with exactly one newline.

  Background:
    Given a connected environment
    And the Space "Research"

  Rule: Nothing is lost

    @mc
    Scenario Outline: Markdown imports and exports as the very same file
      When the user imports the Markdown file "<file>" into "Research"
      And the user exports the imported page as Markdown
      Then the Markdown is the file "<file>" exactly

      Examples:
        | file                 | what it holds                                                     |
        | architecture.md      | tables, fenced code, Mermaid flowcharts and sequence diagrams     |
        | runbook.md           | ordered and nested lists, a quote, code inside list items         |
        | release-checklist.md | a task list, strikethrough, a collapsed section and an image      |
        | spacing.md           | two blank lines between sections, a heading with text right under |

    @mc
    Scenario: What a page does not model is kept as its Markdown
      When the user imports this Markdown into "Research":
        """
        # Plan

        | Step | Owner |
        | ---- | ----- |
        | MC   | Ada   |

        Ship it
        """
      Then the blocks of "Plan" are of the kinds "raw, paragraph"
      And the raw block of "Plan" holds:
        """
        | Step | Owner |
        | ---- | ----- |
        | MC   | Ada   |
        """

    @mc
    Scenario: The user edits Markdown the page keeps as written
      Given the page "Plan" imported from:
        """
        # Plan

        1. Tag
        2. Ship
        """
      When the user changes the raw block of "Plan" to:
        """
        1. Tag
        2. Build
        3. Ship
        """
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        1. Tag
        2. Build
        3. Ship
        """

    @mc
    Scenario: The blank lines between blocks come back as they were
      Given the page "Plan" imported from:
        """
        # Plan
        Right under the title


        Two blank lines above
        """
      When the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan
        Right under the title


        Two blank lines above
        """

    @mc
    Scenario: A block the user moves gets the usual blank line
      Given the page "Plan" imported from:
        """
        # Plan

        First


        Second
        """
      When the user moves the block "Second" before "First"
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        Second

        First
        """

    @mc
    Scenario Outline: Only line ends and the last newline are made uniform
      When the user imports the Markdown "<written>" into "Research"
      And the user exports the imported page as Markdown
      Then the exported Markdown is "# Plan\n\nShip\n"

      Examples:
        | written                  |
        | # Plan\r\n\r\nShip\r\n |
        | # Plan\n\nShip           |
        | # Plan\n\nShip\n\n\n     |

    @mc
    Scenario: A file with no title on top gains one as a page
      When the user imports this Markdown into "Research" as "Agent role":
        """
        ---
        name: reviewer
        ---

        Reads diffs.
        """
      And the user exports "Agent role" as Markdown
      Then the Markdown is:
        """
        # Agent role

        ---
        name: reviewer
        ---

        Reads diffs.
        """

    # https://github.com/hal-c2/hal-c2/issues/847
    @shared
    Scenario: Markdown a page keeps as written is shown as its source
      Given the page "Plan" holds a table the page does not model yet
      When the user opens "Plan"
      Then the table is shown as its Markdown, exactly as written, in a fixed-width face
      And the user can edit it as text

  Rule: Headings

    @mc
    Scenario Outline: A heading keeps its level
      Given the page "Plan" imported from:
        """
        # Plan

        <marks> Steps
        """
      Then "Plan" has a heading "Steps" of level <level>
      When the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n<marks> Steps\n"

      Examples:
        | marks  | level |
        | #      | 1     |
        | ##     | 2     |
        | ###    | 3     |
        | ####   | 4     |
        | #####  | 5     |
        | ###### | 6     |

    @mc
    Scenario: A heading written with closing marks is kept as written
      Given the page "Plan" imported from:
        """
        # Plan

        ## Steps ##
        """
      Then the blocks of "Plan" are of the kinds "raw"

    @mc
    Scenario: A heading made in a page is a second-level heading
      Given the page "Plan" with the blocks:
        | kind    | text  |
        | heading | Steps |
      When the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n## Steps\n"

    # https://github.com/hal-c2/hal-c2/issues/846
    @mc @backlog
    Scenario: The user changes a heading's level
      Given the page "Plan" imported from:
        """
        # Plan

        ## Steps
        """
      When the user makes "Steps" a level 3 heading
      Then "Plan" has a heading "Steps" of level 3

    # https://github.com/hal-c2/hal-c2/issues/847
    @shared
    Scenario: Each heading level is shown in its own size
      Given the page "Plan" with headings of every level from 1 to 6
      When the user opens "Plan"
      Then each heading is smaller than the one of the level above it

  # https://github.com/hal-c2/hal-c2/issues/842
  @backlog @mc @shared
  Rule: Tables

    Scenario: A table is a block of rows and columns
      When the user imports a page holding a table with the columns "Step", "Owner" and "Done"
      Then the page has a table block of 3 columns and its rows
      And it is shown as a table

    Scenario: A column keeps its alignment
      When the user imports a table whose columns are aligned left, centre and right
      Then the columns are shown aligned that way
      And the export writes the same alignment row

    Scenario: The user edits a cell
      Given a page with a table
      When the user changes a cell's text
      Then the table's Markdown has the new text in that cell, the other rows as they were

    Scenario: The user adds and removes a row and a column
      Given a page with a table
      When the user adds a row, then a column, then removes them again
      Then the table's Markdown is what it was before

    Scenario: A cell can hold formatting and an escaped pipe
      When the user imports a table whose cell holds "`a \| b`" and bold text
      Then the cell shows the code and the bold text
      And the export writes the cell as it was

  # https://github.com/hal-c2/hal-c2/issues/842
  @backlog @mc @shared
  Rule: Code

    Scenario: A fenced code block keeps its language and its text
      When the user imports a page holding a "ts" code block
      Then the page has a code block in "ts"
      And it is shown in a fixed-width face, coloured for that language where the surface can
      And the export writes the same fence, language and text

    Scenario: The user copies a code block
      Given a page with a code block
      When the user copies the code block
      Then the clipboard holds its text without the fence

    Scenario: The user edits code and its language
      Given a page with a "sh" code block
      When the user changes its text and makes it "bash"
      Then the export writes the new fence and text

    Scenario: Code written with tildes or a longer fence keeps its fence
      When the user imports code fenced with "~~~~"
      Then the export writes it fenced with "~~~~"

  # https://github.com/hal-c2/hal-c2/issues/843
  @backlog @mc @shared
  Rule: Mermaid diagrams

    # The diagram is drawn by the one Mermaid renderer the pages, the chat and the file
    # viewer share. The terminal shows the diagram's source, named as a diagram.
    Scenario Outline: A Mermaid diagram is drawn
      When the user imports a page holding a "<type>" Mermaid diagram
      Then the page has a diagram block of the type "<type>"
      And on the desktop and the phone the diagram is drawn
      And in the terminal the diagram's source is shown, named as a "<type>" diagram

      Examples:
        | type            |
        | flowchart       |
        | graph           |
        | sequenceDiagram |
        | stateDiagram-v2 |
        | gantt           |

    Scenario: A diagram type the renderer cannot draw shows its source and says why
      When the user imports a page holding a "block-beta" Mermaid diagram
      Then the diagram's source is shown
      And the user is told "block-beta" diagrams cannot be drawn yet

    Scenario: A diagram with a mistake shows its source and the mistake
      When the user imports a page holding a flowchart with an unclosed bracket
      Then the diagram's source is shown
      And the user is told where the mistake is
      And nothing claims the diagram is still being drawn

    Scenario: The user edits a diagram's source
      Given a page with a flowchart
      When the user adds a node to its source
      Then the diagram is drawn again with the new node
      And the export writes the new source

    Scenario: A diagram is drawn once, not over and over
      Given a page with a flowchart
      When the user scrolls the page past it and back
      Then the diagram is not drawn again

  # https://github.com/hal-c2/hal-c2/issues/844
  @backlog @mc @shared
  Rule: Lists

    Scenario Outline: A list keeps its kind, its numbers and its nesting
      When the user imports a page holding <list>
      Then the page has a list block shown as <list>
      And the export writes it as it was

      Examples:
        | list                                      |
        | a bulleted list                           |
        | an ordered list starting at 3             |
        | a bulleted list with an ordered list in it |
        | a list whose items hold code              |
        | a list with blank lines between its items |

    Scenario: The user adds, indents and outdents a list item
      Given a page with a bulleted list
      When the user adds an item, indents it, then outdents it
      Then the list's Markdown has the item at the level it ended at

    Scenario: A task list in a list keeps its ticks
      When the user imports a list whose nested items are tasks, some ticked
      Then ticking a nested task changes only that task's mark in the export

  # https://github.com/hal-c2/hal-c2/issues/844
  @backlog @mc @shared
  Rule: Quotes and alerts

    Scenario: A quote is a callout
      When the user imports a page holding a quote of two paragraphs
      Then the page has a callout of those two paragraphs
      And the export writes the quote as it was

    Scenario Outline: A GitHub alert is a callout of its kind
      When the user imports a page holding the alert "> [!<kind>]"
      Then the page has a callout of the kind "<kind>", shown as one
      And the export writes "> [!<kind>]" again

      Examples:
        | kind      |
        | NOTE      |
        | TIP       |
        | IMPORTANT |
        | WARNING   |
        | CAUTION   |

    Scenario: The user changes a callout's kind
      Given a page with a "NOTE" callout
      When the user makes it a "WARNING"
      Then the export writes "> [!WARNING]"

  # https://github.com/hal-c2/hal-c2/issues/844
  @backlog @mc @shared
  Rule: Horizontal rules

    Scenario: A horizontal rule is a divider
      When the user imports a page holding "---" between two paragraphs
      Then the page has a divider between them
      And the export writes "---" again

  # https://github.com/hal-c2/hal-c2/issues/845
  @backlog @mc @shared
  Rule: Inline formatting

    Scenario Outline: Text keeps its inline formatting
      When the user imports a paragraph holding <formatting>
      Then the paragraph is shown with <formatting>
      And the export writes it as it was

      Examples:
        | formatting                                |
        | bold and italic text                      |
        | struck-through text                       |
        | inline code                               |
        | a link with a title                       |
        | an autolinked address and a bare www link |

    Scenario: A link in a page never loads anything by itself
      When the user imports a paragraph linking to a web address
      Then nothing is fetched until the user opens the link

  # https://github.com/hal-c2/hal-c2/issues/845
  @backlog @mc @shared
  Rule: Footnotes

    Scenario: A footnote reference and its note go together
      When the user imports a paragraph with the reference "[^1]" and the note "[^1]: Source"
      Then the reference is shown as a link to the note
      And the export writes both as they were

  # https://github.com/hal-c2/hal-c2/issues/845
  @backlog @mc @shared
  Rule: Math

    Scenario Outline: Math is shown as math
      When the user imports a page holding <math>
      Then it is shown typeset where the surface can, else as its source
      And the export writes it as it was

      Examples:
        | math                    |
        | inline "$x^2$"          |
        | a "$$" block            |
        | a "math" fenced block   |

  # https://github.com/hal-c2/hal-c2/issues/845
  @backlog @mc @shared
  Rule: Collapsed sections

    Scenario: A collapsed section opens and closes
      When the user imports a page holding a "<details>" section titled "Logs"
      Then the page shows "Logs" closed
      When the user opens "Logs"
      Then its contents are shown
      When the user closes "Logs"
      Then its contents are hidden again

    Scenario: The section's contents are blocks of their own
      Given a page with a collapsed section holding a table
      When the user edits the table
      Then the export writes the section with the new table inside

  # https://github.com/hal-c2/hal-c2/issues/845
  @backlog @mc @shared
  Rule: Images

    Scenario: An image from the web is shown only when the user asks
      When the user imports a page holding an image from a web address
      Then its description and address are shown in its place
      And nothing is fetched until the user asks to see it

    Scenario: An image beside the file is shown from the project
      Given a page that is a project file holding an image beside it
      When the user opens the page
      Then the image is shown from the project's files
