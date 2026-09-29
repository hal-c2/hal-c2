# Sources:
#   apps/desktop-qt/src/native/ThemeController.cpp (the theme resolved from the choice, the built-ins and published themes)
#   apps/desktop-qt/src/ThemeStore.cpp (the palette the shell draws and hands the page)
#   apps/desktop-qt/scripts/gen-themes.mjs (the built-in palettes, from packages/shared/src/themePalettes.ts)
#   apps/web/src/components/settings/themePalette.ts (getThemeDefinition, resolveThemeAppearance: what the shell mirrors)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   settings/saving-settings.feature has the desktop's settings document and device preferences.

Feature: The page follows the desktop shell's theme
  The Qt shell resolves the theme it draws without the page, and hands it to the page.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"

  Rule: The page follows the shell's theme
    # Choosing and resolving the theme is navigation/appearance.feature's and
    # navigation/environment-themes.feature's.

    @desktop
    Scenario: With no theme chosen the shell draws the standard theme
      When the desktop shell starts
      Then the app uses the standard theme
      And the page is drawn in the shell's theme

    @desktop
    Scenario: A built-in theme is drawn and handed to the page
      When the theme choice becomes "grove"
      Then the app uses "grove"
      And the page is drawn in the shell's theme
