defmodule HalC2.TurnLifecycleTest do
  # Regressions proof/hal_c2/turns_proof_test.exs found.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.TurnWatch

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
