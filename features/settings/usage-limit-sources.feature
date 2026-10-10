# Sources:
#   docs/user/usage.md (CLIProxyAPI hub)
#   apps/server-ex/lib/hal_c2/usage_limit_sources.ex (reading hubs, errors, refresh)
#   apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex (accounts, reset credit redemption)
#   apps/server-ex/lib/hal_c2/web/socket.ex (usageLimitSources subscription)
#   packages/contracts/src/usageLimitSourceId.ts
#   apps/web/src/components/settings/UsageProviderSettings.tsx
#   apps/web/src/components/settings/AddUsageLimitSourceDialog.tsx
#   packages/shared/src/usageLimits.ts (hub accounts pooled with native ones, the hub wins redemption)
#   apps/desktop-qt/src/native/UsageController.cpp
#   apps/desktop-qt/src/native/ProviderSettingsController.cpp (adding and removing hubs)
#   apps/desktop-qt/tests/tst_ProvidersSettings.qml (the add and remove dialogs)
#   apps/tui/src/host/sections/usageHubs.ts, apps/tui/src/host/sections/usageLimits.ts

Feature: Usage limit sources
  A CLIProxyAPI hub pools many provider accounts. Adding it as a usage source
  puts its accounts' limits next to the machine's own in Limits.

  Background:
    Given an MC the user administers

  @mc
  Scenario: A hub's accounts appear in limits
    Given the user added a hub at "https://hub.example" with its management key
    When the MC reads its usage sources
    Then the hub's Codex and Claude accounts appear in limits

  @mc
  Scenario: The management key is kept secret
    Given the user added a hub with its management key
    When a client reads the settings
    Then the settings hold only a marker in place of the key
    And saving the settings back with the marker keeps the key

  @mc
  Scenario: A hub that cannot be read keeps its place with an error
    Given a hub that is unreachable
    When the MC reads its usage sources
    Then the hub is still listed with the error

  @mc
  Scenario: Redeeming a hub account's reset credit twice counts once
    Given a hub account with a banked reset credit
    When the redeem request is sent again after a dropped connection
    Then the hub counts one redemption

  @shared @backlog-mobile
  Scenario: A hub's accounts are pooled into limits
    Given the hub "Team hub" reports a Codex account
    When the user views limits
    Then Codex limits include the account "codex-ops" of the hub

  @shared @backlog-mobile
  Scenario: An account both a hub and this machine report counts once
    Given Codex is signed in here as "sam@example.com"
    And the hub "Team hub" reports the Codex account "sam@example.com"
    When the user views limits
    Then Codex limits count one account

  @shared @backlog-mobile
  Scenario: A hub that cannot be read is named in limits
    Given the hub "Team hub" cannot be read: "Hub unreachable."
    When the user views limits
    Then usage says "Team hub: Hub unreachable."

  @shared @backlog-mobile
  Scenario: A reset credit a hub also reports is spent through the hub
    Given Codex has a reset credit banked
    And the hub "Team hub" reports the Codex account "sam@example.com" with a banked reset credit
    When the user uses the reset credit and confirms
    Then the credit is spent through the hub

  @shared @backlog-mobile
  Scenario: The user adds a hub
    When the user adds a hub with a URL and management key but no label
    Then the hub is listed under the hub's host name

  @shared @backlog-mobile
  Scenario: A hub cannot be added without a URL and key
    When the user fills in a URL but no management key
    Then the user cannot add the hub

  @shared @backlog-mobile
  Scenario: The user removes a hub
    Given a hub "Team hub"
    When the user removes "Team hub" and confirms
    Then its key is deleted from the MC
    And its accounts leave limits
    And the hub itself is untouched

  # The desktop does not know what its own session may do yet.
  @shared @backlog-desktop @backlog-mobile
  Scenario: A read-only connection cannot add hubs
    Given the user is connected with read-only access
    When the user opens usage providers
    Then the user cannot add a hub

  @backlog @desktop
  Scenario: With no hubs the list says so
    Given no hub is configured on the machine
    When the user opens usage providers
    Then the user is told "No usage providers configured."

  @backlog @desktop
  Scenario Outline: A hub is listed by its label or address
    Given a hub at "https://hub.example.ts.net:8318" that <state>
    When the user opens usage providers
    Then the hub is listed as "<title>" with "<detail>"

    Examples:
      | state                                  | title    | detail                                                 |
      | is labelled "Team hub"                 | Team hub | CLI Proxy · https://hub.example.ts.net:8318            |
      | is labelled "Team hub" and is disabled | Team hub | CLI Proxy · Disabled · https://hub.example.ts.net:8318 |

    # Dropped: contradicts the passing "The user adds a hub" (a hub with no label is listed under
    # its host name, the label apps/server-ex/lib/hal_c2/usage_limit_sources.ex gives it). The web
    # showed the full URL (apps/web/src/components/settings/UsageProviderSettings.tsx).
    @dropped
    Examples:
      | state                        | title                           | detail               |
      | has no label                 | https://hub.example.ts.net:8318 | CLI Proxy            |
      | has no label and is disabled | https://hub.example.ts.net:8318 | CLI Proxy · Disabled |

  @backlog @desktop
  Scenario: Adding a hub says whose accounts it shows and where the key stays
    When the user opens the dialog to add a hub on the machine "workstation"
    Then the dialog says it shows the quota of every account the hub pools, next to the providers on "workstation"
    And that the key stays on that machine
    And the label field says it defaults to the hub's host name

  @backlog @desktop
  Scenario Outline: A hub cannot be added without a URL and a key
    When the user fills in the URL "<url>" and the management key "<key>"
    Then adding the hub is <availability>

    Examples:
      | url                   | key      | availability |
      | https://hub.example   | secret   | available    |
      | https://hub.example   |          | not available |
      |                       | secret   | not available |
      | https://hub.example   |  (spaces) | not available |
      | (spaces)              | secret   | not available |

  @backlog @desktop
  Scenario: A hub is saved with its text trimmed
    When the user adds a hub with the URL " https://hub.example ", the key " secret " and the label " Team hub "
    Then the hub is saved with the URL "https://hub.example", the key "secret" and the label "Team hub"
    And it is switched on

  @backlog @desktop
  Scenario: Pressing Enter adds the hub
    Given the add hub dialog is filled in
    When the user presses Enter
    Then the hub is added and the dialog closes

  @backlog @desktop
  Scenario: Cancelling the add hub dialog leaves nothing behind
    Given the user typed a URL and a key in the add hub dialog
    When the user cancels
    Then the dialog closes and no hub is added
    And opening it again shows empty fields

  @backlog @desktop
  Scenario: Adding the same hub again updates it
    Given a hub at "https://hub.example" is already configured
    When the user adds a hub at "https://hub.example" with a new key
    Then there is still one hub at "https://hub.example"
    And it uses the new key

  @backlog @desktop
  Scenario: Hubs on different ports or hosts are different hubs
    Given a hub at "https://hub.example:8318" is configured
    When the user adds a hub at "https://hub.example:9000"
    And the user adds a hub at "https://hub-example.com"
    Then three hubs are listed

  @backlog @desktop
  Scenario: Removing a hub explains what goes and what stays
    Given a hub "Team hub"
    When the user chooses to remove "Team hub"
    Then the user is asked "Remove Team hub?"
    And told its management key is deleted from the MC, its accounts leave limits and the hub itself is untouched
    And told adding it again with the URL and key brings them back
    And cancelling keeps the hub

  @backlog @desktop
  Scenario: Hubs belong to the machine whose providers are being managed
    Given the user manages the providers of the machine "workstation"
    When the user adds a hub
    Then the hub is kept on "workstation" and not on any other machine
