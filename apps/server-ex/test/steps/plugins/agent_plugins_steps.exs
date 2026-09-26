defmodule T3.Steps.Plugins.AcpRegistry do
  @moduledoc """
  A fake ACP Registry for plugin scenarios: a loopback HTTP server that serves
  `registry.json` and agent archives from a directory, with `T3.Acp.Catalog`
  pointed at it. Agents are archives holding `bin/fake`, which runs the fake ACP
  agent (`test/support/fake_acp.py`).
  """

  alias T3.Test.Node.World

  defmodule Files do
    @moduledoc false
    @behaviour Plug

    def init(dir), do: dir

    def call(%{request_path: "/" <> name} = conn, dir) do
      case File.read(Path.join(dir, name)) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        _ -> Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  @fake_acp Path.expand("../../support/fake_acp.py", __DIR__)

  @doc "Starts the registry once per scenario; returns the context with `:registry`."
  def ensure(%{registry: %{}} = context), do: context

  def ensure(context) do
    T3.Test.Node.ensure(T3.Settings)
    served = T3.Test.Node.tmp_dir(context.node, "registry")

    server =
      T3.Test.Node.ensure(
        Supervisor.child_spec({Bandit, plug: {Files, served}, port: 0, ip: :loopback},
          id: :acp_registry
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    Application.put_env(:t3, :acp_registry_url, "#{base}/registry.json")
    :persistent_term.erase({T3.Acp.Catalog, :index})

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:t3, :acp_registry_url)
      :persistent_term.erase({T3.Acp.Catalog, :index})
    end)

    script = Path.join(served, "fake")
    File.write!(script, "#!/bin/sh\nexec python3 -u #{@fake_acp} \"$@\"\n")
    File.chmod!(script, 0o755)
    archive = Path.join(served, "fake.tar.gz")

    :ok =
      :erl_tar.create(to_charlist(archive), [{~c"bin/fake", to_charlist(script)}], [:compressed])

    sha = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    Map.put(context, :registry, %{served: served, base: base, sha: sha, agents: []})
  end

  @doc "An agent entry whose binary for this platform is the fake archive."
  def agent(context, id, extra \\ %{}) do
    %{base: base, sha: sha} = context.registry

    Map.merge(
      %{
        "id" => id,
        "name" => id |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1),
        "version" => "1.0.0",
        "description" => "A test agent",
        "authors" => ["Tests"],
        "distribution" => %{
          "binary" => %{
            T3.Acp.Catalog.platform() => %{
              "archive" => "#{base}/fake.tar.gz",
              "cmd" => "./bin/fake",
              "args" => ["--acp"],
              "sha256" => sha
            }
          }
        }
      },
      extra
    )
  end

  @doc "Publishes `agents` (added to what the registry already lists)."
  def publish(context, agents) do
    context = ensure(context)
    agents = context.registry.agents ++ agents

    File.write!(
      Path.join(context.registry.served, "registry.json"),
      JSON.encode!(%{"version" => "1.0.0", "agents" => agents})
    )

    :persistent_term.erase({T3.Acp.Catalog, :index})
    put_in(context, [:registry, :agents], agents)
  end

  @doc """
  Adds an `acpRegistry` provider instance running `agent_id` the way a client
  does: it reads the settings document and writes it back with the instance.
  """
  def add_instance(context, instance_id, agent_id) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "t3.readSettings")

    instance = %{
      "driver" => "acpRegistry",
      "enabled" => true,
      "config" => %{"agentId" => agent_id}
    }

    instances = Map.put(settings["providerInstances"] || %{}, instance_id, instance)

    {_, context} =
      World.call!(context, "t3.writeSettings", %{
        "settings" => Map.put(settings, "providerInstances", instances),
        "version" => version
      })

    context
  end

  @doc "Where the node installs a registry agent."
  def tools_dir(context, agent_id), do: Path.join([context.node.home, "tools", agent_id])
end

