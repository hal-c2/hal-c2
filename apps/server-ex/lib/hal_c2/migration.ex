defmodule HalC2.Migration do
  @moduledoc """
  The one-shot copy from an old home into the MC's own directories
  (`features/mc/platform/storage-migration.feature`).

  A user coming from T3 Code has `~/.t3`, an early HAL-C2 user `~/.hal-c2`. The first
  time the MC starts with no database of its own and no migration record, it copies
  what the user cannot get back from `<old home>/elixir` into its config, data and
  state directories (`HalC2.Paths`). The old home is chosen by
  `HalC2.Paths.legacy_candidates/3`, first one that exists.

  The old home is only read, never changed: the database is copied with `VACUUM INTO`
  from a read-only (and, with no writer, immutable) connection, so a T3 Code still
  running against it is undisturbed and the copy is a consistent snapshot. Caches,
  downloaded tools and worktrees are not copied; threads keep working in the worktrees
  where they are.

  Everything is copied into `<dir>.migrating-<pid>` beside each directory and moved
  into place only when the whole copy succeeded, the database last. A copy that fails
  leaves nothing behind, logs a warning and the MC starts fresh; one cut short by a
  crash leaves a staging directory the next start removes before copying again.

  `<state>/migrated-from.json` records the source, when it ran and what was copied, so
  the migration runs once. `HAL_C2_NO_MIGRATE=1` records a skipped migration instead.
  """

  require Logger

  alias Exqlite.Sqlite3
  alias HalC2.Paths

  @config ~w(settings.json keybindings.json themes)
  @data ~w(environment-id access-token secrets attachments provider-auth plugins cluster
           scheduled-tasks.json providers device upgrades)
  @state ~w(logs)
  @databases ~w(hal-c2.sqlite t3.sqlite)

  @doc """
  Migrates when there is something to migrate from and nothing migrated yet:
  `{:migrated, source}`, `:skipped` (`HAL_C2_NO_MIGRATE`), `:no_source`,
  `:not_needed`, or `{:failed, source, reason}`.

  Options: `:dirs` (default `HalC2.Paths.dirs/0`), `:env` (default the process
  environment), `:user_home`, and `:copy_file`, the `(from, to -> :ok)` that copies
  one file.
  """
  def run(opts \\ []) do
    dirs = opts[:dirs] || Paths.dirs()
    env = opts[:env] || System.get_env()
    user_home = opts[:user_home] || Paths.user_home()
    record = record_path(dirs)

    cond do
      File.exists?(Path.join(dirs.data, "hal-c2.sqlite")) or File.exists?(record) ->
        :not_needed

      env["HAL_C2_NO_MIGRATE"] == "1" ->
        write_record(record, %{"source" => nil, "skipped" => true, "at" => now()})
        :skipped

      source = Enum.find(Paths.legacy_candidates(env, user_home), &File.dir?/1) ->
        migrate(source, dirs, record, opts[:copy_file] || (&copy_file/2))

      true ->
        :no_source
    end
  end

  @doc "Where the migration is recorded: `<state>/migrated-from.json`."
  def record_path(dirs \\ Paths.dirs()), do: Path.join(dirs.state, "migrated-from.json")

  defp migrate(source, dirs, record, copy) do
    old = Path.join(source, "elixir")
    stage = "migrating-#{System.pid()}"
    kinds = [config: @config, state: @state, data: @data]

    # A copy an earlier start was cut off in is never used.
    for {kind, _} <- kinds,
        stale <- Path.wildcard(dirs[kind] <> ".migrating-*"),
        do: File.rm_rf!(stale)

    stagings = for {kind, _} <- kinds, into: %{}, do: {kind, "#{dirs[kind]}.#{stage}"}

    try do
      # The database first, into staging: it is never at its final path half-copied.
      database =
        case Enum.find(@databases, &regular?(Path.join(old, &1))) do
          nil ->
            []

          name ->
            Paths.mkdir_private!(stagings.data)
            snapshot(Path.join(old, name), Path.join(stagings.data, "hal-c2.sqlite"))
            ["elixir/" <> name]
        end

      copied =
        for {kind, names} <- kinds, name <- names, from = Path.join(old, name), regular?(from) do
          Paths.mkdir_private!(stagings[kind])
          copy_tree(from, Path.join(stagings[kind], name), copy)
          "elixir/" <> name
        end

      # Into place, the database last.
      for {kind, _} <- kinds, File.dir?(stagings[kind]), do: commit(stagings[kind], dirs[kind])
      write_record(record, %{"source" => source, "at" => now(), "copied" => copied ++ database})
      Logger.info("Migrated from #{source}: copied #{length(copied ++ database)} items")
      {:migrated, source}
    rescue
      error ->
        for {_, staging} <- stagings, do: File.rm_rf(staging)
        reason = Exception.message(error)
        Logger.warning("Migrating from #{source} failed, starting fresh: #{reason}")
        {:failed, source, reason}
    end
  end

  # A file or directory, not a link: nothing copied may point back into the old home.
  defp regular?(path),
    do: match?({:ok, %{type: type}} when type in [:regular, :directory], File.lstat(path))

  defp copy_tree(from, to, copy) do
    %File.Stat{type: type, mode: mode} = File.lstat!(from)

    case type do
      :directory ->
        File.mkdir!(to)

        for name <- File.ls!(from),
            child = Path.join(from, name),
            regular?(child),
            do: copy_tree(child, Path.join(to, name), copy)

        # Secrets stay private whatever the old home allowed.
        File.chmod!(to, if(Path.basename(to) == "secrets", do: 0o700, else: mode_of(mode)))

      :regular ->
        :ok = copy.(from, to)
        File.chmod!(to, mode_of(mode))
    end
  end

  defp mode_of(mode), do: Bitwise.band(mode, 0o7777)

  defp copy_file(from, to) do
    File.copy!(from, to)
    :ok
  end

  # A consistent copy of a database another process may have open for writing. With
  # no write-ahead log the source is opened immutable, which reads it without creating
  # any file beside it; with one, a read-only connection reads through the log.
  defp snapshot(from, to) do
    path = URI.encode(from, &(URI.char_unreserved?(&1) or &1 == ?/))

    uri =
      if File.exists?(from <> "-wal"),
        do: "file:#{path}?mode=ro",
        else: "file:#{path}?immutable=1"

    {:ok, db} = Sqlite3.open(uri, mode: :readonly)

    try do
      with :ok <- Sqlite3.execute(db, "PRAGMA busy_timeout = 10000"),
           :ok <- Sqlite3.execute(db, "VACUUM INTO '#{String.replace(to, "'", "''")}'") do
        :ok
      else
        {:error, reason} -> raise "could not copy the database #{from}: #{reason}"
      end
    after
      Sqlite3.close(db)
    end
  end

  # Moves each staged entry into `dir` unless it is there already, then drops the staging.
  defp commit(staging, dir) do
    Paths.mkdir_private!(dir)
    names = File.ls!(staging)
    {db, rest} = Enum.split_with(names, &(&1 == "hal-c2.sqlite"))

    for name <- rest ++ db,
        target = Path.join(dir, name),
        not File.exists?(target),
        do: File.rename!(Path.join(staging, name), target)

    File.rm_rf!(staging)
  end

  defp write_record(path, record) do
    Paths.mkdir_private!(Path.dirname(path))
    File.write!(path, JSON.encode!(record))
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
