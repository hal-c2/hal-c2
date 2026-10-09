# Sources:
#   docs/user/appearance.md (Environment themes, Publish a theme)
#   apps/server-ex/lib/hal_c2/environment_themes.ex
#   apps/server-ex/lib/hal_c2/settings.ex (notify_themes)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (config.themes)
#   apps/server/src/cli/theme.ts (hal-c2 theme set, clear, show)
#   docs/internals/desktop-qt.md (theme.json ricing contract)
#   apps/desktop-qt/src/ThemeStore.cpp
#   apps/desktop-qt/src/native/ThemeController.cpp (follows the themes its own MC publishes)

Feature: Environment themes and the desktop shell theme
  A machine can publish themes for the clients it serves, and set a default that connected
  clients switch to. The desktop shell also follows a theme file that theme managers write.

  Rule: Publishing themes from the MC

    @mc
    Scenario: A theme file in the themes folder is published
      Given the MC's themes folder is empty
      When "nightfall.json" with a dark palette is written into the themes folder
      Then within a few seconds the MC publishes a theme with the id "nightfall"

    @mc
    Scenario: Clients watching the MC receive the new set
      Given a client is watching the MC's configuration
      When a theme file is added to the themes folder
      Then the client receives the updated list of published themes

    @mc
    Scenario: Updating a theme file republishes its colors
      Given the MC publishes "nightfall"
      When the user changes the accent in "nightfall.json"
      Then the published "nightfall" has the new accent

    @mc
    Scenario: Removing a theme file stops publishing it
      Given the MC publishes "nightfall"
      When "nightfall.json" is deleted
      Then "nightfall" is no longer published

    @mc
    Scenario: The short format names only canvas and accent
      When a theme file gives only a name, an appearance, a canvas and an accent
      Then the theme is published

    @mc
    Scenario Outline: Unusable theme files are skipped without an error
      When a theme file that is <problem> is written into the themes folder
      Then it is not published
      And the other themes are still published

      Examples:
        | problem                              |
        | not valid JSON                       |
        | without any colors                   |
        | larger than 32 KB                    |
        | a symbolic link                      |
        | named system.json                    |
        | named after a built-in theme         |
        | named with capital letters           |

    @mc
    Scenario: Only a bounded number of themes is published
      When 40 valid theme files are written into the themes folder
      Then at most 32 themes are published

  Rule: Following published themes

    @desktop
    Scenario: Selecting a published theme follows its updates
      Given the user selected the published theme "nightfall"
      When the server updates "nightfall"
      Then the app shows the updated colors

    @desktop
    Scenario: Duplicating a published theme makes an independent copy
      Given the server publishes "nightfall"
      When the user duplicates "nightfall"
      Then the user has an editable copy that does not change when the server updates "nightfall"

    @desktop
    Scenario: A saved custom theme with the same id wins
      Given the user saved a custom theme with the id "nightfall"
      And the server publishes "nightfall"
      Then the app uses the user's saved "nightfall"

    @desktop
    Scenario: A theme that stops being published falls back to the standard theme
      Given the user selected the published theme "nightfall"
      When the server stops publishing "nightfall"
      Then the app uses the standard theme

    @desktop
    Scenario: A published theme stays chosen across a reconnect
      Given the user selected the published theme "nightfall"
      When the MC drops the connection
      And the desktop reconnects to the MC
      Then the app uses the published "nightfall"

    @desktop
    Scenario: Extra connections do not impose their themes
      Given the user connected a second environment that publishes "sunrise"
      Then "sunrise" is not offered

  Rule: A default theme set on the server

    @mc
    Scenario: Setting a default switches connected clients
      Given two clients are connected
      When the server operator runs "hal-c2 theme set nightfall"
      Then both clients switch to "nightfall"

    @mc
    Scenario: An offline client applies the default when it reconnects
      Given a client is offline
      When the server operator runs "hal-c2 theme set nightfall"
      And the client reconnects
      Then the client switches to "nightfall"

    @mc
    Scenario: A client applies a default only once
      Given the server default is "nightfall" and the client applied it
      When the user chooses "Nord"
      And the client reconnects
      Then the client keeps "Nord"

    @mc
    Scenario: Setting the same default again reapplies it
      Given the server default is "nightfall" and the user switched to "Nord"
      When the server operator runs "hal-c2 theme set nightfall" again
      Then the client switches to "nightfall"

    @mc
    Scenario: Clearing the default leaves current themes alone
      Given the server default is "nightfall"
      When the server operator runs "hal-c2 theme clear"
      Then no default is set
      And every client keeps its current theme

    @mc
    Scenario: Showing the default and published themes
      # A default is set first so the listing has something to show.
      Given the server default is "nightfall"
      When the server operator runs "hal-c2 theme show"
      Then the default theme and every published theme are listed

  Rule: The desktop shell theme file

    @desktop
    Scenario: Editing the shell theme file recolors the app live
      Given the desktop shell is running
      When a theme manager writes a new canvas color into the shell theme file
      Then the app uses the new canvas color

    @desktop
    Scenario: A malformed shell theme file keeps the last good theme
      Given the desktop shell is using a shell theme
      When the shell theme file is saved with a syntax error
      Then the app keeps the previous colors
      And the error is available to the user's shell layout

    @desktop
    Scenario: Deleting the shell theme file returns to the app's own theme
      Given the desktop shell is using a shell theme
      When the shell theme file is deleted
      Then the app uses its own selected theme again

    @desktop
    Scenario: A shell theme can override one appearance
      Given the shell theme has a light variant with a different canvas
      When the appearance is Light
      Then the light variant's canvas is used

    @desktop
    Scenario: A shell theme never changes saved preferences
      Given the desktop shell is using a shell theme
      Then the user's saved theme choice is unchanged

    @desktop
    Scenario: Settings → Appearance says a shell theme file is in charge
      Given the desktop shell is using a shell theme
      Then Settings → Appearance names the shell theme file and where it is
      And says its colors are drawn over the theme chosen there
