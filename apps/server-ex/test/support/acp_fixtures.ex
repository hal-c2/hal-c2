defmodule HalC2.Test.AcpFixtures do
  @moduledoc """
  Fake provider agents for the provider features (`features/providers/`).

  `ready/1` brings up the provider services a node runs (settings, ACP, sign-in,
  URL sign-in) with Codex and Claude replaced by their fakes, and nothing reaching
  the network. Agents are `test/support/fake_acme_agent.py` (any ACP agent: Grok,
  OpenCode, registry agents) and `test/support/fake_cursor.mjs` (the real Cursor
  ACP agent over a fake Cursor SDK). Each agent's behaviour is set under its name
  in `<home>/agents/control.json` (`control/3`), and its launches and requests are
  logged to `<home>/agents/<name>.log` (`log/2`).
  """

  import ExUnit.Assertions

  alias HalC2.StreamState

  @support Path.expand(".", __DIR__)
  @fake_agent Path.join(@support, "fake_acme_agent.py")
  @fake_cursor Path.join(@support, "fake_cursor.mjs")
  @fake_codex Path.join(@support, "fake_codex.py")
  @fake_claude Path.join(@support, "fake_claude.py")
  @fake_text Path.join(@support, "fake_text_cli.py")

  @app_keys [
    :codex_command,
    :claude_command,
    :acp_commands,
    :acp_registry_url,
    :text_codex_command,
    :text_claude_command,
    :provider_update_checks
  ]
  @os_keys ["HAL_C2_NODE_COMMAND", "HAL_C2_NODE_ELECTRON", "PATH", "FAKE_TEXT_LOG"]

  @doc "Starts the provider services with fake Codex and Claude; idempotent."
  def ready(%{acp: _} = ctx), do: ctx

  def ready(ctx) do
    dir = Path.join(ctx.node.home, "agents")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "control.json"), "{}")

    app = for key <- @app_keys, do: {key, Application.fetch_env(:hal_c2, key)}
    os = for key <- @os_keys, do: {key, System.get_env(key)}

    ExUnit.Callbacks.on_exit(fn ->
      for {key, value} <- app do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end

      for {key, value} <- os,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      forget_all()
    end)

    forget_all()
    # Fakes another step set up first are kept.
    put_new(:codex_command, ["python3", "-u", @fake_codex])
    put_new(:claude_command, ["python3", "-u", @fake_claude])
    put_new(:acp_commands, %{})
    # Nothing reaches the real ACP or npm registries; `registry/2` serves one.
    Application.put_env(:hal_c2, :acp_registry_url, "http://127.0.0.1:1/registry.json")
    Application.put_env(:hal_c2, :provider_update_checks, false)
    Application.put_env(:hal_c2, :text_codex_command, @fake_text)
    Application.put_env(:hal_c2, :text_claude_command, @fake_text)
    System.put_env("FAKE_TEXT_LOG", Path.join(dir, "text.log"))
    System.delete_env("HAL_C2_NODE_ELECTRON")

    HalC2.Test.Node.ensure(HalC2.Settings)
    HalC2.Test.Node.ensure({Registry, keys: :unique, name: HalC2.Codex.Registry})

    HalC2.Test.Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      )
    )

    HalC2.Test.Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      )
    )

    HalC2.Test.Node.ensure(
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}
    )

    HalC2.Test.Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.ProviderAuth.Registry},
        id: :provider_auth_registry
      )
    )

    HalC2.Test.Node.ensure(
      {DynamicSupervisor, name: HalC2.ProviderAuth.Supervisor, strategy: :one_for_one}
    )

    HalC2.Test.Node.ensure(HalC2.Acp.UrlAuth)
    cursor_node(dir)
    Map.put(ctx, :acp, %{dir: dir})
  end

  defp put_new(key, value) do
    if Application.get_env(:hal_c2, key) == nil, do: Application.put_env(:hal_c2, key, value)
  end

  # What the node read from agents and registries lives in persistent terms.
  defp forget_all do
    for {key, _} <- :persistent_term.get(),
        is_tuple(key),
        elem(key, 0) in [
          HalC2.Acp,
          HalC2.Acp.Catalog,
          HalC2.Codex.Provider,
          HalC2.Claude.Provider,
          HalC2.ProviderUpdates
        ],
        do: :persistent_term.erase(key)
  end

  # Cursor's sidecar runs `$HAL_C2_NODE_COMMAND <main.ts> --mode <mode>`; this node
  # command drops main.ts and runs the fake SDK's agent instead.
  defp cursor_node(dir) do
    path = Path.join(dir, "cursor-node")
    File.write!(path, "#!/bin/sh\nshift\nexec node #{@fake_cursor} --control #{dir} \"$@\"\n")
    File.chmod!(path, 0o755)
    System.put_env("HAL_C2_NODE_COMMAND", path)
  end

  @doc "The fake agents' directory."
  def dir(ctx), do: ctx.acp.dir

  @doc "Merges `fields` into the behaviour of the fake agent `name`."
  def control(ctx, name, fields) do
    path = Path.join(dir(ctx), "control.json")
    all = path |> File.read!() |> JSON.decode!()
    File.write!(path, JSON.encode!(Map.update(all, name, fields, &Map.merge(&1, fields))))
    ctx
  end

  @doc "The argv that runs the fake agent `name`."
  def agent_cmd(ctx, name),
    do: ["python3", "-u", @fake_agent, "--control", dir(ctx), "--name", name]

  @doc "Writes an executable at `path` that runs the fake agent `name`."
  def wrapper(ctx, path, name) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "#!/bin/sh\nexec python3 -u #{@fake_agent} --control #{dir(ctx)} --name #{name} --argv0 \"$0\" \"$@\"\n"
    )

    File.chmod!(path, 0o755)
    path
  end

  @doc "Runs instance `id`'s agent as the fake agent `name` (`:acp_commands`)."
  def run_as(ctx, id, name) do
    commands = Application.get_env(:hal_c2, :acp_commands, %{})
    Application.put_env(:hal_c2, :acp_commands, Map.put(commands, id, agent_cmd(ctx, name)))
    ctx
  end

  @doc "Every entry the fake agent `name` logged, oldest first."
  def log(ctx, name) do
    case File.read(Path.join(dir(ctx), name <> ".log")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  def launches(ctx, name), do: Enum.filter(log(ctx, name), &(&1["event"] == "launch"))

  def requests(ctx, name, method),
    do: Enum.filter(log(ctx, name), &(&1["event"] == "request" and &1["method"] == method))

  @doc "Changes the settings document with `fun` (as a client write would land)."
  def put_settings(fun) do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(fun.(settings), version)
    :ok
  end

  @doc "Sets `providerInstances.<id>` (merged into what is there)."
  def put_instance(id, fields) do
    put_settings(fn settings ->
      instances = settings["providerInstances"] || %{}

      Map.put(
        settings,
        "providerInstances",
        Map.put(instances, id, Map.merge(instances[id] || %{}, fields))
      )
    end)
  end

  @doc "Sets `providers.<driver>` fields."
  def put_provider(driver, fields) do
    put_settings(fn settings ->
      providers = settings["providers"] || %{}

      Map.put(
        settings,
        "providers",
        Map.put(providers, driver, Map.merge(providers[driver] || %{}, fields))
      )
    end)
  end

  @doc """
  Writes the settings through a client (`hal-c2.readSettings`, then
  `hal-c2.writeSettings`), as the settings UI does.
  """
  def write_settings(ctx, fun, name \\ "default") do
    {%{"settings" => settings, "version" => version}, ctx} =
      HalC2.Test.Node.World.call!(ctx, "hal-c2.readSettings", %{}, name)

    {_, ctx} =
      HalC2.Test.Node.World.call!(
        ctx,
        "hal-c2.writeSettings",
        %{"settings" => fun.(settings), "version" => version},
        name
      )

    ctx
  end

  @doc "The provider entry for `id` as clients get it, or nil."
  def provider(id), do: Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == id))

  @doc "Reads instance `id`'s agent again now, as a status check does."
  def check(id) do
    HalC2.Acp.reload(id)
    HalC2.Acp.entry(id)
  end

  # --- the ACP Registry --------------------------------------------------------------

  defmodule Files do
    @moduledoc false
    @behaviour Plug

    def init(dir), do: dir

    def call(%{request_path: "/" <> name} = conn, dir) do
      File.write!(Path.join(dir, "requests.log"), name <> "\n", [:append])

      case File.read(Path.join(dir, name)) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        _ -> Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  @doc "Serves an ACP Registry on loopback and points the node at it; idempotent."
  def serve_registry(ctx) do
    ctx = ready(ctx)

    if ctx.acp[:served] do
      ctx
    else
      served = Path.join(dir(ctx), "served")
      File.mkdir_p!(served)

      server =
        ExUnit.Callbacks.start_supervised!(
          {Bandit, plug: {Files, served}, port: 0, ip: :loopback}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      base = "http://127.0.0.1:#{port}"
      Application.put_env(:hal_c2, :acp_registry_url, "#{base}/registry.json")
      %{ctx | acp: Map.merge(ctx.acp, %{served: served, base: base})}
    end
  end

  @doc """
  Publishes `agents` (default: `acme_agent/2`) on the served registry, and makes the
  node forget any registry it read before.
  """
  def publish(ctx, agents \\ nil) do
    ctx = serve_registry(ctx)
    agents = agents || [acme_agent(ctx)]

    File.write!(
      Path.join(ctx.acp.served, "registry.json"),
      JSON.encode!(%{"version" => "1.0.0", "agents" => agents})
    )

    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    File.rm(Path.join([ctx.node.home, "cache", "acp-registry", "registry.json"]))
    ctx
  end

  @doc "Registry fetches the served registry has answered (paths, oldest first)."
  def registry_requests(ctx) do
    case File.read(Path.join(ctx.acp.served, "requests.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  @doc """
  The registry entry of "acme" 2.0.0: a binary archive for this platform holding
  `bin/acme`, which runs the fake agent "acme" with the registry's arguments and
  environment. Options: `:id`, `:name`, `:sha256` (false leaves it out), `:archive`
  (the archive's bytes), `:dist` (a whole distribution map).
  """
  def acme_agent(ctx, opts \\ []) do
    id = opts[:id] || "acme"
    served = ctx.acp.served
    archive = Path.join(served, "#{id}.tar.gz")

    bytes =
      opts[:archive] ||
        (
          script = wrapper(ctx, Path.join([dir(ctx), "archive-src", id]), id)

          :ok =
            :erl_tar.create(
              to_charlist(archive),
              [{~c"bin/#{id}", to_charlist(script)}],
              [:compressed]
            )

          File.read!(archive)
        )

    File.write!(archive, bytes)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    target =
      %{
        "archive" => "#{ctx.acp.base}/#{id}.tar.gz",
        "cmd" => "./bin/#{id}",
        "args" => ["--acp"],
        "env" => %{"ACME_MODE" => "registry"}
      }
      |> then(
        &if(opts[:sha256] == false, do: &1, else: Map.put(&1, "sha256", opts[:sha256] || sha))
      )

    %{
      "id" => id,
      "name" => opts[:name] || String.capitalize(id),
      "version" => opts[:version] || "2.0.0",
      "description" => opts[:description] || "A test agent",
      "authors" => ["Acme"],
      "distribution" => opts[:dist] || %{"binary" => %{HalC2.Acp.Catalog.platform() => target}}
    }
  end

  @doc "Adds the registry instance `id` running agent `agent_id` (enabled)."
  def add_registry_instance(id, agent_id, fields \\ %{}) do
    put_instance(
      id,
      Map.merge(
        %{"driver" => "acpRegistry", "enabled" => true, "config" => %{"agentId" => agent_id}},
        fields
      )
    )
  end

  # --- threads -------------------------------------------------------------------------

  @doc """
  Starts a thread titled `title` in the context's first project, on `instance` with
  `runtime_mode`, sending `text`; returns the context with the thread recorded.
  """
  def launch(ctx, title, instance, text, opts \\ []) do
    {_, project} = Enum.at(ctx.projects, 0)
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      HalC2.Orchestration.launch_thread(%{
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => project.id,
        "title" => title,
        "modelSelection" => %{"instanceId" => instance, "model" => opts[:model] || "default"},
        "runtimeMode" => opts[:mode] || "full-access",
        "interactionMode" => opts[:interaction] || "default",
        "workspaceStrategy" =>
          if(opts[:worktree],
            do: %{
              "type" => "existing_worktree",
              "worktreePath" => project.root,
              "branch" => "main"
            },
            else: %{"type" => "root"}
          ),
        "initialMessage" => %{
          "messageId" => "msg-#{System.unique_integer([:positive])}",
          "text" => text,
          "attachments" => []
        }
      })

    %{ctx | threads: Map.put(ctx.threads, title, thread_id)}
  end

  @doc "Sends a follow-up message on a thread."
  def follow_up(ctx, title, text, extra \\ %{}) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "message.dispatch",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => ctx.threads[title],
            "messageId" => "msg-#{System.unique_integer([:positive])}",
            "text" => text,
            "attachments" => [],
            "dispatchMode" => %{"type" => "queue_after_active"}
          },
          extra
        )
      )

    ctx
  end

  @doc "A thread's current stream state."
  def stream(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  @doc "Waits until `fun.(state)` is truthy on the thread's stream; returns its value."
  def await_stream(thread_id, fun, timeout \\ 5_000) do
    case fun.(stream(thread_id)) do
      result when result not in [nil, false] ->
        result

      _ ->
        receive do
          {:hal_c2_stream, ^thread_id, _} -> await_stream(thread_id, fun, timeout)
        after
          timeout -> flunk("the thread never got there: #{inspect(summary(thread_id))}")
        end
    end
  end

  defp summary(thread_id) do
    state = stream(thread_id)

    %{
      runs: StreamState.list(state, "run") |> Enum.map(&Map.take(&1, ["ordinal", "status"])),
      items: StreamState.list(state, "turn-item") |> Enum.map(&Map.take(&1, ["type", "text"]))
    }
  end

  @doc "The thread's runs, oldest first."
  def runs(thread_id),
    do: thread_id |> stream() |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  @doc "Waits until the thread has `count` runs and all have finished; returns the runs."
  def await_runs(thread_id, count) do
    await_stream(thread_id, fn state ->
      runs = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

      if length(runs) == count and
           Enum.all?(runs, &(&1["status"] in ["completed", "failed", "interrupted", "cancelled"])),
         do: runs
    end)
  end

  @doc "The assistant's text in a thread, joined."
  def assistant_text(thread_id) do
    thread_id
    |> stream()
    |> StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] == "assistant_message"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  # --- sign-in -------------------------------------------------------------------------

  @doc """
  Subscribes the client `name` to instance `id`'s sign-in under `sub` and waits
  until the agent's methods are known; returns `{state, ctx}`.
  """
  def watch_auth(ctx, id, name \\ "default", sub \\ nil) do
    sub = sub || 1000 + System.unique_integer([:positive])
    client = HalC2.Test.Node.World.client(ctx, name)

    client =
      HalC2.Test.Node.sub(client, sub, %{
        "type" => "providerAuth",
        "node" => Atom.to_string(node()),
        "instanceId" => id
      })

    {frame, client} =
      HalC2.Test.Node.await(
        client,
        &(&1["t"] == "providerAuth" and &1["id"] == sub and is_list(&1["state"]["methods"])),
        5_000
      )

    ctx = HalC2.Test.Node.World.put_client(ctx, name, client)
    {frame["state"], put_in(ctx, [Access.key(:auth_subs, %{}), {name, id}], sub)}
  end

  @doc "Waits on client `name` for a sign-in state of `id` matching `fun`."
  def await_auth(ctx, id, fun, name \\ "default", timeout \\ 5_000) do
    sub = ctx.auth_subs[{name, id}] || flunk("client #{name} does not watch #{id}'s sign-in")

    {frame, client} =
      HalC2.Test.Node.await(
        HalC2.Test.Node.World.client(ctx, name),
        &(&1["t"] == "providerAuth" and &1["id"] == sub and fun.(&1["state"])),
        timeout
      )

    {frame["state"], HalC2.Test.Node.World.put_client(ctx, name, client)}
  end

  @doc "The sign-in process of instance `id`, if one runs."
  def auth_server(id) do
    case Registry.lookup(HalC2.ProviderAuth.Registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
