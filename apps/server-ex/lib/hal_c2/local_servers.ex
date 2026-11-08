defmodule HalC2.LocalServers do
  @moduledoc """
  Web servers listening on this host (`subscribeDiscoveredLocalServers`), for the
  preview panel's suggestions. While anyone watches, `lsof` lists listening TCP
  ports every few seconds and each new one is asked for a page; those answering
  with HTML are the list. Watchers get `{:hal_c2_local_servers, mc, list}` when it
  changes.
  """

  use GenServer

  @interval 3_000
  @probe_timeout 1_000
  # A probe's answer, a failed one included, is reused this long.
  @cache_ttl 15_000
  @configured_max 32
  @url_max 2_048
  @local_hosts ["localhost", "127.0.0.1", "[::1]", "::1", "0.0.0.0", "[::]", "::"]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Watches the list under `ref` (nil for none). The arity every MC has.
  """
  def subscribe(pid, ref \\ nil), do: subscribe_urls(pid, [], ref)

  @doc """
  `subscribe/2` for a client that names its configured preview addresses: the ones on
  this machine are asked for a page as written and join that client's list. A separate
  function so `subscribe(pid, ref)` keeps its meaning for a cluster member that is
  still on the older code.
  """
  def subscribe_urls(pid, urls, ref \\ nil),
    do: GenServer.call(__MODULE__, {:subscribe, pid, List.wrap(urls), ref})

  def unsubscribe(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unsubscribe, pid, ref})

  @impl true
  def init(nil) do
    # Its own HTTP client profile, which also reaches servers bound to IPv6 only.
    case :inets.start(:httpc, profile: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok = :httpc.set_options([ipfamily: :inet6fb4], __MODULE__)
    {:ok, fresh()}
  end

  # `configured` is `%{pid => %{ref => urls}}`, `sent` what each watcher was last told.
  defp fresh,
    do: %{watchers: %{}, configured: %{}, base: nil, cache: %{}, sent: %{}, timer: nil}

  # Answers from what the last scan found; the addresses it has not asked yet are
  # probed by a scan started at once, whose result reaches the watcher as a change.
  @impl true
  def handle_call({:subscribe, pid, urls, ref}, _from, state) do
    urls = if is_list(urls), do: urls, else: []
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)

    configured =
      Map.update(state.configured, pid, %{ref => urls}, &Map.put(&1, ref, urls))

    state = %{state | watchers: watchers, configured: configured}
    {:reply, {:ok, list_for(state, pid)}, scan_soon(remember(state, pid))}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state) do
    watchers = HalC2.Watchers.remove(state.watchers, pid, ref)
    state = %{state | watchers: watchers}

    state =
      case state.configured do
        %{^pid => refs} when is_map_key(watchers, pid) ->
          %{state | configured: Map.put(state.configured, pid, Map.delete(refs, ref))}

        _ ->
          forget(state, pid)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:scan, state) do
    state = %{state | timer: nil}

    if state.watchers == %{} do
      {:noreply, fresh()}
    else
      state = scan(state)

      state =
        Enum.reduce(state.watchers, state, fn {pid, entry}, state ->
          list = list_for(state, pid)

          if list["servers"] != state.sent[pid] do
            HalC2.Watchers.tell(pid, entry, {:hal_c2_local_servers, node(), list})
            remember(state, pid)
          else
            state
          end
        end)

      {:noreply, schedule(state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, forget(%{state | watchers: Map.delete(state.watchers, pid)}, pid)}

  defp forget(state, pid),
    do: %{
      state
      | configured: Map.delete(state.configured, pid),
        sent: Map.delete(state.sent, pid)
    }

  defp remember(state, pid),
    do: %{state | sent: Map.put(state.sent, pid, list_for(state, pid)["servers"])}

  # A scan now, in place of the one a few seconds off.
  defp scan_soon(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :scan, 0)}
  end

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :scan, @interval)}

  defp schedule(state), do: state

  # What `pid` is told: the listeners found, and the configured addresses of its own
  # that serve a page. A configured address stands for the listener on its port.
  defp list_for(state, pid) do
    configured =
      for url <- configured_urls(state, pid), match?({true, _}, state.cache[{:url, url}]) do
        server(url)
      end

    ports = MapSet.new(configured, & &1["port"])
    base = state.base || %{"servers" => [], "scannedAt" => nil}

    servers =
      (Enum.reject(base["servers"], &(&1["port"] in ports)) ++ configured)
      |> Enum.uniq_by(& &1["url"])
      |> Enum.sort_by(& &1["port"])

    list = %{"servers" => servers, "scannedAt" => base["scannedAt"]}

    if configured_urls(state, pid) == [],
      do: list,
      else: Map.put(list, "configuredUrlProbing", true)
  end

  # The local web addresses `pid` named, rewritten to be asked, the first 32 of them.
  defp configured_urls(state, pid) do
    state.configured
    |> Map.get(pid, %{})
    |> Map.values()
    |> Enum.flat_map(&Enum.take(&1, @configured_max))
    |> Enum.flat_map(&local_url/1)
    |> Enum.uniq()
    |> Enum.take(@configured_max)
  end

  # `url` as it is asked and suggested: an address on every interface becomes localhost.
  defp local_url(url) when is_binary(url) do
    with {:ok, %URI{scheme: scheme, host: host} = uri} <- URI.new(url),
         true <- scheme in ["http", "https"] and host in @local_hosts do
      rewritten =
        if host in ["0.0.0.0", "[::]", "::"],
          do:
            uri |> Map.put(:host, "localhost") |> Map.update!(:path, &(&1 || "/")) |> to_string(),
          else: url

      if String.length(rewritten) <= @url_max, do: [rewritten], else: []
    else
      _ -> []
    end
  end

  defp local_url(_), do: []

  defp server(url) do
    %URI{host: host, port: port} = URI.parse(url)

    %{
      "host" => host,
      "port" => port,
      "url" => url,
      "processName" => nil,
      "pid" => nil,
      "terminal" => nil
    }
  end

  defp scan(state) do
    # `:local_servers_skew` moves the clock for the cache's sake in tests.
    now =
      System.monotonic_time(:millisecond) + Application.get_env(:hal_c2, :local_servers_skew, 0)

    listeners = listeners()
    urls = state.configured |> Map.keys() |> Enum.flat_map(&configured_urls(state, &1))

    # An answer is reused while fresh; the rest is asked at once.
    cache = Map.reject(state.cache, fn {_, {_, at}} -> now - at >= @cache_ttl end)

    asked =
      Enum.map(listeners, &{:listener, &1}) ++ Enum.map(Enum.uniq(urls), &{:url, &1})

    cache =
      asked
      |> Enum.reject(&Map.has_key?(cache, key_of(&1)))
      |> Task.async_stream(fn target -> {key_of(target), ask(target)} end,
        timeout: @probe_timeout * 4,
        on_timeout: :kill_task
      )
      |> Enum.reduce(cache, fn
        {:ok, {key, answer}}, cache -> Map.put(cache, key, {answer, now})
        _, cache -> cache
      end)

    servers =
      for {port, pid, name, _} = key <- listeners,
          {scheme, _} when is_binary(scheme) <- [cache[{:listener, key}]] do
        %{
          "host" => "localhost",
          "port" => port,
          "url" => "#{scheme}://localhost:#{port}",
          "processName" => name,
          "pid" => pid,
          "terminal" => nil
        }
      end
      |> Enum.sort_by(& &1["port"])

    %{state | cache: cache, base: %{"servers" => servers, "scannedAt" => now()}}
  end

  defp key_of({:listener, key}), do: {:listener, key}
  defp key_of({:url, url}), do: {:url, url}

  # The scheme a listener answers on, or false; whether a configured address serves a page.
  defp ask(target) do
    case Application.get_env(:hal_c2, :local_servers_probe) do
      nil -> probe(target)
      stub -> stub.(target)
    end
  end

  defp probe({:listener, {port, _, _, ipv6}}), do: probe_listener(port, ipv6)
  defp probe({:url, url}), do: web_page?(url)

  # A listener is asked over plain HTTP, then over HTTPS unless it did not answer at all.
  defp probe_listener(port, ipv6) do
    host = if ipv6, do: "[::1]", else: "127.0.0.1"

    case request("http://#{host}:#{port}/") do
      true -> "http"
      :timeout -> false
      false -> if request("https://#{host}:#{port}/") == true, do: "https", else: false
    end
  end

  defp web_page?(url), do: request(url) == true

  # `{port, pid, command, ipv6_only}` for every loopback or wildcard TCP listener.
  defp listeners do
    case Application.get_env(:hal_c2, :local_servers_listeners) do
      nil -> lsof_listeners()
      stub -> stub
    end
  end

  defp lsof_listeners do
    with path when is_binary(path) <- System.find_executable("lsof"),
         {out, _} <-
           System.cmd(path, ~w(-iTCP -sTCP:LISTEN -P -n -F pcn), stderr_to_stdout: false) do
      out
      |> String.split("\n", trim: true)
      |> Enum.reduce({nil, nil, []}, fn
        "p" <> pid, {_, _, acc} -> {String.to_integer(pid), nil, acc}
        "c" <> name, {pid, _, acc} -> {pid, name, acc}
        "n" <> address, {pid, name, acc} -> {pid, name, [{address, pid, name} | acc]}
        _, acc -> acc
      end)
      |> elem(2)
      |> Enum.flat_map(fn {address, pid, name} ->
        case Regex.run(~r/^(\*|127\.0\.0\.1|\[::1\]|\[::\]|localhost):(\d+)$/, address) do
          [_, _host, port] -> [{String.to_integer(port), pid, name, ipv6?(address)}]
          _ -> []
        end
      end)
      # This MC's own port is not a suggestion.
      |> Enum.reject(fn {port, _, _, _} -> port == Application.get_env(:hal_c2, :port, 3780) end)
      |> Enum.group_by(&elem(&1, 0))
      # A port bound on both stacks is asked over IPv4.
      |> Enum.map(fn {port, [{_, pid, name, _} | _] = entries} ->
        {port, pid, name, Enum.all?(entries, &elem(&1, 3))}
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp ipv6?(address), do: String.starts_with?(address, "[")

  # Whether `url` answers with a page: HTML, or any redirect. `:timeout` when it said
  # nothing within the probe's second.
  defp request(url) do
    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [timeout: @probe_timeout, autoredirect: false, ssl: [verify: :verify_none]],
           [ipv6_host_with_brackets: true],
           __MODULE__
         ) do
      {:ok, {{_, status, _}, headers, _}} when status in 200..399 and status not in [204, 205] ->
        status >= 300 or
          Enum.any?(headers, fn {key, value} ->
            key == ~c"content-type" and String.contains?(to_string(value), "html")
          end)

      {:error, :timeout} ->
        :timeout

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    # A handler crashing on what the listener answered (a TLS alert, say).
    :exit, _ -> false
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
