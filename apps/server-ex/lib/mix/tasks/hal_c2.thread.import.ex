defmodule Mix.Tasks.HalC2.Thread.Import do
  @shortdoc "Imports a thread from a file another machine exported"
  @moduledoc """
  Imports a thread written by `mix hal_c2.thread.export` (or a version 1 thread archive
  from an earlier install) into a project on this machine.

      mix hal_c2.thread.import FILE [--project PROJECT]

  Without `--project` the thread goes into the one project that is a checkout of the
  same repository. Nothing is written unless the whole file checks out.
  """

  use Mix.Task

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [project: :string]) do
      {opts, [file], []} ->
        Mix.Tasks.HalC2.Thread.Export.start_store()

        case HalC2.ThreadArchive.import_file(file, project: opts[:project]) do
          {:ok, result} ->
            Mix.shell().info("Imported #{result.title} into #{project_title(result.project)}.")
            Enum.each(result.notes, fn note -> Mix.shell().info(note) end)

          {:error, message} ->
            Mix.raise(message)
        end

      _ ->
        Mix.raise("usage: mix hal_c2.thread.import FILE [--project PROJECT]")
    end
  end

  defp project_title(id) do
    Enum.find_value(HalC2.ThreadArchive.local_projects(), id, fn project ->
      if project["id"] == id, do: project["title"]
    end)
  end
end
