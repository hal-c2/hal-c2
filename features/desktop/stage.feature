# Sources:
#   apps/desktop-qt/src/native/PanelStage.h (tabs, panes, layouts, focus, the conversation's width)
#   apps/desktop-qt/src/native/RightPanelController.cpp (rightPanel.dock, stage.*, shownTabs, saved per thread)
#   apps/desktop-qt/src/native/Keybindings.cpp (stage.moveTab mod+alt+s, stage.toggleFocus mod+alt+f,
#     stage.showTimeline in the palette)
#   apps/desktop-qt/qml/HalC2/Bricks/Stage.qml (tab strip and its Timeline tab, layout switcher, pane
#     headers, drop zones)
#   apps/desktop-qt/qml/HalC2/Bricks/PanelBodies.qml, PanelBodySlot.qml (one body per kind, moved, never remade)
#   apps/desktop-qt/qml/HalC2/Bricks/ThreadArea.qml (beside the conversation, focus mode, narrow windows)
#   apps/desktop-qt/qml/HalC2/Bricks/CentreHost.qml (the stage in a shell that lays out its own composer)
#   apps/desktop-qt/tests/tst_Stage.qml (the scenarios tagged @backlog-desktop, by name)
#   apps/desktop-qt/tests/native/features/PanelSteps.cpp
#   apps/desktop-qt/tests/prop/tst_RightPanelProp.cpp (the stage's invariants over any command sequence)
#   Desktop only: the phone and the TUI have no room for a second centre and keep the right
#   panel's tabs in their own panel; a tablet stage would be new mobile work.

