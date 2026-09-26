defmodule T3.Steps.Providers.AcpRegistry do
  @moduledoc """
  Steps for `features/providers/acp-registry.feature`: agents from the ACP Registry.

  The registry is served on loopback by `T3.Test.AcpFixtures` and lists "acme", whose
  archive holds `bin/acme`, which runs the fake agent "acme". Scenarios that are not
  about installing run the instance "acme" straight as that fake (`run_as/3`). Sign-in
  RPCs go through the client "ops", so the frames the other clients await are never
  skipped while an RPC reply is awaited.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Test.AcpFixtures, as: Acp
  alias T3.Test.Node
  alias T3.Test.Node.World

  @browser %{"id" => "acme-login", "name" => "Log in with Acme"}
  @terminal %{
    "id" => "acme-terminal",
    "name" => "Sign in in a terminal",
    "type" => "terminal",
    "args" => ["login"]
  }
  @api_key %{
    "id" => "acme-key",
    "name" => "API key",
    "type" => "env_var",
    "vars" => [%{"name" => "ACME_API_KEY"}]
  }

  # --- helpers -------------------------------------------------------------------------

  # The registry instance "acme", run as the fake agent "acme" with `control`.
  defp acme(ctx, control \\ %{}) do
    # Connected first: a client connecting reads every message the test process gets.
    ctx = ctx |> ops() |> Acp.publish() |> Acp.run_as("acme", "acme")
    Acp.control(ctx, "acme", control)
    Acp.add_registry_instance("acme", "acme")
    Map.put(ctx, :auth_instance, "acme")
  end

  defp signed_out_acme(ctx, methods) do
    ctx = acme(ctx, %{"auth" => "file", "methods" => methods})
    assert Acp.check("acme")["auth"]["status"] == "unauthenticated"
    ctx
  end

  defp tools(ctx, id \\ "acme"), do: Path.join([ctx.node.home, "tools", id])

  defp installed(ctx),
    do: Path.join([tools(ctx), "2.0.0", T3.Acp.Catalog.platform(), "bin", "acme"])

  defp ops(ctx) do
    if Map.has_key?(ctx.clients, "ops"),
      do: ctx,
      else: World.put_client(ctx, "ops", Node.connect(ctx.node))
  end

  defp prepare(ctx, id \\ "acme") do
    ctx = ops(ctx)
    {reply, ctx} = World.call(ctx, "server.prepareAcpRegistryAgent", %{"agentId" => id}, "ops")
    Map.put(ctx, :reply, reply)
  end

  defp operation_error(reply) do
    assert {:error, message, %{"_tag" => "AcpRegistryOperationError"} = detail} = reply
    Map.put_new(detail, "message", message)
  end

  # Starts a sign-in with `method` from "ops", watched on the client `watcher`.
  defp start_sign_in(ctx, method, watcher \\ "default") do
    ctx = ops(ctx)

    ctx =
      if ctx[:auth_subs][{watcher, "acme"}],
        do: ctx,
        else: ctx |> Acp.watch_auth("acme", watcher) |> elem(1)

    {state, ctx} =
      World.call!(
        ctx,
        "provider.auth.start",
        %{"instanceId" => "acme", "methodId" => method},
        "ops"
      )

    Map.put(ctx, :flow, state["flowId"])
  end

  defp await_phase(ctx, phase, fun \\ fn _ -> true end, watcher \\ "default") do
    flow = ctx.flow

    Acp.await_auth(
      ctx,
      "acme",
      &(&1["flowId"] == flow and &1["phase"] == phase and fun.(&1)),
      watcher
    )
  end

  defp respond(ctx, interaction, response) do
    {_, ctx} =
      World.call!(
        ctx,
        "provider.auth.respond",
        %{
          "instanceId" => "acme",
          "flowId" => ctx.flow,
          "interactionId" => interaction["id"],
          "response" => response
        },
        "ops"
      )

    ctx
  end

  defp terminal_shows?(text),
    do:
      &(get_in(&1, ["interaction", "type"]) == "terminal" and &1["interaction"]["output"] =~ text)

  # Subscribes client `name` to its config, so later provider changes arrive as frames.
  defp watch_providers(ctx, name \\ "default") do
    sub = 3000 + System.unique_integer([:positive])

    client =
      Node.sub(World.client(ctx, name), sub, %{
        "type" => "config",
        "node" => Atom.to_string(node())
      })

    {_, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == sub), 5_000)

    ctx
    |> World.put_client(name, client)
    |> put_in([Access.key(:config_subs, %{}), name], sub)
  end

  # Waits on client `name` for a provider list whose "acme" entry matches `fun`.
  defp await_acme(ctx, fun, name \\ "default") do
    sub = ctx.config_subs[name]

    {frame, client} =
      Node.await(
        World.client(ctx, name),
        fn frame ->
          frame["t"] == "config.providers" and frame["id"] == sub and
            case Enum.find(frame["providers"], &(&1["instanceId"] == "acme")) do
              nil -> false
              entry -> fun.(entry)
            end
        end,
        5_000
      )

    {Enum.find(frame["providers"], &(&1["instanceId"] == "acme")),
     World.put_client(ctx, name, client)}
  end

  defp thread(ctx), do: ctx.threads[ctx.thread]

  defp run_on_acme(ctx, text, opts \\ []) do
    ctx = Acp.launch(ctx, "Acme", "acme", text, opts)
    Map.put(ctx, :thread, "Acme")
  end

  defp url_action(id), do: &(get_in(&1, ["auth", "action", "elicitationId"]) == id)

  defp agent(ctx, id, name, dist) do
    Map.merge(Acp.acme_agent(ctx, id: id, name: name), %{
      "description" => "#{name}, an ACP agent",
      "distribution" => dist
    })
  end

  defp npx(package), do: %{"npx" => %{"package" => package}}

  defp elsewhere,
    do: %{
      "binary" => %{
        "plan9-mips" => %{"archive" => "https://example.com/a.tar.gz", "cmd" => "./a"}
      }
    }

  defp ids(reply) do
    assert {:ok, %{"agents" => agents}} = reply
    Enum.map(agents, & &1["id"])
  end

  # --- the registry --------------------------------------------------------------------

  step "matching agents are listed, best match first, at most 20", context do
    assert {:ok, %{"agents" => agents}} = context.reply
    assert length(agents) == 20
    query = String.downcase(context.query)

    rank = fn agent ->
      name = String.downcase(agent["name"])
      id = agent["id"]

      cond do
        id == query or name == query -> 0
        String.starts_with?(id, query) or String.starts_with?(name, query) -> 1
        true -> 2
      end
    end

    assert Enum.all?(
             agents,
             &(rank.(&1) < 2 or String.contains?(String.downcase(&1["name"]), query))
           )

    assert agents == Enum.sort_by(agents, &{rank.(&1), String.downcase(&1["name"])})
    context
  end

  step "agents without a build for this platform are left out", context do
    refute Enum.any?(ids(context.reply), &String.contains?(&1, "elsewhere"))
    context
  end

  step "the user opens the registry search without a query", context do
    ctx = context |> Acp.serve_registry() |> ops()

    ctx =
      Acp.publish(ctx, [
        Acp.acme_agent(ctx),
        agent(ctx, "npx-agent", "Npx Agent", npx("@acme/npx-agent")),
        agent(ctx, "elsewhere", "Elsewhere", elsewhere())
      ])

    {reply, ctx} = World.call(ctx, "server.searchAcpRegistry", %{"query" => ""}, "ops")
    Map.put(ctx, :reply, reply)
  end

  step "every compatible agent is listed", context do
    assert ids(context.reply) == ["acme", "npx-agent"]
    context
  end

  step "the user adds the registry agent {string}", %{args: [id]} = context do
    ctx = context |> Acp.publish() |> prepare(id)
    assert {:ok, %{"agentId" => ^id, "version" => "2.0.0", "prepared" => true}} = ctx.reply

    # The client adds the instance once the agent is prepared.
    Acp.write_settings(ctx, fn settings ->
      put_in(settings, [Access.key("providerInstances", %{}), id], %{
        "driver" => "acpRegistry",
        "enabled" => true,
        "config" => %{"agentId" => id}
      })
    end)
  end

  step "{string} is installed under the node's tools folder at the registry's version",
       %{args: [id]} = context do
    assert id == "acme"
    assert File.regular?(installed(context))
    assert File.ls!(tools(context)) == ["2.0.0"]
    context
  end

  step "an instance of {string} is created and enabled", %{args: [id]} = context do
    assert %{"driver" => "acpRegistry", "config" => %{"agentId" => ^id}} =
             T3.Settings.settings()["providerInstances"][id]

    assert %{"enabled" => true, "driver" => "acpRegistry"} = Acp.provider(id)
    context
  end

  step "an instance of {string} exists", %{args: [id]} = context do
    ctx = acme(context)
    assert id == "acme"
    ctx
  end

  step "the user searches the registry for {string}", %{args: [query]} = context do
    ctx = ops(context)
    {reply, ctx} = World.call(ctx, "server.searchAcpRegistry", %{"query" => query}, "ops")
    Map.put(ctx, :reply, reply)
  end

  # The client marks a result as added when one of its instances runs that agent.
  step "{string} is shown as already added", %{args: [id]} = context do
    assert id in ids(context.reply)
    {%{"settings" => settings}, ctx} = World.call!(context, "t3.readSettings", %{})

    assert Enum.any?(
             settings["providerInstances"],
             fn {_, instance} ->
               instance["driver"] == "acpRegistry" and instance["config"]["agentId"] == id
             end
           )

    ctx
  end

  step "the registry agent {string} runs through npx", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", npx("@acme/agent@2.0.0"))])
  end

  step "npm is not installed on the node", context do
    # `AcpFixtures.ready/1` puts PATH back after the scenario.
    empty = Path.join(context.node.home, "empty-bin")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)
    assert System.find_executable("npm") == nil
    context
  end

  step "the user is told to install npm to use this agent", context do
    assert %{"reason" => "runner_unavailable", "message" => "Install npm to use this agent."} =
             operation_error(context.reply)

    refute File.exists?(tools(context))
    context
  end

  step "the registry lists a checksum for {string}", %{args: [id]} = context do
    ctx = Acp.publish(context)
    assert {:ok, agents} = T3.Acp.Catalog.index(true)
    agent = Enum.find(agents, &(&1["id"] == id))

    assert agent["distribution"]["binary"][T3.Acp.Catalog.platform()]["sha256"] =~
             ~r/^[0-9a-f]{64}$/

    ctx
  end

  step "the downloaded archive does not match it", context do
    # The archive is replaced after the registry listed its checksum.
    File.write!(Path.join(context.acp.served, "acme.tar.gz"), "tampered")
    context
  end

  step "adding {string} fails with a checksum error", %{args: [id]} = context do
    ctx = prepare(context, id)
    assert %{"reason" => "checksum_mismatch"} = operation_error(ctx.reply)
    ctx
  end

  step "nothing is installed", context do
    assert Path.wildcard(Path.join(tools(context), "**/*"), match_dot: true)
           |> Enum.filter(&File.regular?/1) == []

    context
  end

  step "the archive downloaded for {string} cannot be unpacked", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [Acp.acme_agent(ctx, id: id, archive: "not a tarball")])
  end

  step "adding {string} fails saying the archive is invalid", %{args: [id]} = context do
    ctx = prepare(context, id)
    assert %{"reason" => "archive_invalid"} = operation_error(ctx.reply)
    refute File.exists?(installed(ctx))
    ctx
  end

  step "the node has never fetched the registry", context do
    ctx = Acp.ready(context)
    refute File.exists?(Path.join([ctx.node.home, "cache", "acp-registry", "registry.json"]))
    assert :persistent_term.get({T3.Acp.Catalog, :index}, nil) == nil
    ctx
  end

  step "the registry cannot be reached", context do
    # `AcpFixtures.ready/1` points the node at a closed loopback port.
    assert Application.get_env(:t3, :acp_registry_url) =~ "127.0.0.1:1/"
    context
  end

  step "the user is told the registry is unavailable", context do
    assert %{
             "reason" => "registry_unavailable",
             "message" => "The ACP Registry could not be loaded."
           } =
             operation_error(context.reply)

    context
  end

  step "the node fetched the registry an hour ago", context do
    ctx = Acp.publish(context)
    {:ok, [_]} = T3.Acp.Catalog.index(true)
    assert Acp.registry_requests(ctx) == ["registry.json"]
    cache = Path.join([ctx.node.home, "cache", "acp-registry", "registry.json"])
    File.touch!(cache, System.os_time(:second) - 3600)
    # A node that starts now has only the file.
    :persistent_term.erase({T3.Acp.Catalog, :index})
    ctx
  end

  step "the node needs registry data without a search", context do
    Map.put(context, :described, T3.Acp.Catalog.describe("acme"))
  end

  step "the cached copy is used", context do
    assert %{name: "Acme", version: "2.0.0"} = context.described
    assert Acp.registry_requests(context) == ["registry.json"]
    context
  end

  step "one instance of {string} exists", %{args: [id]} = context do
    ctx = context |> Acp.publish() |> prepare(id)
    assert {:ok, _} = ctx.reply
    Acp.add_registry_instance(id, id)
    assert File.regular?(installed(ctx))
    ctx
  end

  step "the user deletes that instance", context do
    ctx =
      Acp.write_settings(context, fn settings ->
        update_in(settings, ["providerInstances"], &Map.delete(&1, "acme"))
      end)

    # As the settings panel does once the last instance of an agent is gone.
    {reply, ctx} =
      World.call(ctx, "server.uninstallAcpRegistryManagedBinary", %{"agentId" => "acme"})

    Map.put(ctx, :reply, reply)
  end

  step "the downloaded files for {string} are removed", %{args: [id]} = context do
    assert {:ok, %{"agentId" => ^id, "removed" => true}} = context.reply
    refute File.exists?(tools(context, id))
    context
  end

  step "the instance of {string} has an executable override", %{args: [id]} = context do
    ctx = Acp.publish(context)
    local = Acp.wrapper(ctx, Path.join([ctx.node.home, "local", "acme-dev"]), id)

    Acp.add_registry_instance(id, id, %{
      "config" => %{"agentId" => id, "commandPath" => local}
    })

    Map.put(ctx, :local, local)
  end

  step "the user sends a message on that instance", context do
    ctx = run_on_acme(context, "hello")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the local executable runs with the registry's arguments and environment", context do
    root = World.project(context).root
    assert [launch | _] = Enum.filter(Acp.launches(context, "acme"), &(&1["cwd"] == root))
    assert launch["argv0"] == context.local
    assert launch["args"] == ["--acp"]
    assert launch["env"]["ACME_MODE"] == "registry"
    assert Acp.assistant_text(thread(context)) =~ "Hello from acme"
    # Nothing was downloaded for it.
    refute File.exists?(tools(context))
    context
  end

  # --- sign-in -------------------------------------------------------------------------

  step "the agent {string} refuses new sessions until the user signs in",
       %{args: [_]} = context do
    acme(context, %{"auth" => "file", "methods" => [@browser]})
  end

  step "the node checks {string}", %{args: [id]} = context do
    Map.put(context, :entry, Acp.check(id))
  end

  step "{string} is shown as signed out with {string}", %{args: [_, message]} = context do
    assert %{"auth" => %{"status" => "unauthenticated"}, "message" => ^message} = context.entry
    assert context.entry["setup"]["canAuthenticate"] == true
    context
  end

  step "{string} offers a terminal sign-in", %{args: [_]} = context do
    signed_out_acme(context, [@terminal])
  end

  # "acme" signs in in a terminal; a Cursor instance in the browser.
  step "the user signs in to {string}", %{args: [id]} = context do
    if id == "acme" do
      ctx = start_sign_in(context, "acme-terminal")
      {state, ctx} = await_phase(ctx, "waiting", terminal_shows?("Paste code: "))
      Map.put(ctx, :interaction, state["interaction"])
    else
      T3.Steps.Providers.Cursor.sign_in_to(context, id)
    end
  end

  step "the agent's login runs in a terminal on the node that the user can type into",
       context do
    assert %{"type" => "terminal", "id" => "terminal"} = context.interaction
    # The login is the agent's own command with the method's arguments.
    assert [%{"args" => ["login"]}] =
             Enum.filter(Acp.launches(context, "acme"), &("login" in &1["args"]))

    # What the user types reaches the login.
    respond(context, context.interaction, %{"type" => "terminal", "data" => "ok\n"})
  end

  step "{string} is shown as signed in once a fresh session succeeds", %{args: [id]} = context do
    {state, ctx} = await_phase(context, "succeeded")
    assert state["message"] == "Sign-in complete."
    assert File.exists?(Path.join(Acp.dir(ctx), "acme.auth"))
    assert [_ | _] = Acp.requests(ctx, "acme", "session/new")
    assert Acp.check(id)["auth"]["status"] == "authenticated"
    ctx
  end

  step "a terminal sign-in for {string} is running", %{args: [_]} = context do
    ctx = signed_out_acme(context, [@terminal])
    ctx = start_sign_in(ctx, "acme-terminal")
    {state, ctx} = await_phase(ctx, "waiting", terminal_shows?("Paste code: "))
    Map.put(ctx, :interaction, state["interaction"])
  end

  step "the user resizes the sign-in view", context do
    respond(context, context.interaction, %{
      "type" => "terminal",
      "size" => %{"cols" => 100, "rows" => 30}
    })
  end

  step "the sign-in terminal is resized to match", context do
    {_, ctx} = await_phase(context, "waiting", terminal_shows?("size 100x30"))
    ctx
  end

  step "{string} signs in with an API key", %{args: [_]} = context do
    ctx = acme(context, %{"auth" => "env:ACME_API_KEY", "methods" => [@api_key]})
    assert Acp.check("acme")["auth"]["status"] == "unauthenticated"
    watch_providers(ctx)
  end

  step "the user signs in and enters the key", context do
    # The client saves the key in the instance's environment, then signs in with it.
    ctx =
      Acp.write_settings(context, fn settings ->
        put_in(settings, ["providerInstances", "acme", "environment"], [
          %{"name" => "ACME_API_KEY", "value" => "sk-acme"}
        ])
      end)

    start_sign_in(ctx, "acme-key")
  end

  step "the key is passed to the agent and {string} is checked again", %{args: [_]} = context do
    {_, ctx} = await_phase(context, "succeeded")
    assert Acp.requests(ctx, "acme", "authenticate") == []
    assert %{"env" => %{"ACME_API_KEY" => "sk-acme"}} = List.last(Acp.launches(ctx, "acme"))
    {entry, ctx} = await_acme(ctx, &(&1["auth"]["status"] == "authenticated"))
    refute entry["message"]
    ctx
  end

  step "{string} offers a browser method and a terminal method", %{args: [_]} = context do
    signed_out_acme(context, [@browser, @terminal])
  end

  step "the user picks the terminal method", context do
    start_sign_in(context, "acme-terminal")
  end

  step "the terminal sign-in starts", context do
    {state, ctx} = await_phase(context, "waiting", terminal_shows?("Paste code: "))
    assert state["interaction"]["type"] == "terminal"

    assert [%{"args" => ["login"]}] =
             Enum.filter(Acp.launches(ctx, "acme"), &("login" in &1["args"]))

    # The browser method was not started.
    assert Acp.requests(ctx, "acme", "authenticate") == []
    ctx
  end

  step "{string} signs in through a browser page", %{args: [_]} = context do
    signed_out_acme(context, [@browser])
  end

  step "the user starts sign-in", context do
    start_sign_in(context, "acme-login")
  end

  step "the page link is shown to the user", context do
    {state, ctx} = await_phase(context, "waiting")

    assert %{"type" => "browser", "url" => "https://acme.test/login", "requiresConsent" => true} =
             state["interaction"]

    Map.put(ctx, :interaction, state["interaction"])
  end

  step "the agent is told to proceed only after the user opens or copies the link", context do
    answered = fn ->
      Enum.filter(
        Acp.log(context, "acme"),
        &(&1["event"] == "response" and &1["id"] == "auth-url")
      )
    end

    assert answered.() == []

    ctx = respond(context, context.interaction, %{"type" => "browser", "action" => "accept"})
    {_, ctx} = await_phase(ctx, "succeeded")
    assert [%{"result" => %{"action" => "accept"}}] = answered.()
    ctx
  end

  step "the user starts signing in to {string} on one client", %{args: [_]} = context do
    ctx = signed_out_acme(context, [@browser])
    {_, ctx} = Acp.watch_auth(ctx, "acme", "first")
    {_, ctx} = Acp.watch_auth(ctx, "acme", "second")

    {state, ctx} =
      World.call!(
        ctx,
        "provider.auth.start",
        %{"instanceId" => "acme", "methodId" => "acme-login"},
        "first"
      )

    ctx = Map.put(ctx, :flow, state["flowId"])
    {state, ctx} = await_phase(ctx, "waiting", fn _ -> true end, "first")
    Map.put(ctx, :sign_in, state)
  end

  step "a sign-in for {string} has been waiting for five minutes", %{args: [_]} = context do
    ctx = signed_out_acme(context, [@browser])
    started = System.system_time(:millisecond)
    ctx = start_sign_in(ctx, "acme-login")
    {state, ctx} = await_phase(ctx, "waiting")
    {:ok, expires, _} = DateTime.from_iso8601(state["expiresAt"])
    left = DateTime.to_unix(expires, :millisecond) - started
    assert left in 299_000..301_000, "the sign-in expires in #{left}ms"
    ctx
  end

  step "the time runs out", context do
    send(Acp.auth_server(context.auth_instance), {:expire, context.flow})
    context
  end

  step "the sign-in fails as timed out and can be retried", context do
    {state, ctx} = await_phase(context, "failed")
    assert state["message"] == "Sign-in expired. Start again."
    before = ctx.flow
    ctx = start_sign_in(ctx, "acme-login")
    assert ctx.flow != before
    {_, ctx} = await_phase(ctx, "waiting")
    ctx
  end

  step "a sign-in for {string} is in progress", %{args: [_]} = context do
    ctx = signed_out_acme(context, [@browser])
    ctx = start_sign_in(ctx, "acme-login")
    {_, ctx} = await_phase(ctx, "waiting")
    Map.merge(ctx, %{sign_in: %{"flowId" => ctx.flow}, auth_client: "ops"})
  end

  # After a cancelled sign-in of `id`, or while another instance signed in.
  step "{string} stays signed out", %{args: [id]} = context do
    ctx =
      if context[:auth_instance] == id do
        {state, ctx} = await_phase(context, "cancelled")
        assert state["message"] == "Sign-in cancelled."
        refute File.exists?(Path.join(Acp.dir(ctx), "acme.auth"))
        ctx
      else
        context
      end

    assert Acp.check(id)["auth"]["status"] == "unauthenticated"
    ctx
  end

  # --- URL sign-in mid-session -----------------------------------------------------------

  step "a thread is running on {string}", %{args: [_]} = context do
    ctx =
      context
      |> acme()
      |> World.put_client("second", Node.connect(context.node))
      |> watch_providers("default")
      |> watch_providers("second")
      |> run_on_acme("hello")

    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "{string} asks the user to open a sign-in URL", %{args: [_]} = context do
    Acp.follow_up(context, context.thread, "open url login-1")
  end

  step "every client is offered the URL", context do
    Enum.reduce(["default", "second"], context, fn name, ctx ->
      {entry, ctx} = await_acme(ctx, url_action("login-1"), name)

      assert %{"url" => "https://acme.test/login-1", "message" => "Sign in to Acme"} =
               entry["auth"]["action"]

      ctx
    end)
  end

  step "answering on one client clears it on the others", context do
    {reply, ctx} =
      World.call!(
        context,
        "server.acceptAcpRegistryUrlAuth",
        %{"instanceId" => "acme", "elicitationId" => "login-1"},
        "second"
      )

    assert reply == %{"accepted" => true}
    {entry, ctx} = await_acme(ctx, &(get_in(&1, ["auth", "action"]) == nil))
    refute entry["auth"]["action"]
    # The agent heard the answer.
    Acp.await_stream(thread(ctx), fn _ ->
      Enum.any?(
        Acp.log(ctx, "acme"),
        &(&1["id"] == "url-login-1" and &1["result"] == %{"action" => "accept"})
      )
    end)

    ctx
  end

  step "{string} is waiting for the user to open a sign-in URL", %{args: [_]} = context do
    ctx =
      context
      |> acme()
      |> watch_providers()
      |> run_on_acme("open url one")

    {_, ctx} = await_acme(ctx, url_action("one"))
    ctx
  end

  step "{string} asks for a different sign-in URL", %{args: [_]} = context do
    Acp.await_runs(thread(context), 1)
    Acp.follow_up(context, context.thread, "open url two")
  end

  step "only the newer request is offered", context do
    {entry, ctx} = await_acme(context, url_action("two"))
    assert entry["auth"]["action"]["url"] == "https://acme.test/two"

    {reply, ctx} =
      World.call!(ctx, "server.acceptAcpRegistryUrlAuth", %{
        "instanceId" => "acme",
        "elicitationId" => "one"
      })

    assert reply == %{"accepted" => false}

    assert Enum.any?(
             Acp.log(ctx, "acme"),
             &(&1["id"] == "url-one" and &1["result"] == %{"action" => "decline"})
           )

    ctx
  end

  # --- sign-out ------------------------------------------------------------------------

  step "{string} supports signing out and the user is signed in", %{args: [id]} = context do
    ctx = acme(context, %{"auth" => "file", "methods" => [@browser]})
    File.write!(Path.join(Acp.dir(ctx), "acme.auth"), "signed in")
    entry = Acp.check(id)
    assert %{"status" => "authenticated", "canLogout" => true} = entry["auth"]
    watch_providers(ctx)
  end

  step "the user signs out of {string}", %{args: [id]} = context do
    {reply, ctx} =
      World.call!(ops(context), "server.logoutAcpRegistry", %{"instanceId" => id}, "ops")

    assert reply == %{"loggedOut" => true}
    ctx
  end

  step "{string} is checked again and shown as signed out", %{args: [_]} = context do
    assert [_] = Acp.requests(context, "acme", "logout")
    {entry, ctx} = await_acme(context, &(&1["auth"]["status"] == "unauthenticated"))
    assert entry["message"] == "Sign in to use this agent."
    ctx
  end

  # --- threads -------------------------------------------------------------------------

  step "the thread runs {string} with full access", %{args: [_]} = context do
    context |> acme() |> Map.put(:mode, "full-access")
  end

  step "the thread runs {string} with approval required", %{args: [_]} = context do
    context |> acme() |> Map.put(:mode, "approval-required")
  end

  step "{string} asks permission to edit a file", %{args: [_]} = context do
    run_on_acme(context, "edit file", mode: context.mode)
  end

  step "{string} asks permission to run a command", %{args: [_]} = context do
    run_on_acme(context, "approve", mode: context.mode)
  end

  step "the request is approved without asking the user", context do
    [run] = Acp.await_runs(thread(context), 1)
    assert run["status"] == "completed"
    assert Acp.assistant_text(thread(context)) =~ "allowed"

    refute Enum.any?(
             T3.StreamState.list(Acp.stream(thread(context)), "runtime-request"),
             &(&1["status"] == "pending")
           )

    context
  end

  step "a turn is running on {string}", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("wait")

    Acp.await_stream(thread(ctx), fn state ->
      Enum.any?(T3.StreamState.list(state, "run"), &(&1["status"] == "running"))
    end)

    Acp.await_stream(thread(ctx), fn _ -> Acp.requests(ctx, "acme", "session/prompt") != [] end)
    ctx
  end

  step "{string} is told to cancel the turn", %{args: [_]} = context do
    [run] = Acp.await_runs(thread(context), 1)
    assert run["status"] in ["interrupted", "cancelled"]
    assert [%{"params" => %{"sessionId" => _}}] = Acp.requests(context, "acme", "session/cancel")
    context
  end

  step "an {string} thread with three turns", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("write one.txt", worktree: true)
    Acp.await_runs(thread(ctx), 1)
    Acp.follow_up(ctx, ctx.thread, "write two.txt")
    Acp.await_runs(thread(ctx), 2)
    Acp.follow_up(ctx, ctx.thread, "write three.txt")
    Acp.await_runs(thread(ctx), 3)
    scope = T3.Checkpoint.scope_id(thread(ctx))
    last = T3.Checkpoint.checkpoint_id(scope, 3)

    Acp.await_stream(thread(ctx), fn state ->
      T3.StreamState.get(state, "checkpoint")[last]["status"] == "ready"
    end)

    ctx
  end

  step "the user rolls back to the first turn", context do
    scope = T3.Checkpoint.scope_id(thread(context))

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "checkpoint.rollback",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(context),
        "scopeId" => scope,
        "checkpointId" => T3.Checkpoint.checkpoint_id(scope, 1)
      })

    Map.put(context, :before_rollback, length(Acp.log(context, "acme")))
  end

  step "the files are restored to the first turn", context do
    root = World.project(context).root
    assert File.exists?(Path.join(root, "one.txt"))
    refute File.exists?(Path.join(root, "two.txt"))
    refute File.exists?(Path.join(root, "three.txt"))
    context
  end

  step "the next message starts a new agent session without the later conversation",
       context do
    old = Enum.map(Acp.requests(context, "acme", "session/prompt"), & &1["params"]["sessionId"])
    Acp.follow_up(context, context.thread, "what now")

    Acp.await_stream(thread(context), fn state ->
      state |> T3.StreamState.list("run") |> Enum.count(&(&1["status"] == "completed")) == 2
    end)

    since = Enum.drop(Acp.log(context, "acme"), context.before_rollback)
    methods = for %{"event" => "request", "method" => m} <- since, do: m
    assert "session/new" in methods
    refute "session/resume" in methods
    refute "session/load" in methods
    [prompt] = Enum.filter(since, &(&1["method"] == "session/prompt"))
    refute prompt["params"]["sessionId"] in old
    # The new session hears only what is left of the conversation.
    [%{"text" => text}] = prompt["params"]["prompt"]
    assert text =~ "write one.txt"
    refute text =~ "two.txt"
    refute text =~ "three.txt"
    context
  end

  step "{string} offers two models", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("hello", model: "acme/fast")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the user switches the thread to the other model", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.model-selection.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(context),
        "modelSelection" => %{"instanceId" => "acme", "model" => "acme/smart"}
      })

    context
  end

  step "the agent's session uses the new model for the next turn", context do
    Acp.follow_up(context, context.thread, "which model")
    Acp.await_runs(thread(context), 2)
    assert Acp.assistant_text(thread(context)) =~ "model: acme/smart"

    assert %{"params" => %{"configId" => "model", "value" => "acme/smart"}} =
             List.last(Acp.requests(context, "acme", "session/set_config_option"))

    context
  end

  step "{string} reports no models", %{args: [_]} = context do
    ctx = acme(context, %{"models" => []})
    assert Acp.check("acme")["models"] == []
    ctx |> watch_providers() |> Map.put(:model_instance, "acme")
  end

  step "the user adds the custom model {string}", %{args: [slug]} = context do
    Acp.write_settings(
      context,
      &update_in(&1, ["providerInstances", "acme"], fn instance ->
        config = instance["config"] || %{}
        Map.put(instance, "config", Map.put(config, "customModels", [slug]))
      end),
      "ops"
    )
  end

  step "{string} reports a new model while a session runs", %{args: [_]} = context do
    ctx = acme(context)
    # Probed first, so the picker already holds the agent's starting models.
    refute Enum.any?(Acp.check("acme")["models"], &(&1["slug"] == "acme/huge"))
    ctx = ctx |> watch_providers() |> run_on_acme("new model")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the model picker offers it without a provider refresh", context do
    {entry, ctx} =
      await_acme(context, fn entry -> Enum.any?(entry["models"], &(&1["slug"] == "acme/huge")) end)

    assert %{"isCustom" => false} = Enum.find(entry["models"], &(&1["slug"] == "acme/huge"))
    # Only the probe and the thread's session ran the agent: nothing probed it again.
    assert length(Acp.launches(ctx, "acme")) == 2
    ctx
  end

  step "{string} asks the client to read a file or run a terminal", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("read file")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the request is refused rather than left waiting", context do
    text = Acp.assistant_text(thread(context))
    assert text =~ "fs: -32601"
    assert text =~ "terminal: -32601"
    context
  end

  step "the user picks a provider for thread titles", context do
    ctx = acme(context)
    # Loaded as the node's status check does, so the entry is complete.
    assert Acp.check("acme")["models"] != []
    sub = 4000 + System.unique_integer([:positive])

    client =
      Node.sub(World.client(ctx), sub, %{"type" => "config", "node" => Atom.to_string(node())})

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == sub), 5_000)
    ctx |> World.put_client(client) |> Map.put(:providers, frame["config"]["providers"])
  end

  step "registry instances are not offered", context do
    assert %{"driver" => "acpRegistry", "supportsTextGeneration" => false} =
             Enum.find(context.providers, &(&1["instanceId"] == "acme"))

    context
  end

  # --- model providers -------------------------------------------------------------------

  defp model_providers(ctx) do
    {reply, ctx} =
      World.call!(
        ops(ctx),
        "server.listAcpRegistryProviders",
        %{
          "instanceId" => "acme",
          "projectId" => World.project(ctx).id
        },
        "ops"
      )

    {reply["providers"], ctx}
  end

  step "{string} lists its model providers", %{args: [_]} = context do
    {providers, ctx} = context |> acme() |> model_providers()
    assert ["openai", "openrouter"] = Enum.map(providers, & &1["providerId"])
    ctx
  end

  step "the user sets the base URL and headers for one of them", context do
    {reply, ctx} =
      World.call(
        ops(context),
        "server.setAcpRegistryProvider",
        %{
          "instanceId" => "acme",
          "projectId" => World.project(context).id,
          "providerId" => "openai",
          "apiType" => "openai",
          "baseUrl" => "https://proxy.acme.test/v1",
          "headers" => %{"Authorization" => "Bearer sk-secret-header"}
        },
        "ops"
      )

    assert reply == {:ok, %{"configured" => true}}
    ctx
  end

  step "{string} uses that routing", %{args: [_]} = context do
    assert %{"params" => %{"baseUrl" => "https://proxy.acme.test/v1", "headers" => headers}} =
             List.last(Acp.requests(context, "acme", "providers/set"))

    assert headers == %{"Authorization" => "Bearer sk-secret-header"}
    {providers, ctx} = model_providers(context)

    assert %{"current" => %{"baseUrl" => "https://proxy.acme.test/v1"}} =
             Enum.find(providers, &(&1["providerId"] == "openai"))

    Map.put(ctx, :listed, providers)
  end

  step "the headers are never shown back to the user", context do
    refute JSON.encode!(context.listed) =~ "sk-secret-header"
    assert Enum.all?(context.listed, &(not Map.has_key?(&1["current"] || %{}, "headers")))
    context
  end

  step "{string} lists an optional model provider {string}", %{args: [_, id]} = context do
    {providers, ctx} = context |> acme() |> model_providers()

    assert %{"required" => false, "current" => %{}} =
             Enum.find(providers, &(&1["providerId"] == id))

    Map.put(ctx, :model_provider, id)
  end

  step "{string} is shown as disabled", %{args: [id]} = context do
    {providers, ctx} = model_providers(context)
    assert %{"current" => nil} = Enum.find(providers, &(&1["providerId"] == id))
    ctx
  end

  step "the user saves model provider headers that are not a JSON object of strings", context do
    ctx = acme(context)

    {reply, ctx} =
      World.call(
        ops(ctx),
        "server.setAcpRegistryProvider",
        %{
          "instanceId" => "acme",
          "projectId" => World.project(ctx).id,
          "providerId" => "openai",
          "apiType" => "openai",
          "baseUrl" => "https://proxy.acme.test/v1",
          "headers" => %{"X-Retries" => 3}
        },
        "ops"
      )

    Map.put(ctx, :reply, reply)
  end

  step "the save is refused with a message about the header format", context do
    assert %{"message" => "Headers must be a JSON object with string values."} =
             operation_error(context.reply)

    assert Acp.requests(context, "acme", "providers/set") == []
    context
  end

  # --- what the agent reports during a turn --------------------------------------------

  step "{string} reports a plan and its context usage during a turn", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("plan")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the task list and the context meter follow the agent's reports", context do
    state = Acp.stream(thread(context))
    assert [plan] = T3.StreamState.list(state, "plan")

    assert [
             %{"text" => "Read the code", "status" => "completed"},
             %{"text" => "Fix the bug", "status" => "running"}
           ] = plan["steps"]

    assert [%{"contextUsage" => %{"usedTokens" => 1200, "maxTokens" => 200_000}}] =
             T3.StreamState.list(state, "provider-thread")

    context
  end

  step "{string} returns an image resource in its answer", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("image")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the answer shows a placeholder for the image instead of dropping it", context do
    text = Acp.assistant_text(thread(context))
    assert text == "[ACP image (image/png)]"
    refute text =~ "iVBORw0KGgo"
    context
  end
end
