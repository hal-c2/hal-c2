# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/DefaultShell.qml
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (sidebarCollapsed, settingsActive)
#   apps/desktop-qt/src/native/LayoutController.cpp (sidebar.toggle, remembered on the device)
#   apps/desktop-qt/qml/HalC2/Bricks/Workspace.qml (header strip: run action, open in editor, git actions)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (workspace.runScript, workspace.openInEditor)
#   apps/desktop-qt/qml/HalC2/Bricks/RightPanel.qml
#   apps/desktop-qt/qml/HalC2/Bricks/ThreadDetailsPanel.qml (threadPanel.toggle)
#   apps/desktop-qt/src/native/RightPanelController.cpp (tabs, open, canAdd; the Pull requests and Previews tabs)
#   apps/desktop-qt/tests/native/features/PanelSteps.cpp
#   apps/desktop-qt/tests/native/features/HeaderSteps.cpp (the header brick laid out offscreen)
#   apps/desktop-qt/tests/native/features/TerminalSteps.cpp (terminal drawer, right panel terminal tabs)
#   apps/desktop-qt/qml/HalC2/Bricks/TerminalPanel.qml
#   apps/desktop-qt/src/native/TerminalController.cpp (terminal.toggle, panel groups)
#   apps/desktop-qt/tests/tst_Workspace.qml
#   apps/desktop-qt/tests/tst_RightPanel.qml (native bodies kept while hidden)
#   apps/desktop-qt/tests/native/tst_ShellExamples.cpp, tst_ShellRuntime.cpp (DefaultShell, user shells)
#   apps/desktop-qt/tests/native/features/LayoutSteps.cpp
#   apps/web/src/components/AppSidebarLayout.tsx (sidebar width)
#   apps/web/src/components/threadSidebarWidth.ts
#   apps/web/src/components/preview/RightPanelResizeHandle.tsx
#   apps/web/src/components/RightPanelTabs.tsx
#   apps/web/src/components/chat/PanelLayoutControls.tsx
#   packages/contracts/src/keybindings.ts (sidebar.toggle, rightPanel.toggle, rightPanel.close,
#   rightPanel.toggleMaximized, threadPanel.toggle, terminal.toggle)
#   docs/internals/desktop-qt.md (ricing contract, bricks)

