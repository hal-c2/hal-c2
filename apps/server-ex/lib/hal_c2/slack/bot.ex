defmodule HalC2.Slack.Bot do
  @moduledoc """
  What Slack's Socket Mode delivers (`HalC2.Slack.Socket`, each event in a task), turned
  into the events plugins granted `slack:read` hear (`HalC2.Plugins.slack_event/2`):

    * `slack.mention`: a message that mentions the bot (`app_mention`).
    * `slack.reply`: a reply in the thread of a message the bot posted that does not
      mention it (that one is a mention), with the parent's `parentTs`.
    * `slack.command`: a slash command the app answers, with its `responseUrl`.

  The bot's own messages, edits and other subtypes, and plain messages that do not
  mention it are dropped here, so they cost the plugins nothing.
  """

  @doc "Hands plugins the event for a Slack event, if any; `bot` is `HalC2.Slack.identity/0`."
  def handle_event(type, payload, bot) do
    case event(type, payload, bot) do
      nil -> :ok
      event -> HalC2.Plugins.slack_event(event)
    end
  end

  @doc "The plugin event for a Slack event, or nil."
  def event("app_mention", %{"user" => user} = message, %{bot_user_id: me}) when user != me,
    do: message("slack.mention", message)

  def event("message", %{"thread_ts" => parent, "ts" => ts} = message, bot)
      when parent != ts do
    if plain?(message, bot) and message["parent_user_id"] == bot.bot_user_id and
         not mentions?(message, bot),
       do: Map.put(message("slack.reply", message), "parentTs", parent)
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

  def event(type, _payload, _bot) when type in ["member_joined_channel", "channel_left"] do
    HalC2.Slack.channels_changed()
    nil
  end

  def event(_type, _payload, _bot), do: nil

  # A person's message as written: not the bot's, not an edit or a join.
  defp plain?(message, bot) do
    message["user"] != nil and message["user"] != bot.bot_user_id and message["bot_id"] == nil and
      message["subtype"] in [nil, "thread_broadcast", "file_share"]
  end

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