defmodule T3.Steps.Plugins.Turns do
  @moduledoc """
  Turns on fake providers for plugin scenarios: the fake Codex, Claude and ACP
  agents under `test/support`, run by the node's own runtimes. A running turn is
  kept in the context as `:running` (`%{thread, run}`), which the shared
  follow-up steps in `common_steps.exs` read.
  """

  alias T3.StreamState
  alias T3.Test.Node
  alias T3.Test.Node.World

  @support Path.expand("../../support", __DIR__)

  @doc "Starts what provider turns need and points the node at the fake agents."
  def providers(context) do
    Node.ensure(T3.Settings)

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Codex.Registry},
        id: T3.Codex.Registry
      )
    )

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Claude.Registry},
        id: T3.Claude.Registry
      )
    )

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Acp.Registry}, id: T3.Acp.Registry)
    )

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one},
        id: T3.Codex.Supervisor
      )
    )

    Application.put_env(:t3, :codex_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_codex.py")
    ])

    Application.put_env(:t3, :claude_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_claude.py")
    ])

    Application.put_env(:t3, :acp_commands, %{
      "opencode" => ["python3", "-u", Path.join(@support, "fake_acp.py")]
    })

    ExUnit.Callbacks.on_exit(fn ->
      for key <- [:codex_command, :claude_command, :acp_commands],
          do: Application.delete_env(:t3, key)
    end)

    context
  end

  @doc """
  Creates a thread in the scenario's project on `instance` and sends `text` as its
  first message over the socket; returns `{thread_id, context}`.
  """
  def send_first(context, instance, text, fields \\ %{}) do
    title = "#{instance} #{System.unique_integer([:positive])}"

    context =
      World.create_thread(
        context,
        title,
        nil,
        Map.merge(
          %{"modelSelection" => %{"instanceId" => instance, "model" => "fake/one"}},
          fields
        )
      )

    thread_id = World.thread_id(context, title)
    {{:ok, _}, context} = World.dispatch(context, message(thread_id, "m1", text))
    {thread_id, context}
  end

  @doc "A `message.dispatch` as the composer sends it: start now, and steer if it can."
  def message(thread_id, message_id, text) do
    %{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "messageId" => message_id,
      "text" => text,
      "attachments" => [],
      "dispatchMode" => %{"type" => "start_immediately"},
      "deliveryIntent" => "auto"
    }
  end

  @doc "The thread's runs in order, once their statuses are `statuses`."
  def await_runs(thread_id, statuses) do
    World.await_stream(thread_id, fn state ->
      runs = runs(state)
      if Enum.map(runs, & &1["status"]) == statuses, do: runs
    end)
  end

  def runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  @doc "The turn item the message `message_id` became, once there is one."
  def await_user_item(thread_id, message_id) do
    World.await_stream(thread_id, fn state ->
      Enum.find(StreamState.list(state, "turn-item"), &(&1["messageId"] == message_id))
    end)
  end
end

