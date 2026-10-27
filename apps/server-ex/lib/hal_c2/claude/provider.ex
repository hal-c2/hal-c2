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
  @capabilities {__MODULE__, :capabilities}
  @health {__MODULE__, :health}
  @probe_timeout 20_000
  # How long an `initialize` read (account, commands, models) stands before the
  # next check reads it again; a refresh by hand always reads afresh.
  @capabilities_ttl_ms 300_000

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
        case HalC2.Settings.not_installed_entry(id, "claudeAgent", "Claude") do
          nil ->
            nil

          entry ->
            # A bare command name was looked up on the PATH, and says so.
            if String.contains?(HalC2.Settings.instance_setting(id, "binaryPath") || "", "/") do
              entry
            else
              Map.put(entry, "message", "Claude Agent CLI (`claude`) was not found on PATH.")
            end
        end

      path ->
        enabled = HalC2.Settings.instance_enabled?(id, "claudeAgent")

        base = %{
          "instanceId" => id,
          "driver" => "claudeAgent",
          # Turned off in settings (`providers.claudeAgent.enabled`), it stays listed so it can be
          # turned back on; clients leave it out of the model picker.
          "enabled" => enabled,
          "installed" => true,
          "version" => version(path),
          "versionAdvisory" =>
            HalC2.ProviderUpdates.advisory("claudeAgent", path, version(path), id),
          "status" => "ready",
          "availability" => "available",
          "auth" => %{"status" => "authenticated"},
          "checkedAt" => HalC2.Orchestration.Entities.now(),
          "models" => models(id, path),
          "slashCommands" => slash_commands(id, path),
          "skills" => skills(id, path)
        }

        base
        |> then(fn entry ->
          case upgrade_message(version(path)) do
            nil -> entry
            message -> Map.put(entry, "message", message)
          end
        end)
        |> with_health(id, path, enabled)
    end
  end

  # Claude's skills for the entry: read from its config directory and the
  # project's folders when a client asks for a folder's (`skills/2`); the entry
  # itself carries none until then.
  defp skills(_id, _path), do: []

  defp slash_commands(id, path) do
    commands =
      case cached_capabilities(id, path) do
        %{"commands" => commands} -> HalC2.ProviderUsageLimits.Claude.commands(commands)
        _ -> []
      end

    Enum.uniq_by(
      [
        %{
          "name" => "compact",
          "description" => "Summarize the conversation and reduce context usage"
        }
      ] ++ commands,
      & &1["name"]
    )
  end

  # What the health check last found, in the entry's words. The version run is the
  # check (as it always was, now with a deadline); the sign-in comes from the
  # `initialize` read the models load or the usage probe already made.
  defp with_health(entry, _id, _path, false) do
    entry
    |> Map.put("status", "warning")
    |> Map.put("message", "Claude is disabled in HAL-C2 settings.")
  end

  defp with_health(entry, id, path, true) do
    case version_health(id, path) do
      :pending ->
        entry
        |> Map.merge(%{
          "status" => "warning",
          "installed" => false,
          "version" => nil,
          "auth" => %{"status" => "unknown"},
          "message" => "Claude provider status has not been checked in this session yet."
        })

      {:error, message, version} ->
        entry
        |> Map.merge(%{
          "status" => "error",
          "version" => version,
          "auth" => %{"status" => "unknown"},
          "message" => message
        })

      {:ok, _version} ->
        if auth_unverified?(id, path) do
          entry
          |> Map.merge(%{
            "status" => "warning",
            "auth" => %{"status" => "unknown"},
            "message" =>
              "Could not verify Claude authentication status from initialization result."
          })
        else
          entry
        end
    end
  end

  # Signed-in-ness as the last `initialize` read left it: a read that reported no
  # account could not verify it. No read yet says nothing either way.
  defp auth_unverified?(id, path) do
    case cached_capabilities(id, path) do
      nil -> false
      reply -> reply["account"] in [nil, ""]
    end
  end

  # The version run's outcome, checked once per executable: the first reader runs
  # it (readers while it runs see the check as pending), later ones read the record.
  defp version_health(id, path) do
    records = :persistent_term.get(@health, %{})

    case Map.get(records, {id, path}) do
      {:done, health} ->
        health

      :probing ->
        :pending

      nil ->
        :persistent_term.put(@health, Map.put(records, {id, path}, :probing))

        health =
          try do
            probe_version(path)
          rescue
            _ -> {:error, "Failed to execute Claude Agent CLI health check.", nil}
          end

        records = :persistent_term.get(@health, %{})
        :persistent_term.put(@health, Map.put(records, {id, path}, {:done, health}))
        health
    end
  end

  defp probe_version(path) do
    task = Task.async(fn -> run_version(path) end)
    timeout = Application.get_env(:hal_c2, :claude_health_timeout_ms, 5_000)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, version}} ->
        {:ok, version}

      {:ok, {:exit, output}} ->
        {:error, "Claude Agent CLI is installed but failed to run.", version_token(output)}

      {:ok, {:spawn, :enoent}} ->
        if System.find_executable(path) do
          {:error, "Failed to execute Claude Agent CLI health check.", nil}
        else
          {:error, "Claude Agent CLI (`claude`) was not found on PATH.", nil}
        end

      {:ok, {:spawn, _reason}} ->
        {:error, "Failed to execute Claude Agent CLI health check.", nil}

      _ ->
        {:error,
         "Claude Agent CLI is installed but failed to run. Timed out while running command.", nil}
    end
  end

  defp run_version(path) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, version_token(output) || "unknown"}
      # A program that cannot be executed at all (a launcher whose interpreter
      # is gone) fails before it can say anything: an empty failure is the OS's.
      {"", _status} -> {:spawn, :enoent}
      {output, _status} -> {:exit, output}
    end
  rescue
    error in ErlangError -> {:spawn, error.original}
  end

  defp version_token(output) do
    case output |> String.split() |> List.first() do
      token ->
        case token && Version.parse(token) do
          {:ok, _} -> token
          _ -> nil
        end
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

  defp read_models(id) do
    case capabilities(id, executable(id), true) do
      {:ok, %{"models" => [_ | _] = models}} -> {:ok, models}
      {:ok, _reply} -> :none
      :error -> :error
    end
  end

  # The last `initialize` reply read for an instance, when it is still fresh.
  defp cached_capabilities(id, path) do
    case Map.get(:persistent_term.get(@capabilities, %{}), {id, path}) do
      {reply, at} ->
        if System.monotonic_time(:millisecond) - at < @capabilities_ttl_ms, do: reply

      _ ->
        nil
    end
  end

  @doc """
  What `initialize` reports for instance `id` — its account, commands, agents and
  models — read at most once in five minutes. `force` reads afresh, as a refresh
  by hand does. The read itself is the models load's: a short-lived session with
  no hooks or MCP servers, so nothing reaches the model.
  """
  @spec capabilities(String.t(), String.t() | nil, boolean) :: {:ok, map} | :error
  def capabilities(id, path \\ nil, force \\ false) do
    path = path || executable(id)

    if path == nil do
      :error
    else
      case {force, cached_capabilities(id, path)} do
        {false, %{} = reply} ->
          {:ok, reply}

        _ ->
          case read_capabilities(id) do
            {:ok, reply} ->
              records = :persistent_term.get(@capabilities, %{})

              :persistent_term.put(
                @capabilities,
                Map.put(records, {id, path}, {reply, System.monotonic_time(:millisecond)})
              )

              {:ok, reply}

            :error ->
              :error
          end
      end
    end
  end

  # Without the user's hooks or MCP servers, as the usage probe runs it.
  defp read_capabilities(id) do
    Process.flag(:trap_exit, true)

    home =
      case home_path(id) do
        nil -> []
        path -> [{"CLAUDE_CONFIG_DIR", expand_home(path)}]
      end

    opts = [
      handler: self(),
      command: command(id) ++ ["--settings", ~s({"disableAllHooks":true}), "--strict-mcp-config"],
      persist_session: false,
      env:
        Enum.to_list(HalC2.Settings.instance_env(id)) ++
          home ++
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
            {:claude, ^session, {:initialized, {:ok, reply}}} ->
              {:ok, reply}

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
  # CLI now runs itself, and without context suffixes on an id that carries one. A
  # context suffix goes on `modelId`, the model the row resolves to, since Claude Code
  # takes none on an alias (`opus[1m]`).
  defp cli_adapter(row, profile) do
    adapter = get_in(profile, ["adapter", "claudeCode"]) || %{}
    levels = List.wrap(row["supportedEffortLevels"])

    adapter
    |> Map.put(
      "modelId",
      String.replace(row["resolvedModel"] || row["value"], ~r/\[[^\]]*\]$/, "")
    )
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
          prompt_effort: String.t() | nil,
          context_window: pos_integer
        }
  def launch(model, options, instance \\ "claudeAgent") do
    case spec(model, instance) do
      nil ->
        %{
          model: model,
          effort: nil,
          settings: %{},
          prompt_effort: nil,
          context_window: 200_000
        }

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
          model: if(suffix == "", do: slug, else: (adapter["modelId"] || slug) <> suffix),
          effort: Map.get(adapter["effortMap"] || %{}, effort, effort),
          settings: Map.reject(settings, fn {_, value} -> value == nil end),
          prompt_effort: if(effort in injected, do: effort),
          context_window:
            adapter["fixedContextWindowTokens"] ||
              get_in(adapter, [
                "contextWindowTokens",
                choice(descriptors, "contextWindow", options)
              ]) ||
              200_000
        }
    end
  end

  @doc """
  The config directory instance `instance`'s Claude uses: its `homePath` setting
  (`~` expanded) when set, else the MC's own `CLAUDE_CONFIG_DIR` (a relative one
  resolved from `cwd`, `~` left as written), else `.claude` in the user's home.
  """
  @spec config_dir(String.t(), String.t()) :: String.t()
  def config_dir(instance \\ "claudeAgent", cwd \\ nil) do
    cond do
      home = home_path(instance) ->
        expand_home(home)

      env = trim(HalC2.Settings.instance_env(instance)["CLAUDE_CONFIG_DIR"]) ->
        expand_home(env)

      env = trim(System.get_env("CLAUDE_CONFIG_DIR")) ->
        if Path.type(env) == :absolute, do: env, else: Path.absname(env, cwd || File.cwd!())

      true ->
        Path.join(System.get_env("HOME") || System.user_home!(), ".claude")
    end
  end

  @doc "The instance's own config directory (`homePath`) when it sets one."
  @spec home_path(String.t()) :: String.t() | nil
  def home_path(instance \\ "claudeAgent"),
    do: trim(HalC2.Settings.instance_setting(instance, "homePath"))

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(_value), do: nil

  @doc "A `homePath` with a leading `~` filled in from the MC's HOME, as a shell would."
  @spec expand_home(String.t()) :: String.t()
  def expand_home("~" <> rest) do
    home = System.get_env("HOME") || System.user_home!()
    Path.expand(Path.join(home, String.trim_leading(rest, "/")))
  end

  def expand_home(path), do: Path.expand(path)

  @doc """
  The `claude` a session spawns. On Windows an npm install puts a launcher script
  (`.cmd`/`.bat`/`.ps1`) on the path, which cannot be spawned directly, so the
  program it points to — `bin/claude.exe`, else `cli.js` under Node — is started
  instead. Anywhere else the command is unchanged.
  """
  @spec resolve_command([String.t()], (String.t() -> boolean)) :: [String.t()]
  def resolve_command(command, exists? \\ &File.regular?/1)

  def resolve_command([exe | rest] = command, exists?) do
    if Application.get_env(:hal_c2, :os_type, :os.type()) |> elem(0) == :win32 and
         String.downcase(Path.extname(exe)) in [".cmd", ".bat", ".ps1"] do
      dir = Path.dirname(exe)

      native =
        Path.join([dir, "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe"])

      cli = Path.join([dir, "node_modules", "@anthropic-ai", "claude-code", "cli.js"])

      cond do
        exists?.(native) -> [native | rest]
        exists?.(cli) -> ["node", cli | rest]
        true -> command
      end
    else
      command
    end
  end

  def resolve_command(command, _exists?), do: command

  @doc """
  The launch arguments set on a Claude instance (`launchArgs`), split as a shell
  would, as Codex's are (`HalC2.Codex.Provider.launch_args/1`).
  """
  @spec launch_args(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def launch_args(instance \\ "claudeAgent") do
    {:ok, OptionParser.split(HalC2.Settings.instance_setting(instance, "launchArgs") || "")}
  rescue
    RuntimeError ->
      {:error, "the launch arguments in settings have a quote that is never closed"}
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
  The provider list's word on a CLI too old for a manifest model: it names the
  model needing the lowest newer version and the version to upgrade to. A CLI
  whose version cannot be read is too old for every gated model (gated models
  are left out while the version is unknown), and is named without a version.
  `nil` when the CLI runs every model in the catalog.
  """
  @spec upgrade_message(String.t()) :: String.t() | nil
  def upgrade_message(version) do
    parsed =
      case Version.parse(version) do
        {:ok, parsed} -> parsed
        :error -> nil
      end

    gated =
      for model <- catalog()["models"],
          min when is_binary(min) <- [get_in(model, ["adapter", "claudeCode", "minVersion"])],
          parsed == nil or Version.compare(parsed, min) == :lt,
          do: {min, model["name"]}

    case Enum.sort_by(gated, fn {min, _} -> Version.parse!(min) end, Version) do
      [{min, name} | _] ->
        label = if parsed, do: "v#{parsed}", else: "the installed version"
        "Claude Code #{label} is too old for #{name}. Upgrade to v#{min} or newer to access it."

      [] ->
        nil
    end
  end

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

  defp command(id) do
    id
    |> HalC2.Settings.instance_command(Application.get_env(:hal_c2, :claude_command, ["claude"]))
    |> resolve_command()
  end

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

  # Read once per executable, so each instance's binary path has its own. The run
  # has the health check's deadline, so a CLI that hangs cannot hang the list.
  defp version(path) do
    versions = :persistent_term.get({__MODULE__, :version}, %{})

    case versions do
      %{^path => version} ->
        version

      _ ->
        version =
          case probe_version(path) do
            {:ok, version} -> version
            {:error, _message, version} -> version || "unknown"
          end

        :persistent_term.put({__MODULE__, :version}, Map.put(versions, path, version))
        version
    end
  rescue
    _ -> "unknown"
  end
end
