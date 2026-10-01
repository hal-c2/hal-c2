defmodule HalC2.Links.Rows do
  @moduledoc """
  What this MC knows of a linked environment's shell: its MCs and their project
  and thread rows, as the link's own `shell` subscription reports them
  (`HalC2.Links`). MC names are the linked environment's, kept as strings and apart
  from this cluster's.

  `apply/2` folds in one frame of that subscription and returns what changed, as the
  messages `HalC2.Shell` sends its subscribers (`{:rows, mc, [{id, {kind, row}}]}`,
  `{:environment, mc, descriptor}`, `{:mc, mc, online?}`), so clients get
  deltas: a fresh snapshot after the link reconnects yields only the rows that differ.
  """

  defstruct mcs: %{}, rows: %{}

  @type change ::
          {:rows, String.t(), [{String.t(), {String.t(), map}}]}
          | {:environment, String.t(), map}
          | {:mc, String.t(), boolean}

  def new, do: %__MODULE__{}

  @spec apply(%__MODULE__{}, map) :: {%__MODULE__{}, [change]}
  def apply(state, %{"t" => "shell", "mcs" => mcs, "rows" => rows}) do
    {state, mc_changes} =
      Enum.reduce(mcs, {state, []}, fn %{"mc" => mc} = entry, {state, acc} ->
        {state, env} = environment(state, mc, entry["environment"])
        {state, online} = online(state, mc, entry["online"] == true)
        {state, acc ++ env ++ online}
      end)

    by_mc = Enum.group_by(rows, &hd/1, fn [_mc, id, kind, row] -> {id, {kind, row}} end)

    Enum.reduce(by_mc, {state, mc_changes}, fn {mc, rows}, {state, acc} ->
      {state, changes} = put_rows(state, mc, rows)
      {state, acc ++ changes}
    end)
  end

  def apply(state, %{"t" => "shell.rows", "mc" => mc, "rows" => rows}),
    do: put_rows(state, mc, for([id, kind, row] <- rows, do: {id, {kind, row}}))

  def apply(state, %{"t" => "shell.environment", "mc" => mc, "environment" => env}),
    do: environment(state, mc, env)

  def apply(state, %{"t" => "shell.mc", "mc" => mc, "online" => online}),
    do: online(state, mc, online == true)

  def apply(state, _frame), do: {state, []}

  @doc "The link dropped: every MC is offline, and every row stays as it was."
  @spec offline(%__MODULE__{}) :: {%__MODULE__{}, [change]}
  def offline(state) do
    Enum.reduce(Map.keys(state.mcs), {state, []}, fn mc, {state, acc} ->
      {state, changes} = online(state, mc, false)
      {state, acc ++ changes}
    end)
  end

  @doc ~s|The `"mcs"` and `"rows"` a link carries in a client's shell snapshot.|
  @spec listing(%__MODULE__{}) :: map
  def listing(state) do
    %{
      "mcs" => for({_mc, entry} <- Enum.sort(state.mcs), entry["environment"] != nil, do: entry),
      "rows" => for({{mc, id}, {kind, row}} <- state.rows, do: [mc, id, kind, row])
    }
  end

  defp put_rows(state, mc, rows) do
    changed = Enum.reject(rows, fn {id, kind_row} -> state.rows[{mc, id}] == kind_row end)
    state = %{state | rows: Enum.into(changed, state.rows, fn {id, kr} -> {{mc, id}, kr} end)}
    {state, if(changed == [], do: [], else: [{:rows, mc, changed}])}
  end

  defp environment(state, mc, env) do
    case state.mcs[mc] do
      %{"environment" => ^env} ->
        {state, []}

      entry ->
        entry = Map.put(entry || %{"mc" => mc, "online" => false}, "environment", env)
        {put_in(state.mcs[mc], entry), [{:environment, mc, env}]}
    end
  end

  defp online(state, mc, online) do
    case state.mcs[mc] do
      %{"online" => ^online} ->
        {state, []}

      entry ->
        entry = Map.put(entry || %{"mc" => mc, "environment" => nil}, "online", online)
        {put_in(state.mcs[mc], entry), [{:mc, mc, online}]}
    end
  end
end
