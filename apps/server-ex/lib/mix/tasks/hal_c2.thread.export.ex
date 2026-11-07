defmodule Mix.Tasks.HalC2.Thread.Export do
  @shortdoc "Writes a thread to a file another machine can import"
  @moduledoc """
  Writes a thread, with its attachments, checkpoints and (when its provider can carry
  one) the agent's session, to a new file only the user can read.

      mix hal_c2.thread.export THREAD FILE [--terminal-scrollback]

  `THREAD` is the thread's id or title. A file already at `FILE` is never replaced.
  Terminal scrollback can hold secrets, so it goes only with `--terminal-scrollback`.
  Import the file on another machine with `mix hal_c2.thread.import`. The MC need not
  be stopped.
  """

  use Mix.Task

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [terminal_scrollback: :boolean]) do
      {opts, [thread, file], []} -> export(thread, file, opts)
      _ -> Mix.raise("usage: mix hal_c2.thread.export THREAD FILE [--terminal-scrollback]")
    end
  end

  defp export(thread, file, opts) do
    start_store()

    case HalC2.ThreadArchive.export_file(thread, file,
           terminal_logs: Keyword.get(opts, :terminal_scrollback, false)
         ) do
      {:ok, summary} ->
        Mix.shell().info(
          "Exported #{summary.title} (#{summary.thread}) to #{summary.path} " <>
            "(#{summary.attachments} attachments, #{summary.terminal_logs} terminal logs, " <>
            "#{summary.checkpoints} checkpoints#{if summary.session, do: ", the agent's session"})"
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc false
  def start_store do
    Mix.Task.run("app.config")

    unless Process.whereis(HalC2.Store) do
      {:ok, _} = Application.ensure_all_started(:exqlite)
      {:ok, _} = HalC2.Store.start_link(path: HalC2.Store.home_path())
    end
  end
end
