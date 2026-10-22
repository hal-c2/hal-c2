defmodule HalC2.HomeLock do
  @moduledoc """
  One MC per HAL-C2 home. Two MCs on the same files share a database and a node name,
  so a peer's connection flips between them and each undoes the other's work. Boot
  takes `<data dir>/mc.lock` before anything else opens a file there, and holds it
  until the OS process ends.

  The lock is an SQLite exclusive transaction that is never committed: the operating
  system drops it with the process, however that ends, so a crashed MC leaves nothing
  stale behind. It is a file of its own, so tools reading `hal-c2.sqlite` while the
  MC runs are not blocked.
  """
  require Logger
  alias Exqlite.Sqlite3

  # How long a waiting MC sleeps between attempts.
  @retry_ms 1_000

  @doc "The lock file of the HAL-C2 home whose data directory is `data_dir`."
  def path(data_dir \\ HalC2.Paths.data_dir()), do: Path.join(data_dir, "mc.lock")

  @doc """
  Takes the home's lock for this OS process: `:ok`, or `{:error, :held}` when
  another process holds it. With `wait: true` it waits for the lock to be let go
  instead, as the background service does: it takes over once the MC holding the
  files (the desktop app's own) stops.
  """
  def acquire(opts \\ []) do
    path = Keyword.get(opts, :path, path())
    wait = Keyword.get(opts, :wait, false)

    case try_lock(path) do
      {:ok, db} ->
        # Held for the life of the node: the term keeps the connection from being
        # collected, and with it the lock.
        :persistent_term.put({__MODULE__, path}, db)
        :ok

      :held when wait ->
        Logger.info("another MC is running on #{Path.dirname(path)}; waiting for it to stop")
        wait_for(path)

      :held ->
        {:error, :held}
    end
  end

  defp wait_for(path) do
    Process.sleep(@retry_ms)

    case try_lock(path) do
      {:ok, db} ->
        :persistent_term.put({__MODULE__, path}, db)
        :ok

      :held ->
        wait_for(path)
    end
  end

  defp try_lock(path) do
    {:ok, db} = Sqlite3.open(path)

    case Sqlite3.execute(db, "BEGIN EXCLUSIVE") do
      :ok ->
        {:ok, db}

      {:error, _busy} ->
        Sqlite3.close(db)
        :held
    end
  end
end
