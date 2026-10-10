# Sources:
#   docs/user/usage.md (Understand your usage, Set custom model prices)
#   apps/server-ex/lib/hal_c2/usage.ex (server.getUsageSummary, server.refreshUsageRates, windows, fingerprints, 90-day cache)
#   apps/server-ex/lib/hal_c2/usage/transcripts.ex (Claude, Codex and Grok Build transcripts)
#   apps/server-ex/lib/hal_c2/usage/pricing.ex (rate table, daily TTL, snapshot fallback, usagePriceOverrides, cost sources)
#   apps/server-ex/lib/hal_c2/usage/aggregator.ex
#   apps/web/src/routes/usage.tsx, apps/web/src/components/usage/ (environment filter, model prices dialog)
#   packages/contracts/src/usage.ts (UsageSummary, UsageReadError, cost sources)
#   apps/server/src/usage/usagePricing.ts (bare family names unpriced, bracket suffix stripped)
#   apps/server/src/usage/usageTranscripts.ts (Codex token_count dedupe, fork-copy suppression)
#   apps/server/src/usage/UsageLimitSources.ts (provider with no history folder)
#   apps/server/src/provider/CodexTurnTokenUsage.ts, apps/server/src/provider/ClaudeTurnTokenUsage.ts (per-turn usage records)
#   apps/server/src/usage/usageScanCache.ts, usageTranscriptReader.ts, UsageService.ts (resume guard, tail lines, saved scan, shared scans, price floor)

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

  @backlog @mc
  Scenario: A bare model family name is marked unpriced rather than guessed
    Given a turn recorded only the model family name "opus"
    When the user opens Usage
    Then that model is marked unpriced rather than priced at one generation's rate

  @backlog @mc
  Scenario: A model's larger context variant is priced at its base rate
    Given a turn on a model recorded with a bracketed context-size suffix such as "[1m]"
    When the user opens Usage
    Then that model is priced at the rate of its base model

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

  @backlog @mc
  Scenario: Codex repeating an unchanged token count is counted once
    Given a Codex session re-sends the same token count at a stream boundary
    When the user opens Usage
    Then the repeated count adds nothing to the totals

  # Legacy: apps/server/src/usage/usageTranscriptReader.ts (tailRecords), usageScanCache.ts
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage.ex (tail)
  @backlog @mc
  Scenario: A transcript line the CLI is still writing is counted once it is complete
    Given a transcript whose last line has no line ending yet
    When the user opens Usage
    Then that unfinished line is counted in the totals
    When the CLI finishes the line and the user opens Usage again
    Then the line is counted once

  # Legacy: apps/server/src/usage/usageTranscriptReader.ts (guard hash, shrunk file)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage.ex (size and mtime resume)
  @backlog @mc
  Scenario Outline: A transcript that did not just grow is read again from the start
    Given the user opened Usage and a transcript was read
    And the transcript was then <change>
    When the user opens Usage again
    Then the whole transcript is read again
    And its earlier lines are not counted twice

    Examples:
      | change                                                  |
      | rewritten with different text but the same start        |
      | replaced by a shorter file                              |

  # Legacy: apps/server/src/usage/usageScanCache.ts (decodeScanCache, cache version, corrupt rows)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage.ex (@cache_version)
  @backlog @mc
  Scenario Outline: A saved scan the MC cannot trust is discarded
    Given the MC saved its scan of the history before it restarted
    And the saved scan <damage>
    When the user opens Usage
    Then the affected transcripts are read from the start
    And the usage page is still shown

    Examples:
      | damage                                         |
      | was written by an older version of the MC      |
      | is not readable                                |
      | has one entry that is damaged                  |

  # Legacy: apps/server/src/usage/UsageService.ts (in-flight scans keyed by request and prices)
  @backlog @mc
  Scenario: Identical requests that overlap share one scan
    Given the user opened Usage in two clients at the same moment
    When both ask for the same window and time zone
    Then the transcripts are scanned once and both get the same totals

  # Legacy: apps/server/src/usage/UsageService.ts ("does not share an in-flight scan after custom prices change")
  @backlog @mc
  Scenario: A scan under way does not answer a request made after a price changed
    Given a usage scan is under way
    When the user saves a custom price and asks for usage
    Then the new request gets totals priced with the new price

  # Legacy: apps/server/src/usage/UsageService.ts ("does not orphan an in-flight scan when its first caller is interrupted")
  @backlog @mc
  Scenario: A scan other callers wait for survives its first caller leaving
    Given two clients wait on the same usage scan
    When the client that started it disconnects
    Then the other client still receives the totals

  # Legacy: apps/server/src/usage/UsageService.ts (RATES_REFRESH_FLOOR_MS, "refetches a rate table inside its TTL only when the client asks")
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage/pricing.ex (@refresh_floor_ms)
  @backlog @mc
  Scenario: Refreshing again within a minute does not fetch prices again
    Given the user refreshed Usage and prices were fetched ten seconds ago
    When the user refreshes Usage again
    Then the price table is not fetched again
    And an ordinary open of Usage never fetches inside the daily refresh

  # Legacy: apps/server/src/usage/UsageService.ts (pricing fetched while transcripts stream, 10 s timeout)
  @backlog @mc
  Scenario: A price table that is slow to fetch does not hold up the scan
    Given the price table has to be fetched and the source is slow
    When the user opens Usage
    Then the transcripts are scanned while the table is fetched
    And a fetch that takes longer than 10 seconds is treated as failed

  # Legacy: apps/server/src/usage/UsageService.ts (collectDirs: MTIME_SLACK_MS)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage.ex (@mtime_slack_ms)
  @backlog @mc
  Scenario: Only transcripts touched near the window are read, and only records inside it count
    Given a Claude transcript last changed 30 hours before the window began, holding records from before and inside the window
    And another transcript last changed 40 hours before the window began
    When the user opens Usage for that window
    Then the first transcript is read and only its records inside the window are counted
    And the second transcript is not opened

  # Legacy: apps/server/src/usage/UsageService.ts (codexEventOccurrences)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage.ex (codex_key)
  @backlog @mc
  Scenario: A moved copy of a Codex rollout counts once but equal events inside one rollout all count
    Given a Codex rollout was copied into another folder
    And one rollout has two token counts with identical time, model and totals
    When the user opens Usage
    Then each event of the copied rollout is counted once
    And the two identical events inside a single rollout are both counted

  # Legacy: apps/server/src/usage/usageTranscripts.ts (Grok reads updates.jsonl only)
  # Likely already implemented: apps/server-ex/lib/hal_c2/usage/transcripts.ex
  @backlog @mc
  Scenario: Only Grok's session update log is read as usage
    Given a Grok session folder with "updates.jsonl" and other JSONL files
    When the user opens Usage
    Then only "updates.jsonl" contributes to the totals

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

  # Clients leave a missing source out of the totals; saved records keep counting.
  @backlog @mc
  Scenario: A provider with no history folder on an environment is noted and its saved usage still counts
    Given an environment where Grok has never written a history folder
    And the MC counted Grok usage there before
    When the user opens Usage
    Then the environment says it has no transcript directory for Grok
    And the Grok usage counted before is still in the totals

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

  @desktop
  Scenario: A custom price is saved to several environments at once
    Given two connected environments
    When the user saves a custom price for "my-model" to both
    Then each environment reports that the price saved

  @desktop
  Scenario: An offline environment is marked not saved and can be retried
    Given one of two selected environments is offline
    When the user saves a custom price to both
    Then the offline environment is marked "Not saved"
    When the environment reconnects and the user chooses "Retry failed saves"
    Then the price is saved there without writing again to the other environment

  @desktop
  Scenario: Environments with different prices show the price as mixed
    Given two environments with different prices for "my-model"
    When the user opens Model prices with both selected
    Then the price of "my-model" is shown as "Mixed"

  @desktop
  Scenario: A reset marked for removal can be undone before saving
    Given the user marked "claude-sonnet" to reset to automatic
    When the user undoes the reset before saving
    Then the custom price of "claude-sonnet" is kept

  @tui
  Scenario: The TUI shows usage totals
    When the user opens Usage in the TUI
    Then tokens and estimated cost per provider are shown

  # Per-turn totals of apps/server/src/provider/CodexTurnTokenUsage.ts and ClaudeTurnTokenUsage.ts,
  # recorded on each provider turn (they feed the usage analytics, not the Usage page).
  @backlog @mc
  Scenario: A finished turn records how many tokens it used
    Given a Codex turn that read 12000 tokens, 9000 of them cached, and wrote 800
    When the turn completes
    Then the turn is recorded with complete usage of 12000 input and 800 output tokens
    And the cached tokens are not above the input tokens

  @backlog @mc
  Scenario Outline: A turn that did not finish records its usage as partial
    Given a <provider> turn that used some tokens
    When the turn ends <ending>
    Then the turn's usage is recorded as partial

    Examples:
      | provider | ending                |
      | Codex    | interrupted by user   |
      | Codex    | with an error         |
      | Claude   | interrupted by user   |
      | Claude   | with an error         |

  @backlog @mc
  Scenario Outline: A turn whose provider reported no usage records it as unavailable
    Given a <provider> turn for which the provider reported no token counts
    When the turn ends
    Then the turn's usage is recorded as unavailable

    Examples:
      | provider |
      | Codex    |
      | Claude   |

  @backlog @mc
  Scenario: Codex counts only what the turn used of a thread-wide total
    Given a Codex thread whose running total was 50000 tokens before a turn
    When the turn ends with a running total of 53000 tokens
    Then the turn is recorded as having used 3000 tokens

  @backlog @mc
  Scenario: Usage that arrives after a turn ended is not added to the next turn
    Given a Codex turn has ended
    When Codex reports a late token count for it during the next turn
    Then the late count is not recorded against the next turn

  @backlog @mc
  Scenario: A turn's usage says when subagents ran in it
    Given a Claude turn in which the agent started a subagent
    When the turn completes
    Then the turn's usage says it covers the main agent only
    And it says subagents ran
