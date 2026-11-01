defmodule HalC2.Scratch do
  @moduledoc """
  Disposable files, kept apart from the machine's shared temp folder, where they cannot
  collide with another MC's and something knows when they may go.

  `HalC2.Paths.scratch_dir/0` holds two folders:

  - `mc`: what the MC itself needs for a moment (`path/2`, `dir/1`). Its owner removes
    each one; what a crash left behind goes when the next MC starts, `HomeLock` having
    made sure no other MC uses this home.
  - `t/<key>`: one thread's, the temp folder its agent sessions are launched with
    (`thread_env/1`). `HalC2.StorageCleanup` removes it once `stale/3` says so.

  The key is short, and so is the rest of the path: programs put unix sockets under
  their temp folder, and a socket path may hold only about 100 bytes.
  """

  require Logger

  alias HalC2.Paths

  @day_ms 86_400_000
  @idle_days 7

  @doc "A new path for a scratch file or folder of the MC, not yet created."
  def path(prefix, extension \\ "") do
    dir = Path.join(Paths.scratch_dir(), "mc")
    Paths.mkdir_private!(dir)
    Path.join(dir, "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}#{extension}")
  end

  @doc "A new scratch folder of the MC."
  def dir(prefix) do
    dir = path(prefix)
    File.mkdir_p!(dir)
    dir
  end

  @doc "Removes what an earlier MC on this home left. Only at boot, under the home's lock."
  def clear_leftovers do
    File.rm_rf(Path.join(Paths.scratch_dir(), "mc"))
    :ok
  end

  @doc "The folder for `thread_id`'s temporary files."
  def thread_dir(thread_id), do: Path.join(threads_dir(), key(thread_id))

  @doc """
  The variables that send an agent session's temporary files to its thread's folder,
  created here. Claude Code ignores `TMPDIR` and reads only its own variable. Empty when
  the folder cannot be made, which must not stop a session from starting.
  """
  def thread_env(thread_id) do
    dir = thread_dir(thread_id)
    Paths.mkdir_private!(dir)
    for name <- ~w(TMPDIR TMP TEMP CLAUDE_CODE_TMPDIR), do: {name, dir}
  rescue
    error in File.Error ->
      Logger.warning("no temp folder for a thread: #{Exception.message(error)}")
      []
  end

  @doc """
  Which of `keys`, the thread folders on disk, may go: those of no thread here (a deleted
  thread's, one moved to another MC), and those of a thread with nothing running for
  #{@idle_days} days. `threads` is `{id, last_active_ms, running?}` for this MC's threads
  that are not deleted.
  """
  def stale(keys, threads, now) do
    kept =
      for {id, active_at, running?} <- threads,
          running? or active_at >= now - @idle_days * @day_ms,
          into: MapSet.new(),
          do: key(id)

    Enum.reject(keys, &MapSet.member?(kept, &1))
  end

  @doc "Removes the thread folders `stale/3` picks."
  def sweep(threads, now) do
    with {:ok, names} <- File.ls(threads_dir()) do
      for key <- stale(Enum.filter(names, &(&1 =~ ~r/^[0-9a-f]{8}$/)), threads, now) do
        File.rm_rf(Path.join(threads_dir(), key))
      end
    end

    :ok
  end

  defp threads_dir, do: Path.join(Paths.scratch_dir(), "t")

  defp key(thread_id) do
    :crypto.hash(:sha256, thread_id) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end
end
