defmodule HalC2.SlackTest do
  use ExUnit.Case, async: false

  alias HalC2.Slack
  alias HalC2.Test.FakeSlack

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :slack_backoff_ms, 5)

    on_exit(fn ->
      Application.delete_env(:hal_c2, :slack_backoff_ms)

      if previous,
        do: Application.put_env(:hal_c2, :home, previous),
        else: Application.delete_env(:hal_c2, :home)
    end)

    :ok = FakeSlack.start()
    start_supervised!(Slack)
    %{dir: dir}
  end

  defp tokens(bot \\ FakeSlack.bot_token(), app \\ FakeSlack.app_token()),
    do: %{"botToken" => bot, "appToken" => app}

  defp await_state(state) do
    assert_receive {:hal_c2_slack, _, %{"state" => ^state} = status}, 10_000
    status
  end

  test "connecting checks both tokens, keeps them in the secret store and never shows them", %{
    dir: dir
  } do
    assert {:ok, status} = Slack.connect(tokens())

    assert %{
             "state" => "connected",
             "team" => "acme",
             "teamId" => "T0ACME",
             "bot" => "HAL",
             "botUserId" => "UHAL",
             "error" => nil,
             "tokensSet" => true
           } = status

    path = Path.join([dir, "secrets", "slack.bin"])
    assert %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert File.read!(path) =~ FakeSlack.bot_token()

    for payload <- [status, Slack.status(), Slack.call("status", %{})] do
      refute inspect(payload) =~ FakeSlack.bot_token()
      refute inspect(payload) =~ FakeSlack.app_token()
    end

    assert {:ok, %{"connected" => true, "team" => "acme", "bot" => "HAL"}} =
             Slack.call("status", %{})
  end

  test "tokens Slack refuses leave it failed with Slack's reason and are not kept", %{dir: dir} do
    assert {:error, "Slack refused the bot token: invalid_auth"} =
             Slack.connect(tokens("xoxb-wrong"))

    assert %{"state" => "failed", "error" => "Slack refused the bot token: invalid_auth"} =
             Slack.status()

    assert {:error, "Slack refused the app token: invalid_auth"} =
             Slack.connect(tokens(FakeSlack.bot_token(), "xapp-wrong"))

    assert %{"tokensSet" => false} = Slack.status()
    refute File.exists?(Path.join([dir, "secrets", "slack.bin"]))
    assert {:error, "Slack is not connected on this MC."} = Slack.call("channels", %{})
  end

  test "an unreachable Slack fails a connect without keeping the tokens" do
    FakeSlack.available(false)
    assert {:error, "Could not reach Slack: HTTP 503"} = Slack.connect(tokens())
    assert %{"state" => "failed", "tokensSet" => false} = Slack.status()
  end

  test "disconnecting stops the connection and forgets the tokens", %{dir: dir} do
    {:ok, _} = Slack.connect(tokens())
    [{_, sup, _, _}] = DynamicSupervisor.which_children(HalC2.Slack.Connections)
    ref = Process.monitor(sup)

    assert {:ok, %{"state" => "off", "tokensSet" => false, "team" => nil}} = Slack.disconnect()
    assert_receive {:DOWN, ^ref, :process, ^sup, _}
    refute File.exists?(Path.join([dir, "secrets", "slack.bin"]))

    assert {:error, "Slack is not connected on this MC."} =
             Slack.call("post", %{"channel" => "#planning", "text" => "x"})
  end

  test "a dropped socket reconnects with backoff once Slack answers again" do
    {:ok, _} = Slack.connect(tokens())
    {:ok, _} = Slack.subscribe(self())

    FakeSlack.available(false)
    FakeSlack.drop()
    assert %{"error" => nil} = await_state("reconnecting")
    assert {:error, "Slack is not connected on this MC."} = Slack.call("channels", %{})

    FakeSlack.available(true)
    assert %{"team" => "acme"} = await_state("connected")
    assert {:ok, %{"channels" => [%{"id" => "CPLAN"}]}} = Slack.call("channels", %{})
  end

  test "stored tokens connect again when the MC starts" do
    {:ok, _} = Slack.connect(tokens())
    stop_supervised!(Slack)
    start_supervised!(Slack)

    case Slack.subscribe(self()) do
      {:ok, %{"state" => "connected"}} -> :ok
      {:ok, %{"state" => "connecting", "tokensSet" => true}} -> await_state("connected")
    end

    # auth.test twice per attempt: the check, and slack_elixir's own.
    assert length(FakeSlack.calls("auth.test")) == 4
  end

  test "stored tokens Slack now refuses are forgotten at start" do
    {:ok, _} = Slack.connect(tokens())
    stop_supervised!(Slack)

    HalC2.Connect.Secrets.put(
      "slack",
      JSON.encode!(%{"botToken" => "xoxb-revoked", "appToken" => FakeSlack.app_token()})
    )

    start_supervised!(Slack)

    case Slack.subscribe(self()) do
      {:ok, %{"state" => "failed"} = status} -> status
      {:ok, %{"state" => "connecting"}} -> await_state("failed")
    end

    assert %{"error" => "Slack refused the bot token: invalid_auth", "tokensSet" => false} =
             Slack.status()
  end

  describe "plugin calls" do
    setup do
      {:ok, _} = Slack.connect(tokens())
      :ok
    end

    test "post resolves #name through the bot's channels and answers where it went" do
      assert {:ok, %{"channel" => "CPLAN", "ts" => ts}} =
               Slack.call("post", %{"channel" => "#planning", "text" => "Plan is on track"})

      assert [%{"channel" => "CPLAN", "text" => "Plan is on track"}] =
               FakeSlack.calls("chat.postMessage")

      assert {:ok, %{"ts" => ^ts}} =
               Slack.call("update", %{"channel" => "CPLAN", "ts" => ts, "text" => "At risk"})

      assert {:ok, %{"ts" => reply}} =
               Slack.call("post", %{
                 "channel" => "CPLAN",
                 "text" => "Two moved",
                 "threadTs" => ts,
                 "blocks" => [%{"type" => "divider"}]
               })

      assert [_, %{"thread_ts" => ^ts, "blocks" => blocks}] = FakeSlack.calls("chat.postMessage")
      assert JSON.decode!(blocks) == [%{"type" => "divider"}]

      assert {:ok, %{"ok" => true}} =
               Slack.call("react", %{"channel" => "CPLAN", "ts" => reply, "name" => "eyes"})
    end

    test "Slack's refusal is the plugin's error" do
      assert {:error, "Slack refused it: not_in_channel"} =
               Slack.call("post", %{"channel" => "#random", "text" => "Hello"})
    end

    test "replies name their authors" do
      {:ok, %{"ts" => ts}} = Slack.call("post", %{"channel" => "CPLAN", "text" => "Plan"})

      FakeSlack.add_message(%{
        "channel" => "CPLAN",
        "thread_ts" => ts,
        "user" => "UDANA",
        "text" => "Slip docs?"
      })

      assert {:ok, %{"messages" => [parent, reply]}} =
               Slack.call("replies", %{"channel" => "#planning", "ts" => ts})

      assert %{"botId" => "BHAL", "text" => "Plan"} = parent
      assert %{"user" => "UDANA", "userName" => "dana", "threadTs" => ^ts, "botId" => nil} = reply

      assert {:ok, %{"id" => "UDANA", "name" => "dana", "realName" => "Dana Ito"}} =
               Slack.call("user", %{"user" => "UDANA"})
    end

    test "respond answers a slash command only its author sees" do
      url = FakeSlack.response_url()

      assert {:ok, %{"ok" => true}} =
               Slack.call("respond", %{"responseUrl" => url, "text" => "Nothing is late"})

      assert [
               %{
                 "url" => ^url,
                 "body" => %{"text" => "Nothing is late", "response_type" => "ephemeral"}
               }
             ] =
               FakeSlack.responses()
    end
  end

  describe "events" do
    @bot %Elixir.Slack.Bot{
      id: "BHAL",
      module: HalC2.Slack.Bot,
      team_id: "T0ACME",
      token: "x",
      user_id: "UHAL"
    }

    test "a mention, a reply in the bot's thread and a slash command reach plugins" do
      assert %{
               "type" => "slack.mention",
               "channel" => "CPLAN",
               "user" => "UDANA",
               "text" => "<@UHAL> hi",
               "ts" => "2"
             } =
               HalC2.Slack.Bot.event(
                 "app_mention",
                 %{"channel" => "CPLAN", "user" => "UDANA", "text" => "<@UHAL> hi", "ts" => "2"},
                 @bot
               )

      reply = %{
        "channel" => "CPLAN",
        "user" => "UDANA",
        "text" => "ok",
        "ts" => "3",
        "thread_ts" => "1",
        "parent_user_id" => "UHAL"
      }

      assert %{"type" => "slack.reply", "parentTs" => "1", "threadTs" => "1", "text" => "ok"} =
               HalC2.Slack.Bot.event("message", reply, @bot)

      assert %{
               "type" => "slack.command",
               "command" => "/planner",
               "text" => "status",
               "userName" => "dana",
               "responseUrl" => "u"
             } =
               HalC2.Slack.Bot.event(
                 "slash_commands",
                 %{
                   "command" => "/planner",
                   "text" => "status",
                   "user_id" => "UDANA",
                   "user_name" => "dana",
                   "channel_id" => "CPLAN",
                   "response_url" => "u"
                 },
                 @bot
               )
    end

    test "the bot's own messages, other threads, edits and plain messages are dropped" do
      base = %{
        "channel" => "CPLAN",
        "user" => "UDANA",
        "text" => "ok",
        "ts" => "3",
        "thread_ts" => "1",
        "parent_user_id" => "UHAL"
      }

      for message <- [
            %{base | "parent_user_id" => "UDANA"},
            %{base | "user" => "UHAL"},
            Map.put(base, "bot_id", "BOTHER"),
            Map.put(base, "subtype", "message_changed"),
            %{base | "text" => "<@UHAL> ok"},
            Map.drop(base, ["thread_ts", "parent_user_id"])
          ] do
        assert HalC2.Slack.Bot.event("message", message, @bot) == nil, inspect(message)
      end

      assert HalC2.Slack.Bot.event("app_mention", %{"user" => "UHAL", "text" => "x"}, @bot) == nil
    end
  end
end
