Code.require_file("../../../../plugins/cliproxyapi/mc/usage.ex", __DIR__)
Code.require_file("../../../../plugins/cliproxyapi/mc/proxy.ex", __DIR__)

defmodule HalC2.CliProxyApiPropTest do
  @moduledoc """
  The CLIProxyAPI plugin's two stateful parts, in `plugins/cliproxyapi/mc`.

  Usage (`HalC2Plugins.CliProxyApi.Usage`): batches of usage records, well formed or
  not, added as the days pass. After every step it holds, for each day × account ×
  model of the last 30 days, the sums of the records that fall there and nothing
  else; so it never holds more rows than days × accounts × models, its rows are those
  sums newest day first, and what it writes to disk reads back as it was.

  The supervisor (`HalC2Plugins.CliProxyApi.Proxy`) as a state machine over the fake
  binary (`test/support/fake_cli_proxy_api.sh`): runs with one config or another, the
  same one again, halts, the proxy failing (and failing again while it waits to
  restart, as `run/1` and `halt/0` come in, or with its binary gone so the restart
  cannot start), and the MC dying with the proxy still up. After every step at most
  one of the processes it ever started still runs, the one its status and pidfile
  name; a failed proxy, or a restart that could not start, is started again after a
  backoff that doubles to its cap and starts over with a new config; a halted one
  stays down; and the proxy a dead MC left behind is stopped by the next run. Every
  wait is on a message the supervisor sends, never a sleep.

  The plugin process is not modelled here. What it decides is what the proxy's
  management API, the MC's settings and the host answer it, so a model of it would be
  a model of the fake proxy; `features/plugins/cliproxyapi.feature` drives it through
  each of those answers instead, and `HalC2Plugins.CliProxyApi.Instances`, the part
  that decides on its own, is plain functions those scenarios cover.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.CliProxyApi.{Proxy, Usage}

  @today ~D[2026-11-19]
  @accounts ["a1", "a2", "k1", "unknown"]
  @models ["m1", "m2", "m3", "unknown"]
  @backoff {10, 80}
  @binary Path.expand("../../test/support/fake_cli_proxy_api.sh", __DIR__)
  @wait_ms 10_000

  # -- Usage ---------------------------------------------------------------------

  property "usage is the sums of the last 30 days per day, account and model",
    numtests: HalC2.Prop.numtests(300) do
    forall steps <- list(oneof([{:add, list(record())}, {:tick, integer(0, 12)}])) do
      {_today, usage, kept} =
        Enum.reduce(steps, {@today, Usage.new(), []}, fn
          {:add, records}, {today, usage, kept} ->
            {today, Usage.add(usage, records, today), window(kept ++ accepted(records), today)}

          {:tick, days}, {today, usage, kept} ->
            today = Date.add(today, days)
            {today, Usage.prune(usage, today), window(kept, today)}
        end)

      expected = sums(kept)
      today = Enum.reduce(steps, @today, &tick/2)
      rows = Usage.rows(usage, today, Usage.days())

      (usage == expected and
         map_size(usage) <= Usage.days() * length(@accounts) * length(@models) and
         Usage.load(Usage.dump(usage)) == usage and
         length(rows) == map_size(usage) and
         Enum.map(rows, & &1["day"]) == Enum.sort(Enum.map(rows, & &1["day"]), :desc) and
         Enum.sum(Enum.map(rows, & &1["requests"])) == length(kept))
      |> when_fail(
        IO.puts(
          "Usage: #{inspect(usage, pretty: true)}\nExpected: #{inspect(expected, pretty: true)}"
        )
      )
      |> aggregate(Enum.map(steps, &elem(&1, 0)))
    end
  end

  defp tick({:tick, days}, today), do: Date.add(today, days)
  defp tick(_step, today), do: today

  # A record a day of up to 40 days back, its account and model named or not, its
  # tokens counted or not; now and then one the queue should never hold.
  defp record do
    frequency([
      {8,
       let {back, hour, auth, source, nick, model, failed, tokens} <-
             {integer(0, 40), integer(0, 23), elements([nil, "", "a1", "a2"]),
              elements([nil, "k1"]), elements([nil, "", "m1"]), elements([nil, "m2", "m3"]),
              boolean(), tokens()} do
         at = DateTime.new!(Date.add(@today, -back), Time.new!(hour, 0, 0))

         %{
           "timestamp" => DateTime.to_iso8601(at),
           "auth_id" => auth,
           "source" => source,
           "alias" => nick,
           "model" => model,
           "failed" => failed,
           "tokens" => tokens
         }
       end},
      {1, elements(["not a record", %{"timestamp" => "yesterday"}, %{"model" => "m1"}, 7])}
    ])
  end

  defp tokens do
    oneof([
      nil,
      let {input, output, total, cached} <-
            {integer(0, 500), integer(0, 500), elements([0, nil, 1_000, -4]),
             elements([nil, 3, "x"])} do
        %{
          "input_tokens" => input,
          "output_tokens" => output,
          "total_tokens" => total,
          "cached_tokens" => cached
        }
      end
    ])
  end

  # The model: the records kept, as {key, totals}, and their sums.
  defp accepted(records) do
    for %{"timestamp" => at} = record <- records,
        is_binary(at),
        {:ok, time, _} <- [DateTime.from_iso8601(at)] do
      account = named(record["auth_id"]) || named(record["source"]) || "unknown"
      model = named(record["alias"]) || named(record["model"]) || "unknown"
      tokens = record["tokens"] || %{}
      input = tokens["input_tokens"] || 0
      output = tokens["output_tokens"] || 0
      total = tokens["total_tokens"]

      {{Date.to_iso8601(DateTime.to_date(time)), account, model},
       %{
         "requests" => 1,
         "failed" => if(record["failed"], do: 1, else: 0),
         "inputTokens" => input,
         "outputTokens" => output,
         "cachedTokens" =>
           if(is_integer(tokens["cached_tokens"]), do: tokens["cached_tokens"], else: 0),
         "reasoningTokens" => 0,
         "totalTokens" => if(is_integer(total) and total > 0, do: total, else: input + output)
       }}
    end
  end

  defp named(""), do: nil
  defp named(name), do: name

  defp window(kept, today) do
    oldest = today |> Date.add(1 - Usage.days()) |> Date.to_iso8601()
    Enum.filter(kept, fn {{day, _, _}, _} -> day >= oldest end)
  end

  defp sums(kept) do
    Enum.reduce(kept, %{}, fn {key, totals}, sums ->
      Map.update(sums, key, totals, &Map.merge(&1, totals, fn _field, a, b -> a + b end))
    end)
  end

  # -- The supervisor ------------------------------------------------------------

  property "the proxy runs once, restarts after its backoff and stops when told",
    numtests: HalC2.Prop.numtests(40) do
    trap_exit do
      forall cmds <- commands(__MODULE__) do
        home = HalC2.Prop.scratch_home("cliproxyapi")
        HalC2.Prop.put_env(:cliproxyapi, backoff_ms: @backoff)
        Process.put(:home, home)
        Process.put(:pids, [])
        put_binary()
        start_proxy()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            cleanup()
            HalC2.Prop.stop_services()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  def initial_state,
    do: %{spec: nil, up: false, restarts: 0, backoff: elem(@backoff, 0), orphan: false}

  def command(%{up: true} = s) do
    frequency([
      {3, {:call, __MODULE__, :run, [config()]}},
      {2, {:call, __MODULE__, :halt, []}},
      {3, {:call, __MODULE__, :fail, []}},
      {2, {:call, __MODULE__, :fail_then_halt, []}},
      {2, {:call, __MODULE__, :fail_then_run, [config()]}},
      {1, {:call, __MODULE__, :fail_unstartable_then_run, [other(s.spec)]}},
      {1, {:call, __MODULE__, :mc_dies, []}}
    ])
  end

  def command(_s) do
    frequency([
      {4, {:call, __MODULE__, :run, [config()]}},
      {1, {:call, __MODULE__, :halt, []}}
    ])
  end

  defp config, do: elements([:a, :b])

  def precondition(%{up: up}, {:call, _, name, _})
      when name in [:fail, :fail_then_halt, :fail_then_run, :fail_unstartable_then_run, :mc_dies],
      do: up

  def precondition(_s, _call), do: true

  def next_state(s, _result, {:call, _, :run, [spec]}) do
    if s.up and s.spec == spec,
      do: s,
      else: %{s | spec: spec, up: true, restarts: 0, backoff: first(), orphan: false}
  end

  def next_state(s, _result, {:call, _, :halt, []}), do: %{s | spec: nil, up: false}
  def next_state(s, _result, {:call, _, :fail, []}), do: failed(s)

  def next_state(s, _result, {:call, _, :fail_then_halt, []}),
    do: %{failed(s) | spec: nil, up: false}

  def next_state(s, result, {:call, _, :fail_then_run, [spec]}) do
    s = failed(s)

    if s.spec == spec,
      do: s,
      else: next_state(%{s | up: false}, result, {:call, __MODULE__, :run, [spec]})
  end

  # Runs the other config, so it starts over whatever the failed restarts counted.
  def next_state(s, _result, {:call, _, :fail_unstartable_then_run, [spec]}),
    do: %{s | spec: spec, up: true, restarts: 0, backoff: first(), orphan: false}

  def next_state(s, _result, {:call, _, :mc_dies, []}),
    do: %{s | spec: nil, up: false, restarts: 0, backoff: first(), orphan: true}

  defp failed(s),
    do: %{s | restarts: s.restarts + 1, backoff: min(s.backoff * 2, elem(@backoff, 1))}

  defp first, do: elem(@backoff, 0)

  defp other(:a), do: :b
  defp other(:b), do: :a

  def postcondition(s, {:call, _, :run, [spec]}, seen) do
    same = s.up and s.spec == spec
    restarts = if same, do: s.restarts, else: 0

    # The same config keeps the process; another replaces it.
    running?(seen, restarts) and same == (seen.pid == seen.before)
  end

  # A dead MC's proxy is stopped by the next run, not by a halt, which has no config to
  # know it by.
  def postcondition(%{orphan: true}, {:call, _, :halt, []}, seen),
    do:
      seen.status["state"] == "stopped" and seen.pid == nil and
        seen.alive == [String.to_integer(seen.pidfile)]

  def postcondition(_s, {:call, _, :halt, []}, seen), do: stopped?(seen)

  def postcondition(s, {:call, _, :fail, []}, seen),
    do:
      seen.retry == s.backoff and is_integer(seen.code) and seen.code != 0 and
        seen.pid != seen.before and
        running?(seen, s.restarts + 1)

  def postcondition(s, {:call, _, :fail_then_halt, []}, seen),
    do: seen.retry == s.backoff and stopped?(seen)

  def postcondition(s, {:call, _, :fail_then_run, [spec]}, seen) do
    restarts = if s.spec == spec, do: s.restarts + 1, else: 0

    seen.retry == s.backoff and seen.pid != seen.before and running?(seen, restarts)
  end

  # The restart that could not start waits out the next backoff, and leaves nothing
  # running: only the proxy the run started is up.
  def postcondition(s, {:call, _, :fail_unstartable_then_run, [_spec]}, seen),
    do:
      seen.retry == s.backoff and seen.retry_failed == min(s.backoff * 2, elem(@backoff, 1)) and
        seen.pid != seen.before and running?(seen, 0)

  # The proxy it ran is still up, and no supervisor knows it.
  def postcondition(_s, {:call, _, :mc_dies, []}, seen),
    do: seen.status["state"] == "stopped" and seen.alive == [seen.before]

  defp running?(seen, restarts) do
    seen.status["state"] == "running" and seen.status["restarts"] == restarts and
      seen.alive == [seen.pid] and
      seen.pidfile == "#{seen.pid}" and length(seen.status["lines"]) <= 20
  end

  defp stopped?(seen),
    do:
      seen.status["state"] == "stopped" and seen.status["pid"] == nil and seen.alive == [] and
        seen.pidfile == nil

  # -- Commands ------------------------------------------------------------------

  def run(name) do
    before = current()
    Proxy.run(spec(name))
    seen(before)
  end

  def halt do
    before = current()
    Proxy.halt()
    seen(before)
  end

  def fail do
    before = fail_now()
    {retry, code} = await_restarting()
    await_state("running")
    seen(before) |> Map.merge(%{retry: retry, code: code})
  end

  def fail_then_halt do
    before = fail_now()
    {retry, _code} = await_restarting()
    Proxy.halt()
    seen(before) |> Map.put(:retry, retry)
  end

  # The same config waits out its backoff; another starts at once.
  def fail_then_run(name) do
    before = fail_now()
    {retry, _code} = await_restarting()
    status = Proxy.run(spec(name))
    if status["state"] == "restarting", do: await_state("running")
    seen(before) |> Map.put(:retry, retry)
  end

  # The binary is gone as the proxy fails, so its restart cannot start; it is back for
  # the run of the other config.
  def fail_unstartable_then_run(name) do
    File.rm!(fake_binary())
    before = fail_now()
    {retry, _code} = await_restarting()
    {retry_failed, _code} = await_restarting()
    put_binary()
    Proxy.run(spec(name))
    seen(before) |> Map.merge(%{retry: retry, retry_failed: retry_failed})
  end

  def mc_dies do
    before = current()
    proxy = Process.whereis(Proxy)
    ref = Process.monitor(proxy)
    Process.exit(proxy, :kill)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
    start_proxy()
    seen(before)
  end

  # -- Helpers -------------------------------------------------------------------

  defp start_proxy do
    {:ok, _} = GenServer.start(Proxy, nil, name: Proxy)
    flush()
  end

  # A copy of the fake in the scratch home, so a command can take it away.
  defp fake_binary, do: Path.join(Process.get(:home), "cli-proxy-api")

  defp put_binary do
    File.cp!(@binary, fake_binary())
    File.chmod!(fake_binary(), 0o755)
  end

  defp spec(name) do
    home = Process.get(:home)

    %{
      binary: fake_binary(),
      args: ["-config", Path.join(home, "config.yaml")],
      env: %{"MANAGEMENT_PASSWORD" => password(name), "WRITABLE_PATH" => home},
      cd: home,
      pidfile: Path.join(home, "cli-proxy-api.pid")
    }
  end

  defp password(name), do: "secret-#{name}"

  defp current, do: Proxy.status()["pid"]

  # Makes the proxy fail as one whose port is taken does: it exits 3, or by the signal
  # when it has not set its trap yet.
  defp fail_now do
    flush()
    pid = current()
    System.cmd("kill", ["-USR1", to_string(pid)])
    pid
  end

  defp await_restarting do
    receive do
      {:cliproxyapi_proxy, %{"state" => "restarting"} = status} ->
        {status["retryInMs"], status["code"]}
    after
      @wait_ms -> {:timeout, :timeout}
    end
  end

  defp await_state(state) do
    receive do
      {:cliproxyapi_proxy, %{"state" => ^state}} -> :ok
    after
      @wait_ms -> :timeout
    end
  end

  # What the proxy is now: its status, which of the processes started so far still
  # run, and its pidfile.
  defp seen(before) do
    status = Proxy.status()
    if status["pid"], do: Process.put(:pids, Enum.uniq([status["pid"] | Process.get(:pids)]))
    pids = Enum.uniq(Enum.reject([before | Process.get(:pids)], &is_nil/1))
    Process.put(:pids, pids)

    pidfile =
      case File.read(Path.join(Process.get(:home), "cli-proxy-api.pid")) do
        {:ok, text} -> String.trim(text)
        _ -> nil
      end

    flush()

    %{
      status: status,
      pid: status["pid"],
      before: before,
      alive: pids |> Enum.filter(&alive?/1) |> Enum.sort(),
      pidfile: pidfile
    }
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))

  defp flush do
    receive do
      {:cliproxyapi_proxy, _} -> flush()
    after
      0 -> :ok
    end
  end

  # Stops the supervisor, then any process it started that still runs (a dead MC's
  # proxy), by the pids it reported, and waits for each to go.
  defp cleanup do
    if proxy = Process.whereis(Proxy) do
      ref = Process.monitor(proxy)
      GenServer.stop(proxy)
      receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
    end

    for pid <- Process.get(:pids, []), alive?(pid) do
      System.cmd("kill", ["-TERM", to_string(pid)])
      await_gone(pid, 100)
    end

    flush()
  end

  defp await_gone(pid, 0), do: System.cmd("kill", ["-KILL", to_string(pid)])

  defp await_gone(pid, tries) do
    if alive?(pid) do
      Process.sleep(20)
      await_gone(pid, tries - 1)
    end
  end
end
