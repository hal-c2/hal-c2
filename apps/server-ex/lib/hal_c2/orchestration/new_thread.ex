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
  A thread's creation `input` with what it runs on filled in where it names nothing:
  the defaults of its project (`defaults/1`). What it does name is kept as it is.
  """
  @spec complete(map) :: map
  def complete(input) do
    if is_map(input["modelSelection"]) and is_binary(input["runtimeMode"]) do
      input
    else
      defaults = defaults(project(input["projectId"]))

      input
      |> Map.update("modelSelection", defaults["modelSelection"], &(&1 || defaults["modelSelection"]))
      |> Map.update("runtimeMode", defaults["runtimeMode"], &(&1 || defaults["runtimeMode"]))
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
