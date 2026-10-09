# Sources:
#   docs/user/keybindings.md (Desktop quit shortcut, mod+w)
#   apps/web/src/components/QuitHoldOverlay.tsx
#   apps/desktop/src/window/QuitHold.ts
#   apps/desktop/src/window/DesktopApplicationMenu.ts (Settings..., View zoom items, Quit)
#   apps/desktop/src/window/DesktopWindow.ts (zoomMain)
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
    @desktop
    Scenario: The window controls stay in the window's corner
      Given the user is on Linux
      And the right panel and the thread details are open
      Then the window controls end at the window's right edge
      When the user closes the thread details
      Then the window controls have not moved
      And nothing of the right panel is under them

    @desktop
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
