defmodule HalC2.ProjectDeleteOverridesPropTest do
  @moduledoc """
  Deleting a project and its `projectSettingsOverrides` entry (`HalC2.Projects`
  over `HalC2.Settings`): two projects and one id that never was a project have
  overrides written for them (as a delete that stopped after tombstoning would
  leave one behind), are updated and are deleted, in any order.

  The invariant is that a deleted project has no overrides entry after any
  delete of it: the delete that tombstones it drops the entry, and a repeated
  delete, though refused as unknown, drops a leftover one. An update of a
  deleted project is refused too and drops nothing, and deleting an id that
  never was a project drops nothing either. Restarts of `HalC2.Settings` and
  `HalC2.Streams` between steps change none of that: the overrides and the
  tombstones are read back from disk.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @projects ~w(p1 p2)
  @ids @projects ++ ["nowhere"]

  property "a deleted project has no overrides entry after any delete of it",
    numtests: HalC2.Prop.numtests(100),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("project_delete_overrides")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Settings,
          HalC2.Streams,
          HalC2.Shell
        ])

        for id <- @projects do
          root = Path.join(home, "work-" <> id)
          File.mkdir_p!(root)

          {:ok, _} =
            HalC2.Projects.mutate(%{
              "type" => "project.create",
              "projectId" => id,
              "workspaceRoot" => root
            })
        end

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # live and deleted: of the projects the case created; overrides: the ids with a
  # `projectSettingsOverrides` entry.
  def initial_state,
    do: %{live: MapSet.new(@projects), deleted: MapSet.new(), overrides: MapSet.new()}

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :put_override, [oneof(@ids)]}},
      {4, {:call, __MODULE__, :delete_project, [oneof(@ids)]}},
      {2, {:call, __MODULE__, :update_project, [oneof(@ids)]}},
      {2, {:call, __MODULE__, :read_override, [oneof(@ids)]}},
      {1, {:call, __MODULE__, :restart, [oneof([HalC2.Settings, HalC2.Streams])]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :put_override, [id]}),
    do: %{state | overrides: MapSet.put(state.overrides, id)}

  def next_state(state, _result, {:call, _, :delete_project, [id]}) do
    cond do
      MapSet.member?(state.live, id) ->
        %{
          state
          | live: MapSet.delete(state.live, id),
            deleted: MapSet.put(state.deleted, id),
            overrides: MapSet.delete(state.overrides, id)
        }

      MapSet.member?(state.deleted, id) ->
        %{state | overrides: MapSet.delete(state.overrides, id)}

      true ->
        state
    end
  end

  def next_state(state, _result, _call), do: state

  def postcondition(_state, {:call, _, :put_override, [_id]}, present?), do: present?

  def postcondition(_state, {:call, _, :restart, [_service]}, result), do: result == :ok

  def postcondition(state, {:call, _, :read_override, [id]}, present?),
    do: present? == MapSet.member?(state.overrides, id)

  def postcondition(state, {:call, _, :update_project, [id]}, {reply, present?}) do
    refused? = not MapSet.member?(state.live, id)

    reply_ok? =
      if refused?,
        do: reply == {:error, "unknown project #{id}"},
        else: match?({:ok, _}, reply)

    reply_ok? and present? == MapSet.member?(state.overrides, id)
  end

  def postcondition(state, {:call, _, :delete_project, [id]}, {reply, present?}) do
    cond do
      MapSet.member?(state.live, id) ->
        match?({:ok, %{"deletedAt" => at}} when is_binary(at), reply) and not present?

      MapSet.member?(state.deleted, id) ->
        reply == {:error, "unknown project #{id}"} and not present?

      true ->
        reply == {:error, "unknown project #{id}"} and
          present? == MapSet.member?(state.overrides, id)
    end
  end

  # --- the real thing -----------------------------------------------------------

  def put_override(id) do
    {:ok, _} =
      HalC2.Settings.update(fn settings ->
        overrides =
          Map.put(settings["projectSettingsOverrides"] || %{}, id, %{"defaultAutoPull" => true})

        Map.put(settings, "projectSettingsOverrides", overrides)
      end)

    read_override(id)
  end

  def delete_project(id) do
    reply = HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => id})
    {reply, read_override(id)}
  end

  def update_project(id) do
    reply =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => id,
        "title" => "Title #{id}"
      })

    {reply, read_override(id)}
  end

  # A restart keeps the model: what the service had stored must come back.
  def restart(service), do: HalC2.Prop.restart_service(service)

  def read_override(id),
    do: Map.has_key?(HalC2.Settings.settings()["projectSettingsOverrides"] || %{}, id)
end
