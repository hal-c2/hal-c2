# Sources:
#   docs/user/usage.md (Track subscription limits, Connect a CLIProxyAPI hub, Subscription usage widget)
#   apps/server-ex/lib/t3/provider_usage_limits.ex, apps/server-ex/lib/t3/provider_usage_limits/codex.ex,
#   apps/server-ex/lib/t3/provider_usage_limits/claude.ex (probes, probeFailed, unsupported, provider.consumeResetCredit)
#   apps/server-ex/lib/t3/usage_limit_sources.ex, apps/server-ex/lib/t3/usage_limit_sources/cliproxy.ex (hubs, sealed keys)
#   apps/server-ex/lib/t3/background_policy.ex (providerHealthRefreshInterval, client leases)
#   apps/web/src/components/usage/UsageLimits.tsx, apps/web/src/components/usage/UsageLimitsPooled.tsx
#   apps/web/src/components/settings/UsageProviderSettings.tsx, apps/web/src/components/settings/AddUsageLimitSourceDialog.tsx
#   packages/contracts/src/providerUsageLimits.ts, packages/contracts/src/usageLimitSourceId.ts

@node
Feature: Subscription limits
  Provider plugins that can read a subscription's remaining allowance report it as
  windows (session, weekly, monthly). Hubs such as CLIProxyAPI add accounts the node
  cannot run turns on. Clients pool the same account seen in several places once.

  Background:
    Given a connected environment with Codex and Claude signed in with subscriptions

  Scenario: Limits are read when the node starts
    When the node starts
    Then Codex and Claude report their session and weekly windows

  Scenario: Limits follow the rate-limit updates a running turn reports
    Given a Codex turn is running
    When Codex reports a new rate-limit reading
    Then the session window shows the new reading without a new check

  Scenario: A failed check keeps the last good reading
    Given Codex reported its windows a minute ago
    When the next check of Codex fails
    Then the windows from a minute ago are still shown

  Scenario: An API key account reports that limits are not available
    Given Codex is signed in with an API key
    When the node checks Codex's limits
    Then Codex's limits are reported as not supported for this account

  Scenario: Refreshing checks every provider and hub again
    Given a hub is connected
    When the user refreshes the providers
    Then Codex, Claude and the hub are checked again

  Scenario: Limits are checked in the background only while a client shows them
    Given the background activity profile checks provider status every five minutes
    And a client in front shows provider status
    When five minutes pass
    Then Codex and Claude are checked again

  Scenario: No background checks run while every client is in the background
    Given no client in front shows provider status
    When the background check interval passes
    Then Codex and Claude are not checked

  Scenario: Using a Codex reset credit restores the limit
    Given Codex has a banked reset credit
    When the user uses the reset credit
    Then Codex's limits are checked again and show the reset

  Scenario: A reset credit whose new limits cannot be confirmed says so
    Given Codex has a banked reset credit
    When the user uses the reset credit and the following check fails
    Then the user is told "The reset was applied, but Codex could not confirm the new limits. Refresh to check."

  Scenario: A failed redemption is retried as the same attempt
    Given a reset credit redemption timed out
    When the user uses the reset credit again
    Then Codex receives the same redemption rather than a second one

  Scenario Outline: Reset credits are refused where they do not exist
    When the user uses a reset credit on <target>
    Then the user is told "<message>"

    Examples:
      | target                        | message                                               |
      | Claude                        | This provider does not bank reset credits.            |
      | a provider that is not set up | Provider instance not found.                          |
      | a hub that is disabled        | The usage limit source is missing or disabled.        |
      | a hub without naming a credit | The reset credit request is incomplete.               |

  Scenario: Adding a CLIProxyAPI hub shows its pooled accounts
    When the user adds a hub with its URL and management key
    Then the hub's accounts are reported with their limits

  Scenario: A hub's management key is kept out of the settings
    When the user adds a hub with a management key
    Then the settings show the key only as hidden
    And the key is kept in the environment's secret store

  Scenario: Saving a hub without changing its hidden key keeps the key
    Given a hub with a saved management key
    When the user renames the hub and saves
    Then the hub still reads with its saved key

  Scenario: Removing a hub forgets its key
    Given a hub with a saved management key
    When the user removes the hub
    Then its accounts are no longer reported
    And its key is removed from the secret store

  Scenario Outline: A hub that cannot be read keeps its row with the reason
    Given a hub <problem>
    When the node reads the hub
    Then the hub is reported with no accounts and the error "<error>"

    Examples:
      | problem                          | error                                 |
      | without a management key         | No management key configured.         |
      | whose management request crashes | The hub management request failed.    |

  Scenario: A hub's Codex account reset credit is redeemed through the hub
    Given a hub account with a banked Codex reset credit
    When the user uses that reset credit
    Then the hub redeems it and the account's limits are read again

  @backlog
  Scenario Outline: Other providers report their own windows
    Given <provider> is signed in with a subscription
    When the node checks limits
    Then <provider> reports <windows>

    Examples:
      | provider      | windows                                    |
      | Cursor        | its monthly allowance with Auto and API use |
      | Grok          | its billing period allowance and reset time |
      | OpenCode Go   | its session, weekly and monthly allowance  |

  @backlog
  Scenario: Grok with an explicit API key reports no subscription limits
    Given Grok is connected with an explicit API key
    When the node checks limits
    Then Grok's limits are reported as not supported for this account

  @backlog
  Scenario: An external OpenCode server reports no limits
    Given OpenCode runs on an external server
    When the node checks limits
    Then OpenCode's limits are reported as not available

  @backlog @desktop @mobile
  Scenario: The same account on two environments counts once
    Given the same Codex account is signed in on two environments and reported by a hub
    When the user opens Limits
    Then that account is counted once in each window

  @backlog @desktop @mobile
  Scenario: Automatic checks wait at least five minutes per environment
    Given the user opened Limits two minutes ago
    When the user opens Limits again
    Then the environment is not checked again yet

  @backlog @desktop @mobile @tui
  Scenario: The /usage-limits command shows the current model's limits
    Given a Codex thread
    When the user sends "/usage-limits"
    Then Codex's windows are shown above the composer without running the agent
    And they close when the user sends the next message

  @backlog @desktop @mobile @tui
  Scenario: The /usage-limits command is not offered for providers without limits
    Given an Antigravity thread
    When the user opens the composer's command menu
    Then "/usage-limits" is not offered

  @backlog @mobile
  Scenario: The subscription usage widget shows remaining quotas
    Given the user added the Subscription usage widget
    When the user looks at the home screen
    Then remaining Codex and Claude quotas are shown
    And tapping it opens Limits

  @backlog @mobile
  Scenario: The widget can show session, weekly or both per provider
    When the user sets the widget to show only the weekly window for Claude
    Then the widget shows Claude's weekly window only
