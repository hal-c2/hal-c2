defmodule HalC2.Doctor do
  @moduledoc """
  `hal-c2-service doctor` (`mix hal_c2.doctor`): checks a home's store with its MC
  stopped and repairs it. It rebuilds projections that no longer match the log
  (`HalC2.Projection.Check`), compacts the log (`HalC2.Store.Compaction`), and
  shrinks the store, switching one made before the MC could give space back while
  running to do so from now on.

  It changes nothing while anything has the store open: it takes the home's lock
  (`HalC2.HomeLock`), so no MC starts on it meanwhile, and refuses if another
  connection to the store is open, an MC on the same files included.

  Flags: `--fix` makes every recommended repair; `--dry-run` lists them and changes
  nothing, with `--fix` too. With neither, a terminal asks which to make, the
  recommended ones chosen; anything else gets the list.
  """

  alias Exqlite.Sqlite3
  alias HalC2.{HomeLock, Store}
  alias HalC2.Projection.Check
  alias HalC2.Store.Compaction

  # The least free space worth shrinking a store that gives space back as it runs.
  @free_bytes 1_000_000

  @type repair :: %{
          id: :rebuild | :compact | :shrink,
          text: String.t(),
          recommended: boolean,
          streams: [String.t()]
        }

  @doc "Runs the doctor on argv and prints its outcome; exits 1 on failure."
  def main(args) do
    case command(args, tty?: tty?()) do
      {:ok, text} ->
        IO.puts(text)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc """
  Runs the doctor as `{:ok, report}` or `{:error, message}`. Options: `:path` the store
  (this home's by default), `:lock` the home's lock, `:tty?` whether to ask, and
  `:choose`, given the repairs and returning those to make (it asks on the terminal by
  default).
  """
  @spec command([String.t()], keyword) :: {:ok, String.t()} | {:error, String.t()}
  def command(args, opts \\ []) do
    path = Keyword.get_lazy(opts, :path, &Store.home_path/0)
    lock = Keyword.get(opts, :lock, HomeLock.path(Path.dirname(path)))

    with {:ok, mode} <- mode(args, Keyword.get(opts, :tty?, false)),
         true <- File.exists?(path) || {:ok, "No store at #{path}"} do
      case HomeLock.with_lock(lock, fn -> doctor(path, mode, opts) end) do
        {:error, :held} -> {:error, open(path)}
        result -> result
      end
    else
      {:ok, _} = done -> done
      {:error, _} = error -> error
    end
  end

  defp mode(args, tty?) do
    case Enum.sort(Enum.uniq(args)) do
      [] -> {:ok, if(tty?, do: :ask, else: :list)}
      ["--dry-run"] -> {:ok, :list}
      ["--dry-run", "--fix"] -> {:ok, :list}
      ["--fix"] -> {:ok, :fix}
      _ -> {:error, "usage: hal-c2-service doctor [--fix] [--dry-run]"}
    end
  end

  defp doctor(path, mode, opts) do
    if open?(path) do
      {:error, open(path)}
    else
      repairs = survey(path)

      case {repairs, mode} do
        {[], _} ->
          {:ok, "Nothing to repair"}

        {_, :list} ->
          {:ok, list(repairs) <> "\nNothing was changed. Run with --fix to make these repairs."}

        {_, :fix} ->
          {:ok, repair(path, Enum.filter(repairs, & &1.recommended))}

        {_, :ask} ->
          case Keyword.get(opts, :choose, &ask/1).(repairs) do
            [] -> {:ok, "Nothing was changed."}
            chosen -> {:ok, repair(path, chosen)}
          end
      end
    end
  end

  defp open(path),
    do:
      "The store at #{path} is open: stop the MC, or whatever else has it open, " <>
        "and run the doctor again. Nothing was changed."

  # Another connection to a store in WAL mode holds a lock on it that an exclusive
  # connection cannot get past, whether or not it is reading.
  defp open?(path) do
    {:ok, db} = Sqlite3.open(path)

    try do
      :ok = Sqlite3.execute(db, "PRAGMA locking_mode = EXCLUSIVE")

      case Sqlite3.execute(db, "BEGIN EXCLUSIVE") do
        :ok ->
          :ok = Sqlite3.execute(db, "ROLLBACK")
          false

        {:error, reason} ->
          if reason =~ ~r/locked|busy/i, do: true, else: raise("#{path}: #{reason}")
      end
    after
      Sqlite3.close(db)
    end
  end

  # What is wrong with the store, read without writing anything.
  defp survey(path) do
    problems = Check.run(path)
    removable = Compaction.removable(path)
    space = Store.space(path)

    rebuild =
      if problems != [],
        do: [
          %{
            id: :rebuild,
            recommended: true,
            streams: Check.streams(problems),
            text:
              "Rebuild #{length(Check.streams(problems))} projections from the log:\n" <>
                Enum.map_join(problems, "\n", &("      " <> Check.describe(&1)))
          }
        ],
        else: []

    compact =
      if removable > 0,
        do: [
          %{
            id: :compact,
            recommended: true,
            streams: [],
            text: "Compact the log: #{removable} events no replay needs"
          }
        ],
        else: []

    shrink =
      cond do
        space.vacuum != :incremental ->
          [
            %{
              id: :shrink,
              recommended: true,
              streams: [],
              text:
                "Shrink the store (#{bytes(space.size)}) and let it give space back while the MC runs"
            }
          ]

        # A running MC gives free pages back a few at a time itself, and every store
        # has a few; worth a VACUUM only when a good part of the store is free.
        space.free >= max(@free_bytes, div(space.size, 4)) ->
          [
            %{
              id: :shrink,
              recommended: true,
              streams: [],
              text: "Shrink the store: #{bytes(space.free)} free"
            }
          ]

        true ->
          []
      end

    rebuild ++ compact ++ shrink
  end

  defp list(repairs), do: "Repairs:\n" <> Enum.map_join(repairs, "\n", &("  - " <> &1.text))

  # Asks for each repair in turn on the terminal, the recommended ones chosen.
  defp ask(repairs) do
    for repair <- repairs,
        answer =
          IO.gets(
            "#{repair.text}\n  Make this repair? #{if repair.recommended, do: "[Y/n]", else: "[y/N]"} "
          ),
        is_binary(answer),
        yes?(String.trim(answer), repair.recommended),
        do: repair
  end

  defp yes?("", default), do: default
  defp yes?(answer, _default), do: String.downcase(answer) in ["y", "yes"]

  # Makes the repairs: projections and compaction through a store of the doctor's own,
  # then shrinking on a connection of its own once that store has closed.
  defp repair(path, repairs) do
    chosen = MapSet.new(repairs, & &1.id)
    size = size(path)

    {:ok, store} = Store.start_link(path: path)

    lines =
      try do
        problems = Check.run(path)

        rebuilt =
          if :rebuild in chosen, do: Check.rebuild(Store, Check.streams(problems)), else: []

        report = if :compact in chosen, do: Compaction.run(Store, all: true)
        again = Check.run(path)

        [
          "Checked the projections: #{problems(problems)}" <>
            if(rebuilt != [], do: ", rebuilt #{length(rebuilt)}", else: ""),
          report && "Compacted the log: removed #{report.events} events",
          "Checked the projections again: #{problems(again)}"
        ] ++ Enum.map(again, &("  " <> Check.describe(&1)))
      after
        GenServer.stop(store)
      end

    if :shrink in chosen, do: shrink(path)

    Enum.join(
      Enum.reject(lines, &is_nil/1) ++
        ["Store size: #{bytes(size)} before, #{bytes(size(path))} after"],
      "\n"
    )
  end

  defp problems([]), do: "they match the log"
  defp problems([_]), do: "1 problem"
  defp problems(problems), do: "#{length(problems)} problems"

  # VACUUM rewrites the store, under the auto_vacuum mode set before it.
  defp shrink(path) do
    {:ok, db} = Sqlite3.open(path)

    try do
      for sql <- ["PRAGMA auto_vacuum = INCREMENTAL", "VACUUM", "PRAGMA wal_checkpoint(TRUNCATE)"],
          do: :ok = Sqlite3.execute(db, sql)
    after
      Sqlite3.close(db)
    end
  end

  defp size(path) do
    for file <- [path, path <> "-wal"],
        {:ok, %{size: size}} <- [File.stat(file)],
        reduce: 0,
        do: (total -> total + size)
  end

  defp bytes(n) when n >= 1_000_000_000, do: "#{Float.round(n / 1_000_000_000, 1)} GB"
  defp bytes(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)} MB"
  defp bytes(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)} kB"
  defp bytes(n), do: "#{n} bytes"

  # Standard input is a terminal: a character device, not a pipe or a file.
  defp tty?, do: match?({:ok, %{type: :device}}, File.stat("/dev/stdin"))
end
