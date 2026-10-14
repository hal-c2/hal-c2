# Sources:
#   apps/server-ex/lib/hal_c2/slack.ex (the MC's Slack connection: Socket Mode and slack_elixir's Web API)
#   apps/server-ex/lib/hal_c2/slack/socket.ex (the Socket Mode connection; events for the bot's workspace and app)
#   apps/server-ex/lib/hal_c2/slack/bot.ex (Slack events turned into plugin events, dropped once their connection stopped)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (Host.slack, gated by slack:read and slack:write)
#   apps/server-ex/lib/hal_c2/plugins.ex (Slack events delivered to plugins' handle_event)
#   apps/server-ex/lib/hal_c2/plugins/package.ex (permission ids and their labels)
#   packages/contracts/src/plugin.ts (PluginPermissionId)
#   https://hex.pm/packages/slack_elixir, Slack's Web API and Socket Mode

Feature: Slack for MC plugins
  An MC connected to a Slack workspace (Settings → Integrations → Slack) lends that
  connection to its plugins. With `slack:read` a plugin lists the channels the bot is in,
  reads a message's replies, and hears messages that mention the bot, replies in threads
  the bot started, and slash commands. With `slack:write` it posts, replies, edits what it
  posted and answers slash commands. The MC holds the tokens; plugins never see them.

  Background:
    Given an MC connected to the Slack workspace "acme" as the bot "HAL"
    And the bot is in the channel "#planning"

  @mc
  Scenario: A plugin posts a message and learns where it went
    Given a plugin granted "slack:write"
    When it posts "Plan is on track" to "#planning"
    Then Slack is asked to post "Plan is on track" to "#planning"
    And the plugin gets the channel and the message's timestamp

  @mc
  Scenario: A plugin replies in a message's thread and edits what it posted
    Given a plugin granted "slack:write" that posted "Plan is on track" to "#planning"
    When it replies "Two tasks moved" in that message's thread
    And it edits "Plan is on track" to "Plan is at risk"
    Then Slack is asked to post "Two tasks moved" in the thread of "Plan is on track"
    And Slack is asked to change "Plan is on track" to "Plan is at risk"

  @mc
  Scenario: A plugin lists the channels the bot is in
    Given a plugin granted "slack:read"
    When it lists the Slack channels
    Then "#planning" is listed with its id

  @mc
  Scenario: A plugin reads the replies to a message
    Given a plugin granted "slack:read"
    And "dana" replied "Can we slip docs?" to the bot's message in "#planning"
    When it reads the replies to that message
    Then it gets "Can we slip docs?" from "dana"

  @mc
  Scenario Outline: What happens in Slack reaches plugins granted slack:read
    Given the plugins "planner", granted "slack:read", and "quiet", which is not
    When <something happens> in Slack
    Then "planner" is handed a "<event>" event with the channel, the user and the text
    And "quiet" is handed nothing

    # Slack sends a message that mentions the bot twice, as itself and as a mention, but
    # only once in a direct message, where it sends no mention.
    Examples:
      | something happens                                            | event         |
      | "dana" mentions "HAL" in "#planning"                         | slack.mention |
      | "dana" mentions "HAL" in a reply to the bot's direct message | slack.mention |
      | "dana" replies in the thread of a message the bot posted     | slack.reply   |
      | "dana" runs the slash command "/planner status"              | slack.command |

  # One Slack app installed in several workspaces hears them all on one Socket Mode
  # connection, while the bot token answers for one.
  @mc
  Scenario Outline: What happens outside the bot's workspace and app does not reach plugins
    Given the plugins "planner", granted "slack:read", and "quiet", which is not
    When "dana" mentions "HAL" <elsewhere>, and then in "#planning"
    Then "planner" is handed only the mention in "#planning"

    Examples:
      | elsewhere                                   |
      | in a workspace the bot does not belong to   |
      | in an event Slack sends for another app     |

  # A mention waits on Slack to name its author; the connection may stop meanwhile.
  @mc
  Scenario: An event read while Slack is disconnected does not reach plugins after it
    Given the plugins "planner", granted "slack:read", and "quiet", which is not
    And Slack takes its time to name "dana"
    When "dana" mentions "HAL" in "#planning", and the MC disconnects Slack before Slack names "dana"
    Then "planner" is handed Slack stopping, and not the mention

  # Socket Mode delivers at least once: an ack lost with the connection has Slack deliver
  # the event again, with the same event id, on the next connection.
  @mc
  Scenario: An event Slack delivers again after a reconnect reaches plugins once
    Given the plugins "planner", granted "slack:read", and "quiet", which is not
    And "dana" mentioned "HAL" in "#planning" and "planner" was handed it
    And the Socket Mode connection dropped and came back
    When Slack delivers that mention again, and then "dana" mentions "HAL" once more
    Then "planner" is handed the second mention, and not the first one again

  @mc
  Scenario: A plugin hears Slack stop and connect again in the order it happened
    Given a plugin granted "slack:read" that takes its time with each Slack event
    When the MC disconnects Slack and connects it again
    Then the plugin is handed Slack stopping, and nothing more until it is done with it
    And it is handed Slack connected after that

  # What still waits for a plugin busy with an event belongs to the plugin as it ran:
  # stopping it drops that, and the plugin started again does not hear it.
  @mc
  Scenario Outline: A plugin stopped while Slack events wait for it does not hear them later
    Given a plugin granted "slack:read" that takes its time with each Slack event
    And the MC disconnects Slack and connects it again
    And the plugin is handed Slack stopping, and is still busy with it
    When the plugin is <stopped>
    And it is done with Slack stopping, and the MC disconnects Slack
    Then the plugin is handed Slack stopping again, and never the connect that waited

    Examples:
      | stopped                 |
      | turned off and on again |
      | restarted               |

  @mc
  Scenario: A plugin answers a slash command only the person who ran it sees
    Given a plugin granted "slack:write"
    And "dana" ran the slash command "/planner status"
    When the plugin answers it with "Nothing is late"
    Then Slack shows "Nothing is late" to "dana" only

  @mc
  Scenario: Posting without slack:write is refused
    Given a plugin granted only "slack:read"
    When it posts "Hello" to "#planning"
    Then the MC refuses the call naming "slack:write"
    And the refusal is recorded on the plugin

  @mc
  Scenario: Slack's refusal reaches the plugin
    Given a plugin granted "slack:write"
    When it posts "Hello" to a channel the bot is not in
    Then it is told Slack refused it with "not_in_channel"

  @mc
  Scenario: A plugin can tell when the MC has no Slack connection
    Given the MC is not connected to Slack
    And a plugin granted "slack:read" and "slack:write"
    When it asks whether Slack is connected
    Then it is told Slack is not connected
    When it posts "Hello" to "#planning"
    Then it is told "Slack is not connected on this MC."
