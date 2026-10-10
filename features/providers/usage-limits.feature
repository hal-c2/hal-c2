# Sources:
#   docs/user/usage.md (Track subscription limits, Connect a CLIProxyAPI hub, Subscription usage widget)
#   apps/server-ex/lib/hal_c2/provider_usage_limits.ex, apps/server-ex/lib/hal_c2/provider_usage_limits/codex.ex,
#   apps/server-ex/lib/hal_c2/provider_usage_limits/claude.ex (probes, probeFailed, unsupported, provider.consumeResetCredit)
#   apps/server-ex/lib/hal_c2/usage_limit_sources.ex, apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex (hubs, sealed keys)
#   apps/server-ex/lib/hal_c2/background_policy.ex (providerHealthRefreshInterval, client leases)
#   apps/web/src/components/usage/UsageLimits.tsx, apps/web/src/components/usage/UsageLimitsPooled.tsx
#   apps/web/src/components/settings/UsageProviderSettings.tsx, apps/web/src/components/settings/AddUsageLimitSourceDialog.tsx
#   packages/contracts/src/providerUsageLimits.ts, packages/contracts/src/usageLimitSourceId.ts
#   apps/server/src/ws.ts, packages/shared/src/usageLimits.ts (usageLimitsCommand, withUsageLimitsCommands)
#   apps/server/src/provider/makeManagedServerProvider.ts (re-probe on settings change, disabled providers)
#   apps/server/src/usage/cliproxyApi.ts (per-account read failures, account listing failure,
#     enabled accounts only, credit lookup failure, redemption outcomes and cooldown warning)
#   apps/server-ex/lib/hal_c2/web/socket.ex (config shape with usageLimitsCommand)
#   apps/desktop-qt/src/native/UsageController.cpp (limits, one account per driver and email)
#   apps/web/src/components/chat/ComposerUsageLimits.tsx (the /usage-limits answer above the composer)

