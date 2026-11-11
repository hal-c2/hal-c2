defmodule HalC2.Orchestration.NewThread do
  @moduledoc """
  What a new thread in a project runs on when nothing picked it: this MC's defaults.

  The model is the project's override in settings, else the project's own
  `defaultModelSelection`, else the settings default, each only while its provider is
  on for the project; else the first model of the first provider that can start a
  turn. The runtime mode is the project's override, else the settings default, else
  full access. `complete/1` records them on a thread being created, so no thread runs
  on a model it does not name; project rows carry them (`newThreadModelSelection`,
  `newThreadRuntimeMode`) so a client drafting a thread on any machine shows that
  machine's defaults (`HalC2.Shell`).
  """

  @doc """
  The defaults of a new thread in `project` (a project row, or nil for none):
  `%{"modelSelection" => selection | nil, "runtimeMode" => mode}`. The selection is
  nil only when no provider can run at all.
  """
  @spec defaults(map | nil) :: %{String.t() => term}
  def defaults(project), do: defaults(project, :read)

  @doc """
  `defaults/1` with the provider list given (`HalC2.Environment.providers/0`, read
  once for many projects), or nil to leave a project with no default of its own
  without a model rather than read it.
  """
  @spec defaults(map | nil, [map] | nil | :read) :: %{String.t() => term}
  def defaults(project, providers) do
    settings = HalC2.Settings.settings()
    project_id = project && project["id"]
    resolved = HalC2.Settings.resolve(settings, project_id)

    configured =
      [
        get_in(settings, ["projectSettingsOverrides", project_id || "", "defaultModelSelection"]),
        project && project["defaultModelSelection"],
        settings["defaultModelSelection"]
      ]
      |> Enum.find(&on?(&1, settings, project_id))

    %{
      "modelSelection" => configured || first_ready(project_id, providers),
      "runtimeMode" => resolved["defaultRuntimeMode"] || "full-access"
    }
  end

  @doc """
  A thread's creation `input` with what it runs on filled in where it names nothing,
  each field alone. What it does name is kept as it is. Both come from the settings as
  they are now, so a create right after a settings change gets the new default
  (`defaults/2`). A model that settings do not name is the first one that can run,
  which the project's row in the shell already has (`HalC2.Shell`) while its provider
  is on: the provider list probes provider CLIs and is read only when the row has none.
  """
  @spec complete(map) :: map
  def complete(input) do
    if is_map(input["modelSelection"]) and is_binary(input["runtimeMode"]) do
      input
    else
      row = project(input["projectId"])
      configured = defaults(row, nil)

      input
      |> fill("modelSelection", fn ->
        configured["modelSelection"] || first_ready_from_row(row)
      end)
      |> fill("runtimeMode", fn -> configured["runtimeMode"] end)
    end
  end

  defp fill(input, key, default) do
    if input[key] == nil, do: Map.put(input, key, default.()), else: input
  end

  # A null selection on the row is known: no provider can run. One whose provider has
  # been turned off since the row was made is not used.
  defp first_ready_from_row(row) do
    case row do
      %{"newThreadModelSelection" => nil} ->
        nil

      %{"newThreadModelSelection" => selection} = row ->
        if on?(selection, HalC2.Settings.settings(), row["id"]),
          do: selection,
          else: defaults(row)["modelSelection"]

      row ->
        defaults(row)["modelSelection"]
    end
  end

  defp on?(%{"instanceId" => instance}, settings, project_id) when is_binary(instance),
    do: HalC2.Settings.provider_on?(settings, project_id, instance)

  defp on?(_selection, _settings, _project_id), do: false

  defp first_ready(_project_id, nil), do: nil

  defp first_ready(project_id, providers) do
    if(providers == :read,
      do: HalC2.Settings.providers_for(project_id),
      else: HalC2.Settings.providers_for(project_id, providers)
    )
    |> Enum.find_value(fn provider ->
      with [] <- HalC2.Mcp.Tools.Threads.constraints(provider),
           %{"slug" => slug} <- get_in(provider, ["models", Access.at(0)]) do
        %{"instanceId" => provider["instanceId"], "model" => slug}
      else
        _ -> nil
      end
    end)
  end

  defp project(nil), do: nil

  defp project(project_id) do
    case HalC2.Shell.row(node(), project_id) do
      {"project", row} -> row
      _ -> %{"id" => project_id}
    end
  end
end
