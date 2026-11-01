defmodule HalC2.Subprocess.Durable do
  @moduledoc """
  Provider programs that outlive the MC, so the next boot connects to them again.

  Each program runs under a small `sh` shim, detached from the VM, in a private dir
  under `<state dir>/durable/`:

    * `in`, a FIFO the shim holds open read-write, so the program never reads end of
      file because an MC went away;
    * `out`, an append-only file of the program's stdout. A file rather than a second
      FIFO because reading a FIFO consumes it: what a dying MC had read but not yet
      recorded would be gone. A program never blocks on it or gets SIGPIPE;
    * `err`, likewise for stderr, read only when the caller asked for a prefix;
    * `status`, and a last line in `out`, once the program has ended;
    * `alive`, which the attached helper touches; a shim that sees it go stale ends
      the program, so one whose MC never comes back does not run on for good;
    * `meta`, `snapshot`: who it is, and the runtime's state as of an offset in `out`.

  An MC talks to the dir through an ordinary tracked Exile program, the helper
  (`attach_args/2`), so `HalC2.Subprocess` reads and writes it as any other. The MC
  dying only ends the helper.

  A runtime checkpoints after each batch of output (`save/2`): its state, its
  connection's, and the offset they account for. A VM that dies between recording a
  batch's patches and that checkpoint replays the batch, so an update can repeat but
  none is lost. The files are not synced: a crash of the machine ends the program too.

  A boot (`survivors/0`) keeps a program only if its checkpoint names the run the thread
  is on (`HalC2.Orchestration.Recovery`). Anything else is killed first, as without
  this: two programs must never work on one provider conversation (hal-c2/hal-c2#254).

  Not on Windows, which has no such FIFO, and not for programs started without
  `:durable` (probes, sign-in, the device hub).
  """

  require Logger

  alias HalC2.Subprocess.Orphans

  @exit_mark "\x01hal-c2-exit "
  # How long a program waits for an MC, in minutes.
  @wait_minutes 10
  # Bumped when the snapshot's outer shape changes; an older one is not adopted.
  @format 1
  @runtimes [
    HalC2.Codex.ThreadRuntime,
    HalC2.Claude.ThreadRuntime,
    HalC2.Acp.ThreadRuntime,
    HalC2.Pi.ThreadRuntime,
    HalC2.Muse.ThreadRuntime
  ]

  @shim ~S"""
  dir=$1; shift
  exec 3<>"$dir/in"
  touch "$dir/alive"
  trap : TERM INT HUP
  "$@" <&3 >>"$dir/out" 2>>"$dir/err" 3<&- &
  prog=$!
  (
    trap - TERM INT HUP
    while sleep 30; do
      if [ -z "$(find "$dir/alive" -mmin -"$HAL_C2_DURABLE_WAIT" 2>/dev/null)" ]; then
        kill -TERM "$prog" 2>/dev/null
        sleep 5
        kill -KILL "$prog" 2>/dev/null
        exit 0
      fi
    done
  ) </dev/null >/dev/null 2>&1 3<&- &
  watch=$!
  status=1
  while kill -0 "$prog" 2>/dev/null; do
    wait "$prog"
    status=$?
  done
  kill "$watch" 2>/dev/null
  printf '%s' "$status" >"$dir/status.tmp"
  mv "$dir/status.tmp" "$dir/status"
  printf '\n\001hal-c2-exit %s\n' "$status" >>"$dir/out"
  """

  @helper ~S"""
  dir=$1; offset=$2; prefix=$3; shim=$4; helper=$$
  tail -c +"$((offset + 1))" -f "$dir/out" &
  out=$!
  err=
  if [ -n "$prefix" ]; then
    tail -n 0 -f "$dir/err" >&2 &
    err=$!
  fi
  (
    while kill -0 "$shim" 2>/dev/null; do
      touch "$dir/alive"
      sleep 2
    done
    # Gone without its report (a kill of the whole group): the output will not end by itself.
    sleep 1
    kill "$out" $err "$helper" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  beat=$!
  cat >"$dir/in"
  kill "$out" $err "$beat" 2>/dev/null
  """

  @doc "Whether a program may be started durable here."
  def enabled?,
    do:
      Application.get_env(:hal_c2, :durable_programs, true) and
        HalC2.Paths.platform() != :windows

  @doc "Where the programs' dirs live."
  def root, do: Path.join(HalC2.Paths.state_dir(), "durable")

  @doc """
  Starts `cmd` detached for `thread_id`, and returns `{:ok, %{dir, pid, started, group}}`.
  `opts`: `:cd` and `:env` as for a program.
  """
  def launch(thread_id, cmd, opts) do
    dir = Path.join(root(), "#{hash(thread_id)}-#{System.unique_integer([:positive])}-#{now()}")

    with :ok <- make_dir(dir),
         :ok <- touch_files(dir),
         {:ok, {group, pid}} <- detach(dir, cmd, opts),
         started when is_binary(started) <- Orphans.started(pid) do
      meta = %{
        "thread" => thread_id,
        "pid" => pid,
        "started" => started,
        "group" => group,
        "created" => now()
      }

      File.write!(Path.join(dir, "meta"), JSON.encode!(meta))
      {:ok, %{dir: dir, pid: pid, started: started, group: group}}
    else
      nil ->
        kill_dir(dir)
        {:error, :no_start_time}

      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  rescue
    e -> {:error, {:durable, Exception.message(e)}}
  end

  defp make_dir(dir) do
    HalC2.Paths.mkdir_private!(root())
    HalC2.Paths.mkdir_private!(dir)
    :ok
  end

  defp touch_files(dir) do
    with {_, 0} <- shell("mkfifo", [Path.join(dir, "in")]),
         :ok <- File.touch(Path.join(dir, "out")),
         :ok <- File.touch(Path.join(dir, "err")) do
      :ok
    else
      other -> {:error, {:durable, other}}
    end
  end

  # The shim is the background job of a shell that exits at once. It stays in that
  # shell's process group, which erl_child_setup made for it, so the program and the
  # commands it starts can be signalled together, and nothing the VM does reaches it.
  defp detach(dir, cmd, opts) do
    launcher =
      ~S(sh -c "$0" "$@" </dev/null >/dev/null 2>&1 & printf '%s %s' "$$" "$!")

    args = ["-c", launcher, @shim, "shim", dir | cmd]

    options =
      [env: [{"HAL_C2_DURABLE_WAIT", "#{@wait_minutes}"} | opts[:env] || []]] ++
        if(opts[:cd], do: [cd: opts[:cd]], else: [])

    case shell("sh", args, options) do
      {out, 0} ->
        [group, pid] = out |> String.trim() |> String.split(" ")
        {:ok, {String.to_integer(group), String.to_integer(pid)}}

      other ->
        {:error, {:durable, other}}
    end
  end

  @doc "The argv of the helper that connects an MC to `dir` from byte `offset` of its output."
  def attach_args(dir, offset, prefix \\ nil) do
    shim = (meta(dir) || %{})["pid"] || 0
    ["sh", "-c", @helper, "helper", dir, "#{offset}", prefix || "", "#{shim}"]
  end

  @doc "Whether a line of output is the shim's report that the program ended."
  def exit_line?(line), do: String.starts_with?(line, @exit_mark)

  @doc "Records a runtime's state as of a checkpoint a connection or session handed it."
  def save(%{dir: dir} = checkpoint, runtime, state) do
    snapshot = %{
      format: @format,
      runtime: runtime,
      state: state,
      offset: checkpoint.offset,
      channel: checkpoint.channel,
      mcp: HalC2.Mcp.credentials(state.thread_id)
    }

    path = Path.join(dir, "snapshot")
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, :erlang.term_to_binary(snapshot)),
         do: File.rename(tmp, path)

    :ok
  end

  @doc """
  A runtime's saved state ready to run on `channel`, the process now holding its
  program: what timers it held are gone, so what they guarded runs now.
  """
  def restored(state, field, channel, snapshot) do
    HalC2.Mcp.restore(snapshot.mcp)

    if turn = state[:turn],
      do: HalC2.Orchestration.TurnWatch.claim(state.thread_id, turn.ids.run)

    send(self(), :flush)
    state |> Map.put(field, channel) |> Map.put(:flush_timer, nil)
  end

  @doc """
  What this boot may connect to again: `%{thread_id => %{dir, snapshot}}`. A program with
  no usable checkpoint is killed here, and so is any but a thread's newest.
  """
  def survivors do
    Enum.each(@runtimes, &Code.ensure_loaded/1)

    candidates =
      for dir <- dirs(), entry = read(dir), do: entry

    candidates
    |> Enum.group_by(& &1.thread)
    |> Enum.reduce(%{}, fn {thread, entries}, acc ->
      [newest | older] = Enum.sort_by(entries, & &1.created, :desc)
      Enum.each(older, &kill_dir(&1.dir))

      case newest.snapshot do
        nil ->
          kill_dir(newest.dir)
          acc

        _ ->
          Map.put(acc, thread, newest)
      end
    end)
  end

  @doc false
  # What `survivors/0` would read, killing nothing: for tests.
  def survivors_peek do
    for dir <- dirs(), entry = read(dir), into: %{}, do: {entry.thread, entry}
  end

  defp dirs do
    case File.ls(root()) do
      {:ok, names} -> Enum.map(names, &Path.join(root(), &1))
      {:error, _} -> []
    end
  end

  defp read(dir) do
    case File.read(Path.join(dir, "meta")) do
      {:ok, text} ->
        meta = JSON.decode!(text)

        %{
          dir: dir,
          thread: meta["thread"],
          created: meta["created"],
          snapshot: snapshot(dir)
        }

      {:error, _} ->
        File.rm_rf(dir)
        nil
    end
  rescue
    _ ->
      File.rm_rf(dir)
      nil
  end

  defp snapshot(dir) do
    with {:ok, binary} <- File.read(Path.join(dir, "snapshot")),
         %{format: @format, runtime: runtime} = snapshot when runtime in @runtimes <-
           :erlang.binary_to_term(binary, [:safe]) do
      snapshot
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Whether the program of `dir` is still the one started there, or has reported its end."
  def attachable?(dir) do
    File.exists?(Path.join(dir, "status")) or running?(dir)
  end

  defp running?(dir) do
    case meta(dir) do
      %{"pid" => pid, "started" => started} -> Orphans.started(pid) == started
      _ -> false
    end
  end

  defp meta(dir) do
    case File.read(Path.join(dir, "meta")) do
      {:ok, text} -> JSON.decode!(text)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Stops the program of `dir`: a polite signal, then SIGKILL when `timeout` passes. Its
  dir goes with it. `{:ok, status}` when it reported one.
  """
  def stop(dir, timeout \\ 2_000) do
    if meta = meta(dir) do
      if running?(dir) do
        signal("-TERM", meta["group"])
        await_gone(dir, div(timeout, 10))
        if running?(dir), do: signal("-KILL", meta["group"])
      end
    end

    status = read_status(dir)
    File.rm_rf(dir)
    if status, do: {:ok, status}, else: {:error, :killed}
  end

  @doc "Kills the program of `dir` at once and removes the dir."
  def kill_dir(dir) do
    if meta = meta(dir) do
      if running?(dir), do: signal("-KILL", meta["group"])
    end

    File.rm_rf(dir)
    :ok
  end

  defp await_gone(_dir, tries) when tries <= 0, do: :ok

  defp await_gone(dir, tries) do
    if running?(dir) and not File.exists?(Path.join(dir, "status")) do
      Process.sleep(10)
      await_gone(dir, tries - 1)
    else
      :ok
    end
  end

  defp read_status(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "status")),
         {status, ""} <- Integer.parse(String.trim(text)) do
      status
    else
      _ -> nil
    end
  end

  defp signal(signal, group) when is_integer(group) and group > 1 do
    case shell("kill", [signal, "--", "-#{group}"]) do
      {_, 0} -> :ok
      {out, status} -> Logger.debug("kill #{signal} of group #{group}: #{status} #{out}")
    end
  end

  # In a process of its own: `System.cmd` links its port to the caller, and a caller
  # trapping exits (a provider session, which stops on any `:EXIT`) would hear of it.
  defp shell(cmd, args, opts \\ []) do
    {runner, ref} =
      spawn_monitor(fn ->
        exit({:done, System.cmd(cmd, args, [stderr_to_stdout: true] ++ opts)})
      end)

    receive do
      {:DOWN, ^ref, :process, ^runner, {:done, result}} -> result
      {:DOWN, ^ref, :process, ^runner, reason} -> {inspect(reason), 1}
    end
  end

  defp hash(thread_id),
    do:
      :crypto.hash(:sha256, thread_id) |> Base.url_encode64(padding: false) |> binary_part(0, 16)

  defp now, do: System.system_time(:millisecond)
end
