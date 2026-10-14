defmodule HalC2.Slack.Bot do
  @moduledoc """
  What Slack's Socket Mode delivers (`HalC2.Slack.Socket`, each event in a task), turned
  into the events plugins granted `slack:read` hear (`HalC2.Plugins.slack_event/2`):

    * `slack.mention`: a message that mentions the bot (`app_mention`; in a direct
      message, where Slack sends no `app_mention`, the message itself).
    * `slack.reply`: a reply in the thread of a message the bot posted that does not
      mention it (that one is a mention), with the parent's `parentTs`.
    * `slack.command`: a slash command the app answers, with its `responseUrl`.

  The bot's own messages, edits and other subtypes, and plain messages that do not
  mention it are dropped here, so they cost the plugins nothing.
  """

  @doc """
  Hands plugins the event for a Slack event, if any; `bot` is the identity of the
  connection that took it, `id` the Events API's `event_id` (nil for a slash command).
  Reading the event can wait on Slack (`users.info`), so one whose connection stopped or
  was replaced meanwhile is dropped. Slack delivers an event again when its ack was lost
  (`HalC2.Slack.first_delivery?/1`); only the first delivery handed on reaches plugins, so
  a retry of one dropped here still does.
  """
  def handle_event(type, payload, bot, id) do
    case event(type, payload, bot) do
      nil ->
        :ok

      event ->
        if HalC2.Slack.identity() == bot and HalC2.Slack.first_delivery?(id),
          do: HalC2.Plugins.slack_event(event),
          else: :ok
    end
  end

  @doc "The plugin event for a Slack event, or nil."
  def event("app_mention", %{"user" => user} = message, %{bot_user_id: me}) when user != me,
    do: message("slack.mention", message)

  # Outside a direct message, one that mentions the bot comes again as `app_mention`.
  def event("message", message, bot) do
    cond do
      not plain?(message, bot) ->
        nil

      mentions?(message, bot) and message["channel_type"] == "im" ->
        message("slack.mention", message)

      mentions?(message, bot) ->
        nil

      reply?(message, bot) ->
        Map.put(message("slack.reply", message), "parentTs", message["thread_ts"])

      true ->
        nil
    end
  end

  def event("slash_commands", %{"command" => command} = payload, _bot) do
    %{
      "type" => "slack.command",
      "command" => command,
      "text" => payload["text"] || "",
      "user" => payload["user_id"],
      "userName" => payload["user_name"],
      "channel" => payload["channel_id"],
      "responseUrl" => payload["response_url"]
    }
  end

  def event(type, _payload, _bot)
      when type in ~w(member_joined_channel channel_left channel_rename channel_archive
                      channel_unarchive channel_deleted group_left group_rename group_archive
                      group_unarchive group_deleted) do
    HalC2.Slack.channels_changed()
    nil
  end

  def event(_type, _payload, _bot), do: nil

  # A person's message as written: not the bot's, not an edit or a join.
  defp plain?(message, bot) do
    message["user"] != nil and message["user"] != bot.bot_user_id and message["bot_id"] == nil and
      message["subtype"] in [nil, "thread_broadcast", "file_share"]
  end

  defp reply?(%{"thread_ts" => parent, "ts" => ts} = message, bot),
    do: parent != ts and message["parent_user_id"] == bot.bot_user_id

  defp reply?(_message, _bot), do: false

  defp mentions?(message, bot),
    do: String.contains?(message["text"] || "", "<@#{bot.bot_user_id}>")

  defp message(type, message) do
    %{
      "type" => type,
      "channel" => message["channel"],
      "user" => message["user"],
      "userName" => HalC2.Slack.user_name(message["user"]),
      "text" => message["text"] || "",
      "ts" => message["ts"],
      "threadTs" => message["thread_ts"]
    }
  end
end
