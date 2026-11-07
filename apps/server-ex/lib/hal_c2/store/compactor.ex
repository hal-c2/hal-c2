defmodule HalC2.Store.Compactor do
  @moduledoc """
  Compacts the log in the background (`HalC2.Store.Compaction`): a minute after the
  MC starts, then every six hours. After a run, a store that frees pages as it runs
  gives them back a little at a time, `@pages` pages a few seconds apart, so the
  writer is never held long. A store made before that waits for the doctor
  (`HalC2.Doctor`).

  Options: `:after` and `:every` in ms (`nil` never runs), `:store`, `:pages` and
  `:gap` for each step of giving space back, and `:notify`, a pid sent
  `{:compacted, report}` after each run and `{:reclaimed, free_bytes}` after each step.
  """

  use GenServer

  alias HalC2.Store
  alias HalC2.Store.Compaction

  @first :timer.minutes(1)
  @every :timer.hours(6)
  @pages 256
  @reclaim_gap :timer.seconds(5)

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "When it runs by default: `{after_start_ms, every_ms}`."
  def schedule, do: {@first, @every}

  @impl true
  def init(opts) do
    state = %{
      store: Keyword.get(opts, :store, Store),
      every:
        Keyword.get(opts, :every, Application.get_env(:hal_c2, :store_compact_every_ms, @every)),
      gap: Keyword.get(opts, :gap, @reclaim_gap),
      pages: Keyword.get(opts, :pages, @pages),
      notify: Keyword.get(opts, :notify)
    }

    later(
      :compact,
      Keyword.get(opts, :after, Application.get_env(:hal_c2, :store_compact_after_ms, @first))
    )

    {:ok, state}
  end

  @impl true
  def handle_info(:compact, state) do
    report = Compaction.run(state.store)
    if report.events > 0, do: Compaction.log(report)
    tell(state, {:compacted, report})
    later(:compact, state.every)
    if reclaims?(state, report.reclaimable), do: send(self(), :reclaim)
    {:noreply, state}
  end

  def handle_info(:reclaim, state) do
    {:ok, free} = Store.reclaim(state.store, state.pages)
    tell(state, {:reclaimed, free})
    if free > 0, do: later(:reclaim, state.gap)
    {:noreply, state}
  end

  defp reclaims?(state, free),
    do: free > 0 and Store.space(Store.path(state.store)).vacuum == :incremental

  defp later(_message, nil), do: :ok
  defp later(message, ms), do: Process.send_after(self(), message, ms)

  defp tell(%{notify: nil}, _message), do: :ok
  defp tell(%{notify: pid}, message), do: send(pid, message)
end
