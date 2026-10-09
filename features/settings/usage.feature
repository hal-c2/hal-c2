# Sources:
#   docs/user/usage.md
#   apps/server-ex/lib/hal_c2/usage.ex (server.getUsageSummary, transcript sources, scan cache)
#   apps/server-ex/lib/hal_c2/usage/aggregator.ex (de-duplication, day and hour buckets)
#   apps/server-ex/lib/hal_c2/usage/pricing.ex (LiteLLM rates, server.refreshUsageRates, usagePriceOverrides)
#   apps/server-ex/lib/hal_c2/provider_usage_limits.ex (limits, consumeResetCredit)
#   apps/server-ex/test/mc_parity_test.exs (usage summary and rates, consumeResetCredit aligned)
#   packages/contracts/src/usage.ts
#   packages/contracts/src/providerUsageLimits.ts
#   packages/contracts/src/rpc.ts (server.getUsageSummary, server.refreshUsageRates, server.consumeResetCredit)
#   apps/web/src/components/usage/UsagePage.tsx
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (usage.open entry)
#   apps/desktop-qt/src/native/UsageController.cpp, apps/desktop-qt/qml/HalC2/Bricks/UsagePage.qml
#   apps/desktop-qt/qml/HalC2/Bricks/UsageChart.qml (the chart)
#   apps/desktop-qt/tests/tst_UsagePage.qml (backing out of a reset credit, not yet a scenario; the chart's hover)
#   apps/web/src/components/usage/UsageLimits.tsx (reset credits)
#   apps/web/src/components/usage/usageBreakdown.ts, apps/web/src/components/usage/UsageProviderChart.tsx (model and day breakdown, chart)
#   apps/web/src/components/usage/UsagePriceOverrides.tsx, apps/web/src/components/usage/usagePriceTable.ts (model prices dialog)
#   apps/web/src/components/usage/usagePagePreferences.ts (environment subset)
#   apps/web/src/components/usage/UsageLimitsPooled.tsx (account chips)
#   packages/shared/src/usageMerge.ts, packages/shared/src/usageLimits.ts

