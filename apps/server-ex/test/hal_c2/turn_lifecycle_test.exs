defmodule HalC2.TurnLifecycleTest do
  # Regressions proof/hal_c2/turns_proof_test.exs found: a run's start and end racing a
  # delete, a start that gave up, and a start that could not reach its runtime.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.{TurnWatch, TurnWriter}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  setup %{tmp_dir: dir} = context do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    start_supervised!(
      {DynamicSupervisor,
       name: HalC2.Codex.Supervisor,
       strategy: :one_for_one,
       max_children: context[:max_children] || :infinity}
    )

    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Turns",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    %{thread_id: thread_id}
  end

  # A start that raises before it reaches the runtime (here the runtime cannot start)
  # left the run "starting" for good, and every later message queued behind it.
  @tag max_children: 0
  test "a turn whose runtime cannot start fails, and the next message is not stuck behind it",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    await_statuses(thread_id, ["failed"])

    {:ok, _} = send_message(thread_id, "m2")
    await_statuses(thread_id, ["failed", "failed"])
  end

  # The provider's turn ending after a delete cancelled its run wrote the run as
  # interrupted over the cancel.
  test "a turn that ends after its thread was deleted stays cancelled", %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    [running] = await_statuses(thread_id, ["running"])
    [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    stream = HalC2.Streams.ensure(thread_id)
    test = self()

    :ok = :sys.suspend(stream)
    :erlang.trace(stream, true, [:receive])
    deleter = spawn(fn -> send(test, {:deleted, delete(thread_id)}) end)
    await_call(stream, deleter)
    # Codex ends the turn as interrupted; the runtime writes the end behind the delete.
    :ok = HalC2.Codex.ThreadRuntime.interrupt(thread_id, running["id"])
    await_call(stream, runtime)
    :erlang.trace(stream, false, [:receive])
    :ok = :sys.resume(stream)

    assert_receive {:deleted, {:ok, _}}, 5_000
    assert ["cancelled"] = statuses(thread_id)
  end

  # A delete that cancelled the run while Codex started its turn was undone by the
  # runtime marking the run running once the turn had started.
  test "a turn that starts after its thread was deleted stays cancelled",
       %{thread_id: thread_id} do
    watch = suspend_watch()
    test = self()
    spawn(fn -> send(test, {:sent, send_message(thread_id, "m1")}) end)
    _runtime = await_claim(watch)

    spawn(fn -> send(test, {:deleted, delete(thread_id)}) end)
    await_statuses(thread_id, ["cancelled"])
    :ok = :sys.resume(watch)

    assert_receive {:deleted, {:ok, _}}, 5_000
    assert_receive {:sent, {:ok, _}}, 5_000
    assert ["cancelled"] = statuses(thread_id)
  end

  # A start that gave up waiting on the runtime failed the run and started the next
  # message, then the runtime marked the failed run running: two runs at once, the
  # first never to end.
  test "a turn that starts after its start gave up stays failed, and the next one runs alone",
       %{thread_id: thread_id} do
    watch = suspend_watch()
    test = self()
    spawn(fn -> send(test, {:sent, send_message(thread_id, "m1")}) end)
    runtime = await_claim(watch)
    {:ok, _} = send_message(thread_id, "m2")
    [first, _] = await_statuses(thread_id, ["starting", "queued"])

    # As begin_turn/2 does when its call to the runtime times out.
    :erlang.trace(runtime, true, [:receive])
    TurnWriter.abandon(thread_id, first["id"], "failed", TurnWriter.start_failure(nil, :closed))
    assert_receive {:trace, ^runtime, :receive, {:"$gen_call", _, {:start_turn, _}}}, 5_000
    :erlang.trace(runtime, false, [:receive])
    :ok = :sys.resume(watch)

    await_statuses(thread_id, ["failed", "running"])
    # The first turn's end, which Codex sends as it lets go of it, is not the second's.
    :ok = GenServer.call(runtime, :settle)
    assert ["failed", "running"] = statuses(thread_id)
  end

  defp suspend_watch do
    watch = Process.whereis(TurnWatch)
    :ok = :sys.suspend(watch)
    :erlang.trace(watch, true, [:receive])
    watch
  end

  # The runtime claiming a run from the suspended TurnWatch, once the turn started.
  defp await_claim(watch) do
    assert_receive {:trace, ^watch, :receive, {:"$gen_call", {runtime, _}, {:claim, _, _, _}}},
                   5_000

    :erlang.trace(watch, false, [:receive])
    runtime
  end

  defp send_message(thread_id, message_id) do
    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "messageId" => message_id,
      "text" => "wait #{message_id}",
      "attachments" => [],
      "dispatchMode" => %{"type" => "queue_after_active"}
    })
  end

  defp delete(thread_id),
    do: Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => thread_id})

  defp await_call(stream, from),
    do: assert_receive({:trace, ^stream, :receive, {:"$gen_call", {^from, _}, _}}, 5_000)

  defp statuses(thread_id) do
    HalC2.Streams.ensure(thread_id)
    |> HalC2.Streams.Server.state()
    |> StreamState.list("run")
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.map(& &1["status"])
  end

  # Waits until the thread's runs, in order, have these statuses; returns the runs.
  defp await_statuses(thread_id, statuses) do
    runs =
      HalC2.Streams.ensure(thread_id)
      |> HalC2.Streams.Server.state()
      |> StreamState.list("run")
      |> Enum.sort_by(& &1["ordinal"])

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
