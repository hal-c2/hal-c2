defmodule Mix.Tasks.HalC2.Import do
  @shortdoc "Imports a state.sqlite from an earlier install into this MC's store"
  @moduledoc """
  Imports the event log of an earlier HAL-C2 install into the MC's store.

      mix hal_c2.import PATH/TO/state.sqlite

  Threads an earlier install never migrated to orchestration v2 are imported from their
  version 1 events (`HalC2.Import.V1Thread`).

  The source is opened read-only, but it must not be a database a running server has
  open for writing: snapshot it first with `VACUUM INTO` (see AGENTS.md, Test data).
  """

  use Mix.Task

  @impl true
  def run([source]) do
    Mix.Task.run("app.config")
    home = HalC2.Paths.data_dir()
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = HalC2.Store.start_link(path: HalC2.Store.home_path())

    {us, {:ok, report}} = :timer.tc(fn -> HalC2.Import.V2.run(Path.expand(source)) end)

    Mix.shell().info("""
    Imported #{report.streams} streams in #{div(us, 1000)} ms into #{home}
      events:  #{report.source_events} -> #{report.events}
      payload: #{mb(report.source_bytes)} MB -> #{mb(report.bytes)} MB
    """)
  end

  def run(_), do: Mix.raise("usage: mix hal_c2.import PATH/TO/state.sqlite")

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
end
