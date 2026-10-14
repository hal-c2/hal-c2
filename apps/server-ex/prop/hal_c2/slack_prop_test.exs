defmodule HalC2.SlackPropTest do
  @moduledoc """
  `HalC2.Slack`, the MC's one Slack connection, against a model of what it promises: its
  state (off, connecting, connected, reconnecting, failed), whether it keeps tokens, and
  what the plugins hear. Slack is `HalC2.Test.FakeSlack`.

  Commands connect with good tokens, with a bot or app token Slack refuses and with an
  app token of another app than the bot token's, disconnect, take Slack away and bring it back, drop the Socket Mode connection (and
  drop it with a long backoff, where the lost connection must be stopped before the
  retry, then connect again), disconnect while a connect waits for Slack's hello (its
  socket must close), restart the service and mention the bot in Slack, in its workspace
  and app or in another, or mention it and disconnect while the MC asks Slack who wrote it,
  and have Slack deliver a mention again (as it does when an ack was lost), however the
  connection changed since. After every step the status must
  match the model and never carry a token, and the secret store must hold tokens
  exactly when the model keeps them. At the end of a case the plugin granted
  `slack:read` must have heard every connect and every stop (`slack.status`), in the
  order they happened, and every mention in the bot's workspace and app once, but none from
  elsewhere, and one read after a disconnect only when Slack delivered it again, once;
  the plugin without it nothing.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Test.FakeSlack

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @probe :hal_c2_slack_prop
  @wait 10_000

  setup do
    keys = [
      :bundled_plugins,
      :settings_check_ms,
      :slack_backoff_ms,
      :slack_backoff_max_ms,
      :slack_hello_ms
    ]

    saved = for key <- keys, do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  property "the Slack connection connects, fails, drops, comes back and restarts as the model says",
    numtests: HalC2.Prop.numtests(60),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        heard = if result == :ok, do: heard(state), else: :skipped
        stop()

        (result == :ok and heard == :ok)
        |> when_fail(
          IO.puts("""
          #{HalC2.Prop.report(cmds, history, state, result)}
          Plugins heard: #{inspect(heard, pretty: true)}
          """)
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    Application.put_env(:hal_c2, :bundled_plugins, [])
    Application.put_env(:hal_c2, :slack_backoff_ms, 1)
    Application.put_env(:hal_c2, :slack_backoff_max_ms, 20)
    Application.put_env(:hal_c2, :slack_hello_ms, 500)
    HalC2.Prop.scratch_home("slack")
    nonce = System.unique_integer([:positive])
    Process.put({__MODULE__, :nonce}, nonce)
    Process.register(self(), @probe)
    Process.put({__MODULE__, :fake}, FakeSlack.start_unsupervised())
    write_listener("heard", ["slack:read"], nonce)
    write_listener("deaf", [], nonce)
    HalC2.Prop.start_services([HalC2.Settings, HalC2.Plugins, HalC2.Slack])

    for {id, permissions} <- [{"heard", ["slack:read"]}, {"deaf", []}] do
      {:ok, _} =
        HalC2.Plugins.handle("enable", %{"id" => id, "acceptPermissions" => permissions})
    end
  end

  defp stop do
    HalC2.Prop.stop_services()
    if stop = Process.delete({__MODULE__, :fake}), do: stop.()
    Process.unregister(@probe)
  end

  # A plugin that tells the case every event it is handed, marked with the case's nonce
  # so a late event of an earlier case is not counted.
  defp write_listener(id, permissions, nonce) do
    dir = Path.join([HalC2.Paths.data_dir(), "plugins", id])
    File.mkdir_p!(Path.join(dir, "mc"))

    File.write!(
      Path.join(dir, "plugin.json"),
      JSON.encode!(%{
        "id" => id,
        "name" => id,
        "version" => "1.0.0",
        "apiVersion" => 1,
        "description" => "Hears Slack.",
        "permissions" => for(p <- permissions, do: %{"id" => p, "reason" => "The property."})
      })
    )

    File.write!(Path.join(dir, "mc/listener.ex"), """
    defmodule HalC2PropSlackListener#{Macro.camelize(id)} do
      @behaviour HalC2.Plugins.Extension

      @impl true
      def call(method, _input, _context), do: {:error, "no method " <> method}

      @impl true
      def handle_event(event, context),
        do: send(#{inspect(@probe)}, {:slack_event, #{nonce}, context.id, event})
    end
    """)
  end

  # --- model ------------------------------------------------------------------------

  # phase: what the status says. stored: whether it keeps tokens. up: whether Slack
  # answers. told: the slack.status events the granted plugin is owed, their
  # `connected`, newest first. mentions: the mentions it is owed. sent: the next mention's
  # number, its event id. events: the mentions in the bot's workspace and app since the
  # service started, by number: :heard, or :stale (read after a disconnect, so not heard).
  def initial_state,
    do: %{phase: :off, stored: false, up: true, told: [], mentions: 0, sent: 0, events: %{}}

  def command(state) do
    frequency(
      [
        {4, {:call, __MODULE__, :connect, [:good]}},
        {1, {:call, __MODULE__, :connect, [:bad_bot]}},
        {1, {:call, __MODULE__, :connect, [:bad_app]}},
        {1, {:call, __MODULE__, :connect, [:other_app]}},
        {2, {:call, __MODULE__, :disconnect, []}},
        {2, {:call, __MODULE__, :outage, []}},
        {2, {:call, __MODULE__, :restore, [state.phase]}},
        {2, {:call, __MODULE__, :restart, [state.stored, state.up]}}
      ] ++
        if(state.up, do: [{1, {:call, __MODULE__, :disconnect_before_hello, []}}], else: []) ++
        if state.phase == :connected do
          [
            {6, {:call, __MODULE__, :drop, [state.up]}},
            {2, {:call, __MODULE__, :drop_held, []}},
            {4, {:call, __MODULE__, :mention, [:ours, state.sent]}},
            {1, {:call, __MODULE__, :mention, [:other_team, state.sent]}},
            {1, {:call, __MODULE__, :mention, [:other_app, state.sent]}},
            {1, {:call, __MODULE__, :mention, [:their_installation, state.sent]}},
            {1, {:call, __MODULE__, :mention_then_disconnect, [state.sent]}}
          ] ++
            if(state.up,
              do: [
                {1, {:call, __MODULE__, :read_across_reconnect, []}},
                {1, {:call, __MODULE__, :read_across_change, []}}
              ],
              else: []
            ) ++
            if(state.events != %{}, do: [{4, retry_command(state)}], else: [])
        else
          []
        end
    )
  end

  defp retry_command(state) do
    let n <- elements(Map.keys(state.events)),
        do: {:call, __MODULE__, :retry, [n, state.events[n]]}
  end

  def precondition(state, {:call, _, :drop, _}), do: state.phase == :connected
  def precondition(state, {:call, _, :drop_held, _}), do: state.phase == :connected

  def precondition(state, {:call, _, :mention, [_, n]}),
    do: state.phase == :connected and n >= state.sent

  def precondition(state, {:call, _, :mention_then_disconnect, [n]}),
    do: state.phase == :connected and n >= state.sent

  def precondition(state, {:call, _, :retry, [n, kind]}),
    do: state.phase == :connected and state.events[n] == kind

  def precondition(state, {:call, _, :disconnect_before_hello, _}), do: state.up

  def precondition(state, {:call, _, :read_across_reconnect, _}),
    do: state.phase == :connected and state.up

  def precondition(state, {:call, _, :read_across_change, _}),
    do: state.phase == :connected and state.up

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :connect, [:good]}) do
    if state.up,
      do: state |> walk([:connecting, :connected]) |> Map.put(:stored, true),
      else: state |> walk([:connecting, :failed]) |> Map.put(:stored, false)
  end

  def next_state(state, _result, {:call, _, :connect, [_bad]}),
    do: state |> walk([:connecting, :failed]) |> Map.put(:stored, false)

  def next_state(state, _result, {:call, _, :disconnect, []}),
    do: state |> walk([:off]) |> Map.put(:stored, false)

  def next_state(state, _result, {:call, _, :disconnect_before_hello, []}),
    do: state |> walk([:connecting, :off]) |> Map.put(:stored, false)

  def next_state(state, _result, {:call, _, :mention_then_disconnect, [n]}) do
    state = %{state | sent: n + 1, events: Map.put(state.events, n, :stale)}
    state |> walk([:off]) |> Map.put(:stored, false)
  end

  # Connected afresh twice: once to start from empty caches, once under the reads.
  def next_state(state, _result, {:call, _, :read_across_change, []}), do: state

  def next_state(state, _result, {:call, _, :read_across_reconnect, []}) do
    Enum.reduce(1..2, state, fn _, state ->
      state = state |> walk([:off]) |> Map.put(:stored, false)
      next_state(state, nil, {:call, __MODULE__, :connect, [:good]})
    end)
  end

  def next_state(state, _result, {:call, _, :outage, []}), do: %{state | up: false}

  def next_state(state, _result, {:call, _, :restore, _}) do
    state = %{state | up: true}
    if state.phase in [:connecting, :reconnecting], do: walk(state, [:connected]), else: state
  end

  def next_state(state, _result, {:call, _, :drop, _}) do
    state = walk(state, [:reconnecting])
    if state.up, do: walk(state, [:connected]), else: state
  end

  # Held in reconnecting by the backoff, then connected afresh.
  def next_state(state, _result, {:call, _, :drop_held, []}) do
    state = walk(state, [:reconnecting])
    next_state(state, nil, {:call, __MODULE__, :connect, [:good]})
  end

  # A service that stops says nothing, and forgets the events it handed on; the one that
  # starts connects when it keeps tokens.
  def next_state(state, _result, {:call, _, :restart, _}) do
    state = %{state | phase: if(state.stored, do: :connecting, else: :off), events: %{}}
    if state.stored and state.up, do: walk(state, [:connected]), else: state
  end

  def next_state(state, _result, {:call, _, :mention, [:ours, n]}),
    do: %{
      state
      | mentions: state.mentions + 1,
        sent: n + 1,
        events: Map.put(state.events, n, :heard)
    }

  def next_state(state, _result, {:call, _, :mention, [_elsewhere, n]}),
    do: %{state | sent: n + 1}

  # Delivered again, a stale mention is heard now, and a heard one not again.
  def next_state(state, _result, {:call, _, :retry, [n, _kind]}),
    do: %{state | events: Map.put(state.events, n, :heard)}

  # Moves through `phases`, owing the plugins an event for every connect and every stop.
  defp walk(state, phases) do
    Enum.reduce(phases, state, fn phase, state ->
      cond do
        state.phase != :connected and phase == :connected ->
          %{state | phase: phase, told: [true | state.told]}

        state.phase == :connected and phase != :connected ->
          %{state | phase: phase, told: [false | state.told]}

        true ->
          %{state | phase: phase}
      end
    end)
  end

  def postcondition(state, call, result) do
    model = next_state(state, result, call)
    status = HalC2.Slack.status()

    replied?(state, call, result) and
      status["state"] == Atom.to_string(model.phase) and
      status["tokensSet"] == model.stored and
      status["team"] == "acme" == (model.phase == :connected) and
      File.exists?(secret()) == model.stored and
      not leaks?([status, result])
  end

  defp replied?(state, {:call, _, :connect, [:good]}, result) do
    if state.up,
      do: match?({:ok, %{"state" => "connected", "team" => "acme", "bot" => "HAL"}}, result),
      else: result == {:error, "Could not reach Slack: HTTP 503"}
  end

  defp replied?(state, {:call, _, :connect, [:other_app]}, result) do
    if state.up,
      do: result == {:error, "The bot token and app token belong to different Slack apps."},
      else: result == {:error, "Could not reach Slack: HTTP 503"}
  end

  defp replied?(state, {:call, _, :connect, [bad]}, result) do
    token = if bad == :bad_bot, do: "bot", else: "app"

    if state.up,
      do: result == {:error, "Slack refused the #{token} token: invalid_auth"},
      else: result == {:error, "Could not reach Slack: HTTP 503"}
  end

  defp replied?(_state, {:call, _, :disconnect, []}, result),
    do: match?({:ok, %{"state" => "off", "tokensSet" => false}}, result)

  # Whichever gave up first, the connect or its wait for hello, its socket is gone.
  defp replied?(_state, {:call, _, :disconnect_before_hello, []}, {connected, off, closed}) do
    match?({:error, _}, connected) and closed == :closed and
      replied?(nil, {:call, __MODULE__, :disconnect, []}, off)
  end

  defp replied?(_state, {:call, _, :mention_then_disconnect, []}, result),
    do: replied?(nil, {:call, __MODULE__, :disconnect, []}, result)

  defp replied?(_state, {:call, _, :read_across_change, []}, result), do: result == :read_again

  defp replied?(state, {:call, _, :read_across_reconnect, []}, {connected, read_again}) do
    read_again == {true, true} and
      replied?(state, {:call, __MODULE__, :connect, [:good]}, connected)
  end

  defp replied?(_state, {:call, _, :mention, [:ours, _]}, result), do: result == :heard
  defp replied?(_state, {:call, _, :mention, _elsewhere}, result), do: result == :sent
  defp replied?(_state, {:call, _, :retry, [_, :stale]}, result), do: result == :heard
  defp replied?(_state, {:call, _, :retry, [_, :heard]}, result), do: result == :sent

  defp replied?(state, {:call, _, :drop_held, []}, result) do
    match?({:held, _}, result) and
      replied?(state, {:call, __MODULE__, :connect, [:good]}, elem(result, 1))
  end

  defp replied?(_state, _call, _result), do: true

  defp leaks?(payloads) do
    text = inspect(payloads)
    tokens = [FakeSlack.bot_token(), FakeSlack.app_token(), FakeSlack.other_app_token()]
    Enum.any?(tokens ++ ["xoxb-", "xapp-"], &(text =~ &1))
  end

  defp secret, do: Path.join([HalC2.Paths.data_dir(), "secrets", "slack.bin"])

  # --- commands ---------------------------------------------------------------------

  def connect(:good),
    do: HalC2.Slack.connect(tokens(FakeSlack.bot_token(), FakeSlack.app_token()))

  def connect(:bad_bot), do: HalC2.Slack.connect(tokens("xoxb-revoked", FakeSlack.app_token()))
  def connect(:bad_app), do: HalC2.Slack.connect(tokens(FakeSlack.bot_token(), "xapp-revoked"))

  def connect(:other_app),
    do: HalC2.Slack.connect(tokens(FakeSlack.bot_token(), FakeSlack.other_app_token()))

  defp tokens(bot, app), do: %{"botToken" => bot, "appToken" => app}

  def disconnect, do: HalC2.Slack.disconnect()

  # Connects to a Slack that never says hello, and disconnects once the socket is open:
  # the attempt is stale, and the connection it started must stop.
  def disconnect_before_hello do
    flush_sockets()
    FakeSlack.hello(false)
    connecting = Task.async(fn -> connect(:good) end)

    receive do
      {:fake_slack_socket, :open} -> :ok
    after
      @wait -> exit(:slack_socket_never_opened)
    end

    live =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(HalC2.Slack.Connections),
          do: {pid, Process.monitor(pid)}

    off = disconnect()
    connected = Task.await(connecting, @wait)
    FakeSlack.hello(true)

    stopped =
      Enum.all?(live, fn {pid, ref} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> true
        after
          @wait -> false
        end
      end)

    {connected, off, if(live != [] and stopped, do: :closed, else: {:still_running, live})}
  end

  # Mentions the bot as someone Slack is slow to name, and disconnects meanwhile; the
  # mention must not reach a plugin once Slack names them (`heard/1`). Slack never knows
  # this person, so the MC asks every time.
  def mention_then_disconnect(n) do
    FakeSlack.hold("users.info")
    FakeSlack.event(mention_event(n, :stale), %{"event_id" => event_id(n)})

    reading =
      receive do
        {:fake_slack_held, "users.info", pid} -> Process.monitor(pid)
      after
        @wait -> exit(:mention_never_read)
      end

    off = disconnect()
    FakeSlack.release()

    receive do
      {:DOWN, ^reading, :process, _, _} -> off
    after
      @wait -> exit(:mention_never_finished)
    end
  end

  # Reads the channels while one of them changes: the list read before the change must
  # not stand in for the one after it, so the channels are read again after.
  def read_across_change do
    HalC2.Slack.channels_changed()
    FakeSlack.hold("users.conversations")
    reading = Task.async(fn -> HalC2.Slack.channels() end)

    receive do
      {:fake_slack_held, "users.conversations", _} -> :ok
    after
      @wait -> exit(:channels_never_read)
    end

    HalC2.Slack.channels_changed()
    FakeSlack.release()
    Task.await(reading, @wait)

    before = length(FakeSlack.calls("users.conversations"))
    {:ok, _} = HalC2.Slack.channels()

    if length(FakeSlack.calls("users.conversations")) == before + 1,
      do: :read_again,
      else: :cached
  end

  # Reads the channels and a person while the connection changes under them: what the old
  # connection reads must not stand in for the new one's, so both are read again after.
  def read_across_reconnect do
    disconnect()
    {:ok, _} = connect(:good)
    FakeSlack.hold("users.conversations")
    FakeSlack.hold("users.info")
    channels = Task.async(fn -> HalC2.Slack.channels() end)
    user = Task.async(fn -> HalC2.Slack.user("UDANA") end)

    for method <- ~w(users.conversations users.info) do
      receive do
        {:fake_slack_held, ^method, _} -> :ok
      after
        @wait -> exit({:never_read, method})
      end
    end

    disconnect()
    connected = connect(:good)
    FakeSlack.release()
    Task.await(channels, @wait)
    Task.await(user, @wait)

    read_again =
      for {method, read} <- [
            {"users.conversations", fn -> HalC2.Slack.channels() end},
            {"users.info", fn -> HalC2.Slack.user("UDANA") end}
          ] do
        before = length(FakeSlack.calls(method))
        {:ok, _} = read.()
        length(FakeSlack.calls(method)) == before + 1
      end

    {connected, List.to_tuple(read_again)}
  end

  def outage, do: FakeSlack.available(false)

  def restore(phase) do
    FakeSlack.available(true)
    if phase in [:connecting, :reconnecting], do: await("connected")
    :ok
  end

  def drop(up) do
    watch()
    FakeSlack.drop()
    receive_state("reconnecting")
    if up, do: receive_state("connected")
    :ok
  end

  # Drops the socket while the backoff is far off: by the time the status says
  # reconnecting, the connection that was lost must be gone, not restarted by slack_elixir
  # to take events nobody can answer. Then connects again, the retry being far off.
  def drop_held do
    for key <- [:slack_backoff_ms, :slack_backoff_max_ms],
        do: Application.put_env(:hal_c2, key, 600_000)

    live =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(HalC2.Slack.Connections),
          do: {pid, Process.monitor(pid)}

    watch()
    FakeSlack.drop()
    receive_state("reconnecting")

    stopped =
      Enum.all?(live, fn {pid, ref} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> true
        after
          @wait -> false
        end
      end)

    held =
      live != [] and stopped and DynamicSupervisor.which_children(HalC2.Slack.Connections) == []

    Application.put_env(:hal_c2, :slack_backoff_ms, 1)
    Application.put_env(:hal_c2, :slack_backoff_max_ms, 20)
    {if(held, do: :held, else: {:still_running, live}), connect(:good)}
  end

  def restart(stored, up) do
    HalC2.Prop.restart_service(HalC2.Slack)
    if stored and up, do: await("connected")
    :ok
  end

  # A mention in the bot's workspace and app, heard before this answers; one from
  # elsewhere is sent, and must never be heard (`heard/1`).
  def mention(where, n) do
    FakeSlack.event(mention_event(n, where), Map.put(origin(where), "event_id", event_id(n)))
    if where == :ours, do: heard_mention(n), else: :sent
  end

  # Slack delivers mention `n` again: a stale one is heard before this answers, one heard
  # already is sent, and must never be heard again (`heard/1`).
  def retry(n, kind) do
    FakeSlack.retry(mention_event(n, kind), event_id(n))
    if kind == :stale, do: heard_mention(n), else: :sent
  end

  defp event_id(n), do: "Ev#{n}"

  # Mention `n`; a stale one is by someone Slack never names.
  defp mention_event(n, kind) do
    {user, text} =
      case kind do
        :stale -> {"USTALE", "<@UHAL> stale"}
        where when where in [:ours, :heard] -> {"UDANA", "<@UHAL> what is late?"}
        _elsewhere -> {"UDANA", "<@UHAL> elsewhere"}
      end

    %{
      "type" => "app_mention",
      "channel" => "CPLAN",
      "user" => user,
      "text" => text,
      "ts" => ts(n)
    }
  end

  defp ts(n), do: "1800000000.#{n}"

  defp origin(:ours), do: %{}

  defp origin(:other_team),
    do: %{"team_id" => "T0OTHER", "authorizations" => [%{"team_id" => "T0OTHER"}]}

  defp origin(:other_app), do: %{"api_app_id" => "A0OTHER"}

  # In this workspace, in a channel shared with another, for that one's installation.
  defp origin(:their_installation), do: %{"authorizations" => [%{"team_id" => "T0OTHER"}]}

  defp heard_mention(n) do
    nonce = Process.get({__MODULE__, :nonce})
    ts = ts(n)

    receive do
      {:slack_event, ^nonce, "heard", %{"type" => "slack.mention", "ts" => ^ts}} -> :heard
    after
      @wait -> :not_heard
    end
  end

  # Waits until the status is `state`: now, or in a later push to this watcher.
  defp await(state) do
    case watch() do
      %{"state" => ^state} -> :ok
      _ -> receive_state(state)
    end
  end

  # Watches afresh, dropping what an earlier watch was told; answers the status now.
  defp watch do
    HalC2.Slack.unsubscribe(self())
    flush()
    {:ok, status} = HalC2.Slack.subscribe(self())
    status
  end

  defp flush do
    receive do
      {:hal_c2_slack, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  # Earlier sockets' opens and closes, told to this process since a hello/2 or hold/2.
  defp flush_sockets do
    receive do
      {:fake_slack_socket, _} -> flush_sockets()
    after
      0 -> :ok
    end
  end

  defp receive_state(state) do
    receive do
      {:hal_c2_slack, _, %{"state" => ^state}} -> :ok
      {:hal_c2_slack, _, _} -> receive_state(state)
    after
      @wait -> exit({:slack_never_became, state})
    end
  end

  # --- what the plugins heard -------------------------------------------------------

  # The granted plugin's slack.status events in the order it heard them, once as many as
  # the model owes have come; the mentions were waited on as they happened, and none from
  # elsewhere, read after a disconnect, or heard before may come. Nothing may reach the
  # other plugin.
  defp heard(model) do
    nonce = Process.get({__MODULE__, :nonce})
    owed = Enum.reverse(model.told)
    none = %{told: [], deaf: 0, elsewhere: 0, stale: 0, again: 0}
    got = gather(nonce, length(owed), none)
    got = %{got | told: Enum.reverse(got.told)}

    if got == %{none | told: owed},
      do: :ok,
      else: %{owed: owed, got: got}
  end

  defp gather(nonce, owed, got) do
    if length(got.told) == owed do
      drain(nonce, got)
    else
      receive do
        {:slack_event, ^nonce, id, event} -> gather(nonce, owed, count(got, id, event))
      after
        @wait -> drain(nonce, got)
      end
    end
  end

  # What has already arrived beyond what was owed.
  defp drain(nonce, got) do
    receive do
      {:slack_event, ^nonce, id, event} -> drain(nonce, count(got, id, event))
    after
      0 -> got
    end
  end

  defp count(got, "deaf", _event), do: Map.update!(got, :deaf, &(&1 + 1))

  defp count(got, "heard", %{"type" => "slack.status", "connected" => connected}),
    do: %{got | told: [connected | got.told]}

  defp count(got, "heard", %{"text" => "<@UHAL> elsewhere"}),
    do: Map.update!(got, :elsewhere, &(&1 + 1))

  defp count(got, "heard", %{"text" => "<@UHAL> stale"}),
    do: Map.update!(got, :stale, &(&1 + 1))

  defp count(got, "heard", %{"type" => "slack.mention"}),
    do: Map.update!(got, :again, &(&1 + 1))

  defp count(got, "heard", _event), do: got
end
