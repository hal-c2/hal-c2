defmodule HalC2.ClaudeHeldNoticeTest do
  # A command the thread waits on that ends between turns holds its notice for
  # Claude's answer (`hold_notice?/2`). Regression: stopping the thread, rewinding it
  # or losing the CLI while the notice was held must not end that command as
  # interrupted or failed, with its summary dropped: it finished.
  use ExUnit.Case, async: false

  alias HalC2.Claude.ThreadRuntime
  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir
  @thread "Build"

  setup %{tmp_dir: dir} do
    context =
      %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}
      |> World.create_project("shop")
      |> then(&World.put_client(&1, World.client(&1)))
      |> World.fake_providers()
      # The fake's turn leaves a background command (task task-build-1) running.
      |> World.launch_on(@thread, "claudeAgent", "background commands: build")

    World.await_runs(context, @thread, ["completed"])
    id = World.thread_id(context, @thread)
    assert {:ok, ["task-build-1"]} = ThreadRuntime.await_background(id, ["task-build-1"], true)

    pid = runtime(context)

    send(pid, {
      :claude,
      :sys.get_state(pid).session,
      {:message,
       %{
         "type" => "system",
         "subtype" => "task_notification",
         "task_id" => "task-build-1",
         "tool_use_id" => "build-1",
         "status" => "completed",
         "summary" => "The build passed"
       }}
    })

    assert [_] = :sys.get_state(pid).notices
    {:ok, context: context, id: id, pid: pid}
  end

  test "stopping the thread keeps the finished command completed", %{context: context, id: id} do
    assert :ok = ThreadRuntime.interrupt(id, nil)
    assert_completed(context)
  end

  test "rewinding the thread keeps the finished command completed", %{context: context, id: id} do
    assert {:ok, _} = ThreadRuntime.rollback(id, %{head: nil})
    assert_completed(context)
  end

  test "the CLI exiting keeps the finished command completed", %{context: context, pid: pid} do
    Process.exit(:sys.get_state(pid).session, :kill)
    assert_completed(context)
  end

  # The command's item ends with the status and summary Claude reported, and the
  # runtime holds neither the notice nor the work.
  defp assert_completed(context) do
    World.await_value(context, @thread, fn state ->
      state
      |> StreamState.list("turn-item")
      |> Enum.any?(&(&1["type"] == "command_execution" and &1["status"] != "running"))
    end)

    assert [%{"status" => "completed", "output" => "The build passed"}] =
             context
             |> World.stream(@thread)
             |> StreamState.list("turn-item")
             |> Enum.filter(&(&1["type"] == "command_execution"))

    assert %{notices: [], work: work} = :sys.get_state(runtime(context))
    assert work == %{}
  end

  defp runtime(context) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    pid
  end
end
