defmodule HalC2.Web.Socket do
  @moduledoc """
  One client connection. See `HalC2.Web.Protocol` for the wire format.

  Stream subscriptions may live on any MC in the cluster; the owning MC's stream
  server sends straight to this process, already trimmed to what the client holds
  (`HalC2.Streams.Server`). Incoming events are buffered and flushed
  once the mailbox is drained, merged per entity, so a burst of streaming tokens
  becomes one frame. A subscription whose unsent buffer passes `@max_buffered` is
  dropped with a `resync`; the client resubscribes from its offset and the stream
  replays from the log instead of this process holding the backlog. That replay is
  never itself cut short by a resync, or a client behind by more than the limit would
  be told to resync forever.

  Sidebar rows are buffered the same way, per MC, and flushed as one `shell.rows` frame
  per MC. The other shell messages are not buffered, but the rows before them go out first.

  The socket monitors each stream's server. One that stops took the subscription
  with it, so the client is sent a `resync` and resubscribes from what it holds;
  one whose MC left the cluster is an `error`, and the client follows it again once
  that MC is back.
  """

  @behaviour WebSock

  alias HalC2.Web.Protocol

  require Logger

  @max_buffered 8 * 1024 * 1024

  # Sockets are Bandit's processes, so a code upgrade in place (`HalC2.Upgrade`) runs no
  # `code_change/3` for them: each callback first brings an older state up to date.
  @state_version 7

  # The services `watch_spec/1` subscribes to as `{kind, mc}`, by kind.
  @services %{
    resource_telemetry: HalC2.Diagnostics,
    preview: HalC2.Preview,
    local_servers: HalC2.LocalServers,
    devices: HalC2.Devices,
    slack: HalC2.Slack,
    project_clones: HalC2.ProjectClones,
    scheduled_tasks: HalC2.ScheduledTasks,
    background_policy: HalC2.BackgroundPolicy,
    pull_request_refreshes: HalC2.PullRequests.Refreshes,
    plugins: HalC2.Plugins
  }

  # The tags of the messages watched services send (`watched/3`).
  @watched ~w(hal_c2_settings hal_c2_themes hal_c2_usage_limit_sources hal_c2_keybindings
              hal_c2_providers_changed hal_c2_usage_limits_command hal_c2_upgraded
              hal_c2_auth_access hal_c2_resource_telemetry hal_c2_preview hal_c2_local_servers
              hal_c2_devices hal_c2_slack hal_c2_project_clones hal_c2_scheduled_tasks
              hal_c2_background_policy hal_c2_pull_request_refreshes hal_c2_plugins
              hal_c2_plugin_topic hal_c2_worktree_setup hal_c2_provider_install
              hal_c2_provider_auth hal_c2_vcs hal_c2_terminals)a

  @doc "How long a client RPC may run before it fails as timed out (`:rpc_timeout`)."
  def rpc_timeout, do: Application.get_env(:hal_c2, :rpc_timeout, :timer.minutes(10))

  @impl true
  def init(opts) do
    # A socket opened with a ticket belongs to that client's session.
    session = opts[:session]
    if session, do: HalC2.Auth.connected(session)

    state = %{
      v: @state_version,
      session: session,
      # What the session may do; the MC's own token may do anything.
      scopes: session_scopes(session),
      subs: %{},
      # stream id => {the subscription's id, the tag its messages carry}
      by_stream: %{},
      # The monitor of each stream subscription's server => {its id, the server}.
      monitors: %{},
      by_terminal: %{},
      buffers: %{},
      shell: %{},
      flush_scheduled: false
    }

    {:push,
     Protocol.encode(%{
       "t" => "hello",
       "protocol" => Protocol.version(),
       "mc" => Atom.to_string(node()),
       "environment" => HalC2.Environment.id()
     }), state}
  end

  @impl true
  def handle_in(frame, state)
      when not is_map_key(state, :v) or :erlang.map_get(:v, state) != @state_version,
      do: handle_in(frame, migrate(state))

  def handle_in({frame, [opcode: :text]}, state) do
    case Protocol.decode(frame, known_mcs()) do
      {:ok, :ping} ->
        {:push, Protocol.encode(%{"t" => "pong"}), state}

      {:ok, {:sub, id, shape, offset}} ->
        scope = shape_scope(shape)

        if allowed?(state, scope),
          do: subscribe(state, id, shape, offset),
          else: {:push, Protocol.encode(error_frame(id, "#{scope} is required")), state}

      {:ok, {:more, id, items}} ->
        with %{^id => {:stream, mc, stream_id}} <- state.subs,
             do: :erpc.cast(mc, HalC2.Streams, :more, [stream_id, self(), items])

        {:ok, state}

      {:ok, {:unsub, id}} ->
        {:ok, unsubscribe(state, id)}

      {:ok, {:rpc, id, environment, method, payload}} ->
        {:ok, rpc(state, id, environment, method, payload)}

      {:error, reason} ->
        {:push, Protocol.encode(%{"t" => "error", "reason" => reason}), state}
    end
  end

  def handle_in(_binary, state), do: {:ok, state}

  @impl true
  def handle_info(message, state)
      when not is_map_key(state, :v) or :erlang.map_get(:v, state) != @state_version,
      do: handle_info(message, migrate(state))

  # One for a subscription followed before this one, still on its way, is not this
  # one's. A follow that gave up may yet be taken: that subscription goes live, and is
  # ended then.
  def handle_info({:hal_c2_stream, {stream_id, tag}, message}, state) do
    case {state.by_stream, message, tag} do
      {%{^stream_id => {id, ^tag}}, _, _} ->
        stream_message(state, id, message)

      {_, {:live, _, _}, {mc, _ref}} ->
        :erpc.cast(mc, HalC2.Streams, :unsubscribe, [stream_id, self(), tag])
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  # For a subscription followed before an upgrade in place, which has no tag (members
  # run one version, so no other MC sends one untagged). A later follow's is not it.
  def handle_info({:hal_c2_stream, stream_id, message}, state) do
    case state.by_stream do
      %{^stream_id => {id, nil}} -> stream_message(state, id, message)
      _ -> {:ok, state}
    end
  end

  def handle_info({:hal_c2_shell, {:rows, mc, rows, version}}, state) do
    case shell_sub(state) do
      {_id, _} -> {:ok, schedule_flush(buffer_shell_rows(state, mc, rows, version))}
      nil -> {:ok, state}
    end
  end

  # Rows sent before this message reach the client before it.
  def handle_info({:hal_c2_shell, message}, state) do
    case shell_sub(state) do
      {id, _} ->
        {frames, state} = flush_shell(state)
        {:push, frames ++ [Protocol.encode(shell_message(id, message))], state}

      nil ->
        {:ok, state}
    end
  end

  def handle_info({:hal_c2_terminal, key, event}, state) do
    case state.by_terminal do
      %{^key => id} ->
        {:push, Protocol.encode(%{"t" => "terminal", "id" => id, "event" => event}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:hal_c2_server_update, mc, event}, state) do
    case state.by_terminal do
      %{{:server_update, ^mc} => id} ->
        case event do
          {:error, detail} ->
            frame =
              Map.put(error_frame(id, detail["reason"] || "update failed"), "detail", detail)

            {:push, Protocol.encode(frame), unsubscribe(state, id)}

          %{"type" => "complete"} ->
            frames = [
              Protocol.encode(%{"t" => "serverUpdate", "id" => id, "event" => event}),
              Protocol.encode(%{"t" => "end", "id" => id})
            ]

            {:push, frames, unsubscribe(state, id)}

          _ ->
            {:push, Protocol.encode(%{"t" => "serverUpdate", "id" => id, "event" => event}),
             state}
        end

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:hal_c2_relay_client_install, mc, event}, state) do
    case state.by_terminal do
      %{{:relay_client_install, ^mc} => id} ->
        case event do
          {:error, detail} ->
            frame = Map.put(error_frame(id, detail["reason"]), "detail", detail)
            {:push, Protocol.encode(frame), unsubscribe(state, id)}

          %{"type" => "complete"} ->
            frames = [
              Protocol.encode(%{"t" => "relayClientInstall", "id" => id, "event" => event}),
              Protocol.encode(%{"t" => "end", "id" => id})
            ]

            {:push, frames, unsubscribe(state, id)}

          _ ->
            {:push, Protocol.encode(%{"t" => "relayClientInstall", "id" => id, "event" => event}),
             state}
        end

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:hal_c2_git_action, action_id, event}, state) do
    case state.by_terminal do
      %{{:git_action, ^action_id} => id} ->
        frame = Protocol.encode(%{"t" => "gitAction", "id" => id, "event" => event})

        # The action's last event ends the subscription.
        if event["kind"] in ["action_finished", "action_failed"],
          do: {:push, frame, unsubscribe(state, id)},
          else: {:push, frame, state}

      _ ->
        {:ok, state}
    end
  end

  # A change from a service this socket watches, for the subscriptions it was sent to.
  def handle_info({:hal_c2_watched, refs, message}, state), do: watched(state, message, refs)

  # Slack's, sent before an upgrade in place.
  def handle_info({:hal_c2_slack, mc, refs, status}, state) when is_list(refs),
    do: watched(state, {:hal_c2_slack, mc, status}, refs)

  # To subscriptions made before an upgrade in place, which hold no ref.
  def handle_info(message, state)
      when is_tuple(message) and tuple_size(message) > 1 and elem(message, 0) in @watched,
      do: watched(state, message, [nil])

  def handle_info({:hal_c2_preview_automation, mc, client_id, event}, state) do
    case state.by_terminal do
      %{{:preview_automation, ^mc, ^client_id} => id} when event == :end ->
        {:push, Protocol.encode(%{"t" => "end", "id" => id}), unsubscribe(state, id)}

      %{{:preview_automation, ^mc, ^client_id} => id} ->
        {:push, Protocol.encode(%{"t" => "previewAutomation", "id" => id, "event" => event}),
         state}

      _ ->
        {:ok, state}
    end
  end

  # An administrator revoked this socket's session: it may not stay connected.
  def handle_info({:hal_c2_session_revoked, session}, %{session: session} = state),
    do: {:stop, :normal, {4401, "session revoked"}, state}

  def handle_info({:rpc_reply, id, reply}, state) do
    frame =
      case reply do
        {:ok, result} ->
          %{"t" => "rpc.result", "id" => id, "result" => result}

        {:error, %{} = detail} ->
          %{
            "t" => "rpc.error",
            "id" => id,
            "error" => to_string(detail["message"] || detail["_tag"]),
            "detail" => Map.delete(detail, "message")
          }

        {:error, message} ->
          %{"t" => "rpc.error", "id" => id, "error" => to_string(message)}
      end

    {:push, Protocol.encode(frame), state}
  end

  def handle_info(:flush, state) do
    {frames, state} = flush(state)
    {shell_frames, state} = flush_shell(state)
    {:push, frames ++ shell_frames, %{state | flush_scheduled: false}}
  end

  # A stream's server stopped, and its subscribers with it. What it sent first is
  # already here and goes out, then the client follows the stream again from what
  # it holds: a `resync` without an offset keeps its own. An MC that left the
  # cluster is not asked again until the client sees it back.
  def handle_info({:DOWN, ref, :process, _server, reason}, %{monitors: monitors} = state)
      when is_map_key(monitors, ref) do
    {id, _server} = monitors[ref]
    {frames, state} = flush(state)
    state = forget_stream(%{state | monitors: Map.delete(monitors, ref)}, id)

    frame =
      if reason == :noconnection,
        do: error_frame(id, "MC unavailable: noconnection"),
        else: %{"t" => "resync", "id" => id}

    {:push, frames ++ [Protocol.encode(frame)], state}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    state = migrate(state)
    for {id, _} <- state.subs, do: unsubscribe(state, id)
    :ok
  end

  # Runs a client RPC on the MC that owns the environment, off this process so a
  # slow command never holds up streaming.
  # Each method needs the scope the contract declares for it (`HalC2.Rpc.required_scope/1`).
  defp rpc(state, id, environment, method, payload) do
    scope = HalC2.Rpc.required_scope(method)

    if allowed?(state, scope) do
      run_rpc(state, id, environment, method, payload)
    else
      error = %{
        "_tag" => "EnvironmentScopeRequiredError",
        "requiredScope" => scope,
        "message" => "#{scope} is required"
      }

      send(self(), {:rpc_reply, id, {:error, error}})
      state
    end
  end

  @session_methods HalC2.Rpc.session_methods()
  @session_elsewhere %{
    "_tag" => "EnvironmentOperationForbiddenError",
    "code" => "operation_forbidden",
    "reason" => "session_on_another_mc",
    "message" => "paired clients are managed on the MC the caller's session belongs to"
  }

  defp run_rpc(state, id, environment, method, payload) do
    socket = self()
    timeout = rpc_timeout()

    Task.start(fn ->
      reply =
        case HalC2.Shell.mc_for(environment) do
          nil -> {:error, "unknown environment"}
          mc -> call_mc(state, socket, mc, method, payload, timeout)
        end

      send(socket, {:rpc_reply, id, reply})
    end)

    state
  end

  # Activity leases belong to this socket and its session.
  defp call_mc(state, socket, mc, "server.reportClientActivity", payload, _timeout) do
    args = [state.session, socket, payload || %{}]
    :erpc.cast(mc, HalC2.BackgroundPolicy, :report_client_activity, args)
    {:ok, nil}
  end

  # The paired-clients methods answer for this socket's session, which only this MC
  # knows: on another member every session would be "other".
  defp call_mc(_state, _socket, mc, method, _payload, _timeout)
       when mc != node() and method in @session_methods,
       do: {:error, @session_elsewhere}

  defp call_mc(state, _socket, mc, method, payload, timeout) do
    args =
      if method in @session_methods,
        do: [method, payload || %{}, state.session],
        else: [method, payload || %{}]

    try do
      # Each call runs in its own task; some (a provider update, a scheduled task run)
      # take minutes.
      :erpc.call(mc, HalC2.Rpc, :handle, args, timeout)
    catch
      :error, {:erpc, :timeout} ->
        {:error, "#{method} timed out"}

      :error, {:erpc, reason} ->
        {:error, "MC unavailable: #{reason}"}

      kind, reason ->
        # The client is told, and so is the log: a failure only a client saw is lost.
        message = Exception.format(kind, reason)
        Logger.error("#{method} failed: #{message}")
        {:error, message}
    end
  end

  # --- subscriptions -------------------------------------------------------------

  defp subscribe(state, id, :shell, %{have: have}) do
    %{mcs: mcs, rows: rows} = HalC2.Shell.subscribe(self(), have)

    frame = %{
      "t" => "shell",
      "id" => id,
      "mcs" =>
        for mc <- mcs do
          %{
            "mc" => Atom.to_string(mc.mc),
            "online" => mc.online,
            "environment" => mc.environment,
            "epoch" => mc.epoch,
            "rev" => mc.rev,
            "reset" => mc.reset
          }
        end,
      "rows" => for({mc, stream, kind, row} <- rows, do: [Atom.to_string(mc), stream, kind, row])
    }

    # The snapshot has every row buffered so far.
    {:push, Protocol.encode(frame), %{put_in(state.subs[id], :shell) | shell: %{}}}
  end

  defp subscribe(state, id, {:config, mc}, offset),
    do: subscribe(state, id, {:config, mc, nil}, offset)

  # The MC's config, then its settings as they change. A client that answers
  # `/usage-limits` itself (`:usage_limits_command`) gets providers that offer it.
  defp subscribe(state, id, {:config, mc, command}, _offset) do
    shape = {:config, mc}
    ref = make_ref()

    with {:ok, :ok} <- remote(mc, HalC2.Settings, :watch, [self(), ref]),
         {:ok, config} <- remote(mc, HalC2.Environment, :server_config, []) do
      # Published themes follow the snapshot.
      themes =
        case remote(mc, HalC2.EnvironmentThemes, :current, []) do
          {:ok, themes} when is_list(themes) -> themes
          _ -> []
        end

      themes_frame = %{"t" => "config.themes", "id" => id, "themes" => themes}

      # So do usage-limit source snapshots.
      sources =
        case remote(mc, HalC2.UsageLimitSources, :current, []) do
          {:ok, sources} when is_list(sources) -> sources
          _ -> []
        end

      sources_frame = %{"t" => "config.usageLimitSources", "id" => id, "sources" => sources}

      state =
        %{
          state
          | subs: Map.put(state.subs, id, shape),
            # One MC's config may be watched by several subscriptions (config, lifecycle).
            by_terminal:
              state.by_terminal
              |> Map.update({:settings, mc}, %{id => ref}, &Map.put(&1, id, ref))
              |> Map.put({:usage_limit_sources, mc}, sources)
        }

      state = if command, do: update_commands(state, &MapSet.put(&1, id)), else: state

      config = Map.update(config, "providers", [], &providers_for(state, mc, id, &1))
      frame = %{"t" => "config", "id" => id, "mc" => Atom.to_string(mc), "config" => config}

      # How the MC's last update went, so a client reconnecting after one can tell.
      frame =
        case remote(mc, HalC2.Upgrade, :outcome, []) do
          {:ok, %{} = outcome} -> Map.put(frame, "updateOutcome", outcome)
          _ -> frame
        end

      {:push,
       [Protocol.encode(frame), Protocol.encode(themes_frame), Protocol.encode(sources_frame)],
       state}
    else
      {_, reason} ->
        :erpc.cast(mc, HalC2.Settings, :unwatch, [self(), ref])
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:stream, mc, stream_id} = shape, resume) do
    if Map.has_key?(state.by_stream, stream_id) do
      {:push, Protocol.encode(error_frame(id, "already subscribed")), state}
    else
      # Names the MC too, for ending the subscription if this follow gives up.
      tag = {mc, make_ref()}
      client = resume |> Map.take([:handle, :window, :kinds]) |> Map.put(:tag, tag)

      # The owning MC may be gone or slow; the client retries when it is back.
      case follow(mc, stream_id, resume.offset, client) do
        {:ok, server, ref} ->
          monitors = Map.put(state.monitors, ref, {id, server})

          # Until `live`, events are the stream's replay from `offset`: bounded by the
          # stream, and resyncing on them would only ask for the same replay again.
          {:ok,
           %{
             state
             | subs: Map.put(state.subs, id, shape),
               by_stream: Map.put(state.by_stream, stream_id, {id, tag}),
               monitors: monitors,
               buffers: Map.put(state.buffers, id, %{events: [], bytes: 0, replay: true})
           }}

        {:error, reason} ->
          # A call that gave up may still be taken, and would feed a socket that is
          # not following the stream.
          :erpc.cast(mc, HalC2.Streams, :unsubscribe, [stream_id, self(), tag])
          {:push, Protocol.encode(error_frame(id, reason)), state}
      end
    end
  end

  # A shape named by environment: its MC form on this MC or the cluster member that
  # serves it.
  defp subscribe(state, id, {:environment, environment_id, shape}, offset) do
    case HalC2.Shell.mc_for(environment_id) do
      nil ->
        {:push, Protocol.encode(error_frame(id, "unknown environment")), state}

      mc ->
        {:ok, local} = Protocol.at_mc(shape, mc)
        subscribe(state, id, local, offset)
    end
  end

  # A terminal lives on the MC that owns its thread; its events come straight here.
  defp subscribe(state, id, {:terminal, mc, input}, _offset) do
    key = {input["threadId"], input["terminalId"]}

    case remote(mc, HalC2.Terminal, :attach, [input, self()]) do
      {:ok, {:ok, snapshot}} ->
        frame = %{"type" => "snapshot", "snapshot" => snapshot}

        {:push, Protocol.encode(%{"t" => "terminal", "id" => id, "event" => frame}),
         %{
           state
           | subs: Map.put(state.subs, id, {:terminal, mc, key}),
             by_terminal: Map.put(state.by_terminal, key, id)
         }}

      {:ok, {:error, %{} = error}} ->
        {:push, Protocol.encode(error_frame(id, error)), state}

      {_, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:preview_automation, mc, host}, _offset) do
    key = {:preview_automation, mc, host["clientId"]}

    case remote(mc, HalC2.PreviewAutomation, :connect, [host, self()]) do
      {:ok, {:ok, _connection_id}} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, key),
             by_terminal: Map.put(state.by_terminal, key, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # Runs on the checkout's MC; its events come straight here.
  defp subscribe(state, id, {:server_update, mc, input} = shape, _) do
    case remote(mc, HalC2.Upgrade, :start, [input, self()]) do
      {:ok, :ok} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:server_update, mc}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # Installing software on the host is for sessions that may change its relay setup.
  defp subscribe(state, id, {:relay_client_install, mc} = shape, _) do
    allowed =
      state.session == nil or
        Enum.any?(
          HalC2.Auth.clients(),
          &(&1["sessionId"] == state.session and "relay:write" in &1["scopes"])
        )

    case allowed && remote(mc, HalC2.Connect.RelayClient, :start_install, [self()]) do
      false ->
        {:push, Protocol.encode(error_frame(id, "relay:write is required")), state}

      {:ok, :ok} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:relay_client_install, mc}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:git_action, mc, %{"actionId" => action_id} = input} = shape, _) do
    case remote(mc, HalC2.GitActions, :start, [input, self()]) do
      {:ok, :ok} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:git_action, action_id}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # A shape watching a service (`watch_spec/1`): what the service answered, then its
  # changes. The subscription's own ref keeps an unsubscribe cast landing after a later
  # subscribe from dropping that one, and the changes sent before it from following
  # its snapshot.
  defp subscribe(state, id, shape, _offset) do
    {key, mc, module, sub, unsub, args} = watch_spec(shape)
    ref = make_ref()

    case remote(mc, module, sub, args ++ [ref]) do
      {:ok, reply} ->
        case snapshot(shape, reply) do
          {:error, detail} ->
            {:push, Protocol.encode(error_frame(id, detail)), state}

          message ->
            state = %{
              state
              | subs: Map.put(state.subs, id, shape),
                by_terminal:
                  Map.update(state.by_terminal, key, %{id => ref}, &Map.put(&1, id, ref))
            }

            if message, do: watched(state, message, [ref]), else: {:ok, state}
        end

      {:error, reason} ->
        # A call that gave up may still be taken.
        :erpc.cast(mc, module, unsub, args ++ [ref])
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # A stream that took the follow lets it go if the MCs part, and they may meet again
  # before the answer is read and the stream monitored: a follow they parted during
  # fails, as one they parted before the answer does.
  defp follow(mc, stream_id, offset, client) do
    watch? = mc != node() and Node.alive?()
    if watch?, do: Node.monitor(mc, true)

    result =
      case remote(mc, HalC2.Streams, :follow, [stream_id, self(), offset, client]) do
        {:ok, {:ok, server}} -> {:ok, server, Process.monitor(server)}
        {:error, reason} -> {:error, reason}
      end

    if watch?, do: Node.monitor(mc, false)

    receive do
      {:nodedown, ^mc} ->
        with {:ok, _server, ref} <- result, do: Process.demonitor(ref, [:flush])
        {:error, "MC unavailable: noconnection"}
    after
      0 -> result
    end
  end

  # Calls an MC without ever taking this socket down: an unreachable MC, or one
  # without the feature (an older version), fails only the one subscription.
  # Connected MCs plus members the shell has seen that are offline now, so a
  # subscription to an MC that went away fails as unavailable, not unknown.
  defp known_mcs do
    shell = if Process.whereis(HalC2.Shell), do: HalC2.Shell.environments(), else: []
    Enum.uniq([node() | Node.list()] ++ Enum.map(shell, &elem(&1, 0)))
  end

  defp remote(mc, module, fun, args) do
    {:ok, :erpc.call(mc, module, fun, args, 15_000)}
  catch
    :error, {:erpc, reason} ->
      {:error, "MC unavailable: #{reason}"}

    kind, reason ->
      {:error, "#{mc} cannot serve this: #{Exception.format_banner(kind, reason)}"}
  end

  # Marks this socket's own session in an access event.
  defp own(%{"type" => "snapshot", "payload" => payload} = event, state),
    do:
      put_in(
        event,
        ["payload", "clientSessions"],
        Enum.map(payload["clientSessions"], &mark(&1, state))
      )

  defp own(%{"type" => "clientUpserted", "payload" => client} = event, state),
    do: %{event | "payload" => mark(client, state)}

  defp own(event, _state), do: event

  defp mark(client, state), do: %{client | "current" => client["sessionId"] == state.session}

  # Version 1: an MC's config may be watched by several subscriptions.
  defp migrate(state) when not is_map_key(state, :v) do
    by_terminal =
      Map.new(state.by_terminal, fn
        {{:settings, _mc} = key, id} when is_integer(id) -> {key, [id]}
        entry -> entry
      end)

    %{state | by_terminal: by_terminal} |> Map.put(:v, 1) |> migrate()
  end

  # Version 2: the session's scopes, checked on every call and subscription.
  defp migrate(%{v: 1} = state),
    do: state |> Map.put(:scopes, session_scopes(state.session)) |> Map.put(:v, 2) |> migrate()

  # Version 3: streams send what the client holds already trimmed, with the offset
  # each batch of events brings it to.
  defp migrate(%{v: 2} = state) do
    buffers =
      Map.new(state.buffers, fn
        {id, %{events: [last | _]} = buffer} -> {id, Map.put(buffer, :seq, last.seq)}
        entry -> entry
      end)

    state |> Map.delete(:item_types) |> Map.merge(%{buffers: buffers, v: 3}) |> migrate()
  end

  # Version 4: stream servers are monitored. Those followed before are not.
  defp migrate(%{v: 3} = state), do: state |> Map.merge(%{monitors: %{}, v: 4}) |> migrate()

  # Version 5: sidebar rows are buffered per MC, like stream events.
  defp migrate(%{v: 4} = state), do: state |> Map.merge(%{shell: %{}, v: 5}) |> migrate()

  # Version 6: a stream subscription's messages carry its tag. Those followed before
  # carry none.
  defp migrate(%{v: 5} = state) do
    by_stream = Map.new(state.by_stream, fn {stream_id, id} -> {stream_id, {id, nil}} end)
    migrate(%{state | by_stream: by_stream, v: 6})
  end

  # Version 7: subscriptions watching a service each hold a ref of their own, several to
  # a key (`watch_spec/1`). Those made before hold none; Slack's already did.
  defp migrate(%{v: 6} = state) do
    watched =
      for {id, shape} <- state.subs,
          {key, _, _, _, _, _} <- [watch_spec(shape)],
          not match?({:slack, _}, key),
          do: {key, id}

    by_terminal =
      Enum.reduce(
        watched,
        Map.drop(state.by_terminal, Enum.map(watched, &elem(&1, 0))),
        fn {key, id}, by_terminal ->
          Map.update(by_terminal, key, %{id => nil}, &Map.put(&1, id, nil))
        end
      )

    %{state | by_terminal: by_terminal, v: 7}
  end

  defp migrate(state), do: state

  defp session_scopes(nil), do: :all

  defp session_scopes(session) do
    case HalC2.Auth.session_scopes(session) do
      {:ok, scopes} -> scopes
      :error -> []
    end
  end

  defp allowed?(%{scopes: :all}, _scope), do: true
  defp allowed?(%{scopes: scopes}, scope), do: scope in scopes

  # The scope each shape needs.
  defp shape_scope({:terminal, _, _}), do: "terminal:operate"
  defp shape_scope({:terminals, _}), do: "terminal:operate"
  # By environment, as its MC form needs, wherever it is served.
  defp shape_scope({:environment, _, shape}) do
    {:ok, local} = Protocol.at_mc(shape, node())
    shape_scope(local)
  end

  defp shape_scope(:auth_access), do: "access:read"

  defp shape_scope({kind, _, _}) when kind in [:server_update, :git_action, :preview_automation],
    do: "orchestration:operate"

  defp shape_scope(_shape), do: "orchestration:read"

  # The subscriptions watching `mc`'s config under one of `refs`.
  defp config_ids(state, mc, refs),
    do: for({id, ref} <- Map.get(state.by_terminal, {:settings, mc}, %{}), ref in refs, do: id)

  # A frame for each of them, built by `frame.(id)`.
  defp config_push(state, mc, refs, frame) do
    case config_ids(state, mc, refs) do
      [] -> {:ok, state}
      ids -> {:push, Enum.map(ids, &Protocol.encode(frame.(&1))), state}
    end
  end

  # `config.providers` for the subscriptions `ids` watching `mc`.
  defp push_providers(state, _mc, []), do: {:ok, state}

  defp push_providers(state, mc, ids) do
    case remote(mc, HalC2.Environment, :providers, []) do
      {:ok, providers} ->
        frames =
          for id <- ids do
            Protocol.encode(%{
              "t" => "config.providers",
              "id" => id,
              "providers" => providers_for(state, mc, id, providers)
            })
          end

        {:push, frames, state}

      _ ->
        {:ok, state}
    end
  end

  # The subscriptions of clients that answer `/usage-limits` themselves.
  defp command?(state, id), do: id in Map.get(state.by_terminal, :usage_limits_command, [])

  defp update_commands(state, fun) do
    commands = fun.(Map.get(state.by_terminal, :usage_limits_command, MapSet.new()))
    %{state | by_terminal: Map.put(state.by_terminal, :usage_limits_command, commands)}
  end

  defp providers_for(state, mc, id, providers) do
    if command?(state, id) do
      sources = Map.get(state.by_terminal, {:usage_limit_sources, mc}, [])
      HalC2.ProviderUsageLimits.with_command(providers, sources)
    else
      providers
    end
  end

  # Keeps `mc`'s latest usage-limit sources for the `/usage-limits` providers, and
  # has those re-sent when the drivers the sources cover change.
  defp remember_sources(state, mc, refs, sources) do
    case config_ids(state, mc, refs) do
      [] ->
        state

      ids ->
        key = {:usage_limit_sources, mc}
        before = HalC2.ProviderUsageLimits.command_coverage(Map.get(state.by_terminal, key, []))

        if Enum.any?(ids, &command?(state, &1)) and
             before != HalC2.ProviderUsageLimits.command_coverage(sources),
           do: send(self(), {:hal_c2_watched, refs, {:hal_c2_usage_limits_command, mc}})

        %{state | by_terminal: Map.put(state.by_terminal, key, sources)}
    end
  end

  # A contract error's fields go in `detail`, as rpc.error carries them.
  defp error_frame(id, %{} = error),
    do: id |> error_frame(error["message"]) |> Map.put("detail", Map.delete(error, "message"))

  defp error_frame(id, reason), do: %{"t" => "error", "id" => id, "reason" => to_string(reason)}

  defp unsubscribe(state, id) do
    case Map.pop(state.subs, id) do
      {{:terminal, mc, {thread_id, terminal_id} = key}, subs} ->
        :erpc.cast(mc, HalC2.Terminal, :detach, [thread_id, terminal_id, self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, key)}

      {{:server_update, mc, _input}, subs} ->
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:server_update, mc})}

      {{:relay_client_install, mc}, subs} ->
        %{
          state
          | subs: subs,
            by_terminal: Map.delete(state.by_terminal, {:relay_client_install, mc})
        }

      {{:git_action, _mc, %{"actionId" => action_id}}, subs} ->
        %{
          state
          | subs: subs,
            by_terminal: Map.delete(state.by_terminal, {:git_action, action_id})
        }

      {{:config, mc} = shape, subs} ->
        state = update_commands(%{state | subs: subs}, &MapSet.delete(&1, id))
        state = unwatch(state, id, shape)

        if Map.has_key?(state.by_terminal, {:settings, mc}),
          do: state,
          else: %{state | by_terminal: Map.delete(state.by_terminal, {:usage_limit_sources, mc})}

      {{:preview_automation, mc, client_id} = key, subs} ->
        :erpc.cast(mc, HalC2.PreviewAutomation, :disconnect, [client_id, self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, key)}

      {{:stream, mc, stream_id}, _subs} ->
        # By its tag, so it ends no subscription that follows, whenever it arrives.
        case Enum.find(state.monitors, fn {_ref, {sub, _server}} -> sub == id end) do
          {ref, {_, server}} ->
            Process.demonitor(ref, [:flush])
            {_id, tag} = state.by_stream[stream_id]

            message =
              if tag, do: {:unsubscribe, self(), tag}, else: {:unsubscribe, self()}

            GenServer.cast(server, message)
            forget_stream(%{state | monitors: Map.delete(state.monitors, ref)}, id)

          # Followed before stream servers were monitored.
          nil ->
            :erpc.cast(mc, HalC2.Streams, :unsubscribe, [stream_id, self()])
            forget_stream(state, id)
        end

      {:shell, subs} ->
        %{state | subs: subs, shell: %{}}

      {nil, _subs} ->
        state

      {shape, subs} ->
        unwatch(%{state | subs: subs}, id, shape)
    end
  end

  # Lets go of subscription `id`'s ref on the service it watches; the service keeps
  # this socket's others.
  defp unwatch(state, id, shape) do
    {key, mc, module, _sub, unsub, args} = watch_spec(shape)
    {ref, ids} = Map.pop(Map.get(state.by_terminal, key, %{}), id)
    :erpc.cast(mc, module, unsub, args ++ [ref])

    by_terminal =
      if ids == %{},
        do: Map.delete(state.by_terminal, key),
        else: Map.put(state.by_terminal, key, ids)

    %{state | by_terminal: by_terminal}
  end

  # --- watched services -------------------------------------------------------------

  # How a shape watching a service is followed: `{key, mc, module, subscribe,
  # unsubscribe, args}`, both called with `args ++ [ref]` (`HalC2.Watchers`). This
  # socket's subscriptions watching one service share `key` in `by_terminal`, as
  # `%{id => ref}`. Nil for any other shape.
  defp watch_spec({:config, mc}),
    do: {{:settings, mc}, mc, HalC2.Settings, :watch, :unwatch, [self()]}

  defp watch_spec({:terminals, mc} = shape),
    do: {shape, mc, HalC2.Terminal.Hub, :watch, :unwatch, [self()]}

  defp watch_spec({:vcs, mc, cwd}),
    do: {{:vcs, cwd}, mc, HalC2.Vcs.Watch, :subscribe, :unsubscribe, [cwd, self()]}

  # Only an administrative session (or the MC's own token) sees who is paired;
  # `shape_scope/1` asks for access:read.
  defp watch_spec(:auth_access),
    do: {:auth_access, node(), HalC2.Auth, :subscribe, :unsubscribe, [self()]}

  defp watch_spec({:plugin_topic, mc, plugin, topic} = shape),
    do: {shape, mc, HalC2.Plugins, :subscribe_topic, :unsubscribe_topic, [self(), plugin, topic]}

  defp watch_spec({:worktree_setup, mc, thread_id}),
    do:
      {{:worktree_setup, thread_id}, mc, HalC2.WorktreeSetup, :subscribe, :unsubscribe,
       [thread_id, self()]}

  defp watch_spec({:provider_auth, mc, instance}),
    do:
      {{:provider_auth, instance}, mc, HalC2.ProviderAuth, :subscribe, :unsubscribe,
       [instance, self()]}

  defp watch_spec({:provider_install, mc, instance}),
    do:
      {{:provider_install, instance}, mc, HalC2.Acp.Antigravity.Installation, :subscribe,
       :unsubscribe, [instance, self()]}

  defp watch_spec({kind, mc} = shape) when is_map_key(@services, kind),
    do: {shape, mc, Map.fetch!(@services, kind), :subscribe, :unsubscribe, [self()]}

  defp watch_spec(_shape), do: nil

  # What a service answered a subscribe with, as the message it sends of a change (nil
  # for none), or the error it refused with.
  defp snapshot({:terminals, mc}, terminals),
    do: {:hal_c2_terminals, mc, %{"type" => "snapshot", "terminals" => terminals}}

  defp snapshot({:vcs, _mc, cwd}, event), do: {:hal_c2_vcs, cwd, event}

  defp snapshot(:auth_access, {:ok, revision, payload}) do
    event = %{"version" => 1, "revision" => revision, "type" => "snapshot", "payload" => payload}
    {:hal_c2_auth_access, event}
  end

  defp snapshot({:preview, _mc}, :ok), do: nil
  defp snapshot({:plugins, mc}, plugins), do: {:hal_c2_plugins, mc, plugins}

  defp snapshot({:plugin_topic, mc, plugin, topic}, {:ok, value}),
    do: {:hal_c2_plugin_topic, mc, plugin, topic, value}

  defp snapshot({:worktree_setup, _mc, thread_id}, setup),
    do: {:hal_c2_worktree_setup, thread_id, setup}

  defp snapshot({:provider_auth, _mc, instance}, {:ok, auth}),
    do: {:hal_c2_provider_auth, instance, auth}

  defp snapshot({:provider_install, _mc, instance}, {:ok, install}),
    do: {:hal_c2_provider_install, instance, install}

  defp snapshot({kind, _mc, _instance}, {:error, %{} = detail})
       when kind in [:provider_auth, :provider_install],
       do: {:error, detail}

  defp snapshot({:resource_telemetry, mc}, {:ok, value}),
    do: {:hal_c2_resource_telemetry, mc, value}

  defp snapshot({:local_servers, mc}, {:ok, value}), do: {:hal_c2_local_servers, mc, value}
  defp snapshot({:devices, mc}, {:ok, value}), do: {:hal_c2_devices, mc, value}
  defp snapshot({:slack, mc}, {:ok, value}), do: {:hal_c2_slack, mc, value}
  defp snapshot({:project_clones, mc}, {:ok, value}), do: {:hal_c2_project_clones, mc, value}
  defp snapshot({:scheduled_tasks, mc}, {:ok, value}), do: {:hal_c2_scheduled_tasks, mc, value}

  defp snapshot({:background_policy, mc}, {:ok, value}),
    do: {:hal_c2_background_policy, mc, value}

  defp snapshot({:pull_request_refreshes, mc}, {:ok, value}),
    do: {:hal_c2_pull_request_refreshes, mc, value}

  # A watched service's message, for this socket's subscriptions under `refs`.
  defp watched(state, {:hal_c2_settings, mc, settings}, refs) do
    # Settings can add, remove, or enable providers.
    if config_ids(state, mc, refs) != [],
      do: send(self(), {:hal_c2_watched, refs, {:hal_c2_providers_changed, mc}})

    config_push(state, mc, refs, &%{"t" => "config.settings", "id" => &1, "settings" => settings})
  end

  defp watched(state, {:hal_c2_themes, mc, themes}, refs),
    do: config_push(state, mc, refs, &%{"t" => "config.themes", "id" => &1, "themes" => themes})

  defp watched(state, {:hal_c2_usage_limit_sources, mc, sources}, refs) do
    state = remember_sources(state, mc, refs, sources)
    frame = &%{"t" => "config.usageLimitSources", "id" => &1, "sources" => sources}
    config_push(state, mc, refs, frame)
  end

  defp watched(state, {:hal_c2_keybindings, mc, rules}, refs),
    do:
      config_push(state, mc, refs, &%{"t" => "config.keybindings", "id" => &1, "rules" => rules})

  defp watched(state, {:hal_c2_providers_changed, mc}, refs),
    do: push_providers(state, mc, config_ids(state, mc, refs))

  # The hubs now cover other drivers: only `/usage-limits` clients see a change.
  defp watched(state, {:hal_c2_usage_limits_command, mc}, refs),
    do: push_providers(state, mc, Enum.filter(config_ids(state, mc, refs), &command?(state, &1)))

  # The MC moved to another version in place; clients watching it see its new
  # descriptor as a `ready`.
  defp watched(state, {:hal_c2_upgraded, mc, outcome}, refs) do
    with [_ | _] <- config_ids(state, mc, refs),
         {:ok, descriptor} <- remote(mc, HalC2.Environment, :descriptor, []) do
      config_push(state, mc, refs, fn id ->
        %{
          "t" => "config.ready",
          "id" => id,
          "environment" => descriptor,
          "updateOutcome" => outcome
        }
      end)
    else
      _ -> {:ok, state}
    end
  end

  defp watched(state, message, refs) do
    {key, type, fields} = watched_frame(message, state)

    case for({id, ref} <- Map.get(state.by_terminal, key, %{}), ref in refs, do: id) do
      [] ->
        {:ok, state}

      ids ->
        frames = for id <- ids, do: Protocol.encode(Map.merge(%{"t" => type, "id" => id}, fields))
        {:push, frames, state}
    end
  end

  # The key of the subscriptions a service's message is for, and their frame's type and
  # fields.
  defp watched_frame({:hal_c2_terminals, mc, event}, _state),
    do: {{:terminals, mc}, "terminals", %{"event" => event}}

  defp watched_frame({:hal_c2_vcs, cwd, event}, _state),
    do: {{:vcs, cwd}, "vcs", %{"event" => event}}

  defp watched_frame({:hal_c2_auth_access, event}, state),
    do: {:auth_access, "authAccess", %{"event" => own(event, state)}}

  defp watched_frame({:hal_c2_resource_telemetry, mc, snapshot}, _state),
    do: {{:resource_telemetry, mc}, "resourceTelemetry", %{"snapshot" => snapshot}}

  defp watched_frame({:hal_c2_preview, mc, event}, _state),
    do: {{:preview, mc}, "preview", %{"event" => event}}

  defp watched_frame({:hal_c2_local_servers, mc, list}, _state),
    do: {{:local_servers, mc}, "localServers", %{"list" => list}}

  defp watched_frame({:hal_c2_devices, mc, devices}, _state),
    do: {{:devices, mc}, "devices", %{"state" => devices}}

  defp watched_frame({:hal_c2_slack, mc, status}, _state),
    do: {{:slack, mc}, "slack", %{"status" => status}}

  defp watched_frame({:hal_c2_project_clones, mc, clones}, _state),
    do: {{:project_clones, mc}, "projectClones", %{"clones" => clones}}

  defp watched_frame({:hal_c2_scheduled_tasks, mc, tasks}, _state),
    do: {{:scheduled_tasks, mc}, "scheduledTasks", %{"tasks" => tasks}}

  defp watched_frame({:hal_c2_background_policy, mc, policy}, _state),
    do: {{:background_policy, mc}, "backgroundPolicy", %{"policy" => policy}}

  defp watched_frame({:hal_c2_pull_request_refreshes, mc, revision}, _state),
    do: {{:pull_request_refreshes, mc}, "pullRequestRefreshes", %{"revision" => revision}}

  defp watched_frame({:hal_c2_plugins, mc, plugins}, _state),
    do: {{:plugins, mc}, "plugins", %{"plugins" => plugins}}

  defp watched_frame({:hal_c2_plugin_topic, mc, plugin, topic, value}, _state),
    do: {{:plugin_topic, mc, plugin, topic}, "plugin", %{"topic" => topic, "value" => value}}

  defp watched_frame({:hal_c2_worktree_setup, thread_id, setup}, _state),
    do: {{:worktree_setup, thread_id}, "worktreeSetup", %{"event" => setup}}

  defp watched_frame({:hal_c2_provider_install, instance, install}, _state),
    do: {{:provider_install, instance}, "providerInstall", %{"state" => install}}

  defp watched_frame({:hal_c2_provider_auth, instance, auth}, _state),
    do: {{:provider_auth, instance}, "providerAuth", %{"state" => auth}}

  # Drops a stream subscription here, telling its stream nothing.
  defp forget_stream(state, id) do
    {{:stream, _mc, stream_id}, subs} = Map.pop(state.subs, id)

    %{
      state
      | subs: subs,
        by_stream: Map.delete(state.by_stream, stream_id),
        buffers: Map.delete(state.buffers, id)
    }
  end

  # The stream ended the subscription: its relay failed. What came first goes out,
  # then the client follows the stream again from what it holds.
  defp stream_message(state, id, :resync) do
    {frames, state} = flush(state)

    state =
      case Enum.find(state.monitors, fn {_ref, {sub, _server}} -> sub == id end) do
        {ref, _} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: Map.delete(state.monitors, ref)}

        nil ->
          state
      end

    resync = Protocol.encode(%{"t" => "resync", "id" => id})
    {:push, frames ++ [resync], forget_stream(state, id)}
  end

  defp stream_message(state, id, {:snapshot, seq, updated_at, rows, part_state, meta}) do
    part = get_in(state.buffers, [id, :snapshot_part]) || 0

    frame =
      %{
        "t" => "snapshot",
        "id" => id,
        "offset" => seq,
        "at" => updated_at,
        "part" => part,
        "done" => part_state == :done,
        "handle" => meta.handle,
        "rows" => for({kind, eid, entity} <- rows, do: [kind, eid, entity])
      }
      |> put_floor(meta)

    buffers =
      if part_state == :done,
        do: Map.delete(state.buffers, id),
        else: Map.put(state.buffers, id, %{events: [], bytes: 0, snapshot_part: part + 1})

    {:push, Protocol.encode(frame), %{state | buffers: buffers}}
  end

  # Replayed events may still be buffered; they go out before the live marker.
  defp stream_message(state, id, {:live, seq, handle}) do
    {frames, state} = flush(state)

    state =
      case state.buffers do
        %{^id => buffer} ->
          %{state | buffers: Map.put(state.buffers, id, Map.delete(buffer, :replay))}

        _ ->
          state
      end

    live = %{"t" => "live", "id" => id, "offset" => seq, "handle" => handle}
    {:push, frames ++ [Protocol.encode(live)], state}
  end

  # A page is the stream as of `seq`, so the events before it go out first.
  defp stream_message(state, id, {:page, seq, rows, floor, part_state}) do
    {frames, state} = flush(state)

    page = %{
      "t" => "page",
      "id" => id,
      "offset" => seq,
      "floor" => floor,
      "done" => part_state == :done,
      "rows" => for({kind, eid, entity} <- rows, do: [kind, eid, entity])
    }

    {:push, frames ++ [Protocol.encode(page)], state}
  end

  defp stream_message(state, id, {:events, events, seq}) do
    buffer = Map.get(state.buffers, id, %{events: [], bytes: 0})
    bytes = buffer.bytes + Enum.reduce(events, 0, &(:erlang.external_size(&1.patch) + &2))

    cond do
      # A part of what the client lacks goes out as it comes, as a snapshot's parts
      # do. Buffered, the parts of a thread on this MC would all be here before the
      # first flush and leave as one frame of any size.
      Map.get(buffer, :replay, false) ->
        {:push, events_frame(id, events, seq), state}

      bytes > @max_buffered ->
        # The client has everything before the oldest event it has not been sent.
        oldest = List.last(buffer.events) || hd(events)
        state = unsubscribe(state, id)
        resync = %{"t" => "resync", "id" => id, "offset" => oldest.seq - 1}
        {:push, Protocol.encode(resync), state}

      true ->
        buffer =
          Map.merge(buffer, %{events: Enum.reverse(events, buffer.events), bytes: bytes, seq: seq})

        state = %{state | buffers: Map.put(state.buffers, id, buffer)}
        {:ok, schedule_flush(state)}
    end
  end

  # The offset is the one the stream gave with the last of the events: a replay in
  # several parts only moves the client's offset with its last.
  defp events_frame(id, events, seq) do
    wire = for e <- Protocol.coalesce(events), do: [e.seq, e.kind, e.entity, e.patch, e.at]
    Protocol.encode(%{"t" => "events", "id" => id, "offset" => seq, "events" => wire})
  end

  defp put_floor(frame, %{floor: floor}), do: Map.put(frame, "floor", floor)
  defp put_floor(frame, _meta), do: frame

  defp flush(state) do
    frames =
      for {id, %{events: [_ | _] = events, seq: seq}} <- state.buffers,
          do: events_frame(id, Enum.reverse(events), seq)

    buffers =
      Map.new(state.buffers, fn {id, buffer} -> {id, %{buffer | events: [], bytes: 0}} end)

    {frames, %{state | buffers: buffers}}
  end

  # The flush message lands behind everything already in the mailbox, so each
  # flush drains a whole burst.
  defp schedule_flush(%{flush_scheduled: true} = state), do: state

  defp schedule_flush(state) do
    send(self(), :flush)
    %{state | flush_scheduled: true}
  end

  # A later row of a stream replaces an earlier one, so the frame carries the same
  # changes as the messages did. After a `reset` the MC's earlier rows are gone,
  # buffered or held; rows merged on top of it keep the frame a reset.
  defp buffer_shell_rows(state, mc, rows, %{epoch: epoch, rev: rev, reset: reset?}) do
    buffer = Map.get(state.shell, mc, %{rows: %{}, reset: false})
    kept = if reset?, do: %{}, else: buffer.rows

    buffer = %{
      rows: Map.merge(kept, Map.new(rows)),
      epoch: epoch,
      rev: rev,
      reset: reset? or buffer.reset
    }

    put_in(state.shell[mc], buffer)
  end

  defp flush_shell(%{shell: shell} = state) when map_size(shell) == 0, do: {[], state}

  defp flush_shell(state) do
    frames =
      case shell_sub(state) do
        {id, _} ->
          for {mc, buffer} <- Enum.sort(state.shell),
              do: Protocol.encode(shell_message(id, {:rows, mc, Enum.sort(buffer.rows), buffer}))

        nil ->
          []
      end

    {frames, %{state | shell: %{}}}
  end

  # The socket's one shell subscription, as `{id, :shell}`.
  defp shell_sub(state), do: Enum.find(state.subs, fn {_, shape} -> shape == :shell end)

  # To a socket that subscribed before rows had versions.
  defp shell_message(id, {:rows, mc, rows}),
    do: %{
      "t" => "shell.rows",
      "id" => id,
      "mc" => to_string(mc),
      "rows" => for({sid, {kind, row}} <- rows, do: [sid, kind, row])
    }

  defp shell_message(id, {:rows, mc, rows, version}),
    do: %{
      "t" => "shell.rows",
      "id" => id,
      "mc" => to_string(mc),
      "epoch" => version.epoch,
      "rev" => version.rev,
      "reset" => version.reset,
      "rows" => for({sid, {kind, row}} <- rows, do: [sid, kind, row])
    }

  defp shell_message(id, {:environment, mc, descriptor}),
    do: %{
      "t" => "shell.environment",
      "id" => id,
      "mc" => to_string(mc),
      "environment" => descriptor
    }

  defp shell_message(id, {:mc, mc, :removed}),
    do: %{
      "t" => "shell.mc",
      "id" => id,
      "mc" => to_string(mc),
      "online" => false,
      "removed" => true
    }

  defp shell_message(id, {:mc, mc, status}),
    do: %{
      "t" => "shell.mc",
      "id" => id,
      "mc" => to_string(mc),
      "online" => status in [:up, true]
    }
end
