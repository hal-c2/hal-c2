# Sources:
#   apps/tui/src/theme.ts, theme.test.ts (indexed ANSI palette, status glyphs, relative times)
#   apps/tui/src/icons.ts, icons.test.ts
#   apps/tui/src/format.ts
#   apps/tui/src/mouse.ts, mouse.test.ts
#   apps/tui/src/terminalGraphics.ts, terminalGraphics.test.ts
#   apps/tui/src/attachmentImages.ts, attachmentImages.test.ts
#   apps/tui/src/components/ImageLightbox.tsx, ImageLightbox.test.tsx
#   apps/tui/src/components/MessagesTimeline.tsx (attachment link lines)
#   apps/tui/src/components/Sidebar.tsx (right-click, tap, long press)
#   apps/tui/src/index.tsx (colour capability log, mouse configuration)
#   packages/opentui-image (decodeImage, Kitty protocol, tmux passthrough)
#   Shared domain: navigation/ owns appearance and themes on the other surfaces.

Feature: Colour, icons, mouse and images in the terminal
  The terminal client borrows the user's terminal theme, uses glyphs every font has, and
  shows images only where the terminal can draw them, with a readable fallback everywhere else.

  @tui
  Scenario: The client borrows the terminal's own colour theme
    Given the user's terminal has a light theme
    When the terminal client opens
    Then text uses the terminal's default foreground and background
    And accent colours come from the terminal's ANSI palette

  @tui
  Scenario: Opening the client never leaks colour queries into the prompt
    When the terminal client opens
    Then no terminal colour reply appears as typed text in the prompt

  @tui
  Scenario: Colour depth is logged at startup for diagnosis
    When the terminal client opens
    Then the client log records the detected colour capabilities
    And it records them again two seconds later after the terminal has answered

  @tui
  Scenario Outline: Thread status shows as a coloured glyph in priority order
    Given a thread that is <state>
    Then the thread list shows it with "<glyph>" in <colour>

    Examples:
      | state                    | glyph | colour  |
      | waiting on an approval   | ◆     | red     |
      | waiting on the user      | ◆     | yellow  |
      | holding a ready plan     | ◇     | magenta |
      | working                  | ●     | green   |
      | connecting               | ◌     | cyan    |
      | failed                   | ✕     | red     |
      | ready                    | ○     | cyan    |
      | completed                | ✓     | green   |
      | idle                     | ○     | gray    |

  @tui
  Scenario: A pending approval outranks a running session
    Given a thread that is working and waiting on an approval
    Then the thread list shows the approval glyph

  @tui
  Scenario: A project shows the most urgent status among its threads
    Given a project with one idle thread and one thread waiting on the user
    Then the project shows the waiting-on-the-user status

  @tui
  Scenario Outline: Ages are shown in compact relative time
    Given a thread last updated <age> ago
    Then its age reads "<label>"

    Examples:
      | age        | label |
      | 30 seconds | now   |
      | 90 seconds | 1m    |
      | 3 hours    | 3h    |
      | 2 days     | 2d    |

  @tui
  Scenario Outline: Status line messages carry a tone glyph
    When the client reports a <tone> message
    Then the status line starts with "<glyph>"

    Examples:
      | tone    | glyph |
      | success | ✓     |
      | error   | ✗     |
      | busy    | ⟳     |
      | info    | ·     |

  @tui
  Scenario: Every icon takes exactly one terminal column
    Then every tool and status icon is a single-column character in any monospace font

  @tui
  Scenario: File names are tinted by their type
    Given a changed file "src/app.ts" and a changed file "notes.unknownext"
    Then "src/app.ts" is tinted for its file type
    And "notes.unknownext" is dimmed

  @backlog @tui
  Scenario: A nerd font opts the client into richer icons
    Given the user has told the client their terminal uses a nerd font
    Then tool and file icons use nerd font glyphs
    And turning the option off returns to the single-column fallbacks

  @backlog @tui
  Scenario: The user picks a colour theme for the client
    When the user chooses a colour theme in the terminal client
    Then the client redraws in that theme
    And choosing the terminal default again borrows the terminal's colours

  @backlog @tui
  Scenario Outline: The client adapts to the terminal's colour depth
    Given the terminal supports <depth>
    Then status, diff and syntax colours stay distinguishable

    Examples:
      | depth           |
      | truecolor       |
      | 256 colours     |

  @backlog @tui
  Scenario: The client honours NO_COLOR
    Given the environment variable "NO_COLOR" is set
    When the terminal client opens
    Then no colour escape sequences are written
    And status is still readable from glyphs and text

  @tui
  Scenario: Clicking a thread selects it
    When the user clicks a thread in the list
    Then that thread opens

  @tui
  Scenario: Right-clicking a thread opens its context menu
    When the user right-clicks a thread in the list
    Then the thread context menu opens without changing the selected thread

  @tui
  Scenario: A long press opens the context menu for users without a right button
    When the user presses and holds on a thread in the list
    Then the thread context menu opens without changing the selected thread

  @tui
  Scenario: Dragging still selects text for the terminal's own copy
    When the user drags across text in the timeline
    Then the terminal's native text selection works

  @tui
  Scenario: Rapid clicks do not act twice
    When one click reaches the same control more than once
    Then the action runs once, after the click has been handled

  @backlog @tui
  Scenario: The user turns mouse support off
    Given the user starts the terminal client with mouse support turned off
    Then clicks and wheel events go to the terminal emulator
    And every action is still reachable from the keyboard

  @tui
  Scenario Outline: Terminals that speak the Kitty graphics protocol show inline images
    Given the user's terminal is <terminal>
    When a message with an image attachment is shown
    Then the image is drawn inline in the timeline

    Examples:
      | terminal |
      | Ghostty  |
      | Kitty    |
      | WezTerm  |
      | Konsole  |

  @tui
  Scenario: Images work inside tmux when the outer terminal supports them
    Given the terminal client runs inside tmux in Ghostty
    When a message with an image attachment is shown
    Then the image is drawn inline through tmux passthrough

  @tui
  Scenario: An unknown terminal inside tmux gets no inline images
    Given the terminal client runs inside tmux in a terminal it cannot identify
    When a message with an image attachment is shown
    Then no image is drawn
    And the attachment shows its name, size and link

  @tui
  Scenario Outline: The attachment line explains where the image link stands
    Given an image attachment whose link is <link state>
    Then the attachment line reads "<text>"

    Examples:
      | link state    | text             |
      | still loading | resolving link…  |
      | unavailable   | link unavailable |

  @tui
  Scenario: Oversized images are refused before decoding
    Given an image attachment larger than the preview byte limit
    Then no inline preview is drawn
    And the attachment line stays visible

  @tui
  Scenario: A preview that failed to load is retried later
    Given an image preview failed because of a network error
    When the message is shown again
    Then the client tries to load the preview again

  @tui
  Scenario: Clicking an inline image opens it full size
    Given an inline image in the timeline
    When the user clicks the image
    Then the image opens fitted inside the terminal without distortion

  @tui
  Scenario: Closing the full-size image returns to the same place
    Given an image is open full size
    When the user presses "Esc"
    Then the image closes
    And the timeline is at the same scroll position as before

  @backlog @tui
  Scenario: Sixel terminals show inline images
    Given the user's terminal supports sixel but not the Kitty graphics protocol
    When a message with an image attachment is shown
    Then the image is drawn inline with sixel

  @backlog @tui
  Scenario: Copying a message puts its text on the clipboard
    When the user copies a message from the timeline
    Then the message text is on the system clipboard

  @backlog @tui
  Scenario: Opening an external link falls back to copying it
    Given the terminal cannot open links
    When the user opens a link from the timeline
    Then the link is copied and the status line says so

  @backlog @tui
  Scenario: The user opens a file location in their editor
    When the user opens a file reference from the timeline
    Then the file opens in the user's editor at that line
