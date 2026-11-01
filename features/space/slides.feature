# Sources:
#   https://chatgpt.com/features/space/ (slides made from a Space's pages)
#   spaces-feature-bdd-tests branch, features/space/slides-sites-and-images.feature
#     (the prototype: decks, slides, a presenter; read for ideas only)
#   packages/contracts/src/space.ts (space.deck.*, space.slide.*)
#   apps/server-ex/lib/hal_c2/space/decks.ex

Feature: Slide decks in a Space
  A deck is a second kind of thing in a Space, beside pages: a list of slides, each
  with a title and a body of text. It lives on the Space's stream, so every client
  watching sees each edit as it lands. A deck made from a page is a copy: later edits
  of the page do not change it. Slide tables write a body's lines apart with " / ".
  A slide's body is text, so an image on the page is marked there by its caption.

  Background:
    Given a connected environment
    And the Space "Research"

  @mc @desktop @mobile @tui
  Rule: Making a deck

    Scenario: The user makes a deck from nothing
      When the user makes the deck "Pitch"
      Then the decks of "Research" are "Pitch"
      And the deck "Pitch" has the slides:
        | title | body |
        |       |      |

    Scenario: A deck needs a title
      When the user makes the deck " "
      Then the deck request is refused
      And the decks of "Research" are ""

    Scenario: A deck from a page has a slide for each section
      Given the page "Roadmap" with the blocks:
        | kind      | text       | checked |
        | paragraph | Why now    |         |
        | heading   | Goals      |         |
        | paragraph | Ship pages |         |
        | checklist | Contracts  | yes     |
        | checklist | MC         | no      |
        | heading   | Risks      |         |
        | callout   | Mind trash |         |
      When the user makes a deck from the page "Roadmap"
      Then the decks of "Research" are "Roadmap"
      And the deck "Roadmap" has the slides:
        | title   | body                                    |
        | Roadmap | Why now                                 |
        | Goals   | Ship pages / - [x] Contracts / - [ ] MC |
        | Risks   | > Mind trash                            |

    Scenario: A page with no headings makes one slide
      Given the page "Roadmap" reads "Ship pages"
      When the user makes a deck from the page "Roadmap"
      Then the deck "Roadmap" has the slides:
        | title   | body       |
        | Roadmap | Ship pages |

    Scenario: A deck from a page is a copy
      Given the page "Roadmap" reads "Ship pages"
      And the user makes a deck from the page "Roadmap"
      When the user writes "More" on the page "Roadmap"
      Then the deck "Roadmap" has the slides:
        | title   | body       |
        | Roadmap | Ship pages |

    Scenario: A page in the trash makes no deck
      Given the page "Roadmap" is in the trash
      When the user makes a deck from the page "Roadmap"
      Then the deck request is refused
      And the decks of "Research" are ""

    Scenario: The user renames a deck
      Given the deck "Pitch"
      When the user renames the deck "Pitch" to "Keynote"
      Then the decks of "Research" are "Keynote"

    Scenario: A client watching the Space sees a new deck
      Given a second client watching the Space "Research"
      When the user makes the deck "Pitch"
      Then the second client sees the deck "Pitch"

  @mc
  Rule: An image on the page a deck is made from

    Scenario: A slide marks an image from its page
      Given the page "Roadmap"
      And the image "cat.png" in "Research"
      And "Roadmap" shows the image "cat.png" already
      When the user makes a deck from the page "Roadmap"
      Then the deck "Roadmap" has the slides:
        | title   | body             |
        | Roadmap | [image: cat.png] |

  @mc @desktop @mobile @tui
  Rule: Slides

    Background:
      Given the deck "Pitch" with the slides "One, Two, Three"

    Scenario: The user adds a slide at the end
      When the user adds the slide "Four" to "Pitch"
      Then the slides of "Pitch" are "One, Two, Three, Four"

    Scenario: A slide goes in between two others
      When the user adds the slide "Between" after "One" in "Pitch"
      Then the slides of "Pitch" are "One, Between, Two, Three"

    Scenario: The user edits a slide's title and body
      When the user changes the slide "Two" to "Second" reading "More to say"
      Then the deck "Pitch" has the slides:
        | title  | body        |
        | One    |             |
        | Second | More to say |
        | Three  |             |

    Scenario: The user moves a slide
      When the user moves the slide "Three" before "One"
      Then the slides of "Pitch" are "Three, One, Two"

    Scenario: The user deletes a slide
      When the user deletes the slide "Two"
      Then the slides of "Pitch" are "One, Three"

    Scenario: A deck can lose its last slide and gain another
      Given the deck "Short" with the slides "Only"
      When the user deletes the slide "Only"
      Then the slides of "Short" are ""
      When the user adds the slide "Again" to "Short"
      Then the slides of "Short" are "Again"

    Scenario: A client watching the Space sees a slide edit as it lands
      Given a second client watching the Space "Research"
      When the user changes the slide "Two" to "Second" reading "More to say"
      Then the second client sees the slide "Second"

    Scenario: Decks and their slides survive a restart
      When the MC restarts
      Then the slides of "Pitch" are still "One, Two, Three"

  @tui
  Rule: Editing a slide on one line in the terminal

    Background:
      Given the deck "Pitch" with the slides "One"

    Scenario: A slash in a slide's body stays a slash
      When the user changes the slide "One" to "One" reading "Either / or"
      Then the slide "One" shows the line "Either / or"

    Scenario: The user starts a new line in a slide's body
      When the user changes the slide "One" to "One" reading "Up\nDown"
      Then the slide "One" shows the line "Up"
      And the slide "One" shows the line "Down"

  @desktop
  Rule: Writing a deck's title in place

    Scenario: A title being written reaches its deck after the Space changes
      Given the deck "Pitch"
      When the title "Keynote" written for the deck "Pitch" lands once the Space "Lab" is on show
      Then the decks of "Research" are "Keynote"

  @mc @desktop @mobile @tui
  Rule: Trash

    Background:
      Given the deck "Pitch" with the slides "One, Two"

    Scenario: A trashed deck leaves the Space and waits in the trash
      When the user moves the deck "Pitch" to the trash
      Then the decks of "Research" are ""
      And the trash of "Research" holds "Pitch"

    Scenario: The user restores a deck from the trash
      Given the deck "Pitch" is in the trash
      When the user restores the deck "Pitch"
      Then the decks of "Research" are "Pitch"
      And the trash of "Research" holds ""
      And the slides of "Pitch" are "One, Two"

    Scenario: A trashed deck cannot be edited
      Given the deck "Pitch" is in the trash
      When the user adds the slide "Three" to "Pitch"
      Then the deck request is refused

    Scenario: The user deletes a deck from the trash for good
      Given the deck "Pitch" is in the trash
      When the user deletes the deck "Pitch" for good
      Then the trash of "Research" holds ""
      And no slides remain in "Research"

    Scenario: Only a trashed deck can be deleted for good
      When the user deletes the deck "Pitch" for good
      Then the deck request is refused
      And the decks of "Research" are "Pitch"

    Scenario: A Space with a deck cannot be deleted
      When the user deletes the Space "Research"
      Then the Space request is refused
      And the Spaces are "Personal, Research"

    Scenario: A Space with a deck in the trash cannot be deleted
      Given the deck "Pitch" is in the trash
      When the user deletes the Space "Research"
      Then the Space request is refused
      And the Spaces are "Personal, Research"

  @desktop @mobile @tui
  Rule: Presenting

    Background:
      Given the deck "Pitch" with the slides "One, Two, Three"

    Scenario: Presenting starts at the first slide
      When the user presents the deck "Pitch"
      Then the presenter shows "One", slide 1 of 3

    Scenario: The user steps through the slides and back
      Given the user presents the deck "Pitch"
      When the user steps forward
      Then the presenter shows "Two", slide 2 of 3
      When the user steps back
      Then the presenter shows "One", slide 1 of 3

    Scenario: Stepping stops at either end
      Given the user presents the deck "Pitch"
      When the user steps back
      Then the presenter shows "One", slide 1 of 3
      When the user steps forward
      And the user steps forward
      And the user steps forward
      Then the presenter shows "Three", slide 3 of 3

    Scenario: The user leaves the presenter
      Given the user presents the deck "Pitch"
      When the user leaves the presenter
      Then nothing is being presented
      And the slides of "Pitch" are "One, Two, Three"

    Scenario: An edit from another client shows while presenting
      Given the user presents the deck "Pitch"
      When another client changes the slide "One" to "First"
      Then the presenter shows "First", slide 1 of 3

    Scenario: A slide moved by another client keeps the presenter on it
      Given the user presents the deck "Pitch"
      When another client moves the slide "One" after "Three"
      Then the presenter shows "One", slide 3 of 3

    Scenario: The slide on show is deleted by another client
      Given the user presents the deck "Pitch"
      And the user steps forward
      And the user steps forward
      When another client deletes the slide "Three"
      Then the presenter shows "Two", slide 2 of 2

    Scenario: The presenter closes when the deck goes to the trash
      Given the user presents the deck "Pitch"
      When another client moves the deck "Pitch" to the trash
      Then nothing is being presented

    Scenario: A deck with no slides cannot be presented
      Given the deck "Blank" with the slides ""
      When the user presents the deck "Blank"
      Then nothing is being presented
      And the user is told the deck has no slides

  @backlog @mc @shared
  Rule: Still to come

    Background:
      Given the deck "Pitch" with the slides "One, Two"

    Scenario: The user keeps speaker notes on a slide
      When the user writes the speaker note "Slow down" on the slide "One"
      Then the presenter shows the note "Slow down" on the slide "One"

    Scenario: The user exports a deck to PowerPoint
      When the user exports the deck "Pitch" as PowerPoint
      Then the file has a slide for "One" and for "Two"

    Scenario: A slide shows an image
      When the user puts an image on the slide "One"
      Then the slide "One" shows the image

    Scenario: A deck has a theme
      When the user picks a theme for the deck "Pitch"
      Then each slide of "Pitch" is drawn in that theme

    Scenario: An agent makes and edits a deck
      When the agent in "Work" makes the deck "Agent pitch"
      Then the decks of "Research" are "Pitch, Agent pitch"
