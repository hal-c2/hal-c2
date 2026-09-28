defmodule HalC2.Subprocess.Orphans do
  @moduledoc """
  `<state dir>/programs/<os pid>.json`: the programs this node started, so the next
  node can stop the ones a halted node left running.

  A VM that halts (a second Ctrl-C, `:erlang.halt/0`) runs no `terminate`, and its
  programs only lose their pipes. A provider CLI mid-turn keeps editing the checkout,
  and a restarted node that resumes the thread would run a second agent beside it.
  `HalC2.Subprocess` records each program it starts and forgets it once stopped;
  `reap/0` runs at boot, before any thread can resume a provider session.

  An entry names the program and the node's own VM by OS pid and start identity, so a
  reused pid is never signalled and a node never stops what a live VM on the same state
  runs. An entry whose owner crashed stays until a later boot finds both gone.
  """

  require Logger

  @grace 1_000

  @doc "The directory entries live in."
  def dir, do: Path.join(HalC2.Paths.state_dir(), "programs")

  @doc "Records `os_pid`, started for `program`. Nothing is recorded where identity is unknown."
  def record(os_pid, program) do
    {node_pid, node_started} = owner()

    with started when is_binary(started) <- identity(os_pid),
         true <- is_binary(node_started),
         :ok <- File.mkdir_p(dir()) do
      entry = %{
        "pid" => os_pid,
        "started" => started,
        "program" => program,
        "node" => %{"pid" => node_pid, "started" => node_started}
      }

      File.write(path(os_pid), JSON.encode!(entry))
    end

    :ok
  end

  @doc "Removes `os_pid`'s entry."
  def forget(os_pid) do
    File.rm(path(os_pid))
    :ok
  end

  @doc """
  Stops every recorded program whose node is gone and which still runs as recorded:
  SIGTERM, then SIGKILL after a short grace. Programs share the node's process group,
  so only their own pid is signalled. Clears those entries.
  """
  def reap do
    dir = dir()

    # Entries of a live node stay; unreadable ones (a halt mid-write) go unsignalled.
    stale =
      case File.ls(dir) do
        {:ok, names} -> Enum.map(names, &{Path.join(dir, &1), read(Path.join(dir, &1))})
        {:error, _} -> []
      end
      |> Enum.reject(fn {_, entry} -> entry && alive?(entry["node"]) end)

    running = for {_, %{} = entry} <- stale, alive?(entry), do: entry

    if running != [] do
      Logger.warning(
        "stopping programs a halted node left running: " <>
          Enum.map_join(running, ", ", &"#{&1["program"]} (#{&1["pid"]})")
      )

      running |> signal("TERM") |> await_exit() |> signal("KILL") |> await_exit()
    end

    Enum.each(stale, &File.rm(elem(&1, 0)))
  end

  @doc """
  What tells `os_pid`'s process apart from a later one given the same pid, or nil when
  it has ended: the boot and start time on Linux, the start time on macOS.
  """
  def identity(os_pid) do
    case :os.type() do
      {:unix, :linux} -> linux_identity(os_pid)
      {:unix, :darwin} -> ps_identity(os_pid)
      _ -> nil
    end
  end

  defp linux_identity(os_pid) do
    # Fields after the command name, which may hold spaces and parentheses; the state
    # is field 3 and the start time, in clock ticks since boot, field 22.
    with {:ok, stat} <- File.read("/proc/#{os_pid}/stat"),
         [_, fields] <- Regex.run(~r/^.*\) (.*)$/s, stat),
         [state | _] = fields = String.split(fields, " "),
         false <- state in ["Z", "X"],
         {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id") do
      "#{String.trim(boot)}/#{Enum.at(fields, 19)}"
    else
      _ -> nil
    end
  end

  defp ps_identity(os_pid) do
    case System.cmd("ps", ["-o", "stat=,lstart=", "-p", to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.split(String.trim(out), ~r/\s+/, parts: 2) do
          ["Z" <> _, _] -> nil
          [_, started] -> started
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp owner do
    case :persistent_term.get({__MODULE__, :owner}, nil) do
      nil ->
        pid = String.to_integer(System.pid())
        owner = {pid, identity(pid)}
        :persistent_term.put({__MODULE__, :owner}, owner)
        owner

      owner ->
        owner
    end
  end

  defp path(os_pid), do: Path.join(dir(), "#{os_pid}.json")

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"pid" => pid, "started" => s, "node" => %{}} = entry}
         when is_integer(pid) and is_binary(s) <- JSON.decode(body) do
      entry
    else
      _ -> nil
    end
  end

  defp alive?(%{"pid" => pid, "started" => started}) when is_integer(pid),
    do: identity(pid) == started

  defp alive?(_), do: false

  defp signal([], _signal), do: []

  defp signal(entries, signal) do
    System.cmd("kill", ["-s", signal | Enum.map(entries, &to_string(&1["pid"]))],
      stderr_to_stdout: true
    )

    entries
  end

  # Only at boot, and only for programs that outlived their node: these are not this
  # VM's children, so there is no exit to wait on, only their pids to look at.
  defp await_exit(entries, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @grace

    case Enum.filter(entries, &alive?/1) do
      [] ->
        []

      left ->
        if System.monotonic_time(:millisecond) >= deadline do
          left
        else
          Process.sleep(50)
          await_exit(left, deadline)
        end
    end
  end
end
