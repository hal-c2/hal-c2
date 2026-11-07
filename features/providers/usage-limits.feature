# Sources:
#   https://github.com/pingdotgg/t3code/pull/17061
#   https://github.com/pingdotgg/t3code/pull/20081
#   https://github.com/pingdotgg/t3code/pull/19808
#   https://github.com/pingdotgg/t3code/pull/15116
#   https://github.com/pingdotgg/t3code/pull/14657
#   https://github.com/pingdotgg/t3code/pull/10700
#   https://github.com/pingdotgg/t3code/pull/21413
#   https://github.com/pingdotgg/t3code/pull/10310
#   https://github.com/pingdotgg/t3code/pull/18624
#   https://github.com/pingdotgg/t3code/pull/19207
#   https://github.com/pingdotgg/t3code/pull/17711
#   https://github.com/pingdotgg/t3code/pull/17530
#   https://github.com/pingdotgg/t3code/pull/16358
#   https://github.com/pingdotgg/t3code/pull/13118 (Claude banked resets)
#   https://github.com/pingdotgg/t3code/pull/14209 (OpenCode Go accounts merged by API key fingerprint)
#   https://github.com/pingdotgg/t3code/pull/13363 (a refused Codex reset credit is not reported as unconfirmed)
#   https://github.com/pingdotgg/t3code/pull/12799 (a Grok account with no metered usage yet stays in Limits)
#   https://github.com/pingdotgg/t3code/pull/12588 (Grok reports the account's email so one account merges)
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

  # Upstream #15116: a window reported mid-turn cleared the failed-check marker; the failure now
  # stays until a full check succeeds.
  @mc @backlog
  Scenario: A reading from a running turn does not hide a failed check
    Given the last check of Codex's limits failed
    When a running Codex turn reports one rate-limit window
    Then that window is shown
    And Codex's limits still say the last check failed until a check succeeds

  @mc
  Scenario: An API key account reports that limits are not available
    Given Codex is signed in with an API key
    When the MC checks Codex's limits
    Then Codex's limits are reported as not supported for this account

  # Upstream #18624: a Claude account with limits but no data is a failed check, not unsupported
  @mc @backlog @plugin-claude
  Scenario: A Claude account whose limits come back empty is checked again
    Given a Claude subscription account whose check says it has limits but returns none
    When the MC checks Claude's limits
    Then the check is reported as failed, not as not supported
    And the next check that returns limits shows them

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

  # Upstream #10310: switching background checks off also stops reading the usage hubs
  @mc @backlog
  Scenario: Background checks switched off do not read the usage hubs either
    Given the health check interval is set to never
    When a minute passes
    Then no usage hub is read
    And refreshing by hand still reads them

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

  # Upstream #19808: reset credit progress shows after the usage popover closes
  @backlog @desktop
  Scenario: Using a reset credit shows its progress under the usage bar
    Given Codex has a banked reset credit
    When the user uses the reset credit from the usage bar and confirms
    Then "Using reset credit…" shows under the bar after the popover closes
    And it is replaced by how the reset went

  @backlog @mc @plugin-codex @priority-low
  Scenario Outline: A refused Codex reset credit is not reported as unconfirmed when the following check fails
    Given Codex refuses the reset credit because <refusal>
    When the user uses the reset credit and the following check fails
    Then the user is told "<message>"
    And the reset is not reported as applied

    Examples:
      | refusal                    | message                            |
      | it was already redeemed    | That credit was already redeemed.  |
      | nothing needs resetting    | Nothing to reset right now.        |
      | the account has no credit  | No reset credit left.              |

  @mc
  Scenario: A second Codex instance's reset credit is redeemed on its own account
    Given a second Codex instance has a banked reset credit
    When the user uses the reset credit on the second Codex instance
    Then only the second Codex instance's account redeems it and shows the reset

  @mc
  Scenario: A failed redemption is retried as the same attempt
    Given a reset credit redemption timed out
    When the user uses the reset credit again
    Then Codex receives the same redemption rather than a second one

  @backlog @mc @plugin-claude
  Scenario: Claude's banked reset credit restores the limit
    Given Claude has a banked reset credit
    When the user uses the reset credit
    Then Claude's limits are checked again and show the reset

  @backlog @mc @plugin-claude
  Scenario: Claude's reset credits are shown with its limits
    Given Claude has a banked reset credit
    When the user views limits
    Then the limits show 1 reset credit banked for Claude

  # macOS keeps Claude's sign-in token in the Keychain, which the MC does not read, so the
  # reset credits stay off there and no request is sent.
  @backlog @mc @plugin-claude @priority-low
  Scenario: Claude's reset credits are not offered on macOS and no request is sent for them
    Given the MC runs on macOS with Claude signed in
    When the user views limits
    Then Claude shows no reset credits
    And no request for Claude's reset credits is sent

  # The MC does not bank Claude's reset credits yet, so this refusal still holds. Drop this
  # scenario once the Claude redemption scenarios above pass.
  @mc @plugin-claude
  Scenario: Claude reset credits are refused until the MC banks them
    When the user uses a reset credit on Claude
    Then the user is told "This provider does not bank reset credits."

  @mc
  Scenario Outline: Reset credits are refused where they do not exist
    When the user uses a reset credit on <target>
    Then the user is told "<message>"

    Examples:
      | target                        | message                                               |
      | a provider that is not set up | Provider instance not found.                          |
      | a Codex instance that is off  | Provider instance not found.                          |
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
  @mc
  Scenario: A hub's disabled accounts and other providers are left out
    Given a hub that lists a disabled Codex account, an enabled Claude account and a Gemini account
    When the MC reads the hub
    Then only the enabled Claude account is reported
    And a reset credit cannot be redeemed on the disabled Codex account

  # Legacy: apps/server/src/usage/cliproxyApi.ts (credits endpoint failure keeps usage)
  @mc
  Scenario: A hub's credit lookup failing keeps the account's windows
    Given a hub whose Codex account reports its windows but whose credit lookup fails
    When the MC reads the hub
    Then the account shows its windows with no reset credits

  # Legacy: apps/server/src/usage/cliproxyApi.ts (failed account never publishes the upstream body)
  @mc @backlog @priority-low
  Scenario: What a hub's upstream said is not shown to clients
    Given a hub account whose upstream request fails with a message that holds a secret
    When the MC reads the hub
    Then the account is reported as not read
    And the secret text is not in anything sent to clients

  # Legacy: apps/server/src/usage/cliproxyApi.ts (Claude weekly scoped windows)
  @mc
  Scenario: A hub's Claude account shows its per-model weekly limits
    Given a hub Claude account that reports a weekly limit scoped to one model
    When the MC reads the hub
    Then the account shows its session and weekly windows and the model's own weekly window

  # Upstream #21413: a hub Codex account keeps its plan when the usage response leaves it out
  @mc
  Scenario: A hub's Codex account keeps its plan when the usage report leaves it out
    Given a hub Codex account on the Free plan whose usage report names no plan
    When the MC reads the hub
    Then the account is labelled with the Free plan from its sign-in details
    And its quota is shown as that plan's window, not as a session window

  # Legacy: apps/server/src/usage/cliproxyApi.ts (consume outcomes)
  @mc
  Scenario Outline: A hub answers a reset credit redemption with what happened
    Given a hub account with a banked Codex reset credit
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
  @mc
  Scenario: A reset applied through a hub whose cooldown cannot be cleared still succeeds
    Given a hub account with a banked Codex reset credit
    When the user uses the reset credit and the hub cannot clear the account's cooldown
    Then the reset is reported as applied
    And the user is warned that routing may resume only after the hub's cooldown expires

  # Legacy: apps/server/src/usage/cliproxyApi.ts (account in a redemption must be one the hub listed)
  @mc @backlog @priority-low
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

  # Upstream #14657: a Codex Enterprise allowance with no session or weekly window was dropped; it
  # is now a monthly credit limit with the reset Codex reports.
  @mc @backlog
  Scenario: A Codex Enterprise allowance shows as a monthly credit limit
    Given Codex is signed in to an Enterprise workspace that reports only its allowance, 99% left
    When the MC checks limits
    Then Codex reports a monthly credit limit 1% used, with the reset Codex gave

  @mc
  Scenario: Grok with an explicit API key reports no subscription limits
    Given Grok is connected with an explicit API key
    When the MC checks limits
    Then Grok's limits are reported as not supported for this account

  # xAI omits the usage percentage until an account has metered use, so the account is
  # kept with no windows rather than dropped as one that can never report.
  @mc @shared @backlog-mobile @backlog-mc @priority-low
  Scenario: A Grok account with no metered usage yet stays in Limits
    Given Grok is signed in with a subscription and has not used any metered credit yet
    When the user opens Limits
    Then Grok's account is listed with the notice "No limits reported."
    And it is not reported as not supported

  # Upstream #17061: a complete weekly or monthly period with no usage percentage now reads as
  # unused; an incomplete, unsupported or invalid period still reports no limits. Replaces the
  # scenario above once the MC and the clients carry it.
  @mc @shared @backlog @plugin-grok @priority-low
  Scenario Outline: A Grok account with no metered usage yet shows its billing period unused
    Given Grok is signed in with a subscription and has not used any metered credit yet
    And xAI reports <period> without a usage percentage
    When the user opens Limits
    Then <shown>

    Examples:
      | period                            | shown                                                           |
      | a complete weekly billing period  | Grok's weekly window reads 0% used with its reset time          |
      | a complete monthly billing period | Grok's monthly window reads 0% used with its reset time         |
      | an incomplete billing period      | Grok's account is listed with the notice "No limits reported."  |

  @mc @backlog @priority-low
  Scenario: Grok names its limits by the signed-in account's email
    Given Grok is signed in with a subscription as "dev@example.com"
    When the MC checks limits
    Then Grok's limits name the account "dev@example.com"

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

  # Upstream #10700: two instances of a provider signed in to one subscription counted twice; they
  # are one account, with the freshest usage and reset credit.
  @backlog @mc @desktop @mobile @priority-low
  Scenario: Two instances signed in to the same account count once
    Given the Codex instances "codex" and "codex-work" are signed in to the same account and workspace
    When the user opens Limits
    Then that account is shown once, with the freshest usage either instance reported
    And its reset credit is redeemed through the instance that reported it

  # OpenCode Go reports no account email, so a shared API key is what identifies the account.
  @backlog @desktop @mobile @priority-low
  Scenario: OpenCode Go accounts sharing an API key on two environments count once
    Given OpenCode Go is signed in with the same API key on two environments and reports no email
    When the user opens Limits
    Then the account is shown once, with the environments it is on and one pooled window for each limit

  @backlog @desktop @mobile @priority-low
  Scenario: OpenCode Go accounts with different API keys stay separate
    Given OpenCode Go is signed in with a different API key on each of two environments and reports no email
    When the user opens Limits
    Then each account is shown with its own limits

  # Upstream #19207: each machine's sign-in has its own refresh token, so the Google account id
  # identifies the account; when it cannot be read, the sign-in itself still does.
  @backlog @mc @desktop @mobile @priority-low
  Scenario: One Google account signed in to Antigravity on two environments counts once
    Given the same Google account is signed in to Antigravity on two environments
    When the user opens Limits
    Then the Antigravity account is shown once, with one pooled window for each limit

  # Upstream #17711: one email in two workspaces (a Plus plan and a Business workspace, or
  # one Claude login in two organizations) has two quotas, and they collapsed into one bar.
  @backlog @mc @desktop @mobile @priority-low
  Scenario Outline: One email in two workspaces is two accounts
    Given <provider> is signed in as "same@example.com" in the workspaces "Personal" and "Business"
    When the user opens Limits
    Then "Personal" and "Business" each show their own limits under their own name

    Examples:
      | provider |
      | Codex    |
      | Claude   |

  @backlog @desktop @mobile @priority-low
  Scenario: Weekly limits of two Codex plans share one card
    Given Codex reports "Business" with its weekly limit first and "Personal" with its weekly limit second
    When the user opens Limits
    Then one Weekly card shows both "Personal" and "Business"

  @backlog @mc @desktop @mobile @priority-low
  Scenario Outline: A report that names no workspace joins its email's only workspace
    Given a hub reports "same@example.com" without saying which workspace
    And "same@example.com" is signed in <workspaces>
    When the user opens Limits
    Then the hub's report <result>

    Examples:
      | workspaces                                                    | result                                                         |
      | in one workspace                                              | is shown with that workspace                                   |
      | in two workspaces                                             | keeps its own row and its reset credit goes to neither workspace |
      | in two workspaces, one of whose limits cannot be read         | keeps its own row and its reset credit goes to neither workspace |

  @backlog @mc @priority-low
  Scenario: Last good limits are not kept for a login that switched workspace
    Given Codex reported the limits of "Personal" a minute ago
    And the login has since switched to "Business"
    When the next check of Codex fails
    Then the limits of "Personal" are not shown for "Business"

  @desktop @mobile @backlog-mobile @priority-low
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

  @desktop @mobile @tui @backlog-mobile @priority-low
  Scenario: The /usage-limits command is not offered for providers without limits
    Given an Antigravity thread
    When the user opens the composer's command menu
    Then "/usage-limits" is not offered

  @desktop
  Scenario Outline: The /usage-limits answer says whose limits it shows
    Given a Codex thread whose limits come from <accounts>
    When the user sends "/usage-limits"
    Then the answer is headed "Usage limits" and says "<summary>"

    Examples:
      | accounts                                   | summary        |
      | the one Codex account on the "Pro" plan    | Codex · Pro    |
      | a second Codex instance named "Work"       | Codex · Work   |
      | three accounts pooled by a hub             | 3 accounts     |

  @desktop
  Scenario: An account named by its email is hidden in the /usage-limits answer until asked for
    Given a hub account is labelled "sam@example.com"
    When the user sends "/usage-limits"
    Then the answer does not show "sam@example.com"
    When the user chooses to reveal the account
    Then the answer shows "sam@example.com"
    And the user can hide it again

  @desktop
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

  @backlog @mobile @priority-low
  Scenario: The widget can show session, weekly or both per provider
    When the user sets the widget to show only the weekly window for Claude
    Then the widget shows Claude's weekly window only

  @backlog @mc @plugin-claude @priority-low
  Scenario: Claude limits load for a user with gigabytes of transcripts
    Given the user has gigabytes of Claude transcripts
    When the MC reads Claude's limits
    Then the plan's limits are shown without the check failing
    And the check does not scan the transcripts

  # Upstream now reads Antigravity's quota; the /usage-limits scenario above that leaves
  # Antigravity out predates it.
  @backlog @mc @shared @mobile @plugin-antigravity @priority-low
  Scenario: Antigravity's subscription limits are shown with the other providers'
    Given an Antigravity instance signed in to a Google account
    When the user opens the usage limits
    Then Antigravity shows its 5-hour and weekly windows
    And the Gemini models' windows are kept apart from those of the Claude and GPT models it shares

  # Upstream #20081: Antigravity's limits merge both quota services
  @backlog @mc @plugin-antigravity @priority-low
  Scenario: Antigravity's Gemini limits show when one quota service leaves them out
    Given one of Google's quota services reports only the Claude and GPT limits for the account
    And the other reports the Gemini limits
    When the user opens the usage limits
    Then Antigravity shows both the Gemini limits and the Claude and GPT limits
    And a limit both services report shows the more used reading
