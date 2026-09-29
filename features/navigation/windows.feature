# Sources:
#   docs/user/keybindings.md (Desktop quit shortcut, mod+w)
#   apps/web/src/components/QuitHoldOverlay.tsx
#   apps/desktop/src/window/QuitHold.ts
#   apps/desktop/src/window/DesktopApplicationMenu.ts (Settings..., View zoom items)
#   apps/desktop/src/window/DesktopWindow.ts (zoomMain)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (window commands, title from `route`)
#   apps/desktop-qt/src/native/NavigationController.cpp (the route's title)
#   apps/desktop-qt/qml/HalC2/Bricks/TitleBar.qml
#   apps/desktop-qt/qml/HalC2/Bricks/WindowControls.qml
#   apps/desktop-qt/qml/HalC2/Bricks/AppWindow.qml
#   apps/desktop-qt/qml/HalC2/Bricks/AppView.qml
#   apps/desktop-qt/src/native/NativeShell.cpp (window.new, per-window state)
#   apps/desktop-qt/tests/tst_ShellWindow.qml (a window's title and minimum size)
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

    @desktop
    Scenario: Dragging the header moves the window
      When the user drags an empty part of the header
      Then the window moves with the pointer

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
    Scenario: Closing a second window leaves the first alone
      Given a second window is open
      When the user closes the second window
      Then the first window stays open on the same thread

    @desktop
    Scenario: Windows share the sign-in but not the navigation
      Given a second window is open
      Then the second window is signed in to the same environments
      And navigating in one window does not navigate the other

    @desktop
    Scenario: A window restores its drafts and panels after a restart
      Given a second window with a stable identity has a draft and an open panel
      When the user restarts the app
      Then that window has the same draft and panel

    @desktop
    Scenario: A window has a sensible title and size
      Given a second window has no page title yet
      Then its title is "HAL-C2"
      And it cannot be made smaller than 640 by 400

  Rule: Zoom

    @backlog @desktop
    Scenario Outline: Zooming the app
      When the user presses <key>
      Then the app content is <result>

      Examples:
        | key    | result                 |
        | mod+=  | larger                 |
        | mod++  | larger                 |
        | mod+-  | smaller                |
        | mod+0  | back to its actual size|

    @backlog @desktop
    Scenario: Zooming the app keeps the preview's own zoom
      Given the preview is zoomed to 125 percent
      When the user zooms the app in
      Then the preview is still at 125 percent

    @backlog @desktop
    Scenario: Context menus follow the zoomed app
      Given the app is zoomed in
      When the user opens a context menu
      Then the menu appears at the pointer

  Rule: Quitting and the application menu

    @backlog @desktop
    Scenario: Holding the quit shortcut quits
      Given the quit shortcut is set to Hold
      When the user holds mod+Q for 1.2 seconds
      Then the app quits

    @backlog @desktop
    Scenario: Pressing the quit shortcut twice quits
      Given the quit shortcut is set to Hold
      When the user presses mod+Q twice within 500 milliseconds
      Then the app quits

    @backlog @desktop
    Scenario: A single quick press does not quit
      Given the quit shortcut is set to Hold
      When the user presses mod+Q once
      Then the app keeps running
      And the user is told to hold the shortcut or press twice to quit

    @backlog @desktop
    Scenario: Double press mode asks for a second press
      Given the quit shortcut is set to Double press
      When the user presses mod+Q once
      Then the user is told to press the shortcut again to quit

    @backlog @desktop
    Scenario: Direct mode quits on one press
      Given the quit shortcut is set to Direct
      When the user presses mod+Q
      Then the app quits

    @backlog @desktop
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
      And the desktop's node "node-a" serves the environment "env-a"
      And the node has these threads:
        | id | project | title  | createdAt            |
        | t1 | p1      | First  | 2026-09-23T09:50:00Z |
        | t2 | p1      | Second | 2026-09-23T09:40:00Z |
      And the node has the project "p1" titled "proj-1"
      And the desktop shell is connected to its node

    @desktop
    Scenario: The window title follows the thread's title
      Given the user opens "env-a:t1" from the sidebar
      When the node updates the thread "t1" with the title "Renamed"
      Then the window is titled "Renamed"
