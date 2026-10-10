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
#   apps/web/src/components/ui/color-picker.tsx (keyboard nudging of hue, saturation and brightness)
#   apps/web/src/themePalette.ts (theme file validation, stored theme library)
#   apps/web/src/vscodeThemeImport.ts
#   apps/web/src/openVsxThemes.ts
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
    Scenario: Picking a color from the app
      Given the theme editor is open
      When the user inspects the app and picks the sidebar
      Then the editor shows the color used there and how many places use it

    @desktop
    Scenario: Escape cancels picking a color
      Given the user is inspecting the app for a color
      When the user presses Escape
      Then nothing is picked

    # Legacy: apps/web/src/components/settings/ThemeColorPicker.tsx (ThemeColorField)
    @backlog @desktop
    Scenario: A color typed in the field that is not a color is flagged
      Given the advanced colors are shown
      When the user types "not-a-color" as the accent color
      Then the accent field is marked invalid

    # Legacy: apps/web/src/components/settings/ThemeColorPicker.tsx (ThemeColorPickerPanel)
    @backlog @desktop
    Scenario Outline: The color chooser takes a hex or RGB value only when it is complete
      Given the user opened the color chooser for the accent color
      When the user types "<typed>" in the <field> value
      Then the accent color <result>

      Examples:
        | field | typed         | result                  |
        | hex   | #12ab9        | does not change         |
        | hex   | #12AB9C       | becomes #12ab9c         |
        | RGB   | 18, 171       | does not change         |
        | RGB   | 18, 171, 300  | does not change         |
        | RGB   | 18, 171, 156  | becomes #12ab9c         |
        | RGB   | 18 171 156    | becomes #12ab9c         |

    # Legacy: apps/web/src/components/settings/ThemeColorPicker.tsx (alphaSuffix)
    @backlog @desktop
    Scenario: Choosing a color keeps the transparency of the color it replaces
      Given the toolbar border color is "#ffffff40"
      When the user drags the color chooser to another color
      Then the toolbar border keeps its transparency of 25%
      And the chooser shows the opaque color it is editing

    # Legacy: apps/web/src/components/ui/color-picker.tsx (hue slider keys; the provider accent
    # chooser in settings uses the same picker)
    @backlog @desktop
    Scenario Outline: The arrow keys nudge the hue in the color chooser
      Given the user opened the color chooser for the accent color
      And the hue is <from> degrees
      When the user presses <keys> on the hue
      Then the hue is <to> degrees

      Examples:
        | from | keys                      | to  |
        | 120  | the right arrow           | 121 |
        | 120  | Shift and the right arrow | 130 |
        | 120  | the left arrow            | 119 |
        | 355  | Shift and the right arrow | 5   |
        | 5    | Shift and the left arrow  | 355 |

    # Legacy: apps/web/src/components/ui/color-picker.tsx (saturation and brightness: Tab moves
    # between the two values; the arrows, Shift and Home/End act on the one that has focus)
    @backlog @desktop
    Scenario Outline: The keys nudge the focused saturation or brightness in the color chooser
      Given the user opened the color chooser for the accent color
      And <value> is at 50% and has the keyboard focus
      When the user presses <keys>
      Then <value> is <result>

      Examples:
        | value      | keys                       | result |
        | saturation | the right arrow            | 52%    |
        | saturation | Shift and the up arrow     | 60%    |
        | brightness | the left arrow             | 48%    |
        | brightness | Shift and the down arrow   | 40%    |
        | saturation | Home                       | 0%     |
        | brightness | End                        | 100%   |

    @backlog @desktop
    Scenario: Nudging saturation or brightness stops at the ends
      Given the user opened the color chooser for the accent color
      And saturation is at 100% and has the keyboard focus
      When the user presses the right arrow
      Then saturation is still 100%

    # Legacy: apps/web/src/components/settings/ThemeColorPicker.tsx (usage toggle)
    @backlog @desktop
    Scenario: A color's name shows and hides where it is used
      Given the advanced colors are shown
      When the user chooses the name of the accent color
      Then the places in the app that use the accent color are highlighted
      When the user chooses the name again
      Then the highlight is removed

    @desktop
    Scenario: Duplicating a theme
      When the user duplicates "Nord"
      Then an editable copy of "Nord" is added

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (seedName `${label} copy`)
    @backlog @desktop
    Scenario: A duplicated theme is named after the original
      When the user duplicates "Nord"
      Then the theme editor opens with the name "Nord copy"

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (built-in and environment cards pass no edit, export or remove)
    @backlog @desktop
    Scenario Outline: Built-in and published themes can only be used or duplicated
      Given the theme "<theme>" is <kind>
      Then "<theme>" offers duplicating
      And "<theme>" offers no editing, exporting or removing

      Examples:
        | theme     | kind                          |
        | HAL-C2    | the standard theme            |
        | Ocean     | a theme that ships with HAL-C2 |
        | nightfall | published by the environment  |

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (activeThemeForAppearance, initialAppearance)
    @backlog @desktop
    Scenario: A new theme starts from the theme shown for the appearance being edited
      Given "Solarized" is the light theme and "Nord" is the dark theme
      And the appearance is Dark
      When the user creates a theme
      Then the theme editor opens with Nord's colors

    @backlog @desktop
    Scenario: A theme cannot be saved without a name
      Given the theme editor is open with an empty name
      When the user saves the theme
      Then the user is told "Name your theme first."
      And the theme editor stays open

    @backlog @desktop
    Scenario: The whole app previews the draft while the editor is open
      Given the theme editor is open
      When the user changes the accent color
      Then the app is drawn with the draft colors
      When the user closes the editor without saving
      Then the app is drawn with the stored theme again

    @backlog @desktop
    Scenario: A theme not made in the guided view opens with its colors untouched
      Given "Nord" was imported from a file
      When the user edits "Nord"
      Then the advanced colors are shown
      And none of its colors are regenerated until the user chooses to

    @backlog @desktop
    Scenario Outline: Saving a theme says whether the changes are live
      Given "My Theme" is <state>
      When the user saves changes to "My Theme"
      Then the user is told "My Theme saved" and "<description>"

      Examples:
        | state                      | description                  |
        | the theme in use           | Your changes are now active. |
        | installed but not in use   | Your changes are saved.      |

    @backlog @desktop
    Scenario: Creating a theme makes it the active theme
      When the user creates "Aurora" and saves it
      Then the user is told "Aurora created" and "It's now active."

    @backlog @desktop
    Scenario: Naming a new theme after an installed one adds its other appearance
      Given "Dusk" is installed with only a light palette
      When the user creates a dark theme named "Dusk" and saves it
      Then "Dusk" has both a light and a dark palette
      And the user is told "Dusk updated" and "Its dark palette was added."

    @backlog @desktop
    Scenario Outline: A name that already has the chosen appearance is refused
      Given "Dusk" is installed with <palettes>
      When the user creates a <chosen> theme named "Dusk"
      Then <result>

      Examples:
        | palettes                  | chosen | result                                                              |
        | only a dark palette       | dark   | the dark appearance is unavailable because "Dusk" already has it    |
        | a light and a dark palette | light  | saving is refused with "“Dusk” already has light and dark palettes. Pick another name." |

    @backlog @desktop
    Scenario: Typing an installed name moves the draft to its free appearance
      Given "Dusk" is installed with only a light palette
      And the editor draft is a new light theme
      When the user types the name "Dusk"
      Then the draft's appearance becomes dark

    @backlog @desktop
    Scenario: Renaming a theme onto another folds the two together
      Given "Dusk" is installed with only a light palette
      And "Dusk Night" is installed with only a dark palette
      When the user renames "Dusk Night" to "Dusk" and saves it
      Then "Dusk" has both a light and a dark palette
      And "Dusk Night" is gone

    @backlog @desktop
    Scenario: Renaming onto a theme that has the same appearance is refused
      Given "Dusk" is installed with only a dark palette
      And "Dusk Night" is installed with only a dark palette
      When the user renames "Dusk Night" to "Dusk" and saves it
      Then the user is told "“Dusk” already has a dark palette. Pick another name."
      And both themes are unchanged

    @backlog @desktop
    Scenario: An appearance a theme never had cannot be edited into it
      Given "Dusk" is installed with only a light palette
      When the user edits "Dusk" and hovers over the unavailable dark appearance
      Then the user is told "“Dusk” has no dark palette. Create a theme with the same name to add one."

    @backlog @desktop
    Scenario: A save that cannot be stored is reported and can be retried
      Given the theme library cannot be written
      When the user saves a new theme
      Then the user is told "Could not save your theme" and "Browser storage is unavailable, so the change was not kept."
      And no half-saved theme is left behind

    @backlog @desktop
    Scenario: A saved theme that cannot be made active is rolled back
      Given the theme was stored but selecting it fails
      When the user saves a new theme
      Then the editor says "Theme saved, but it could not be made active. Try again."
      And saving again works instead of failing on the name

    @backlog @desktop
    Scenario: Filtering colors with no match says so
      Given the advanced colors are shown
      When the user filters the colors for a name nothing matches
      Then the editor says "No matches."

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (THEME_EDITOR_ROLE_GROUPS)
    @backlog @desktop
    Scenario Outline: Each group of advanced colors lists its own colors
      Given the advanced colors are shown
      When the user looks at the "<group>" colors
      Then they are <colors>

      Examples:
        | group           | colors                                                                                  |
        | Foundation      | Background, Surface, Raised surface, Overlay, Text, Muted text, Border and Input        |
        | Brand & content | Subtle surface, Highlight surface, Accent, Action, Message surface and Code surface     |
        | Context         | Sidebar background, Sidebar controls, Sidebar selection and Terminal background         |
        | Status          | Error and Warning                                                                       |

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (renderColorFields, family roles)
    @backlog @desktop
    Scenario: Filtering colors also finds the colors a family carries
      Given the advanced colors are shown
      When the user filters the colors for "toolbar"
      Then the "Background" color is listed
      And the colors that have nothing to do with the toolbar are not

    # Legacy: apps/web/src/themePalette.ts (updateThemeColorFamily)
    @backlog @desktop
    Scenario Outline: Changing one advanced color carries the colors that belong with it
      Given the advanced colors are shown
      When the user changes the "<color>" color
      Then <followers> follow it

      Examples:
        | color      | followers                                              |
        | Background | the toolbar and window chrome colors                   |
        | Error      | the error text and error background colors             |
        | Warning    | the warning text and warning background colors         |
        | Accent     | the focus ring, update and terminal cursor colors      |

    # Legacy: apps/web/src/themePalette.ts (updateThemeColorFamily, readableThemeForeground)
    @backlog @desktop
    Scenario: Text that sits on a changed color stays readable
      Given the advanced colors are shown
      When the user changes the "Error" color to one that is hard to read against the background
      Then the error text color is adjusted until it can be read on the error background

    @backlog @desktop
    Scenario: The theme editor can be minimised and brought back
      Given the theme editor is open with unsaved changes
      When the user minimises the editor
      Then only its header remains
      When the user expands it again
      Then the changes are still there

    @backlog @desktop
    Scenario: The theme editor stays reachable when the window shrinks
      Given the user moved and resized the theme editor
      When the window becomes smaller than the editor's position
      Then the editor is moved back inside the window so its header can still be grabbed

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (resize grip, MIN_WIDTH, MIN_HEIGHT)
    @backlog @desktop
    Scenario: The theme editor can be resized within the window but not made tiny
      Given the theme editor is open
      When the user drags the editor's corner toward the top left
      Then the editor stops shrinking at a small but usable size
      When the user drags the corner past the window's edge
      Then the editor grows no further than the window

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (submit button label, disabled while the name is blank)
    @backlog @desktop
    Scenario Outline: The save choice says what saving will do
      Given the theme editor is open <situation>
      Then the save choice reads "<label>"

      Examples:
        | situation                                                   | label                |
        | to create a theme with a new name                           | Create theme         |
        | to edit a theme                                             | Save changes         |
        | to create a dark theme named after an installed light theme | Add dark palette     |
        | to rename "Dusk Night" to the name of installed "Dusk"      | Merge into “Dusk”    |

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (Button disabled={!name.trim()})
    @backlog @desktop
    Scenario: Saving is unavailable while the name is blank
      Given the theme editor is open
      When the user clears the theme name or types only spaces
      Then saving the theme cannot be chosen

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (renderNameField onChange clears error)
    @backlog @desktop
    Scenario: Retyping the name clears the error under it
      Given saving was refused because the name is taken
      When the user changes the name
      Then the refusal is no longer shown

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (header status line, usageCount)
    @backlog @desktop
    Scenario Outline: The editor header says which color is selected and how often it is used
      Given the theme editor is open
      When <selection>
      Then the header reads "<header>"

      Examples:
        | selection                                   | header                            |
        | no color is selected                        | Select a color below              |
        | the user starts inspecting the app          | Select an element · Esc to cancel |
        | a color used in one place is selected       | <its name> · 1 use                |
        | a color used in twelve places is selected   | <its name> · 12 uses              |

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (selectThemeRole)
    @backlog @desktop
    Scenario: Picking an element whose color the guided view does not offer opens the advanced colors
      Given the theme editor shows only the two guided colors
      When the user inspects the app and picks the toolbar
      Then the advanced colors are shown with the toolbar's color selected
      And the color filter is empty

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (handleAdvancedChange, getManagedEditorColors)
    @backlog @desktop
    Scenario: Going back to the guided view rebuilds the palette from its two colors
      Given the user changed an advanced color in the theme editor
      When the user turns the advanced colors off
      Then the rest of the palette is derived again from the background and accent colors
      And a theme with both appearances is rebuilt for both appearances

    # Legacy: apps/web/src/components/settings/ThemeEditorPanel.tsx (simpleColorsDirtyByAppearance)
    @backlog @desktop
    Scenario: Saving in the guided view only rebuilds the appearance that was changed
      Given a guided theme has a light and a dark palette
      When the user changes the light accent color and saves
      Then the light palette is rebuilt from its two colors
      And the dark palette is saved exactly as it was shown

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

    @backlog @desktop
    Scenario Outline: Importing a theme file that breaks the rules explains why
      When the user imports a theme file that <problem>
      Then the user is told "<message>"
      And nothing is added

      Examples:
        | problem                                       | message                                                              |
        | is not a JSON object                          | Theme files must contain a JSON object.                              |
        | has a different version than the app reads    | This theme file uses an unsupported version. Expected 1.             |
        | has no name or one over 48 characters         | Theme files need a name (48 characters or fewer).                    |
        | has an appearance other than light or dark    | Theme files need an appearance of "light" or "dark".                 |
        | has no colors                                 | Add at least one color role to the theme file.                       |
        | names a color the app does not have           | "background" is not a supported theme color role.                    |
        | uses a color that is not a literal CSS color  | The color for "accent" must be a literal CSS color such as oklch(0.62 0.2 280). |
        | has an id with capitals or spaces             | Theme ids may only contain lowercase letters, numbers, and hyphens.  |
        | takes the id of a built-in theme              | The theme id "default" is reserved.                                  |
        | has a variant that repeats the base appearance | Theme variants must not repeat the base appearance "dark".           |

    @backlog @desktop
    Scenario Outline: Theme files accept the usual CSS color notations
      When the user imports a theme file whose accent is "<notation>"
      Then the theme is added with that accent

      Examples:
        | notation                       |
        | #abcd                          |
        | rgb(10 20 30 / 50%)            |
        | hsl(350 80% 50%)               |
        | oklch(62% 0.2 280deg / 50%)    |
        | color(display-p3 0.8 0.2 0.3)  |
        | rebeccapurple                  |
        | transparent                    |

    @backlog @desktop
    Scenario: A theme file only needs to list the colors it changes
      When the user imports a theme file with a name, an appearance and one color
      Then every other color comes from the built-in palette of that appearance

    @backlog @desktop
    Scenario: A theme file can carry its other appearance
      When the user imports a theme file that has light colors and a dark variant
      Then one theme is added that has both a light and a dark palette

    @backlog @desktop
    Scenario Outline: A VS Code theme's appearance follows its declared type
      When the user imports a VS Code theme whose type is <type>
      Then the theme is a <appearance> theme

      Examples:
        | type                         | appearance                                  |
        | light                        | light                                       |
        | hc-light                     | light                                       |
        | dark                         | dark                                        |
        | hc-black                     | dark                                        |
        | missing                      | light or dark by how bright its editor background is |

    @backlog @desktop
    Scenario: A VS Code theme without an editor background is refused
      When the user imports a VS Code theme that has no editor background color
      Then the user is told 'That VS Code theme has no "editor.background" color, so there is nothing to build a palette from.'

    @backlog @desktop
    Scenario: A VS Code theme fills the colors it leaves out
      When the user imports a VS Code theme that only sets the editor background and a few other colors
      Then the surfaces and accent come from the theme
      And every color it omits gets a readable derived value

    @backlog @desktop
    Scenario: A VS Code color that would be unreadable is not used
      When the user imports a VS Code theme whose foreground cannot be read on its own background
      Then the imported theme uses a readable text color instead

    @backlog @desktop
    Scenario: A VS Code theme's translucent colors are flattened onto the surface they sit on
      When the user imports a VS Code theme that uses colors with transparency
      Then the imported colors are opaque and match what the surface shows

    @backlog @desktop
    Scenario Outline: A VS Code theme's name is tidied
      When the user imports a VS Code theme with <source>
      Then the theme is named "<name>"

      Examples:
        | source                                  | name                       |
        | a display name                          | the display name           |
        | only a file-style name "solar-dusk"     | Solar Dusk                 |
        | no name at all                          | VS Code theme              |
        | a name longer than 48 characters        | the first 48 characters    |

    @backlog @desktop
    Scenario: Light and dark VS Code files of one family become one theme
      When the user imports "Dusk Light.json" and "Dusk Dark.json" together
      Then one "Dusk" theme is added with a light and a dark palette

    @backlog @desktop
    Scenario: A family that cannot be paired safely stays separate
      When the user imports two light files and one dark file of the same family
      Then each file is added as its own theme

    @backlog @desktop
    Scenario: Same-named VS Code variants are told apart by their file names
      When the user imports two VS Code themes that are both named "Dusk"
      Then each is labelled from its file name
      And a number is appended only when the file names are the same too

    @backlog @desktop
    Scenario: A batch import reports the files that failed and adds the rest
      When the user imports three theme files and one of them is invalid
      Then the other two themes are added without becoming active
      And the user is told which file failed and why

    @backlog @desktop
    Scenario: Files in a batch that are too large are named
      When the user imports several files and "huge.json" is larger than 256 KB
      Then the user is told "huge.json: too large"
      And the other files are still added

    @backlog @desktop
    Scenario: Theme files can be dropped on the add-theme dialog
      When the user drops HAL-C2 or VS Code .json files on the dialog
      Then the files are imported

    @backlog @desktop
    Scenario: The file picker starts in the VS Code extensions folder
      Given VS Code is installed on this computer
      When the user chooses a theme file to import
      Then the file picker starts in VS Code's extensions folder

    @backlog @desktop
    Scenario: A theme that was added but could not be selected is undone
      Given the theme library accepts the theme but selecting it fails
      When the user adds a pasted theme
      Then the user is told "Theme added, but it could not be selected. Try again."
      And adding it again does not fail because the theme already exists

    @backlog @desktop
    Scenario: Keeping both copies of a theme names the copy after its file
      Given "Nord" is installed
      When the user imports a file named "nord-night.json" whose theme is called "Nord"
      And the user chooses Keep both
      Then the copy is named "Nord Night"

    # Legacy: apps/web/src/components/settings/ThemeImportDialog.tsx (readThemeFile fills the editor, handleSubmit)
    @backlog @desktop
    Scenario: A single theme file is shown for review before it is added
      When the user chooses one theme file to import
      Then the file's name and its JSON are shown in the dialog
      And the theme is not added until the user chooses Add theme

    # Legacy: apps/web/src/components/settings/ThemeImportDialog.tsx (Button disabled={!json.trim() || isReading})
    @backlog @desktop
    Scenario: Adding is unavailable while there is nothing to add or a file is still being read
      Given the add-theme dialog is open
      Then adding the theme cannot be chosen while the JSON is empty
      When the user chooses a large theme file
      Then adding the theme cannot be chosen until the file has been read

    # Legacy: apps/web/src/components/settings/ThemeImportDialog.tsx (handleSubmit describeOversizedThemeFile)
    @backlog @desktop
    Scenario: Pasted JSON is held to the same size limit as a file
      When the user pastes more than 256 KB of text and chooses Add theme
      Then the user is told the pasted text is too large and the limit is 256 KB
      And nothing is added

    # Legacy: apps/web/src/components/settings/ThemeImportDialog.tsx (conflicts view, Back)
    @backlog @desktop
    Scenario: An installed theme can be sent back to the import view
      Given "Nord" is installed
      And the user imported "Nord" again and was told it is already installed
      When the user chooses Back
      Then the pasted or chosen JSON is shown again for editing

    # Legacy: apps/web/src/components/settings/ThemeImportDialog.tsx (resolveConflicts, conflicts list)
    @backlog @desktop
    Scenario: Already installed themes in a batch are listed and decided together
      Given "Nord" and "Dusk" are installed
      When the user imports "Nord", "Dusk" and a new theme "Aurora" together
      Then "Aurora" is added at once
      And the user is told "Nord, Dusk" are already installed
      When the user chooses Update existing
      Then both installed themes are replaced and the user is told "2 themes updated"

    # Legacy: apps/web/src/components/settings/ThemeImportDialog.tsx (resolveConflicts, existingTheme.collection)
    @backlog @desktop
    Scenario: Updating an installed theme keeps it in its collection
      Given "Dracula Soft" is installed as part of the "Dracula" collection
      When the user imports "Dracula Soft" again and chooses Update existing
      Then "Dracula Soft" is replaced and is still part of the "Dracula" collection

    # Legacy: apps/web/src/components/settings/ThemeImportDialog.tsx (useEffect on open resets the dialog)
    @backlog @desktop
    Scenario: The add-theme dialog opens empty every time
      Given the user closed the add-theme dialog with JSON and an error showing
      When the user opens the add-theme dialog again
      Then no JSON, file name or error is shown

    @backlog @desktop
    Scenario Outline: The marketplace only offers themes whose license allows it
      Given the marketplace has a theme under the <license> license
      When the user searches for themes
      Then the theme is <outcome>

      Examples:
        | license      | outcome       |
        | MIT          | offered       |
        | Apache-2.0   | offered       |
        | BSD-3-Clause | offered       |
        | MPL-2.0      | offered       |
        | proprietary  | not offered   |
        | unknown      | not offered   |

    @backlog @desktop
    Scenario: Marketplace results are limited to the first few
      When the user searches for a broad term such as "dark"
      Then at most 8 themes are shown

    @backlog @desktop
    Scenario: Typing in the theme search searches after a short pause
      When the user types a search without pressing Enter
      Then the search runs after a short pause
      When the user presses Enter
      Then the search runs immediately

    @backlog @desktop
    Scenario: A search with no supported themes suggests broadening it
      When the user searches for something with no supported open-source themes
      Then the user is told "No supported open-source themes found" and "Try a broader search."

    @backlog @desktop
    Scenario Outline: A marketplace problem is explained and nothing is installed
      When <event> while the user searches or installs a marketplace theme
      Then the user is told "<message>"

      Examples:
        | event                                          | message                                                         |
        | the marketplace cannot be reached              | Open VSX search is unavailable right now.                       |
        | the marketplace takes more than 10 seconds     | Open VSX took too long to respond.                              |
        | the downloaded package fails its checksum      | That Open VSX theme failed its integrity check.                 |
        | the package is not the theme that was selected | That extension package does not match the selected Open VSX theme. |
        | the package's license differs from the listing | That extension does not match its advertised license.           |
        | the package has no color themes                | That extension does not contain color themes.                   |
        | the package has more than 40 color themes      | That extension contains too many color themes to import safely. |
        | one of its themes is not safe to read          | One or more color themes in that extension could not be imported safely. |
        | none of its themes are compatible              | That extension has no compatible color themes.                  |

    @backlog @desktop
    Scenario Outline: An oversized or suspicious package is refused before it is unpacked
      When the user installs a marketplace theme whose package <problem>
      Then the install is refused and nothing is added

      Examples:
        | problem                                |
        | is larger than 20 MB                   |
        | holds more than 5,000 files            |
        | would unpack to more than 100 MB       |
        | compresses suspiciously well           |
        | has a theme file larger than 256 KB    |

    @backlog @desktop
    Scenario: Marketplace downloads only come from the marketplace
      When a marketplace listing points at a download outside its own host
      Then the theme is not installed

    @backlog @desktop
    Scenario: Cancelling a marketplace install stops the download
      Given a marketplace theme is downloading
      When the user closes the dialog
      Then the download and import work stop

    @backlog @desktop
    Scenario: Updating a marketplace theme asks first
      Given "Dracula" is installed and a newer version exists
      When the user chooses to update "Dracula"
      Then the user is asked to confirm that its installed variants are replaced, including any local edits
      And that variants no longer in the extension are removed
      When the user cancels
      Then "Dracula" is unchanged

    @backlog @desktop
    Scenario: An update that raced with a local change is not applied
      Given "Dracula" is being updated from the marketplace
      When the installed variants change while the package downloads
      Then the update is refused with "Your installed themes changed while this package was downloading. Try again."

    @backlog @desktop
    Scenario: A marketplace theme with no description gets a generic one
      When the marketplace lists a theme with no description
      Then it is described as "A community color theme for your editor."

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (SORT_OPTIONS, default downloadCount)
    @backlog @desktop
    Scenario Outline: Marketplace results can also be ordered by recency and relevance
      Given marketplace results are shown
      When the user sorts theme results by <order>
      Then the results are ordered by <order>

      Examples:
        | order         |
        | Newest        |
        | Most relevant |

    @backlog @desktop
    Scenario: Marketplace results start with the most downloaded
      When the user searches for themes
      Then the results are ordered by Most downloaded

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (result card)
    @backlog @desktop
    Scenario: A marketplace result says who made it and how popular it is
      When the user searches for themes
      Then each result shows the theme's name, its publisher and its download count
      And a link to the theme's source is offered where the listing has one

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (suggestion chips)
    @backlog @desktop
    Scenario: Choosing a suggested search runs it
      When the user chooses the suggestion "Nord"
      Then the search box holds "Nord" and its results are shown

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (installingId disables the controls)
    @backlog @desktop
    Scenario: Only one marketplace theme installs at a time
      Given a marketplace theme is installing
      Then the other results cannot be installed or updated
      And the suggested searches and the sort order cannot be changed

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (isInstalled action label)
    @backlog @desktop
    Scenario: An installed marketplace theme offers an update rather than an install
      Given "Dracula" is installed from the marketplace
      When the user searches for "Dracula"
      Then its result offers to update it instead of installing it

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (query effect clears results)
    @backlog @desktop
    Scenario: Clearing the search box clears the results and any problem shown
      Given marketplace results or a marketplace problem are shown
      When the user empties the search box
      Then no results and no problem are shown

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (onKeyDown isComposing)
    @backlog @desktop
    Scenario: Confirming a typed character composition does not start a search
      Given the user is composing text with an input method in the theme search
      When the user presses Enter to confirm the composition
      Then no search starts until the user presses Enter again

    # Legacy: apps/web/src/components/settings/ThemeSearchSection.tsx (open effect resets state)
    @backlog @desktop
    Scenario: The add-theme dialog forgets the last marketplace search
      Given the user searched the marketplace and closed the add-theme dialog
      When the user opens it again
      Then the search box is empty and no results are shown
      And the sort order is back to Most downloaded

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

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (themeIdsToRemove, canRemoveCollection)
    @backlog @desktop
    Scenario: Removing from a collection starts with nothing selected
      Given an installed collection "Dusk" with four variants
      When the user removes themes from "Dusk"
      Then the user is asked "Remove themes from “Dusk”?"
      And no variant is selected and removing is not possible yet
      When the user selects two variants
      Then the removal choice reads "Remove selected (2)"
      And the user is told the variants can be restored by importing the extension again

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (AlertDialogDescription)
    @backlog @desktop
    Scenario: Removing a single theme says it can be imported again
      When the user removes "My Theme"
      Then the user is told it can be brought back anytime by importing its JSON file

    @desktop
    Scenario: A removal that fails is reported
      Given the theme cannot be removed
      When the user removes it
      Then the user is told "Couldn’t remove theme"

    @backlog @desktop
    Scenario: Removing the theme in use moves the selection off it first
      Given "My Theme" is the active theme
      When the user removes "My Theme" and confirms
      Then the app uses the standard theme
      And the appearance mode is unchanged

    @backlog @desktop
    Scenario: Removing a theme that owns only one appearance leaves the other alone
      Given "Solarized" is the light theme and "Nord" is the dark theme
      When the user removes "Nord" and confirms
      Then the dark appearance falls back to the base theme
      And "Solarized" is still the light theme

    @backlog @desktop
    Scenario: A removal that cannot move the selection keeps the theme installed
      Given "My Theme" is the active theme
      And the theme choice cannot be saved
      When the user removes "My Theme" and confirms
      Then the user is told "Couldn’t save theme selection"
      And "My Theme" is still installed
      And the removal dialog stays open

  Rule: Keeping installed themes safe

    @backlog @desktop
    Scenario: A theme library that cannot be read is never overwritten
      Given the stored themes cannot be read
      When the user installs, edits or removes a theme
      Then the change is refused
      And the stored themes are left as they were

    @backlog @desktop
    Scenario: One broken stored theme does not hide the others
      Given the stored themes include one entry that is malformed
      When the app lists the installed themes
      Then every valid theme is listed
      And the malformed entry is not written back over the others

    @backlog @desktop
    Scenario: A stored theme cannot take the id of a built-in theme
      Given a stored theme reuses the id of a built-in theme
      When the app lists the installed themes
      Then that stored theme is not listed

    @backlog @desktop
    Scenario: A theme chosen under an old id still resolves
      Given the stored theme choice names a theme by its old id
      When HAL-C2 starts
      Then the renamed theme is used
