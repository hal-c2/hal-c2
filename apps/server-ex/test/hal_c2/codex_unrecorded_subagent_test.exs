defmodule HalC2.CodexUnrecordedSubagentTest do
  # hal-c2#1285 (review of #1398): a full disk refuses a Codex turn's thread and its
  # subagent's thread alike. The runtime's end of the subagent was dropped with the
  # rest, and the run's end TurnWatch recorded once the store recovered failed the
  # subagent but left the work in its own thread running.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.TurnWatch

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @tid "thread-sub"

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    Application.put_env(:hal_c2, :unrecorded_retry_ms, 20)

    on_exit(fn ->
      HalC2.Test.Machines.refuse_changes(nil)

      for key <- ~w(codex_command unrecorded_retry_ms)a,
          do: Application.delete_env(:hal_c2, key)
    end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    for registry <- [HalC2.Claude.Registry, HalC2.Acp.Registry, HalC2.Pi.Registry],
        do: start_supervised!({Registry, keys: :unique, name: registry}, id: registry)

    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    %{work: work}
  end

  # The store refuses every stream's changes, as a full disk does.
  def refuse_every(:append_change, _stream_id) do
    if self() == Process.whereis(HalC2.Store), do: raise("the disk is full"), else: :ok
  end

  def refuse_every(_stage, _stream_id), do: :ok

  # The store's first write waits for the test's go.
  def hold_once(test, gate, :append_change, _stream_id) do
    if self() == Process.whereis(HalC2.Store) and Process.put({:held, gate}, true) == nil do
      send(test, {:held, gate, self()})

      receive do
        {:go, ^gate} -> :ok
      end
    end

    :ok
  end

  def hold_once(_test, _gate, _stage, _stream_id), do: :ok

  test "a run the store failed ends the work in its subagents' threads once it recovers",
       %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}

    notify(pid, runtime, "item/started", Map.put(native, "item", collab()))
    await(fn -> list(@tid, "subagent") != [] end)

    notify(pid, runtime, "item/started", %{
      "threadId" => "native-child-1",
      "turnId" => "native-child-turn-1",
      "item" => %{"type" => "commandExecution", "id" => "child-cmd-1", "command" => "ls lib"}
    })

    :ok = GenServer.call(pid, :settle)
    [%{"childThreadId" => child}] = list(@tid, "subagent")
    assert %{"status" => "running"} = command(child)

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    message = %{"type" => "agentMessage", "id" => "msg-1", "text" => ""}
    notify(pid, runtime, "item/started", Map.put(native, "item", message))
    assert {:unrecorded, _} = TurnWatch.attempted(run)

    HalC2.Test.Machines.refuse_changes(nil)
    await(fn -> match?([%{"status" => "failed"}], list(@tid, "run")) end)

    assert [%{"status" => "failed"}] = list(@tid, "subagent")
    assert %{"status" => "failed"} = command(child)
  end

  # A completed Codex turn leaves its subagents carrying on in their own threads: the
  # run's end TurnWatch records once the store recovers leaves them running, as the
  # recorded end of that turn would have.
  test "a subagent outlives a completed run the store failed", %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    child_command(pid, runtime, native)
    [%{"childThreadId" => child}] = list(@tid, "subagent")

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    assert {:unrecorded, _} = TurnWatch.attempted(run)

    HalC2.Test.Machines.refuse_changes(nil)
    await(fn -> match?([%{"status" => "failed"}], list(@tid, "run")) end)

    assert [%{"status" => "running"}] = list(@tid, "subagent")
    assert %{"status" => "running"} = item(@tid, "subagent")
    assert %{"status" => "running"} = command(child)
    assert %{subagents: %{"native-child-1" => %{done: false}}} = :sys.get_state(pid)
  end

  # A subagent a completed run left carrying on is the next run's work too: the stop
  # of that run the store failed ends it (`finish_subagents/2`), and so does the
  # run's end TurnWatch records, though the subagent is the earlier run's.
  test "a run the store failed ends the subagent an earlier run left running",
       %{work: work} do
    {pid, runtime, first} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    child_command(pid, runtime, native)
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    await(fn -> match?([%{"status" => "completed"}], list(@tid, "run")) end)

    runtime = dispatch("m2", native["turnId"])
    second = runtime.turn.ids.run

    [%{"childThreadId" => child, "runId" => ^first, "status" => "running"}] =
      list(@tid, "subagent")

    assert %{"status" => "running"} = command(child)

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    message = %{"type" => "agentMessage", "id" => "msg-2", "text" => ""}
    notify(pid, runtime, "item/started", Map.put(native, "item", message))
    assert {:unrecorded, _} = TurnWatch.attempted(second)

    HalC2.Test.Machines.refuse_changes(nil)
    await(fn -> match?([%{"status" => "completed"}, %{"status" => "failed"}], runs(@tid)) end)

    assert [%{"status" => "failed"}] = list(@tid, "subagent")
    assert %{"status" => "failed"} = item(@tid, "subagent")
    assert %{"status" => "failed"} = command(child)
  end

  # The run's end TurnWatch holds leaves a completed turn's subagents running, as its
  # recorded end would; an app-server that exits before the store recovers takes them
  # with it, and the run's end ends them, its provider turn still as Codex ended it.
  test "a completed run the store failed ends the subagents its app-server took with it",
       %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    provider_turn = runtime.turn.ids.provider_turn
    child_command(pid, runtime, native)
    [%{"childThreadId" => child}] = list(@tid, "subagent")

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    assert {:unrecorded, _} = TurnWatch.attempted(run)

    # Its app-server exits; the runtime, failing to record the subagents' end, goes.
    ref = Process.monitor(pid)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

    HalC2.Test.Machines.refuse_changes(nil)
    await(fn -> match?([%{"status" => "failed"}], list(@tid, "run")) end)

    assert [%{"status" => "failed"}] = list(@tid, "subagent")
    assert %{"status" => "failed"} = item(@tid, "subagent")
    assert %{"status" => "failed"} = command(child)

    assert %{"status" => "completed"} =
             Enum.find(list(@tid, "provider-turn"), &(&1["id"] == provider_turn))
  end

  # The app-server that exits before the store recovers holds every subagent the
  # runtime kept running, an earlier run's too: the held run's end ends them all, in
  # the parent thread and in their own.
  test "a completed run the store failed ends an earlier run's subagent its app-server took",
       %{work: work} do
    {pid, runtime, first} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    child_command(pid, runtime, native)
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    await(fn -> match?([%{"status" => "completed"}], list(@tid, "run")) end)

    runtime = dispatch("m2", native["turnId"])
    second = runtime.turn.ids.run
    [%{"childThreadId" => child, "runId" => ^first}] = list(@tid, "subagent")

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    assert {:unrecorded, _} = TurnWatch.attempted(second)

    ref = Process.monitor(pid)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

    HalC2.Test.Machines.refuse_changes(nil)
    await(fn -> match?([%{"status" => "completed"}, %{"status" => "failed"}], runs(@tid)) end)

    assert [%{"status" => "failed"}] = list(@tid, "subagent")
    assert %{"status" => "failed"} = item(@tid, "subagent")
    assert %{"status" => "failed"} = command(child)
  end

  # Found by unrecorded_turns.maude: TurnWatch's try at the end can start before the
  # runtime's `:DOWN` reaches it, and a try that took the runtime for alive kept what
  # went with it running.
  test "a try at the end started before its runtime's exit is heard ends what it took with it",
       %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    child_command(pid, runtime, native)
    [%{"childThreadId" => child}] = list(@tid, "subagent")

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    assert {:unrecorded, _} = TurnWatch.attempted(run)

    # The next try is queued ahead of the runtime's `:DOWN`.
    :sys.suspend(TurnWatch)
    send(TurnWatch, {:retry, run})
    ref = Process.monitor(pid)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    HalC2.Test.Machines.refuse_changes(nil)
    :sys.resume(TurnWatch)

    await(fn -> match?([%{"status" => "failed"}], list(@tid, "run")) end)
    assert [%{"status" => "failed"}] = list(@tid, "subagent")
    assert %{"status" => "failed"} = command(child)
  end

  # Review of #1398: the runtime can go after a try took it for alive and before the
  # try's end is recorded. The run is recorded with its subagent kept running; the try
  # after ends what went with the runtime.
  test "a runtime that goes while the run's end is recorded takes its subagent with it",
       %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    child_command(pid, runtime, native)
    [%{"childThreadId" => child}] = list(@tid, "subagent")

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    assert {:unrecorded, _} = TurnWatch.attempted(run)

    # The next try holds at its first write, the runtime alive when it started.
    gate = make_ref()
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :hold_once, [self(), gate]})
    assert_receive {:held, ^gate, store}, 5_000
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    send(store, {:go, gate})

    # The try after settles the child thread, then the subagent in a write of its own.
    await(fn ->
      match?([%{"status" => "failed"}], list(@tid, "run")) and
        match?([%{"status" => "failed"}], list(@tid, "subagent"))
    end)

    assert %{"status" => "failed"} = command(child)
    assert %{"status" => "failed"} = item(@tid, "subagent")
  end

  # Review of #1398: the try that records the run releases its claim before its answer
  # reaches TurnWatch. A runtime that goes in between still takes its subagent with it,
  # TurnWatch watching it until the end records.
  test "a runtime that goes after the run's end released it takes its subagent with it",
       %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    child_command(pid, runtime, native)
    [%{"childThreadId" => child}] = list(@tid, "subagent")

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    assert {:unrecorded, _} = TurnWatch.attempted(run)

    # The next try holds at its first write; TurnWatch hears its release and answer
    # only after the runtime went.
    gate = make_ref()
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :hold_once, [self(), gate]})
    assert_receive {:held, ^gate, store}, 5_000
    watch = Process.whereis(TurnWatch)
    :erlang.trace(watch, true, [:receive])
    :sys.suspend(watch)
    send(store, {:go, gate})
    assert_receive {:trace, ^watch, :receive, {:attempted, ^run, :ok}}, 5_000
    :erlang.trace(watch, false, [:receive])
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    :sys.resume(watch)

    await(fn ->
      match?([%{"status" => "failed"}], list(@tid, "run")) and
        match?([%{"status" => "failed"}], list(@tid, "subagent"))
    end)

    assert %{"status" => "failed"} = command(child)
    assert %{"status" => "failed"} = item(@tid, "subagent")
  end

  # The subagent an earlier run left running is ended by the run's end however long
  # ago that run settled: its item and node, in cold storage by then, end with it.
  test "a run the store failed ends an earlier run's subagent whose item went cold",
       %{work: work} do
    Application.put_env(:hal_c2, :stream_hot_items, 1)
    on_exit(fn -> Application.delete_env(:hal_c2, :stream_hot_items) end)

    {pid, runtime, first} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    child_command(pid, runtime, native)
    completed = Map.put(native, "turn", %{"id" => native["turnId"], "status" => "completed"})
    notify(pid, runtime, "turn/completed", completed)
    await(fn -> match?([%{"status" => "completed"}], list(@tid, "run")) end)
    %{"id" => item_id, "nodeId" => node_id, "runId" => ^first} = item(@tid, "subagent")

    runtime = dispatch("m2", native["turnId"])
    second = runtime.turn.ids.run
    [%{"childThreadId" => child, "status" => "running"}] = list(@tid, "subagent")
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}

    # Enough of this run's items that memory keeps only them.
    for id <- ~w(msg-a msg-b msg-c) do
      said = %{"type" => "agentMessage", "id" => id, "text" => "on it"}
      notify(pid, runtime, "item/started", Map.put(native, "item", said))
      notify(pid, runtime, "item/completed", Map.put(native, "item", said))
    end

    :ok = GenServer.call(pid, :settle)
    refute item(@tid, "subagent"), "the earlier run's subagent item is still in memory"

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    message = %{"type" => "agentMessage", "id" => "msg-2", "text" => ""}
    notify(pid, runtime, "item/started", Map.put(native, "item", message))
    assert {:unrecorded, _} = TurnWatch.attempted(second)

    HalC2.Test.Machines.refuse_changes(nil)
    await(fn -> match?([%{"status" => "completed"}, %{"status" => "failed"}], runs(@tid)) end)

    assert [%{"status" => "failed"}] = list(@tid, "subagent")
    assert %{"status" => "failed"} = command(child)

    keys = [{"turn-item", item_id}, {"node", node_id}]

    found =
      @tid |> HalC2.Streams.ensure() |> HalC2.Streams.Server.state() |> StreamState.lookup(keys)

    assert %{"status" => "failed"} = found[{"turn-item", item_id}]
    assert %{"status" => "failed"} = found[{"node", node_id}]
  end

  # The dry replay decides against the thread as the store left it: a command that
  # starts and ends after the store failed was never recorded, and its end must not
  # crash the runtime, which would take the provider session with it.
  test "a command the store never recorded ends without crashing the runtime",
       %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_every, []})
    command = %{"type" => "commandExecution", "id" => "cmd-dry", "command" => "ls"}
    notify(pid, runtime, "item/started", Map.put(native, "item", command))

    done =
      Map.merge(command, %{"status" => "completed", "aggregatedOutput" => "", "exitCode" => 0})

    notify(pid, runtime, "item/completed", Map.put(native, "item", done))
    assert {:unrecorded, _} = TurnWatch.attempted(run)

    HalC2.Test.Machines.refuse_changes(nil)
    await(fn -> match?([%{"status" => "failed"}], list(@tid, "run")) end)

    # Its end is handed over (or the runtime went) before the first try at it.
    assert Process.alive?(pid)
    assert [{^pid, _}] = Registry.lookup(HalC2.Codex.Registry, @tid)
  end

  defp child_command(pid, runtime, native, n \\ "1") do
    count = length(list(@tid, "subagent"))
    notify(pid, runtime, "item/started", Map.put(native, "item", collab(n)))
    await(fn -> length(list(@tid, "subagent")) > count end)
    child = %{"threadId" => "native-child-#{n}", "turnId" => "native-child-turn-#{n}"}
    notify(pid, runtime, "item/started", Map.put(child, "item", child_cmd(n)))
    :ok = GenServer.call(pid, :settle)

    %{"childThreadId" => child} =
      Enum.find(list(@tid, "subagent"), &(&1["runId"] == runtime.turn.ids.run))

    assert %{"status" => "running"} = command(child, n)
  end

  defp child_cmd(n),
    do: %{"type" => "commandExecution", "id" => "child-cmd-#{n}", "command" => "ls lib"}

  defp item(thread_id, type), do: Enum.find(list(thread_id, "turn-item"), &(&1["type"] == type))

  defp runs(thread_id), do: Enum.sort_by(list(thread_id, "run"), & &1["ordinal"])

  defp running_turn(work) do
    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    selection = %{"instanceId" => "codex", "model" => "gpt-5.4"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Subagent",
        "modelSelection" => selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    runtime = dispatch("m1", nil)
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, @tid)
    {pid, runtime, runtime.turn.ids.run}
  end

  # The thread's next message, and the runtime once Codex runs its turn.
  defp dispatch(message_id, previous, gone \\ nil) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => message_id,
        "text" => "wait for it",
        "attachments" => [],
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    # A runtime that went may linger in the registry a moment.
    [{pid, _}] =
      await(fn ->
        Enum.reject(Registry.lookup(HalC2.Codex.Registry, @tid), &(elem(&1, 0) == gone))
      end)

    await_state(
      pid,
      &match?(%{turn: %{native_turn_id: id}} when is_binary(id) and id != previous, &1)
    )
  end

  defp collab(n \\ "1") do
    %{
      "type" => "collabAgentToolCall",
      "id" => "collab-#{n}",
      "tool" => "spawnAgent",
      "prompt" => "List the modules in lib",
      "receiverThreadIds" => ["native-child-#{n}"],
      "status" => "inProgress",
      "agentsStates" => %{"native-child-#{n}" => %{"status" => "running"}}
    }
  end

  defp command(child, n \\ "1"),
    do: Enum.find(list(child, "turn-item"), &(&1["id"] =~ "child-cmd-#{n}"))

  # As the app-server would send it.
  defp notify(pid, runtime, method, params),
    do: send(pid, {:json_rpc, runtime.conn, {:notification, method, params}})

  defp list(thread_id, kind),
    do:
      thread_id
      |> HalC2.Streams.ensure()
      |> HalC2.Streams.Server.state()
      |> StreamState.list(kind)

  # Wakes on the thread's own commits.
  defp await(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    case fun.() do
      result when result in [nil, false, []] ->
        receive do
          {:hal_c2_stream, @tid, _} -> await(fun, deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> flunk("never happened")
        end

      result ->
        result
    end
  end

  defp await_state(pid, fun) do
    await(fn ->
      state = :sys.get_state(pid)
      if fun.(state), do: state
    end)
  end
end
