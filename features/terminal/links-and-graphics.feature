# Sources:
#   packages/shared/src/terminalLinks.ts (extractTerminalLinks, wrapped link ranges, resolveTerminalPath)
#   apps/tui/src/terminalView.ts (readTerminalFrame colours, cursor, OSC 8 links, scan limits)
#   apps/tui/src/terminalView.test.ts
#   apps/tui/src/components/ThreadTerminalDrawer.tsx (renderSegment)
#   apps/web/src/components/ThreadTerminalDrawer.tsx (link activation, theme and font)
#   apps/web/src/components/preview/openTerminalLinkInPreview.ts
#   apps/web/src/components/preview/openTerminalLinkInPreview.test.ts
#   apps/web/src/terminal/ghostty/surface.ts (libghostty-vt renderer, Kitty keyboard reporting)
#   Cross-domain: tui/appearance.feature owns inline images and graphics detection in the terminal
#   client itself; settings/integrations.feature owns the "Open links in" preference and
#   navigation/appearance.feature owns terminal fonts.

Feature: Links and rendering inside terminals
  A terminal shows the program's colours faithfully and turns web addresses and file paths in
  its output into links the user can follow.

  Rule: The terminal client draws the shell's screen faithfully

    @tui
    Scenario Outline: Terminal colours follow the program and the user's theme
      Given a program prints text in <colour>
      When the terminal client shows the terminal
      Then the text is drawn in <drawn>

      Examples:
        | colour                     | drawn                                          |
        | an ANSI palette colour     | the user's own terminal theme for that colour |
        | an exact 24-bit colour     | that exact colour                              |
        | the default colour         | the user's default text colour                 |

    @tui
    Scenario: The shell's cursor stays visible on any theme
      Given the shell's prompt is waiting at an empty cell
      Then the terminal client shows a solid cursor block there
      And the cursor is dimmed while the terminal does not have focus

    @tui
    Scenario: Bold, italic, underlined and reversed text keep their style
      Given a program prints bold, italic, underlined and reversed text
      Then the terminal client shows each style

  Rule: Web addresses in terminal output are links

    @tui
    Scenario: A web address in the output becomes a link the user's terminal can open
      Given the shell prints "Server ready at http://localhost:5173"
      Then only "http://localhost:5173" is a link
      And following it opens "http://localhost:5173"

    @tui
    Scenario: A web address that wraps across lines opens in full
      Given the shell prints a web address longer than the terminal is wide
      Then every visible piece of it opens the complete address

    @tui
    Scenario: A link after wide characters still lines up with its text
      Given the shell prints Chinese text followed by a web address
      Then the link covers exactly the address

    @tui
    Scenario Outline: Oversized output is not turned into links
      Given the shell prints <output>
      Then no link is created for it

      Examples:
        | output                                              |
        | a web address longer than 4 KiB                     |
        | a single line longer than 64 KiB with an address   |

    @backlog @desktop
    Scenario: Following a web address opens it in the in-app browser
      Given the user's links open in the in-app browser
      When the user follows "http://localhost:5173" in the terminal
      Then the address opens in a browser tab beside the thread

    @backlog @desktop
    Scenario: Public web addresses open in the in-app browser too
      Given the user's links open in the in-app browser
      When the user follows "https://example.com/docs" in the terminal
      Then the address opens in a browser tab beside the thread

    @desktop
    Scenario: Following a link opens the system browser when that is the chosen target
      Given the user's links open in the system browser
      When the user follows "http://localhost:5173" in the terminal
      Then the address opens in the system browser

    @backlog @desktop
    Scenario: Holding the command key sends a link to the system browser
      Given the user's links open in the in-app browser
      When the user follows a link while holding Command or Control
      Then the address opens in the system browser

    @backlog @desktop
    Scenario: A link that cannot open in the in-app browser falls back to the system browser
      Given opening the in-app browser fails
      When the user follows a web address in the terminal
      Then the address opens in the system browser
      And the failure is recorded with its cause

    @desktop
    Scenario: A file path in the output opens in the editor
      Given the shell prints "src/app.ts:12:4"
      When the user follows that path
      Then "src/app.ts" opens in the user's editor at line 12, column 4
      And the path is resolved against the terminal's folder

    @backlog @desktop
    Scenario: Hovering a link underlines all of it and shows it can be followed
      Given the shell prints a web address that wraps across two lines
      When the user moves the pointer over one piece of it
      Then every piece of the address is underlined
      And the pointer shows that it can be followed
      When the pointer moves off the address
      Then the underline and the pointer go back to normal

    @backlog @desktop
    Scenario: A link is not offered while a program has the mouse
      Given a program in the terminal has asked to receive mouse events
      When the user moves the pointer over a web address in the output
      Then the address is not underlined
      And pressing on it goes to the program

    @backlog @desktop
    Scenario: A click that moves a little still follows the link
      Given the shell prints a web address
      When the user presses on the address and releases a few pixels away
      Then the address is followed

    @backlog @desktop
    Scenario: Dragging from a link selects text instead of following it
      Given the shell prints a web address
      When the user presses on the address and drags well away before releasing
      Then the text between the press and the release is selected
      And the address is not followed

    @backlog @desktop
    Scenario: A link replaced before the pointer is released is not followed
      Given the user pressed on a link
      When the output changes so that another address is under the pointer before release
      Then nothing is followed

    @backlog @desktop
    Scenario: Clicking a link twice or three times selects a word or a line
      Given the shell prints a web address
      When the user double-clicks and then triple-clicks on the address
      Then the word is selected and then the whole line
      And the address is not followed

    @backlog @desktop
    Scenario: A link cut off by the edge of the screen is not offered
      Given a web address wraps so that its start has scrolled above the top of the screen
      Then the part still on screen is not a link
      And nothing is opened for a half-seen address

  Rule: The web terminal renders like a native terminal

    @desktop
    Scenario: The web terminal follows the app's theme and font
      Given the user switches the app to a dark theme
      Then the terminal's colours and selection follow the dark theme
      And the terminal uses the app's terminal font

    @desktop
    Scenario: Programs that ask for enhanced keyboard reporting receive it
      Given a program turns on the Kitty keyboard protocol
      When the user presses a key with modifiers
      Then the program receives the enhanced key report
