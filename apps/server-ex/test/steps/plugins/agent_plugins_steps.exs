defmodule HalC2.Steps.Plugins.AcpRegistry do
  @moduledoc """
  A fake ACP Registry for plugin scenarios: a loopback HTTP server that serves
  `registry.json` and agent archives from a directory, with `HalC2.Acp.Catalog`
  pointed at it. Agents are archives holding `bin/fake`, which runs the fake ACP
  agent (`test/support/fake_acp.py`).
  """

  alias HalC2.Test.Mc.World

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
    HalC2.Test.Mc.ensure(HalC2.Settings)
    served = HalC2.Test.Mc.tmp_dir(context.mc, "registry")

    server =
      HalC2.Test.Mc.ensure(
        Supervisor.child_spec({Bandit, plug: {Files, served}, port: 0, ip: :loopback},
          id: :acp_registry
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    Application.put_env(:hal_c2, :acp_registry_url, "#{base}/registry.json")
    :persistent_term.erase({HalC2.Acp.Catalog, :index})

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :acp_registry_url)
      :persistent_term.erase({HalC2.Acp.Catalog, :index})
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
            HalC2.Acp.Catalog.platform() => %{
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

    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    put_in(context, [:registry, :agents], agents)
  end

  @doc """
  Adds an `acpRegistry` provider instance running `agent_id` the way a client
  does: it reads the settings document and writes it back with the instance.
  """
  def add_instance(context, instance_id, agent_id) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    instance = %{
      "driver" => "acpRegistry",
      "enabled" => true,
      "config" => %{"agentId" => agent_id}
    }

    instances = Map.put(settings["providerInstances"] || %{}, instance_id, instance)

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => Map.put(settings, "providerInstances", instances),
        "version" => version
      })

    context
  end

  @doc "Where the MC installs a registry agent."
  def tools_dir(context, agent_id), do: Path.join([context.mc.home, "tools", agent_id])
end

