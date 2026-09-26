defmodule T3.Steps.Common do
  @moduledoc """
  Steps shared by more than one feature directory: the environment a scenario
  starts from, its projects and threads, and the node's lifecycle. A step that
  appears in several directories belongs here; one directory's steps live in
  its own file.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  # --- environments, projects and threads ---------------------------------------

  step "a connected environment", context do
    World.put_client(context, World.client(context))
  end

  step "a connected environment {string}", %{args: [label]} = context do
    context |> Map.put(:environment_label, label) |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the project {string}", %{args: [title]} = context do
    context |> World.create_project(title) |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment {string} with the project {string}",
       %{args: [label, title]} = context do
    context
    |> Map.put(:environment_label, label)
    |> World.create_project(title)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the projects {string} and {string}",
       %{args: [first, second]} = context do
    context
    |> World.create_project(first)
    |> World.create_project(second)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the idle thread {string} in the project {string}",
       %{args: [thread, project]} = context do
    context
    |> World.create_project(project)
    |> World.create_thread(thread, project)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the thread {string} in the project {string}",
       %{args: [thread, project]} = context do
    context
    |> World.create_project(project)
    |> World.create_thread(thread, project)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the idle thread {string}", %{args: [thread]} = context do
    context
    |> World.create_project("shop")
    |> World.create_thread(thread, "shop")
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step("a node", context, do: context)
  step("a running node", context, do: context)

  step "a node with a project {string}", %{args: [title]} = context do
    World.create_project(context, title)
  end

  step "two clients are connected to the node", context do
    context
    |> World.put_client("first", Node.connect(context.node))
    |> World.put_client("second", Node.connect(context.node))
  end

  step "a paired client", context do
    {:ok, access, _expires, _scopes} =
      T3.Auth.exchange(T3.Auth.create_pairing_token(context.node.store), %{"label" => "Phone"})

    {:ok, ticket, _} = T3.Auth.issue_ticket(access)
    client = Node.connect(context.node, "wsTicket=#{ticket}")
    context |> Map.put(:access_token, access) |> World.put_client("paired", client)
  end

  # --- the node's lifecycle ----------------------------------------------------------

  step "the node restarts", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "the node starts again", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "the node starts", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  # --- shared outcomes -----------------------------------------------------------------

  step "the request is refused with {string}", %{args: [message]} = context do
    assert {:error, error, _detail} = context.reply,
           "expected a refusal, got #{inspect(context.reply)}"

    assert error =~ message
    context
  end

  step "the socket stays open", context do
    client = T3.Test.WsClient.send_json(World.client(context), %{"t" => "ping"})
    {%{"t" => "pong"}, client} = T3.Test.WsClient.recv(client, 1_000)
    World.put_client(context, client)
  end

  # --- added by W10 ---

  # Providers run as the fakes of `T3.Test.AcpFixtures`; no real provider CLI starts.

  step "the user refreshes provider status", context do
    ctx = T3.Test.AcpFixtures.ready(context)
    Node.ensure(T3.ProviderUsageLimits)
    # The boot probe has finished once this returns.
    :ok = T3.ProviderUsageLimits.refresh([])
    before = Map.new(["codex", "claudeAgent"], &{&1, T3.ProviderUsageLimits.get(&1)})
    at = T3.Orchestration.Entities.now()
    {result, ctx} = World.call!(ctx, "server.refreshProviders", %{})
    Map.put(ctx, :refreshed, %{before: before, at: at, providers: result["providers"]})
  end

  step "the user disables Grok", context do
    T3.Test.AcpFixtures.write_settings(context, fn settings ->
      settings
      |> put_in([Access.key("providers", %{}), Access.key("grok", %{}), "enabled"], false)
      |> then(fn settings ->
        if is_map(get_in(settings, ["providerInstances", "grok"])),
          do: put_in(settings, ["providerInstances", "grok", "enabled"], false),
          else: settings
      end)
    end)
  end

  step "the user updates Codex", context do
    {reply, ctx} = World.call(context, "server.updateProvider", %{"provider" => "codex"})
    Map.put(ctx, :reply, reply)
  end

  step "Claude was installed in a way the node cannot identify", context do
    # An executable outside every installer's layout, behind the latest release.
    ctx = T3.Test.AcpFixtures.ready(context)
    fake_claude = Path.expand("../support/fake_claude.py", __DIR__)
    path = Path.join(context.node.home, "odd/bin/claude")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "2.0.0 (Claude Code)"; exit 0; fi
    exec python3 -u #{fake_claude} "$@"
    """)

    File.chmod!(path, 0o755)
    Application.put_env(:t3, :claude_command, [path])

    :persistent_term.put(
      {T3.ProviderUpdates, "claudeAgent"},
      {"9.9.9", System.monotonic_time(:millisecond)}
    )

    ctx
  end

  # ACP Registry steps shared with `features/plugins/plugin-catalog.feature` (and, for
  # cancelling, approving and stopping, other provider features). They leave the
  # node's answer in `context.reply`.

  step "the user searches the ACP registry for {string}", %{args: [query]} = context do
    alias T3.Test.AcpFixtures, as: Acp
    ctx = Acp.serve_registry(context)

    other =
      if T3.Acp.Catalog.platform() == "linux-x86_64", do: "darwin-aarch64", else: "linux-x86_64"

    agent = fn id, name, fields ->
      Map.merge(
        %{
          "id" => id,
          "name" => name,
          "version" => "1.0.0",
          "description" => "An ACP agent",
          "distribution" => %{"npx" => %{"package" => "@acme/#{id}"}}
        },
        fields
      )
    end

    # Built only for another platform.
    elsewhere = %{
      "distribution" => %{
        "binary" => %{other => %{"archive" => "https://example.com/a.tar.gz", "cmd" => "./a"}}
      }
    }

    agents =
      [
        agent.("agent", "Agent", %{}),
        agent.("code", "Code", %{"description" => "A test tool"}),
        agent.("agent-0-elsewhere", "Agent 0 Elsewhere", elsewhere),
        agent.("code-elsewhere", "Code Elsewhere", elsewhere)
      ] ++
        for(n <- 1..24, do: agent.("agent-#{n}", "Agent #{n}", %{"description" => "writes code"}))

    ctx = Acp.publish(ctx, agents)
    {reply, ctx} = World.call(ctx, "server.searchAcpRegistry", %{"query" => query})
    Map.merge(ctx, %{reply: reply, query: query})
  end

  step "the user searches the registry", context do
    {reply, ctx} = World.call(context, "server.searchAcpRegistry", %{"query" => "acme"})
    Map.put(ctx, :reply, reply)
  end

  step "the user adds {string}", %{args: [id]} = context do
    {reply, ctx} = World.call(context, "server.prepareAcpRegistryAgent", %{"agentId" => id})
    # A client creates the instance only once the agent is prepared.
    if match?({:ok, _}, reply), do: T3.Test.AcpFixtures.add_registry_instance(id, id)
    Map.put(ctx, :reply, reply)
  end

  # An ACP sign-in (`context.auth_instance`, `context.flow`), cancelled from the client
  # `context.auth_client` so the others see it end.
  step "the user cancels it", %{auth_instance: instance, flow: flow} = context do
    {state, ctx} =
      World.call!(
        context,
        "provider.auth.cancel",
        %{"instanceId" => instance, "flowId" => flow},
        context[:auth_client] || "default"
      )

    assert state["flowId"] == flow
    ctx
  end

  # The pending request of the turn on `context.thread`.
  step "the user is asked to approve it", context do
    thread_id = World.thread_id(context, context.thread)

    request =
      T3.Test.AcpFixtures.await_stream(thread_id, fn state ->
        state
        |> T3.StreamState.list("runtime-request")
        |> Enum.find(&(&1["status"] == "pending"))
      end)

    assert request["kind"] in ~w(command file-change file-read permission)
    Map.put(context, :request, request)
  end

  step "the user stops the turn", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    context
  end

  # A model provider of an ACP Registry agent (`context.model_provider`), or else a
  # node plugin.
  step "the user disables {string}", %{args: [id]} = context do
    if context[:model_provider] == id do
      {result, ctx} =
        World.call!(context, "server.disableAcpRegistryProvider", %{
          "instanceId" => context.auth_instance,
          "projectId" => World.project(context).id,
          "providerId" => id
        })

      Map.put(ctx, :reply, {:ok, result})
    else
      {result, ctx} = World.call!(context, "plugins.disable", %{"id" => id})
      Map.put(ctx, :reply, {:ok, result})
    end
  end

  # The provider list the client "default" watches (`context.config_subs`) comes to offer
  # the model `slug` for the instance `context.model_instance`.
  step "{string} is offered in the model picker", %{args: [slug]} = context do
    sub = context.config_subs["default"]
    instance = context.model_instance

    {_, client} =
      Node.await(
        World.client(context),
        fn frame ->
          frame["t"] == "config.providers" and frame["id"] == sub and
            Enum.any?(frame["providers"], fn entry ->
              entry["instanceId"] == instance and
                Enum.any?(entry["models"] || [], &(&1["slug"] == slug))
            end)
        end,
        5_000
      )

    World.put_client(context, client)
  end

  # The union's W11 section defines the same step; keep one.
  step "a new thread needs a title", context do
    Map.put(
      context,
      :title_result,
      T3.TextGeneration.thread_title(World.project(context).root, "Fix the login form")
    )
  end

  # The provider list a client receives when it subscribes to the node's config.
  step "the user opens the provider list", context do
    sub = 6000 + System.unique_integer([:positive])

    client =
      Node.sub(World.client(context), sub, %{"type" => "config", "node" => Atom.to_string(node())})

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == sub), 5_000)
    assert is_list(frame["config"]["providers"])
    context |> World.put_client(client) |> Map.put(:providers, frame["config"]["providers"])
  end

  # Starts the thread a Given described (`context.pending_launch`: `instance`, and
  # `fields` such as "runtimeMode") with a message, and waits for its turn to end.
  step "the user sends a message", context do
    assert %{instance: instance, fields: fields} = context[:pending_launch],
           "no thread was described to send a message to"

    ctx =
      context
      |> Map.delete(:pending_launch)
      |> T3.Test.AcpFixtures.launch("Work", instance, "hello", mode: fields["runtimeMode"])

    T3.Test.AcpFixtures.await_runs(ctx.threads["Work"], 1)
    Map.put(ctx, :thread, "Work")
  end
end
