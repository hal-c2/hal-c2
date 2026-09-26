# Sources:
#   docs/user/usage.md
#   apps/server-ex/lib/hal_c2/usage.ex (server.getUsageSummary, transcript sources, scan cache)
#   apps/server-ex/lib/hal_c2/usage/aggregator.ex (de-duplication, day and hour buckets)
#   apps/server-ex/lib/hal_c2/usage/pricing.ex (LiteLLM rates, server.refreshUsageRates, usagePriceOverrides)
#   apps/server-ex/lib/hal_c2/provider_usage_limits.ex (limits, consumeResetCredit)
#   apps/server-ex/test/node_parity_test.exs (usage summary and rates, consumeResetCredit aligned)
#   packages/contracts/src/usage.ts
#   packages/contracts/src/providerUsageLimits.ts
#   packages/contracts/src/rpc.ts (server.getUsageSummary, server.refreshUsageRates, server.consumeResetCredit)
#   apps/web/src/components/usage/UsagePage.tsx
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (usage.open entry)

Feature: Usage and limits
  Usage adds up token use and estimated cost from each provider's local
  session history, and shows how much of each provider's rate limits is left.
  Cost is an API-equivalent estimate, not a bill.

  Rule: The node summarises usage from session history

    @node
    Scenario: Usage combines every supported provider's history
      Given Codex, Claude Code and Grok have session history on the machine
      When a client asks for the usage summary
      Then the summary has tokens, cache savings and estimated cost per model

    @node
    Scenario: A provider home moved by environment variable is found
      Given Claude Code keeps its history under a custom config directory
      When a client asks for the usage summary
      Then that history is counted

    @node
    Scenario: Two accounts that share a history directory count once
      Given two Codex accounts point at the same history directory
      When a client asks for the usage summary
      Then that history is counted once

    @node
    Scenario: Resumed and forked sessions are not counted twice
      Given a Claude session was resumed into a new transcript
      When a client asks for the usage summary
      Then the repeated turns count once

    @node
    Scenario: A second scan only reads what changed
      Given the node has scanned the history once
      And one transcript has grown since
      When a client asks for the usage summary again
      Then only the new lines of that transcript are read

    @node
    Scenario: History the provider deleted still counts for 90 days
      Given a transcript that was scanned and then removed by its CLI
      When a client asks for the usage summary within 90 days
      Then its usage is still counted

    @node
    Scenario Outline: Usage is bucketed in the user's time zone
      When a client asks for <granularity> usage in "<zone>"
      Then the buckets start at <boundary> in "<zone>"

      # Hourly buckets start at the window start plus whole hours (both servers and the clients' minute-aligned 24-hour window), not at the top of the hour.
      Examples:
        | granularity | zone               | boundary                        |
        | daily       | Atlantic/Reykjavik | midnight                        |
        | hourly      | America/New_York   | each hour from the window start |

    @node
    Scenario: An unknown time zone falls back to UTC
      When a client asks for daily usage in "Mars/Olympus"
      Then the buckets are in UTC

  Rule: Prices

    @node
    Scenario: Prices keep working offline
      Given the node fetched model prices yesterday
      And the machine is offline
      When a client asks for the usage summary
      Then costs use the saved prices

    @node
    Scenario: Refreshing prices fetches them again
      When the user refreshes usage prices
      Then the node fetches the latest model prices

    @node
    Scenario: A custom model price replaces automatic pricing
      Given the user saved a price for "my-model" of 1 USD input and 4 USD output per million tokens
      When a client asks for the usage summary
      Then "my-model" costs are estimated at those rates

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

    @backlog @shared
    Scenario Outline: The user reads usage over a window
      When the user views <metric> for the past <window>
      Then the numbers cover that window

      Examples:
        | metric | window  |
        | cost   | 24 hours |
        | tokens | 7 days  |
        | cost   | 90 days |

    @backlog @shared
    Scenario: Usage from several environments arrives as each finishes scanning
      Given "laptop" is still scanning and "server" has finished
      When the user views usage for all environments
      Then "server" usage is shown
      And "laptop" is shown as still scanning

    @backlog @shared
    Scenario: An environment that cannot report usage is named
      Given "server" is offline
      When the user views usage for all environments
      Then the user is told some environments could not report usage

    @backlog @shared
    Scenario: Usage remembers the view the user last chose
      Given the user switched usage to tokens
      When the user opens usage again
      Then it shows tokens

  Rule: Limits

    @node
    Scenario: Provider limits are checked when a client asks for providers again
      When a client refreshes providers
      Then the node checks Codex and Claude rate limits

    @node
    Scenario: A failed limit check keeps the last known limits
      Given Codex limits were read an hour ago
      When the next limit check fails
      Then the last known Codex limits remain

    @node
    Scenario: An API key account has no limits to show
      Given Claude is signed in with an API key
      Then Claude limits are reported as unsupported

    @node
    Scenario Outline: Using a banked Codex reset credit
      Given a Codex account <credits>
      When the user uses a reset credit
      Then the user is told "<message>"

      Examples:
        | credits                              | message                                |
        | with one banked reset credit         | Reset applied. Your windows have cleared. |
        | with no reset credits left           | No reset credit left.                  |
        | whose credit another device redeemed | That credit was already redeemed.      |

    @backlog @shared
    Scenario: Limits are pooled per provider with one share per account
      Given two Codex accounts
      When the user views limits
      Then Codex shows one 5-hour number made up of both accounts
      And the account that resets soonest comes first

    @backlog @shared
    Scenario: Opening limits checks them at most every five minutes
      Given limits were checked two minutes ago
      When the user opens limits
      Then the limits are not checked again

    # apps/server-ex reads limits for Codex and Claude only (provider_usage_limits/). The same
    # backlog, plus the /usage-limits composer command, is in providers/usage-limits.feature.
    @backlog @node
    Scenario Outline: Other providers report their limits
      Given <provider> is signed in <how>
      Then its <window> limits are shown

      Examples:
        | provider    | how                   | window        |
        | Grok        | with grok login       | allowance     |
        | Cursor      | with a login file     | monthly       |
        | OpenCode Go | on this machine       | usage         |
