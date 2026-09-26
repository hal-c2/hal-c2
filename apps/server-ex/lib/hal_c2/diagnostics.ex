defmodule HalC2.Diagnostics do
  @moduledoc """
  What the node and the processes it started are doing (Settings → Diagnostics).

  A sampler reads the process tree under the node with `ps`: every 15 seconds,
  or every 2 while a client watches the resource monitor. It keeps an hour of
  samples. From those come the process list (`server.getProcessDiagnostics`),
  the resource monitor's live snapshots and timeline (`subscribeResourceTelemetry`,
  `server.getResourceTelemetryHistory`) and the process history
  (`server.getProcessResourceHistory`). `server.signalProcess` only signals a
  process under the node that is still the one a client saw. I/O comes from
  `/proc/<pid>/io` (storage bytes) where the platform has it, and is reported as
  unavailable elsewhere. Traces are recorded only while `HalC2.Traces` is on, and
  there is no desktop host to supply power state.

  Watchers get `{:hal_c2_resource_telemetry, node, snapshot}` after every sample.
  """

  use GenServer

  @idle_every 15_000
  @watched_every 2_000
  @keep :timer.hours(1)
  @providers ~w(codex claude opencode grok cursor-agent pi-acp node devin gemini)
  @shells ~w(zsh bash fish sh nu)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`server.getProcessDiagnostics`."
  def processes(_input \\ %{}) do
    root = os_pid()
    base = %{"serverPid" => root, "readAt" => now()}

    case tree(root) do
      {:ok, rows} ->
        {:ok,
         Map.merge(base, %{
           "processCount" => length(rows),
           "totalRssBytes" => rows |> Enum.map(& &1.rss) |> Enum.sum(),
           "totalCpuPercent" => rows |> Enum.map(& &1.cpu) |> Enum.sum(),
           "processes" => Enum.map(rows, &diagnostics_entry/1),
           "error" => none()
         })}

      {:error, message} ->
        {:ok,
         Map.merge(base, %{
           "processCount" => 0,
           "totalRssBytes" => 0,
           "totalCpuPercent" => 0,
           "processes" => [],
           "error" => some(%{"message" => message})
         })}
    end
  end

  @doc "`server.signalProcess`: only a process under this node, and only the one that was seen."
  def signal(%{"pid" => pid, "startTimeMs" => started, "signal" => signal}) do
    result = %{"pid" => pid, "signal" => signal}

    with {:ok, rows} <- tree(os_pid()),
         %{started: seen} <- Enum.find(rows, &(&1.pid == pid)) || :not_ours,
         true <- pid != os_pid() || :server,
         true <- abs(seen - started) < 2_000 || :replaced,
         {_, 0} <-
           System.cmd("kill", ["-#{String.trim_leading(signal, "SIG")}", "#{pid}"],
             stderr_to_stdout: true
           ) do
      {:ok, Map.merge(result, %{"signaled" => true, "message" => none()})}
    else
      reason ->
        message =
          case reason do
            :not_ours -> "That process is not one this node started."
            :server -> "The node itself cannot be signalled from here."
            :replaced -> "That process has already exited."
            {:error, message} -> message
            {out, _} -> String.trim(out)
          end

        {:ok, Map.merge(result, %{"signaled" => false, "message" => some(message)})}
    end
  end

  @doc "`server.getTraceDiagnostics`: the trace files while tracing is on (`HalC2.Traces`)."
  def traces(_input \\ %{}) do
    if HalC2.Traces.enabled?(), do: {:ok, HalC2.Traces.diagnostics()}, else: {:ok, untraced()}
  end

  defp untraced do
    %{
      "traceFilePath" =>
        Path.join([Application.fetch_env!(:hal_c2, :home), "logs", "server.trace.ndjson"]),
      "scannedFilePaths" => [],
      "readAt" => now(),
      "recordCount" => 0,
      "parseErrorCount" => 0,
      "firstSpanAt" => none(),
      "lastSpanAt" => none(),
      "failureCount" => 0,
      "interruptionCount" => 0,
      "slowSpanThresholdMs" => 1_000,
      "slowSpanCount" => 0,
      "logLevelCounts" => %{},
      "topSpansByCount" => [],
      "slowestSpans" => [],
      "commonFailures" => [],
      "latestFailures" => [],
      "latestWarningAndErrorLogs" => [],
      "partialFailure" => none(),
      "error" =>
        some(%{
          "kind" => "trace-file-not-found",
          "message" => "This node does not record traces."
        })
    }
  end

  @doc "`server.getHostResources`: CPU use comes from two readings of the CPU counters 200ms apart."
  def host(_input \\ %{}) do
    {total, available} = memory()
    cpu = cpu_utilization()

    {:ok,
     %{
       "sampledAt" => System.system_time(:millisecond),
       "cpuUtilization" => cpu,
       "cpuCount" =>
         case :erlang.system_info(:logical_processors) do
           count when is_integer(count) -> count
           _ -> System.schedulers_online()
         end,
       "availableMemoryBytes" => available,
       "totalMemoryBytes" => total
     }}
  end

  @doc "`server.getProcessResourceHistory`."
  def history(%{"windowMs" => window, "bucketMs" => bucket}),
    do: {:ok, GenServer.call(__MODULE__, {:history, :process, window, bucket})}

  @doc "`server.getResourceTelemetryHistory`."
  def telemetry_history(%{"windowMs" => window, "bucketMs" => bucket}),
    do: {:ok, GenServer.call(__MODULE__, {:history, :telemetry, window, bucket})}

  @doc "`server.retryResourceTelemetry`: samples now."
  def retry(_input \\ %{}),
    do: {:ok, %{"accepted" => true, "snapshot" => GenServer.call(__MODULE__, :sample_now)}}

  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  # --- sampler -----------------------------------------------------------------

  @impl true
  def init(nil) do
    send(self(), :sample)
    {:ok, %{samples: [], watchers: %{}, timer: nil}}
  end

  @impl true
  def handle_call(:sample_now, _from, state) do
    state = sample(state)
    {:reply, snapshot(state), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    state = sample(%{state | watchers: watchers})
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:history, kind, window, bucket}, _from, state) do
    at = System.system_time(:millisecond)
    samples = state.samples |> Enum.filter(fn {t, _} -> at - t <= window end) |> Enum.reverse()
    {:reply, history(kind, samples, window, max(bucket, interval(state)), state), state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info(:sample, state) do
    state = sample(%{state | timer: nil})
    snapshot = if state.watchers != %{}, do: snapshot(state)
    for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_resource_telemetry, node(), snapshot})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  defp sample(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    at = System.system_time(:millisecond)

    samples =
      case tree(os_pid()) do
        {:ok, rows} -> [{at, rows} | state.samples]
        _ -> state.samples
      end

    %{
      state
      | samples: Enum.take_while(samples, fn {t, _} -> at - t <= @keep end),
        timer: Process.send_after(self(), :sample, interval(state))
    }
  end

  defp interval(state), do: if(state.watchers == %{}, do: @idle_every, else: @watched_every)

  # --- telemetry ---------------------------------------------------------------

  # `ResourceTelemetrySnapshot` from the latest sample.
  defp snapshot(state) do
    {at, rows} = List.first(state.samples, {System.system_time(:millisecond), []})
    first_seen = first_seen(state.samples)

    previous = previous_sample(state.samples)

    processes =
      for row <- rows do
        {io_read, io_write, semantics} = io(row)
        {read_rate, write_rate} = io_rates(row, at, previous)

        %{
          "identity" => identity(row),
          "ppid" => row.ppid,
          "childPids" => row.children,
          "depth" => row.depth,
          "name" => row.name,
          "command" => row.command,
          "status" => row.stat,
          "category" => category(row),
          "cpuPercent" => row.cpu,
          "cpuTimeMs" => row.cpu_time,
          "residentBytes" => row.rss,
          "peakResidentBytes" => peak_rss(state.samples, key(row)),
          "virtualBytes" => row.vsz,
          "ioReadBytes" => io_read,
          "ioWriteBytes" => io_write,
          "ioReadBytesPerSecond" => read_rate,
          "ioWriteBytesPerSecond" => write_rate,
          "ioSemantics" => semantics,
          "runTimeMs" => max(at - row.started, 0),
          "firstSeenAt" => iso(Map.get(first_seen, key(row), at)),
          "lastSeenAt" => iso(at)
        }
      end

    backend = aggregate(rows, state.samples)
    empty = aggregate([], [])

    %{
      "readAt" => iso(at),
      "sampleIntervalMs" => interval(state),
      "processes" => processes,
      "groups" => %{
        "backend" => backend,
        "electron" => empty,
        "monitor" => empty,
        "allHalC2" => backend
      },
      "power" => power(),
      "speedLimitPercent" => none(),
      "attribution" => %{"readAt" => iso(at), "entries" => []},
      "health" => health(state, length(rows))
    }
  end

  defp aggregate(rows, samples) do
    %{
      "processCount" => length(rows),
      "currentCpuPercent" => rows |> Enum.map(& &1.cpu) |> Enum.sum(),
      "cpuTimeMs" => rows |> Enum.map(& &1.cpu_time) |> Enum.sum(),
      "currentRssBytes" => rows |> Enum.map(& &1.rss) |> Enum.sum(),
      "peakRssBytes" =>
        samples
        |> Enum.map(fn {_, rows} -> rows |> Enum.map(& &1.rss) |> Enum.sum() end)
        |> Enum.max(fn -> 0 end),
      "ioReadBytes" => rows |> Enum.map(&elem(io(&1), 0)) |> Enum.sum(),
      "ioWriteBytes" => rows |> Enum.map(&elem(io(&1), 1)) |> Enum.sum(),
      "ioReadBytesPerSecond" => 0,
      "ioWriteBytesPerSecond" => 0,
      "processStarts" => 0,
      "processExits" => 0
    }
  end

  defp health(state, count) do
    %{
      "native" => %{
        "status" => if(state.samples == [], do: "starting", else: "healthy"),
        "lastSampleAt" =>
          case state.samples do
            [{at, _} | _] -> some(iso(at))
            [] -> none()
          end,
        "lastError" => none()
      },
      "desktop" => %{"status" => "unavailable", "lastSampleAt" => none(), "lastError" => none()},
      "sidecarVersion" => none(),
      "sidecarPid" => none(),
      "restartCount" => 0,
      "collectionDurationMicros" => 0,
      "scannedProcessCount" => count,
      "retainedProcessCount" => count,
      "inaccessibleProcessCount" => 0
    }
  end

  defp power do
    %{
      "source" => "unknown",
      "idle" => "unknown",
      "idleSeconds" => nil,
      "locked" => "unknown",
      "suspended" => false,
      "onBattery" => "unknown",
      "lowPowerMode" => "unknown",
      "thermalState" => "unknown",
      "stale" => true,
      "updatedAt" => now()
    }
  end

  defp category(%{depth: 0}), do: "server"

  defp category(row) do
    cond do
      row.name in @shells ->
        "terminal-root"

      Enum.any?(@providers, &(row.name == &1 or String.starts_with?(row.name, &1 <> "-"))) ->
        "provider-root"

      true ->
        "server-child"
    end
  end

  # --- history -----------------------------------------------------------------

  defp history(kind, samples, window, bucket, state) do
    buckets =
      samples
      |> Enum.group_by(fn {t, _} -> div(t, bucket) end)
      |> Enum.sort()
      |> Enum.map(fn {index, in_bucket} -> bucket(kind, index, bucket, in_bucket) end)

    root = os_pid()

    top =
      samples
      |> Enum.flat_map(fn {t, rows} -> Enum.map(rows, &{t, &1}) end)
      |> Enum.group_by(fn {_, row} -> key(row) end)
      |> Enum.map(fn {key, seen} ->
        {first, _} = hd(seen)
        {last, latest} = List.last(seen)
        cpu = Enum.map(seen, fn {_, row} -> row.cpu end)
        peak = seen |> Enum.map(fn {_, row} -> row.rss end) |> Enum.max()

        stats = %{
          "avgCpuPercent" => Enum.sum(cpu) / length(cpu),
          "maxCpuPercent" => Enum.max(cpu),
          "sampleCount" => length(seen)
        }

        {latest.cpu_time, summary(kind, key, latest, stats, {first, last, peak}, root)}
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(20)
      |> Enum.map(&elem(&1, 1))

    base = %{
      "readAt" => now(),
      "windowMs" => window,
      "bucketMs" => bucket,
      "sampleIntervalMs" => interval(state),
      "retainedSampleCount" => length(state.samples),
      "buckets" => buckets,
      "topProcesses" => top
    }

    case kind do
      :telemetry ->
        latest = samples |> List.last({0, []}) |> elem(1)
        Map.put(base, "health", health(state, length(latest)))

      :process ->
        Map.merge(base, %{
          "totalCpuSecondsApprox" => top |> Enum.map(& &1["cpuSecondsApprox"]) |> Enum.sum(),
          "error" => none()
        })
    end
  end

  defp bucket(kind, index, size, samples) do
    cpu = for {_, rows} <- samples, do: rows |> Enum.map(& &1.cpu) |> Enum.sum()

    %{
      "startedAt" => iso(index * size),
      "endedAt" => iso((index + 1) * size),
      "avgCpuPercent" => Enum.sum(cpu) / length(cpu),
      "maxCpuPercent" => Enum.max(cpu),
      "maxRssBytes" =>
        samples
        |> Enum.map(fn {_, rows} -> rows |> Enum.map(& &1.rss) |> Enum.sum() end)
        |> Enum.max(),
      "maxProcessCount" => samples |> Enum.map(fn {_, rows} -> length(rows) end) |> Enum.max()
    }
    |> then(
      &if(kind == :telemetry,
        do: Map.merge(&1, %{"ioReadBytes" => 0, "ioWriteBytes" => 0}),
        else: &1
      )
    )
  end

  defp summary(:telemetry, _key, row, stats, {first, last, peak}, _root) do
    Map.merge(stats, %{
      "identity" => identity(row),
      "ppid" => row.ppid,
      "depth" => row.depth,
      "name" => row.name,
      "command" => row.command,
      "category" => category(row),
      "firstSeenAt" => iso(first),
      "lastSeenAt" => iso(last),
      "currentCpuPercent" => row.cpu,
      "cpuTimeMs" => row.cpu_time,
      "currentRssBytes" => row.rss,
      "peakRssBytes" => peak,
      "ioReadBytes" => elem(io(row), 0),
      "ioWriteBytes" => elem(io(row), 1),
      "ioSemantics" => elem(io(row), 2)
    })
  end

  defp summary(:process, key, row, stats, {first, last, peak}, root) do
    Map.merge(stats, %{
      "processKey" => key,
      "pid" => row.pid,
      "ppid" => row.ppid,
      "command" => row.command,
      "depth" => row.depth,
      "isServerRoot" => row.pid == root,
      "firstSeenAt" => iso(first),
      "lastSeenAt" => iso(last),
      "currentCpuPercent" => row.cpu,
      "cpuSecondsApprox" => row.cpu_time / 1000,
      "currentRssBytes" => row.rss,
      "maxRssBytes" => peak
    })
  end

  defp first_seen(samples) do
    samples
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn {t, rows}, seen ->
      Enum.reduce(rows, seen, &Map.put_new(&2, key(&1), t))
    end)
  end

  defp peak_rss(samples, key) do
    for({_, rows} <- samples, row <- rows, key(row) == key, do: row.rss) |> Enum.max(fn -> 0 end)
  end

  defp key(row), do: "#{row.pid}:#{row.started}"

  # `{read, write, semantics}` for a sampled row; rows without counters read as unavailable.
  defp io(row) do
    case Map.get(row, :io) do
      {read, write} -> {read, write, "storage"}
      nil -> {0, 0, "unavailable"}
    end
  end

  defp previous_sample([_latest, {at, rows} | _]), do: {at, Map.new(rows, &{key(&1), &1})}
  defp previous_sample(_), do: nil

  defp io_rates(row, at, {before, rows}) when at > before do
    with {read, write} <- Map.get(row, :io),
         %{io: {read_before, write_before}} <- rows[key(row)] do
      per_second = &max(round((&1 - &2) * 1000 / (at - before)), 0)
      {per_second.(read, read_before), per_second.(write, write_before)}
    else
      _ -> {0, 0}
    end
  end

  defp io_rates(_row, _at, _previous), do: {0, 0}
  defp identity(row), do: %{"pid" => row.pid, "startTimeMs" => max(row.started, 0)}

  defp diagnostics_entry(row) do
    %{
      "pid" => row.pid,
      "startTimeMs" => max(row.started, 0),
      "ppid" => row.ppid,
      "pgid" => if(row.pgid, do: some(row.pgid), else: none()),
      "status" => row.stat,
      "cpuPercent" => row.cpu,
      "rssBytes" => row.rss,
      "elapsed" => row.etime,
      "command" => row.command,
      "depth" => row.depth,
      "childPids" => row.children
    }
  end

  # --- process tree --------------------------------------------------------------

  # Every process under `root`, root first, with its depth and children.
  defp tree(root) do
    ps = ~w(-axo pid=,ppid=,pgid=,stat=,%cpu=,rss=,vsz=,time=,etime=,lstart=,command=)

    case System.cmd("ps", ps, stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {out, 0} ->
        rows = for line <- String.split(out, "\n", trim: true), row = row(line), do: row
        children = Enum.group_by(rows, & &1.ppid)

        case Enum.find(rows, &(&1.pid == root)) do
          nil -> {:error, "The node's own process was not found."}
          row -> {:ok, row |> walk(0, children) |> Enum.map(&Map.put(&1, :io, proc_io(&1.pid)))}
        end

      {out, _} ->
        {:error, String.trim(out)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp row(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 15) do
      [pid, ppid, pgid, stat, cpu, rss, vsz, time, etime, _day, month, date, clock, year, command] ->
        command = if(command == "", do: "?", else: String.slice(command, 0, 500))

        %{
          pid: String.to_integer(pid),
          ppid: String.to_integer(ppid),
          pgid:
            case Integer.parse(pgid) do
              {pgid, _} -> pgid
              :error -> nil
            end,
          stat: stat,
          cpu: parse_float(cpu),
          rss: String.to_integer(rss) * 1024,
          vsz: String.to_integer(vsz) * 1024,
          cpu_time: cpu_time_ms(time),
          etime: etime,
          command: command,
          name: command |> String.split(" ") |> hd() |> Path.basename(),
          started: started_ms(month, date, clock, year)
        }

      _ ->
        nil
    end
  end

  defp walk(row, depth, children) do
    kids = Map.get(children, row.pid, [])
    row = Map.merge(row, %{depth: depth, children: Enum.map(kids, & &1.pid)})
    [row | Enum.flat_map(kids, &walk(&1, depth + 1, children))]
  end

  # Storage bytes from `/proc/<pid>/io` (Linux), or nil where there is none to read.
  defp proc_io(pid) do
    with {:ok, text} <-
           File.read(
             Path.join([Application.get_env(:hal_c2, :proc_dir, "/proc"), "#{pid}", "io"])
           ),
         [_, read] <- Regex.run(~r/^read_bytes:\s*(\d+)/m, text),
         [_, write] <- Regex.run(~r/^write_bytes:\s*(\d+)/m, text) do
      {String.to_integer(read), String.to_integer(write)}
    else
      _ -> nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # `ps` start time (`lstart`, local time, whole seconds) as unix ms.
  defp started_ms(month, date, clock, year) do
    [hour, minute, second] = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    month = Enum.find_index(@months, &(&1 == month)) + 1
    local = {{String.to_integer(year), month, String.to_integer(date)}, {hour, minute, second}}

    case :calendar.local_time_to_universal_time_dst(local) do
      [utc | _] -> (:calendar.datetime_to_gregorian_seconds(utc) - 62_167_219_200) * 1000
      [] -> 0
    end
  rescue
    _ -> 0
  end

  # `ps` cumulative CPU time: `[[dd-]hh:]mm:ss[.cc]`.
  defp cpu_time_ms(time) do
    {days, clock} =
      case String.split(time, "-") do
        [days, clock] -> {String.to_integer(days), clock}
        [clock] -> {0, clock}
      end

    seconds =
      clock
      |> String.split(":")
      |> Enum.map(&parse_float/1)
      |> Enum.reduce(0, &(&2 * 60 + &1))

    round((days * 86_400 + seconds) * 1000)
  rescue
    _ -> 0
  end

  defp parse_float(text) do
    case Float.parse(String.replace(text, ",", ".")) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  # Busy share of all CPUs (0..1) between two readings of /proc/stat; nil where there is none.
  defp cpu_utilization do
    with {:ok, {idle1, total1}} <- cpu_times(),
         :ok <- Process.sleep(200),
         {:ok, {idle2, total2}} <- cpu_times(),
         total when total > 0 <- total2 - total1,
         idle when idle >= 0 <- idle2 - idle1 do
      min(1.0, max(0.0, 1 - idle / total))
    else
      _ -> nil
    end
  end

  defp cpu_times do
    with {:ok, stat} <- File.read("/proc/stat"),
         ["cpu" <> _ | fields] <- stat |> String.split("\n", parts: 2) |> hd() |> String.split() do
      [user, nice, system, idle, iowait, irq, softirq, steal | _] =
        fields |> Enum.map(&String.to_integer/1) |> Kernel.++(List.duplicate(0, 8))

      {:ok, {idle + iowait, user + nice + system + idle + iowait + irq + softirq + steal}}
    else
      _ -> :error
    end
  end

  # Total and available memory, in bytes.
  defp memory do
    case :os.type() do
      {:unix, :darwin} ->
        page = sysctl("hw.pagesize")
        {out, _} = System.cmd("vm_stat", [])

        pages =
          for name <- ["Pages free", "Pages inactive", "Pages speculative"],
              [_, count] <- [Regex.run(~r/#{name}:\s+(\d+)/, out)],
              do: String.to_integer(count)

        {sysctl("hw.memsize"), Enum.sum(pages) * page}

      _ ->
        info = File.read!("/proc/meminfo")

        kb = fn key ->
          [value] = Regex.run(~r/#{key}:\s+(\d+)/, info, capture: :all_but_first)
          String.to_integer(value) * 1024
        end

        {kb.("MemTotal"), kb.("MemAvailable")}
    end
  rescue
    _ -> {0, 0}
  end

  defp sysctl(key) do
    {out, 0} = System.cmd("sysctl", ["-n", key])
    String.to_integer(String.trim(out))
  end

  defp os_pid, do: String.to_integer(System.pid())

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp some(value), do: %{"_tag" => "Some", "value" => value}
  defp none, do: %{"_tag" => "None"}
end
