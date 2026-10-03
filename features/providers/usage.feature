# Sources:
#   docs/user/usage.md (Understand your usage, Set custom model prices)
#   apps/server-ex/lib/hal_c2/usage.ex (server.getUsageSummary, server.refreshUsageRates, windows, fingerprints, 90-day cache)
#   apps/server-ex/lib/hal_c2/usage/transcripts.ex (Claude, Codex and Grok Build transcripts)
#   apps/server-ex/lib/hal_c2/usage/pricing.ex (rate table, daily TTL, snapshot fallback, usagePriceOverrides, cost sources)
#   apps/server-ex/lib/hal_c2/usage/aggregator.ex
#   apps/web/src/routes/usage.tsx, apps/web/src/components/usage/ (environment filter, model prices dialog)
#   packages/contracts/src/usage.ts (UsageSummary, UsageReadError, cost sources)

Feature: Usage
  Usage adds up token use and estimated API-equivalent cost from the provider CLIs' own
  session history, so work done outside HAL-C2 counts too. Each provider plugin that
  keeps transcripts contributes them; the MC prices them and the clients combine
  environments.

  Background:
    Given a connected environment with Codex, Claude and Grok history

  @mc
  Scenario: Usage totals tokens and cost per day, provider and model
    When the user opens Usage for the last seven days
    Then tokens, cache savings and estimated cost are shown per day, provider and model

  @mc
  Scenario: Usage can be read per hour for up to a day
    When the user asks for hourly usage over the last twelve hours
    Then usage is shown per hour

  @mc
  Scenario Outline: A usage window that cannot be read is refused
    When the user asks for usage <window>
    Then the request is refused with "<detail>"

    Examples:
      | window                                  | detail                                                                   |
      | from 2026-09-10 until 2026-09-01        | sinceDay '2026-09-10' is after untilDay '2026-09-01'                     |
      | from "yesterday"                        | sinceDay 'yesterday' is not a valid date                                 |
      | per hour over two days                  | Hourly usage window must be greater than zero and at most 24 hours       |
      | per hour without start and end instants | Hourly usage requires valid sinceTime and untilTime instants            |
      | without a time zone                     | sinceDay, untilDay, and timeZone are required                            |

  @mc
  Scenario: Work done in the CLI outside HAL-C2 is counted
    Given the user ran Claude Code directly in a terminal yesterday
    When the user opens Usage
    Then yesterday's Claude usage includes that session

  @mc
  Scenario: Grok turns without a completed-turn record are not counted
    Given a Grok session whose last turn never completed
    When the user opens Usage
    Then that turn is missing from the totals

  @mc
  Scenario: A cost reported by the provider is used as is
    Given a Grok turn that reported its own cost
    When the user opens Usage
    Then that turn's cost is the provider's reported cost

  @mc
  Scenario: Models without a known price are marked unpriced
    Given a turn on a model missing from the price table
    When the user opens Usage
    Then that model's cost is marked unpriced

  @mc
  Scenario: Usage uses a saved copy of prices when the price table cannot be fetched
    Given the MC fetched the price table before
    And the price table cannot be fetched now
    When the user opens Usage
    Then costs use the saved price table

  @mc
  Scenario: Without any price table every model is unpriced
    Given the MC has never fetched the price table and cannot fetch it now
    When the user opens Usage
    Then every model is marked unpriced

  @mc
  Scenario: Refreshing fetches new prices ahead of the daily refresh
    Given a new model appeared with no cost
    When the user refreshes Usage
    Then the price table is fetched again
    And the new model is priced when the table knows it

  @mc
  Scenario: A custom model price replaces automatic pricing
    Given the user saved a custom price for "my-model" of 1 USD input and 2 USD output per million tokens
    When the user opens Usage
    Then "my-model" is priced with the custom rates
    And a provider-reported cost for "my-model" is replaced by the custom price

  @mc
  Scenario: Blank cache rates use the input rate
    Given the user saved a custom price for "my-model" without cache rates
    When the user opens Usage
    Then cache reads and writes of "my-model" are priced at its input rate

  @mc
  Scenario: Resetting a custom price returns the model to automatic pricing
    Given the user saved a custom price for "claude-sonnet"
    When the user resets "claude-sonnet" to automatic
    Then "claude-sonnet" is priced from the price table again

  @mc
  Scenario: Each account's history counts, including disabled accounts
    Given two Claude accounts with their own homes, one of them disabled
    When the user opens Usage
    Then both accounts' history is counted

  @mc
  Scenario: A home set through the account's environment is followed
    Given a Codex account whose CODEX_HOME points at "~/work-codex"
    When the user opens Usage
    Then history under "~/work-codex" is counted

  @mc
  Scenario: A history directory shared by two accounts counts once
    Given two accounts that read the same history directory
    When the user opens Usage
    Then that history is counted once

  @mc
  Scenario: A history directory seen by two environments counts once
    Given two environments on the same machine that read the same history directory
    When the user opens Usage with both environments selected
    Then that history is counted once

  @mc
  Scenario: A repeat scan reads only what changed
    Given the user opened Usage a minute ago
    And one transcript grew since
    When the user opens Usage again
    Then only the new lines of that transcript are read

  @mc
  Scenario: History cleaned up by the CLI still counts for 90 days
    Given a transcript that was counted last week and has since been deleted by the CLI
    When the user opens Usage
    Then last week's totals still include it

  @mc
  Scenario: A scan that fails is reported
    Given the transcripts cannot be scanned
    When the user opens Usage
    Then the user is told "Transcripts could not be scanned."

  @desktop @mobile @backlog-mobile
  Scenario: Usage can be filtered by environment
    Given two connected environments
    When the user selects only one environment in Usage
    Then costs, tokens and limits are shown for that environment only

  @desktop @mobile @backlog-mobile
  Scenario: Environments still scanning are shown as they finish
    Given two connected environments, one slow to scan
    When the user opens Usage
    Then the fast environment's results appear first
    And the slow environment is shown as still scanning until it responds

  @backlog @desktop
  Scenario: A custom price is saved to several environments at once
    Given two connected environments
    When the user saves a custom price for "my-model" to both
    Then each environment reports that the price saved

  @backlog @desktop
  Scenario: An offline environment is marked not saved and can be retried
    Given one of two selected environments is offline
    When the user saves a custom price to both
    Then the offline environment is marked "Not saved"
    When the environment reconnects and the user chooses "Retry failed saves"
    Then the price is saved there without writing again to the other environment

  @backlog @desktop
  Scenario: Environments with different prices show the price as mixed
    Given two environments with different prices for "my-model"
    When the user opens Model prices with both selected
    Then the price of "my-model" is shown as "Mixed"

  @backlog @desktop
  Scenario: A reset marked for removal can be undone before saving
    Given the user marked "claude-sonnet" to reset to automatic
    When the user undoes the reset before saving
    Then the custom price of "claude-sonnet" is kept

  @backlog @tui
  Scenario: The TUI shows usage totals
    When the user opens Usage in the TUI
    Then tokens and estimated cost per provider are shown
