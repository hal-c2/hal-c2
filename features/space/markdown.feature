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
#   https://spec.commonmark.org/0.31.2/#list-items (list items, their content column, lazy lines)
#   https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts
#   ~/dev/pos-ecs again for lists, quotes and rules (1772 distinct .md files outside hidden directories:
#     5388 lists, 77 of them kept raw; 24752 items, 1315 nested; 920 quotes, 23 of them alerts, 85 kept by
#     their `> ` blank lines or two-space line breaks, and 4 kept raw; 598 rules, 152 of them not `---`)
#   apps/server-ex/lib/hal_c2/space/markdown.ex, apps/server-ex/lib/hal_c2/space/blocks.ex,
#     apps/server-ex/lib/hal_c2/space/table.ex
#   packages/contracts/src/space.ts (SpaceBlock, SpaceWritableBlockKind, SpaceTable, SpaceTableEdit,
#     SpaceCalloutAlert)
#   apps/desktop-qt/qml/HalC2/Bricks/SpaceBlock.qml (a page's diagram on the desktop)
#   apps/mobile-qt/qml/HalC2/Mobile/SpaceBlockRow.qml (a page's diagram on the phone)

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

        <p align="center">Tag</p>
        """
      When the user changes the raw block of "Plan" to:
        """
        <p align="center">Tag and ship</p>
        """
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        <p align="center">Tag and ship</p>
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

    # https://github.com/hal-c2/hal-c2/issues/854
    @shared
    Scenario: A table and code are shown as their source until they are drawn as such
      Given the page "Plan" holds a table and a code block
      When the user opens "Plan"
      Then the table and the code are each shown line for line in a fixed-width face

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
    @shared
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
  @mc @shared @backlog-mc @backlog-tui
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

  # Each list item is a block: a bullet, a numbered item or a checklist item, nested under
  # the items above it by its depth. A numbered item counts on from the one before it at
  # its depth; one that begins a list may start at another number. An item keeps the
  # marker (`*`, `+`, `)`) and the indent it was written with, and its text runs on in
  # lines indented under it. A list its own form would not write back exactly (a lazy
  # line, numbers that skip, an item back under a parent's text) is kept as written.
  Rule: Lists

    @mc
    Scenario: Each list item is a block of its kind and depth
      Given the page "Plan" imported from:
        """
        # Plan

        - Release
          1. Tag
          2. Ship
             - [x] Notes
        - Announce
        """
      Then the list items of "Plan" are:
        | kind      | depth | text     |
        | bullet    | 0     | Release  |
        | numbered  | 1     | Tag      |
        | numbered  | 1     | Ship     |
        | checklist | 2     | Notes    |
        | bullet    | 0     | Announce |
      When the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        - Release
          1. Tag
          2. Ship
             - [x] Notes
        - Announce
        """

    @mc
    Scenario Outline: A list keeps how it was written
      When the user imports the Markdown "# Plan\n\n<written>" into "Research"
      Then the blocks of "Plan" are of the kinds "<kinds>"
      When the user exports the imported page as Markdown
      Then the exported Markdown is "# Plan\n\n<written>\n"

      Examples:
        | written                                 | kinds                      |
        | * Tag\n* Ship                           | bullet, bullet             |
        | + Tag\n+ Ship                           | bullet, bullet             |
        | 3) Tag\n4) Ship                         | numbered, numbered         |
        | 1. Tag\n\n2. Ship                       | numbered, numbered         |
        | - Tag\n    - Ship                       | bullet, bullet             |
        | - Tag\n  the release tag\n- Ship        | bullet, bullet             |
        | - Tag:\n  ```sh\n  git tag\n  ```\n- Ship | bullet, bullet             |
        | - Tag\n---\n- Ship                      | bullet, divider, bullet    |
        | - Tag\nthe release tag                  | raw                        |
        | 1. Tag\n3. Ship                         | raw                        |
        | - Tag\n  - Ship\n  the release tag      | raw                        |
        | * [ ] Tag                               | raw                        |

    @mc
    Scenario: A numbered list counts on from where it starts
      Given the page "Plan" imported from:
        """
        # Plan

        3. Tag
        4. Ship
        """
      When the user adds the numbered item "Announce" after "Ship"
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        3. Tag
        4. Ship
        5. Announce
        """
      When the user starts the list at "Tag" from 1
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        1. Tag
        2. Ship
        3. Announce
        """

    @mc
    Scenario: The user indents and outdents a list item
      Given the page "Plan" imported from:
        """
        # Plan

        - Release
            - Tag
        - Ship
        """
      When the user nests "Ship" 1 deep
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        - Release
            - Tag
          - Ship
        """
      When the user nests "Tag" 0 deep
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        - Release
        - Tag
          - Ship
        """

    @mc
    Scenario: A task nested in a list keeps its tick
      Given the page "Plan" imported from:
        """
        # Plan

        - Release
          - [ ] Tag
          - [x] Ship
        """
      When the user ticks "Tag"
      And the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        - Release
          - [x] Tag
          - [x] Ship
        """

    @mc
    Scenario: Only a list item has a depth
      Given the page "Plan" imported from:
        """
        # Plan

        Ship it
        """
      When the user nests "Ship it" 1 deep
      Then the user is told "Only a list item has a depth."

    # https://github.com/hal-c2/hal-c2/issues/869
    @shared @backlog
    Scenario: A list is shown with its markers and nesting
      Given the page "Plan" with a bulleted list holding a numbered list
      When the user opens "Plan"
      Then each item is shown with its bullet or its number, indented under its parent

    # https://github.com/hal-c2/hal-c2/issues/869
    @shared @backlog
    Scenario: The user adds, indents and outdents a list item in a page
      Given the page "Plan" with a bulleted list
      When the user adds an item, indents it, then outdents it
      Then the item is shown at the depth it ended at

  # A quote is a callout. One that starts `[!NOTE]` (or TIP, IMPORTANT, WARNING, CAUTION)
  # is GitHub's alert of that kind, a callout with its `alert`.
  Rule: Quotes and alerts

    @mc
    Scenario: A quote is a callout
      Given the page "Plan" imported from:
        """
        # Plan

        > Tag first.
        >
        > Then ship.
        """
      Then "Plan" has a callout holding:
        """
        Tag first.

        Then ship.
        """
      When the user exports "Plan" as Markdown
      Then the Markdown is:
        """
        # Plan

        > Tag first.
        >
        > Then ship.
        """

    # Some editors write a quote's blank line as `> ` and keep two spaces for a line break.
    @mc
    Scenario: A quote keeps its blank lines and line breaks as written
      When the user imports the Markdown "# Plan\n\n> Tag first,  \n> then wait.\n> \n> Then ship." into "Research"
      Then the blocks of "Plan" are of the kinds "callout"
      When the user exports the imported page as Markdown
      Then the exported Markdown is "# Plan\n\n> Tag first,  \n> then wait.\n> \n> Then ship.\n"

    @mc
    Scenario Outline: A GitHub alert is a callout of its kind
      When the user imports the Markdown "# Plan\n\n> [!<written>]\n> Tag first." into "Research"
      Then "Plan" has a "<alert>" callout "Tag first."
      When the user exports the imported page as Markdown
      Then the exported Markdown is "# Plan\n\n> [!<written>]\n> Tag first.\n"

      Examples:
        | written   | alert     |
        | NOTE      | note      |
        | TIP       | tip       |
        | IMPORTANT | important |
        | WARNING   | warning   |
        | CAUTION   | caution   |

    @mc
    Scenario: The user changes a callout's alert
      Given the page "Plan" imported from:
        """
        # Plan

        > [!NOTE]
        > Tag first.
        """
      When the user makes "Tag first." a "warning" alert
      And the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n> [!WARNING]\n> Tag first.\n"
      When the user makes "Tag first." a plain quote
      And the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\n> Tag first.\n"

    @mc
    Scenario: Only a callout has an alert
      Given the page "Plan" imported from:
        """
        # Plan

        Ship it
        """
      When the user makes "Ship it" a "note" alert
      Then the user is told "Only a callout has an alert."

    # https://github.com/hal-c2/hal-c2/issues/869
    @shared @backlog
    Scenario: An alert is shown as its kind
      Given the page "Plan" with a "warning" callout
      When the user opens "Plan"
      Then the callout is shown as a warning
      And the user can make it another kind of alert, or a plain quote

  # A horizontal rule is a divider, and one written other than `---` keeps how it was
  # written. A rule set in by spaces, or with spaces after it, stays raw.
  Rule: Horizontal rules

    @mc
    Scenario: A horizontal rule is a divider
      Given the page "Plan" imported from:
        """
        # Plan

        Tag

        ---

        Ship
        """
      Then the blocks of "Plan" are of the kinds "paragraph, divider, paragraph"
      When the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\nTag\n\n---\n\nShip\n"

    @mc
    Scenario Outline: A divider keeps how its rule was written
      When the user imports the Markdown "# Plan\n\nTag\n\n<written>\n\nShip" into "Research"
      Then the blocks of "Plan" are of the kinds "paragraph, divider, paragraph"
      When the user exports the imported page as Markdown
      Then the exported Markdown is "# Plan\n\nTag\n\n<written>\n\nShip\n"

      Examples:
        | written    |
        | ***        |
        | ___        |
        | - - -      |
        | ---------- |

    @mc
    Scenario: A rule set in by spaces is kept as written
      Given the page "Plan" imported from:
        """
        # Plan

        Tag

           ***

        Ship
        """
      Then the blocks of "Plan" are of the kinds "paragraph, raw, paragraph"
      When the user exports "Plan" as Markdown
      Then the exported Markdown is "# Plan\n\nTag\n\n   ***\n\nShip\n"

    # https://github.com/hal-c2/hal-c2/issues/869
    @shared @backlog
    Scenario: A divider is shown as a line
      Given the page "Plan" with a divider between two paragraphs
      When the user opens "Plan"
      Then a line is shown between them

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
