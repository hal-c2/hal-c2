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

  test "a run the store failed ends the work in its subagents' threads once it recovers",
       %{work: work} do
    {pid, runtime, run} = running_turn(work)
    native = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}

    notify(pid, runtime, "item/started", Map.put(native, "item", collab()))
    await(fn -> list(@tid, "subagent") != [] end)

    notify(pid, runtime, "item/started", %{
      "threadId" => "native-child-1",
      "turnId" => "native-child-turn-1",
      "item" => %{"type" => "commandExecution", "id" => "child-cmd", "command" => "ls lib"}
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

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m1",
        "text" => "wait for it",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    [{pid, _}] = await(fn -> Registry.lookup(HalC2.Codex.Registry, @tid) end)
    runtime = await_state(pid, &match?(%{turn: %{native_turn_id: id}} when is_binary(id), &1))
    {pid, runtime, runtime.turn.ids.run}
  end

  defp collab do
    %{
      "type" => "collabAgentToolCall",
      "id" => "collab-1",
      "tool" => "spawnAgent",
      "prompt" => "List the modules in lib",
      "receiverThreadIds" => ["native-child-1"],
      "status" => "inProgress",
      "agentsStates" => %{"native-child-1" => %{"status" => "running"}}
    }
  end

  defp command(child), do: Enum.find(list(child, "turn-item"), &(&1["id"] =~ "child-cmd"))

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
