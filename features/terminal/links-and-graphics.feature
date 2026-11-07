# Sources:
#   https://github.com/pingdotgg/t3code/pull/23527
#   https://github.com/pingdotgg/t3code/pull/24013
#   https://github.com/pingdotgg/t3code/pull/15020
#   https://github.com/pingdotgg/t3code/pull/22872
#   https://github.com/pingdotgg/t3code/pull/21199
#   https://github.com/pingdotgg/t3code/pull/15838
#   https://github.com/pingdotgg/t3code/pull/9867
#   https://github.com/pingdotgg/t3code/pull/20264
#   https://github.com/pingdotgg/t3code/pull/17653
#   https://github.com/pingdotgg/t3code/pull/17168
#   https://github.com/pingdotgg/t3code/pull/13408
#   packages/shared/src/terminalLinks.ts (extractTerminalLinks, wrapped link ranges, resolveTerminalPath)
#   apps/tui/src/terminalView.ts (readTerminalFrame colours, cursor, OSC 8 links, scan limits)
#   apps/tui/src/terminalView.test.ts
#   apps/tui/src/components/ThreadTerminalDrawer.tsx (renderSegment)
#   apps/web/src/components/ThreadTerminalDrawer.tsx (link activation, theme and font)
#   apps/web/src/components/preview/openTerminalLinkInPreview.ts
#   apps/web/src/components/preview/openTerminalLinkInPreview.test.ts
#   apps/web/src/terminal/ghostty/surface.ts (libghostty-vt renderer, Kitty keyboard reporting)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalSplits.qml, TerminalMenu.qml (Ctrl-click and the link's menu)
#   apps/desktop-qt/src/native/TerminalController.cpp (followLink)
#   Cross-domain: tui/appearance.feature owns inline images and graphics detection in the terminal
#   client itself; settings/integrations.feature owns the "Open links in" preference and
#   navigation/appearance.feature owns terminal fonts.
#   https://github.com/pingdotgg/t3code/pull/28189

