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
#   apps/server-ex/lib/hal_c2/space/markdown.ex, apps/server-ex/lib/hal_c2/space/blocks.ex,
#     apps/server-ex/lib/hal_c2/space/table.ex
#   packages/contracts/src/space.ts (SpaceBlock, SpaceWritableBlockKind, SpaceTable, SpaceTableEdit)

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

        <div align="center">
          <b>Ada</b>
        </div>

        Ship it
        """
      Then the blocks of "Plan" are of the kinds "raw, paragraph"
      And the raw block of "Plan" holds:
        """
        <div align="center">
          <b>Ada</b>
        </div>
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
    @shared @backlog-desktop
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

    @mc
    Scenario: The user changes a heading's level
      Given the page "Plan" imported from:
        """
        # Plan

        ## Steps
        """
      When the user makes "Steps" a level 3 heading
      Then "Plan" has a heading "Steps" of level 3
      When the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n### Steps\n"

    @mc
    Scenario: Only a heading has a level
      Given the page "Plan" imported from:
        """
        # Plan

        Ship it
        """
      When the user makes "Ship it" a level 3 heading
      Then the user is told "Only a heading has a level."
      And the blocks of "Plan" are of the kinds "paragraph"

    # https://github.com/hal-c2/hal-c2/issues/854
    @shared @backlog
    Scenario: The user picks a heading's level
      Given the page "Plan" with a heading "Steps"
      When the user makes "Steps" a level 3 heading from the block's menu
      Then "Steps" is shown as a level 3 heading

    # https://github.com/hal-c2/hal-c2/issues/847
    @shared @backlog-desktop
    Scenario: Each heading level is shown in its own size
      Given the page "Plan" with headings of every level from 1 to 6
      When the user opens "Plan"
      Then each heading is smaller than the one of the level above it

  # A table is its cells and how its columns align. Its Markdown keeps the widths it was
  # written with, the cells' and the rule row's apart: a padded table comes back padded,
  # one with unpadded cells unpadded, and editing a cell writes only that cell's row
  # again. A table made in a page is padded to its widest cell. A table its own form would
  # not write back exactly (rows of other lengths, no pipes at the ends, cells padded on
  # the left) is kept as written.
  Rule: Tables

    @mc
    Scenario: A table is a block of rows and columns
      Given the page "Plan" imported from:
        """
        # Plan

        | Step | Owner | Done |
        | ---- | ----- | ---- |
        | MC   | Ada   | yes  |
        """
      Then the blocks of "Plan" are of the kinds "table"
      And the table of "Plan" has the rows:
        | Step | Owner | Done |
        | MC   | Ada   | yes  |

    @mc
    Scenario: A table keeps the spacing it was written with
      Given the page "Plan" imported from:
        """
        # Plan

        | Step | Owner |
        | --- | --- |
        | MC | Ada |

        | Step     | Owner |
        |---|---|
        | MC       | Ada   |
        | Lovelace | Grace |
        """
      Then the blocks of "Plan" are of the kinds "table, table"
      When the user changes the "Owner" of "MC" in the table of "Plan" to "Barbara"
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner |
        | --- | --- |
        | MC | Barbara |

        | Step     | Owner |
        |---|---|
        | MC       | Ada   |
        | Lovelace | Grace |
        """

    @mc
    Scenario: A column keeps its alignment
      Given the page "Plan" imported from:
        """
        # Plan

        | Step | Owner | Done |
        |:-----|:-----:|-----:|
        | MC   | Ada   | yes  |
        """
      Then the columns of the table of "Plan" are aligned "left, center, right"
      When the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner | Done |
        |:-----|:-----:|-----:|
        | MC   | Ada   | yes  |
        """

    @mc
    Scenario: The user edits a cell
      Given the page "Plan" imported from:
        """
        # Plan

        | Step | Owner |
        | ---- | ----- |
        | MC   | Ada   |
        | QML  | Grace |
        """
      When the user changes the "Owner" of "MC" in the table of "Plan" to "Barbara"
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner |
        | ---- | ----- |
        | MC   | Barbara |
        | QML  | Grace |
        """

    @mc
    Scenario: The user adds and removes a row and a column
      Given the page "Plan" imported from:
        """
        # Plan

        | Step | Owner |
        |------|------:|
        | MC   | Ada   |
        """
      When the user adds a row to the end of the table of "Plan"
      And the user adds a column to the end of the table of "Plan"
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner |     |
        |------|------:|-----|
        | MC   | Ada   |     |
        |      |       |     |
        """
      When the user removes the last row of the table of "Plan"
      And the user removes the last column of the table of "Plan"
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner |
        |------|------:|
        | MC   | Ada   |
        """

    @mc
    Scenario: A cell can hold formatting and an escaped pipe
      Given the page "Plan" imported from:
        """
        # Plan

        | Code     | Note     |
        | -------- | -------- |
        | `a \| b` | **bold** |
        """
      Then the first row's "Code" in the table of "Plan" reads "`a | b`"
      When the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Code     | Note     |
        | -------- | -------- |
        | `a \| b` | **bold** |
        """

    @mc
    Scenario: A table made in a page is padded to its widest cell
      Given the page "Plan" imported from:
        """
        # Plan
        """
      When the user adds a table to "Plan" of the rows:
        | Step | Owner   |
        | MC   | Barbara |
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner   |
        | ---- | ------- |
        | MC   | Barbara |
        """

    @mc
    Scenario: A table's text rewritten in its own form keeps its spacing
      Given the page "Plan" imported from:
        """
        # Plan

        | Step | Owner |
        | --- | --- |
        | MC | Ada |
        """
      When the user changes the text of the table of "Plan" to:
        """
        | Step | Owner |
        | --- | --- |
        | MC | Barbara |
        """
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner |
        | --- | --- |
        | MC | Barbara |
        """

    @mc
    Scenario: A table's text rewritten another way is padded to its cells
      Given the page "Plan" imported from:
        """
        # Plan

        | Step | Owner |
        | ---- | ----- |
        | MC   | Ada   |
        """
      When the user changes the text of the table of "Plan" to:
        """
        Step | Owner
        --- | ---:
        MC | Barbara
        """
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | Step | Owner   |
        | ---- | ------: |
        | MC   | Barbara |
        """

    @mc
    Scenario: A table's text must be a table
      Given the page "Plan" imported from:
        """
        # Plan

        | Step |
        | ---- |
        | MC   |
        """
      When the user changes the text of the table of "Plan" to:
        """
        | Step |
        | ---- |
        | MC   |

        Notes for later
        """
      Then the user is told "A table's text is a table"
      And the table of "Plan" has the rows:
        | Step |
        | MC   |

    @mc
    Scenario: A table written another way is kept as written
      Given the page "Plan" imported from:
        """
        # Plan

        | a | b |
        |---|---|
        | 1 |

        a | b
        --- | ---
        1 | 2

        | Total |
        | ----: |
        |    12 |
        """
      Then the blocks of "Plan" are of the kinds "raw, raw, raw"
      When the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        | a | b |
        |---|---|
        | 1 |

        a | b
        --- | ---
        1 | 2

        | Total |
        | ----: |
        |    12 |
        """

    # https://github.com/hal-c2/hal-c2/issues/854
    @shared @backlog
    Scenario: A table is shown as a table
      Given the page "Plan" with a table whose columns are aligned left, centre and right
      When the user opens "Plan"
      Then the table is shown as a grid of its cells, its header row apart
      And each column is aligned as it was written
      And a cell's formatting is shown, a "\|" as a pipe

    # https://github.com/hal-c2/hal-c2/issues/854
    @shared @backlog
    Scenario: The user edits a table where it stands
      Given the page "Plan" with a table
      When the user changes a cell, adds a row and a column, then removes them
      Then the page shows the table with only the changed cell

  # A code block's text is the code, its language the first word after the fence. The
  # fence (backticks or tildes, and how many) and the rest of its line come back as they
  # were written. A fence that is indented, or has a space before its language, is kept as
  # written. A diagram's fence is a code block too, in "mermaid" (see Mermaid diagrams).
  Rule: Code

    @mc
    Scenario: A fenced code block keeps its language and its text
      Given the page "Plan" imported from:
        """
        # Plan

        ```ts
        const a = 1

        // two
        ```
        """
      Then "Plan" has a code block in "ts" holding:
        """
        const a = 1

        // two
        """
      When the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n```ts\nconst a = 1\n\n// two\n```\n"

    @mc
    Scenario: The user edits code and its language
      Given the page "Plan" imported from:
        """
        # Plan

        ```sh
        echo hi
        ```
        """
      When the user makes the code block of "Plan" "bash" code holding:
        """
        echo hello
        """
      And the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n```bash\necho hello\n```\n"

    @mc
    Scenario: Code holding a fence is written inside a longer one
      Given the page "Plan" imported from:
        """
        # Plan

        ```md
        x
        ```
        """
      When the user makes the code block of "Plan" "md" code holding:
        """
        ```ts
        x
        ```
        """
      And the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n````md\n```ts\nx\n```\n````\n"

    @mc
    Scenario Outline: Code keeps the fence it was written with
      When the user imports the Markdown "# Plan\n\n<written>" into "Research"
      Then the blocks of "Plan" are of the kinds "<kinds>"
      When the user exports the imported page as Markdown
      Then the exported Markdown is "# Plan\n\n<written>\n"

      Examples:
        | written                          | kinds |
        | ~~~~js\nx\n~~~~                   | code  |
        | ```js {.numbered}\nx\n```         | code  |
        | ````md\n```ts\nx\n```\n````       | code  |
        | ```\nno language\n```             | code  |
        |   ```ts\n  x\n  ```               | raw   |
        | ``` ts\nx\n```                    | raw   |

    # https://github.com/hal-c2/hal-c2/issues/854
    @shared @backlog
    Scenario: A code block is shown as code
      Given the page "Plan" with a "ts" code block
      When the user opens "Plan"
      Then its text is shown in a fixed-width face, coloured for that language where the surface can
      And its language is named on it

    # https://github.com/hal-c2/hal-c2/issues/854
    @shared @backlog
    Scenario: The user copies a code block
      Given the page "Plan" with a code block
      When the user copies the code block
      Then the clipboard holds its text without the fence

    # https://github.com/hal-c2/hal-c2/issues/854
    @shared @backlog
    Scenario: The user edits code and its language in a page
      Given the page "Plan" with a "sh" code block
      When the user changes its text and makes it "bash"
      Then the page shows the new text, named "bash"

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
