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
      Application.delete_env(:hal_c2, :durable_programs)
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
      GenServer.stop(pid, :shutdown)
    end

    context
  end

  # After what an earlier MC's leaving could still do: a stop of its connection reaching
  # the adopted program takes up to a second, and a check before that proves nothing.
  step "the provider process of {string} is the one that was running",
       %{args: [thread]} = context do
    Process.sleep(1_000)
    assert program(context, thread) == context.program
    assert alive?(context.program)
    context
  end

  step "the run of {string} is still running", %{args: [thread]} = context do
    assert status(context, thread) == "running"
    context
  end

  step "the user stops {string} after the restart", %{args: [thread]} = context do
    Process.sleep(1_000)
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
    Process.sleep(1_000)
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
    Process.sleep(1_000)
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
    Process.sleep(1_000)
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

  step "that provider process has been killed", context do
    await_dead(context.program)
    context
  end
end
