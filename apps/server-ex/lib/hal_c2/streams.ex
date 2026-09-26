defmodule HalC2.Streams do
  @moduledoc """
  Runs one `HalC2.Streams.Server` per active stream on this node.

  A stream process starts on first use and stops after it has been idle with no
  subscribers, so inactive threads cost nothing but a row in the shell index.
  """

  use Supervisor

  alias HalC2.Streams.Server

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: HalC2.Streams.Registry},
        {DynamicSupervisor, name: HalC2.Streams.Supervisor, strategy: :one_for_one}
      ],
      strategy: :rest_for_one
    )
  end

  @doc "The stream's server, started if needed."
  @spec ensure(String.t()) :: pid
  def ensure(stream_id) do
    case Registry.lookup(HalC2.Streams.Registry, stream_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(HalC2.Streams.Supervisor, {Server, stream_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @doc """
  Subscribes `pid` to a stream. Delivers either the full state or, when `offset` is
  recent enough, only the events after it; see `HalC2.Streams.Server.subscribe/3`.
  """
  defdelegate subscribe(stream_id, pid, offset), to: Server
  defdelegate unsubscribe(stream_id, pid), to: Server

  @doc "See `HalC2.Streams.Server.transact/3`."
  def transact(stream_id, stream_kind, fun),
    do: stream_id |> ensure() |> Server.transact(stream_kind, fun)

  @doc "See `HalC2.Streams.Server.flush_shell/1`."
  def flush_shell(stream_id), do: stream_id |> ensure() |> Server.flush_shell()

  @doc "Commits changes to a stream and fans them out to its subscribers."
  @spec commit(String.t(), HalC2.Store.stream_kind(), [HalC2.Store.change()]) :: {:ok, non_neg_integer}
  def commit(stream_id, stream_kind, changes),
    do: stream_id |> ensure() |> Server.commit(stream_kind, changes)
end