Feature: The stage: right panel tabs in the thread's centre
  Any tab of the right panel can be brought into the thread's centre, beside the
  conversation or across the centre, where the stage's strip starts with a Timeline tab
  that switches between the timeline and the stage's tabs. The composer always stays. The
  stage shows its tabs in one to four panes, and each thread keeps its own stage.

  Background:
    Given the user is looking at a thread

  Rule: Tabs move between the side panel and the stage

    @desktop
    Scenario: A tab moves to the centre beside the conversation
      Given the right panel has "Diff" and "Files" tabs
      When the user moves the "Diff" tab to the centre
      Then the "Diff" tab is on the stage
      And the right panel shows only the "Files" tab
      And the timeline is shown

    @desktop
    Scenario: Open in centre puts the timeline away
      Given the right panel has "Diff" and "Files" tabs
      And the user switches to "Diff"
      When the user opens the "Diff" tab in the centre
      Then the "Diff" tab is on the stage
      And the timeline is hidden
      When the user shows the timeline again
      Then the timeline shows under the stage's strip
      And the "Diff" tab is on the stage

    # A shell lays out its own centre (CentreHost), which draws the stage. glass-macos
    # has the same centre as glass, with controls only macOS has.
    @desktop
    Scenario Outline: Open in centre shows the tab in any shell
      Given the window is drawn by <shell>
      And the right panel has "Diff" and "Files" tabs
      And the user switches to "Diff"
      When the user opens the "Diff" tab in the centre
      Then the window shows the "Diff" tab in the centre

      Examples:
        | shell                       |
        | the default shell           |
        | the minimal example shell   |
        | the dashboard example shell |
        | the folders example shell   |
        | the glass example shell     |
        | the terminal example shell  |

    @desktop
    Scenario: A tab goes back to the side panel
      Given the "Diff" tab is on the stage
      When the user moves the "Diff" tab to the side panel
      Then the "Diff" tab is in the right panel
      And the stage is empty

    @desktop
    Scenario: Every tab goes back to the side panel at once
      Given the "Diff" and "Files" tabs are on the stage
      When the user moves every stage tab to the side panel
      Then the "Diff" tab is in the right panel
      And the "Files" tab is in the right panel
      And the stage is empty
      And the timeline is shown

    @desktop
    Scenario: The stage's shortcuts move the tab and put the timeline away
      Given no custom keybindings
      And the right panel has "Diff" and "Files" tabs
      And the user switches to "Files"
      When the user presses mod+alt+s
      Then the "Files" tab is on the stage
      When the user presses mod+alt+f
      Then the timeline is hidden
      When the user presses mod+alt+s
      Then the "Files" tab is in the right panel
      And the timeline is shown

  Rule: The stage shows its tabs in one to four panes

    @desktop
    Scenario: Dropping a tab at a pane's edge splits it
      Given the "Diff" tab is on the stage
      And the right panel has a "Files" tab
      When the user drops the "Files" tab at the right edge of the stage's first pane
      Then the stage shows "Diff" and "Files" side by side

    @desktop
    Scenario Outline: The stage has a layout for one, two or four panes
      Given the "Diff" and "Files" tabs are on the stage
      When the user chooses the <layout> layout
      Then the stage has <panes> panes

      Examples:
        | layout  | panes |
        | single  | 1     |
        | columns | 2     |
        | rows    | 2     |
        | grid    | 4     |

    # Proved by tst_Stage.qml (test_anEmptyPaneOffersTheStagesTabs), not yet by a step.
    @desktop @backlog-desktop
    Scenario: An empty pane offers the tabs no pane shows
      Given the "Diff" tab is on the stage in a grid
      Then each empty pane offers the "Files" tab to show there

    # Proved by tst_Stage.qml (test_aTabDragsIntoAnEmptyCentre, test_aTabDragsBetweenThePanelAndTheStage), not yet by a step.
    @desktop @backlog-desktop
    Scenario: Tabs drag between the side panel and the stage
      Given the right panel is open
      When the user drags a tab from the right panel onto the stage
      Then the tab shows on the stage with what it showed before
      When the user drags it back onto the right panel
      Then it shows in the right panel again

  Rule: A tab on the stage keeps working

    @desktop
    Scenario: A tab on the stage works while the right panel is closed
      Given the diff of the latest turn is on the stage
      And the right panel is closed
      When the agent finishes another turn
      Then the stage's diff shows that turn

    # Proved by tst_Stage.qml (test_aBodyMovesWithoutBeingRemade), not yet by a step.
    @desktop @backlog-desktop
    Scenario: A tab keeps what it shows when it moves
      Given the Files tab shows a file scrolled half way
      When the user moves the tab to the centre and back
      Then the file is still open at the same place

  Rule: Across the centre, the strip switches between the timeline and the tabs

    @desktop
    Scenario: The Timeline tab switches quickly between the timeline and a tab
      Given no custom keybindings
      And the "Diff" tab is on the stage
      And the timeline is hidden
      When the user chooses the Timeline tab
      Then the timeline shows under the stage's strip
      When the user chooses the "Diff" tab on the stage's strip
      Then the timeline is hidden
      And the "Diff" tab is on the stage
      When the user chooses the Timeline tab
      And the user presses mod+alt+f
      Then the timeline is shown
      And the "Diff" tab is on the stage

    # Proved by tst_Stage.qml (test_theTimelineTabShowsTheTimelineUnderTheStrip), not yet by a step.
    @desktop @backlog-desktop
    Scenario: The strip stays over the timeline
      Given the "Diff" tab fills the thread's centre
      When the user chooses the Timeline tab
      Then the timeline fills the centre under the stage's strip
      And the strip shows the Timeline tab chosen

    # Proved by tst_Stage.qml (test_focusModeKeepsTheComposerUnderTheLatestActivity), not yet by a step.
    @desktop @backlog-desktop
    Scenario: The latest activity shows over the composer while a tab fills the centre
      Given a tab fills the thread's centre
      When the agent writes a line
      Then a one-line strip above the composer shows it
      When the user clicks the strip
      Then the timeline shows under the stage's strip

    # Proved by tst_Stage.qml (test_aNarrowWindowShowsOneAtATime), not yet by a step.
    @desktop @backlog-desktop
    Scenario: A narrow window keeps the stage across the centre
      Given the window leaves the thread less than 721 pixels
      And the "Diff" tab is on the stage
      Then the stage's strip shows over the timeline with the Timeline tab chosen
      When the user chooses the "Diff" tab on the stage's strip
      Then the stage shows above the composer
      And a one-line strip above the composer offers the timeline back

  Rule: Each thread keeps its stage

    @desktop
    Scenario: The stage survives a visit to settings
      Given the "Diff" tab is on the stage
      And the timeline is hidden
      When the user opens settings and comes back
      Then the "Diff" tab is on the stage
      And the timeline is hidden

    @desktop
    Scenario: The stage survives a restart
      Given the "Diff" and "Files" tabs are on the stage
      And the user chooses the columns layout
      And the timeline is hidden
      When the desktop quits and starts again
      And the user is looking at a thread
      Then the stage shows "Files" and "Diff" side by side
      And the timeline is hidden

    @desktop
    Scenario: Resizing the conversation beside the stage
      Given the "Diff" tab is on the stage
      When the user drags the divider between the conversation and the stage
      Then the conversation keeps the width it was dragged to
      When the user double-clicks the divider
      Then the conversation is back to its default width
