defmodule HalC2.Claude.Provider do
  @moduledoc """
  The Claude entry in this node's `ServerConfig.providers`, present when the `claude`
  CLI is on the node's PATH. Models are the Claude catalog of the bundled model manifest,
  read at compile time, less those the installed CLI is too old to run.
  """

  @manifest Path.expand("../../../priv/model-manifest.json", __DIR__)
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
        "capabilities" => profile(model)["capabilities"]
      }
      |> then(&if model["badge"], do: Map.put(&1, "badge", model["badge"]), else: &1)
    end
  end

  @doc """
  How the CLI runs `model` with the options picked in the composer (option id -> value),
  as the model's manifest profile maps them: the model id (a context window adds its
  suffix, such as `[1m]`), the `--effort` level, `--settings` (fast mode, thinking,
  ultracode), and an effort the CLI has no level for, which goes in the prompt instead
  (`prompt/2`). A model the manifest does not know runs as named, without options.
  """
  @spec launch(String.t() | nil, map) :: %{
          model: String.t() | nil,
          effort: String.t() | nil,
          settings: map,
          prompt_effort: String.t() | nil
        }
  def launch(model, options) do
    case find(model) do
      nil ->
        %{model: model, effort: nil, settings: %{}, prompt_effort: nil}

      entry ->
        profile = profile(entry)
        descriptors = get_in(profile, ["capabilities", "optionDescriptors"]) || []
        adapter = get_in(profile, ["adapter", "claudeCode"]) || %{}
        effort = choice(descriptors, "effort", options)

        suffix =
          Enum.find_value(adapter["modelSuffixes"] || %{}, "", fn {id, suffixes} ->
            suffixes[choice(descriptors, id, options)]
          end)

        settings = %{
          "fastMode" => toggle(descriptors, "fastMode", options),
          "alwaysThinkingEnabled" => toggle(descriptors, "thinking", options),
          "ultracode" => if(effort == "ultracode", do: true)
        }

        injected = (descriptor(descriptors, "effort") || %{})["promptInjectedValues"] || []

        %{
          model: entry["slug"] <> suffix,
          effort: Map.get(adapter["effortMap"] || %{}, effort, effort),
          settings: Map.reject(settings, fn {_, value} -> value == nil end),
          prompt_effort: if(effort in injected, do: effort)
        }
    end
  end

  @doc """
  The message as Claude gets it: ultrathink is asked for in the prompt, except on a
  slash command, which the prefix would turn into prose.
  """
  @spec prompt(String.t(), String.t() | nil) :: String.t()
  def prompt(text, "ultrathink") do
    if text =~ ~r{^\s*/[^\s/]+(\s|$)} or String.starts_with?(String.trim(text), "Ultrathink:"),
      do: text,
      else: "Ultrathink:\n" <> String.trim(text)
  end

  def prompt(text, _effort), do: text

  # The catalog model named by its slug or one of its aliases.
  defp find(model) when is_binary(model) do
    name = String.downcase(model)

    Enum.find(@catalog["models"], fn entry ->
      Enum.any?([entry["slug"] | entry["aliases"] || []], &(String.downcase(&1) == name))
    end)
  end

  defp find(_model), do: nil

  defp profile(model), do: @catalog["profiles"][model["profile"]] || %{}

  defp descriptor(descriptors, id), do: Enum.find(descriptors, &(&1["id"] == id))

  # The picked value of a select option, or its default when none of its values is picked.
  defp choice(descriptors, id, options) do
    with %{"type" => "select", "options" => values} <- descriptor(descriptors, id) do
      ids = Enum.map(values, & &1["id"])

      if options[id] in ids,
        do: options[id],
        else: Enum.find_value(values, &(&1["isDefault"] == true && &1["id"]))
    else
      _ -> nil
    end
  end

  # A boolean option the model has, when the user set it.
  defp toggle(descriptors, id, options) do
    if match?(%{"type" => "boolean"}, descriptor(descriptors, id)) and is_boolean(options[id]),
      do: options[id]
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