Feature: Links and rendering inside terminals
  A terminal shows the program's colours faithfully and turns web addresses and file paths in
  its output into links the user can follow with Ctrl-click (Cmd-click on macOS) or its menu.

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
    # Upstream #24013: a wide character's second cell read as a space, which ended the link.
    @desktop @backlog
    Scenario Outline: A link holding wide characters opens in full
      Given the shell prints <output>
      Then the whole of it is underlined, both cells of its last character included
      And following it opens <opens>

      Examples:
        | output                                    | opens                                     |
        | "https://ja.wikipedia.org/wiki/日本語"     | "https://ja.wikipedia.org/wiki/日本語"     |
        | the path "docs/日本語/notes.md"            | "docs/日本語/notes.md"                     |
        | "https://example.com/party/🎉"            | "https://example.com/party/🎉"            |
        | "https://example.com/a b"                 | "https://example.com/a", as a real space still ends a link |


    @tui
    Scenario Outline: Oversized output is not turned into links
      Given the shell prints <output>
      Then no link is created for it

      Examples:
        | output                                              |
        | a web address longer than 4 KiB                     |
        | a single line longer than 64 KiB with an address   |

    # A plain click on a link only places the pointer, so copying an address never opens it by
    # accident: links are followed with Ctrl held (Cmd on macOS), as other terminals do, or from
    # the terminal's menu.
    @desktop
    Scenario: A plain click on a link does not follow it
      Given the user's links open in the system browser
      When the user clicks "http://localhost:5173" in the terminal without holding Ctrl
      Then nothing is opened

    @desktop
    Scenario: A plain click on a file path does not open it
      Given the shell prints "src/app.ts:12:4"
      When the user clicks "src/app.ts:12:4" in the terminal without holding Ctrl
      Then nothing is opened

    @desktop @mobile @backlog-mobile
    Scenario: A tap on a link on a touch screen follows it
      Given the user's links open in the system browser
      When the user taps "http://localhost:5173" in the terminal on a touch screen
      Then the address opens in the system browser

    # Waits on an in-app browser: the desktop has none (docs/internals/desktop-qt.md), so every link
    # goes to the system browser whatever the setting says.
    @backlog @blocked @desktop
    Scenario: Following a web address opens it in the in-app browser
      Given the user's links open in the in-app browser
      When the user follows "http://localhost:5173" in the terminal
      Then the address opens in a browser tab beside the thread

    # Waits on an in-app browser: the desktop has none (docs/internals/desktop-qt.md), so every link
    # goes to the system browser whatever the setting says.
    @backlog @blocked @desktop
    Scenario: Public web addresses open in the in-app browser too
      Given the user's links open in the in-app browser
      When the user follows "https://example.com/docs" in the terminal
      Then the address opens in a browser tab beside the thread

    @desktop
    Scenario: Following a link opens the system browser when that is the chosen target
      Given the user's links open in the system browser
      When the user follows "http://localhost:5173" in the terminal
      Then the address opens in the system browser

    @desktop
    Scenario: The link's menu sends a link to the system browser
      Given the user's links open in the in-app browser
      When the user chooses to open a link in the system browser from the terminal's menu
      Then the address opens in the system browser

    # Waits on an in-app browser: the desktop has none (docs/internals/desktop-qt.md), so every link
    # goes to the system browser whatever the setting says.
    @backlog @blocked @desktop
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

    # Upstream #21199: relative backslash paths and quoted paths with spaces are file links,
    # keeping a line and column given inside or outside the quotes.
    @backlog @desktop @priority-low
    Scenario Outline: Windows paths in the output open in the editor
      Given the shell prints <output>
      When the user follows that path
      Then "<file>" opens in the user's editor at line 12

      Examples:
        | output                                                         | file                               |
        | src\index.ts:12                                                | src\index.ts                       |
        | .\src\index.ts:12                                              | src\index.ts                       |
        | C:\Users\Jane Doe\project\index.ts:12 wrapped in double quotes | C:\Users\Jane Doe\project\index.ts |
        | C:\Users\Jane Doe\project\index.ts in double quotes, then :12  | C:\Users\Jane Doe\project\index.ts |

    # Upstream #23527: PowerShell's prompt prints its folder unquoted, so a folder with a space split
    # into two links.
    @backlog @desktop @priority-low
    Scenario: A PowerShell prompt's folder with a space is one link
      Given the shell prints the prompt "PS C:\dev\ai-test\dir 1\test>"
      When the user follows "dir 1" in the terminal
      Then the link followed is "C:\dev\ai-test\dir 1\test"
      And no separate link covers "1\test"

    # git status prints a branch and its upstream as "## main...origin/main".
    @desktop
    Scenario: A branch range in git's output is not a file path
      Given the shell prints "## main...origin/main"
      When the user follows "main...origin/main" in the terminal
      Then nothing is opened

    # Upstream #15838: a logged request route with a query was opened in the editor as a file.
    @backlog @desktop @priority-low
    Scenario Outline: A request route in a log line is not a file path
      Given the shell prints "<line>"
      When the user follows "<route>" in the terminal
      Then nothing is opened

      Examples:
        | line                                         | route                               |
        | GET /api/trpc/post.list,user.me?batch=1 200  | /api/trpc/post.list,user.me?batch=1 |
        | proxying /api/users?page=2 to localhost:4000 | /api/users?page=2                   |

    # Upstream #28189: the Windows drive rule matched the last letter of a URL scheme, so
    # "redis://..." became a link to a file that does not exist.
    @backlog @desktop
    Scenario Outline: An address with a scheme other than http is not a file path
      Given the shell prints "<line>"
      When the user follows "<text>" in the terminal
      Then nothing is opened

      Examples:
        | line                                               | text                                  |
        | Connected to redis://127.0.0.1:6379/0              | s://127.0.0.1:6379/0                  |
        | postgres://app@localhost:5432/shop                 | s://app@localhost:5432/shop           |
        | uploaded to s3://bucket/key                        | //bucket/key                          |
        | at main (file:///Users/me/app/src/index.mjs:3:7)   | e:///Users/me/app/src/index.mjs:3:7   |

    # Upstream #28189
    @backlog @desktop
    Scenario: A file path beside a non-web address is still a link
      Given the shell prints "src/config.ts:12 uses redis://127.0.0.1:6379/0"
      When the user follows "src/config.ts:12" in the terminal
      Then "src/config.ts" opens in the editor at line 12

    @desktop
    Scenario Outline: The terminal's menu opens or copies the link under the pointer
      Given the shell prints "<link>"
      And the user's links open in the system browser
      When the user opens the terminal's menu on "<link>"
      Then the menu offers "<open>" and "<copy>"
      When the user chooses "<copy>" from the link's menu
      Then "<link>" is on the clipboard
      And nothing is opened
      When the user opens the terminal's menu on "<link>"
      And the user chooses "<open>" from the link's menu
      Then <opened>

      Examples:
        | link                  | open      | copy      | opened                                                  |
        | http://localhost:5173 | Open link | Copy link | the address opens in the system browser                 |
        | src/app.ts:12:4       | Open file | Copy path | "src/app.ts" opens in the user's editor at line 12, column 4 |

    @desktop
    Scenario: Holding Ctrl over a link underlines all of it and shows it can be followed
      Given the shell prints a web address that wraps across two lines
      When the user holds Ctrl (Cmd on macOS) and moves the pointer over one piece of it
      Then every piece of the address is underlined
      And the pointer shows that it can be followed
      When the pointer moves off the address
      Then the underline and the pointer go back to normal

    @desktop
    Scenario: A link is not offered while a program has the mouse
      Given a program in the terminal has asked to receive mouse events
      When the user moves the pointer over a web address in the output
      Then the address is not underlined
      And pressing on it goes to the program
      And the terminal's menu on it offers no link

    @desktop
    Scenario: Ctrl still follows a link while a program has the mouse
      Given a program in the terminal has asked to receive mouse events
      And the shell prints a web address
      When the user holds Ctrl and moves the pointer over the address
      Then the address is underlined
      When the user holds Ctrl and clicks the address
      Then the address is followed
      And the program receives no click

    @desktop
    Scenario: A Ctrl-click that moves a little still follows the link
      Given the shell prints a web address
      When the user holds Ctrl, presses on the address and releases a few pixels away
      Then the address is followed

    @desktop
    Scenario: Dragging from a link selects text instead of following it
      Given the shell prints a web address
      When the user presses on the address and drags well away before releasing
      Then the text between the press and the release is selected
      And the address is not followed

    # Upstream #17653. The terminal drawer ends where the window ends, so the pointer can
    # never get past its bottom edge; the edge itself scrolls.
    @desktop @backlog @priority-low
    Scenario Outline: Dragging a selection to the <edge> edge of the terminal scrolls its history
      Given the terminal has more history than fits <direction> the visible rows
      And the terminal's <edge> edge is also the window's <edge> edge
      When the user drags a selection to the <edge> edge and holds it there
      Then the terminal scrolls <direction> through its history
      And the selection keeps growing with it

      Examples:
        | edge   | direction |
        | bottom | below     |
        | top    | above     |

    # Upstream #22872: dragging past the edge scrolled one row a tick however far the pointer
    # went, so selecting a few hundred lines took tens of seconds.
    @desktop @backlog @priority-low
    Scenario Outline: A selection dragged further past the edge scrolls faster
      Given the terminal has hundreds of rows of history above the visible rows
      When the user drags a selection <distance> past the top edge and holds it there
      Then the terminal scrolls up <speed>

      Examples:
        | distance        | speed                   |
        | just            | one row at a time       |
        | 50 pixels       | fifteen rows at a time  |

    @desktop
    Scenario: A link replaced before the pointer is released is not followed
      Given the user pressed on a link
      When the output changes so that another address is under the pointer before release
      Then nothing is followed

    @desktop
    Scenario: Clicking a link twice or three times selects a word or a line
      Given the shell prints a web address
      When the user double-clicks and then triple-clicks on the address
      Then the word is selected and then the whole line
      And the address is not followed

    @desktop
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

    # Upstream #17168. Without a palette of its own the terminal fell back to a pastel one
    # that washed out prompts on dark themes and was hard to read on light ones.
    @desktop @backlog @priority-low
    Scenario: The terminal's sixteen ANSI colours follow the app's light or dark theme
      Given a program printed red text and text in 256-colour red
      When the user switches the app between a light and a dark theme
      Then the red text is redrawn in the red of the new theme's terminal palette
      And the 256-colour red text keeps its colour

    @desktop @backlog @priority-low
    Scenario: A palette colour a program set itself is kept across theme changes
      Given a program changed the terminal's red to its own colour
      When the user switches the app to a dark theme
      Then red text keeps the program's colour

    @desktop
    Scenario: Programs that ask for enhanced keyboard reporting receive it
      Given a program turns on the Kitty keyboard protocol
      When the user presses a key with modifiers
      Then the program receives the enhanced key report

    # Upstream #15020: Kitty programs got releases for shortcuts the app took, and a split lost held keys.
    @backlog @desktop
    Scenario: A program gets no key release for a shortcut the app handled
      Given a program turns on the Kitty keyboard protocol
      When the user presses and releases a shortcut that the app handles
      Then the program receives neither the press nor the release
      And splitting the terminal while a key is held keeps the program's view of that key

    @desktop
    Scenario: On macOS a program that asks for enhanced reporting gets Ctrl as Ctrl
      Given the user is on macOS
      And a program turns on the Kitty keyboard protocol
      When the user presses "Ctrl+A" in the terminal
      Then the program receives Ctrl+A in the enhanced report

    # Upstream #9867: a synchronized update split across output chunks was painted half-done;
    # the renderer now waits for the end of the update before painting it.
    @backlog @desktop
    Scenario: A program's synchronized screen update appears all at once
      Given a program redraws its screen as one synchronized update
      And the update reaches the terminal in several pieces
      Then the terminal shows the old screen until the update is complete
      And then shows the whole new screen at once

    # Upstream #9867: an update that is never closed is painted after half a second.
    @backlog @desktop @priority-low
    Scenario: A synchronized update that never ends is shown after half a second
      Given a program starts a synchronized update and never ends it
      When half a second passes
      Then the terminal shows what the program has drawn so far

  Rule: File locations in compiler output are links

    # Upstream #13408: the colon that ends a compiler's location is not part of the path.
    @desktop @backlog
    Scenario Outline: Ctrl-clicking a compiler's file location opens that file at its line and column
      Given the shell prints "<output>"
      When the user Ctrl-clicks the file location
      Then "<file>" opens in the editor at line <line>, column <column>

      Examples:
        | output                                | file        | line | column |
        | ./main.go:10:5: undefined: x          | ./main.go   | 10   | 5      |
        | /src/main.c:10:5: error: expected ';' | /src/main.c | 10   | 5      |

    # Upstream #20264: terminal links keep Unicode file paths intact.
    @backlog @desktop
    Scenario: A file location with non-ASCII characters opens the whole path
      Given the shell prints "./src/café/menü.ts:3:1: error"
      When the user Ctrl-clicks the file location
      Then "./src/café/menü.ts" opens in the editor at line 3, column 1
