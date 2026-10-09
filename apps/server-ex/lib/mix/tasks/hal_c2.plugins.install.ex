defmodule Mix.Tasks.HalC2.Plugins.Install do
  @shortdoc "Installs or updates this checkout's plugin packages in an MC"
  @moduledoc """
  Copies plugin packages from this checkout's `plugins/` into an MC's plugins
  directory and has the running MC load them, as Look for plugins does; an MC that
  is not running loads them when it starts.

      mix hal_c2.plugins.install                # every package, into the dev MC
      mix hal_c2.plugins.install code-review    # just these
      mix hal_c2.plugins.install --release      # into the installed MC

  A package is replaced whole, so files an older version had do not linger. Files
  git ignores stay behind.
  """

  use Mix.Task

  @checkout Path.expand("../../../../..", __DIR__)

  @impl true
  def run(args) do
    {opts, ids} = OptionParser.parse!(args, strict: [release: :boolean])
    Mix.Task.run("app.config")

    # A checkout's own home is the dev profile; the installed MC's is the user's.
    if opts[:release] && Application.get_env(:hal_c2, :home) == :dev,
      do: Application.delete_env(:hal_c2, :home)

    source = Path.join(@checkout, "plugins")
    ids = if ids == [], do: packages(source), else: ids

    for id <- ids,
        not File.regular?(Path.join([source, id, "plugin.json"])),
        do: Mix.raise("No plugin package at plugins/#{id}")

    plugins = Path.join(HalC2.Paths.data_dir(), "plugins")
    File.mkdir_p!(plugins)
    Enum.each(ids, &install(&1, plugins))

    case HalC2.Cluster.Command.request(:post, "/api/plugins/rescan", %{}, 90_000) do
      {:ok, %{"plugins" => listed}} ->
        for %{"id" => id} = entry <- listed, id in ids do
          Mix.shell().info("#{id} #{entry["version"]}: #{entry["error"] || entry["status"]}")
        end

      {:error, message} ->
        Mix.shell().info("Installed #{Enum.join(ids, ", ")} in #{plugins}.")
        Mix.shell().info(message)
        Mix.shell().info("They load when the MC starts.")
    end
  end

  defp packages(source) do
    source
    |> File.ls!()
    |> Enum.filter(&File.regular?(Path.join([source, &1, "plugin.json"])))
    |> Enum.sort()
  end

  # Staged beside the plugins directory, where a rescan does not see it, then swapped in.
  defp install(id, plugins) do
    staged = Path.join(Path.dirname(plugins), ".plugin-#{id}.partial")
    old = Path.join(Path.dirname(plugins), ".plugin-#{id}.old")
    target = Path.join(plugins, id)
    Enum.each([staged, old], &File.rm_rf!/1)

    {files, 0} =
      System.cmd(
        "git",
        ~w(ls-files -z --cached --others --exclude-standard) ++ ["plugins/#{id}"],
        cd: @checkout
      )

    for file <- String.split(files, <<0>>, trim: true),
        File.regular?(Path.join(@checkout, file)) do
      to = Path.join(staged, Path.relative_to(file, "plugins/#{id}"))
      File.mkdir_p!(Path.dirname(to))
      File.cp!(Path.join(@checkout, file), to)
    end

    if File.exists?(target), do: File.rename!(target, old)
    File.rename!(staged, target)
    File.rm_rf!(old)
  end
end
