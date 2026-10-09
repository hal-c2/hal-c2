# Sources:
#   docs/user/appearance.md (Custom themes)
#   apps/web/src/components/settings/ThemeSettings.tsx
#   apps/web/src/components/settings/ThemeImportDialog.tsx
#   apps/web/src/components/settings/ThemeSearchSection.tsx
#   apps/web/src/components/settings/ThemeEditorPanel.tsx
#   apps/web/src/components/settings/ThemeEditorHost.tsx
#   apps/web/src/components/settings/themeEditorStore.ts
#   apps/web/src/components/settings/themeInspector.ts
#   apps/web/src/components/settings/ThemeColorPicker.tsx
#   packages/shared/src/keybindings.ts (themeEditor.toggle)

Feature: Custom themes
  Users create, import, edit, share and remove their own themes, and can pick a color
  straight off the app to change it.

  Background:
    Given the user is in Settings → Appearance

  Rule: Creating and editing

    @desktop
    Scenario: A new theme starts from the active theme
      Given the active theme is "Nord"
      When the user creates a theme
      Then the theme editor opens with Nord's colors

    @desktop
    Scenario: Two colors are enough to make a theme
      Given the theme editor is open
      When the user sets the canvas and accent colors
      Then the rest of the palette is derived from them

    @desktop
    Scenario: The advanced view edits every color by family
      Given the theme editor is open
      When the user shows the advanced colors
      Then colors are grouped as Foundation, Brand & content, Context and Status
      And the user can filter them by name

    @desktop
    Scenario: Saving an edited theme applies it
      Given the user changed colors in the theme editor
      When the user saves the changes
      Then the app uses the edited theme

    @desktop
    Scenario: The theme editor survives navigation
      Given the theme editor is open with unsaved changes
      When the user opens a thread
      Then the theme editor is still open with the changes

    @desktop
    Scenario: The theme editor shortcut toggles it
      Given the theme editor is open
      When the user presses the theme editor shortcut
      Then the theme editor is closed

    @desktop
    Scenario: The theme dialogs are drawn in the current theme
      Given the appearance is Light
      When the user opens the theme editor and the import dialog
      Then both are drawn on the theme's dialog surface with text that can be read

    @desktop
    Scenario: Picking a color from the app
      Given the theme editor is open
      When the user inspects the app and picks the sidebar
      Then the editor shows the color used there and how many places use it

    @desktop
    Scenario: Escape cancels picking a color
      Given the user is inspecting the app for a color
      When the user presses Escape
      Then nothing is picked

    @desktop
    Scenario: Duplicating a theme
      When the user duplicates "Nord"
      Then an editable copy of "Nord" is added

  Rule: Adding themes

    @backlog @desktop
    Scenario: Searching the extension marketplace for themes
      When the user searches for themes to add
      Then suggestions such as Dracula, Catppuccin, Nord and Tokyo Night are offered

    @backlog @desktop
    Scenario Outline: Sorting marketplace results
      When the user sorts theme results by <order>
      Then the results are ordered by <order>

      Examples:
        | order           |
        | Most downloaded |
        | Best rated      |

    @backlog @desktop
    Scenario: Installing a marketplace theme makes it active
      When the user installs "Dracula" from the marketplace
      Then the user is told "Dracula added" and "It's now active."

    @backlog @desktop
    Scenario: A single-appearance theme becomes that appearance's theme
      When the user installs a dark-only theme "Midnight"
      Then the user is told "It's now your dark theme."

    @backlog @desktop
    Scenario: An installed marketplace theme can be updated
      Given "Dracula" is installed and a newer version exists
      Then "Dracula" offers an update

    @desktop
    Scenario Outline: Importing theme files
      When the user imports <files>
      Then <result>

      Examples:
        | files                        | result                          |
        | one HAL-C2 theme file       | the theme is added              |
        | one VS Code theme file       | the theme is added              |
        | three theme files at once    | the user is told "3 themes added" |

    @desktop
    Scenario: Pasting theme JSON
      When the user pastes a theme's JSON
      Then the theme is added

    @desktop
    Scenario: An oversized theme file is refused
      When the user imports a theme file larger than 256 KB
      Then the file is refused with the size limit explained

    @desktop
    Scenario: An unreadable theme file suggests pasting
      When the user imports a theme file that cannot be read
      Then the user is told "Could not read that file. Paste the JSON below instead."

    @desktop
    Scenario Outline: Importing a theme that is already installed
      Given "Nord" is installed
      When the user imports "Nord" again and chooses <choice>
      Then <result>

      Examples:
        | choice          | result                                  |
        | Update existing | the installed "Nord" is replaced        |
        | Keep both       | a copy named "Nord (2)" is added        |
        | Cancel          | nothing changes                          |

  Rule: Sharing and removing

    @desktop
    Scenario: Exporting a theme
      When the user exports "My Theme"
      Then a JSON theme file is saved that can be imported elsewhere

    @desktop
    Scenario: Removing a theme asks first
      When the user removes "My Theme"
      Then the user is asked "Remove “My Theme”?"
      When the user confirms
      Then "My Theme" is gone

    @desktop
    Scenario: Removing some variants of a theme collection
      Given an installed collection with four variants
      When the user removes two selected variants
      Then only those two variants are gone

    @desktop
    Scenario: A removal that fails is reported
      Given the theme cannot be removed
      When the user removes it
      Then the user is told "Couldn’t remove theme"
