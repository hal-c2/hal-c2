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

  @shared @backlog-mobile @backlog-tui
  Scenario: A hub's accounts are pooled into limits
    Given the hub "Team hub" reports a Codex account
    When the user views limits
    Then Codex limits include the account "codex-ops" of the hub

  @shared @backlog-mobile @backlog-tui
  Scenario: An account both a hub and this machine report counts once
    Given Codex is signed in here as "sam@example.com"
    And the hub "Team hub" reports the Codex account "sam@example.com"
    When the user views limits
    Then Codex limits count one account

  @shared @backlog-mobile @backlog-tui
  Scenario: A hub that cannot be read is named in limits
    Given the hub "Team hub" cannot be read: "Hub unreachable."
    When the user views limits
    Then usage says "Team hub: Hub unreachable."

  @shared @backlog-mobile @backlog-tui
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

  @shared @backlog-mobile @backlog-tui
  Scenario: The user removes a hub
    Given a hub "Team hub"
    When the user removes "Team hub" and confirms
    Then its key is deleted from the MC
    And its accounts leave limits
    And the hub itself is untouched

  @shared @backlog-mobile
  Scenario: A read-only connection cannot add hubs
    Given the user is connected with read-only access
    When the user opens usage providers
    Then the user cannot add a hub
