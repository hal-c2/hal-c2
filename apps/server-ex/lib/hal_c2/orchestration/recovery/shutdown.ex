defmodule HalC2.Orchestration.Recovery.Shutdown do
  @moduledoc """
  Settles cut-off turns at a clean stop (`HalC2.Orchestration.Recovery.shut_down/0`).
  It starts before the provider runtimes, so the supervisor stops it after them, while
  the streams and the store it writes to are still up.
  """

  use GenServer

  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Settling writes every thread that was running.
      shutdown: 30_000
    }
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def terminate(reason, _state) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: HalC2.Orchestration.Recovery.shut_down(),
      else: :ok
  catch
    kind, error ->
      Logger.warning("could not settle turns before stopping: #{inspect({kind, error})}")
  end
end
