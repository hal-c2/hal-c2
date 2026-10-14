defmodule HalC2.Steps.Settings.Slack do
  @moduledoc """
  The MC's Slack connection (Settings → Integrations → Slack, over `slack.*` and the
  `slack` shape) and what plugins do with it through `Host.slack/3`
  (`features/plugins/host-slack.feature`), against the fake workspace of
  `HalC2.Test.FakeSlack`. Plugin calls go through `host-probe`
  (`HalC2.Steps.Support.PluginHost`); events reach listeners of
  `HalC2.Steps.Support.Slack`.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Steps.Support.{PluginHost, Slack}
  alias HalC2.Test.FakeSlack
  alias HalC2.Test.Mc.World

  # --- the connection -----------------------------------------------------------------

  step "an MC connected to the Slack workspace {string} as the bot {string}",
       %{args: [team, bot]} = context do
    Slack.connect(context, %{team: team, bot: bot})
  end

  step "the bot is in the channel {string}", %{args: ["#" <> name]} = context do
    assert channel_id(name)
    context
  end

  step "the MC is not connected to Slack", context do
    {_, context} = World.call!(context, "slack.disconnect")
    context
  end

  step "Slack is connected", context do
    Slack.connect(context)
  end

  step "the user enters a Slack bot token and app token and connects", context do
    context = Slack.ready(context)
    {reply, context} = World.call(context, "slack.connect", Slack.tokens())
    Map.put(context, :reply, reply)
  end

  step "the user connects Slack with a bot token Slack refuses", context do
    context = Slack.ready(context)

    {reply, context} =
      World.call(context, "slack.connect", %{Slack.tokens() | "botToken" => "xoxb-revoked"})

    Map.put(context, :reply, reply)
  end

  step "the user connects Slack with a bot token of one Slack app and an app token of another",
       context do
    context = Slack.ready(context)

    {reply, context} =
      World.call(context, "slack.connect", %{
        Slack.tokens()
        | "appToken" => FakeSlack.other_app_token()
      })

    Map.put(context, :reply, reply)
  end

  step "Slack shows as connected to the workspace {string} as the bot {string}",
       %{args: [team, bot]} = context do
    assert {:ok, %{"state" => "connected", "team" => ^team, "bot" => ^bot}} = context.reply
    {status, context} = World.call!(context, "slack.status")
    assert %{"state" => "connected", "team" => ^team, "bot" => ^bot} = status
    context
  end

  step "the tokens show as set but are never shown again", context do
    {status, context} = World.call!(context, "slack.status")
    assert status["tokensSet"] == true
    {settings, context} = World.call!(context, "server.getSettings")

    for payload <- [status, settings, context.reply], token <- Map.values(Slack.tokens()) do
      refute inspect(payload) =~ token
    end

    context
  end

  step "Slack shows as not connected with Slack's reason {string}",
       %{args: [reason]} = context do
    assert {:error, message, _} = context.reply
    assert message =~ reason
    {status, context} = World.call!(context, "slack.status")
    assert %{"state" => "failed", "tokensSet" => false} = status
    assert status["error"] =~ reason
    context
  end

  step "the user disconnects Slack", context do
    context = Slack.listener(context, "listener", ["slack:read"])
    {reply, context} = World.call(context, "slack.disconnect")
    Map.put(context, :reply, reply)
  end

  step "Slack shows as not connected", context do
    assert {:ok, %{"state" => "off"}} = context.reply
    {status, context} = World.call!(context, "slack.status")
    assert %{"state" => "off", "team" => nil} = status
    context
  end

  step "the tokens are forgotten", context do
    {status, context} = World.call!(context, "slack.status")
    assert status["tokensSet"] == false
    refute File.exists?(Path.join([HalC2.Paths.data_dir(), "secrets", "slack.bin"]))
    context
  end

  step "plugins are told Slack is not connected", context do
    assert_receive {:slack_event, "listener", %{"type" => "slack.status", "connected" => false}},
                   10_000

    context
  end

  step "the Socket Mode connection drops", context do
    context = Slack.watch(context)
    FakeSlack.available(false)
    FakeSlack.drop()
    context
  end

  step "Slack shows as reconnecting", context do
    {_, context} = Slack.await(context, "reconnecting")
    context
  end

  step "it shows as connected again once Slack answers", context do
    FakeSlack.available(true)
    {status, context} = Slack.await(context, "connected")
    assert %{"team" => "acme", "tokensSet" => true} = status
    context
  end

  step "Slack connects again with the stored tokens", context do
    {status, context} = Slack.await(context, "connected")
    assert %{"team" => "acme", "tokensSet" => true} = status
    context
  end

  step "the MC is asked for the Slack app manifest", context do
    {%{"manifest" => manifest}, context} = World.call!(context, "slack.manifest")
    Map.put(context, :manifest, manifest |> String.split("\n") |> Enum.map(&String.trim/1))
  end

  step "it asks for {string} and {string} and subscribes to {string}",
       %{args: entries} = context do
    for entry <- entries, do: assert(("- " <> entry) in context.manifest, entry)
    context
  end

  # --- plugins' calls -----------------------------------------------------------------

  step "a plugin granted {string} that posted {string} to {string}",
       %{args: [permission, text, channel]} = context do
    context = PluginHost.granted(context, [permission])
    post(context, text, channel)
  end

  step "it posts {string} to {string}", %{args: [text, channel]} = context do
    post(context, text, channel)
  end

  step "it posts {string} to a channel the bot is not in", %{args: [text]} = context do
    post(context, text, "#random")
  end

  step "Slack is asked to post {string} to {string}",
       %{args: [text, "#" <> name]} = context do
    id = channel_id(name)

    assert Enum.any?(
             FakeSlack.calls("chat.postMessage"),
             &match?(%{"channel" => ^id, "text" => ^text}, &1)
           )

    context
  end

  step "the plugin gets the channel and the message's timestamp", context do
    assert {:ok, %{"channel" => channel, "ts" => ts}} = context.reply
    assert Enum.any?(FakeSlack.messages(), &match?(%{"channel" => ^channel, "ts" => ^ts}, &1))
    context
  end

  step "it replies {string} in that message's thread", %{args: [text]} = context do
    {channel, ts} = context.last_post

    {_, context} =
      PluginHost.call!(context, "slack", "post", %{
        "channel" => channel,
        "text" => text,
        "threadTs" => ts
      })

    context
  end

  step "it edits {string} to {string}", %{args: [text, edited]} = context do
    {channel, ts} = Map.fetch!(context.posts, text)

    {_, context} =
      PluginHost.call!(context, "slack", "update", %{
        "channel" => channel,
        "ts" => ts,
        "text" => edited
      })

    context
  end

  step "Slack is asked to post {string} in the thread of {string}",
       %{args: [text, parent]} = context do
    {_, ts} = Map.fetch!(context.posts, parent)

    assert Enum.any?(
             FakeSlack.calls("chat.postMessage"),
             &match?(%{"text" => ^text, "thread_ts" => ^ts}, &1)
           )

    context
  end

  step "Slack is asked to change {string} to {string}", %{args: [text, edited]} = context do
    {channel, ts} = Map.fetch!(context.posts, text)

    assert [%{"channel" => ^channel, "ts" => ^ts, "text" => ^edited}] =
             FakeSlack.calls("chat.update")

    context
  end

  step "it lists the Slack channels", context do
    PluginHost.call(context, "slack", "channels", %{})
  end

  step "{string} is listed with its id", %{args: ["#" <> name]} = context do
    assert {:ok, %{"channels" => channels}} = context.reply
    id = channel_id(name)
    assert %{"id" => ^id, "private" => false} = Enum.find(channels, &(&1["name"] == name))
    context
  end

  step "{string} replied {string} to the bot's message in {string}",
       %{args: [person, text, "#" <> name]} = context do
    channel = channel_id(name)
    ts = bot_message(channel, "Plan is on track")

    FakeSlack.add_message(%{
      "channel" => channel,
      "thread_ts" => ts,
      "user" => user_id(person),
      "text" => text
    })

    Map.put(context, :thread, {channel, ts})
  end

  step "it reads the replies to that message", context do
    {channel, ts} = context.thread
    PluginHost.call(context, "slack", "replies", %{"channel" => channel, "ts" => ts})
  end

  step "it gets {string} from {string}", %{args: [text, person]} = context do
    assert {:ok, %{"messages" => messages}} = context.reply
    assert Enum.any?(messages, &match?(%{"text" => ^text, "userName" => ^person}, &1))
    context
  end

  step "it asks whether Slack is connected", context do
    PluginHost.call(context, "slack", "status", %{})
  end

  step "it is told Slack is not connected", context do
    assert {:ok, %{"connected" => false}} = context.reply
    context
  end

  step "it is told {string}", %{args: [message]} = context do
    # The MC names the plugin before what it was told: "host-probe: <message>".
    assert String.ends_with?(PluginHost.refusal(context), ": " <> message)
    context
  end

  step "it is told Slack refused it with {string}", %{args: [error]} = context do
    assert String.ends_with?(PluginHost.refusal(context), ": Slack refused it: " <> error)
    context
  end

  # --- what happens in Slack ----------------------------------------------------------

  step "the plugins {string}, granted {string}, and {string}, which is not",
       %{args: [granted, permission, other]} = context do
    context
    |> Slack.listener(granted, [permission])
    |> Slack.listener(other, [])
    |> Map.merge(%{granted: granted, other: other})
  end

  step "{string} mentions {string} in {string} in Slack",
       %{args: [person, _bot, "#" <> name]} = context do
    event = %{
      "channel" => channel_id(name),
      "user" => user_id(person),
      "text" => "<@UHAL> what is late?",
      "ts" => "1700000100.000001"
    }

    # Slack sends the channel's message too; only the mention reaches plugins.
    FakeSlack.event(Map.put(event, "type", "message"))
    FakeSlack.event(Map.put(event, "type", "app_mention"))
    Map.put(context, :said, {event["channel"], event["text"]})
  end

  step "{string} mentions {string} in a workspace the bot does not belong to, and then in {string}",
       %{args: [person, _bot, "#" <> name]} = context do
    origin = %{"team_id" => "T0OTHER", "authorizations" => [%{"team_id" => "T0OTHER"}]}
    mention_elsewhere(context, person, name, origin)
  end

  step "{string} mentions {string} in an event Slack sends for another app, and then in {string}",
       %{args: [person, _bot, "#" <> name]} = context do
    mention_elsewhere(context, person, name, %{"api_app_id" => "A0OTHER"})
  end

  step "{string} replies in the thread of a message the bot posted in Slack",
       %{args: [person]} = context do
    channel = channel_id("planning")
    ts = bot_message(channel, "Plan is on track")

    FakeSlack.event(%{
      "type" => "message",
      "channel" => channel,
      "user" => user_id(person),
      "text" => "Can we slip docs?",
      "ts" => "1700000100.000002",
      "thread_ts" => ts,
      "parent_user_id" => "UHAL"
    })

    Map.put(context, :said, {channel, "Can we slip docs?"})
  end

  step "{string} runs the slash command {string} in Slack",
       %{args: [person, command]} = context do
    context = command(context, person, command)
    Map.put(context, :said, {channel_id("planning"), context.command_text})
  end

  step "{string} is handed a {string} event with the channel, the user and the text",
       %{args: [id, type]} = context do
    {channel, text} = context.said

    assert_receive {:slack_event, ^id, %{"type" => ^type} = event}, 10_000

    assert %{"channel" => ^channel, "user" => "UDANA", "userName" => "dana", "text" => ^text} =
             event

    context
  end

  step "{string} is handed only the mention in {string}", %{args: [id, _channel]} = context do
    {channel, text} = context.said

    assert_receive {:slack_event, ^id, %{"type" => "slack.mention", "text" => ^text} = event},
                   10_000

    assert event["channel"] == channel
    # Each event is handed on in a task of its own; give the other one its chance.
    refute_receive {:slack_event, ^id, _}, 200
    context
  end

  step "{string} is handed nothing", %{args: [id]} = context do
    # The event went to every plugin granted slack:read at once; give a wrong one its chance.
    refute_receive {:slack_event, ^id, _}, 200
    context
  end

  step "a plugin granted {string} that takes its time with each Slack event",
       %{args: [permission]} = context do
    Slack.listener(context, "slow", [permission], hold: true)
  end

  step "the MC disconnects Slack and connects it again", context do
    {_, context} = World.call!(context, "slack.disconnect")
    {reply, context} = World.call(context, "slack.connect", Slack.tokens())
    assert {:ok, %{"state" => "connected"}} = reply
    context
  end

  step "the plugin is handed Slack stopping, and nothing more until it is done with it",
       context do
    assert_receive {:slack_held, "slow", %{"type" => "slack.status", "connected" => false}, pid},
                   10_000

    # The connect that followed has had its chance to overtake.
    refute_receive {:slack_held, "slow", _, _}, 200
    send(pid, :go)
    context
  end

  step "it is handed Slack connected after that", context do
    assert_receive {:slack_held, "slow", %{"type" => "slack.status", "connected" => true}, pid},
                   10_000

    send(pid, :go)
    context
  end

  step "{string} ran the slash command {string}", %{args: [person, command]} = context do
    command(context, person, command)
  end

  step "the plugin answers it with {string}", %{args: [text]} = context do
    PluginHost.call(context, "slack", "respond", %{
      "responseUrl" => context.response_url,
      "text" => text
    })
  end

  step "Slack shows {string} to {string} only", %{args: [text, _person]} = context do
    assert {:ok, %{"ok" => true}} = context.reply
    url = context.response_url

    assert [%{"url" => ^url, "body" => %{"text" => ^text, "response_type" => "ephemeral"}}] =
             FakeSlack.responses()

    context
  end

  # --- helpers ------------------------------------------------------------------------

  defp post(context, text, channel) do
    context = PluginHost.call(context, "slack", "post", %{"channel" => channel, "text" => text})

    case context.reply do
      {:ok, %{"channel" => id, "ts" => ts}} ->
        posts = Map.put(Map.get(context, :posts, %{}), text, {id, ts})
        Map.merge(context, %{posts: posts, last_post: {id, ts}})

      _ ->
        context
    end
  end

  defp command(context, person, slash) do
    [command | rest] = String.split(slash, " ", parts: 2)
    url = FakeSlack.response_url()
    text = Enum.join(rest, " ")

    FakeSlack.command(%{
      "command" => command,
      "text" => text,
      "user_id" => user_id(person),
      "user_name" => person,
      "channel_id" => channel_id("planning"),
      "response_url" => url
    })

    Map.merge(context, %{response_url: url, command_text: text})
  end

  defp bot_message(channel, text),
    do:
      FakeSlack.add_message(%{
        "channel" => channel,
        "user" => "UHAL",
        "bot_id" => "BHAL",
        "text" => text
      })

  defp channel_id(name) do
    Agent.get(FakeSlack, fn state ->
      Enum.find_value(state.channels, fn {id, c} -> c["name"] == name && id end)
    end)
  end

  defp user_id(name) do
    Agent.get(FakeSlack, fn state ->
      Enum.find_value(state.users, fn {id, u} -> u["name"] == name && id end)
    end)
  end

  # A mention from `origin` (overriding the envelope's team or app), then one in `name`.
  defp mention_elsewhere(context, person, name, origin) do
    mention = fn text, ts ->
      %{
        "type" => "app_mention",
        "channel" => channel_id(name),
        "user" => user_id(person),
        "text" => text,
        "ts" => ts
      }
    end

    FakeSlack.event(mention.("<@UHAL> is this ours?", "1700000100.000003"), origin)
    FakeSlack.event(mention.("<@UHAL> what is late?", "1700000100.000004"))
    Map.put(context, :said, {channel_id(name), "<@UHAL> what is late?"})
  end
end
