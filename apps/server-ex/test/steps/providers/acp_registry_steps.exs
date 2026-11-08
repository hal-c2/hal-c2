defmodule HalC2.Steps.Providers.AcpRegistry do
  @moduledoc """
  Steps for `features/providers/acp-registry.feature`: agents from the ACP Registry.

  The registry is served on loopback by `HalC2.Test.AcpFixtures` and lists "acme", whose
  archive holds `bin/acme`, which runs the fake agent "acme". Scenarios that are not
  about installing run the instance "acme" straight as that fake (`run_as/3`). Sign-in
  RPCs go through the client "ops", so the frames the other clients await are never
  skipped while an RPC reply is awaited.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.AcpFixtures, as: Acp
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

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

  defp tools(ctx, id \\ "acme"), do: Path.join([ctx.mc.home, "tools", id])

  defp installed(ctx),
    do: Path.join([tools(ctx), "2.0.0", HalC2.Acp.Catalog.platform(), "bin", "acme"])

  defp ops(ctx) do
    if Map.has_key?(ctx.clients, "ops"),
      do: ctx,
      else: World.put_client(ctx, "ops", Mc.connect(ctx.mc))
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
      Mc.sub(World.client(ctx, name), sub, %{
        "type" => "config",
        "mc" => Atom.to_string(node())
      })

    {_, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == sub))

    ctx
    |> World.put_client(name, client)
    |> put_in([Access.key(:config_subs, %{}), name], sub)
  end

  # Waits on client `name` for a provider list whose "acme" entry matches `fun`.
  defp await_acme(ctx, fun, name \\ "default") do
    sub = ctx.config_subs[name]

    {frame, client} =
      Mc.await(
        World.client(ctx, name),
        fn frame ->
          frame["t"] == "config.providers" and frame["id"] == sub and
            case Enum.find(frame["providers"], &(&1["instanceId"] == "acme")) do
              nil -> false
              entry -> fun.(entry)
            end
        end
      )

    {Enum.find(frame["providers"], &(&1["instanceId"] == "acme")),
     World.put_client(ctx, name, client)}
  end

  defp thread(ctx), do: ctx.threads[ctx.thread]

  defp run_on_acme(ctx, text, opts \\ []) do
    ctx = Acp.launch(ctx, "Acme", "acme", text, opts)
    Map.put(ctx, :thread, "Acme")
  end

  defp interaction_mode(ctx, mode) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.interaction-mode.set",
        "commandId" => "cmd-mode-#{System.unique_integer([:positive])}",
        "threadId" => thread(ctx),
        "interactionMode" => mode
      })

    ctx
  end

  # The thread's prompts and the modes set between them, in order.
  defp mode_calls(ctx) do
    Enum.flat_map(Acp.log(ctx, "acme"), fn
      %{"event" => "request", "method" => "session/prompt", "params" => %{"prompt" => prompt}} ->
        # Title generation prompts the agent too, on a session of its own.
        if Enum.any?(prompt, &((&1["text"] || "") =~ "Return a JSON object")),
          do: [],
          else: [:prompt]

      %{
        "event" => "request",
        "method" => "session/set_config_option",
        "params" => %{"configId" => "mode", "value" => value}
      } ->
        [{"mode", value}]

      _ ->
        []
    end)
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
        agent(ctx, "npx-agent", "Npx Agent", npx("@acme/npx-agent@1.0.0")),
        agent(ctx, "elsewhere", "Elsewhere", elsewhere())
      ])

    {reply, ctx} =
      Acp.with_runners(ctx, fn ->
        World.call(ctx, "server.searchAcpRegistry", %{"query" => ""}, "ops")
      end)

    Map.put(ctx, :reply, reply)
  end

  step "every compatible agent is listed", context do
    assert ids(context.reply) == ["acme", "npx-agent"]
    context
  end

  step "the user installs the registry agent {string}", %{args: [id]} = context do
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

  step "{string} is installed under the MC's tools folder at the registry's version",
       %{args: [id]} = context do
    assert id == "acme"
    assert File.regular?(installed(context))
    assert File.ls!(tools(context)) == ["2.0.0"]
    context
  end

  step "an instance of {string} is created and enabled", %{args: [id]} = context do
    assert %{"driver" => "acpRegistry", "config" => %{"agentId" => ^id}} =
             HalC2.Settings.settings()["providerInstances"][id]

    assert %{"enabled" => true, "driver" => "acpRegistry"} = Acp.provider(id)
    context
  end

  step "an instance of {string} exists", %{args: [id]} = context do
    ctx = acme(context)
    assert id == "acme"
    # Adding an instance in a client prepares its agent first.
    ctx = prepare(ctx, id)
    assert {:ok, %{"prepared" => true}} = ctx.reply
    ctx
  end

  step "the user searches the registry for {string}", %{args: [query]} = context do
    ctx = ops(context)

    {reply, ctx} =
      Acp.with_runners(ctx, fn ->
        World.call(ctx, "server.searchAcpRegistry", %{"query" => query}, "ops")
      end)

    Map.put(ctx, :reply, reply)
  end

  step "the registry lists Kimi CLI", context do
    ctx = context |> Acp.serve_registry()

    Acp.publish(ctx, [
      Map.merge(Acp.acme_agent(ctx, id: "kimi"), %{
        "name" => "Kimi CLI",
        "version" => "1.52.0",
        "repository" => "https://github.com/MoonshotAI/kimi-cli"
      })
    ])
  end

  step "the registry lists Kimi Code {word}", %{args: [version]} = context do
    ctx = context |> Acp.serve_registry()

    Acp.publish(ctx, [
      Map.merge(Acp.acme_agent(ctx, id: "kimi"), %{
        "name" => "Kimi Code",
        "version" => version,
        "repository" => "https://github.com/MoonshotAI/kimi-code"
      })
    ])
  end

  step "Kimi is offered as the registry's Kimi Code {word}", %{args: [version]} = context do
    assert {:ok, %{"agents" => [%{"id" => "kimi", "version" => ^version}]}} = context.reply
    context
  end

  step "Kimi is offered as Kimi Code, checked against its checksum", context do
    assert {:ok, %{"agents" => [kimi]}} = context.reply

    assert %{
             "id" => "kimi",
             "name" => "Kimi Code",
             "version" => "2.3.1",
             "repository" => "https://github.com/MoonshotAI/kimi-code",
             "integrity" => "sha256"
           } = kimi

    context
  end

  # The client marks a result as added when one of its instances runs that agent.
  step "{string} is shown as already added", %{args: [id]} = context do
    assert id in ids(context.reply)
    {%{"settings" => settings}, ctx} = World.call!(context, "hal-c2.readSettings", %{})

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

  step "npm is not installed on the MC", context do
    # `AcpFixtures.ready/1` puts PATH back after the scenario.
    empty = Path.join(context.mc.home, "empty-bin")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)
    assert System.find_executable("npm") == nil
    Map.put(context, :runners_removed, true)
  end

  step "the user is told to install npm to use this agent", context do
    assert %{"reason" => "runner_unavailable", "message" => "Install npm to use this agent."} =
             operation_error(context.reply)

    refute File.exists?(tools(context))
    context
  end

  step "the registry lists a checksum for {string}", %{args: [id]} = context do
    ctx = Acp.publish(context)
    assert {:ok, agents} = HalC2.Acp.Catalog.index(true)
    agent = Enum.find(agents, &(&1["id"] == id))

    assert agent["distribution"]["binary"][HalC2.Acp.Catalog.platform()]["sha256"] =~
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

  step "the MC has never fetched the registry", context do
    ctx = Acp.ready(context)
    refute File.exists?(Path.join([HalC2.Paths.cache_dir(), "acp-registry", "registry.json"]))
    assert :persistent_term.get({HalC2.Acp.Catalog, :index}, nil) == nil
    ctx
  end

  step "the registry cannot be reached", context do
    # A closed loopback port: nothing answers there.
    Application.put_env(:hal_c2, :acp_registry_url, "http://127.0.0.1:1/registry.json")
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

  step "the MC fetched the registry an hour ago", context do
    ctx = Acp.publish(context)
    {:ok, [_]} = HalC2.Acp.Catalog.index(true)
    assert Acp.registry_requests(ctx) == ["registry.json"]
    cache = Path.join([HalC2.Paths.cache_dir(), "acp-registry", "registry.json"])
    File.touch!(cache, System.os_time(:second) - 3600)
    # An MC that starts now has only the file.
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    ctx
  end

  step "the MC needs registry data without a search", context do
    Map.put(context, :described, HalC2.Acp.Catalog.describe("acme"))
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
    local = Acp.wrapper(ctx, Path.join([ctx.mc.home, "local", "acme-dev"]), id)

    Acp.add_registry_instance(id, id, %{
      "config" => %{"agentId" => id, "commandPath" => local}
    })

    Map.put(ctx, :local, local)
  end

  step "the user sends a message on that instance", context do
    ctx = run_on_acme(context, "hello")
    [run] = Acp.await_runs(thread(ctx), 1)

    # A failed turn's refusal is left where "it fails with ..." reads it.
    if run["status"] == "failed" do
      session = HalC2.StreamState.list(Acp.stream(thread(ctx)), "provider-session")
      message = session |> Enum.map(& &1["lastError"]) |> Enum.reject(&is_nil/1) |> List.last()
      Map.put(ctx, :reply, {:error, message || "turn failed", %{}})
    else
      ctx
    end
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

  step "the MC checks {string}", %{args: [id]} = context do
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
      HalC2.Steps.Providers.Cursor.sign_in_to(context, id)
    end
  end

  step "the agent's login runs in a terminal on the MC that the user can type into",
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

    {_, ctx} =
      ctx
      |> HalC2.Steps.Providers.ProviderSetup.paired("second")
      |> Acp.watch_auth("acme", "second")

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
      |> World.put_client("second", Mc.connect(context.mc))
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

  # The fake agent's permission request offers exactly allow_once and reject_once.
  step "{string} asks permission to run a command, offering only to allow once or reject",
       %{args: [_]} = context do
    context
    |> run_on_acme("approve", mode: context.mode)
    |> Map.put(:current_thread, "Acme")
  end

  step "{string} is told the request is allowed once", %{args: [_]} = context do
    [run] = Acp.await_runs(thread(context), 1)
    assert run["status"] == "completed"
    assert Acp.assistant_text(thread(context)) =~ "allowed"

    assert Enum.any?(
             Acp.log(context, "acme"),
             &(&1["event"] == "response" and
                 &1["result"] == %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}})
           )

    context
  end

  step "the request is approved without asking the user", context do
    [run] = Acp.await_runs(thread(context), 1)
    assert run["status"] == "completed"
    assert Acp.assistant_text(thread(context)) =~ "allowed"

    refute Enum.any?(
             HalC2.StreamState.list(Acp.stream(thread(context)), "runtime-request"),
             &(&1["status"] == "pending")
           )

    context
  end

  step "a turn is running on {string}", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("wait")

    Acp.await_stream(thread(ctx), fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))
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

  defp three_turns(ctx) do
    ctx = ctx |> acme() |> run_on_acme("write one.txt", worktree: true)
    Acp.await_runs(thread(ctx), 1)
    Acp.follow_up(ctx, ctx.thread, "write two.txt")
    Acp.await_runs(thread(ctx), 2)
    Acp.follow_up(ctx, ctx.thread, "write three.txt")
    Acp.await_runs(thread(ctx), 3)
    scope = HalC2.Checkpoint.scope_id(thread(ctx))
    last = HalC2.Checkpoint.checkpoint_id(scope, 3)

    Acp.await_stream(thread(ctx), fn state ->
      HalC2.StreamState.get(state, "checkpoint")[last]["status"] == "ready"
    end)

    ctx
  end

  defp rollback_to_first(ctx) do
    scope = HalC2.Checkpoint.scope_id(thread(ctx))

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "checkpoint.rollback",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(ctx),
        "scopeId" => scope,
        "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 1)
      })

    Map.put(ctx, :before_rollback, length(Acp.log(ctx, "acme")))
  end

  step "an {string} thread with three turns", %{args: [_]} = context do
    three_turns(context)
  end

  step "the user rolls back to the first turn", context do
    rollback_to_first(context)
  end

  step "an {string} thread that was rolled back to its first turn", %{args: [_]} = context do
    context |> three_turns() |> rollback_to_first()
  end

  step "the user sends a message and then stops the turn", context do
    # The first message on the replacement session carries the history the
    # rollback kept; the second is the one whose work must show.
    Acp.follow_up(context, context.thread, "hello again")

    Acp.await_stream(thread(context), fn state ->
      state |> HalC2.StreamState.list("run") |> Enum.count(&(&1["status"] == "completed")) == 2
    end)

    Acp.follow_up(context, context.thread, "plan the next step")

    Acp.await_stream(thread(context), fn state ->
      state |> HalC2.StreamState.list("run") |> Enum.count(&(&1["status"] == "completed")) == 3
    end)

    Acp.follow_up(context, context.thread, "wait")

    Acp.await_stream(thread(context), fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))
    end)

    started = System.monotonic_time(:millisecond)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(context)
      })

    Map.put(context, :stop_started, started)
  end

  step "the thread shows what {string} did for that message", %{args: [_]} = context do
    assert Acp.assistant_text(thread(context)) =~ "planned"
    context
  end

  step "{string} reaches HAL-C2's tools through the bridge that reads its standard input",
       %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("hello")
    Acp.await_runs(thread(ctx), 1)
    Mc.ensure(HalC2.Mcp)
    {:ok, lines} = Agent.start_link(fn -> [] end)

    # The MC itself as the transport: the same handler its HTTP route calls.
    post = fn _endpoint, headers, body, emit ->
      {status, resp_headers, reply} =
        HalC2.Mcp.handle_request(headers["authorization"], headers, body)

      if reply, do: emit.(reply)
      {:ok, status, resp_headers}
    end

    Map.merge(ctx, %{
      mcp_bridge_lines: lines,
      mcp_bridge_run: {
        HalC2.Mcp.endpoint(),
        HalC2.Mcp.server(thread(ctx), "acme").authorization,
        post
      }
    })
  end

  step ~r/^the agent sends a tool call whose arguments hold a (?:line|paragraph) separator \(U\+(?<code>2028|2029)\)$/,
       %{args: [code]} = context do
    separator = <<String.to_integer(code, 16)::utf8>>

    call =
      ~s({"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"hal_c2_thread_list","arguments":{"titleContains":"a) <>
        separator <> ~s(b"}}})

    raw =
      ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}) <>
        "\n" <> call <> "\n"

    # Read as the bridge's stdio entry reads it: one line at a time, through
    # the same line loop the release runs.
    {:ok, io} = StringIO.open(raw)
    {endpoint, authorization, post} = context.mcp_bridge_run
    lines = context.mcp_bridge_lines

    :ok =
      HalC2.Mcp.BridgeCli.run_bridge(
        endpoint,
        authorization,
        IO.stream(io, :line),
        fn line -> Agent.update(lines, &[line | &1]) end,
        post: post
      )

    context
  end

  defp bridge_answers(context) do
    context.mcp_bridge_lines
    |> Agent.get(&Enum.reverse/1)
    |> Enum.map(&JSON.decode!(String.trim_trailing(&1, "\n")))
  end

  step "HAL-C2 answers that tool call under its own request id", context do
    assert Enum.any?(bridge_answers(context), &(&1["id"] == 99 and is_map(&1["result"])))
    context
  end

  step "no parse error is sent back", context do
    refute Enum.any?(bridge_answers(context), &(get_in(&1, ["error", "code"]) == -32700))
    context
  end

  step "the turn stops without waiting for a time limit", context do
    Acp.await_stream(thread(context), fn state ->
      last =
        state
        |> HalC2.StreamState.list("run")
        |> Enum.max_by(& &1["ordinal"], fn -> %{} end)

      last["status"] in ["interrupted", "cancelled"]
    end)

    # The upstream bug made Stop wait out a 15-second limit; the await above
    # already gives up at five, and the stop lands well inside it.
    assert System.monotonic_time(:millisecond) - context.stop_started < 5_000
    context
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
      state |> HalC2.StreamState.list("run") |> Enum.count(&(&1["status"] == "completed")) == 2
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
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.model-selection.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(context),
        "modelSelection" => %{"instanceId" => "acme", "model" => "acme/smart"}
      })

    context
  end

  step "{string} offers models through the session model list", %{args: [_]} = context do
    ctx = acme(context, %{"legacyModels" => true})
    assert [%{"slug" => "acme/fast"}, %{"slug" => "acme/smart"}] = Acp.check("acme")["models"]
    ctx = run_on_acme(ctx, "hello", model: "acme/fast")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "{string} resumes its sessions without the model list", %{args: [_]} = context do
    Acp.control(context, "acme", %{"resumeWithoutModels" => true})
  end

  step "the agent's session uses the new model through set_model", context do
    Acp.follow_up(context, context.thread, "which model")
    Acp.await_runs(thread(context), 2)
    assert Acp.assistant_text(thread(context)) =~ "model: acme/smart"

    assert %{"params" => %{"modelId" => "acme/smart"}} =
             List.last(Acp.requests(context, "acme", "session/set_model"))

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

  step "the user adds the custom model {string} with a reasoning choice of low or high",
       %{args: [slug]} = context do
    options = [%{"id" => "low", "label" => "Low"}, %{"id" => "high", "label" => "High"}]

    model = %{
      "slug" => slug,
      "capabilities" => %{
        "optionDescriptors" => [
          %{"id" => "effort", "label" => "Reasoning", "type" => "select", "options" => options}
        ]
      }
    }

    Acp.write_settings(
      context,
      &update_in(&1, ["providerInstances", "acme"], fn instance ->
        config = instance["config"] || %{}
        Map.put(instance, "config", Map.put(config, "customModels", [model]))
      end),
      "ops"
    )
  end

  step "{string} is offered with low and high reasoning", %{args: [slug]} = context do
    {entry, ctx} =
      await_acme(context, fn entry -> Enum.any?(entry["models"], &(&1["slug"] == slug)) end)

    model = Enum.find(entry["models"], &(&1["slug"] == slug))
    assert [descriptor] = model["capabilities"]["optionDescriptors"]
    assert Enum.map(descriptor["options"], & &1["id"]) == ["low", "high"]
    ctx
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

  # --- plan mode -----------------------------------------------------------------------

  step "{string} has its own plan mode", %{args: [_]} = context do
    ctx = context |> acme(%{"modes" => ["build", "plan"]}) |> run_on_acme("hello")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the user switches the thread to plan mode", context do
    context |> interaction_mode("plan") |> Acp.follow_up("Acme", "plan the checkout")
    Acp.await_runs(thread(context), 2)
    context
  end

  step "{string} runs in its plan mode", %{args: [_]} = context do
    # The agent's own mode is chosen on the session before the plan turn's prompt.
    assert [:prompt, {"mode", "plan"}, :prompt] = mode_calls(context)

    # Out of plan mode again, the agent goes back to the mode it was in.
    context |> interaction_mode("default") |> Acp.follow_up("Acme", "now build it")
    Acp.await_runs(thread(context), 3)

    assert [:prompt, {"mode", "plan"}, :prompt, {"mode", "build"}, :prompt] =
             mode_calls(context)

    context
  end

  # The file is outside the workspace (`/etc/hosts`): HAL-C2 serves workspace reads only.
  # The fake keeps its mode with the session, as a real agent does: started again, it
  # resumes the session still planning.
  step "{string} has its own plan mode and the thread is in plan mode", %{args: [_]} = context do
    ctx =
      context
      |> acme(%{"modes" => ["build", "plan"], "keepMode" => true})
      |> run_on_acme("hello")

    Acp.await_runs(thread(ctx), 1)
    ctx |> interaction_mode("plan") |> Acp.follow_up("Acme", "plan the checkout")
    Acp.await_runs(thread(ctx), 2)
    assert [:prompt, {"mode", "plan"}, :prompt] = mode_calls(ctx)
    ctx
  end

  step "the runtime of {string} restarted", %{args: [_]} = context do
    [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, thread(context))
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    context
  end

  step "the user switches the thread out of plan mode", context do
    context |> interaction_mode("default") |> Acp.follow_up("Acme", "now build it")
    Acp.await_runs(thread(context), 3)
    context
  end

  step "{string} runs in the mode it had before plan mode", %{args: [_]} = context do
    assert [:prompt, {"mode", "plan"}, :prompt, {"mode", "build"}, :prompt] =
             mode_calls(context)

    # The agent that ran the last turn is a new process, on the session it had.
    root = World.project(context).root
    assert [_, _] = Enum.filter(Acp.launches(context, "acme"), &(&1["cwd"] == root))
    assert [_] = Acp.requests(context, "acme", "session/resume")
    context
  end

  step "{string} asks the client to read a file or run a terminal", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("read file")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the request is refused rather than left waiting", context do
    text = Acp.assistant_text(thread(context))
    assert text =~ "fs: -32002"
    assert text =~ "terminal: -32601"
    context
  end

  step "{string} is waiting for approval to write a file", %{args: [_]} = context do
    ctx = acme(context)
    File.write!(Path.join(World.project(ctx).root, "notes.txt"), "line one\nline two\n")
    ctx = run_on_acme(ctx, "change and read notes.txt", mode: "approval-required")

    request =
      Acp.await_stream(thread(ctx), fn state ->
        Enum.find(
          HalC2.StreamState.list(state, "runtime-request"),
          &(&1["status"] == "pending" and &1["kind"] == "file-change")
        )
      end)

    Map.put(ctx, :write_request, request["id"])
  end

  # The fake asks for the file right after the approval, and says what it got.
  step "{string} asks the client to read a file in the workspace", %{args: [_]} = context do
    answer =
      Acp.await_stream(thread(context), fn _ ->
        case Regex.run(~r/read: (.*)/, Acp.assistant_text(thread(context))) do
          [_, json] -> JSON.decode!(json)
          nil -> nil
        end
      end)

    Map.put(context, :read_answer, answer)
  end

  step "the read is answered", context do
    assert context.read_answer == %{"content" => "line one\nline two\n"}

    context
  end

  step "the write is still waiting for approval", context do
    state = Acp.stream(thread(context))
    request = HalC2.StreamState.get(state, "runtime-request")[context.write_request]
    assert request["status"] == "pending"
    assert [%{"status" => "running"}] = HalC2.StreamState.list(state, "run")
    context
  end

  # --- sign-in before a session ----------------------------------------------------------

  step "{string} requires sign-in and the user has not signed in", %{args: [_]} = context do
    signed_out_acme(context, [@browser])
  end

  step "a thread tries to start a session with {string}", %{args: [_]} = context do
    ctx = run_on_acme(context, "hello")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the thread fails with an authentication error", context do
    assert [%{"status" => "failed"}] = Acp.runs(thread(context))

    assert [%{"lastError" => message}] =
             HalC2.StreamState.list(Acp.stream(thread(context)), "provider-session")

    assert message =~ "acme is not signed in"
    context
  end

  step "no session with {string} is created", %{args: [_]} = context do
    # The agent is never started in the thread's workspace, and never prompted.
    refute Enum.any?(Acp.launches(context, "acme"), &(&1["cwd"] == World.project(context).root))
    assert Acp.requests(context, "acme", "session/prompt") == []

    assert [%{"nativeThreadRef" => nil}] =
             HalC2.StreamState.list(Acp.stream(thread(context)), "provider-thread")

    context
  end

  # --- commands and skills ---------------------------------------------------------------

  step "a running {string} session offers the command {string} and the skill {string}",
       %{args: [_, "/" <> command, skill]} = context do
    ctx =
      context
      |> acme(%{
        "commands" => [
          %{
            "name" => command,
            "description" => "Review the changes",
            "input" => %{"hint" => "path"}
          },
          %{"name" => skill, "description" => "Ship it"}
        ]
      })
      |> watch_providers()
      |> run_on_acme("offer commands")

    {entry, ctx} = await_acme(ctx, &(&1["slashCommands"] != []))
    assert [%{"status" => "running"}] = Acp.runs(thread(ctx))
    Map.put(ctx, :entry, entry)
  end

  step "the user types a slash", context do
    Map.put(context, :entry, Acp.provider("acme"))
  end

  step "{string} is offered under the provider's commands", %{args: ["/" <> name]} = context do
    assert [
             %{
               "name" => ^name,
               "description" => "Review the changes",
               "input" => %{"hint" => "path"}
             }
           ] =
             context.entry["slashCommands"]

    context
  end

  step "{string} is offered in the skill menu", %{args: ["$" <> name]} = context do
    assert [%{"name" => ^name, "description" => "Ship it", "enabled" => true, "scope" => "agent"}] =
             context.entry["skills"]

    # A skill is not also a slash command.
    refute Enum.any?(context.entry["slashCommands"], &(&1["name"] =~ name))
    context
  end

  # --- the agent's own terminal ----------------------------------------------------------

  step "an ACP v2 agent runs a command in its own terminal", context do
    ctx = context |> acme() |> run_on_acme("own terminal")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the command, its output and exit status are shown", context do
    assert [command] =
             Acp.stream(thread(context))
             |> HalC2.StreamState.list("turn-item")
             |> Enum.filter(&(&1["type"] == "command_execution"))

    assert %{
             "input" => "npm test",
             "output" => "running 2 tests\n1 failed\n",
             "exitCode" => 1,
             "status" => "failed"
           } = command

    context
  end

  step "the user cannot type into that terminal", context do
    HalC2.Test.Mc.Terminal.ensure(context)

    # It is a command of the turn: no terminal session exists to write to.
    assert {:error, _} =
             HalC2.Terminal.write(%{
               "threadId" => thread(context),
               "terminalId" => "term-1",
               "data" => "echo hi\n"
             })

    context
  end

  step "the user picks a provider for thread titles", context do
    ctx = acme(context)
    # Loaded as the MC's status check does, so the entry is complete.
    assert Acp.check("acme")["models"] != []
    sub = 4000 + System.unique_integer([:positive])

    client =
      Mc.sub(World.client(ctx), sub, %{"type" => "config", "mc" => Atom.to_string(node())})

    {frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == sub))
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
    assert [plan] = HalC2.StreamState.list(state, "plan")

    assert [
             %{"text" => "Read the code", "status" => "completed"},
             %{"text" => "Fix the bug", "status" => "running"}
           ] = plan["steps"]

    assert [%{"contextUsage" => %{"usedTokens" => 1200, "maxTokens" => 200_000}}] =
             HalC2.StreamState.list(state, "provider-thread")

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

  # --- Kimi and the subagents setting --------------------------------------------------

  step "Kimi CLI is offered HAL-C2's tools", context do
    Mc.ensure(HalC2.Mcp)

    config = %{
      "turns" => FakeAcp.turns(),
      "capabilities" => %{"mcpCapabilities" => %{"http" => true}}
    }

    context = FakeAcp.install(context, "kimi", config)
    World.put_app_env(:acp_commands, %{"kimi" => [context.fakes["kimi"].bin]})

    FakeAcp.settings(fn settings ->
      put_in(settings, [Access.key("providerInstances", %{}), "kimi"], %{
        "driver" => "acpRegistry",
        "enabled" => true,
        "config" => %{"agentId" => "kimi"}
      })
    end)

    context
  end

  step "the user sends a Kimi thread its first message", context do
    context = context |> FakeAcp.thread("Kimi work") |> FakeAcp.send_message("hello")
    FakeAcp.await_run(context, "completed")
    context
  end

  step ~r/^Kimi is (?<told>told|not told) to delegate with "(?<tool>[^"]+)" instead of using its own subagents$/,
       %{args: [told, tool]} = context do
    assert [%{"params" => %{"prompt" => [%{"text" => text} | _]}}] =
             FakeAcp.received(context, "session/prompt", "kimi")

    assert text =~ "<hal_c2_orchestration_instructions>"
    delegate = ~r/built-in subagents\. Delegate child work with `#{tool}`/

    if told == "told", do: assert(text =~ delegate), else: refute(text =~ delegate)
    context
  end

  # --- the registry, fetched and read -------------------------------------------

  defp fetches(ctx), do: Enum.count(Acp.registry_requests(ctx), &(&1 == "registry.json"))

  # Publishes "acme", fetches the registry once, then ages that fetch.
  defp seed_fetch(ctx, age_ms, fresh \\ true) do
    ctx = Acp.publish(ctx)
    {:ok, [_]} = HalC2.Acp.Catalog.index(true)
    {_, agents, _} = :persistent_term.get({HalC2.Acp.Catalog, :index})
    at = System.system_time(:millisecond) - age_ms
    :persistent_term.put({HalC2.Acp.Catalog, :index}, {at, agents, fresh})
    Map.put(ctx, :fetches_before, fetches(ctx))
  end

  step "the MC fetched the registry four minutes ago", context do
    seed_fetch(context, 4 * 60_000)
  end

  step "the MC fetched the registry six minutes ago", context do
    seed_fetch(context, 6 * 60_000)
  end

  step "the MC fetched the registry a minute ago", context do
    seed_fetch(context, 60_000)
  end

  step "the MC could not reach the registry a minute ago and used its cached copy", context do
    ctx = seed_fetch(context, 0)
    Application.put_env(:hal_c2, :acp_registry_url, "http://127.0.0.1:1/registry.json")
    # The forced fetch fails and the cached copy serves; that is on record now.
    {:ok, [_]} = HalC2.Acp.Catalog.index(true)
    {_, agents, fresh} = :persistent_term.get({HalC2.Acp.Catalog, :index})
    assert fresh == false
    at = System.system_time(:millisecond) - 60_000
    :persistent_term.put({HalC2.Acp.Catalog, :index}, {at, agents, false})
    # The failure itself is a minute old too, past the backoff a search honours.
    :persistent_term.put({HalC2.Acp.Catalog, :fetch_failed_at}, at)
    Application.put_env(:hal_c2, :acp_registry_url, "#{ctx.acp.base}/registry.json")
    Map.put(ctx, :fetches_before, fetches(ctx))
  end

  step "the MC fetched the registry a minute ago, but its clock has since gone back", context do
    # The recorded fetch now lies in the future.
    seed_fetch(context, -60_000)
  end

  step "the registry is not fetched again", context do
    assert ids(context.reply) == ["acme"]
    assert fetches(context) == context.fetches_before
    context
  end

  step "the registry is fetched again", context do
    assert ids(context.reply) == ["acme"]
    assert fetches(context) == context.fetches_before + 1
    context
  end

  step "the registry is fetched again before {string} is prepared", %{args: [id]} = context do
    assert {:ok, %{"agentId" => ^id, "prepared" => true}} = context.reply
    requests = Acp.registry_requests(context)
    assert fetches(context) == context.fetches_before + 1

    fetched_at =
      requests
      |> Enum.with_index()
      |> Enum.filter(&(elem(&1, 0) == "registry.json"))
      |> List.last()
      |> elem(1)

    downloaded_at = Enum.find_index(requests, &(&1 == "#{id}.tar.gz"))
    assert fetched_at < downloaded_at
    context
  end

  step "the MC holds a cached copy of the registry", context do
    # Ten minutes old, so a search tries the registry before falling back.
    seed_fetch(context, 10 * 60_000)
  end

  step "agents from the cached copy are listed", context do
    assert ids(context.reply) == ["acme"]
    context
  end

  defp serve_raw(ctx, body) do
    ctx = Acp.serve_registry(ctx)
    File.write!(Path.join(ctx.acp.served, "registry.json"), body)
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    File.rm(HalC2.Acp.Catalog.cache_path())
    Map.put(ctx, :bad_body, body)
  end

  defp search_acme(ctx) do
    ctx = ops(ctx)

    {reply, ctx} =
      Acp.with_runners(ctx, fn ->
        World.call(ctx, "server.searchAcpRegistry", %{"query" => "acme"}, "ops")
      end)

    Map.put(ctx, :reply, reply)
  end

  step "the registry answers with text that is not JSON", context do
    context |> serve_raw("this is not json") |> search_acme()
  end

  step "the registry answers with JSON that is not a registry", context do
    context |> serve_raw(JSON.encode!(%{"hello" => "world"})) |> search_acme()
  end

  step "the registry answers with an index larger than 1 MB", context do
    body = JSON.encode!(%{"version" => String.duplicate("x", 1_100_000), "agents" => []})
    context |> serve_raw(body) |> search_acme()
  end

  step "the fetch fails with {string}", %{args: [message]} = context do
    error = operation_error(context.reply)
    assert error["reason"] == "registry_unavailable"
    # The scenario names the production registry; the MC names the one it was told.
    url = Application.get_env(:hal_c2, :acp_registry_url)

    actual =
      String.replace(
        error["message"],
        url,
        "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
      )

    assert actual == message
    context
  end

  step "a cached copy is used if the MC has one", context do
    ctx = seed_fetch(context, 10 * 60_000)
    File.write!(Path.join(ctx.acp.served, "registry.json"), ctx.bad_body)
    ctx = search_acme(ctx)
    assert ids(ctx.reply) == ["acme"]
    ctx
  end

  step "the registry lists {string} correctly and another agent with a malformed entry",
       %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [Acp.acme_agent(ctx, id: id), %{"id" => "broken"}])
  end

  step "the malformed entry is left out", context do
    assert ids(context.reply) == ["acme"]
    context
  end

  defp untrusted(ctx, dist) do
    ctx = Acp.serve_registry(ctx)
    Acp.publish(ctx, [agent(ctx, "acme", "Acme", dist)])
  end

  defp binary_at(url),
    do: %{
      "binary" => %{HalC2.Acp.Catalog.platform() => %{"archive" => url, "cmd" => "./bin/acme"}}
    }

  step "the registry lists an agent whose download address is not HTTPS", context do
    untrusted(context, binary_at("http://example.com/acme.tar.gz"))
  end

  step "the registry lists an agent whose download address carries a user name or password",
       context do
    untrusted(context, binary_at("https://user:secret@example.com/acme.tar.gz"))
  end

  step "the registry lists an agent whose npx or uvx package does not pin an exact version",
       context do
    untrusted(context, npx("@acme/acme"))
  end

  step "that agent is not offered", context do
    assert ids(context.reply) == []
    context
  end

  step "the registry lists more than 512 agents", context do
    ctx = Acp.serve_registry(context)
    base = Acp.acme_agent(ctx)
    agents = for n <- 1..513, do: %{base | "id" => "agent-#{n}", "name" => "Agent #{n}"}
    Acp.publish(ctx, agents)
  end

  step "the MC reads the registry", context do
    search_acme(context)
  end

  step "the index is refused as invalid", context do
    assert %{"message" => "ACP Registry returned an invalid index."} =
             operation_error(context.reply)

    context
  end

  step "the registry agent {string} only runs through uvx", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", %{"uvx" => %{"package" => "acme==2.0.0"}})])
  end

  step "uv is not installed on the MC", context do
    empty = Path.join(context.mc.home, "empty-bin")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)
    assert System.find_executable("uv") == nil
    Map.put(context, :runners_removed, true)
  end

  step "the instance of {string} is set to run through uvx", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", %{"uvx" => %{"package" => "acme==2.0.0"}})])

    Acp.add_registry_instance(id, id, %{
      "config" => %{"agentId" => id, "distribution" => "uvx"}
    })

    ctx
  end

  step "the MC prepares {string}", %{args: [id]} = context do
    prepare_agent(context, id)
  end

  step "the registry lists agents matching {string} by id, by the start of their name, by author and by description",
       %{args: [_]} = context do
    ctx = Acp.serve_registry(context)
    dist = fn id -> npx("@acme/#{id}@1.0.0") end

    agents = [
      agent(ctx, "gem", "Gem", dist.("gem")),
      agent(ctx, "gemcut", "Gemcut", dist.("gemcut")),
      agent(ctx, "agemo", "Agemo", dist.("agemo")),
      agent(ctx, "bgemo", "Bgemo", dist.("bgemo")),
      ctx
      |> agent("smith", "Smith", dist.("smith"))
      |> Map.put("authors", ["Gemma"]),
      ctx
      |> agent("rock", "Rock", dist.("rock"))
      |> Map.put("description", "A gem tool")
    ]

    Acp.publish(ctx, agents)
  end

  step "the exact id or name match comes first", context do
    assert hd(ids(context.reply)) == "gem"
    context
  end

  step "matches at the start of a name come before matches inside it, then authors, then descriptions",
       context do
    assert ids(context.reply) == ["gem", "gemcut", "agemo", "bgemo", "smith", "rock"]
    context
  end

  step "equal matches are ordered by name", context do
    found = ids(context.reply)
    assert Enum.find_index(found, &(&1 == "agemo")) < Enum.find_index(found, &(&1 == "bgemo"))
    context
  end

  step "each agent says whether its download is checked against a published SHA-256 or trusted from the registry alone",
       context do
    assert {:ok, %{"agents" => agents}} = context.reply
    assert Enum.all?(agents, &(&1["integrity"] in ["sha256", "registry"]))
    assert Enum.find(agents, &(&1["id"] == "acme"))["integrity"] == "sha256"
    assert Enum.find(agents, &(&1["id"] == "acme-beta"))["integrity"] == "registry"
    context
  end

  step "each agent carries its version, authors, license, website and repository", context do
    assert {:ok, %{"agents" => agents}} = context.reply

    for agent <- agents do
      assert agent["version"] == "2.0.0"
      assert agent["authors"] == ["Acme"]
      assert agent["license"] == "MIT"
      assert agent["website"] == "https://acme.test"
      assert agent["repository"] == "https://github.com/acme/acme"
    end

    context
  end

  step "the registry lists no checksum for {string}", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [Acp.acme_agent(ctx, id: id, sha256: false)])
  end

  step "the user installs {string}", %{args: [id]} = context do
    prepare(context, id)
  end

  step "{string} is installed", %{args: [id]} = context do
    assert {:ok, %{"agentId" => ^id, "prepared" => true}} = context.reply
    assert Path.wildcard(Path.join([tools(context, id), "**", "bin", id])) != []
    context
  end

  step "the MC holds no cached copy of the registry", context do
    ctx = Acp.ready(context)
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    File.rm(HalC2.Acp.Catalog.cache_path())
    ctx
  end

  step "the registry answers with an error status", context do
    # The served registry has no registry.json, so it answers 404.
    context |> Acp.serve_registry() |> search_acme()
  end

  step "the registry breaks off while its answer is being read", context do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    Application.put_env(:hal_c2, :acp_registry_url, "http://127.0.0.1:#{port}/registry.json")

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 10_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 10_000)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n{\"agents\": [")
        :gen_tcp.close(socket)
      end)

    ctx = search_acme(context)
    Task.await(server, 10_000)
    :gen_tcp.close(listen)
    ctx
  end

  step "the registry answers with bytes that are not UTF-8", context do
    context |> serve_raw(<<0xFF, 0xFE, 0x00, 0x7B>>) |> search_acme()
  end

  step "the registry can be reached", context do
    Acp.publish(context)
  end

  step "two clients search the registry at the same moment", context do
    searches =
      Acp.with_runners(context, fn ->
        [
          Task.async(fn -> HalC2.Acp.Catalog.search(%{"query" => "acme"}) end),
          Task.async(fn -> HalC2.Acp.Catalog.search(%{"query" => "acme"}) end)
        ]
        |> Enum.map(&Task.await(&1, 30_000))
      end)

    Map.put(context, :searches, searches)
  end

  step "the registry is fetched once", context do
    assert fetches(context) == 1
    context
  end

  step "both searches are answered from that one fetch", context do
    assert Enum.all?(context.searches, &match?({:ok, %{"agents" => [%{"id" => "acme"}]}}, &1))
    context
  end

  step "the registry lists an agent whose name is blank", context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [Acp.acme_agent(ctx, name: " ")])
  end

  step "the registry lists an agent whose version is {string} or {string} or holds a path separator",
       %{args: [_, _]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [Acp.acme_agent(ctx, version: "..")])
  end

  step "the registry lists an agent whose id holds upper-case letters, spaces or a path separator",
       context do
    ctx = Acp.serve_registry(context)
    base = Acp.acme_agent(ctx)
    Acp.publish(ctx, [%{base | "id" => "Acme/Bad Id"}])
  end

  step "the registry lists an agent whose npx package is written the way a uvx package pins versions",
       context do
    untrusted(context, npx("acme==1.0.0"))
  end

  step "the MC runs on a machine that is neither macOS, Linux nor Windows on arm64 or x64",
       context do
    ctx = Acp.serve_registry(context)

    Acp.publish(ctx, [
      Acp.acme_agent(ctx),
      agent(ctx, "acme-npx", "Acme Npx", npx("@acme/npx@1.0.0")),
      agent(ctx, "acme-uvx", "Acme Uvx", %{"uvx" => %{"package" => "acme==1.0.0"}})
    ])

    Application.put_env(:hal_c2, :acp_platform, nil)
    ctx
  end

  step "agents that run through npx or uvx are offered", context do
    assert "acme-npx" in ids(context.reply)
    assert "acme-uvx" in ids(context.reply)
    context
  end

  step "agents published only as binaries are left out", context do
    refute "acme" in ids(context.reply)
    context
  end

  # --- fake package managers ---------------------------------------------------

  # Prepares `id` for its instance: through the prepare RPC, or through the
  # command the instance's distribution preference picks.
  defp prepare_agent(ctx, id) do
    ctx = fake_managers(ctx)

    case ctx[:dist_pref] do
      pref when pref in ["binary", "npx", "uvx"] ->
        reply =
          case HalC2.Acp.Catalog.command(%{"agentId" => id, "distribution" => pref}) do
            {:ok, [exe | _], _env} -> {:ok, %{"agentId" => id, "prepared" => true, "exe" => exe}}
            {:error, detail} -> {:error, detail["message"], detail}
          end

        Map.put(ctx, :reply, reply)

      _ ->
        prepare(ctx, id)
    end
  end

  # npm and uv on the MC's path, installing the fake agent like a real package
  # would, under the prefix the MC names. Their behaviour is steered by the
  # `npm-control.json` / `uv-control.json` beside them (`bin`, `commands`,
  # `version`, `output`, `exit`); every call is logged next to them.
  defp fake_managers(%{fake_managers: _} = ctx), do: ctx

  defp fake_managers(ctx) do
    if System.find_executable("npm") == nil and System.find_executable("uv") == nil do
      # The scenario took the package managers away; keep them gone.
      ctx
    else
      ctx = Acp.ready(ctx)
      dir = Path.join(ctx.mc.home, "fake-bin")
      File.mkdir_p!(dir)
      Acp.wrapper(ctx, Path.join(dir, "agent-wrapper"), "acme")

      for name <- ["npm-control.json", "uv-control.json"],
          not File.exists?(Path.join(dir, name)),
          do: File.write!(Path.join(dir, name), "{}")

      File.write!(Path.join(dir, "npm"), npm_script())
      File.write!(Path.join(dir, "uv"), uv_script())
      File.chmod!(Path.join(dir, "npm"), 0o755)
      File.chmod!(Path.join(dir, "uv"), 0o755)
      System.put_env("PATH", dir <> ":" <> (System.get_env("PATH") || ""))
      Map.put(ctx, :fake_managers, dir)
    end
  end

  defp manager_control(ctx, file, fields) do
    ctx = fake_managers(ctx)
    path = Path.join(ctx.fake_managers, file)
    merged = path |> File.read!() |> JSON.decode!() |> Map.merge(fields)
    File.write!(path, JSON.encode!(merged))
    ctx
  end

  defp manager_calls(ctx, name) do
    case File.read(Path.join(ctx.fake_managers, name <> ".log")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  defp npm_script do
    """
    #!/usr/bin/env python3
    import json, os, shutil, sys
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        ctl = json.load(open(os.path.join(here, "npm-control.json")))
    except FileNotFoundError:
        ctl = {}
    with open(os.path.join(here, "npm.log"), "a") as log:
        log.write(json.dumps({"args": sys.argv[1:], "prefix": os.environ.get("npm_config_prefix")}) + "\\n")
    if ctl.get("output"):
        print(ctl["output"])
    if ctl.get("exit"):
        sys.exit(ctl["exit"])
    pkg = sys.argv[-1]
    name, _, version = pkg.rpartition("@")
    prefix = os.environ["npm_config_prefix"]
    root = os.path.join(prefix, "lib", "node_modules", *name.split("/"))
    os.makedirs(root, exist_ok=True)
    os.makedirs(os.path.join(prefix, "bin"), exist_ok=True)
    bins = ctl.get("bin", {name.split("/")[-1]: "index.js"})
    json.dump({"name": name, "version": ctl.get("version", version), "bin": bins},
              open(os.path.join(root, "package.json"), "w"))
    names = [name.split("/")[-1]] if isinstance(bins, str) else list(bins)
    for command in names:
        dest = os.path.join(prefix, "bin", command)
        shutil.copyfile(os.path.join(here, "agent-wrapper"), dest)
        os.chmod(dest, 0o755)
    """
  end

  defp uv_script do
    """
    #!/usr/bin/env python3
    import json, os, shutil, sys
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        ctl = json.load(open(os.path.join(here, "uv-control.json")))
    except FileNotFoundError:
        ctl = {}
    with open(os.path.join(here, "uv.log"), "a") as log:
        log.write(json.dumps({"args": sys.argv[1:], "binDir": os.environ.get("UV_TOOL_BIN_DIR"),
                                "toolDir": os.environ.get("UV_TOOL_DIR")}) + "\\n")
    if ctl.get("output"):
        print(ctl["output"])
    if ctl.get("exit"):
        sys.exit(ctl["exit"])
    pkg = sys.argv[-1]
    name = pkg.split("==")[0].rpartition("@")[0] or pkg.split("==")[0]
    bin_dir = os.environ["UV_TOOL_BIN_DIR"]
    os.makedirs(bin_dir, exist_ok=True)
    for command in ctl.get("commands", [name]):
        dest = os.path.join(bin_dir, command)
        shutil.copyfile(os.path.join(here, "agent-wrapper"), dest)
        os.chmod(dest, 0o755)
    """
  end

  # --- archives -----------------------------------------------------------------

  # A tar.gz built by the system tar from a tree `build.(dir)` lays out.
  defp tar_bytes(ctx, build) do
    src = Path.join(ctx.mc.home, "archive-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    build.(src)
    archive = src <> ".tar.gz"
    {_, 0} = System.cmd("tar", ["-czf", archive, "-C", src, "."])
    File.read!(archive)
  end

  defp publish_archive(ctx, id, bytes, fields \\ %{}) do
    ctx = Acp.serve_registry(ctx)
    Acp.publish(ctx, [Map.merge(Acp.acme_agent(ctx, id: id, archive: bytes), fields)])
  end

  defp with_cmd(ctx, id, cmd) do
    base = Acp.acme_agent(ctx, id: id)
    platform = HalC2.Acp.Catalog.platform()
    target = base["distribution"]["binary"][platform]
    dist = %{"binary" => %{platform => %{target | "cmd" => cmd}}}
    Acp.publish(ctx, [%{base | "distribution" => dist}])
  end

  step "the registry entry or archive for {string} names a command path that leaves the install folder",
       %{args: [id]} = context do
    context |> Acp.serve_registry() |> with_cmd(id, "../bin/acme")
  end

  step "the registry entry or archive for {string} holds a file path that leaves the install folder",
       %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    script = Acp.wrapper(ctx, Path.join([ctx.mc.home, "evil-src", id]), id)
    archive = Path.join(ctx.mc.home, "evil.tar.gz")

    :ok =
      :erl_tar.create(
        to_charlist(archive),
        [
          {~c"bin/#{id}", to_charlist(script)},
          {~c"../evil.txt", "x"}
        ],
        [:compressed]
      )

    publish_archive(ctx, id, File.read!(archive))
  end

  step "the registry entry or archive for {string} does not hold the command the registry names",
       %{args: [id]} = context do
    bytes = tar_bytes(context, fn src -> File.write!(Path.join(src, "readme.txt"), "hi") end)
    publish_archive(context, id, bytes)
  end

  step "the registry entry or archive for {string} links its command to a file outside the install folder",
       %{args: [id]} = context do
    bytes =
      tar_bytes(context, fn src ->
        File.mkdir_p!(Path.join(src, "bin"))
        File.ln_s!("/bin/true", Path.join([src, "bin", id]))
      end)

    publish_archive(context, id, bytes)
  end

  step "the registry entry or archive for {string} links its command through another link to a file outside the install folder",
       %{args: [id]} = context do
    bytes =
      tar_bytes(context, fn src ->
        File.mkdir_p!(Path.join(src, "bin"))
        File.mkdir_p!(Path.join(src, "lib"))
        File.ln_s!("/bin/true", Path.join([src, "lib", "out"]))
        File.ln_s!("../lib/out", Path.join([src, "bin", id]))
      end)

    publish_archive(context, id, bytes)
  end

  # A bzip2 archive, unpacked by the system tar: `bin` in it is a link to a
  # folder outside the install folder that holds a same-named command.
  step "the registry entry or archive for {string} links a folder on its command's path to a folder outside the install folder",
       %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    script = Acp.wrapper(ctx, Path.join([ctx.mc.home, "outside-bin", id]), id)
    src = Path.join(ctx.mc.home, "dirlink-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    File.ln_s!(Path.dirname(script), Path.join(src, "bin"))
    served = Path.join(ctx.acp.served, "#{id}.tar.bz2")
    {_, 0} = System.cmd("tar", ["-cjf", served, "-C", src, "."])
    sha = :crypto.hash(:sha256, File.read!(served)) |> Base.encode16(case: :lower)
    platform = HalC2.Acp.Catalog.platform()

    dist = %{
      "binary" => %{
        platform => %{
          "archive" => "#{ctx.acp.base}/#{id}.tar.bz2",
          "cmd" => "./bin/#{id}",
          "args" => ["--acp"],
          "sha256" => sha
        }
      }
    }

    base = Acp.acme_agent(ctx, id: id)
    Acp.publish(ctx, [%{base | "distribution" => dist}])
  end

  step "the archive for {string} links its command to a file inside its own folder",
       %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    script = Acp.wrapper(ctx, Path.join([ctx.mc.home, "rel-src", id]), id)

    bytes =
      tar_bytes(ctx, fn src ->
        File.mkdir_p!(Path.join(src, "bin"))
        File.mkdir_p!(Path.join(src, "lib"))
        File.cp!(script, Path.join([src, "lib", "real-#{id}"]))
        File.chmod!(Path.join([src, "lib", "real-#{id}"]), 0o755)
        File.ln_s!("../lib/real-#{id}", Path.join([src, "bin", id]))
      end)

    publish_archive(ctx, id, bytes)
  end

  step "the registry entry or archive for {string} names a command that is not an executable file",
       %{args: [id]} = context do
    bytes = tar_bytes(context, fn src -> File.mkdir_p!(Path.join([src, "bin", id])) end)
    publish_archive(context, id, bytes)
  end

  step "adding {string} fails with {string}", %{args: [_id, message]} = context do
    assert %{"message" => ^message} = operation_error(context.reply)

    # An unsafe command path is refused before the archive is even fetched.
    if message =~ "unsafe command path" do
      refute Enum.any?(Acp.registry_requests(context), &String.ends_with?(&1, ".tar.gz"))
    end

    context
  end

  step "the archive downloaded for {string} holds a bundled tree of many thousands of files",
       %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    script = Acp.wrapper(ctx, Path.join([ctx.mc.home, "tree-src", id]), id)
    archive = Path.join(ctx.mc.home, "tree.tar.gz")

    entries =
      [{~c"bin/#{id}", to_charlist(script)}] ++
        for n <- 1..3000, do: {~c"tree/f-#{n}.txt", "x"}

    :ok = :erl_tar.create(to_charlist(archive), entries, [:compressed])
    ctx = publish_archive(ctx, id, File.read!(archive))
    prepare(ctx, id)
  end

  step "the registry publishes {string} as a download ending in {string}",
       %{args: [id, ending]} = context do
    ctx = Acp.serve_registry(context)
    script = Acp.wrapper(ctx, Path.join([ctx.mc.home, "kind-src", id]), id)
    served = Path.join(ctx.acp.served, "#{id}#{ending}")

    case ending do
      bin when bin in [".tar.gz", ".tgz"] ->
        :ok =
          :erl_tar.create(to_charlist(served), [{~c"bin/#{id}", to_charlist(script)}], [
            :compressed
          ])

      bin when bin in [".tar.bz2", ".tbz2"] ->
        src = Path.join(ctx.mc.home, "bz2-src-#{System.unique_integer([:positive])}")
        File.mkdir_p!(Path.join(src, "bin"))
        File.cp!(script, Path.join([src, "bin", id]))
        {_, 0} = System.cmd("tar", ["-cjf", served, "-C", src, "."])
        :ok

      ".zip" ->
        {:ok, _} = :zip.create(to_charlist(served), [{~c"bin/#{id}", File.read!(script)}])

      ".bin" ->
        File.cp!(script, served)
    end

    sha = :crypto.hash(:sha256, File.read!(served)) |> Base.encode16(case: :lower)
    platform = HalC2.Acp.Catalog.platform()

    dist = %{
      "binary" => %{
        platform => %{
          "archive" => "#{ctx.acp.base}/#{id}#{ending}",
          "cmd" => "./bin/#{id}",
          "args" => ["--acp"],
          "env" => %{"ACME_MODE" => "registry"},
          "sha256" => sha
        }
      }
    }

    base = Acp.acme_agent(ctx, id: id)
    Acp.publish(ctx, [%{base | "distribution" => dist}])
  end

  step "the download is unpacked as a gzip tar archive", context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert Path.wildcard(Path.join([tools(context), "**", "bin", "acme"])) != []
    context
  end

  step "the download is unpacked as a bzip2 tar archive", context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert Path.wildcard(Path.join([tools(context), "**", "bin", "acme"])) != []
    context
  end

  step "the download is unpacked as a zip archive", context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert Path.wildcard(Path.join([tools(context), "**", "bin", "acme"])) != []
    context
  end

  step "the download is kept as the agent's command and made runnable", context do
    assert {:ok, %{"prepared" => true}} = context.reply
    [exe] = Path.wildcard(Path.join([tools(context), "**", "bin", "acme"]))
    assert File.stat!(exe).mode |> Bitwise.band(0o111) != 0
    assert File.read!(exe) =~ "fake_acme_agent.py"
    context
  end

  step "the MC runs on Windows on ARM", context do
    ctx = Acp.ready(context)
    Application.put_env(:hal_c2, :acp_platform, "windows-aarch64")
    ctx
  end

  defp publish_builds(ctx, id, platforms) do
    ctx = Acp.serve_registry(ctx)
    base = Acp.acme_agent(ctx, id: id)
    target = base["distribution"]["binary"] |> Map.values() |> hd()
    dist = %{"binary" => Map.new(platforms, &{&1, target})}
    Acp.publish(ctx, [%{base | "distribution" => dist}])
  end

  step "the agent {string} publishes only a Windows x64 build", %{args: [id]} = context do
    publish_builds(context, id, ["windows-x86_64"])
  end

  step "the agent {string} publishes Windows x64 and ARM64 builds", %{args: [id]} = context do
    publish_builds(context, id, ["windows-x86_64", "windows-aarch64"])
  end

  defp assert_build_runs(context, platform) do
    assert {:ok, %{"prepared" => true}} = context.reply
    exe = Path.join([tools(context), "2.0.0", platform, "bin", "acme"])
    assert File.regular?(exe)
    Acp.add_registry_instance("acme", "acme")
    ctx = run_on_acme(context, "hello")
    Acp.await_runs(thread(ctx), 1)
    assert Acp.assistant_text(thread(ctx)) =~ "Hello from acme"
    launch = Enum.find(Acp.launches(ctx, "acme"), &(&1["cwd"] == World.project(ctx).root))
    assert launch["argv0"] == exe
    ctx
  end

  step "the Windows x64 build is installed and runs", context do
    assert_build_runs(context, "windows-x86_64")
  end

  step "the Windows ARM64 build is installed and runs", context do
    assert_build_runs(context, "windows-aarch64")
  end

  step "both add the registry agent {string} at the same moment", %{args: [id]} = context do
    ctx = Acp.publish(context)

    results =
      [
        Task.async(fn -> HalC2.Acp.Catalog.prepare(%{"agentId" => id}) end),
        Task.async(fn -> HalC2.Acp.Catalog.prepare(%{"agentId" => id}) end)
      ]
      |> Enum.map(&Task.await(&1, 60_000))

    Map.put(ctx, :results, results)
  end

  step "{string} is downloaded and installed once", %{args: [id]} = context do
    assert Enum.count(Acp.registry_requests(context), &(&1 == "#{id}.tar.gz")) == 1
    assert File.regular?(installed(context))
    context
  end

  step "the second client finds the finished install", context do
    assert Enum.all?(context.results, &match?({:ok, %{"prepared" => true}}, &1))
    context
  end

  step "the download of {string} 1.2.0 is answered with an error", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    ctx = Acp.publish(ctx, [Acp.acme_agent(ctx, id: id, version: "1.2.0")])
    File.rm!(Path.join(ctx.acp.served, "#{id}.tar.gz"))
    prepare(ctx, id)
  end

  step "the download of {string} 1.2.0 cannot be written to disk", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    ctx = Acp.publish(ctx, [Acp.acme_agent(ctx, id: id, version: "1.2.0")])
    # Where the agent's tools folder would go sits a file instead.
    File.mkdir_p!(Path.join(ctx.mc.home, "tools"))
    File.write!(tools(ctx, id), "in the way")
    prepare(ctx, id)
  end

  step "the binary of {string} was installed", %{args: [id]} = context do
    ctx = context |> Acp.publish() |> prepare(id)
    assert {:ok, %{"prepared" => true}} = ctx.reply
    Acp.add_registry_instance(id, id)
    ctx
  end

  step "its command was since replaced by a link to a file outside the install folder", context do
    exe = installed(context)
    File.rm!(exe)
    File.ln_s!("/bin/true", exe)
    context
  end

  step "a thread starts a session with {string}", %{args: [_]} = context do
    ctx = run_on_acme(context, "hello")
    Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the session fails with {string}", %{args: [message]} = context do
    assert [%{"status" => "failed"}] = Acp.runs(thread(context))

    session = HalC2.StreamState.list(Acp.stream(thread(context)), "provider-session")
    assert Enum.any?(session, &((&1["lastError"] || "") =~ message))
    context
  end

  step "{string} is not started", %{args: [id]} = context do
    assert Acp.launches(context, id) == []
    context
  end

  step "nothing is installed for {string}", %{args: [id]} = context do
    ctx = Acp.ready(context)
    refute File.dir?(tools(ctx, id))
    ctx
  end

  step "the uninstall succeeds and nothing changes", context do
    assert {:ok, %{"removed" => false}} = context.reply
    context
  end

  step "a client prepared {string} and no instance of {string} was added",
       %{args: [id, _]} = context do
    ctx = context |> Acp.publish() |> prepare(id)
    assert {:ok, %{"prepared" => true}} = ctx.reply
    refute get_in(HalC2.Settings.settings(), ["providerInstances", id])
    ctx
  end

  step "30 seconds pass and the MC is asked to uninstall {string}", %{args: [id]} = context do
    # The client-side grace period is over: it asks the MC now.
    {reply, ctx} =
      World.call(
        ops(context),
        "server.uninstallAcpRegistryManagedBinary",
        %{"agentId" => id},
        "ops"
      )

    Map.put(ctx, :reply, reply)
  end

  step "the uninstall reports that nothing was removed", context do
    assert {:ok, %{"removed" => false}} = context.reply
    context
  end

  step "the downloaded files for {string} are kept", %{args: [_]} = context do
    assert File.regular?(installed(context))
    context
  end

  step "the MC is asked to uninstall an agent id that is not a valid registry id", context do
    {reply, ctx} =
      World.call(
        ops(context),
        "server.uninstallAcpRegistryManagedBinary",
        %{"agentId" => "../bad id"},
        "ops"
      )

    Map.put(ctx, :reply, reply)
  end

  step "the uninstall fails with {string}", %{args: [message]} = context do
    assert %{"message" => ^message} = operation_error(context.reply)
    context
  end

  # --- packages -----------------------------------------------------------------

  step "the package is installed at its exact version under the MC's tools folder", context do
    assert {:ok, %{"prepared" => true, "distribution" => "npx"}} = context.reply
    [call] = manager_calls(context, "npm")
    assert call["args"] == ["install", "--global", "@acme/agent@2.0.0"]
    assert call["prefix"] == Path.join([tools(context), "2.0.0", "npm"])
    assert File.regular?(Path.join([tools(context), "2.0.0", "npm", "bin", "agent"]))
    context
  end

  step "the machine's own global packages are not changed", context do
    # npm was told to install under the MC's prefix, never its own global one.
    assert Enum.all?(
             manager_calls(context, "npm"),
             &String.starts_with?(&1["prefix"], tools(context))
           )

    context
  end

  step "the package of {string} is already installed at the registry's version",
       %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", npx("@acme/agent@2.0.0"))])
    ctx = ctx |> fake_managers() |> prepare_agent(id)
    assert {:ok, %{"prepared" => true}} = ctx.reply
    Map.put(ctx, :npm_before, length(manager_calls(ctx, "npm")))
  end

  step "the existing install is used and nothing is downloaded", context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert length(manager_calls(context, "npm")) == context.npm_before
    context
  end

  step "the registry publishes {string} as a binary and npx", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    base = Acp.acme_agent(ctx, id: id)
    dist = Map.put(base["distribution"], "npx", %{"package" => "@acme/agent@2.0.0"})
    Acp.publish(ctx, [%{base | "distribution" => dist}])
  end

  step "the registry publishes {string} as npx and uvx", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)

    Acp.publish(ctx, [
      agent(ctx, id, "Acme", %{
        "npx" => %{"package" => "@acme/agent@2.0.0"},
        "uvx" => %{"package" => "acme==2.0.0"}
      })
    ])
  end

  step "the registry publishes {string} as uvx only", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", %{"uvx" => %{"package" => "acme==2.0.0"}})])
  end

  step "the registry publishes {string} as a binary only", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [Acp.acme_agent(ctx, id: id)])
  end

  step "the instance prefers automatic", context do
    Map.put(context, :dist_pref, "auto")
  end

  step "the instance prefers npx", context do
    Map.put(context, :dist_pref, "npx")
  end

  step "{string} is installed from the binary", %{args: [_]} = context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert File.regular?(installed(context))
    assert manager_calls(context, "npm") == []
    context
  end

  step "{string} runs through npx", %{args: [id]} = context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert {:ok, [exe | _], _env} = HalC2.Acp.Catalog.command(%{"agentId" => id})
    assert exe =~ "/npm/bin/"
    context
  end

  step "{string} runs through uvx", %{args: [id]} = context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert {:ok, [exe | _], _env} = HalC2.Acp.Catalog.command(%{"agentId" => id})
    assert exe =~ "/python/bin/"
    context
  end

  step "{string} is refused for having no npx distribution for this machine",
       %{args: [_]} = context do
    assert %{"reason" => "unsupported_platform"} = operation_error(context.reply)
    context
  end

  step "the registry agent {string} runs through npx as {string}",
       %{args: [id, package]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", npx(package))])
  end

  step "npm exits with code 1 and prints {string} while the MC prepares {string}",
       %{args: [output, id]} = context do
    context
    |> manager_control("npm-control.json", %{"exit" => 1, "output" => output})
    |> prepare_agent(id)
  end

  step "npm cannot be started while the MC prepares {string}", %{args: [id]} = context do
    ctx = fake_managers(context)
    npm = Path.join(ctx.fake_managers, "npm")
    File.write!(npm, "#!/nonexistent/interpreter\necho never\n")
    File.chmod!(npm, 0o755)
    prepare_agent(ctx, id)
  end

  step "npm installs the package but exposes no usable command while the MC prepares {string}",
       %{args: [id]} = context do
    context |> manager_control("npm-control.json", %{"bin" => %{}}) |> prepare_agent(id)
  end

  step "preparing {string} fails with {string}", %{args: [_id, message]} = context do
    error = operation_error(context.reply)
    # The scenario names npm's usual path; the MC names the one on its path.
    npm = System.find_executable("npm")
    assert String.replace(error["message"], npm, "/usr/bin/npm") == message
    context
  end

  defp npm_bins(ctx, bins) do
    ctx = Acp.serve_registry(ctx)
    Acp.publish(ctx, [agent(ctx, "acme", "Acme", npx("@acme/acme-acp@1.2.0"))])
    ctx = manager_control(ctx, "npm-control.json", %{"bin" => bins})
    Map.put(ctx, :pkg_agent, "acme")
  end

  step "the npm package {string} of the registry agent {string} publishes one command {string}",
       %{args: [_, _, command]} = context do
    npm_bins(context, %{command => "index.js"})
  end

  step "the npm package {string} of the registry agent {string} publishes the commands {string} and {string}",
       %{args: [_, _, first, second]} = context do
    npm_bins(context, %{first => "#{first}.js", second => "#{second}.js"})
  end

  step "the npm package {string} of the registry agent {string} publishes two other names that both lead to the same file",
       %{args: [_, _]} = context do
    context
    |> npm_bins(%{"beta" => "same.js", "alpha" => "same.js"})
    |> Map.put(:expected_command, "alpha")
  end

  step "the npm package {string} of the registry agent {string} publishes two other names that lead to different files",
       %{args: [_, _]} = context do
    npm_bins(context, %{"beta" => "beta.js", "alpha" => "alpha.js"})
  end

  defp assert_command_runs(context, command) do
    assert {:ok, %{"prepared" => true}} = context.reply
    Acp.add_registry_instance(context.pkg_agent, context.pkg_agent)
    ctx = Acp.launch(context, "Pkg", context.pkg_agent, "hello")
    ctx = Map.put(ctx, :thread, "Pkg")
    Acp.await_runs(thread(ctx), 1)
    assert Acp.assistant_text(thread(ctx)) =~ "Hello from acme"
    launch = Enum.find(Acp.launches(ctx, "acme"), &(&1["cwd"] == World.project(ctx).root))
    assert Path.basename(launch["argv0"]) == command
    ctx
  end

  step "{string} is the command that runs the agent", %{args: [command]} = context do
    assert_command_runs(context, command)
  end

  step "the first of them by name runs the agent", context do
    assert_command_runs(context, context.expected_command)
  end

  step "preparing fails because no command can be told apart", context do
    assert %{"message" => message} = operation_error(context.reply)

    assert message ==
             "ACP Registry installed @acme/acme-acp@1.2.0, but could not resolve its global command."

    context
  end

  step "the uv tool {string} of the registry agent {string} exposes the command {string}",
       %{args: [tool, id, command]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", %{"uvx" => %{"package" => "#{tool}==1.2.0"}})])
    ctx = manager_control(ctx, "uv-control.json", %{"commands" => [command]})
    # The fake agent logs under the name its wrapper was made for.
    Map.merge(ctx, %{pkg_agent: id})
  end

  step "the package of {string} was installed at the registry's version",
       %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", npx("@acme/agent@2.0.0"))])
    ctx = ctx |> fake_managers() |> prepare_agent(id)
    assert {:ok, %{"prepared" => true}} = ctx.reply
    Map.put(ctx, :npm_before, length(manager_calls(ctx, "npm")))
  end

  step "its command was since deleted", context do
    [exe] = Path.wildcard(Path.join([tools(context), "**", "npm", "bin", "*"]))
    File.rm!(exe)
    context
  end

  step "its package was replaced by another version", context do
    [manifest] =
      Path.wildcard(
        Path.join([tools(context), "**", "npm", "lib", "node_modules", "**", "package.json"])
      )

    manifest
    |> File.read!()
    |> JSON.decode!()
    |> Map.put("version", "0.0.1")
    |> JSON.encode!()
    |> then(&File.write!(manifest, &1))

    context
  end

  step "the package is installed again at the registry's exact version", context do
    assert {:ok, %{"prepared" => true}} = context.reply
    calls = manager_calls(context, "npm")
    assert length(calls) == context.npm_before + 1
    assert List.last(calls)["args"] == ["install", "--global", "@acme/agent@2.0.0"]
    context
  end

  step "npm on the MC is set to install global packages into a folder the MC may not write",
       context do
    previous = System.get_env("npm_config_prefix")
    System.put_env("npm_config_prefix", "/usr/lib/node_modules")

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: System.put_env("npm_config_prefix", previous),
        else: System.delete_env("npm_config_prefix")
    end)

    context
  end

  step "the MC prepares the npx agent {string}", %{args: [id]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", npx("@acme/agent@2.0.0"))])
    prepare_agent(ctx, id)
  end

  step "{string} is installed under the MC's tools folder all the same", %{args: [_]} = context do
    assert {:ok, %{"prepared" => true}} = context.reply
    [call] = manager_calls(context, "npm")
    assert String.starts_with?(call["prefix"], tools(context))
    assert File.regular?(Path.join([tools(context), "2.0.0", "npm", "bin", "agent"]))
    context
  end

  defp rogue_command(ctx, name) do
    dir = Path.join(ctx.mc.home, "rogue-bin")
    File.mkdir_p!(dir)
    marker = Path.join(ctx.mc.home, "rogue-ran")
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\ntouch #{marker}\nexit 1\n")
    File.chmod!(path, 0o755)
    System.put_env("PATH", dir <> ":" <> (System.get_env("PATH") || ""))
    Map.merge(ctx, %{rogue: path, rogue_marker: marker})
  end

  step "a command named like the binary of {string} is on the MC's path",
       %{args: [id]} = context do
    context |> Acp.publish() |> rogue_command(id)
  end

  step "the registry's binary is downloaded and used", context do
    assert {:ok, %{"prepared" => true}} = context.reply
    assert File.regular?(installed(context))
    assert {:ok, [exe | _], _env} = HalC2.Acp.Catalog.command(%{"agentId" => "acme"})
    assert exe == installed(context)
    refute File.exists?(context.rogue_marker)
    context
  end

  step "only an executable override makes the MC run a local copy", context do
    assert {:ok, [exe | _], _env} =
             HalC2.Acp.Catalog.command(%{"agentId" => "acme", "commandPath" => context.rogue})

    assert exe == context.rogue
    context
  end

  step "the instance of {string} has the executable override {string}",
       %{args: [id, override]} = context do
    ctx = Acp.publish(context)

    Acp.add_registry_instance(id, id, %{
      "config" => %{"agentId" => id, "commandPath" => override}
    })

    Map.put(ctx, :auth_instance, id)
  end

  step "{string} is not on the instance's path", %{args: [name]} = context do
    assert System.find_executable(name) == nil
    context
  end

  step "{string} was installed as a binary and {string} through npx",
       %{args: [binary_id, package_id]} = context do
    ctx = Acp.serve_registry(context)

    Acp.publish(ctx, [
      Acp.acme_agent(ctx, id: binary_id),
      agent(ctx, package_id, "Beta", npx("@acme/beta@1.0.0"))
    ])

    ctx = prepare_agent(ctx, binary_id)
    assert {:ok, %{"prepared" => true}} = ctx.reply
    ctx = prepare_agent(ctx, package_id)
    assert {:ok, %{"prepared" => true}} = ctx.reply
    ctx
  end

  step "the MC uninstalls both", context do
    ctx =
      Enum.reduce(["acme", "beta"], ops(context), fn id, ctx ->
        {reply, ctx} =
          World.call(ctx, "server.uninstallAcpRegistryManagedBinary", %{"agentId" => id}, "ops")

        assert {:ok, _} = reply
        ctx
      end)

    ctx
  end

  step "the downloaded files of {string} are removed", %{args: [id]} = context do
    assert Path.wildcard(Path.join([tools(context, id), "**", "bin", id])) == []
    context
  end

  step "the package of {string} is kept", %{args: [id]} = context do
    assert Path.wildcard(Path.join([tools(context, id), "**", "npm", "bin", "*"])) != []
    context
  end

  step "an instance of {string} exists and the MC holds no cached copy of the registry",
       %{args: [id]} = context do
    ctx = Acp.publish(context)
    Acp.add_registry_instance(id, id)
    refute File.exists?(HalC2.Acp.Catalog.cache_path())
    ctx
  end

  step "the registry is fetched before {string} is started", %{args: [id]} = context do
    assert Acp.assistant_text(thread(context)) =~ "Hello from acme"
    requests = Acp.registry_requests(context)
    fetched_at = Enum.find_index(requests, &(&1 == "registry.json"))
    downloaded_at = Enum.find_index(requests, &(&1 == "#{id}.tar.gz"))
    assert fetched_at != nil and downloaded_at != nil and fetched_at < downloaded_at
    context
  end

  step "the registry agent {string} runs through npx and another {string} command is on the MC's path",
       %{args: [id, _]} = context do
    ctx = Acp.serve_registry(context)
    Acp.publish(ctx, [agent(ctx, id, "Acme", npx("acme@2.0.0"))])
    ctx = Acp.control(ctx, "acme", %{"logEnv" => ["PATH"]})
    ctx = fake_managers(ctx)
    ctx = rogue_command(ctx, "acme")
    Acp.add_registry_instance(id, id)
    ctx
  end

  step "the command the MC installed is the one that runs", context do
    assert Acp.assistant_text(thread(context)) =~ "Hello from acme"
    launch = Enum.find(Acp.launches(context, "acme"), &(&1["cwd"] == World.project(context).root))
    assert launch["argv0"] =~ "/npm/bin/acme"
    refute File.exists?(context.rogue_marker)
    Map.put(context, :launch, launch)
  end

  step "the folder it was installed into comes first on the agent's path", context do
    launch = context.launch
    assert hd(String.split(launch["env"]["PATH"], ":")) == Path.dirname(launch["argv0"])
    context
  end

  # --- URL sign-in outside a sign-in flow ----------------------------------------

  defp ask_url(context, prompt, response_id) do
    ctx = context |> acme() |> watch_providers() |> run_on_acme(prompt)
    Acp.await_runs(thread(ctx), 1)
    Map.put(ctx, :url_response, response_id)
  end

  step "{string} asks the user to open a sign-in address that is not http or https",
       %{args: [_]} = context do
    ask_url(context, "open bad url", "url-bad")
  end

  step "{string} asks the user to open a sign-in address with an empty request id",
       %{args: [_]} = context do
    ask_url(context, "open anonymous url", "url-anon")
  end

  step "the request is declined without being shown to the user", context do
    # A later turn makes the agent read the decline before it answers again.
    Acp.follow_up(context, context.thread, "hello again")
    Acp.await_runs(thread(context), 2)

    assert Enum.any?(
             Acp.log(context, "acme"),
             &(&1["id"] == context.url_response and &1["result"] == %{"action" => "decline"})
           )

    assert HalC2.Acp.UrlAuth.action("acme") == nil
    context
  end

  step "ten minutes pass", context do
    action = HalC2.Acp.UrlAuth.action("acme")
    {:ok, created, _} = DateTime.from_iso8601(action["createdAt"])
    {:ok, expires, _} = DateTime.from_iso8601(action["expiresAt"])
    assert DateTime.diff(expires, created, :second) == 600
    send(Process.whereis(HalC2.Acp.UrlAuth), {:expire, "acme", action["elicitationId"]})
    Map.put(context, :expired_id, action["elicitationId"])
  end

  step "the request is declined and cleared on every client", context do
    {entry, ctx} = await_acme(context, &(get_in(&1, ["auth", "action"]) == nil))
    refute entry["auth"]["action"]
    # A later turn makes the agent read the decline before it answers again.
    Acp.follow_up(ctx, ctx.thread, "hello again")
    Acp.await_runs(thread(ctx), 2)

    assert Enum.any?(
             Acp.log(ctx, "acme"),
             &(&1["id"] == "url-one" and &1["result"] == %{"action" => "decline"})
           )

    ctx
  end

  step "accepting it afterwards is refused", context do
    {reply, ctx} =
      World.call!(context, "server.acceptAcpRegistryUrlAuth", %{
        "instanceId" => "acme",
        "elicitationId" => context.expired_id
      })

    assert reply == %{"accepted" => false}
    ctx
  end

  step "{string} asks the user to open a sign-in address with a message longer than 1,024 characters",
       %{args: [_]} = context do
    ctx = context |> acme() |> watch_providers() |> run_on_acme("open long url")
    Acp.await_runs(thread(ctx), 1)
    {entry, ctx} = await_acme(ctx, &(get_in(&1, ["auth", "action"]) != nil))
    Map.put(ctx, :url_action, entry["auth"]["action"])
  end

  step "the clients are offered the address with the first 1,024 characters of the message",
       context do
    assert context.url_action["url"] == "https://acme.test/long"
    assert context.url_action["message"] == String.duplicate("m", 1024)
    context
  end

  step "a request id longer than 256 characters is cut to 256", context do
    assert context.url_action["elicitationId"] == String.duplicate("x", 256)
    context
  end
end
