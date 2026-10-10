# Sources:
#   docs/user/appearance.md (appearance, composer context, motion)
#   apps/web/src/components/settings/ThemeSettings.tsx (mode tiles, light and dark pairing)
#   apps/web/src/components/settings/SettingsPanels.tsx (AppearanceSettingsPanel: interface, motion, fonts)
#   apps/web/src/appearanceFonts.ts, apps/web/src/appearanceContrast.ts (font stacks, size limits, contrast)
#   apps/web/src/components/settings/PanelAnimationsPreview.tsx, SettingsFontPreviews.tsx (the previews beside the motion and font settings)
#   apps/web/src/components/settings/FontFamilyPicker.tsx
#   apps/web/src/components/CommandPalette.logic.ts (appearance.cycle, change theme)
#   packages/shared/src/keybindings.ts (theme.select, appearance.cycle)
#   apps/desktop-qt/src/native/ThemeController.cpp (the desktop's appearance, following the system, clearing a choice)
#   apps/desktop-qt/src/native/LayoutController.cpp (panels snap)
#   Settings panel: Settings → Appearance
#   apps/web/src/branding.ts, apps/web/src/branding.logic.ts (stage label, display name, Nightly server version pattern)
#   apps/web/src/components/SidebarStageBackdrop.tsx (environment stage pill label)
#   apps/web/index.html (the inline boot script: stored theme and appearance before the app mounts)

