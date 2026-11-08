defmodule HalC2.Steps.Providers.CodexRuntime do
  @moduledoc """
  More steps for `features/providers/codex.feature`: the app-server's wire and life
  (killed, wedged, closed), retries and what the runtime makes of Codex's items. They
  run on `fake_codex.py` as `HalC2.Steps.Providers.Codex` does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.JsonRpc.Connection
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

  # --- an app-server that stops taking input ---------------------------------------------

  step "the Codex app-server stops accepting input but keeps its output open", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    conn = runtime.conn
    open = Task.async(fn -> Connection.call(conn, "test/hang", %{}, 30_000) end)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "test/hang"))
    {:ok, _} = Connection.call(conn, "test/deaf", %{})
    # The next thing written to it, as a steer or an answer would be.
    later = Task.async(fn -> Connection.call(conn, "test/hang", %{}, 30_000) end)
    Map.merge(context, %{open_call: open, later_call: later, killed_conn: conn})
  end

  step "the turn fails with the write error instead of waiting", context do
    assert {:error, %{"message" => message}} = Task.await(context.later_call, 5_000)
    assert message =~ "stopped taking input"
    state = World.await_runs(context, @thread, ["failed"])
    assert Enum.any?(StreamState.list(state, "provider-session"), &(&1["lastError"] == message))
    Map.put(context, :write_error, message)
  end

  step "later requests to that app-server fail with the same error", context do
    assert {:error, %{"message" => message}} = Task.await(context.open_call, 5_000)
    assert message == context.write_error
    {pid, _} = World.codex_runtime(context, @thread)
    await_runtime(pid, &(&1.conn == nil))
    context
  end

  # --- an app-server that closes its output ----------------------------------------------

  step "Codex closes its output and keeps running", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    Connection.notify(runtime.conn, "test/mute", nil)
    Map.put(context, :muted_at, System.monotonic_time(:millisecond))
  end

  # Not waiting the second a program's stop is given, and not its exit code once
  # that stop killed it.
  step "within a quarter of a second the request fails saying Codex's input ended", context do
    assert {:error, %{"message" => message}} = Task.await(context.pending_call, 5_000)
    assert message == "Input from Codex App Server ended while it was still running"
    assert System.monotonic_time(:millisecond) - context.muted_at < 1_000
    context
  end

  step "an exit Codex reports within that time keeps its code", context do
    fake = Path.join(File.cwd!(), "test/support/fake_codex.py")

    {:ok, conn} =
      GenServer.start(Connection,
        cmd: ["python3", "-u", fake],
        handler: self(),
        program: "Codex App Server"
      )

    open = Task.async(fn -> Connection.call(conn, "test/hang", %{}, 30_000) end)
    Connection.notify(conn, "test/mute-exit", nil)

    assert Task.await(open, 5_000) ==
             {:error, %{"message" => "Codex App Server process exited with code 3"}}

    context
  end

  # --- a Codex that exits before it starts -----------------------------------------------

  step "the Codex command exits with code 1 after printing {string}",
       %{args: [said]} = context do
    context = World.fake_providers(context)
    script = Path.join(context.fakes.dir, "dying-codex")
    File.write!(script, "#!/bin/sh\nprintf '%s\\n' #{inspect(said)} >&2\nexit 1\n")
    File.chmod!(script, 0o755)
    World.put_app_env(:codex_command, [script])
    Map.put(context, :codex_said, said)
  end

  step "the MC checks Codex or starts a turn with it", context do
    HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)

    context =
      context |> Map.put(:providers, providers) |> World.launch_on(@thread, "codex", "hello")

    World.await_runs(context, @thread, ["failed"])
    context
  end

  step "the provider status and the failed turn both end with {string}",
       %{args: [said]} = context do
    status = Enum.find(context.providers, &(&1["instanceId"] == "codex"))
    assert String.ends_with?(status["message"], said)
    state = World.stream(context, @thread)
    errors = state |> StreamState.list("provider-session") |> Enum.map(& &1["lastError"])
    assert Enum.any?(errors, &(is_binary(&1) and String.ends_with?(&1, said))), inspect(errors)
    context
  end

  # --- stops over waiting approvals ------------------------------------------------------

  # Upstream #23234: each stop over a waiting approval held one of Codex's 32 request
  # slots. Here the MC's own count of waiting requests is what refuses the 33rd.
  step "32 Codex turns on one Codex instance were stopped while an approval waited", context do
    context = World.fake_providers(context)

    Enum.reduce(1..32, context, fn i, context ->
      context =
        if i == 1,
          do: World.launch_on(context, @thread, "codex", "approve"),
          else: World.post_message(context, @thread, "approve")

      World.await_request(context, @thread)
      run = Enum.find(World.runs(context, @thread), &(&1["status"] == "running"))

      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => World.thread_id(context, @thread),
          "runId" => run["id"]
        })

      World.await_runs(context, @thread, List.duplicate("interrupted", i))
      context
    end)
  end

  step "a Codex turn in another thread asks for an approval", context do
    World.launch_on(context, "Other", "codex", "approve")
  end

  step "the approval is shown to the user", context do
    assert %{"status" => "pending"} = World.await_request(context, "Other")
    {_, runtime} = World.codex_runtime(context, @thread)
    assert runtime.requests == %{}
    requests = StreamState.list(World.stream(context, @thread), "runtime-request")
    # The fake asks each time for the same item, so the 32 are one request, cancelled.
    assert requests != [] and not Enum.any?(requests, &(&1["status"] == "pending"))
    context
  end

  # --- stopping a command of a thread Codex unloaded -------------------------------------

  step "Codex left a command running and the thread was settled", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "run the dev server in the background")

    World.await_runs(context, @thread, ["completed"])
    id = World.thread_id(context, @thread)
    :ok = HalC2.Shell.subscribe(self())
    World.await_row(id, &(&1["runningBackgroundTasks"] != []))
    {{:ok, _}, context} = World.dispatch(context, %{"type" => "thread.settle", "threadId" => id})
    Map.put(context, :thread, @thread)
  end

  step "Codex has since unloaded the thread", context do
    cwd = World.thread(context, @thread)["worktreePath"] || World.project(context, "shop").root
    File.write!(Path.join(cwd, "thread-unloaded"), "")
    context
  end

  step "the command counts as already stopped", context do
    assert {:ok, _} = context.reply

    World.await_provider_log(
      context,
      "codex",
      &(get_in(&1, ["in", "method"]) == "thread/backgroundTerminals/terminate")
    )

    item =
      World.await_value(context, @thread, fn state ->
        Enum.find(
          StreamState.list(state, "turn-item"),
          &(&1["nativeItemRef"]["nativeId"] == "cmd-bg" and &1["status"] != "running")
        )
      end)

    assert item["status"] == "interrupted"
    context
  end

  step "the running banner clears", context do
    World.await_row(World.thread_id(context, @thread), &(&1["runningBackgroundTasks"] == []))
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