Feature: Usage and limits
  Usage adds up token use and estimated cost from each provider's local
  session history, and shows how much of each provider's rate limits is left.
  Cost is an API-equivalent estimate, not a bill.

  Rule: The MC summarises usage from session history

    @mc
    Scenario: Usage combines every supported provider's history
      Given Codex, Claude Code and Grok have session history on the machine
      When a client asks for the usage summary
      Then the summary has tokens, cache savings and estimated cost per model

    @mc
    Scenario: A provider home moved by environment variable is found
      Given Claude Code keeps its history under a custom config directory
      When a client asks for the usage summary
      Then that history is counted

    @mc
    Scenario: Two accounts that share a history directory count once
      Given two Codex accounts point at the same history directory
      When a client asks for the usage summary
      Then that history is counted once

    @mc
    Scenario: Resumed and forked sessions are not counted twice
      Given a Claude session was resumed into a new transcript
      When a client asks for the usage summary
      Then the repeated turns count once

    @mc
    Scenario: A second scan only reads what changed
      Given the MC has scanned the history once
      And one transcript has grown since
      When a client asks for the usage summary again
      Then only the new lines of that transcript are read

    @mc
    Scenario: History the provider deleted still counts for 90 days
      Given a transcript that was scanned and then removed by its CLI
      When a client asks for the usage summary within 90 days
      Then its usage is still counted

    @mc
    Scenario Outline: Usage is bucketed in the user's time zone
      When a client asks for <granularity> usage in "<zone>"
      Then the buckets start at <boundary> in "<zone>"

      # Hourly buckets start at the window start plus whole hours (both servers and the clients' minute-aligned 24-hour window), not at the top of the hour.
      Examples:
        | granularity | zone               | boundary                        |
        | daily       | Atlantic/Reykjavik | midnight                        |
        | hourly      | America/New_York   | each hour from the window start |

    @mc
    Scenario: An unknown time zone falls back to UTC
      When a client asks for daily usage in "Mars/Olympus"
      Then the buckets are in UTC

  Rule: Prices

    @mc
    Scenario: Prices keep working offline
      Given the MC fetched model prices yesterday
      And the machine is offline
      When a client asks for the usage summary
      Then costs use the saved prices

    @mc
    Scenario: Refreshing prices fetches them again
      When the user refreshes usage prices
      Then the MC fetches the latest model prices

    @mc
    Scenario: A custom model price replaces automatic pricing
      Given the user saved a price for "my-model" of 1 USD input and 4 USD output per million tokens
      When a client asks for the usage summary
      Then "my-model" costs are estimated at those rates

    # The model prices dialog: its finer points are the backlog scenarios below.
    @desktop @backlog-desktop
    Scenario: The user sets a model's price from Usage
      Given the user views cost for the past 7 days
      When the user opens model prices
      Then each model lists its input, output and cache rates and where they come from
      When the user sets a custom input and output rate for one model
      Then that model's cost uses the custom rates

    @backlog @shared
    Scenario: A custom price with no cache rates uses the input rate
      When the user sets only input and output prices for a model
      Then cache reads and writes are priced at the input rate

    @backlog @shared
    Scenario: Resetting a model to automatic pricing can be undone before saving
      Given a model with a custom price
      When the user resets it to automatic
      And the user discards the change
      Then the custom price remains

    @backlog @shared
    Scenario: A price saved to several environments reports each result
      Given the user applies a price to "laptop" and "server"
      And "server" is unreachable
      When the user saves the price
      Then "laptop" reports saved and "server" reports not saved
      And retrying only saves to "server"

    @backlog @shared
    Scenario: Environments with different prices show the price as mixed
      Given "laptop" and "server" have different prices for "my-model"
      When the user views prices for all environments
      Then the price for "my-model" shows as mixed

  Rule: Reading usage

    @shared @backlog-mobile @backlog-tui
    Scenario Outline: The user reads usage over a window
      When the user views <metric> for the past <window>
      Then the numbers cover that window

      Examples:
        | metric | window  |
        | cost   | 24 hours |
        | tokens | 7 days  |
        | cost   | 90 days |

    @shared @backlog-mobile @backlog-tui
    Scenario: Usage from several environments arrives as each finishes scanning
      Given "laptop" is still scanning and "server" has finished
      When the user views usage for all environments
      Then "server" usage is shown
      And "laptop" is shown as still scanning

    @desktop @backlog-desktop
    Scenario: Usage shows one loading state until the first answer
      Given the first scan of session history is still running
      When the user views usage for the cost metric
      Then "Reading session history…" is the only thing shown, with no empty breakdown headings

    @shared @backlog-mobile @backlog-tui
    Scenario: An environment that cannot report usage is named
      Given "server" is offline
      When the user views usage for all environments
      Then the user is told some environments could not report usage

    @shared @backlog-mobile @backlog-tui
    Scenario: Usage remembers the view the user last chose
      Given the user switched usage to tokens
      When the user opens usage again
      Then it shows tokens

    @shared @backlog-mobile @backlog-tui
    Scenario: An environment on an older server is left out of the totals
      Given "server" runs an older server version
      When the user views usage for all environments
      Then usage says "server runs an older server version and is excluded from totals."
      And the usage of "server" is not counted

    @shared @backlog-mobile @backlog-tui
    Scenario: Usage that could not be read can be read again
      Given the MC cannot read usage
      When the user views cost for the past 7 days
      Then usage says "This environment could not report usage."
      When the MC can read usage again
      And the user refreshes usage
      Then the usage of this environment is shown

    @shared @backlog-mobile @backlog-tui
    Scenario: Refreshing usage fetches prices and reads it again
      Given the user views cost for the past 7 days
      When the user refreshes usage
      Then the MC is asked for the latest model prices
      And usage is read again

    @shared @backlog-mobile @backlog-tui
    Scenario: Usage of one environment leaves the others out
      Given "laptop" is still scanning and "server" has finished
      When the user views usage for "server"
      Then the usage of "server" is shown
      And the usage of this environment is not counted

    # The web's breakdown and environment choices the desktop's Usage page does not draw yet.
    @desktop @backlog-desktop
    Scenario: Usage breaks cost down by model and by day
      Given the user views cost for the past 7 days
      When the user breaks usage down by model
      Then each model lists its tokens and estimated cost, largest first
      When the user breaks usage down by day
      Then each day lists its tokens and estimated cost

    # One line per provider, each measured from zero, as the web's UsageProviderChart. Drawing
    # them and following the pointer are UsageChart.qml's own (tst_UsagePage.qml).
    @desktop
    Scenario: The usage chart draws each provider and reads out a day on hover
      Given Codex and Claude both have usage in the past 7 days
      When the user views cost for the past 7 days
      Then the chart draws Codex and Claude over all 7 days
      When the user hovers a day
      Then that day's cost for each provider is read out

    # "laptop" still shows its last answer, asked over a window ten minutes older.
    @desktop
    Scenario: A refresh still under way keeps every provider on the chart
      Given Codex and Claude both have usage in the past 24 hours
      And the user views cost for the past 24 hours
      When 10 minutes pass and "laptop" is slow to answer
      And the user refreshes usage
      Then the chart still draws Codex and Claude

    @desktop
    Scenario: An hour the clocks repeat says which of the two it is
      Given the user is in "America/New_York" on the night its clocks fall back
      When the user views cost for the past 24 hours
      Then the chart tells the two hours labelled 1 AM apart

    @desktop @backlog-desktop
    Scenario: Each model shows its share of the cost
      Given the user views cost for the past 7 days
      Then each model shows what percentage of the total cost it makes up

    @desktop @backlog-desktop
    Scenario: The user chooses several environments to add up
      Given "laptop", "server" and this environment have usage
      When the user chooses "laptop" and "server" only
      Then usage adds up "laptop" and "server"
      And the usage of this environment is not counted

  Rule: Limits

    @mc
    Scenario: Provider limits are checked when a client asks for providers again
      When a client refreshes providers
      Then the MC checks Codex and Claude rate limits

    @mc
    Scenario: A failed limit check keeps the last known limits
      Given Codex limits were read an hour ago
      When the next limit check fails
      Then the last known Codex limits remain

    @mc
    Scenario: An API key account has no limits to show
      Given Claude is signed in with an API key
      Then Claude limits are reported as unsupported

    @mc
    Scenario Outline: Using a banked Codex reset credit
      Given a Codex account <credits>
      When the user uses a reset credit
      Then the user is told "<message>"

      Examples:
        | credits                              | message                                |
        | with one banked reset credit         | Reset applied. Your windows have cleared. |
        | with no reset credits left           | No reset credit left.                  |
        | whose credit another device redeemed | That credit was already redeemed.      |

    @shared @backlog-mobile @backlog-tui
    Scenario: Limits are pooled per provider with one share per account
      Given two Codex accounts
      When the user views limits
      Then Codex shows one 5-hour number made up of both accounts
      And the account that resets soonest comes first

    @desktop @backlog-desktop
    Scenario: Each account in Limits is told apart by its chip
      Given two Codex accounts
      When the user views limits
      Then each account shows its initials in a colour of its own, the same on every visit
      And an account signed in on a provider instance shows that instance's badge instead

    @shared @backlog-mobile @backlog-tui
    Scenario: Opening limits checks them at most every five minutes
      Given limits were checked two minutes ago
      When the user opens limits
      Then the limits are not checked again

    @shared @backlog-mobile @backlog-tui
    Scenario: Refreshing limits checks them even within five minutes
      Given limits were checked two minutes ago
      When the user opens limits
      And the user refreshes usage
      Then the limits are checked again

    @shared @backlog-mobile @backlog-tui
    Scenario: A provider whose limits could not be read is named
      Given Codex could not read its limits
      When the user views limits
      Then usage says "Codex: Could not read limits."

    @shared @backlog-mobile @backlog-tui
    Scenario: Without limits to show the page says so
      Given no provider reports limits
      When the user views limits
      Then usage says "No provider on the selected environments reports subscription limits."

    @shared @backlog-mobile @backlog-tui
    Scenario: Leaving usage stops following limits
      Given the user views limits
      When the user leaves usage
      Then limits are no longer followed

    # Grok, Cursor and OpenCode Go limits, and the /usage-limits composer command, are in
    # providers/usage-limits.feature.

    @shared @backlog-mobile @backlog-tui
    Scenario: A banked reset credit is spent once the user confirms
      Given Codex has a reset credit banked
      When the user views limits
      Then limits show 1 reset credit banked for Codex
      When the user uses the reset credit and confirms
      Then the user is told "Reset applied. Your windows have cleared."
      And the credit is spent on the Codex instance
      And limits show 0 reset credits banked for Codex

    # The confirmation is UsagePage.qml's own dialog (tst_UsagePage.qml); no feature runner
    # drives it yet.
    @backlog @shared
    Scenario: The user backs out of spending a reset credit
      Given Codex has a reset credit banked
      When the user starts to use the reset credit but cancels
      Then the credit is still banked

    @shared @backlog-mobile @backlog-tui
    Scenario Outline: A reset credit that cannot be used says why
      Given Codex has a reset credit banked
      And <situation>
      When the user uses the reset credit and confirms
      Then the user is told "<message>"

      Examples:
        | situation                                 | message                           |
        | no rate-limit window is in use            | Nothing to reset right now.       |
        | the account has no credit left            | No reset credit left.             |
        | the credit was redeemed on another device | That credit was already redeemed. |

