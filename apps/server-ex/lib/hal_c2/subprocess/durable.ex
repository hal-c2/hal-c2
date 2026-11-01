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
    * `err`, likewise for stderr, only when the caller asked for a prefix;
    * `status`, and a last line in `out`, once the program has ended;
    * `alive`, which the attached helper touches; a shim that sees it go stale ends
      the program, so one whose MC never comes back does not run on for good;
    * `meta`, `snapshot`: who it is, and the runtime's state as of an offset in `out`.

  An MC talks to the dir through an ordinary tracked Exile program, the helper
  (`attach_args/2`), so `HalC2.Subprocess` reads and writes it as any other. The MC
  dying only ends the helper.

  A runtime checkpoints (`checkpoint/4`) its state, its connection's, and the offset they
  account for. A VM that dies since the last save replays what came after it, so an
  update can repeat but none is lost; an MC stopping saves first (`leaving/2`). The
  files are not synced: a crash of the machine ends the program too. `out` is not
  trimmed, so it grows for as long as the program runs, until the idle release.

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
  @save_ms 100
  @pending {__MODULE__, :pending}
  @timer {__MODULE__, :timer}
  @last {__MODULE__, :last}
  # Bumped when the snapshot's outer shape changes; an older one is not adopted.
  @format 1
  @runtimes [
    HalC2.Codex.ThreadRuntime,
    HalC2.Claude.ThreadRuntime,
    HalC2.Acp.ThreadRuntime,
    HalC2.Pi.ThreadRuntime,
    HalC2.Muse.ThreadRuntime
  ]

  # In the foreground, because `sh` starts a background job with SIGINT and SIGQUIT
  # ignored and it could not undo that: whatever the program runs would inherit it. The
  # shim leads the program's process group (`detach/3`), so the watcher signals both.
  # It needs two stale looks in a row: a machine waking from sleep can run the watcher
  # before the helper has touched `alive`. It is in the group it signals, so it ignores
  # TERM to live to send the KILL, and only KILL stops it.
  # `kill -s`, because dash reads `kill -TERM -- -1` as a bad pid.
  @shim ~S"""
  exec </dev/null >/dev/null 2>&1
  dir=$1; wait_minutes=$2; err=$3; shift 3
  exec 3<>"$dir/in"
  touch "$dir/alive"
  trap : TERM INT HUP
  shim=$$
  (
    trap '' TERM
    stale=0
    while sleep "$HAL_C2_DURABLE_LOOK"; do
      if [ -z "$(find "$dir/alive" -mmin -"$wait_minutes" 2>/dev/null)" ]; then
        stale=$((stale + 1))
      else
        stale=0
      fi
      if [ "$stale" -ge 2 ]; then
        kill -s TERM -- "-$shim" 2>/dev/null
        sleep 5
        kill -s KILL -- "-$shim" 2>/dev/null
        exit 0
      fi
    done
  ) 3<&- &
  watch=$!
  "$@" <&3 >>"$dir/out" 2>>"$err" 3<&-
  status=$?
  kill -KILL "$watch" 2>/dev/null
  printf '%s' "$status" >"$dir/status.tmp"
  mv "$dir/status.tmp" "$dir/status"
  printf '\n\001hal-c2-exit %s\n' "$status" >>"$dir/out"
  """

  # `in` opened read-write, so the open cannot block once the shim is gone. A shim gone
  # without its report (a kill of its whole group) gets one written here, so what is
  # left of the output is still read to its end, however much that is.
  @helper ~S"""
  dir=$1; offset=$2; prefix=$3; shim=$4
  exec 3<>"$dir/in"
  tail -c +"$((offset + 1))" -f "$dir/out" 3<&- &
  out=$!
  err=
  if [ -n "$prefix" ]; then
    tail -n 0 -f "$dir/err" >&2 3<&- &
    err=$!
  fi
  (
    while kill -0 "$shim" 2>/dev/null; do
      touch "$dir/alive"
      sleep 2
    done
    if [ ! -e "$dir/status" ]; then
      printf '\n\001hal-c2-exit 137\n' >>"$dir/out"
    fi
  ) </dev/null >/dev/null 2>&1 3<&- &
  beat=$!
  cat >&3
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
    {mark, entry} = Orphans.new_mark()
    opts = Keyword.update(opts, :env, [entry], &(Enum.to_list(&1 || []) ++ [entry]))

    with :ok <- make_dir(dir),
         :ok <- touch_files(dir),
         {:ok, {group, pid}} <- detach(dir, cmd, opts),
         started when is_binary(started) <- Orphans.started(pid) do
      meta = %{
        "thread" => thread_id,
        "pid" => pid,
        "started" => started,
        "group" => group,
        "mark" => mark,
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

  # A port rather than Exile: erl_child_setup makes the program the leader of a session of
  # its own and leaves it running when the port closes or the VM goes, and it gets no
  # background job's ignored signals. The shim lets go of the port's pipes first thing.
  defp detach(dir, cmd, opts) do
    err = if opts[:stderr_prefix], do: Path.join(dir, "err"), else: "/dev/null"

    args = ["-c", @shim, "shim", dir, "#{@wait_minutes}", err | cmd]
    look = Application.get_env(:hal_c2, :durable_look_seconds, 30)

    env =
      for {key, value} <- [{"HAL_C2_DURABLE_LOOK", "#{look}"} | Enum.to_list(opts[:env] || [])],
          do: {to_charlist(key), to_charlist(value)}

    cd = if opts[:cd], do: [cd: to_charlist(opts[:cd])], else: []
    settings = [:binary, :exit_status, :hide, {:args, args}, {:env, env}] ++ cd
    {runner, ref} = spawn_monitor(fn -> exit({:spawned, open(settings)}) end)

    receive do
      {:DOWN, ^ref, :process, ^runner, {:spawned, pid}} when is_integer(pid) -> {:ok, {pid, pid}}
      {:DOWN, ^ref, :process, ^runner, reason} -> {:error, {:durable, reason}}
    end
  end

  defp open(settings) do
    port = Port.open({:spawn_executable, System.find_executable("sh")}, settings)
    {:os_pid, pid} = Port.info(port, :os_pid)
    pid
  end

  @doc "The argv of the helper that connects an MC to `dir` from byte `offset` of its output."
  def attach_args(dir, offset, prefix \\ nil) do
    shim = (meta(dir) || %{})["pid"] || 0
    ["sh", "-c", @helper, "helper", dir, "#{offset}", prefix || "", "#{shim}"]
  end

  @doc "Whether a line of output is the shim's report that the program ended."
  def exit_line?(line), do: String.starts_with?(line, @exit_mark)

  @doc """
  A runtime heard a checkpoint from its connection or session; returns its state. What
  was just sent to the program is saved at once, or a reply to it could not be told
  apart after a restart. Output is saved at most every #{@save_ms} ms: a stale save only
  replays more output, and a long turn's state is too big to write for every batch.
  Saving runs `flush` first, and a later flush that writes saves again (`flushed/2`), so
  the state saved holds no text the log has for longer than that interval.
  """
  def checkpoint(checkpoint, runtime, state, flush) do
    Process.put(@pending, {checkpoint, runtime})
    Process.put(@last, {checkpoint, runtime})

    cond do
      checkpoint[:wrote] ->
        save_pending(state, flush)

      Process.get(@timer) ->
        state

      true ->
        Process.put(@timer, Process.send_after(self(), :durable_save, @save_ms))
        state
    end
  end

  @doc "The timer of `checkpoint/4` fired: `:durable_save`."
  def save_due(state, flush) do
    Process.delete(@timer)
    save_pending(state, flush)
  end

  @doc """
  A runtime's flush timer ran, from state `before` to `state`: text it wrote is in the
  log but still in the last save, so another save is due. Returns `state`.
  """
  def flushed(before, state) do
    with true <- before.buffer != state.buffer,
         {_checkpoint, _runtime} = last <- Process.get(@last) do
      Process.put(@pending, last)

      unless Process.get(@timer),
        do: Process.put(@timer, Process.send_after(self(), :durable_save, @save_ms))
    end

    state
  end

  @doc "A runtime is stopping: with the MC, what it has is saved as it stands."
  def leaving(state, flush) do
    if HalC2.Orchestration.Recovery.stopping?() do
      if last = Process.get(@last), do: Process.put(@pending, last)
      save_pending(state, flush)
    else
      state
    end
  catch
    _, _ -> state
  end

  defp save_pending(state, flush) do
    case Process.delete(@pending) do
      {checkpoint, runtime} = pending ->
        Process.put(@last, pending)
        state = flush.(state)
        save(checkpoint, runtime, state)
        state

      nil ->
        state
    end
  end

  defp save(%{dir: dir} = checkpoint, runtime, state) do
    snapshot = %{
      format: @format,
      dir: dir,
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

    # A program gone quiet sends no checkpoint, and this flush may write what the save
    # holds: `flushed/2` and `leaving/2` need the checkpoint this state came from.
    checkpoint = %{dir: snapshot.dir, offset: snapshot.offset, channel: snapshot.channel}
    Process.put(@last, {checkpoint, snapshot.runtime})
    send(self(), :flush)

    # `text_at` is the old VM's monotonic time, which means nothing here: kept, it would
    # hold back every paragraph until this VM had been up as long as that one.
    state |> Map.put(field, channel) |> Map.put(:flush_timer, nil) |> Map.delete(:text_at)
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
    remove(dir)
    if status, do: {:ok, status}, else: {:error, :killed}
  end

  @doc "Kills the program of `dir` at once and removes the dir."
  def kill_dir(dir) do
    if meta = meta(dir) do
      if running?(dir), do: signal("-KILL", meta["group"])
    end

    remove(dir)
    :ok
  end

  # What the program left in its group outlives it, a dev server say, and with the dir
  # gone nothing could name it. A dir whose commands could not all be killed stays, so
  # the next boot's `survivors/0` comes here again.
  defp remove(dir) do
    with %{"group" => group, "mark" => mark} <- meta(dir),
         :kept <- sweep(Path.join(dir, "meta"), group, mark) do
      :ok
    else
      _ -> File.rm_rf(dir)
    end
  end

  # In a process of its own, as `shell/3`.
  defp sweep(path, group, mark) do
    {runner, ref} =
      spawn_monitor(fn -> exit({:swept, Orphans.sweep_group(path, group, mark)}) end)

    receive do
      {:DOWN, ^ref, :process, ^runner, {:swept, outcome}} -> outcome
      {:DOWN, ^ref, :process, ^runner, _crash} -> :kept
    end
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
