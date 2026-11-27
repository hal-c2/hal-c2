defmodule HalC2.Plugins.Host.ThreadRelay do
  @moduledoc """
  The process behind `HalC2.Plugins.Host.watch_threads/1`: it hears `HalC2.Shell`'s
  row changes and sends the caller `{:hal_c2_threads, rows}`, this MC's changed
  thread rows plus the threads of a project whose row changed. It waits on
  `HalC2.Pump` and ends when the caller does.
  """

  @tags %{hal_c2_shell: true, DOWN: true}

  @doc "Starts a relay to `caller`, linked to the calling process."
  @spec start_link(pid) :: pid
  def start_link(caller), do: HalC2.Pump.spawn_link(__MODULE__, %{caller: caller, ref: nil})

  @doc false
  # `HalC2.Pump`'s step: the caller is watched first, then each Shell change relayed.
  def step(%{caller: caller} = state, :start),
    do: {:receive, @tags, :infinity, %{state | ref: Process.monitor(caller)}}

  def step(%{ref: ref}, {:message, {:DOWN, ref, :process, _pid, _reason}}), do: {:done, :ok}

  def step(state, {:message, {:hal_c2_shell, {:rows, mc, rows}}}) when mc == node() do
    case for({_id, {"thread", row}} <- rows, do: row) ++ retitled(rows) do
      [] -> :ok
      rows -> send(state.caller, {:hal_c2_threads, with_project_titles(rows)})
    end

    {:receive, @tags, :infinity, state}
  end

  def step(state, {:message, _other}), do: {:receive, @tags, :infinity, state}

  @doc "Thread rows with their project's `\"projectTitle\"`, as this MC has it."
  def with_project_titles(rows) do
    titles =
      for project <- rows |> Enum.map(& &1["projectId"]) |> Enum.uniq(),
          is_binary(project),
          into: %{} do
        case HalC2.Shell.row(node(), project) do
          {"project", row} -> {project, row["title"]}
          _ -> {project, nil}
        end
      end

    Enum.map(rows, &Map.put(&1, "projectTitle", titles[&1["projectId"]]))
  end

  # A project's row changing (a rename, say) changes the `"projectTitle"` of its
  # threads, so those come again; the ones among `rows` already come.
  defp retitled(rows) do
    projects = for {id, {"project", _}} <- rows, into: MapSet.new(), do: id
    changed = for {id, {"thread", _}} <- rows, into: MapSet.new(), do: id

    if MapSet.size(projects) == 0 do
      []
    else
      for {{_mc, id}, {"thread", row}} <- HalC2.Shell.query(mc: :local, kind: "thread"),
          row["deletedAt"] == nil,
          MapSet.member?(projects, row["projectId"]) and not MapSet.member?(changed, id),
          do: row
    end
  end
end
