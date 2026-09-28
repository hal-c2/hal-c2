# Sources:
#   docs/user/appearance.md (appearance, composer context, motion)
#   apps/web/src/components/settings/ThemeSettings.tsx (mode tiles, light and dark pairing)
#   apps/web/src/components/settings/SettingsPanels.tsx (AppearanceSettingsPanel: interface, motion, fonts)
#   apps/web/src/components/CommandPalette.logic.ts (appearance.cycle, change theme)
#   packages/shared/src/keybindings.ts (theme.select, appearance.cycle)
#   apps/desktop-qt/src/native/ThemeController.cpp (the desktop's appearance, following the system)
#   Settings panel: Settings → Appearance

Feature: Appearance
  The user picks a theme, follows the system appearance or pins light or dark, and tunes
  contrast, fonts and motion. Appearance preferences belong to the device.

  Background:
    Given the user is using HAL-C2 on the desktop

  Rule: Light, dark and system

    @backlog @desktop
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

    @backlog @desktop
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

    @backlog @desktop
    Scenario: Holding the appearance shortcut does not spin through modes
      Given the appearance is System
      When the user holds the appearance shortcut down
      Then the appearance is Light

    @backlog @desktop
    Scenario: Appearance preferences stay on this device
      Given the user chose the Dark appearance on the desktop
      When the user opens HAL-C2 in a browser signed in to the same environment
      Then the browser keeps its own appearance

  Rule: Themes

    @backlog @desktop
    Scenario: Choosing a theme
      When the user chooses the "Nord" theme in Settings → Appearance
      Then the app uses "Nord"

    @backlog @desktop
    Scenario: The theme shortcut opens the theme picker without leaving the thread
      When the user presses the theme shortcut
      Then the theme picker opens over the thread
      And the current theme is marked "Current"

    @backlog @desktop
    Scenario: Different themes for light and dark
      When the user picks "Solarized" for light and "Nord" for dark
      And the appearance is Light
      Then the app uses "Solarized"
      When the appearance becomes Dark
      Then the app uses "Nord"

    @backlog @desktop
    Scenario: A theme with only one appearance fills only that half
      Given "Midnight" only has a dark palette
      When the user chooses "Midnight"
      Then "Midnight" is the dark theme
      And the light theme is unchanged

    @backlog @desktop
    Scenario: A theme choice that cannot be saved is reported
      Given the theme choice cannot be saved
      When the user chooses a theme
      Then the user is told "Couldn't save theme selection"

  Rule: Interface

    @backlog @desktop
    Scenario Outline: Interface sliders change the look
      When the user sets <setting> to <value>
      Then <effect>

      Examples:
        | setting       | value | effect                                   |
        | contrast      | 20    | text and borders stand out more          |
        | glass opacity | 50    | translucent surfaces are more see-through |

    @backlog @desktop
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
    Scenario Outline: Diff colors can be changed
      When the user sets diff colors to "<scheme>"
      Then added and removed lines are shown in <colors>

      Examples:
        | scheme        | colors          |
        | Red & green   | green and red   |
        | Blue & orange | blue and orange |

    @backlog @desktop
    Scenario: Composer context stays visible after the first message
      Given the user turned on composer context
      When the user sends the first message in a new thread
      Then branch and worktree controls stay visible below the composer

    @backlog @desktop
    Scenario: Composer context retreats by default
      Given composer context is off
      When the user sends the first message in a new thread
      Then branch and worktree controls are hidden

    @backlog @desktop
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

    @backlog @desktop
    Scenario: Panel animations can be slowed down
      When the user sets panel animations to 200 ms
      And the user toggles the right panel
      Then the right panel slides open over 200 ms

    @backlog @desktop
    Scenario: Panel animations respect reduced motion
      Given the operating system asks for reduced motion
      And panel animations are set to 200 ms
      When the user toggles the right panel
      Then the right panel opens immediately

    @backlog @desktop
    Scenario: Switching threads never replays panel transitions
      Given panel animations are set to 200 ms
      When the user switches to a thread with a different panel layout
      Then the panels snap to that thread's layout

  Rule: Fonts and text

    @backlog @desktop
    Scenario Outline: Font preferences change their part of the app
      When the user sets the <font> font to "<family>" at <size>
      Then <area> uses "<family>" at <size>

      Examples:
        | font      | family         | size | area                                      |
        | interface | Inter          | 14   | everything outside code and the terminal  |
        | prompt    | Inter          | 15   | the composer                              |
        | code      | JetBrains Mono | 13   | code blocks and diffs                     |
        | terminal  | JetBrains Mono | 12   | the terminal                              |

    @backlog @desktop
    Scenario: A font preference can be reset to the system font
      Given the user set the interface font to "Inter"
      When the user resets the interface font
      Then the interface uses the system default font

    @backlog @desktop
    Scenario: Font smoothing is offered only on macOS
      Given the user is on Linux
      Then font smoothing is not offered

    @backlog @desktop
    Scenario: Word wrap applies to code
      When the user turns on word wrap
      Then long lines in code blocks, tables, diffs and file previews wrap instead of scrolling
