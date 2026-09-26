defmodule HalC2.Steps.Terminal.Reconnect do
  @moduledoc "Steps for `features/terminal/reconnect.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.{Terminal, World}

  # --- attaching replays history, then streams --------------------------------------

  step "a running terminal that has printed {string}", %{args: [text]} = context do
    context |> attached(["default"]) |> print("default", text)
  end

  step "a second client attaches to it", context do
    {snapshot, context} = Terminal.attach!(context, "second", attach_input(context))
    Map.put(context, :snapshot, snapshot)
  end

  step "the second client first receives a snapshot containing {string}",
       %{args: [text]} = context do
    assert context.snapshot["history"] =~ line(text)
    context
  end

  step "then receives new output as it happens", context do
    context = Terminal.write(context, "default", "echo n''ew-output\n")
    {_, _, context} = Terminal.await_output(context, "second", line("new-output"))
    context
  end

  step "two clients attached to the same terminal", context do
    attached(context, ["default", "second"])
  end

  step "one client runs {string}", %{args: [command]} = context do
    context = Terminal.write(context, "default", "#{command}; echo __ran''__\n")
    {output, _, context} = Terminal.await_output(context, "default", "__ran__")
    Map.put(context, :ran, output)
  end

  step "both clients receive the date", context do
    year = Integer.to_string(Date.utc_today().year)
    [date] = Regex.run(~r/[^\r\n]*\d\d:\d\d:\d\d[^\r\n]*/, context.ran)
    assert date =~ year
    {output, _, context} = Terminal.await_output(context, "second", "__ran__")
    assert output =~ date
    context
  end

  step "the thread has no terminal {string}", %{args: [terminal]} = context do
    context = Terminal.ensure(context)
    input = Terminal.input(context, %{"terminalId" => terminal})
    assert Registry.lookup(HalC2.Terminal.Registry, {input["threadId"], terminal}) == []
    context
  end

  step "a client attaches to {string} in {string}", %{args: [terminal, path]} = context do
    input =
      Terminal.input(context, %{"terminalId" => terminal, "cwd" => Terminal.mkdir(context, path)})

    {frame, context} = Terminal.attach(context, "default", input)
    context |> Terminal.put_input(input) |> Map.merge(%{frame: frame, snapshot: snapshot(frame)})
  end

  step "the client receives its snapshot", context do
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal

    assert %{"t" => "terminal", "event" => %{"type" => "snapshot"}} = context.frame

    assert %{"threadId" => ^thread, "terminalId" => ^terminal, "status" => "running"} =
             context.snapshot

    context
  end

  step "a client attaches asking to restart it if it is not running", context do
    input = Map.put(context.terminal, "restartIfNotRunning", true)
    {snapshot, context} = Terminal.attach!(context, "later", input)
    Map.put(context, :snapshot, snapshot)
  end

  step "a new shell starts", context do
    assert %{"status" => "running", "pid" => pid, "exitCode" => nil} = context.snapshot
    assert File.read_link!("/proc/#{pid}/cwd") == context.terminal["cwd"]
    context
  end

  step "the client is told the terminal restarted", context do
    # The snapshot is the new shell's: the old one's output is gone.
    refute context.snapshot["history"] =~ line("done")
    {output, context} = Terminal.run(context, "later", "echo $$")
    assert output =~ line(Integer.to_string(context.snapshot["pid"]))
    context
  end

  step "a terminal whose shell has exited after printing {string}", %{args: [text]} = context do
    Terminal.exited(context, text)
  end

  step "a client attaches without asking for a restart", context do
    {snapshot, context} = Terminal.attach!(context, "later", context.terminal)
    Map.put(context, :snapshot, snapshot)
  end

  step "the client receives the history containing {string}", %{args: [text]} = context do
    assert context.snapshot["history"] =~ line(text)
    context
  end

  step "the terminal is reported as exited", context do
    assert %{"status" => "exited", "exitCode" => 0, "pid" => nil} = context.snapshot
    context
  end

  step "a client attached to a running terminal", context do
    attached(context, ["default", "viewer"])
  end

  step "the client disconnects", context do
    client = World.client(context, "viewer")
    Mint.HTTP.close(client.conn)

    context
    |> Map.update!(:clients, &Map.delete(&1, "viewer"))
    |> Map.update!(:terminal_subs, &Map.delete(&1, "viewer"))
  end

  step "its output keeps being recorded", context do
    {_, context} = Terminal.run(context, "default", "echo s''till-here")
    {snapshot, context} = Terminal.attach!(context, "later", attach_input(context))
    assert snapshot["history"] =~ line("still-here")
    context
  end

  # --- history on disk and its limits -----------------------------------------------

  step "a terminal that has printed {string}", %{args: [text]} = context do
    context |> attached(["default"]) |> print("default", text)
  end

  step "a client closes the terminal without deleting its history", context do
    {nil, context} = World.call!(context, "terminal.close", session(context), "ctl")
    refute_running(context.terminal)
    context
  end

  step "later opens the same terminal again", context do
    {:ok, saved} = File.read(Terminal.history_file(context, context.terminal))
    {_, context} = Terminal.open!(context, %{}, "ctl")
    {snapshot, context} = Terminal.attach!(context, "later", attach_input(context))
    Map.merge(context, %{saved: saved, snapshot: snapshot})
  end

  step "the new shell's history begins with {string}", %{args: [text]} = context do
    assert context.saved =~ line(text)
    assert String.starts_with?(context.snapshot["history"], context.saved)
    context
  end

  step "a client closes the terminal and deletes its history", context do
    input = Map.put(session(context), "deleteHistory", true)
    {nil, context} = World.call!(context, "terminal.close", input, "ctl")
    refute_running(context.terminal)
    context
  end

  step "no saved output remains for that terminal", context do
    refute File.exists?(Terminal.history_file(context, context.terminal))
    # Opening it again starts from nothing.
    {snapshot, _context} = Terminal.open!(context, %{}, "ctl")
    refute snapshot["history"] =~ "secret token"
    context
  end

  step "a thread with terminals 1, 2 and 3", context do
    {pids, context} =
      Enum.map_reduce(1..3, context, fn n, context ->
        {snapshot, context} = Terminal.open!(context, %{"terminalId" => "term-#{n}"}, "ctl")
        {snapshot["pid"], context}
      end)

    Map.put(context, :shell_pids, pids)
  end

  step "a client closes the thread's terminals without naming one", context do
    {nil, context} =
      World.call!(context, "terminal.close", %{"threadId" => context.terminal["threadId"]}, "ctl")

    context
  end

  step "all three shells stop", context do
    Enum.each(context.shell_pids, &Terminal.await_exit/1)

    for n <- 1..3,
        do:
          refute_running(%{
            "threadId" => context.terminal["threadId"],
            "terminalId" => "term-#{n}"
          })

    context
  end

  step "a terminal that keeps printing output", context do
    context = attached(context, ["default"])
    Terminal.write(context, "default", "for i in $(seq 1 50); do echo tick-$i; done\n")
  end

  step "the output stops for half a second", context do
    {_, _, context} = Terminal.await_output(context, "default", line("tick-50"))
    context
  end

  step "the history is written to the node's terminal store", context do
    # The node saves at most every 500 ms while output arrives.
    saved = Terminal.await_persisted(context, context.terminal, line("tick-50"))
    assert saved =~ line("tick-1")
    context
  end

  # Printed with no client attached, so the test does not stream it; the node's
  # own save of the scrollback says when printing finished.
  step ~r/^a terminal that has printed (?<amount>6,000 lines|10 MiB of text)$/,
       %{args: [amount]} = context do
    command =
      case amount do
        "6,000 lines" -> "seq 1 6000"
        "10 MiB of text" -> "yes \"$(printf '%04095d' 7)\" | head -n 2560"
      end

    {_, context} = Terminal.open!(context, %{}, "ctl")
    context = Terminal.write(context, "ctl", "#{command}; echo __printed''__\n")
    Terminal.await_persisted(context, context.terminal, "__printed__", 20_000)
    context
  end

  step "a client attaches", context do
    {snapshot, context} = Terminal.attach!(context, "later", attach_input(context))
    Map.put(context, :snapshot, snapshot)
  end

  step ~r/^the replayed history keeps only the newest (?<kept>5,000 lines|8 MiB of text)$/,
       %{args: [kept]} = context do
    history = context.snapshot["history"]
    assert history =~ "__printed__"

    case kept do
      "5,000 lines" ->
        lines = String.split(history, "\n")
        assert length(lines) in 4_990..5_000

        numbers =
          for l <- lines, n = Regex.run(~r/^(\d+)\r?$/, l, capture: :all_but_first), do: hd(n)

        assert List.last(numbers) == "6000"
        assert String.to_integer(hd(numbers)) > 1_000

      "8 MiB of text" ->
        max = 8 * 1024 * 1024
        assert byte_size(history) in (max - 8 * 1024)..max
    end

    context
  end

  step "a program asked the terminal for its cursor position and colours", context do
    # The questions, and replies as a terminal would send them, in the output.
    context
    |> attached(["default"])
    |> printf(
      "default",
      "q-start\\033[6n\\033]11;?\\033\\\\\\033[12;40R\\033]11;rgb:0000/0000/0000\\033\\\\q-end",
      "q-end"
    )
  end

  step "a client attaches and the history is replayed", context do
    {snapshot, context} = Terminal.attach!(context, "later", attach_input(context))
    Map.put(context, :snapshot, snapshot)
  end

  step "the replay does not contain those questions or their answers", context do
    history = context.snapshot["history"]
    assert history =~ "q-startq-end"

    for sequence <- ["\e[6n", "\e]11;?", "\e[12;40R", "\e]11;rgb"],
        do: refute(history =~ sequence, "#{inspect(sequence)} replayed")

    context
  end

  step "the shell receives no stray replies", context do
    # Anything answered on attach would reach the shell's input before this.
    {output, context} = Terminal.run(context, "later", "true")
    refute output =~ "40R"
    refute output =~ "rgb:"
    context
  end

  step "a program changed the cursor shape and saved the cursor", context do
    context |> attached(["default"]) |> printf("default", "c-start\\033[2 q\\0337c-end", "c-end")
  end

  step "the replay keeps the cursor shape and the saved cursor", context do
    assert context.snapshot["history"] =~ "c-start\e[2 q\e7c-end"
    context
  end

  step "the shell prints an emoji whose bytes arrive in two reads", context do
    context
    |> attached(["default"])
    |> printf("default", "e-start\\360\\237'; sleep 0.2; printf '\\232\\200e-end", "e-end")
  end

  step "the emoji appears once and intact", context do
    history = context.snapshot["history"]
    assert history =~ "e-start🚀e-end"
    assert length(String.split(history, "🚀")) == 2
    refute history =~ "\uFFFD"
    context
  end

  step "the shell prints a colour change whose bytes arrive in two reads", context do
    context
    |> attached(["default"])
    |> printf("default", "s-start\\033['; sleep 0.2; printf '31mred\\033[0ms-end", "s-end")
  end

  step "the colour change is applied and no stray characters appear", context do
    assert context.snapshot["history"] =~ "s-start\e[31mred\e[0ms-end"
    context
  end

  step "the shell prints bytes that are not valid UTF-8", context do
    context = attached(context, ["default", "second"])
    Terminal.write(context, "default", "printf 'bad-\\377-bytes\\n'\n")
  end

  step "attached clients see a replacement character in their place", context do
    for name <- ["default", "second"], reduce: context do
      context ->
        {_, _, context} = Terminal.await_output(context, name, line("bad-\uFFFD-bytes"))
        context
    end
  end

  # --- watching the node's terminals ------------------------------------------------

  step "the node runs terminals for two threads", context do
    open_threads(context, ["th-one", "th-two"])
  end

  step "a client starts watching the node's terminals", context do
    watch(context)
  end

  step "it first receives both terminals", context do
    assert %{"type" => "snapshot", "terminals" => terminals} = context.watch_frame["event"]
    assert Enum.sort(Enum.map(terminals, & &1["threadId"])) == ["th-one", "th-two"]
    context
  end

  step "then it is told each time a terminal is added, changes or goes away", context do
    input = Terminal.input(context, %{"threadId" => "th-three"})
    {_, context} = World.call!(context, "terminal.open", input, "ctl")

    context =
      await_watch(
        context,
        &match?(
          %{"type" => "upsert", "terminal" => %{"threadId" => "th-three", "status" => "running"}},
          &1
        )
      )

    write = Map.merge(Map.take(input, ["threadId", "terminalId"]), %{"data" => "exit 3\n"})
    {nil, context} = World.call!(context, "terminal.write", write, "ctl")

    context =
      await_watch(
        context,
        &match?(
          %{
            "type" => "upsert",
            "terminal" => %{"threadId" => "th-three", "status" => "exited", "exitCode" => 3}
          },
          &1
        )
      )

    {nil, context} =
      World.call!(context, "terminal.close", Map.take(input, ["threadId", "terminalId"]), "ctl")

    await_watch(context, &match?(%{"type" => "remove", "threadId" => "th-three"}, &1))
  end

  step "a client is watching the node's terminals", context do
    context |> open_threads(["th-one", "th-two"]) |> watch()
  end

  step "another client closes one of the terminals", context do
    {nil, context} =
      World.call!(
        context,
        "terminal.close",
        %{"threadId" => "th-one", "terminalId" => "term-1"},
        "ctl"
      )

    context
  end

  step "the watching client is told that terminal was removed", context do
    await_watch(
      context,
      &match?(%{"type" => "remove", "threadId" => "th-one", "terminalId" => "term-1"}, &1)
    )
  end

  # --- terminals on other nodes -----------------------------------------------------

  step "a thread whose terminal runs on the second node", context do
    peer = context.peer
    :ok = :erpc.call(peer, System, :put_env, ["SHELL", "/bin/sh"])

    input =
      Terminal.input(context, %{
        "threadId" => "th-peer",
        "cwd" => Terminal.mkdir(context, "/work/peer")
      })

    {:ok, _} = :erpc.call(peer, HalC2.Terminal, :open, [input])

    # Something printed there before anyone attaches.
    Task.async(fn ->
      {:ok, _} = :erpc.call(peer, HalC2.Terminal, :attach, [input, self()])

      {:ok, nil} =
        :erpc.call(peer, HalC2.Terminal, :write, [Map.put(input, "data", "echo p''eer-history\n")])

      await_peer_output(line("peer-history"), "")
    end)
    |> Task.await()

    Terminal.put_input(context, input)
  end

  step "a client connected to the first node attaches to that terminal", context do
    input = attach_input(context)
    {frame, context} = Terminal.attach(context, "default", input, Atom.to_string(context.peer))
    Map.merge(context, %{frame: frame, snapshot: snapshot(frame)})
  end

  step "the client receives the terminal's history and live output from the second node",
       context do
    assert context.snapshot["history"] =~ line("peer-history")
    assert context.snapshot["cwd"] == context.terminal["cwd"]
    data = Map.put(attach_input(context), "data", "echo l''ive-from-peer\n")
    {:ok, nil} = :erpc.call(context.peer, HalC2.Terminal, :write, [data])
    {_, _, context} = Terminal.await_output(context, "default", line("live-from-peer"))
    context
  end

  step "a client attaches to a terminal on a node the cluster does not know", context do
    {frame, context} =
      Terminal.attach(context, "default", Terminal.input(context), "ghost@nowhere")

    Map.put(context, :frame, frame)
  end

  step "the subscription fails with {string}", %{args: [reason]} = context do
    assert %{"t" => "error", "reason" => ^reason} = context.frame
    context
  end

  # --- helpers ----------------------------------------------------------------------

  # A line of output reading exactly `text`.
  defp line(text), do: ~r/(^|\n)#{Regex.escape(text)}\r?\n/

  defp session(context), do: Map.take(context.terminal, ["threadId", "terminalId"])
  defp attach_input(context), do: Map.delete(context.terminal, "cwd")

  defp snapshot(%{"event" => %{"type" => "snapshot", "snapshot" => snapshot}}), do: snapshot
  defp snapshot(frame), do: flunk("no snapshot: #{inspect(frame)}")

  defp refute_running(input),
    do:
      assert(
        Registry.lookup(HalC2.Terminal.Registry, {input["threadId"], input["terminalId"]}) == []
      )

  # Opens the scenario's terminal and attaches the named clients.
  defp attached(context, names) do
    {snapshot, context} = Terminal.open!(context, %{}, "ctl")

    names
    |> Enum.reduce(context, fn name, context ->
      {_, context} = Terminal.attach!(context, name, attach_input(context))
      context
    end)
    |> Map.put(:snapshot, snapshot)
  end

  # Prints `text` as a line of output; the typed command does not contain it.
  defp print(context, name, text) do
    {first, rest} = String.split_at(text, 1)
    context = Terminal.write(context, name, "echo #{first}''\"#{rest}\"\n")
    {_, _, context} = Terminal.await_output(context, name, line(text))
    context
  end

  # Runs `printf '<format>\n'` and waits for `done` at the end of the line.
  defp printf(context, name, format, done) do
    context = Terminal.write(context, name, "printf '#{format}\\n'\n")
    {_, _, context} = Terminal.await_output(context, name, ~r/#{Regex.escape(done)}\r?\n/)
    context
  end

  defp open_threads(context, threads) do
    Enum.reduce(threads, context, fn thread, context ->
      {_, context} = Terminal.open!(context, %{"threadId" => thread}, "ctl")
      context
    end)
  end

  defp watch(context) do
    id = System.unique_integer([:positive])

    client =
      Node.sub(World.client(context, "watcher"), id, %{
        "type" => "terminals",
        "node" => Atom.to_string(node())
      })

    {frame, client} = Node.await(client, &(&1["id"] == id))

    context
    |> World.put_client("watcher", client)
    |> Map.merge(%{watch_id: id, watch_frame: frame})
  end

  defp await_watch(context, fun) do
    id = context.watch_id

    {_, client} =
      Node.await(
        World.client(context, "watcher"),
        &(&1["t"] == "terminals" and &1["id"] == id and fun.(&1["event"])),
        5_000
      )

    World.put_client(context, "watcher", client)
  end

  defp await_peer_output(pattern, acc) do
    receive do
      {:halc2_terminal, _key, %{"type" => "output", "data" => data}} ->
        acc = acc <> data
        if acc =~ pattern, do: acc, else: await_peer_output(pattern, acc)

      {:halc2_terminal, _key, _event} ->
        await_peer_output(pattern, acc)
    after
      5_000 -> flunk("no #{inspect(pattern)} from the peer in #{inspect(acc)}")
    end
  end
end
