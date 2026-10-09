defmodule HalC2.Streams do
  @moduledoc """
  Runs one `HalC2.Streams.Server` per active stream on this MC.

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
    # The registry forgets a stream a moment after it stops: one found there that
    # has stopped is started again, as one not found is.
    with [{pid, _}] <- Registry.lookup(HalC2.Streams.Registry, stream_id),
         true <- Process.alive?(pid) do
      pid
    else
      _ ->
        case DynamicSupervisor.start_child(HalC2.Streams.Supervisor, {Server, stream_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @tries 3

  @doc """
  Calls `fun` with the stream's server, started if needed.

  A stream can stop between `ensure/1` and the call: the call then exits `:noproc`,
  or `:normal` if it was queued as the stream stopped. Either way it was not read, so
  `fun` asks again for a server, a few times.
  """
  def with_server(stream_id, fun, tries \\ @tries) do
    server = ensure(stream_id)
    hook(:ensured, stream_id)
    fun.(server)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal] and tries > 1 ->
      with_server(stream_id, fun, tries - 1)
  end

  # Tests stop a stream at a stage: `{module, function, args}`, called with the stage
  # and the stream id.
  defp hook(stage, stream_id) do
    case Application.get_env(:hal_c2, :streams_hook) do
      {m, f, a} -> apply(m, f, a ++ [stage, stream_id])
      nil -> :ok
    end
  end

  @doc """
  Subscribes `pid` to a stream. Delivers either the full state or, when `offset` is
  recent enough, only the events after it; see `HalC2.Streams.Server`.
  """
  defdelegate subscribe(stream_id, pid, offset), to: Server

  @doc "Subscribes `pid` for a client, which is sent only what its view of the stream lacks."
  defdelegate subscribe(stream_id, pid, offset, client), to: Server

  @doc "See `HalC2.Streams.Server.follow/4`."
  defdelegate follow(stream_id, pid, offset, client), to: Server

  @doc "Tells `pid` whenever the stream changes, without sending it the stream."
  defdelegate watch(stream_id, pid), to: Server

  @doc "See `HalC2.Streams.Server.more/3`."
  defdelegate more(stream_id, pid, items), to: Server

  @doc "See `HalC2.Streams.Server.unsubscribe/3`."
  defdelegate unsubscribe(stream_id, pid, tag \\ nil), to: Server

  @doc "See `HalC2.Streams.Server.transact/3`."
  def transact(stream_id, stream_kind, fun),
    do: with_server(stream_id, &Server.transact(&1, stream_kind, fun))

  @doc "The stream's current state, started if needed."
  def state(stream_id), do: with_server(stream_id, &Server.state/1)

  @doc "See `HalC2.Streams.Server.flush_shell/1`."
  def flush_shell(stream_id), do: with_server(stream_id, &Server.flush_shell/1)

  @doc "Commits changes to a stream and fans them out to its subscribers."
  @spec commit(String.t(), HalC2.Store.stream_kind(), [HalC2.Store.change()]) ::
          {:ok, non_neg_integer}
  def commit(stream_id, stream_kind, changes),
    do: with_server(stream_id, &Server.commit(&1, stream_kind, changes))
end
