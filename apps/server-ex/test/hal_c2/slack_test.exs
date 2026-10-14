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

  test "a bot token and an app token of two Slack apps are refused and not kept", %{dir: dir} do
    message = "The bot token and app token belong to different Slack apps."

    assert {:error, ^message} =
             Slack.connect(tokens(FakeSlack.bot_token(), FakeSlack.other_app_token()))

    assert %{"state" => "failed", "error" => ^message, "tokensSet" => false} = Slack.status()
    refute File.exists?(Path.join([dir, "secrets", "slack.bin"]))
    assert DynamicSupervisor.which_children(HalC2.Slack.Connections) == []
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

  # Slack delivers an event again when its ack was lost, on the next connection too.
  test "an event is new once, across a reconnect, until many newer ones pushed it out" do
    {:ok, _} = Slack.connect(tokens())
    {:ok, _} = Slack.subscribe(self())
    assert Slack.first_delivery?("Ev1")
    refute Slack.first_delivery?("Ev1")

    FakeSlack.drop()
    await_state("reconnecting")
    await_state("connected")
    refute Slack.first_delivery?("Ev1")

    for n <- 2..20_001, do: assert(Slack.first_delivery?("Ev#{n}"))
    refute Slack.first_delivery?("Ev20001")
    assert Slack.first_delivery?("Ev1")
  end

  # Nothing of the lost connection may live on to take events while the MC says it is
  # reconnecting and has no token for plugins.
  test "a dropped socket's connection stops at once, not when the backoff ends" do
    Application.put_env(:hal_c2, :slack_backoff_ms, 600_000)
    {:ok, _} = Slack.connect(tokens())
    [{_, sup, _, _}] = DynamicSupervisor.which_children(HalC2.Slack.Connections)
    ref = Process.monitor(sup)
    {:ok, _} = Slack.subscribe(self())

    FakeSlack.drop()
    await_state("reconnecting")
    assert_receive {:DOWN, ^ref, :process, ^sup, _}, 10_000
    assert DynamicSupervisor.which_children(HalC2.Slack.Connections) == []
    assert %{"state" => "reconnecting", "tokensSet" => true} = Slack.status()
  end

  # Slack may send an event straight after hello, before this server has made the
  # connection its own; acked then and dropped, Slack would never send it again.
  test "an event Slack sends right after hello waits, unacked, for the connection and reaches plugins" do
    FakeSlack.hold("auth.test")
    connecting = Task.async(fn -> Slack.connect(tokens()) end)
    assert_receive {:fake_slack_held, "auth.test", _}, 5_000

    # The attempt's answer waits for the server while the socket takes the event.
    :sys.suspend(Slack)

    mention = %{
      "type" => "app_mention",
      "channel" => "CPLAN",
      "user" => "UDANA",
      "text" => "<@UHAL> hi",
      "ts" => "1800000000.1"
    }

    FakeSlack.event(mention, %{"event_id" => "EvEarly"})
    FakeSlack.ping()
    FakeSlack.release()
    assert_receive :fake_slack_pong, 5_000
    await_tasks()
    refute_received {:fake_slack_ack, _}

    :sys.resume(Slack)
    assert {:ok, %{"state" => "connected"}} = Task.await(connecting)
    assert_receive {:fake_slack_ack, _}, 5_000
    await_tasks()
    refute Slack.first_delivery?("EvEarly")
  end

  # What the connection's tasks (its attempt, the events it handed on) were doing is done.
  defp await_tasks do
    for pid <- Task.Supervisor.children(HalC2.Slack.Tasks) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  # The attempt gives up on hello after the disconnect, an answer that is not `{:ok, _}`;
  # its socket must not live on to take events while the MC says it is off.
  test "a disconnect while a connect waits for Slack's hello leaves no socket behind" do
    Application.put_env(:hal_c2, :slack_hello_ms, 200)
    on_exit(fn -> Application.delete_env(:hal_c2, :slack_hello_ms) end)
    FakeSlack.hello(false)
    connecting = Task.async(fn -> Slack.connect(tokens()) end)
    assert_receive {:fake_slack_socket, :open}, 5_000

    assert {:ok, %{"state" => "off"}} = Slack.disconnect()
    assert {:error, "Another Slack connection replaced it."} = Task.await(connecting)
    assert_receive {:fake_slack_socket, :closed}, 5_000
  end

  test "stored tokens connect again when the MC starts" do
    {:ok, _} = Slack.connect(tokens())
    stop_supervised!(Slack)
    start_supervised!(Slack)

    case Slack.subscribe(self()) do
      {:ok, %{"state" => "connected"}} -> :ok
      {:ok, %{"state" => "connecting", "tokensSet" => true}} -> await_state("connected")
    end

    assert length(FakeSlack.calls("auth.test")) == 2
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

  # A reply in a thread the bot started reaches it only from a conversation whose
  # history it may read and whose messages it subscribes to.
  test "the manifest hears messages in every kind of conversation the bot may read" do
    lines = Slack.manifest() |> String.split("\n") |> Enum.map(&String.trim/1)

    for kind <- ~w(channels groups im mpim), "- #{kind}:read" in lines do
      assert "- #{kind}:history" in lines, kind
      assert "- message.#{kind}" in lines, kind
    end
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

    test "replies and channels follow every page Slack hands out" do
      FakeSlack.page_size(2)
      FakeSlack.join("CDOCS", "docs")
      FakeSlack.join("CSHIP", "ship")

      assert {:ok, %{"channels" => channels}} = Slack.call("channels", %{})
      assert Enum.map(channels, & &1["id"]) == ~w(CDOCS CPLAN CSHIP)

      {:ok, %{"ts" => ts}} = Slack.call("post", %{"channel" => "CPLAN", "text" => "Plan"})

      for n <- 1..4 do
        FakeSlack.add_message(%{
          "channel" => "CPLAN",
          "thread_ts" => ts,
          "user" => "UDANA",
          "text" => "Reply #{n}"
        })
      end

      assert {:ok, %{"messages" => messages}} =
               Slack.call("replies", %{"channel" => "CPLAN", "ts" => ts})

      assert Enum.map(messages, & &1["text"]) == ["Plan" | for(n <- 1..4, do: "Reply #{n}")]
      assert length(FakeSlack.calls("conversations.replies")) == 4
    end

    test "a renamed, archived or unarchived channel is read again" do
      assert {:ok, _} = Slack.call("channels", %{})

      for {type, name} <- [{"channel_rename", "plans"}, {"group_rename", "roadmap"}] do
        FakeSlack.join("CPLAN", name)
        HalC2.Slack.Bot.event(type, %{"channel" => %{"id" => "CPLAN", "name" => name}}, %{})

        assert {:ok, %{"channels" => [%{"id" => "CPLAN", "name" => ^name}]}} =
                 Slack.call("channels", %{})
      end

      lines = Slack.manifest() |> String.split("\n") |> Enum.map(&String.trim/1)

      for kind <- ~w(channel group), event <- ~w(rename archive unarchive) do
        assert "- #{kind}_#{event}" in lines
      end
    end

    test "a channel the bot leaves or that is deleted leaves the list" do
      for {type, id} <- [
            {"group_left", "CLEFT"},
            {"group_deleted", "CGONE"},
            {"channel_deleted", "CDROP"}
          ] do
        FakeSlack.join(id, String.downcase(id))
        Slack.channels_changed()
        assert {:ok, %{"channels" => channels}} = Slack.call("channels", %{})
        assert id in Enum.map(channels, & &1["id"])

        FakeSlack.leave(id)
        HalC2.Slack.Bot.event(type, %{"channel" => id}, %{})
        assert {:ok, %{"channels" => channels}} = Slack.call("channels", %{})
        refute id in Enum.map(channels, & &1["id"]), type
      end

      lines = Slack.manifest() |> String.split("\n") |> Enum.map(&String.trim/1)

      for event <- ~w(channel_left channel_deleted group_left group_deleted),
          do: assert("- #{event}" in lines)
    end

    # A list read before a channel changed must not stand in for the list after it.
    test "channels read across a change are read again" do
      FakeSlack.hold("users.conversations")
      reading = Task.async(fn -> Slack.channels() end)
      assert_receive {:fake_slack_held, "users.conversations", _}, 5_000

      Slack.channels_changed()
      FakeSlack.release()
      Task.await(reading)

      read = length(FakeSlack.calls("users.conversations"))
      assert {:ok, _} = Slack.channels()
      assert length(FakeSlack.calls("users.conversations")) == read + 1
    end

    # A read that answers after the connection changed belongs to the old one, and must
    # not stand in for the new connection's own read.
    test "channels read across a reconnect are read again on the new connection" do
      FakeSlack.hold("users.conversations")
      reading = Task.async(fn -> Slack.channels() end)
      assert_receive {:fake_slack_held, "users.conversations", _}, 5_000

      assert {:ok, %{"state" => "off"}} = Slack.disconnect()
      assert {:ok, _} = Slack.connect(tokens())
      FakeSlack.release()
      Task.await(reading)

      read = length(FakeSlack.calls("users.conversations"))
      assert {:ok, _} = Slack.channels()
      assert length(FakeSlack.calls("users.conversations")) == read + 1
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

    test "respond posts only to Slack's response URLs" do
      for url <- [
            "https://internal.example/hook",
            "https://hooks.slack.com.example/commands/x",
            "https://hooks.slack.com:8443/commands/x",
            "https://user@hooks.slack.com/commands/x",
            "http://hooks.slack.com/commands/x"
          ] do
        assert {:error, "slack respond takes only a Slack response URL."} =
                 Slack.call("respond", %{"responseUrl" => url, "text" => "Nothing is late"})
      end

      assert FakeSlack.responses() == []
    end
  end

  describe "events" do
    @bot %{
      team: "acme",
      team_id: "T0ACME",
      bot: "HAL",
      bot_user_id: "UHAL",
      bot_id: "BHAL",
      app_id: "A0ACME"
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

    test "only envelopes for the bot's app and workspace are its own" do
      ours = %{
        "team_id" => "T0ACME",
        "api_app_id" => "A0ACME",
        "authorizations" => [%{"team_id" => "T0ACME", "user_id" => "UHAL"}]
      }

      # In a channel shared with another workspace, the event happens there and reaches
      # the bot's installation here.
      shared = %{ours | "team_id" => "T0PARTNER"}
      other_team = %{shared | "authorizations" => [%{"team_id" => "T0PARTNER"}]}
      other_app = %{ours | "api_app_id" => "A0OTHER"}
      # Here, in a channel shared with another workspace, for that workspace's installation.
      theirs = %{other_team | "team_id" => "T0ACME"}

      assert HalC2.Slack.Socket.ours?(ours, @bot)
      assert HalC2.Slack.Socket.ours?(shared, @bot)
      refute HalC2.Slack.Socket.ours?(other_team, @bot)
      refute HalC2.Slack.Socket.ours?(other_app, @bot)
      refute HalC2.Slack.Socket.ours?(theirs, @bot)
      refute HalC2.Slack.Socket.ours?(Map.delete(other_team, "authorizations"), @bot)
    end

    test "the socket refuses a server whose certificate it cannot trust" do
      key = X509.PrivateKey.new_ec(:secp256r1)
      names = X509.Certificate.Extension.subject_alt_name(["localhost"])

      cert =
        X509.Certificate.self_signed(key, "/CN=localhost",
          template: :server,
          extensions: [subject_alt_name: names]
        )

      tls = [
        cert: X509.Certificate.to_der(cert),
        key: {:ECPrivateKey, X509.PrivateKey.to_der(key)}
      ]

      {:ok, listen} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ tls)
      {:ok, {_, port}} = :ssl.sockname(listen)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listen)
        send(test, {:handshake, :ssl.handshake(socket, 5_000)})
      end)

      assert {:error, _} = HalC2.Slack.Socket.start_link("wss://localhost:#{port}/", @bot, self())
      assert_receive {:handshake, {:error, _}}, 5_000
    end

    test "a pong echoes the ping's payload" do
      state = %{identity: @bot, owner: self(), alive: false}

      assert {:reply, {:pong, "beat"}, %{alive: true}} =
               HalC2.Slack.Socket.handle_ping({:ping, "beat"}, state)

      assert {:reply, :pong, %{alive: true}} = HalC2.Slack.Socket.handle_ping(:ping, state)
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
