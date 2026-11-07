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
  @approve "approve this"

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

    ask = %{
      "match" => @approve,
      "steps" => [
        %{"tool" => "bash", "args" => %{"command" => "ls"}, "output" => "a.txt"},
        %{"text" => "Ran it."}
      ]
    }

    FakeAcp.install_pi(context, %{}, enabled: true, turns: [wait, ask | FakeAcp.pi_turns()])
  end

  defp install(context, "muse") do
    wait = %{"match" => @wait, "steps" => [%{"waitInterrupt" => true}]}
    ask = %{"match" => @approve, "steps" => [%{"shell" => "ls"}, %{"text" => "Ran it."}]}
    FakeAcp.install_muse(context, %{}, enabled: true, turns: [wait, ask])
  end

  defp install(context, "antigravity") do
    context =
      FakeAcp.install(
        context,
        "antigravity",
        %{
          "googleAuth" => true,
          "turns" => [
            %{"match" => @wait, "steps" => [%{"waitCancel" => true}]},
            %{
              "match" => @approve,
              "steps" => [
                %{
                  "permission" => %{
                    "toolCallId" => "cmd-1",
                    "title" => "ls",
                    "kind" => "execute",
                    "rawInput" => %{"command" => "ls"}
                  }
                },
                %{"text" => "Ran it."}
              ]
            }
            | FakeAcp.turns()
          ]
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

    context =
      context
      |> Map.put(:thread, thread)
      |> Map.put(:provider, provider)
      |> Map.put(:running, run["id"])
      |> Map.put(:cut_off, run["id"])

    await_checkpoint(context, thread, text == @wait)
    if text == @wait and provider == "claudeAgent", do: await_session(context, thread)
    Map.put(context, :program, program(context, thread))
  end

  # Claude names its session as the turn begins, which is what a cut-off turn resumes on.
  defp await_session(context, thread) do
    World.await_state(context, thread, fn state ->
      Enum.any?(
        Map.values(state.entities["provider-thread"] || %{}),
        &is_map(&1["nativeThreadRef"])
      )
    end)
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
  step(~r/^the MC (?:dies|shuts down)$/, context, do: stop_mc(context))

  defp stop_mc(context) do
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
      World.launch_on(context, thread, instance(provider), @approve, %{
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

  step "no program of {string} is left running", %{args: [thread]} = context do
    await_no_programs(context, thread)
    if context[:program], do: await_dead(context.program)
    context
  end

  defp await_no_programs(context, thread, tries \\ 500) do
    cond do
      programs(context, thread) == [] -> :ok
      tries == 0 -> flunk("#{thread} still has a program")
      true -> Process.sleep(10) && await_no_programs(context, thread, tries - 1)
    end
  end

  defp meta(context) do
    %{dir: dir} = Durable.survivors_peek()[World.thread_id(context, context.thread)]
    {Path.join(dir, "meta"), JSON.decode!(File.read!(Path.join(dir, "meta")))}
  end

  defp snapshot_path(context) do
    %{dir: dir} = Durable.survivors_peek()[World.thread_id(context, context.thread)]
    Path.join(dir, "snapshot")
  end

  # Why a program cannot be reattached, done to it while no MC is there.
  step ~r/^the program's pipes are gone$/, context do
    %{dir: dir} = Durable.survivors_peek()[World.thread_id(context, context.thread)]
    File.rm!(Path.join(dir, "in"))
    context
  end

  step ~r/^the program does not answer on reattaching$/, context do
    Application.put_env(:hal_c2, :claude_reattach_timeout_ms, 300)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :claude_reattach_timeout_ms)
    end)

    {_path, %{"group" => group}} = meta(context)
    # Stopped, it still holds its pipes and its pid; it only answers nothing.
    System.cmd("kill", ["-STOP", "--", "-#{group}"])
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", ["-KILL", "--", "-#{group}"]) end)
    context
  end

  step ~r/^the new MC cannot read the program's format$/, context do
    path = snapshot_path(context)
    snapshot = :erlang.binary_to_term(File.read!(path))
    File.write!(path, :erlang.term_to_binary(%{snapshot | format: snapshot.format + 1}))
    context
  end

  # A stand-in for the stranger: the program's whole group goes (no MC is there to hear
  # it), and its record names a process started later under the pid it had.
  step "the program ends and another program takes its pid", context do
    {path, %{"group" => group} = meta} = meta(context)
    System.cmd("kill", ["-KILL", "--", "-#{group}"])
    await_dead(context.program)

    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["600"]])

    {:os_pid, other} = Port.info(port, :os_pid)
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", ["-KILL", "#{other}"]) end)
    File.write!(path, JSON.encode!(%{meta | "pid" => other, "group" => other}))
    Map.put(context, :other, other)
  end

  step "the other program is still running", context do
    assert alive?(context.other)
    context
  end

  # Codex leaves a dev server in a unified exec terminal; Claude a build and a subagent;
  # Grok a shell task and a subagent.
  # The turn ended, so nothing was cut off: only the background work could be.
  step "thread {string} left a command running in the background on {string}",
       %{args: [thread, provider]} = context do
    text =
      if provider == "codex",
        do: "Start the dev server in the background",
        else: "Work in the background"

    context = turn_on(context, thread, provider, text)

    row =
      World.await_row(
        World.thread_id(context, thread),
        &Enum.any?(&1["pendingBackgroundTasks"] || [], fn task ->
          task["taskType"] not in ~w(local_agent subagent)
        end)
      )

    command =
      Enum.find(row["pendingBackgroundTasks"], &(&1["taskType"] not in ~w(local_agent subagent)))

    context
    |> Map.delete(:cut_off)
    |> Map.put(:background, command["taskId"])
  end

  step "thread {string} left a Claude subagent running in the background",
       %{args: [thread]} = context do
    context = turn_on(context, thread, "claudeAgent", "Work in the background")

    row =
      World.await_row(
        World.thread_id(context, thread),
        &Enum.any?(&1["pendingBackgroundTasks"] || [], fn t ->
          t["taskType"] in ~w(local_agent subagent)
        end)
      )

    task = Enum.find(row["pendingBackgroundTasks"], &(&1["taskType"] in ~w(local_agent subagent)))

    context
    |> Map.delete(:cut_off)
    |> Map.put(:background, task["taskId"])
  end

  step "{string} lists the subagent as background work", %{args: [thread]} = context do
    task = context.background

    World.await_row(
      World.thread_id(context, thread),
      &Enum.any?(&1["pendingBackgroundTasks"] || [], fn t -> t["taskId"] == task end)
    )

    context
  end

  # Claude says it on its output, which the reattached MC reads.
  step "Claude reports the subagent completed with {string}", %{args: [summary]} = context do
    settled(context, context.thread)
    # The fake Claude names a task after its tool call: task-agent-1 for agent-1.
    tool = String.replace_prefix(context.background, "task-", "")

    notification = %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-" <> tool,
      "tool_use_id" => tool,
      "status" => "completed",
      "summary" => summary
    }

    write_out(context, JSON.encode!(notification) <> "\n")

    World.await_state(context, context.thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "subagent"), &(&1["status"] == "completed"))
    end)

    context
  end

  step "the command is still running", context do
    settled(context, context.thread)
    assert program(context, context.thread) == context.program
    assert alive?(context.program)

    assert Enum.any?(
             World.entities(context, context.thread, "turn-item"),
             &(&1["type"] == "command_execution" and &1["status"] in ~w(pending running))
           )

    context
  end

  step "{string} lists the command as background work", %{args: [thread]} = context do
    task = context.background

    World.await_row(
      World.thread_id(context, thread),
      &Enum.any?(&1["pendingBackgroundTasks"] || [], fn t -> t["taskId"] == task end)
    )

    context
  end

  # The provider's output is the program's `out` file, so the test writes there as the
  # provider would: one update and half the next while the MC reads, the rest after it went.
  step "the MC dies partway through reading a line from the provider", context do
    {prelude, [first, second | rest]} = updates(context)
    {head, tail} = String.split_at(second, div(String.length(second), 2))
    write_out(context, Enum.map_join(prelude ++ [first], &(&1 <> "\n")) <> head)
    await_said(context, "u0.")
    context |> stop_mc() |> Map.put(:later, [tail | rest])
  end

  step "the provider writes three more updates", context do
    write_out(context, Enum.map_join(context.later, &(&1 <> "\n")))
    context
  end

  step "{string} shows every update once, in the order the provider wrote them",
       %{args: [thread]} = context do
    settled(context, thread)
    said = await_said(context, "u3.")
    assert said =~ "u0.\n\nu1.\n\nu2.\n\nu3."
    for n <- 0..3, do: assert(length(String.split(said, "u#{n}.")) == 2, said)
    context
  end

  defp write_out(context, text) do
    %{dir: dir} = Durable.survivors_peek()[World.thread_id(context, context.thread)]
    File.write!(Path.join(dir, "out"), text, [:append])
  end

  # What the agent said in the run, its messages in the order they were made.
  defp await_said(context, text) do
    said = fn state ->
      for %{"role" => "assistant", "runId" => run, "text" => said} <-
            HalC2.StreamState.list(state, "message"),
          run == context.running,
          into: "",
          do: said
    end

    state = World.await_state(context, context.thread, &(said.(&1) =~ text), 10_000)
    said.(state)
  end

  # Lines the provider writes before its updates, then four text updates, "u0." to "u3.",
  # in its own protocol on the turn it is running. Each ends a paragraph, which the MC
  # writes to the thread as it comes rather than holding it in its buffer.
  defp updates(context) do
    lines = out_lines(context)
    texts = for n <- 0..3, do: "u#{n}.\n\n"
    encode = &Enum.map(&1, fn line -> JSON.encode!(line) end)

    {prelude, updates} =
      case context.provider do
        "codex" ->
          %{"params" => %{"threadId" => thread, "turn" => %{"id" => turn}}} =
            List.last(for %{"method" => "turn/started"} = line <- lines, do: line)

          ctx = %{"threadId" => thread, "turnId" => turn}

          {[
             %{
               "method" => "item/started",
               "params" =>
                 Map.put(ctx, "item", %{
                   "type" => "agentMessage",
                   "id" => "msg-down",
                   "text" => ""
                 })
             }
           ],
           for text <- texts do
             %{
               "method" => "item/agentMessage/delta",
               "params" => Map.merge(ctx, %{"itemId" => "msg-down", "delta" => text})
             }
           end}

        "claudeAgent" ->
          session = Enum.find_value(lines, & &1["session_id"])

          {[],
           for {text, n} <- Enum.with_index(texts) do
             %{
               "type" => "assistant",
               "session_id" => session,
               "message" => %{
                 "id" => "m-down-#{n}",
                 "role" => "assistant",
                 "content" => [%{"type" => "text", "text" => text}]
               }
             }
           end}

        "pi" ->
          {[%{"type" => "message_start", "message" => %{"role" => "assistant"}}],
           for text <- texts do
             %{
               "type" => "message_update",
               "assistantMessageEvent" => %{"type" => "text_delta", "delta" => text}
             }
           end}

        "muse" ->
          %{"params" => %{"sessionId" => session, "turnId" => turn}} =
            List.last(for %{"method" => "turn/started"} = line <- lines, do: line)

          item = %{
            "itemId" => "item-down",
            "turnId" => turn,
            "kind" => "agentMessage",
            "status" => "inProgress",
            "revision" => 1,
            "text" => ""
          }

          {[%{"method" => "item/started", "params" => %{"sessionId" => session, "item" => item}}],
           for text <- texts do
             %{
               "method" => "item/delta",
               "params" => %{
                 "sessionId" => session,
                 "itemId" => "item-down",
                 "field" => "text",
                 "delta" => text
               }
             }
           end}

        _acp ->
          session = Enum.find_value(lines, &get_in(&1, ["result", "sessionId"]))

          {[],
           for text <- texts do
             %{
               "method" => "session/update",
               "params" => %{
                 "sessionId" => session,
                 "update" => %{
                   "sessionUpdate" => "agent_message_chunk",
                   "content" => %{"type" => "text", "text" => text}
                 }
               }
             }
           end}
      end

    jsonrpc? = context.provider not in ~w(claudeAgent pi)

    rpc =
      &if(jsonrpc?, do: Enum.map(&1, fn line -> Map.put(line, "jsonrpc", "2.0") end), else: &1)

    {encode.(rpc.(prelude)), encode.(rpc.(updates))}
  end

  defp out_lines(context) do
    %{dir: dir} = Durable.survivors_peek()[World.thread_id(context, context.thread)]

    for line <- String.split(File.read!(Path.join(dir, "out")), "\n"),
        {:ok, %{} = json} <- [JSON.decode(line)],
        do: json
  end

  # As `<mc> uninstall` does it, on a service manager that only records what it is told.
  step "the user stops the MC without restarting it", context do
    context = context |> stop_mc() |> service_manager()
    assert {:ok, _} = HalC2.Service.command(["uninstall"])
    context
  end

  step "the MC runs as a service", context do
    context = service_manager(context)
    assert {:ok, _} = HalC2.Service.command(["install"])
    context
  end

  # The manager as the installed unit tells it: one that stops a unit's every process
  # (systemd's default, KillMode=control-group, or mixed) takes the program down too.
  step "the service restarts", context do
    [unit] = Path.wildcard(Path.join(context.service_home, "**/*.service"), match_dot: true)
    kill_mode = Regex.run(~r/^KillMode=(\S+)/m, File.read!(unit), capture: :all_but_first)

    if kill_mode != ["process"] do
      {_path, %{"group" => group}} = meta(context)
      System.cmd("kill", ["-TERM", "--", "-#{group}"])
    end

    context = stop_mc(context)
    %{context | mc: HalC2.Test.Mc.restart(context.mc), clients: %{}}
  end

  # A systemd user manager that only records what it is told (HalC2.Test.Storage).
  defp service_manager(context) do
    bin = HalC2.Test.Mc.tmp_dir(context.mc, "service-bin")
    home = HalC2.Test.Mc.tmp_dir(context.mc, "service-home")
    File.mkdir_p!(bin)
    HalC2.Test.Storage.fake_service_manager(bin)

    env = [
      service_platform: {:unix, :linux},
      service_user_home: home,
      systemctl_command: Path.join(bin, "systemctl"),
      loginctl_command: Path.join(bin, "loginctl")
    ]

    for {key, value} <- env, do: Application.put_env(:hal_c2, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      for {key, _} <- env, do: Application.delete_env(:hal_c2, key)
    end)

    Map.put(context, :service_home, home)
  end
end
