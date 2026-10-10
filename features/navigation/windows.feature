# Sources:
#   apps/web/src/contextMenuFallback.ts (dismissal, one menu at a time, clamping, submenus, disabled and destructive entries)
#   docs/user/keybindings.md (Desktop quit shortcut, mod+w)
#   apps/web/src/components/QuitHoldOverlay.tsx
#   apps/desktop/src/window/QuitHold.ts
#   apps/desktop/src/window/DesktopApplicationMenu.ts (Settings..., View zoom items, Quit)
#   apps/desktop/src/window/DesktopWindow.ts (zoomMain, saved bounds and maximized state, minimum size, native context menu, held close shortcut)
#   apps/desktop/src/app/DesktopClerk.ts (single-instance lock, second launch reveals the window)
#   apps/desktop/src/electron/ElectronShell.ts (parseSafeExternalUrl: which links may leave the app)
#   apps/desktop/src/settings/DesktopAppSettings.ts (default and minimum window size)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (window commands, title from `route`)
#   apps/desktop-qt/src/native/NavigationController.cpp (the route's title)
#   apps/desktop-qt/qml/HalC2/Bricks/TitleBar.qml
#   apps/desktop-qt/qml/HalC2/Bricks/WindowControls.qml
#   apps/desktop-qt/src/native/NativeShell.cpp (window.new, per-window state)
#   apps/desktop-qt/src/ShellWindows.cpp (closing one window)
#   apps/desktop/src/app/DesktopLifecycle.ts (quit on the last window, except macOS; activate reopens)
#   apps/desktop-qt/tests/tst_ShellWindow.qml (a window's title and minimum size, the zoomed body, a menu at the pointer)
#   apps/desktop-qt/src/native/LayoutController.cpp (the app zoom)
#   apps/desktop-qt/src/native/QuitController.cpp (the quit shortcut; Quit is the palette's app.quit)
#   apps/desktop-qt/qml/HalC2/Bricks/Workspace.qml (frameless drag and maximize)
#   apps/desktop-qt/tests/tst_WindowControls.qml (the header asks the system to move the window)
#   apps/desktop-qt/src/ThemeStore.cpp (the theme's window frame and opacity)

