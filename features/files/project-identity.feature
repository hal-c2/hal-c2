# Sources:
#   docs/user/project-settings.md (Project icons)
#   apps/server-ex/lib/hal_c2/environment_themes.ex
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (project-favicon-assets)
#   apps/server/src/project/ProjectFaviconResolver.ts (candidate order, linked icons, checkout bounds, caching)
#   apps/web/src/components/ProjectFavicon.tsx
#   packages/client-runtime/src/projectFaviconCache.ts (icons kept on the device: size, count, clearing)
#   apps/web/src/components/ProjectMonogram.tsx
#   apps/web/src/components/ProjectEnvironmentBadge.tsx
#   apps/web/src/components/settings/ProjectIconPickerDialog.tsx
#   apps/web/src/components/settings/ProjectFaviconPickerDialog.tsx
#   apps/web/src/components/settings/EnvironmentIconPicker.tsx
#   apps/web/src/components/settings/EnvironmentIconPicker.test.ts (the lock reasons and their order)
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

    # Legacy: apps/server/src/project/ProjectFaviconResolver.ts (resolvePathUncached)
    # Likely already implemented: apps/server-ex/lib/hal_c2/project_favicon.ex
    @mc @backlog
    Scenario Outline: A project's icon is found in the usual places, in order
      Given the checkout of "shop" has <files>
      When a client asks for the icon of "shop"
      Then <served> is served

      Examples:
        | files                                  | served               |
        | "favicon.svg" and "public/favicon.ico" | "favicon.svg"        |
        | "public/favicon.png" and "app/icon.svg" | "public/favicon.png" |
        | "app/icon.png" only                    | "app/icon.png"       |
        | "assets/logo.svg" only                 | "assets/logo.svg"    |
        | ".idea/icon.svg" only                  | ".idea/icon.svg"     |

    # Legacy: apps/server/src/project/ProjectFaviconResolver.ts (extractIconHref, resolveIconHref)
    # Likely already implemented: apps/server-ex/lib/hal_c2/project_favicon.ex
    @mc @backlog
    Scenario: An icon the page or root route links to is used when no usual file exists
      Given the checkout of "shop" has "index.html" linking the icon "/brand/mark.png"
      And "public/brand/mark.png" exists
      When a client asks for the icon of "shop"
      Then "public/brand/mark.png" is served

    # Legacy: apps/server/src/project/ProjectFaviconResolver.ts (extractIconHref, ICON_SOURCE_FILES)
    # Likely already implemented: apps/server-ex/lib/hal_c2/project_favicon.ex
    @mc @backlog
    Scenario: An icon declared in a root route's metadata is used like a linked one
      Given the checkout of "shop" has "src/routes/__root.tsx" declaring an icon with the address "/brand/mark.png"
      And "public/brand/mark.png" exists
      When a client asks for the icon of "shop"
      Then "public/brand/mark.png" is served

    # Legacy: apps/server/src/project/ProjectFaviconResolver.ts (findExistingFile)
    # Likely already implemented: apps/server-ex/lib/hal_c2/project_favicon.ex
    @mc @backlog
    Scenario: An icon outside the checkout is never served unless the user saved it
      Given the checkout of "shop" has "hal-c2.json" naming "../../etc/logo.png" as its icon
      When a client asks for the icon of "shop"
      Then that file is not served
      And the usual icon locations are tried instead

    # Legacy: apps/server/src/project/ProjectFaviconResolver.ts (resolvePathUncached: saved path first)
    # Likely already implemented: apps/server-ex/lib/hal_c2/project_favicon.ex
    @mc @backlog
    Scenario: A saved icon path that is missing on this checkout falls back to automatic discovery
      Given "shop" has the saved icon path "assets/brand.png"
      And this checkout has no "assets/brand.png" but has "public/favicon.svg"
      When a client asks for the icon of "shop"
      Then "public/favicon.svg" is served

    # Legacy: apps/server/src/project/ProjectFaviconResolver.ts (resolvePath re-stats a cached hit)
    @mc @backlog
    Scenario: An icon file deleted from the checkout stops being served at once
      Given the icon of "shop" was served from "public/favicon.svg"
      When the user deletes "public/favicon.svg" and a client asks for the icon again
      Then the next icon candidate is served or the MC answers that there is no icon

    # Legacy: packages/client-runtime/src/projectFaviconCache.ts (hydrate, resolve, peek)
    @desktop @mobile @backlog
    Scenario: A project's icon shows at once after a restart and while the environment is away
      Given "shop" showed its icon before the app was closed
      When the app starts and "laptop" has not connected yet
      Then "shop" shows the same icon

    # Legacy: packages/client-runtime/src/projectFaviconCache.ts (resolve, revision)
    @desktop @mobile @backlog
    Scenario: A changed icon replaces the kept one, and a failed download keeps the old
      Given "shop" showed an icon that is kept
      When "shop" is given a different icon and the download fails
      Then "shop" still shows the kept icon
      When the download works
      Then "shop" shows the new icon

    # Legacy: packages/client-runtime/src/projectFaviconCache.ts (PROJECT_FAVICON_MAX_*, createProjectFaviconImageLoader)
    @desktop @mobile @backlog
    Scenario Outline: Only small icons are kept on the device
      Given the icon of "shop" is <icon>
      When the app shows "shop"
      Then <result>

      Examples:
        | icon                                              | result                                              |
        | a small image                                     | it is kept for the next start                       |
        | a large picture that can be reduced                | a reduced copy is kept                              |
        | a vector image too large to keep                  | it is shown from the environment and not kept       |
        | a file larger than 4 MB                           | it is shown from the environment and not kept       |

    # Legacy: packages/client-runtime/src/projectFaviconCache.ts (PROJECT_FAVICON_CACHE_MAX_ENTRIES, trim)
    @desktop @mobile @backlog
    Scenario: The kept icons are few and the least recently shown go first
      Given the device keeps the icons of 128 projects
      When another project shows its icon
      Then the icon that was shown longest ago is no longer kept

    # Legacy: packages/client-runtime/src/projectFaviconCache.ts (clear, environmentRevisions)
    @desktop @mobile @backlog
    Scenario: Removing an environment forgets the icons kept for its projects
      Given the device keeps the icons of the projects of "laptop"
      When the user removes "laptop"
      Then none of those icons is kept or shown again, even one still downloading

    # Legacy: packages/client-runtime/src/projectFaviconCache.ts (isProjectFaviconFallbackUrl)
    @desktop @mobile @backlog
    Scenario: A project whose icon went back to the automatic one drops the kept icon
      Given "shop" showed an icon that is kept
      When the environment answers for "shop" with its placeholder icon
      Then "shop" shows its monogram and the kept icon is dropped

    @desktop @mobile @backlog-mobile
    Scenario Outline: A project without an icon shows a two-character monogram
      Given the project "<name>" has no icon
      When the user looks at the project list
      Then "<name>" shows the monogram "<monogram>" in a colour derived from its name

      Examples:
        | name           | monogram |
        | Nebula         | NA       |
        | Silver Orchard | SO       |
        | M7 Forge       | M7       |

    @desktop @mobile @backlog-mobile
    Scenario Outline: The user picks a project icon
      When the user sets the icon of "shop" to <icon>
      Then "shop" shows <icon> everywhere it is listed

      Examples:
        | icon                            |
        | the "rocket" symbol in teal     |
        | the emoji "🛒"                  |
        | the monogram "SH" in rose       |
        | the image file "assets/logo.png" |

    @desktop @mobile @backlog-mobile
    Scenario: Resetting the icon returns to the automatic icon
      Given the user set the icon of "shop" to the emoji "🛒"
      When the user resets the icon of "shop"
      Then "shop" shows its automatic icon

    @desktop
    Scenario Outline: Monograms take one or two letters or numbers
      When the user types "<text>" as the monogram of "shop"
      Then the monogram <result>

      Examples:
        | text | result                  |
        | sh   | is saved as "SH"        |
        | 7    | is saved as "7"         |
        | abc  | cannot be saved         |
        | #!   | cannot be saved         |

    @desktop
    Scenario: A picked icon still shows on environments that do not know monograms
      Given "laptop" runs an older server that only knows symbol icons
      When the user sets the monogram "SH" on "shop"
      Then "laptop" keeps a folder symbol with the letters "SH"

    @desktop
    Scenario: Choosing an image searches only image files in the project
      When the user searches the project for an icon image named "logo"
      Then "assets/logo.png" is offered
      And "src/logo.ts" is not offered

    # Legacy: apps/web/src/components/settings/ProjectFaviconPickerDialog.tsx (emptyMessage)
    @backlog @desktop
    Scenario Outline: The image search says why nothing is listed
      Given <state>
      When the user searches the project for an icon image
      Then the user is told "<message>"

      Examples:
        | state                                    | message                  |
        | the project's files are still being read | Indexing project files…  |
        | the user has typed a name being searched | Searching project files… |
        | the project has no image files           | No image files found.    |
        | no image file matches what the user typed | No matching image files. |

    # Legacy: apps/web/src/components/settings/ProjectFaviconPickerDialog.tsx (pickExternal)
    @backlog @desktop
    Scenario: An image outside the project can be chosen with the computer's file manager
      Given the project is on this computer
      When the user chooses to open the image picker of the file manager
      And picks an image file
      Then the project's icon is that image

    @backlog @desktop
    Scenario: A failed file manager picker leaves the icon search open
      Given the file manager's image picker cannot be opened
      When the user chooses to open it
      Then the user is told the image picker could not be opened and why
      And the icon search stays open

    @backlog @desktop
    Scenario: A project inside WSL cannot use the file manager's image picker
      Given the project's folder is inside Windows Subsystem for Linux
      When the user searches the project for an icon image
      Then choosing an image from outside the project is not offered

    # Legacy: apps/web/src/components/settings/ProjectIconPickerDialog.tsx
    @backlog @desktop
    Scenario: Icons can be searched across the whole symbol set
      When the user searches the project icon symbols for "rocket"
      Then symbols whose name contains "rocket" are offered
      When nothing matches what the user typed
      Then the user is told no icons were found

    @backlog @desktop
    Scenario: A pasted emoji becomes the project's emoji
      When the user pastes "🛒 cart" as the emoji of "shop"
      Then "🛒" is chosen as the icon, as one complete emoji

    # Legacy: apps/web/src/projectIconOptions.ts (filterProjectIconNames, firstEmoji)
    @backlog @desktop
    Scenario Outline: A pasted emoji of any kind is taken whole and other text is ignored
      Given "shop" has the emoji "💻" as its icon
      When the user pastes "<pasted>" as the emoji of "shop"
      Then the chosen icon is <result>

      Examples:
        | pasted       | result                     |
        | 👩🏽‍💻 hello  | the emoji "👩🏽‍💻"          |
        | 🇺🇸 project  | the flag "🇺🇸"              |
        | 1️⃣ project   | the keycap "1️⃣"            |
        | plain text   | still the emoji "💻"       |

    # Legacy: apps/web/src/projectIconOptions.ts (POPULAR_PROJECT_ICONS, 60 results)
    @backlog @desktop
    Scenario: The symbol search starts from a short list and shows a bounded number of matches
      When the user opens the symbol choices without typing
      Then a short list of popular project symbols is offered
      When the user searches the symbols for "a"
      Then at most 60 matching symbols are offered
      And spaces in the search match the dashes in symbol names

    @backlog @desktop
    Scenario: A monogram is tidied before it is checked
      When the user types " ｓｈ " as the monogram of "shop"
      Then the monogram is saved as "SH"

    @backlog @desktop
    Scenario: The icon picker opens on the icon the project has
      Given the user set the icon of "shop" to the monogram "SH" in rose
      When the user opens the icon picker for "shop"
      Then the monogram "SH" in rose is selected
      And a project without a picked icon starts from the automatic letters and colour

    @backlog @desktop
    Scenario: An emoji icon has no colour to choose
      When the user picks an emoji as the icon of "shop"
      Then no colour choice is offered

  Rule: Environment icons

    @desktop
    Scenario: The user chooses the kind of machine an environment runs on
      Given "laptop" is detected as a laptop
      When the user marks "laptop" as a server
      Then "laptop" shows a server icon

    @desktop
    Scenario: Choosing the detected kind clears the choice
      Given the user marked "laptop" as a server
      When the user marks "laptop" as a laptop, its detected kind
      Then "laptop" follows its detected kind again

    @desktop
    Scenario Outline: An environment icon cannot always be changed
      Given <situation>
      When the user tries to change the icon of "laptop"
      Then the user is told "<message>"

      Examples:
        | situation                                  | message                                                                  |
        | "laptop" is disconnected                   | Connect to this environment to change its icon.                          |
        | "laptop" runs a server too old to keep one | This environment's server is too old to keep an icon. Update it to choose one. |
        | the user's session cannot change settings  | Your session on this environment cannot change its settings.             |

    @backlog @desktop
    Scenario: The icon choices name the machine kinds
      When the user opens the icon choices of "laptop"
      Then the choices are Server, Cloud VM, Linux/WSL, Desktop, Laptop, Mini PC and Workstation
      And the current one is marked

    @backlog @desktop
    Scenario Outline: The detected kind is marked
      Given <situation>
      When the user opens the icon choices of "laptop"
      Then <kind> is marked "<marker>"

      Examples:
        | situation                                  | kind    | marker   |
        | "laptop" reports that it is a laptop       | Laptop  | detected |
        | "laptop" cannot tell what machine it is    | Server  | default  |

    @backlog @desktop
    Scenario: A locked icon choice still shows the current icon
      Given "laptop" is disconnected
      When the user opens the icon choices of "laptop"
      Then the reason the icon cannot be changed is shown
      And the current icon is still shown, with no choice available

    @backlog @desktop
    Scenario: The icon choices stay available while the session is being checked
      Given the user's session on "laptop" is still being checked
      When the user opens the icon choices of "laptop"
      Then a kind can be chosen

    @backlog @desktop
    Scenario: The desktop app's own machine can always be marked
      Given the user is using the desktop app
      When the user opens the icon choices of this machine
      Then a kind can be chosen without checking the session's scopes

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

    @desktop @mobile @tui @backlog-mobile @backlog-tui
    Scenario: The user applies an environment theme
      Given "laptop" offers the theme "dusk"
      When the user picks the theme "dusk"
      Then the app uses the colours of "dusk"
