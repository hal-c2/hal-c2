defmodule HalC2.Scratch do
  @moduledoc """
  Disposable files, kept apart from the machine's shared temp folder, where they cannot
  collide with another MC's and something knows when they may go.

  They go where the user chose (`storageCleanup.temporaryFilesFolder`, then
  `HAL_C2_TMPDIR`, see `HalC2.Paths.scratch_dir/1`), or to the default while that cannot
  be used, a disk being away, say. A folder holds:

  - `mc`: what the MC itself needs for a moment (`path/2`, `dir/1`). Its owner removes
    each one; `clear_leftovers/0` removes what a crash left behind.
  - `t/<key>`: one thread's, the temp folder its agent sessions are launched with
    (`thread_env/1`). `HalC2.StorageCleanup` removes it once `stale/4` says so.

  The key is short, and so is the rest of the path: programs put unix sockets under
  their temp folder, and a socket path may hold only about 100 bytes.
  """

  require Logger

  alias HalC2.Paths

  @day_ms 86_400_000
  @default_idle_days 7

  @doc "A new path for a scratch file or folder of the MC, not yet created."
  def path(prefix, extension \\ "") do
    dir = Path.join(root(), "mc")
    Paths.mkdir_private!(dir)
    Path.join(dir, "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}#{extension}")
  end

  @doc "A new scratch folder of the MC."
  def dir(prefix) do
    dir = path(prefix)
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Removes what a process that has ended left, read from the OS pid in each name. A
  running one may be another program on this home (`mix hal_c2.thread.import`), and
  a pid used again only keeps a leftover a while longer.
  """
  def clear_leftovers do
    for root <- roots(),
        dir = Path.join(root, "mc"),
        {:ok, names} <- [File.ls(dir)],
        name <- names,
        [_, pid] <- [Regex.run(~r/-(\d+)-\d+(\.[^.]+)?$/, name, capture: [0, 1])],
        HalC2.Subprocess.Orphans.gone?(String.to_integer(pid)) do
      File.rm_rf(Path.join(dir, name))
    end

    :ok
  end

  @doc "The folder for `thread_id`'s temporary files."
  def thread_dir(thread_id), do: Path.join([root(), "t", key(thread_id)])

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

  @doc "Days a thread may sit idle before its folder goes, or nil to keep folders of idle threads."
  def idle_days(settings) do
    case Map.fetch(settings["storageCleanup"] || %{}, "threadTempAfterDays") do
      :error -> @default_idle_days
      {:ok, days} when is_integer(days) and days > 0 -> days
      {:ok, _off} -> nil
    end
  end

  @doc """
  Which of `keys`, the thread folders on disk, may go: those of no thread here (a deleted
  thread's, one moved to another MC), and those of a thread with nothing running for
  `days` days. `threads` is `{id, last_active_ms, running?}` for this MC's threads that
  are not deleted.
  """
  def stale(keys, threads, days, now) do
    kept =
      for {id, active_at, running?} <- threads,
          running? or days == nil or active_at >= now - days * @day_ms,
          into: MapSet.new(),
          do: key(id)

    Enum.reject(keys, &MapSet.member?(kept, &1))
  end

  @doc """
  Removes the thread folders `stale/4` picks, wherever temporary files have lately gone:
  a folder chosen before this one is the user's to remove, having no record here.
  """
  def sweep(threads, days, now) do
    for root <- roots(), dir = Path.join(root, "t"), {:ok, names} <- [File.ls(dir)] do
      for key <- stale(Enum.filter(names, &(&1 =~ ~r/^[0-9a-f]{8}$/)), threads, days, now) do
        File.rm_rf(Path.join(dir, key))
      end
    end

    :ok
  end

  @doc "Every place the MC may have put scratch: the default, `HAL_C2_TMPDIR`, the chosen one."
  def roots, do: Enum.uniq([Paths.default_scratch_dir(), Paths.scratch_dir(), root()])

  # The chosen place while it can be used. `get/0` reads a table, so a launch can afford it.
  defp root do
    # The MC keeps the document as written, so a hand-edited one may hold anything here.
    chosen = get_in(HalC2.Settings.settings(), ["storageCleanup", "temporaryFilesFolder"])
    wanted = Paths.scratch_dir(if is_binary(chosen) and chosen != "", do: chosen)

    try do
      Paths.mkdir_private!(wanted)
      wanted
    rescue
      error in File.Error ->
        Logger.warning("temporary files go to the default: #{Exception.message(error)}")
        Paths.default_scratch_dir()
    end
  end

  defp key(thread_id) do
    :crypto.hash(:sha256, thread_id) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end
end
