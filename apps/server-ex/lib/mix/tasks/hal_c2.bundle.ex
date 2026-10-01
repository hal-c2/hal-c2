defmodule Mix.Tasks.HalC2.Bundle do
  @shortdoc "Packs the built release into an upgrade bundle"
  @moduledoc """
  Packs `_build/prod/rel/hal_c2` (build it first with `MIX_ENV=prod mix release`) into
  the bundle MCs install to move to its version (`HalC2.Upgrade`):

      mix hal_c2.bundle [OUT_DIR]

  Writes `hal-c2-mc-<version>-<platform>.tar.gz` and its `.sha256` to `OUT_DIR`
  (default `_build/prod`), the names release artifacts are published under. Beside it
  goes the single-file MC, `hal-c2-mc-<version>-<platform>` and its `.sha256`: the
  bundle behind a shell script (`rel/hal-c2-mc.sh`) that unpacks it into the MC's
  data directory and starts it, for machines without Elixir or Erlang.
  Prints the bundle's path.
  """

  use Mix.Task

  @stub_path Path.expand("../../../rel/hal-c2-mc.sh", __DIR__)
  @external_resource @stub_path
  @stub File.read!(@stub_path)

  @impl true
  def run(args) do
    Mix.shell().info(bundle(List.first(args)))
  end

  @doc "Builds the bundle from the prod release (or the release at `root`); returns its path."
  def bundle(out_dir \\ nil, root \\ "_build/prod/rel/hal_c2") do
    root = Path.expand(root)

    [erts, version] =
      root |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

    manifest = Path.join([root, "releases", version, "upgrade.json"])

    File.exists?(manifest) ||
      Mix.raise("#{manifest} is missing; build the release with MIX_ENV=prod mix release")

    platform = manifest |> File.read!() |> JSON.decode!() |> Map.fetch!("platform")
    out_dir = Path.expand(out_dir || "_build/prod")
    File.mkdir_p!(out_dir)
    path = Path.join(out_dir, HalC2.Upgrade.Source.file_name(version, platform))

    entries =
      [Path.join(root, "bin"), Path.join(root, "lib"), Path.join([root, "releases", version])] ++
        [Path.join(root, "erts-#{erts}")]

    files =
      for entry <- entries,
          do: {String.to_charlist(Path.relative_to(entry, root)), String.to_charlist(entry)}

    :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
    write_sum(path)

    single = String.replace_suffix(path, ".tar.gz", "")
    File.write!(single, [stub(root, version, erts), File.read!(path)])
    File.chmod!(single, 0o755)
    write_sum(single)
    path
  end

  # The script the single-file MC starts with; the bundle follows its last line.
  defp stub(root, version, erts) do
    data_dir = File.read!(Path.join([root, "bin", "hal-c2-data-dir"]))

    script =
      @stub
      |> String.replace("@VERSION@", version)
      |> String.replace("@ERTS@", erts)
      |> String.replace("@DATA_DIR@\n", data_dir)

    lines = length(String.split(script, "\n")) - 1
    String.replace(script, "@PAYLOAD_LINE@", Integer.to_string(lines + 1))
  end

  defp write_sum(path) do
    sum = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    File.write!(path <> ".sha256", "#{sum}  #{Path.basename(path)}\n")
  end
end
