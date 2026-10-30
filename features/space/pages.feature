# Sources:
#   https://chatgpt.com/features/space/ (Spaces: shared pages people and agents write together)
#   spaces-feature-bdd-tests branch, features/space/space-navigation-and-organization.feature
#     (the prototype: nested pages, trash, comments, a page made from a thread; read for ideas only)
#   packages/contracts/src/space.ts (space.*, space.page.*, space.block.*, space.comment.*)
#   apps/server-ex/lib/hal_c2/space.ex
#   apps/server-ex/priv/mcp_tools.json (hal_c2_page_*)

@mc @desktop @mobile @tui
Feature: Pages in a Space
  A Space holds Pages that people and agents write together. A page is a list of
  blocks (paragraphs, headings, checklists, callouts and links to subpages), can sit
  inside another page, and collects comments. Everything a client sees comes from the
  Space's stream, so every client watching a Space sees each edit as it lands.

  Background:
    Given a connected environment

  Rule: Spaces

    Scenario: The first look at Spaces finds a Personal Space
      When the user lists their Spaces
      Then the Spaces are "Personal"

    Scenario: The Personal Space is made only once
      Given the user has listed their Spaces
      When the user lists their Spaces
      Then the Spaces are "Personal"

    Scenario: The user makes a Space
      When the user makes the Space "Research"
      Then the Spaces are "Personal, Research"

    Scenario: The user renames a Space
      Given the Space "Research"
      When the user renames the Space "Research" to "Lab"
      Then the Spaces are "Personal, Lab"

    Scenario: A Space needs a name
      When the user makes the Space ""
      Then the Space request is refused

    Scenario: The user deletes an empty Space
      Given the Space "Research"
      When the user deletes the Space "Research"
      Then the Spaces are "Personal"

    Scenario: A Space with pages cannot be deleted
      Given the Space "Research" with the page "Notes"
      When the user deletes the Space "Research"
      Then the Space request is refused
      And the Spaces are "Personal, Research"

    Scenario: A client watching the Spaces sees a new one
      Given a second client watching the Spaces
      When the user makes the Space "Research"
      Then the second client sees the Space "Research"

  Rule: Pages and their places

    Background:
      Given the Space "Research"

    Scenario: The user makes a page
      When the user makes the page "Roadmap"
      Then the pages of "Research" are "Roadmap"

    Scenario: The user makes a page inside another page
      Given the page "Roadmap"
      When the user makes the page "Q3" inside "Roadmap"
      Then "Q3" is a subpage of "Roadmap"

    Scenario: The user renames a page
      Given the page "Roadmap"
      When the user renames the page "Roadmap" to "Plan"
      Then the pages of "Research" are "Plan"

    Scenario: The user moves a page to the top of the Space
      Given the page "Q3" inside "Roadmap"
      When the user moves the page "Q3" to the top of the Space
      Then "Q3" is not inside another page

    Scenario: The user moves a page into another page
      Given the pages "Roadmap" and "Ideas"
      When the user moves the page "Ideas" into "Roadmap"
      Then "Ideas" is a subpage of "Roadmap"

    Scenario Outline: A page cannot move inside itself
      Given the page "Q3" inside "Roadmap"
      When the user moves the page "Roadmap" into "<parent>"
      Then the page request is refused
      And "Q3" is a subpage of "Roadmap"

      Examples:
        | parent  |
        | Roadmap |
        | Q3      |

    Scenario: Pages and their content survive a restart
      Given the page "Roadmap" reads "Ship pages"
      When the MC restarts
      Then the page "Roadmap" still reads "Ship pages"

  Rule: Trash

    Background:
      Given the Space "Research"

    Scenario: A trashed page leaves the Space and waits in the trash
      Given the page "Roadmap"
      When the user moves the page "Roadmap" to the trash
      Then the pages of "Research" are ""
      And the trash of "Research" holds "Roadmap"

    Scenario: Trashing a page takes its subpages with it
      Given the page "Q3" inside "Roadmap"
      When the user moves the page "Roadmap" to the trash
      Then the pages of "Research" are ""

    Scenario: The user restores a page from the trash
      Given the page "Q3" inside "Roadmap"
      And the page "Roadmap" is in the trash
      When the user restores the page "Roadmap"
      Then the pages of "Research" are "Roadmap, Q3"
      And the trash of "Research" holds ""

    Scenario: A trashed page cannot be edited
      Given the page "Roadmap" is in the trash
      When the user writes "More" on the page "Roadmap"
      Then the page request is refused

    Scenario: The user deletes a page from the trash for good
      Given the page "Q3" inside "Roadmap"
      And the page "Roadmap" reads "Ship pages"
      And the page "Roadmap" is in the trash
      When the user deletes the page "Roadmap" for good
      Then the trash of "Research" holds ""
      And no blocks or comments of "Roadmap" or "Q3" remain

    Scenario: Only a trashed page can be deleted for good
      Given the page "Roadmap"
      When the user deletes the page "Roadmap" for good
      Then the page request is refused
      And the pages of "Research" are "Roadmap"

  Rule: Blocks

    Background:
      Given the Space "Research" with the page "Roadmap"

    Scenario Outline: The user adds a block of each kind
      When the user adds a <kind> block "Ship it" to "Roadmap"
      Then "Roadmap" has a <kind> block "Ship it"

      Examples:
        | kind      |
        | paragraph |
        | heading   |
        | checklist |
        | callout   |

    Scenario: A block can link to a subpage
      Given the page "Q3" inside "Roadmap"
      When the user links "Q3" from "Roadmap"
      Then "Roadmap" links to "Q3"

    @backlog-mobile @backlog-tui
    Scenario: A subpage made from a link is linked straight away
      Given the page "Roadmap"
      When the user makes the subpage "Q3" from a link on "Roadmap"
      Then "Q3" is a subpage of "Roadmap"
      And "Roadmap" links to "Q3"

    Scenario: A block goes in between two others
      Given "Roadmap" has the blocks "One, Three"
      When the user adds "Two" after "One" on "Roadmap"
      Then the blocks of "Roadmap" read "One, Two, Three"

    Scenario: The user edits a block
      Given "Roadmap" has the blocks "Draft"
      When the user changes the block "Draft" to "Final"
      Then the blocks of "Roadmap" read "Final"

    Scenario: The user ticks and unticks a checklist item
      Given "Roadmap" has the checklist item "Ship it"
      When the user ticks "Ship it"
      Then "Ship it" is ticked
      When the user unticks "Ship it"
      Then "Ship it" is not ticked

    Scenario: Only a checklist item can be ticked
      Given "Roadmap" has the blocks "Plain"
      When the user ticks "Plain"
      Then the page request is refused

    Scenario: The user moves a block
      Given "Roadmap" has the blocks "One, Two, Three"
      When the user moves the block "Three" before "One"
      Then the blocks of "Roadmap" read "Three, One, Two"

    Scenario: Moving a block changes no other block
      Given "Roadmap" has the blocks "One, Two, Three"
      When the user moves the block "Three" before "Two"
      Then only the block "Three" changed

    Scenario: The user deletes a block
      Given "Roadmap" has the blocks "One, Two"
      When the user deletes the block "One"
      Then the blocks of "Roadmap" read "Two"

    Scenario: A client watching the Space sees an edit as it lands
      Given a second client watching the Space "Research"
      When the user adds a paragraph block "Ship it" to "Roadmap"
      Then the second client sees the block "Ship it"

  Rule: Comments

    Background:
      Given the Space "Research" with the page "Roadmap"
      And "Roadmap" has the blocks "Ship it"

    Scenario: The user comments on a block
      When the user comments "Which week?" on the block "Ship it"
      Then the block "Ship it" has the open comment "Which week?"

    Scenario: The user resolves a comment
      Given the comment "Which week?" on the block "Ship it"
      When the user resolves the comment "Which week?"
      Then the comment "Which week?" is resolved

    Scenario: The user reopens a resolved comment
      Given the comment "Which week?" on the block "Ship it"
      And the comment "Which week?" is resolved already
      When the user reopens the comment "Which week?"
      Then the block "Ship it" has the open comment "Which week?"

    Scenario: A comment needs a body
      When the user comments "" on the block "Ship it"
      Then the page request is refused

  Rule: Markdown

    Background:
      Given the Space "Research"

    Scenario: The user exports a page as Markdown
      Given the page "Roadmap" with the blocks:
        | kind      | text       | checked |
        | heading   | Goals      |         |
        | paragraph | Ship pages |         |
        | checklist | Contracts  | yes     |
        | checklist | MC         | no      |
        | callout   | Mind trash |         |
      When the user exports "Roadmap" as Markdown
      Then the Markdown is:
        """
        # Roadmap

        ## Goals

        Ship pages

        - [x] Contracts
        - [ ] MC

        > Mind trash
        """

    Scenario: The user imports Markdown as a new page
      When the user imports this Markdown into "Research":
        """
        # Roadmap

        ## Goals

        Ship pages

        - [x] Contracts
        - [ ] MC
        """
      Then the page "Roadmap" has the blocks:
        | kind      | text       | checked |
        | heading   | Goals      |         |
        | paragraph | Ship pages |         |
        | checklist | Contracts  | yes     |
        | checklist | MC         | no      |

  Rule: A page from a thread

    Background:
      Given a connected environment with the thread "Work" in the project "shop"
      And the thread "Work" talked about a release plan
      And the Space "Research"

    Scenario: The user turns a thread into a page
      Given text generation is available
      When the user makes a page in "Research" from the thread "Work"
      Then the new page holds the generated summary
      And the new page remembers it came from "Work"
      And the summary was written in the project's folder

    Scenario: No page is made without text generation
      Given no text generation provider is available
      When the user makes a page in "Research" from the thread "Work"
      Then the user is told text generation is unavailable
      And the pages of "Research" are ""

    Scenario: A failed summary makes no page
      Given text generation fails
      When the user makes a page in "Research" from the thread "Work"
      Then the user is told text generation failed
      And the pages of "Research" are ""

  @backlog-desktop @backlog-mobile
  Rule: Agents write pages too

    Background:
      Given a connected environment with the thread "Work" in the project "shop"
      And the Space "Research" with the page "Roadmap"
      And "Roadmap" has the blocks "Ship it"

    @backlog-tui
    Scenario: An agent lists and reads pages
      When the agent in "Work" lists the pages of "Research"
      Then the agent sees the page "Roadmap"
      When the agent in "Work" reads the page "Roadmap"
      Then the agent reads "Ship it"

    Scenario: An agent's edit names its thread
      When the agent in "Work" adds the block "Agent note" to "Roadmap"
      Then the block "Agent note" was written by the thread "Work"

    Scenario: An agent edits and deletes a block
      When the agent in "Work" changes the block "Ship it" to "Shipped"
      And the agent in "Work" deletes the block "Shipped"
      Then the blocks of "Roadmap" read ""

    @backlog-tui
    Scenario: An agent's refused edit changes nothing
      When the agent in "Work" changes the block "Ship it" to "Shipped" and ticks it
      Then the agent is refused
      And the blocks of "Roadmap" read "Ship it"

    @backlog-tui
    Scenario: An agent cannot edit a trashed page
      Given the page "Roadmap" is in the trash
      When the agent in "Work" adds the block "Agent note" to "Roadmap"
      Then the agent is refused