Feature: Layout: sidebar, header, right panel and drawer
  The window is a thread list beside the thread, with a header above it, a terminal drawer
  below it and a right panel of tabs. Each part can be shown, hidden and sized.

  Background:
    Given the user is looking at a thread

  Rule: Sidebar

    @desktop
    Scenario: Hiding the sidebar
      Given the sidebar is shown
      When the user toggles the sidebar
      Then the sidebar is hidden

    @desktop
    Scenario: Showing the sidebar again from the header
      Given the sidebar is hidden
      When the user asks to show the sidebar
      Then the sidebar is shown

    @desktop
    Scenario: The sidebar shortcut hides and shows the sidebar
      Given the sidebar is shown
      When the user presses the sidebar shortcut
      Then the sidebar is hidden
      When the user presses the sidebar shortcut
      Then the sidebar is shown

    @desktop
    Scenario: A hidden sidebar stays hidden after a restart
      Given the sidebar is hidden
      When the desktop quits and starts again
      Then the sidebar is hidden

    @desktop
    Scenario: Settings replace the thread list with the settings sections
      When the user opens settings
      Then the thread list is hidden
      And the settings sections are shown in its place

    @desktop
    Scenario: The sidebar snaps rather than animating its width
      When the user toggles the sidebar
      Then the thread view is resized once, not on every frame

    @desktop
    Scenario: Resizing the sidebar is remembered
      When the user drags the sidebar to a new width
      And the user restarts the app
      Then the sidebar has the width the user chose

    @desktop
    Scenario: The sidebar cannot be narrower than its minimum or wider than the window allows
      When the user drags the sidebar narrower than its minimum
      Then the sidebar stops at its minimum width
      When the window becomes narrower than the sidebar allows
      Then the sidebar shrinks to fit

    @desktop
    Scenario: Resetting the sidebar width
      Given the user resized the sidebar
      When the user resets the sidebar width
      Then the sidebar returns to its default width

  Rule: Header

    @desktop
    Scenario: The header names the project and thread
      Then the header shows the project name and the thread title

    # The web never says "No thread": with no thread open it lands on a draft, and its header
    # belongs to the thread. The desktop now lands on a draft like the web
    # (navigation/landing.feature, navigation/header.feature: Leaving the thread lands on a new
    # draft in the most recent project).
    @dropped @desktop
    Scenario: The header says when there is no thread
      Given no thread is open
      Then the header says "No thread"

    @desktop
    Scenario: Choosing the project in the header starts a new thread there
      When the user chooses the project name in the header
      Then a new thread starts in that project

    @desktop
    Scenario: The thread title uses the room it has
      Given a long thread title
      When the window is wide
      Then the whole title is shown
      When the header is narrow
      Then the title is shortened with an ellipsis

    @desktop
    Scenario: A narrow header drops action labels
      When the window is narrower than 720 pixels
      Then the header actions show without their labels

    @desktop
    Scenario: The header runs the project's action the user ran last
      Given the thread's project has the actions "Dev" and "Test"
      And the user last ran "Test"
      When the user runs the action offered in the header
      Then "Test" runs for the thread's workspace

    @desktop
    Scenario: The header runs any of the project's actions
      Given the thread's project has the actions "Dev" and "Test"
      When the user picks "Dev" from the header's actions
      Then "Dev" runs for the thread's workspace

    @desktop
    Scenario: The header offers no action to run when the project has none
      Given the thread's project has no actions
      Then the header offers no action to run

    @desktop
    Scenario: The header opens the thread's workspace in the preferred editor
      Given the user has picked "VS Code" as their preferred editor
      When the user opens the thread's workspace from the header
      Then "VS Code" opens the thread's workspace folder

    @desktop
    Scenario: The header opens the thread's workspace in another editor
      Given the environment has the editors "VS Code" and "Zed"
      When the user opens the thread's workspace in "Zed" from the header
      Then "Zed" opens the thread's workspace folder
      And "Zed" becomes the preferred editor

    @desktop
    Scenario: The header prefers the host's default editor until the user picks another
      Given the environment has the editors "Zed" and "Default Editor"
      Then the header lists the editors "Default Editor" and "Zed"
      And "Default Editor" is the editor offered first
      When the user opens the thread's workspace from the header
      Then "Default Editor" opens the thread's workspace folder

    @desktop
    Scenario: The header offers no editor when the environment has none
      Given the environment has no editors
      Then the header does not offer to open the workspace in an editor

    @desktop
    Scenario: The thread's git actions are in the header
      When the user opens the git actions from the header
      Then the thread's git actions are offered

  Rule: Right panel

    @desktop
    Scenario: Opening and closing the right panel
      Given the right panel is closed
      When the user toggles the right panel
      Then the right panel is open
      When the user toggles the right panel
      Then the right panel is closed

    @desktop
    Scenario: Switching between right panel tabs
      Given the right panel has "Diff" and "Files" tabs
      When the user switches to "Files"
      Then the "Files" tab is active

    @desktop
    Scenario: Closing a right panel tab
      Given the right panel has "Diff" and "Files" tabs
      When the user closes the "Diff" tab
      Then only the "Files" tab remains

    @desktop
    Scenario Outline: Adding a tab to the right panel
      Given the thread can show <kind>
      When the user adds a <kind> tab to the right panel
      Then a <kind> tab opens in the right panel

      Examples:
        | kind         |
        | diff         |
        | files        |
        | agents       |
        | terminal     |
        | pull request |
        | previews     |

    @desktop
    Scenario: A tab kind that the thread cannot show is not offered
      Given the thread has no pull request
      When the user looks at what can be added to the right panel
      Then pull request cannot be added
      And the Add menu says "This thread's branch has no pull request yet." for pull request

    @desktop
    Scenario: Right panel contents survive closing the panel
      Given a terminal tab in the right panel has output
      When the user closes the right panel and opens it again
      Then the terminal tab still has its output

    @desktop
    Scenario: Right panel contents survive a visit to settings
      Given the right panel shows a scrolled diff
      When the user opens settings and comes back
      Then the diff is at the same scroll position

    @desktop
    Scenario: A hidden right panel does no work
      When the user closes the right panel
      Then the right panel stops updating until it is opened again

    @desktop
    Scenario: Resizing the right panel
      Given the right panel is open
      When the user drags the right panel's edge
      Then the right panel takes the new width

    @desktop
    Scenario: Maximizing the right panel
      Given the right panel is open
      When the user toggles the right panel to fill the window
      Then the right panel covers the thread
      When the user toggles it again
      Then the thread is shown beside the right panel

    @desktop
    Scenario: The right panel's tabs and width survive a restart
      Given the right panel has "Diff" and "Files" tabs
      And the user switches to "Files"
      And the user drags the right panel's edge
      When the desktop quits and starts again
      And the user is looking at a thread
      Then the "Files" tab is active
      And the right panel takes the new width

    @desktop
    Scenario: Toggling the thread details panel
      When the user toggles the thread details panel
      Then the thread details panel is shown

    @desktop
    Scenario: Hiding the thread details panel
      Given the thread details panel is shown
      When the user toggles the thread details panel
      Then the thread details panel is hidden

    @desktop
    Scenario: The thread details panel leads to the thread it was forked from
      Given the thread was forked from "Planning"
      And the thread details panel is shown
      Then the thread details panel names "Planning" as the thread it was forked from
      When the user opens the related thread "Planning"
      Then the thread "Planning" is open

  Rule: Terminal drawer

    @desktop
    Scenario: Showing the terminal from the header
      Given the terminal is hidden
      When the user shows the terminal
      Then the terminal drawer opens under the thread

    @desktop
    Scenario: Hiding the terminal
      Given the terminal is shown
      When the user hides the terminal
      Then the terminal drawer closes
      And its terminals keep running

  Rule: Rearranging the shell

    @desktop
    Scenario: A user's own shell layout replaces the default
      Given the user wrote their own shell layout in the HAL-C2 home
      When the app starts
      Then the app uses the user's layout

    @desktop
    Scenario: A user's own shell layout still answers the agent
      Given the app is using the user's own shell layout
      And that layout shows the composer
      When the agent asks the user a question
      Then the question and its options show on the composer

    @desktop
    Scenario: A broken shell layout falls back to the default
      Given the user's own shell layout has an error
      When the app starts
      Then the default layout is used
      And the error is shown to the user

    @desktop
    Scenario: A shell layout change applies without restarting
      Given the app is using the user's own shell layout
      When the user saves a change to it
      Then the window reloads the layout
