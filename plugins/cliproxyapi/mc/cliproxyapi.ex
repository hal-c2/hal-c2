defmodule HalC2Plugins.CliProxyApi do
  @moduledoc """
  CLIProxyAPI on this MC: runs `cli-proxy-api` (or connects to one already running),
  keeps "Claude via CLIProxyAPI" and "Codex via CLIProxyAPI" in Settings → Providers
  pointed at it, and drains what its page shows into topics.

  The plugin is a supervisor of three processes: an Agent holding the settings saved
  last, `Proxy` (the Port) and this server, which a crash restarts with those settings.
  This server reads the proxy's management API on one timer (`@drain_ms`): the usage
  queue (summed by `Usage`), new log lines, the accounts, a sign-in waiting on the
  user and, every few hours, whether a newer release is out. It publishes a topic
  only when what it holds changed, so the page subscribes and never polls.

  A management key the proxy refuses blocks every call until the settings change or
  the user asks to retry: the proxy bans an address after five refusals.

  Everything it keeps is in the plugin's data folder: the management secret and the
  client key agents use (`0600`), the config it starts the proxy with, the accounts
  (`auths/`), the downloaded release, the usage and its ledger of instances.

  `config :hal_c2, :cliproxyapi, drain_ms: ms` sets the timer, as the tests do.
  """

  use GenServer
  @behaviour HalC2.Plugins.Extension

  alias HalC2.Plugins.Host
  alias HalC2Plugins.CliProxyApi.{Api, Instances, Proxy, Release, Usage}

  @id "cliproxyapi"
  @drain_ms 15_000
  @latest_ms 6 * 60 * 60 * 1000
  @usage_days 7
  @log_lines 100
  @queue_batch 500
  @key_providers ~w(claude codex gemini)
  @sign_in_providers ~w(claude codex)

  @settings Module.concat(__MODULE__, Settings)

  @impl HalC2.Plugins.Extension
  def start_link(settings) do
    Supervisor.start_link(
      [
        %{id: @settings, start: {Agent, :start_link, [fn -> settings end, [name: @settings]]}},
        Proxy,
        %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}}
      ],
      strategy: :rest_for_one
    )
  end

  # The host calls this from its own server: hand the settings over and return. The
  # Agent keeps them for this server started again after a crash.
  @impl HalC2.Plugins.Extension
  def settings_changed(_pid, settings, _old) do
    Agent.update(@settings, fn _ -> settings end)
    GenServer.cast(__MODULE__, {:settings, settings})
  end

  @impl HalC2.Plugins.Extension
  def validate_settings(settings) do
    port = settings["port"]
    url = String.trim(settings["url"] || "")

    cond do
      settings["mode"] not in [nil, "run", "connect"] ->
        {:error, "Proxy is Run or Connect."}

      port != nil and not (is_integer(port) and port in 1..65_535) ->
        {:error, "Port is a whole number from 1 to 65535."}

      settings["mode"] == "connect" and not address?(url) ->
        {:error, "Connect needs the proxy's address, such as http://127.0.0.1:8317."}

      # The plugin and Codex append their paths to it, which would land in a query.
      settings["mode"] == "connect" and suffixed?(url) ->
        {:error, "Connect takes the proxy's address without a query (?) or fragment (#)."}

      # The management key crosses the wire with every call.
      settings["mode"] == "connect" and not (https?(url) or loopback?(url)) ->
        {:error,
         "Connect over http only to a proxy on this machine (127.0.0.1, localhost); use https for one elsewhere."}

      settings["mode"] == "connect" and String.trim(settings["managementKey"] || "") == "" ->
        {:error, "Connect needs the proxy's management key."}

      true ->
        :ok
    end
  end

  @impl HalC2.Plugins.Extension
  def call(method, input, _context),
    do: GenServer.call(__MODULE__, {:call, method, input || %{}}, 30_000)

  @impl GenServer
  def init(nil) do
    Process.flag(:trap_exit, true)
    dir = Host.data_dir(@id)

    state = %{
      settings: Agent.get(@settings, & &1),
      dir: dir,
      management: secret(dir, "management.key", ""),
      client: secret(dir, "client.key", "hal-c2-"),
      ledger: read_json(dir, "providers.json", %{}),
      usage: Usage.load(read_json(dir, "usage.json", [])),
      # Why the proxy gives no usage, when it refuses its usage queue.
      usage_note: nil,
      spec: nil,
      proxy: %{"state" => "stopped", "pid" => nil, "restarts" => 0, "lines" => []},
      binary: nil,
      source: nil,
      download: nil,
      failure: nil,
      answering: false,
      unreachable: nil,
      # Connect: whether the proxy holds the plugin's client key yet (`allow_client/1`).
      allowed: false,
      # Connect: why its saved settings are not used (`validate_settings/1`).
      invalid: nil,
      blocked: nil,
      error: nil,
      # Per instance name, why the host refused to put it: the user has an instance
      # under its id. Tried again on the next sync.
      taken: %{},
      # Why the host could not list the plugin's instances, so none is known to be there.
      unlisted: nil,
      latest: nil,
      latest_at: nil,
      accounts: [],
      sign_in: nil,
      keys: [],
      logs: [],
      cursor: nil,
      published: %{},
      timer: nil,
      # The drain the timer is for: one cancelled after it fired is dropped.
      drain: nil
    }

    HalC2.Settings.watch(self())
    send(self(), :apply)
    {:ok, state}
  end

  # Applied at once, so the page's next call sees the new settings. A sign-in started on
  # another proxy, or with another key, is that proxy's.
  @impl GenServer
  def handle_cast({:settings, settings}, state) do
    next = %{state | settings: settings, blocked: nil, failure: nil}
    next = if conn(next) == conn(state), do: next, else: %{next | sign_in: nil}

    # A cursor and its lines are the proxy's at that address; another address starts
    # its log over, where an unrelated edit leaves them alone.
    next = if base(next) == base(state), do: next, else: %{next | cursor: nil, logs: []}
    {:noreply, apply_now(next)}
  end

  @impl GenServer
  def handle_call({:call, method, input}, _from, state) do
    case handle(method, input, state) do
      {:ok, reply, state} -> {:reply, {:ok, reply}, publish(state)}
      {:error, message, state} -> {:reply, {:error, message}, publish(state)}
    end
  end

  @impl GenServer
  def handle_info(:apply, state), do: {:noreply, apply_now(state)}

  def handle_info({:drain, token}, %{drain: token} = state),
    do: {:noreply, %{state | timer: nil, drain: nil} |> drain() |> schedule() |> publish()}

  def handle_info({:drain, _stale}, state), do: {:noreply, state}

  # A proxy that just started is asked soon rather than at the next drain.
  def handle_info({:cliproxyapi_proxy, proxy}, state) do
    state = %{state | proxy: proxy, answering: state.answering and proxy["state"] == "running"}
    {:noreply, state |> soon() |> publish()}
  end

  def handle_info({:hal_c2_settings, _mc, _settings}, state),
    do: {:noreply, state |> sync() |> publish()}

  def handle_info({ref, result}, %{download: ref} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, _path} -> %{state | download: nil}
        {:error, message} -> %{state | download: nil, failure: message}
      end

    send(self(), :apply)
    {:noreply, publish(state)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{download: ref} = state),
    do:
      {:noreply,
       publish(%{state | download: nil, failure: "The download stopped: #{inspect(reason)}."})}

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_now(state) do
    state |> apply_settings() |> sync() |> drain() |> schedule() |> publish()
  end

  # --- calls from the page ---

  defp handle("status", _input, state), do: {:ok, view(state), state}

  defp handle("refresh", _input, state) do
    state = drain(state)
    {:ok, view(state), state}
  end

  defp handle("retry", _input, state) do
    state = %{state | blocked: nil, failure: nil, error: nil} |> apply_settings() |> drain()
    {:ok, view(state), state}
  end

  defp handle("addInstance", %{"name" => name}, state) do
    if name in Instances.names() do
      # Written before the put: one the host refuses must not come back dismissed.
      state = %{state | ledger: Map.delete(state.ledger, name)} |> save_ledger() |> sync()
      {:ok, view(state), state}
    else
      {:error, "#{inspect(name)} is not one of the plugin's instances.", state}
    end
  end

  defp handle("signIn", %{"provider" => provider}, state) when provider in @sign_in_providers do
    with {:ok, conn} <- usable(state),
         {:ok, %{"url" => url, "state" => key}, _} when is_binary(url) <-
           api(state, Api.get(conn, "/oauth/auth-url", provider: provider)),
         true <- address?(url) || :not_web do
      sign_in = %{
        "provider" => provider,
        "state" => key,
        "url" => url,
        "status" => "wait",
        "error" => nil
      }

      {:ok, %{"url" => url}, %{state | sign_in: sign_in}}
    else
      :not_web ->
        {:error, "The proxy returned a sign-in address that is not http or https.", state}

      {:ok, body, _} ->
        {:error, "The proxy did not start a sign-in: #{inspect(body)}", state}

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  defp handle("signIn", _input, state), do: {:error, "Sign in to Claude or Codex.", state}

  defp handle(
         "finishSignIn",
         %{"address" => address},
         %{sign_in: %{"status" => "wait"} = sign_in} = state
       ) do
    body = %{
      "provider" => sign_in["provider"],
      "redirect_url" => String.trim(address),
      "state" => sign_in["state"]
    }

    with {:ok, conn} <- usable(state),
         {:ok, _, _} <- api(state, Api.post(conn, "/oauth/callback", body)) do
      state = check_sign_in(state, conn)
      {:ok, %{"signIn" => state.sign_in}, state}
    end
  end

  defp handle("finishSignIn", _input, state), do: {:error, "No sign-in is waiting.", state}

  defp handle("cancelSignIn", _input, %{sign_in: %{"state" => key}} = state) do
    with {:ok, conn} <- usable(state),
         do: api(state, Api.delete(conn, "/oauth/session", state: key))

    {:ok, %{}, %{state | sign_in: nil}}
  end

  defp handle("cancelSignIn", _input, state), do: {:ok, %{}, %{state | sign_in: nil}}

  defp handle("removeAccount", %{"name" => name}, state) when is_binary(name) do
    with {:ok, conn} <- usable(state),
         {:ok, _, _} <- api(state, Api.delete(conn, "/credentials", name: name)) do
      state = accounts(state, conn)
      {:ok, %{}, state}
    end
  end

  defp handle("toggleAccount", %{"name" => name, "disabled" => disabled}, state)
       when is_boolean(disabled) do
    with {:ok, conn} <- usable(state),
         {:ok, _, _} <-
           api(
             state,
             Api.patch(conn, "/credentials/status", %{"name" => name, "disabled" => disabled})
           ) do
      {:ok, %{}, accounts(state, conn)}
    end
  end

  defp handle("addKey", %{"provider" => provider, "apiKey" => key} = input, state)
       when provider in @key_providers and is_binary(key) do
    key = String.trim(key)
    base = String.trim(input["baseUrl"] || "")

    cond do
      key == "" ->
        {:error, "The API key is empty.", state}

      base != "" and not address?(base) ->
        {:error, "The base URL is an http or https address.", state}

      true ->
        group = %{"keys" => [%{"api-key" => key}]}
        group = if base == "", do: group, else: Map.put(group, "base-url", base)
        edit_keys(state, provider, &(&1 ++ [group]))
    end
  end

  defp handle("removeKey", %{"provider" => provider, "id" => id}, state)
       when provider in @key_providers and is_binary(id) do
    edit_keys(state, provider, fn groups ->
      case Enum.find_index(groups, &(is_map(&1) and group_id(state, &1) == id)) do
        nil -> :changed
        index -> List.delete_at(groups, index)
      end
    end)
  end

  defp handle("clearLogs", _input, state) do
    with {:ok, conn} <- usable(state),
         {:ok, _, _} <- api(state, Api.delete(conn, "/observability/logs")) do
      {:ok, %{}, %{state | logs: []}}
    end
  end

  defp handle(method, _input, state),
    do: {:error, "CLIProxyAPI has no method #{method} taking that input.", state}

  # --- the proxy ---

  defp apply_settings(state) do
    case mode(state) do
      "connect" ->
        if state.spec, do: Proxy.halt()
        stopped = %{state.proxy | "state" => "stopped", "pid" => nil}

        # The host checks a save only while the plugin runs: settings saved while it was
        # off are checked here, so the key is never sent where they would send it.
        invalid =
          case validate_settings(state.settings) do
            :ok -> nil
            {:error, message} -> message
          end

        # Each drain adds the client key to the proxy until it holds it (`allow_client/1`).
        %{
          state
          | spec: nil,
            binary: nil,
            source: nil,
            proxy: stopped,
            answering: false,
            allowed: false,
            invalid: invalid
        }

      "run" ->
        # `invalid` is Connect's: a refusal there must not withhold Run's proxy.
        run(%{state | invalid: nil})
    end
  end

  defp run(%{download: ref} = state) when ref != nil, do: state
  defp run(%{failure: failure} = state) when failure != nil, do: state

  defp run(state) do
    case Release.locate(state.settings["binaryPath"], state.dir) do
      {:ok, binary, source} ->
        spec = spec(state, binary)

        if spec == state.spec and state.proxy["state"] in ["running", "restarting"] do
          state
        else
          state = snapshot_keys(state)
          write_config(state)
          proxy = Proxy.run(spec)
          %{state | spec: spec, proxy: proxy, binary: binary, source: source, answering: false}
        end

      {:download, _path} ->
        if state.spec, do: Proxy.halt()
        task = Task.async(fn -> Release.download(state.dir) end)
        %{state | download: task.ref, spec: nil, binary: nil, source: "download"}

      {:error, message} ->
        if state.spec, do: Proxy.halt()
        %{state | failure: message, spec: nil, binary: nil, source: nil}
    end
  end

  defp spec(state, binary) do
    %{
      binary: binary,
      args: ["-config", config_path(state)],
      env: %{"MANAGEMENT_PASSWORD" => state.management, "WRITABLE_PATH" => state.dir},
      cd: state.dir,
      pidfile: Path.join(state.dir, "cli-proxy-api.pid"),
      # The managed config: a change of port or key restarts the proxy on it.
      config: :erlang.phash2(config(state))
    }
  end

  defp config_path(state), do: Path.join(state.dir, "config.yaml")

  # JSON is YAML, so the proxy reads this as its config.yaml. It writes the file
  # back as YAML when its API edits the config; the next start writes it again from
  # these values and the upstream keys it last held.
  defp config(state) do
    %{
      "config-version" => 8,
      "server" => %{"host" => "127.0.0.1", "port" => port(state)},
      "management" => %{
        "allow-remote" => false,
        "secret-key" => "",
        "disable-control-panel" => true
      },
      "access" => %{"api-keys" => [state.client]},
      "oauth" => %{"auth-dir" => Path.join(state.dir, "auths")},
      "observability" => %{
        "logs" => %{"logging-to-file" => true, "logs-max-total-size-mb" => 50},
        "usage" => %{
          "usage-statistics-enabled" => true,
          "redis-usage-queue-retention-seconds" => 300
        }
      }
    }
  end

  defp write_config(state) do
    File.mkdir_p!(Path.join(state.dir, "auths"))
    upstream = read_json(state.dir, "upstream-keys.json", %{})

    config =
      if upstream == %{}, do: config(state), else: Map.put(config(state), "api-keys", upstream)

    private(config_path(state), JSON.encode!(config))
  end

  # The proxy's own copy of the upstream keys, kept for the next start.
  defp snapshot_keys(%{answering: true, spec: spec} = state) when spec != nil do
    case Api.get(conn(state), "/config/api-keys") do
      {:ok, %{} = keys, _} ->
        private(Path.join(state.dir, "upstream-keys.json"), JSON.encode!(keys))

      _ ->
        :ok
    end

    state
  end

  defp snapshot_keys(state), do: state

  # In Connect the proxy is someone else's: the plugin's client key is added to its
  # access keys, without touching the others, and tried again each drain until it is.
  defp allow_client(state, tries \\ 2)

  defp allow_client(%{allowed: true} = state, _tries), do: state

  defp allow_client(state, tries) do
    conn = conn(state)

    result =
      with {:ok, keys, headers} <- Api.get(conn, "/config/access/api-keys") do
        keys = if is_list(keys), do: keys, else: []

        if state.client in keys,
          do: {:ok, nil, []},
          else:
            Api.put(conn, "/config/access/api-keys", keys ++ [state.client], Api.etag(headers))
      end

    case result do
      {:ok, _, _} -> %{state | allowed: true, unreachable: nil, error: nil}
      {:error, :conflict, _} when tries > 1 -> allow_client(state, tries - 1)
      {:error, kind, message} -> refused(state, kind, message)
    end
  end

  # --- what the page shows ---

  defp drain(%{blocked: blocked} = state) when blocked != nil, do: state
  defp drain(%{invalid: invalid} = state) when invalid != nil, do: state

  # A download in flight is Run's; in Connect the user's proxy is drained meanwhile.
  defp drain(state) do
    state = proxy_output(state)

    if mode(state) == "run" and (state.download != nil or state.proxy["state"] != "running") do
      state
    else
      conn = conn(state)

      case usage(state, conn) do
        {:ok, state} ->
          was = state.answering
          state = %{state | answering: true, unreachable: nil}

          # A refusal ends the drain: a refused key is not sent again (`refused/3`).
          Enum.reduce(
            [
              &if(mode(&1) == "connect", do: allow_client(&1), else: &1),
              &if(was, do: &1, else: keys(&1, conn)),
              &logs(&1, conn),
              &accounts(&1, conn),
              &check_sign_in(&1, conn),
              &latest(&1, conn)
            ],
            state,
            fn stage, state ->
              if state.blocked == nil and state.answering, do: stage.(state), else: state
            end
          )

        {:error, kind, message} ->
          refused(state, kind, message)
      end
    end
  end

  # A proxy that keeps no usage queue (usage statistics off in its config, say) still
  # routes: the page says why there is no usage, and the rest is read.
  defp usage(state, conn) do
    case Api.get(conn, "/observability/usage/queue", count: @queue_batch) do
      {:ok, records, _} ->
        usage =
          Usage.add(state.usage, if(is_list(records), do: records, else: []), Date.utc_today())

        if usage != state.usage,
          do: private(Path.join(state.dir, "usage.json"), JSON.encode!(Usage.dump(usage)))

        {:ok, %{state | usage: usage, usage_note: nil}}

      {:error, kind, message} when kind in [:http, :missing] ->
        {:ok, %{state | usage_note: message}}

      {:error, kind, message} ->
        {:error, kind, message}
    end
  end

  defp logs(state, conn) do
    query =
      if state.cursor, do: [cursor: state.cursor, limit: @log_lines], else: [limit: @log_lines]

    case Api.get(conn, "/observability/logs", query) do
      {:ok, %{"lines" => lines} = body, _} when is_list(lines) ->
        lines = for line <- lines, is_binary(line), do: String.slice(line, 0, 500)
        kept = if body["cursor-reset"] == true, do: lines, else: state.logs ++ lines
        %{state | logs: Enum.take(kept, -@log_lines), cursor: body["next-cursor"] || state.cursor}

      {:ok, _, _} ->
        state

      {:error, kind, message} ->
        # A proxy that keeps no log file (Connect, say) still routes; say so and go on.
        if kind in [:http, :missing],
          do: %{state | logs: ["(no log: #{message})"]},
          else: refused(state, kind, message)
    end
  end

  defp accounts(state, conn) do
    case Api.get(conn, "/credentials") do
      {:ok, %{"files" => files}, _} when is_list(files) ->
        accounts =
          for %{} = file <- files do
            %{
              "id" => file["id"] || file["name"],
              "name" => file["name"],
              "provider" => file["provider"] || file["type"],
              "email" => file["email"] || file["account"],
              "status" => file["status"],
              "message" => file["status_message"],
              "disabled" => file["disabled"] == true,
              "unavailable" => file["unavailable"] == true
            }
          end

        %{state | accounts: accounts}

      {:ok, _, _} ->
        state

      {:error, kind, message} ->
        refused(state, kind, message)
    end
  end

  defp check_sign_in(%{sign_in: %{"status" => "wait", "state" => key}} = state, conn) do
    case Api.get(conn, "/oauth/status", state: key) do
      {:ok, %{"status" => "ok"}, _} ->
        accounts(%{state | sign_in: nil}, conn)

      {:ok, %{"status" => "error"} = body, _} ->
        %{
          state
          | sign_in: %{
              state.sign_in
              | "status" => "error",
                "error" => body["error"] || "The sign-in failed."
            }
        }

      {:ok, _, _} ->
        state

      {:error, kind, message} when kind in [:http, :missing] ->
        %{state | sign_in: %{state.sign_in | "status" => "error", "error" => message}}

      {:error, kind, message} ->
        refused(state, kind, message)
    end
  end

  defp check_sign_in(state, _conn), do: state

  defp latest(state, conn) do
    now = System.monotonic_time(:millisecond)

    if state.latest_at && now - state.latest_at < @latest_ms do
      state
    else
      case Api.get(conn, "/server/latest-version") do
        {:ok, %{"latest-version" => latest}, _} when is_binary(latest) ->
          %{state | latest: latest, latest_at: now}

        _ ->
          %{state | latest_at: now}
      end
    end
  end

  defp keys(state, conn) do
    case Api.get(conn, "/config/api-keys") do
      {:ok, %{} = keys, _} ->
        %{state | keys: mask_keys(state, keys)}

      {:ok, _, _} ->
        state

      {:error, kind, _} when kind in [:http, :missing] ->
        %{state | keys: []}

      {:error, kind, message} ->
        refused(state, kind, message)
    end
  end

  defp edit_keys(state, provider, fun, tries \\ 2) do
    path = "/config/api-keys/#{provider}"

    with {:ok, conn} <- usable(state),
         {:ok, groups, etag} <- groups(state, conn, path) do
      case fun.(groups) do
        :changed ->
          {:error, "That key changed on the proxy; look again.", keys(state, conn)}

        groups ->
          case Api.put(conn, path, groups, etag) do
            {:ok, _, _} ->
              if mode(state) == "run", do: keep_keys(state, provider, groups)
              state = keys(state, conn)
              {:ok, %{"keys" => state.keys}, state}

            {:error, :conflict, _} when tries > 1 ->
              edit_keys(state, provider, fun, tries - 1)

            {:error, kind, message} ->
              {:error, message, refused(state, kind, message)}
          end
      end
    end
  end

  defp groups(state, conn, path) do
    case Api.get(conn, path) do
      {:ok, groups, headers} when is_list(groups) -> {:ok, groups, Api.etag(headers)}
      {:ok, _, headers} -> {:ok, [], Api.etag(headers)}
      {:error, :missing, _} -> {:ok, [], nil}
      {:error, kind, message} -> {:error, message, refused(state, kind, message)}
    end
  end

  # What a key edit put, kept for the next start at once: the proxy writes it to its
  # config, which the next start writes again from this file.
  defp keep_keys(state, provider, groups) do
    upstream = read_json(state.dir, "upstream-keys.json", %{})

    private(
      Path.join(state.dir, "upstream-keys.json"),
      JSON.encode!(Map.put(upstream, provider, groups))
    )
  end

  defp mask_keys(state, keys) do
    for provider <- @key_providers,
        group <- List.wrap(keys[provider]),
        is_map(group),
        do:
          Map.merge(mask_group(group), %{"provider" => provider, "id" => group_id(state, group)})
  end

  # Names a key group for `removeKey` without showing its keys: keyed by the client key,
  # so it says nothing of them, and it changes whenever the group does.
  defp group_id(state, group) do
    :crypto.mac(:hmac, :sha256, state.client, :erlang.term_to_binary(group, [:deterministic]))
    |> binary_part(0, 12)
    |> Base.encode16(case: :lower)
  end

  defp mask_group(group) do
    %{
      "name" => group["name"],
      "baseUrl" => group["base-url"],
      "keys" =>
        for(%{"api-key" => key} <- List.wrap(group["keys"]), is_binary(key), do: mask(key))
    }
  end

  defp mask(key) when byte_size(key) <= 10, do: "…"
  defp mask(key), do: String.slice(key, 0, 4) <> "…" <> String.slice(key, -4, 4)

  # A refused key is never tried again by itself; a proxy that does not answer is
  # one starting, or one gone.
  defp refused(state, :auth, message), do: %{state | blocked: message}

  # The proxy at that address may be another one when it answers again, without the
  # plugin's client key: the next drain checks its access keys afresh.
  defp refused(state, :down, message),
    do: %{state | answering: false, unreachable: message, allowed: false}
  defp refused(state, _kind, message), do: %{state | error: message}

  defp usable(%{blocked: blocked} = state) when blocked != nil,
    do:
      {:error, "The proxy refused the management key (#{blocked}). Fix the key and retry.", state}

  defp usable(state) do
    cond do
      mode(state) == "connect" and state.invalid != nil ->
        {:error, state.invalid, state}

      mode(state) == "run" and state.proxy["state"] != "running" ->
        {:error, "The proxy is not running.", state}

      true ->
        {:ok, conn(state)}
    end
  end

  defp api(state, result) do
    case result do
      {:ok, body, headers} -> {:ok, body, headers}
      {:error, kind, message} -> {:error, message, refused(state, kind, message)}
    end
  end

  # The proxy tells the plugin when it starts, stops or fails, not of each line it
  # prints, so the lines it printed since are read at every drain.
  defp proxy_output(%{spec: nil} = state), do: state

  defp proxy_output(state) do
    %{state | proxy: %{state.proxy | "lines" => Proxy.status()["lines"]}}
  catch
    :exit, _ -> state
  end

  defp schedule(%{timer: nil} = state) do
    token = make_ref()
    %{state | timer: Process.send_after(self(), {:drain, token}, next_ms(state)), drain: token}
  end

  defp schedule(state), do: state

  defp soon(%{timer: nil} = state), do: state

  defp soon(state) do
    Process.cancel_timer(state.timer)
    schedule(%{state | timer: nil})
  end

  # The one timer: every `drain_ms`, or every couple of seconds while a proxy that
  # runs has not answered yet.
  defp next_ms(state) do
    starting = mode(state) == "run" and state.proxy["state"] == "running" and not state.answering
    if starting, do: min(2_000, drain_ms()), else: drain_ms()
  end

  defp drain_ms,
    do: Keyword.get(Application.get_env(:hal_c2, :cliproxyapi, []), :drain_ms, @drain_ms)

  # --- provider instances ---

  defp save_ledger(state) do
    private(Path.join(state.dir, "providers.json"), JSON.encode!(state.ledger))
    state
  end

  # Connect settings that do not validate would send agents, and the client key, where
  # the check meant to keep them from: the plugin's instances leave until the settings
  # validate, and are put as new then. Those the user deleted stay deleted.
  defp sync(%{invalid: invalid} = state) when invalid != nil do
    case Host.provider_instances(@id, "list", %{}) do
      {:ok, %{"instances" => listed} = reply} ->
        present = MapSet.new(listed, & &1["name"])
        released = MapSet.new(reply["released"] || [])

        failed =
          Enum.reduce(listed, %{}, fn %{"name" => name}, failed ->
            case Host.provider_instances(@id, "remove", %{"name" => name}) do
              {:ok, _} -> failed
              {:error, message} -> Map.put(failed, name, message)
            end
          end)

        # A remove the host refused leaves its instance there, and its ledger entry
        # with it, so the page cannot call it not added. A created instance already
        # gone was the user's doing unless the host released it while the plugin was
        # off, so it stays deleted when the settings validate again.
        ledger =
          Enum.reduce(state.ledger, %{}, fn {name, entry}, ledger ->
            cond do
              entry["state"] == "dismissed" -> Map.put(ledger, name, entry)
              Map.has_key?(failed, name) -> Map.put(ledger, name, entry)
              name not in present and name not in released -> Map.put(ledger, name, %{"state" => "dismissed"})
              true -> ledger
            end
          end)

        changed? = ledger != state.ledger

        state = %{
          state
          | ledger: ledger,
            taken: failed,
            unlisted: nil,
            error: failed |> Map.values() |> List.first() || state.error
        }

        if changed?, do: save_ledger(state), else: state

      {:error, message} ->
        %{state | error: message, unlisted: message}
    end
  end

  defp sync(state) do
    case Host.provider_instances(@id, "list", %{}) do
      {:ok, %{"instances" => listed} = reply} ->
        current = Map.new(listed, &{&1["name"], &1["instance"]})
        released = reply["released"] || []

        {ledger, taken} =
          Enum.reduce(Instances.names(), {state.ledger, state.taken}, fn name, {ledger, taken} ->
            desired =
              Instances.desired(name, base(state), state.client, Path.join(state.dir, "claude"))

            case Instances.decide(ledger[name], current[name], desired, name in released) do
              :keep ->
                {ledger, Map.delete(taken, name)}

              :dismiss ->
                {Map.put(ledger, name, %{"state" => "dismissed"}), Map.delete(taken, name)}

              {:put, instance} ->
                case Host.provider_instances(@id, "put", %{"name" => name, "instance" => instance}) do
                  {:ok, _} ->
                    entry = %{"state" => "created", "digest" => Instances.digest(desired)}
                    {Map.put(ledger, name, entry), Map.delete(taken, name)}

                  {:error, message} ->
                    {ledger, Map.put(taken, name, message)}
                end
            end
          end)

        changed? = ledger != state.ledger
        state = %{state | ledger: ledger, taken: taken, unlisted: nil}
        if changed?, do: save_ledger(state), else: state

      {:error, message} ->
        %{state | error: message, unlisted: message}
    end
  end

  # --- topics ---

  defp publish(state) do
    views = %{
      "status" => status(state),
      "accounts" => %{"accounts" => state.accounts, "signIn" => state.sign_in},
      "usage" => %{"rows" => usage_rows(state), "days" => @usage_days, "note" => state.usage_note},
      "logs" => %{"lines" => state.logs},
      "keys" => %{"keys" => state.keys}
    }

    Enum.reduce(views, state, fn {topic, value}, state ->
      if state.published[topic] == value do
        state
      else
        Host.publish(@id, topic, value)
        %{state | published: Map.put(state.published, topic, value)}
      end
    end)
  end

  defp view(state) do
    %{
      "status" => status(state),
      "accounts" => state.accounts,
      "signIn" => state.sign_in,
      "usage" => usage_rows(state),
      "usageNote" => state.usage_note,
      "logs" => state.logs,
      "keys" => state.keys
    }
  end

  defp usage_rows(state) do
    labels = Map.new(state.accounts, &{&1["id"], &1["email"] || &1["name"]})
    Usage.rows(state.usage, Date.utc_today(), @usage_days, labels)
  end

  defp status(state) do
    {phase, message} = phase(state)

    %{
      "mode" => mode(state),
      "state" => phase,
      "message" => message,
      "pid" => state.proxy["pid"],
      "restarts" => state.proxy["restarts"],
      "output" => Enum.take(state.proxy["lines"] || [], -5),
      # Only the binary the plugin downloads is known to be the release it pins; one
      # from the settings or PATH is whatever the user put there.
      "version" => if(state.source == "download", do: Release.version()),
      "pinned" => Release.version(),
      "latest" => newer(state.latest),
      "binary" => state.binary,
      "source" => state.source,
      "address" => base(state),
      "error" => state.error,
      "instances" =>
        for name <- Instances.names() do
          %{
            "name" => name,
            "instanceId" => "plugin_#{@id}_#{name}",
            "label" => Instances.label(name),
            "state" =>
              cond do
                state.ledger[name]["state"] == "dismissed" -> "dismissed"
                state.invalid -> "withheld"
                state.unlisted -> "unknown"
                Map.has_key?(state.taken, name) -> "taken"
                state.ledger[name]["state"] == "created" -> "added"
                true -> "unknown"
              end,
            "message" =>
              if(state.ledger[name]["state"] != "dismissed",
                do: state.invalid || state.unlisted || state.taken[name]
              )
          }
        end
    }
  end

  defp phase(state) do
    cond do
      state.blocked ->
        {"blocked", "The proxy refused the management key: #{state.blocked}"}

      # A download and its failure are Run's: one left running when the user switched
      # to Connect does not stand for the proxy they connect to.
      mode(state) == "run" and state.download ->
        {"downloading", "Downloading CLIProxyAPI #{Release.version()}…"}

      mode(state) == "run" and state.failure ->
        {"failed", state.failure}

      mode(state) == "connect" and state.invalid ->
        {"failed", state.invalid}

      mode(state) == "connect" and state.unreachable ->
        {"unreachable", state.unreachable}

      mode(state) == "connect" and state.answering ->
        {"connected", nil}

      mode(state) == "connect" ->
        {"connecting", nil}

      state.proxy["state"] == "restarting" ->
        {"restarting", exited(state.proxy)}

      state.proxy["state"] == "failed" ->
        {"failed", List.last(state.proxy["lines"] || []) || "The proxy did not start."}

      state.proxy["state"] == "running" and state.answering ->
        {"running", nil}

      state.proxy["state"] == "running" ->
        {"starting", nil}

      true ->
        {"stopped", nil}
    end
  end

  defp newer(latest) when is_binary(latest) do
    with {:ok, latest} <- Version.parse(String.trim_leading(latest, "v")),
         :gt <- Version.compare(latest, Version.parse!(Release.version())) do
      to_string(latest)
    else
      _ -> nil
    end
  end

  defp newer(_latest), do: nil

  defp exited(proxy) do
    last = List.last(proxy["lines"] || [])

    "The proxy exited (#{proxy["code"]})#{if last, do: ": " <> last, else: ""}; it starts again in #{div(proxy["retryInMs"] || 1000, 1000)}s."
  end

  # --- settings and files ---

  defp mode(state), do: if(state.settings["mode"] == "connect", do: "connect", else: "run")
  defp port(state), do: state.settings["port"] || 8317

  defp base(state) do
    case mode(state) do
      "connect" -> String.trim_trailing(String.trim(state.settings["url"] || ""), "/")
      "run" -> "http://127.0.0.1:#{port(state)}"
    end
  end

  defp conn(state) do
    key =
      if mode(state) == "connect",
        do: String.trim(state.settings["managementKey"] || ""),
        else: state.management

    %{base: base(state), key: key}
  end

  defp https?(url), do: URI.parse(url).scheme == "https"

  defp loopback?(url) do
    case URI.parse(url).host do
      "localhost" ->
        true

      host when is_binary(host) ->
        case :inet.parse_address(to_charlist(host)) do
          {:ok, {127, _, _, _}} -> true
          {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp suffixed?(url) do
    %URI{query: query, fragment: fragment} = URI.parse(url)
    query != nil or fragment != nil
  end

  defp address?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp secret(dir, name, prefix) do
    path = Path.join(dir, name)

    case File.read(path) do
      {:ok, text} when byte_size(text) > 16 ->
        String.trim(text)

      _ ->
        value = prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        private(path, value)
        value
    end
  end

  # Written only after the file is the user's alone.
  defp private(path, contents) do
    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.write!(path, contents)
  end

  defp read_json(dir, name, default) do
    with {:ok, text} <- File.read(Path.join(dir, name)),
         {:ok, value} <- JSON.decode(text) do
      value
    else
      _ -> default
    end
  end
end
