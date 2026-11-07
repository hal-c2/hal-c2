defmodule HalC2.CodexTurnEndTest do
  # How a Codex turn's end treats the subagents it left running: they end with
  # the turn when nothing can report them again (the app-server, and with it
  # the event stream, is gone), and carry on in their own threads when Codex
  # itself reported the turn's end and can still report theirs.
  use ExUnit.Case, async: false

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir
  @thread "Survey"
  @child "native-child-1"

  setup %{tmp_dir: dir} do
    context =
      %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}
      |> World.create_project("shop")
      |> then(&World.put_client(&1, World.client(&1)))
      |> World.fake_providers()
      # The fake leaves a turn that says "wait" open: the test plays Codex's side.
      |> World.launch_on(@thread, "codex", "wait for the survey")

    run = World.await_running(context, @thread)
    spawn_subagent(context)

    World.await_state(context, @thread, fn state ->
      match?([%{"status" => "running"}], StreamState.list(state, "subagent"))
    end)

    {:ok, context: context, run: run}
  end

  # Regression (runs.feature:304): the runtime used to settle subagents only
  # for an interrupted turn, so a stream that ended mid-turn failed the run
  # but left its running subagents running forever.
  test "an event stream that ends mid-turn fails the run and its subagents",
       %{context: context, run: run} do
    kill_app_server(context)

    World.await_runs(context, @thread, ["failed"])

    run_id = run["id"]

    World.await_state(context, @thread, fn state ->
      match?(
        [%{"status" => "failed", "runId" => other}] when other == run_id,
        StreamState.list(state, "subagent")
      )
    end)

    # The thread takes its next message on a fresh app-server.
    context = World.post_message(context, @thread, "hello")
    World.await_runs(context, @thread, ["failed", "completed"])
  end

  # The other side of the same line (codex.feature, upstream #21366): Codex
  # reporting its turn failed does not end the subagents working in their own
  # threads; their finish still lands afterwards.
  test "a turn Codex reports failed leaves its subagents to finish on their own",
       %{context: context} do
    {pid, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{
        "id" => runtime.turn.native_turn_id,
        "status" => "failed",
        "error" => %{"message" => "the turn failed"}
      }
    })

    World.await_runs(context, @thread, ["failed"])
    :ok = GenServer.call(pid, :settle)

    assert [%{"status" => "running"}] =
             context |> World.state(@thread) |> StreamState.list("subagent")

    finish_subagent(context)

    World.await_state(context, @thread, fn state ->
      match?([%{"status" => "completed"}], StreamState.list(state, "subagent"))
    end)
  end

  # A subagent a reported turn left running carries on only while its
  # app-server does: when the stream later ends with no turn active, nothing
  # can report it again, so it fails then — and the run keeps how its turn
  # was reported.
  test "a stream that ends after its turn was reported fails subagents it left running",
       %{context: context, run: run} do
    {pid, _} = report_turn_end(context, "completed")
    :ok = GenServer.call(pid, :settle)

    assert [%{"status" => "running"}] =
             context |> World.state(@thread) |> StreamState.list("subagent")

    kill_app_server(context)

    run_id = run["id"]

    World.await_state(context, @thread, fn state ->
      match?(
        [%{"status" => "failed", "runId" => other}] when other == run_id,
        StreamState.list(state, "subagent")
      )
    end)

    World.await_runs(context, @thread, ["completed"])

    # The thread takes its next message on a fresh app-server.
    context = World.post_message(context, @thread, "hello")
    World.await_runs(context, @thread, ["completed", "completed"])
  end

  # The same end by non-protocol output instead of an exit, again with no
  # turn active: the subagent the reported turn left running fails.
  test "non-protocol output after its turn was reported fails subagents it left running",
       %{context: context, run: run} do
    {pid, _} = report_turn_end(context, "failed")
    :ok = GenServer.call(pid, :settle)

    assert [%{"status" => "running"}] =
             context |> World.state(@thread) |> StreamState.list("subagent")

    {pid, runtime} = World.codex_runtime(context, @thread)
    send(pid, {:json_rpc, runtime.conn, {:invalid, "this is not a protocol message"}})

    run_id = run["id"]

    World.await_state(context, @thread, fn state ->
      match?(
        [%{"status" => "failed", "runId" => other}] when other == run_id,
        StreamState.list(state, "subagent")
      )
    end)

    World.await_runs(context, @thread, ["failed"])

    # The thread takes its next message on a fresh app-server.
    context = World.post_message(context, @thread, "hello")
    World.await_runs(context, @thread, ["failed", "completed"])
  end

  # --- Codex's side --------------------------------------------------------------

  # Codex reports its turn over; the run reads as it ended and the subagent
  # it left running is still running. Returns what `codex_runtime` does.
  defp report_turn_end(context, status) do
    {pid, runtime} = World.codex_runtime(context, @thread)

    turn =
      %{"id" => runtime.turn.native_turn_id, "status" => status}
      |> then(fn turn ->
        if status == "failed",
          do: Map.put(turn, "error", %{"message" => "the turn failed"}),
          else: turn
      end)

    World.codex_notify(context, @thread, "turn/completed", %{"turn" => turn})
    World.await_runs(context, @thread, [status])
    {pid, runtime}
  end

  defp spawn_subagent(context) do
    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "item/started", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => runtime.turn.native_turn_id,
      "item" => %{
        "type" => "collabAgentToolCall",
        "id" => "collab-1",
        "tool" => "spawnAgent",
        "prompt" => "List the modules in lib",
        "senderThreadId" => runtime.native_thread_id,
        "receiverThreadIds" => [@child],
        "status" => "inProgress",
        "agentsStates" => %{@child => %{"status" => "running"}}
      }
    })
  end

  defp finish_subagent(context) do
    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => runtime.native_thread_id,
      "item" => %{
        "type" => "collabAgentToolCall",
        "id" => "collab-1",
        "tool" => "spawnAgent",
        "prompt" => "List the modules in lib",
        "senderThreadId" => runtime.native_thread_id,
        "receiverThreadIds" => [@child],
        "status" => "completed",
        "agentsStates" => %{@child => %{"status" => "completed", "message" => "three modules"}}
      }
    })
  end

  # The fake app-server dies without ending its turn, as a crashed Codex does.
  defp kill_app_server(context) do
    {_, runtime} = World.codex_runtime(context, @thread)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
  end
end
