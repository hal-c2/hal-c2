defmodule HalC2.Steps.Orchestration.ReattachAfterRestart do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Orchestration.Recovery
  alias HalC2.Subprocess.Durable
  alias HalC2.Test.{AcpFixtures, FakeAcp}
  alias HalC2.Test.Mc.World

  # Real programs (the fakes) under the real shim. An MC "dies" or "shuts down" by
  # stopping its services with `Recovery.stopping?/0` true: the helper goes and the
  # program stays, which a real VM kill does too (see subprocess_durable_test.exs, which kills one).
  # Every provider proves both directions the same way: its turn waits, the stop crosses
  # the new helper to the same program, and its answer comes back through the file.

  @wait "wait for me"

  defp durable(context) do
    Application.put_env(:hal_c2, :durable_programs, true)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:hal_c2, :durable_programs, false)
      Recovery.leaving(false)
    end)

    context
  end

  # Each provider on its own fake; what differs is only how it is made this MC's.
  defp install(context, "pi") do
    wait = %{"match" => @wait, "steps" => [%{"waitAbort" => true}]}
    FakeAcp.install_pi(context, %{}, enabled: true, turns: [wait | FakeAcp.pi_turns()])
  end

  defp install(context, "muse") do
    wait = %{"match" => @wait, "steps" => [%{"waitInterrupt" => true}]}
    FakeAcp.install_muse(context, %{}, enabled: true, turns: [wait])
  end

  defp install(context, "antigravity") do
    context =
      FakeAcp.install(
        context,
        "antigravity",
        %{
          "googleAuth" => true,
          "turns" => [%{"match" => @wait, "steps" => [%{"waitCancel" => true}]} | FakeAcp.turns()]
        },
        binary: "agy_acp_server.par",
        enabled: true
      )

    harness =
      Path.join(Path.dirname(FakeAcp.fake(context, "antigravity").bin), "localharness_external")

    File.write!(harness, "#!/bin/sh\n")
    File.chmod!(harness, 0o755)
    token = HalC2.Acp.Antigravity.token_path("antigravity")
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, JSON.encode!(%{"account" => "user@example.com"}))
    context
  end

  defp install(context, "acpRegistry") do
    ctx =
      context
      |> AcpFixtures.ready()
      |> AcpFixtures.publish()
      |> AcpFixtures.run_as("acme", "acme")

    AcpFixtures.add_registry_instance("acme", "acme")
    ctx
  end

  defp install(context, _provider), do: context

  defp instance("acpRegistry"), do: "acme"
  defp instance(provider), do: provider

  defp turn_on(context, thread, provider, text \\ @wait) do
    context = context |> durable() |> World.fake_providers() |> install(provider)
    fields = if provider == "antigravity", do: %{"model" => "antigravity-default"}, else: %{}
    context = World.launch_on(context, thread, instance(provider), text, fields)

    run =
      if text == @wait, do: World.await_running(context, thread), else: latest(context, thread)

    context = context |> Map.put(:thread, thread) |> Map.put(:running, run["id"])
    await_checkpoint(context, thread, text == @wait)
    Map.put(context, :program, program(context, thread))
  end

  defp latest(context, thread) do
    World.await_idle(context, thread)
    World.state(context, thread) |> HalC2.StreamState.list("run") |> Enum.max_by(& &1["ordinal"])
  end

  # The boot adopts only what has a checkpoint on this run.
  defp await_checkpoint(context, thread, on_run? \\ true, tries \\ 500) do
    run = context.running
    id = World.thread_id(context, thread)

    saved? =
      with %{dir: dir} <- Durable.survivors_peek()[id],
           {:ok, binary} <- File.read(Path.join(dir, "snapshot")),
           %{state: %{turn: turn}} <- :erlang.binary_to_term(binary) do
        if on_run?, do: match?(%{ids: %{run: ^run}}, turn), else: turn == nil
      else
        _ -> false
      end

    cond do
      saved? -> :ok
      tries == 0 -> flunk("no checkpoint for the run of #{thread}")
      true -> Process.sleep(10) && await_checkpoint(context, thread, on_run?, tries - 1)
    end
  end

  defp program(context, thread) do
    id = World.thread_id(context, thread)

    case Durable.survivors_peek()[id] do
      %{dir: dir} -> JSON.decode!(File.read!(Path.join(dir, "meta")))["pid"]
      nil -> nil
    end
  end

  defp status(context, thread),
    do: World.state(context, thread).entities["run"][context.running]["status"]

  defp await_dead(pid, tries \\ 200) do
    cond do
      not alive?(pid) -> :ok
      tries == 0 -> flunk("program #{pid} is still running")
      true -> Process.sleep(10) && await_dead(pid, tries - 1)
    end
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  defp await_status(context, thread, status) do
    World.await_state(
      context,
      thread,
      fn state ->
        state.entities["run"][context.running]["status"] == status
      end,
      10_000
    )
  end

  step(
    ~r/^thread "(?<thread>[^"]+)" has a running turn on "(?<provider>[^"]+)"$/,
    %{args: [thread, provider]} = context,
    do: turn_on(context, thread, provider)
  )

  # Every runtime goes now, as all of them go with a real VM: not all sit under what
  # the harness's stop takes down, and one left over would stop its program later.
  step ~r/^the MC (?:dies|shuts down)$/, context do
    Recovery.leaving(true)

    for registry <- [
          HalC2.Codex.Registry,
          HalC2.Claude.Registry,
          HalC2.Acp.Registry,
          HalC2.Pi.Registry,
          HalC2.Muse.Registry
        ],
        Process.whereis(registry),
        thread <- Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        {pid, _} <- Registry.lookup(registry, thread) do
      state = :sys.get_state(pid)
      channel = state[:conn] || state[:session]
      ref = channel && Process.monitor(channel)
      GenServer.stop(pid, :shutdown)
      # What holds the program goes too, before anything can read the MC as back.
      if ref, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
    end

    context
  end

  step "the provider process of {string} is the one that was running",
       %{args: [thread]} = context do
    settled(context, thread)
    assert program(context, thread) == context.program
    assert alive?(context.program)
    context
  end

  step "the run of {string} is still running", %{args: [thread]} = context do
    assert status(context, thread) == "running"
    context
  end

  step "the user stops {string} after the restart", %{args: [thread]} = context do
    settled(context, thread)
    assert status(context, thread) == "running"
    assert alive?(context.program)

    {reply, context} =
      World.dispatch(context, %{
        "type" => "run.interrupt",
        "commandId" => "command:stop-#{thread}",
        "threadId" => World.thread_id(context, thread)
      })

    assert {:ok, _} = reply
    await_status(context, thread, "interrupted")
    context
  end

  step "no continuation message is sent to {string} after reattaching",
       %{args: [thread]} = context do
    runs = World.state(context, thread).entities["run"]
    refute Enum.any?(runs, fn {id, _} -> id =~ "restart-continuation" end)
    context
  end

  step "the provider process of {string} exits while the MC is down",
       %{args: [thread]} = context do
    System.cmd("kill", ["-KILL", "#{context.program}"])
    _ = thread
    context
  end

  step "the run of {string} ended without a second program",
       %{args: [thread]} = context do
    World.await_state(
      context,
      thread,
      fn state ->
        state.entities["run"][context.running]["status"] in ~w(failed interrupted)
      end,
      10_000
    )

    context
  end

  step "the snapshot of {string} is unreadable", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    %{dir: dir} = Durable.survivors_peek()[id]
    File.write!(Path.join(dir, "snapshot"), "not a snapshot")
    context
  end

  defp programs(context, thread) do
    id = World.thread_id(context, thread)

    for name <- File.ls!(Durable.root()),
        {:ok, text} <- [File.read(Path.join([Durable.root(), name, "meta"]))],
        JSON.decode!(text)["thread"] == id,
        do: name
  end

  step ~r/^thread "(?<thread>[^"]+)" finished a turn on "(?<provider>[^"]+)" and its provider process is live$/,
       %{args: [thread, provider]} = context do
    context = turn_on(context, thread, provider, "hello")
    World.await_idle(context, thread)
    context
  end

  step "the user sends {string} to {string} after the restart",
       %{args: [text, thread]} = context do
    settled(context, thread)
    context = World.post_message(context, thread, text)
    World.await_idle(context, thread)
    context
  end

  step "a new run of {string} completed on that program", %{args: [thread]} = context do
    assert program(context, thread) == context.program
    assert alive?(context.program)
    assert [_one] = programs(context, thread)

    latest =
      World.state(context, thread)
      |> HalC2.StreamState.list("run")
      |> Enum.max_by(& &1["ordinal"])

    assert latest["status"] == "completed"
    context
  end

  step ~r/^thread "(?<thread>[^"]+)" has a turn on "(?<provider>[^"]+)" waiting on an approval$/,
       %{args: [thread, provider]} = context do
    context = context |> durable() |> World.fake_providers() |> install(provider)

    context =
      World.launch_on(context, thread, instance(provider), "approve this", %{
        "runtimeMode" => "approval-required"
      })

    request = World.await_request(context, thread)
    run = World.await_running(context, thread)
    context = context |> Map.put(:thread, thread) |> Map.put(:running, run["id"])
    await_checkpoint(context, thread)

    context
    |> Map.put(:program, program(context, thread))
    |> Map.put(:request_id, request["id"])
  end

  step "the approval of {string} is still pending", %{args: [thread]} = context do
    settled(context, thread)
    request = World.state(context, thread).entities["runtime-request"][context.request_id]
    assert request["status"] == "pending"
    context
  end

  step "the user approves it, and the run of {string} completes on that program",
       %{args: [thread]} = context do
    {reply, context} =
      World.dispatch(context, %{
        "type" => "runtime-request.respond",
        "commandId" => "command:approve-#{thread}",
        "threadId" => World.thread_id(context, thread),
        "requestId" => context.request_id,
        "decision" => "accept"
      })

    assert {:ok, _} = reply
    await_status(context, thread, "completed")
    assert alive?(context.program)
    context
  end

  step "the provider process of {string} crashes after the restart",
       %{args: [thread]} = context do
    settled(context, thread)
    id = World.thread_id(context, thread)
    %{dir: dir} = Durable.survivors_peek()[id]
    %{"group" => group} = JSON.decode!(File.read!(Path.join(dir, "meta")))
    System.cmd("kill", ["-KILL", "--", "-#{group}"])
    context
  end

  step "the run of {string} fails", %{args: [thread]} = context do
    World.await_state(
      context,
      thread,
      &(&1.entities["run"][context.running]["status"] == "failed"),
      15_000
    )

    context
  end

  step "the machine reboots", context do
    id = World.thread_id(context, context.thread)
    %{dir: dir} = Durable.survivors_peek()[id]
    %{"group" => group} = JSON.decode!(File.read!(Path.join(dir, "meta")))
    System.cmd("kill", ["-KILL", "--", "-#{group}"])
    await_dead(context.program)
    context
  end

  # The adopted runtime has handled what adoption sent it, the first flush included.
  defp settled(context, thread), do: :sys.get_state(runtime(context, thread))

  defp await_saved_past(context, thread, text, tries \\ 500) do
    id = World.thread_id(context, thread)
    %{dir: dir} = Durable.survivors_peek()[id]

    held? =
      case File.read(Path.join(dir, "snapshot")) do
        {:ok, binary} ->
          %{state: %{buffer: buffer}} = :erlang.binary_to_term(binary)
          Enum.any?(Map.values(buffer), &(&1 =~ text))

        _ ->
          true
      end

    cond do
      not held? -> :ok
      tries == 0 -> flunk("the save of #{thread} still holds #{text}")
      true -> Process.sleep(10) && await_saved_past(context, thread, text, tries - 1)
    end
  end

  defp runtime(context, thread) do
    id = World.thread_id(context, thread)

    Enum.find_value(
      [
        HalC2.Codex.Registry,
        HalC2.Claude.Registry,
        HalC2.Acp.Registry,
        HalC2.Pi.Registry,
        HalC2.Muse.Registry
      ],
      fn registry ->
        case Process.whereis(registry) && Registry.lookup(registry, id) do
          [{pid, _}] -> pid
          _ -> nil
        end
      end
    )
  end

  step ~r/^thread "(?<thread>[^"]+)" has a turn on "codex" that streamed a paragraph and paused$/,
       %{args: [thread]} = context do
    context = context |> durable() |> World.fake_providers()
    World.put_os_env("FAKE_CODEX_GATE", HalC2.Test.Mc.tmp_dir(context.mc, "gate"))
    context = World.launch_on(context, thread, "codex", "stream paragraphs")
    run = World.await_running(context, thread)
    context = context |> Map.put(:thread, thread) |> Map.put(:running, run["id"])
    await_checkpoint(context, thread)
    context = Map.put(context, :program, program(context, thread))

    World.await_state(context, thread, fn state ->
      match?(%{"text" => "One.\n\n"}, state.entities["message"]["message:codex:msg-stream"])
    end)

    # The flush wrote it, and the save after that no longer holds it.
    await_saved_past(context, thread, "One.")
    context
  end

  step "{string} shows that paragraph once", %{args: [thread]} = context do
    settled(context, thread)
    message = World.state(context, thread).entities["message"]["message:codex:msg-stream"]
    assert message["text"] == "One.\n\n"
    context
  end

  step "a stop of {string} is out and {string} will not answer it",
       %{args: [thread, provider]} = context do
    Application.put_env(:hal_c2, :codex_interrupt_deadline_ms, 200)
    Application.put_env(:hal_c2, :claude_interrupt_timeout_ms, 200)
    Application.put_env(:hal_c2, :antigravity_cancel_timeout_ms, 200)

    ExUnit.Callbacks.on_exit(fn ->
      for key <-
            ~w(codex_interrupt_deadline_ms claude_interrupt_timeout_ms antigravity_cancel_timeout_ms)a,
          do: Application.delete_env(:hal_c2, key)
    end)

    # The state a stop leaves; the fake is not told, so nothing answers.
    :sys.replace_state(runtime(context, thread), fn state ->
      case provider do
        "codex" -> %{state | interrupting: state.turn.native_turn_id, stopped: true}
        _ -> %{state | interrupted: true}
      end
    end)

    context
  end

  step ~r/^the run of "(?<thread>[^"]+)" ends as (?<status>\w+)$/,
       %{args: [thread, status]} = context do
    await_status(context, thread, status)
    context
  end

  step "a second Antigravity thread starts", context do
    settled(context, context.thread)
    temp = :sys.get_state(runtime(context, context.thread)).temp_dir
    assert is_binary(temp)
    File.mkdir_p!(temp)

    context =
      World.launch_on(context, "t2", "antigravity", @wait, %{"model" => "antigravity-default"})

    World.await_running(context, "t2")
    Map.put(context, :temp_dir, temp)
  end

  step "the runtime directory of {string} is still there", %{args: [_thread]} = context do
    assert File.dir?(context.temp_dir)
    context
  end

  step "the user signs out of Antigravity", context do
    settled(context, context.thread)
    assert runtime(context, context.thread) in HalC2.Acp.Antigravity.sessions("antigravity")
    HalC2.Acp.Antigravity.stop_sessions("antigravity")
    context
  end

  step "the provider process of {string} has stopped", %{args: [_thread]} = context do
    await_dead(context.program)
    context
  end

  step "a queued run waits in {string}", %{args: [thread]} = context do
    World.numbered_run(context, thread, 90, "queued")
  end

  step "a held queued run waits in {string}", %{args: [thread]} = context do
    World.numbered_run(context, thread, 90, "queued", %{"queueHeld" => true})
  end

  step "the queued run of {string} is held", %{args: [thread]} = context do
    assert World.state(context, thread).entities["run"]["run-90"]["queueHeld"] == true
    context
  end

  step "that provider process has been killed", context do
    await_dead(context.program)
    context
  end
end
