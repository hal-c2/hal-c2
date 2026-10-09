# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/ShellSwitch.qml, ShellCheckBox.qml, ShellSpinBox.qml,
#     ShellTextField.qml, ShellComboBox.qml, ShellMenu.qml, ContextMenuHost.qml (the shared controls)
#   apps/desktop-qt/src/ShellRuntime.cpp (applyWindowTheme: tooltip colours)
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
    Then its background and text use the theme's surface and text colours
    When the light base theme is applied
    Then the next tooltip uses the light colours

  Scenario: A text field is translucent in dark themes and keeps a focus ring
    Given the dark base theme is applied
    Then a text field's fill is the input colour at low opacity
    When the text field has focus
    Then its border is the theme's focus colour

  Scenario: Menus, palettes and dialogs are nearly opaque by default
    Given the glass opacity setting was never changed
    Then the overlay surface used by menus, palettes and dialogs has an alpha of 96 percent

  @backlog-desktop
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
