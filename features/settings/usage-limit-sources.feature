# Sources:
#   docs/user/usage.md (CLIProxyAPI hub)
#   apps/server-ex/lib/hal_c2/usage_limit_sources.ex (reading hubs, errors, refresh)
#   apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex (accounts, reset credit redemption)
#   apps/server-ex/lib/hal_c2/web/socket.ex (usageLimitSources subscription)
#   packages/contracts/src/usageLimitSourceId.ts
#   apps/web/src/components/settings/UsageProviderSettings.tsx
#   apps/web/src/components/settings/AddUsageLimitSourceDialog.tsx

Feature: Usage limit sources
  A CLIProxyAPI hub pools many provider accounts. Adding it as a usage source
  puts its accounts' limits next to the machine's own in Limits.

  Background:
    Given a node the user administers

  @node
  Scenario: A hub's accounts appear in limits
    Given the user added a hub at "https://hub.example" with its management key
    When the node reads its usage sources
    Then the hub's Codex and Claude accounts appear in limits

  @node
  Scenario: The management key is kept secret
    Given the user added a hub with its management key
    When a client reads the settings
    Then the settings hold only a marker in place of the key
    And saving the settings back with the marker keeps the key

  @node
  Scenario: A hub that cannot be read keeps its place with an error
    Given a hub that is unreachable
    When the node reads its usage sources
    Then the hub is still listed with the error

  @node
  Scenario: Redeeming a hub account's reset credit twice counts once
    Given a hub account with a banked reset credit
    When the redeem request is sent again after a dropped connection
    Then the hub counts one redemption

  @backlog @shared
  Scenario: The user adds a hub
    When the user adds a hub with a URL and management key but no label
    Then the hub is listed under the hub's host name

  @backlog @shared
  Scenario: A hub cannot be added without a URL and key
    When the user fills in a URL but no management key
    Then the user cannot add the hub

  @backlog @shared
  Scenario: The user removes a hub
    Given a hub "Team hub"
    When the user removes "Team hub" and confirms
    Then its key is deleted from the node
    And its accounts leave limits
    And the hub itself is untouched

  @backlog @shared
  Scenario: A read-only connection cannot add hubs
    Given the user is connected with read-only access
    When the user opens usage providers
    Then the user cannot add a hub
