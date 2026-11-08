defmodule HalC2.CursorSkillsPropTest do
  @moduledoc """
  `HalC2.Acp.CursorSkills` workspace snapshots against a model of their
  promise: a workspace refresh replaces that workspace's snapshot with the
  skills then on disk (sorted by name, known by folder), a failed read
  (a skill folder that cannot be read) keeps the previous snapshot and
  reports the failure, one workspace's refresh never touches another's,
  and forgetting what was probed (`HalC2.Acp.forget/1`) leaves snapshots
  alone — only the next workspace refresh replaces them — while dropping a
  removed instance (`HalC2.Acp.drop/1`) erases them, and a refresh whose scan
  began before a drop cannot write its snapshot back after it.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Acp.CursorSkills

  @moduletag timeout: :infinity
  @instance "cursor"
  @cwds [:a, :b]
  @names ["deploy", "review", "test"]

  property "workspace snapshots follow refresh, read and forget in any order",
    numtests: HalC2.Prop.numtests(50),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()

        try do
          {history, state, result} = run_commands(__MODULE__, cmds)

          if result != :ok, do: IO.puts(HalC2.Prop.report(cmds, history, state, result))
          result == :ok
        after
          stop_case()
        end
        |> aggregate(command_names(cmds))
      end
    end
  end

  def initial_state, do: %{disk: %{}, snapshots: %{}, broken: MapSet.new()}

  def command(_state) do
    frequency([
      {4, {:call, __MODULE__, :write, [oneof(@cwds), oneof(@names)]}},
      {2, {:call, __MODULE__, :remove, [oneof(@cwds), oneof(@names)]}},
      {1, {:call, __MODULE__, :break, [oneof(@cwds)]}},
      {1, {:call, __MODULE__, :mend, [oneof(@cwds)]}},
      {4, {:call, __MODULE__, :refresh, [oneof(@cwds)]}},
      {3, {:call, __MODULE__, :read, []}},
      {1, {:call, __MODULE__, :forget, []}},
      {1, {:call, __MODULE__, :drop, []}},
      {1, {:call, __MODULE__, :refresh_across_drop, [oneof(@cwds)]}}
    ])
  end

  def precondition(state, {:call, _, :break, [cwd]}), do: not MapSet.member?(state.broken, cwd)
  def precondition(state, {:call, _, :mend, [cwd]}), do: MapSet.member?(state.broken, cwd)
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :write, [cwd, name]}),
    do: %{state | disk: Map.update(state.disk, cwd, [name], &Enum.uniq([name | &1]))}

  def next_state(state, _result, {:call, _, :remove, [cwd, name]}),
    do: %{state | disk: Map.update(state.disk, cwd, [], &List.delete(&1, name))}

  def next_state(state, _result, {:call, _, :break, [cwd]}),
    do: %{state | broken: MapSet.put(state.broken, cwd)}

  def next_state(state, _result, {:call, _, :mend, [cwd]}),
    do: %{state | broken: MapSet.delete(state.broken, cwd)}

  def next_state(state, _result, {:call, _, :refresh, [cwd]}) do
    if MapSet.member?(state.broken, cwd) do
      state
    else
      %{state | snapshots: Map.put(state.snapshots, cwd, Enum.sort(state.disk[cwd] || []))}
    end
  end

  def next_state(state, _result, {:call, _, :drop, []}), do: %{state | snapshots: %{}}

  def next_state(state, _result, {:call, _, :refresh_across_drop, [_cwd]}),
    do: %{state | snapshots: %{}}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :refresh, [cwd]}, result) do
    if MapSet.member?(state.broken, cwd) do
      match?({:error, _}, result) and snapshots_now() == model_snapshots(state)
    else
      result == :ok and
        snapshots_now() ==
          Map.put(model_snapshots(state), cwd, Enum.sort(state.disk[cwd] || []))
    end
  end

  def postcondition(state, {:call, _, :read, []}, result),
    do: result == model_snapshots(state)

  def postcondition(state, {:call, _, :forget, []}, result),
    do: result == model_snapshots(state)

  def postcondition(state, {:call, _, :drop, []}, result),
    do: result == %{} and model_snapshots(%{state | snapshots: %{}}) == %{}

  # The refresh outlived the instance: it reports the drop and keeps nothing.
  def postcondition(_state, {:call, _, :refresh_across_drop, [_cwd]}, result),
    do: result == {{:error, :dropped}, %{}}

  def postcondition(_state, _call, result), do: result == :ok

  # --- the commands, against the real discovery and snapshot store ------------

  def write(cwd, name) do
    dir = Path.join([dir_of(cwd), ".cursor", "skills", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\n---\nDo #{name}.\n")
    :ok
  end

  def remove(cwd, name) do
    File.rm_rf!(Path.join([dir_of(cwd), ".cursor", "skills", name]))
    :ok
  end

  def break(cwd) do
    locked = locked_of(cwd)
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o000)
    :ok
  end

  def mend(cwd) do
    locked = locked_of(cwd)
    File.chmod!(locked, 0o755)
    File.rm_rf!(locked)
    :ok
  end

  def refresh(cwd), do: CursorSkills.refresh_workspace(@instance, dir_of(cwd))

  def read, do: snapshots_now()

  def forget do
    HalC2.Acp.forget(@instance)
    snapshots_now()
  end

  def drop do
    HalC2.Acp.drop(@instance)
    snapshots_now()
  end

  # A refresh that read the epoch, scanned, and met a drop before it could write.
  def refresh_across_drop(cwd) do
    epoch = HalC2.Acp.workspaces_epoch(@instance)
    HalC2.Acp.drop(@instance)

    snapshot = %{"checkedAt" => "t", "slashCommands" => [], "skills" => []}

    result =
      case HalC2.Acp.put_workspace(@instance, dir_of(cwd), snapshot, epoch) do
        :dropped -> {:error, :dropped}
        other -> other
      end

    {result, snapshots_now()}
  end

  # The snapshots the entry would show, keyed back to this model's cwd names.
  defp snapshots_now do
    dirs = Process.get({__MODULE__, :dirs})

    Map.new(CursorSkills.workspaces(@instance), fn %{"cwd" => dir, "skills" => skills} ->
      {key, _} = Enum.find(dirs, fn {_key, path} -> path == dir end)
      {key, Enum.map(skills, & &1["name"])}
    end)
  end

  defp model_snapshots(state), do: state.snapshots

  defp dir_of(cwd), do: Process.get({__MODULE__, :dirs})[cwd]

  defp locked_of(cwd), do: Path.join([dir_of(cwd), ".cursor", "skills", "locked"])

  # --- one case -----------------------------------------------------------------

  defp start_case do
    home = HalC2.Prop.scratch_home("cursor-skills")
    user = Path.join(home, "user")
    File.mkdir_p!(user)

    dirs = Map.new(@cwds, fn cwd -> {cwd, Path.join(home, "ws-#{cwd}")} end)
    for {_cwd, dir} <- dirs, do: File.mkdir_p!(dir)
    Process.put({__MODULE__, :dirs}, dirs)

    Process.put({__MODULE__, :previous_home}, System.get_env("HOME"))
    System.put_env("HOME", user)
    :persistent_term.erase({HalC2.Acp, @instance, :workspaces})

    HalC2.Prop.start_services([HalC2.Settings])
    :ok
  end

  defp stop_case do
    for cwd <- @cwds do
      locked = locked_of(cwd)
      if File.exists?(locked), do: File.chmod(locked, 0o755)
    end

    :persistent_term.erase({HalC2.Acp, @instance, :workspaces})

    case Process.delete({__MODULE__, :previous_home}) do
      nil -> System.delete_env("HOME")
      previous -> System.put_env("HOME", previous)
    end

    HalC2.Prop.stop_services()
  end
end
