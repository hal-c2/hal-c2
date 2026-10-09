defmodule HalC2.TurnLifecycleTest do
  # Regressions proof/hal_c2/turns_proof_test.exs found: a run's start and end racing a
  # delete, a start that gave up, a start that could not reach its runtime, and an idle
  # session's release. Codex stands for every runtime there; the runtimes' own handling
  # of a run that ended as its turn started is tested for each.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.{TurnWatch, TurnWriter}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)
  @fake_pi Path.expand("../support/fake_pi_rpc.py", __DIR__)

  setup %{tmp_dir: dir} = context do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    # Each fake logs the messages it got under the test's directory.
    Application.put_env(:hal_c2, :claude_command, [
      "env",
      "FAKE_CLAUDE_LOG=#{Path.join(dir, "provider.log")}",
      "python3",
      "-u",
      @fake_claude
    ])

    Application.put_env(:hal_c2, :acp_commands, %{
      "opencode" => [
        "env",
        "FAKE_ACP_TRACE=#{Path.join(dir, "provider.log")}",
        "python3",
        "-u",
        @fake_acp
      ]
    })

    # Pi runs its settings' binary, never the `pi` on PATH.
    pi = Path.join([dir, "bin", "pi"])
    File.mkdir_p!(Path.dirname(pi))
    File.write!(pi, "#!/bin/sh\nFAKE_DIR='#{dir}' exec python3 -u '#{@fake_pi}' \"$@\"\n")
    File.chmod!(pi, 0o755)
    File.write!(Path.join(dir, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    start_supervised!(HalC2.Settings)
    {settings, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        Map.put(settings, "providers", %{"pi" => %{"enabled" => true, "binaryPath" => pi}}),
        version
      )

    for id <- ~w(opencode pi), do: HalC2.Acp.forget(id)

    on_exit(fn ->
      for key <-
            ~w(codex_command claude_command acp_commands settings_check_ms release_timeout_ms)a,
          do: Application.delete_env(:hal_c2, key)

      for id <- ~w(opencode pi), do: HalC2.Acp.forget(id)
    end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    for registry <- [HalC2.Claude.Registry, HalC2.Acp.Registry, HalC2.Pi.Registry],
        do: start_supervised!({Registry, keys: :unique, name: registry}, id: registry)

    start_supervised!(
      {DynamicSupervisor,
       name: HalC2.Codex.Supervisor,
       strategy: :one_for_one,
       max_children: context[:max_children] || :infinity}
    )

    %{thread_id: create_thread(work, "codex", "gpt-5.4"), work: work, dir: dir}
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

  # IdleSessions found the thread idle and released its runtime just as a message
  # started a run there: the runtime stopped under the start, and the run failed.
  test "a turn that starts as its idle runtime is released runs on a new one",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1", "say done")
    await_statuses(thread_id, ["completed"])
    [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    test = self()

    :ok = :sys.suspend(runtime)
    :erlang.trace(runtime, true, [:receive])
    spawn(fn -> send(test, {:released, Orchestration.release_session(thread_id)}) end)
    assert_receive {:trace, ^runtime, :receive, {:"$gen_call", _, :release}}, 5_000
    spawn(fn -> send(test, {:sent, send_message(thread_id, "m2")}) end)
    assert_receive {:trace, ^runtime, :receive, {:"$gen_call", _, {:start_turn, _}}}, 5_000
    :erlang.trace(runtime, false, [:receive])
    :ok = :sys.resume(runtime)

    assert_receive {:released, :ok}, 5_000
    assert_receive {:sent, {:ok, _}}, 5_000
    await_statuses(thread_id, ["completed", "running"])
    assert [{fresh, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    assert fresh != runtime
  end

  # A runtime that did not answer its release in time was taken for gone: its agent's
  # credential was revoked while it ran on, perhaps driving a turn.
  test "a runtime that does not answer its release in time is kept", %{thread_id: thread_id} do
    start_supervised!(HalC2.Mcp)
    {:ok, _} = send_message(thread_id, "m1", "say done")
    await_statuses(thread_id, ["completed"])
    [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    credential = HalC2.Mcp.server(thread_id, "codex")

    :ok = :sys.suspend(runtime)
    Application.put_env(:hal_c2, :release_timeout_ms, 0)
    assert :busy = Orchestration.release_session(thread_id)
    assert [{^runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    assert HalC2.Mcp.server(thread_id, "codex") == credential

    # The release it was asked for is the runtime's to answer: idle, it lets go then.
    ref = Process.monitor(runtime)
    :ok = :sys.resume(runtime)
    assert_receive {:DOWN, ^ref, :process, _, {:shutdown, :released}}, 5_000
  end

  # The other order: the runtime took a turn after the thread looked idle. Stopping it
  # left the run running with nothing driving it, for IdleSessions to fail.
  test "a runtime asked to release itself keeps the turn it drives", %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    [running] = await_statuses(thread_id, ["running"])
    [{runtime, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)

    assert :busy = GenServer.call(runtime, :release)
    :ok = HalC2.Codex.ThreadRuntime.interrupt(thread_id, running["id"])
    await_statuses(thread_id, ["interrupted"])
    ref = Process.monitor(runtime)
    assert :ok = Orchestration.release_session(thread_id)
    assert_receive {:DOWN, ^ref, :process, _, {:shutdown, :released}}, 5_000
  end

  # A run that ended while the runtime started its turn (here its start gave up) never
  # reached the provider, and the next message's turn runs alone. Codex lets go of a
  # native turn it had started (see the test above); these start theirs after.
  for {instance, model} <- [
        {"claudeAgent", "claude-haiku-4-5"},
        {"opencode", "gpt-5.4"},
        {"pi", "default"}
      ] do
    test "a #{instance} turn whose run ended as it started never reaches the provider",
         %{work: work, dir: dir} do
      thread_id = create_thread(work, unquote(instance), unquote(model))
      watch = suspend_watch()
      test = self()
      spawn(fn -> send(test, {:sent, send_message(thread_id, "m1", "first message")}) end)
      _runtime = await_claim(watch)
      [first] = await_statuses(thread_id, ["starting"])
      TurnWriter.abandon(thread_id, first["id"], "failed", TurnWriter.start_failure(nil, :closed))
      :ok = :sys.resume(watch)
      assert_receive {:sent, {:ok, _}}, 5_000

      {:ok, _} = send_message(thread_id, "m2", "second message")
      await_statuses(thread_id, ["failed", "completed"])
      # The second turn's prompt carries the thread's history, the first message included.
      assert [prompt] = provider_prompts(dir, unquote(instance))
      assert prompt =~ "second message"
    end
  end

  # A turn Claude began by itself (a wake) whose run ended as it started: Claude is told
  # to stop it, and what it says goes on as between turns.
  test "a Claude wake whose run ended as it started is interrupted", %{work: work, dir: dir} do
    trace = Path.join(dir, "claude-trace.log")
    command = Application.get_env(:hal_c2, :claude_command)
    Application.put_env(:hal_c2, :claude_command, ["env", "FAKE_CLAUDE_TRACE=#{trace}" | command])
    thread_id = create_thread(work, "claudeAgent", "claude-haiku-4-5")
    {:ok, _} = send_message(thread_id, "m1", "hello")
    await_statuses(thread_id, ["completed"])
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
    session = :sys.get_state(runtime).session

    watch = suspend_watch()
    send(runtime, {:claude, session, {:message, claude_text("m-wake", "The build passed")}})
    ^runtime = await_claim(watch)
    [_, wake] = await_statuses(thread_id, ["completed", "starting"])
    TurnWriter.abandon(thread_id, wake["id"], "failed", TurnWriter.start_failure(nil, :closed))
    :ok = :sys.resume(watch)

    send(runtime, {:claude, session, {:message, %{"type" => "result", "subtype" => "success"}}})
    assert %{wake: nil, turn: nil} = :sys.get_state(runtime)
    assert File.read!(trace) =~ ~s("subtype": "interrupt")

    assert [] =
             for(
               %{"runId" => run} = m <- StreamState.list(current(thread_id), "message"),
               run == wake["id"] and m["role"] == "assistant",
               do: m
             )

    {:ok, _} = send_message(thread_id, "m2", "hello again")
    await_statuses(thread_id, ["completed", "failed", "completed"])
  end

  defp create_thread(work, instance, model) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Turns",
        "modelSelection" => %{"instanceId" => instance, "model" => model},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    thread_id
  end

  # The prompts a fake provider got, one per turn it ran.
  defp provider_prompts(dir, instance) do
    {file, prompt?} =
      case instance do
        "claudeAgent" -> {"provider.log", &Map.has_key?(&1, "text")}
        "opencode" -> {"provider.log", &match?(%{"in" => %{"method" => "session/prompt"}}, &1)}
        "pi" -> {"log.jsonl", &match?(%{"recv" => %{"type" => "prompt"}}, &1)}
      end

    for line <- File.read!(Path.join(dir, file)) |> String.split("\n", trim: true),
        entry = JSON.decode!(line),
        prompt?.(entry),
        do: line
  end

  defp claude_text(id, text),
    do: %{
      "type" => "assistant",
      "message" => %{"id" => id, "content" => [%{"type" => "text", "text" => text}]}
    }

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

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

  defp send_message(thread_id, message_id, text \\ nil) do
    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "messageId" => message_id,
      "text" => text || "wait #{message_id}",
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
