defmodule HalC2.Links.Rows do
  @moduledoc """
  What this node knows of a linked environment's shell: its nodes and their project
  and thread rows, as the link's own `shell` subscription reports them
  (`HalC2.Links`). Node names are the linked environment's, kept as strings and apart
  from this cluster's.

  `apply/2` folds in one frame of that subscription and returns what changed, as the
  messages `HalC2.Shell` sends its subscribers (`{:rows, node, [{id, {kind, row}}]}`,
  `{:environment, node, descriptor}`, `{:node, node, online?}`), so clients get
  deltas: a fresh snapshot after the link reconnects yields only the rows that differ.
  """

  defstruct nodes: %{}, rows: %{}

  @type change ::
          {:rows, String.t(), [{String.t(), {String.t(), map}}]}
          | {:environment, String.t(), map}
          | {:node, String.t(), boolean}

  def new, do: %__MODULE__{}

  @spec apply(%__MODULE__{}, map) :: {%__MODULE__{}, [change]}
  def apply(state, %{"t" => "shell", "nodes" => nodes, "rows" => rows}) do
    {state, node_changes} =
      Enum.reduce(nodes, {state, []}, fn %{"node" => node} = entry, {state, acc} ->
        {state, env} = environment(state, node, entry["environment"])
        {state, online} = online(state, node, entry["online"] == true)
        {state, acc ++ env ++ online}
      end)

    by_node = Enum.group_by(rows, &hd/1, fn [_node, id, kind, row] -> {id, {kind, row}} end)

    Enum.reduce(by_node, {state, node_changes}, fn {node, rows}, {state, acc} ->
      {state, changes} = put_rows(state, node, rows)
      {state, acc ++ changes}
    end)
  end

  def apply(state, %{"t" => "shell.rows", "node" => node, "rows" => rows}),
    do: put_rows(state, node, for([id, kind, row] <- rows, do: {id, {kind, row}}))

  def apply(state, %{"t" => "shell.environment", "node" => node, "environment" => env}),
    do: environment(state, node, env)

  def apply(state, %{"t" => "shell.node", "node" => node, "online" => online}),
    do: online(state, node, online == true)

  def apply(state, _frame), do: {state, []}

  @doc "The link dropped: every node is offline, and every row stays as it was."
  @spec offline(%__MODULE__{}) :: {%__MODULE__{}, [change]}
  def offline(state) do
    Enum.reduce(Map.keys(state.nodes), {state, []}, fn node, {state, acc} ->
      {state, changes} = online(state, node, false)
      {state, acc ++ changes}
    end)
  end

  @doc ~s|The `"nodes"` and `"rows"` a link carries in a client's shell snapshot.|
  @spec listing(%__MODULE__{}) :: map
  def listing(state) do
    %{
      "nodes" =>
        for({_node, entry} <- Enum.sort(state.nodes), entry["environment"] != nil, do: entry),
      "rows" => for({{node, id}, {kind, row}} <- state.rows, do: [node, id, kind, row])
    }
  end

  defp put_rows(state, node, rows) do
    changed = Enum.reject(rows, fn {id, kind_row} -> state.rows[{node, id}] == kind_row end)
    state = %{state | rows: Enum.into(changed, state.rows, fn {id, kr} -> {{node, id}, kr} end)}
    {state, if(changed == [], do: [], else: [{:rows, node, changed}])}
  end

  defp environment(state, node, env) do
    case state.nodes[node] do
      %{"environment" => ^env} ->
        {state, []}

      entry ->
        entry = Map.put(entry || %{"node" => node, "online" => false}, "environment", env)
        {put_in(state.nodes[node], entry), [{:environment, node, env}]}
    end
  end

  defp online(state, node, online) do
    case state.nodes[node] do
      %{"online" => ^online} ->
        {state, []}

      entry ->
        entry = Map.put(entry || %{"node" => node, "environment" => nil}, "online", online)
        {put_in(state.nodes[node], entry), [{:node, node, online}]}
    end
  end
end