Feature: Subscription limits
  Provider plugins that can read a subscription's remaining allowance report it as
  windows (session, weekly, monthly). Hubs such as CLIProxyAPI add accounts the MC
  cannot run turns on. Clients pool the same account seen in several places once.

  Background:
    Given a connected environment with Codex and Claude signed in with subscriptions

  @mc
  Scenario: Limits are read when the MC starts
    When the MC starts
    Then Codex and Claude report their session and weekly windows

  @mc
  Scenario: Limits follow the rate-limit updates a running turn reports
    Given a Codex turn is running
    When Codex reports a new rate-limit reading
    Then the session window shows the new reading without a new check

  @mc
  Scenario: A failed check keeps the last good reading
    Given Codex reported its windows a minute ago
    When the next check of Codex fails
    Then the windows from a minute ago are still shown

  @mc
  Scenario: An API key account reports that limits are not available
    Given Codex is signed in with an API key
    When the MC checks Codex's limits
    Then Codex's limits are reported as not supported for this account

  @mc
  Scenario: A disabled provider shows no limits until it is enabled again
    Given Codex and Claude reported their limits
    When the user turns Claude off
    Then Claude reports no limits and is not checked
    When the user turns Claude back on
    Then Claude's limits are read again at once

  @mc
  Scenario: Refreshing checks every provider and hub again
    Given a hub is connected
    When the user refreshes the providers
    Then Codex, Claude and the hub are checked again

  @mc
  Scenario: Limits are checked in the background only while a client shows them
    Given the background activity profile checks provider status every five minutes
    And a client in front shows provider status
    When five minutes pass
    Then Codex and Claude are checked again

  @mc
  Scenario: No background checks run while every client is in the background
    Given no client in front shows provider status
    When the background check interval passes
    Then Codex and Claude are not checked

  @mc
  Scenario: Using a Codex reset credit restores the limit
    Given Codex has a banked reset credit
    When the user uses the reset credit
    Then Codex's limits are checked again and show the reset

  @mc
  Scenario: A reset credit whose new limits cannot be confirmed says so
    Given Codex has a banked reset credit
    When the user uses the reset credit and the following check fails
    Then the user is told "The reset was applied, but Codex could not confirm the new limits. Refresh to check."

  @mc
  Scenario: A failed redemption is retried as the same attempt
    Given a reset credit redemption timed out
    When the user uses the reset credit again
    Then Codex receives the same redemption rather than a second one

  @mc
  Scenario Outline: Reset credits are refused where they do not exist
    When the user uses a reset credit on <target>
    Then the user is told "<message>"

    Examples:
      | target                        | message                                               |
      | Claude                        | This provider does not bank reset credits.            |
      | a provider that is not set up | Provider instance not found.                          |
      | a hub that is disabled        | The usage limit source is missing or disabled.        |
      | a hub without naming a credit | The reset credit request is incomplete.               |

  @mc
  Scenario: Adding a CLIProxyAPI hub shows its pooled accounts
    When the user adds a hub with its URL and management key
    Then the hub's accounts are reported with their limits

  @mc
  Scenario: A hub's management key is kept out of the settings
    When the user adds a hub with a management key
    Then the settings show the key only as hidden
    And the key is kept in the environment's secret store

  @mc
  Scenario: Saving a hub without changing its hidden key keeps the key
    Given a hub with a saved management key
    When the user renames the hub and saves
    Then the hub still reads with its saved key

  @mc
  Scenario: Removing a hub forgets its key
    Given a hub with a saved management key
    When the user removes the hub
    Then its accounts are no longer reported
    And its key is removed from the secret store

  @mc
  Scenario Outline: A hub that cannot be read keeps its row with the reason
    Given a hub <problem>
    When the MC reads the hub
    Then the hub is reported with no accounts and the error "<error>"

    Examples:
      | problem                       | error                            |
      | without a management key      | No management key configured.    |
      | that cannot list its accounts | The hub could not list accounts. |

  @mc
  Scenario: An account the hub cannot read keeps its row with the reason
    Given a hub whose Codex account reports usage the MC cannot read
    When the MC reads the hub
    Then the Codex account is reported as not read, beside the hub's other accounts

  @mc
  Scenario: A hub's Codex account reset credit is redeemed through the hub
    Given a hub account with a banked Codex reset credit
    When the user uses that reset credit
    Then the hub redeems it and the account's limits are read again

  # Legacy: apps/server/src/usage/cliproxyApi.ts (readAccounts: enabled codex and claude auth files only)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex
  @mc @backlog
  Scenario: A hub's disabled accounts and other providers are left out
    Given a hub that lists a disabled Codex account, an enabled Claude account and a Gemini account
    When the MC reads the hub
    Then only the enabled Claude account is reported
    And a reset credit cannot be redeemed on the disabled Codex account

  # Legacy: apps/server/src/usage/cliproxyApi.ts (credits endpoint failure keeps usage)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex (credits)
  @mc @backlog
  Scenario: A hub's credit lookup failing keeps the account's windows
    Given a hub whose Codex account reports its windows but whose credit lookup fails
    When the MC reads the hub
    Then the account shows its windows with no reset credits

  # Legacy: apps/server/src/usage/cliproxyApi.ts (failed account never publishes the upstream body)
  @mc @backlog
  Scenario: What a hub's upstream said is not shown to clients
    Given a hub account whose upstream request fails with a message that holds a secret
    When the MC reads the hub
    Then the account is reported as not read
    And the secret text is not in anything sent to clients

  # Legacy: apps/server/src/usage/cliproxyApi.ts (Claude weekly scoped windows)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex
  @mc @backlog
  Scenario: A hub's Claude account shows its per-model weekly limits
    Given a hub Claude account that reports a weekly limit scoped to one model
    When the MC reads the hub
    Then the account shows its session and weekly windows and the model's own weekly window

  # Legacy: apps/server/src/usage/cliproxyApi.ts (consume outcomes)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex (@outcomes)
  @mc @backlog
  Scenario Outline: A hub answers a reset credit redemption with what happened
    Given a hub account with a banked reset credit
    When the hub answers the redemption with <answer>
    Then the user is told <outcome>
    And the hub's cooldown for that account is <cooldown>

    Examples:
      | answer              | outcome                                 | cooldown          |
      | success             | the reset was applied                   | cleared           |
      | nothing to reset    | there was nothing to reset right now    | left alone        |
      | no credit           | the account has no reset credit left    | left alone        |
      | already redeemed    | the credit was already redeemed         | cleared           |

  # Legacy: apps/server/src/usage/cliproxyApi.ts (cooldown clearing failure is a warning)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage_limit_sources/cliproxy.ex
  @mc @backlog
  Scenario: A reset applied through a hub whose cooldown cannot be cleared still succeeds
    Given a hub account with a banked reset credit
    When the user uses the reset credit and the hub cannot clear the account's cooldown
    Then the reset is reported as applied
    And the user is warned that routing may resume only after the hub's cooldown expires

  # Legacy: apps/server/src/usage/cliproxyApi.ts (account in a redemption must be one the hub listed)
  @mc @backlog
  Scenario: A redemption for an account the hub does not list is not forwarded
    Given a hub that lists two accounts
    When the user uses a reset credit naming an account the hub does not list
    Then the MC sends nothing to the hub's upstream
    And the user is told the account is missing or disabled

  @mc
  Scenario Outline: Other providers report their own windows
    Given <provider> is signed in with a subscription
    When the MC checks limits
    Then <provider> reports <windows>

    Examples:
      | provider      | windows                                    |
      | Cursor        | its monthly allowance with Auto and API use |
      | Grok          | its billing period allowance and reset time |
      | OpenCode Go   | its session, weekly and monthly allowance  |

  @mc
  Scenario: Grok with an explicit API key reports no subscription limits
    Given Grok is connected with an explicit API key
    When the MC checks limits
    Then Grok's limits are reported as not supported for this account

  @mc
  Scenario: An external OpenCode server reports no limits
    Given OpenCode runs on an external server
    When the MC checks limits
    Then OpenCode's limits are reported as not available

  @desktop @mobile @backlog-mobile
  Scenario: The same account on two environments counts once
    Given the same Codex account is signed in on two environments and reported by a hub
    When the user opens Limits
    Then that account is counted once in each window

  @desktop @mobile @backlog-mobile
  Scenario: Automatic checks wait at least five minutes per environment
    Given the user opened Limits two minutes ago
    When the user opens Limits again
    Then the environment is not checked again yet

  @mc
  Scenario: Providers with limits offer /usage-limits to clients that answer it themselves
    Given Pi, which reports no limits, is set up too
    When a client that answers "/usage-limits" itself reads the providers
    Then Codex and Claude offer "/usage-limits"
    And Pi does not offer "/usage-limits"

  # An older client would send the command to the agent as an ordinary prompt.
  @mc
  Scenario: Clients that do not answer /usage-limits themselves are not offered it
    When a client that does not answer "/usage-limits" itself reads the providers
    Then no provider offers "/usage-limits"

  @mc
  Scenario: A hub that cannot be read offers /usage-limits for every provider
    Given Pi, which reports no limits, is set up too
    And a client that answers "/usage-limits" itself reads the providers
    When a hub that cannot be read is added
    Then Pi offers "/usage-limits" so the hub's error can be shown

  @desktop @mobile @tui @backlog-mobile
  Scenario: The /usage-limits command shows the current model's limits
    Given a Codex thread
    When the user sends "/usage-limits"
    Then Codex's windows are shown above the composer without running the agent
    And they close when the user sends the next message

  @desktop @mobile @tui @backlog-mobile
  Scenario: The /usage-limits command is not offered for providers without limits
    Given an Antigravity thread
    When the user opens the composer's command menu
    Then "/usage-limits" is not offered

  @backlog @desktop
  Scenario Outline: The /usage-limits answer says whose limits it shows
    Given a Codex thread whose limits come from <accounts>
    When the user sends "/usage-limits"
    Then the answer is headed "Usage limits" and says "<summary>"

    Examples:
      | accounts                                   | summary        |
      | the one Codex account on the "Pro" plan    | Codex · Pro    |
      | a second Codex instance named "Work"       | Codex · Work   |
      | three accounts pooled by a hub             | 3 accounts     |

  @backlog @desktop
  Scenario: An account named by its email is hidden in the /usage-limits answer until asked for
    Given a hub account is labelled "sam@example.com"
    When the user sends "/usage-limits"
    Then the answer does not show "sam@example.com"
    When the user chooses to reveal the account
    Then the answer shows "sam@example.com"
    And the user can hide it again

  @backlog @desktop
  Scenario: The /usage-limits answer is dismissed without sending anything
    Given the answer to "/usage-limits" is shown above the composer
    When the user dismisses the usage limits
    Then the answer is gone
    And nothing was sent to the agent

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