Feature: Appearance
  The user picks a theme, follows the system appearance or pins light or dark, and tunes
  contrast, fonts and motion. Appearance preferences belong to the device.

  Background:
    Given the user is using HAL-C2 on the desktop

  Rule: Light, dark and system

    @desktop
    Scenario Outline: Choosing an appearance mode
      When the user chooses the <mode> appearance
      Then the app is drawn <result>

      Examples:
        | mode   | result                                  |
        | System | in the operating system's appearance    |
        | Light  | light                                   |
        | Dark   | dark                                    |

    @desktop
    Scenario: System appearance follows the operating system as it changes
      Given the user chose the System appearance
      When the operating system switches to dark
      Then the app is drawn dark

    @desktop
    Scenario Outline: The appearance shortcut cycles through the modes
      Given the appearance is <from>
      When the user presses the appearance shortcut
      Then the appearance is <to>
      And the user is told "Appearance: <to>"

      Examples:
        | from   | to     |
        | System | Light  |
        | Light  | Dark   |
        | Dark   | System |

    @desktop
    Scenario: Holding the appearance shortcut does not spin through modes
      Given the appearance is System
      When the user holds the appearance shortcut down
      Then the appearance is Light

    @backlog @desktop
    Scenario: Appearance preferences stay on this device
      Given the user chose the Dark appearance on the desktop
      When the user opens HAL-C2 in a browser signed in to the same environment
      Then the browser keeps its own appearance

    # Legacy: apps/web/index.html (the inline boot script reads the stored theme before the app mounts)
    # Uncertain: a Qt window may paint from its stored settings by construction; kept so the ledger names the behaviour.
    @backlog @desktop
    Scenario: The first thing the window shows already uses the chosen theme and appearance
      Given the user chose the Dark appearance and a theme of their own
      When the user starts the desktop app
      Then the window is drawn in that theme from its first frame

    # Legacy: apps/web/index.html (an unknown stored theme is treated as "system")
    @backlog @desktop
    Scenario: A stored theme that no longer exists makes the window follow the system appearance
      Given the stored theme is one the app does not know
      When the user starts the desktop app
      Then the window follows the system's light or dark appearance

  Rule: Themes

    @desktop
    Scenario: Choosing a theme
      When the user chooses the "Nord" theme in Settings → Appearance
      Then the app uses "Nord"

    @desktop
    Scenario: The theme shortcut opens the theme picker without leaving the thread
      When the user presses the theme shortcut
      Then the theme picker opens over the thread
      And the current theme is marked "Current"

    @desktop
    Scenario: Different themes for light and dark
      When the user picks "Solarized" for light and "Nord" for dark
      And the appearance is Light
      Then the app uses "Solarized"
      When the appearance becomes Dark
      Then the app uses "Nord"

    @desktop
    Scenario: A theme with only one appearance fills only that half
      Given "Midnight" only has a dark palette
      When the user chooses "Midnight"
      Then "Midnight" is the dark theme
      And the light theme is unchanged

    @desktop
    Scenario: A theme choice that cannot be saved is reported
      Given the theme choice cannot be saved
      When the user chooses a theme
      Then the user is told "Couldn't save theme selection"

    @desktop
    Scenario: Clearing the theme choice returns to the standard theme
      Given the theme choice is "grove"
      When the theme choice is cleared
      Then the app uses the standard theme

    @desktop
    Scenario: Clearing one appearance's theme returns it to the theme choice
      Given the theme choice is "iris"
      And the theme choice is "ocean" for dark
      When the dark theme choice is cleared
      And the appearance choice becomes Dark
      Then the app uses "iris"

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (pickedModesFor, assignHalf)
    @backlog @desktop
    Scenario: A fresh install shows the standard theme as chosen for both appearances
      Given the user has never chosen a theme
      When the user opens Settings → Appearance
      Then the standard theme is marked as the light theme and as the dark theme

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (assignHalf with a null card)
    @backlog @desktop
    Scenario: Putting the standard theme on one appearance keeps the other appearance's theme
      Given the theme choice is "iris" for both appearances
      When the user picks the standard theme for dark
      Then the app uses the standard theme in dark
      And the app still uses "iris" in light

    # Legacy: apps/web/src/themePalette.ts (resolveThemeAppearance, resolveDesktopTheme)
    @backlog @desktop
    Scenario Outline: A theme that has only one appearance is drawn in that appearance
      Given "Midnight" only has a dark palette and is the theme choice
      And the appearance is <mode>
      And the operating system is light
      Then the app is drawn dark

      Examples:
        | mode   |
        | System |
        | Light  |

    # Legacy: apps/web/src/themePalette.ts (parseThemeHalves)
    @backlog @desktop
    Scenario: A light or dark theme choice that names a theme that is gone is ignored
      Given the theme choice is "iris" and "nightfall" is chosen for dark
      When "nightfall" is no longer installed or published
      And the appearance becomes Dark
      Then the app uses "iris"

    # Legacy: apps/web/src/hooks/useSettings.ts (resolveEnvironmentIdentificationMode)
    @backlog @desktop
    Scenario: A theme the user made shows the version pill where a built-in theme shows artwork
      Given environment identification is set to "Artwork"
      And the environment is a Nightly build
      When the user chooses a theme they imported or created
      Then the app shows a Nightly version pill
      And the setting still reads "Artwork"

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (CustomThemeCollectionCard, variantNavigation)
    @backlog @desktop
    Scenario: A theme collection offers its variants separately for light and dark
      Given the installed collection "Dusk" has the variants "Dusk Soft", "Dusk Bold" and "Dusk Night"
      When the user looks at the "Dusk" card
      Then the light variants and the dark variants can be chosen separately
      When the user picks "Dusk Bold" for light
      Then "Dusk Bold" is the light theme
      And the dark theme is unchanged

    # Legacy: apps/web/src/components/settings/ThemeSettings.tsx (selectCollectionDefaults)
    @backlog @desktop
    Scenario: Choosing a theme collection uses its first light and first dark variants
      Given the installed collection "Dusk" has several light and dark variants
      When the user chooses the "Dusk" card
      Then the first light variant becomes the light theme
      And the first dark variant becomes the dark theme

  Rule: Interface

    @desktop
    Scenario Outline: Interface sliders change the look
      When the user sets <setting> to <value>
      Then <effect>

      Examples:
        | setting       | value | effect                                   |
        | glass opacity | 50    | translucent surfaces are more see-through |

      # Contrast runs from 50 to 200 (packages/contracts settings.ts), so 20 is not a
      # value the row can take, and below 100 it softens rather than sharpens.
      @backlog
      Examples: Not drawn by the desktop yet
        | setting       | value | effect                                   |
        | contrast      | 20    | text and borders stand out more          |

    @backlog @desktop
    Scenario Outline: Interface sliders keep to their range
      When the user drags <setting> to its <end>
      Then <setting> is <value>

      Examples:
        | setting          | end     | value  |
        | contrast         | minimum | 50%    |
        | contrast         | maximum | 200%   |
        | glass opacity    | minimum | 40%    |
        | glass opacity    | maximum | 100%   |
        | panel animations | minimum | 0 ms   |
        | panel animations | maximum | 400 ms |

    @desktop
    Scenario Outline: The environment can be identified at a glance
      When the user sets environment identification to "<mode>"
      And the environment is a Nightly build
      Then <outcome>

      Examples:
        | mode         | outcome                                        |
        | Artwork      | the app shows the Nightly artwork              |
        | Version pill | the app shows a Nightly version pill           |
        | None         | the app shows no environment marker            |

    @backlog @desktop
    Scenario Outline: The environment's version decides whether it is a Nightly build
      Given the app's own stage is "Alpha"
      And the primary environment runs version "<version>"
      When the user looks at which stage the app shows
      Then the app shows the "<stage>" stage

      Examples:
        | version                   | stage   |
        | 1.4.0-nightly.20260901.3  | Nightly |
        | 1.4.0-preview.20260901.3  | Nightly |
        | 1.4.0                     | Alpha   |
        | 1.4.0-nightly.3           | Alpha   |

    @backlog @desktop
    Scenario: A development build is identified as Dev
      Given the app's own stage is "Dev"
      And environment identification is set to "Version pill"
      When the user looks at the app
      Then the app shows a Dev version pill

    @backlog @desktop
    Scenario Outline: The app's name carries its stage unless it is the latest release
      Given the app's stage is "<stage>"
      When the user looks at the app's name
      Then it reads "<name>"

      Examples:
        | stage   | name              |
        | Latest  | HAL-C2            |
        | Nightly | HAL-C2 (Nightly)  |
        | Alpha   | HAL-C2 (Alpha)    |
        | Dev     | HAL-C2 (Dev)      |

    # The hosted web app's channel is a browser-tab concern (apps/web/src/branding.ts,
    # VITE_HOSTED_APP_CHANNEL); the Qt desktop has no hosted build.
    @dropped @desktop
    Scenario: A hosted app is labelled with the release channel it was built for
      Given the hosted app was built for the "nightly" channel
      When the user looks at the app's stage
      Then the app shows the "Nightly" stage

    @desktop
    Scenario Outline: Diff colors can be changed
      When the user sets diff colors to "<scheme>"
      Then added and removed lines are shown in <colors>

      Examples:
        | scheme        | colors          |
        | Red & green   | green and red   |
        | Blue & orange | blue and orange |

    @desktop
    Scenario: Composer context stays visible after the first message
      Given the user turned on composer context
      When the user sends the first message in a new thread
      Then branch and worktree controls stay visible below the composer

    @desktop
    Scenario: Composer context retreats by default
      Given composer context is off
      When the user sends the first message in a new thread
      Then branch and worktree controls are hidden

    @desktop
    Scenario Outline: An appearance setting can be put back to its default
      Given the user changed <setting>
      When the user resets <setting>
      Then <setting> is back to its default

      Examples:
        | setting                    |
        | contrast                   |
        | glass opacity              |
        | environment identification |
        | diff colors                |
        | composer context           |
        | panel animations           |
        | font smoothing             |
        | word wrapping              |

  Rule: Motion

    @desktop
    Scenario: Panels open and close immediately by default
      When the user toggles the sidebar
      Then the sidebar appears without animation

    @desktop
    Scenario: Panel animations can be slowed down
      When the user sets panel animations to 200 ms
      And the user toggles the right panel
      Then the right panel slides open over 200 ms

    @desktop
    Scenario: Panel animations respect reduced motion
      Given the operating system asks for reduced motion
      And panel animations are set to 200 ms
      When the user toggles the right panel
      Then the right panel opens immediately

    @desktop
    Scenario: Switching threads never replays panel transitions
      Given panel animations are set to 200 ms
      When the user switches to a thread with a different panel layout
      Then the panels snap to that thread's layout

    # Legacy: apps/web/src/components/settings/PanelAnimationsPreview.tsx
    @backlog @desktop
    Scenario: The motion setting previews its duration and can be replayed
      Given panel animations are set to 200 ms
      When the user looks at the panel animation setting
      Then a small preview opens and closes its panels over 200 ms
      When the user activates the preview
      Then the preview plays again
      And the preview does not animate when the operating system asks for reduced motion

  Rule: Fonts and text

    @desktop
    Scenario Outline: Font preferences change their part of the app
      When the user sets the <font> font to "<family>" at <size>
      Then <area> uses "<family>" at <size>

      Examples:
        | font      | family         | size | area                                      |
        | interface | Inter          | 14   | everything outside code and the terminal  |
        | prompt    | Inter          | 15   | the composer                              |
        | code      | JetBrains Mono | 13   | code blocks and diffs                     |
        | terminal  | JetBrains Mono | 12   | the terminal                              |

    @desktop
    Scenario: A font preference can be reset to the system font
      Given the user set the interface font to "Inter"
      When the user resets the interface font
      Then the interface uses the system default font

    # Legacy: apps/web/src/components/settings/SettingsFontPreviews.tsx
    @backlog @desktop
    Scenario Outline: Each font setting previews the surface it changes
      When the user looks at the <font> font setting
      Then a preview shows <preview> in the chosen family and size
      And changing the family or size updates the preview at once

      Examples:
        | font      | preview                                         |
        | prompt    | a prompt with a skill and file links, editable  |
        | code      | a small diff                                    |
        | terminal  | a terminal sample                               |

    @desktop
    Scenario: Font smoothing is offered only on macOS
      Given the user is on Linux
      Then font smoothing is not offered

    @desktop
    Scenario: Word wrap applies to code
      When the user turns on word wrap
      Then long lines in code blocks, tables, diffs and file previews wrap instead of scrolling

    @backlog @desktop
    Scenario: Typography starts as one interface font and one monospace font
      When the user opens the typography settings
      Then the user sees an interface font and a monospace font
      And the prompt follows the interface font
      And the terminal follows the monospace font

    @backlog @desktop
    Scenario: Advanced typography separates the prompt and terminal fonts
      Given the user set the monospace font to "JetBrains Mono"
      When the user turns on advanced typography
      Then the prompt, code and terminal fonts and sizes can be set one by one
      And leaving the terminal font empty uses the terminal's default instead of the code font

    @backlog @desktop
    Scenario: The advanced typography choice stays on this device
      Given the user turned on advanced typography
      When the user restarts HAL-C2
      Then advanced typography is still on

    @backlog @desktop
    Scenario: Jumping to an advanced font setting from search shows it
      Given advanced typography is off
      When the user opens the terminal font from settings search
      Then advanced typography turns on
      And the terminal font setting is shown

    @backlog @desktop
    Scenario Outline: Font sizes stay within a range that keeps the layout intact
      When the user sets the <font> font size to <value>
      Then the <font> font size is <result>

      Examples:
        | font      | value | result |
        | interface | 8     | 12     |
        | interface | 30    | 20     |
        | prompt    | 8     | 12     |
        | prompt    | 30    | 20     |
        | code      | 4     | 10     |
        | code      | 30    | 18     |
        | terminal  | 4     | 8      |
        | terminal  | 30    | 20     |

    @backlog @desktop
    Scenario: A font that is not installed is flagged and not applied
      Given the interface font is "Inter"
      When the user types "Nonexistent Sans" as the interface font and pauses
      Then the field is marked as not found
      And the interface keeps using "Inter"

    @backlog @desktop
    Scenario: A font is only applied once typing pauses
      When the user types a font name letter by letter
      Then the interface does not reflow with each letter
      And the font is applied after a short pause or when the field loses focus

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (font family field: Enter, Escape, maxLength)
    @backlog @desktop
    Scenario: Enter applies a typed font at once
      Given the interface font is "Inter"
      When the user types "Helvetica" as the interface font and presses Enter
      Then the interface uses "Helvetica" without waiting for the pause

    @backlog @desktop
    Scenario: Escape throws away a font name that was not applied yet
      Given the interface font is "Inter"
      When the user types "Helv" in the interface font field and presses Escape
      Then the field shows "Inter" again
      And the interface keeps using "Inter"
      And the settings page stays open

    @backlog @desktop
    Scenario: A font name is limited to 200 characters
      When the user types a font name longer than 200 characters in the interface font field
      Then the field keeps only the first 200 characters

    @backlog @desktop
    Scenario: Clearing a font name returns to the default
      Given the interface font is "Inter"
      When the user clears the interface font field
      Then the interface uses the default font

    @backlog @desktop
    Scenario: The terminal only accepts a fixed-width font
      When the user sets the terminal font to a proportional font such as "Inter"
      Then the font is not applied
      And the terminal keeps its current font

    @backlog @desktop
    Scenario: A font list is tried in order and falls back to the default
      When the user sets the interface font to "Inter, Helvetica"
      Then text is drawn in "Inter", then "Helvetica", then the default font for any missing characters

    @backlog @desktop
    Scenario: The default font is named for this computer
      Given no interface font is set
      When the user opens the interface font setting
      Then it shows which font the default resolves to on this computer

    @backlog @desktop
    Scenario: Fonts can be picked from the installed list
      Given the computer lets HAL-C2 list installed fonts
      When the user opens the code font setting
      Then only fixed-width installed fonts are offered
      And the user can search them
      And a search with no match says "No fonts found."

    @backlog @desktop
    Scenario: Without a font list the user types the font name
      Given the computer does not let HAL-C2 list installed fonts
      When the user opens the interface font setting
      Then a plain field accepts a font family name
