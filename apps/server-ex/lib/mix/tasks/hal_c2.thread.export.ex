defmodule Mix.Tasks.HalC2.Thread.Export do
  @shortdoc "Writes a thread to a file another machine can import"
  @moduledoc """
  Writes a thread, with its attachments, terminal scrollback, checkpoints and (when
  its provider can carry one) the agent's session, to one file.

      mix hal_c2.thread.export THREAD FILE

  `THREAD` is the thread's id or title. Import the file on another machine with
  `mix hal_c2.thread.import`. The MC need not be stopped.
  """

  use Mix.Task

  @impl true
  def run([thread, file]) do
    start_store()

    case HalC2.ThreadArchive.export_file(thread, file) do
      {:ok, summary} ->
        Mix.shell().info(
          "Exported #{summary.title} to #{Path.expand(file)} " <>
            "(#{summary.attachments} attachments, #{summary.terminal_logs} terminal logs, " <>
            "#{summary.checkpoints} checkpoints#{if summary.session, do: ", the agent's session"})"
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end

  def run(_), do: Mix.raise("usage: mix hal_c2.thread.export THREAD FILE")

  @doc false
  def start_store do
    Mix.Task.run("app.config")

    unless Process.whereis(HalC2.Store) do
      {:ok, _} = Application.ensure_all_started(:exqlite)
      {:ok, _} = HalC2.Store.start_link(path: HalC2.Store.home_path())
    end
  end
end
