# Sources:
#   apps/mobile/src/features/widgets/ (SubscriptionUsage and AgentActivity widgets)
#   apps/mobile/modules/t3-subscription-widget
#   apps/mobile/app.config.ts (expo-widgets families, frequent updates, push updates)
#   apps/mobile/src/features/usage/ (subscription usage coordinator)
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
    Then the widget asks the user to open T3 Code to refresh

  @backlog @mobile
  Scenario: A widget with no connected environment asks the user to connect
    Given the phone is not paired with any environment
    Then the usage widget asks the user to open T3 Code to connect
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
