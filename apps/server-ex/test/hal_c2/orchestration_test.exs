defmodule HalC2.OrchestrationTest do
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  setup %{tmp_dir: dir} do
    # Threads without a project run in the MC's cwd; make that a repo of its own so
    # checkpoints land there and not in this checkout.
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    previous_cwd = File.cwd!()
    File.cd!(work)
    on_exit(fn -> File.cd!(previous_cwd) end)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    Application.put_env(:hal_c2, :claude_command, ["python3", "-u", @fake_claude])
    fake_acp = ["python3", "-u", @fake_acp]
    Application.put_env(:hal_c2, :acp_commands, %{"opencode" => fake_acp, "grok" => fake_acp})

    on_exit(fn ->
      Application.delete_env(:hal_c2, :codex_command)
      Application.delete_env(:hal_c2, :claude_command)
      Application.delete_env(:hal_c2, :acp_commands)
    end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    start_supervised!({Registry, keys: :unique, name: HalC2.Claude.Registry},
      id: :claude_registry
    )

    start_supervised!({Registry, keys: :unique, name: HalC2.Acp.Registry}, id: :acp_registry)
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    %{work: work}
  end

  defp launch(text, instance \\ "codex", mode \\ "full-access", interaction \\ "default") do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Try codex",
        "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"},
        "runtimeMode" => mode,
        "interactionMode" => interaction,
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "msg-user-1", "text" => text, "attachments" => []}
      })

    thread_id
  end

  # A thread whose run is only recorded (no live runtime ever starts): for
  # paths that decide against stream state, or ask a stand-in in the registry.
  defp recorded_run(run_status, thread_fields \\ %{}) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Try codex",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"}
      })

    at = HalC2.Orchestration.Entities.now()
    run_id = "run-recorded-#{System.unique_integer([:positive])}"

    ids = %{
      thread: thread_id,
      run: run_id,
      root_node: "node-recorded-#{run_id}",
      provider_thread: "provider-thread:codex:#{thread_id}",
      message: "m1",
      attempt: "attempt-recorded-#{run_id}",
      instance: "codex",
      driver: "codex"
    }

    run =
      HalC2.Orchestration.Entities.run(
        ids,
        1,
        %{"instanceId" => "codex", "model" => "gpt-5.4"},
        at
      )
      |> Map.merge(%{
        "status" => run_status,
        "queuePosition" => if(run_status == "queued", do: 1)
      })

    message = HalC2.Orchestration.Entities.message(ids, "m1", "user", "first", false, at)

    changes =
      [{"run", run_id, %{"s" => run}}, {"message", "m1", %{"s" => message}}]
      |> then(fn changes ->
        if thread_fields == %{},
          do: changes,
          else: [{"thread", thread_id, %{"s" => thread_fields}} | changes]
      end)

    {:ok, _} = HalC2.Streams.commit(thread_id, :thread, changes)
    {thread_id, run_id}
  end

  # Waits on the thread's own event stream until its run reaches a terminal status.
  defp await_run(thread_id, status) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

        case StreamState.list(state, "run") do
          [%{"status" => ^status} | _] -> state
          _ -> await_run(thread_id, status)
        end
    after
      5_000 -> flunk("run never reached #{status}")
    end
  end

  # The registry still has a session that stops as it is asked (released as idle,
  # crashed): the answer finds no pending request, as with no session at all.
  for reason <- [{:shutdown, :released}, :killed] do
    test "an answer to a session that stops with #{inspect(reason)} as it is asked finds no request" do
      test = self()

      # Not linked: its exit would take the test with it.
      session =
        spawn(fn ->
          {:ok, _} = Registry.register(HalC2.Codex.Registry, "t-gone", nil)
          send(test, :registered)

          receive do
            {:"$gen_call", _from, {:respond, _, _}} -> exit(unquote(Macro.escape(reason)))
          end
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(session, :kill) end)

      assert {:error, "no pending request"} =
               Orchestration.dispatch(%{
                 "type" => "thread.user-input.dismiss",
                 "threadId" => "t-gone",
                 "requestId" => "q1"
               })
    end
  end

  # Any GenServer.call exit reads as a stopped session, so one that is not a way a
  # session stops (another server a runtime adapter called first) is logged with
  # its reason instead of being silently reclassified.
  test "a session call that exits unexpectedly is gone, and the log says why" do
    call = fn why -> fn -> exit({why, {GenServer, :call, [:stand_in, :work, 0]}}) end end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:gone, Orchestration.session_call(call.(:boom), :gone)})
      end)

    assert_received {:gone, :gone}
    assert log =~ "a session call read as stopped exited with :boom"

    # The ways a session stops are logged only at debug: they can still be a
    # nested call's exit, so they are not dropped silently either.
    for why <- [:noproc, :normal, :shutdown, :killed, {:shutdown, :released}] do
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          send(self(), {:gone, Orchestration.session_call(call.(why), :gone)})
        end)

      assert_received {:gone, :gone}
      refute log =~ "read as stopped"

      # The test logger runs at :warning; let the debug line through for this.
      Logger.configure(level: :debug)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(self(), {:gone, Orchestration.session_call(call.(why), :gone)})
        end)

      Logger.configure(level: :warning)

      assert_received {:gone, :gone}
      assert log =~ "a session call read as stopped exited with #{inspect(why)}"
    end
  end

  # The thread's session stops as it is asked to steer the running turn: the command
  # answers as with no session, and the message does not join the turn.
  test "a steer whose session stops as it is asked is refused while the turn runs" do
    thread_id = launch("wait for it")
    _ = await_run(thread_id, "running")
    stand_in(HalC2.Codex.Registry, thread_id, :steer)

    assert {:error, message} =
             send_message(thread_id, "m2", "look here instead", %{
               "dispatchMode" => %{"type" => "start_immediately"},
               "deliveryIntent" => "auto"
             })

    assert message =~ "did not take the message into its running turn (its session stopped)"
    assert ["running"] = Enum.map(runs(current(thread_id)), & &1["status"])
  end

  test "a promoted message whose session stops as it is asked to steer goes first instead" do
    thread_id = launch("wait for it")
    _ = await_run(thread_id, "running")
    {:ok, _} = send_message(thread_id, "m2", "second")
    {:ok, _} = send_message(thread_id, "m3", "third")
    [active, _, third] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))
    stand_in(HalC2.Codex.Registry, thread_id, :steer)

    assert {:ok, _} =
             Orchestration.dispatch(%{
               "type" => "queued-message.promote-to-steer",
               "threadId" => thread_id,
               "queuedRunId" => third["id"],
               "targetRunId" => active["id"]
             })

    state = current(thread_id)
    refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m3"))

    assert %{"status" => "queued", "queuePosition" => 1} =
             StreamState.get(state, "run")[third["id"]]

    # Going first interrupts the turn it was to steer, so that turn ends steered by it.
    assert StreamState.get(state, "run")[active["id"]]["steeredByRunId"] == third["id"]
  end

  test "a message runs a Codex turn and streams it into the thread" do
    thread_id = launch("list the files")
    state = await_run(thread_id, "completed")

    [run] = StreamState.list(state, "run")
    assert %{"ordinal" => 1, "startedAt" => started, "completedAt" => completed} = run
    assert started && completed

    items = StreamState.list(state, "turn-item")

    assert Enum.map(items, & &1["type"]) == [
             "user_message",
             "command_execution",
             "assistant_message",
             "checkpoint"
           ]

    assert Enum.map(items, & &1["ordinal"]) == [0, 1, 2, 3]

    [_user, command, answer, _checkpoint] = items

    assert %{"input" => "ls", "output" => "a.txt\n", "exitCode" => 0, "status" => "completed"} =
             command

    assert %{"text" => "Hello from codex", "streaming" => false, "status" => "completed"} = answer

    assert [%{"role" => "user"}, %{"role" => "assistant", "text" => "Hello from codex"}] =
             StreamState.list(state, "message")

    assert [%{"status" => "idle", "nativeThreadRef" => %{"nativeId" => "native-thread-1"}}] =
             StreamState.list(state, "provider-thread")

    assert [%{"status" => "completed"}] = StreamState.list(state, "provider-turn")
    # Every run, node, and item points at entities that exist.
    nodes = StreamState.get(state, "node")
    assert Map.has_key?(nodes, run["rootNodeId"])
    assert Enum.all?(items, &Map.has_key?(nodes, &1["nodeId"]))
  end

  test "the model options picked in the composer reach Codex's turn", %{tmp_dir: dir} do
    log = Path.join(dir, "codex.log")

    Application.put_env(:hal_c2, :codex_command, [
      "env",
      "FAKE_CODEX_TRACE=#{log}",
      "python3",
      "-u",
      @fake_codex
    ])

    thread_id = "thread-options"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-1",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Options",
        "modelSelection" => %{
          "instanceId" => "codex",
          "model" => "gpt-5.4",
          "options" => [
            %{"id" => "reasoningEffort", "value" => "high"},
            %{"id" => "serviceTier", "value" => "fast"}
          ]
        },
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "msg-user-1", "text" => "hello", "attachments" => []}
      })

    await_run(thread_id, "completed")

    [params] =
      for line <- String.split(File.read!(log), "\n", trim: true),
          %{"in" => %{"method" => "turn/start", "params" => params}} <- [JSON.decode!(line)],
          do: params

    assert %{"effort" => "high", "serviceTier" => "fast"} = params
  end

  test "streamed text is stored as appends, not re-sent whole" do
    thread_id = launch("list the files")
    _ = await_run(thread_id, "completed")

    patches =
      HalC2.Store.reduce_stream(HalC2.Store.path(), thread_id, 0, [], fn e, acc ->
        if e.entity == "turn-item:codex:msg-1", do: [e.patch | acc], else: acc
      end)

    assert Enum.any?(patches, &Map.has_key?(&1, "a"))
    refute Enum.any?(patches, &(get_in(&1, ["s", "text"]) == "Hello from codex"))
  end

  test "a command id used for one parent thread is refused for another, even after a rejection" do
    command = %{"type" => "delegated_task.unknown", "commandId" => "c-parent"}

    first =
      Orchestration.handle(
        "orchestration.dispatchCommand",
        Map.put(command, "parentThreadId", "p1")
      )

    assert {:error, "delegated_task.unknown is not supported" <> _} = first

    assert Orchestration.handle(
             "orchestration.dispatchCommand",
             Map.put(command, "parentThreadId", "p1")
           ) ==
             first

    assert {:error, message} =
             Orchestration.handle(
               "orchestration.dispatchCommand",
               Map.put(command, "parentThreadId", "p2")
             )

    assert message =~ "already handled for thread p1"
  end

  test "interrupt ends the running turn" do
    thread_id = launch("wait for me")
    _ = await_run(thread_id, "running")

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    state = await_run(thread_id, "interrupted")
    assert [%{"status" => "interrupted"}] = StreamState.list(state, "run-attempt")
  end

  # An MC runs its providers as bundled plugins: the run's runtime is then the plugin's
  # module, not the built-in runtime it delegates to, and the stop still reaches it.
  test "interrupt ends the running turn of a bundled provider plugin" do
    Application.put_env(:hal_c2, :bundled_plugins, [HalC2.Plugins.Bundled.Codex])
    on_exit(fn -> Application.delete_env(:hal_c2, :bundled_plugins) end)
    start_supervised!(HalC2.Settings)
    start_supervised!(HalC2.Plugins)
    # A call behind the host's first scan: the bundled plugins are running.
    _ = :sys.get_state(HalC2.Plugins)
    assert {:ok, _, HalC2.Plugins.Bundled.Codex} = HalC2.Plugins.provider("codex")

    thread_id = launch("wait for me")
    await_provider_turn(thread_id)

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    _ = await_run(thread_id, "interrupted")
  end

  # #1233: a run that starts a new conversation lets go of the runtime holding the old
  # one, which would otherwise go on in it, also when that runtime is a bundled plugin's.
  test "a bundled Codex plugin's run in a new conversation starts a new native thread",
       %{tmp_dir: dir} do
    log = Path.join(dir, "sessions.jsonl")
    codex = ["env", "FAKE_CODEX_SESSION_LOG=" <> log, "python3", "-u", @fake_codex]
    Application.put_env(:hal_c2, :codex_command, codex)
    Application.put_env(:hal_c2, :bundled_plugins, [HalC2.Plugins.Bundled.Codex])
    on_exit(fn -> Application.delete_env(:hal_c2, :bundled_plugins) end)
    start_supervised!(HalC2.Settings)
    start_supervised!(HalC2.Plugins)
    _ = :sys.get_state(HalC2.Plugins)

    thread_id = launch("hello")
    [%{"id" => run_id}] = thread_id |> await_run("completed") |> StreamState.list("run")
    [{first, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)

    # As if the history the run handed over had never been answered.
    :ok =
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        [%{"id" => id}] = StreamState.list(state, "provider-thread")
        mark = &Map.put(&1, "unconfirmedRunId", run_id)
        {[Orchestration.upsert(state, "provider-thread", id, mark)], :ok}
      end)

    assert {:ok, _} = send_message(thread_id, "m2", "again")
    _ = await_runs(thread_id, 2)
    refute Process.alive?(first)

    methods =
      for line <- log |> File.read!() |> String.split("\n", trim: true),
          do: Jason.decode!(line)["method"]

    assert methods == ["thread/start", "thread/start"]
  end

  # #1233: Codex answering `turn/start` took the prompt and the history it carried, so
  # a turn stopped before it said anything leaves its conversation to resume.
  test "a Codex turn stopped before its first output resumes its conversation next",
       %{tmp_dir: dir} do
    log = Path.join(dir, "sessions.jsonl")
    codex = ["env", "FAKE_CODEX_SESSION_LOG=" <> log, "python3", "-u", @fake_codex]
    Application.put_env(:hal_c2, :codex_command, codex)
    start_supervised!(HalC2.Settings)
    {_, version} = HalC2.Settings.get()
    work = %{"codex-work" => %{"driver" => "codex", "enabled" => true}}
    {:ok, _} = HalC2.Settings.put(%{"providerInstances" => work}, version)

    thread_id = launch("hello")
    _ = await_statuses(thread_id, ["completed"])
    elsewhere = %{"modelSelection" => %{"instanceId" => "codex-work", "model" => "gpt-5.4"}}
    {:ok, _} = send_message(thread_id, "m2", "hi", elsewhere)
    _ = await_statuses(thread_id, ["completed", "completed"])
    back = %{"modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}}
    {:ok, _} = send_message(thread_id, "m3", "wait for me", back)
    state = await_statuses(thread_id, ["completed", "completed", "running"])

    %{"id" => run_id, "providerThreadId" => own} = List.last(runs(state))
    refute Map.has_key?(StreamState.get(state, "provider-thread")[own], "unconfirmedRunId")

    # The run handed codex-work's turn over, and marked it until Codex took it.
    marks =
      HalC2.Store.reduce_stream(HalC2.Store.path(), thread_id, 0, [], fn e, acc ->
        if e.entity == own, do: [get_in(e.patch, ["s", "unconfirmedRunId"]) | acc], else: acc
      end)

    assert run_id in marks

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    _ = await_statuses(thread_id, ["completed", "completed", "interrupted"])
    {:ok, _} = send_message(thread_id, "m4", "again", back)
    _ = await_statuses(thread_id, ["completed", "completed", "interrupted", "completed"])

    starts =
      for line <- log |> File.read!() |> String.split("\n", trim: true),
          Jason.decode!(line)["method"] == "thread/start",
          do: line

    # One for each instance's conversation, none for a new one.
    assert length(starts) == 2
  end

  # A command finding its conversation gone runs on a new one, which then holds the
  # thread: a later run resumes it with only what came since.
  test "a /compact whose Codex conversation is gone is handed the thread", %{tmp_dir: dir} do
    inputs = Path.join(dir, "inputs.jsonl")

    codex = [
      "env",
      "FAKE_CODEX_INPUT_LOG=" <> inputs,
      "FAKE_CODEX_RESUME_ERROR=no rollout found for thread id",
      "python3",
      "-u",
      @fake_codex
    ]

    Application.put_env(:hal_c2, :codex_command, codex)
    start_supervised!(HalC2.Settings)
    {_, version} = HalC2.Settings.get()
    work = %{"codex-work" => %{"driver" => "codex", "enabled" => true}}
    {:ok, _} = HalC2.Settings.put(%{"providerInstances" => work}, version)

    thread_id = launch("hello")
    _ = await_statuses(thread_id, ["completed"])
    elsewhere = %{"modelSelection" => %{"instanceId" => "codex-work", "model" => "gpt-5.4"}}
    {:ok, _} = send_message(thread_id, "m2", "work was here", elsewhere)
    _ = await_statuses(thread_id, ["completed", "completed"])
    back = %{"modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}}
    {:ok, _} = send_message(thread_id, "m3", "/compact", back)
    _ = await_statuses(thread_id, ["completed", "completed", "completed"])

    [_hello, _work, [%{"text" => compact} | _]] =
      inputs |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert compact =~ "work was here"
    assert String.ends_with?(compact, "/compact")
  end

  # A turn on another instance stops the app-server the runtime had; what it had sent
  # by then is still in the runtime's mailbox.
  test "what a Codex app-server the runtime no longer runs sent belongs to no turn" do
    thread_id = launch("wait for me")
    await_provider_turn(thread_id)
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    %{turn: %{native_turn_id: turn}, native_thread_id: native} = :sys.get_state(pid)
    stopped = spawn(fn -> :ok end)

    send(
      pid,
      {:json_rpc, stopped,
       {:notification, "turn/completed",
        %{"threadId" => native, "turn" => %{"id" => turn, "status" => "completed"}}}}
    )

    assert %{turn: %{native_turn_id: ^turn}} = :sys.get_state(pid)

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    _ = await_run(thread_id, "interrupted")
  end

  # Pending provider requests are a turn's (every request handler needs a turn,
  # and ending one cancels them), so none is live when a turn on another instance
  # replaces the app-server. One somehow left is settled there, not carried: its
  # rpc id belongs to the stopped connection.
  test "a turn on another Codex instance settles requests the old app-server left" do
    start_supervised!(HalC2.Settings)
    {_, version} = HalC2.Settings.get()
    work = %{"codex-work" => %{"driver" => "codex", "enabled" => true}}
    {:ok, _} = HalC2.Settings.put(%{"providerInstances" => work}, version)

    thread_id = launch("hello")
    _ = await_statuses(thread_id, ["completed"])
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    # A call behind the turn's last notification: the runtime has ended it.
    :ok = GenServer.call(pid, :settle)
    %{conn: conn, turn: nil} = :sys.get_state(pid)

    :sys.replace_state(pid, &%{&1 | requests: %{"runtime-request:codex:stale" => 99}})
    assert %{"runtime-request:codex:stale" => 99} = :sys.get_state(pid).requests

    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        {"runtime-request", "runtime-request:codex:stale",
         %{"s" => %{"id" => "runtime-request:codex:stale", "status" => "pending"}}},
        {"turn-item", "turn-item:approval:stale",
         %{"s" => %{"id" => "turn-item:approval:stale", "status" => "running", "ordinal" => 0}}},
        {"node", "node:approval:stale",
         %{"s" => %{"id" => "node:approval:stale", "status" => "running"}}}
      ])

    elsewhere = %{"modelSelection" => %{"instanceId" => "codex-work", "model" => "gpt-5.4"}}
    {:ok, _} = send_message(thread_id, "msg-user-2", "wait for me", elsewhere)
    state = await_statuses(thread_id, ["completed", "running"])

    assert %{conn: renewed, instance: "codex-work", requests: requests} = :sys.get_state(pid)
    assert requests == %{}
    refute renewed == conn

    assert %{"status" => "cancelled"} =
             StreamState.get(state, "runtime-request")["runtime-request:codex:stale"]

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    _ = await_statuses(thread_id, ["completed", "interrupted"])
  end

  # A turn on another instance stops the CLI the runtime had; what it had sent by
  # then is still in the runtime's mailbox.
  test "what a Claude CLI the runtime no longer runs sent belongs to no turn" do
    thread_id = launch("wait for me", "claudeAgent")
    _ = await_run(thread_id, "running")
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
    %{turn: %{ids: %{run: run_id}}} = :sys.get_state(pid)
    stopped = spawn(fn -> :ok end)

    send(
      pid,
      {:claude, stopped,
       {:message, %{"type" => "result", "subtype" => "success", "is_error" => false}}}
    )

    assert %{turn: %{ids: %{run: ^run_id}}} = :sys.get_state(pid)

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    _ = await_run(thread_id, "interrupted")
  end

  # Only a thread from before instances had their own provider threads has anything to
  # bring up to date; one this MC started is never rewritten for it.
  test "a thread's next run leaves the provider thread this MC made for it as it was" do
    thread_id = launch("hello")
    _ = await_statuses(thread_id, ["completed"])
    {:ok, _} = send_message(thread_id, "msg-user-2", "again")
    _ = await_statuses(thread_id, ["completed", "completed"])
    id = HalC2.Orchestration.Entities.provider_thread_id("codex", thread_id)

    [created | updates] =
      HalC2.Store.reduce_stream(HalC2.Store.path(), thread_id, 0, [], fn e, acc ->
        if e.entity == id, do: [e.patch | acc], else: acc
      end)
      |> Enum.reverse()

    assert %{"s" => %{"perInstance" => true}} = created
    refute Enum.any?(updates, &Map.has_key?(&1["s"] || %{}, "perInstance"))
  end

  # Of a thread from before instances had their own provider threads: an instance that
  # did not run there last gets a provider thread of its own covering the runs it had.
  test "a provider thread made for an instance's earlier runs spans them" do
    thread_id = launch("one")
    _ = await_statuses(thread_id, ["completed"])

    for {n, done} <- [{2, 2}, {3, 3}] do
      {:ok, _} = send_message(thread_id, "msg-user-#{n}", "more")
      _ = await_statuses(thread_id, List.duplicate("completed", done))
    end

    [one, two, three] = runs(current(thread_id))
    shared = HalC2.Orchestration.Entities.provider_thread_id("codex", thread_id)
    on = &%{"s" => %{"providerInstanceId" => &1}}

    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        {"run", one["id"], on.("codex-other")},
        {"run", two["id"], on.("codex-other")},
        {"run", three["id"], on.("codex-work")},
        {"provider-thread", shared,
         %{"s" => %{"providerInstanceId" => "codex-work"}, "u" => ["perInstance"]}}
      ])

    {:ok, _} = send_message(thread_id, "msg-user-4", "back home")
    state = await_statuses(thread_id, List.duplicate("completed", 4))
    other = HalC2.Orchestration.Entities.provider_thread_id("codex-other", thread_id)

    assert %{"firstRunOrdinal" => 1, "lastRunOrdinal" => 2, "nativeSinceRunOrdinal" => 3} =
             StreamState.get(state, "provider-thread")[other]
  end

  # The shape the old MC itself wrote: it set the shared record's instance only when
  # it created it, so the instance named there is the one the thread was made on, not
  # the one that ran last. The creator keeps the native thread; the later instance
  # starts a new one.
  test "a shared provider thread keeps its native thread with the instance it was made for" do
    thread_id = launch("one")
    _ = await_statuses(thread_id, ["completed"])

    for {n, done} <- [{2, 2}, {3, 3}] do
      {:ok, _} = send_message(thread_id, "msg-user-#{n}", "more")
      _ = await_statuses(thread_id, List.duplicate("completed", done))
    end

    [one, two, three] = runs(current(thread_id))
    shared = HalC2.Orchestration.Entities.provider_thread_id("codex", thread_id)
    legacy = StreamState.get(current(thread_id), "provider-thread")[shared]
    on = &%{"s" => %{"providerInstanceId" => &1}}

    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        {"run", one["id"], on.("codex-other")},
        {"run", two["id"], on.("codex-other")},
        {"run", three["id"], on.("codex-work")},
        {"provider-thread", shared,
         %{"s" => %{"providerInstanceId" => "codex-other"}, "u" => ["perInstance"]}}
      ])

    {:ok, _} = send_message(thread_id, "msg-user-4", "back home")
    state = await_statuses(thread_id, List.duplicate("completed", 4))
    other = HalC2.Orchestration.Entities.provider_thread_id("codex-other", thread_id)
    work = HalC2.Orchestration.Entities.provider_thread_id("codex-work", thread_id)

    assert %{
             "providerInstanceId" => "codex-other",
             "nativeThreadRef" => native,
             "perInstance" => true
           } = StreamState.get(state, "provider-thread")[other]

    assert native == legacy["nativeThreadRef"]

    assert %{
             "firstRunOrdinal" => 3,
             "lastRunOrdinal" => 3,
             "nativeSinceRunOrdinal" => 4,
             "nativeThreadRef" => nil,
             "perInstance" => true
           } = StreamState.get(state, "provider-thread")[work]
  end

  defp await_provider_turn(thread_id) do
    if StreamState.list(current(thread_id), "provider-turn") == [] do
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_provider_turn(thread_id)
      after
        5_000 -> flunk("no provider turn")
      end
    end
  end

  test "a message's image upload reaches codex inline, with where it is saved" do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "name" => "a.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(png)
      })

    :ok = HalC2.Attachments.store(token, png)

    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Look",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "look at this",
          "attachments" => [
            %{
              "type" => "image",
              "id" => id,
              "name" => "a.png",
              "mimeType" => "image/png",
              "sizeBytes" => byte_size(png)
            }
          ]
        }
      })

    state = await_run(thread_id, "completed")
    items = StreamState.list(state, "turn-item")
    assert Enum.any?(items, &(&1["text"] == "input text,image saved True"))

    assert %{"attachments" => [%{"id" => "thread-" <> _}]} =
             StreamState.get(state, "message")["m1"]
  end

  test "a message sent again under its id keeps its first copies and leaves no others" do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    upload = fn ->
      {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
        HalC2.Attachments.create_upload_url(%{
          "name" => "a.png",
          "mimeType" => "image/png",
          "sizeBytes" => byte_size(png)
        })

      :ok = HalC2.Attachments.store(token, png)

      %{
        "type" => "image",
        "id" => id,
        "name" => "a.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(png)
      }
    end

    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Twice",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "first",
          "attachments" => [upload.()]
        }
      })

    state = await_run(thread_id, "completed")
    %{"attachments" => [%{"id" => first}]} = StreamState.get(state, "message")["m1"]
    again = upload.()
    on_disk = fn -> HalC2.Attachments.dir() |> Path.join("*") |> Path.wildcard() end
    before = length(on_disk.())

    assert {:ok, %{"sequence" => _}} =
             Orchestration.dispatch(%{
               "type" => "message.dispatch",
               "threadId" => thread_id,
               "messageId" => "m1",
               "text" => "first",
               "attachments" => [again]
             })

    # The resend's copy is gone; the pending upload it came from stays, as does the
    # message's own copy.
    assert length(on_disk.()) == before
    assert HalC2.Attachments.path(%{"id" => first})
    assert HalC2.Attachments.path(again)

    assert %{"attachments" => [%{"id" => ^first}]} =
             StreamState.get(current(thread_id), "message")["m1"]
  end

  test "inline context reaches the agent as markers and an envelope, and stays on the message" do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)
    skill = %{"version" => 1, "contextId" => "ctx_s", "kind" => "skill", "name" => "pinchtab"}

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Context",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "repeat with [$pinchtab](hal-c2-context://v1/skill/ctx_s)",
          "context" => %{"version" => 1, "records" => [skill]},
          "attachments" => []
        }
      })

    state = await_run(thread_id, "completed")

    assert Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["text"] ==
                 "repeat with [Skill: $pinchtab; ref=ctx_s]\n\n<hal_c2_context version=\"1\">\n" <>
                   ~s(<context kind="skill" id="ctx_s">\nname: pinchtab\n</context>\n</hal_c2_context>))
           )

    assert %{"context" => %{"records" => [^skill]}} = StreamState.get(state, "message")["m1"]
  end

  test "a launch reuses only an existing empty thread of its project" do
    reuse = fn thread_id, project_id ->
      Orchestration.launch_thread(%{
        "commandId" => "c-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => project_id,
        "title" => "Draft",
        "reuseExistingThread" => true,
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "m1", "text" => "hi", "attachments" => []}
      })
    end

    assert {:error, "Thread missing does not exist."} = reuse.("missing", "project-1")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => "draft",
        "projectId" => "project-1",
        "title" => "Draft"
      })

    assert {:error, "Only an empty active thread" <> _} = reuse.("draft", "project-2")

    thread_id = launch("list the files")
    _ = await_run(thread_id, "completed")
    assert {:error, "Only an empty active thread" <> _} = reuse.(thread_id, "project-1")
  end

  test "the archived threads follow an archive, unarchive or delete as soon as it replies" do
    archived = fn ->
      {:ok, %{"threads" => threads}} =
        Orchestration.handle("orchestration.getArchivedShellSnapshot", %{})

      Enum.map(threads, & &1["id"])
    end

    for id <- ~w(spike vite) do
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.create",
          "threadId" => id,
          "projectId" => "project-1",
          "title" => "Old #{id}"
        })
    end

    command = &Orchestration.dispatch(%{"type" => "thread.#{&1}", "threadId" => &2})

    {:ok, _} = command.("archive", "spike")
    assert archived.() == ["spike"]
    assert {:error, "Old spike is already archived."} = command.("archive", "spike")

    {:ok, _} = command.("unarchive", "spike")
    assert archived.() == []
    # What a second click on Unarchive is told names the thread as the user knows it.
    assert {:error, "Old spike is not archived."} = command.("unarchive", "spike")

    {:ok, _} = command.("archive", "vite")
    assert archived.() == ["vite"]
    {:ok, _} = command.("delete", "vite")
    assert archived.() == []
  end

  test "a launch retried with its command id after a reconnect starts one thread with one message" do
    thread_id = "thread-retried"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    input = %{
      "commandId" => "cmd-retried",
      "threadId" => thread_id,
      "projectId" => "project-1",
      "title" => "Retried",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default",
      "workspaceStrategy" => %{"type" => "root"},
      "initialMessage" => %{"messageId" => "m1", "text" => "wait for me", "attachments" => []}
    }

    # Both calls run at once, as when the first is still in the dropped socket's process.
    # A launch answers once the provider has started the turn, so how long that takes is
    # the machine's; ExUnit's own timeout bounds the wait.
    [first, second] =
      [input, input]
      |> Enum.map(&Task.async(fn -> Orchestration.launch_thread(&1) end))
      |> Task.await_many(:infinity)

    assert {:ok, %{"threadId" => ^thread_id}} = first
    assert {:ok, %{"threadId" => ^thread_id}} = second
    # And once more after both have answered.
    assert {:ok, %{"threadId" => ^thread_id, "resumed" => true}} =
             Orchestration.launch_thread(input)

    state = await_run(thread_id, "running")
    assert [_] = StreamState.list(state, "run")
    assert [%{"id" => "m1", "role" => "user"}] = StreamState.list(state, "message")

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    await_run(thread_id, "interrupted")
  end

  test "a message sent twice with its message id is one message, even while it waits in the queue" do
    thread_id = launch("wait for me")
    _ = await_run(thread_id, "running")

    send_queued = fn ->
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "messageId" => "m2",
        "text" => "next",
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      })
    end

    assert {:ok, %{"sequence" => _}} = send_queued.()
    assert {:ok, %{"sequence" => _}} = send_queued.()
    # The first message, already running, is not sent again either.
    assert {:ok, %{"sequence" => _}} =
             Orchestration.dispatch(%{
               "type" => "message.dispatch",
               "threadId" => thread_id,
               "messageId" => "msg-user-1",
               "text" => "wait for me",
               "attachments" => []
             })

    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    [_, queued] = runs_by_ordinal(state)
    assert ["msg-user-1", "m2"] = state |> runs_by_ordinal() |> Enum.map(& &1["userMessageId"])

    assert ["m2", "msg-user-1"] =
             state |> StreamState.list("message") |> Enum.map(& &1["id"]) |> Enum.sort()

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "queued-run.cancel",
        "threadId" => thread_id,
        "runId" => queued["id"]
      })

    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    await_run(thread_id, "interrupted")
  end

  defp runs_by_ordinal(state),
    do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  test "feedback goes to Codex for the thread's provider thread" do
    thread_id = launch("list the files")
    _ = await_run(thread_id, "completed")
    :ok = HalC2.Shell.subscribe(self())
    await_shell_row(thread_id, &(&1["providerInstanceId"] == "codex"))

    assert {:ok, %{"feedbackId" => "feedback-for-" <> _}} =
             Orchestration.handle("provider.uploadFeedback", %{
               "threadId" => thread_id,
               "reason" => "wrong answer"
             })

    :ok = Orchestration.release_session(thread_id)

    assert {:error,
            %{"_tag" => "ProviderUploadFeedbackError", "cause" => "The provider session" <> _}} =
             Orchestration.handle("provider.uploadFeedback", %{"threadId" => thread_id})
  end

  describe "thread settings and plan mode" do
    test "thread commands set the thread's own fields" do
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")

      for {type, fields} <- [
            {"thread.metadata.update", %{"title" => "Renamed"}},
            {"thread.interaction-mode.set", %{"interactionMode" => "plan"}},
            {"thread.runtime-mode.set", %{"runtimeMode" => "approval-required"}},
            {"thread.pin", %{"orderKey" => "a0"}},
            {"thread.visit", %{"visitedAt" => "2026-09-23T12:00:00.000Z"}},
            {"thread.visit", %{"visitedAt" => "2026-09-23T11:00:00.000Z"}},
            {"thread.archive", %{}}
          ] do
        {:ok, _} =
          Orchestration.dispatch(Map.merge(%{"type" => type, "threadId" => thread_id}, fields))
      end

      assert %{
               "title" => "Renamed",
               "interactionMode" => "plan",
               "runtimeMode" => "approval-required",
               "pinOrderKey" => "a0",
               "pinnedAt" => pinned,
               "lastVisitedAt" => "2026-09-23T12:00:00.000Z",
               "archivedAt" => archived
             } = StreamState.get(current(thread_id), "thread")[thread_id]

      assert is_binary(pinned) and is_binary(archived)
    end

    test "an access change names the version of the rows that holds it" do
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")

      assert {:ok, %{"shell" => %{"mc" => mc, "epoch" => epoch, "rev" => rev}}} =
               Orchestration.dispatch(%{
                 "type" => "thread.runtime-mode.set",
                 "threadId" => thread_id,
                 "runtimeMode" => "approval-required"
               })

      # The row is in the shell by the answer, so a client at that version has it.
      assert mc == to_string(node())

      assert {"thread", %{"runtimeMode" => "approval-required"}} =
               HalC2.Shell.row(node(), thread_id)

      assert {^epoch, now} = HalC2.Shell.version()
      assert now >= rev

      assert {:ok, answer} =
               Orchestration.dispatch(%{
                 "type" => "thread.interaction-mode.set",
                 "threadId" => thread_id,
                 "interactionMode" => "plan"
               })

      refute Map.has_key?(answer, "shell")
    end

    test "regenerating a title marks it in flight until the attempt ends" do
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.metadata.update",
          "commandId" => "cmd-regen",
          "threadId" => thread_id,
          "regenerateTitle" => true
        })

      assert %{"titleRegeneration" => %{"requestId" => "cmd-regen"}} =
               StreamState.get(current(thread_id), "thread")[thread_id]

      # No text generator is installed in tests, so the attempt fails and clears it.
      await_thread(thread_id, &(&1["titleRegeneration"] == nil))
    end

    test "codex in plan mode proposes a plan and keeps a todo list; implementing completes it" do
      thread_id = launch("make a plan", "codex", "full-access", "plan")
      state = await_run(thread_id, "completed")

      assert [
               %{"kind" => "proposed_plan", "status" => "active", "markdown" => "# Plan\n- do it"} =
                 plan
             ] =
               Enum.filter(StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan"))

      items = StreamState.list(state, "turn-item")

      assert %{"markdown" => "# Plan\n- do it", "streaming" => false, "status" => "completed"} =
               Enum.find(items, &(&1["type"] == "proposed_plan"))

      assert %{
               "steps" => [%{"status" => "completed"}, %{"status" => "running"}],
               "explanation" => "Two steps"
             } =
               Enum.find(items, &(&1["type"] == "todo_list"))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => "m-implement",
          "text" => "go ahead",
          "attachments" => [],
          "sourcePlanRef" => %{"threadId" => thread_id, "planId" => plan["id"]},
          "dispatchMode" => %{"type" => "start_immediately"}
        })

      state = await_statuses(thread_id, ["completed", "completed"])
      assert %{"status" => "completed"} = StreamState.get(state, "plan")[plan["id"]]
    end

    test "codex outside plan mode is told so" do
      thread_id = launch("make a plan", "codex")
      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "mode default"))
    end

    test "claude's ExitPlanMode becomes the proposed plan, and TodoWrite a todo list" do
      thread_id = launch("make a plan", "claudeAgent", "full-access", "plan")
      state = await_run(thread_id, "completed")

      assert [%{"status" => "active", "markdown" => "# Plan\n- do it"}] =
               Enum.filter(StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan"))

      refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["toolName"] == "ExitPlanMode"))

      thread_id = launch("keep a todo list", "claudeAgent")
      state = await_run(thread_id, "completed")

      assert [%{"kind" => "todo_list", "status" => "active", "steps" => [first, second]}] =
               StreamState.list(state, "plan")

      assert {first["text"], first["status"], second["status"]} ==
               {"Read the code", "completed", "running"}
    end
  end

  test "pull requests link to a thread by host, repository and number" do
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    key = %{"host" => "github.com", "repository" => "hal-c2/code", "number" => 7}

    link = fn url ->
      Orchestration.dispatch(
        Map.merge(key, %{
          "type" => "thread.pull-request.link",
          "threadId" => thread_id,
          "url" => url,
          "source" => "manual"
        })
      )
    end

    {:ok, _} = link.("https://github.com/hal-c2/code/pull/7")
    {:ok, _} = link.("https://github.com/hal-c2/code/pull/7?again")
    thread = StreamState.get(current(thread_id), "thread")[thread_id]

    assert [%{"number" => 7, "url" => "https://github.com/hal-c2/code/pull/7"}] =
             thread["pullRequests"]

    {:ok, _} =
      Orchestration.dispatch(
        Map.merge(key, %{"type" => "thread.pull-request.unlink", "threadId" => thread_id})
      )

    assert [] = StreamState.get(current(thread_id), "thread")[thread_id]["pullRequests"]
  end

  test "threads are found by what was said in them, the user's words first" do
    thread_id = launch("hello there")
    await_statuses(thread_id, ["completed"])
    :ok = HalC2.Shell.subscribe(self())

    # Search lists active threads from the sidebar rows.
    unless HalC2.Shell.row(node(), thread_id) do
      assert_receive {:hal_c2_shell, _}, 2_000
    end

    assert {:ok, %{"matches" => [%{"threadId" => ^thread_id, "source" => "assistant"} = match]}} =
             HalC2.Search.threads(%{"query" => "FROM CODEX"})

    assert match["snippet"] == "Hello from codex"

    assert {:ok, %{"matches" => [%{"source" => "user", "snippet" => "hello there"}]}} =
             HalC2.Search.threads(%{"query" => "hello"})

    assert {:ok, %{"matches" => []}} = HalC2.Search.threads(%{"query" => "100%"})
  end

  test "a scheduled task sends its prompt into its thread when run" do
    start_supervised!(HalC2.ScheduledTasks)
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])

    {:ok, %{"task" => task}} =
      HalC2.ScheduledTasks.upsert(%{
        "title" => "Nightly",
        "prompt" => "where are we",
        "enabled" => false,
        "schedule" => %{"type" => "fixed_time", "timeOfDay" => "03:00"},
        "projectId" => "project-1",
        "threadId" => thread_id,
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    assert %{"nextRunAt" => nil, "lastRunStatus" => "never"} = task

    assert {:ok, %{"task" => %{"lastRunStatus" => "succeeded", "runCount" => 1}}} =
             HalC2.ScheduledTasks.run_now(%{"id" => task["id"]})

    state = await_statuses(thread_id, ["completed", "completed"])
    assert Enum.any?(StreamState.list(state, "message"), &(&1["text"] == "where are we"))

    {:ok, %{"task" => %{"nextRunAt" => next}}} =
      HalC2.ScheduledTasks.set_enabled(%{"id" => task["id"], "enabled" => true})

    assert is_binary(next)
    {:ok, _} = HalC2.ScheduledTasks.delete(%{"id" => task["id"]})
    assert {:ok, %{"tasks" => []}} = HalC2.ScheduledTasks.list()
  end

  defp scheduled_task(thread_id, prompt) do
    {:ok, %{"task" => task}} =
      HalC2.ScheduledTasks.upsert(%{
        "title" => "Nightly",
        "prompt" => prompt,
        "enabled" => false,
        "schedule" => %{"type" => "fixed_time", "timeOfDay" => "03:00"},
        "projectId" => "project-1",
        "threadId" => thread_id,
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    task
  end

  # A timed-out run must clean up only its own prompt. The stream is held
  # while a user turn runs, so the run times out before its dispatch commits;
  # when the stream opens, the late dispatch queues the prompt behind that
  # turn, and the cleanup cancels it there instead of interrupting the turn.
  test "a timed-out scheduled run held behind a turn cancels only its own prompt" do
    start_supervised!(HalC2.ScheduledTasks)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 1_000)
    on_exit(fn -> Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms) end)

    thread_id = launch("wait for me")
    _ = await_run(thread_id, "running")
    task = scheduled_task(thread_id, "scheduled hello")

    server = HalC2.Streams.ensure(thread_id)
    :ok = :sys.suspend(server)
    caller = Task.async(fn -> HalC2.ScheduledTasks.run_now(%{"id" => task["id"]}) end)

    assert {:ok,
            %{
              "task" => %{
                "lastRunStatus" => "failed",
                "lastRunError" => "The run timed out."
              }
            }} = Task.await(caller, 10_000)

    :ok = :sys.resume(server)
    state = await_statuses(thread_id, ["running", "cancelled"])

    assert [%{"status" => "running"}] = StreamState.list(state, "run-attempt")

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    state = await_statuses(thread_id, ["interrupted", "cancelled"])

    assert [%{"status" => "interrupted"}] = StreamState.list(state, "run-attempt")
  end

  # The same held dispatch on a thread with no turn running: the late prompt
  # lands as a run nothing ever began, and the cleanup ends that run itself.
  test "a timed-out scheduled run whose prompt lands late on an idle thread ends its own run" do
    start_supervised!(HalC2.ScheduledTasks)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 1_000)
    on_exit(fn -> Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms) end)

    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    task = scheduled_task(thread_id, "wait for me")

    server = HalC2.Streams.ensure(thread_id)
    :ok = :sys.suspend(server)
    caller = Task.async(fn -> HalC2.ScheduledTasks.run_now(%{"id" => task["id"]}) end)

    assert {:ok,
            %{
              "task" => %{
                "lastRunStatus" => "failed",
                "lastRunError" => "The run timed out."
              }
            }} = Task.await(caller, 10_000)

    :ok = :sys.resume(server)
    state = await_statuses(thread_id, ["completed", "interrupted"])

    attempts = state |> StreamState.list("run-attempt") |> Enum.map(& &1["status"])
    assert attempts == ["completed", "interrupted"]
  end

  # The prompt landed and its turn is running, driven by the runtime, when
  # the run times out (the fake fire dispatches the prompt itself, then
  # wedges): the cleanup interrupts that run through the runtime — it is
  # not the undriven kind to abandon — and a user run queued behind it is
  # untouched: it runs next and completes.
  test "a timed-out scheduled run whose prompt is already running is interrupted, its queue left alone" do
    start_supervised!(HalC2.ScheduledTasks)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 5_000)

    on_exit(fn ->
      Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms)
      Application.delete_env(:hal_c2, :scheduled_tasks_fire)
    end)

    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    task = scheduled_task(thread_id, "wait for me")
    test_pid = self()

    Application.put_env(:hal_c2, :scheduled_tasks_fire, fn task, fire_key ->
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "commandId" => "scheduled-task:#{fire_key}",
          "threadId" => task["threadId"],
          "messageId" => "scheduled-task-message:#{fire_key}",
          "scheduledTaskId" => task["id"],
          "text" => task["prompt"],
          "attachments" => [],
          "modelSelection" => task["modelSelection"],
          "createdBy" => task["createdBy"],
          "creationSource" => task["creationSource"],
          "dispatchMode" => %{"type" => "queue_after_active"}
        })

      send(test_pid, {:dispatched, self()})

      receive do
        :release -> {:ok, %{}}
      end
    end)

    caller = Task.async(fn -> HalC2.ScheduledTasks.run_now(%{"id" => task["id"]}) end)
    assert_receive {:dispatched, _run_pid}, 5_000

    state = await_statuses(thread_id, ["completed", "running"])

    [%{"id" => scheduled_run}] =
      Enum.filter(runs(state), &(&1["userMessageId"] =~ "scheduled-task-message:"))

    assert HalC2.Orchestration.TurnWatch.driven?(scheduled_run)

    assert {:ok, _} = send_message(thread_id, "msg-user-2", "hello again")

    assert {:ok,
            %{
              "task" => %{
                "lastRunStatus" => "failed",
                "lastRunError" => "The run timed out."
              }
            }} = Task.await(caller, 15_000)

    state = await_statuses(thread_id, ["completed", "interrupted", "completed"])

    attempts = state |> StreamState.list("run-attempt") |> Enum.map(& &1["status"])
    assert attempts == ["completed", "interrupted", "completed"]
  end

  # A fake fire that sends the task's prompt itself, reports it, then wedges
  # (as the already-running test's inline fake does).
  defp dispatching_fire(test_pid) do
    fn task, fire_key ->
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "commandId" => "scheduled-task:#{fire_key}",
          "threadId" => task["threadId"],
          "messageId" => "scheduled-task-message:#{fire_key}",
          "scheduledTaskId" => task["id"],
          "text" => task["prompt"],
          "attachments" => [],
          "modelSelection" => task["modelSelection"],
          "createdBy" => task["createdBy"],
          "creationSource" => task["creationSource"],
          "dispatchMode" => %{"type" => "queue_after_active"}
        })

      send(test_pid, {:dispatched, self()})

      receive do
        :release -> {:ok, %{}}
      end
    end
  end

  # Holds a timed-out run's cleanup between its reading its prompt's run as
  # queued and its cancelling it: the cleanup task's second call into the
  # thread's stream (the streams_hook stage; the first is that read) waits
  # until the test has let the queue promote the run.
  def hold_cleanup(test, :ensured, _id) do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    # The read is made from inside `clean_up_prompt/2`; the cancel that
    # follows it is a tail call, so from there on this process is known by
    # the count the read left in it.
    if Process.get(:cleanup_ensures) != nil or
         Enum.any?(stack, &match?({HalC2.ScheduledTasks, :clean_up_prompt, 2, _}, &1)) do
      count = Process.get(:cleanup_ensures, 0) + 1
      Process.put(:cleanup_ensures, count)

      if count == 2 do
        send(test, {:cleanup_held, self()})

        receive do
          :cleanup_go -> :ok
        after
          10_000 -> :ok
        end
      end
    end

    :ok
  end

  def hold_cleanup(_test, _stage, _id), do: :ok

  # The cleanup reads its prompt's run as queued, the thread's active turn
  # ends and the queue promotes exactly that run, and only then does the
  # cleanup's cancel land — a no-op on a run that has started. The promoted
  # run must still be interrupted, not left to run a turn unattended for a
  # run already recorded as timed out.
  test "a timed-out scheduled run promoted while its cleanup cancels is interrupted" do
    start_supervised!(HalC2.ScheduledTasks)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 5_000)

    on_exit(fn ->
      Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms)
      Application.delete_env(:hal_c2, :scheduled_tasks_fire)
      Application.delete_env(:hal_c2, :streams_hook)
    end)

    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    assert {:ok, _} = send_message(thread_id, "msg-user-2", "wait for me")
    await_statuses(thread_id, ["completed", "running"])

    task = scheduled_task(thread_id, "wait for me")
    Application.put_env(:hal_c2, :scheduled_tasks_fire, dispatching_fire(self()))

    caller = Task.async(fn -> HalC2.ScheduledTasks.run_now(%{"id" => task["id"]}) end)
    assert_receive {:dispatched, _run_pid}, 5_000
    await_statuses(thread_id, ["completed", "running", "queued"])

    Application.put_env(:hal_c2, :streams_hook, {__MODULE__, :hold_cleanup, [self()]})
    assert_receive {:cleanup_held, cleanup}, 15_000

    # The active turn ends while the cleanup is held, promoting the
    # timed-out run's prompt into a running turn of its own.
    assert {:ok, _} =
             Orchestration.dispatch(%{
               "type" => "run.interrupt",
               "threadId" => thread_id,
               "holdQueue" => false
             })

    await_statuses(thread_id, ["completed", "interrupted", "running"])
    send(cleanup, :cleanup_go)

    assert {:ok,
            %{
              "task" => %{
                "lastRunStatus" => "failed",
                "lastRunError" => "The run timed out."
              }
            }} = Task.await(caller, 15_000)

    state = await_statuses(thread_id, ["completed", "interrupted", "interrupted"])

    attempts = state |> StreamState.list("run-attempt") |> Enum.map(& &1["status"])
    assert attempts == ["completed", "interrupted", "interrupted"]
  end

  # Deleting a task ends the turn its in-flight run already started, not
  # only a prompt that lands late: the prompt's turn is visibly running,
  # driven by the runtime, when the task is deleted.
  test "a scheduled run deleted while its prompt's turn is running has that turn interrupted" do
    start_supervised!(HalC2.ScheduledTasks)
    start_supervised!(HalC2.Orchestration.TurnWatch)

    on_exit(fn -> Application.delete_env(:hal_c2, :scheduled_tasks_fire) end)

    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    task = scheduled_task(thread_id, "wait for me")
    Application.put_env(:hal_c2, :scheduled_tasks_fire, dispatching_fire(self()))

    caller = Task.async(fn -> HalC2.ScheduledTasks.run_now(%{"id" => task["id"]}) end)
    assert_receive {:dispatched, _run_pid}, 5_000

    state = await_statuses(thread_id, ["completed", "running"])

    [%{"id" => scheduled_run}] =
      Enum.filter(runs(state), &(&1["userMessageId"] =~ "scheduled-task-message:"))

    assert HalC2.Orchestration.TurnWatch.driven?(scheduled_run)

    assert {:ok, %{"id" => _}} = HalC2.ScheduledTasks.delete(%{"id" => task["id"]})
    assert {:error, %{"message" => "Schedule task not found."}} = Task.await(caller, 10_000)

    state = await_statuses(thread_id, ["completed", "interrupted"])

    attempts = state |> StreamState.list("run-attempt") |> Enum.map(& &1["status"])
    assert attempts == ["completed", "interrupted"]
  end

  # Holds a launch between its thread landing and its first message landing:
  # the launching process is suspended in its stream as it is about to make
  # the second of the launch's calls to it (the streams_hook stage).
  def hold_launch(test, :ensured, id) do
    count = Process.get({:ensured, id}, 0) + 1
    Process.put({:ensured, id}, count)

    if count == 2 do
      server = HalC2.Streams.ensure(id)
      :ok = :sys.suspend(server)
      send(test, {:launch_held, id, server})
    end

    :ok
  end

  def hold_launch(_test, _stage, _id), do: :ok

  # A task that starts a new thread per run, timed out mid-launch: the
  # thread id minted when the run started is where the launch was heading,
  # so when the stream opens and the late dispatch lands there undriven,
  # the cleanup ends that run instead of leaving it in a thread nobody
  # knows.
  test "a new-thread scheduled run that times out mid-launch still has its thread cleaned up" do
    start_supervised!(HalC2.ScheduledTasks)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 2_000)
    Application.put_env(:hal_c2, :streams_hook, {__MODULE__, :hold_launch, [self()]})

    on_exit(fn ->
      Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms)
      Application.delete_env(:hal_c2, :streams_hook)
    end)

    {:ok, %{"task" => task}} =
      HalC2.ScheduledTasks.upsert(%{
        "title" => "Nightly",
        "prompt" => "wait for me",
        "enabled" => false,
        "schedule" => %{"type" => "fixed_time", "timeOfDay" => "03:00"},
        "projectId" => "project-1",
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    caller = Task.async(fn -> HalC2.ScheduledTasks.run_now(%{"id" => task["id"]}) end)
    assert_receive {:launch_held, thread_id, server}, 5_000
    Application.delete_env(:hal_c2, :streams_hook)

    assert {:ok,
            %{
              "task" => %{
                "lastRunStatus" => "failed",
                "lastRunError" => "The run timed out."
              }
            }} = Task.await(caller, 15_000)

    :ok = :sys.resume(server)
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)
    state = await_statuses(thread_id, ["interrupted"])

    assert StreamState.get(state, "thread")[thread_id]
    assert [%{"userMessageId" => "scheduled-task-message:" <> _}] = runs(state)

    attempts = state |> StreamState.list("run-attempt") |> Enum.map(& &1["status"])
    assert attempts == ["interrupted"]
  end

  # Runs in the scheduled run's own process. `:ensured` comes before the call
  # into the stream, so the hook asks the VM to report that process's sends to
  # the test: the send of its transaction is the barrier that the dispatch is
  # on its way, and a signal already sent survives its sender being killed.
  def notify_ensured(test, :ensured, id) do
    :erlang.trace(self(), true, [:send, {:tracer, test}])
    send(test, {:ensured_stream, id})
    :ok
  end

  def notify_ensured(_test, _stage, _id), do: :ok

  # Deleting a task mid-dispatch is the timeout's hazard with another cause:
  # the killed run's dispatch can still commit. It cleans up its own prompt
  # the same way, so nothing runs — or sits undriven — for the deleted task.
  test "a scheduled run deleted mid-dispatch ends the prompt it lands late" do
    start_supervised!(HalC2.ScheduledTasks)
    start_supervised!(HalC2.Orchestration.TurnWatch)

    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    task = scheduled_task(thread_id, "wait for me")

    server = HalC2.Streams.ensure(thread_id)
    :ok = :sys.suspend(server)
    Application.put_env(:hal_c2, :streams_hook, {__MODULE__, :notify_ensured, [self()]})
    on_exit(fn -> Application.delete_env(:hal_c2, :streams_hook) end)
    caller = Task.async(fn -> HalC2.ScheduledTasks.run_now(%{"id" => task["id"]}) end)

    # The run has sent its dispatch to the held stream.
    assert_receive {:ensured_stream, ^thread_id}, 5_000

    assert_receive {:trace, _run, :send, {:"$gen_call", _, {:transact, _, _}}, ^server}, 5_000
    Application.delete_env(:hal_c2, :streams_hook)

    assert {:ok, %{"id" => _}} = HalC2.ScheduledTasks.delete(%{"id" => task["id"]})
    assert {:error, %{"message" => "Schedule task not found."}} = Task.await(caller, 10_000)

    :ok = :sys.resume(server)
    state = await_statuses(thread_id, ["completed", "interrupted"])

    attempts = state |> StreamState.list("run-attempt") |> Enum.map(& &1["status"])
    assert attempts == ["completed", "interrupted"]
  end

  test "an agent's MCP credential reads its own project's threads, and nothing else" do
    start_supervised!(HalC2.Mcp)
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    :ok = HalC2.Shell.subscribe(self())

    unless HalC2.Shell.row(node(), thread_id) do
      assert_receive {:hal_c2_shell, _}, 2_000
    end

    %{authorization: auth} = HalC2.Mcp.server(thread_id, "codex")
    rpc = &HalC2.Mcp.handle(auth, JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => 1}, &1)))

    assert {200, %{"result" => %{"serverInfo" => %{"name" => "hal-c2"}, "instructions" => text}}} =
             rpc.(%{"method" => "initialize", "params" => %{"protocolVersion" => "2025-06-18"}})

    assert text =~ "hal-c2"

    assert {202, nil} =
             HalC2.Mcp.handle(auth, ~s({"jsonrpc":"2.0","method":"notifications/initialized"}))

    {200, %{"result" => %{"tools" => tools}}} = rpc.(%{"method" => "tools/list"})

    assert Enum.any?(
             tools,
             &(&1["name"] == "hal_c2_thread_list" and &1["inputSchema"]["type"] == "object")
           )

    {200, %{"result" => %{"structuredContent" => listed}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{"name" => "hal_c2_thread_list", "arguments" => %{}}
      })

    assert %{"currentThreadId" => ^thread_id, "threads" => [%{"threadId" => ^thread_id}]} = listed

    {200, %{"result" => %{"structuredContent" => read}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{"name" => "hal_c2_thread_read", "arguments" => %{"threadId" => thread_id}}
      })

    assert Enum.map(read["items"], & &1["type"]) == ["user_message", "assistant_message"]

    # An idle caller cannot change things, and other projects are out of reach.
    {200, %{"result" => %{"isError" => true, "content" => [%{"text" => denied}]}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{
          "name" => "hal_c2_thread_send",
          "arguments" => %{"threadId" => thread_id, "message" => "hi"}
        }
      })

    assert denied =~ "parent_not_active"
    assert {401, _} = HalC2.Mcp.handle("Bearer nope", "{}")
  end

  test "reading a thread says where a message too long to send whole was saved" do
    start_supervised!(HalC2.Mcp)
    long = String.duplicate("word ", 30_000)
    thread_id = launch(long)
    await_statuses(thread_id, ["completed"])
    :ok = HalC2.Shell.subscribe(self())

    unless HalC2.Shell.row(node(), thread_id) do
      assert_receive {:hal_c2_shell, _}, 2_000
    end

    %{authorization: auth} = HalC2.Mcp.server(thread_id, "codex")

    {200, %{"result" => %{"structuredContent" => read}}} =
      HalC2.Mcp.handle(
        auth,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "hal_c2_thread_read", "arguments" => %{"threadId" => thread_id}}
        })
      )

    [message, answer] = read["items"]
    assert message["text"] =~ "the whole message is in the attached message.txt"
    assert [%{"name" => "message.txt", "path" => path}] = message["files"]
    assert File.read!(path) == long
    refute Map.has_key?(answer, "files")
  end

  test "a running thread delegates a task, and hears the result when the child finishes" do
    start_supervised!(HalC2.Mcp)
    parent_id = launch("wait here")
    await_statuses(parent_id, ["running"])
    :ok = HalC2.Shell.subscribe(self())

    unless HalC2.Shell.row(node(), parent_id) do
      assert_receive {:hal_c2_shell, _}, 2_000
    end

    %{authorization: auth} = HalC2.Mcp.server(parent_id, "codex")

    call = fn name, arguments ->
      {200, %{"result" => result}} =
        HalC2.Mcp.handle(
          auth,
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => name, "arguments" => arguments}
          })
        )

      result
    end

    %{"structuredContent" => %{"taskId" => task_id, "childThreadId" => child_id}} =
      call.("delegate_task", %{"task" => "hello", "title" => "Say hello"})

    :ok = HalC2.Streams.subscribe(child_id, self(), nil)
    await_statuses(child_id, ["completed"])

    child = StreamState.get(current(child_id), "thread")[child_id]

    # The worker's thread can say which thread asked for it.
    assert [%{"senderThreadId" => ^parent_id}] =
             current(child_id)
             |> StreamState.list("message")
             |> Enum.filter(&(&1["role"] == "user"))

    assert %{"relationshipToParent" => "subagent", "parentThreadId" => ^parent_id} =
             child["lineage"]

    # The parent is still running, so the result waits in its queue.
    state = await_statuses(parent_id, ["running", "queued"])

    assert [%{"status" => "completed", "result" => "Hello from codex"}] =
             StreamState.list(state, "subagent")

    assert Enum.any?(StreamState.list(state, "message"), &(&1["text"] =~ "delegated_task_result"))

    assert %{
             "structuredContent" => %{
               "workState" => "result_available",
               "summary" => "Hello from codex"
             }
           } =
             call.("task_status", %{"taskId" => task_id})

    # Once the parent's turn ends the result starts a run. (Interrupting it would
    # instead stop the task from waking it.) The transcript says the task
    # finished; the envelope is the agent's to read, not a message from the user.
    [parent_run | _] = runs(state)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => parent_id,
        "messageId" => "msg-carry-on",
        "text" => "say Carrying on",
        "attachments" => [],
        "dispatchMode" => %{"type" => "steer_active", "targetRunId" => parent_run["id"]}
      })

    state = await_statuses(parent_id, ["completed", "running"])
    [_, woken] = runs(state)
    item = StreamState.get(state, "turn-item")["turn-item:user:#{woken["userMessageId"]}"]

    assert %{
             "type" => "notification",
             "runId" => run_id,
             "source" => %{"kind" => "delegated_task", "taskIds" => [^task_id]},
             "outcome" => "completed",
             "summary" => "Say hello finished",
             "workerThreadId" => ^child_id,
             "workerTitle" => "Say hello",
             "detail" => "Hello from codex"
           } = item

    assert run_id == woken["id"]
    refute Map.has_key?(item, "text")

    refute Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["type"] == "user_message" and &1["text"] =~ "delegated_task_result")
           )
  end

  describe "queued messages" do
    # The guard lives in `decide_next/2` itself, not only in callers checked
    # earlier in other transactions: a move marked in between must not start.
    test "a moving thread starts nothing from its queue" do
      moving = %{"label" => "desktop", "at" => HalC2.Orchestration.Entities.now()}
      {thread_id, run_id} = recorded_run("queued", %{"moving" => moving})

      assert :ok = Orchestration.start_next(thread_id)

      assert %{"status" => "queued", "queuePosition" => 1} =
               StreamState.get(current(thread_id), "run")[run_id]
    end

    test "a moved thread starts nothing from its queue" do
      moved = %{
        "mc" => "desktop@127.0.0.1",
        "label" => "desktop",
        "at" => HalC2.Orchestration.Entities.now()
      }

      {thread_id, run_id} = recorded_run("queued", %{"movedTo" => moved})

      assert :ok = Orchestration.start_next(thread_id)

      assert %{"status" => "queued", "queuePosition" => 1} =
               StreamState.get(current(thread_id), "run")[run_id]
    end

    test "a message sent on its own cannot defer its start" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      assert {:error, _} =
               Orchestration.dispatch(%{
                 "type" => "message.dispatch",
                 "threadId" => thread_id,
                 "messageId" => "deferred",
                 "text" => "later",
                 "attachments" => [],
                 "dispatchMode" => %{"type" => "defer_start"}
               })

      refute Enum.any?(
               StreamState.list(current(thread_id), "run"),
               &(&1["userMessageId"] == "deferred")
             )
    end

    test "a message sent during a run waits in the queue and starts when the run ends" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      {:ok, _} = send_message(thread_id, "m2", "then list the files")
      {:ok, _} = send_message(thread_id, "m3", "and once more")

      state = await_statuses(thread_id, ["running", "queued", "queued"])
      [_, second, third] = runs(state)
      assert {second["queuePosition"], third["queuePosition"]} == {1, 2}
      assert %{"text" => "then list the files"} = StreamState.get(state, "message")["m2"]

      # Queued messages join the transcript only when their run starts.
      refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      # The run ends without holding the queue, which a user's Stop holds (next test).
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => thread_id,
          "holdQueue" => false
        })

      state = await_statuses(thread_id, ["interrupted", "completed", "completed"])

      assert %{"inputIntent" => "queued_turn", "text" => "then list the files"} =
               Enum.find(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      assert Enum.all?(runs(state), &(&1["queuePosition"] == nil))
    end

    test "a user's stop holds the queue until a message the user sends resumes it" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "then list the files")
      _ = await_statuses(thread_id, ["running", "queued"])

      {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      state = await_statuses(thread_id, ["interrupted", "queued"])
      assert [_, %{"queueHeld" => true}] = runs(state)

      # An agent's message leaves it held; the user's starts, and the queue after it.
      {:ok, _} =
        send_message(thread_id, "m3", "from the agent", %{
          "createdBy" => "agent",
          "creationSource" => "mcp",
          "dispatchMode" => %{"type" => "start_immediately"}
        })

      state = await_statuses(thread_id, ["interrupted", "completed", "queued"])
      assert %{"queueHeld" => true} = Enum.find(runs(state), &(&1["userMessageId"] == "m2"))

      {:ok, _} =
        send_message(thread_id, "m4", "from the user", %{
          "dispatchMode" => %{"type" => "start_immediately"}
        })

      state = await_statuses(thread_id, ["interrupted", "completed", "completed", "completed"])
      assert Enum.map(runs(state), & &1["userMessageId"]) |> Enum.take(-2) == ["m4", "m2"]
    end

    # A client still showing an ended run as active stops it (found by the property).
    test "a stop for a run that already ended holds nothing" do
      thread_id = launch("hello")
      [first] = runs(await_statuses(thread_id, ["completed"]))
      {:ok, _} = send_message(thread_id, "m2", "wait for it")
      _ = await_statuses(thread_id, ["completed", "running"])
      {:ok, _} = send_message(thread_id, "m3", "then list the files")
      _ = await_statuses(thread_id, ["completed", "running", "queued"])

      _ =
        Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => thread_id,
          "runId" => first["id"]
        })

      assert [_, %{"status" => "running"}, queued] = runs(current(thread_id))
      refute queued["queueHeld"]
    end

    # Found by the property: the stop left an interrupt request on the queued run, so
    # once it started it read as being stopped and refused every steer.
    test "a stop for a run still queued does not mark it as being stopped once it starts" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "wait for it")
      [_, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      _ =
        Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => thread_id,
          "runId" => queued["id"]
        })

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => thread_id,
          "holdQueue" => false
        })

      _ = await_statuses(thread_id, ["interrupted", "running"])

      assert {:ok, _} =
               send_message(thread_id, "m3", "also this", %{
                 "deliveryIntent" => "steer",
                 "dispatchMode" => %{"type" => "steer_active", "targetRunId" => queued["id"]}
               })
    end

    test "archiving a thread cancels what it had queued" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "then list the files")
      _ = await_statuses(thread_id, ["running", "queued"])

      {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})

      assert [_, %{"status" => "cancelled", "queuePosition" => nil}] = runs(current(thread_id))
    end

    test "queued runs can be reordered, edited, and cancelled" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      {:ok, _} = send_message(thread_id, "m3", "third")
      [_, second, third] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))

      {:ok, _} =
        queue_command("queued-run.reorder", thread_id, third["id"], %{
          "beforeRunId" => second["id"]
        })

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, third["id"], %{"text" => "third, edited"})

      {:ok, _} = queue_command("queued-run.cancel", thread_id, second["id"])

      state = current(thread_id)
      by_id = Map.new(runs(state), &{&1["id"], &1})
      assert %{"status" => "cancelled", "queuePosition" => nil} = by_id[second["id"]]
      assert %{"status" => "queued", "queuePosition" => 1} = by_id[third["id"]]
      assert %{"text" => "third, edited"} = StreamState.get(state, "message")["m3"]
    end

    test "an edit of a queued run keeps the copies it made" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      [_, queued] = runs(await_statuses(thread_id, ["running", "queued"]))
      upload = pending_upload()
      before = length(attachment_files())

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, queued["id"], %{
          "text" => "second",
          "attachments" => [upload]
        })

      assert %{"attachments" => [%{"id" => claimed}]} =
               StreamState.get(current(thread_id), "message")["m2"]

      assert HalC2.Attachments.path(%{"id" => claimed})
      assert length(attachment_files()) == before + 1
    end

    test "an edit of a run that is no longer queued gives its copies back" do
      thread_id = launch("hello")
      state = await_run(thread_id, "completed")
      [%{"id" => run_id, "userMessageId" => message_id}] = runs(state)
      upload = pending_upload()
      before = length(attachment_files())

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, run_id, %{
          "text" => "too late",
          "attachments" => [upload]
        })

      assert length(attachment_files()) == before
      assert HalC2.Attachments.path(upload)
      assert %{"text" => "hello"} = StreamState.get(current(thread_id), "message")[message_id]
    end

    test "a queued message edited past 120,000 characters is folded, its file joining the others" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))
      long = String.duplicate("y", 130_000)

      {:ok, _} = queue_command("queued-run.edit", thread_id, second["id"], %{"text" => long})

      message = StreamState.get(current(thread_id), "message")["m2"]
      assert String.length(message["text"]) < 10_100

      assert message["text"] =~
               "[... 120000 characters cut here; the whole message is in the attached message.txt ...]"

      assert [%{"name" => "message.txt", "source" => %{"_tag" => "pasted-text"}} = file] =
               message["attachments"]

      assert File.read!(HalC2.Attachments.path(file)) == long
    end

    # The file a long text was folded into holds that text: an edit never leaves it
    # beside text it no longer matches (#1363 review).
    test "an edit of a folded queued message drops the file the old text was folded into" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", String.duplicate("y", 130_000))
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))
      [old] = StreamState.get(current(thread_id), "message")["m2"]["attachments"]
      longer = String.duplicate("z", 140_000)

      {:ok, _} = queue_command("queued-run.edit", thread_id, second["id"], %{"text" => longer})

      assert [%{"name" => "message.txt"} = file] =
               StreamState.get(current(thread_id), "message")["m2"]["attachments"]

      assert File.read!(HalC2.Attachments.path(file)) == longer
      refute HalC2.Attachments.path(old)

      {:ok, _} = queue_command("queued-run.edit", thread_id, second["id"], %{"text" => "short"})

      assert %{"text" => "short", "attachments" => []} =
               StreamState.get(current(thread_id), "message")["m2"]

      refute HalC2.Attachments.path(file)
    end

    # A message may name a file the thread already has, as one sent again with another's
    # attachments does: an edit of the message it was folded for leaves it to that one.
    test "an edit of a folded queued message keeps its old file while another message names it" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", String.duplicate("y", 130_000))
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))
      [old] = StreamState.get(current(thread_id), "message")["m2"]["attachments"]
      {:ok, _} = send_message(thread_id, "m3", "see the file", %{"attachments" => [old]})
      _ = await_statuses(thread_id, ["running", "queued", "queued"])

      {:ok, _} = queue_command("queued-run.edit", thread_id, second["id"], %{"text" => "short"})

      assert %{"text" => "short", "attachments" => []} =
               StreamState.get(current(thread_id), "message")["m2"]

      assert [%{"id" => id}] = StreamState.get(current(thread_id), "message")["m3"]["attachments"]
      assert id == old["id"]
      assert File.read!(HalC2.Attachments.path(old)) == String.duplicate("y", 130_000)
    end

    # The desktop edits a queued message from its stored text, which for a long one is
    # the folded text with its cut mark.
    test "an edit of a folded message's stored text keeps the file its cut mark names" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      whole = String.duplicate("y", 130_000)
      {:ok, _} = send_message(thread_id, "m2", whole)
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))

      %{"text" => folded, "attachments" => [file]} =
        current(thread_id) |> StreamState.get("message") |> Map.fetch!("m2")

      edited = "Typo fixed. " <> folded

      {:ok, _} = queue_command("queued-run.edit", thread_id, second["id"], %{"text" => edited})

      assert %{"text" => ^edited, "attachments" => [^file]} =
               StreamState.get(current(thread_id), "message")["m2"]

      assert File.read!(HalC2.Attachments.path(file)) == whole
    end

    # A long text quoting another message's cut mark, beside a pasted text of the name it
    # quotes, is folded into a file of its own; an edit drops only that (#1363 review).
    test "an edit of a long message quoting a cut mark drops only the file the MC folded" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      pasted = pending_text_upload("message.txt", "pasted by hand")

      quoted =
        "[... 5 characters cut here; the whole message is in the attached message.txt ...]\n" <>
          String.duplicate("y", 130_000)

      {:ok, _} = send_message(thread_id, "m2", quoted, %{"attachments" => [pasted]})
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))

      assert [%{"name" => "message.txt"} = own, %{"name" => "message-2.txt"} = folded] =
               StreamState.get(current(thread_id), "message")["m2"]["attachments"]

      {:ok, _} = queue_command("queued-run.edit", thread_id, second["id"], %{"text" => "short"})

      assert %{"text" => "short", "attachments" => [^own]} =
               StreamState.get(current(thread_id), "message")["m2"]

      assert File.read!(HalC2.Attachments.path(own)) == "pasted by hand"
      refute HalC2.Attachments.path(folded)
    end

    # A client that sends the folded file back without the MC's mark keeps it the fold.
    test "an edit listing a folded file without its mark keeps it the message's fold" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", String.duplicate("y", 130_000))
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))

      %{"text" => text, "attachments" => [file]} =
        StreamState.get(current(thread_id), "message")["m2"]

      sent_back = put_in(file, ["source"], %{"_tag" => "pasted-text"})

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, second["id"], %{
          "text" => "Typo fixed. " <> text,
          "attachments" => [sent_back]
        })

      assert %{"attachments" => [^file]} = StreamState.get(current(thread_id), "message")["m2"]

      {:ok, _} = queue_command("queued-run.edit", thread_id, second["id"], %{"text" => "short"})
      refute HalC2.Attachments.path(file)
    end

    test "an edit naming a folded message's attachments leaves out the file its old text was in" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", String.duplicate("y", 130_000))
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))
      [old] = StreamState.get(current(thread_id), "message")["m2"]["attachments"]
      upload = pending_upload()

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, second["id"], %{
          "text" => "short",
          "attachments" => [old, upload]
        })

      assert [%{"name" => "a.png"} = claimed] =
               StreamState.get(current(thread_id), "message")["m2"]["attachments"]

      assert HalC2.Attachments.path(claimed)
      refute HalC2.Attachments.path(old)
    end

    # The desktop's edit of a queued long message loads the folded text with its file
    # listed; taking the file off and keeping the text drops the file.
    test "an edit that keeps a folded message's text but not its file drops the file" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", String.duplicate("y", 130_000))
      [_, second] = runs(await_statuses(thread_id, ["running", "queued"]))
      message = StreamState.get(current(thread_id), "message")["m2"]
      [old] = message["attachments"]

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, second["id"], %{
          "text" => message["text"],
          "attachments" => []
        })

      assert StreamState.get(current(thread_id), "message")["m2"]["attachments"] in [nil, []]
      refute HalC2.Attachments.path(old)
    end

    test "a long message sent without an id keeps the file it was folded into" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      long = String.duplicate("y", 130_000)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "text" => long,
          "attachments" => [],
          "dispatchMode" => %{"type" => "queue_after_active"}
        })

      [_, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      assert [file] =
               StreamState.get(current(thread_id), "message")[queued["userMessageId"]][
                 "attachments"
               ]

      assert File.read!(HalC2.Attachments.path(file)) == long
    end

    # A resend (the client did not hear the first was taken) folds the text again; the
    # thread keeps the first, and the second file goes with the send.
    test "a long message sent twice leaves only the file its message names" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      long = String.duplicate("y", 130_000)

      {:ok, _} = send_message(thread_id, "m2", long)
      {:ok, _} = send_message(thread_id, "m2", long)

      assert [file] = StreamState.get(current(thread_id), "message")["m2"]["attachments"]
      prefix = HalC2.Attachments.thread_segment(thread_id) <> "-"

      assert Path.wildcard(Path.join(HalC2.Attachments.dir(), prefix <> "*")) ==
               [HalC2.Attachments.path(file)]
    end

    test "an agent that cannot be steered is interrupted, and the steered message goes next" do
      thread_id = launch("wait for it", "grok")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      {:ok, _} = send_message(thread_id, "m3", "third")
      [active, _, third] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "queued-message.promote-to-steer",
          "threadId" => thread_id,
          "queuedRunId" => third["id"],
          "targetRunId" => active["id"]
        })

      state = await_statuses(thread_id, ["interrupted", "completed", "completed"])

      # The interrupted run names the steer that cut it off.
      assert StreamState.get(state, "run")[active["id"]]["steeredByRunId"] == third["id"]

      # The promoted message ran before the one queued ahead of it.
      order =
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(&(&1["messageId"] in ["m2", "m3"]))
        |> Enum.sort_by(& &1["ordinal"])
        |> Enum.map(& &1["messageId"])

      assert order == ["m3", "m2"]
    end

    for instance <- ["codex", "claudeAgent"] do
      test "#{instance}: a message sent during a run steers it" do
        thread_id = launch("wait for it", unquote(instance))
        _ = await_run(thread_id, "running")

        {:ok, _} =
          send_message(thread_id, "m2", "look here instead", %{
            "dispatchMode" => %{"type" => "start_immediately"},
            "deliveryIntent" => "auto"
          })

        state = await_statuses(thread_id, ["completed"])
        items = StreamState.list(state, "turn-item")

        assert %{"inputIntent" => "steer", "runId" => run_id} =
                 Enum.find(items, &(&1["messageId"] == "m2"))

        assert [%{"id" => ^run_id}] = runs(state)
        assert Enum.any?(items, &(&1["text"] == "steered: look here instead"))
      end
    end

    # #98: the steer is recorded before Codex is asked, so the repeat finds it. #384: it
    # hears it was sent only once Codex took it.
    test "the same steer sent twice at once reaches the provider once", %{tmp_dir: dir} do
      log = Path.join(dir, "codex-requests.log")
      gates = held_steers(dir, ["FAKE_CODEX_LOG=#{log}"])
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      steer = fn ->
        send_message(thread_id, "m2", "hold this", %{
          "dispatchMode" => %{"type" => "start_immediately"},
          "deliveryIntent" => "steer"
        })
      end

      # The repeat is decided while Codex holds the first.
      first = Task.async(steer)
      :ok = await_turn_item(thread_id, "turn-item:user:m2")
      # A code, not the words, tells a client to ask again.
      assert {:error, %{"code" => "message_still_sending", "message" => still}} = steer.()
      assert still =~ "still being sent"
      File.touch!(Path.join(gates, "steer"))
      assert {:ok, _} = Task.await(first)
      assert {:ok, _} = steer.()

      state = await_statuses(thread_id, ["completed"])

      steers =
        log
        |> File.stream!()
        |> Enum.map(&JSON.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/steer"))

      assert length(steers) == 1

      assert [%{"id" => "m2"}] =
               Enum.filter(StreamState.list(state, "message"), &(&1["id"] == "m2"))
    end

    # #384: the repeat of a steer Codex goes on to refuse never heard it was sent, its
    # answer leaves no receipt to replay, and a send after the refusal goes through.
    test "a repeat of a steer Codex refuses hears it is still being sent", %{tmp_dir: dir} do
      hold = Path.join(dir, "hold-steer")
      reject = Path.join(dir, "reject-steer")

      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_HOLD_STEER=#{hold}",
        "FAKE_CODEX_REJECT_STEER=#{reject}",
        "python3",
        "-u",
        @fake_codex
      ])

      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      steer = fn ->
        HalC2.Orchestration.dispatch_once(%{
          "type" => "message.dispatch",
          "commandId" => "command-m2",
          "threadId" => thread_id,
          "messageId" => "m2",
          "text" => "say again",
          "attachments" => [],
          "dispatchMode" => %{"type" => "start_immediately"},
          "deliveryIntent" => "steer"
        })
      end

      File.touch!(hold)
      File.touch!(reject)
      first = Task.async(steer)
      :ok = await_turn_item(thread_id, "turn-item:user:m2")
      assert {:error, %{"message" => still}} = steer.()
      assert still =~ "still being sent"
      assert HalC2.Store.meta(HalC2.Store.path(), "command-receipt:command-m2") == nil

      File.rm!(hold)
      assert {:error, refused} = Task.await(first)
      assert refused =~ "did not take the message"
      refute StreamState.get(current(thread_id), "message")["m2"]
      assert {:error, ^refused} = steer.()

      File.rm!(reject)
      assert {:ok, _} = send_message(thread_id, "m2", "say again", %{"deliveryIntent" => "steer"})
      state = await_statuses(thread_id, ["completed"])
      refute Map.has_key?(StreamState.get(state, "message")["m2"], "steer")
    end

    # #384: a refusal can still drop the message once its turn ended, so the repeat has
    # no more reason to call it sent than while the turn ran.
    test "a repeat of a steer whose turn ended mid-ask is still being sent", %{tmp_dir: dir} do
      hold = Path.join(dir, "hold-steer")

      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_HOLD_STEER=#{hold}",
        "python3",
        "-u",
        @fake_codex
      ])

      thread_id = launch("wait for it")
      [%{"id" => run_id}] = await_run(thread_id, "running") |> StreamState.list("run")
      command = %{"dispatchMode" => %{"type" => "start_immediately"}, "deliveryIntent" => "steer"}
      File.touch!(hold)
      first = Task.async(fn -> send_message(thread_id, "m2", "hold this", command) end)
      :ok = await_turn_item(thread_id, "turn-item:user:m2")

      :ok =
        HalC2.Streams.transact(thread_id, :thread, fn state ->
          ended = Orchestration.upsert(state, "run", run_id, &Map.put(&1, "status", "completed"))
          {[ended], :ok}
        end)

      assert {:error, %{"message" => still}} = send_message(thread_id, "m2", "hold this", command)
      assert still =~ "still being sent"

      File.rm!(hold)
      assert {:ok, _} = Task.await(first)
      assert {:ok, _} = send_message(thread_id, "m2", "hold this", command)
    end

    # #384: boot recovery clears the mark, since no send is left to answer for the steer.
    test "a steer an MC restart cut off reads as sent", %{tmp_dir: dir} do
      hold = Path.join(dir, "hold-steer")

      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_HOLD_STEER=#{hold}",
        "python3",
        "-u",
        @fake_codex
      ])

      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      :ok = HalC2.Shell.subscribe(self())
      await_shell_row(thread_id, &(&1["activeRunId"] != nil))
      command = %{"dispatchMode" => %{"type" => "start_immediately"}, "deliveryIntent" => "steer"}
      File.touch!(hold)
      first = Task.async(fn -> send_message(thread_id, "m2", "hold this", command) end)
      :ok = await_turn_item(thread_id, "turn-item:user:m2")

      Task.shutdown(first, :brutal_kill)

      for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread_id),
          do: :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)

      File.rm!(hold)
      assert thread_id in HalC2.Orchestration.Recovery.run()
      state = await_statuses(thread_id, ["interrupted"])
      refute Map.has_key?(StreamState.get(state, "message")["m2"], "steer")

      assert {:ok, _} = send_message(thread_id, "m2", "hold this", command)
    end

    # The message is in the turn before Codex is asked, so a runtime that stops as it
    # is asked must take it back out, or a repeat would find it sent.
    @tag :capture_log
    test "a steer whose runtime stops as it is asked leaves the turn", %{tmp_dir: dir} do
      gates = held_steers(dir)
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      first =
        Task.async(fn ->
          send_message(thread_id, "m2", "hold this", %{
            "dispatchMode" => %{"type" => "start_immediately"},
            "deliveryIntent" => "steer"
          })
        end)

      # Killed only once Codex holds the steer: earlier, the steer could find no
      # turn to steer instead of a runtime stopping under it.
      :ok = await_held_steer(gates)
      [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      Process.exit(runtime, :kill)

      assert {:error, reason} = Task.await(first)
      assert reason =~ "its session stopped"
      state = current(thread_id)
      refute StreamState.get(state, "message")["m2"]
      refute StreamState.get(state, "turn-item")["turn-item:user:m2"]
      # The fake, its connection gone, exits once it answers.
      File.touch!(Path.join(gates, "steer"))
    end

    # A runtime (a plugin provider's, say) can refuse with a reason that is not
    # a string; the sender still hears a bounded refusal, not a crash, and the
    # reserved message still leaves the turn. The run is only recorded, so the
    # odd stand-in registers first and no runtime has to be killed for it.
    @tag :capture_log
    test "a steer refused with a reason that is not a string still leaves the turn" do
      {thread_id, _run_id} = recorded_run("running")
      odd_runtime(thread_id)

      assert {:error, reason} =
               send_message(thread_id, "m2", "hold this", %{
                 "dispatchMode" => %{"type" => "start_immediately"},
                 "deliveryIntent" => "steer"
               })

      assert reason =~ "its runtime answered"
      state = current(thread_id)
      refute StreamState.get(state, "message")["m2"]
      refute StreamState.get(state, "turn-item")["turn-item:user:m2"]
    end

    # The file a long text was folded into is the message's, so a refused send takes
    # it away again.
    @tag :capture_log
    test "a long message the thread refuses leaves no file behind" do
      {thread_id, _run_id} = recorded_run("running")
      odd_runtime(thread_id)

      assert {:error, _} =
               send_message(thread_id, "m2", String.duplicate("y", 130_000), %{
                 "dispatchMode" => %{"type" => "start_immediately"},
                 "deliveryIntent" => "steer"
               })

      refute StreamState.get(current(thread_id), "message")["m2"]
      prefix = HalC2.Attachments.thread_segment(thread_id) <> "-"
      assert Path.wildcard(Path.join(HalC2.Attachments.dir(), prefix <> "*")) == []
    end

    @tag :capture_log
    test "a promote whose runtime stops as it is asked goes back first in the queue",
         %{tmp_dir: dir} do
      gates = held_steers(dir)
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      {:ok, _} = send_message(thread_id, "m3", "hold this")
      [active, _, queued] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))

      promote =
        Task.async(fn ->
          Orchestration.dispatch(%{
            "type" => "queued-message.promote-to-steer",
            "threadId" => thread_id,
            "queuedRunId" => queued["id"],
            "targetRunId" => active["id"]
          })
        end)

      :ok = await_held_steer(gates)
      [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      Process.exit(runtime, :kill)

      assert {:ok, _} = Task.await(promote)
      state = current(thread_id)

      assert %{"status" => "queued", "queuePosition" => 1} =
               StreamState.get(state, "run")[queued["id"]]

      assert StreamState.get(state, "message")["m3"]["runId"] == queued["id"]
      refute StreamState.get(state, "turn-item")["turn-item:user:m3"]
      File.touch!(Path.join(gates, "steer"))
    end

    # Archiving cancels the queue, and the promoted run, out of the queue while Codex
    # was asked, was not in it: the refusal must not queue it again.
    @tag :capture_log
    test "a promote refused after its thread was archived leaves its run cancelled",
         %{tmp_dir: dir} do
      gates = held_steers(dir)
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "hold this")
      [active, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      promote =
        Task.async(fn ->
          Orchestration.dispatch(%{
            "type" => "queued-message.promote-to-steer",
            "threadId" => thread_id,
            "queuedRunId" => queued["id"],
            "targetRunId" => active["id"]
          })
        end)

      :ok = await_turn_item(thread_id, "turn-item:user:m2")
      {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})
      [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      Process.exit(runtime, :kill)

      assert {:error, reason} = Task.await(promote)
      assert reason =~ "the thread was archived"
      state = current(thread_id)

      assert %{"status" => "cancelled", "queuePosition" => nil} =
               StreamState.get(state, "run")[queued["id"]]

      assert StreamState.get(state, "message")["m2"]["runId"] == queued["id"]
      refute StreamState.get(state, "turn-item")["turn-item:user:m2"]
      File.touch!(Path.join(gates, "steer"))
    end

    # A thread that has moved keeps only a forwarding record here: a message queued
    # here again would wait where nothing runs it, so the sender is told to resend.
    @tag :capture_log
    test "a promote refused after its thread moved leaves its run cancelled", %{tmp_dir: dir} do
      gates = held_steers(dir)
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "hold this")
      [active, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      promote =
        Task.async(fn ->
          Orchestration.dispatch(%{
            "type" => "queued-message.promote-to-steer",
            "threadId" => thread_id,
            "queuedRunId" => queued["id"],
            "targetRunId" => active["id"]
          })
        end)

      :ok = await_turn_item(thread_id, "turn-item:user:m2")

      moved = %{
        "mc" => "desktop@127.0.0.1",
        "label" => "desktop",
        "at" => HalC2.Orchestration.Entities.now()
      }

      {:ok, _} =
        HalC2.Streams.commit(thread_id, :thread, [
          {"thread", thread_id, %{"s" => %{"movedTo" => moved}}}
        ])

      [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      Process.exit(runtime, :kill)

      assert {:error, reason} = Task.await(promote)
      assert reason =~ "the thread has moved to desktop; send it again there"
      state = current(thread_id)

      assert %{"status" => "cancelled", "queuePosition" => nil} =
               StreamState.get(state, "run")[queued["id"]]

      assert StreamState.get(state, "message")["m2"]["runId"] == queued["id"]
      refute StreamState.get(state, "turn-item")["turn-item:user:m2"]
      File.touch!(Path.join(gates, "steer"))
    end

    # Codex still holds a steer it did not answer in time, and takes it later: the
    # promoted message stays in the turn rather than also running as its own.
    test "a promote whose runtime answers too late stays in the turn", %{tmp_dir: dir} do
      log = Path.join(dir, "codex-requests.log")
      gates = held_steers(dir, ["FAKE_CODEX_LOG=#{log}"])
      Application.put_env(:hal_c2, :codex_steer_timeout_ms, 100)
      on_exit(fn -> Application.delete_env(:hal_c2, :codex_steer_timeout_ms) end)
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "hold this")
      [active, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      assert {:ok, _} =
               Orchestration.dispatch(%{
                 "type" => "queued-message.promote-to-steer",
                 "threadId" => thread_id,
                 "queuedRunId" => queued["id"],
                 "targetRunId" => active["id"]
               })

      File.touch!(Path.join(gates, "steer"))
      state = await_statuses(thread_id, ["completed", "cancelled"])
      assert StreamState.get(state, "message")["m2"]["runId"] == active["id"]
      assert StreamState.get(state, "turn-item")["turn-item:user:m2"]

      asked =
        log
        |> File.stream!()
        |> Enum.map(&JSON.decode!/1)
        |> Enum.filter(&(&1["method"] in ["turn/start", "turn/steer"]))
        |> Enum.filter(&(inspect(&1["params"]) =~ "hold this"))

      assert [%{"method" => "turn/steer"}] = asked
    end

    # The queue closes up when the promoted message joins the turn, not when the
    # provider answers: Codex may hold the steer for as long as its timeout.
    test "a promote renumbers the queue while Codex still holds the steer", %{tmp_dir: dir} do
      gates = held_steers(dir)
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "hold this")
      {:ok, _} = send_message(thread_id, "m3", "third")
      {:ok, _} = send_message(thread_id, "m4", "fourth")

      [active, first, second, third] =
        runs(await_statuses(thread_id, ["running", "queued", "queued", "queued"]))

      promote =
        Task.async(fn ->
          Orchestration.dispatch(%{
            "type" => "queued-message.promote-to-steer",
            "threadId" => thread_id,
            "queuedRunId" => first["id"],
            "targetRunId" => active["id"]
          })
        end)

      :ok = await_turn_item(thread_id, "turn-item:user:m2")
      state = current(thread_id)

      assert %{"status" => "queued", "queuePosition" => 1} =
               StreamState.get(state, "run")[second["id"]]

      assert %{"status" => "queued", "queuePosition" => 2} =
               StreamState.get(state, "run")[third["id"]]

      File.touch!(Path.join(gates, "steer"))
      assert {:ok, _} = Task.await(promote)
    end

    # #105: Codex took the steer and ended its turn before it said so. The message is
    # in the turn ahead of its answer, not after the turn's end.
    test "a steer taken as the turn ends is shown before its answer" do
      thread_id = launch("closing soon")
      _ = await_run(thread_id, "running")

      {:ok, _} =
        send_message(thread_id, "m2", "look here instead", %{
          "dispatchMode" => %{"type" => "start_immediately"},
          "deliveryIntent" => "steer"
        })

      state = await_statuses(thread_id, ["completed"])
      items = StreamState.list(state, "turn-item")
      steer = Enum.find(items, &(&1["messageId"] == "m2"))
      answer = Enum.find(items, &(&1["text"] == "steered: look here instead"))

      assert steer["runId"] == answer["runId"]
      assert steer["ordinal"] < answer["ordinal"]
    end

    test "a queued message promoted to steer joins the running turn" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      [active, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "queued-message.promote-to-steer",
          "threadId" => thread_id,
          "queuedRunId" => queued["id"],
          "targetRunId" => active["id"]
        })

      state = await_statuses(thread_id, ["completed", "cancelled"])

      assert %{"inputIntent" => "promoted_queued_to_steer", "runId" => run_id} =
               Enum.find(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      assert run_id == active["id"]
    end

    test "restart interrupts the running turn and starts the message next" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      {:ok, _} =
        send_message(thread_id, "m2", "do this instead", %{
          "dispatchMode" => %{"type" => "start_immediately"},
          "deliveryIntent" => "restart"
        })

      state = await_statuses(thread_id, ["interrupted", "completed"])
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      # The interrupted run names the steer that cut it off; a stop or a crash leaves
      # no such mark.
      [interrupted, restart] = runs(state)
      assert interrupted["steeredByRunId"] == restart["id"]
      assert restart["userMessageId"] == "m2"
      refute Map.has_key?(restart, "steeredByRunId")
    end
  end

  describe "Codex background terminals" do
    setup %{tmp_dir: dir} do
      log = Path.join(dir, "codex-requests.log")

      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_LOG=#{log}",
        "python3",
        "-u",
        @fake_codex
      ])

      :ok = HalC2.Shell.subscribe(self())
      %{log: log}
    end

    test "a command left running keeps its session until Codex reports it ended" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))
      assert [%{"status" => "running", "input" => "npm run dev"}] = commands(thread_id)

      assert HalC2.Orchestration.IdleSessions.check() == []
      assert [_] = Registry.lookup(HalC2.Codex.Registry, thread_id)

      codex_says(thread_id, "item/completed", %{
        "threadId" => "native-thread-1",
        "turnId" => "native-turn-1",
        "item" => %{
          "type" => "commandExecution",
          "id" => "cmd-bg",
          "command" => "npm run dev",
          "status" => "completed",
          "aggregatedOutput" => "listening on 5173\nbye\n",
          "exitCode" => 0
        }
      })

      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      # The exit wakes the thread with a turn telling Codex; the session idles after it.
      state = await_runs(thread_id, 2)

      assert [_, %{"userMessageId" => wake}] = runs(state)

      assert StreamState.get(state, "message")[wake]["text"] ==
               "Background command completed (exit 0): npm run dev\n\nOutput tail:\nlistening on 5173\nbye"

      assert [%{"status" => "completed", "output" => "listening on 5173\nbye\n", "exitCode" => 0}] =
               Enum.filter(commands(thread_id), &(&1["input"] == "npm run dev"))

      await_shell_row(thread_id, &(&1["activeRunId"] == nil))
      assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
    end

    test "stopping the thread between turns terminates the command", %{log: log} do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert [%{"status" => "interrupted"}] = commands(thread_id)
      assert [%{"processId" => "4275"}] = terminated(log)

      assert {:error, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    end

    # A restart's interrupt for a run that ended before it arrived names an earlier
    # run than the one that left the command (#474); a client's stop names the latest.
    test "an interrupt between turns pinned to an earlier run leaves the command running",
         %{log: log} do
      thread_id = launch("start the dev server in the background")
      [%{"id" => run_id}] = thread_id |> await_run("completed") |> StreamState.list("run")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))
      pinned = &%{"type" => "run.interrupt", "threadId" => thread_id, "runId" => &1}

      assert {:error, "no running turn"} = Orchestration.dispatch(pinned.("run:earlier"))
      assert [%{"status" => "running"}] = commands(thread_id)
      assert terminated(log) == []

      assert {:ok, _} = Orchestration.dispatch(pinned.(run_id))
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert [%{"status" => "interrupted"}] = commands(thread_id)
    end

    # The completed-stop grace is for a live thread whose turn ended as the stop
    # arrived; a deleted thread refuses the stop (the orchestration property's
    # delete-then-interrupt_run counterexample).
    test "an interrupt pinned to a deleted thread's completed run is refused" do
      thread_id = launch("start the dev server in the background")
      [%{"id" => run_id}] = thread_id |> await_run("completed") |> StreamState.list("run")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => thread_id})

      assert {:error, "no running turn"} =
               Orchestration.dispatch(%{
                 "type" => "run.interrupt",
                 "threadId" => thread_id,
                 "runId" => run_id
               })
    end

    # The latest run went to another provider; the command an earlier Codex run left
    # is still the thread's latest run's to stop, as the client's stop names it.
    test "an interrupt pinned to a later run on another provider stops the command",
         %{log: log} do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))
      claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}}
      {:ok, _} = send_message(thread_id, "msg-claude", "hello", claude)
      [_, %{"id" => latest}] = runs(await_statuses(thread_id, ["completed", "completed"]))

      assert {:ok, _} =
               Orchestration.dispatch(%{
                 "type" => "run.interrupt",
                 "threadId" => thread_id,
                 "runId" => latest
               })

      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))

      assert [%{"status" => "interrupted"}] =
               Enum.filter(commands(thread_id), &(&1["nativeItemRef"]["nativeId"] == "cmd-bg"))

      assert [%{"processId" => "4275"}] = terminated(log)
    end

    # Codex holds the command an earlier run left while Claude runs the latest. The
    # stop reaches Claude's turn, before Codex or not, and like a stop of a turn on
    # one provider it leaves the command; the next stop, between turns, ends it.
    test "an interrupt pinned to a turn on another provider stops the turn, then the command",
         %{log: log} do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))
      claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}}
      {:ok, _} = send_message(thread_id, "msg-claude", "wait for me", claude)
      [_, %{"id" => latest}] = runs(await_statuses(thread_id, ["completed", "running"]))
      stop = %{"type" => "run.interrupt", "threadId" => thread_id, "runId" => latest}

      cmd_bg = fn ->
        Enum.filter(commands(thread_id), &(&1["nativeItemRef"]["nativeId"] == "cmd-bg"))
      end

      assert {:ok, _} = Orchestration.dispatch(stop)
      _ = await_statuses(thread_id, ["completed", "interrupted"])
      assert [%{"status" => "running"}] = cmd_bg.()
      assert terminated(log) == []

      assert {:ok, _} = Orchestration.dispatch(stop)
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert [%{"status" => "interrupted"}] = cmd_bg.()
      assert [%{"processId" => "4275"}] = terminated(log)
    end

    test "an interrupted turn terminates the command it started", %{log: log} do
      thread_id = launch("start the dev server in the background and wait")
      _ = await_run(thread_id, "running")
      await_item(thread_id, "command_execution")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      _ = await_run(thread_id, "interrupted")
      assert [%{"status" => "interrupted"}] = commands(thread_id)
      assert [%{"processId" => "4275"}] = terminated(log)
    end

    test "the command fails when Codex exits" do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))

      [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      Process.exit(:sys.get_state(pid).conn, :kill)

      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert [%{"status" => "failed"}] = commands(thread_id)
    end

    test "releasing the session ends the command" do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))

      assert :ok = Orchestration.release_session(thread_id)
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert [%{"status" => "interrupted"}] = commands(thread_id)
    end

    defp commands(thread_id) do
      current(thread_id)
      |> StreamState.list("turn-item")
      |> Enum.filter(&(&1["type"] == "command_execution"))
    end

    defp terminated(log) do
      for line <- String.split(File.read!(log), "\n", trim: true),
          %{"method" => "thread/backgroundTerminals/terminate", "params" => params} <-
            [JSON.decode!(line)],
          do: params
    end

    defp codex_says(thread_id, method, params) do
      [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      send(pid, {:json_rpc, :sys.get_state(pid).conn, {:notification, method, params}})
    end
  end

  describe "Grok background work" do
    setup do
      :ok = HalC2.Shell.subscribe(self())
      :ok
    end

    @child "0f8e2a4c-5b6d-4e7f-8a9b-1c2d3e4f5a6b"

    test "a background shell and subagent keep the agent until Grok reports them ended" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      assert [
               %{"type" => "command_execution", "status" => "running", "input" => "npm run dev"},
               %{"type" => "subagent", "status" => "running"}
             ] = background_items(thread_id)

      assert HalC2.Orchestration.IdleSessions.check() == []
      assert [_] = Registry.lookup(HalC2.Acp.Registry, thread_id)

      grok_says(thread_id, "x.ai/task_completed", %{
        "sessionId" => session(thread_id),
        "update" => %{
          "sessionUpdate" => "task_completed",
          "task_snapshot" => %{"task_id" => "task-sh"}
        }
      })

      grok_says(thread_id, "session/update", %{
        "sessionId" => session(thread_id),
        "update" => %{
          "sessionUpdate" => "user_message_chunk",
          "content" => %{
            "type" => "text",
            "text" =>
              ~s[Background subagent "#{@child}" (type: "general") completed successfully.]
          }
        }
      })

      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert ["completed", "completed"] = Enum.map(background_items(thread_id), & &1["status"])
      assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
    end

    test "the subagent's answer after the turn still reaches its child thread" do
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      grok_says(thread_id, "session/update", %{
        "sessionId" => @child,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "the repo has a lib"}
        }
      })

      grok_says(thread_id, "x.ai/task_completed", %{
        "sessionId" => session(thread_id),
        "update" => %{
          "sessionUpdate" => "task_completed",
          "task_snapshot" => %{"task_id" => @child}
        }
      })

      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"]) == 1))

      assert [%{"status" => "completed", "result" => "the repo has a lib"}] =
               StreamState.list(current(thread_id), "subagent")
    end

    test "stopping the thread between turns ends the work and the agent" do
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))
      conn = :sys.get_state(runtime_pid(thread_id)).conn
      ref = Process.monitor(conn)

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))

      assert ["interrupted", "interrupted"] =
               Enum.map(background_items(thread_id), & &1["status"])

      assert_receive {:DOWN, ^ref, :process, _, _}

      assert {:error, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    end

    test "an interrupt between turns pinned to an earlier run leaves the work and the agent" do
      thread_id = launch("work in the background", "grok")
      [%{"id" => run_id}] = thread_id |> await_run("completed") |> StreamState.list("run")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))
      conn = :sys.get_state(runtime_pid(thread_id)).conn
      pinned = &%{"type" => "run.interrupt", "threadId" => thread_id, "runId" => &1}

      assert {:error, "no running turn"} = Orchestration.dispatch(pinned.("run:earlier"))
      assert Process.alive?(conn)
      assert ["running", "running"] = Enum.map(background_items(thread_id), & &1["status"])

      ref = Process.monitor(conn)
      assert {:ok, _} = Orchestration.dispatch(pinned.(run_id))
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert_receive {:DOWN, ^ref, :process, _, _}
    end

    test "an interrupted turn ends the work it started, and the agent" do
      thread_id = launch("work in the background and wait", "grok")
      _ = await_run(thread_id, "running")
      await_item(thread_id, "subagent")
      conn = :sys.get_state(runtime_pid(thread_id)).conn
      ref = Process.monitor(conn)

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      _ = await_run(thread_id, "interrupted")
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert ["interrupted", "interrupted"] =
               Enum.map(background_items(thread_id), & &1["status"])

      assert [%{"status" => "interrupted"}] = StreamState.list(current(thread_id), "subagent")
    end

    test "releasing the agent ends the work it ran" do
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      assert :ok = Orchestration.release_session(thread_id)
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))

      assert ["interrupted", "interrupted"] =
               Enum.map(background_items(thread_id), & &1["status"])
    end

    defp background_items(thread_id) do
      current(thread_id)
      |> StreamState.list("turn-item")
      |> Enum.filter(
        &(&1["nativeItemRef"]["nativeId"] in ["sh-1", "spawn-1"] or
            (&1["type"] == "subagent" and &1["status"] != nil))
      )
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["type"])
    end

    defp runtime_pid(thread_id) do
      [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, thread_id)
      pid
    end

    defp session(thread_id), do: :sys.get_state(runtime_pid(thread_id)).session_id

    defp grok_says(thread_id, method, params) do
      pid = runtime_pid(thread_id)
      send(pid, {:json_rpc, :sys.get_state(pid).conn, {:notification, method, params}})
    end
  end

  describe "Claude" do
    # A history put before it would make the command a message Claude only reads.
    test "a /compact reaches Claude alone, and what it missed goes with the next turn",
         %{tmp_dir: dir} do
      log = Path.join(dir, "claude-input.log")
      System.put_env("FAKE_CLAUDE_INPUT_LOG", log)
      on_exit(fn -> System.delete_env("FAKE_CLAUDE_INPUT_LOG") end)
      claude = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}}
      codex = %{"modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}}

      thread_id = launch("hello", "claudeAgent")
      _ = await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-codex", "list the files", codex)
      _ = await_statuses(thread_id, ["completed", "completed"])
      {:ok, _} = send_message(thread_id, "msg-compact", "/compact", claude)
      _ = await_statuses(thread_id, ["completed", "completed", "completed"])
      {:ok, _} = send_message(thread_id, "msg-next", "hello again", claude)
      _ = await_statuses(thread_id, ["completed", "completed", "completed", "completed"])

      assert ["hello", "/compact", next] =
               log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert next =~ "list the files"
      assert String.ends_with?(next, "\n\nhello again")
    end

    test "a message runs a Claude turn: thinking, a Bash call, and a streamed answer" do
      thread_id = launch("list the files", "claudeAgent")
      state = await_run(thread_id, "completed")

      items = StreamState.list(state, "turn-item")

      assert Enum.map(items, & &1["type"]) == [
               "user_message",
               "reasoning",
               "command_execution",
               "assistant_message",
               "checkpoint"
             ]

      [_, thinking, command, answer, _checkpoint] = items
      assert %{"text" => "Let me look.", "status" => "completed"} = thinking
      assert %{"input" => "ls", "output" => "a.txt\n", "status" => "completed"} = command

      assert %{"text" => "Hello from claude", "streaming" => false, "status" => "completed"} =
               answer

      assert [
               %{
                 "driver" => "claudeAgent",
                 "nativeThreadRef" => %{"nativeId" => "fake-session-1"}
               }
             ] =
               StreamState.list(state, "provider-thread")

      assert [%{"providerInstanceId" => "claudeAgent"}] = StreamState.list(state, "run")
    end

    test "interrupt ends a Claude run" do
      thread_id = launch("wait for me", "claudeAgent")
      _ = await_run(thread_id, "running")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      assert [%{"status" => "interrupted"}] =
               StreamState.list(await_run(thread_id, "interrupted"), "run-attempt")
    end

    test "Claude's background subagent and command keep its process until their tasks end" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      assert %{
               "turn-item:subagent:node:subagent:claudeAgent:agent-1" => %{
                 "type" => "subagent",
                 "status" => "running",
                 "title" => "Survey the repo",
                 "prompt" => "List what is in the repo"
               }
             } = StreamState.get(current(thread_id), "turn-item")

      assert [%{"status" => "running", "output" => "Command running in background" <> _}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] == "command_execution"))

      # The idle timeout passed, but the process runs the work: it stays.
      assert HalC2.Orchestration.IdleSessions.check() == []
      assert [_] = Registry.lookup(HalC2.Claude.Registry, thread_id)

      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-agent-1",
        "tool_use_id" => "agent-1",
        "description" => "Survey the repo",
        "summary" => "Reading the README"
      })

      claude_says(thread_id, notification("task-agent-1", "agent-1", "completed", "3 files"))
      claude_says(thread_id, notification("task-bash-1", "bash-1", "stopped", "Stopped"))
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))

      state = current(thread_id)

      assert %{"status" => "completed", "result" => "3 files", "progress" => "Reading the README"} =
               StreamState.get(state, "turn-item")[
                 "turn-item:subagent:node:subagent:claudeAgent:agent-1"
               ]

      assert %{"status" => "completed", "origin" => "provider_native"} =
               StreamState.get(state, "subagent")["node:subagent:claudeAgent:agent-1"]

      assert [%{"status" => "cancelled", "output" => "Stopped"}] =
               state
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] == "command_execution"))

      assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
    end

    test "stopping a Claude thread between turns ends its background work" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))

      # Claude reports a task it stopped as cancelled; a command it stopped is interrupted.
      assert [{"subagent", "cancelled"}, {"command_execution", "interrupted"}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] in ["subagent", "command_execution"]))
               |> Enum.map(&{&1["type"], &1["status"]})

      # With nothing left to stop, a second stop is refused as before.
      assert {:error, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    end

    # Claude's work outlives a restart of the Codex turn after it, as Codex's own work
    # outlives a restart of a Codex turn: interrupt-and-send reaches only the turn.
    test "a restart of a turn on another provider leaves Claude's work and process" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      session = :sys.get_state(pid).session
      codex = %{"modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}}
      {:ok, _} = send_message(thread_id, "m2", "wait for it", codex)
      _ = await_statuses(thread_id, ["completed", "running"])

      {:ok, _} =
        send_message(
          thread_id,
          "m3",
          "say done",
          Map.merge(codex, %{
            "dispatchMode" => %{"type" => "start_immediately"},
            "deliveryIntent" => "restart"
          })
        )

      _ = await_statuses(thread_id, ["completed", "interrupted", "completed"])
      assert Process.alive?(session)

      assert ["running", "running"] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] in ["subagent", "command_execution"]))
               |> Enum.map(& &1["status"])
    end

    test "an interrupt between turns pinned to an earlier run leaves Claude's work and process" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      [%{"id" => run_id}] = thread_id |> await_run("completed") |> StreamState.list("run")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      session = :sys.get_state(pid).session
      pinned = &%{"type" => "run.interrupt", "threadId" => thread_id, "runId" => &1}

      assert {:error, "no running turn"} = Orchestration.dispatch(pinned.("run:earlier"))
      assert Process.alive?(session)

      assert ["running", "running"] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] in ["subagent", "command_execution"]))
               |> Enum.map(& &1["status"])

      assert {:ok, _} = Orchestration.dispatch(pinned.(run_id))
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      refute Process.alive?(session)
    end

    test "releasing a Claude process ends the background work it ran" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      assert :ok = Orchestration.release_session(thread_id)
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))

      assert %{"status" => "interrupted"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-1"
               ]
    end

    test "work Claude starts in a wake is recorded on the wake's run until its task ends" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      # The turn a task notification wakes Claude for launches a subagent and a command.
      claude_says(thread_id, %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-wake",
          "content" => [
            %{"type" => "text", "text" => "Starting more"},
            %{
              "type" => "tool_use",
              "id" => "agent-wake",
              "name" => "Agent",
              "input" => %{"description" => "Check the tests", "run_in_background" => true}
            },
            %{
              "type" => "tool_use",
              "id" => "bash-wake",
              "name" => "Bash",
              "input" => %{"command" => "mix test", "run_in_background" => true}
            }
          ]
        }
      })

      claude_says(thread_id, task_started("task-agent-wake", "agent-wake", "local_agent"))
      claude_says(thread_id, task_started("task-bash-wake", "bash-wake", "local_bash"))

      claude_says(thread_id, %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "agent-wake", "content" => "launched"},
            %{"type" => "tool_result", "tool_use_id" => "bash-wake", "content" => "running"}
          ]
        }
      })

      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      [_, %{"id" => run_id}] = runs(await_statuses(thread_id, ["completed", "completed"]))
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      assert %{"runId" => ^run_id, "status" => "running", "title" => "Check the tests"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-wake"
               ]

      assert [%{"runId" => ^run_id, "status" => "running", "output" => "running"}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["input"] == "mix test"))

      claude_says(thread_id, notification("task-agent-wake", "agent-wake", "completed", "Fine"))
      claude_says(thread_id, notification("task-bash-wake", "bash-wake", "completed", "ok"))
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
    end

    # #1233: a wake sends Claude nothing, so what another provider did before it is
    # still Claude's to hear, from the next run that sends it something.
    test "a wake leaves the runs Claude missed to the next run that sends it a message",
         %{tmp_dir: dir} do
      log = Path.join(dir, "prompts.jsonl")
      claude = ["env", "FAKE_CLAUDE_PROMPT_LOG=" <> log, "python3", "-u", @fake_claude]
      Application.put_env(:hal_c2, :claude_command, claude)
      selection = &%{"modelSelection" => %{"instanceId" => &1, "model" => "gpt-5.4"}}

      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")
      assert {:ok, _} = send_message(thread_id, "m2", "codex was here", selection.("codex"))
      _ = await_statuses(thread_id, ~w(completed completed))

      # Claude takes a turn by itself, as a background task's end wakes it.
      claude_says(thread_id, %{
        "type" => "assistant",
        "message" => %{"id" => "m-wake", "content" => [%{"type" => "text", "text" => "Woke"}]}
      })

      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      _ = await_statuses(thread_id, ~w(completed completed completed))

      assert {:ok, _} = send_message(thread_id, "m4", "back to claude", selection.("claudeAgent"))
      _ = await_statuses(thread_id, ~w(completed completed completed completed))

      assert [_hello, back] =
               log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert back =~ "codex was here"
      assert back =~ "back to claude"
    end

    # A `/compact` is Claude's to run on its conversation: history before it would make
    # it a message. What Claude missed waits for the next message.
    test "a /compact reaches Claude as it was sent, and the next message brings what it missed",
         %{tmp_dir: dir} do
      log = Path.join(dir, "prompts.jsonl")
      claude = ["env", "FAKE_CLAUDE_PROMPT_LOG=" <> log, "python3", "-u", @fake_claude]
      Application.put_env(:hal_c2, :claude_command, claude)
      selection = &%{"modelSelection" => %{"instanceId" => &1, "model" => "gpt-5.4"}}

      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")
      assert {:ok, _} = send_message(thread_id, "m2", "codex was here", selection.("codex"))
      _ = await_statuses(thread_id, ~w(completed completed))
      assert {:ok, _} = send_message(thread_id, "m3", "/compact", selection.("claudeAgent"))
      _ = await_statuses(thread_id, ~w(completed completed completed))
      assert {:ok, _} = send_message(thread_id, "m4", "back to claude", selection.("claudeAgent"))
      _ = await_statuses(thread_id, ~w(completed completed completed completed))

      assert [_hello, "/compact", back] =
               log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert back =~ "codex was here"
    end

    # provider-handoff.feature: a handoff waits when the first message after a switch
    # asks to compact.
    # Nothing is handed over with it, so Claude would have nothing to compact.
    test "a /compact that is Claude's first run in the thread waits for the next message",
         %{tmp_dir: dir} do
      log = Path.join(dir, "prompts.jsonl")
      claude = ["env", "FAKE_CLAUDE_PROMPT_LOG=" <> log, "python3", "-u", @fake_claude]
      Application.put_env(:hal_c2, :claude_command, claude)
      selection = &%{"modelSelection" => %{"instanceId" => &1, "model" => "gpt-5.4"}}

      thread_id = launch("codex was here")
      _ = await_run(thread_id, "completed")
      assert {:ok, _} = send_message(thread_id, "m2", "/compact", selection.("claudeAgent"))
      state = await_statuses(thread_id, ~w(completed failed))

      assert Enum.any?(
               StreamState.list(state, "turn-item"),
               &(&1["type"] == "error" and &1["title"] == "Nothing to compact yet")
             )

      refute File.exists?(log)
      assert {:ok, _} = send_message(thread_id, "m3", "and now", selection.("claudeAgent"))
      _ = await_statuses(thread_id, ~w(completed failed completed))

      assert [next] =
               log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert next =~ "codex was here"
      assert String.ends_with?(next, "and now")
    end

    # #1233: Claude starting the prompt took it, and the history it carried, so a turn
    # stopped before Claude said anything leaves its conversation to go on in.
    test "a Claude turn stopped before its first output goes on in its conversation next" do
      selection = &%{"modelSelection" => %{"instanceId" => &1, "model" => "gpt-5.4"}}

      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")
      assert {:ok, _} = send_message(thread_id, "m2", "codex was here", selection.("codex"))
      _ = await_statuses(thread_id, ~w(completed completed))

      assert {:ok, _} =
               send_message(thread_id, "m3", "start and wait", selection.("claudeAgent"))

      state = await_statuses(thread_id, ~w(completed completed running))
      %{"id" => run_id, "providerThreadId" => own} = List.last(runs(state))
      # The run handed codex's turn over, and marked it until Claude took it.
      marked = StreamState.get(state, "provider-thread")[own]
      assert marked["unconfirmedRunId"] == run_id

      state =
        await_state(
          thread_id,
          &(not Map.has_key?(StreamState.get(&1, "provider-thread")[own], "unconfirmedRunId"))
        )

      native = StreamState.get(state, "provider-thread")[own]["nativeThreadRef"]
      assert native != nil

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      _ = await_statuses(thread_id, ~w(completed completed interrupted))
      assert {:ok, _} = send_message(thread_id, "m4", "again", selection.("claudeAgent"))
      state = await_statuses(thread_id, ~w(completed completed interrupted completed))

      assert StreamState.get(state, "provider-thread")[own]["nativeThreadRef"] == native
    end

    test "a subagent resumed through SendMessage keeps its process until its task ends" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("wait for me", "claudeAgent")
      _ = await_run(thread_id, "running")

      claude_says(thread_id, %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-send",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "send-1",
              "name" => "SendMessage",
              "input" => %{"to" => "task-old", "message" => "Carry on"}
            }
          ]
        }
      })

      claude_says(thread_id, task_started("task-old", "send-1", "local_agent"))

      claude_says(thread_id, %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "send-1", "content" => "sent"}
          ]
        }
      })

      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))

      # The MC never saw task-old start, so the message that resumed it opens its
      # subagent, which runs on after the call.
      subagent = fn ->
        current(thread_id)
        |> StreamState.list("turn-item")
        |> Enum.filter(&(&1["type"] == "subagent"))
      end

      assert [%{"prompt" => "Carry on", "status" => "running"}] = subagent.()

      assert [] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["toolName"] == "SendMessage"))

      claude_says(thread_id, notification("task-old", "send-1", "completed", "Done"))
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))
      assert [%{"status" => "completed"}] = subagent.()
    end

    test "after an upgrade, the progress of a subagent it never recorded records it" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("hello", "claudeAgent")
      [%{"id" => run_id}] = StreamState.list(await_run(thread_id, "completed"), "run")

      # A runtime from before this version: no latest turn ids.
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      :sys.replace_state(pid, &Map.drop(&1, [:last_ids]))
      :ok = :sys.suspend(pid)
      :ok = :sys.change_code(pid, HalC2.Claude.ThreadRuntime, 6, nil)
      :ok = :sys.resume(pid)

      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-unseen",
        "tool_use_id" => "agent-unseen",
        "description" => "Review the diff",
        "summary" => "Reading lib"
      })

      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))

      assert %{"runId" => ^run_id, "status" => "running", "progress" => "Reading lib"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-unseen"
               ]

      claude_says(thread_id, notification("task-unseen", "agent-unseen", "completed", "LGTM"))
      await_shell_row(thread_id, &(&1["runningBackgroundTasks"] == []))

      # Its progress after it ended does not bring it back.
      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-unseen",
        "tool_use_id" => "agent-unseen",
        "summary" => "late"
      })

      assert %{"status" => "completed"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-unseen"
               ]
    end

    # A held queue that a newer run passed is numbered above it, and has no attempt
    # yet, cancelled while held no more than still queued.
    for status <- ["queued", "cancelled"] do
      test "a fresh runtime records a subagent under the run that ran, not a held #{status} run's" do
        :ok = HalC2.Shell.subscribe(self())
        thread_id = launch("hello", "claudeAgent")
        [%{"id" => run_id}] = StreamState.list(await_run(thread_id, "completed"), "run")

        {:ok, _} =
          HalC2.Streams.commit(thread_id, :thread, [
            {"run", "held",
             %{
               "s" => %{
                 "id" => "held",
                 "threadId" => thread_id,
                 "ordinal" => 2,
                 "status" => unquote(status),
                 "queuePosition" => 1,
                 "queueHeld" => true
               }
             }}
          ])

        # A runtime that started after that turn: no latest turn ids.
        [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
        :sys.replace_state(pid, &%{&1 | last_ids: nil})

        claude_says(thread_id, %{
          "type" => "system",
          "subtype" => "task_progress",
          "task_id" => "task-unseen",
          "tool_use_id" => "agent-unseen",
          "description" => "Review the diff",
          "summary" => "Reading lib"
        })

        await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 1))

        assert %{"runId" => ^run_id} =
                 StreamState.get(current(thread_id), "subagent")[
                   "node:subagent:claudeAgent:agent-unseen"
                 ]
      end
    end

    test "ambient tasks between turns are not background work" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      claude_says(
        thread_id,
        Map.put(task_started("task-watch", "watch-1", "local_agent"), "ambient", true)
      )

      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-watch",
        "summary" => "watching"
      })

      # A round trip: both messages were handled.
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      assert %{work: work} = :sys.get_state(pid)
      assert work == %{}
      assert StreamState.get(current(thread_id), "subagent") in [nil, %{}]
    end

    test "a turn Claude runs by itself is a run of its own until its result" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      # A background task ended; Claude answers its notification.
      claude_says(thread_id, notification("task-gone", "bash-gone", "completed", "Build passed"))
      claude_says(thread_id, wake_text("m-wake-1", "The build passed"))

      state = await_statuses(thread_id, ["completed", "running"])
      [_, %{"id" => wake_run, "userMessageId" => wake_message}] = runs(state)

      assert %{"role" => "user", "createdBy" => "agent", "creationSource" => "provider"} =
               StreamState.get(state, "message")[wake_message]

      claude_says(thread_id, wake_text("m-wake-2", "Nothing else to do"))
      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      state = await_statuses(thread_id, ["completed", "completed"])

      assert ["The build passed", "Nothing else to do"] =
               for(
                 %{"role" => "assistant", "runId" => ^wake_run} = m <-
                   StreamState.list(state, "message"),
                 do: m["text"]
               )

      # The next message is a turn of its own again.
      {:ok, _} = send_message(thread_id, "msg-user-2", "hello again")
      _ = await_statuses(thread_id, ["completed", "completed", "completed"])
    end

    test "a message sent while Claude runs a wake keeps its turn past the wake's result" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      session = :sys.get_state(pid).session

      # The user's run starts before the wake's: the runtime hears of the wake, then of
      # the user's turn, before asking for the wake's run.
      :ok = :sys.suspend(pid)
      send(pid, {:claude, session, {:message, wake_text("m-wake", "Checking the build")}})
      user = Task.async(fn -> send_message(thread_id, "msg-user-2", "and now?") end)
      await_mailbox(pid, 2)
      :ok = :sys.resume(pid)
      assert {:ok, _} = Task.await(user)

      # The fake answers the steer with the wake's aborted result, then the user's.
      state = await_statuses(thread_id, ["completed", "completed", "completed"])
      [_, %{"id" => user_run}, %{"userMessageId" => wake_message}] = runs(state)
      assert StreamState.get(state, "message")[wake_message]["creationSource"] == "provider"

      assert ["Checking the build", "steered: and now?"] =
               for(
                 %{"role" => "assistant", "runId" => ^user_run} = m <-
                   StreamState.list(state, "message"),
                 do: m["text"]
               )
    end

    test "a hot upgrade keeps the runtime going and takes the next wake" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      :sys.replace_state(pid, &Map.drop(&1, [:wake]))
      :ok = :sys.suspend(pid)
      :ok = :sys.change_code(pid, HalC2.Claude.ThreadRuntime, 7, nil)
      :ok = :sys.resume(pid)

      claude_says(thread_id, wake_text("m-wake", "Woke up"))
      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      _ = await_statuses(thread_id, ["completed", "completed"])
    end

    # The default instance takes over a provider thread another Claude
    # instance left under its id, and the decide carries that instance's
    # native thread — the instances share a home, so it is the same
    # conversation — without storing it on the taken-over record. The turn
    # that starts must still resume it, not open a fresh conversation.
    test "a foreign takeover keeps the native thread the decide carried" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_statuses(thread_id, ["completed"])

      default = HalC2.Orchestration.Entities.provider_thread_id("claudeAgent", thread_id)
      other = HalC2.Orchestration.Entities.provider_thread_id("claude-work", thread_id)

      native =
        get_in(StreamState.get(current(thread_id), "provider-thread")[default], [
          "nativeThreadRef"
        ])

      assert %{"nativeId" => "fake-session-1"} = native

      {:ok, _} =
        HalC2.Streams.commit(thread_id, :thread, [
          {"provider-thread", default, %{"s" => %{"providerInstanceId" => "claude-work"}}},
          {"provider-thread", other,
           %{
             "s" => %{
               "id" => other,
               "threadId" => thread_id,
               "providerInstanceId" => "claude-work",
               "driver" => "claudeAgent",
               "status" => "idle",
               "nativeThreadRef" => native
             }
           }}
        ])

      {:ok, _} = send_message(thread_id, "msg-user-2", "wait for me")
      _ = await_statuses(thread_id, ["completed", "running"])

      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      assert %{turn: %{native_thread_id: "fake-session-1"}} = :sys.get_state(pid)

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      _ = await_statuses(thread_id, ["completed", "interrupted"])
    end

    # Another instance of Claude runs with its own variables and home, so its turn needs
    # its own CLI even when it launches Claude as the first does. A runtime updated in
    # place from before launches recorded their instance cannot tell the one its CLI
    # runs, so its next turn starts a new CLI rather than guess.
    test "a turn on another instance of Claude starts its own CLI" do
      start_supervised!(HalC2.Settings)
      {_, version} = HalC2.Settings.get()
      work = %{"claude-work" => %{"driver" => "claudeAgent", "enabled" => true}}
      {:ok, _} = HalC2.Settings.put(%{"providerInstances" => work}, version)

      thread_id = launch("hello", "claudeAgent")
      _ = await_statuses(thread_id, ["completed"])
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      %{session: session} = :sys.get_state(pid)

      :ok = :sys.suspend(pid)

      :sys.replace_state(
        pid,
        &update_in(&1.launch, fn launch -> Map.delete(launch, :instance) end)
      )

      :ok = :sys.change_code(pid, HalC2.Claude.ThreadRuntime, 9, nil)
      :ok = :sys.resume(pid)

      {:ok, _} = send_message(thread_id, "msg-user-2", "again")
      _ = await_statuses(thread_id, ["completed", "completed"])
      assert %{session: renewed, launch: %{instance: "claudeAgent"}} = :sys.get_state(pid)
      refute renewed == session

      elsewhere = %{"modelSelection" => %{"instanceId" => "claude-work", "model" => "gpt-5.4"}}
      {:ok, _} = send_message(thread_id, "msg-user-3", "elsewhere", elsewhere)
      _ = await_statuses(thread_id, ["completed", "completed", "completed"])
      assert %{session: other, launch: %{instance: "claude-work"}} = :sys.get_state(pid)
      refute other == renewed
    end

    # A start that failed on another instance left the old runtime's latest ids
    # naming that instance while its CLI was still the first instance's. Updated
    # in place in that state, it must not stamp the old CLI with the new instance:
    # the next turn there would reuse the wrong account's CLI.
    test "an upgrade after a failed start on another instance does not reuse the old CLI" do
      start_supervised!(HalC2.Settings)
      {_, version} = HalC2.Settings.get()
      work = %{"claude-work" => %{"driver" => "claudeAgent", "enabled" => true}}
      {:ok, _} = HalC2.Settings.put(%{"providerInstances" => work}, version)

      thread_id = launch("hello", "claudeAgent")
      _ = await_statuses(thread_id, ["completed"])
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      %{session: session} = :sys.get_state(pid)

      :ok = :sys.suspend(pid)

      :sys.replace_state(pid, fn state ->
        state
        |> update_in([:launch], &Map.delete(&1, :instance))
        |> update_in([:last_ids], &Map.put(&1, :instance, "claude-work"))
      end)

      :ok = :sys.change_code(pid, HalC2.Claude.ThreadRuntime, 9, nil)
      :ok = :sys.resume(pid)

      elsewhere = %{"modelSelection" => %{"instanceId" => "claude-work", "model" => "gpt-5.4"}}
      {:ok, _} = send_message(thread_id, "msg-user-2", "elsewhere", elsewhere)
      _ = await_statuses(thread_id, ["completed", "completed"])
      assert %{session: other, launch: %{instance: "claude-work"}} = :sys.get_state(pid)
      refute other == session
    end

    defp wake_text(id, text),
      do: %{
        "type" => "assistant",
        "message" => %{"id" => id, "content" => [%{"type" => "text", "text" => text}]}
      }

    defp await_mailbox(pid, count) do
      if Process.info(pid, :message_queue_len) |> elem(1) >= count do
        :ok
      else
        receive do
        after
          5 -> await_mailbox(pid, count)
        end
      end
    end

    defp task_started(task_id, tool_id, type),
      do: %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => task_id,
        "tool_use_id" => tool_id,
        "description" => "A task",
        "task_type" => type,
        "is_backgrounded" => true
      }

    defp claude_says(thread_id, message) do
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
    end

    defp notification(task_id, tool_id, status, summary),
      do: %{
        "type" => "system",
        "subtype" => "task_notification",
        "task_id" => task_id,
        "tool_use_id" => tool_id,
        "status" => status,
        "output_file" => "/tmp/#{task_id}.output",
        "summary" => summary
      }
  end

  describe "approvals" do
    for {instance, answer_text, prompt} <- [
          {"codex", nil, "touch x"},
          {"claudeAgent", "allowed", "Bash: touch x"}
        ] do
      test "#{instance}: a prompt becomes a pending request, and accepting it lets the turn go on" do
        thread_id = launch("approve this", unquote(instance))
        request = await_request(thread_id)
        assert %{"status" => "pending", "kind" => "command"} = request

        assert [
                 %{
                   "type" => "approval_request",
                   "status" => "waiting",
                   "prompt" => unquote(prompt)
                 }
               ] =
                 thread_id
                 |> current()
                 |> StreamState.list("turn-item")
                 |> Enum.filter(&(&1["type"] == "approval_request"))

        assert {:ok, _} =
                 Orchestration.dispatch(%{
                   "type" => "runtime-request.respond",
                   "threadId" => thread_id,
                   "requestId" => request["id"],
                   "decision" => "accept"
                 })

        state = await_run(thread_id, "completed")

        assert [%{"status" => "resolved", "decision" => "accept"}] =
                 StreamState.list(state, "runtime-request")

        if unquote(answer_text) do
          assert Enum.any?(
                   StreamState.list(state, "turn-item"),
                   &(&1["text"] == unquote(answer_text))
                 )
        else
          assert Enum.any?(
                   StreamState.list(state, "turn-item"),
                   &(&1["type"] == "command_execution" and &1["status"] == "completed")
                 )
        end
      end
    end

    # Each fake says what it was told; Claude keys answers by question text.
    for {instance, question_id, told} <- [
          {"codex", "color", ~s(answered {"color": {"answers": ["Red"]}})},
          {"claudeAgent", "Which color?", ~s(answered {"Which color?": "Red"})}
        ] do
      test "#{instance}: a question waits for the user's answer and passes it on" do
        thread_id = launch("ask me", unquote(instance))
        request = await_request(thread_id)
        assert %{"status" => "pending", "kind" => "user_input"} = request

        assert [%{"status" => "waiting", "questions" => [question]}] =
                 thread_id
                 |> current()
                 |> StreamState.list("turn-item")
                 |> Enum.filter(&(&1["type"] == "user_input_request"))

        assert %{"id" => unquote(question_id), "header" => "Color", "question" => "Which color?"} =
                 question

        assert %{"label" => "Red", "description" => "Warm"} = hd(question["options"])

        {:ok, _} =
          Orchestration.dispatch(%{
            "type" => "runtime-request.respond",
            "threadId" => thread_id,
            "requestId" => request["id"],
            "answers" => %{unquote(question_id) => "Red"}
          })

        state = await_run(thread_id, "completed")

        assert [%{"status" => "resolved", "answers" => %{unquote(question_id) => "Red"}}] =
                 StreamState.list(state, "runtime-request")

        assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == unquote(told)))
      end
    end

    test "a file attached to an answer reaches the agent as where it is saved" do
      {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
        HalC2.Attachments.create_upload_url(%{
          "type" => "file",
          "name" => "notes.txt",
          "mimeType" => "text/plain",
          "sizeBytes" => 5
        })

      :ok = HalC2.Attachments.store(token, "notes")
      thread_id = launch("ask me")
      request = await_request(thread_id)
      file = %{"type" => "file", "id" => id, "name" => "notes.txt", "sizeBytes" => 5}

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "answers" => %{"color" => "Red"},
          "attachmentsByQuestionId" => %{"color" => [file]}
        })

      state = await_run(thread_id, "completed")

      assert [%{"questionAnswer" => %{"answers" => %{"color" => "Red"}} = answer}] =
               state
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] == "user_input_request"))

      # The file now belongs to the thread, and the agent was told where it is.
      assert [%{"id" => claimed, "name" => "notes.txt"}] =
               answer["attachmentsByQuestionId"]["color"]

      path = HalC2.Attachments.path(%{"id" => claimed})
      assert File.read!(path) == "notes"

      assert Enum.any?(
               StreamState.list(state, "turn-item"),
               &String.contains?(&1["text"] || "", ~s(Attached file \\"notes.txt\\": ))
             )
    end

    test "an answer to a request the agent no longer has gives its copies back" do
      thread_id = launch("ask me")
      _ = await_request(thread_id)
      upload = pending_upload()
      before = length(attachment_files())

      assert {:error, _} =
               Orchestration.dispatch(%{
                 "type" => "runtime-request.respond",
                 "threadId" => thread_id,
                 "requestId" => "request-gone",
                 "answers" => %{"color" => "Red"},
                 "attachmentsByQuestionId" => %{"color" => [upload]}
               })

      # The copy the answer made is gone; the pending upload stays for a retry.
      assert length(attachment_files()) == before
      assert HalC2.Attachments.path(upload)
    end

    test "dismissing a question tells Claude no and cancels the request" do
      thread_id = launch("ask me", "claudeAgent")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.user-input.dismiss",
          "threadId" => thread_id,
          "requestId" => request["id"]
        })

      state = await_run(thread_id, "completed")
      assert [%{"status" => "cancelled"}] = StreamState.list(state, "runtime-request")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "denied"))
    end

    test "dismissing Claude's question about compacting a resumed conversation cancels it" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")
      # Without its process, the next message resumes the conversation.
      :ok = Orchestration.release_session(thread_id)
      {:ok, _} = send_message(thread_id, "m2", "long session")
      request = await_request(thread_id)
      assert %{"status" => "pending", "kind" => "user_input"} = request

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.user-input.dismiss",
          "threadId" => thread_id,
          "requestId" => request["id"]
        })

      state = await_statuses(thread_id, ["completed", "completed"])
      assert [%{"status" => "cancelled"}] = StreamState.list(state, "runtime-request")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "resume cancelled"))
    end

    test "declining a Claude prompt is passed on to Claude" do
      thread_id = launch("approve this", "claudeAgent")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "decline"
        })

      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "denied"))
    end
  end

  describe "ACP agents (OpenCode)" do
    test "an agent that cannot start fails its run" do
      Application.put_env(:hal_c2, :acp_commands, %{"opencode" => ["/nonexistent/agent"]})

      # The runtime settles the turn itself, before creating its provider turn.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:state, await_run(launch("hello", "opencode"), "failed")})
        end)

      assert_received {:state, state}
      refute log =~ "turn failed to start in"

      assert [%{"status" => "failed"}] = StreamState.list(state, "run-attempt")
      assert [%{"status" => "idle"}] = StreamState.list(state, "provider-thread")
      assert StreamState.list(state, "provider-turn") == []
    end

    test "a turn streams thinking, a command, and the answer; the session is recorded" do
      thread_id = launch("list the files", "opencode")
      state = await_run(thread_id, "completed")

      assert Enum.map(StreamState.list(state, "turn-item"), & &1["type"]) == [
               "user_message",
               "reasoning",
               "command_execution",
               "assistant_message",
               "checkpoint"
             ]

      items = StreamState.list(state, "turn-item")

      assert %{"input" => "ls", "output" => "a.txt\n", "status" => "completed"} =
               Enum.find(items, &(&1["type"] == "command_execution"))

      assert %{"text" => "Hello from acp", "streaming" => false} =
               Enum.find(items, &(&1["type"] == "assistant_message"))

      assert [%{"text" => "Hello from acp", "streaming" => false}] =
               Enum.filter(StreamState.list(state, "message"), &(&1["role"] == "assistant"))

      assert [%{"driver" => "opencode", "nativeThreadRef" => %{"nativeId" => "acp-1"}}] =
               StreamState.list(state, "provider-thread")

      # A follow-up is another prompt on the same session.
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => "msg-user-2",
          "text" => "again"
        })

      state = await_runs(thread_id, 2)
      assert Enum.all?(StreamState.list(state, "run"), &(&1["status"] == "completed"))
    end

    test "a supervised thread asks before a command, and the answer goes to the agent" do
      thread_id = launch("approve the command", "opencode", "approval-required")
      request = await_request(thread_id)
      assert %{"kind" => "command"} = request

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "decline"
        })

      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "not allowed"))
    end

    test "interrupt cancels the prompt" do
      thread_id = launch("wait for it", "opencode")
      await_item(thread_id, "command_execution")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_run(thread_id, "interrupted")
    end
  end

  describe "checkpoints" do
    test "a completed run records what it changed, and its diff is served", %{work: dir} do
      File.write!(Path.join(dir, "before.txt"), "already here\n")
      thread_id = launch("approve the command")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "accept"
        })

      state = await_run(thread_id, "completed")
      scope_id = HalC2.Checkpoint.scope_id(thread_id)

      assert [%{"id" => ^scope_id, "kind" => "root_run", "cwd" => ^dir}] =
               StreamState.list(state, "checkpoint-scope")

      # The scope's baseline (ordinal 0) comes first, then the run's checkpoint.
      assert [
               %{"ordinalWithinScope" => 0, "appRunOrdinal" => nil},
               %{"status" => "ready", "appRunOrdinal" => 1, "files" => files} = checkpoint
             ] = StreamState.list(state, "checkpoint") |> Enum.sort_by(& &1["ordinalWithinScope"])

      # The baseline was taken before the turn, so only the turn's own file shows.
      assert [%{"path" => "x", "additions" => 1}] = files
      assert [%{"checkpointId" => checkpoint_id}] = StreamState.list(state, "run")
      assert checkpoint_id == checkpoint["id"]

      assert %{"type" => "checkpoint", "files" => ^files} =
               state |> StreamState.list("turn-item") |> List.last()

      assert {:ok, %{"diff" => diff, "toTurnCount" => 1}} =
               Orchestration.handle("orchestration.getTurnDiff", %{
                 "threadId" => thread_id,
                 "fromTurnCount" => 0,
                 "toTurnCount" => 1
               })

      assert diff =~ "+++ b/x"
      refute diff =~ "before.txt"

      assert {:ok, %{"diff" => ^diff}} =
               Orchestration.handle("orchestration.getFullThreadDiff", %{
                 "threadId" => thread_id,
                 "toTurnCount" => 1
               })
    end
  end

  describe "checkpoint rollback" do
    # A thread working in `work` as its own worktree, so files can be restored.
    defp launch_in(work, text, instance) do
      thread_id = "thread-#{System.unique_integer([:positive])}"
      :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

      {:ok, _} =
        Orchestration.launch_thread(%{
          "commandId" => "cmd-#{System.unique_integer([:positive])}",
          "threadId" => thread_id,
          "projectId" => "project-1",
          "title" => "Rewind",
          "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"},
          "runtimeMode" => "full-access",
          "interactionMode" => "default",
          "workspaceStrategy" => %{
            "type" => "existing_worktree",
            "worktreePath" => work,
            "branch" => "main"
          },
          "initialMessage" => %{"messageId" => "msg-user-1", "text" => text, "attachments" => []}
        })

      thread_id
    end

    defp rollback(thread_id, ordinal, extra \\ %{}) do
      scope_id = HalC2.Checkpoint.scope_id(thread_id)

      Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "checkpoint.rollback",
            "commandId" => "cmd-rollback",
            "threadId" => thread_id,
            "scopeId" => scope_id,
            "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope_id, ordinal)
          },
          extra
        )
      )
    end

    test "Codex drops the later turns, the files go back, and the next run diffs from there",
         %{work: work} do
      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1)

      state = current(thread_id)
      assert ["completed", "rolled_back"] = Enum.map(runs(state), & &1["status"])
      assert File.exists?(Path.join(work, "a.txt"))
      refute File.exists?(Path.join(work, "b.txt"))

      assert [%{"lastRunOrdinal" => 1, "nativeThreadRef" => %{"nativeId" => native}}] =
               StreamState.list(state, "provider-thread")

      # Paginated history is cut before the first dropped turn.
      assert native == "native-thread-1-before-native-turn-2"

      assert %{"status" => "stale"} =
               StreamState.get(state, "checkpoint")[
                 HalC2.Checkpoint.checkpoint_id(HalC2.Checkpoint.scope_id(thread_id), 2)
               ]

      {:ok, _} = send_message(thread_id, "msg-user-3", "write c.txt")
      state = await_statuses(thread_id, ["completed", "rolled_back", "completed"])

      assert %{"files" => [%{"path" => "c.txt"}]} =
               StreamState.get(state, "checkpoint")[
                 HalC2.Checkpoint.checkpoint_id(HalC2.Checkpoint.scope_id(thread_id), 3)
               ]
    end

    # One from before provider threads recorded their instance is the driver's own.
    test "a Codex provider thread that names no instance rolls back in the app-server it ran in",
         %{work: work} do
      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])
      [%{"id" => provider_thread}] = StreamState.list(current(thread_id), "provider-thread")

      {:ok, _} =
        HalC2.Streams.commit(thread_id, :thread, [
          {"provider-thread", provider_thread, %{"s" => %{"providerInstanceId" => nil}}}
        ])

      [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      %{conn: conn} = :sys.get_state(pid)

      assert {:ok, _} = rollback(thread_id, 1)
      assert %{conn: ^conn} = :sys.get_state(pid)
    end

    test "a legacy Codex thread drops its later turns by count", %{work: work} do
      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_LEGACY=1",
        "python3",
        "-u",
        @fake_codex
      ])

      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1)

      assert [%{"nativeThreadRef" => %{"nativeId" => "native-thread-1-dropped-1"}}] =
               StreamState.list(current(thread_id), "provider-thread")
    end

    # An app-server without `thread/revert` cannot deserialize the method and
    # answers -32600 naming it an unknown variant, not -32601: dropping by
    # count is still the fallback.
    test "a Codex that knows no thread/revert drops its later turns by count", %{work: work} do
      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_LEGACY=1",
        "FAKE_CODEX_NO_REVERT=1",
        "python3",
        "-u",
        @fake_codex
      ])

      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1)

      assert [%{"nativeThreadRef" => %{"nativeId" => "native-thread-1-dropped-1"}}] =
               StreamState.list(current(thread_id), "provider-thread")
    end

    # A run above the target that never started — still in a held queue, or
    # cancelled out of it — is one the provider never saw: settling must not
    # leave `lastRunOrdinal` at it.
    for status <- ["queued", "cancelled"] do
      test "rewinding past a #{status} run settles lastRunOrdinal at the target",
           %{work: work} do
        thread_id = launch_in(work, "write a.txt", "codex")
        await_statuses(thread_id, ["completed"])
        {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
        await_statuses(thread_id, ["completed", "completed"])

        {:ok, _} =
          HalC2.Streams.commit(thread_id, :thread, [
            {"run", "never-started",
             %{
               "s" => %{
                 "id" => "never-started",
                 "threadId" => thread_id,
                 "ordinal" => 3,
                 "status" => unquote(status),
                 "queuePosition" => 1,
                 "queueHeld" => true
               }
             }}
          ])

        assert {:ok, _} = rollback(thread_id, 1)

        assert [%{"lastRunOrdinal" => 1}] =
                 StreamState.list(current(thread_id), "provider-thread")
      end
    end

    # Picking another provider in the composer moves the selection, not the
    # conversation: a rewind asked for after the pick still rewinds the
    # conversation that is active, in either selection shape.
    test "a provider picked before the rewind was asked for does not block it", %{work: work} do
      for selection <- [
            %{"instanceId" => "opencode", "model" => "sonnet"},
            %{"model" => "sonnet"}
          ] do
        thread_id = launch_in(work, "write a.txt", "codex")
        await_statuses(thread_id, ["completed"])
        {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
        await_statuses(thread_id, ["completed", "completed"])

        {:ok, _} =
          HalC2.Streams.commit(thread_id, :thread, [
            {"thread", thread_id, %{"s" => %{"modelSelection" => selection}}}
          ])

        # Both iterations share `work`, so only the conversation rewinds.
        assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})
        assert ["completed", "rolled_back"] = Enum.map(runs(current(thread_id)), & &1["status"])
      end
    end

    # The session stops as it is asked to drop the turns: a Codex rewind fails and
    # changes nothing; a Claude one needs no session, as when none was running.
    test "a rewind whose Codex session stops as it is asked fails", %{work: work} do
      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])
      stand_in(HalC2.Codex.Registry, thread_id, :rollback)

      assert {:error, "Failed to roll back codex provider thread " <> reason} =
               rollback(thread_id, 1, %{"restoreFiles" => false})

      assert reason =~ "its session stopped"
      assert ["completed", "completed"] = Enum.map(runs(current(thread_id)), & &1["status"])
    end

    test "a rewind whose Claude session stops as it is asked goes ahead", %{work: work} do
      thread_id = launch_in(work, "hello", "claudeAgent")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "hello again")
      await_statuses(thread_id, ["completed", "completed"])
      stand_in(HalC2.Claude.Registry, thread_id, :rollback)

      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})
      assert ["completed", "rolled_back"] = Enum.map(runs(current(thread_id)), & &1["status"])
    end

    test "files are only restored in a worktree of the thread's own" do
      thread_id = launch("write a.txt")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:error, "File restore requires an isolated worktree." <> _} = rollback(thread_id, 1)

      # Rewinding only the conversation leaves the files alone.
      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})
      assert ["completed", "rolled_back"] = Enum.map(runs(current(thread_id)), & &1["status"])
      assert File.exists?("b.txt")
    end

    test "Claude resumes the next turn at the last message of the kept turn", %{work: work} do
      thread_id = launch_in(work, "hello", "claudeAgent")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "hello again")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})

      {:ok, _} = send_message(thread_id, "msg-user-3", "where are we")
      state = await_statuses(thread_id, ["completed", "rolled_back", "completed"])

      assert Enum.any?(
               StreamState.list(state, "message"),
               &(&1["text"] == "resumed at uuid-1 fork False history False")
             )
    end

    test "rolling back ends the background work Claude was running", %{work: work} do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch_in(work, "hello", "claudeAgent")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "work in the background")
      await_statuses(thread_id, ["completed", "completed"])
      await_shell_row(thread_id, &(length(&1["runningBackgroundTasks"] || []) == 2))

      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})

      assert %{"status" => "interrupted"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-2"
               ]

      assert [%{"status" => "interrupted"}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["input"] == "npm run build"))
    end
  end

  describe "forks and handoffs" do
    defp fork(source_id, run_id) do
      fork_id = "thread-#{System.unique_integer([:positive])}"
      :ok = HalC2.Streams.subscribe(fork_id, self(), nil)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.fork",
          "commandId" => "cmd-fork-#{fork_id}",
          "createdBy" => "user",
          "creationSource" => "web",
          "sourceThreadId" => source_id,
          "targetThreadId" => fork_id,
          "sourcePoint" => %{"type" => "run", "runId" => run_id}
        })

      fork_id
    end

    defp replies(state),
      do: for(m <- StreamState.list(state, "message"), m["role"] == "assistant", do: m["text"])

    defp claude, do: %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}}

    test "a fork starts with its source's history and continues the native Codex thread" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])

      state = current(fork_id)

      assert %{
               "title" => "Try codex fork",
               "lineage" => %{"parentThreadId" => ^source_id, "relationshipToParent" => "fork"},
               "forkedFrom" => %{"threadId" => ^source_id}
             } = StreamState.get(state, "thread")[fork_id]

      assert [%{"status" => "completed", "threadId" => ^fork_id}] = runs(state)
      assert "Hello from codex" in replies(state)

      assert [%{"type" => "fork", "status" => "pending"}] =
               StreamState.list(state, "context-transfer")

      {:ok, _} = send_message(fork_id, "msg-fork-1", "where are we")
      state = await_statuses(fork_id, ["completed", "completed"])

      assert "on forked-native-thread-1-at-native-turn-1 history False merged False" in replies(
               state
             )

      assert [%{"status" => "consumed", "resolution" => %{"strategy" => "native_fork"}}] =
               StreamState.list(state, "context-transfer")
    end

    # An MCP app's document is an attachment of its thread, removed with it.
    test "a fork keeps an MCP app's document when its source is deleted" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))

      source_doc = "#{HalC2.Attachments.thread_segment(source_id)}-mcp-app-doc"
      File.mkdir_p!(HalC2.Attachments.dir())
      File.write!(Path.join(HalC2.Attachments.dir(), source_doc <> ".html"), "<p>app</p>")

      {:ok, _} =
        HalC2.Streams.commit(source_id, :thread, [
          {"turn-item", "app-item",
           %{
             "s" => %{
               "id" => "app-item",
               "threadId" => source_id,
               "runId" => run["id"],
               "type" => "dynamic_tool",
               "mcpApp" => %{"attachmentId" => source_doc, "toolResult" => %{"ok" => true}}
             }
           }}
        ])

      fork_id = fork(source_id, run["id"])

      assert %{"mcpApp" => %{"attachmentId" => copy, "toolResult" => %{"ok" => true}}} =
               StreamState.get(current(fork_id), "turn-item")["app-item"]

      assert copy != source_doc
      assert HalC2.McpApps.document_id?(copy)
      assert String.starts_with?(copy, HalC2.Attachments.thread_segment(fork_id) <> "-")

      HalC2.Attachments.delete_thread(source_id)
      assert File.read!(HalC2.Attachments.path(%{"id" => copy})) == "<p>app</p>"
    end

    # The copies are made before the target's stream decides, so a rejected fork must
    # take back what it copied, and never what the winning fork references.
    defp app_source do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))

      source_doc = "#{HalC2.Attachments.thread_segment(source_id)}-mcp-app-doc"
      File.mkdir_p!(HalC2.Attachments.dir())
      File.write!(Path.join(HalC2.Attachments.dir(), source_doc <> ".html"), "<p>app</p>")

      {:ok, _} =
        HalC2.Streams.commit(source_id, :thread, [
          {"turn-item", "app-item",
           %{
             "s" => %{
               "id" => "app-item",
               "threadId" => source_id,
               "runId" => run["id"],
               "type" => "dynamic_tool",
               "mcpApp" => %{"attachmentId" => source_doc, "toolResult" => %{"ok" => true}}
             }
           }}
        ])

      {source_id, run}
    end

    defp fork_to(source_id, run, target_id) do
      Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-fork-#{target_id}-#{System.unique_integer([:positive])}",
        "createdBy" => "user",
        "creationSource" => "web",
        "sourceThreadId" => source_id,
        "targetThreadId" => target_id,
        "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
      })
    end

    test "a fork to an existing target leaves no copies behind" do
      {source_id, run} = app_source()
      fork_id = fork(source_id, run["id"])
      before = attachment_files()

      assert {:error, _} = fork_to(source_id, run, fork_id)
      assert attachment_files() == before
    end

    test "concurrent forks to one target leave only the winner's copies" do
      {source_id, run} = app_source()
      target_id = "thread-#{System.unique_integer([:positive])}"
      before = attachment_files()

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> fork_to(source_id, run, target_id) end) end)
        |> Task.await_many(30_000)

      assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert %{"mcpApp" => %{"attachmentId" => copy}} =
               StreamState.get(current(target_id), "turn-item")["app-item"]

      assert [HalC2.Attachments.path(%{"id" => copy})] == attachment_files() -- before
    end

    # Tool images (the `output` blocks, and an MCP tool's `images`) are attachments of
    # the source thread too, with or without an MCP app on the item.
    test "a fork keeps tool images when its source is deleted" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))

      File.mkdir_p!(HalC2.Attachments.dir())
      segment = HalC2.Attachments.thread_segment(source_id)

      for name <- ~w(out-img img-a img-b) do
        File.write!(Path.join(HalC2.Attachments.dir(), "#{segment}-#{name}.png"), name)
      end

      doc = "#{segment}-mcp-app-doc"
      File.write!(Path.join(HalC2.Attachments.dir(), doc <> ".html"), "<p>app</p>")

      block = fn name ->
        %{"type" => "image", "id" => "#{segment}-#{name}", "mimeType" => "image/png"}
      end

      {:ok, _} =
        HalC2.Streams.commit(source_id, :thread, [
          {"turn-item", "plain-item",
           %{
             "s" => %{
               "id" => "plain-item",
               "threadId" => source_id,
               "runId" => run["id"],
               "type" => "dynamic_tool",
               "output" => [%{"type" => "text", "text" => "hi"}, block.("out-img")],
               "images" => [block.("img-a"), %{"type" => "image", "id" => "#{segment}-gone"}]
             }
           }},
          {"turn-item", "app-item",
           %{
             "s" => %{
               "id" => "app-item",
               "threadId" => source_id,
               "runId" => run["id"],
               "type" => "dynamic_tool",
               "images" => [block.("img-b")],
               "mcpApp" => %{"attachmentId" => doc, "toolResult" => %{"ok" => true}}
             }
           }}
        ])

      fork_id = fork(source_id, run["id"])
      items = StreamState.get(current(fork_id), "turn-item")
      HalC2.Attachments.delete_thread(source_id)

      resolves = fn %{"id" => id} ->
        assert String.starts_with?(id, HalC2.Attachments.thread_segment(fork_id) <> "-")
        assert is_binary(HalC2.Attachments.path(%{"id" => id}))
      end

      assert %{"output" => [%{"text" => "hi"}, out], "images" => [img]} = items["plain-item"]
      resolves.(out)
      resolves.(img)
      assert %{"images" => [img_b], "mcpApp" => %{"attachmentId" => _}} = items["app-item"]
      resolves.(img_b)
    end

    # The item keeps its output; `mcpApp` needs its `attachmentId` to decode, so it goes.
    test "a fork drops mcpApp when the source document is missing" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))

      {:ok, _} =
        HalC2.Streams.commit(source_id, :thread, [
          {"turn-item", "app-item",
           %{
             "s" => %{
               "id" => "app-item",
               "threadId" => source_id,
               "runId" => run["id"],
               "type" => "dynamic_tool",
               "output" => "result",
               "mcpApp" => %{
                 "attachmentId" => "gone-mcp-app-doc",
                 "toolResult" => %{"ok" => true}
               }
             }
           }}
        ])

      fork_id = fork(source_id, run["id"])
      item = StreamState.get(current(fork_id), "turn-item")["app-item"]
      assert item["output"] == "result"
      refute Map.has_key?(item, "mcpApp")
    end

    # Fork history is selected by ordinal (start order): a held queued run a
    # newer run passed was renumbered above the fork point when the passer
    # started, so it and its queued message stay in the source — the same
    # rule the ledger states for messages queued after the fork point.
    test "a fork at a run that passed a held queue does not copy the held run" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))

      {:ok, _} =
        HalC2.Streams.commit(source_id, :thread, [
          {"run", "held",
           %{
             "s" => %{
               "id" => "held",
               "threadId" => source_id,
               "ordinal" => run["ordinal"] + 1,
               "status" => "queued",
               "queuePosition" => 1,
               "queueHeld" => true
             }
           }},
          {"message", "held-msg",
           %{
             "s" => %{
               "id" => "held-msg",
               "threadId" => source_id,
               "runId" => "held",
               "role" => "user",
               "text" => "held ask"
             }
           }}
        ])

      fork_id = fork(source_id, run["id"])
      state = current(fork_id)

      assert [%{"status" => "completed", "threadId" => ^fork_id}] = runs(state)
      texts = for m <- StreamState.list(state, "message"), do: m["text"]
      refute "held ask" in texts
    end

    # Called by `HalC2.Orchestration.Fork` at its stages (`hook/2` there).
    def fork_hook(fun, stage, id), do: fun.(stage, id)

    # The source of a fork is deleted, its files with it, at `at` in the fork: before
    # its history is read (the copies find the files gone), or after the copies were
    # made. Either way the fork is refused and leaves no file of its own behind
    # (thread_files.maude finds the first without the fork's second look).
    for at <- [:reading, :copied] do
      test "a fork whose source is deleted while it is #{at} is refused (#{at})" do
        source_id = launch("hello")
        [run] = runs(await_statuses(source_id, ["completed"]))

        [user] =
          for m <- StreamState.list(current(source_id), "message"), m["role"] == "user", do: m

        file = "#{HalC2.Attachments.thread_segment(source_id)}-#{HalC2.Environment.uuid4()}"
        File.mkdir_p!(HalC2.Attachments.dir())
        File.write!(Path.join(HalC2.Attachments.dir(), file <> ".txt"), "the notes")

        {:ok, _} =
          HalC2.Streams.commit(source_id, :thread, [
            {"message", user["id"],
             %{
               "s" => %{
                 "attachments" => [%{"type" => "file", "id" => file, "name" => "notes.txt"}]
               }
             }}
          ])

        at = unquote(at)

        Application.put_env(
          :hal_c2,
          :fork_hook,
          {__MODULE__, :fork_hook,
           [
             fn
               ^at, id ->
                 {:ok, _} = Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
                 HalC2.Attachments.delete_thread(id)

               _stage, _id ->
                 :ok
             end
           ]}
        )

        on_exit(fn -> Application.delete_env(:hal_c2, :fork_hook) end)
        fork_id = "thread-#{System.unique_integer([:positive])}"

        assert {:error, message} =
                 Orchestration.dispatch(%{
                   "type" => "thread.fork",
                   "commandId" => "cmd-fork-#{fork_id}",
                   "createdBy" => "user",
                   "creationSource" => "web",
                   "sourceThreadId" => source_id,
                   "targetThreadId" => fork_id,
                   "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
                 })

        assert message =~ "was deleted"
        refute StreamState.get(current(fork_id), "thread")[fork_id]

        assert Path.wildcard(
                 Path.join(
                   HalC2.Attachments.dir(),
                   HalC2.Attachments.thread_segment(fork_id) <> "-*"
                 )
               ) == []
      end
    end

    # Called by `HalC2.Store` inside its append (`hook/2` there): stream `id` cannot be
    # written, as on a full disk.
    def refuse_append(id, :append_change, id), do: raise("the disk is full")
    def refuse_append(_id, _stage, _stream_id), do: :ok

    test "a fork whose thread cannot be written leaves no file of its own behind" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))

      [user] =
        for m <- StreamState.list(current(source_id), "message"), m["role"] == "user", do: m

      file = "#{HalC2.Attachments.thread_segment(source_id)}-#{HalC2.Environment.uuid4()}"
      File.mkdir_p!(HalC2.Attachments.dir())
      File.write!(Path.join(HalC2.Attachments.dir(), file <> ".txt"), "the notes")

      {:ok, _} =
        HalC2.Streams.commit(source_id, :thread, [
          {"message", user["id"],
           %{
             "s" => %{
               "attachments" => [%{"type" => "file", "id" => file, "name" => "notes.txt"}]
             }
           }}
        ])

      fork_id = "thread-#{System.unique_integer([:positive])}"
      Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_append, [fork_id]})
      on_exit(fn -> Application.delete_env(:hal_c2, :store_hook) end)

      assert_raise RuntimeError, "the disk is full", fn ->
        Orchestration.dispatch(%{
          "type" => "thread.fork",
          "commandId" => "cmd-fork-#{fork_id}",
          "createdBy" => "user",
          "creationSource" => "web",
          "sourceThreadId" => source_id,
          "targetThreadId" => fork_id,
          "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
        })
      end

      Application.delete_env(:hal_c2, :store_hook)
      refute StreamState.get(current(fork_id), "thread")[fork_id]

      assert Path.wildcard(
               Path.join(
                 HalC2.Attachments.dir(),
                 HalC2.Attachments.thread_segment(fork_id) <> "-*"
               )
             ) == []
    end

    test "a fork on another provider gets the history as a transcript" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])

      {:ok, _} = send_message(fork_id, "msg-fork-1", "where are we", claude())
      state = await_statuses(fork_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)

      assert [%{"resolution" => %{"strategy" => "portable_context"}}] =
               StreamState.list(state, "context-transfer")

      assert [%{"strategy" => "full_thread_summary", "summaryText" => summary}] =
               StreamState.list(state, "context-handoff")

      assert summary =~ "User: hello"
      assert summary =~ "Assistant: Hello from codex"
    end

    test "switching provider mid-thread hands the conversation over" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we", claude())
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)
    end

    test "provider.switch moves the next run to the new provider, with the conversation" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])

      {:ok, _} =
        Orchestration.dispatch(
          Map.merge(claude(), %{"type" => "provider.switch", "threadId" => thread_id})
        )

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we")
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)
    end

    test "a turn a restart cut off goes on when the project asks for that" do
      start_supervised!(HalC2.Settings)
      {_, version} = HalC2.Settings.get()
      {:ok, _} = HalC2.Settings.put(%{"continueThreadsAfterServerUpdate" => true}, version)

      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      :ok = HalC2.Shell.subscribe(self())
      await_shell_row(thread_id, &(&1["activeRunId"] != nil))

      # The MC stops: its provider processes go with it.
      for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread_id),
          do: :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)

      assert thread_id in HalC2.Orchestration.Recovery.run()
      :ok = HalC2.Orchestration.Recovery.continue()

      state = await_statuses(thread_id, ["interrupted", "completed"])

      assert %{"text" => "Continue where you left off.", "createdBy" => "agent"} =
               StreamState.get(state, "message")[
                 "message:restart-continuation:" <> hd(runs(state))["id"]
               ]

      # It asks once.
      :ok = HalC2.Orchestration.Recovery.continue()
      assert length(runs(current(thread_id))) == 2
    end

    test "an MC without automatic actions leaves a cut-off turn where it stopped" do
      start_supervised!(HalC2.Settings)
      {_, version} = HalC2.Settings.get()
      {:ok, _} = HalC2.Settings.put(%{"continueThreadsAfterServerUpdate" => true}, version)
      Application.put_env(:hal_c2, :auto_actions, false)
      on_exit(fn -> Application.delete_env(:hal_c2, :auto_actions) end)

      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      :ok = HalC2.Shell.subscribe(self())
      await_shell_row(thread_id, &(&1["activeRunId"] != nil))

      for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread_id),
          do: :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)

      assert thread_id in HalC2.Orchestration.Recovery.run()
      :ok = HalC2.Orchestration.Recovery.continue()

      assert [%{"status" => "interrupted"}] = runs(await_statuses(thread_id, ["interrupted"]))
    end

    test "an idle session is stopped, and the next run starts it again" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")
      :ok = HalC2.Shell.subscribe(self())
      await_shell_row(thread_id, &(&1["activeRunId"] == nil))

      # The next message reads this registry, so a released session is gone from it when
      # the check returns. Its partitions held back, the registry's own asynchronous
      # cleanup of the dead pid cannot make the lookup pass, nor missing it fail it now
      # and then (#436).
      partitions =
        for {_id, partition, :worker, _} <-
              Supervisor.which_children(HalC2.Codex.Registry),
            do: partition

      assert partitions != []
      Enum.each(partitions, &:sys.suspend/1)

      try do
        assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
        assert Registry.lookup(HalC2.Codex.Registry, thread_id) == []
      after
        Enum.each(partitions, &:sys.resume/1)
      end

      assert [%{"status" => "stopped"}] =
               StreamState.list(current(thread_id), "provider-session")

      {:ok, _} = send_message(thread_id, "m2", "list the files again")
      state = await_statuses(thread_id, ["completed", "completed"])
      assert [%{"status" => "ready"}] = StreamState.list(state, "provider-session")
    end

    test "a stopped session starts again on the next run and resumes its thread" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])
      [session] = StreamState.list(current(thread_id), "provider-session")

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "provider-session.detach",
          "threadId" => thread_id,
          "providerSessionId" => session["id"]
        })

      assert [] = StreamState.list(current(thread_id), "provider-session")
      assert [] = Registry.lookup(HalC2.Codex.Registry, thread_id)

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we")
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "on native-thread-1 history False merged False" in replies(state)
      assert [_] = StreamState.list(state, "provider-session")
    end

    # Stopping the session drops its record; what the agent's session can do outlives it,
    # and the resumed session, which names no model, does not say it again.
    test "an ACP session that cannot switch models still refuses after it is stopped" do
      System.put_env("FAKE_ACP_NO_MODEL_SWITCH", "1")
      on_exit(fn -> System.delete_env("FAKE_ACP_NO_MODEL_SWITCH") end)
      thread_id = launch("hello", "grok")
      await_statuses(thread_id, ["completed"])
      [session] = StreamState.list(current(thread_id), "provider-session")
      refused = {:error, "The active ACP session does not expose a model-switch capability."}

      set_model = fn ->
        Orchestration.dispatch(%{
          "type" => "thread.model-selection.set",
          "threadId" => thread_id,
          "modelSelection" => %{"instanceId" => "grok", "model" => "gpt-4.1"}
        })
      end

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "provider-session.detach",
          "threadId" => thread_id,
          "providerSessionId" => session["id"]
        })

      assert set_model.() == refused

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we")
      await_statuses(thread_id, ["completed", "completed"])
      assert set_model.() == refused
    end

    test "merging a fork back brings its newer work to the parent's next run" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])
      {:ok, _} = send_message(fork_id, "msg-fork-1", "write fork.txt")
      [_, fork_run] = runs(await_statuses(fork_id, ["completed", "completed"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.merge_back",
          "commandId" => "cmd-merge",
          "createdBy" => "user",
          "sourceThreadId" => fork_id,
          "targetThreadId" => source_id,
          "sourcePoint" => %{"type" => "run", "runId" => fork_run["id"]}
        })

      {:ok, _} = send_message(source_id, "msg-user-2", "where are we")
      state = await_statuses(source_id, ["completed", "completed"])

      assert "on native-thread-1 history False merged True" in replies(state)

      assert [%{"strategy" => "fork_delta_summary", "summaryText" => summary}] =
               StreamState.list(state, "context-handoff")

      # Only the fork's own work, not the history it started with.
      assert summary =~ "User: write fork.txt"
      refute summary =~ "User: hello"
    end
  end

  defp await_shell_row(thread_id, done?) do
    case HalC2.Shell.row(node(), thread_id) do
      {"thread", row} ->
        if done?.(row), do: :ok, else: await_shell_message(thread_id, done?)

      _ ->
        await_shell_message(thread_id, done?)
    end
  end

  defp await_shell_message(thread_id, done?) do
    receive do
      {:hal_c2_shell, {:rows, _, _}} -> await_shell_row(thread_id, done?)
    after
      5_000 -> flunk("the sidebar row never got there")
    end
  end

  defp await_state(thread_id, done?) do
    state = current(thread_id)

    if done?.(state) do
      state
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_state(thread_id, done?)
      after
        5_000 -> flunk("the thread's stream never got there")
      end
    end
  end

  defp await_thread(thread_id, done?) do
    if done?.(StreamState.get(current(thread_id), "thread")[thread_id]) do
      :ok
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_thread(thread_id, done?)
      after
        5_000 -> flunk("the thread never got there")
      end
    end
  end

  defp await_runs(thread_id, count) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        state = current(thread_id)
        runs = StreamState.list(state, "run")

        if length(runs) == count and Enum.all?(runs, &(&1["status"] == "completed")),
          do: state,
          else: await_runs(thread_id, count)
    after
      5_000 -> flunk("runs never completed")
    end
  end

  defp await_item(thread_id, type) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        if Enum.any?(StreamState.list(current(thread_id), "turn-item"), &(&1["type"] == type)),
          do: :ok,
          else: await_item(thread_id, type)
    after
      5_000 -> flunk("no #{type} item")
    end
  end

  # Codex holds a steer whose text starts with "hold " until the gate file "steer" in
  # the returned directory exists.
  defp held_steers(dir, env \\ []) do
    gates = Path.join(dir, "gates")
    File.mkdir_p!(gates)

    Application.put_env(
      :hal_c2,
      :codex_command,
      ["env", "FAKE_CODEX_GATE=#{gates}" | env] ++ ["python3", "-u", @fake_codex]
    )

    gates
  end

  # The fake Codex's receipt that a "hold ..." steer reached it and waits on the
  # gate file "steer". The fake is another OS process whose only channel into the
  # test is the filesystem, so its file is the receipt: this waits on it up to a
  # deadline.
  defp await_held_steer(gates) do
    await_file(Path.join(gates, "steer.held"), System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("#{path} was not written in time")

      true ->
        Process.sleep(10)
        await_file(path, deadline)
    end
  end

  # A stand-in in the Codex registry that refuses a steer with a reason that is
  # not a string (and settles at once). Its thread has no live runtime, so it
  # registers first try and `:odd_registered` is the receipt to wait on.
  defp odd_runtime(thread_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(HalC2.Codex.Registry, thread_id, nil)
        send(parent, :odd_registered)
        odd_loop()
      end)

    assert_receive :odd_registered, 5_000
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp odd_loop do
    receive do
      {:"$gen_call", from, {:steer, _run_id, _message}} ->
        GenServer.reply(from, {:error, %{"odd" => "refusal"}})
        odd_loop()

      {:"$gen_call", from, :settle} ->
        GenServer.reply(from, :ok)
        odd_loop()
    end
  end

  defp await_turn_item(thread_id, id) do
    if StreamState.get(current(thread_id), "turn-item")[id] do
      :ok
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_turn_item(thread_id, id)
      after
        5_000 -> flunk("no turn item #{id}")
      end
    end
  end

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  # Stands in for the thread's session in `registry`: it exits as a released session
  # would when it is asked `tag` (a request, or the tag of one). The real session, if
  # any, leaves the registry and keeps running, so a turn it holds still runs.
  defp stand_in(registry, thread_id, tag) do
    case Registry.lookup(registry, thread_id) do
      [{real, _}] ->
        :sys.replace_state(real, fn state ->
          :ok = Registry.unregister(registry, thread_id)
          state
        end)

      [] ->
        :ok
    end

    test = self()

    # Not linked: its exit would take the test with it.
    session =
      spawn(fn ->
        {:ok, _} = Registry.register(registry, thread_id, nil)
        send(test, :registered)

        receive do
          {:"$gen_call", _from, request} when request == tag when elem(request, 0) == tag ->
            exit({:shutdown, :released})
        end
      end)

    assert_receive :registered
    on_exit(fn -> Process.exit(session, :kill) end)
  end

  defp send_message(thread_id, message_id, text, extra \\ %{}) do
    Orchestration.dispatch(
      Map.merge(
        %{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => message_id,
          "text" => text,
          "attachments" => [],
          "dispatchMode" => %{"type" => "queue_after_active"}
        },
        extra
      )
    )
  end

  defp attachment_files, do: HalC2.Attachments.dir() |> Path.join("*") |> Path.wildcard()

  # An uploaded, not yet sent, file.
  defp pending_upload do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "name" => "a.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(png)
      })

    :ok = HalC2.Attachments.store(token, png)

    %{
      "type" => "image",
      "id" => id,
      "name" => "a.png",
      "mimeType" => "image/png",
      "sizeBytes" => byte_size(png)
    }
  end

  # A pasted text a client folded and uploaded, as the desktop does with a long paste.
  defp pending_text_upload(name, text) do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "name" => name,
        "mimeType" => "text/plain",
        "sizeBytes" => byte_size(text)
      })

    :ok = HalC2.Attachments.store(token, text)

    %{
      "type" => "file",
      "id" => id,
      "name" => name,
      "mimeType" => "text/plain",
      "sizeBytes" => byte_size(text),
      "source" => %{"_tag" => "pasted-text"}
    }
  end

  defp queue_command(type, thread_id, run_id, extra \\ %{}),
    do:
      Orchestration.dispatch(
        Map.merge(%{"type" => type, "threadId" => thread_id, "runId" => run_id}, extra)
      )

  # Waits until the thread's runs, in order, have these statuses.
  defp await_statuses(thread_id, statuses) do
    state = current(thread_id)

    if Enum.map(runs(state), & &1["status"]) == statuses do
      state
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_statuses(thread_id, statuses)
      after
        5_000 ->
          flunk(
            "runs never reached #{inspect(statuses)}: #{inspect(Enum.map(runs(state), & &1["status"]))}"
          )
      end
    end
  end

  test "a provider diff never replaces a captured checkpoint and must name a checkpoint ref" do
    {thread_id, run_id} = recorded_run("completed")
    scope = HalC2.Checkpoint.scope_id(thread_id)
    checkpoint_id = HalC2.Checkpoint.checkpoint_id(scope, 1)

    command = fn ref, status ->
      %{
        "type" => "thread.turn.diff.complete",
        "threadId" => thread_id,
        "turnId" => run_id,
        "completedAt" => HalC2.Orchestration.Entities.now(),
        "checkpointRef" => ref,
        "status" => status,
        "files" => [],
        "checkpointTurnCount" => 1
      }
    end

    # A placeholder for a run with no checkpoint is recorded; a captured
    # checkpoint may then replace the placeholder.
    assert {:ok, _} = Orchestration.dispatch(command.("provider-diff:event-1", "missing"))

    assert {:ok, _} =
             Orchestration.dispatch(command.(HalC2.Checkpoint.ref(scope, 1), "ready"))

    checkpoint = current(thread_id) |> StreamState.get("checkpoint") |> Map.fetch!(checkpoint_id)
    assert checkpoint["status"] == "ready"

    # Nothing replaces what was captured, in either direction.
    assert {:error, already} =
             Orchestration.dispatch(command.(HalC2.Checkpoint.ref(scope, 1), "ready"))

    assert already =~ "already has a captured checkpoint"

    assert {:error, _} = Orchestration.dispatch(command.("provider-diff:event-2", "missing"))

    # A ready checkpoint's ref reaches git, so only checkpoint refs are accepted.
    assert {:error, not_ref} = Orchestration.dispatch(command.("config", "ready"))
    assert not_ref =~ "is not under refs/hal-c2/ or refs/t3/"

    assert current(thread_id) |> StreamState.get("checkpoint") |> Map.fetch!(checkpoint_id) ==
             checkpoint
  end

  defp await_request(thread_id) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        case thread_id |> current() |> StreamState.list("runtime-request") do
          [%{"status" => "pending"} = request] -> request
          _ -> await_request(thread_id)
        end
    after
      5_000 -> flunk("no approval request")
    end
  end
end