defmodule T3.Steps.Plugins.Fixtures do
  @moduledoc """
  Node plugins for scenarios, written as source files into the node's plugins
  directory (`T3.Plugins`). Each fixture implements the behaviour its id stands for
  and runs a process registered under its module name, which answers `:version`,
  crashes on `:crash`, and tells a process registered as `:t3_plugin_probe` that
  it started.
  """

  alias T3.Test.Node

  @kinds %{
    "acme-agent" => "ProviderAdapter",
    "acme" => "ProviderAdapter",
    "jira-tools" => "McpToolPack",
    "future-tools" => "McpToolPack",
    "gitea" => "GitHost",
    "old-host" => "GitHost",
    "ntfy" => "NotificationChannel",
    "broken" => "NotificationChannel",
    "local-llama" => "TextGeneration"
  }

  @api %{"old-host" => 0, "future-tools" => 2}

  @doc "The kind a scenario names, as `T3.Plugins` lists it."
  def kind("provider adapter"), do: "providerAdapter"
  def kind("MCP tool pack"), do: "mcpToolPack"
  def kind("git host"), do: "gitHost"
  def kind("notification channel"), do: "notificationChannel"
  def kind("text-generation backend"), do: "textGeneration"

  @doc "The fixture's plugin module."
  def module(id), do: Module.concat(T3PluginFixture, Macro.camelize(String.replace(id, "-", "_")))

  @doc "Starts settings and plugins; the plugins directory is scanned as they start."
  def ensure(context) do
    Node.ensure(T3.Settings)
    Node.ensure(T3.Plugins)
    context
  end

  @doc "Writes `source` (default: the fixture `id`) into the plugins directory and rescans."
  def install(context, id, source \\ nil) do
    File.mkdir_p!(Path.dirname(path(context, id)))
    File.write!(path(context, id), source || source(id))
    rescan(ensure(context))
  end

  def remove(context, id) do
    File.rm!(path(context, id))
    rescan(context)
  end

  def rescan(context) do
    {:ok, _} = T3.Plugins.handle("rescan", %{})
    context
  end

  def path(context, id), do: Path.join([context.node.home, "plugins", "#{id}.ex"])

  @doc "The node's listing of plugin `id`, or nil."
  def entry(id) do
    {:ok, %{"plugins" => plugins}} = T3.Plugins.handle("list", %{})
    Enum.find(plugins, &(&1["id"] == id))
  end

  @doc "Turns plugin `id` on as a client does, asserting it runs."
  def enable(context, id) do
    {_, context} = T3.Test.Node.World.call!(context, "plugins.enable", %{"id" => id})
    %{"status" => "running"} = entry(id)
    context
  end

  @doc "Makes the test process `:t3_plugin_probe`, which fixtures tell when they start."
  def probe do
    if Process.whereis(:t3_plugin_probe) != self(), do: Process.register(self(), :t3_plugin_probe)
    :ok
  end

  @doc "The source of fixture `id`: `version` sets its manifest and `:version` answer."
  def source(id, version \\ "1.0.0") do
    module = inspect(module(id))

    """
    defmodule #{module} do
      @behaviour T3.Plugins.#{Map.fetch!(@kinds, id)}
      use GenServer

      def manifest do
        %{
          id: #{inspect(id)},
          name: #{inspect(String.capitalize(id))},
          version: #{inspect(version)},
          api_version: #{Map.get(@api, id, 1)},
          settings: #{inspect(settings(id))}
        }
      end

      def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

      def init(settings) do
        if probe = Process.whereis(:t3_plugin_probe), do: send(probe, {:plugin_started, #{inspect(id)}, self()})
        {:ok, settings}
      end

      def handle_call(:version, _from, settings), do: {:reply, #{inspect(version)}, settings}
      def handle_cast(:crash, _settings), do: raise(#{inspect("#{id} lost its connection")})

    #{callbacks(id)}
    end
    """
  end

  defp settings("jira-tools"), do: [%{key: "siteUrl", label: "Site URL"}]

  defp settings("gitea"),
    do: [%{key: "baseUrl", label: "Base URL"}, %{key: "token", label: "Token", secret: true}]

  defp settings("ntfy"), do: [%{key: "topic", label: "Topic"}]
  defp settings(_id), do: []

  defp callbacks(id) when id in ["jira-tools", "future-tools"] do
    ~S"""
      def tools(settings) do
        [
          %{
            name: "jira_search",
            description: "Searches Jira issues on #{settings["siteUrl"]}",
            inputSchema: %{type: "object", properties: %{query: %{type: "string"}}}
          }
        ]
      end

      def call_tool("jira_search", _arguments, settings),
        do: {:ok, %{site: settings["siteUrl"], issues: [%{key: "SHOP-1", summary: "Checkout fails"}]}}
    """
  end

  defp callbacks(id) when id in ["gitea", "old-host"] do
    ~S"""
      def validate_settings(settings) do
        case settings["baseUrl"] && URI.new(settings["baseUrl"]) do
          nil -> :ok
          {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and host not in [nil, ""] -> :ok
          _ -> {:error, "The base URL must be an http(s) address, like https://git.example.com."}
        end
      end

      def host?(host, settings), do: URI.parse(settings["baseUrl"] || "").host == host

      def list_pull_requests(repository, settings) do
        {:ok,
         [
           %{
             number: 7,
             title: "Add a basket",
             url: "#{settings["baseUrl"]}/#{repository}/pulls/7",
             state: "open",
             headBranch: "basket",
             baseBranch: "main",
             updatedAt: "2026-09-20T10:00:00Z"
           }
         ]}
      end
    """
  end

  defp callbacks("ntfy"), do: "  def notify(_notification, _settings), do: :ok"

  defp callbacks("local-llama") do
    ~S"""
      def generate(_prompt, schema, _settings) do
        {:ok,
         Map.new(schema["properties"], fn
           {key, %{"type" => "string"}} -> {key, "Written by local-llama"}
           {key, _} -> {key, false}
         end)}
      end
    """
  end

  defp callbacks(_provider_adapter), do: ""
