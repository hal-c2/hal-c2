defmodule HalC2.Environment do
  @moduledoc """
  This node's identity as a client-facing environment.

  The environment id is generated once and kept in the HAL-C2 home directory, so it
  survives restarts, address changes, and cluster membership. Clients key their
  caches and settings by it, exactly as they do for Node servers.
  """

  @protocol 3

  @doc "The descriptor served at `/.well-known/hal-c2/environment`."
  @spec descriptor() :: map
  def descriptor do
    base = %{
      "environmentId" => id(),
      "label" => label(),
      "platform" => platform(),
      "serverVersion" => version(),
      "orchestrationProtocolVersion" => @protocol,
      # Commands are resolved against the thread on the node, so clients need not
      # read the projection before sending.
      "capabilities" => %{
        # Projects carry their checkout's repository (`HalC2.Projects.repository_identity/1`).
        "repositoryIdentity" => true,
        "serverResolvedCommandContext" => true,
        # GitHub pull requests through `gh` (`HalC2.PullRequests`), diff over HTTP.
        "pullRequests" => true,
        "pullRequestChecks" => true,
        # Threads link many pull requests, kept in sync with the host
        # (`HalC2.PullRequests.Sync`, `HalC2.PullRequests.Discovery`), and settle on their own
        # (`HalC2.Orchestration.Settlement`). Stack actions are not served.
        "threadPullRequests" => true,
        # Stacks merge and rebase as a whole (`HalC2.PullRequests.GitHubStack`).
        "pullRequestStackActions" => true,
        "threadPullRequestLinking" => true,
        "threadAutoSettlement" => true,
        # Files besides images upload to `HalC2.Attachments` too.
        "attachmentUploads" => true,
        "fileAttachments" => %{"maxUploadBytes" => 50 * 1024 * 1024},
        "questionAttachments" => true,
        # Context links become markers plus an envelope (`HalC2.ComposerContext`).
        "inlineMessageContext" => true,
        # A worktree that cannot be made fails its run; it never falls back to the root.
        "requiredWorktreeBootstrap" => true,
        "usagePriceOverrides" => true,
        # The icon setting persists, and `platform.machine` is detected.
        "environmentIcon" => true,
        # Project-scoped settings resolve per project (`HalC2.Settings.for_project/1`).
        "projectSettingsOverrides" => true,
        # Worktrees and browser artifacts are cleaned up by the rules (`HalC2.StorageCleanup`).
        # Turns a restart cut off go on when asked (`HalC2.Orchestration.Recovery`).
        "threadRestartContinuation" => true,
        # Themes in `<home>/themes` reach clients (`HalC2.EnvironmentThemes`).
        "environmentThemes" => true,
        # Quota from CLIProxyAPI hubs in settings (`HalC2.UsageLimitSources`).
        "usageLimitSources" => true,
        "storageCleanup" => true,
        # Releases move to a new version in place, or restart into it (`HalC2.Upgrade`).
        "serverSelfUpdateProgress" => HalC2.Upgrade.capability() != nil,
        "projectWorktreeCleanup" => true,
        # Thread commands `HalC2.Orchestration` understands (`@thread_updates`).
        "threadSettlement" => true,
        "threadSnooze" => true,
        "threadPinning" => true,
        "threadPinReorder" => true,
        "threadActiveReorder" => true,
        "threadVisitedTracking" => true,
        "threadTitleRegeneration" => true,
        "projectCloneTracking" => true
      }
    }

    # Only a release can install a version; a checkout omits the capability.
    case HalC2.Upgrade.capability() do
      nil -> base
      method -> put_in(base, ["capabilities", "serverSelfUpdate"], method)
    end
  end

  @doc """
  `server.refreshProviders`: probes the providers again, for one instance or all,
  and announces the new list to every client, then returns it. As the Node
  server's registry refresh does, each ACP agent is started again to read its
  version, sign-in and models; `refreshModels` also reads Codex's model list again.
  Subscription quota is read again too (`HalC2.ProviderUsageLimits`), and an untargeted
  refresh re-reads the usage-limit sources, as the Node server's status probe does,
  and a refresh of one ACP instance reads its agent again; a workspace refresh
  (with a `cwd`) leaves quota and probes alone.
  """
  def refresh_providers(input) do
    case input do
      # Antigravity's skills come from the workspace's folders (`HalC2.Acp.Antigravity.skills/2`).
      %{"cwd" => cwd, "instanceId" => id} when is_binary(cwd) and is_binary(id) ->
        if HalC2.Acp.driver(id) == "antigravity",
          do: HalC2.Acp.Antigravity.refresh_workspace(id, cwd)

      %{"cwd" => cwd} when is_binary(cwd) ->
        :ok

      %{"instanceId" => id} when is_binary(id) ->
        HalC2.ProviderUsageLimits.refresh([id])
        probe([id], input["refreshModels"] == true)

      _ ->
        HalC2.ProviderUsageLimits.refresh()
        HalC2.UsageLimitSources.refresh()
        probe(["codex" | HalC2.Acp.instances()], input["refreshModels"] == true)
    end

    {:ok, %{"providers" => providers()}}
  end

  # Agents are probed apart, so one slow agent does not hold up the others.
  defp probe(ids, models?) do
    if models? and "codex" in ids, do: HalC2.Codex.Provider.load()

    ids
    |> Enum.filter(&HalC2.Acp.agent?/1)
    |> Task.async_stream(&HalC2.Acp.reload/1, timeout: :infinity, max_concurrency: 4)
    |> Stream.run()

    HalC2.Settings.notify_providers()
  end

  @doc """
  The client's `ServerConfig` for this node. Only what a node serves today is
  filled in: Codex and Claude when installed, the user's keybinding rules, the installed editors, and
  the stored settings (`HalC2.Settings`), which decode to their defaults.
  """
  @spec server_config() :: map
  def server_config do
    %{
      "environment" => descriptor(),
      "auth" => %{
        "policy" => "loopback-browser",
        "bootstrapMethods" => ["one-time-token"],
        "sessionMethods" => ["bearer-access-token"],
        "sessionCookieName" => "hal_c2_session"
      },
      "cwd" => File.cwd!(),
      "keybindingsConfigPath" => Path.join(HalC2.Paths.config_dir(), "keybindings.json"),
      # Clients compile the rules with the defaults into `keybindings`.
      "keybindings" => [],
      "keybindingRules" => HalC2.Keybindings.rules(),
      "issues" => [],
      "providers" => providers(),
      "availableEditors" => HalC2.Editors.available(),
      "observability" =>
        %{
          "logsDirectoryPath" => Path.join(HalC2.Paths.state_dir(), "logs"),
          "localTracingEnabled" => HalC2.Traces.enabled?(),
          "otlpTracesEnabled" => HalC2.Traces.otlp_url() != nil,
          "otlpMetricsEnabled" => false,
          "otlpLogsEnabled" => false
        }
        |> then(
          &if(url = HalC2.Traces.otlp_url(), do: Map.put(&1, "otlpTracesUrl", url), else: &1)
        ),
      "settings" => HalC2.Settings.settings()
    }
  end

  @doc "`ServerConfig.providers`: the agents this node can run."
  def providers do
    (HalC2.Plugins.providers() || builtin_providers())
    |> Enum.map(
      &(&1
        |> with_identity()
        |> with_custom_models()
        |> HalC2.ProviderUsageLimits.put())
    )
  end

  # The name and accent colour the user gave an instance in settings, which every
  # picker shows it by.
  defp with_identity(%{"instanceId" => id} = entry) do
    instance = (HalC2.Settings.settings()["providerInstances"] || %{})[id]

    for key <- ["displayName", "accentColor"],
        is_map(instance),
        is_binary(instance[key]) and String.trim(instance[key]) != "",
        reduce: entry,
        do: (entry -> Map.put(entry, key, String.trim(instance[key])))
  end

  defp with_identity(entry), do: entry

  defp builtin_providers do
    for(
      entry <- [HalC2.Codex.Provider.entry(), HalC2.Claude.Provider.entry()],
      entry != nil,
      do: HalC2.ProviderUpdates.put_state(entry)
    ) ++ HalC2.Acp.entries()
  end

  # The model ids the user added in settings (`customModels`: bare slugs or
  # `{slug, name, capabilities}`) follow the provider's own models; one it already
  # lists is skipped.
  defp with_custom_models(%{"instanceId" => id, "driver" => driver} = entry) do
    custom =
      if driver in ["codex", "claudeAgent"],
        do: get_in(HalC2.Settings.settings(), ["providers", driver, "customModels"]),
        else: HalC2.Acp.setting(id, "customModels")

    models = entry["models"] || []

    added =
      for setting <- List.wrap(custom),
          %{"slug" => slug} = model <- [custom_model(setting)],
          reduce: [] do
        added ->
          if Enum.any?(models ++ added, &(&1["slug"] == slug)), do: added, else: added ++ [model]
      end

    if added == [], do: entry, else: Map.put(entry, "models", models ++ added)
  end

  defp with_custom_models(entry), do: entry

  defp custom_model(slug) when is_binary(slug), do: custom_model(%{"slug" => slug})

  defp custom_model(%{"slug" => slug} = setting) when is_binary(slug) do
    case String.trim(slug) do
      "" ->
        nil

      slug ->
        name = if is_binary(setting["name"]), do: String.trim(setting["name"]), else: ""

        %{
          "slug" => slug,
          "name" => if(name == "", do: slug, else: name),
          "isCustom" => true,
          "capabilities" => setting["capabilities"] || %{"optionDescriptors" => []}
        }
    end
  end

  defp custom_model(_), do: nil

  @spec id() :: String.t()
  def id do
    case :persistent_term.get({__MODULE__, :id}, nil) do
      nil ->
        path = Path.join(HalC2.Paths.data_dir(), "environment-id")

        id =
          case File.read(path) do
            {:ok, id} ->
              String.trim(id)

            {:error, :enoent} ->
              id = uuid4()
              File.mkdir_p!(Path.dirname(path))
              File.write!(path, id)
              id
          end

        :persistent_term.put({__MODULE__, :id}, id)
        id

      id ->
        id
    end
  end

  @doc "The name this machine goes by: `HAL_C2_LABEL`, else its hostname."
  def label do
    case System.get_env("HAL_C2_LABEL") do
      nil ->
        {:ok, host} = :inet.gethostname()
        List.to_string(host)

      label ->
        label
    end
  end

  defp platform do
    base = %{"os" => os(), "arch" => arch()}

    case HalC2.Environment.Machine.kind() do
      nil -> base
      machine -> Map.put(base, "machine", machine)
    end
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "win32"
      {_, other} -> Atom.to_string(other)
    end
  end

  defp arch do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      arch =~ ~r/aarch64|arm64/ -> "arm64"
      arch =~ ~r/x86_64|amd64/ -> "x64"
      true -> arch
    end
  end

  defp version, do: HalC2.Upgrade.version()

  @doc "A random (v4) UUID."
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      Enum.join(
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ],
        "-"
      )
    end)
  end
end
