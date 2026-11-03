defmodule HalC2.Streams do
  @moduledoc """
  Runs one `HalC2.Streams.Server` per active stream on this MC.

  A stream process starts on first use and stops after it has been idle with no
  subscribers, so inactive threads cost nothing but a row in the shell index.
  """

  use Supervisor

  alias HalC2.StreamState
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

  @doc "See `HalC2.Streams.Server.more/4`."
  defdelegate more(stream_id, pid, items, tag \\ nil), to: Server

  @doc "See `HalC2.Streams.Server.unsubscribe/3`."
  defdelegate unsubscribe(stream_id, pid, tag \\ nil), to: Server

  @doc "See `HalC2.Streams.Server.transact/3`."
  def transact(stream_id, stream_kind, fun),
    do: with_server(stream_id, &Server.transact(&1, stream_kind, fun))

  @doc """
  The stream's current state, started if needed. What walks its cold rows (a whole
  thread's rows, a kind's entities, the changes since an offset) takes `read/2`.
  """
  def state(stream_id), do: with_server(stream_id, &Server.state/1)

  @doc """
  Runs `fun` with the stream's current state, started if needed, its cold rows read
  as they were when the state was taken however the stream moves on
  (`HalC2.StreamState.read/2`). `fun` returns nothing that still reads them.
  """
  @spec read(String.t(), (StreamState.t() -> result)) :: result when result: term
  def read(stream_id, fun),
    do: stream_id |> with_server(&Server.read/1) |> StreamState.read(fun)

  @doc """
  `read/2` for a reader that leaves the stream as it found it: a stream not running
  is started for the read and stopped once it is done, unless something subscribed
  to it meanwhile. It is gone when this returns, so a sweep of every thread does not
  keep each one in memory until it idles out. One that something else starts at the
  same time without subscribing stops too, and starts again on its next use.
  """
  @spec read_once(String.t(), (StreamState.t() -> result)) :: result when result: term
  def read_once(stream_id, fun) do
    if running?(stream_id) do
      read(stream_id, fun)
    else
      {server, state} = with_server(stream_id, &{&1, Server.read(&1)})

      try do
        StreamState.read(state, fun)
      after
        release(server)
      end
    end
  end

  defp running?(stream_id) do
    case Registry.lookup(HalC2.Streams.Registry, stream_id) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  # Stops the stream if it is idle, and waits for it to be gone. One that went down
  # on its own meanwhile is gone too.
  defp release(pid) do
    ref = Process.monitor(pid)

    stopped? =
      try do
        Server.release(pid)
      catch
        :exit, _ -> true
      end

    if stopped?,
      do: receive(do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)),
      else: Process.demonitor(ref, [:flush])

    :ok
  end

  @doc "See `HalC2.Streams.Server.sequence/1`."
  def sequence(stream_id), do: with_server(stream_id, &Server.sequence/1)

  @doc "See `HalC2.Streams.Server.get/3`."
  def get(stream_id, kind, id), do: with_server(stream_id, &Server.get(&1, kind, id))

  @doc "See `HalC2.Streams.Server.flush_shell/1`."
  def flush_shell(stream_id), do: with_server(stream_id, &Server.flush_shell/1)

  @doc "Commits changes to a stream and fans them out to its subscribers."
  @spec commit(String.t(), HalC2.Store.stream_kind(), [HalC2.Store.change()]) ::
          {:ok, non_neg_integer}
  def commit(stream_id, stream_kind, changes),
    do: with_server(stream_id, &Server.commit(&1, stream_kind, changes))
end
