# Sources:
#   apps/tui/src/components/ChatView.layout.ts (column and row allocation)
#   apps/tui/src/components/ChatView.layout.test.ts
#   apps/tui/src/components/Sidebar.tsx, Sidebar.logic.ts
#   apps/tui/src/components/RightPanel.tsx
#   apps/tui/src/components/ComposerDock.tsx, ComposerDock.test.tsx (centred, bounded prompt)
#   apps/tui/src/format.ts (clip and pad by display width)
#   Shared domain: navigation/ owns layout on the other surfaces.

Feature: Terminal layout at every size
  The conversation stays usable first. Sidebars, panels, the prompt and the terminal drawer
  only take the room left over, and the layout follows the terminal as it resizes.

  @tui
  Scenario: A wide terminal docks the thread list at full height
    Given the terminal is 140 columns wide
    Then the thread list is docked beside the conversation at full height

  @tui
  Scenario: A narrow terminal collapses the thread list before squeezing the conversation
    Given the terminal is 70 columns wide
    Then the thread list is hidden
    And the conversation takes the full width

  @tui
  Scenario: Filtering threads on a narrow terminal opens the list over the conversation
    Given the terminal is 70 columns wide
    When the user presses "Ctrl+F"
    Then the thread list opens over the conversation with the filter focused

  @tui
  Scenario: Closing the filter on a narrow terminal returns to the conversation
    Given the thread list is open over the conversation on a narrow terminal
    When the user presses "Esc"
    Then the thread list closes and the conversation has the full width again

  @tui
  Scenario: A detail panel docks beside the conversation when there is room
    Given the terminal is 160 columns wide
    When the user opens the source-control panel
    Then the panel sits beside the conversation

  @tui
  Scenario: A detail panel replaces the conversation when the main column is narrow
    Given the terminal is 90 columns wide
    When the user opens the source-control panel
    Then the panel replaces the conversation until it is closed

  @tui
  Scenario: The conversation column is capped on very wide terminals
    Given the terminal is 300 columns wide
    Then the conversation and prompt are no wider than 96 columns and centred

  @tui
  Scenario: Resizing the terminal re-lays out without leaving stale rows
    Given the terminal client is open at 140 by 40
    When the terminal is resized to 80 by 24
    Then every pane is redrawn inside the new size
    And no text is left from the previous layout

  @tui
  Scenario: An empty prompt starts at a comfortable multi-line height
    Given the prompt is empty
    Then the prompt shows 3 editable rows

  @tui
  Scenario: A long prompt grows up to a cap and then scrolls inside itself
    When the user types a prompt longer than 8 wrapped lines
    Then the prompt stops growing at 8 rows
    And the prompt scrolls to keep the cursor visible

  @tui
  Scenario: An open terminal keeps a usable drawer even with a long prompt
    Given the terminal drawer is open
    When the user types a very long prompt on a short terminal
    Then the terminal drawer keeps at least 6 rows
    And the timeline keeps at least 4 rows

  @tui
  Scenario: A popup above an open terminal does not shrink the terminal
    Given the terminal drawer is open at its preferred size
    When a picker opens above the prompt
    Then the terminal drawer keeps its preferred size

  @tui
  Scenario: Wide characters never overflow their column
    Given a thread title that contains emoji and CJK characters
    Then the title is clipped by display width and never pushes other columns out of line
