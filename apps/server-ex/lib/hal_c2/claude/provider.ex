defmodule HalC2.Claude.Provider do
  @moduledoc """
  The Claude entry in this node's `ServerConfig.providers`, present when the `claude`
  CLI is on the node's PATH. Models are the Claude catalog of the bundled model manifest,
  read at compile time, less those the installed CLI is too old to run.
  """

  @manifest Path.expand("../../../../server/src/provider/model-manifest.json", __DIR__)
  @external_resource @manifest
  @catalog @manifest |> File.read!() |> JSON.decode!() |> get_in(["providers", "claudeAgent"])

  @spec entry() :: map | nil
  def entry do
    with [executable | _] <- Application.get_env(:hal_c2, :claude_command, ["claude"]),
         path when is_binary(path) <- System.find_executable(executable) do
      %{
        "instanceId" => "claudeAgent",
        "driver" => "claudeAgent",
        # Turned off in settings (`providers.claudeAgent.enabled`), it stays listed so it can be
        # turned back on; clients leave it out of the model picker.
        "enabled" =>
          get_in(HalC2.Settings.settings(), ["providers", "claudeAgent", "enabled"]) != false,
        "installed" => true,
        "version" => version(path),
        "versionAdvisory" => HalC2.ProviderUpdates.advisory("claudeAgent", path, version(path)),
        "status" => "ready",
        "availability" => "available",
        "auth" => %{"status" => "authenticated"},
        "checkedAt" => HalC2.Orchestration.Entities.now(),
        "models" => models(version(path)),
        "slashCommands" => [
          %{
            "name" => "compact",
            "description" => "Summarize the conversation and reduce context usage"
          }
        ],
        "skills" => []
      }
    else
      _ -> nil
    end
  end

  # The catalog's models the CLI at `version` can run, in manifest order.
  defp models(version) do
    for model <- @catalog["models"], runs?(model, version) do
      %{
        "slug" => model["slug"],
        "name" => model["name"],
        "aliases" => model["aliases"] || [],
        "isCustom" => false,
        "isDefault" => model["slug"] == @catalog["defaults"]["chat"],
        "isLegacy" => model["status"] == "legacy",
        # Reasoning, fast mode and context window need the session to pass them to the CLI.
        "capabilities" => nil
      }
      |> then(&if model["badge"], do: Map.put(&1, "badge", model["badge"]), else: &1)
    end
  end

  # A model gated on a CLI version is left out while the installed version is unknown.
  defp runs?(model, version) do
    case {get_in(model, ["adapter", "claudeCode", "minVersion"]), Version.parse(version)} do
      {nil, _} -> true
      {min, {:ok, v}} -> Version.compare(v, min) != :lt
      {_, :error} -> false
    end
  end

  defp version(path) do
    case :persistent_term.get({__MODULE__, :version}, nil) do
      nil ->
        version =
          case System.cmd(path, ["--version"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> List.first() |> Kernel.||("unknown")
            _ -> "unknown"
          end

        :persistent_term.put({__MODULE__, :version}, version)
        version

      version ->
        version
    end
  rescue
    _ -> "unknown"
  end
end
