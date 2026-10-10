# Sources:
#   apps/mobile/src/features/widgets/ (SubscriptionUsage and AgentActivity widgets)
#   apps/mobile/modules/hal-c2-subscription-widget
#   apps/mobile/app.config.ts (expo-widgets families, frequent updates, push updates)
#   apps/mobile/src/features/usage/ (subscription usage coordinator)
#   apps/mobile/src/widgets/ (subscriptionUsageSnapshot.ts, SubscriptionUsage.tsx, AgentActivity.tsx, SubscriptionUsageCoordinator.tsx, useSubscriptionUsage.ts)
# Provider usage limits are specified in features/providers/. This file covers the
# home screen and lock screen widgets that show them on a phone.

Feature: Home screen and lock screen widgets
  Widgets show subscription limits and agent activity without opening the app. They say
  plainly when their data is stale and open the app at the right place when tapped.

  @backlog @mobile
  Scenario Outline: The usage widget shows the limits the user picked
    Given the user added the subscription usage widget for "<provider>"
    And the user set its period to "<period>"
    Then the widget shows the <shown> limits for "<provider>"

    Examples:
      | provider | period  | shown                 |
      | Codex    | Both    | session and weekly    |
      | Codex    | Session | session               |
      | Claude   | Weekly  | weekly                |

  @backlog @mobile
  Scenario Outline: The usage widget fits every widget size
    When the user adds the subscription usage widget in the <size> size
    Then the widget shows the limits that fit that size

    Examples:
      | size            |
      | small           |
      | medium          |
      | large           |
      | extra large     |
      | lock screen     |

  @backlog @mobile
  Scenario: The lock screen usage widget shows the tightest limit
    Given the session limit is 80% used and the weekly limit is 40% used
    When the user looks at the lock screen usage widget
    Then the widget shows the session limit

  @backlog @mobile
  Scenario: The usage widget refreshes while the app is in the background
    Given the subscription usage widget is on the home screen
    When a provider's usage changes
    Then the widget shows the new usage without the app being opened

  @backlog @mobile
  Scenario: Usage older than 15 minutes asks the user to refresh
    Given the widget's usage was last updated 20 minutes ago
    Then the widget asks the user to open HAL-C2 to refresh

  @backlog @mobile
  Scenario: The app asks for fresh usage at most every five minutes
    Given the app is open and "My MacBook" is connected
    When the app comes to the front again within five minutes of the last ask
    Then the app does not ask "My MacBook" for usage again
    When five minutes have passed
    Then the app asks "My MacBook" for fresh usage

  @backlog @mobile
  Scenario: The app does not ask for usage while it is in the background or the environment is away
    Given the user has a subscription usage widget
    When the app is in the background
    Then the app does not ask any environment for usage
    When the app is open and "My MacBook" is not connected
    Then the app does not ask "My MacBook" for usage

  @backlog @mobile
  Scenario: A widget with many limits keeps the session and weekly limits
    Given a provider reports eight limits including a session limit and a weekly limit
    When the user looks at the usage widget
    Then the widget shows at most six limits
    And the session limit and the weekly limit are among them

  @backlog @mobile
  Scenario: A widget with no connected environment asks the user to connect
    Given the phone is not paired with any environment
    Then the usage widget asks the user to open HAL-C2 to connect
    When the user taps the widget
    Then the app opens to add an environment

  @backlog @mobile
  Scenario Outline: The usage widget explains missing data
    Given <situation>
    Then the widget says "<message>"

    Examples:
      | situation                                  | message                |
      | the provider reports no limits             | No limits available    |
      | the provider does not say when limits reset | Reset time unavailable |

  @backlog @mobile
  Scenario: Tapping the usage widget opens the usage limits
    When the user taps the subscription usage widget
    Then the app opens on the usage limits

  @backlog @mobile
  Scenario: Resizing the usage widget on an Android home screen changes how many limits it shows
    Given the user is on an Android phone
    And several providers report two limits each
    When the user makes the usage widget taller
    Then the widget shows more limits
    When the user makes the usage widget shorter
    Then the widget shows fewer limits

  @backlog @mobile
  Scenario: A widget that is too short shows every provider before any second limit
    Given the user is on an Android phone
    And "Codex" and "Claude" each report a session and a weekly limit
    And the usage widget has room for two limits
    Then the widget shows the session limit of "Codex" and of "Claude"
    And no weekly limit is shown

  @backlog @mobile
  Scenario: A widget that cannot fit every limit counts the rest
    Given the user is on an Android phone
    And the providers report six limits in total
    And the usage widget has room for four
    Then the widget says 2 more

  @backlog @mobile
  Scenario Outline: The usage widget says when it last checked
    Given the user is on an Android phone
    And the widget's usage <state>
    Then the widget's footer reads "<footer>"

    Examples:
      | state                         | footer                         |
      | was last checked at 14:05      | As of the time of that check   |
      | has no time of its last check | Last checked unavailable       |

  @backlog @mobile
  Scenario: A limit is read to a screen reader as one line
    Given the usage widget shows "Codex" session limit at 62% remaining
    When a screen reader focuses that limit
    Then it reads the provider, the limit, the percentage remaining and when it resets together

  @backlog @mobile
  Scenario: The activity widget lists the agents that need the user first
    Given one agent needs approval, one is working and one is done
    When the user looks at the agent activity widget
    Then the agent that needs approval is listed first
    And the widget says 3 agents are active and 1 needs attention

  @backlog @mobile
  Scenario Outline: The activity widget orders agents by how much they need the user
    Given agents that are <first> and <second>
    Then the <first> agent is listed before the <second> agent

    Examples:
      | first            | second   |
      | waiting approval | working  |
      | asking for input | failed   |
      | failed           | working  |
      | working          | done     |

  @backlog @mobile
  Scenario: Tapping an agent in the activity widget opens its thread
    Given the agent activity widget lists "Fix checkout"
    When the user taps "Fix checkout" in the widget
    Then "Fix checkout" is shown

  @backlog @mobile
  Scenario Outline: Agent activity appears on every system surface
    Given agent work is in progress
    Then the agent activity is shown on the <surface>

    Examples:
      | surface               |
      | lock screen           |
      | Dynamic Island        |
      | Apple Watch Smart Stack |
      | CarPlay dashboard     |

  @backlog @mobile
  Scenario: Widgets clear the user's data when the user signs out
    Given the widgets show usage and activity
    When the user removes every environment and signs out
    Then the widgets no longer show the user's usage or threads

  @backlog @mobile
  Scenario: A usage period the provider reports no limit for says so
    Given the user set the Claude usage widget's period to "Weekly"
    And Claude reports a session limit but no weekly limit
    Then the widget says no weekly limit was reported for Claude

  @backlog @mobile
  Scenario: Pooled accounts are labelled as pooled on the usage widget
    Given two Codex accounts are pooled
    Then the usage widget labels Codex as "2 accounts · pooled"

  @backlog @mobile
  Scenario: Usage is treated as out of date once a limit resets
    Given the widget shows a Codex limit that resets in 3 minutes
    When 3 minutes pass without the app being opened
    Then the widget asks the user to open HAL-C2 to refresh instead of showing the old percentage

  @backlog @mobile
  Scenario: A failure anywhere outweighs a newer success in the activity summary
    Given one agent failed and a newer one finished successfully and nothing else is active
    Then the activity widget summarises the work as failed

  @backlog @mobile
  Scenario: Tapping the activity widget opens the thread that needs the user
    Given the activity widget lists one agent working and one waiting for approval
    When the user taps the widget outside any single agent
    Then the thread waiting for approval is shown