Feature: Windows, zoom and quitting
  The desktop app draws its own window frame, can open more than one window, zooms its
  content, and guards against quitting by accident.

  Rule: Window controls

    @desktop
    Scenario Outline: The window controls act on the window
      When the user chooses <control> in the window controls
      Then the window <result>

      Examples:
        | control  | result                                 |
        | Minimize | is minimized                           |
        | Maximize | is maximized                           |
        | Close    | closes                                 |

    @desktop
    Scenario: Maximize restores a maximized window
      Given the window is maximized
      When the user chooses Maximize in the window controls
      Then the window returns to its previous size

    @desktop
    Scenario Outline: Window controls follow the platform's order and side
      Given the user is on <platform>
      Then the window controls are on the <side> in the order <order>

      Examples:
        | platform | side  | order                     |
        | macOS    | left  | close, minimize, maximize |
        | Linux    | right | minimize, maximize, close |
        | Windows  | right | minimize, maximize, close |

    # The window's, not one page's header: where the old Electron window's
    # titleBarOverlay had them (apps/desktop/src/window/DesktopWindow.ts).
    # Proved by tst_ShellExamples.cpp (defaultShellKeepsTheWindowButtonsInTheCorner), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: The window controls stay in the window's corner
      Given the user is on Linux
      And the right panel and the thread details are open
      Then the window controls end at the window's right edge
      When the user closes the thread details
      Then the window controls have not moved
      And nothing of the right panel is under them

    # Proved by tst_ShellExamples.cpp (defaultShellHasTheWindowButtonsOnEveryPage), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario Outline: The window controls are on every page
      Given the user is on Linux
      When the user opens <page>
      Then the window controls are in the window's top right corner
      And the window can be dragged by the band they are in

      Examples:
        | page                        |
        | a thread                    |
        | the home page               |
        | Pull requests               |
        | Usage                       |
        | Settings                    |
        | a maximized right panel     |
        | a plugin's page             |

    @desktop
    Scenario: macOS controls show their symbols only on hover
      Given the user is on macOS
      When the pointer is over the window controls
      Then the controls show their symbols

    @desktop
    Scenario: macOS controls turn grey in an inactive window
      Given the user is on macOS
      When another app's window is active
      Then the window controls are grey

    # The window system does the moving; offscreen tests can only see the ask.
    @desktop
    Scenario: Dragging the header asks the window system to move the window
      When the user drags an empty part of the header
      Then the window asks the window system to move it

    @desktop
    Scenario: Double-clicking the header toggles maximize
      Given the window is not maximized
      When the user double-clicks an empty part of the header
      Then the window is maximized

    @desktop
    Scenario: A theme can ask for the system window frame
      Given the shell theme turns off the frameless window
      When the app starts
      Then the window has the system's own frame

    @desktop
    Scenario: A theme can make the window translucent
      Given the shell theme sets the window opacity to 0.9
      Then the window is drawn at that opacity

    # Legacy: apps/desktop/src/window/DesktopWindow.ts (render-process-gone recovery)
    @backlog @desktop
    Scenario: A window whose page crashes comes back by itself
      Given a thread is open in the window
      When the window's page crashes or runs out of memory
      Then the window reloads itself after a moment
      And the thread comes back from the MC with its work still running

    @backlog @desktop
    Scenario: A window that keeps crashing stops reloading itself
      Given the window's page has crashed and reloaded three times within a minute
      When the page crashes a fourth time within that minute
      Then the window is not reloaded again

    # Legacy: apps/desktop/src/window/DesktopWindow.ts (bounds persistence when the saved position cannot be restored)
    @backlog @desktop
    Scenario: A saved position that could not be restored is kept until the user moves the window
      Given the first window was left on a screen that is no longer connected
      When the app starts and the window opens at its default size
      Then the saved position is kept
      When the user moves or resizes the window
      Then the new position is saved

  Rule: More than one window

    @desktop
    Scenario: A second window works on its own
      Given the user's shell layout opens a second window
      When the user opens a thread in the second window
      Then the first window still shows its own thread

    @desktop
    Scenario: Every window shows a backend failure
      Given a second window is open
      When the backend fails
      And the user opens a third window
      Then every window shows the failure

    # Every window reads the one SettingsController; there is no page per window to tell.
    @dropped
    Scenario: Every window's page follows this device's settings
      Given a second window is open
      When the user changes a device setting
      Then every window's page follows the change
      When the second window's page reloads
      Then only the second window's page is told this device's settings

    @desktop
    Scenario: A setting that fails to save says so in the window that changed it
      Given a second window is open
      And the MC refuses to save settings
      When the user changes an MC setting in the second window and goes back to the first
      Then the second window says "Setting not saved"
      And the first window shows no toast

    @desktop
    Scenario: Closing a second window leaves the first alone
      Given a second window is open
      When the user closes the second window
      Then the first window stays open on the same thread

    @desktop
    Scenario: Closing the first window leaves the others open
      Given a second window is open
      When the user closes the first window
      Then the second window is still open on its own thread
      And the app is still running
      When the user restarts the app
      Then only the second window reopens

    # Linux and Windows. On macOS the app stays in the dock (main.cpp), as the
    # Electron desktop did; see the next scenario.
    @desktop
    Scenario: Closing the last window quits
      Given a second window is open
      When the user closes the second window
      And the user closes the first window
      Then the app quits

    # main.cpp reopens the window when the app is activated again, but the
    # scenarios run on Linux and cannot drive macOS's dock.
    @desktop @backlog-desktop
    Scenario: On macOS closing the last window keeps the app in the dock
      Given the user is on macOS
      And the user closed the last window
      When the user clicks the app in the dock
      Then the window opens again

    @desktop
    Scenario: Closing a window keeps its unsent work
      Given a second window is open
      And the user has unsent work in the second window
      When the user closes the second window
      Then the first window has that unsent work

    @desktop
    Scenario: Closing a window while it waits on the MC
      Given a second window is open
      And the second window is waiting on the MC
      When the user closes the second window
      And the MC answers what the closed window asked
      Then the first window stays open on the same thread
      And the MC no longer sends the closed window anything

    @desktop
    Scenario: Windows share the sign-in but not the navigation
      Given a second window is open
      Then the second window is signed in to the same environments
      And navigating in one window does not navigate the other

    # Drafts are the app's, not a window's: every window sees the same ones.
    @desktop
    Scenario: A window restores its drafts and panels after a restart
      Given a second window with a stable identity has a draft and an open panel
      When the user restarts the app
      Then that window has the same draft and panel

    @desktop
    Scenario: A window keeps its files in its own folder
      When the shell is asked for a second window with the id "../../outside"
      Then the second window keeps its files in its own folder

    @desktop
    Scenario: A restart skips a saved window that names another folder
      Given the saved windows are "../outside" and "kept"
      When the user restarts the app
      Then only the window "kept" reopens beside the first

    @desktop
    Scenario: A window has a sensible title and size
      Given a second window shows no thread yet
      Then its title is "HAL-C2"
      And it cannot be made smaller than 640 by 400

    @backlog @desktop
    Scenario: The first window opens at a comfortable size it cannot shrink below
      Given the user has never resized the window
      When the app starts
      Then the first window opens at 1100 by 780
      And it cannot be made smaller than 840 by 620

    @backlog @desktop
    Scenario: The first window remembers its size and position across restarts
      Given the user moved and resized the first window
      When the user restarts the app
      Then the first window opens where and as large as it was left

    @backlog @desktop
    Scenario: A maximized first window is maximized again after a restart
      Given the user maximized the first window
      When the user restarts the app
      Then the first window opens maximized

    @backlog @desktop
    Scenario: A saved position that is no longer on any screen is not used
      Given the first window was left on a screen that is no longer connected
      When the user restarts the app
      Then the first window opens at its default size on a connected screen

    # Electron's single-instance lock (DesktopClerk.ts); the Qt app's own lock decision is the maintainers'.
    @backlog @desktop
    Scenario: Starting the app again brings the open window forward
      Given the app is already running
      When the user starts the app a second time
      Then no second copy of the app runs
      And the open window is shown in front, restored if it was minimized

    @backlog @desktop
    Scenario: Holding the close shortcut closes one window, not all of them
      Given three windows are open
      When the user holds mod+w so that it repeats
      Then only the window in front closes
      And the others stay open

  Rule: Zoom

    @desktop
    Scenario Outline: Zooming the app
      When the user presses <key>
      Then the app content is <result>

      Examples:
        | key    | result  |
        | mod+=  | larger  |
        | mod++  | larger  |
        | mod+-  | smaller |

    @desktop
    Scenario: Actual size undoes the zoom
      Given the app is zoomed in
      When the user presses mod+0
      Then the app content is back to its actual size

    @desktop
    Scenario: Every window follows the app's zoom
      Given a second window is open
      When the user presses mod+=
      Then the second window's content is larger too

    # The Qt desktop embeds no preview browser (PreviewsPanel opens tabs in the
    # user's browser), so it has no preview zoom for the app's to disturb.
    @backlog @desktop
    Scenario: Zooming the app keeps the preview's own zoom
      Given the preview is zoomed to 125 percent
      When the user zooms the app in
      Then the preview is still at 125 percent

    @desktop
    Scenario: Context menus follow the zoomed app
      Given the app is zoomed in
      When the user opens a context menu
      Then the menu appears at the pointer

    # The web app drew these itself when no desktop shell was present
    # (apps/web/src/contextMenuFallback.ts); the Qt shell's menus must keep the same rules.
    @backlog @desktop
    Scenario Outline: A context menu closes without choosing anything
      Given a context menu is open
      When the user <closes it>
      Then the menu closes
      And no entry is chosen
      And focus returns to where it was before the menu opened

      Examples:
        | closes it                              |
        | presses Escape                         |
        | clicks outside the menu                |
        | opens a context menu somewhere else    |

    @backlog @desktop
    Scenario: Only one context menu is open at a time
      Given a context menu is open
      When the user opens a context menu elsewhere
      Then the first menu closes
      And only the second menu is shown

    # Likely already implemented: apps/desktop-qt/qml/HalC2/Bricks/ContextMenuHost.qml
    @backlog @desktop
    Scenario: A context menu opened near the edge stays inside the window
      Given the pointer is at the bottom right corner of the window
      When the user opens a context menu
      Then the whole menu is visible inside the window with a small margin

    # ContextMenuHost.qml flattens a submenu into a labelled section instead of
    # opening one; maintainer decision whether that replaces this scenario.
    @backlog @desktop
    Scenario: A submenu opens beside its entry and flips when there is no room
      Given a context menu with a submenu
      When the user hovers or clicks the submenu's entry
      Then the submenu opens beside it
      And where there is no room on that side it opens on the other

    # Likely already implemented: apps/desktop-qt/qml/HalC2/Bricks/ContextMenuHost.qml
    @backlog @desktop
    Scenario: Disabled entries cannot be chosen and destructive ones are marked
      Given a context menu with a disabled entry and a destructive entry
      When the user clicks the disabled entry
      Then nothing happens and the menu stays open
      And the destructive entry is visibly marked as destructive

    @backlog @desktop
    Scenario: A context menu closes when what it was about changes
      Given a context menu is open on a terminal selection
      When the selection is cleared
      Then the menu closes with nothing chosen

    # The Electron desktop's native context menu (DesktopWindow.ts).
    @backlog @desktop
    Scenario: A misspelled word offers corrections in its context menu
      Given the user typed a misspelled word in a text field
      When the user opens the context menu on the word
      Then up to five spelling suggestions are offered
      And choosing one replaces the word

    @backlog @desktop
    Scenario: A misspelled word with no corrections says so
      Given the user typed a word the spell checker has no suggestion for
      When the user opens the context menu on the word
      Then the menu says there are no suggestions
      And that entry cannot be chosen

    @backlog @desktop
    Scenario Outline: A text field's context menu offers only what can be done
      Given <situation>
      When the user opens the context menu in the text field
      Then <entry> is available
      And the entries that do not apply cannot be chosen

      Examples:
        | situation                                        | entry        |
        | some text is selected in an editable field       | cut and copy |
        | text is selected in read-only text               | copy         |
        | the clipboard holds text and the field is empty  | paste        |

    @backlog @desktop
    Scenario: A link's context menu can copy the link
      Given the conversation shows a link
      When the user opens the context menu on the link
      Then the user can copy the link address

    @backlog @desktop
    Scenario: An image's context menu can copy the image
      Given the conversation shows an image
      When the user opens the context menu on the image
      Then the user can copy the image

    @backlog @desktop
    Scenario Outline: A link leaves the app only when it is safe to open
      Given the conversation shows a link to <address>
      When the user opens the link
      Then <result>

      Examples:
        | address                                              | result                                           |
        | an https or http page                                | it opens in the system browser                   |
        | an ssh remote folder in VS Code or Zed               | it opens in that editor                          |
        | an address with a user name and password in it       | nothing opens                                    |
        | a file path or a script address                      | nothing opens                                    |

    @backlog @desktop
    Scenario: A link never replaces the app's own page
      Given the conversation shows a link to a web page
      When the user opens the link
      Then the page opens outside the app
      And the app's window keeps showing HAL-C2

  Rule: Quitting and the application menu

    @desktop
    Scenario: Holding the quit shortcut quits
      Given the quit shortcut is set to Hold
      When the user holds mod+Q for 1.2 seconds
      Then the app quits

    @desktop
    Scenario: Pressing the quit shortcut twice quits
      Given the quit shortcut is set to Hold
      When the user presses mod+Q twice within 500 milliseconds
      Then the app quits

    @desktop
    Scenario: A single quick press does not quit
      Given the quit shortcut is set to Hold
      When the user presses mod+Q once
      Then the app keeps running
      And the user is told to hold the shortcut or press twice to quit

    @desktop
    Scenario: Double press mode asks for a second press
      Given the quit shortcut is set to Double press
      When the user presses mod+Q once
      Then the user is told to press the shortcut again to quit

    @desktop
    Scenario: Direct mode quits on one press
      Given the quit shortcut is set to Direct
      When the user presses mod+Q
      Then the app quits

    # Legacy: apps/desktop/src/window/QuitHold.ts (other keys, concealed window, unreadable setting)
    @backlog @desktop
    Scenario: Pressing another key cancels a quit in progress
      Given the quit shortcut is set to Hold
      And the user is holding mod+Q
      When the user presses another key
      Then the app keeps running
      And a following single press of mod+Q starts over

    @backlog @desktop
    Scenario: A held quit hides the window until the shortcut is released
      Given the quit shortcut is set to Hold
      When the user has held mod+Q long enough to quit
      Then the window disappears at once
      And the repeats of the held keys do not reach the next application

    @backlog @desktop
    Scenario: The quit shortcut quits even when its setting cannot be read
      Given the quit shortcut setting cannot be read
      When the user presses mod+Q
      Then the app quits

    @desktop
    Scenario: Quit from the command palette is immediate
      Given the quit shortcut is set to Hold
      When the user chooses Quit from the command palette
      Then the app quits

    # The Electron desktop's application menu had Quit
    # (DesktopApplicationMenu.ts); the Qt desktop has no application menu yet,
    # so only the palette's app.quit quits at once.
    @desktop @backlog-desktop
    Scenario: Quit from the application menu is immediate
      Given the quit shortcut is set to Hold
      When the user chooses Quit from the application menu
      Then the app quits

    @desktop
    Scenario: The settings shortcut opens settings
      When the user presses mod+,
      Then settings open

  Rule: The window is titled after what it shows

    Background:
      Given the time is "2026-09-23T10:00:00Z"
      And the desktop's MC "mc-a" serves the environment "env-a"
      And the MC has these threads:
        | id | project | title  | createdAt            |
        | t1 | p1      | First  | 2026-09-23T09:50:00Z |
        | t2 | p1      | Second | 2026-09-23T09:40:00Z |
      And the MC has the project "p1" titled "proj-1"
      And the desktop shell is connected to its MC

    @desktop
    Scenario: The window title follows the thread's title
      Given the user opens "env-a:t1" from the sidebar
      When the MC updates the thread "t1" with the title "Renamed"
      Then the window is titled "Renamed"
