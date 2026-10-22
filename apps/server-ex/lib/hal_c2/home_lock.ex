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

    case if(held?(path), do: :mine, else: try_lock(path)) do
      :mine ->
        :ok

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

  @doc "Whether this node holds the lock at `path`."
  def held?(path \\ path()), do: :persistent_term.get({__MODULE__, path}, nil) != nil

  @doc """
  The lock as a service of the MC (`HalC2.Application.children/0`), so an MC that
  moved to this version by a hot update takes it too: boot took it already, and an
  MC updated in place takes it now. Refused, the service fails to start, which asks
  for a restart; the restarted MC waits for the lock at boot.
  """
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc false
  def start_link(opts \\ []) do
    case acquire(Keyword.take(opts, [:path])) do
      :ok -> :ignore
      {:error, :held} -> {:error, :home_held}
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

  # Only a busy database is another MC's lock. Anything else (a file that is not a
  # database) stops the start: two MCs repairing it at once could each unlink the
  # other's live lock, so the user removes it instead.
  defp try_lock(path) do
    {:ok, db} = Sqlite3.open(path)

    case Sqlite3.execute(db, "BEGIN EXCLUSIVE") do
      :ok ->
        {:ok, db}

      {:error, reason} ->
        Sqlite3.close(db)

        if reason =~ ~r/locked|busy/i,
          do: :held,
          else:
            raise(
              "#{path} is not a lock (#{reason}). Remove it with no MC running and start again."
            )
    end
  end
end
