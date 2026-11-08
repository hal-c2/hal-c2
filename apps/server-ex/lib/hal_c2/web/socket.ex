defmodule HalC2.Web.Socket do
  @moduledoc """
  One client connection. See `HalC2.Web.Protocol` for the wire format.

  Stream subscriptions may live on any MC in the cluster; the owning MC's stream
  server sends straight to this process, already trimmed to what the client holds
  (`HalC2.Streams.Server`). Incoming events are buffered and flushed
  once the mailbox is drained, merged per entity, so a burst of streaming tokens
  becomes one frame. A subscription whose unsent buffer passes `@max_buffered`, or
  holds more than `@max_buffered_events` events, is dropped with a `resync`; the client resubscribes from its offset and the stream
  replays from the log instead of this process holding the backlog. That replay is
  never itself cut short by a resync, or a client behind by more than the limit would
  be told to resync forever.

  Progress of a running tool call (`HalC2.Streams.View.events/4` marks it) is held
  for 50 ms, or until `@max_held_progress` updates wait, so a tool that reports many
  times reaches the client as its latest state. Anything else for the subscription
  sends what is held first, at once.

  Sidebar rows are buffered the same way, per MC, and flushed as one `shell.rows` frame
  per MC. The other shell messages are not buffered, but the rows before them go out first.

  The socket monitors each stream's server. One that stops took the subscription
  with it, so the client is sent a `resync` and resubscribes from what it holds;
  one whose MC left the cluster is an `error`, and the client follows it again once
  that MC is back.

  Following a stream is the one subscribe whose cost grows with the data (a long
  thread resumed from an old offset), so it runs off this process (`following`):
  the socket keeps answering pings and other frames meanwhile, and what the stream
  sends before the follow is answered is held until it is.

  Each socket logs when it opens and closes, under the trace id of the client's
  attempt (its handshake's `traceparent`).
  """

  @behaviour WebSock

  alias HalC2.Terminal.OutputWindow
  alias HalC2.Web.Protocol

  require Logger

  @max_buffered 8 * 1024 * 1024
  @max_buffered_events 1_000
  @max_held_progress 512

  # Sockets are Bandit's processes, so a code upgrade in place (`HalC2.Upgrade`) runs no
  # `code_change/3` for them: each callback first brings an older state up to date.
  @state_version 11

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
              hal_c2_provider_auth hal_c2_vcs hal_c2_terminals hal_c2_space_presence)a

  @doc "How long a client RPC may run before it fails as timed out (`:rpc_timeout`)."
  def rpc_timeout, do: Application.get_env(:hal_c2, :rpc_timeout, :timer.minutes(10))

  # A manual scheduled run answers only when its run does — a wedged one at
  # its hour cap, with the timed-out task. That method gets the run cap plus
  # slack for the scheduler's own answer (its `run_now/1` call waits the cap
  # plus five seconds), so the client is told the outcome instead of a
  # generic RPC timeout ten minutes in.
  def rpc_timeout("scheduledTasks.runNow"),
    do: max(rpc_timeout(), HalC2.ScheduledTasks.run_timeout_ms() + 10_000)

  # A desktop app update has its own deadline (`HalC2.DesktopUpdate`); the MC's own
  # has one per stage (`HalC2.Upgrade`), so a long download that keeps going is
  # waited for.
  def rpc_timeout("server.updateServer") do
    case HalC2.DesktopUpdate.available?() && HalC2.DesktopUpdate.update_timeout() do
      false -> :infinity
      :infinity -> :infinity
      ms -> max(rpc_timeout(), ms + 10_000)
    end
  end

  def rpc_timeout(_method), do: rpc_timeout()

  @impl true
  def init(opts) do
    # A socket opened with a ticket belongs to that client's session.
    session = opts[:session]
    if session, do: HalC2.Auth.connected(session, opts[:client] || %{})
    trace = opts[:trace]
    if trace, do: Logger.metadata(trace_id: trace)

    Logger.info(
      "socket open (trace #{trace || "none"}, #{if session, do: "paired session", else: "MC token"})"
    )

    state = %{
      v: @state_version,
      session: session,
      trace: trace,
      opened_at: System.monotonic_time(:millisecond),
      # Stream follows still on their way (`subscribe/4`), by the follow's tag:
      # %{id, stream_id, mc, shape, held: [messages, newest first], more: items asked, parted: bool}.
      following: %{},
      # What the session may do; the MC's own token may do anything.
      scopes: session_scopes(session),
      subs: %{},
      # stream id => {the subscription's id, the tag its messages carry}
      by_stream: %{},
      # The monitor of each stream subscription's server => {its id, the server}.
      monitors: %{},
      by_terminal: %{},
      # The monitor of each followed terminal => {its MC, its key, its pid}.
      terminals: %{},
      # MC => the keys of its terminals lost with it, attached again when it is back.
      lost: %{},
      # The subscription of a terminal client that acknowledges => its output window.
      terminal_windows: %{},
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
        {:ok, more(state, id, items)}

      {:ok, {:ack, id, sequence}} ->
        terminal_ack(state, id, sequence)

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

      {_, _, _} when is_map_key(:erlang.map_get(:following, state), tag) ->
        {:ok, hold(state, tag, message)}

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

  # Every subscription of this socket to the terminal is told, under its own id,
  # what follows the snapshot it was sent: an event the snapshot already holds
  # (at or below its sequence, as the output the terminal flushed while this
  # socket waited on the attach) goes to that subscription nowhere. An error's
  # message is in no snapshot, so an error is always told.
  def handle_info({:hal_c2_terminal, key, event}, state), do: terminal_event(state, key, event)

  # An event the terminal emitted while this socket's attach for a new
  # subscription was in flight — the pending batch the attach flushed, or what
  # it started. The new subscription holds it in its snapshot; the ones this
  # socket already held do not, so it is fanned out as any terminal event is
  # and each subscription's floor decides.
  def handle_info({:hal_c2_terminal_attach, key, event}, state),
    do: terminal_event(state, key, event)

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

  def handle_info({:hal_c2_desktop_update_control, mc, message}, state) do
    case state.by_terminal do
      %{{:desktop_update_control, ^mc} => id} ->
        {:push, Protocol.encode(%{"t" => "desktopUpdateControl", "id" => id, "event" => message}),
         state}

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

  def handle_info({:hal_c2_followed, tag, result}, state), do: followed(state, tag, result)

  # The MCs parted while a follow to `mc` was out (`subscribe/4`).
  def handle_info({:nodedown, mc}, state), do: {:ok, parted(state, mc)}

  def handle_info(:flush, state) do
    {frames, state} = flush(state, false)
    {shell_frames, state} = flush_shell(state)
    {:push, frames ++ shell_frames, %{state | flush_scheduled: false}}
  end

  # A subscription's held progress has waited long enough. A hold sent early leaves
  # its timer stale.
  def handle_info({:release_progress, id, hold}, state) do
    case state.buffers do
      %{^id => %{hold: ^hold} = buffer} ->
        {frames, buffer} = release(id, buffer)
        {:push, frames, %{state | buffers: Map.put(state.buffers, id, buffer)}}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:hal_c2_terminal_down, mc, key, reason}, state),
    do: terminal_down(state, mc, key, reason)

  # An MC whose terminals were lost with it is back: they are attached again.
  def handle_info({:nodeup, mc, _info}, state) do
    case Map.pop(state.lost, mc) do
      {nil, _} ->
        {:ok, state}

      {keys, lost} ->
        # The last lost MC is back: no more cluster news is wanted.
        if lost == %{}, do: :ok = :net_kernel.monitor_nodes(false, node_type: :all)

        {frames, state} =
          Enum.flat_map_reduce(keys, %{state | lost: lost}, &resync_terminal(&2, &1))

        if frames == [], do: {:ok, state}, else: {:push, frames, state}
    end
  end

  # A stream's server stopped, and its subscribers with it. What it sent first is
  # already here and goes out, then the client follows the stream again from what
  # it holds: a `resync` without an offset keeps its own. An MC that left the
  # cluster is not asked again until the client sees it back. A followed terminal
  # that stopped is `terminal_down/4`'s.
  def handle_info({:DOWN, ref, :process, _server, reason}, %{terminals: terminals} = state)
      when is_map_key(terminals, ref) do
    {{mc, key, _pid}, terminals} = Map.pop(terminals, ref)
    terminal_down(%{state | terminals: terminals}, mc, key, reason)
  end

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
  def terminate(reason, state) do
    state = migrate(state)
    held = System.monotonic_time(:millisecond) - state.opened_at

    Logger.info(
      "socket closed (trace #{state.trace || "none"}): #{close_reason(reason)} after #{held} ms, " <>
        "#{map_size(state.subs) + map_size(state.following)} subscriptions"
    )

    # Each unsubscribe sees the last one's state, so the last of several sharing
    # one watch (a terminal, an MC's config) is the one that ends it. Nothing on
    # this socket attaches again, so a terminal detach needs no ordering here:
    # it is cast, and the terminal's monitor drops this socket in any case.
    state = Enum.reduce(Map.keys(state.subs), state, &unsubscribe(&2, &1, false))

    Enum.reduce(state.following, state, fn {_tag, follow}, state ->
      unsubscribe(state, follow.id, false)
    end)

    :ok
  end

  defp close_reason(:normal), do: "closed by the MC"
  defp close_reason(:remote), do: "closed by the client"
  defp close_reason(:timeout), do: "the client went quiet"
  defp close_reason(:shutdown), do: "the MC is stopping"
  defp close_reason({:error, reason}), do: "failed: #{inspect(reason)}"
  defp close_reason(other), do: inspect(other)

  # Runs a client RPC on the MC that owns the environment, off this process so a
  # slow command never holds up streaming.
  # Most calls need the scopes the contract declares for them (`HalC2.Rpc.required_scopes/2`),
  # checked here. A file write's root-dependent scope is checked on the environment's MC.
  # The desktop app's reports go to its MC from here, in the order it sent them.
  defp rpc(state, id, environment, "server.reportDesktopUpdateStatus", payload)
       when is_map(payload) do
    if desktop_host?(state) do
      HalC2.DesktopUpdate.report(payload)
      send(self(), {:rpc_reply, id, {:ok, %{}}})
      state
    else
      scoped_rpc(state, id, environment, "server.reportDesktopUpdateStatus", payload)
    end
  end

  defp rpc(state, id, environment, method, payload),
    do: scoped_rpc(state, id, environment, method, payload)

  defp scoped_rpc(state, id, environment, method, payload),
    do: check_scopes(state, id, environment, method, payload, local_scopes(method, payload))

  # Whether a relative write's root is a project belongs to the environment's MC, which
  # checks it again with the caller's scopes (`HalC2.Rpc.handle_with_scopes/3`); a write
  # by full path is refused here, before it is routed anywhere.
  defp local_scopes("projects.writeFile" = method, %{"relativePath" => path})
       when is_binary(path) do
    if Path.type(path) == :absolute,
      do: ["terminal:operate"],
      else: [HalC2.Rpc.required_scope(method)]
  end

  defp local_scopes(method, payload), do: HalC2.Rpc.required_scopes(method, payload)

  defp check_scopes(state, id, environment, method, payload, scopes) do
    scope = Enum.find(scopes, fn scope -> not allowed?(state, scope) end)

    if scope == nil do
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
  @provider_auth_methods ~w(provider.auth.start provider.auth.respond provider.auth.cancel
                            provider.auth.logout provider.auth.complete)
  @session_elsewhere %{
    "_tag" => "EnvironmentOperationForbiddenError",
    "code" => "operation_forbidden",
    "reason" => "session_on_another_mc",
    "message" => "paired clients are managed on the MC the caller's session belongs to"
  }

  defp run_rpc(state, id, environment, method, payload) do
    socket = self()
    timeout = rpc_timeout(method)

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

  defp call_mc(state, socket, mc, method, payload, timeout) do
    {module, fun, args} =
      cond do
        method == "projects.writeFile" ->
          {HalC2.Rpc, :handle_with_scopes, [method, payload || %{}, state.scopes]}

        method == "hal-c2.createPairingLink" ->
          {HalC2.Rpc, :handle, [method, payload || %{}, state.scopes]}

        method in @session_methods ->
          {HalC2.Rpc, :handle, [method, payload || %{}, state.session]}

        # A sign-in belongs to the client that started it (`HalC2.ProviderAuth`).
        method in @provider_auth_methods ->
          {HalC2.ProviderAuth, :handle, [method, payload || %{}, auth_owner(state)]}

        # A desktop app update this socket asks for is cancelled when it goes.
        method == "server.updateServer" and mc == node() ->
          {HalC2.Upgrade, :update, [payload || %{}, nil, socket]}

        # The call runs in a process of its own that outlives this socket, so the
        # Mermaid server watches the socket (on whichever MC draws): a diagram it asked
        # for and is still waiting for when it goes is not drawn for nobody.
        method == "mermaid.render" ->
          {HalC2.Mermaid, :handle, [payload || %{}, socket]}

        true ->
          {HalC2.Rpc, :handle, [method, payload || %{}]}
      end

    try do
      # Each call runs in its own task; some (a provider update, a scheduled task run)
      # take minutes.
      :erpc.call(mc, module, fun, args, timeout)
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

  defp subscribe(state, id, :shell, %{have: have} = resume) do
    %{mcs: mcs, rows: rows} =
      HalC2.Shell.subscribe(self(), have,
        settled_limit: resume[:settled_limit],
        omit_idle_subagents: Map.get(resume, :omit_idle_subagents, false)
      )

    offline = HalC2.Cluster.Discovery.offline()

    frame = %{
      "t" => "shell",
      "id" => id,
      "mcs" =>
        for mc <- mcs do
          %{
            "mc" => Atom.to_string(mc.mc),
            "online" => mc.online,
            "trying" => mc.online or (mc.environment || %{})["environmentId"] not in offline,
            "environment" => mc.environment,
            "epoch" => mc.epoch,
            "rev" => mc.rev,
            "reset" => mc.reset
          }
          |> put_left_out(mc[:settled_left_out])
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

    with {:ok, ref, :ok} <- watch(state, shape),
         {:ok, config} <- config_or_let_go(state, shape, ref) do
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
      {:error, reason} -> {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # The follow runs in a process of its own (`follow/5`) and is answered by
  # `{:hal_c2_followed, tag, result}` (`followed/3`). Until then the subscription is in
  # `following`, and what its stream sends is held for it there.
  defp subscribe(state, id, {:stream, mc, stream_id} = shape, resume) do
    pending? = Enum.any?(state.following, fn {_, follow} -> follow.stream_id == stream_id end)

    if Map.has_key?(state.by_stream, stream_id) or pending? do
      {:push, Protocol.encode(error_frame(id, "already subscribed")), state}
    else
      # Names the MC too, for ending the subscription if this follow gives up.
      tag = {mc, make_ref()}
      client = resume |> Map.take([:handle, :window, :kinds]) |> Map.put(:tag, tag)
      socket = self()

      # The MCs may part while the follow is out: watched from here, so a follow they
      # parted during fails even if they meet again before its answer is read
      # (`handle_info/2`'s `:nodedown`).
      if watch_node?(mc), do: Node.monitor(mc, true)

      # The owning MC may be gone or slow; the client retries when it is back.
      spawn(fn ->
        result = remote(mc, HalC2.Streams, :follow, [stream_id, socket, resume.offset, client])
        send(socket, {:hal_c2_followed, tag, result})
      end)

      follow = %{
        id: id,
        stream_id: stream_id,
        mc: mc,
        shape: shape,
        held: [],
        more: 0,
        parted: false
      }

      {:ok, %{state | following: Map.put(state.following, tag, follow)}}
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

  # A terminal lives on the MC that owns its thread; its events come straight
  # here. Several subscriptions of this socket may follow one terminal (a page
  # in each window, or one made before the last is gone), each with the
  # sequence of the snapshot it was sent.
  defp subscribe(state, id, {:terminal, mc, input}, resume) do
    key = {input["threadId"], input["terminalId"]}

    case remote(mc, HalC2.Terminal, :attach, [input, self()]) do
      {:ok, {:ok, snapshot}} ->
        frame = %{"type" => "snapshot", "snapshot" => snapshot}

        windows =
          if match?(%{acks: true}, resume) do
            {:send, window} = OutputWindow.offer(OutputWindow.new(), frame)
            Map.put(state.terminal_windows, id, window)
          else
            Map.delete(state.terminal_windows, id)
          end

        state = %{
          state
          | terminal_windows: windows,
            subs: Map.put(state.subs, id, {:terminal, mc, key}),
            by_terminal:
              Map.update(
                state.by_terminal,
                key,
                %{id => snapshot["sequence"]},
                &Map.put(&1, id, snapshot["sequence"])
              )
        }

        {:push, Protocol.encode(%{"t" => "terminal", "id" => id, "event" => frame}),
         watch_terminal(state, mc, key)}

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

  # Only the desktop app that started this MC, on its bootstrap session.
  defp subscribe(state, id, {:desktop_update_control, mc} = shape, _) do
    if mc == node() and desktop_host?(state) do
      :ok = HalC2.DesktopUpdate.attach(self())

      {:ok,
       %{
         state
         | subs: Map.put(state.subs, id, shape),
           by_terminal: Map.put(state.by_terminal, shape, id)
       }}
    else
      reason = "Only the desktop app that started this MC can drive its updates."
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

  # Being on a page: the service is told this socket's device, which only this MC can
  # name, and monitored so that, if it starts again, the client follows the page anew
  # (`handle_info/2`'s `:DOWN`, as for a stream) and is back on it.
  defp subscribe(state, id, {:space_presence, mc, space, page}, offset) do
    shape = {:space_presence, mc, space, page, device(state)}

    case subscribe(state, id, shape, offset) do
      {:push, _frame, %{subs: %{^id => ^shape}} = next} = pushed ->
        monitor = Process.monitor({HalC2.Space.Presence, mc})
        put_elem(pushed, 2, put_in(next.monitors[monitor], {id, HalC2.Space.Presence}))

      other ->
        other
    end
  end

  # A shape watching a service (`watch_spec/1`): what the service answered, then its
  # changes. The subscription's own ref keeps an unsubscribe cast landing after a later
  # subscribe from dropping that one, and the changes sent before it from following
  # its snapshot.
  defp subscribe(state, id, shape, _offset) do
    key = elem(watch_spec(shape), 0)

    case watch(state, shape) do
      {:ok, ref, reply} ->
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

            # To this subscription alone: others without a ref were sent it already.
            if message,
              do: {:push, Protocol.encode(snapshot_frame(id, message, state)), state},
              else: {:ok, state}
        end

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # Watches the service of `shape` (`watch_spec/1`) under a new ref, answering
  # `{:ok, ref, reply}`, or `{:error, reason}` with nothing left watching.
  #
  # An MC from before refs (a cluster member whose update failed) has no ref arity, so
  # it is watched without one: `ref` is nil, and it tells this socket its changes bare
  # (`handle_info/2`'s last clause for `@watched`).
  #
  # The subscribe runs in a process of its own, which outlives this socket giving up on
  # it after `remote_timeout/0`: the service may still take the subscribe after an
  # unsubscribe sent now, and keep the ref as long as this socket lives. Whichever of
  # the two settles the atomic first decides: the process hands the answer over, or
  # it lets go of the ref itself once the subscribe has been taken, ordered after it.
  defp watch(state, shape) do
    {key, mc, module, sub, unsub, args} = watch_spec(shape)
    socket = self()
    tag = make_ref()
    verdict = :atomics.new(1, [])

    spawn(fn ->
      result = subscribe_call(mc, module, sub, args, make_ref())

      case :atomics.compare_exchange(verdict, 1, 0, 1) do
        :ok ->
          send(socket, {tag, result})

        # An old MC's watch without a ref may be shared with the socket's others, which
        # this process knows nothing of: one left over is let go of with the socket's
        # next subscription to it, or when the socket exits.
        _given_up ->
          with {_, ref, _} when ref != nil <- result,
               do: :erpc.cast(mc, module, unsub, args ++ [ref])
      end
    end)

    receive do
      {^tag, result} -> settle(state, shape, key, result)
    after
      remote_timeout() ->
        case :atomics.compare_exchange(verdict, 1, 0, 2) do
          :ok ->
            {:error, "MC unavailable: timeout"}

          _handed_over ->
            receive do
              {^tag, result} -> settle(state, shape, key, result)
            end
        end
    end
  end

  # The MC's config for a watch of its settings just made under `ref`, which is let go
  # of if the MC cannot answer.
  defp config_or_let_go(state, {:config, mc} = shape, ref) do
    with {:error, _} = error <- remote(mc, HalC2.Environment, :server_config, []) do
      let_go(shape, ref, Map.get(state.by_terminal, {:settings, mc}, %{}))
      error
    end
  end

  # A failed subscribe may still have been taken (a service's own call timing out).
  defp settle(_state, _shape, _key, {:ok, _ref, _reply} = ok), do: ok

  defp settle(state, shape, key, {:error, reason, ref}) do
    let_go(shape, ref, Map.get(state.by_terminal, key, %{}))
    {:error, reason}
  end

  # `fun` under `args ++ [ref]`, or under `args` alone on an MC without that arity.
  defp subscribe_call(mc, module, fun, args, ref) do
    with_ref = args ++ [ref]

    try do
      {:ok, ref, :erpc.call(mc, module, fun, with_ref, :infinity)}
    catch
      :error, {:exception, :undef, [{^module, ^fun, ^with_ref, _} | _]} ->
        case remote(mc, module, fun, args, :infinity) do
          {:ok, reply} -> {:ok, nil, reply}
          {:error, reason} -> {:error, reason, nil}
        end

      kind, reason ->
        {:error, failure(mc, kind, reason), ref}
    end
  end

  # Lets go of the watch of `shape` under `ref`; `others`, the socket's other
  # subscriptions to it (`%{id => ref}`). Without a ref (an MC from before refs, or a
  # subscription an upgrade carried over), the watch is the socket's and goes with the
  # last subscription holding none, by the arity without one, which every MC has.
  defp let_go(shape, ref, others) do
    {_key, mc, module, _sub, unsub, args} = watch_spec(shape)

    cond do
      ref != nil -> :erpc.cast(mc, module, unsub, args ++ [ref])
      nil in Map.values(others) -> :ok
      true -> :erpc.cast(mc, module, unsub, args)
    end
  end

  defp watch_node?(mc), do: mc != node() and Node.alive?()

  # What a stream sent for a follow still on its way, kept for when it is answered.
  defp hold(state, tag, message),
    do: update_in(state.following[tag].held, &[message | &1])

  # A follow was answered. One whose subscription went meanwhile (an `unsub`) lets the
  # stream go, if it took it. One the MCs parted during fails, as one they parted before
  # the answer does. A taken one goes live: its stream monitored, then what it sent so
  # far handled in order, as if it had come after.
  defp followed(state, tag, result) do
    case Map.pop(state.following, tag) do
      {nil, _} ->
        with {:ok, {:ok, server}} <- result,
             do: GenServer.cast(server, {:unsubscribe, self(), tag})

        {:ok, state}

      {follow, following} ->
        state = %{state | following: following}
        parted? = unwatch_node(follow.mc) or follow.parted

        case result do
          {:ok, {:ok, server}} when not parted? ->
            go_live(state, follow, tag, server)

          _ ->
            reason =
              case result do
                {:error, reason} when not parted? -> reason
                _ -> "MC unavailable: noconnection"
              end

            # A call that gave up may still be taken, and would feed a socket that is
            # not following the stream.
            :erpc.cast(follow.mc, HalC2.Streams, :unsubscribe, [follow.stream_id, self(), tag])
            {:push, Protocol.encode(error_frame(follow.id, reason)), state}
        end
    end
  end

  defp go_live(state, follow, tag, server) do
    %{id: id, stream_id: stream_id} = follow
    ref = Process.monitor(server)
    buffer = %{events: [], bytes: 0, replay: true}
    buffer = if follow.more > 0, do: Map.put(buffer, :pending_more, follow.more), else: buffer

    # Until `live`, events are the stream's replay from `offset`: bounded by the
    # stream, and resyncing on them would only ask for the same replay again.
    state = %{
      state
      | subs: Map.put(state.subs, id, follow.shape),
        by_stream: Map.put(state.by_stream, stream_id, {id, tag}),
        monitors: Map.put(state.monitors, ref, {id, server}),
        buffers: Map.put(state.buffers, id, buffer)
    }

    {frames, state} =
      follow.held
      |> Enum.reverse()
      |> Enum.flat_map_reduce(state, fn message, state ->
        # A resync among them ended the subscription: what follows is not its.
        case state.by_stream do
          %{^stream_id => {^id, ^tag}} ->
            case stream_message(state, id, message) do
              {:ok, state} -> {[], state}
              {:push, frames, state} -> {List.wrap(frames), state}
            end

          _ ->
            {[], state}
        end
      end)

    if frames == [], do: {:ok, state}, else: {:push, frames, state}
  end

  # Stops watching `mc` for one follow, answering whether it parted from this MC
  # meanwhile. Each follow's monitor sends a `:nodedown` of its own, so the one read
  # here leaves the others theirs.
  defp unwatch_node(mc) do
    if watch_node?(mc) do
      Node.monitor(mc, false)

      receive do
        {:nodedown, ^mc} -> true
      after
        0 -> false
      end
    else
      false
    end
  end

  # The MCs parted: every follow to `mc` still on its way fails when it is answered.
  defp parted(state, mc) do
    following =
      Map.new(state.following, fn
        {tag, %{mc: ^mc} = follow} -> {tag, %{follow | parted: true}}
        entry -> entry
      end)

    %{state | following: following}
  end

  # Calls an MC without ever taking this socket down: an unreachable MC, or one
  # without the feature (an older version), fails only the one subscription.
  # Connected MCs plus members the shell has seen that are offline now, so a
  # subscription to an MC that went away fails as unavailable, not unknown.
  defp known_mcs do
    shell = if Process.whereis(HalC2.Shell), do: HalC2.Shell.environments(), else: []
    Enum.uniq([node() | Node.list()] ++ Enum.map(shell, &elem(&1, 0)))
  end

  defp remote(mc, module, fun, args, timeout \\ remote_timeout()) do
    {:ok, :erpc.call(mc, module, fun, args, timeout)}
  catch
    kind, reason -> {:error, failure(mc, kind, reason)}
  end

  defp failure(_mc, :error, {:erpc, reason}), do: "MC unavailable: #{reason}"

  defp failure(mc, kind, reason),
    do: "#{mc} cannot serve this: #{Exception.format_banner(kind, reason)}"

  # How long a call to an MC may take before its subscription fails (`:remote_timeout`).
  defp remote_timeout, do: Application.get_env(:hal_c2, :remote_timeout, 15_000)

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
    %{state | by_stream: by_stream, v: 6} |> migrate()
  end

  # Version 7: a terminal's subscriptions are held by id, each with the sequence
  # of the snapshot it was sent. One followed before has none recorded, so it is
  # told everything, as it was. The entries are rebuilt from `subs`, which is
  # authoritative: a socket that already followed one terminal twice recorded
  # only the last id in v6, and rebuilding revives the earlier subscription
  # (told everything on its nil floor, where it was told nothing).
  defp migrate(%{v: 6} = state) do
    kept =
      Map.reject(state.by_terminal, fn
        {{thread, terminal}, id} -> is_binary(thread) and is_binary(terminal) and is_integer(id)
        _entry -> false
      end)

    by_terminal =
      Enum.reduce(state.subs, kept, fn
        {id, {:terminal, _mc, key}}, acc ->
          Map.update(acc, key, %{id => nil}, &Map.put(&1, id, nil))

        _sub, acc ->
          acc
      end)

    %{state | by_terminal: by_terminal, v: 7} |> migrate()
  end

  # Version 8: subscriptions watching a service each hold a ref of their own, several to
  # a key (`watch_spec/1`). Those made before hold none; Slack's already did.
  defp migrate(%{v: 7} = state) do
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

    %{state | by_terminal: by_terminal, v: 8}
  end

  # Version 10: a terminal subscription may acknowledge its output.
  # Version 11: stream follows run off the socket, and its open is logged under a trace.
  defp migrate(%{v: 10} = state),
    do:
      state
      |> Map.merge(%{following: %{}, trace: nil, opened_at: System.monotonic_time(:millisecond)})
      |> Map.put(:v, 11)
      |> migrate()

  defp migrate(%{v: 9} = state),
    do: state |> Map.merge(%{terminal_windows: %{}, v: 10}) |> migrate()

  # Version 9: followed terminals are monitored, and those lost with their MC kept.
  defp migrate(%{v: 8} = state),
    do: state |> Map.merge(%{terminals: %{}, lost: %{}, v: 9}) |> migrate()

  defp migrate(state), do: state

  defp session_scopes(nil), do: :all

  defp session_scopes(session) do
    case HalC2.Auth.session_scopes(session) do
      {:ok, scopes} -> scopes
      :error -> []
    end
  end

  # The desktop app that started this MC, on the session its bootstrap token made.
  defp desktop_host?(state),
    do:
      HalC2.DesktopUpdate.available?() and
        HalC2.Auth.session_subject(state.session) == "desktop-bootstrap"

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

  defp shape_scope({:desktop_update_control, _}), do: "orchestration:operate"
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

  # Where a terminal event stands in its terminal's sequence, its snapshot's for
  # a snapshot event, or `nil` when it carries none.
  defp terminal_event(state, key, event) do
    subs = Map.get(state.by_terminal, key, %{})
    seq = terminal_seq(event)
    held? = event["type"] in ~w(output snapshot restarted cleared exited closed activity)
    snapshot? = event["type"] == "snapshot"

    {frames, {subs, windows}} =
      Enum.map_reduce(subs, {subs, state.terminal_windows}, fn
        # A snapshot below the floor is a new incarnation of the terminal
        # (its process restarted its sequence at 0 after a close): the
        # subscription restarts from it instead of being starved until the
        # sequence climbs back past the old floor.
        {id, floor}, {acc, windows}
        when snapshot? and is_integer(seq) and is_integer(floor) and seq < floor ->
          {_, windows} = offer_window(windows, id, event)
          {terminal_frame(id, event), {Map.put(acc, id, seq), windows}}

        {_id, floor}, acc
        when held? and is_integer(seq) and is_integer(floor) and seq <= floor ->
          {nil, acc}

        {id, floor}, {acc, windows} ->
          acc =
            cond do
              # The terminal's next process counts its sequences from the start.
              event["type"] == "closed" -> Map.put(acc, id, nil)
              is_integer(seq) -> Map.put(acc, id, max(floor || seq, seq))
              true -> acc
            end

          case offer_window(windows, id, event) do
            {:send, windows} -> {terminal_frame(id, event), {acc, windows}}
            {:hold, windows} -> {nil, {acc, windows}}
          end
      end)

    state = %{state | terminal_windows: windows}
    state = if subs == %{}, do: state, else: put_in(state.by_terminal[key], subs)
    state = if snapshot?, do: follow_process(state, key, subs), else: state

    case Enum.reject(frames, &is_nil/1) do
      [] -> {:ok, state}
      frames -> {:push, frames, state}
    end
  end

  # A snapshot nobody attached for can be a new process, the terminal having closed and
  # opened again, which these subscriptions watch from now on.
  defp follow_process(state, key, subs) do
    with {id, _floor} <- Enum.at(subs, 0),
         %{^id => {:terminal, mc, ^key}} <- state.subs do
      watch_terminal(state, mc, key)
    else
      _ -> state
    end
  end

  defp terminal_frame(id, event),
    do: Protocol.encode(%{"t" => "terminal", "id" => id, "event" => event})

  # A subscription with no window does not acknowledge, and is sent everything.
  defp offer_window(windows, id, event) do
    case windows do
      %{^id => window} ->
        {verdict, window} = OutputWindow.offer(window, event)
        {verdict, Map.put(windows, id, window)}

      _ ->
        {:send, windows}
    end
  end

  # A subscription that caught up gets what it missed as a new snapshot, from the same
  # attach a new subscription makes: its floor moves to the snapshot, so nothing the
  # terminal is still sending is told twice. When that attach fails, the subscription
  # starts over by a `resync`, as for a terminal that went down, rather than being
  # sent everything from then on with a gap where it was held.
  defp terminal_ack(state, id, sequence) do
    with %{^id => window} <- state.terminal_windows,
         {:caught_up, window} <- OutputWindow.ack(window, sequence),
         %{^id => {:terminal, mc, {thread_id, terminal_id} = key}} <- state.subs,
         input = %{"threadId" => thread_id, "terminalId" => terminal_id},
         {:ok, {:ok, snapshot}} <- remote(mc, HalC2.Terminal, :attach, [input, self()]) do
      frame = %{"type" => "snapshot", "snapshot" => snapshot}
      {:send, window} = OutputWindow.offer(window, frame)

      {:push, terminal_frame(id, frame),
       %{
         state
         | terminal_windows: Map.put(state.terminal_windows, id, window),
           by_terminal: put_in(state.by_terminal, [key, id], snapshot["sequence"])
       }}
    else
      {:ok, %OutputWindow{} = window} ->
        {:ok, put_in(state.terminal_windows[id], window)}

      %{} ->
        {:ok, state}

      _failed ->
        {:push, Protocol.encode(%{"t" => "resync", "id" => id}), unsubscribe(state, id, false)}
    end
  end

  # A terminal drops this socket when it goes away, as it does when its MC leaves
  # the cluster for a moment. Unwatched, the subscriptions would hear nothing more
  # while what the user types still reaches the shell, so the terminal is
  # monitored, once for all of its subscriptions here (`terminal_down/4`).
  defp watch_terminal(state, mc, key) do
    found =
      case remote(mc, Registry, :lookup, [HalC2.Terminal.Registry, key]) do
        {:ok, [{pid, _}]} -> {:ok, pid}
        {:ok, []} -> {:error, :noproc}
        {:error, _} -> {:error, :noconnection}
      end

    watching = for {ref, {_, ^key, pid}} <- state.terminals, do: {ref, pid}

    {kept, stale} =
      Enum.split_with(watching, fn {_ref, pid} -> found == {:ok, pid} end)

    for {ref, _} <- stale, do: Process.demonitor(ref, [:flush])
    terminals = Map.drop(state.terminals, Enum.map(stale, &elem(&1, 0)))

    case {found, kept} do
      {{:ok, pid}, []} ->
        %{state | terminals: Map.put(terminals, Process.monitor(pid), {mc, key, pid})}

      {{:ok, _}, _} ->
        %{state | terminals: terminals}

      # Gone again before it could be monitored.
      {{:error, reason}, _} ->
        send(self(), {:hal_c2_terminal_down, mc, key, reason})
        %{state | terminals: terminals}
    end
  end

  # Nothing here follows the terminal any more: it is no longer awaited either,
  # and cluster news stops with the last one that was.
  defp unwatch_terminal(state, key) do
    gone = for {ref, {_, ^key, _}} <- state.terminals, do: ref
    for ref <- gone, do: Process.demonitor(ref, [:flush])

    lost =
      for {mc, keys} <- state.lost, (left = keys -- [key]) != [], into: %{}, do: {mc, left}

    if state.lost != %{} and lost == %{},
      do: :ok = :net_kernel.monitor_nodes(false, node_type: :all)

    %{state | terminals: Map.drop(state.terminals, gone), lost: lost}
  end

  # A terminal that closed said so first. Any other end is told to its
  # subscriptions as a `resync`, which attaches them again (a stopped terminal
  # is opened anew from its saved scrollback); while its MC cannot be reached
  # they are told so in the terminal, and resync once it is back.
  defp terminal_down(state, _mc, _key, :normal), do: {:ok, state}

  defp terminal_down(state, mc, key, _reason) do
    if mc == node() or mc in Node.list() do
      case resync_terminal(state, key) do
        {[], state} -> {:ok, state}
        {frames, state} -> {:push, frames, state}
      end
    else
      lose_terminal(state, mc, key)
    end
  end

  # Unfollowed meanwhile: nothing awaits it.
  defp lose_terminal(state, _mc, key) when not is_map_key(state.by_terminal, key),
    do: {:ok, state}

  defp lose_terminal(state, mc, key) do
    # The 3-tuple messages of `node_type`, which a stream follow's `{:nodedown, mc}` is not.
    # Turned off by the `nodeup` that empties `lost`.
    if state.lost == %{}, do: :ok = :net_kernel.monitor_nodes(true, node_type: :all)
    lost = Map.update(state.lost, mc, [key], &Enum.uniq([key | &1]))

    {thread_id, terminal_id} = key

    frames =
      for {id, _floor} <- Map.get(state.by_terminal, key, %{}) do
        event = %{
          "type" => "error",
          "threadId" => thread_id,
          "terminalId" => terminal_id,
          "message" => "lost the connection to #{mc}; reattaching when it is back"
        }

        Protocol.encode(%{"t" => "terminal", "id" => id, "event" => event})
      end

    # Back before the monitor started: no nodeup is coming.
    if mc in Node.list(), do: send(self(), {:nodeup, mc, []})

    if frames == [],
      do: {:ok, %{state | lost: lost}},
      else: {:push, frames, %{state | lost: lost}}
  end

  # Forgets the terminal's subscriptions here and tells each to `resync`.
  defp resync_terminal(state, key) do
    ids = Map.keys(Map.get(state.by_terminal, key, %{}))

    state =
      unwatch_terminal(
        %{
          state
          | subs: Map.drop(state.subs, ids),
            terminal_windows: Map.drop(state.terminal_windows, ids),
            by_terminal: Map.delete(state.by_terminal, key)
        },
        key
      )

    {Enum.map(ids, &Protocol.encode(%{"t" => "resync", "id" => &1})), state}
  end

  defp terminal_seq(%{"sequence" => seq}) when is_integer(seq), do: seq
  defp terminal_seq(%{"snapshot" => %{"sequence" => seq}}) when is_integer(seq), do: seq
  defp terminal_seq(_event), do: nil

  # A contract error's fields go in `detail`, as rpc.error carries them.
  defp error_frame(id, %{} = error),
    do: id |> error_frame(error["message"]) |> Map.put("detail", Map.delete(error, "message"))

  defp error_frame(id, reason), do: %{"t" => "error", "id" => id, "reason" => to_string(reason)}

  # How this socket reaches a stream subscription's server: straight to the
  # monitored server, carrying the subscription's tag, or — for one followed
  # before stream servers were monitored — the legacy `:erpc.cast` route the
  # caller names. A page and an unsubscribe for the same subscription must
  # take this same route (see `more/3`), so the lookup lives in one place.
  defp stream_route(state, id, stream_id) do
    case Enum.find(state.monitors, fn {_ref, {sub, _server}} -> sub == id end) do
      {ref, {_, server}} ->
        {_id, tag} = state.by_stream[stream_id]
        {:server, ref, server, tag}

      nil ->
        :legacy
    end
  end

  # Straight to the monitored stream server by its tag, as a stream unsubscribe
  # goes: ordered with this socket's unsubscribe for the subscription, and taken
  # for no subscription that follows it if it still arrives after one (a follow
  # goes by another process). An `:erpc.cast` ran in a process of its own and
  # could reach the stream after both.
  #
  # None is sent while the subscription is still replaying: a client can ask
  # before `live` (a resync-driven resubscribe does not reset its live
  # status), and the page it would move this subscription's floor for is the
  # one `stream_message/3` drops — the floor must not move for a page the
  # client never sees. The ask is not the client's to repeat either (the Qt
  # timeline asks once and waits behind its own loading flag), so it is
  # held in the subscription's buffer and forwarded when `live` arrives.
  defp more(state, id, items) do
    case state.subs do
      # Asked before its follow was answered: forwarded once it is live.
      _ when not is_map_key(state.subs, id) ->
        case pending_follow(state, id) do
          {tag, _} -> update_in(state.following[tag].more, &(&1 + items))
          nil -> state
        end

      %{^id => {:stream, _mc, _stream_id}} ->
        if get_in(state.buffers, [id, :replay]) == true do
          buffer = state.buffers[id]
          pending = Map.get(buffer, :pending_more, 0) + items
          %{state | buffers: Map.put(state.buffers, id, Map.put(buffer, :pending_more, pending))}
        else
          send_more(state, id, items)
          state
        end

      _ ->
        state
    end
  end

  defp send_more(state, id, items) do
    %{^id => {:stream, mc, stream_id}} = state.subs

    case stream_route(state, id, stream_id) do
      {:server, _ref, server, tag} ->
        message = if tag, do: {:more, self(), items, tag}, else: {:more, self(), items}
        GenServer.cast(server, message)

      :legacy ->
        :erpc.cast(mc, HalC2.Streams, :more, [stream_id, self(), items])
    end
  end

  # `ordered?` is the terminal detach's: only an unsubscribe a later attach on
  # this socket could follow pays for the ordered call.
  defp unsubscribe(state, id, ordered? \\ true) do
    state = %{state | terminal_windows: Map.delete(state.terminal_windows, id)}

    case Map.pop(state.subs, id) do
      {{:terminal, mc, {thread_id, terminal_id} = key}, subs} ->
        case Map.delete(Map.get(state.by_terminal, key, %{}), id) do
          %{} = left when left != %{} ->
            %{state | subs: subs, by_terminal: Map.put(state.by_terminal, key, left)}

          _ ->
            # The last of this socket's subscriptions to the terminal: let it go
            # by the attach's own path, a call this socket waits on, so it has
            # reached the terminal's MC before any attach that follows is made
            # and cannot land after it, as a cast in a process of its own could.
            # The wait is the trade-off: a hung owning MC stalls this socket
            # for the call's 15 seconds, where the cast never blocked (attach
            # itself is synchronous on this same path). A detach that did not
            # get through is logged: only the terminal's monitor is left to
            # drop this socket, whenever it eventually dies.
            if ordered? do
              case remote(mc, HalC2.Terminal, :detach, [thread_id, terminal_id, self()]) do
                {:ok, _} ->
                  :ok

                {:error, reason} ->
                  Logger.warning(
                    "terminal detach for #{thread_id}/#{terminal_id} did not reach #{mc}: #{reason}"
                  )
              end
            else
              :erpc.cast(mc, HalC2.Terminal, :detach, [thread_id, terminal_id, self()])
            end

            unwatch_terminal(
              %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, key)},
              key
            )
        end

      {{:server_update, mc, _input}, subs} ->
        # A desktop app update this socket asked for is cancelled.
        :erpc.cast(mc, HalC2.DesktopUpdate, :abandon, [self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:server_update, mc})}

      {{:desktop_update_control, _mc} = shape, subs} ->
        HalC2.DesktopUpdate.detach(self())
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, shape)}

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

      {{:space_presence, _mc, _space, _page, _device} = shape, subs} ->
        state = unwatch(%{state | subs: subs}, id, shape)

        {monitor, _} =
          Enum.find(state.monitors, {nil, nil}, fn {_, {sub, _}} -> sub == id end)

        if monitor, do: Process.demonitor(monitor, [:flush])
        %{state | monitors: Map.delete(state.monitors, monitor)}

      {{:stream, mc, stream_id}, _subs} ->
        # By its tag, so it ends no subscription that follows, whenever it arrives.
        case stream_route(state, id, stream_id) do
          {:server, ref, server, tag} ->
            Process.demonitor(ref, [:flush])

            message =
              if tag, do: {:unsubscribe, self(), tag}, else: {:unsubscribe, self()}

            GenServer.cast(server, message)
            forget_stream(%{state | monitors: Map.delete(state.monitors, ref)}, id)

          :legacy ->
            :erpc.cast(mc, HalC2.Streams, :unsubscribe, [stream_id, self()])
            forget_stream(state, id)
        end

      {:shell, subs} ->
        %{state | subs: subs, shell: %{}}

      {nil, _subs} ->
        case pending_follow(state, id) do
          # The follow may yet be taken: told here, and again by `followed/3` if it is.
          {tag, follow} ->
            :erpc.cast(follow.mc, HalC2.Streams, :unsubscribe, [follow.stream_id, self(), tag])
            unwatch_node(follow.mc)
            %{state | following: Map.delete(state.following, tag)}

          nil ->
            state
        end

      {shape, subs} ->
        unwatch(%{state | subs: subs}, id, shape)
    end
  end

  # Lets go of subscription `id`'s ref on the service it watches; the service keeps
  # this socket's others. Those without a ref (an upgrade carried them over, version 7,
  # or the MC is from before refs) share one watch, let go of with the last of them.
  defp unwatch(state, id, shape) do
    key = elem(watch_spec(shape), 0)
    {ref, ids} = Map.pop(Map.get(state.by_terminal, key, %{}), id)
    let_go(shape, ref, ids)

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

  defp watch_spec({:space_presence, mc, space, page, device}),
    do:
      {{:space_presence, space, page}, mc, HalC2.Space.Presence, :subscribe, :unsubscribe,
       [self(), space, page, device]}

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

  defp snapshot({:space_presence, _mc, space, page, _device}, view),
    do: {:hal_c2_space_presence, space, page, view}

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

  defp snapshot_frame(id, message, state) do
    {_key, type, fields} = watched_frame(message, state)
    Map.merge(%{"t" => type, "id" => id}, fields)
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

  defp watched_frame({:hal_c2_space_presence, space, page, view}, state),
    do:
      {{:space_presence, space, page}, "spacePresence",
       %{"viewers" => space_viewers(view, device_key(state))}}

  defp watched_frame({:hal_c2_provider_auth, instance, auth}, state),
    do:
      {{:provider_auth, instance}, "providerAuth",
       %{"state" => HalC2.ProviderAuth.view(auth, auth_owner(state))}}

  # Whose sign-ins a socket acts on and sees whole: its paired session's, so a device's
  # sockets are one client; the local tools on the MC's own token are one client too.
  defp auth_owner(%{session: nil}), do: "local"
  defp auth_owner(%{session: session}), do: session

  # This socket's device on a page: its session's, or for the MC's own token, itself.
  defp device(state) do
    name = if state.session, do: HalC2.Auth.device_name(state.session)
    %{key: device_key(state), label: name || "Another client"}
  end

  defp device_key(%{session: nil}), do: inspect(self())
  defp device_key(%{session: session}), do: session

  # Everyone on the page but this device; all of the user's devices are one viewer.
  defp space_viewers(%{devices: devices, agents: agents}, own) do
    labels = for(device <- devices, device.key != own, uniq: true, do: device.label)
    user = if labels != [], do: [%{"type" => "user", "devices" => Enum.sort(labels)}], else: []

    user ++
      for agent <- agents,
          do: %{"type" => "agent", "threadId" => agent.thread_id, "title" => agent.title}
  end

  # Drops a subscription whose service went away, telling that service nothing.
  defp pending_follow(state, id),
    do: Enum.find(state.following, fn {_tag, follow} -> follow.id == id end)

  defp forget_stream(state, id) do
    case Map.pop(state.subs, id) do
      {{:space_presence, _mc, _space, _page, _device} = shape, subs} ->
        unwatch(%{state | subs: subs}, id, shape)

      {{:stream, _mc, stream_id}, subs} ->
        forget_stream(state, id, stream_id, subs)
    end
  end

  # Drops a stream subscription here, telling its stream nothing.
  defp forget_stream(state, id, stream_id, subs) do
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

    # Still replaying until `live`, through every snapshot part: a page is only
    # ever an answer to a `more` sent once live (below). An ask held from
    # before this part (`more/3`) is carried over the buffer's reset.
    held = Map.take(Map.get(state.buffers, id, %{}), [:pending_more])

    buffers =
      if part_state == :done,
        do: Map.put(state.buffers, id, Map.merge(%{events: [], bytes: 0, replay: true}, held)),
        else:
          Map.put(
            state.buffers,
            id,
            Map.merge(%{events: [], bytes: 0, snapshot_part: part + 1, replay: true}, held)
          )

    {:push, Protocol.encode(frame), %{state | buffers: buffers}}
  end

  # Replayed events may still be buffered; they go out before the live marker.
  # An ask held while replaying (`more/3`) is forwarded now that its page
  # will be seen, behind the live marker it waited for.
  defp stream_message(state, id, {:live, seq, handle}) do
    {frames, state} = flush(state)

    {pending, state} =
      case state.buffers do
        %{^id => buffer} ->
          {pending, buffer} =
            buffer |> Map.delete(:replay) |> Map.pop(:pending_more)

          {pending, %{state | buffers: Map.put(state.buffers, id, buffer)}}

        _ ->
          {nil, state}
      end

    if pending, do: send_more(state, id, pending)

    live = %{"t" => "live", "id" => id, "offset" => seq, "handle" => handle}
    {:push, frames ++ [Protocol.encode(live)], state}
  end

  # A page is the stream as of `seq`, so the events before it go out first. One
  # that arrives while this subscription is still replaying answers no `more`
  # of its — `more/3` sends none until `live`, so this subscription's floor
  # has not moved for it and dropping it loses nothing: it is the
  # subscription before this one's, and goes nowhere. (For a `more` sent by
  # pre-upgrade code on the legacy route, same-sender ordering from the
  # stream server or its relay is what keeps its page behind `live`.)
  defp stream_message(state, id, {:page, seq, rows, floor, part_state}) do
    if get_in(state.buffers, [id, :replay]) do
      {:ok, state}
    else
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
  end

  defp stream_message(state, id, {:events, events, seq}) do
    buffer = Map.get(state.buffers, id, %{events: [], bytes: 0})
    # Sized once; `buffer_events/6` adds them to whatever the buffer still holds.
    size = Enum.reduce(events, 0, &(:erlang.external_size(&1.patch) + &2))
    bytes = buffer.bytes + size
    # Buffers from before the count was kept count from what they hold.
    count = Map.get_lazy(buffer, :count, fn -> length(buffer.events) end) + length(events)

    cond do
      # A part of what the client lacks goes out as it comes, as a snapshot's parts
      # do. Buffered, the parts of a thread on this MC would all be here before the
      # first flush and leave as one frame of any size.
      Map.get(buffer, :replay, false) ->
        {:push, events_frame(id, events, seq), state}

      bytes > @max_buffered or count > @max_buffered_events ->
        # The client has everything before the oldest event it has not been sent.
        oldest = List.last(buffer.events) || hd(events)
        state = unsubscribe(state, id)
        resync = %{"t" => "resync", "id" => id, "offset" => oldest.seq - 1}
        {:push, Protocol.encode(resync), state}

      true ->
        buffer_events(state, id, buffer, events, seq, size)
    end
  end

  defp buffer_events(state, id, buffer, events, seq, size) do
    progress? = Enum.all?(events, &Map.get(&1, :progress, false))
    held? = Map.has_key?(buffer, :hold)

    # What else comes for the subscription goes after the progress held before it.
    {frames, buffer} =
      if held? and not progress?, do: release(id, buffer), else: {[], buffer}

    # With nothing else waiting, the progress waits for more of itself.
    hold? = progress? and (held? or buffer.events == [])

    buffer =
      Map.merge(buffer, %{
        events: Enum.reverse(events, buffer.events),
        bytes: buffer.bytes + size,
        count: Map.get_lazy(buffer, :count, fn -> length(buffer.events) end) + length(events),
        seq: seq
      })

    cond do
      hold? and buffer.count >= @max_held_progress ->
        {frames, buffer} = release(id, buffer)
        {:push, frames, %{state | buffers: Map.put(state.buffers, id, buffer)}}

      hold? ->
        buffer = Map.put_new_lazy(buffer, :hold, fn -> hold(id) end)
        {:ok, %{state | buffers: Map.put(state.buffers, id, buffer)}}

      true ->
        state = schedule_flush(%{state | buffers: Map.put(state.buffers, id, buffer)})
        if frames == [], do: {:ok, state}, else: {:push, frames, state}
    end
  end

  defp hold(id) do
    hold = make_ref()
    Process.send_after(self(), {:release_progress, id, hold}, progress_hold_ms())
    hold
  end

  # Features hold progress longer, so what they send in a row lands in one hold.
  defp progress_hold_ms, do: Application.get_env(:hal_c2, :progress_hold_ms, 50)

  defp release(id, buffer),
    do: {[events_frame(id, Enum.reverse(buffer.events), buffer.seq)], sent(buffer)}

  defp sent(buffer),
    do: buffer |> Map.merge(%{events: [], bytes: 0, count: 0}) |> Map.delete(:hold)

  # The offset is the one the stream gave with the last of the events: a replay in
  # several parts only moves the client's offset with its last.
  defp events_frame(id, events, seq) do
    wire = for e <- Protocol.coalesce(events), do: [e.seq, e.kind, e.entity, e.patch, e.at]
    Protocol.encode(%{"t" => "events", "id" => id, "offset" => seq, "events" => wire})
  end

  defp put_floor(frame, %{floor: floor}), do: Map.put(frame, "floor", floor)
  defp put_floor(frame, _meta), do: frame

  # Sends what the subscriptions have buffered, with their held progress unless
  # `held?` is false.
  defp flush(state, held? \\ true) do
    ready =
      for {id, %{events: [_ | _]} = buffer} <- state.buffers,
          held? or not Map.has_key?(buffer, :hold),
          do: id

    Enum.flat_map_reduce(ready, state, fn id, state ->
      {frames, buffer} = release(id, state.buffers[id])
      {frames, %{state | buffers: Map.put(state.buffers, id, buffer)}}
    end)
  end

  # The flush message lands behind everything already in the mailbox, so each
  # flush drains a whole burst.
  defp schedule_flush(%{flush_scheduled: true} = state), do: state

  defp schedule_flush(state) do
    send(self(), :flush)
    %{state | flush_scheduled: true}
  end

  # A later row of a stream replaces an earlier one, so the frame carries the same
  # changes as the messages did, in the order each row last changed (`order`). After
  # a `reset` the MC's earlier rows are gone, buffered or held; rows merged on top of
  # it keep the frame a reset.
  defp buffer_shell_rows(state, mc, rows, %{epoch: epoch, rev: rev, reset: reset?} = version) do
    buffer = Map.get(state.shell, mc, %{rows: %{}, reset: false})
    {kept, order} = if reset?, do: {%{}, %{}}, else: {buffer.rows, Map.get(buffer, :order, %{})}
    last = Map.get(buffer, :last, 0)

    buffer = %{
      rows: Map.merge(kept, Map.new(rows)),
      order:
        Map.merge(
          order,
          Map.new(Enum.with_index(rows, last + 1), fn {{sid, _}, n} -> {sid, n} end)
        ),
      last: last + length(rows),
      epoch: epoch,
      rev: rev,
      reset: reset? or buffer.reset,
      # Told with the rows sent whole, to a client that asked for a settled limit.
      settled_left_out:
        if(reset?, do: version[:settled_left_out], else: buffer[:settled_left_out])
    }

    put_in(state.shell[mc], buffer)
  end

  defp flush_shell(%{shell: shell} = state) when map_size(shell) == 0, do: {[], state}

  defp flush_shell(state) do
    frames =
      case shell_sub(state) do
        {id, _} ->
          for {mc, buffer} <- Enum.sort(state.shell),
              do: Protocol.encode(shell_message(id, {:rows, mc, in_order(buffer), buffer}))

        nil ->
          []
      end

    {frames, %{state | shell: %{}}}
  end

  # Rows buffered before their order was kept go first, by id.
  defp in_order(buffer) do
    order = Map.get(buffer, :order, %{})
    Enum.sort_by(buffer.rows, fn {sid, _} -> {Map.get(order, sid, 0), sid} end)
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
    do:
      %{
        "t" => "shell.rows",
        "id" => id,
        "mc" => to_string(mc),
        "epoch" => version.epoch,
        "rev" => version.rev,
        "reset" => version.reset,
        "rows" => for({sid, {kind, row}} <- rows, do: [sid, kind, row])
      }
      |> put_left_out(version[:settled_left_out])

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
      "trying" => false,
      "removed" => true
    }

  defp shell_message(id, {:mc, mc, :offline}),
    do: %{
      "t" => "shell.mc",
      "id" => id,
      "mc" => to_string(mc),
      "online" => false,
      "trying" => false
    }

  defp shell_message(id, {:mc, mc, status}),
    do: %{
      "t" => "shell.mc",
      "id" => id,
      "mc" => to_string(mc),
      "online" => status in [:up, true],
      "trying" => true
    }

  # The settled threads of each project an MC's rows sent whole left out, for a client
  # that asked for a settled limit.
  defp put_left_out(frame, nil), do: frame
  defp put_left_out(frame, left_out), do: Map.put(frame, "settledLeftOut", left_out)
end
