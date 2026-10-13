defmodule HalC2.Slack do
  @moduledoc """
  The MC's one Slack connection, which plugins borrow through `HalC2.Plugins.Host.slack/3`.
  It is a Slack app's bot token (`xoxb-`, the Web API) and app token (`xapp-`, Socket
  Mode), kept in the secret store (`<home>/secrets/slack.bin`) and never sent to a client,
  which sees only `tokensSet`.

  slack_elixir's `Slack.Supervisor` holds the socket. It registers global names, so a node
  has at most one, and its start raises when Slack refuses, so the tokens are checked first
  (`auth.test`, `apps.connections.open`) and it runs under a `DynamicSupervisor` of this
  module's own as a temporary child. Every attempt runs in a task, one at a time, so the
  server always answers; each begins by stopping what the last one started. A connection
  that drops (the socket or its supervisor exits) is torn down at once and made again with
  backoff (`:slack_backoff_ms`, doubling to a minute) while the status is `reconnecting`;
  Slack refusing the tokens ends in `failed`, an unreachable Slack keeps retrying.

  Watchers (`subscribe/1`) get `{:hal_c2_slack, node(), status}` on every change, and the
  plugins granted `slack:read` a `slack.status` event when it connects or stops.
  """

  use GenServer
  require Logger

  @secret "slack"
  @cache __MODULE__.Cache
  @connections __MODULE__.Connections
  @tasks __MODULE__.Tasks
  @not_connected "Slack is not connected on this MC."
  @max_backoff 60_000

  def child_spec(_) do
    children = [
      {Task.Supervisor, name: @tasks},
      {DynamicSupervisor, name: @connections, strategy: :one_for_one},
      %{id: :connection, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}}
    ]

    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :rest_for_one, name: __MODULE__.Supervisor]]}
    }
  end

  # --- clients ----------------------------------------------------------------------------

  @doc """
  The connection as clients see it:
  `%{"state", "team", "teamId", "bot", "botUserId", "error", "tokensSet"}`, `state`
  one of off, connecting, connected, reconnecting, failed.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> view(%{phase: :off, identity: nil, error: nil, tokens: nil})
  end

  @doc """
  Checks and stores `botToken` and `appToken`, replacing the connection there was;
  answers the status once connected, or Slack's reason. Tokens Slack refuses are not kept.
  """
  def connect(%{"botToken" => bot, "appToken" => app}) when is_binary(bot) and is_binary(app) do
    case {String.trim(bot), String.trim(app)} do
      {"", _} -> {:error, "A Slack bot token is required."}
      {_, ""} -> {:error, "A Slack app token is required."}
      tokens -> GenServer.call(__MODULE__, {:connect, tokens}, 60_000)
    end
  end

  def connect(_input), do: {:error, "A Slack bot token and app token are required."}

  @doc "Stops the connection and forgets the tokens."
  def disconnect, do: GenServer.call(__MODULE__, :disconnect)

  @doc "Sends `pid` `{:hal_c2_slack, node(), status}` on every change; answers the status now."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  @doc """
  `slack.*` RPCs: `status`, `connect`, `disconnect` and `manifest`, the Slack app
  manifest a user pastes into api.slack.com to make the app this connection needs.
  """
  def handle("status", _input), do: {:ok, status()}
  def handle("connect", input), do: connect(input)
  def handle("disconnect", _input), do: disconnect()
  def handle("manifest", _input), do: {:ok, %{"manifest" => manifest()}}
  def handle(method, _input), do: {:error, "unknown method slack.#{method}"}

  @doc "The Slack app manifest (YAML): the bot's scopes and events, with Socket Mode on."
  def manifest do
    """
    display_information:
      name: HAL-C2
      description: HAL-C2 plugins in Slack
    features:
      bot_user:
        display_name: HAL-C2
        always_online: true
    oauth_config:
      scopes:
        bot:
          - app_mentions:read
          - channels:history
          - channels:read
          - groups:history
          - groups:read
          - im:history
          - im:read
          - mpim:read
          - chat:write
          - commands
          - users:read
          - reactions:write
    settings:
      event_subscriptions:
        bot_events:
          - app_mention
          - message.channels
          - message.groups
          - message.im
          - member_joined_channel
          - channel_left
      interactivity:
        is_enabled: false
      org_deploy_enabled: false
      socket_mode_enabled: true
      token_rotation_enabled: false
    """
  end

  # --- plugins ----------------------------------------------------------------------------

  @writes ~w(post update respond react)

  @doc "Whether plugin call `method` writes to Slack (`slack:write`)."
  def write?(method), do: method in @writes

  @doc "A plugin's call, as `HalC2.Plugins.Host.slack/3` documents it."
  def call("status", _input) do
    identity = identity()

    {:ok,
     %{
       "connected" => identity != nil,
       "team" => identity[:team],
       "bot" => identity[:bot],
       "botUserId" => identity[:bot_user_id]
     }}
  end

  def call("channels", _input) do
    with {:ok, channels} <- channels(), do: {:ok, %{"channels" => channels}}
  end

  def call("replies", %{"channel" => channel, "ts" => ts}) do
    with {:ok, id} <- channel_id(channel),
         {:ok, %{"messages" => messages}} <-
           api(:get, "conversations.replies", %{channel: id, ts: ts}) do
      {:ok, %{"messages" => Enum.map(messages, &message(id, &1))}}
    end
  end

  def call("user", %{"user" => user}), do: user(user)

  def call("post", %{"channel" => channel, "text" => text} = input) do
    with {:ok, id} <- channel_id(channel),
         {:ok, body} <-
           api(:post, "chat.postMessage", posted(input, %{channel: id, text: text})) do
      {:ok, %{"channel" => body["channel"], "ts" => body["ts"]}}
    end
  end

  def call("update", %{"channel" => channel, "ts" => ts, "text" => text} = input) do
    with {:ok, id} <- channel_id(channel),
         {:ok, body} <-
           api(:post, "chat.update", posted(input, %{channel: id, ts: ts, text: text})) do
      {:ok, %{"channel" => body["channel"], "ts" => body["ts"]}}
    end
  end

  def call("react", %{"channel" => channel, "ts" => ts, "name" => name}) do
    with {:ok, id} <- channel_id(channel),
         {:ok, _} <- api(:post, "reactions.add", %{channel: id, timestamp: ts, name: name}) do
      {:ok, %{"ok" => true}}
    end
  end

  # A slash command's response_url takes the answer without the token, for a while after.
  def call("respond", %{"responseUrl" => "https://" <> _ = url, "text" => text}) do
    with {:ok, _token} <- token() do
      case Req.post(url, json: %{"text" => text, "response_type" => "ephemeral"}) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> {:ok, %{"ok" => true}}
        {:ok, %Req.Response{} = response} -> {:error, "Slack refused it: #{reason(response)}"}
        {:error, error} -> {:error, "Slack refused it: #{reason(error)}"}
      end
    end
  end

  def call(method, _input) when method in ~w(replies user post update react respond),
    do: {:error, "slack #{method} is missing an argument."}

  def call(method, _input), do: {:error, "unknown Slack call #{method}"}

  defp posted(input, args) do
    args
    |> then(&if input["threadTs"], do: Map.put(&1, :thread_ts, input["threadTs"]), else: &1)
    |> then(
      &if input["blocks"], do: Map.put(&1, :blocks, JSON.encode!(input["blocks"])), else: &1
    )
  end

  defp message(channel, message) do
    %{
      "channel" => channel,
      "ts" => message["ts"],
      "threadTs" => message["thread_ts"],
      "user" => message["user"],
      "userName" => message["user"] && user_name(message["user"]),
      "text" => message["text"] || "",
      "botId" => message["bot_id"]
    }
  end

  @doc """
  A Web API call with the bot token: `{:ok, body}`, `{:error, "Slack is not connected on
  this MC."}` or `{:error, "Slack refused it: <error>"}`. `verb` is `:get` or `:post`.
  """
  def api(verb, endpoint, args) do
    with {:ok, token} <- token(), do: request(verb, endpoint, token, args)
  end

  @doc "The bot token while connected."
  def token do
    case :ets.lookup(@cache, :token) do
      [{:token, token}] -> {:ok, token}
      [] -> {:error, @not_connected}
    end
  rescue
    ArgumentError -> {:error, @not_connected}
  end

  @doc "The bot's identity while connected: `%{team, team_id, bot, bot_user_id, bot_id}`."
  def identity do
    case :ets.lookup(@cache, :identity) do
      [{:identity, identity}] -> identity
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "The channels the bot is in, `%{\"id\", \"name\", \"private\"}`, cached until one changes."
  def channels do
    case :ets.lookup(@cache, :channels) do
      [{:channels, channels}] ->
        {:ok, channels}

      [] ->
        with {:ok, channels} <- fetch_channels() do
          :ets.insert(@cache, {:channels, channels})
          {:ok, channels}
        end
    end
  rescue
    ArgumentError -> {:error, @not_connected}
  end

  @doc "Forgets the cached channel list (the bot joined or left one)."
  def channels_changed do
    :ets.delete(@cache, :channels)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "A channel id for `\"#name\"` from the bot's channels; an id, or a name it is not in, as given."
  def channel_id("#" <> name = channel) do
    with {:ok, channels} <- channels() do
      case Enum.find(channels, &(&1["name"] == name)) do
        %{"id" => id} -> {:ok, id}
        nil -> {:ok, channel}
      end
    end
  end

  def channel_id(channel) when is_binary(channel) and channel != "", do: {:ok, channel}
  def channel_id(_channel), do: {:error, "A Slack channel is required."}

  @doc "A user's `%{\"id\", \"name\", \"realName\"}`, cached."
  def user(id) when is_binary(id) do
    case :ets.lookup(@cache, {:user, id}) do
      [{_, user}] ->
        {:ok, user}

      [] ->
        with {:ok, %{"user" => found}} <- api(:get, "users.info", %{user: id}) do
          user = %{
            "id" => id,
            "name" => found["name"],
            "realName" => found["real_name"] || get_in(found, ["profile", "real_name"])
          }

          :ets.insert(@cache, {{:user, id}, user})
          {:ok, user}
        end
    end
  rescue
    ArgumentError -> {:error, @not_connected}
  end

  def user(_id), do: {:error, "A Slack user is required."}

  @doc "A user's name, or nil when Slack does not say."
  def user_name(id) do
    case user(id) do
      {:ok, %{"name" => name}} -> name
      _ -> nil
    end
  end

  defp fetch_channels do
    with {:ok, token} <- token() do
      try do
        channels =
          "users.conversations"
          |> Slack.API.stream(token, "channels",
            types: "public_channel,private_channel",
            exclude_archived: true
          )
          |> Enum.map(
            &%{"id" => &1["id"], "name" => &1["name"], "private" => &1["is_private"] == true}
          )

        {:ok, channels}
      rescue
        e -> {:error, "Slack refused it: #{Exception.message(e)}"}
      end
    end
  end

  defp request(verb, endpoint, token, args) do
    case apply(Slack.API, verb, [endpoint, token, args]) do
      {:ok, body} -> {:ok, body}
      {:error, error} -> {:error, "Slack refused it: #{reason(error)}"}
    end
  end

  # What Slack said, or why it could not be asked.
  defp reason(%Req.Response{body: %{"error" => error}}), do: error
  defp reason(%Req.Response{status: status}), do: "HTTP #{status}"
  defp reason(%{__exception__: true} = e), do: Exception.message(e)
  defp reason(other), do: inspect(other)

  # --- server -----------------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
    tokens = stored_tokens()

    state = %{
      tokens: tokens,
      phase: :off,
      identity: nil,
      error: nil,
      # The attempt in flight, `%{ref, gen, tokens, from}`; one at a time.
      job: nil,
      # Bumped by every connect, disconnect and retry; an attempt from an older one is stale.
      gen: 0,
      # The connection wanted for `gen`: nil (none), or `{tokens, from}` not yet attempted.
      want: nil,
      # Something may still run under `@connections`, for the next attempt to stop.
      dirty: false,
      conn: nil,
      retries: 0,
      timer: nil,
      watchers: %{},
      # What the watchers were last told.
      seen: nil
    }

    state = %{state | seen: view(state)}

    if tokens,
      do: {:ok, %{state | phase: :connecting, want: {tokens, nil}}, {:continue, :drive}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:drive, state), do: {:noreply, state |> drive() |> publish()}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, view(state), state}

  def handle_call({:connect, tokens}, from, state) do
    state = supersede(state)
    state = %{state | gen: state.gen + 1, want: {tokens, from}, error: nil, retries: 0}
    state = state |> lose() |> phase(:connecting)
    {:noreply, state |> drive() |> publish()}
  end

  def handle_call(:disconnect, _from, state) do
    state = supersede(state)
    HalC2.Connect.Secrets.delete(@secret)
    state = %{state | gen: state.gen + 1, want: nil, tokens: nil, error: nil, retries: 0}
    state = state |> lose() |> phase(:off) |> drive() |> publish()
    {:reply, {:ok, view(state)}, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, view(state)}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({ref, result}, %{job: %{ref: ref} = job} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | job: nil}
    {:noreply, state |> settle(job, result) |> drive() |> publish()}
  end

  # The attempt crashed: Slack answered something slack_elixir did not expect.
  def handle_info({:DOWN, ref, :process, _, reason}, %{job: %{ref: ref} = job} = state) do
    state = %{state | job: nil}
    result = {:error, :unreachable, "The Slack connection failed: #{short(reason)}"}
    {:noreply, state |> settle(job, result) |> drive() |> publish()}
  end

  # slack_elixir's supervisor restarts a lost socket at once, which would take and ack
  # events while this says reconnecting, so the old connection is stopped now; the
  # retry makes a new one after the backoff.
  def handle_info({:DOWN, ref, :process, _, reason}, %{conn: %{refs: refs}} = state)
      when is_map_key(refs, ref) do
    Logger.info("Slack connection dropped: #{short(reason)}")
    state = %{lose(state) | dirty: true}
    {:noreply, state |> phase(:reconnecting) |> retry_later() |> drive() |> publish()}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.watchers do
      %{^pid => ^ref} -> {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:retry, gen}, %{gen: gen, tokens: tokens} = state) when tokens != nil do
    state = %{state | timer: nil, gen: gen + 1, want: {tokens, nil}}
    {:noreply, state |> drive() |> publish()}
  end

  def handle_info({:retry, _gen}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  # Starts the next attempt when none is in flight: the connection wanted, or stopping
  # what an earlier one left running.
  defp drive(%{job: nil, want: {tokens, from}} = state) do
    job = start_job(fn -> attempt(tokens) end)
    %{state | job: Map.merge(job, %{gen: state.gen, tokens: tokens, from: from}), want: nil}
  end

  defp drive(%{job: nil, want: nil, conn: nil, dirty: true} = state) do
    job = start_job(&teardown/0)
    %{state | job: Map.merge(job, %{gen: state.gen, tokens: nil, from: nil}), dirty: false}
  end

  defp drive(state), do: state

  defp start_job(fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(@tasks, fun)
    %{ref: ref}
  end

  # A stale attempt's connection is left for the next attempt (or a teardown) to stop.
  defp settle(state, %{gen: gen, tokens: nil}, _result) when gen == state.gen, do: state

  defp settle(state, %{gen: gen} = job, result) when gen != state.gen do
    if job.from, do: GenServer.reply(job.from, {:error, "Another Slack connection replaced it."})
    if match?({:ok, _}, result), do: %{state | dirty: true}, else: state
  end

  defp settle(state, job, {:ok, %{supervisor: sup, socket: socket, identity: identity}}) do
    refs = Map.new([sup, socket], &{Process.monitor(&1), &1})

    if job.tokens != state.tokens do
      {bot, app} = job.tokens

      HalC2.Connect.Secrets.put(
        @secret,
        JSON.encode!(%{"botToken" => bot, "appToken" => app})
      )
    end

    :ets.insert(@cache, [{:token, elem(job.tokens, 0)}, {:identity, identity}])

    state =
      %{state | tokens: job.tokens, conn: %{refs: refs}, identity: identity, error: nil}
      |> Map.put(:retries, 0)
      |> phase(:connected)

    if job.from, do: GenServer.reply(job.from, {:ok, view(state)})
    state
  end

  # A user's tokens Slack refused are not kept; the stored ones it now refuses are forgotten.
  defp settle(state, job, {:error, :refused, message}) do
    HalC2.Connect.Secrets.delete(@secret)
    state = %{state | tokens: nil, error: message, dirty: true} |> phase(:failed)
    if job.from, do: GenServer.reply(job.from, {:error, message})
    state
  end

  # A user's connect that fails is not kept either; stored tokens retry until Slack answers.
  defp settle(state, %{from: from}, {:error, :unreachable, message}) do
    state = %{state | dirty: true, error: message}

    cond do
      from != nil ->
        HalC2.Connect.Secrets.delete(@secret)
        GenServer.reply(from, {:error, message})
        %{state | tokens: nil} |> phase(:failed)

      state.tokens != nil ->
        state
        |> phase(if state.phase == :connecting, do: :connecting, else: :reconnecting)
        |> retry_later()

      true ->
        phase(state, :off)
    end
  end

  defp retry_later(state) do
    cap = Application.get_env(:hal_c2, :slack_backoff_max_ms, @max_backoff)
    delay = min(backoff() * Integer.pow(2, min(state.retries, 16)), cap)
    timer = Process.send_after(self(), {:retry, state.gen}, delay)
    %{state | timer: timer, retries: state.retries + 1}
  end

  defp backoff, do: Application.get_env(:hal_c2, :slack_backoff_ms, 1_000)

  # A connect or disconnect replaces an earlier connect still waiting to start.
  defp supersede(%{want: {_, from}} = state) when from != nil do
    GenServer.reply(from, {:error, "Another Slack connection replaced it."})
    %{state | want: nil}
  end

  defp supersede(state), do: state

  # Forgets the live connection (its processes are stopped by the next attempt).
  defp lose(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    for {ref, _} <- (state.conn && state.conn.refs) || %{},
        do: Process.demonitor(ref, [:flush])

    :ets.delete_all_objects(@cache)
    %{state | conn: nil, timer: nil, identity: nil, dirty: state.dirty or state.conn != nil}
  end

  # Plugins hear when it connects or stops, from a process of its own: a plugin may be
  # asking this server something meanwhile.
  defp phase(state, phase) do
    if state.phase == :connected != (phase == :connected) do
      event = %{"type" => "slack.status", "connected" => phase == :connected}
      Task.start(fn -> HalC2.Plugins.slack_event(event) end)
    end

    %{state | phase: phase}
  end

  # Tells the watchers when what they see changed.
  defp publish(state) do
    view = view(state)

    if view != state.seen,
      do: for({pid, _} <- state.watchers, do: send(pid, {:hal_c2_slack, node(), view}))

    %{state | seen: view}
  end

  defp view(state) do
    identity = state.identity || %{}

    %{
      "state" => Atom.to_string(state.phase),
      "team" => identity[:team],
      "teamId" => identity[:team_id],
      "bot" => identity[:bot],
      "botUserId" => identity[:bot_user_id],
      "error" => state.error,
      "tokensSet" => state.tokens != nil
    }
  end

  defp stored_tokens do
    with bytes when is_binary(bytes) <- HalC2.Connect.Secrets.get(@secret),
         {:ok, %{"botToken" => bot, "appToken" => app}} when is_binary(bot) and is_binary(app) <-
           JSON.decode(bytes) do
      {bot, app}
    else
      _ -> nil
    end
  end

  # --- attempts (in a task) ---------------------------------------------------------------

  defp attempt({bot_token, app_token}) do
    teardown()

    with {:ok, auth} <- check(:get, "auth.test", bot_token, "bot token"),
         :ok <- bot_token?(auth),
         {:ok, _} <- check(:post, "apps.connections.open", app_token, "app token"),
         {:ok, sup} <- start_connection(bot_token, app_token) do
      socket =
        Enum.find_value(Supervisor.which_children(sup), sup, fn
          {Slack.Socket, pid, _, _} when is_pid(pid) -> pid
          _ -> nil
        end)

      identity = %{
        team: auth["team"],
        team_id: auth["team_id"],
        bot: auth["user"],
        bot_user_id: auth["user_id"],
        bot_id: auth["bot_id"]
      }

      {:ok, %{supervisor: sup, socket: socket, identity: identity}}
    end
  end

  defp check(verb, endpoint, token, what) do
    case apply(Slack.API, verb, [endpoint, token, %{}]) do
      {:ok, body} ->
        {:ok, body}

      {:error, %Req.Response{body: %{"error" => error}}} ->
        {:error, :refused, "Slack refused the #{what}: #{error}"}

      {:error, error} ->
        {:error, :unreachable, "Could not reach Slack: #{reason(error)}"}
    end
  end

  defp bot_token?(%{"bot_id" => id}) when is_binary(id), do: :ok
  defp bot_token?(_), do: {:error, :refused, "Slack refused the bot token: not a bot token"}

  defp start_connection(bot_token, app_token) do
    spec = %{
      id: Slack.Supervisor,
      start:
        {Slack.Supervisor, :start_link,
         [[bot_token: bot_token, app_token: app_token, bot: HalC2.Slack.Bot]]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(@connections, spec) do
      {:ok, sup} ->
        {:ok, sup}

      {:error, reason} ->
        Logger.warning("Slack connection did not start: #{short(reason)}")
        {:error, :unreachable, "The Slack connection did not start: #{short(reason)}"}
    end
  end

  defp teardown do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@connections),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(@connections, pid)

    :ok
  end

  defp short(reason), do: inspect(reason, limit: 5, printable_limit: 200)
end
