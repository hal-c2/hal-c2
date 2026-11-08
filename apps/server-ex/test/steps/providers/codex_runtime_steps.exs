defmodule HalC2.Steps.Providers.CodexRuntime do
  @moduledoc """
  More steps for `features/providers/codex.feature`: the app-server's wire and life
  (killed, wedged, closed), retries and what the runtime makes of Codex's items. They
  run on `fake_codex.py` as `HalC2.Steps.Providers.Codex` does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @thread "Codex work"

  # --- a killed app-server ----------------------------------------------------------------

  step "the Codex app-server was killed by a signal", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    {pid, runtime} = World.codex_runtime(context, @thread)
    conn = runtime.conn
    kill_and_await(pid, conn)
    Map.put(context, :killed_conn, conn)
  end

  step ~r/^the user (?<action>sends a follow-up on a thread that used Codex|starts a new Codex thread|delegates a task to Codex)$/,
       %{args: [action]} = context do
    case action do
      "sends a follow-up on a thread that used Codex" ->
        context |> World.post_message(@thread, "hello") |> Map.put(:turn_thread, @thread)

      "starts a new Codex thread" ->
        context |> World.launch_on("Second", "codex", "hello") |> Map.put(:turn_thread, "Second")

      "delegates a task to Codex" ->
        input = %{
          "task" => "hello",
          "mode" => "async",
          "target" => %{"providerInstanceId" => "codex"}
        }

        # Only a thread with a run going can delegate; the tools find it through its
        # sidebar row.
        context = World.launch_on(context, "Lead", "codex", "wait")
        World.await_running(context, "Lead")
        :ok = HalC2.Shell.subscribe(self())
        World.await_row(World.thread_id(context, "Lead"), & &1)

        assert {:ok, %{"taskId" => task_id}} =
                 World.mcp_tool(context, "Lead", "delegate_task", input, "codex")

        state = World.await_state(context, "Lead", &StreamState.get(&1, "subagent")[task_id])
        child = StreamState.get(state, "subagent")[task_id]["childThreadId"]
        :ok = HalC2.Streams.subscribe(child, self(), nil)

        context
        |> put_in([:threads, "Delegated"], child)
        |> Map.put(:turn_thread, "Delegated")
    end
  end

  step "a new Codex app-server is started", context do
    title = context.turn_thread
    statuses = if title == @thread, do: ["completed", "completed"], else: ["completed"]
    World.await_runs(context, title, statuses, 10_000)
    {_, runtime} = World.codex_runtime(context, title)
    assert is_pid(runtime.conn) and runtime.conn != context.killed_conn
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # Kills the app-server by the pid its connection started (never found by name), and
  # returns once the thread's runtime has taken in its connection's end.
  defp kill_and_await(runtime, conn) do
    ref = Process.monitor(conn)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    await_runtime(runtime, &(&1.conn == nil))
  end

  # Each check is a round trip through the runtime's mailbox, behind what reached it first.
  defp await_runtime(runtime, fun, tries \\ 1_000) do
    cond do
      fun.(:sys.get_state(runtime)) -> :ok
      tries == 0 -> flunk("the Codex runtime never got there")
      true -> await_runtime(runtime, fun, tries - 1)
    end
  end
end
