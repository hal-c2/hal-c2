defmodule HalC2.Slack do
  @moduledoc """
  The MC's one Slack connection, which plugins borrow through `HalC2.Plugins.Host.slack/3`.
  It is a Slack app's bot token (`xoxb-`, the Web API) and app token (`xapp-`, Socket
  Mode), kept in the secret store (`<home>/secrets/slack.bin`) and never sent to a client,
  which sees only `tokensSet`.

  An attempt checks the bot token (`auth.test`, then `bots.info` for its app), opens
  Socket Mode with the app token (`apps.connections.open`) and starts `HalC2.Slack.Socket`
  under a `DynamicSupervisor` of this module's own, connected once Slack's hello names the
  bot token's app; the socket hands on only events for that app and the bot's workspace,
  and none before this server has made the connection its own.
  Every attempt runs in a task, one at a time, so the server always answers; each begins
  by stopping what the last one started. A connection that drops is made again with
  backoff (`:slack_backoff_ms`, doubling to a minute) while the status is `reconnecting`;
  Slack refusing the tokens (`invalid_auth`, `token_revoked` and the like) ends in
  `failed` and forgets them; a Slack unreachable, rate limiting or failing in any other
  way keeps retrying with them.

  Watchers (`subscribe/2`) get `{:hal_c2_slack, node(), status}` on every change (one
  that subscribed under a ref gets it wrapped as `HalC2.Watchers` sends it), and the
  plugins granted `slack:read` a `slack.status` event when it connects or stops,
  in order.
  """

  use GenServer
  require Logger

  @secret "slack"
  @cache __MODULE__.Cache
  @delivered __MODULE__.Delivered
  @connections __MODULE__.Connections
  @tasks __MODULE__.Tasks
  @courier __MODULE__.Courier
  @not_connected "Slack is not connected on this MC."
  @max_backoff 60_000
  # Slack retries an event for minutes; far fewer reach plugins meanwhile.
  @remembered 10_000

  def child_spec(_) do
    # The courier comes first so that a crash of the rest leaves it, and the order it
    # keeps, alone. Trapping exits, it stops behind the changes it holds, not before them.
    courier = fn ->
      Process.flag(:trap_exit, true)
      %{}
    end

    children = [
      %{id: @courier, start: {Agent, :start_link, [courier, [name: @courier]]}},
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
      tokens -> connect_with(tokens)
    end
  end

  def connect(_input), do: {:error, "A Slack bot token and app token are required."}

  # A failed call exits with its message, the tokens in it: neither the client nor the
  # log may see that.
  defp connect_with(tokens) do
    GenServer.call(__MODULE__, {:connect, tokens}, 60_000)
  catch
    :exit, {:timeout, _} -> {:error, "Slack did not answer the connect in time."}
    :exit, _ -> {:error, "The Slack connection is not running on this MC."}
  end

  @doc "Stops the connection and forgets the tokens."
  def disconnect, do: GenServer.call(__MODULE__, :disconnect)

  @doc """
  Sends `pid` `{:hal_c2_slack, node(), status}` on every change until it unsubscribes
  `ref` or exits; answers the status now. Under a `ref`, the message comes as
  `{:hal_c2_watched, refs, message}` (`HalC2.Watchers`).
  """
  def subscribe(pid, ref \\ nil), do: GenServer.call(__MODULE__, {:subscribe, pid, ref})

  @doc "Lets go of `pid`'s subscription `ref` only."
  def unsubscribe(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unsubscribe, pid, ref})

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
          - mpim:history
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
          - message.mpim
          - member_joined_channel
          - channel_left
          - channel_rename
          - channel_archive
          - channel_unarchive
          - channel_deleted
          - group_left
          - group_rename
          - group_archive
          - group_unarchive
          - group_deleted
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
    # A later page can start with the parent again; each message is kept once.
    with {:ok, id} <- channel_id(channel),
         {:ok, messages} <- pages("conversations.replies", %{channel: id, ts: ts}, "messages") do
      {:ok, %{"messages" => messages |> Enum.uniq_by(& &1["ts"]) |> Enum.map(&message(id, &1))}}
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
  # Only Slack's own hosts take it, so a plugin cannot point the MC at anything else.
  def call("respond", %{"responseUrl" => url, "text" => text}) when is_binary(url) do
    with :ok <- response_url(url),
         {:ok, _token} <- token() do
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

  @response_hosts ~w(hooks.slack.com hooks.slack-gov.com)

  defp response_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil}
      when host in @response_hosts ->
        :ok

      _ ->
        {:error, "slack respond takes only a Slack response URL."}
    end
  end

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
    with {:ok, token, _connection} <- connection(), do: {:ok, token}
  end

  # The bot token and a ref of this connection, read together.
  defp connection do
    case :ets.lookup(@cache, :token) do
      [{:token, token, connection}] -> {:ok, token, connection}
      [] -> {:error, @not_connected}
    end
  rescue
    ArgumentError -> {:error, @not_connected}
  end

  @doc "The bot's identity while connected: `%{team, team_id, bot, bot_user_id, bot_id, app_id}`."
  def identity do
    case :ets.lookup(@cache, :identity) do
      [{:identity, identity}] -> identity
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # What is read from Slack is cached under the connection it was read on, so a read
  # that outlives its connection is never found by the next one; `lose/1` clears it all.
  # The channel list is also cached under how many times the channels changed when it
  # was read, so a read that outlives a change is never found either.
  @doc "The channels the bot is in, `%{\"id\", \"name\", \"private\"}`, cached until one changes."
  def channels do
    with {:ok, token, connection} <- connection() do
      key = {:channels, connection, changes()}

      case :ets.lookup(@cache, key) do
        [{_, channels}] ->
          {:ok, channels}

        [] ->
          with {:ok, channels} <- fetch_channels(token) do
            :ets.insert(@cache, {key, channels})
            {:ok, channels}
          end
      end
    end
  rescue
    ArgumentError -> {:error, @not_connected}
  end

  defp changes do
    case :ets.lookup(@cache, :channel_changes) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  @doc "Forgets the cached channel list (the bot joined or left one, or one was renamed, archived or deleted)."
  def channels_changed do
    :ets.update_counter(@cache, :channel_changes, 1, {:channel_changes, 0})
    :ets.match_delete(@cache, {{:channels, :_, :_}, :_})
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
    with {:ok, token, connection} <- connection() do
      case :ets.lookup(@cache, {:user, connection, id}) do
        [{_, user}] ->
          {:ok, user}

        [] ->
          with {:ok, %{"user" => found}} <- request(:get, "users.info", token, %{user: id}) do
            user = %{
              "id" => id,
              "name" => found["name"],
              "realName" => found["real_name"] || get_in(found, ["profile", "real_name"])
            }

            :ets.insert(@cache, {{:user, connection, id}, user})
            {:ok, user}
          end
      end
    end
  rescue
    ArgumentError -> {:error, @not_connected}
  end

  def user(_id), do: {:error, "A Slack user is required."}

  @doc """
  Whether the event Slack names `id` (the Events API's `event_id`) reaches plugins for the
  first time, remembering it if so. Socket Mode delivers an event again, with the same id,
  when the ack did not reach Slack, on the next connection too, so the last #{@remembered}
  are kept across reconnects; a restart of the service forgets them. A nil id (a slash
  command, which Slack does not deliver again) is always new.
  """
  def first_delivery?(nil), do: true

  def first_delivery?(id) do
    n = :ets.update_counter(@delivered, :count, 1, {:count, 0})

    if rem(n, @remembered) == 0 do
      old = [{{{:event, :_}, :"$1"}, [{:"=<", :"$1", n - @remembered}], [true]}]
      :ets.select_delete(@delivered, old)
    end

    :ets.insert_new(@delivered, {{:event, id}, n})
  rescue
    ArgumentError -> true
  end

  @doc "A user's name, or nil when Slack does not say."
  def user_name(id) do
    case user(id) do
      {:ok, %{"name" => name}} -> name
      _ -> nil
    end
  end

  defp fetch_channels(token) do
    args = %{types: "public_channel,private_channel", exclude_archived: true, limit: 200}

    with {:ok, channels} <- pages("users.conversations", token, args, "channels", []) do
      {:ok,
       Enum.map(
         channels,
         &%{"id" => &1["id"], "name" => &1["name"], "private" => &1["is_private"] == true}
       )}
    end
  end

  # Every page of a cursor-paginated Web API method's `key` list, in order. Not
  # `Slack.API.stream/4`: it sends the cursor as `next_cursor`, which Slack ignores, so
  # past one page it asks for the first page forever.
  defp pages(endpoint, args, key) do
    with {:ok, token} <- token(), do: pages(endpoint, token, Map.put(args, :limit, 200), key, [])
  end

  defp pages(endpoint, token, args, key, acc) do
    with {:ok, body} <- request(:get, endpoint, token, args) do
      acc = [Map.get(body, key, []) | acc]

      case get_in(body, ["response_metadata", "next_cursor"]) do
        cursor when cursor in [nil, ""] -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
        cursor -> pages(endpoint, token, Map.put(args, :cursor, cursor), key, acc)
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
    :ets.new(@delivered, [:named_table, :public, :set, write_concurrency: true])
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

  # What a crash report or `:sys.get_status/1` shows, the tokens left out.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %{tokens: _} = state} -> {:state, redact(state)}
      {:message, message} -> {:message, redact(message)}
      {:queue, queue} -> {:queue, Enum.map(queue, &redact/1)}
      other -> other
    end)
  end

  defp redact(%{tokens: _, want: _, job: _} = state) do
    %{
      state
      | tokens: state.tokens && :redacted,
        want: with({_tokens, from} <- state.want, do: {:redacted, from}),
        job: state.job && %{state.job | tokens: state.job.tokens && :redacted}
    }
  end

  defp redact({:connect, _tokens}), do: {:connect, :redacted}

  defp redact({:"$gen_call", from, {:connect, _tokens}}),
    do: {:"$gen_call", from, {:connect, :redacted}}

  defp redact(other), do: other

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

  def handle_call({:subscribe, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    {:reply, {:ok, view(state)}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state),
    do: {:noreply, %{state | watchers: HalC2.Watchers.remove(state.watchers, pid, ref)}}

  @impl true
  def handle_info({ref, result}, %{job: %{ref: ref} = job} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | job: nil}
    {:noreply, state |> settle(job, result) |> drive() |> publish()}
  end

  # The attempt crashed on something Slack answered.
  def handle_info({:DOWN, ref, :process, _, reason}, %{job: %{ref: ref} = job} = state) do
    state = %{state | job: nil}
    result = {:error, :unreachable, "The Slack connection failed: #{short(reason)}"}
    {:noreply, state |> settle(job, result) |> drive() |> publish()}
  end

  # The socket ended; what is left of it is stopped now, and the retry makes a new
  # one after the backoff.
  def handle_info({:DOWN, ref, :process, _, reason}, %{conn: %{refs: refs}} = state)
      when is_map_key(refs, ref) do
    Logger.info("Slack connection dropped: #{short(reason)}")
    state = %{lose(state) | dirty: true}
    {:noreply, state |> phase(:reconnecting) |> retry_later() |> drive() |> publish()}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    {:noreply, %{state | watchers: HalC2.Watchers.down(state.watchers, ref, pid)}}
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

  # A stale attempt's connection is left for the next attempt (or a teardown) to stop,
  # whatever it answered: one that gave up waiting for hello leaves its socket running.
  defp settle(state, %{gen: gen, tokens: nil}, _result) when gen == state.gen, do: state

  defp settle(state, %{gen: gen} = job, _result) when gen != state.gen do
    if job.from, do: GenServer.reply(job.from, {:error, "Another Slack connection replaced it."})
    %{state | dirty: true}
  end

  defp settle(state, job, {:ok, %{socket: socket, identity: identity}}) do
    refs = %{Process.monitor(socket) => socket}

    if job.tokens != state.tokens do
      {bot, app} = job.tokens

      HalC2.Connect.Secrets.put(
        @secret,
        JSON.encode!(%{"botToken" => bot, "appToken" => app})
      )
    end

    :ets.insert(@cache, [{:token, elem(job.tokens, 0), make_ref()}, {:identity, identity}])
    HalC2.Slack.Socket.activate(socket)

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

  # Forgets the live connection (its processes are stopped by the next attempt). Its
  # socket stops acking first: until the next attempt tears it down it would ack events
  # the bot, with no identity, drops, and Slack does not deliver an acked event again.
  defp lose(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    for {ref, socket} <- (state.conn && state.conn.refs) || %{} do
      Process.demonitor(ref, [:flush])
      HalC2.Slack.Socket.deactivate(socket)
    end

    :ets.delete_all_objects(@cache)
    %{state | conn: nil, timer: nil, identity: nil, dirty: state.dirty or state.conn != nil}
  end

  # Plugins hear when it connects or stops through the courier, not this server: a
  # plugin may be asking this server something meanwhile. The courier takes the
  # changes in order and keeps the process that handed each plugin the last one, so
  # a plugin hears them one at a time, in order.
  defp phase(state, phase) do
    if state.phase == :connected != (phase == :connected) do
      event = %{"type" => "slack.status", "connected" => phase == :connected}
      Agent.cast(@courier, &HalC2.Plugins.slack_event(event, &1))
    end

    %{state | phase: phase}
  end

  # Tells the watchers when what they see changed.
  defp publish(state) do
    view = view(state)

    if view != state.seen,
      do: HalC2.Watchers.notify(state.watchers, {:hal_c2_slack, node(), view})

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

    with {:ok, auth} <- check(:get, "auth.test", bot_token, %{}, "bot token"),
         :ok <- bot_token?(auth),
         {:ok, %{"bot" => bot}} <-
           check(:get, "bots.info", bot_token, %{bot: auth["bot_id"]}, "bot token"),
         :ok <- app?(bot),
         {:ok, open} <- check(:post, "apps.connections.open", app_token, %{}, "app token"),
         {:ok, url} <- url(open) do
      identity = %{
        team: auth["team"],
        team_id: auth["team_id"],
        bot: auth["user"],
        bot_user_id: auth["user_id"],
        bot_id: auth["bot_id"],
        app_id: bot["app_id"]
      }

      with {:ok, socket} <- start_connection(url, identity), do: hello(socket, identity)
    end
  end

  # Slack's errors that say the token will never do. Only these forget stored tokens, which
  # the user must then fetch from api.slack.com again; any other error (`ratelimited`,
  # `internal_error`, `service_unavailable`, one Slack adds later) is retried with them,
  # which costs a request a minute at most and shows the error meanwhile.
  @refusals ~w(invalid_auth not_authed invalid_token account_inactive token_revoked
               token_expired not_allowed_token_type missing_scope no_permission access_denied
               ekm_access_denied team_access_not_granted org_login_required
               two_factor_setup_required bot_not_found)

  defp check(verb, endpoint, token, args, what) do
    case apply(Slack.API, verb, [endpoint, token, args]) do
      {:ok, body} ->
        {:ok, body}

      {:error, %Req.Response{body: %{"error" => error}}} when error in @refusals ->
        {:error, :refused, "Slack refused the #{what}: #{error}"}

      {:error, %Req.Response{body: %{"error" => error}}} ->
        {:error, :unreachable, "Slack could not check the #{what}: #{error}"}

      {:error, error} ->
        {:error, :unreachable, "Could not reach Slack: #{reason(error)}"}
    end
  end

  defp bot_token?(%{"bot_id" => id}) when is_binary(id), do: :ok
  defp bot_token?(_), do: {:error, :refused, "Slack refused the bot token: not a bot token"}

  defp app?(%{"app_id" => id}) when is_binary(id), do: :ok
  defp app?(_), do: {:error, :refused, "Slack refused the bot token: it names no app"}

  defp url(%{"url" => url}) when is_binary(url), do: {:ok, url}
  defp url(_), do: {:error, :unreachable, "Slack handed out no Socket Mode URL."}

  defp start_connection(url, identity) do
    case DynamicSupervisor.start_child(
           @connections,
           {HalC2.Slack.Socket, {url, identity, self()}}
         ) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        Logger.warning("Slack connection did not start: #{short(reason)}")
        {:error, :unreachable, "The Slack connection did not start: #{short(reason)}"}
    end
  end

  # Slack's hello names the app the app token is for, which must be the bot token's:
  # each answers for itself, so a pair from two apps would otherwise connect.
  defp hello(socket, identity) do
    ref = Process.monitor(socket)
    app = identity.app_id

    receive do
      {:slack_hello, ^socket, ^app} ->
        Process.demonitor(ref, [:flush])
        {:ok, %{socket: socket, identity: identity}}

      {:slack_hello, ^socket, _other} ->
        Process.demonitor(ref, [:flush])
        DynamicSupervisor.terminate_child(@connections, socket)
        {:error, :refused, "The bot token and app token belong to different Slack apps."}

      {:DOWN, ^ref, :process, ^socket, reason} ->
        {:error, :unreachable, "The Slack connection failed: #{short(reason)}"}
    after
      Application.get_env(:hal_c2, :slack_hello_ms, 10_000) ->
        Process.demonitor(ref, [:flush])
        {:error, :unreachable, "Slack did not say hello."}
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
