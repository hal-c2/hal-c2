defmodule HalC2.OrchestrationQueueGuardsTest do
  # Regressions `prop/hal_c2/orchestration_prop_test.exs` found: queue commands and
  # messages on threads that cannot take them, and boot recovery missing a running turn.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.TurnWriter

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Settings)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Guards",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    %{thread_id: thread_id}
  end

  test "queue commands on an unknown thread are refused" do
    for {type, extra} <- [
          {"queue.resume", %{}},
          {"queued-run.cancel", %{"runId" => "run-x"}},
          {"queued-run.edit", %{"runId" => "run-x", "text" => "hi"}},
          {"queued-run.reorder", %{"runId" => "run-x"}}
        ] do
      assert {:error, "unknown thread nowhere"} =
               Orchestration.dispatch(
                 Map.merge(%{"type" => type, "threadId" => "nowhere"}, extra)
               )
    end
  end

  test "reordering a run that already started leaves the queue alone", %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    [running] = await_statuses(thread_id, ["running"])

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "queued-run.reorder",
        "threadId" => thread_id,
        "runId" => running["id"]
      })

    assert [%{"status" => "running", "queuePosition" => nil}] = runs(current(thread_id))
  end

  test "promoting a run that is not queued refuses and leaves the turn running",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    [running] = await_statuses(thread_id, ["running"])
    run_id = running["id"]

    assert {:error, "Queued run " <> _} =
             Orchestration.dispatch(%{
               "type" => "queued-message.promote-to-steer",
               "threadId" => thread_id,
               "queuedRunId" => run_id,
               "targetRunId" => run_id
             })

    assert [%{"status" => "running", "queuePosition" => nil}] = runs(current(thread_id))
  end

  test "promoting on an archived thread is refused", %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    [running] = await_statuses(thread_id, ["running"])
    {:ok, _} = send_message(thread_id, "m2")
    [_, queued] = await_statuses(thread_id, ["running", "queued"])
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})

    assert {:error, "Thread #{thread_id} is not active."} ==
             Orchestration.dispatch(%{
               "type" => "queued-message.promote-to-steer",
               "threadId" => thread_id,
               "queuedRunId" => queued["id"],
               "targetRunId" => running["id"]
             })
  end

  test "an archived thread starts nothing from its queue until it is unarchived",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    await_statuses(thread_id, ["running"])
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})
    {:ok, _} = send_message(thread_id, "m2")
    await_statuses(thread_id, ["running", "queued"])

    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    await_statuses(thread_id, ["interrupted", "queued"])

    assert {:error, "Thread #{thread_id} is not active."} ==
             Orchestration.dispatch(%{"type" => "queue.resume", "threadId" => thread_id})

    assert ["interrupted", "queued"] = Enum.map(runs(current(thread_id)), & &1["status"])

    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.unarchive", "threadId" => thread_id})
    {:ok, _} = Orchestration.dispatch(%{"type" => "queue.resume", "threadId" => thread_id})
    await_statuses(thread_id, ["interrupted", "running"])
  end

  # The next queued message starts off the runtime's process once a run has ended: an
  # unarchive landing in between must not start what the archived thread left queued.
  test "a turn that ends on an archived thread leaves its queue to the user",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    [running] = await_statuses(thread_id, ["running"])
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})
    {:ok, _} = send_message(thread_id, "m2")
    await_statuses(thread_id, ["running", "queued"])

    # Its runtime dies, so the run is ended from what the thread recorded.
    for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread_id),
        do: :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)

    # Held, the stream takes the run's end, then the unarchive, then what the end
    # starts once it has returned.
    stream = HalC2.Streams.ensure(thread_id)
    :ok = :sys.suspend(stream)
    :erlang.trace(stream, true, [:receive])

    ender = spawn(fn -> TurnWriter.abandon(thread_id, running["id"], "interrupted", nil) end)
    :erlang.trace(ender, true, [:procs])
    await_call(stream, ender)

    test = self()
    unarchive = %{"type" => "thread.unarchive", "threadId" => thread_id}
    unarchiver = spawn(fn -> send(test, {:unarchived, Orchestration.dispatch(unarchive)}) end)
    await_call(stream, unarchiver)

    :erlang.trace(stream, false, [:receive])
    :ok = :sys.resume(stream)
    assert_receive {:unarchived, {:ok, _}}

    # What follows the end runs in a task of its own; once it is over, the queue waits.
    assert_receive {:trace, ^ender, :spawn, task, _}
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, ^task, _}
    assert ["interrupted", "queued"] = Enum.map(runs(current(thread_id)), & &1["status"])

    {:ok, _} = Orchestration.dispatch(%{"type" => "queue.resume", "threadId" => thread_id})
    await_statuses(thread_id, ["interrupted", "running"])
  end

  # #277: a limit stop on a queue the restart held is what the user resumes at the reset.
  # The sweep hands the queue on once; the next finds a newer run and sends nothing.
  test "a limit stop behind a restart-held queue resumes the queue once",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    await_statuses(thread_id, ["running"])
    {:ok, _} = send_message(thread_id, "m2")
    await_statuses(thread_id, ["running", "queued"])
    restart(thread_id)

    # Sent, not queued: an explicitly queued message would wait behind the held queue.
    {:ok, _} = send_message(thread_id, "m3", "usage limit m3", "start_immediately")
    await_statuses(thread_id, ["interrupted", "failed", "queued"])
    {:ok, _} = recover(thread_id)
    restart(thread_id)

    assert [%{"type" => "queue.resume"}] = sweep(thread_id)
    await_statuses(thread_id, ["interrupted", "failed", "running"])
    assert [] = sweep(thread_id)

    assert ["m1", "m3", "m2"] = Enum.map(runs(current(thread_id)), & &1["userMessageId"])
    assert ["m1", "m2", "m3"] = user_messages(thread_id)
  end

  # #277: the held message says "usage limit" too, so the resumed queue stops at once on
  # a limit of its own, which nobody armed.
  test "a held message that hits the limit again ends the recovery", %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    await_statuses(thread_id, ["running"])
    {:ok, _} = send_message(thread_id, "m2", "usage limit m2")
    await_statuses(thread_id, ["running", "queued"])
    restart(thread_id)

    # Sent, not queued: an explicitly queued message would wait behind the held queue.
    {:ok, _} = send_message(thread_id, "m3", "usage limit m3", "start_immediately")
    await_statuses(thread_id, ["interrupted", "failed", "queued"])
    {:ok, _} = recover(thread_id)
    restart(thread_id)

    assert [%{"type" => "queue.resume"}] = sweep(thread_id)
    await_statuses(thread_id, ["interrupted", "failed", "failed"])
    assert [] = sweep(thread_id)

    assert ["m1", "m3", "m2"] = Enum.map(runs(current(thread_id)), & &1["userMessageId"])
    assert ["m1", "m2", "m3"] = user_messages(thread_id)
  end

  test "a deleted thread refuses messages, updates and queue commands", %{thread_id: thread_id} do
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => thread_id})
    deleted = "Thread #{thread_id} is deleted."

    assert {:error, ^deleted} = send_message(thread_id, "m1")

    assert {:error, ^deleted} =
             Orchestration.dispatch(%{
               "type" => "thread.metadata.update",
               "threadId" => thread_id,
               "title" => "Back"
             })

    assert {:error, ^deleted} =
             Orchestration.dispatch(%{"type" => "queue.resume", "threadId" => thread_id})

    # Deleting it again changes nothing.
    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => thread_id})

    assert runs(current(thread_id)) == []
  end

  test "boot recovery interrupts a running turn behind a cancelled queued message",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    await_statuses(thread_id, ["running"])
    {:ok, _} = send_message(thread_id, "m2")
    [_, queued] = await_statuses(thread_id, ["running", "queued"])

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "queued-run.cancel",
        "threadId" => thread_id,
        "runId" => queued["id"]
      })

    # The sidebar row's status is now the cancelled run's.
    HalC2.Streams.flush_shell(thread_id)
    :sys.get_state(HalC2.Shell)

    # The MC stops: its provider processes go with it.
    for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread_id),
        do: :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)

    assert thread_id in HalC2.Orchestration.Recovery.run()
    await_statuses(thread_id, ["interrupted", "cancelled"])
  end

  defp send_message(thread_id, message_id, text \\ nil, mode \\ "queue_after_active") do
    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "messageId" => message_id,
      "text" => text || "wait #{message_id}",
      "attachments" => [],
      "dispatchMode" => %{"type" => mode}
    })
  end

  # What a restart does to one thread: its provider process goes with the MC, and boot
  # recovery ends what ran and holds the queue.
  defp restart(thread_id) do
    for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread_id),
        do: :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)

    HalC2.Orchestration.Recovery.settle(thread_id)
  end

  # Resume at the reset, as the limit banner asks for the thread's current stop.
  defp recover(thread_id) do
    shell = HalC2.Projection.Shell.thread_shell(current(thread_id))

    Orchestration.dispatch(%{
      "type" => "thread.metadata.update",
      "threadId" => thread_id,
      "limitRecovery" => %{
        "runId" => shell["latestRunId"],
        "resetAt" => shell["usageLimitResetAt"],
        "autoResume" => true
      }
    })
  end

  # The recovery sweep a week on, past every reset the fake reports.
  defp sweep(thread_id) do
    HalC2.Streams.flush_shell(thread_id)
    HalC2.Orchestration.LimitRecovery.sweep(System.system_time(:millisecond) + 7 * 86_400_000)
  end

  defp user_messages(thread_id) do
    for {id, %{"role" => "user"}} <- StreamState.get(current(thread_id), "message"),
        do: id
  end

  defp await_call(stream, from),
    do: assert_receive({:trace, ^stream, :receive, {:"$gen_call", {^from, _}, _}})

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  # Waits until the thread's runs, in order, have these statuses; returns the runs.
  defp await_statuses(thread_id, statuses) do
    runs = runs(current(thread_id))

    if Enum.map(runs, & &1["status"]) == statuses do
      runs
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_statuses(thread_id, statuses)
      after
        5_000 -> flunk("runs never reached #{inspect(statuses)}")
      end
    end
  end
end
