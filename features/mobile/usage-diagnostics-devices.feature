# Sources:
#   apps/mobile/src/features/usage/UsageRouteScreen.tsx (usage and limits tabs, ranges, filter)
#   apps/mobile/src/features/usage/UsageLimitsSection.tsx (reset credits)
#   apps/mobile/src/features/usage/UsageLimitsPooled.tsx (accounts, pace, reveal email)
#   apps/mobile/src/features/usage/UsageDailyChart.tsx
#   apps/mobile/src/features/diagnostics/SettingsDiagnosticsRouteScreen.tsx
#   apps/mobile/src/features/diagnostics/crash-log-model.ts
#   apps/mobile/src/features/observability/tracing.ts
#   apps/mobile/src/features/devices/ (device viewer, stream fallbacks, device options)
#   apps/mobile/src/features/showcase/ (screenshot capture scenes, sample environments)
#   docs/user/devices.md (mobile device viewer)
# Usage accounting and devices are specified in features/providers/ and the node domains.
# This file covers the phone screens that show them.

Feature: Usage, diagnostics and devices on a phone
  The phone shows what agents cost across environments, keeps enough crash evidence to
  report a problem, and lets the user watch and drive a device an agent is using.

  Background:
    Given the phone is paired with "My MacBook" and "Office Mac"

  @backlog @mobile
  Scenario Outline: The user looks at usage over a period
    When the user opens usage for the past <range>
    Then usage from both environments over the past <range> is shown

    Examples:
      | range    |
      | 24 hours |
      | 7 days   |
      | 30 days  |
      | 90 days  |

  @backlog @mobile
  Scenario: The user switches usage between cost and tokens
    Given the user is looking at usage
    When the user shows tokens
    Then usage is shown as processed tokens
    When the user shows cost
    Then usage is shown as raw token cost

  @backlog @mobile
  Scenario: Usage breaks down by provider and by model
    When the user opens usage
    Then usage totals are shown per provider
    And usage totals are shown per model

  @backlog @mobile
  Scenario: Models without a price are marked unpriced
    Given a model has no known price
    When the user opens usage
    Then that model is shown as unpriced

  @backlog @mobile
  Scenario: The user narrows usage to one environment and back
    When the user shows usage only for "Office Mac"
    Then only usage from "Office Mac" is counted
    When the user shows usage for all environments
    Then usage from both environments is counted

  @backlog @mobile
  Scenario Outline: Each environment says how current its usage is
    Given "Office Mac" <situation>
    When the user opens usage
    Then "Office Mac" is described as "<status>"

    Examples:
      | situation                                   | status                                  |
      | is disconnected but usage was saved before  | Disconnected · showing saved usage      |
      | runs a server too old to report usage       | Older server · excluded from usage totals |
      | failed to report usage but was saved before | Usage unavailable · showing saved totals |
      | reported usage just now                     | Usage up to date                        |

  @backlog @mobile
  Scenario: With no environment connected, usage asks the user to connect one
    Given the phone has no paired environments
    When the user opens usage
    Then the user is told to connect an environment to see usage

  @backlog @mobile
  Scenario: The user looks at subscription limits and pace
    When the user opens usage limits
    Then each provider account's limits are shown
    And each limit says whether usage is ahead of, on or under pace

  @backlog @mobile
  Scenario: The user reveals and hides an account's email
    Given the usage limits show a provider account
    When the user reveals the account's email
    Then the full email is shown
    When the user hides it again
    Then the email is masked

  @backlog @mobile
  Scenario: The user spends a reset credit after confirming
    Given the account has a reset credit banked
    When the user uses a reset credit and confirms
    Then the user is told the reset was applied and the windows have cleared

  @backlog @mobile
  Scenario: The user backs out of spending a reset credit
    Given the account has a reset credit banked
    When the user starts to use a reset credit but cancels
    Then the credit is still banked

  @backlog @mobile
  Scenario Outline: A reset credit that cannot be used says why
    Given <situation>
    When the user uses a reset credit and confirms
    Then the user is told "<message>"

    Examples:
      | situation                              | message                             |
      | no rate-limit window is in use         | Nothing to reset right now.         |
      | the account has no credit left         | No reset credit left.               |
      | the credit was redeemed on another device | That credit was already redeemed. |

  @backlog @mobile
  Scenario: No startup crashes is reported plainly
    Given the app has not crashed during launch in the last 7 days
    When the user opens diagnostics
    Then the user is told there have been no startup crashes

  @backlog @mobile
  Scenario: The user copies a startup crash report
    Given the app crashed during launch yesterday
    When the user opens diagnostics
    Then the crash is listed with its error description
    When the user copies the crash report
    Then the crash report is on the clipboard

  @backlog @mobile
  Scenario: Builds that keep no crash log say so
    Given the user runs a build that does not keep startup crash records
    When the user opens diagnostics
    Then the user is told the crash log is unavailable in this build

  @backlog @mobile
  Scenario: A build configured for tracing reports what the app was doing
    Given the app build is configured to send traces
    When the phone connects to "My MacBook"
    Then a trace of the connection is sent with the app's version and device

  @backlog @mobile
  Scenario: The user watches and controls a device an agent is using
    Given an agent in "Fix checkout" has an iOS simulator open
    When the user opens the device viewer from "Fix checkout"
    Then the simulator's live screen is shown
    And the user's touches reach the simulator

  @backlog @mobile
  Scenario: The user chooses among several open devices
    Given an agent in "Fix checkout" has an iOS simulator and an Android emulator open
    When the user opens the device viewer from "Fix checkout"
    Then the user is asked which device to view

  @backlog @mobile
  Scenario: Closing the device viewer leaves the device to the agent
    Given the user is viewing the agent's simulator
    When the user closes the device viewer
    Then streaming stops
    And the simulator stays open for the agent

  @backlog @mobile
  Scenario Outline: The device viewer adapts to an insecure remote connection
    Given the phone reaches "My MacBook" over plain HTTP from another network
    And the user is on <platform>
    When the user opens the device viewer
    Then <result>

    Examples:
      | platform       | result                                        |
      | an iPhone      | the device is shown as a stream of still images |
      | an Android phone | the user is told video is unavailable       |

  @backlog @mobile
  Scenario: A dropped device stream can be reconnected
    Given the device stream stopped unexpectedly
    Then the user is told to reconnect to try again
    When the user reloads the stream
    Then the device's live screen is shown again

  @backlog @mobile
  Scenario Outline: The user controls the device from its options
    Given the user is viewing the agent's simulator
    When the user chooses to <action>
    Then <result>

    Examples:
      | action                    | result                                   |
      | rotate the device         | the simulator rotates                    |
      | open the app switcher     | the simulator shows its app switcher     |
      | shut down the device      | the simulator shuts down                 |
      | check device tool versions | the installed device tool versions are listed |

  @backlog @mobile
  Scenario: A device that fails to shut down says so
    Given the simulator cannot be shut down
    When the user chooses to shut down the device
    Then the user is told the device could not be shut down

  # Showcase scenes drive store screenshots. The need to produce consistent screenshots of
  # the phone app stays with the QML client, so it is kept as backlog.
  @backlog @mobile
  Scenario Outline: A screenshot run opens a scene with sample data
    Given the app is launched for a screenshot run of the <scene> scene in <orientation>
    Then the <scene> scene is shown with sample environments in <orientation>
    And the app reports when the scene is ready to capture

    Examples:
      | scene        | orientation |
      | threads      | portrait    |
      | thread       | portrait    |
      | terminal     | landscape   |
      | review       | landscape   |
      | environments | portrait    |

  @backlog @mobile
  Scenario: A screenshot run with an unknown theme keeps the user's theme
    Given the app is launched for a screenshot run with a theme it does not know
    Then the user's stored theme is left unchanged
