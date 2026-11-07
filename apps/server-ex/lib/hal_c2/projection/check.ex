defmodule HalC2.Projection.Check do
  @moduledoc """
  Checks what the MC derives from its log against the log, and derives it again:
  each project's and thread's sidebar row, and the folded state its snapshot holds
  (with the cold rows written with it and the messages indexed from it).

  Both run with no streams on the store, as the doctor runs them (`HalC2.Doctor`):
  a running stream holds its state in memory and would write over a rebuild.
  """

  alias HalC2.{Projection, Search, Store, StreamState}

  @type problem ::
          {:missing, String.t()}
          | {:unexpected, String.t()}
          | {:unreadable, String.t()}
          | {:unreadable_source, source :: String.t(), fork :: String.t()}
          | {:behind, String.t(), at :: non_neg_integer, log :: pos_integer}
          | {:format, String.t(), version :: term}

  @doc """
  What is wrong with the store's projections, by stream, `[]` when nothing is. Reads
  each stream from its snapshot and the events after it, not its whole log.
  """
  @spec run(String.t()) :: [problem]
  def run(path) do
    shells = Map.new(Store.shell_entries(path), fn {id, _kind, seq, row} -> {id, {seq, row}} end)

    streams =
      for kind <- ~w(thread project),
          {id, last} <- Store.stream_ends(path, kind),
          do: {id, last, read(path, id, kind)}

    status = Map.new(streams, fn {id, _, read} -> {id, read} end)

    problems =
      for {id, last, read} <- streams,
          problem <- problems(id, last, read, Map.get(shells, id), status),
          do: problem

    unexpected =
      for {id, _} <- shells, not Map.has_key?(status, id), do: {:unexpected, id}

    Enum.sort(problems ++ unexpected)
  end

  # A stream as its snapshot and the events after it fold: `{:ok, expects_row?,
  # fork source}`, `:unreadable`, or `{:format, version}` for a snapshot in a shape this
  # MC does not know.
  defp read(path, id, kind) do
    case snapshot_version(path, id) do
      :unreadable ->
        :unreadable

      nil ->
        fold(path, id, kind)

      v ->
        if is_integer(v) and v <= StreamState.version(),
          do: fold(path, id, kind),
          else: {:format, v}
    end
  end

  defp snapshot_version(path, id) do
    case Store.get_snapshot(path, id) do
      nil -> nil
      {_seq, %{v: v}} -> v
      {_seq, _other} -> :unreadable
    end
  rescue
    ArgumentError -> :unreadable
  end

  defp fold(path, id, kind) do
    state = StreamState.load(path, id)
    entity = StreamState.get(state, kind)[id]
    source = if kind == "thread", do: get_in(entity || %{}, ["forkedFrom", "threadId"])
    {:ok, entity != nil, source}
  rescue
    _ -> :unreadable
  end

  defp problems(id, _last, :unreadable, _shell, _status), do: [{:unreadable, id}]
  defp problems(id, _last, {:format, v}, _shell, _status), do: [{:format, id, v}]

  defp problems(id, last, {:ok, expects?, source}, shell, status) do
    row =
      case shell do
        nil -> nil
        {seq, json} -> if(match?({:ok, %{}}, JSON.decode(json)), do: seq, else: :unreadable)
      end

    fork =
      if source && Map.get(status, source) == :unreadable,
        do: [{:unreadable_source, source, id}],
        else: []

    fork ++
      cond do
        row == :unreadable -> [{:unreadable, id}]
        expects? and row == nil -> [{:missing, id}]
        not expects? and row != nil -> [{:unexpected, id}]
        expects? and row < last -> [{:behind, id, row, last}]
        true -> []
      end
  end

  @doc """
  Derives every project's and thread's projections again from its log (`:all`), or
  those of the streams named: forgets them (`HalC2.Store.drop_projections/2`), folds the
  log as the stream's own process would, writing its snapshot and cold rows, and
  writes its sidebar row and indexes its messages. Returns the streams rebuilt.
  """
  @spec rebuild(GenServer.server(), :all | [String.t()]) :: [String.t()]
  def rebuild(store \\ Store, ids \\ :all) do
    path = Store.path(store)

    if Process.whereis(HalC2.Streams) && path == Store.path(),
      do: raise(ArgumentError, "projections are rebuilt with no streams running on the store")

    ids =
      if ids == :all,
        do: for(kind <- ~w(thread project), {id, _} <- Store.stream_ends(path, kind), do: id),
        else: ids

    for id <- ids do
      :ok = Store.drop_projections(store, id)
      state = StreamState.load(path, id, store: store, max_legacy: :infinity)

      with {kind, _} = row <- Projection.row(path, id, state) do
        :ok = Store.put_shell(store, id, state.seq, row)
        if kind == "thread", do: Search.index_thread(id, state)
      end

      id
    end
  end

  @doc "What a problem means, in a line for the doctor's report."
  @spec describe(problem) :: String.t()
  def describe({:missing, id}), do: "#{id} has no sidebar row"
  def describe({:unexpected, id}), do: "#{id} has a sidebar row but its log never created it"
  def describe({:unreadable, id}), do: "#{id}'s projection can no longer be read"

  def describe({:unreadable_source, source, fork}),
    do: "#{fork} is a fork of #{source}, whose projection can no longer be read"

  def describe({:behind, id, at, log}),
    do: "#{id}'s sidebar row is at sequence #{at}, its log at #{log}"

  def describe({:format, id, v}),
    do:
      "#{id}'s snapshot is in projection format #{inspect(v)}, this MC writes #{StreamState.version()}"

  @doc "The streams a problem says to rebuild."
  @spec streams([problem]) :: [String.t()]
  def streams(problems) do
    problems
    |> Enum.flat_map(fn
      {:unreadable_source, source, fork} -> [source, fork]
      problem -> [elem(problem, 1)]
    end)
    |> Enum.uniq()
  end
end