defmodule HalC2.Steps.Plugins.Turns do
  @moduledoc """
  Turns on fake providers for plugin scenarios: the fake Codex, Claude and ACP
  agents under `test/support`, run by the MC's own runtimes. A running turn is
  kept in the context as `:running` (`%{thread, run}`), which the shared
  follow-up steps in `common_steps.exs` read.
  """

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @support Path.expand("../../support", __DIR__)

  @doc "Starts what provider turns need and points the MC at the fake agents."
  def providers(context) do
    Mc.ensure(HalC2.Settings)

    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Codex.Registry},
        id: HalC2.Codex.Registry
      )
    )

    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: HalC2.Claude.Registry
      )
    )

    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: HalC2.Acp.Registry
      )
    )

    Mc.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
        id: HalC2.Codex.Supervisor
      )
    )

    Application.put_env(:hal_c2, :codex_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_codex.py")
    ])

    Application.put_env(:hal_c2, :claude_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_claude.py")
    ])

    Application.put_env(:hal_c2, :acp_commands, %{
      "opencode" => ["python3", "-u", Path.join(@support, "fake_acp.py")],
      "grok" => ["python3", "-u", Path.join(@support, "fake_acp.py")]
    })

    ExUnit.Callbacks.on_exit(fn ->
      for key <- [:codex_command, :claude_command, :acp_commands],
          do: Application.delete_env(:hal_c2, key)
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

defmodule HalC2.Steps.Plugins.Fixtures do
  @moduledoc """
  MC plugins for scenarios, written as source files into the MC's plugins
  directory (`HalC2.Plugins`). Each fixture implements the behaviour its id stands for
  and runs a process registered under its module name, which answers `:version`,
  crashes on `:crash`, and tells a process registered as `:hal_c2_plugin_probe` that
  it started.
  """

  alias HalC2.Test.Mc

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

  @doc "The kind a scenario names, as `HalC2.Plugins` lists it."
  def kind("provider adapter"), do: "providerAdapter"
  def kind("MCP tool pack"), do: "mcpToolPack"
  def kind("git host"), do: "gitHost"
  def kind("notification channel"), do: "notificationChannel"
  def kind("text-generation backend"), do: "textGeneration"

  @doc "The fixture's plugin module."
  def module(id),
    do: Module.concat(HalC2PluginFixture, Macro.camelize(String.replace(id, "-", "_")))

  @doc "Starts settings and plugins; the plugins directory is scanned as they start."
  def ensure(context) do
    Mc.ensure(HalC2.Settings)
    Mc.ensure(HalC2.Plugins)
    Mc.ensure(HalC2.Orchestration.TurnWatch)
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
    {:ok, _} = HalC2.Plugins.handle("rescan", %{})
    context
  end

  def path(context, id), do: Path.join([context.mc.home, "plugins", "#{id}.ex"])

  @doc """
  A second MC in the cluster, as `:peer` and its environment id `:peer_environment`;
  started once per scenario.
  """
  def peer(%{peer: _, peer_environment: _} = context), do: context

  def peer(context) do
    context = ensure(context)
    peer = HalC2.Test.Mc.start_peer(context.mc)
    Map.merge(context, %{peer: peer, peer_environment: HalC2.Test.Mc.peer_environment(peer)})
  end

  @doc "Writes fixture `id` into the peer MC's plugins directory and has it rescan."
  def install_on_peer(context, id) do
    context = peer(context)
    dir = Path.join([context.mc.home, "peer", "plugins"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{id}.ex"), source(id))
    {:ok, _} = :erpc.call(context.peer, HalC2.Plugins, :handle, ["rescan", %{}])
    context
  end

  @doc "The plugin listing of the environment `environment`, fetched over the client's socket."
  def list(context, environment) do
    {%{"plugins" => plugins}, client} =
      HalC2.Test.Mc.call!(HalC2.Test.Mc.World.client(context), environment, "plugins.list")

    {plugins, HalC2.Test.Mc.World.put_client(context, client)}
  end

  @doc "The MC's listing of plugin `id`, or nil."
  def entry(id) do
    {:ok, %{"plugins" => plugins}} = HalC2.Plugins.handle("list", %{})
    Enum.find(plugins, &(&1["id"] == id))
  end

  @doc "Turns plugin `id` on as a client does, asserting it runs."
  def enable(context, id) do
    {_, context} = HalC2.Test.Mc.World.call!(context, "plugins.enable", %{"id" => id})
    %{"status" => "running"} = entry(id)
    context
  end

  @doc "Makes the test process `:hal_c2_plugin_probe`, which fixtures tell when they start."
  def probe do
    if Process.whereis(:hal_c2_plugin_probe) != self(),
      do: Process.register(self(), :hal_c2_plugin_probe)

    :ok
  end

  @doc "The source of fixture `id`: `version` sets its manifest and `:version` answer."
  def source(id, version \\ "1.0.0")

  def source(id, version) when id in ["acme", "acme-agent"], do: provider(id, version: version)

  def source(id, version) do
    module = inspect(module(id))

    """
    defmodule #{module} do
      @behaviour HalC2.Plugins.#{Map.fetch!(@kinds, id)}
      use GenServer

      def manifest do
        %{
          id: #{inspect(id)},
          name: #{inspect(String.capitalize(id))},
          version: #{inspect(version)},
          api_version: #{Map.get(@api, id, 1)},
          settings: #{inspect(settings(id))},
          permissions: #{inspect(permissions(id))}
        }
      end

      def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

      def init(settings) do
        if probe = Process.whereis(:hal_c2_plugin_probe), do: send(probe, {:plugin_started, #{inspect(id)}, self()})
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

  defp permissions("gitea"), do: [%{id: "project-remotes", label: "Read project remotes"}]
  defp permissions(_id), do: []

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

  defp callbacks("ntfy") do
    ~S"""
      def notify(notification, settings) do
        if probe = Process.whereis(:hal_c2_plugin_probe), do: send(probe, {:notified, "ntfy", notification, settings})
        :ok
      end
    """
  end

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

  defp callbacks(_other), do: ""

  @doc """
  The source of a provider adapter plugin `id` written against the adapter contract
  alone. Its turns answer "Hello from <id>" (with " and the history" when the turn
  carries the thread's earlier conversation, and the instance's `greeting` setting
  when it has one); a turn saying "wait" runs until it is interrupted, and
  "write <file>" writes that file in the workspace first. It does only what
  `opts[:capabilities]` declares (default: everything); `rollback_fails: true`
  declares rollback and fails every one.
  """
  def provider(id, opts \\ []) do
    version = opts[:version] || "1.0.0"
    driver = opts[:driver] || id
    capabilities = Keyword.get(opts, :capabilities, HalC2.Plugins.ProviderAdapter.capabilities())

    provider =
      %{
        driver: driver,
        name: opts[:name] || String.capitalize(id),
        capabilities: capabilities,
        documentation_url: "https://#{id}.example.com/docs/sign-in",
        models: [%{slug: "#{id}-1", name: "#{String.capitalize(id)} One"}]
      }
      |> Map.merge(
        Map.new(Keyword.take(opts, [:icon, :accent_color, :runtime_modes, :instance_settings]))
      )

    optional =
      [
        :interrupt in capabilities &&
          ~S"""
            def interrupt(thread_id, _run_id) do
              case GenServer.call(__MODULE__, {:turn, thread_id}) do
                pid when is_pid(pid) -> send(pid, :interrupt) && :ok
                nil -> {:error, "no running turn"}
              end
            end
          """,
        :active_steering in capabilities &&
          ~S"""
            def steer(_thread_id, _run_id, _text), do: {:error, "this fixture does not steer"}
          """,
        (opts[:rollback_fails] || :rollback in capabilities) &&
          """
            def rollback(_thread_id, _plan),
              do: #{if opts[:rollback_fails], do: inspect({:error, "#{id} could not rewind its conversation"}), else: ~s({:ok, %{"nativeThreadRef" => nil}})}
          """
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n")

    """
    defmodule #{inspect(module(id))} do
      @behaviour HalC2.Plugins.ProviderAdapter
      use GenServer
      alias HalC2.Orchestration.TurnWriter

      @provider #{inspect(provider)}

      def manifest do
        %{
          id: #{inspect(id)},
          name: #{inspect(provider.name)},
          version: #{inspect(version)},
          api_version: 1,
          settings: [],
          provider: @provider
        }
      end

      def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

      def init(_settings) do
        if probe = Process.whereis(:hal_c2_plugin_probe), do: send(probe, {:plugin_started, #{inspect(id)}, self()})
        {:ok, %{}}
      end

      def handle_call(:version, _from, turns), do: {:reply, #{inspect(version)}, turns}
      def handle_call({:track, thread_id, pid}, _from, turns), do: {:reply, :ok, Map.put(turns, thread_id, pid)}

      def handle_call({:turn, thread_id}, _from, turns) do
        pid = turns[thread_id]
        {:reply, if(pid && Process.alive?(pid), do: pid), turns}
      end

      def handle_cast(:crash, _turns), do: raise(#{inspect("#{id} lost its connection")})

      def start_turn(thread_id, turn) do
        {:ok, pid} =
          DynamicSupervisor.start_child(HalC2.Plugins.sessions(#{inspect(driver)}), %{
            id: :turn,
            start: {Task, :start_link, [fn -> run(thread_id, turn) end]},
            restart: :temporary
          })

        GenServer.call(__MODULE__, {:track, thread_id, pid})
      end

    #{optional}

      defp run(thread_id, turn) do
        ids = Map.put(turn.ids, :provider_turn, "provider-turn:\#{turn.ids.driver}:\#{turn.ids.run}")
        state = %{thread_id: thread_id, turn: %{turn | ids: ids}, items: %{}, buffer: %{}, flush_timer: nil}
        TurnWriter.started(state)

        # Its own session, which later turns continue (a fresh one gets the history).
        if turn.native_thread_id == nil do
          TurnWriter.commit(state, fn stream ->
            [
              HalC2.Orchestration.upsert(stream, "provider-thread", ids.provider_thread, fn thread ->
                Map.put(thread, "nativeThreadRef", HalC2.Orchestration.Entities.provider_ref("session-\#{thread_id}", ids.driver))
              end)
            ]
          end)
        end

        if turn.text =~ "wait" do
          receive do
            :interrupt -> TurnWriter.finish(state, "interrupted", nil)
          end
        else
          with [_, name] <- turn.text |> String.split("</conversation_history>") |> List.last() |> then(&Regex.run(~r/write (\\S+)/, &1)),
               do: File.write!(Path.join(turn.cwd, name), "written by #{id}\\n")

          state = TurnWriter.ensure_item(state, "answer", :assistant)
          TurnWriter.finish_item(state, "answer", "completed", &Map.merge(&1, %{"text" => answer(turn), "streaming" => false}))
          TurnWriter.finish(state, "completed", nil)
        end
      end

      defp answer(turn) do
        config = get_in(HalC2.Settings.settings(), ["providerInstances", turn.ids.instance, "config"]) || %{}
        history = if turn.text =~ "<conversation_history>", do: " and the history", else: ""
        greeting = if config["greeting"], do: " (\#{config["greeting"]})", else: ""
        "Hello from #{id}\#{history}\#{greeting}"
      end
    end
    """
  end
end

defmodule HalC2.Steps.Plugins.AgentPlugins do
  @moduledoc "Steps for `features/plugins/agent-plugins.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Steps.Plugins.{AcpRegistry, Fixtures, Turns}
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # --- registry agents ---------------------------------------------------------------

  step "the ACP registry lists the agent {string}", %{args: [id]} = context do
    context = context |> Turns.providers() |> AcpRegistry.ensure()

    context
    |> AcpRegistry.publish([AcpRegistry.agent(context, id)])
    |> Map.put(:mc_version, HalC2.Upgrade.version())
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

  step "no new MC version was needed", context do
    assert HalC2.Upgrade.version() == context.mc_version
    context
  end

  # --- follow-ups during a turn --------------------------------------------------------

  step "a turn is running on an ACP agent", context do
    # The fake agent holds a turn that asks for approval until it is answered. Grok, as
    # ACP gives no way to add to a running prompt (OpenCode takes one; see its feature).
    context = Turns.providers(context)

    {thread_id, context} =
      Turns.send_first(context, "grok", "approve ls", %{"runtimeMode" => "approval-required"})

    request =
      World.await_stream(thread_id, fn state ->
        Enum.find(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
      end)

    [run] = Turns.runs(HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id)))
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
    Mc.ensure(HalC2.Settings)
    markers = HalC2.Test.Mc.tmp_dir(context.mc, "started")

    # Each agent is a script that leaves a marker when something starts it.
    commands =
      for id <- ~w(opencode grok cursor pi), into: %{} do
        script = Path.join(markers, "#{id}-agent")
        File.write!(script, "#!/bin/sh\ntouch #{Path.join(markers, id)}\n")
        File.chmod!(script, 0o755)
        {id, [script]}
      end

    Application.put_env(:hal_c2, :acp_commands, commands)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :acp_commands) end)

    # Pi counts as installed where its binary is found.
    {settings, version} = HalC2.Settings.get()
    pi = %{"binaryPath" => hd(commands["pi"])}

    {:ok, _} =
      HalC2.Settings.put(put_in(settings, [Access.key("providers", %{}), "pi"], pi), version)

    Map.put(context, :markers, markers)
  end

  step "none of their processes are started", context do
    # What the MC runs at boot and when a client lists its providers.
    HalC2.Acp.load()
    entries = Map.new(HalC2.Acp.entries(), &{&1["instanceId"], &1})

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

    {settings, version} = HalC2.Settings.get()

    instances =
      Map.put(settings["providerInstances"] || %{}, instance, %{
        "driver" => "acme",
        "enabled" => true
      })

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "providerInstances", instances), version)

    context =
      World.create_thread(context, "Acme work", "shop", %{
        "modelSelection" => %{"instanceId" => instance, "model" => "acme-1"}
      })

    Map.merge(context, %{thread: World.thread_id(context, "Acme work"), instance: instance})
  end

  step "the plugin behind {string} has been removed", %{args: [instance]} = context do
    driver = get_in(HalC2.Settings.settings(), ["providerInstances", instance, "driver"])
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
    assert message =~ ~s("#{context.instance}" is not available on this MC)
    context
  end

  step "no other provider runs the turn in its place", context do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(context.thread))
    assert Turns.runs(state) == []
    assert StreamState.list(state, "message") == []
    assert Registry.lookup(HalC2.Codex.Registry, context.thread) == []
    context
  end

  # --- provider plugins ----------------------------------------------------------------

  # A thread on `instance` working in a git checkout of its own, so its turns take
  # checkpoints that can be restored; its first message is `text`.
  defp launch(context, instance, text) do
    work = World.git_repo(context, "work")
    thread_id = "thread-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.launch_thread(%{
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => World.project(context, "shop").id,
        "title" => "Work on #{instance}",
        "modelSelection" => %{"instanceId" => instance, "model" => "#{instance}-1"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{
          "type" => "existing_worktree",
          "worktreePath" => work,
          "branch" => "main"
        },
        "initialMessage" => %{"messageId" => "m1", "text" => text, "attachments" => []}
      })

    Map.merge(context, %{thread_id: thread_id, work: work})
  end

  defp state(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp session(thread_id) do
    World.await_stream(thread_id, fn state ->
      List.first(StreamState.list(state, "provider-session"))
    end)
  end

  defp snapshot(instance), do: FakeAcp.find(HalC2.Environment.providers(), instance)

  defp answers(thread_id) do
    for %{"role" => "assistant", "text" => text} <- StreamState.list(state(thread_id), "message"),
        do: text
  end

  defp rollback(thread_id, ordinal) do
    scope_id = HalC2.Checkpoint.scope_id(thread_id)

    HalC2.Orchestration.dispatch(%{
      "type" => "checkpoint.rollback",
      "commandId" => "cmd-#{System.unique_integer([:positive])}",
      "threadId" => thread_id,
      "scopeId" => scope_id,
      "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope_id, ordinal)
    })
  end

  # Installs the provider fixture `id` (`Fixtures.provider/2` with `opts`) and turns it on.
  defp provider_plugin(context, id, opts \\ []) do
    context
    |> Turns.providers()
    |> Fixtures.install(id, Fixtures.provider(id, opts))
    |> Fixtures.enable(id)
  end

  step "an MC with no provider plugins installed", context do
    Application.put_env(:hal_c2, :bundled_plugins, [])
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :bundled_plugins) end)
    context = Fixtures.ensure(context)

    assert Enum.filter(
             elem(HalC2.Plugins.handle("list", %{}), 1)["plugins"],
             &(&1["kind"] == "providerAdapter")
           ) == []

    context
  end

  step "the user is told to add a provider before starting a thread", context do
    assert HalC2.Environment.providers() == []
    context = World.create_thread(context, "First", "shop")
    thread_id = World.thread_id(context, "First")
    {reply, context} = World.dispatch(context, Turns.message(thread_id, "m1", "hello"))
    assert {:error, message, _} = reply
    assert message =~ "Add a provider before starting a thread"
    assert Turns.runs(state(thread_id)) == []
    context
  end

  step "the bundled plugins {string} and {string}", %{args: ids} = context do
    context = context |> Turns.providers() |> Fixtures.ensure()

    for id <- ids,
        do: assert(%{"source" => "bundled", "status" => "running"} = Fixtures.entry(id))

    drivers = Enum.map(HalC2.Environment.providers(), & &1["driver"])
    assert "codex" in drivers and "claudeAgent" in drivers
    context
  end

  step "the user disables the {string} plugin", %{args: [id]} = context do
    {_, context} = World.call!(context, "plugins.disable", %{"id" => id})
    assert %{"enabled" => false, "status" => "disabled"} = Fixtures.entry(id)
    context
  end

  step "Claude keeps working", context do
    {thread_id, context} = Turns.send_first(context, "claudeAgent", "hello")
    [%{"providerInstanceId" => "claudeAgent"}] = Turns.await_runs(thread_id, ["completed"])
    assert "Hello from claude" in answers(thread_id)
    context
  end

  step "the bundled plugin {string} has a newer version available", %{args: [id]} = context do
    context = context |> Turns.providers() |> Fixtures.ensure()
    Fixtures.probe()
    mc_version = HalC2.Upgrade.version()
    assert %{"source" => "bundled", "version" => ^mc_version} = Fixtures.entry(id)

    context
    |> Map.put(:mc_version, mc_version)
    |> Map.update(:plugin_updates, %{id => claude_update()}, &Map.put(&1, id, claude_update()))
  end

  step "Claude runs on the new plugin version", context do
    assert %{"source" => "file", "version" => "2.0.0", "status" => "running"} =
             Fixtures.entry("claude")

    {thread_id, context} = Turns.send_first(context, "claudeAgent", "hello")
    assert_receive {:plugin_turn, "claude", "2.0.0"}, 5_000
    [_] = Turns.await_runs(thread_id, ["completed"])
    assert "Hello from claude" in answers(thread_id)
    context
  end

  step "the MC version is unchanged", context do
    assert HalC2.Upgrade.version() == context.mc_version
    context
  end

  step "a provider plugin {string} that implements the adapter contract directly",
       %{args: [id]} = context do
    Map.put(context, :plugin, id)
  end

  step "the plugin is installed and enabled", context do
    provider_plugin(context, context.plugin)
  end

  step "{string} is listed as a provider", %{args: [id]} = context do
    assert %{"driver" => ^id, "availability" => "available", "models" => [_]} = snapshot(id)
    context
  end

  step "it can run turns in {string}", %{args: [_project]} = context do
    context = launch(context, context.plugin, "hello")
    [%{"providerInstanceId" => instance}] = Turns.await_runs(context.thread_id, ["completed"])
    assert instance == context.plugin
    assert answers(context.thread_id) == ["Hello from #{context.plugin}"]
    context
  end

  step "the plugin {string} is running a turn with a message queued behind it",
       %{args: [id]} = context do
    context = launch(context, id, "wait")
    [_] = Turns.await_runs(context.thread_id, ["running"])

    queued =
      context.thread_id
      |> Turns.message("m2", "hello again")
      |> Map.put("dispatchMode", %{"type" => "queue_after_active"})

    {{:ok, _}, context} = World.dispatch(context, queued)
    [_, _] = Turns.await_runs(context.thread_id, ["running", "queued"])
    context
  end

  step "the process running that turn crashes", context do
    pid = GenServer.call(Fixtures.module(context.plugin), {:turn, context.thread_id})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    context
  end

  step "the run fails saying the provider's session ended unexpectedly", context do
    World.await_stream(context.thread_id, &match?([%{"status" => "failed"} | _], Turns.runs(&1)))

    assert session(context.thread_id)["lastError"] ==
             "The provider's session ended unexpectedly."

    context
  end

  step "the queued message runs", context do
    [_, _] = Turns.await_runs(context.thread_id, ["failed", "completed"])
    context
  end

  # --- removing a provider plugin -----------------------------------------------------

  step "threads in {string} that ran on {string}", %{args: [project, id]} = context do
    context = provider_plugin(context, id) |> Map.put(:plugin, id)
    context = launch(context, id, "write a.txt")
    [_] = Turns.await_runs(context.thread_id, ["completed"])
    assert World.project(context, project)
    context
  end

  step "the user removes the {string} plugin", %{args: [id]} = context do
    context = Fixtures.remove(context, id)
    assert Fixtures.entry(id) == nil
    context
  end

  step "those threads still show their full history", context do
    state = state(context.thread_id)
    assert [%{"status" => "completed"}] = Turns.runs(state)

    assert Enum.map(StreamState.list(state, "message"), &{&1["role"], &1["text"]}) == [
             {"user", "write a.txt"},
             {"assistant", "Hello from #{context.plugin}"}
           ]

    context
  end

  step "their diffs and checkpoints can still be viewed", context do
    # The run's own checkpoint, next to the baseline (ordinal 0) it diffs against.
    checkpoints = StreamState.list(state(context.thread_id), "checkpoint")
    assert Enum.all?(checkpoints, &(&1["status"] == "ready"))
    assert Enum.any?(checkpoints, &(&1["appRunOrdinal"] == 1))

    assert {:ok, %{"diff" => diff}} =
             HalC2.Orchestration.handle("orchestration.getTurnDiff", %{
               "threadId" => context.thread_id,
               "fromTurnCount" => 0,
               "toTurnCount" => 1
             })

    assert diff =~ "+++ b/a.txt"
    context
  end

  step "the instance {string} has custom settings", %{args: [instance]} = context do
    context = provider_plugin(context, "acme")
    {settings, version} = HalC2.Settings.get()

    instances =
      Map.put(settings["providerInstances"] || %{}, instance, %{
        "driver" => "acme",
        "enabled" => true,
        "displayName" => "Acme at work",
        "config" => %{"greeting" => "hi team"}
      })

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "providerInstances", instances), version)
    assert %{"displayName" => "Acme at work", "availability" => "available"} = snapshot(instance)
    Map.put(context, :instance, instance)
  end

  step "its plugin is removed", context do
    Fixtures.remove(context, "acme")
  end

  step "the instance is listed as unavailable with its settings preserved", context do
    assert %{"availability" => "unavailable", "displayName" => "Acme at work"} =
             snapshot(context.instance)

    assert %{"driver" => "acme", "config" => %{"greeting" => "hi team"}} =
             HalC2.Settings.settings()["providerInstances"][context.instance]

    context
  end

  step "the plugin is installed again", context do
    context = Fixtures.install(context, "acme")
    assert %{"status" => "running"} = Fixtures.entry("acme")
    context
  end

  step "{string} works with the same settings", %{args: [instance]} = context do
    assert %{"availability" => "available"} = snapshot(instance)
    {thread_id, context} = Turns.send_first(context, instance, "hello")
    [_] = Turns.await_runs(thread_id, ["completed"])
    assert answers(thread_id) == ["Hello from acme (hi team)"]
    context
  end

  step "a thread that ran on a provider whose plugin was removed", context do
    context = context |> Turns.providers() |> provider_plugin("acme")
    context = launch(context, "acme", "remember the basket")
    [_] = Turns.await_runs(context.thread_id, ["completed"])
    context = Fixtures.remove(context, "acme")
    assert {:missing, "acme"} = HalC2.Plugins.provider("acme")
    context
  end

  step "the turn runs on Claude with the thread's history as context", context do
    [_, second] = Turns.await_runs(context.thread_id, ["completed", "completed"])
    assert second["providerInstanceId"] == "claudeAgent"
    assert Enum.any?(answers(context.thread_id), &(&1 =~ "history True"))
    context
  end

  # --- capabilities ---------------------------------------------------------------------

  @capabilities %{
    "interrupt" => :interrupt,
    "active steering" => :active_steering,
    "fork" => :fork,
    "rollback" => :rollback,
    "structured approval" => :approvals,
    "plan updates" => :plan_updates,
    "model switching" => :model_switching,
    "interaction mode" => :interaction_mode,
    "text generation" => :text_generation,
    "native sessions" => :native_sessions,
    "usage limits" => :usage_limits,
    "sign-in" => :sign_in
  }

  step "a provider plugin that does not declare {string}", %{args: [name]} = context do
    missing = Map.fetch!(@capabilities, name)
    capabilities = HalC2.Plugins.ProviderAdapter.capabilities() -- [missing]
    context = provider_plugin(context, "acme", capabilities: capabilities)
    refute missing in HalC2.Plugins.declared("acme").capabilities
    Map.put(context, :missing, missing)
  end

  step "the user works in a thread on that provider", context do
    text = if context.missing in [:interrupt, :active_steering], do: "wait", else: "write a.txt"
    context = launch(context, "acme", text)
    status = if text == "wait", do: "running", else: "completed"
    [_] = Turns.await_runs(context.thread_id, [status])
    Map.put(context, :session, session(context.thread_id))
  end

  step "the stop control is not offered while a turn runs", context do
    refute context.session["capabilities"]["turns"]["supportsInterrupt"]

    assert {:error, "The provider \"acme\" cannot stop a running turn."} =
             HalC2.Orchestration.dispatch(%{
               "type" => "run.interrupt",
               "commandId" => "cmd-stop",
               "threadId" => context.thread_id
             })

    assert [%{"status" => "running"}] = Turns.runs(state(context.thread_id))
    context
  end

  step "a follow-up interrupts the turn and starts again with the message", context do
    assert %{"supportsActiveSteering" => false, "supportsSteeringByInterruptRestart" => true} =
             context.session["capabilities"]["turns"]

    {{:ok, _}, context} =
      World.dispatch(
        context,
        Map.put(
          Turns.message(context.thread_id, "m2", "use the red button"),
          "deliveryIntent",
          "steer"
        )
      )

    [_, restarted] = Turns.await_runs(context.thread_id, ["interrupted", "completed"])
    assert Turns.await_user_item(context.thread_id, "m2")["runId"] == restarted["id"]
    assert answers(context.thread_id) == ["Hello from acme"]
    context
  end

  step "forking copies the history into a new thread and starts a fresh session", context do
    refute context.session["capabilities"]["threads"]["canForkThread"]
    fork_id = "fork-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-fork",
        "sourceThreadId" => context.thread_id,
        "targetThreadId" => fork_id
      })

    assert Enum.map(StreamState.list(state(fork_id), "message"), & &1["text"]) == [
             "write a.txt",
             "Hello from acme"
           ]

    {{:ok, _}, context} = World.dispatch(context, Turns.message(fork_id, "f1", "carry on"))
    [_, _] = Turns.await_runs(fork_id, ["completed", "completed"])
    assert "Hello from acme and the history" in answers(fork_id)

    [source_thread] = StreamState.list(state(context.thread_id), "provider-thread")

    assert Enum.all?(
             StreamState.list(state(fork_id), "provider-thread"),
             &(&1["id"] != source_thread["id"])
           )

    context
  end

  step "reverting restores files and marks the agent context as divergent", context do
    refute context.session["capabilities"]["threads"]["canRollbackThread"]

    {{:ok, _}, context} =
      World.dispatch(context, Turns.message(context.thread_id, "m2", "write b.txt"))

    [_, _] = Turns.await_runs(context.thread_id, ["completed", "completed"])
    assert File.exists?(Path.join(context.work, "b.txt"))

    assert {:ok, _} = rollback(context.thread_id, 1)
    assert File.exists?(Path.join(context.work, "a.txt"))
    refute File.exists?(Path.join(context.work, "b.txt"))

    assert [%{"contextDivergent" => true, "nativeThreadRef" => nil}] =
             StreamState.list(state(context.thread_id), "provider-thread")

    context
  end

  step "no approval prompts are shown and the plugin decides on its own", context do
    approvals = context.session["capabilities"]["approvals"]
    refute approvals["supportsCommandApproval"] or approvals["supportsFileChangeApproval"]
    assert StreamState.list(state(context.thread_id), "runtime-request") == []
    assert File.exists?(Path.join(context.work, "a.txt"))
    context
  end

  step "no task list is shown for the turn", context do
    planning = context.session["capabilities"]["planning"]
    refute planning["emitsPlanUpdated"] or planning["emitsTodoList"]
    assert StreamState.list(state(context.thread_id), "plan") == []
    context
  end

  step "changing the model starts a new thread", context do
    assert %{"requiresNewThreadForModelChange" => true} = snapshot("acme")
    refute context.session["capabilities"]["sessions"]["supportsModelSwitchInSession"]

    command =
      context.thread_id
      |> Turns.message("m2", "try the other model")
      |> Map.put("modelSelection", %{"instanceId" => "acme", "model" => "acme-2"})

    {reply, context} = World.dispatch(context, command)
    assert {:error, message, _} = reply
    assert message =~ "Start a new thread to use acme-2"
    assert [_] = Turns.runs(state(context.thread_id))
    context
  end

  step "the plan mode toggle is not offered", context do
    assert %{"showInteractionModeToggle" => false} = snapshot("acme")
    context
  end

  step "the provider cannot be picked for titles and commit messages", context do
    assert %{"supportsTextGeneration" => false} = snapshot("acme")
    {settings, version} = HalC2.Settings.get()

    selection = %{"instanceId" => "acme", "model" => "acme-1"}

    {:ok, _} =
      HalC2.Settings.put(Map.put(settings, "textGenerationModelSelection", selection), version)

    assert {:error, message} = HalC2.TextGeneration.branch_name(context.work, "fix the basket")
    assert message =~ "No text generation provider is available"
    context
  end

  step "there is nothing to import from this provider", context do
    refute Map.has_key?(snapshot("acme"), "nativeSessions")

    assert {:error, %{"_tag" => _, "message" => message}} =
             HalC2.Acp.Sessions.list(%{
               "instanceId" => "acme",
               "projectId" => World.project(context, "shop").id
             })

    assert message =~ "unknown ACP agent acme"
    context
  end

  step "the limits view does not list this provider", context do
    refute Map.has_key?(snapshot("acme"), "usageLimits")
    assert HalC2.ProviderUsageLimits.get("acme") == nil
    context
  end

  step "the user is pointed to the provider's documentation to sign in", context do
    assert %{
             "setup" => %{
               "canAuthenticate" => false,
               "documentationUrl" => "https://acme.example.com/docs/sign-in"
             }
           } = snapshot("acme")

    assert {:error, %{"message" => "This provider does not sign in here."}} =
             HalC2.ProviderAuth.start(%{"instanceId" => "acme"})

    context
  end

  step "a provider plugin that declares rollback but fails every rollback", context do
    context = provider_plugin(context, "acme", rollback_fails: true)
    assert :rollback in HalC2.Plugins.declared("acme").capabilities
    context = launch(context, "acme", "write a.txt")
    [_] = Turns.await_runs(context.thread_id, ["completed"])

    {{:ok, _}, context} =
      World.dispatch(context, Turns.message(context.thread_id, "m2", "write b.txt"))

    [_, _] = Turns.await_runs(context.thread_id, ["completed", "completed"])
    context
  end

  step "the user reverts a turn on that provider", context do
    Map.put(context, :revert, rollback(context.thread_id, 1))
  end

  step "the revert fails with the plugin's error", context do
    # Named as the rollback of the plugin's provider thread, with the plugin's reason.
    assert {:error, message} = context.revert

    assert message =~
             ~r/^Failed to roll back acme provider thread .+: acme could not rewind its conversation$/

    context
  end

  step "the thread is left as it was before the revert", context do
    state = state(context.thread_id)
    assert Enum.map(Turns.runs(state), & &1["status"]) == ["completed", "completed"]
    assert Enum.all?(StreamState.list(state, "checkpoint"), &(&1["status"] == "ready"))
    assert File.exists?(Path.join(context.work, "b.txt"))
    context
  end

  # --- ACP ---------------------------------------------------------------------------

  step "a new agent that speaks ACP", context do
    context = context |> Turns.providers() |> Fixtures.ensure() |> AcpRegistry.ensure()
    Map.put(context, :agent, "newcomer")
  end

  step "its author publishes it to the ACP registry", context do
    AcpRegistry.publish(context, [AcpRegistry.agent(context, context.agent)])
  end

  step "users can add it from the registry without a HAL-C2 plugin", context do
    plugins = elem(HalC2.Plugins.handle("list", %{}), 1)["plugins"]
    agent = context.agent

    {_, context} = World.call!(context, "server.prepareAcpRegistryAgent", %{"agentId" => agent})
    context = AcpRegistry.add_instance(context, agent, agent)
    assert {:ok, ^agent, HalC2.Plugins.Bundled.Acp} = HalC2.Plugins.provider(agent)

    {thread_id, context} = Turns.send_first(context, agent, "list the files")
    [_] = Turns.await_runs(thread_id, ["completed"])
    assert answers(thread_id) == ["Hello from acp"]
    assert elem(HalC2.Plugins.handle("list", %{}), 1)["plugins"] == plugins
    context
  end

  step "a provider plugin {string} built on the ACP contract", %{args: [agent]} = context do
    context = context |> Fixtures.ensure() |> FakeAcp.install(agent, %{}, enabled: true)
    assert {:ok, ^agent, HalC2.Plugins.Bundled.Acp} = HalC2.Plugins.provider(agent)
    context
  end

  # Grok's `x.ai/exit_plan_mode` request is outside ACP (`HalC2.Acp.ThreadRuntime`).
  step "it adds a plan capture that plain ACP does not have", context do
    method = "x.ai/exit_plan_mode"
    refute String.starts_with?(method, ["session/", "fs/", "terminal/"])

    plan = %{
      "match" => "plan the work",
      "steps" => [
        %{
          "request" => %{
            "method" => method,
            "params" => %{"toolCallId" => "plan-1", "planContent" => "# Plan\n\n1. Add the form"}
          }
        }
      ]
    }

    FakeAcp.install(context, context.provider, %{"turns" => [plan | FakeAcp.turns()]},
      enabled: true
    )
  end

  step "a Grok turn proposes a plan", context do
    context =
      context
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("plan the work")

    FakeAcp.await_run(context, "completed")
    Map.put(context, :expected_plan, "# Plan\n\n1. Add the form")
  end

  step "threads are running on Claude and on an ACP agent", context do
    context = context |> Turns.providers() |> Fixtures.ensure()
    {claude, context} = Turns.send_first(context, "claudeAgent", "wait for it")
    [_] = Turns.await_runs(claude, ["running"])

    {acp, context} =
      Turns.send_first(context, "opencode", "approve ls", %{"runtimeMode" => "approval-required"})

    World.await_stream(acp, fn state ->
      Enum.find(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
    end)

    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, claude)
    Map.merge(context, %{claude: claude, claude_runtime: runtime, acp: acp})
  end

  step "the ACP agent's plugin crashes", context do
    sessions = HalC2.Plugins.sessions("acp")
    assert sessions != HalC2.Plugins.sessions("claudeAgent")
    Process.exit(sessions, :kill)
    context
  end

  step "the Claude threads keep running", context do
    assert Process.alive?(context.claude_runtime)
    assert [%{"status" => "running"}] = Turns.runs(state(context.claude))
    context
  end

  step "the ACP agent's threads show that their session ended", context do
    [_] = Turns.await_runs(context.acp, ["failed"])
    [session] = StreamState.list(state(context.acp), "provider-session")
    assert session["lastError"] =~ "session ended"
    context
  end

  # --- what a provider plugin declares ---------------------------------------------------

  step "the provider plugin {string} declares a binary path and an API key setting",
       %{args: [id]} = context do
    provider_plugin(context, id,
      instance_settings: [
        %{key: "binaryPath", label: "Binary path"},
        %{key: "apiKey", label: "API key", secret: true}
      ]
    )
  end

  step "the user adds an {string} instance", %{args: [id]} = context do
    {%{"plugins" => plugins}, context} = World.call!(context, "plugins.list")
    Map.put(context, :plugin_entry, Enum.find(plugins, &(&1["id"] == id)))
  end

  step "the user is asked for a binary path and an API key", context do
    assert context.plugin_entry["provider"]["instanceSettings"] == [
             %{"key" => "binaryPath", "label" => "Binary path", "secret" => false},
             %{"key" => "apiKey", "label" => "API key", "secret" => true}
           ]

    context
  end

  step "the provider plugin {string} declares an icon and an accent colour",
       %{args: [id]} = context do
    provider_plugin(context, id,
      icon: "https://#{id}.example.com/icon.svg",
      accent_color: "#ff6600"
    )
  end

  step "the user looks at the provider list", context do
    elem(FakeAcp.open_config(context), 1)
  end

  step "{string} is shown with its own icon and colour", %{args: [id]} = context do
    assert %{"iconUrl" => icon, "accentColor" => "#ff6600"} = FakeAcp.find(context.providers, id)
    assert icon == "https://#{id}.example.com/icon.svg"
    context
  end

  step "the provider plugin {string} supports every mode except auto",
       %{args: [agent]} = context do
    context = context |> Fixtures.ensure() |> FakeAcp.install(agent, %{}, enabled: true)
    assert {:ok, ^agent, HalC2.Plugins.Bundled.Acp} = HalC2.Plugins.provider(agent)
    context
  end

  step "the user opens the runtime access picker for a Pi thread", context do
    context |> FakeAcp.thread("Work") |> FakeAcp.open_config() |> elem(1)
  end

  step "the MC has the provider plugin {string} that no client knows about",
       %{args: [id]} = context do
    context =
      provider_plugin(context, id, name: "Acme Agent", icon: "https://#{id}.example.com/icon.svg")

    refute id in ~w(codex claudeAgent) or HalC2.Acp.agent?(id)
    context
  end

  step "the user opens the model picker on any client", context do
    elem(FakeAcp.open_config(context), 1)
  end

  step "{string} and its models are listed with the plugin's name and icon",
       %{args: [id]} = context do
    assert %{"displayName" => "Acme Agent", "iconUrl" => icon, "models" => models} =
             FakeAcp.find(context.providers, id)

    assert icon == "https://#{id}.example.com/icon.svg"

    assert Enum.map(models, &Map.take(&1, ~w(slug name isDefault))) == [
             %{"slug" => "#{id}-1", "name" => "Acme One", "isDefault" => true}
           ]

    context
  end

  # Claude as a plugin file: the bundled adapter at version 2.0.0, telling the
  # probe each turn it runs.
  defp claude_update do
    """
    defmodule HalC2PluginFixture.ClaudeUpdate do
      @behaviour HalC2.Plugins.ProviderAdapter
      alias HalC2.Claude.ThreadRuntime

      def manifest, do: %{HalC2.Plugins.Bundled.Claude.manifest() | version: "2.0.0"}

      def start_turn(thread_id, turn) do
        if probe = Process.whereis(:hal_c2_plugin_probe), do: send(probe, {:plugin_turn, "claude", "2.0.0"})
        ThreadRuntime.start_turn(thread_id, turn)
      end

      defdelegate interrupt(thread_id, run_id), to: ThreadRuntime
      defdelegate steer(thread_id, run_id, text), to: ThreadRuntime
      defdelegate respond(thread_id, request_id, response), to: ThreadRuntime
      defdelegate rollback(thread_id, plan), to: ThreadRuntime
      defdelegate providers(settings), to: HalC2.Plugins.Bundled.Claude
    end
    """
  end
end
