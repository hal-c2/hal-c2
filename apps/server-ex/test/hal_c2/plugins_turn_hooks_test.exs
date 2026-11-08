defmodule HalC2.PluginsTurnHooksTest do
  # The plugin hooks on turns (features/plugins/turn-hooks.feature): an extension that
  # hears turns (`observe/2`), one that shapes a new conversation (`shape_run/2`), and
  # the host calls that act on a turn (`Host.steer/4`, `notice/5`, `history/3`), on a
  # fake Claude. The extensions' feeds run as the plugin host runs them, without the
  # rest of the host: their permissions and settings are the settings document's, as the
  # host's are.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.TurnWatch
  alias HalC2.Plugins.{Feed, Host}

  @moduletag :tmp_dir
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  # The settings an extension here declares.
  @fields [%{"key" => "mode", "default" => "a", "secret" => false}]

  defmodule Listener do
    @moduledoc false
    # Tells the test what it heard, by its `tag` when it has one, with the settings it
    # heard with; one told to `hold` waits for `:release` before each event. Shapes runs
    # with `shape`, or fails as `shape` says (`feed/4`).
    def observe(event, %{id: id, settings: settings}) do
      %{test: test, tag: tag, hold: hold} = probe(id)

      if hold do
        send(test, {:holding, self()})
        receive do: (:release -> :ok)
      end

      send(test, if(tag, do: {:observed_by, tag, event}, else: {:observed, event}))
      send(test, {:observed_mode, id, settings["mode"]})
    end

    def shape_run(run, %{id: id, settings: settings}) do
      %{test: test, shape: shape} = probe(id)
      send(test, {:shaping, run})

      case shape do
        :raise ->
          raise "no shape"

        # A process the extension linked to dies, and takes the asking process with it.
        :linked_exit ->
          spawn_link(fn -> exit(:boom) end)
          receive do: (:never -> nil)

        :not_json ->
          %{"context" => self()}

        :mode ->
          %{"context" => "mode " <> settings["mode"]}

        shape ->
          shape
      end
    end

    defp probe(id), do: :hal_c2 |> Application.fetch_env!(:turn_hooks_probes) |> Map.fetch!(id)
  end

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)

    Application.put_env(:hal_c2, :claude_command, [
      "env",
      "FAKE_CLAUDE_PROMPT_LOG=#{Path.join(dir, "provider.log")}",
      "FAKE_CLAUDE_TRACE=#{Path.join(dir, "trace.log")}",
      "python3",
      "-u",
      @fake_claude
    ])

    Application.put_env(:hal_c2, :codex_command, [
      "env",
      "FAKE_CODEX_TRACE=#{Path.join(dir, "codex.log")}",
      "python3",
      "-u",
      @fake_codex
    ])

    File.write!(Path.join(dir, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)

    on_exit(fn ->
      for key <- ~w(claude_command codex_command settings_check_ms turn_hooks_probes)a,
          do: Application.delete_env(:hal_c2, key)
    end)

    start_supervised!(HalC2.Settings)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Plugins.Hooks})
    start_supervised!({Task.Supervisor, name: HalC2.Plugins.Shapes})
    start_supervised!({Registry, keys: :unique, name: HalC2.Claude.Registry}, id: :claude)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry}, id: :codex)
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    %{thread_id: create_thread(work), work: work, dir: dir}
  end

  test "a plugin that hears turns gets a turn's start, its tool call by Claude's name, and its end, in order",
       %{thread_id: thread_id} do
    grant(%{"listener" => ["turns:observe"]})
    feed("listener")

    {:ok, _} = send_message(thread_id, "m1", "hello")

    assert_receive {:observed, %{"type" => "turn.started"} = started}, 5_000

    assert %{"threadId" => ^thread_id, "provider" => "claudeAgent", "newConversation" => true} =
             started

    run_id = started["runId"]

    assert_receive {:observed, %{"type" => "turn.item", "tool" => "Bash"} = item}, 5_000
    assert %{"runId" => ^run_id, "itemType" => "command_execution"} = item

    assert_receive {:observed, %{"type" => "turn.finished", "runId" => ^run_id} = finished}, 5_000
    assert finished["status"] == "completed"
  end

  test "a plugin hears which file a file change wrote, and a long output's end" do
    item = %{
      "id" => "i1",
      "type" => "file_change",
      "providerToolName" => "Edit",
      "status" => "completed",
      "fileName" => "/r/lib/a.ex",
      "output" => String.duplicate("x", 5_000) <> "tail"
    }

    observed = Orchestration.TurnWriter.observed_item(item)
    assert %{"tool" => "Edit", "path" => "/r/lib/a.ex", "itemType" => "file_change"} = observed
    assert String.length(observed["output"]) == 4_000
    assert String.ends_with?(observed["output"], "tail")
  end

  test "a plugin not granted turns:observe hears nothing of a turn", %{thread_id: thread_id} do
    grant(%{"listener" => ["turns:observe"], "deaf" => []})
    feed("listener")
    deaf = feed("deaf", "deaf")

    {:ok, _} = send_message(thread_id, "m1", "hello")
    assert_receive {:observed, %{"type" => "turn.finished"}}, 5_000

    # Both feeds were sent every event at once; the second has handled them all once
    # it answers.
    :sys.get_state(deaf)
    refute_received {:observed_by, "deaf", _}
  end

  test "a plugin shaping runs puts its context ahead of a new conversation's first message and turns a Claude tool off for the conversation",
       %{thread_id: thread_id, dir: dir} do
    grant(%{"shaper" => ["runs:shape"]})
    feed("shaper", nil, %{"context" => "Keep answers short.", "deniedTools" => ["WebFetch"]})

    {:ok, _} = send_message(thread_id, "m1", "first")

    assert_receive {:shaping,
                    %{"message" => "first", "toolUnit" => "tool", "provider" => "claudeAgent"}},
                   5_000

    await_statuses(thread_id, ["completed"])

    {:ok, _} = send_message(thread_id, "m2", "second")
    await_statuses(thread_id, ["completed", "completed"])
    # Asked once, as the conversation started.
    refute_received {:shaping, _}

    [first, second] = prompts(dir)
    assert first =~ ~r/^Keep answers short\.\s+.*first/s
    refute second =~ "Keep answers short."

    for argv <- launches(dir), do: assert(denied(argv) =~ "WebFetch")
  end

  test "a Claude tool a plugin turned off does not tell Claude to keep to HAL-C2's workers" do
    mcp = %{url: "http://127.0.0.1:1/mcp", authorization: "Bearer t"}
    note = String.trim(HalC2.Mcp.workers_only_note())
    told? = &(HalC2.Claude.Protocol.cli_args(&1) |> Enum.any?(fn arg -> arg =~ note end))

    refute told?.(mcp: mcp, disallowed_tools: ["WebFetch"], workers_only: false)
    assert told?.(mcp: mcp, disallowed_tools: ["Agent", "WebFetch"], workers_only: true)
  end

  test "a plugin turning Codex's collaboration off starts the native thread without it",
       %{work: work, dir: dir} do
    grant(%{"shaper" => ["runs:shape"]})
    feed("shaper", nil, %{"deniedTools" => ["collaboration", "no-such-capability"]})
    thread_id = create_thread(work, "codex", "gpt-5.4")

    {:ok, _} = send_message(thread_id, "m1", "first")
    assert_receive {:shaping, %{"toolUnit" => "capability", "provider" => "codex"}}, 5_000
    await_statuses(thread_id, ["completed"])

    [start] =
      for line <- File.read!(Path.join(dir, "codex.log")) |> String.split("\n", trim: true),
          %{"in" => %{"method" => "thread/start", "params" => params}} <- [JSON.decode!(line)],
          do: params

    assert %{
             "features" => %{"multi_agent" => false, "multi_agent_v2" => false},
             "include_collaboration_mode_instructions" => false
           } = start["config"]
  end

  test "a plugin that fails while shaping leaves the conversation as it was",
       %{thread_id: thread_id, dir: dir} do
    grant(%{"shaper" => ["runs:shape"]})
    feed("shaper", nil, :raise)

    {:ok, _} = send_message(thread_id, "m1", "first")
    await_statuses(thread_id, ["completed"])

    assert [prompt] = prompts(dir)
    assert prompt =~ "first"
    for argv <- launches(dir), do: refute(denied(argv) =~ "WebFetch")
  end

  test "a plugin that dies with a process it linked, or answers what is not JSON, is left out of the shape, and the asker lives" do
    grant(%{"good" => ["runs:shape"], "linked" => ["runs:shape"], "bad" => ["runs:shape"]})
    feed("good", nil, %{"context" => "Keep answers short.", "deniedTools" => ["WebFetch"]})
    feed("linked", nil, :linked_exit)
    feed("bad", nil, :not_json)

    # As a turn asks, from a process that does not trap exits.
    {pid, ref} = spawn_monitor(fn -> exit({:shaped, HalC2.Plugins.shape_run(%{})}) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shaped, shape}}, 10_000

    assert %{"context" => "Keep answers short.", "deniedTools" => ["WebFetch"]} = shape
    assert shape["plugins"] == ["good"]
  end

  test "a conversation is left unshaped, and the asker lives, while the plugins' shapes cannot be asked" do
    grant(%{"good" => ["runs:shape"]})
    feed("good", nil, %{"context" => "Keep answers short."})
    # The supervisor shapes are asked under is restarting.
    :ok = stop_supervised(HalC2.Plugins.Shapes)

    {pid, ref} = spawn_monitor(fn -> exit({:shaped, HalC2.Plugins.shape_run(%{})}) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shaped, nil}}, 10_000
  end

  test "a plugin hears turns with the settings saved last, after its feed restarts, and is asked to shape with them while its feed is busy" do
    grant(%{"tuned" => ["turns:observe", "runs:shape"]}, %{"tuned" => %{"mode" => "b"}})
    feed("tuned", nil, :mode, true)
    assert %{"context" => "mode b"} = HalC2.Plugins.shape_run(%{})

    # The feed is busy with a turn's event as the user saves.
    HalC2.Plugins.observe(%{"type" => "turn.started"})
    assert_receive {:holding, busy}, 5_000
    grant(%{"tuned" => ["turns:observe", "runs:shape"]}, %{"tuned" => %{"mode" => "c"}})
    assert %{"context" => "mode c"} = HalC2.Plugins.shape_run(%{})
    send(busy, :release)
    assert_receive {:observed_mode, "tuned", "b"}, 5_000

    # Started again, as its supervisor restarts it, it hears with what was saved.
    :ok = stop_supervised({:feed, "tuned"})
    feed("tuned", nil, :mode, true)
    HalC2.Plugins.observe(%{"type" => "turn.started"})
    assert_receive {:holding, restarted}, 5_000
    send(restarted, :release)
    assert_receive {:observed_mode, "tuned", "c"}, 5_000
  end

  test "a conversation a provider started afresh, because the one to resume was gone, is a new one to plugins" do
    resumed = %{native_thread_id: "native-1", fork: nil, fresh: nil}
    refute Orchestration.TurnWriter.new_conversation?(resumed)

    {state, turn} = Orchestration.Handoff.fresh_start(%{fresh_start: true}, resumed)
    refute Map.has_key?(state, :fresh_start)
    assert Orchestration.TurnWriter.new_conversation?(turn)
  end

  test "a plugin hears how a call ended when its turn is stopped, or its runtime dies, before the turn ends",
       %{thread_id: thread_id, work: work} do
    grant(%{"listener" => ["turns:observe"]})
    feed("listener")

    {:ok, _} = send_message(thread_id, "m1", "leave a tool pending")
    [running] = await_pending(thread_id)
    :ok = HalC2.Claude.ThreadRuntime.interrupt(thread_id, running["id"])

    assert_receive {:observed, %{"type" => "turn.item", "tool" => "Bash"} = stopped}, 5_000
    assert stopped["status"] == "interrupted"
    assert_receive {:observed, %{"type" => "turn.finished", "status" => "interrupted"}}, 5_000

    crashed = create_thread(work)
    {:ok, _} = send_message(crashed, "m1", "leave a tool pending")
    await_pending(crashed)
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, crashed)
    Process.exit(runtime, :kill)

    assert_receive {:observed, %{"type" => "turn.item", "threadId" => ^crashed} = ended}, 5_000
    assert %{"tool" => "Bash", "status" => "failed"} = ended
    assert_receive {:observed, %{"type" => "turn.finished", "threadId" => ^crashed}}, 5_000
  end

  test "a plugin hears a Codex file edit, and reads each Codex turn with the usage it ended with",
       %{work: work} do
    grant(%{"listener" => ["turns:observe"]})
    feed("listener")
    thread_id = create_thread(work, "codex", "gpt-5.4")

    {:ok, _} = send_message(thread_id, "m1", "edit a.txt report usage 1000")

    assert_receive {:observed, %{"type" => "turn.item", "itemType" => "file_change"} = edit},
                   5_000

    assert %{"path" => "a.txt", "status" => "completed"} = edit
    assert edit["output"] =~ "+new"

    assert_receive {:observed, %{"type" => "turn.finished"} = finished}, 5_000
    assert %{"usedTokens" => 1000} = finished["tokenUsage"]
    await_statuses(thread_id, ["completed"])

    {:ok, _} = send_message(thread_id, "m2", "report usage 2000")
    await_statuses(thread_id, ["completed", "completed"])

    assert {:ok, [one, two]} = Host.history("listener", thread_id)
    assert one["provider"] == "codex"
    assert %{"usedTokens" => 1000} = one["tokenUsage"]
    assert %{"usedTokens" => 2000} = two["tokenUsage"]
    # A turn's usage carries its time, as the contract has it; Codex's report has none.
    assert two["tokenUsage"]["updatedAt"] == two["completedAt"]
    assert is_binary(finished["tokenUsage"]["updatedAt"])
    assert Enum.any?(one["items"], &(&1["itemType"] == "file_change"))
  end

  test "a plugin hears and reads the usage a Codex goal's run ended with between Codex's turns",
       %{work: work} do
    grant(%{"listener" => ["turns:observe"]})
    feed("listener")
    # Codex does not go on with the goal, so the run ends after the goal's first turn,
    # once the grace is over, with no turn of its own.
    System.put_env("FAKE_CODEX_GOAL_STALL", "1")
    Application.put_env(:hal_c2, :codex_goal_grace_ms, 0)

    on_exit(fn ->
      System.delete_env("FAKE_CODEX_GOAL_STALL")
      Application.delete_env(:hal_c2, :codex_goal_grace_ms)
    end)

    thread_id = create_thread(work, "codex", "gpt-5.4")
    {:ok, _} = send_message(thread_id, "m1", "/goal report usage 1500")

    assert_receive {:observed, %{"type" => "turn.finished"} = finished}, 5_000
    assert %{"usedTokens" => 1500, "updatedAt" => at} = finished["tokenUsage"]
    assert is_binary(at)
    await_statuses(thread_id, ["completed"])

    assert {:ok, [turn]} = Host.history("listener", thread_id)
    assert %{"usedTokens" => 1500} = turn["tokenUsage"]
  end

  test "a plugin hears what a Claude edit changed and what a web call searched for" do
    edit = %{"type" => "file_change", "fileName" => "a.ex", "diffStr" => "+new", "input" => nil}
    web = %{"type" => "web_search", "patterns" => ["elixir tasks"], "output" => nil}

    assert %{"output" => "+new", "path" => "a.ex"} = Orchestration.TurnWriter.observed_item(edit)
    assert %{"input" => ~s(["elixir tasks"])} = Orchestration.TurnWriter.observed_item(web)
    assert %{"input" => nil} = Orchestration.TurnWriter.observed_item(%{web | "patterns" => []})
  end

  test "a plugin steers the run it names while it works, and a steer to an ended run is refused and kept nowhere",
       %{thread_id: thread_id, dir: dir} do
    grant(%{"steerer" => ["threads:steer"]})

    {:ok, _} = send_message(thread_id, "m1", "wait m1")
    [running] = await_statuses(thread_id, ["running"])

    assert {:ok, _} = Host.steer("steerer", thread_id, running["id"], "use the cache")
    # The fake answers a steer in the turn it cut short, which then ends.
    [ended] = await_statuses(thread_id, ["completed"])
    assert Enum.any?(prompts(dir), &(&1 =~ "use the cache"))

    assert {:error, _} = Host.steer("steerer", thread_id, ended["id"], "too late")
    # Neither queued for a later turn nor kept as a message.
    assert ["completed"] = statuses(thread_id)
    refute Enum.any?(messages(thread_id), &(&1["text"] == "too late"))
  end

  test "a steer that names no run is refused, steering nothing and starting no turn",
       %{thread_id: thread_id} do
    grant(%{"steerer" => ["threads:steer"]})

    # Nothing runs: neither a turn started nor a message kept.
    assert {:error, _} = Host.steer("steerer", thread_id, nil, "unnamed")

    unnamed = %{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "text" => "unnamed",
      "attachments" => [],
      "createdBy" => "system",
      "creationSource" => "server",
      "deliveryIntent" => "steer",
      "dispatchMode" => %{"type" => "steer_active"},
      "steerOnly" => true
    }

    assert {:error, _} = Orchestration.dispatch(Map.put(unnamed, "commandId", "c1"))
    assert [] = statuses(thread_id)

    # A turn runs: it is not steered.
    {:ok, _} = send_message(thread_id, "m1", "wait m1")
    [_running] = await_statuses(thread_id, ["running"])
    assert {:error, _} = Orchestration.dispatch(Map.put(unnamed, "commandId", "c2"))
    assert ["running"] = statuses(thread_id)
    refute Enum.any?(messages(thread_id), &(&1["text"] == "unnamed"))
  end

  test "steering a thread without threads:steer is refused", %{thread_id: thread_id} do
    grant(%{"steerer" => []})
    assert {:error, message} = Host.steer("steerer", thread_id, "run:any", "hi")
    assert message =~ "threads:steer"
  end

  test "a plugin's notice sits in the run it names, offering to stop it; a run the thread lacks is refused",
       %{thread_id: thread_id} do
    grant(%{"noticer" => ["threads:notice"]})
    {:ok, _} = send_message(thread_id, "m1", "wait m1")
    [running] = await_statuses(thread_id, ["running"])

    assert {:ok, item_id} =
             Host.notice("noticer", thread_id, running["id"], "The agent is repeating itself.",
               title: "Loop",
               interrupt: true
             )

    item = state(thread_id) |> StreamState.get("turn-item") |> Map.fetch!(item_id)

    assert %{
             "type" => "system_notice",
             "runId" => run_id,
             "title" => "Loop",
             "message" => "The agent is repeating itself.",
             "pluginId" => "noticer",
             "actions" => ["interrupt"]
           } = item

    assert run_id == running["id"]
    assert {:error, _} = Host.notice("noticer", thread_id, "run:none", "hi")
    :ok = HalC2.Claude.ThreadRuntime.interrupt(thread_id, running["id"])
    await_statuses(thread_id, ["interrupted"])
  end

  test "a plugin reads the turns a thread ran, oldest first, each with its calls",
       %{thread_id: thread_id} do
    grant(%{"reader" => ["turns:observe"]})

    {:ok, _} = send_message(thread_id, "m1", "one")
    await_statuses(thread_id, ["completed"])
    {:ok, _} = send_message(thread_id, "m2", "two")
    [first, second] = await_statuses(thread_id, ["completed", "completed"])

    assert {:ok, [one, two]} = Host.history("reader", thread_id)
    assert one["runId"] == first["id"] and two["runId"] == second["id"]
    assert Enum.any?(one["items"], &(&1["tool"] == "Bash"))

    assert {:ok, [^two]} = Host.history("reader", thread_id, limit: 1)
    assert {:error, _} = Host.history("reader", "thread-none")
  end

  test "a plugin reads an older turn's calls after they went cold" do
    grant(%{"reader" => ["turns:observe"]})
    Application.put_env(:hal_c2, :stream_hot_items, 2)
    on_exit(fn -> Application.delete_env(:hal_c2, :stream_hot_items) end)

    {:ok, _} = HalC2.Streams.commit("th-cold", :thread, [{"thread", "th-cold", %{"s" => %{}}}])

    for i <- 1..6 do
      run = "r#{i}"

      item =
        &{"turn-item", "#{run}-i#{&1}",
         %{"s" => %{"runId" => run, "ordinal" => &1, "type" => "command_execution"}}}

      {:ok, _} =
        HalC2.Streams.commit("th-cold", :thread, [
          {"run", run, %{"s" => %{"id" => run, "ordinal" => i, "status" => "running"}}},
          item.(1),
          item.(2)
        ])

      {:ok, _} =
        HalC2.Streams.commit("th-cold", :thread, [
          {"run", run, %{"s" => %{"status" => "completed"}}}
        ])
    end

    stream = HalC2.Streams.state("th-cold")
    refute HalC2.StreamState.get(stream, "turn-item")["r1-i1"]

    assert {:ok, turns} = Host.history("reader", "th-cold")
    assert Enum.map(turns, &length(&1["items"])) == [2, 2, 2, 2, 2, 2]
    assert {:ok, [first]} = Host.history("reader", "th-cold", before: "r2")
    assert [%{"itemType" => "command_execution"}, _] = first["items"]
  end

  test "a plugin reads each turn with the provider it ran on, and the turns before one it heard of late",
       %{thread_id: thread_id} do
    grant(%{"reader" => ["turns:observe"]})

    {:ok, _} = send_message(thread_id, "m1", "one")
    await_statuses(thread_id, ["completed"])
    {:ok, _} = send_message(thread_id, "m2", "two")
    await_statuses(thread_id, ["completed", "completed"])
    {:ok, _} = send_message(thread_id, "m3", "wait m3")
    [first, second, working] = await_statuses(thread_id, ["completed", "completed", "running"])

    assert {:ok, [one, two]} = Host.history("reader", thread_id, before: working["id"])
    assert one["runId"] == first["id"] and two["runId"] == second["id"]
    assert one["provider"] == "claudeAgent" and two["provider"] == "claudeAgent"

    # The cutoff comes before the limit: the turn before `second`, not the newest.
    assert {:ok, [^one]} = Host.history("reader", thread_id, before: second["id"], limit: 1)
    assert {:ok, []} = Host.history("reader", thread_id, before: first["id"])
    assert {:ok, [^one, ^two]} = Host.history("reader", thread_id, before: "run:none")

    :ok = HalC2.Claude.ThreadRuntime.interrupt(thread_id, working["id"])
    await_statuses(thread_id, ["completed", "completed", "interrupted"])
  end

  test "text generation for a plugin reports what the provider said it used, or an estimate" do
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-haiku-5-5"}

    reported = %{
      "inputTokens" => 120,
      "cachedInputTokens" => 100,
      "outputTokens" => 8,
      "costUsd" => 0.001
    }

    assert %{"estimated" => false, "inputTokens" => 120, "model" => "claude-haiku-5-5"} =
             HalC2.TextGeneration.usage(selection, "prompt", %{"a" => "b"}, reported)

    assert %{"estimated" => true, "inputTokens" => 2, "costUsd" => nil} =
             HalC2.TextGeneration.usage(selection, "12345678", %{"a" => "b"}, nil)
  end

  # --- helpers ------------------------------------------------------------------------

  # Grants each extension its permissions, with the settings `saved` for it.
  defp grant(grants, saved \\ %{}) do
    {settings, version} = HalC2.Settings.get()

    plugins =
      Map.new(grants, fn {id, granted} ->
        {id, %{"enabled" => true, "granted" => granted, "settings" => saved[id] || %{}}}
      end)

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)
  end

  # A feed for the extension `id`, as the plugin host starts one; it tells the test
  # process what it heard, by its `tag` when it has one, and shapes runs with `shape`
  # (`Listener`).
  defp feed(id, tag \\ nil, shape \\ nil, hold \\ false) do
    probes = Application.get_env(:hal_c2, :turn_hooks_probes, %{})
    probe = %{test: self(), tag: tag, shape: shape, hold: hold}
    Application.put_env(:hal_c2, :turn_hooks_probes, Map.put(probes, id, probe))
    start_supervised!({Feed, {id, Listener, @fields}}, id: {:feed, id})
  end

  defp create_thread(work, instance \\ "claudeAgent", model \\ "claude-sonnet-5-5") do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Hooks",
        "modelSelection" => %{"instanceId" => instance, "model" => model},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    thread_id
  end

  defp send_message(thread_id, message_id, text) do
    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "messageId" => message_id,
      "text" => text,
      "attachments" => [],
      "dispatchMode" => %{"type" => "queue_after_active"}
    })
  end

  # The text of each message the fake Claude was sent, steers included.
  defp prompts(dir) do
    for line <- File.read!(Path.join(dir, "provider.log")) |> String.split("\n", trim: true),
        do: JSON.decode!(line)
  end

  # The argv of each launch of the fake Claude.
  defp launches(dir) do
    for line <- File.read!(Path.join(dir, "trace.log")) |> String.split("\n", trim: true),
        %{"argv" => argv} <- [JSON.decode!(line)],
        do: argv
  end

  defp denied(argv) do
    case Enum.drop_while(argv, &(&1 != "--disallowedTools")) do
      [_, tools | _] -> tools
      _ -> ""
    end
  end

  defp state(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp messages(thread_id), do: thread_id |> state() |> StreamState.list("message")

  defp statuses(thread_id) do
    thread_id
    |> state()
    |> StreamState.list("run")
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.map(& &1["status"])
  end

  # The thread's running run, once its Bash call is running.
  defp await_pending(thread_id) do
    pending? = fn ->
      thread_id
      |> state()
      |> StreamState.list("turn-item")
      |> Enum.any?(&(&1["providerToolName"] == "Bash" and &1["status"] == "running"))
    end

    if pending?.() do
      await_statuses(thread_id, ["running"])
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_pending(thread_id)
      after
        5_000 -> flunk("no Bash call ever ran in #{thread_id}")
      end
    end
  end

  defp await_statuses(thread_id, statuses) do
    runs = thread_id |> state() |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

    if Enum.map(runs, & &1["status"]) == statuses do
      runs
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_statuses(thread_id, statuses)
      after
        5_000 ->
          flunk("runs never reached #{inspect(statuses)}, at #{inspect(statuses(thread_id))}")
      end
    end
  end
end
