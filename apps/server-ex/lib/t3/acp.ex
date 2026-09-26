defmodule T3.Acp do
  @moduledoc """
  The Agent Client Protocol agents a node can run (`T3.Acp.ThreadRuntime`), and
  their entries in `ServerConfig.providers`: the built-in OpenCode and Grok, more
  instances of them, and `acpRegistry` instances running an agent from the ACP
  Registry (`T3.Acp.Catalog`). Everything is keyed by provider instance id.

  Built-in agents are off until enabled in the node's settings (`providers.<driver>`
  or a `providerInstances` entry), as on the Node server, so nothing is spawned for
  users who never opted in; a registry instance is on once added. An enabled agent's model list comes from the `model`
  config option of a throwaway session, which lists the models of the providers it
  is connected to; it is read once, at boot or when the agent is first enabled.
  """

  alias T3.JsonRpc.Connection

  @agents %{
    "opencode" => %{binary: "opencode", label: "OpenCode"},
    "grok" => %{binary: "grok", label: "Grok"},
    # The Cursor SDK behind ACP (`packages/cursor-acp`), run by Node.
    "cursor" => %{binary: "node", label: "Cursor"},
    # Pi through the registry's pi-acp adapter, which runs `pi --mode rpc`.
    "pi" => %{binary: "pi", label: "Pi"},
    # Google's Antigravity agent, from the node's managed runtime (`T3.Acp.Antigravity`).
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

  # Instances of this driver run an agent from the ACP Registry (`T3.Acp.Catalog`).
  @registry "acpRegistry"

  @doc "Instance ids of the ACP agents: the built-in agents and configured instances."
  def instances do
    configured =
      for {id, %{"driver" => driver}} <- T3.Settings.settings()["providerInstances"] || %{},
          driver == @registry or Map.has_key?(@agents, driver),
          do: id

    Enum.uniq(Map.keys(@agents) ++ configured)
  end

  @doc "Whether a provider instance runs over ACP."
  def agent?(instance), do: instance(instance) != nil

  # `{driver, instance settings}`; a built-in agent's id is its own default instance.
  defp instance(id) do
    case (T3.Settings.settings()["providerInstances"] || %{})[id] do
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
    override = Application.get_env(:t3, :acp_commands, %{})[instance]

    case override || instance(instance) do
      [_ | _] = command ->
        {driver, entry} = instance(instance) || {nil, %{}}
        {:ok, command, driver_env(driver, entry) ++ instance_env(entry)}

      {@registry, entry} ->
        with {:ok, command, env} <- T3.Acp.Catalog.command(entry["config"] || %{}),
             do: {:ok, command, env ++ instance_env(entry)}

      {"cursor", entry} ->
        # Each instance keeps its own Cursor sign-in, owner-only, under the T3 home.
        credentials =
          Path.join([
            Application.fetch_env!(:t3, :home),
            "provider-auth",
            instance,
            "cursor.json"
          ])

        {node, node_env} = node_command()

        {:ok, [node, cursor_script(), "--mode", runtime_mode || "approval-required"],
         [{"T3_CURSOR_CREDENTIALS", credentials} | node_env ++ instance_env(entry)]}

      {"pi", entry} ->
        with {:ok, command, env} <- T3.Acp.Catalog.command(%{"agentId" => "pi-acp"}),
             do: {:ok, command, driver_env("pi", entry) ++ env ++ instance_env(entry)}

      {"antigravity", _entry} ->
        T3.Acp.Antigravity.command(instance)

      {driver, entry} ->
        binary = binary(driver, entry, @agents[driver].binary)
        {:ok, [binary | args(driver, runtime_mode)], instance_env(entry)}

      nil ->
        {:error, "unknown ACP agent #{instance}"}
    end
  end

  defp cursor_script do
    released = Application.app_dir(:t3, "priv/cursor-acp/main.mjs")
    if File.exists?(released), do: released, else: @cursor_checkout
  end

  # The desktop app names its own Electron binary, which runs as Node with
  # ELECTRON_RUN_AS_NODE (set for the sidecar only, never the node's terminals).
  defp node_command do
    case System.get_env("T3_NODE_COMMAND") do
      command when command in [nil, ""] ->
        {"node", []}

      command ->
        electron =
          if System.get_env("T3_NODE_ELECTRON") == "1", do: [{"ELECTRON_RUN_AS_NODE", "1"}]

        {command, electron || []}
    end
  end

  # What an agent's adapter needs to find the agent: Pi's adapter runs the user's Pi.
  defp driver_env("pi", entry), do: [{"PI_ACP_PI_COMMAND", binary("pi", entry, "pi")}]
  defp driver_env(_driver, _entry), do: []

  # Variables set on the instance in settings, such as an API key.
  defp instance_env(entry) do
    for %{"name" => name, "value" => value} <- entry["environment"] || [],
        is_binary(name) and is_binary(value),
        do: {name, value}
  end

  defp args("opencode", _mode), do: ["acp"]

  # Grok applies permissions itself; full access skips its prompts entirely.
  defp args("grok", "full-access"), do: ["agent", "--always-approve", "stdio"]
  defp args("grok", "approval-required"), do: ["--permission-mode", "default", "agent", "stdio"]

  defp args("grok", "auto-accept-edits"),
    do: ["--permission-mode", "acceptEdits", "agent", "stdio"]

  defp args("grok", "auto"), do: ["--permission-mode", "auto", "agent", "stdio"]
  defp args("grok", _mode), do: ["agent", "stdio"]

  defp binary(driver, entry, default) do
    [
      get_in(entry, ["config", "binaryPath"]),
      get_in(T3.Settings.settings(), ["providers", driver, "binaryPath"])
    ]
    |> Enum.find(default, &(is_binary(&1) and String.trim(&1) != ""))
  end

  @doc "Provider entries for the ACP instances on this node whose agent is available."
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
          "status" => if(failure, do: "error", else: "ready"),
          "availability" => "available",
          # `T3.TextGeneration` runs these; registry agents and Pi write no commits or titles.
          "supportsTextGeneration" => driver in ~w(grok opencode cursor),
          # ACP agents run without T3's plan mode.
          "showInteractionModeToggle" => false,
          "auth" => %{"status" => "authenticated"},
          "checkedAt" => T3.Orchestration.Entities.now(),
          "models" => models || [],
          "slashCommands" => [],
          "skills" => []
        },
        base
      )
      |> then(&if(failure, do: Map.put(&1, "message", failure), else: &1))
      |> Map.merge(capability_fields(capabilities(id)))
      |> Map.merge(access(id, base["setup"]))
      |> then(
        &if(notice = :persistent_term.get({__MODULE__, id, :notice}, nil),
          do: Map.put(&1, "message", notice),
          else: &1
        )
      )
      |> driver_fields(driver, id, instance)
    else
      _ -> nil
    end
  end

  # A registry agent is installed when first used, so it counts as available.
  defp base_entry(id, @registry, instance) do
    agent_id = get_in(instance, ["config", "agentId"])

    case T3.Acp.Catalog.describe(agent_id) do
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

  # Whether the agent can be signed in here (`T3.ProviderAuth`), and whether it must be.
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
          case T3.Acp.UrlAuth.action(id) do
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

  @doc "Whether the node's settings enable an instance (built-in agents are off by default)."
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
        id == driver and get_in(T3.Settings.settings(), ["providers", driver, "enabled"]) == true
    end
  end

  defp load(id) do
    dir = Path.join(System.tmp_dir!(), "t3-acp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      case read_agent(id, dir) do
        :ok ->
          :persistent_term.erase({__MODULE__, id, :error})

        {:error, :unauthenticated} ->
          :persistent_term.put({__MODULE__, id, :error}, sign_in_hint(id))
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
      T3.Settings.notify_providers()
    end
  end

  # How to sign in, for an agent that reported it is signed out.
  defp sign_in_hint(id) do
    case instance(id) do
      {"grok", _} -> "Grok CLI is installed but not logged in. Run `grok login`."
      _ -> "Sign in to use this agent."
    end
  end

  # A probe's call, answering the agent meanwhile: a sign-in page it asks for waits
  # for a user (`T3.Acp.UrlAuth`), so the call may take as long as that allows.
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
          Connection.respond(conn, rpc_id, {:ok, T3.Acp.UrlAuth.request(id, params)})
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

    with :ok <- check_version(id, driver, entry) do
      with_agent(id, dir, fn conn, init ->
        # Pi's version is Pi's own, not its adapter's.
        if driver != "pi",
          do:
            :persistent_term.put(
              {__MODULE__, id, :version},
              get_in(init, ["agentInfo", "version"]) || "unknown"
            )

        :persistent_term.put({__MODULE__, id, :capabilities}, init["agentCapabilities"] || %{})
        :persistent_term.put({__MODULE__, id, :auth_methods}, length(init["authMethods"] || []))
        :persistent_term.put({__MODULE__, id, :meta}, init["_meta"] || %{})

        # Antigravity's models come from its sign-in and sessions
        # (`T3.Acp.Antigravity.account/1`); a probe session would need a Google login.
        case if(driver == "antigravity",
               do: {:ok, %{}},
               else: call_serving(conn, id, "session/new", %{"cwd" => dir, "mcpServers" => []})
             ) do
          {:ok, session} ->
            :persistent_term.put({__MODULE__, id, :models}, models(session))

          # ACP's "authentication required".
          {:error, %{"code" => -32000}} ->
            {:error, :unauthenticated}

          # Pi may stop at a startup prompt only a live session can answer.
          {:error, _} when driver == "pi" ->
            :persistent_term.put({__MODULE__, id, :models}, [@pi_default])

            :persistent_term.put(
              {__MODULE__, id, :notice},
              "Pi is available, but T3 Code could not refresh its models and commands. The live session will retry startup."
            )

          {:error, _} = error ->
            error
        end
      end)
    end
  end

  # Pi runs through its adapter, which needs Pi #{@pi_minimum} or newer (`pi --version`).
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
         "T3 Code could not determine the Pi version. Pi #{@pi_minimum} or newer is required."}
    end
  end

  defp check_version(_id, _driver, _entry), do: :ok

  # --- per-driver fields --------------------------------------------------------

  defp driver_fields(entry, "grok", id, instance) do
    meta = :persistent_term.get({__MODULE__, id, :meta}, nil) || %{}

    entry
    |> Map.merge(%{
      # Grok cannot rewind its own conversation.
      "supportsConversationRollback" => false,
      "slashCommands" => grok_commands(meta["availableCommands"])
    })
    |> Map.update!("models", &grok_reasoning(&1, get_in(meta, ["modelState", "availableModels"])))
    |> Map.update!("auth", &grok_auth(&1, instance))
  end

  defp driver_fields(entry, "opencode", id, _instance) do
    case stable_version(entry["version"]) do
      nil ->
        entry

      version ->
        entry = Map.put(entry, "compatibilityAdvisory", opencode_advisory(version))

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

  defp driver_fields(entry, "pi", id, _instance) do
    # Pi's permission gate has no classifier to run auto on.
    entry = Map.put(entry, "supportedRuntimeModes", @pi_modes)

    if entry["status"] == "ready" and :persistent_term.get({__MODULE__, id, :models}, nil) == [],
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
    do: T3.Acp.Antigravity.entry_fields(entry, id)

  defp driver_fields(entry, _driver, _id, _instance), do: entry

  # An API key set on the instance signs Grok in; otherwise its own login does.
  defp grok_auth(auth, instance) do
    key =
      Enum.find_value(instance_env(instance), fn {name, value} ->
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

  # Grok's commands from `initialize`; permissions change through T3 only, and
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

  # T3's bundled compatibility policy for OpenCode: older than the minimum is broken.
  defp opencode_advisory(version) do
    broken = Version.compare(version, @opencode_minimum) == :lt

    %{
      "status" => if(broken, do: "broken", else: "unknown"),
      "message" =>
        if(broken,
          do:
            "This provider version is known to be incompatible with this T3 Code release. Use >=#{@opencode_minimum}."
        ),
      "recommendedVersion" => nil,
      "recommendedRange" => ">=#{@opencode_minimum}"
    }
  end

  @doc """
  Starts an instance's agent in `cwd`, initializes it, and calls `fun.(conn,
  initialize_result)`; the agent stops when `fun` returns.
  """
  def with_agent(id, cwd, fun) do
    with {:ok, command, env} <- command(id),
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
      "clientInfo" => %{"name" => "t3code", "version" => "0.1.0"}
    }
  end

  @doc "The agent capabilities an instance reported when it was last probed, or `nil`."
  def capabilities(id), do: :persistent_term.get({__MODULE__, id, :capabilities}, nil)

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
          :notice
        ],
        do: :persistent_term.erase({__MODULE__, id, key})

    :ok
  end

  @doc "The models a session's `model` config option lists, as provider models."
  def session_models(session), do: models(session)

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
        "capabilities" => nil
      }
      |> then(&if(sub, do: Map.put(&1, "subProvider", sub), else: &1))
    end
  end
end
