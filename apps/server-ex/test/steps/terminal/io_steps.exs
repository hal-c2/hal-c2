defmodule HalC2.Steps.Terminal.Io do
  @moduledoc "Steps for `features/terminal/io.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Terminal.OutputWindow
  alias HalC2.Test.{Mc, WsClient}
  alias HalC2.Test.Mc.{Terminal, World}

  @clients ["default", "second"]

  # Requests whose reply the step waits for go from a client that is not attached
  # ("ctl"), since waiting for a reply skips the frames that arrive before it.

  # --- a running terminal -------------------------------------------------------------

  step "a running terminal", context do
    running(context)
  end

  step "a running terminal at {int} columns and {int} rows", %{args: [cols, rows]} = context do
    running(context, %{"cols" => cols, "rows" => rows})
  end

  step "a running terminal with output", context do
    context = running(context)
    {output, context} = Terminal.run(context, "default", "echo early''-output")
    assert output =~ "early-output"
    context
  end

  step "a running terminal labelled {string}", %{args: [label]} = context do
    context = running(context, %{"env" => %{"PATH" => fake_bin(context)}})
    assert context.snapshot["label"] == label
    context
  end

  # --- keystrokes and output ----------------------------------------------------------

  step "a client writes {string} and a return", %{args: [command]} = context do
    Terminal.write(context, "default", command <> "\n")
  end

  step "every client attached to the terminal receives {string}", %{args: [text]} = context do
    for name <- @clients, reduce: context do
      context ->
        {_, _, context} = Terminal.await_output(context, name, ~r/(^|[\r\n])#{text}\r?\n/)
        context
    end
  end

  step "the shell prints a thousand lines at once", context do
    Terminal.write(context, "default", "seq 1 1000; echo __seq''_done__\n")
  end

  step "attached clients receive the lines in a few batched output events", context do
    {output, events, context} = Terminal.await_output(context, "default", "__seq_done__")
    outputs = Enum.filter(events, &(&1["type"] == "output"))
    # One event per line would be 1,000; output is flushed every few milliseconds.
    assert length(outputs) < 100, "#{length(outputs)} output events"
    Map.put(context, :printed, output)
  end

  step "no output is lost", context do
    [_, lines] = Regex.run(~r/(?:^|[\r\n])(1\r?\n.*?)__seq_done__/s, context.printed)
    assert String.split(lines, ~r/\r?\n/, trim: true) == Enum.map(1..1000, &to_string/1)
    context
  end

  step "a client resizes it to {int} columns and {int} rows", %{args: [cols, rows]} = context do
    World.call!(
      context,
      "terminal.resize",
      Map.merge(session(context), %{"cols" => cols, "rows" => rows})
    )
    |> elem(1)
  end

  step "the running program sees {int} columns and {int} rows", %{args: [cols, rows]} = context do
    {output, context} = Terminal.run(context, "default", "stty size")
    assert output =~ ~r/(^|[\r\n])#{rows} #{cols}\r?\n/
    context
  end

  # --- clear and restart --------------------------------------------------------------

  step "a client clears it", context do
    {nil, context} = World.call!(context, "terminal.clear", session(context), "ctl")
    context
  end

  step "every attached client is told the terminal was cleared", context do
    await_all(context, "cleared")
  end

  step "a client attaching afterwards sees no earlier output", context do
    {snapshot, context} = Terminal.attach!(context, "later", Map.delete(context.terminal, "cwd"))
    refute snapshot["history"] =~ "early-output"
    context
  end

  step "the shell keeps running", context do
    assert Terminal.session(context.terminal)
    {output, context} = Terminal.run(context, "default", "echo $$")
    assert output =~ ~r/(^|[\r\n])#{context.snapshot["pid"]}\r?\n/
    context
  end

  step "a client restarts it", context do
    {snapshot, context} = World.call!(context, "terminal.restart", context.terminal, "ctl")
    Terminal.await_prompt(context.terminal, "")
    Map.merge(context, %{old_pid: context.snapshot["pid"], snapshot: snapshot})
  end

  step "the old shell stops and a new one starts in the same folder", context do
    %{"pid" => pid, "status" => "running"} = context.snapshot
    assert is_integer(pid) and pid != context.old_pid
    Terminal.await_exit(context.old_pid)
    assert File.read_link!("/proc/#{pid}/cwd") == context.terminal["cwd"]
    context
  end

  step "every attached client is told the terminal restarted", context do
    await_all(context, "restarted")
  end

  step "the history starts empty", context do
    refute context.snapshot["history"] =~ "early-output"
    {snapshot, context} = Terminal.attach!(context, "later", Map.delete(context.terminal, "cwd"))
    refute snapshot["history"] =~ "early-output"
    context
  end

  # Clients send keystrokes and a clear back to back; the write is acknowledged once
  # the shell has the keystrokes, and the clear follows without waiting for output.
  step "a client writes a command and immediately clears the terminal", context do
    marker = Terminal.folder(context, "/work/app/ran-before-clear")
    write = Map.put(session(context), "data", "touch #{marker}\n")
    {nil, context} = World.call!(context, "terminal.write", write, "ctl")
    {nil, context} = World.call!(context, "terminal.clear", session(context), "ctl")
    Map.put(context, :marker, marker)
  end

  step "the command runs before the history is cleared", context do
    context = await_all(context, "cleared")
    # The shell reads its input in order, so it has run the command once it answers.
    {_, context} = Terminal.run(context, "default", "true")
    assert File.exists?(context.marker)
    context
  end

  # --- exit ---------------------------------------------------------------------------

  step ~r/^the shell (?<how>exits with code \d+|is killed with SIGKILL)$/,
       %{args: [how]} = context do
    ending =
      case how do
        "is killed with SIGKILL" -> "kill -9 $$"
        "exits with code " <> code -> "exit #{code}"
      end

    Terminal.write(context, "default", "echo last''-words; #{ending}\n")
  end

  step ~r/^attached clients are told the terminal exited with (?<kind>exit code|signal) (?<n>\d+)$/,
       %{args: [kind, n]} = context do
    n = String.to_integer(n)

    expected =
      if kind == "signal",
        do: %{"exitCode" => nil, "exitSignal" => n},
        else: %{"exitCode" => n, "exitSignal" => nil}

    for name <- @clients, reduce: context do
      context ->
        {event, context} = Terminal.await_event(context, name, &(&1["type"] == "exited"))
        assert Map.take(event, ["exitCode", "exitSignal"]) == expected
        context
    end
  end

  step "the terminal's output is still readable", context do
    {snapshot, context} = Terminal.attach!(context, "later", Map.delete(context.terminal, "cwd"))
    assert snapshot["status"] == "exited"
    assert snapshot["history"] =~ ~r/(^|[\r\n])last-words\r?\n/
    context
  end

  # --- what a terminal is running -----------------------------------------------------

  step "the user starts {string} in it", %{args: [command]} = context do
    Terminal.write(context, "default", command <> "\n")
  end

  step "within a second the terminal is marked as running a command", context do
    # The MC looks at the shell's children once a second (`HalC2.Terminal.Hub`), by a `ps`
    # a loaded machine can keep waiting: the event is the receipt, and the default limit
    # only says how long a missing one takes to fail.
    {event, context} = Terminal.await_event(context, "default", &(&1["type"] == "activity"))

    assert event["hasRunningSubprocess"] == true
    Map.put(context, :activity, event)
  end

  step "its label becomes {string}", %{args: [label]} = context do
    assert context.activity["label"] == label
    assert_hub_label(context, label)
  end

  step "a terminal labelled {string} while a dev server runs", %{args: [label]} = context do
    context = running(context, %{"env" => %{"PATH" => fake_bin(context)}})
    context = Terminal.write(context, "default", "npm run dev\n")
    {event, context} = Terminal.await_event(context, "default", &(&1["type"] == "activity"))

    assert %{"hasRunningSubprocess" => true, "label" => ^label} = event
    context
  end

  step "the dev server stops", context do
    # Ctrl-C.
    Terminal.write(context, "default", "\x03")
  end

  step "the terminal is no longer marked as running a command", context do
    {event, context} = Terminal.await_event(context, "default", &(&1["type"] == "activity"))

    assert event["hasRunningSubprocess"] == false
    Map.put(context, :activity, event)
  end

  step "its label returns to {string}", %{args: [label]} = context do
    assert context.activity["label"] == label
    assert_hub_label(context, label)
  end

  # --- helpers ------------------------------------------------------------------------

  # Opens the scenario's terminal and attaches two clients.
  defp running(context, overrides \\ %{}) do
    {snapshot, context} = Terminal.open!(context, overrides)
    input = Map.delete(context.terminal, "cwd")

    context =
      Enum.reduce(@clients, context, fn name, context ->
        {_, context} = Terminal.attach!(context, name, input)
        context
      end)

    Map.put(context, :snapshot, snapshot)
  end

  defp session(context), do: Map.take(context.terminal, ["threadId", "terminalId"])

  defp await_all(context, type) do
    Enum.reduce(@clients, context, fn name, context ->
      {_, context} = Terminal.await_event(context, name, &(&1["type"] == type))
      context
    end)
  end

  # A PATH whose `npm` is a stand-in dev server: one process, waiting on the terminal until
  # interrupted, so Ctrl-C has no child starting up to miss.
  defp fake_bin(context) do
    bin = Terminal.mkdir(context, "/fake-bin")
    npm = Path.join(bin, "npm")
    File.write!(npm, "#!/bin/sh\nread _\n")
    File.chmod!(npm, 0o755)
    bin <> ":" <> System.get_env("PATH", "/usr/bin:/bin")
  end

  defp assert_hub_label(context, label) do
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal

    assert Enum.any?(
             HalC2.Terminal.Hub.summaries(),
             &match?(%{"threadId" => ^thread, "terminalId" => ^terminal, "label" => ^label}, &1)
           )

    context
  end

  # --- a client that falls behind -------------------------------------------------------------

  # The "default" client keeps up, and so says how much the shell has printed.
  step "a running terminal whose shell prints continuously", context do
    {snapshot, context} = Terminal.open!(context)
    {_, context} = Terminal.attach!(context, "default", Map.delete(context.terminal, "cwd"))
    context = Terminal.write(context, "default", "while :; do seq 1 2000; sleep 0.05; done\n")
    Map.put(context, :snapshot, snapshot)
  end

  step "a client stops acknowledging the output it has received", context do
    id = System.unique_integer([:positive])

    shape = %{
      "type" => "terminal",
      "mc" => Atom.to_string(node()),
      "input" => Map.take(context.terminal, ["threadId", "terminalId"])
    }

    client =
      WsClient.send_json(World.client(context, "behind"), %{
        "t" => "sub",
        "id" => id,
        "shape" => shape,
        "acks" => true
      })

    context |> World.put_client("behind", client) |> Map.put(:behind_sub, id)
  end

  step "only a small amount of output waits unacknowledged for that client", context do
    limit = OutputWindow.limit()
    {_, _, context} = await_printed(context, 3 * limit)
    {events, context} = behind_events(context)

    sizes = for %{"type" => "output", "data" => data} <- events, do: byte_size(data)

    assert sizes != []
    # It was let through until the limit, the event that crossed it included.
    assert Enum.sum(sizes) - List.last(sizes) < limit
    Map.put(context, :behind_acked, Enum.max(Enum.map(events, &sequence/1)))
  end

  step "the MC stops sending output to that client until it catches up", context do
    {_, _, context} = await_printed(context, 2 * OutputWindow.limit())
    {events, context} = behind_events(context)
    assert Enum.filter(events, &(&1["type"] == "output")) == []

    id = context.behind_sub
    send_ack = &WsClient.send_json(&1, %{"t" => "ack", "id" => id, "sequence" => &2})
    client = send_ack.(World.client(context, "behind"), context.behind_acked)
    {caught_up, client} = await_behind(client, id)
    assert %{"type" => "snapshot", "snapshot" => %{"status" => "running"}} = caught_up
    assert sequence(caught_up) > context.behind_acked
    World.put_client(context, "behind", catch_up(client, id, caught_up, send_ack))
  end

  step "the shell itself keeps running", context do
    assert File.exists?("/proc/#{context.snapshot["pid"]}")
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal

    assert Enum.any?(
             HalC2.Terminal.Hub.summaries(),
             &match?(
               %{"threadId" => ^thread, "terminalId" => ^terminal, "status" => "running"},
               &1
             )
           )

    context
  end

  # --- stopping a shell -----------------------------------------------------------------------

  step "a running terminal whose shell ignores the stop request", context do
    context = context |> Terminal.ensure() |> stubborn_shell()
    {snapshot, context} = Terminal.open!(context)
    {_, context} = Terminal.attach!(context, "default", Map.delete(context.terminal, "cwd"))
    {_, _, context} = await_ready(context, snapshot)
    Map.put(context, :snapshot, snapshot)
  end

  step "a client closes it", context do
    started = System.monotonic_time(:millisecond)

    {{:ok, nil}, context} =
      World.call(
        context,
        "terminal.close",
        Map.take(context.terminal, ["threadId", "terminalId"]),
        "ctl"
      )

    Map.put(context, :stop_took, System.monotonic_time(:millisecond) - started)
  end

  step "the shell is asked to stop first", context do
    {_, _, context} = Terminal.await_output(context, "default", "asked-to-stop")
    context
  end

  step "the shell is killed if it is still running a second later", context do
    Terminal.await_exit(context.snapshot["pid"])
    assert context.stop_took >= 900
    assert context.stop_took < HalC2.Terminal.call_timeout()
    context
  end

  step "running terminals, one of whose shells ignores the stop request", context do
    {obliging, context} = Terminal.open!(context, %{"terminalId" => "term-1"})
    context = stubborn_shell(context)
    {stubborn, context} = Terminal.open!(context, %{"terminalId" => "term-2"})
    {_, context} = Terminal.attach!(context, "default", Map.delete(context.terminal, "cwd"))
    {_, _, context} = await_ready(context, stubborn)
    Map.merge(context, %{obliging: obliging, snapshot: stubborn})
  end

  step "the MC shuts down", context do
    started = System.monotonic_time(:millisecond)
    :ok = DynamicSupervisor.stop(HalC2.Terminal.Supervisor, :shutdown)
    Map.put(context, :stop_took, System.monotonic_time(:millisecond) - started)
  end

  step "each shell is asked to stop", context do
    Terminal.await_exit(context.obliging["pid"])
    {_, _, context} = Terminal.await_output(context, "default", "asked-to-stop")
    context
  end

  step "the shell that ignores it is killed after the grace period", context do
    Terminal.await_exit(context.snapshot["pid"])
    assert context.stop_took >= 900
    context
  end

  step "the MC does not wait for them longer than that", context do
    # The supervisor would give up on a terminal at 5 seconds.
    assert context.stop_took < 4_000
    context
  end

  # --- no process list ------------------------------------------------------------------------

  # The hub's poll results are the receipt that it looked and found nothing. `npm` is a
  # function here, so a real child runs that a working process list would see.
  step "the MC cannot read the list of processes on its machine", context do
    Application.put_env(:hal_c2, :terminal_ps, Terminal.folder(context, "/no/ps"))
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :terminal_ps) end)
    {_, context} = Terminal.run(context, "default", "npm() { sleep 30; }")
    :erlang.trace(Process.whereis(HalC2.Terminal.Hub), true, [:receive])
    context
  end

  step "the terminal keeps accepting input and showing output", context do
    hub = Process.whereis(HalC2.Terminal.Hub)
    # The second started after the child did.
    for _ <- 1..2, do: assert_receive({:trace, ^hub, :receive, {:processes, _}}, 5_000)
    :erlang.trace(hub, false, [:receive])
    context = Terminal.write(context, "default", "\x03")
    {output, context} = Terminal.run(context, "default", "echo still-''working")
    assert output =~ "still-working"
    context
  end

  step "the terminal is not marked as running a command", context do
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal

    assert %{"hasRunningSubprocess" => false} =
             Enum.find(
               HalC2.Terminal.Hub.summaries(),
               &match?(%{"threadId" => ^thread, "terminalId" => ^terminal}, &1)
             )

    context
  end

  defp await_printed(context, bytes),
    do: Terminal.await_output(context, "default", &(byte_size(&1) >= bytes), 15_000)

  # What the client that fell behind was sent: the pong to a ping comes after all of it.
  defp behind_events(context) do
    id = context.behind_sub
    client = WsClient.send_json(World.client(context, "behind"), %{"t" => "ping"})
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"), 5_000)
    events = for %{"t" => "terminal", "id" => ^id, "event" => event} <- frames, do: event
    {events, World.put_client(context, "behind", client)}
  end

  defp await_behind(client, id) do
    {%{"event" => event}, client} =
      Mc.await(
        client,
        &(&1["t"] == "terminal" and &1["id"] == id and
            &1["event"]["type"] in ~w(output snapshot)),
        5_000
      )

    {event, client}
  end

  # What a client does: it acknowledges what it handled, a snapshot too, until live
  # output reaches it again.
  defp catch_up(client, id, %{"type" => "output"}, _send_ack) when is_integer(id), do: client

  defp catch_up(client, id, event, send_ack) do
    client = send_ack.(client, sequence(event))
    {event, client} = await_behind(client, id)
    catch_up(client, id, event, send_ack)
  end

  defp sequence(%{"snapshot" => %{"sequence" => sequence}}), do: sequence
  defp sequence(%{"sequence" => sequence}), do: sequence

  defp stubborn_shell(context) do
    path = Path.join(context.mc.home, "stubborn-shell")

    File.write!(path, """
    #!/bin/sh
    trap 'echo asked-to-stop' TERM
    echo ready
    while :; do sleep 0.1; done
    """)

    File.chmod!(path, 0o755)
    Terminal.put_env("SHELL", path)
    context
  end

  defp await_ready(context, snapshot) do
    if snapshot["history"] =~ "ready" do
      {"", [], context}
    else
      {again, context} =
        Terminal.attach!(context, "ready", Map.take(context.terminal, ["threadId", "terminalId"]))

      if again["history"] =~ "ready",
        do: {"", [], context},
        else: Terminal.await_output(context, "default", "ready")
    end
  end
end
