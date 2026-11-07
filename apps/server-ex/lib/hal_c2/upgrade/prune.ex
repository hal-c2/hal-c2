defmodule HalC2.Upgrade.Prune do
  @moduledoc """
  Removes the versions under a release root that nothing can use any more, each time
  the MC starts from a release (`HalC2.Upgrade`). Otherwise every update leaves its
  release, its applications' directories, its Erlang runtime and its cached bundle on
  disk.

  A version is kept while it runs or starts next (`releases/start_erl.data`), while the
  service could go back to it (`start_erl.data.previous`) or the last update came from
  it, while any process on the machine runs from it, and for an hour after it was
  installed, which covers one being staged right now. When the MC cannot tell one of
  these, it removes nothing.

  A removal renames first (`<name>.removing`) and deletes after, so one cut off never
  leaves a directory that looks installed; the next removal finishes it.
  """

  require Logger

  @grace_seconds 3600
  @removing ".removing"

  @doc """
  Removes from the release at `root`, running `running`, the versions nothing can use.
  `{:ok, removed versions}`, or `{:error, reason}` when it cannot tell what is in use.
  """
  def run(root, running) do
    releases = Path.join(root, "releases")
    finish(root)

    with {:ok, installed} <- installed(releases),
         {:ok, keep} <- keep(root, running, installed) do
      gone = Enum.reject(installed, &(&1 in keep))

      with {:ok, used} <- used(root, installed -- gone) do
        for version <- gone, do: remove(Path.join(releases, version))

        for dir <- unused(Path.join(root, "lib"), used), do: remove(dir)
        for dir <- unused(root, used, "erts-*"), do: remove(dir)

        # The bundles of versions not installed here, a removal cut off left among them.
        for dir <- unused(upgrades_dir(), MapSet.new(keep ++ (installed -- gone))),
            File.dir?(dir),
            do: remove(dir)

        {:ok, gone}
      end
    end
  end

  # The versions with a release under `releases/`.
  defp installed(releases) do
    case File.ls(releases) do
      {:ok, names} ->
        {:ok,
         for(
           name <- Enum.sort(names),
           not removing?(name) and not String.ends_with?(name, ".partial"),
           Path.wildcard(Path.join([releases, name, "*.rel"])) != [],
           do: name
         )}

      {:error, reason} ->
        {:error, "the releases cannot be listed: #{:file.format_error(reason)}"}
    end
  end

  defp keep(root, running, installed) do
    with {:ok, start} <- start_version(Path.join([root, "releases", "start_erl.data"])),
         {:ok, previous} <- previous_version(root),
         {:ok, from} <- last_update(),
         {:ok, args} <- processes() do
      in_use =
        for version <- installed,
            path = Path.join([root, "releases", version]) <> "/",
            Enum.any?(args, &String.contains?(&1, path)),
            do: version

      recent =
        for version <- installed, recent?(Path.join([root, "releases", version])), do: version

      {:ok, Enum.uniq([running, start | previous ++ from ++ in_use ++ recent])}
    end
  end

  # Paths under the MC's own release root.
  # sobelow_skip ["Traversal.FileModule"]
  defp start_version(path) do
    with {:ok, text} <- File.read(path),
         [_erts, version] <- String.split(text) do
      {:ok, version}
    else
      _ -> {:error, "#{path} does not name the version that starts"}
    end
  end

  # The version the service goes back to when the next start fails.
  defp previous_version(root) do
    path = Path.join([root, "releases", "start_erl.data.previous"])

    if File.exists?(path),
      do: with({:ok, version} <- start_version(path), do: {:ok, [version]}),
      else: {:ok, []}
  end

  # The version the last update moved from, which going back would return to.
  # sobelow_skip ["Traversal.FileModule"]
  defp last_update do
    path = Path.join(upgrades_dir(), "outcome.json")

    case File.read(path) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, %{"fromVersion" => from} = outcome} ->
            {:ok, Enum.filter([from, outcome["targetVersion"]], &is_binary/1)}

          _ ->
            {:error, "#{path} cannot be read"}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "#{path} cannot be read: #{:file.format_error(reason)}"}
    end
  end

  # The command line of every process on the machine (`:upgrade_processes` in the app
  # env stands in for `ps` in tests).
  defp processes do
    Application.get_env(:hal_c2, :upgrade_processes, &ps/0).()
  end

  defp ps do
    case System.cmd("ps", ["-A", "-ww", "-o", "args="], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, _} -> {:error, "the running processes cannot be listed: #{String.trim(out)}"}
    end
  rescue
    error -> {:error, "the running processes cannot be listed: #{Exception.message(error)}"}
  end

  # The application and runtime directories the kept releases and this VM use.
  # The release files under the MC's own root, which name only its applications.
  # sobelow_skip ["DOS.Consult"]
  defp used(root, kept) do
    Enum.reduce_while(kept, {:ok, own_dirs(root)}, fn version, {:ok, acc} ->
      rel = HalC2.Upgrade.Release.rel_file(Path.join(root, "releases"), version)

      case :file.consult(String.to_charlist(rel)) do
        {:ok, [{:release, _name, {:erts, erts}, apps}]} ->
          names = for app <- apps, do: "#{elem(app, 0)}-#{elem(app, 1)}"
          {:cont, {:ok, MapSet.union(acc, MapSet.new(["erts-#{erts}" | names]))}}

        _ ->
          {:halt, {:error, "#{rel} cannot be read"}}
      end
    end)
  end

  defp own_dirs(root) do
    lib = Path.join(root, "lib") <> "/"

    code =
      for path <- :code.get_path(),
          path = to_string(path),
          String.starts_with?(path, lib),
          do: path |> String.replace_prefix(lib, "") |> Path.split() |> hd()

    MapSet.new(["erts-#{:erlang.system_info(:version)}" | code])
  end

  # Entries of `dir` (matching `pattern`) that `used` does not name and that are not
  # being written or new.
  defp unused(dir, used, pattern \\ "*") do
    for path <- Path.wildcard(Path.join(dir, pattern)),
        name = Path.basename(path),
        not removing?(name) and not String.ends_with?(name, ".partial"),
        name not in used,
        not recent?(path),
        do: path
  end

  defp recent?(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime < @grace_seconds
      _ -> true
    end
  end

  defp remove(path) do
    if File.exists?(path) or match?({:ok, _}, File.lstat(path)) do
      gone = path <> @removing
      File.rm_rf!(gone)
      File.rename!(path, gone)
      File.rm_rf!(gone)
      Logger.info("removed #{path}, which no version uses")
    end
  end

  # What a removal cut off left.
  defp finish(root) do
    for dir <- [Path.join(root, "releases"), Path.join(root, "lib"), root, upgrades_dir()],
        path <- Path.wildcard(Path.join(dir, "*" <> @removing)),
        do: File.rm_rf!(path)
  end

  defp removing?(name), do: String.ends_with?(name, @removing)

  defp upgrades_dir, do: Path.join(HalC2.Paths.data_dir(), "upgrades")
end
