# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/ShellSwitch.qml, ShellCheckBox.qml, ShellSpinBox.qml,
#     ShellTextField.qml, ShellComboBox.qml, ShellMenu.qml, ContextMenuHost.qml (the shared controls)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellToolTip.qml (every attached tooltip's look)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellPopoverSurface.qml (menus, the palette, pickers, dialogs)
#   apps/web/src/components/ui/switch.tsx, checkbox.tsx, number-field.tsx, input.tsx, select.tsx
#   Proved today by apps/desktop-qt/tests/tst_Shell*.qml; no Gherkin step runs QML yet.

@desktop @backlog-desktop
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
    And the glass opacity still thins the composer

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
