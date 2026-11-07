defmodule Mix.Tasks.HalC2.Thread.List do
  @shortdoc "Lists the threads this machine can export"
  @moduledoc """
  Lists the threads this machine holds, most recently updated first, one a line: its
  id, its project's folder and its title, for `mix hal_c2.thread.export`.

      mix hal_c2.thread.list [--json]

  `--json` prints the list as one JSON document. It only reads the store, so the MC may
  be running or stopped.
  """

  use Mix.Task

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {opts, [], []} -> list(opts[:json])
      _ -> Mix.raise("usage: mix hal_c2.thread.list [--json]")
    end
  end

  defp list(json?) do
    Mix.Task.run("app.config")

    path =
      if Process.whereis(HalC2.Store), do: HalC2.Store.path(), else: HalC2.Store.home_path()

    threads = if File.exists?(path), do: HalC2.ThreadArchive.exportable(path), else: []

    cond do
      json? -> Mix.shell().info(JSON.encode!(threads))
      threads == [] -> Mix.shell().info("No threads found.")
      true -> for t <- threads, do: Mix.shell().info(line(t))
    end
  end

  defp line(thread),
    do: Enum.map_join([thread["id"], thread["project"], thread["title"]], "\t", &one_line/1)

  # Breaks, tabs and other control characters as spaces: one thread, one line.
  defp one_line(nil), do: ""
  defp one_line(text), do: String.replace(text, ~r/[\x00-\x1f\x7f]/, " ")
end
