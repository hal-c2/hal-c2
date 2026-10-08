defmodule HalC2.Heir do
  @moduledoc """
  Holds a service's ETS tables while the service starts again, so readers never find
  them gone and what the service kept in them (subscribers, single-use records)
  survives its crash. `supervise/3` runs the heir before the service under a
  `rest_for_one` supervisor; the service creates its tables with `{:heir, pid, nil}`
  (`option/1`) and takes them back in `init` with `claim/2`.
  """

  use GenServer

  @doc """
  The child spec of a supervisor running the heir `name` and then `server`, under
  `server`'s id: stopping or restarting that id takes both.
  """
  def supervise(name, server, supervisor) do
    %{
      id: server.id,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             %{id: name, start: {GenServer, :start_link, [__MODULE__, nil, [name: name]]}},
             server
           ],
           [strategy: :rest_for_one, name: supervisor]
         ]}
    }
  end

  @doc "The table option naming the heir `name`, or none when it is not running."
  def option(name) do
    case Process.whereis(name) do
      nil -> []
      pid -> [{:heir, pid, nil}]
    end
  end

  @doc "Gives the caller every one of `tables` the heir `name` holds, and returns those."
  def claim(name, tables) do
    if Process.whereis(name), do: GenServer.call(name, {:claim, tables}), else: []
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:claim, tables}, {pid, _}, state) do
    held =
      for name <- tables,
          :ets.whereis(name) != :undefined,
          :ets.info(name, :owner) == self() do
        :ets.give_away(name, pid, nil)
        name
      end

    {:reply, held, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state), do: {:noreply, state}
end
