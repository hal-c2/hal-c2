defmodule HalC2.Steps.Platform.Diagnostics do
  @moduledoc "Steps for features/node/platform/diagnostics.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World
  alias HalC2.Test.WsClient

  @hour 3_600_000

  # --- helpers ---------------------------------------------------------------------

  defp put_env(key, value), do: World.put_app_env(key, value)

  defp rpc!(context, method, payload \\ %{}) do
    {result, context} = World.call!(context, method, payload)
    {result, context}
  end

  # The services a provider turn, a terminal and the sampler need.
  defp services do
    World.provider_services()
    Node.ensure(HalC2.Diagnostics)
  end

  defp fake_codex(context) do
    services()
    World.fake_codex(context)
  end

  defp send_message(context, text), do: World.socket_message(context, "main", text)

  defp await_run(context, fun), do: World.await_run(context, "main", fun)

  defp processes(context) do
    {result, context} = rpc!(context, "server.getProcessDiagnostics")
    {result["processes"], context}
  end

  defp provider_process(processes),
    do: Enum.find(processes, &(&1["command"] =~ ~r{/codex\s}))

  # The client's ServerConfig, as the config subscription delivers it.
  defp server_config(context) do
    client =
      World.client(context)
      |> Node.sub(9, %{"type" => "config", "environment" => context.node.environment})

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == 9))
    {frame["config"], World.put_client(context, client)}
  end

  defp snapshot, do: elem(HalC2.Diagnostics.retry(), 1)["snapshot"]

  defp timer_ms do
    %{timer: timer} = :sys.get_state(HalC2.Diagnostics)
    Process.read_timer(timer)
  end

  defp follow(context) do
    client = World.client(context) |> Node.sub(7, telemetry_shape())
    {frame, client} = Node.await(client, &(&1["t"] == "resourceTelemetry" and &1["id"] == 7))
    context |> World.put_client(client) |> Map.put(:telemetry, frame["snapshot"])
  end

  defp telemetry_shape, do: %{"type" => "resourceTelemetry", "node" => Atom.to_string(node())}

  # OTLP JSON for one client span.
  defp otlp_spans(name) do
    now = System.system_time(:nanosecond)

    %{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "hal-c2-web"}}
            ]
          },
          "scopeSpans" => [
            %{
              "scope" => %{"name" => "hal-c2-web"},
              "spans" => [
                %{
                  "traceId" => "0af7651916cd43dd8448eb211c80319c",
                  "spanId" => "b7ad6b7169203331",
                  "name" => name,
                  "kind" => 3,
                  "startTimeUnixNano" => Integer.to_string(now - 5_000_000),
                  "endTimeUnixNano" => Integer.to_string(now),
                  "attributes" => [%{"key" => "route", "value" => %{"stringValue" => "/chat"}}],
                  "events" => [],
                  "links" => [],
                  "status" => %{"code" => 1}
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp post_spans(context, name) do
    response =
      Node.request(context.node, :post, "/api/observability/v1/traces",
        bearer: context.access_token,
        json: otlp_spans(name)
      )

    Map.put(context, :response, response)
  end

  defp paired(context) do
    {:ok, access, _expires, _scopes} =
      HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(context.node.store), %{"label" => "Web"})

    Map.put(context, :access_token, access)
  end

  defmodule Collector do
    @moduledoc false
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    post "/v1/traces" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [test] = Application.fetch_env!(:hal_c2, :test_collector)
      send(test, {:collected, body, Plug.Conn.get_req_header(conn, "x-team")})
      send_resp(conn, 200, "{}")
    end
  end

  # A provider process speaking JSON-RPC, scripted in Python, logged for `thread`.
  defp scripted_provider(context, script) do
    path = Path.join(Node.tmp_dir(context.node, "provider"), "provider.py")
    File.write!(path, script)

    {:ok, conn} =
      HalC2.JsonRpc.Connection.start_link(
        cmd: ["python3", "-u", path],
        handler: self(),
        log: "thread-logged"
      )

    # Linked to the scenario, the connection and its process end with it.
    Map.put(context, :conn, conn)
  end

  defp log_records do
    "thread-logged"
    |> HalC2.ProviderLog.path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      assert [_, json] = Regex.run(~r/^\[[^\]]+\] NTIVE: (.*)$/, line)
      {byte_size(json), JSON.decode!(json)}
    end)
  end

  # --- background ------------------------------------------------------------------

  step "a running node that started a provider and a terminal", context do
    context =
      context
      |> fake_codex()
      |> World.create_project("widgets")
      |> World.create_thread("main", "widgets")
      |> send_message("wait for me")

    await_run(context, &(&1["status"] == "running"))

    {_snapshot, context} =
      rpc!(context, "terminal.open", %{
        "threadId" => World.thread_id(context, "main"),
        "terminalId" => "default",
        "cwd" => World.project(context, "widgets").root
      })

    # The node samples what it started.
    snapshot = snapshot()
    categories = Enum.map(snapshot["processes"], & &1["category"])
    assert "provider-root" in categories and "terminal-root" in categories
    context
  end

  # --- sampling --------------------------------------------------------------------

  step "nobody watches the resource monitor", context do
    assert %{watchers: watchers} = :sys.get_state(HalC2.Diagnostics)
    assert watchers == %{}
    context
  end

  step "the node samples the processes under it every fifteen seconds", context do
    assert snapshot()["sampleIntervalMs"] == 15_000
    assert timer_ms() in 2_001..15_000
    context
  end

  step "a client follows the node's resource telemetry", context do
    follow(context)
  end

  step "the node samples every two seconds", context do
    assert context.telemetry["sampleIntervalMs"] == 2_000
    assert timer_ms() in 1..2_000
    context
  end

  step "each sample is pushed to the client", context do
    # The next tick of the sampler, without waiting two seconds for it.
    send(HalC2.Diagnostics, :sample)
    client = World.client(context)
    {frame, client} = Node.await(client, &(&1["t"] == "resourceTelemetry" and &1["id"] == 7))
    assert frame["snapshot"]["readAt"] >= context.telemetry["readAt"]
    assert frame["snapshot"]["processes"] != []
    World.put_client(context, client)
  end

  step "it stops following", context do
    client = World.client(context) |> Node.unsub(7)
    # The socket handles frames in order, so the pong means the unsubscribe landed.
    client = WsClient.send_json(client, %{"t" => "ping"})
    {_pong, client} = Node.await(client, &(&1["t"] == "pong"))
    World.put_client(context, client)
  end

  step "the node goes back to sampling every fifteen seconds", context do
    assert :sys.get_state(HalC2.Diagnostics).watchers == %{}
    assert snapshot()["sampleIntervalMs"] == 15_000
    assert timer_ms() > 2_000
    context
  end

  # --- process list and history ----------------------------------------------------

  step "a client asks for the node's process diagnostics", context do
    {processes, context} = processes(context)
    Map.put(context, :processes, processes)
  end

  step "it lists the provider and the terminal with their CPU and memory", context do
    provider = provider_process(context.processes)
    assert provider, "no provider in #{inspect(Enum.map(context.processes, & &1["command"]))}"

    shells = ~w(zsh bash fish sh nu)

    terminal =
      Enum.find(context.processes, fn process ->
        process["command"] |> String.split(" ") |> hd() |> Path.basename() |> Kernel.in(shells)
      end)

    assert terminal,
           "no terminal shell in #{inspect(Enum.map(context.processes, & &1["command"]))}"

    for process <- [provider, terminal] do
      assert is_number(process["cpuPercent"])
      assert process["rssBytes"] > 0
      assert process["depth"] > 0
    end

    context
  end

  step "the node has run for two hours", context do
    now = System.system_time(:millisecond)

    :sys.replace_state(HalC2.Diagnostics, fn %{samples: [{_, rows} | _] = samples} = state ->
      old = for minutes <- 115..5//-10, do: {now - minutes * 60_000, rows}
      %{state | samples: samples ++ Enum.reverse(old)}
    end)

    # Its next sample drops whatever is older than an hour.
    send(HalC2.Diagnostics, :sample)
    assert length(:sys.get_state(HalC2.Diagnostics).samples) > 0
    Map.put(context, :asked_at, now)
  end

  step "a client asks for its resource telemetry history", context do
    {history, context} =
      rpc!(context, "server.getResourceTelemetryHistory", %{
        "windowMs" => 2 * @hour,
        "bucketMs" => 60_000
      })

    Map.put(context, :history, history)
  end

  step "it receives the last hour of samples", context do
    %{samples: samples} = :sys.get_state(HalC2.Diagnostics)
    now = System.system_time(:millisecond)
    assert Enum.all?(samples, fn {at, _} -> now - at <= @hour end)
    assert context.history["retainedSampleCount"] == length(samples)
    # Samples from 5 to 55 minutes ago stayed; those from 65 to 115 minutes ago are gone.
    assert length(samples) >= 6

    {:ok, earliest, _} =
      context.history["buckets"]
      |> Enum.map(& &1["startedAt"])
      |> Enum.min()
      |> DateTime.from_iso8601()

    assert now - DateTime.to_unix(earliest, :millisecond) <= @hour + 60_000
    context
  end

  step "a client asks for one process's resource history", context do
    {history, context} =
      rpc!(context, "server.getProcessResourceHistory", %{
        "windowMs" => @hour,
        "bucketMs" => 60_000
      })

    Map.put(context, :history, history)
  end

  step "it receives that process's samples from the last hour", context do
    provider = Enum.find(context.history["topProcesses"], &(&1["command"] =~ ~r{/codex\s}))
    assert provider, "no provider in #{inspect(context.history["topProcesses"])}"
    assert provider["sampleCount"] >= 1
    {:ok, first, _} = DateTime.from_iso8601(provider["firstSeenAt"])
    assert DateTime.diff(DateTime.utc_now(), first, :millisecond) <= @hour
    assert context.history["windowMs"] == @hour
    context
  end

  step "a client asks for the host's resources", context do
    {host, context} = rpc!(context, "server.getHostResources")
    Map.put(context, :host, host)
  end

  step "it receives the host's CPU count and memory", context do
    assert context.host["cpuCount"] > 0
    assert context.host["totalMemoryBytes"] > 0
    assert context.host["availableMemoryBytes"] in 1..context.host["totalMemoryBytes"]
    context
  end

  step "a client asks the node to retry resource telemetry", context do
    before = :sys.get_state(HalC2.Diagnostics).samples |> length()
    asked = DateTime.utc_now()
    {result, context} = rpc!(context, "server.retryResourceTelemetry")
    Map.merge(context, %{retry: result, samples_before: before, asked_at: asked})
  end

  step "the node takes a sample immediately", context do
    assert context.retry["accepted"] == true
    {:ok, read_at, _} = DateTime.from_iso8601(context.retry["snapshot"]["readAt"])
    assert DateTime.compare(read_at, DateTime.truncate(context.asked_at, :second)) != :lt
    assert length(:sys.get_state(HalC2.Diagnostics).samples) == context.samples_before + 1
    context
  end

  step ~r/^a client reads a process sample on a platform that does not count I\/O$/, context do
    put_env(:proc_dir, Node.tmp_dir(context.node, "no-proc"))
    {result, context} = rpc!(context, "server.retryResourceTelemetry")
    Map.put(context, :sample, provider_process(result["snapshot"]["processes"]))
  end

  step ~r/^its I\/O is marked unavailable rather than zero$/, context do
    assert context.sample["ioSemantics"] == "unavailable"
    context
  end

  step ~r/^a client reads a process sample on a platform that counts I\/O$/, context do
    {_, context} = rpc!(context, "server.retryResourceTelemetry")
    {result, context} = rpc!(context, "server.retryResourceTelemetry")
    Map.put(context, :sample, provider_process(result["snapshot"]["processes"]))
  end

  step "the sample includes read and write bytes", context do
    sample = context.sample
    assert sample["ioSemantics"] == "storage"

    [_, read] =
      Regex.run(~r/^read_bytes:\s*(\d+)/m, File.read!("/proc/#{sample["identity"]["pid"]}/io"))

    assert sample["ioReadBytes"] <= String.to_integer(read)
    assert is_integer(sample["ioWriteBytes"]) and is_integer(sample["ioReadBytesPerSecond"])
    context
  end

  # --- signals ---------------------------------------------------------------------

  step "the process list shows a provider process", context do
    {processes, context} = processes(context)
    provider = provider_process(processes)
    assert provider
    Map.put(context, :target, provider)
  end

  step "a client signals that process to terminate", context do
    [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, "main"))
    conn = :sys.get_state(runtime).conn
    assert HalC2.JsonRpc.Connection.os_pid(conn) == context.target["pid"]
    context = Map.put(context, :conn_ref, Process.monitor(conn))

    {result, context} =
      rpc!(context, "server.signalProcess", %{
        "pid" => context.target["pid"],
        "startTimeMs" => context.target["startTimeMs"],
        "signal" => "SIGTERM"
      })

    Map.put(context, :signal, result)
  end

  step "the process stops", context do
    assert context.signal["signaled"] == true
    # The connection that owns the provider's pipes ends when the process does.
    assert_receive {:DOWN, ref, :process, _, _} when ref == context.conn_ref, 5_000
    {processes, context} = processes(context)
    refute Enum.any?(processes, &(&1["pid"] == context.target["pid"]))
    context
  end

  step "a client signals a process id that is not under the node", context do
    {result, context} =
      rpc!(context, "server.signalProcess", %{
        "pid" => 1,
        "startTimeMs" => 0,
        "signal" => "SIGKILL"
      })

    Map.put(context, :signal, result)
  end

  step "the node refuses", context do
    assert context.signal["signaled"] == false

    assert %{"_tag" => "Some", "value" => "That process is not one this node started."} =
             context.signal["message"]

    context
  end

  # The provider's pid now belongs to a process that started later than the one seen.
  step "a process the client saw has exited and its id was reused", context do
    {processes, context} = processes(context)
    current = provider_process(processes)
    Map.put(context, :target, %{current | "startTimeMs" => current["startTimeMs"] - 60_000})
  end

  step "the client signals it with the start time it saw", context do
    {result, context} =
      rpc!(context, "server.signalProcess", %{
        "pid" => context.target["pid"],
        "startTimeMs" => context.target["startTimeMs"],
        "signal" => "SIGKILL"
      })

    Map.put(context, :signal, result)
  end

  step "the node refuses because it is no longer the same process", context do
    assert context.signal["signaled"] == false

    assert %{"_tag" => "Some", "value" => "That process has already exited."} =
             context.signal["message"]

    {processes, _} = processes(context)
    assert provider_process(processes)["pid"] == context.target["pid"]
    context
  end

  # --- traces ----------------------------------------------------------------------

  step "a client asks for trace diagnostics", context do
    {result, context} = rpc!(context, "server.getTraceDiagnostics")
    Map.put(context, :traces, result)
  end

  step "the node answers that it does not record traces", context do
    assert %{
             "_tag" => "Some",
             "value" => %{"kind" => "trace-file-not-found", "message" => message}
           } =
             context.traces["error"]

    assert message == "This node does not record traces."
    assert context.traces["recordCount"] == 0
    context
  end

  step "a client reads the node's server config", context do
    {config, context} = server_config(context)
    Map.put(context, :server_config, config)
  end

  step "it names the directory the node writes its logs to", context do
    assert context.server_config["observability"]["logsDirectoryPath"] ==
             Path.join(context.node.home, "logs")

    context
  end

  step "it says tracing export is off", context do
    observability = context.server_config["observability"]
    assert observability["otlpTracesEnabled"] == false
    refute Map.has_key?(observability, "otlpTracesUrl")
    context
  end

  step "tracing is enabled on the node", context do
    put_env(:trace, true)
    context
  end

  step "a turn runs", context do
    context = send_message(context, "hello")
    run = await_run(context, &(&1["status"] == "completed"))
    Map.put(context, :run, run)
  end

  step "trace diagnostics list the turn's spans", context do
    {traces, _context} = rpc!(context, "server.getTraceDiagnostics")
    assert traces["error"] == %{"_tag" => "None"}
    names = Enum.map(traces["topSpansByCount"], & &1["name"])
    assert "orchestration.dispatchCommand" in names
    assert "provider.turn" in names
    assert "checkpoint.capture" in names
    assert traces["recordCount"] >= 3

    turn =
      context.node.home
      |> Path.join("logs/server.trace.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.find(
        &(&1["name"] == "provider.turn" and &1["attributes"]["run.id"] == context.run["id"])
      )

    assert turn["attributes"]["turn.status"] == "completed"
    context
  end

  step "client tracing is on", context do
    put_env(:trace, true)
    paired(context)
  end

  step "a client exports spans to its node", context do
    post_spans(context, "chat.render")
  end

  step "the node accepts them instead of answering not found", context do
    assert {204, _, _} = context.response
    {traces, _context} = rpc!(context, "server.getTraceDiagnostics")
    assert "chat.render" in Enum.map(traces["topSpansByCount"], & &1["name"])
    context
  end

  step "an OTLP collector is configured on the node", context do
    {:ok, server} = Bandit.start_link(plug: Collector, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    put_env(:test_collector, [self()])
    put_env(:otlp_traces_url, "http://127.0.0.1:#{port}/v1/traces")
    put_env(:otlp_headers, %{"x-team" => "hal_c2"})
    paired(context)
  end

  step "client spans arrive", context do
    post_spans(context, "composer.submit")
  end

  step "the node forwards them to the collector", context do
    assert {204, _, _} = context.response
    assert_receive {:collected, body, ["hal_c2"]}, 5_000
    assert %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]} = JSON.decode!(body)
    assert span["name"] == "composer.submit"
    {config, _} = server_config(context)
    assert config["observability"]["otlpTracesEnabled"] == true
    context
  end

  # --- provider event logs ---------------------------------------------------------

  step "provider event logging is on", context do
    put_env(:provider_event_log, true)
    context
  end

  step "a provider sends a response larger than 64 KiB or nested deeper than the log allows",
       context do
    context =
      scripted_provider(context, """
      import json, sys
      def send(m):
          sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
      for line in sys.stdin:
          msg = json.loads(line)
          if msg["method"] == "big":
              send({"id": msg["id"], "result": {"threadId": "native-1", "turn": {"id": "turn-1", "status": "completed"}, "blob": "x" * 100000}})
          elif msg["method"] == "deep":
              nested = {"leaf": True}
              for _ in range(20):
                  nested = {"inner": nested}
              send({"method": "item/completed", "params": {"threadId": "native-1", "item": {"type": "agentMessage", "text": "y" * 70000}}})
              send({"id": msg["id"], "error": {"code": -32000, "message": "too deep", "data": nested}})
      """)

    {:ok, big} = HalC2.JsonRpc.Connection.call(context.conn, "big", %{})
    deep = HalC2.JsonRpc.Connection.call(context.conn, "deep", %{})
    Map.merge(context, %{big: big, deep: deep})
  end

  step "its log record is a structural summary of at most 64 KiB", context do
    records = log_records()
    assert length(records) == 3

    for {size, record} <- records do
      assert size <= 64 * 1024
      assert record["truncated"] == true
    end

    Map.put(context, :records, records)
  end

  step "the summary keeps the routing ids, method, status and error fields", context do
    [{_, big}, {_, item}, {_, deep}] = context.records
    assert item["method"] == "item/completed"
    assert item["params"]["threadId"] == "native-1"
    # `item` is not one of the summary fields TS keeps either.
    refute Map.has_key?(item["params"], "item")
    assert big["id"] == 1
    assert big["result"]["threadId"] == "native-1"
    assert big["result"]["turn"]["status"] == "completed"
    refute Map.has_key?(big["result"], "blob")
    assert deep["id"] == 2
    refute Map.has_key?(deep["error"], "data")
    assert deep["error"]["code"] == -32000
    assert deep["error"]["message"] == "too deep"
    context
  end

  step "the provider still receives and handles the full response", context do
    assert byte_size(context.big["blob"]) == 100_000
    assert context.big["turn"]["status"] == "completed"
    assert {:error, %{"message" => "too deep", "data" => nested}} = context.deep
    assert get_in(nested, List.duplicate("inner", 20)) == %{"leaf" => true}

    assert_receive {:json_rpc, _,
                    {:notification, "item/completed", %{"item" => %{"text" => text}}}}

    assert byte_size(text) == 70_000
    context
  end

  step "a provider streams text, command output and plan deltas", context do
    context =
      scripted_provider(context, """
      import json, sys
      def send(m):
          sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
      for line in sys.stdin:
          msg = json.loads(line)
          p = {"threadId": "native-1", "turnId": "turn-1"}
          send({"method": "turn/started", "params": p})
          send({"method": "item/agentMessage/delta", "params": {**p, "delta": "Hel"}})
          send({"method": "item/commandExecution/outputDelta", "params": {**p, "delta": "ls\\n"}})
          send({"method": "item/plan/delta", "params": {**p, "delta": "1. look"}})
          send({"method": "item/completed", "params": {**p, "item": {"type": "agentMessage", "text": "Hello"}}})
          send({"method": "turn/completed", "params": {**p, "turn": {"id": "turn-1", "status": "failed", "error": {"message": "boom"}}}})
          if msg["method"] == "run":
              send({"id": msg["id"], "result": {"ok": True}})
          else:
              send({"id": msg["id"], "error": {"code": -32601, "message": "unknown"}})
      """)

    {:ok, _} = HalC2.JsonRpc.Connection.call(context.conn, "run", %{})
    {:error, _} = HalC2.JsonRpc.Connection.call(context.conn, "nope", %{})

    notifications =
      for _ <- 1..12 do
        assert_receive {:json_rpc, _, {:notification, method, _}}, 2_000
        method
      end

    Map.put(context, :handled, notifications)
  end

  step "the log keeps lifecycle events, responses and failures but not the deltas", context do
    logged =
      log_records()
      |> Enum.map(fn {_, record} -> record["method"] || {:response, record["id"]} end)

    assert logged == [
             "turn/started",
             "item/completed",
             "turn/completed",
             {:response, 1},
             "turn/started",
             "item/completed",
             "turn/completed",
             {:response, 2}
           ]

    # The runtime still saw every delta.
    assert Enum.count(context.handled, &String.ends_with?(&1, ["delta", "Delta"])) == 6
    context
  end
end
