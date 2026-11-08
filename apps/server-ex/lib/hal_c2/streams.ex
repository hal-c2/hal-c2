defmodule HalC2.Streams do
  @moduledoc """
  Runs one `HalC2.Streams.Server` per active stream on this MC.

  A stream process starts on first use and stops after it has been idle with no
  subscribers, so inactive threads cost nothing but a row in the shell index.
  """

  use Supervisor

  require Logger

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

  @doc """
  Stops the stream's server if one runs, so its next use loads the stream from the
  store. For a writer that appended to the store behind it (an import): a server that
  held the stream from before would apply its next commit over the events it never
  saw, and snapshot that.
  """
  @spec stop(String.t()) :: :ok
  def stop(stream_id) do
    if Process.whereis(HalC2.Streams.Registry) do
      for {pid, _} <- Registry.lookup(HalC2.Streams.Registry, stream_id),
          do: DynamicSupervisor.terminate_child(HalC2.Streams.Supervisor, pid)
    end

    :ok
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

  @doc """
  See `HalC2.Streams.Server.transact/3`. Inside `unrecorded/2` for the stream, `fun`
  decides against the stream as it stands and its changes are dropped; for another
  stream, changes the store refuses are dropped the same way.
  """
  def transact(stream_id, stream_kind, fun) do
    if unrecorded?(stream_id) do
      dry_transact(stream_id, fun)
    else
      with_server(stream_id, &Server.transact(&1, stream_kind, fun))
    end
  rescue
    error in HalC2.Streams.Unrecorded ->
      if dry?(),
        do: refused(stream_id, error, fn -> dry_transact(stream_id, fun) end),
        else: reraise(error, __STACKTRACE__)
  end

  defp dry_transact(stream_id, fun) do
    {_changes, reply} = fun.(state(stream_id))
    reply
  end

  @doc """
  Runs `fun` with this process's commits to `stream_id` dropped, not recorded: for a
  provider runtime whose turn the store failed to record (`HalC2.Orchestration.Unrecorded`),
  which goes on driving the turn to its end while what ends it is recorded apart. A
  commit to another stream (a subagent's thread) the store refuses meanwhile is dropped
  too, alone, so it cannot keep the runtime from stopping the turn or handing over its
  end.
  """
  def unrecorded(stream_id, fun) do
    previous = Process.put(:hal_c2_unrecorded_stream, stream_id)

    try do
      fun.()
    after
      if previous,
        do: Process.put(:hal_c2_unrecorded_stream, previous),
        else: Process.delete(:hal_c2_unrecorded_stream)
    end
  end

  defp unrecorded?(stream_id), do: Process.get(:hal_c2_unrecorded_stream) == stream_id
  defp dry?, do: Process.get(:hal_c2_unrecorded_stream) != nil

  defp refused(stream_id, error, dropped) do
    Logger.warning("dropped changes to #{stream_id} the store refused: #{error.message}")
    dropped.()
  end

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

  @doc "See `HalC2.Streams.Server.sequence/1`."
  def sequence(stream_id), do: with_server(stream_id, &Server.sequence/1)

  @doc "See `HalC2.Streams.Server.get/3`."
  def get(stream_id, kind, id), do: with_server(stream_id, &Server.get(&1, kind, id))

  @doc "See `HalC2.Streams.Server.flush_shell/1`."
  def flush_shell(stream_id), do: with_server(stream_id, &Server.flush_shell/1)

  @doc "Commits changes to a stream and fans them out to its subscribers."
  @spec commit(String.t(), HalC2.Store.stream_kind(), [HalC2.Store.change()]) ::
          {:ok, non_neg_integer}
  def commit(stream_id, stream_kind, changes) do
    if unrecorded?(stream_id),
      do: {:ok, sequence(stream_id)},
      else: with_server(stream_id, &Server.commit(&1, stream_kind, changes))
  rescue
    error in HalC2.Streams.Unrecorded ->
      if dry?(),
        do: refused(stream_id, error, fn -> {:ok, sequence(stream_id)} end),
        else: reraise(error, __STACKTRACE__)
  end
end
