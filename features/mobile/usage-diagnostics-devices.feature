# Sources:
#   apps/mobile/src/features/usage/UsageRouteScreen.tsx (usage and limits tabs, ranges, filter)
#   apps/mobile/src/features/usage/UsageLimitsSection.tsx (reset credits)
#   apps/mobile/src/features/usage/UsageLimitsPooled.tsx (accounts, pace, reveal email)
#   apps/mobile/src/features/usage/UsageDailyChart.tsx
#   apps/mobile/src/features/diagnostics/SettingsDiagnosticsRouteScreen.tsx
#   apps/mobile/src/features/diagnostics/crash-log-model.ts
#   apps/mobile/src/features/observability/tracing.ts
#   apps/mobile/src/features/devices/ (device viewer, stream fallbacks, device options)
#   apps/mobile/src/features/devices/DevicePreviewRouteScreen.tsx (host retry, buttons, close when no device)
#   apps/mobile/src/features/devices/DeviceStreamWebView.tsx (start timeout, one automatic restart)
#   apps/mobile/src/features/devices/device-preview-button.tsx (device count)
#   apps/mobile/src/features/showcase/ (screenshot capture scenes, sample environments)
#   docs/user/devices.md (mobile device viewer)
# Usage accounting and devices are specified in features/providers/ and the MC domains.
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
  Scenario: Usage opens on its limits unless a link asks for the usage totals
    When the user opens usage from the settings
    Then the limits are shown
    When the user opens usage from a link that asks for the usage totals
    Then the usage totals are shown

  @backlog @mobile
  Scenario Outline: With every environment left out, usage asks to select one
    Given the user shows <tab> for no environment at all
    Then the user is told to select an environment to see <tab>

    Examples:
      | tab    |
      | usage  |
      | limits |

  @backlog @mobile
  Scenario: A period with no activity says so
    Given no agent did anything in the past 7 days
    When the user opens usage for the past 7 days
    Then the user is told there was no activity in this window

  @backlog @mobile
  Scenario: Environments that share transcripts are named when they are counted once
    Given "My MacBook" and "Office Mac" read the same transcript directory
    When the user opens usage
    Then the user is told which transcript directory was counted once across environments

  @backlog @mobile
  Scenario Outline: An environment says when its usage is still on its way
    Given "Office Mac" <situation>
    When the user opens usage
    Then "Office Mac" is described as "<status>"

    Examples:
      | situation                                          | status                |
      | has not connected yet and has no saved usage       | Waiting for connection… |
      | is loading usage for the first time                | Loading usage…        |
      | is refreshing usage it has saved                   | Updating usage…       |
      | failed to report usage and has none saved          | Usage unavailable     |

  @backlog @mobile
  Scenario: The environment filter marks environments that are still loading
    Given "Office Mac" is still loading usage
    When the user looks at the usage environment filter
    Then the filter says some environments are loading

  @backlog @mobile
  Scenario: The user opens an account from the limits to see its details
    Given the limits pool two Codex accounts
    When the user opens one account
    Then the account's name, plan and masked email are shown
    And the time its window resets is shown
    And the environments it is signed in on are listed
    When the user reveals the email
    Then the full email is shown

  @backlog @mobile
  Scenario: An account's details say how much of the pool its reset gives back
    Given the limits pool two Codex accounts
    And the account's window resets soon
    When the user opens the account
    Then the account's details say how much of the pool it restores

  @backlog @mobile
  Scenario: An account that stops reporting limits says so on its details
    Given the user has an account's details open
    When that account stops reporting limits on the selected environments
    Then the details say the account is no longer reporting limits

  @backlog @mobile
  Scenario: Limits that could not be refreshed keep the last known values and say so
    Given "Office Mac" could not refresh limits
    When the user opens usage limits
    Then the last known limits are shown
    And the user is told "Office Mac" could not refresh limits

  @backlog @mobile
  Scenario Outline: Reset credits say what is banked
    Given the account has <credits> banked
    When the user opens usage limits
    Then the account's credits are described as "<summary>"

    Examples:
      | credits                                | summary                                          |
      | no reset credit                        | No reset credits banked                          |
      | one reset credit that expires in time  | 1 reset credit banked, with when the next expires |
      | three reset credits                    | 3 reset credits banked                           |

  @backlog @mobile
  Scenario: A reset credit that fails for another reason says it could not be used
    Given the account has a reset credit banked
    And the environment cannot reach the provider
    When the user uses a reset credit and confirms
    Then the user is told the reset credit could not be used

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

  @backlog @mobile
  Scenario: The device viewer closes when the thread has no device left open
    Given the user is viewing the agent's simulator
    When the agent closes the simulator
    Then the device viewer closes by itself

  @backlog @mobile
  Scenario: Device buttons wait until the device takes input
    Given the user opens the device viewer from "Fix checkout"
    And the device is not yet taking input
    Then the home, app switcher and rotate buttons cannot be used
    When the device starts taking input
    Then the home button can be used

  @backlog @mobile
  Scenario Outline: The device options only offer buttons the platform has
    Given the user is viewing an agent's <device>
    When the user opens the device options
    Then "<offered>" is offered
    And "<not offered>" is not offered

    Examples:
      | device           | offered       | not offered   |
      | iOS simulator    | Rotate device | Back          |
      | Android emulator | Back          | Rotate device |

  @backlog @mobile
  Scenario: The device viewer stops streaming while the app is in the background
    Given the user is viewing the agent's simulator
    When the user switches to another app
    Then the device stream stops
    When the user returns to HAL-C2
    Then the device's live screen is shown again

  @backlog @mobile
  Scenario: A device host that failed can be retried from the viewer
    Given the environment's device host "Build Mac" failed to start
    When the user opens the device options
    Then "Retry Build Mac" is offered
    When the user chooses "Retry Build Mac"
    Then the environment tries "Build Mac" again

  @backlog @mobile
  Scenario: The device viewer explains who updates the device tools
    Given the user is viewing the agent's simulator
    When the user chooses device tool versions
    Then the user is told which tools are installed on that device's host
    And the user is told whether HAL-C2 or the user updates them

  @backlog @mobile
  Scenario: A device viewer that cannot get access to the device says why and can retry
    Given the environment cannot hand the phone access to the device
    When the user opens the device viewer
    Then the user is told why the device is unavailable
    When the user chooses to retry
    Then the phone asks the environment for access again

  @backlog @mobile
  Scenario: A device viewer that never starts says so
    Given the device viewer has not started streaming after 15 seconds
    Then the user is told the viewer could not start
    And the user is offered to reconnect

  @backlog @mobile
  Scenario: A device viewer that stops working restarts once by itself
    Given the user is viewing the agent's simulator
    When the viewer stops working
    Then the viewer restarts and the device's live screen is shown again
    When the viewer stops working again before the screen is shown
    Then the user is told the viewer stopped
    And the user is offered to reconnect

  @backlog @mobile
  Scenario Outline: A thread says how many devices are open
    Given the agent in "Fix checkout" has <count> devices open
    Then the thread offers <offer>

    Examples:
      | count | offer                              |
      | 1     | to view one device                 |
      | 3     | to view 3 devices, showing the 3   |

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