end

defmodule T3.Steps.Plugins.AgentPlugins do
  @moduledoc "Steps for `features/plugins/agent-plugins.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.StreamState
  alias T3.Steps.Plugins.{AcpRegistry, Fixtures, Turns}
  alias T3.Test.Node
  alias T3.Test.Node.World

  # --- registry agents ---------------------------------------------------------------

  step "the ACP registry lists the agent {string}", %{args: [id]} = context do
    context = context |> Turns.providers() |> AcpRegistry.ensure()

    context
    |> AcpRegistry.publish([AcpRegistry.agent(context, id)])
    |> Map.put(:node_version, T3.Upgrade.version())
  end

  step "the user adds {string} as a provider", %{args: [id]} = context do
    {_, context} = World.call!(context, "server.prepareAcpRegistryAgent", %{"agentId" => id})
    AcpRegistry.add_instance(context, id, id)
  end

  step "{string} can run turns in {string}", %{args: [instance, _project]} = context do
    {thread_id, context} = Turns.send_first(context, instance, "list the files")
    [%{"providerInstanceId" => ^instance}] = Turns.await_runs(thread_id, ["completed"])

    answer =
      World.await_stream(thread_id, fn state ->
        Enum.find(StreamState.list(state, "message"), &(&1["role"] == "assistant"))
      end)

    assert answer["text"] == "Hello from acp"
    context
  end

  step "no new node version was needed", context do
    assert T3.Upgrade.version() == context.node_version
    context
  end

  # --- follow-ups during a turn --------------------------------------------------------

  step "a turn is running on an ACP agent", context do
    # The fake agent holds a turn that asks for approval until it is answered.
    context = Turns.providers(context)

    {thread_id, context} =
      Turns.send_first(context, "opencode", "approve ls", %{"runtimeMode" => "approval-required"})

    request =
      World.await_stream(thread_id, fn state ->
        Enum.find(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
      end)

    [run] = Turns.runs(T3.Streams.Server.state(T3.Streams.ensure(thread_id)))
    Map.put(context, :running, %{thread: thread_id, run: run["id"], request: request["id"]})
  end

  step "a turn is running on Codex", context do
    context = Turns.providers(context)
    {thread_id, context} = Turns.send_first(context, "codex", "wait for it")
    [run] = Turns.await_runs(thread_id, ["running"])
    Map.put(context, :running, %{thread: thread_id, run: run["id"]})
  end

  step "the message waits until the running turn finishes", context do
    %{thread: thread_id, run: run_id, request: request_id} = context.running

    [%{"id" => ^run_id}, queued] =
      World.await_stream(thread_id, fn state ->
        case Turns.runs(state) do
          [%{"status" => active}, %{"status" => "queued"}] = runs
          when active in ~w(running waiting) ->
            runs

          _ ->
            nil
        end
      end)

    assert queued["userMessageId"] == context.follow_up

    # Answering the approval lets the running turn finish.
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "runtime-request.respond",
        "threadId" => thread_id,
        "requestId" => request_id,
        "decision" => "accept"
      })

    Map.put(context, :queued_run, queued["id"])
  end

  step "it is then sent as the next turn", context do
    thread_id = context.running.thread
    [first, next] = Turns.await_runs(thread_id, ["completed", "completed"])
    assert next["id"] == context.queued_run
    assert next["startedAt"] >= first["completedAt"]
    assert Turns.await_user_item(thread_id, context.follow_up)["runId"] == next["id"]
    context
  end

  # --- built-in ACP agents ---------------------------------------------------------------

  step "OpenCode, Grok, Cursor and Pi are installed but not enabled", context do
    Node.ensure(T3.Settings)
    markers = T3.Test.Node.tmp_dir(context.node, "started")

    # Each agent is a script that leaves a marker when something starts it.
    commands =
      for id <- ~w(opencode grok cursor pi), into: %{} do
        script = Path.join(markers, "#{id}-agent")
        File.write!(script, "#!/bin/sh\ntouch #{Path.join(markers, id)}\n")
        File.chmod!(script, 0o755)
        {id, [script]}
      end

    Application.put_env(:t3, :acp_commands, commands)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :acp_commands) end)

    # Pi counts as installed where its binary is found.
    {settings, version} = T3.Settings.get()
    pi = %{"binaryPath" => hd(commands["pi"])}

    {:ok, _} =
      T3.Settings.put(put_in(settings, [Access.key("providers", %{}), "pi"], pi), version)

    Map.put(context, :markers, markers)
  end

  step "none of their processes are started", context do
    # What the node runs at boot and when a client lists its providers.
    T3.Acp.load()
    entries = Map.new(T3.Acp.entries(), &{&1["instanceId"], &1})

    for id <- ~w(opencode grok cursor pi) do
      assert %{"enabled" => false} = entries[id], "#{id} is not listed as installed"
    end

    assert File.ls!(context.markers) |> Enum.reject(&String.ends_with?(&1, "-agent")) == []
    context
  end

  # --- removed provider plugins ------------------------------------------------------

  step "a thread that used the instance {string}", %{args: [instance]} = context do
    # The instance's provider came from the provider adapter plugin "acme".
    context =
      context |> Turns.providers() |> World.create_project("shop") |> Fixtures.install("acme")

    {settings, version} = T3.Settings.get()

    instances =
      Map.put(settings["providerInstances"] || %{}, instance, %{
        "driver" => "acme",
        "enabled" => true
      })

    {:ok, _} = T3.Settings.put(Map.put(settings, "providerInstances", instances), version)

    context =
      World.create_thread(context, "Acme work", "shop", %{
        "modelSelection" => %{"instanceId" => instance, "model" => "acme-1"}
      })

    Map.merge(context, %{thread: World.thread_id(context, "Acme work"), instance: instance})
  end

  step "the plugin behind {string} has been removed", %{args: [instance]} = context do
    driver = get_in(T3.Settings.settings(), ["providerInstances", instance, "driver"])
    context = Fixtures.remove(context, driver)
    assert Fixtures.entry(driver) == nil
    context
  end

  step "the user sends a message in that thread", context do
    {reply, context} = World.dispatch(context, Turns.message(context.thread, "m1", "carry on"))
    Map.put(context, :reply, reply)
  end

  step "the message is refused with a message naming the missing provider", context do
    assert {:error, message, _} = context.reply
    assert message =~ ~s("#{context.instance}" is not available on this node)
    context
  end

  step "no other provider runs the turn in its place", context do
    state = T3.Streams.Server.state(T3.Streams.ensure(context.thread))
    assert Turns.runs(state) == []
    assert StreamState.list(state, "message") == []
    assert Registry.lookup(T3.Codex.Registry, context.thread) == []
    context
  end
end
