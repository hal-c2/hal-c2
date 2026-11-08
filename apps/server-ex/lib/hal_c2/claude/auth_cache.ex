defmodule HalC2.Claude.AuthCache do
  @moduledoc """
  Owns the ETS table of Claude's sign-in reads (`HalC2.Claude.Provider`'s
  `auth_claim/2`/`auth_land/4`/`auth_lookup/1`/`forget_auth/1`), so the table
  outlives whichever short-lived process first asked for a provider entry.
  The table is public — every update is one atomic ETS operation from the
  caller — and a cache only: if this process restarts, the reads are simply
  read again. Supervised in the MC; started on first use where no supervisor
  runs it (a test that starts only the services it drives).
  """

  use GenServer

  @table :hal_c2_claude_auth

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}
  end

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The sign-in reads' table, made (with its owner) on first use."
  @spec table() :: :ets.table()
  def table do
    if :ets.whereis(@table) == :undefined do
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        _ -> :ok
      end
    end

    @table
  end

  @impl true
  def init(nil) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, nil}
  end
end
