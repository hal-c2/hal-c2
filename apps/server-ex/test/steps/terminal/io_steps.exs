defmodule T3.Steps.Terminal.Io do
  @moduledoc "Steps for `features/terminal/io.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.{Terminal, World}

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
        {_, _, context} = Terminal.await_output(context, name, ~r/(^|\n)#{text}\r?\n/)
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
    [_, lines] = Regex.run(~r/(?:^|\n)(1\r?\n.*?)__seq_done__/s, context.printed)
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
    assert output =~ ~r/(^|\n)#{rows} #{cols}\r?\n/
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
    assert output =~ ~r/(^|\n)#{context.snapshot["pid"]}\r?\n/
    context
  end

  step "a client restarts it", context do
    {snapshot, context} = World.call!(context, "terminal.restart", context.terminal, "ctl")
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
    # The shell reads its input in order, so this runs after the command did.
    {output, context} = Terminal.run(context, "default", "test -f #{context.marker} && echo ran")
    assert output =~ ~r/(^|\n)ran\r?\n/
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
    assert snapshot["history"] =~ ~r/(^|\n)last-words\r?\n/
    context
  end

  # --- what a terminal is running -----------------------------------------------------

  step "the user starts {string} in it", %{args: [command]} = context do
    Terminal.write(context, "default", command <> "\n")
  end

  step "within a second the terminal is marked as running a command", context do
    # The node looks at the shell's children once a second.
    {event, context} =
      Terminal.await_event(context, "default", &(&1["type"] == "activity"), 2_500)

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

    {event, context} =
      Terminal.await_event(context, "default", &(&1["type"] == "activity"), 2_500)

    assert %{"hasRunningSubprocess" => true, "label" => ^label} = event
    context
  end

  step "the dev server stops", context do
    # Ctrl-C.
    Terminal.write(context, "default", "\x03")
  end

  step "the terminal is no longer marked as running a command", context do
    {event, context} =
      Terminal.await_event(context, "default", &(&1["type"] == "activity"), 2_500)

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

  # A PATH whose `npm` is a stand-in dev server: it runs until interrupted.
  defp fake_bin(context) do
    bin = Terminal.mkdir(context, "/fake-bin")
    npm = Path.join(bin, "npm")
    File.write!(npm, "#!/bin/sh\nsleep 30\n")
    File.chmod!(npm, 0o755)
    bin <> ":" <> System.get_env("PATH", "/usr/bin:/bin")
  end

  defp assert_hub_label(context, label) do
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal

    assert Enum.any?(
             T3.Terminal.Hub.summaries(),
             &match?(%{"threadId" => ^thread, "terminalId" => ^terminal, "label" => ^label}, &1)
           )

    context
  end
end
