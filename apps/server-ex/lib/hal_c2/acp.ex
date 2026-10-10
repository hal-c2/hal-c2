defmodule HalC2.Acp do
  @moduledoc """
  The Agent Client Protocol agents an MC can run (`HalC2.Acp.ThreadRuntime`), and
  their entries in `ServerConfig.providers`: the built-in OpenCode and Grok, more
  instances of them, and `acpRegistry` instances running an agent from the ACP
  Registry (`HalC2.Acp.Catalog`). Everything is keyed by provider instance id.

  Built-in agents are off until enabled in the MC's settings (`providers.<driver>`
  or a `providerInstances` entry), so nothing is spawned for
  users who never opted in; a registry instance is on once added. An enabled agent's model list comes from the `model`
  config option of a throwaway session, which lists the models of the providers it
  is connected to; it is read once, at boot or when the agent is first enabled.
  """

  alias HalC2.JsonRpc.Connection

  @agents %{
    "opencode" => %{binary: "opencode", label: "OpenCode"},
    "grok" => %{binary: "grok", label: "Grok"},
    # The Cursor SDK behind ACP (`packages/cursor-acp`), run by Node.
    "cursor" => %{binary: "node", label: "Cursor"},
    # Pi in its own RPC mode (`HalC2.Pi`), not ACP: listed here for its provider entry.
    "pi" => %{binary: "pi", label: "Pi"},
    # Google's Antigravity agent, from the MC's managed runtime (`HalC2.Acp.Antigravity`).
    "antigravity" => %{binary: "agy_acp_server.par", label: "Antigravity"}
  }

  # The Cursor sidecar: bundled under priv/ in a release, from packages/ in a checkout.
  @cursor_checkout Path.expand("../../../../packages/cursor-acp/src/main.ts", __DIR__)

  @opencode_minimum "1.14.19"
  @pi_minimum "0.80.5"
  @pi_modes ~w(approval-required auto-accept-edits full-access)
  # Deferring to the model in the user's own Pi settings.
  @pi_default %{
    "slug" => "default",
    "name" => "Pi default",
    "isCustom" => false,
    "isDefault" => true,
    "capabilities" => nil
  }
  @compact %{
    "name" => "compact",
    "description" => "Summarize the conversation and reduce context usage"
  }

  # Instances of this driver run an agent from the ACP Registry (`HalC2.Acp.Catalog`).
  @registry "acpRegistry"

  @doc "Instance ids of the ACP agents: the built-in agents and configured instances."
  def instances do
    configured =
      for {id, %{"driver" => driver}} <- HalC2.Settings.settings()["providerInstances"] || %{},
          driver == @registry or Map.has_key?(@agents, driver),
          do: id

    Enum.uniq(Map.keys(@agents) ++ configured)
  end

  @doc "Whether a provider instance runs over ACP."
  def agent?(instance), do: instance(instance) != nil

  # `{driver, instance settings}`; a built-in agent's id is its own default instance.
  defp instance(id) do
    case (HalC2.Settings.settings()["providerInstances"] || %{})[id] do
      %{"driver" => driver} = entry when driver == @registry ->
        {driver, entry}

      %{"driver" => driver} = entry ->
        if Map.has_key?(@agents, driver), do: {driver, entry}, else: builtin(id)

      _ ->
        builtin(id)
    end
  end

  defp builtin(id), do: if(Map.has_key?(@agents, id), do: {id, %{}})

  @doc "The driver an instance runs (\"grok\", \"opencode\", \"pi\", ...), or nil."
  def driver(instance) do
    case instance(instance) do
      {driver, _entry} -> driver
      nil -> nil
    end
  end

  @doc """
  A driver setting of an instance: its own `config` value, else the driver's in
  `providers.<driver>`; blank strings count as unset.
  """
  def setting(id, key) do
    with {driver, entry} <- instance(id) do
      [
        get_in(entry, ["config", key]),
        get_in(HalC2.Settings.settings(), ["providers", driver, key])
      ]
      |> Enum.find(&(&1 not in [nil, ""] and not (is_binary(&1) and String.trim(&1) == "")))
    end
  end

  def label(instance) do
    case instance(instance) do
      {_, %{"displayName" => name}} when is_binary(name) -> name
      {@registry, entry} -> get_in(entry, ["config", "agentId"]) || instance
      {driver, _} -> @agents[driver].label
      nil -> instance
    end
  end

  @doc """
  The command and environment that start an instance's agent for a thread's
  runtime mode: the binary set in its settings, or a registry agent's install;
  `:acp_commands` overrides it (tests).
  """
  def command(instance, runtime_mode \\ nil) do
    override = Application.get_env(:hal_c2, :acp_commands, %{})[instance]

    case override || instance(instance) do
      [_ | _] = command ->
        {:ok, command, instance_env(instance)}

      {@registry, entry} ->
        with {:ok, command, env} <- HalC2.Acp.Catalog.command(entry["config"] || %{}),
             do: {:ok, command, env ++ instance_env(instance)}

      {"cursor", _entry} ->
        credentials = cursor_credentials(instance)

        {:ok, [node_command(), cursor_script(), "--mode", runtime_mode || "approval-required"],
         [{"HAL_C2_CURSOR_CREDENTIALS", credentials} | instance_env(instance)]}

      {"pi", entry} ->
        {:ok, [binary("pi", entry, "pi"), "--mode", "rpc"], instance_env(instance)}

      {"antigravity", _entry} ->
        HalC2.Acp.Antigravity.command(instance)

      {driver, entry} ->
        binary = binary(driver, entry, @agents[driver].binary)
        {:ok, [binary | args(driver, runtime_mode)], instance_env(instance)}

      nil ->
        {:error, "unknown ACP agent #{instance}"}
    end
  end

  defp cursor_script do
    released = Application.app_dir(:hal_c2, "priv/cursor-acp/main.mjs")
    if File.exists?(released), do: released, else: @cursor_checkout
  end

  defp node_command do
    case System.get_env("HAL_C2_NODE_COMMAND") do
      command when command in [nil, ""] -> "node"
      command -> command
    end
  end

  @doc "The executable an instance runs: its `binaryPath` setting, else its driver's binary."
  def binary_path(id) do
    case instance(id) do
      {driver, entry} -> binary(driver, entry, @agents[driver][:binary] || driver)
      nil -> nil
    end
  end

  @doc """
  The variables set on an instance in settings, such as an API key, as `{name, value}`
  pairs; sensitive ones come from the secret store (`HalC2.ProviderSecrets`).
  """
  def instance_env(id) when is_binary(id) do
    case instance(id) do
      {_driver, entry} -> HalC2.ProviderSecrets.environment(id, entry)
      nil -> []
    end
  end

  defp args("opencode", _mode), do: ["acp"]

  # Grok applies permissions itself; full access skips its prompts entirely.
  defp args("grok", "full-access"), do: ["agent", "--always-approve", "stdio"]
  defp args("grok", "approval-required"), do: ["--permission-mode", "default", "agent", "stdio"]

  defp args("grok", "auto-accept-edits"),
    do: ["--permission-mode", "acceptEdits", "agent", "stdio"]

  defp args("grok", "auto"), do: ["--permission-mode", "auto", "agent", "stdio"]
  defp args("grok", _mode), do: ["agent", "stdio"]

  # A path the user wrote as `~/bin/grok` names their home directory, as a shell would.
  defp binary(driver, entry, default) do
    [
      get_in(entry, ["config", "binaryPath"]),
      get_in(HalC2.Settings.settings(), ["providers", driver, "binaryPath"])
    ]
    |> Enum.find(default, &(is_binary(&1) and String.trim(&1) != ""))
    |> String.trim()
    |> case do
      "~" -> HalC2.Paths.user_home()
      "~/" <> rest -> Path.join(HalC2.Paths.user_home(), rest)
      path -> path
    end
  end

  @doc "Provider entries for the ACP instances on this MC whose agent is available."
  def entries, do: for(id <- instances(), entry = entry(id), do: entry)

  def entry(id) do
    with {driver, instance} <- instance(id),
         {:ok, base} <- base_entry(id, driver, instance) do
      enabled = enabled?(id)
      models = :persistent_term.get({__MODULE__, id, :models}, nil)
      failure = :persistent_term.get({__MODULE__, id, :error}, nil)
      if enabled and models == nil and failure == nil, do: load_once(id)

      Map.merge(
        %{
          "instanceId" => id,
          "driver" => driver,
          "enabled" => enabled,
          "installed" => true,
          "version" => :persistent_term.get({__MODULE__, id, :version}, "unknown"),
          "status" =>
            cond do
              not enabled -> "disabled"
              failure -> "error"
              empty_catalog?(driver, models) -> "warning"
              true -> "ready"
            end,
          "availability" => "available",
          # `HalC2.TextGeneration` runs these; registry agents and Pi write no commits or titles.
          "supportsTextGeneration" => driver in ~w(grok opencode cursor),
          # ACP agents run without HAL-C2's plan mode.
          "showInteractionModeToggle" => false,
          "auth" => %{"status" => "authenticated"},
          "checkedAt" => HalC2.Orchestration.Entities.now(),
          "models" => custom_models(models || [], instance),
          "slashCommands" => [],
          "skills" => []
        },
        base
      )
      |> then(&if(failure, do: Map.put(&1, "message", failure), else: &1))
      |> then(
        &if(empty_catalog?(driver, models) and !failure,
          do: Map.put(&1, "message", "Cursor SDK model discovery returned no built-in models."),
          else: &1
        )
      )
      |> Map.merge(capability_fields(capabilities(id)))
      |> Map.merge(access(id, base["setup"]))
      |> then(
        &if(notice = :persistent_term.get({__MODULE__, id, :notice}, nil),
          do: Map.put(&1, "message", notice),
          else: &1
        )
      )
      |> then(
        &if(enabled,
          do: &1,
          else:
            Map.put(
              &1,
              "message",
              "#{&1["displayName"] || label(id)} is disabled in HAL-C2 settings."
            )
        )
      )
      |> driver_fields(driver, id, instance)
    else
      _ -> nil
    end
  end

  # Cursor always offers "default" (Auto); a catalog with nothing else found no models.
  defp empty_catalog?("cursor", [_ | _] = models),
    do: Enum.all?(models, &(&1["slug"] == "default"))

  defp empty_catalog?(_driver, _models), do: false

  # Cursor tells a refused sign-in from a missing one.
  defp signed_out_message(id) do
    case instance(id) do
      {"cursor", _entry} ->
        cond do
          api_key?(id) ->
            "Cursor SDK authentication failed. Check CURSOR_API_KEY."

          File.exists?(cursor_credentials(id)) ->
            "Cursor sign-in expired or was rejected. Sign in again in provider settings."

          true ->
            "Sign in with Cursor or add CURSOR_API_KEY in provider settings."
        end

      {"grok", _} ->
        "Grok CLI is installed but not logged in. Run `grok login`."

      _ ->
        "Sign in to use this agent."
    end
  end

  @doc "Why an instance cannot start a browser sign-in, or nil."
  def sign_in_refusal(id) do
    case instance(id) do
      {"cursor", _entry} ->
        if api_key?(id),
          do:
            "Remove CURSOR_API_KEY from this provider's environment before using browser sign-in."

      _ ->
        nil
    end
  end

  defp api_key?(id),
    do:
      Enum.any?(instance_env(id), fn {k, v} ->
        k == "CURSOR_API_KEY" and String.trim(v) != ""
      end)

  @doc false
  # Each instance keeps its own Cursor sign-in, owner-only, in the MC's data.
  def cursor_credentials(id),
    do: Path.join([HalC2.Paths.data_dir(), "provider-auth", id, "cursor.json"])

  # A registry agent is installed when first used, so it counts as available.
  defp base_entry(id, @registry, instance) do
    agent_id = get_in(instance, ["config", "agentId"])

    case HalC2.Acp.Catalog.describe(agent_id) do
      nil ->
        :error

      agent ->
        {:ok,
         %{
           "displayName" => instance["displayName"] || agent.name,
           "iconUrl" => "https://cdn.agentclientprotocol.com/registry/v1/latest/#{agent_id}.svg",
           "version" => :persistent_term.get({__MODULE__, id, :version}, agent.version)
         }
         |> then(
           &if(agent.website,
             do: Map.put(&1, "setup", %{"documentationUrl" => agent.website}),
             else: &1
           )
         )}
    end
  end

  # Pi is offered where Pi is installed; its adapter installs when first used.
  defp base_entry(_id, "pi", instance) do
    if System.find_executable(binary("pi", instance, "pi")), do: {:ok, %{}}, else: :error
  end

  # Antigravity is always listed: its entry says how to install or sign in.
  defp base_entry(_id, "antigravity", instance) do
    {:ok, if(instance["displayName"], do: %{"displayName" => instance["displayName"]}, else: %{})}
  end

  defp base_entry(id, _driver, instance) do
    with {:ok, [executable | _], _env} <- command(id),
         path when is_binary(path) <- System.find_executable(executable) do
      {:ok,
       if(instance["displayName"], do: %{"displayName" => instance["displayName"]}, else: %{})}
    else
      _ -> :error
    end
  end

  # What the agent can do with its own sessions and model providers.
  defp capability_fields(nil), do: %{}

  defp capability_fields(caps) do
    sessions = caps["sessionCapabilities"] || %{}

    %{
      "nativeSessions" => %{
        "canList" => is_map(sessions["list"]),
        "canLoad" => caps["loadSession"] == true,
        "canResume" => is_map(sessions["resume"]),
        "canDelete" => is_map(sessions["delete"])
      },
      "configurableProviders" => is_map(caps["providers"])
    }
  end

  # Whether the agent can be signed in here (`HalC2.ProviderAuth`), and whether it must be.
  defp access(id, setup) do
    methods = :persistent_term.get({__MODULE__, id, :auth_methods}, 0)
    signed_out = :persistent_term.get({__MODULE__, id, :unauthenticated}, false)

    %{
      "setup" =>
        Map.merge(%{"canAuthenticate" => methods > 0, "canInstall" => false}, setup || %{}),
      "auth" =>
        %{
          "status" =>
            cond do
              signed_out -> "unauthenticated"
              capabilities(id) == nil -> "unknown"
              true -> "authenticated"
            end,
          "canLogout" => is_map(get_in(capabilities(id) || %{}, ["auth", "logout"]))
        }
        |> then(fn auth ->
          case HalC2.Acp.UrlAuth.action(id) do
            nil -> auth
            action -> Map.put(auth, "action", action)
          end
        end)
    }
  end

  @doc "Reads each enabled agent's version and models from a throwaway session."
  def load do
    # Apart, so one agent waiting on a sign-in does not hold up the others.
    instances()
    |> Enum.filter(&enabled?/1)
    |> Task.async_stream(&load/1, timeout: :infinity, max_concurrency: 4)
    |> Stream.run()
  end

  # An agent enabled after boot is read in the background, once.
  defp load_once(id) do
    if :persistent_term.get({__MODULE__, id, :loading}, false) == false do
      :persistent_term.put({__MODULE__, id, :loading}, true)
      Task.start(fn -> load(id) end)
    end
  end

  @doc "Whether the MC's settings enable an instance (built-in agents are off by default)."
  def enabled?(id) do
    case instance(id) do
      nil -> false
      {driver, instance} -> enabled?(id, driver, instance)
    end
  end

  defp enabled?(id, driver, instance) do
    cond do
      instance["enabled"] == false or get_in(instance, ["config", "enabled"]) == false ->
        false

      is_boolean(instance["enabled"]) ->
        instance["enabled"]

      is_boolean(get_in(instance, ["config", "enabled"])) ->
        get_in(instance, ["config", "enabled"])

      driver == @registry ->
        true

      true ->
        id == driver and
          get_in(HalC2.Settings.settings(), ["providers", driver, "enabled"]) == true
    end
  end

  defp load(id) do
    dir = Path.join(System.tmp_dir!(), "hal-c2-acp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      case read_agent(id, dir) do
        :ok ->
          :persistent_term.erase({__MODULE__, id, :error})

        {:error, :unauthenticated} ->
          :persistent_term.put({__MODULE__, id, :error}, signed_out_message(id))
          :persistent_term.put({__MODULE__, id, :unauthenticated}, true)

        {:error, reason} ->
          :persistent_term.put({__MODULE__, id, :error}, describe(reason))

        _ ->
          :ok
      end
    catch
      _, _ -> :ok
    after
      File.rm_rf(dir)
      HalC2.Settings.notify_providers()
    end
  end

  # A probe's call, answering the agent meanwhile: a sign-in page it asks for waits
  # for a user (`HalC2.Acp.UrlAuth`), so the call may take as long as that allows.
  defp call_serving(conn, id, method, params) do
    task = Task.async(fn -> Connection.call(conn, method, params, :timer.minutes(11)) end)
    serve(conn, id, task)
  end

  defp serve(conn, id, task) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:json_rpc, ^conn, {:request, rpc_id, "elicitation/create", %{"mode" => "url"} = params}} ->
        Task.start(fn ->
          Connection.respond(conn, rpc_id, {:ok, HalC2.Acp.UrlAuth.request(id, params)})
        end)

        serve(conn, id, task)

      {:json_rpc, ^conn, {:request, rpc_id, method, _params}} ->
        Connection.respond(conn, rpc_id, {:error, %{"code" => -32601, "message" => method}})
        serve(conn, id, task)

      {:json_rpc, ^conn, _notification} ->
        serve(conn, id, task)
    end
  end

  defp describe(%{"message" => message}) when is_binary(message), do: message
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp read_agent(id, dir) do
    {driver, entry} = instance(id)

    case driver == "opencode" && setting(id, "serverUrl") do
      url when is_binary(url) -> read_server(id, url, setting(id, "serverPassword"))
      _ -> read_agent(id, dir, driver, entry)
    end
  end

  # Pi's models, commands and skills come from Pi's own RPC mode (`HalC2.Pi`). Pi may
  # stop at a startup prompt only a live session can answer, so a failed read still
  # offers "Pi default"; refused launch arguments are the provider's error.
  defp read_agent(id, dir, "pi", entry) do
    with :ok <- check_version(id, "pi", entry),
         {:ok, _args} <- HalC2.Pi.resolve_launch_args(setting(id, "launchArgs")) do
      :persistent_term.put({__MODULE__, id, :capabilities}, %{})

      case HalC2.Pi.discover(id, dir) do
        {:ok, %{models: models, commands: commands, skills: skills}} ->
          :persistent_term.put({__MODULE__, id, :models}, [@pi_default | models])
          :persistent_term.put({__MODULE__, id, :commands}, commands)
          :persistent_term.put({__MODULE__, id, :skills}, skills)
          :persistent_term.put({__MODULE__, id, :pi_signed_out}, models == [])

        {:error, _} ->
          :persistent_term.put({__MODULE__, id, :models}, [@pi_default])

          :persistent_term.put(
            {__MODULE__, id, :notice},
            "Pi is available, but HAL-C2 could not refresh its models and commands. The live session will retry startup."
          )
      end

      :ok
    end
  end

  defp read_agent(id, dir, driver, entry) do
    with :ok <- check_version(id, driver, entry) do
      with_agent(id, dir, fn conn, init ->
        :persistent_term.put(
          {__MODULE__, id, :version},
          get_in(init, ["agentInfo", "version"]) || "unknown"
        )

        :persistent_term.put({__MODULE__, id, :capabilities}, init["agentCapabilities"] || %{})
        :persistent_term.put({__MODULE__, id, :auth_methods}, length(init["authMethods"] || []))
        :persistent_term.put({__MODULE__, id, :meta}, init["_meta"] || %{})

        # Antigravity's models come from its sign-in and sessions
        # (`HalC2.Acp.Antigravity.account/1`); a probe session would need a Google login.
        case if(driver == "antigravity",
               do: {:ok, %{}},
               else: call_serving(conn, id, "session/new", %{"cwd" => dir, "mcpServers" => []})
             ) do
          {:ok, session} ->
            :persistent_term.put({__MODULE__, id, :config}, session["configOptions"] || [])
            :persistent_term.put({__MODULE__, id, :models}, models(session))

          # ACP's "authentication required".
          {:error, %{"code" => -32000}} ->
            {:error, :unauthenticated}

          {:error, _} = error ->
            error
        end
      end)
    end
  end

  # An OpenCode server run elsewhere (`serverUrl`, with `serverPassword` as the
  # `opencode` user's basic auth): its connected providers' models and its
  # failures explained.
  defp read_server(id, url, password) do
    auth = if password, do: {:basic, "opencode", password}
    base = String.trim_trailing(url, "/")

    case HalC2.ProviderUsageLimits.get_json(base <> "/provider", auth, 10_000) do
      {:ok, 200, %{"all" => all} = list} ->
        connected = MapSet.new(list["connected"] || [])

        models =
          for %{"id" => provider} = entry <- all,
              MapSet.member?(connected, provider),
              {model_id, model} <- entry["models"] || %{},
              is_binary(model["name"]) and String.trim(model["name"]) != "" do
            %{
              "slug" => "#{provider}/#{model["id"] || model_id}",
              "name" => String.trim(model["name"]),
              "isCustom" => false,
              "capabilities" => nil
            }
            |> then(&if(entry["name"], do: Map.put(&1, "subProvider", entry["name"]), else: &1))
          end

        :persistent_term.put({__MODULE__, id, :models}, Enum.sort_by(models, & &1["name"]))
        :ok

      {:ok, status, _} when status in [401, 403] ->
        {:error, "OpenCode server rejected authentication. Check the server URL and password."}

      {:ok, status, _} ->
        {:error, "Failed to connect to the configured OpenCode server (HTTP #{status})."}

      {:error, _} ->
        {:error,
         "Couldn't reach the configured OpenCode server at #{url}. Check that the server is running and the URL is correct."}
    end
  end

  # HAL-C2 drives Pi #{@pi_minimum} or newer (`pi --version`).
  defp check_version(id, "pi", entry) do
    output =
      with path when is_binary(path) <- System.find_executable(binary("pi", entry, "pi")),
           task = Task.async(fn -> System.cmd(path, ["--version"], stderr_to_stdout: true) end),
           {:ok, {out, 0}} <- Task.yield(task, 10_000) || Task.shutdown(task) do
        out
      else
        _ -> ""
      end

    case Regex.run(~r/\d+\.\d+\.\d+/, output) do
      [version] ->
        :persistent_term.put({__MODULE__, id, :version}, version)

        if Version.compare(version, @pi_minimum) == :lt,
          do: {:error, "Pi #{version} is unsupported. Update to Pi #{@pi_minimum} or newer."},
          else: :ok

      nil ->
        {:error,
         "HAL-C2 could not determine the Pi version. Pi #{@pi_minimum} or newer is required."}
    end
  end

  defp check_version(_id, _driver, _entry), do: :ok

  # --- per-driver fields --------------------------------------------------------

  defp driver_fields(entry, "grok", id, _instance) do
    meta = :persistent_term.get({__MODULE__, id, :meta}, nil) || %{}

    entry
    |> Map.merge(%{
      # Grok cannot rewind its own conversation.
      "supportsConversationRollback" => false,
      "slashCommands" => grok_commands(meta["availableCommands"])
    })
    |> Map.update!("models", &grok_reasoning(&1, get_in(meta, ["modelState", "availableModels"])))
    |> Map.update!("auth", &grok_auth(&1, id))
  end

  defp driver_fields(entry, "opencode", id, instance) do
    config = :persistent_term.get({__MODULE__, id, :config}, [])

    entry
    |> Map.update!("models", &opencode_options(&1, config))
    |> opencode_version(id, instance)
  end

  defp driver_fields(entry, "pi", id, _instance) do
    # Pi's permission gate has no classifier to run auto on.
    entry =
      Map.merge(entry, %{
        "supportedRuntimeModes" => @pi_modes,
        "slashCommands" => :persistent_term.get({__MODULE__, id, :commands}, []),
        "skills" => :persistent_term.get({__MODULE__, id, :skills}, [])
      })

    if entry["status"] == "ready" and
         :persistent_term.get({__MODULE__, id, :pi_signed_out}, false),
       do:
         Map.merge(entry, %{
           "status" => "warning",
           "auth" => Map.put(entry["auth"], "status", "unauthenticated"),
           "message" =>
             "Pi has no usable models. Run `pi` in a terminal and use /login, or configure an API key in ~/.pi/agent."
         }),
       else: entry
  end

  defp driver_fields(entry, "antigravity", id, _instance),
    do: HalC2.Acp.Antigravity.entry_fields(entry, id)

  # Cursor has a plan mode of its own, which the thread's plan toggle chooses.
  defp driver_fields(entry, "cursor", _id, _instance),
    do: Map.put(entry, "showInteractionModeToggle", true)

  # What a registry agent's running session advertises (`put_commands/2`).
  defp driver_fields(entry, "acpRegistry", id, _instance) do
    Map.merge(entry, %{
      "slashCommands" => :persistent_term.get({__MODULE__, id, :commands}, []),
      "skills" => :persistent_term.get({__MODULE__, id, :skills}, [])
    })
  end

  defp driver_fields(entry, _driver, _id, _instance), do: entry

  defp opencode_version(entry, id, _instance) do
    case stable_version(entry["version"]) do
      nil ->
        entry

      version ->
        entry = HalC2.ProviderCompatibility.put(entry)

        cond do
          Version.compare(version, @opencode_minimum) == :lt ->
            Map.merge(entry, %{
              "status" => "error",
              "models" => [],
              "message" =>
                "OpenCode v#{version} is too old. Upgrade to v#{@opencode_minimum} or newer."
            })

          entry["status"] == "ready" and
              :persistent_term.get({__MODULE__, id, :models}, nil) == [] ->
            Map.merge(entry, %{
              "status" => "warning",
              "message" =>
                "OpenCode is available, but it did not report any connected upstream providers."
            })

          true ->
            entry
        end
    end
  end

  # OpenCode's reasoning variants and agents per model (`openCodeCapabilitiesForModel`):
  # the session's `effort` choices are the current model's variants, other models get
  # the standard levels; its `mode` choices are the primary agents.
  defp opencode_options(models, config) do
    option = fn id -> Enum.find(config, &(&1["id"] == id)) || %{} end
    current = option.("model")["currentValue"]
    variants = for %{"value" => v} <- option.("effort")["options"] || [], v != "default", do: v
    agents = for %{"value" => v} <- option.("mode")["options"] || [], do: v

    Enum.map(models, fn model ->
      provider = model["slug"] |> String.split("/") |> hd()

      variants =
        if model["slug"] == current and variants != [],
          do: variants,
          else: ~w(low medium high xhigh)

      descriptors =
        [
          select("variant", "Reasoning", variants, default_variant(provider, variants)),
          agents != [] &&
            select("agent", "Agent", agents, if("build" in agents, do: "build", else: hd(agents)))
        ]
        |> Enum.filter(& &1)

      Map.put(model, "capabilities", %{"optionDescriptors" => descriptors})
    end)
  end

  defp select(id, label, values, default) do
    %{
      "id" => id,
      "label" => label,
      "type" => "select",
      "options" =>
        for value <- values do
          %{"id" => value, "label" => title_case(value)}
          |> then(&if(value == default, do: Map.put(&1, "isDefault", true), else: &1))
        end
    }
    |> then(&if(default, do: Map.put(&1, "currentValue", default), else: &1))
  end

  defp default_variant(_provider, [only]), do: only

  defp default_variant(provider, variants) do
    cond do
      provider == "anthropic" or String.starts_with?(provider, "google") ->
        if "high" in variants, do: "high"

      provider in ["openai", "opencode"] ->
        Enum.find(["medium", "high"], &(&1 in variants))

      true ->
        nil
    end
  end

  defp title_case(value) do
    value
    |> String.split(~r/[-_\/]+/, trim: true)
    |> Enum.map_join(" ", fn <<first::utf8, rest::binary>> ->
      String.upcase(<<first::utf8>>) <> rest
    end)
  end

  # An API key set on the instance signs Grok in; otherwise its own login does.
  defp grok_auth(auth, id) do
    key =
      Enum.find_value(instance_env(id), fn {name, value} ->
        name == "XAI_API_KEY" and String.trim(value) != ""
      end)

    cond do
      key ->
        Map.merge(auth, %{
          "status" => "authenticated",
          "type" => "api_key",
          "label" => "xAI API key"
        })

      auth["status"] == "authenticated" ->
        Map.merge(auth, %{"type" => "cached_token", "label" => "Grok account"})

      true ->
        auth
    end
  end

  # Grok's commands from `initialize`; permissions change through HAL-C2 only, and
  # /context completes without output.
  defp grok_commands(commands) do
    offered =
      for %{"name" => name} = command when is_binary(name) <- List.wrap(commands),
          name = String.trim(name),
          name != "",
          String.downcase(name) not in ["always-approve", "context"] do
        %{"name" => name}
        |> put_text("description", command["description"])
        |> then(fn c ->
          case get_in(command, ["input", "hint"]) do
            hint when is_binary(hint) and hint != "" ->
              Map.put(c, "input", %{"hint" => String.trim(hint)})

            _ ->
              c
          end
        end)
      end

    compact = Enum.find(offered, @compact, &(&1["name"] == "compact"))
    [compact | Enum.reject(offered, &(&1["name"] == "compact"))]
  end

  defp put_text(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      text -> Map.put(map, key, text)
    end
  end

  defp put_text(map, _key, _value), do: map

  # Reasoning levels a Grok model advertises in `initialize`'s model state.
  defp grok_reasoning(models, [_ | _] = available) do
    by_id = Map.new(available, &{&1["modelId"], &1["_meta"] || %{}})

    Enum.map(models, fn model ->
      case reasoning_descriptor(by_id[model["slug"]] || %{}) do
        nil -> model
        descriptor -> Map.put(model, "capabilities", %{"optionDescriptors" => [descriptor]})
      end
    end)
  end

  defp grok_reasoning(models, _available), do: models

  defp reasoning_descriptor(%{"supportsReasoningEffort" => false}), do: nil

  defp reasoning_descriptor(meta) do
    options =
      (meta["reasoningEfforts"] || [])
      |> Enum.flat_map(fn
        %{} = effort ->
          case Enum.find(
                 [effort["value"], effort["id"]],
                 &(is_binary(&1) and &1 =~ ~r/^[a-z0-9_-]+$/i)
               ) do
            nil -> []
            value -> [{value, effort}]
          end

        _ ->
          []
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    current =
      if Enum.any?(options, &(elem(&1, 0) == meta["reasoningEffort"])),
        do: meta["reasoningEffort"]

    advertised =
      for {value, effort} <- options,
          effort["default"] == true or effort["isDefault"] == true,
          do: value

    default = if current in advertised, do: current, else: List.first(advertised)

    if options != [] do
      %{
        "id" => "reasoningEffort",
        "label" => "Reasoning",
        "type" => "select",
        "options" =>
          for {value, effort} <- options do
            %{
              "id" => value,
              "label" =>
                (is_binary(effort["label"]) && String.trim(effort["label"]) != "" &&
                   String.trim(effort["label"])) || value
            }
            |> put_text("description", effort["description"])
            |> then(&if(value == default, do: Map.put(&1, "isDefault", true), else: &1))
          end
      }
      |> then(
        &if(current || default, do: Map.put(&1, "currentValue", current || default), else: &1)
      )
    end
  end

  defp stable_version(version) when is_binary(version) do
    case Regex.run(~r/^v?(\d+\.\d+\.\d+)$/, String.trim(version)) do
      [_, stable] -> stable
      _ -> nil
    end
  end

  defp stable_version(_version), do: nil

  @doc """
  Starts an instance's agent in `cwd` (for `runtime_mode`, see `command/2`),
  initializes it, and calls `fun.(conn, initialize_result)`; the agent stops when
  `fun` returns.
  """
  def with_agent(id, cwd, fun, runtime_mode \\ nil) do
    with {:ok, command, env} <- command(id, runtime_mode),
         {:ok, conn} <-
           Connection.start_link(cmd: command, handler: self(), cd: cwd, env: env, dialect: :v2) do
      try do
        with {:ok, init} <- Connection.call(conn, "initialize", initialize_params()),
             do: fun.(conn, init)
      after
        Connection.stop(conn)
      end
    end
  end

  @doc """
  `initialize` for management and sign-in connections: the client can show a URL
  (`elicitation/create`) and run a login command in a terminal.
  """
  def initialize_params do
    %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false,
        "auth" => %{"terminal" => true},
        "elicitation" => %{"url" => %{}}
      },
      "clientInfo" => %{"name" => "hal-c2", "version" => "0.1.0"}
    }
  end

  @doc "The agent capabilities an instance reported when it was last probed, or `nil`."
  def capabilities(id), do: :persistent_term.get({__MODULE__, id, :capabilities}, nil)

  # A `$name` mention: a currency sign and a name, not an amount such as `$20` or `$5k`.
  @skill_mention ~r/(^|\s)\p{Sc}(?![0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?(?:\s|$))(?=[a-zA-Z0-9:_-]*[a-zA-Z])([a-zA-Z0-9][a-zA-Z0-9:_-]*)(?=\s|$)/u

  @doc """
  `text` with each `$name` that mentions one of Cursor's skills in `cwd` written as
  Cursor takes it, `/name`. Other
  mentions, and amounts of money, are left as they are.
  """
  def cursor_skill_mentions(text, cwd) do
    names = cursor_skills(cwd)

    Regex.replace(@skill_mention, text, fn match, prefix, name ->
      if MapSet.member?(names, name), do: prefix <> "/" <> name, else: match
    end)
  end

  # The names of the skills Cursor loads in `cwd`: each folder with a SKILL.md under
  # the project's and the user's `.cursor`, `.agents`, `.codex` and `.claude` skills,
  # by its frontmatter `name`, else the folder's.
  defp cursor_skills(cwd) do
    for base <- [cwd, HalC2.Paths.user_home()],
        is_binary(base),
        root <- ~w(.cursor .agents .codex .claude),
        dir = Path.join([base, root, "skills"]),
        {:ok, entries} <- [File.ls(dir)],
        entry <- entries,
        {:ok, body} <- [File.read(Path.join([dir, entry, "SKILL.md"]))],
        into: MapSet.new() do
      case Regex.run(~r/\A---\s*\n.*?^name:\s*["']?([^"'\n]+?)["']?\s*$/ms, body) do
        [_, name] -> String.trim(name)
        _ -> entry
      end
    end
  end

  @doc """
  Whether a registry agent is signed out: one that refused its last check for want of
  a sign-in is checked again now, since the user may have signed in outside HAL-C2.
  """
  def signed_out?(id) do
    if driver(id) == @registry and :persistent_term.get({__MODULE__, id, :unauthenticated}, false) do
      reload(id)
      :persistent_term.get({__MODULE__, id, :unauthenticated}, false)
    else
      false
    end
  end

  @doc "Reads one instance's agent again, now."
  def reload(id) do
    forget(id)
    if enabled?(id), do: load(id)
    :ok
  end

  @doc "Forgets what was read from an instance's agent, so it is probed again."
  def forget(id) do
    for key <- [
          :models,
          :version,
          :capabilities,
          :auth_methods,
          :unauthenticated,
          :error,
          :loading,
          :meta,
          :notice,
          :config,
          :commands,
          :skills,
          :pi_signed_out
        ],
        do: :persistent_term.erase({__MODULE__, id, key})

    :ok
  end

  @doc """
  Replaces an instance's models with those of a session's `configOptions`, as an
  agent reports them mid-session, and tells subscribed clients.
  """
  def put_models(id, config_options) do
    if Enum.any?(config_options, &(&1["id"] == "model")) do
      :persistent_term.put(
        {__MODULE__, id, :models},
        models(%{"configOptions" => config_options})
      )

      HalC2.Settings.notify_providers()
    end

    :ok
  end

  @max_commands 200

  @doc """
  Replaces a registry instance's commands with those its session advertises (ACP's
  `available_commands_update`), and tells subscribed clients. A name starting with
  `$` is a skill of the agent's; the rest are its slash commands.
  """
  def put_commands(id, commands) when is_list(commands) do
    if driver(id) == "acpRegistry" do
      offered =
        for(%{"name" => name} = command when is_binary(name) <- commands, do: command)
        |> Enum.map(&Map.put(&1, "name", String.trim(&1["name"])))
        |> Enum.reject(&(&1["name"] in ["", "$"]))
        |> Enum.uniq_by(&String.downcase(&1["name"]))
        |> Enum.take(@max_commands)

      {skills, slash} = Enum.split_with(offered, &String.starts_with?(&1["name"], "$"))

      slash =
        for command <- slash do
          %{"name" => command["name"]}
          |> put_text("description", command["description"])
          |> then(fn c ->
            case get_in(command, ["input", "hint"]) do
              hint when is_binary(hint) and hint != "" ->
                Map.put(c, "input", %{"hint" => String.trim(hint)})

              _ ->
                c
            end
          end)
        end

      skills =
        for %{"name" => "$" <> name} = command <- skills do
          %{
            "name" => name,
            "path" => "acp://skill/" <> URI.encode_www_form(name),
            "scope" => "agent",
            "enabled" => true
          }
          |> put_text("description", command["description"])
        end

      changed =
        :persistent_term.get({__MODULE__, id, :commands}, []) != slash or
          :persistent_term.get({__MODULE__, id, :skills}, []) != skills

      if changed do
        :persistent_term.put({__MODULE__, id, :commands}, slash)
        :persistent_term.put({__MODULE__, id, :skills}, skills)
        HalC2.Settings.notify_providers()
      end
    end

    :ok
  end

  def put_commands(_id, _commands), do: :ok

  # Model ids the user added (`config.customModels`, slugs or `%{"slug", "name",
  # "capabilities"}`) follow the agent's own, skipping any the agent already offers.
  # One without options of its own takes the agent's, which its models share.
  defp custom_models(models, instance) do
    known = MapSet.new(models, & &1["slug"])
    shared = Enum.find_value(models, &(is_map(&1["capabilities"]) && &1["capabilities"]))

    custom =
      for entry <- get_in(instance, ["config", "customModels"]) || [],
          {slug, name, capabilities} = custom_model(entry),
          is_binary(slug) and slug != "" and not MapSet.member?(known, slug),
          uniq: true,
          do: %{
            "slug" => slug,
            "name" => name,
            "isCustom" => true,
            "isDefault" => false,
            "capabilities" => capabilities || shared
          }

    models ++ custom
  end

  defp custom_model(slug) when is_binary(slug), do: {String.trim(slug), String.trim(slug), nil}

  defp custom_model(%{"slug" => slug} = model) when is_binary(slug) do
    capabilities = if is_map(model["capabilities"]), do: model["capabilities"]
    {String.trim(slug), model["name"] || String.trim(slug), capabilities}
  end

  defp custom_model(_), do: {nil, nil, nil}

  @doc "The models a session's `model` config option lists, as provider models."
  def session_models(session), do: models(session)

  @parameter_options %{"context" => "contextWindow", "fast" => "fastMode"}
  @parameter_order %{
    "effort" => 0,
    "reasoning" => 0,
    "context" => 1,
    "fast" => 2,
    "thinking" => 3
  }

  @doc "The Cursor parameter a model option of HAL-C2's is (`contextWindow` is `context`)."
  def cursor_parameter(option) do
    Enum.find_value(@parameter_options, option, fn {parameter, id} ->
      if id == option, do: parameter
    end)
  end

  # The options a model offers, from the parameters the Cursor agent lists for it:
  # reasoning first, then
  # context size, fast mode and thinking; a true/false parameter is a switch. The
  # default is the default variant's value.
  defp parameter_capabilities(%{"parameters" => [_ | _] = parameters} = meta) do
    defaults =
      for variant <- meta["variants"] || [],
          variant["isDefault"] == true,
          %{"id" => id, "value" => value} <- variant["params"] || [],
          into: %{},
          do: {id, value}

    descriptors =
      parameters
      |> Enum.with_index()
      |> Enum.sort_by(fn {parameter, index} ->
        {Map.get(@parameter_order, parameter["id"], 4), index}
      end)
      |> Enum.flat_map(fn {parameter, _index} -> parameter_descriptor(parameter, defaults) end)
      |> Enum.uniq_by(& &1["id"])

    if descriptors != [], do: %{"optionDescriptors" => descriptors}
  end

  defp parameter_capabilities(_meta), do: nil

  defp parameter_descriptor(%{"id" => native, "values" => values} = parameter, defaults)
       when is_binary(native) and is_list(values) do
    native = String.trim(native)
    id = Map.get(@parameter_options, native, native)

    values =
      for %{"value" => value} = entry when is_binary(value) <- values,
          value = String.trim(value),
          value != "",
          do: {value, text(entry["displayName"]) || value}

    label =
      text(parameter["displayName"]) ||
        id
        |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
        |> String.split(~r/[\s_-]+/, trim: true)
        |> Enum.map_join(" ", &String.capitalize/1)

    default = defaults[native]

    cond do
      native == "" or values == [] ->
        []

      values |> Enum.map(&String.downcase(elem(&1, 0))) |> Enum.sort() == ["false", "true"] ->
        [
          %{"id" => id, "label" => label, "type" => "boolean"}
          |> then(
            &if(default in ["true", "false"],
              do: Map.put(&1, "currentValue", default == "true"),
              else: &1
            )
          )
        ]

      true ->
        [
          %{
            "id" => id,
            "label" => label,
            "type" => "select",
            "options" =>
              for {value, name} <- values do
                %{"id" => value, "label" => name}
                |> then(&if(value == default, do: Map.put(&1, "isDefault", true), else: &1))
              end
          }
          |> then(&if(default, do: Map.put(&1, "currentValue", default), else: &1))
        ]
    end
  end

  defp parameter_descriptor(_parameter, _defaults), do: []

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil

  # "Hugging Face/DeepSeek V3" is the model "DeepSeek V3" of the provider "Hugging Face".
  defp models(session) do
    option = Enum.find(session["configOptions"] || [], &(&1["id"] == "model")) || %{}
    current = option["currentValue"]

    for %{"value" => slug} = model <- option["options"] || [] do
      {sub, name} =
        case String.split(model["name"] || slug, "/", parts: 2) do
          [sub, name] -> {sub, name}
          [name] -> {nil, name}
        end

      %{
        "slug" => slug,
        "name" => name,
        "isCustom" => false,
        "isDefault" => slug == current,
        "capabilities" => parameter_capabilities(model["_meta"])
      }
      |> then(&if(sub, do: Map.put(&1, "subProvider", sub), else: &1))
    end
  end
end
