defmodule HalC2.TerminalRaceTest do
  @moduledoc """
  Regressions found by `prop/hal_c2/terminal_prop_test.exs`. The shell's output is
  simulated with the `{:stdout, os_pid, data}` message erlexec sends, which puts text in
  the scrollback and the pending output batch at a moment the test controls.
  """

  use ExUnit.Case, async: false

  alias HalC2.Terminal
  alias HalC2.Terminal.Hub

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous_shell = System.get_env("SHELL")
    # cat on a PTY prints no prompt of its own.
    System.put_env("SHELL", System.find_executable("cat"))
    Application.put_env(:hal_c2, :home, dir)

    on_exit(fn ->
      if previous_shell, do: System.put_env("SHELL", previous_shell)
    end)

    start_supervised!({Registry, keys: :unique, name: HalC2.Terminal.Registry})

    start_supervised!(
      {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one}
    )

    start_supervised!(Hub)
    %{input: %{"threadId" => "thread-1", "terminalId" => "term-1", "cwd" => dir}}
  end

  defp session(input) do
    [{pid, _}] =
      Registry.lookup(HalC2.Terminal.Registry, {input["threadId"], input["terminalId"]})

    pid
  end

  defp print(input, text) do
    pid = session(input)
    send(pid, {:stdout, :sys.get_state(pid).os_pid, text})
  end

  defp gone?(os_pid) do
    {_, status} =
      System.cmd("timeout", ["5", "tail", "--pid=#{os_pid}", "-f", "/dev/null"],
        stderr_to_stdout: true
      )

    status == 0
  end

  test "an attach during the output batch gets the text once", %{input: input} do
    {:ok, _} = Terminal.open(input)
    print(input, "early\r\n")

    {:ok, %{"history" => history}} = Terminal.attach(input, self())
    {:ok, nil} = Terminal.write(Map.put(input, "data", "marker\n"))
    marker = receive_until("marker\r\nmarker\r\n")

    assert history <> marker =~ ~r/\Aearly\r\n/
    assert length(String.split(history <> marker, "early")) == 2
  end

  test "attaching again during the output batch does not resend it", %{input: input} do
    {:ok, _} = Terminal.attach(input, self())
    print(input, "once\r\n")

    {:ok, %{"history" => history, "sequence" => sequence}} = Terminal.attach(input, self())
    {:ok, nil} = Terminal.write(Map.put(input, "data", "marker\n"))
    events = receive_events("marker\r\nmarker\r\n")

    assert history == "once\r\n"
    assert Enum.all?(events, &(&1["sequence"] > sequence))
    output = for %{"type" => "output", "data" => data} <- events, do: data
    assert history <> Enum.join(output) == "once\r\nmarker\r\nmarker\r\n"
  end

  test "a clear drops what was printed before it, not what follows", %{input: input} do
    {:ok, _} = Terminal.attach(input, self())
    print(input, "stale\r\n")
    {:ok, nil} = Terminal.clear(input)
    print(input, "fresh\r\n")

    assert {:ok, %{"history" => "fresh\r\n"}} = Terminal.open(input)
    events = receive_events("fresh\r\n")

    text =
      Enum.reduce(events, "", fn
        %{"type" => "cleared"}, _ -> ""
        %{"type" => "output", "data" => data}, text -> text <> data
        _, text -> text
      end)

    assert text == "fresh\r\n"
  end

  test "a restarted hub lists the terminals that are running", %{input: input} do
    {:ok, _} = Terminal.open(input)
    assert [%{"terminalId" => "term-1"}] = Hub.summaries()

    :ok = stop_supervised(Hub)
    start_supervised!(Hub)
    # Answered after the hub has asked the terminals to report.
    Hub.summaries()
    :sys.get_state(session(input))
    assert [%{"terminalId" => "term-1", "status" => "running"}] = Hub.summaries()
  end

  test "a reopened terminal is not dropped when the old one's DOWN arrives", %{input: input} do
    {:ok, _} = Terminal.open(input)
    old = session(input)
    session = {input["threadId"], input["terminalId"]}
    summary = hd(Hub.summaries())

    # The new session reports before the hub sees the old one go down.
    :sys.suspend(Hub)
    ref = Process.monitor(old)
    {:ok, nil} = Terminal.close(input)
    assert_receive {:DOWN, ^ref, _, _, _}
    {:ok, _} = Terminal.open(input)
    :sys.resume(Hub)

    assert [%{"terminalId" => "term-1"}] = Hub.summaries()
    assert session == {summary["threadId"], summary["terminalId"]}
  end

  test "closing a terminal frees its shell before the call returns", %{input: input} do
    {:ok, %{"pid" => os_pid}} = Terminal.open(input)
    {:ok, nil} = Terminal.close(input)
    refute File.exists?("/proc/#{os_pid}")
  end

  test "a terminal opened right after it was closed is a new one", %{input: input} do
    for _ <- 1..20 do
      {:ok, %{"status" => "running"}} = Terminal.open(input)
      {:ok, nil} = Terminal.close(input)
    end
  end

  test "a closed terminal saves what its shell printed while stopping", %{
    input: input,
    tmp_dir: dir
  } do
    # Prints only once the SIGTERM of the close has arrived, so its output reaches the
    # terminal while the close waits for the shell to go.
    shell = Path.join(dir, "shell")

    File.write!(shell, """
    #!/bin/sh
    trap 'kill $p; echo bye; exit 0' TERM
    sleep 1000 & p=$!
    echo ready
    wait $p
    """)

    File.chmod!(shell, 0o755)
    System.put_env("SHELL", shell)

    {:ok, _} = Terminal.attach(input, self())
    receive_until("ready\r\n")
    {:ok, nil} = Terminal.close(input)

    assert [{"term-1", "ready\r\nbye\r\n"}] = Terminal.saved_scrollback(input["threadId"])
  end

  test "a killed terminal takes its shell with it", %{input: input} do
    {:ok, %{"pid" => os_pid}} = Terminal.open(input)
    pid = session(input)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert gone?(os_pid)
  end

  defp receive_until(suffix, acc \\ "") do
    receive do
      {:hal_c2_terminal, _, %{"type" => "output", "data" => data}} ->
        acc = acc <> data
        if String.contains?(acc, suffix), do: acc, else: receive_until(suffix, acc)

      {:hal_c2_terminal, _, _} ->
        receive_until(suffix, acc)
    after
      5_000 -> flunk("no #{inspect(suffix)} in #{inspect(acc)}")
    end
  end

  # The events up to the output that ends in `suffix`, with a settling flush after it.
  defp receive_events(suffix, acc \\ [], text \\ "") do
    receive do
      {:hal_c2_terminal, _, event} ->
        text =
          case event do
            %{"type" => "output", "data" => data} -> text <> data
            %{"type" => "cleared"} -> ""
            _ -> text
          end

        acc = acc ++ [event]
        if String.ends_with?(text, suffix), do: acc, else: receive_events(suffix, acc, text)
    after
      5_000 -> flunk("no output ending in #{inspect(suffix)}: #{inspect(acc)}")
    end
  end
end
