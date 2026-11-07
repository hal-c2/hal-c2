# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/ShellSwitch.qml, ShellCheckBox.qml, ShellSpinBox.qml,
#     ShellTextField.qml, ShellComboBox.qml, ShellMenu.qml, ContextMenuHost.qml (the shared controls)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellToolTip.qml (every attached tooltip's look)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellPopoverSurface.qml (menus, the palette, pickers, dialogs)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellButton.qml, src/ThemeStore.cpp (the destructive fill)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellScrollEdge.qml (the edge of a list that goes on)
#   apps/web/src/components/ui/switch.tsx, checkbox.tsx, number-field.tsx, input.tsx, select.tsx
#   Proved today by apps/desktop-qt/tests/tst_Shell*.qml and tests/native/tst_ShellRuntime.cpp;
#   no Gherkin step runs QML yet.

@desktop @backlog-desktop @priority-low
Feature: Shared controls follow the theme
  Switches, check boxes, number fields, text fields, tooltips, menus and select popups take their
  colours from the active theme, so they hold in light, dark and custom themes.

  Scenario: A switch, check box and number field use the theme's accent and input colours
    Given a custom theme with accent "#ff0066"
    When a settings panel shows a switch that is on, a checked check box and a number field
    Then the switch track and the check box are filled with the accent colour
    And the number field's border is the theme's input colour

  Scenario: Tooltips follow the theme
    Given the dark base theme is applied
    When a tooltip is shown
    Then it is drawn on the popover surface: the solid overlay colour, a strong hairline and a small radius
    And its text is the theme's text colour at the meta size
    When the light base theme is applied
    Then the next tooltip uses the light colours
    When I press the control under the tooltip
    Then the tooltip hides at once, without fading

  Scenario: A press hides any control's tooltip
    Given a control that is not a shared button shows its tooltip
    When I press it
    Then the tooltip hides at once
    And it does not come back until the pointer moves

  Scenario: A control that moves under a resting pointer shows no tooltip
    Given the pointer rests on the "Open panel" button
    When I click it and the "Add panel" button takes its place under the pointer
    Then no tooltip opens for "Add panel"
    When I move the pointer over "Add panel"
    Then its tooltip opens

  Scenario: A text field is translucent in dark themes and keeps a focus ring
    Given the dark base theme is applied
    Then a text field's fill is the input colour at low opacity
    When the text field has focus
    Then its border is the theme's focus colour

  Scenario: Menus, palettes and dialogs are opaque whatever the glass opacity
    Given the glass opacity is set to 40 percent
    When a menu, the command palette, a picker or a dialog opens over the timeline
    Then it is drawn on the solid overlay colour, so nothing behind it shows through
    And the glass opacity still thins toasts and floating buttons

  Scenario: A destructive confirm is a deep error fill under white text
    Given the dark base theme is applied, whose error red is light enough for text
    When a confirmation asks to delete a thread
    Then Delete is filled with the theme's destructive fill, a deep red
    And its white label reads at 4.5:1 or better
    And Cancel stays a quiet outline button
    When a custom theme names an error colour but no destructive fill
    Then Delete is filled with that error, deepened until its white label reads at 4.5:1

  # Opaque popovers have nothing behind them to blur.
  @desktop @dropped
  Scenario: Menus, palettes and dialogs blur what is behind them
    When a menu, palette or dialog opens over the timeline
    Then the content behind it is blurred as the web client's dropdown-glass does

  Scenario: The terminal drawer toolbar is readable
    When the terminal drawer is open
    Then its toolbar icons use the terminal's foreground colour, not the muted surface colour

  Scenario: A select popup marks its current value and the keyboard row
    Given a select whose current value is "Medium"
    When its popup opens
    Then the "Medium" row shows a check mark
    When I press Down
    Then the row under the keyboard is highlighted and "Medium" keeps its check mark

  Scenario: A list too long for its menu, picker or palette shows that it goes on
    Given the diff's turn picker lists 30 turns
    When the user opens it
    Then it stops on a whole row, never a sliced one, and every row keeps its full ink
    And a thin bar at its right edge, at the top, says there is more
    When the user scrolls to the end
    Then the bar moves to the bottom
    And a menu longer than the window, the model picker and the command palette do the same

  Scenario: A select popup opens upward when there is no room below
    Given a select near the bottom of the window
    When its popup opens
    Then it opens above the select instead of over the controls below

  Scenario: A context menu nests submenus and draws separators
    Given a context menu with a submenu "Move to" and a separator
    When I open the menu
    Then "Move to" is one row with a chevron and its items open in a flyout
    And the separator is drawn as a line between the groups

  Scenario: Every icon the menus name exists
    Then the icons "link" and "arrow-down" are drawn from the Lucide set
