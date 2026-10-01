# Sources:
#   docs/user/project-settings.md (Project icons)
#   apps/server-ex/lib/hal_c2/environment_themes.ex
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (project-favicon-assets)
#   apps/web/src/components/ProjectFavicon.tsx
#   apps/web/src/components/ProjectMonogram.tsx
#   apps/web/src/components/ProjectEnvironmentBadge.tsx
#   apps/web/src/components/settings/ProjectIconPickerDialog.tsx
#   apps/web/src/components/settings/ProjectFaviconPickerDialog.tsx
#   apps/web/src/components/settings/EnvironmentIconPicker.tsx
#   apps/mobile/src/components/ProjectFavicon.tsx
#   packages/contracts/src/project.ts (ProjectIconOverride, icon colours)
#   packages/contracts/src/rpc.ts (assets.createUrl)

Feature: Project and environment identity
  Projects and environments are easy to tell apart at a glance. A project shows its own
  icon, one the user picked, or a coloured monogram. An environment shows the kind of
  machine it runs on and can bring its own colour themes.

  Background:
    Given a connected environment "laptop" with the project "shop"

  Rule: Project icons

    @mc
    Scenario: A project's own favicon is served as its icon
      Given the checkout of "shop" has "public/favicon.svg"
      When a client asks for the icon of "shop"
      Then the favicon is served

    @mc
    Scenario: A project without a favicon has no icon to serve
      Given the checkout of "shop" has no favicon
      When a client asks for the icon of "shop"
      Then the MC answers that there is no icon

    @backlog @desktop @mobile
    Scenario Outline: A project without an icon shows a two-character monogram
      Given the project "<name>" has no icon
      When the user looks at the project list
      Then "<name>" shows the monogram "<monogram>" in a colour derived from its name

      Examples:
        | name           | monogram |
        | Nebula         | NA       |
        | Silver Orchard | SO       |
        | M7 Forge       | M7       |

    @backlog @desktop @mobile
    Scenario Outline: The user picks a project icon
      When the user sets the icon of "shop" to <icon>
      Then "shop" shows <icon> everywhere it is listed

      Examples:
        | icon                            |
        | the "rocket" symbol in teal     |
        | the emoji "🛒"                  |
        | the monogram "SH" in rose       |
        | the image file "assets/logo.png" |

    @backlog @desktop @mobile
    Scenario: Resetting the icon returns to the automatic icon
      Given the user set the icon of "shop" to the emoji "🛒"
      When the user resets the icon of "shop"
      Then "shop" shows its automatic icon

    @backlog @desktop
    Scenario Outline: Monograms take one or two letters or numbers
      When the user types "<text>" as the monogram of "shop"
      Then the monogram <result>

      Examples:
        | text | result                  |
        | sh   | is saved as "SH"        |
        | 7    | is saved as "7"         |
        | abc  | cannot be saved         |
        | #!   | cannot be saved         |

    @backlog @desktop
    Scenario: A picked icon still shows on environments that do not know monograms
      Given "laptop" runs an older server that only knows symbol icons
      When the user sets the monogram "SH" on "shop"
      Then "laptop" keeps a folder symbol with the letters "SH"

    @backlog @desktop
    Scenario: Choosing an image searches only image files in the project
      When the user searches the project for an icon image named "logo"
      Then "assets/logo.png" is offered
      And "src/logo.ts" is not offered

  Rule: Environment icons

    @backlog @desktop
    Scenario: The user chooses the kind of machine an environment runs on
      Given "laptop" is detected as a laptop
      When the user marks "laptop" as a server
      Then "laptop" shows a server icon

    @backlog @desktop
    Scenario: Choosing the detected kind clears the choice
      Given the user marked "laptop" as a server
      When the user marks "laptop" as a laptop, its detected kind
      Then "laptop" follows its detected kind again

    @backlog @desktop
    Scenario Outline: An environment icon cannot always be changed
      Given <situation>
      When the user tries to change the icon of "laptop"
      Then the user is told "<message>"

      Examples:
        | situation                                  | message                                                                  |
        | "laptop" is disconnected                   | Connect to this environment to change its icon.                          |
        | "laptop" runs a server too old to keep one | This environment's server is too old to keep an icon. Update it to choose one. |
        | the user's session cannot change settings  | Your session on this environment cannot change its settings.             |

  Rule: Environment themes

    @mc
    Scenario: Theme files in the environment's themes folder are offered to clients
      Given the HAL-C2 home of "laptop" has the theme file "themes/dusk.json"
      When a client connects to "laptop"
      Then the theme "dusk" is offered

    @mc
    Scenario: A new or changed theme file reaches connected clients
      Given a client is connected to "laptop"
      When the user adds the theme file "themes/sunset.json"
      Then the client is offered the theme "sunset" within a few seconds

    @mc
    Scenario: Removing a theme file withdraws the theme
      Given the theme "dusk" is offered
      When the user deletes "themes/dusk.json"
      Then "dusk" is no longer offered

    @mc
    Scenario Outline: Theme files that break the rules are skipped without an error
      Given the themes folder has <file>
      When the MC reads its themes
      Then that theme is not offered
      And the other themes are offered

      Examples:
        | file                                       |
        | a file named "Dark.json"                   |
        | a file named "system.json"                 |
        | a file larger than 32 KB                   |
        | a link to a theme elsewhere                |
        | a file that is not valid JSON              |
        | a theme with the colour "red" instead of hex |
        | a theme without colours                    |

    @mc
    Scenario Outline: The themes folder is read only up to its limits
      Given the themes folder has <files>
      When the MC reads its themes
      Then <offered>

      Examples:
        | files                              | offered                                             |
        | 40 valid theme files               | at most 32 themes are offered                       |
        | valid theme files totalling 300 KB | only the themes within the first 192 KB are offered |

    @backlog @desktop @mobile @tui
    Scenario: The user applies an environment theme
      Given "laptop" offers the theme "dusk"
      When the user picks the theme "dusk"
      Then the app uses the colours of "dusk"
