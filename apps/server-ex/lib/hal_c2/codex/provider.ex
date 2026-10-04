defmodule HalC2.Codex.Provider do
  @moduledoc """
  The Codex entry in this MC's `ServerConfig.providers`, which is what lets a
  client's composer send to Codex here.

  The entry appears when the `codex` command is on the MC's PATH. Its model list
  comes from `codex app-server`'s `model/list`, read once in the background at boot
  (`load/0`); until then a single default model is offered.
  """

  alias HalC2.JsonRpc.Connection

  @key {__MODULE__, :models}
  @default_models [%{"slug" => "gpt-5.5", "name" => "GPT-5.5", "isDefault" => true}]

  @doc """
  The entries of every Codex instance: the built-in `codex` and each instance the
  settings add for the `codex` driver, which runs its own `binaryPath`.
  """
  @spec entries() :: [map]
  def entries do
    for id <- ["codex" | HalC2.Settings.instances_of("codex")], entry = entry(id), do: entry
  end

  @doc """
  The entry of Codex instance `id`, or nil when Codex is not installed on this MC.
  An instance whose `binaryPath` names nothing is listed as not installed, so the
  user sees why it cannot run and can correct the path.
  """
  @spec entry(String.t()) :: map | nil
  def entry(id \\ "codex") do
    with [executable | _] <- command(id),
         path when is_binary(path) <- System.find_executable(executable) do
      %{
        "instanceId" => id,
        "driver" => "codex",
        # Turned off in settings (`providers.codex.enabled`), it stays listed so it can be
        # turned back on; clients leave it out of the model picker.
        "enabled" => HalC2.Settings.instance_enabled?(id, "codex"),
        "installed" => true,
        "version" => version(path),
        "versionAdvisory" => HalC2.ProviderUpdates.advisory("codex", path, version(path), id),
        "status" => "ready",
        "availability" => "available",
        "auth" => %{"status" => "authenticated"},
        "checkedAt" => HalC2.Orchestration.Entities.now(),
        "models" =>
          for(model <- :persistent_term.get(@key, @default_models), do: model_entry(model)),
        "slashCommands" => [
          %{
            "name" => "compact",
            "description" => "Summarize the conversation and reduce context usage"
          },
          %{
            "name" => "feedback",
            "description" => "Send this thread and Codex logs to OpenAI",
            "input" => %{"hint" => "Describe the issue (optional)"}
          }
        ],
        "skills" => []
      }
    else
      _ -> HalC2.Settings.not_installed_entry(id, "codex", "Codex")
    end
  end

  @doc """
  Reads the model list from `codex app-server`; run once at boot and on a model
  refresh. A missing binary stops the connection in `init`, which would take the
  linked caller with it, so the read runs in its own process.
  """
  def load do
    {_pid, ref} = spawn_monitor(&read_models/0)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  defp read_models do
    with [_ | _] = cmd <- command("codex"),
         {:ok, args} <- launch_args("codex"),
         {:ok, conn} <- Connection.start_link(cmd: cmd ++ args, handler: self()),
         {:ok, _} <-
           Connection.call(conn, "initialize", %{
             "clientInfo" => %{"name" => "hal_c2_elixir", "version" => "0.1.0"}
           }),
         :ok <- Connection.notify(conn, "initialized", nil),
         {:ok, %{"data" => [_ | _] = models}} <- Connection.call(conn, "model/list", %{}) do
      :persistent_term.put(
        @key,
        for(
          m <- models,
          do: %{
            "slug" => m["model"] || m["id"],
            "name" => m["displayName"] || m["model"] || m["id"],
            "isDefault" => m["isDefault"] == true,
            "capabilities" => capabilities(m)
          }
        )
      )

      Connection.stop(conn)
    end

    :ok
  catch
    _, _ -> :ok
  end

  @doc """
  The launch arguments set on a Codex instance (`launchArgs`), split as a shell
  would. Every Codex process the MC starts for the instance takes them: its sessions
  and this check after `app-server`, and `codex exec` those it has (`exec_args/1`).
  """
  @spec launch_args(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def launch_args(instance) do
    {:ok, OptionParser.split(HalC2.Settings.instance_setting(instance, "launchArgs") || "")}
  rescue
    RuntimeError -> {:error, "the launch arguments in settings have a quote that is never closed"}
  end

  @doc """
  The launch arguments `codex exec` takes: config overrides and feature switches
  (`--strict-config`, `-c`/`--config`, `--enable`, `--disable`). The rest belong to
  `app-server` alone.
  """
  @spec exec_args([String.t()]) :: [String.t()]
  def exec_args(["--strict-config" = arg | rest]), do: [arg | exec_args(rest)]

  def exec_args([arg, value | rest]) when arg in ~w(--config -c --enable --disable) do
    if String.starts_with?(value, "-"),
      do: exec_args([value | rest]),
      else: [arg, value | exec_args(rest)]
  end

  def exec_args([arg | rest]) do
    if String.starts_with?(arg, ["--config=", "-c=", "--enable=", "--disable="]),
      do: [arg | exec_args(rest)],
      else: exec_args(rest)
  end

  def exec_args([]), do: []

  # Names older threads and settings saved a model under (`MODEL_SLUG_ALIASES_BY_PROVIDER`).
  @aliases %{
    "gpt-5-codex" => "gpt-5.4",
    "5.4" => "gpt-5.4",
    "5.3" => "gpt-5.3-codex",
    "gpt-5.3" => "gpt-5.3-codex",
    "5.3-spark" => "gpt-5.3-codex-spark",
    "gpt-5.3-spark" => "gpt-5.3-codex-spark"
  }

  @doc "The model Codex knows `model` as today: an older alias names its current id."
  def current_slug(model), do: Map.get(@aliases, model, model)

  defp model_entry(model),
    do: %{
      "slug" => model["slug"],
      "name" => model["name"],
      # Clients show a thread saved under an alias by the model's current name.
      "aliases" => for({alias, slug} <- Enum.sort(@aliases), slug == model["slug"], do: alias),
      "isCustom" => false,
      "isDefault" => model["isDefault"] == true,
      "capabilities" => model["capabilities"]
    }

  @effort_labels %{
    "none" => "None",
    "minimal" => "Minimal",
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High",
    "xhigh" => "Extra High",
    "max" => "Max",
    "ultra" => "Ultra"
  }

  # The reasoning levels and service tiers a model offers, as the composer's options.
  defp capabilities(model) do
    case Enum.reject([reasoning(model), service_tier(model)], &is_nil/1) do
      [] -> nil
      descriptors -> %{"optionDescriptors" => descriptors}
    end
  end

  defp reasoning(%{"supportedReasoningEfforts" => [_ | _] = efforts} = model) do
    default = model["defaultReasoningEffort"]

    options =
      for %{"reasoningEffort" => id} <- efforts do
        option = %{"id" => id, "label" => @effort_labels[id] || id}
        if id == default, do: Map.put(option, "isDefault", true), else: option
      end

    descriptor = %{
      "id" => "reasoningEffort",
      "label" => "Reasoning",
      "type" => "select",
      "options" => options
    }

    if Enum.any?(options, & &1["isDefault"]),
      do: Map.put(descriptor, "currentValue", default),
      else: descriptor
  end

  defp reasoning(_model), do: nil

  # Standard ("default") plus the model's faster tiers; older CLIs only name speed tiers.
  defp service_tier(model) do
    tiers =
      case model["serviceTiers"] do
        [_ | _] = tiers ->
          tiers

        _ ->
          for id <- model["additionalSpeedTiers"] || [],
              do: %{"id" => id, "name" => if(id == "fast", do: "Fast", else: id)}
      end

    if tiers != [] do
      default =
        if Enum.any?(tiers, &(&1["id"] == model["defaultServiceTier"])),
          do: model["defaultServiceTier"],
          else: "default"

      options =
        for tier <- [%{"id" => "default", "name" => "Standard"} | tiers] do
          %{"id" => tier["id"], "label" => tier["name"] || tier["id"]}
          |> then(
            &if tier["description"] in [nil, ""],
              do: &1,
              else: Map.put(&1, "description", tier["description"])
          )
          |> then(&if tier["id"] == default, do: Map.put(&1, "isDefault", true), else: &1)
        end

      %{
        "id" => "serviceTier",
        "label" => "Service Tier",
        "type" => "select",
        "options" => options,
        "currentValue" => default
      }
    end
  end

  defp command(id),
    do:
      HalC2.Settings.instance_command(
        id,
        Application.get_env(:hal_c2, :codex_command, ["codex", "app-server"])
      )

  # Read once per executable, so each instance's binary path has its own.
  defp version(path) do
    versions = :persistent_term.get({__MODULE__, :version}, %{})

    case versions do
      %{^path => version} ->
        version

      _ ->
        version =
          case System.cmd(path, ["--version"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> List.last() |> Kernel.||("unknown")
            _ -> "unknown"
          end

        :persistent_term.put({__MODULE__, :version}, Map.put(versions, path, version))
        version
    end
  rescue
    _ -> "unknown"
  end
end
