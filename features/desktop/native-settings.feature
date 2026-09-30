# Sources:
#   apps/desktop-qt/src/native/ThemeController.cpp (the theme resolved from the choice, the built-ins and published themes)
#   apps/desktop-qt/src/ThemeStore.cpp (the palette the shell draws)
#   apps/desktop-qt/scripts/gen-themes.mjs (the built-in palettes, from packages/shared/src/themePalettes.ts)
#   apps/web/src/components/settings/themePalette.ts (getThemeDefinition, resolveThemeAppearance: what the shell mirrors)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   settings/saving-settings.feature has the desktop's settings document and device preferences.

Feature: The desktop shell draws its own theme
  The Qt shell resolves the theme it draws itself, from the theme choice, the built-ins and
  the published themes.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"

  Rule: The shell draws the chosen theme
    # Choosing and resolving the theme is navigation/appearance.feature's and
    # navigation/environment-themes.feature's.

    @desktop
    Scenario: With no theme chosen the shell draws the standard theme
      When the desktop shell starts
      Then the app uses the standard theme

    @desktop
    Scenario: A built-in theme is drawn
      When the theme choice becomes "grove"
      Then the app uses "grove"
