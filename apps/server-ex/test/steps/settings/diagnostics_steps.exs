defmodule HalC2.Steps.Settings.Diagnostics do
  @moduledoc """
  Settings → Diagnostics against an MC: the process list, resource history and
  signals (`HalC2.Diagnostics`). The provider session is a copy of `sleep` named
  `codex`, started as a port so its exit status shows the signal it got; the
  terminal is a real `HalC2.Terminal` shell.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @windows %{"5 minutes" => 5 * 60_000, "1 hour" => 60 * 60_000}
  @signals %{"SIGINT" => 2, "SIGKILL" => 9}

  step "an MC running a provider session and a terminal", context do
    home = context.mc.home
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    codex = Path.join(bin, "codex")
    File.cp!("/usr/bin/sleep", codex)
    port = Port.open({:spawn_executable, codex}, [:binary, :exit_status, args: ["60"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
    end)

    shell = World.open_terminal("thread-1", home)

    Mc.ensure(HalC2.Diagnostics)

    context
    |> World.put_client("default", World.client(context))
    |> Map.merge(%{provider: %{port: port, pid: pid}, shell: shell})
  end

  step "each process shows its id, CPU, memory and command", context do
    {:ok, %{"processes" => processes}} = context.reply

    for pid <- [context.provider.pid, context.shell] do
      assert %{"cpuPercent" => cpu, "rssBytes" => rss, "command" => command} =
               Enum.find(processes, &(&1["pid"] == pid)),
             "process #{pid} is not listed in #{inspect(processes)}"

      assert is_number(cpu) and rss > 0 and command != ""
    end

    assert Enum.find(processes, &(&1["pid"] == context.provider.pid))["command"] =~ "codex 60"
    context
  end

  # A sample from 10 minutes ago with the MC at an impossible 100000% CPU sets
  # the one-hour window apart from the five-minute one.
  step ~r/^the user views the last (?<window>5 minutes|1 hour) of resource history$/,
       %{args: [window]} = context do
    World.add_resource_samples([10 * 60_000], 100_000.0)
    window = Map.fetch!(@windows, window)
    {reply, context} = history(context, window)
    Map.merge(context, %{reply: reply, window: window})
  end

  step "the history shows average and peak CPU for that window", context do
    {:ok, %{"windowMs" => window, "buckets" => buckets, "topProcesses" => top}} = context.reply
    assert window == context.window
    assert buckets != []

    for bucket <- buckets do
      assert bucket["avgCpuPercent"] <= bucket["maxCpuPercent"]
    end

    peak = buckets |> Enum.map(& &1["maxCpuPercent"]) |> Enum.max()
    # A bucket sums the whole tree, so the child shell's own CPU can add to the peak.
    if context.window > 10 * 60_000, do: assert(peak >= 100_000.0), else: assert(peak < 100_000.0)

    assert %{"avgCpuPercent" => avg, "maxCpuPercent" => max} =
             Enum.find(top, &(&1["depth"] == 0))

    assert avg <= max
    context
  end

  step "the MC collected an hour of history", context do
    World.add_resource_samples(Enum.map(1..239, &(&1 * 15_000)))
    {{:ok, %{"retainedSampleCount" => count}}, context} = history(context, 60 * 60_000)
    assert count >= 240
    Map.put(context, :restarted_at, System.system_time(:millisecond))
  end

  step "the history is empty", context do
    {{:ok, history}, context} = history(context, 60 * 60_000)
    # Only what the fresh sampler took since starting again.
    assert history["retainedSampleCount"] <= 1

    for bucket <- history["buckets"] do
      {:ok, ended, _} = DateTime.from_iso8601(bucket["endedAt"])
      assert DateTime.to_unix(ended, :millisecond) >= context.restarted_at
    end

    context
  end

  step ~r/^the user sends (?<signal>SIGINT|SIGKILL) to the provider process$/,
       %{args: [signal]} = context do
    {:ok, %{"processes" => processes}} = processes(context)
    seen = Enum.find(processes, &(&1["pid"] == context.provider.pid))
    signal(context, seen["pid"], seen["startTimeMs"], signal)
  end

  step ~r/^the process receives (?<signal>SIGINT|SIGKILL)$/, %{args: [signal]} = context do
    assert {:ok, %{"signaled" => true}} = context.reply
    port = context.provider.port
    status = 128 + Map.fetch!(@signals, signal)
    assert_receive {^port, {:exit_status, ^status}}, 2_000
    context
  end

  step "the user signals a process the MC did not start", context do
    signal(context, 1, 0, "SIGTERM")
  end

  step "the user signals the MC itself", context do
    {:ok, %{"serverPid" => pid, "processes" => processes}} = processes(context)
    signal(context, pid, Enum.find(processes, &(&1["pid"] == pid))["startTimeMs"], "SIGTERM")
  end

  # The id is the provider's, but the start time is not: the process a client saw
  # is gone and another now has its id.
  step "the user signals a process that exited and whose id was reused", context do
    {:ok, %{"processes" => processes}} = processes(context)
    seen = Enum.find(processes, &(&1["pid"] == context.provider.pid))
    context = signal(context, seen["pid"], seen["startTimeMs"] - 60_000, "SIGKILL")
    assert Port.info(context.provider.port) != nil
    context
  end

  step "the user asks for trace diagnostics", context do
    {reply, context} = World.call(context, "server.getTraceDiagnostics")
    Map.put(context, :reply, reply)
  end

  step "the MC recorded failing and slow spans", context do
    now = System.system_time(:nanosecond)

    post_traces(context, [
      span("orchestration.dispatch", now - 9_000_000_000, 40, {2, "ThreadNotFound"}),
      span("orchestration.dispatch", now - 5_000_000_000, 60, {2, "ThreadNotFound"}),
      span("git.status", now - 4_000_000_000, 2_500),
      span("provider.start", now - 1_000_000_000, 30, {2, "ProviderUnavailable"}),
      span("git.status", now - 500_000_000, 20)
    ])

    context
  end

  step "the latest failures, most common failures and slowest spans are listed", context do
    assert {:ok, traces} = context.reply
    assert traces["error"] == %{"_tag" => "None"}
    assert traces["recordCount"] == 5 and traces["failureCount"] == 3

    assert [%{"name" => "provider.start", "cause" => "ProviderUnavailable"}, second, third] =
             traces["latestFailures"]

    assert second["endedAt"] > third["endedAt"]

    assert [%{"name" => "orchestration.dispatch", "cause" => "ThreadNotFound", "count" => 2} | _] =
             traces["commonFailures"]

    assert [%{"name" => "git.status", "durationMs" => 2_500.0} | _] = traces["slowestSpans"]
    assert traces["slowSpanCount"] == 1
    context
  end

  step "a client sends its traces to the MC", context do
    now = System.system_time(:nanosecond)
    post_traces(context, [span("web.thread.render", now - 100_000_000, 12)])
    context
  end

  step "the MC records them in its trace file", context do
    [line] = File.read!(HalC2.Traces.path()) |> String.split("\n", trim: true)

    assert %{"type" => "otlp-span", "name" => "web.thread.render", "durationMs" => 12.0} =
             JSON.decode!(line)

    {{:ok, traces}, context} = World.call(context, "server.getTraceDiagnostics")
    assert [%{"name" => "web.thread.render", "count" => 1}] = traces["topSpansByCount"]
    context
  end

  # An OTLP JSON span that ended `ms` after `start` (unix ns), failing with `{code, message}`.
  defp span(name, start, ms, status \\ {1, nil}) do
    {code, message} = status

    %{
      "traceId" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "spanId" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      "name" => name,
      "kind" => 1,
      "startTimeUnixNano" => "#{start}",
      "endTimeUnixNano" => "#{start + ms * 1_000_000}",
      "attributes" => [%{"key" => "hal-c2.client", "value" => %{"stringValue" => "web"}}],
      "events" => [],
      "links" => [],
      "status" => %{"code" => code, "message" => message}
    }
  end

  # Posts spans as a client's OTLP exporter does, with a paired client's token.
  # The MC keeps client spans only while tracing is on (`HalC2.Traces.enabled?/0`).
  defp post_traces(context, spans) do
    World.put_app_env(:trace, true)

    {:ok, access, _expires, _scopes} =
      HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(context.mc.store), %{"label" => "Web"})

    body =
      JSON.encode!(%{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.name", "value" => %{"stringValue" => "hal-c2-web"}}
              ]
            },
            "scopeSpans" => [%{"scope" => %{"name" => "hal_c2"}, "spans" => spans}]
          }
        ]
      })

    {:ok, _} = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{context.mc.port}/api/observability/v1/traces"
    headers = [{~c"authorization", ~c"Bearer #{access}"}]

    assert {:ok, {{_, 204, _}, _, _}} =
             :httpc.request(:post, {url, headers, ~c"application/json", body}, [], [])
  end

  defp processes(context) do
    {reply, _} = World.call(context, "server.getProcessDiagnostics")
    reply
  end

  defp history(context, window) do
    World.call(context, "server.getResourceTelemetryHistory", %{
      "windowMs" => window,
      "bucketMs" => 60_000
    })
  end

  defp signal(context, pid, started, signal) do
    {reply, context} =
      World.call(context, "server.signalProcess", %{
        "pid" => pid,
        "startTimeMs" => started,
        "signal" => signal
      })

    Map.put(context, :reply, reply)
  end
end
