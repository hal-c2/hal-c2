defmodule HalC2.Claude.Provider do
  @moduledoc """
  The Claude entry in this MC's `ServerConfig.providers`, present when the `claude`
  CLI is on the MC's PATH.

  Its models are the ones the installed Claude Code lists in its `initialize` reply,
  read in the background at boot and on a model refresh (`load/1`). Until that answers,
  or when the CLI answers without them (one too old to list them), they are the Claude
  catalog of the model manifest in use (`HalC2.ModelManifest`), less those the
  installed CLI is too old to run. A read that fails (a crash, a timeout) changes
  nothing: the list read before stands, or the manifest when there was none.
  """

  alias HalC2.Claude.Session

  @models {__MODULE__, :models}
  @probe_timeout 20_000

  @effort_labels %{
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High",
    "xhigh" => "Extra High",
    "max" => "Max"
  }

  # A fetched manifest may leave Claude out; the release's own catalog then stands.
  defp catalog do
    HalC2.ModelManifest.catalog("claudeAgent") ||
      get_in(HalC2.ModelManifest.bundled(), ["providers", "claudeAgent"]) ||
      %{"defaults" => %{}, "profiles" => %{}, "models" => []}
  end

  @doc """
  The entries of every Claude instance: the built-in `claudeAgent` and each instance
  the settings add for the `claudeAgent` driver, which runs its own `binaryPath`.
  """
  @spec entries() :: [map]
  def entries do
    for id <- instances(), entry = entry(id), do: entry
  end

  @doc "The ids of every Claude instance: the built-in `claudeAgent` and those settings add."
  @spec instances() :: [String.t()]
  def instances, do: ["claudeAgent" | HalC2.Settings.instances_of("claudeAgent")]

  @doc """
  The entry of Claude instance `id`, or nil when Claude is not installed on this MC.
  An instance whose `binaryPath` names nothing is listed as not installed.
  """
  @spec entry(String.t()) :: map | nil
  def entry(id \\ "claudeAgent") do
    case executable(id) do
      nil ->
        HalC2.Settings.not_installed_entry(id, "claudeAgent", "Claude")

      path ->
        %{
          "instanceId" => id,
          "driver" => "claudeAgent",
          # Turned off in settings (`providers.claudeAgent.enabled`), it stays listed so it can be
          # turned back on; clients leave it out of the model picker.
          "enabled" => HalC2.Settings.instance_enabled?(id, "claudeAgent"),
          "installed" => true,
          "version" => version(path),
          "versionAdvisory" =>
            HalC2.ProviderUpdates.advisory("claudeAgent", path, version(path), id),
          "status" => "ready",
          "availability" => "available",
          "auth" => %{"status" => "authenticated"},
          "checkedAt" => HalC2.Orchestration.Entities.now(),
          "models" => models(id, path),
          "slashCommands" => [
            %{
              "name" => "compact",
              "description" => "Summarize the conversation and reduce context usage"
            }
          ],
          "skills" => []
        }
    end
  end

  @doc """
  Reads the models each Claude instance's CLI lists (all of them by default) and keeps
  them by instance and executable, since an instance's variables (its config
  directory, a router) change what Claude Code offers. Run once in the background at
  boot and on a model refresh, never on a provider check. Each read starts the CLI,
  sends `initialize` and stops it, so nothing reaches the model. A reply without
  models goes back to the manifest; a CLI that does not answer keeps what was read
  before. Clients read the provider list again when a list changed.
  """
  @spec load([String.t()]) :: :ok
  def load(ids \\ instances()) do
    reads =
      for id <- ids, path = executable(id), do: {{id, path}, id}

    results =
      reads
      |> Task.async_stream(fn {key, id} -> {key, read_models(id)} end,
        timeout: :infinity,
        max_concurrency: 4
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # Loads run at once (boot, and refreshes from several clients), so each merges what
    # it read into the latest map rather than into the one it started from.
    :global.trans(
      {@models, self()},
      fn ->
        cached = :persistent_term.get(@models, %{})

        updated =
          Enum.reduce(results, cached, fn
            {key, {:ok, models}}, acc -> Map.put(acc, key, models)
            {key, :none}, acc -> Map.delete(acc, key)
            {_key, :error}, acc -> acc
          end)

        if updated != cached do
          :persistent_term.put(@models, updated)
          HalC2.Settings.notify_providers()
        end
      end,
      [node()]
    )

    :ok
  end

  # Without the user's hooks or MCP servers, as the usage probe runs it.
  defp read_models(id) do
    Process.flag(:trap_exit, true)

    opts = [
      handler: self(),
      command: command(id) ++ ["--settings", ~s({"disableAllHooks":true}), "--strict-mcp-config"],
      persist_session: false,
      env:
        Enum.to_list(HalC2.Settings.instance_env(id)) ++
          [
            {"ENABLE_CLAUDEAI_MCP_SERVERS", "false"},
            {"CLAUDE_CODE_AUTO_CONNECT_IDE", "0"},
            {"CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL", "1"}
          ]
    ]

    case Session.start_link(opts) do
      {:ok, session} ->
        result =
          receive do
            {:claude, ^session, {:initialized, {:ok, %{"models" => [_ | _] = models}}}} ->
              {:ok, models}

            {:claude, ^session, {:initialized, {:ok, _reply}}} ->
              :none

            {:claude, ^session, {:initialized, _error}} ->
              :error

            {:EXIT, ^session, _reason} ->
              :error
          after
            @probe_timeout -> :error
          end

        stop(session)
        result

      _ ->
        :error
    end
  catch
    _, _ -> :error
  end

  defp stop(session) do
    GenServer.stop(session)
  catch
    :exit, _ -> :ok
  end

  # What Claude Code listed for instance `id`, or nil when it has not said.
  defp reported(id) do
    case executable(id) do
      nil -> nil
      path -> Map.get(:persistent_term.get(@models, %{}), {id, path})
    end
  end

  defp models(id, path) do
    case reported(id) do
      nil -> manifest_models(version(path))
      reported -> for model <- cli_models(reported), do: Map.delete(model, "adapter")
    end
  end

  @doc false
  # The rows Claude Code listed as entry models, in its order, each with the adapter
  # settings `launch/3` runs it with. A row's `value` is its slug and its
  # `resolvedModel` an alias, so a thread saved under the canonical id finds the row
  # that covers it. The `default` row names the CLI's default: the row it resolves to
  # is marked default and takes `default` as an alias, or it stays as a model of its own.
  def cli_models(reported) do
    rows =
      for %{"value" => value} = row <- reported, is_binary(value) and value != "", do: row

    default = Enum.find(rows, &(&1["value"] == "default"))

    covering =
      default &&
        Enum.find(rows, &(&1 != default and resolved(&1) == resolved(default)))

    rows = if covering, do: List.delete(rows, default), else: rows
    default_value = (covering || default || %{})["value"]
    values = MapSet.new(rows, &String.downcase(&1["value"]))

    {models, _claimed} =
      Enum.map_reduce(rows, values, fn row, claimed ->
        aliases =
          [row["resolvedModel"] | if(row == covering, do: ["default"], else: [])]
          |> Enum.filter(&(is_binary(&1) and not MapSet.member?(claimed, String.downcase(&1))))

        profile = known_profile(row)

        model = %{
          "slug" => row["value"],
          "name" => text(row["displayName"]) || row["value"],
          "aliases" => aliases,
          "isCustom" => false,
          "isDefault" => row["value"] == default_value,
          "isLegacy" => false,
          "capabilities" => cli_capabilities(row, profile),
          "adapter" => cli_adapter(row, profile)
        }

        {model, Enum.reduce(aliases, claimed, &MapSet.put(&2, String.downcase(&1)))}
      end)

    models
  end

  defp resolved(row), do: String.downcase(row["resolvedModel"] || row["value"])

  # The manifest profile of the model a row resolves to, without a context suffix
  # such as `[1m]`, or an empty one when the manifest does not know it.
  defp known_profile(row) do
    base = String.replace(row["resolvedModel"] || row["value"], ~r/\[[^\]]*\]$/, "")

    case find(base) do
      nil -> %{}
      entry -> profile(entry)
    end
  end

  # The levels Claude Code reports make the effort select. The manifest profile adds
  # what the CLI does not list: its other options (thinking, context window) and the
  # efforts it knows how to run otherwise (ultracode as xhigh, ultrathink in the
  # prompt). Fast mode is offered when the CLI says the model has it; the context
  # window is not when the row's id already names one.
  defp cli_capabilities(row, profile) do
    known = get_in(profile, ["capabilities", "optionDescriptors"]) || []
    effort_map = get_in(profile, ["adapter", "claudeCode", "effortMap"]) || %{}
    levels = for level <- List.wrap(row["supportedEffortLevels"]), is_binary(level), do: level

    fast =
      if row["supportsFastMode"] == true,
        do:
          descriptor(known, "fastMode") ||
            %{"id" => "fastMode", "label" => "Fast Mode", "type" => "boolean"}

    others =
      for %{"id" => id} = descriptor <- known,
          id not in ["effort", "fastMode"],
          not (id == "contextWindow" and suffixed?(row["value"])),
          do: descriptor

    case Enum.reject(
           [effort(levels, descriptor(known, "effort"), effort_map), fast | others],
           &is_nil/1
         ) do
      [] -> nil
      descriptors -> %{"optionDescriptors" => descriptors}
    end
  end

  defp effort([], _known, _effort_map), do: nil

  defp effort(levels, known, effort_map) do
    known_options = (known || %{})["options"] || []

    listed =
      for level <- levels,
          do:
            Enum.find(known_options, &(&1["id"] == level)) ||
              %{"id" => level, "label" => @effort_labels[level] || level}

    extras =
      for %{"id" => id} = option <- known_options,
          id not in levels,
          Map.has_key?(effort_map, id),
          effort_map[id] == nil or effort_map[id] in levels,
          do: option

    options = listed ++ extras

    injected =
      for id <- (known || %{})["promptInjectedValues"] || [], option?(options, id), do: id

    %{"id" => "effort", "label" => "Reasoning", "type" => "select", "options" => options}
    |> then(&if injected == [], do: &1, else: Map.put(&1, "promptInjectedValues", injected))
  end

  defp option?(options, id), do: Enum.any?(options, &(&1["id"] == id))

  # How the CLI runs a listed row: the profile's adapter, less mappings for levels the
  # CLI now runs itself, and without context suffixes on an id that carries one.
  defp cli_adapter(row, profile) do
    adapter = get_in(profile, ["adapter", "claudeCode"]) || %{}
    levels = List.wrap(row["supportedEffortLevels"])

    adapter
    |> Map.update("effortMap", %{}, &Map.drop(&1, levels))
    |> then(&if suffixed?(row["value"]), do: Map.delete(&1, "modelSuffixes"), else: &1)
  end

  defp suffixed?(value), do: String.ends_with?(value, "]")

  defp text(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp text(_value), do: nil

  # The catalog's models the CLI at `version` can run, in manifest order.
  defp manifest_models(version) do
    catalog = catalog()

    for model <- catalog["models"], runs?(model, version) do
      %{
        "slug" => model["slug"],
        "name" => model["name"],
        "aliases" => model["aliases"] || [],
        "isCustom" => false,
        "isDefault" => model["slug"] == get_in(catalog, ["defaults", "chat"]),
        "isLegacy" => model["status"] == "legacy",
        "capabilities" => profile(model)["capabilities"]
      }
      |> then(&if model["badge"], do: Map.put(&1, "badge", model["badge"]), else: &1)
    end
  end

  @doc """
  How instance `instance`'s CLI runs `model` with the options picked in the composer
  (option id -> value): the model id (a context window adds its suffix, such as
  `[1m]`), the `--effort` level, `--settings` (fast mode, thinking, ultracode), and an
  effort the CLI has no level for, which goes in the prompt instead (`prompt/2`). A
  model the CLI listed runs under the name it was picked by, with the options its
  entry offers; another the manifest knows runs under its manifest id. A model
  neither knows runs as named, without options.
  """
  @spec launch(String.t() | nil, map, String.t()) :: %{
          model: String.t() | nil,
          effort: String.t() | nil,
          settings: map,
          prompt_effort: String.t() | nil
        }
  def launch(model, options, instance \\ "claudeAgent") do
    case spec(model, instance) do
      nil ->
        %{model: model, effort: nil, settings: %{}, prompt_effort: nil}

      %{"slug" => slug, "capabilities" => capabilities, "adapter" => adapter} ->
        descriptors = (capabilities || %{})["optionDescriptors"] || []
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
          model: slug <> suffix,
          effort: Map.get(adapter["effortMap"] || %{}, effort, effort),
          settings: Map.reject(settings, fn {_, value} -> value == nil end),
          prompt_effort: if(effort in injected, do: effort)
        }
    end
  end

  # The slug, capabilities and adapter settings `model` runs with on `instance`: the
  # row Claude Code listed for it, else the manifest's model.
  defp spec(model, instance) do
    case listed(model, instance) do
      nil ->
        with %{} = entry <- find(model) do
          profile = profile(entry)

          %{
            "slug" => entry["slug"],
            "capabilities" => profile["capabilities"],
            "adapter" => get_in(profile, ["adapter", "claudeCode"]) || %{}
          }
        end

      row ->
        Map.put(row, "slug", model)
    end
  end

  # The row Claude Code listed for `model` (by its id or an alias), when it has listed any.
  defp listed(model, instance) when is_binary(model) do
    name = String.downcase(model)

    Enum.find(cli_models(reported(instance) || []), fn row ->
      Enum.any?([row["slug"] | row["aliases"]], &(String.downcase(&1) == name))
    end)
  end

  defp listed(_model, _instance), do: nil

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

  @doc """
  Why instance `instance`'s CLI cannot run `model`, when the manifest gates the model
  on a newer Claude Code than this one: the message names the version to upgrade to.
  `nil` for a model the CLI listed (it runs it, by definition), one it can run, one
  the manifest does not know, or a CLI whose version cannot be read (which is left to
  refuse the model itself).
  """
  @spec too_old(String.t() | nil, String.t()) :: String.t() | nil
  def too_old(model, instance \\ "claudeAgent") do
    with nil <- listed(model, instance),
         %{} = entry <- find(model),
         min when is_binary(min) <- get_in(entry, ["adapter", "claudeCode", "minVersion"]),
         path when is_binary(path) <- executable(instance),
         {:ok, version} <- Version.parse(version(path)),
         :lt <- Version.compare(version, min) do
      "Claude Code v#{version} is too old for #{entry["name"]}. Upgrade to v#{min} or newer to access it."
    else
      _ -> nil
    end
  end

  defp command(id),
    do:
      HalC2.Settings.instance_command(
        id,
        Application.get_env(:hal_c2, :claude_command, ["claude"])
      )

  # The instance's `claude` on this machine, or nil when it names nothing.
  defp executable(id) do
    with [executable | _] <- command(id),
         path when is_binary(path) <- System.find_executable(executable),
         do: path,
         else: (_ -> nil)
  end

  # The catalog model named by its slug or one of its aliases.
  defp find(model) when is_binary(model) do
    name = String.downcase(model)

    Enum.find(catalog()["models"], fn entry ->
      Enum.any?([entry["slug"] | entry["aliases"] || []], &(String.downcase(&1) == name))
    end)
  end

  defp find(_model), do: nil

  defp profile(model), do: catalog()["profiles"][model["profile"]] || %{}

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

  # Read once per executable, so each instance's binary path has its own.
  defp version(path) do
    versions = :persistent_term.get({__MODULE__, :version}, %{})

    case versions do
      %{^path => version} ->
        version

      _ ->
        version =
          case System.cmd(path, ["--version"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> List.first() |> Kernel.||("unknown")
            _ -> "unknown"
          end

        :persistent_term.put({__MODULE__, :version}, Map.put(versions, path, version))
        version
    end
  rescue
    _ -> "unknown"
  end
end
