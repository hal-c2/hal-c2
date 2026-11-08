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
    cond do
      context[:refused_sign_in] ->
        {{state, ctx}, log} =
          ExUnit.CaptureLog.with_log(fn ->
            ctx = start_sign_in(context, "acme-login")
            # The browser step, where there is one: the session after it is refused.
            ctx = accept_browser(ctx)
            await_phase(ctx, "failed")
          end)

        Map.merge(ctx, %{told: state["message"], log: log})

      id == "acme" ->
        ctx = start_sign_in(context, "acme-terminal")
        {state, ctx} = await_phase(ctx, "waiting", terminal_shows?("Paste code: "))
        Map.put(ctx, :interaction, state["interaction"])

      true ->
        HalC2.Steps.Providers.Cursor.sign_in_to(context, id)
    end
  end

  # Accepts the browser sign-in the agent asks for; a sign-in it refuses asks none.
  defp accept_browser(%{refused_sign_in: :session} = ctx) do
    {state, ctx} =
      await_phase(ctx, "waiting", &(get_in(&1, ["interaction", "type"]) == "browser"))

    respond(ctx, state["interaction"], %{"type" => "browser", "action" => "accept"})
  end

  defp accept_browser(ctx), do: ctx

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

  # --- how an agent ends -----------------------------------------------------------------

  defp session_error(ctx) do
    ctx
    |> thread()
    |> Acp.stream()
    |> HalC2.StreamState.list("provider-session")
    |> Enum.map(& &1["lastError"])
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp logged_event(ctx, event) do
    Acp.await_stream(thread(ctx), fn _ ->
      Enum.find(Acp.log(ctx, "acme"), &(&1["event"] == event))
    end)
  end

  step "the MC is waiting on {string} for an answer", %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("close output")
    Acp.await_stream(thread(ctx), fn _ -> Acp.requests(ctx, "acme", "session/prompt") != [] end)
    ctx
  end

  step "{string} closes its output and keeps running", %{args: [_]} = context do
    # The fake sleeps on after closing it, deaf to its input, until it is signalled.
    closed = logged_event(context, "closed")
    Map.put(context, :closed_at, closed["at"])
  end

  step "within a quarter of a second the request fails saying the agent's input ended",
       context do
    assert [%{"status" => "failed", "completedAt" => at}] = Acp.await_runs(thread(context), 1)
    {:ok, at, _} = DateTime.from_iso8601(at)
    waited = DateTime.to_unix(at, :microsecond) / 1_000_000 - context.closed_at
    assert waited < 0.25, "the request failed #{waited}s after the agent closed its output"
    assert session_error(context) == "ACP input stream ended."
    context
  end

  step "the next message to {string} starts it afresh instead of waiting on the closed one",
       %{args: [_]} = context do
    Acp.follow_up(context, context.thread, "hello")
    assert [_, %{"status" => "completed"}] = Acp.await_runs(thread(context), 2)
    assert length(Acp.launches(context, "acme")) == 2
    context
  end

  step "the agent process exits with an error", context do
    # 5,000 characters, the first line beyond the last 4,096.
    lines = for n <- 1..250, do: "acme error line #{String.pad_leading("#{n}", 4, "0")}"
    text = Enum.join(lines, "\n")
    File.write!(Path.join(Acp.dir(context), "acme.stderr"), text)
    [%{"pid" => pid} | _] = Acp.launches(context, "acme")
    {_, 0} = System.cmd("kill", ["-USR1", "#{pid}"])
    Map.put(context, :stderr, text)
  end

  step "the turn fails naming the exit code and the end of what the agent wrote to its error output, 4,096 characters in all",
       context do
    assert [%{"status" => "failed"}] = Acp.await_runs(thread(context), 1)
    message = session_error(context)
    exit = "ACP process exited with code 3\n"
    assert String.length(message) == 4_096

    tail =
      String.slice(
        context.stderr,
        String.length(context.stderr) - 4_096 + String.length(exit),
        4_096
      )

    assert message == exit <> tail
    context
  end

  step "requests still waiting on the agent fail instead of hanging", context do
    state = Acp.stream(thread(context))
    refute Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))

    refute Enum.any?(
             HalC2.StreamState.list(state, "provider-session"),
             &(&1["status"] == "running")
           )

    context
  end

  # The fake writes `text` to its error output and exits with code 1 on its turn.
  defp crash_with(ctx, text) do
    ctx = ctx |> World.capture_log() |> acme(%{"stderr" => text, "exitCode" => 1})
    ctx = run_on_acme(ctx, "crash")
    assert [%{"status" => "failed"}] = Acp.await_runs(thread(ctx), 1)
    Map.put(ctx, :stderr, text)
  end

  defp home, do: System.get_env("HOME") || System.user_home()

  step "the error output of {string} contains a path under the user's home directory",
       %{args: [_]} = context do
    crash_with(context, "cannot read #{home()}/work/acme/config.toml: permission denied")
  end

  step "the error output of {string} contains a HAL-C2 pairing link", %{args: [_]} = context do
    crash_with(context, "pair with https://mc.example:3773/pair#token=pairsecret123 to go on")
  end

  step "the error output of {string} contains a bearer or basic authorization value",
       %{args: [_]} = context do
    crash_with(
      context,
      "request failed: Authorization: Bearer bearersecret.123\nAuthorization: Basic YmFzaWNzZWNyZXQ="
    )
  end

  step "the error output of {string} contains an API key header or a token that looks like a provider key",
       %{args: [_]} = context do
    crash_with(
      context,
      "x-api-key: headersecret42\ntokens ghp_ghsecret42 and sk-abcdefgh12345 and xoxb-slack-secret"
    )
  end

  step "the error output of {string} contains {string}", %{args: [_, key]} = context do
    crash_with(context, "upstream refused the key #{key}: 401")
  end

  step "the failure shows the path starting at {string}", %{args: ["~"]} = context do
    message = session_error(context)
    assert message =~ "cannot read ~/work/acme/config.toml"
    refute message =~ home()
    context
  end

  step "the failure shows {string} in place of the link", %{args: [shown]} = context do
    message = session_error(context)
    assert message =~ shown
    refute message =~ "pairsecret123"
    context
  end

  step "the failure shows {string} in place of the value", %{args: [shown]} = context do
    message = session_error(context)
    assert message =~ shown

    for secret <-
          ~w(bearersecret YmFzaWNzZWNyZXQ headersecret42 ghsecret42 abcdefgh12345 slack-secret),
        do: refute(message =~ secret)

    context
  end

  step "the failure and the MC's log show {string} in place of the whole key",
       %{args: [shown]} = context do
    [_, key] = Regex.run(~r/the key (\S+):/, context.stderr)
    [_, after_underscore] = String.split(key, "_", parts: 2)

    for text <- [session_error(context), World.logged(context)] do
      assert text =~ "the key #{shown}: 401"
      refute text =~ after_underscore
    end

    context
  end

  # --- one instance's sign-in --------------------------------------------------------

  # The second instance runs its own fake ("acme-two"), with its own sign-in on disk.
  step "two instances of {string}", %{args: ["acme"]} = context do
    ctx = signed_out_acme(context, [@browser])
    Acp.run_as(ctx, "acme-two", "acme-two")
    Acp.control(ctx, "acme-two", %{"auth" => "file", "methods" => [@browser]})
    Acp.add_registry_instance("acme-two", "acme")
    assert Acp.check("acme-two")["auth"]["status"] == "unauthenticated"
    ctx
  end

  step "the user signs in to the first from HAL-C2", context do
    ctx = start_sign_in(context, "acme-login")
    {state, ctx} = await_phase(ctx, "waiting")
    ctx = respond(ctx, state["interaction"], %{"type" => "browser", "action" => "accept"})
    {_, ctx} = await_phase(ctx, "succeeded")
    assert Acp.check("acme")["auth"]["status"] == "authenticated"
    ctx
  end

  step "the second is not shown as signed in", context do
    assert Acp.provider("acme-two")["auth"]["status"] == "unauthenticated"
    # Nor once it is checked: its own agent is still signed out.
    assert Acp.check("acme-two")["auth"]["status"] == "unauthenticated"
    context
  end

  @secret_key "sk-acme-0123456789-secret"

  step "an instance of {string} with a secret environment variable",
       %{args: ["acme"]} = context do
    ctx = acme(context, %{"auth" => "env:ACME_API_KEY", "methods" => [@api_key]})

    Acp.write_settings(ctx, fn settings ->
      put_in(settings, ["providerInstances", "acme", "environment"], [
        %{"name" => "ACME_API_KEY", "value" => @secret_key, "sensitive" => true}
      ])
    end)
  end

  step "the user signs in to it from HAL-C2", context do
    ctx = start_sign_in(context, "acme-key")
    {_, ctx} = await_phase(ctx, "succeeded")
    assert %{"env" => %{"ACME_API_KEY" => @secret_key}} = List.last(Acp.launches(ctx, "acme"))
    ctx
  end

  # The MC keeps no record of a sign-in: whether "acme" is signed in is asked of the
  # agent. Only the secret store holds the value, where the instance's settings put it
  # (the fake agents' own files are theirs, not the MC's).
  step "what the MC keeps on disk about the sign-in does not contain the variable's value",
       context do
    assert Acp.check("acme")["auth"]["status"] == "authenticated"
    secrets = Path.join(HalC2.Paths.data_dir(), "secrets")

    holding =
      for path <- Path.wildcard(Path.join(context.mc.home, "**"), match_dot: true),
          File.regular?(path),
          not String.starts_with?(path, secrets <> "/"),
          not String.starts_with?(path, Acp.dir(context) <> "/"),
          File.read!(path) =~ @secret_key,
          do: Path.relative_to(path, context.mc.home)

    assert holding == []
    context
  end

  # --- models the account is not offered -----------------------------------------------

  defp session_error_of(thread_id) do
    thread_id
    |> Acp.stream()
    |> HalC2.StreamState.list("provider-session")
    |> Enum.map(& &1["lastError"])
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  # The user's own prompts to "acme", without title generation's.
  defp user_prompts(ctx), do: user_prompts_of(ctx, "acme")

  defp add_custom_model(ctx, slug) do
    Acp.write_settings(
      ctx,
      &update_in(&1, ["providerInstances", "acme"], fn instance ->
        config = instance["config"] || %{}
        Map.put(instance, "config", Map.put(config, "customModels", [slug]))
      end),
      "ops"
    )
  end

  defp refused?(thread_id, model) do
    assert [%{"status" => "failed"}] = Acp.await_runs(thread_id, 1)
    assert session_error_of(thread_id) =~ "the model #{model} is not available to this account"
    true
  end

  step "the thread is set to the model {string}", %{args: [model]} = context do
    Map.put(context, :pending_launch, %{instance: "acme", fields: %{"model" => model}})
  end

  step "{string} offers only {string} to the signed-in account",
       %{args: [_, model]} = context do
    acme(context, %{"models" => [[model, "Lite"]]})
  end

  step "the turn does not start and the thread says {string} is not available",
       %{args: [model]} = context do
    assert refused?(thread(context), model)
    assert user_prompts(context) == []

    refute Enum.any?(
             Acp.requests(context, "acme", "session/set_config_option"),
             &(&1["params"]["value"] == model)
           )

    context
  end

  step "a thread on the agent's default model still runs on whatever the agent picks",
       context do
    ctx = Acp.launch(context, "Default", "acme", "which model")
    assert [%{"status" => "completed"}] = Acp.await_runs(ctx.threads["Default"], 1)
    assert Acp.assistant_text(ctx.threads["Default"]) =~ "model: acme-lite"
    ctx
  end

  step "{string} does not advertise the model {string}", %{args: [_, model]} = context do
    ctx = acme(context)
    refute Enum.any?(Acp.check("acme")["models"], &(&1["slug"] == model))
    ctx
  end

  step "the user added {string} as a custom model", %{args: [slug]} = context do
    add_custom_model(context, slug)
  end

  step "the user sends a message with {string}", %{args: [model]} = context do
    run_on_acme(context, "which model", model: model)
  end

  step "the session opens and {string} is asked to use {string}",
       %{args: [_, model]} = context do
    assert [%{"status" => "completed"}] = Acp.await_runs(thread(context), 1)
    assert Acp.assistant_text(thread(context)) =~ "model: #{model}"

    assert %{"params" => %{"configId" => "model", "value" => ^model}} =
             List.last(Acp.requests(context, "acme", "session/set_config_option"))

    context
  end

  step "a model id that is neither advertised nor added is still refused", context do
    ctx = Acp.launch(context, "Other", "acme", "hello", model: "acme-free/other")
    assert refused?(ctx.threads["Other"], "acme-free/other")
    ctx
  end

  # --- Copilot ------------------------------------------------------------------------

  # The registry instance "copilot" (GitHub Copilot CLI), run as the fake agent "copilot".
  defp copilot(ctx, control \\ %{}) do
    ctx = ctx |> ops() |> Acp.serve_registry()
    ctx = Acp.publish(ctx, [Acp.acme_agent(ctx), Acp.acme_agent(ctx, id: "github-copilot-cli")])
    Acp.run_as(ctx, "copilot", "copilot")
    Acp.control(ctx, "copilot", control)
    Acp.add_registry_instance("copilot", "github-copilot-cli")
    ctx
  end

  # The id of the thread's running run, once one runs.
  defp running?(thread_id) do
    Acp.await_stream(thread_id, fn state ->
      Enum.find_value(
        HalC2.StreamState.list(state, "run"),
        &(&1["status"] == "running" && &1["id"])
      )
    end)
  end

  defp user_prompts_of(ctx, name) do
    for %{"params" => %{"prompt" => prompt}} <- Acp.requests(ctx, name, "session/prompt"),
        not Enum.any?(prompt, &((&1["text"] || "") =~ "Return a JSON object")),
        do: prompt
  end

  step "Copilot CLI runs over ACP and a Copilot background agent is still working in the thread",
       context do
    ctx = context |> copilot() |> Acp.launch("Copilot", "copilot", "start a background agent")
    ctx = Map.merge(ctx, %{thread: "Copilot", send_message: &send_auto/2})
    running?(thread(ctx))

    Acp.await_stream(thread(ctx), fn _ -> Acp.requests(ctx, "copilot", "session/prompt") != [] end)

    ctx
  end

  # As the composer sends it: the MC picks how the message goes. The shared step
  # "the user sends {string}" calls this through `context.send_message`.
  defp send_auto(context, text) do
    message = "msg-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(context),
        "messageId" => message,
        "text" => text,
        "attachments" => [],
        "deliveryIntent" => "auto",
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    Map.put(context, :followup, text)
  end

  step "the message waits in the thread's queue and the background agent keeps running",
       context do
    Acp.await_stream(thread(context), fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "queued"))
    end)

    assert Acp.requests(context, "copilot", "session/cancel") == []
    assert length(Acp.launches(context, "copilot")) == 1
    assert [_] = user_prompts_of(context, "copilot")
    context
  end

  step "the message is sent once Copilot's current prompt finishes", context do
    [%{"pid" => pid}] = Acp.launches(context, "copilot")
    {_, 0} = System.cmd("kill", ["-USR2", "#{pid}"])

    assert [%{"status" => "completed"}, %{"status" => "completed"}] =
             Acp.await_runs(thread(context), 2)

    assert [_, followup] = user_prompts_of(context, "copilot")
    assert Enum.any?(followup, &((&1["text"] || "") =~ context.followup))
    assert Acp.requests(context, "copilot", "session/cancel") == []
    context
  end

  step "Stop still stops the turn, while a restart from an agent's send is refused as not supported",
       context do
    Acp.follow_up(context, context.thread, "wait")
    active = running?(thread(context))

    assert {:error, refusal} =
             HalC2.Orchestration.dispatch(%{
               "type" => "message.dispatch",
               "commandId" => "cmd-#{System.unique_integer([:positive])}",
               "threadId" => thread(context),
               "messageId" => "msg-#{System.unique_integer([:positive])}",
               "text" => "start over",
               "attachments" => [],
               "dispatchMode" => %{"type" => "restart_active", "targetRunId" => active},
               "createdBy" => "agent",
               "creationSource" => "mcp"
             })

    assert refusal =~ "cannot redirect an active run"
    assert Acp.requests(context, "copilot", "session/cancel") == []

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(context)
      })

    assert [_, _, %{"status" => status}] = Acp.await_runs(thread(context), 3)
    assert status in ["interrupted", "cancelled"]
    assert [_] = Acp.requests(context, "copilot", "session/cancel")
    context
  end

  # --- Stopping only what the agent started ---------------------------------------------

  # Started outside the session, in a session of its own and without the agent's mark,
  # it notes each signal it gets in `log`. No pid can be made to reuse another, so it
  # stands for the program that took the exited helper's pid: what spares it is that
  # the MC signals only the agent's own group and the processes carrying its mark.
  @unrelated ~S"""
  import signal, sys, time
  log = sys.argv[1]
  def note(n, _):
      open(log, "a").write("%d\n" % n)
  for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2):
      signal.signal(s, note)
  open(log, "a").close()
  open(sys.argv[2], "w").write("ready\n")
  while True:
      time.sleep(1)
  """

  defp pgid(pid) do
    [_, rest] = String.split(File.read!("/proc/#{pid}/stat"), ") ", parts: 2)
    rest |> String.split(" ") |> Enum.at(2) |> String.to_integer()
  end

  defp end_session(context) do
    :ok = HalC2.Orchestration.release_session(thread(context))
    context
  end

  step "a helper of {string} exited and its process id was reused by an unrelated program",
       context do
    ctx = context |> acme() |> Acp.launch("Helper", "acme", "start a helper")
    ctx = Map.merge(ctx, %{thread: "Helper", end_session: &end_session/1})
    assert [%{"status" => "completed"}] = Acp.await_runs(thread(ctx), 1)
    [helper] = Enum.filter(Acp.log(ctx, "acme"), &(&1["event"] == "helper"))
    refute File.exists?("/proc/#{helper["pid"]}")

    script = Path.join(Acp.dir(ctx), "unrelated.py")
    log = Path.join(Acp.dir(ctx), "unrelated.signals")
    File.write!(script, @unrelated)

    ready = Path.join(Acp.dir(ctx), "unrelated.ready")
    File.rm(ready)

    # The fifo's read returns once the program's handlers are in place.
    {out, 0} =
      System.cmd("sh", [
        "-c",
        ~S(mkfifo "$2" && { setsid python3 "$0" "$1" "$2" </dev/null >/dev/null 2>&1 & echo $!; } && read _ < "$2"),
        script,
        log,
        ready
      ])

    unrelated = out |> String.trim() |> String.to_integer()
    on_exit_kill(unrelated)
    Map.merge(ctx, %{helper: helper, unrelated: unrelated, unrelated_log: log})
  end

  defp on_exit_kill(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end)
  end

  step "the unrelated program is not signalled", context do
    [%{"pid" => agent}] = Acp.launches(context, "acme")
    refute File.exists?("/proc/#{agent}")
    assert File.exists?("/proc/#{context.unrelated}")
    assert File.read!(context.unrelated_log) == ""
    context
  end

  step "neither the MC's own processes nor the system's first process are ever signalled",
       context do
    # The stop signals the agent's group and the processes carrying its mark: a group
    # that were the MC's own, or 1, would take the MC or the whole machine with it.
    group = context.helper["pgid"]
    refute group in [1, pgid(System.pid()), String.to_integer(System.pid())]
    System.cmd("kill", ["-KILL", "#{context.unrelated}"])
    context
  end

  # --- what an agent reports --------------------------------------------------------------

  step "{string} reports more than 64 model providers", %{args: [_]} = context do
    providers =
      for i <- 1..70,
          do: %{
            "providerId" => "p#{i}",
            "supported" => ["openai"],
            "required" => false,
            "current" => %{"apiType" => "openai", "baseUrl" => "https://p#{i}.acme.test/v1"}
          }

    acme(context, %{"providers" => providers})
  end

  step "the user lists its model providers", context do
    {providers, ctx} = model_providers(context)
    Map.put(ctx, :listed, providers)
  end

  step "the first 64 are listed", context do
    assert Enum.map(context.listed, & &1["providerId"]) == for(i <- 1..64, do: "p#{i}")
    context
  end

  defp offering_review(context, control \\ %{}) do
    ctx =
      context
      |> acme(
        Map.merge(
          %{"commands" => [%{"name" => "review", "description" => "Review the changes"}]},
          control
        )
      )
      |> watch_providers()
      |> run_on_acme("offer commands")

    {entry, ctx} = await_acme(ctx, &(&1["slashCommands"] != []))
    Map.put(ctx, :entry, entry)
  end

  step "a running {string} session offered the command {string}", %{args: [_, _]} = context do
    context |> offering_review() |> Map.put(:no_longer_offered, &command_withdrawn/2)
  end

  step "{string} reports that it now offers no commands", %{args: [_]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread(context)
      })

    Acp.await_runs(thread(context), 1)
    Acp.follow_up(context, context.thread, "withdraw commands")
  end

  # Through the shared step "{string} is no longer offered".
  defp command_withdrawn(context, "/" <> _) do
    {_entry, ctx} = await_acme(context, &(&1["slashCommands"] == []))
    assert [_, %{"status" => "completed"}] = Acp.await_runs(thread(ctx), 2)
    ctx
  end

  step "a running {string} session reported its commands and options", %{args: [_]} = context do
    offering_review(context, %{"modes" => ["ask", "code"]})
  end

  step "another client connects", context do
    asked = length(Acp.log(context, "acme"))
    sub = 3000 + System.unique_integer([:positive])

    client =
      context.mc
      |> Mc.connect()
      |> Mc.sub(sub, %{"type" => "config", "mc" => Atom.to_string(node())})

    {frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == sub))

    context
    |> World.put_client("late", client)
    |> Map.merge(%{late_providers: frame["config"]["providers"], asked: asked})
  end

  step "that client is given the same commands and options without waiting for the agent to report again",
       context do
    late = Enum.find(context.late_providers, &(&1["instanceId"] == "acme"))
    assert late["slashCommands"] == context.entry["slashCommands"]
    assert [%{"name" => "review"}] = late["slashCommands"]
    assert late["models"] == context.entry["models"]
    assert length(Acp.log(context, "acme")) == context.asked
    context
  end

  step "the registry agent {string} is installed", %{args: [_]} = context do
    ctx = acme(context)
    assert Acp.check("acme")["installed"] == true
    ctx
  end

  step "no update is offered for {string}", %{args: [id]} = context do
    entry = Enum.find(context.providers, &(&1["instanceId"] == id))
    assert entry
    refute entry["versionAdvisory"]["canUpdate"] == true
    refute entry["versionAdvisory"]["status"] == "behind_latest"
    refute Map.has_key?(entry, "updateState")
    context
  end

  step "the session of {string} already uses the model {string}", %{args: [_, model]} = context do
    ctx = acme(context, %{"models" => [[model, "Large"], ["acme-small", "Small"]]})
    ctx = run_on_acme(ctx, "which model", model: model)
    assert [%{"status" => "completed"}] = Acp.await_runs(thread(ctx), 1)
    Map.put(ctx, :model, model)
  end

  step "the user picks {string} again", %{args: [model]} = context do
    Acp.follow_up(context, context.thread, "which model", %{
      "modelSelection" => %{"instanceId" => "acme", "model" => model}
    })

    assert [_, %{"status" => "completed"}] = Acp.await_runs(thread(context), 2)
    context
  end

  step "{string} is not asked to change its model", %{args: [_]} = context do
    assert Acp.assistant_text(thread(context)) =~ "model: #{context.model}"

    refute Enum.any?(
             Acp.requests(context, "acme", "session/set_config_option"),
             &(&1["params"]["configId"] == "model")
           )

    refute Acp.requests(context, "acme", "session/set_model") != []
    context
  end

  # --- installing and checking ----------------------------------------------------------

  step "the registry entry for {string} names a command path that leaves the install folder",
       %{args: [id]} = context do
    context
    |> Acp.serve_registry()
    |> with_cmd(id, "../bin/acme")
    |> Map.put(:nothing_downloaded, &no_archive_fetched/1)
  end

  # Through the shared step "nothing is downloaded".
  defp no_archive_fetched(context) do
    assert {:error, _, _} = context.reply
    refute Enum.any?(Acp.registry_requests(context), &String.ends_with?(&1, ".tar.gz"))
    context
  end

  # A status check of the scenario's instance, as a provider refresh runs it.
  step "the MC checks the instance", context do
    case context[:check_instance] do
      check when is_function(check, 1) -> check.(context)
      nil -> Map.put(context, :entry, Acp.check(context[:auth_instance] || "acme"))
    end
  end

  step "the instance is ready and its version is unknown", context do
    assert %{"status" => "ready", "version" => nil} = context.entry
    # Not even once the agent has run and named its own.
    assert Acp.provider("acme")["version"] == nil
    context
  end

  # --- sign-in the agent refuses --------------------------------------------------------

  defp refusing(context, step, error) do
    control =
      case step do
        :sign_in -> %{"authenticateError" => error}
        :session -> %{"sessionError" => error}
      end

    context
    |> acme(Map.merge(%{"auth" => "file", "methods" => [@browser]}, control))
    |> Map.put(:refused_sign_in, step)
  end

  step "{string} answers its sign-in with the error {string}", %{args: [_, error]} = context do
    refusing(context, :sign_in, error)
  end

  step "{string} answers the session it is asked for afterward with the error {string}",
       %{args: [_, error]} = context do
    refusing(context, :session, error)
  end

  step "{string} answers its sign-in with an error of 4,000 characters", %{args: [_]} = context do
    refusing(context, :sign_in, String.duplicate("proxy error page ", 250))
  end

  step "the reason shown after the generic message is cut to 500 characters", context do
    generic = "The ACP agent could not complete sign-in. "
    assert String.starts_with?(context.told, generic)
    reason = context.told |> String.replace_prefix(generic, "") |> String.trim_trailing(".")
    assert String.length(reason) == 500
    assert String.starts_with?(reason, "proxy error page")
    context
  end

  # --- session options -------------------------------------------------------------------

  defp select_option(id, name, values, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "type" => "select",
        "currentValue" => hd(values),
        "options" => for(v <- values, do: %{"value" => v, "name" => v})
      },
      extra
    )
  end

  defp with_session_options(context, options, control \\ %{}) do
    ctx = acme(context, Map.put(control, "sessionOptions", options))
    assert Acp.check("acme")["status"] == "ready"
    ctx
  end

  # The options offered with the first of the instance's models.
  defp model_options(_ctx \\ nil) do
    model = hd(Acp.provider("acme")["models"])
    get_in(model, ["capabilities", "optionDescriptors"]) || []
  end

  defp descriptor(options, id), do: Enum.find(options, &(&1["id"] == id))

  # Sends a turn to "acme" with `options` picked for its model; the thread is started
  # the first time, so the session exists before the options are checked.
  defp send_with_options(ctx, options) do
    selection = %{
      "instanceId" => "acme",
      "model" => "default",
      "options" => for({id, value} <- options, do: %{"id" => id, "value" => value})
    }

    ctx =
      if ctx.threads["Acme"] do
        ctx
      else
        ctx = run_on_acme(ctx, "hello")
        Acp.await_runs(ctx.threads["Acme"], 1)
        ctx
      end

    count = length(Acp.stream(ctx.threads["Acme"]) |> HalC2.StreamState.list("run"))
    ctx = Acp.follow_up(ctx, "Acme", "hello", %{"modelSelection" => selection})
    runs = Acp.await_runs(ctx.threads["Acme"], count + 1)
    Map.merge(ctx, %{last_run: List.last(runs), refused_with: &option_refused/2})
  end

  defp config_sets(ctx, id) do
    for %{"params" => %{"configId" => ^id} = params} <-
          Acp.requests(ctx, "acme", "session/set_config_option"),
        do: params["value"]
  end

  step "{string} offers a session option {string} with the choices low and high",
       %{args: [_, name]} = context do
    with_session_options(
      context,
      [select_option(String.downcase(name), name, ["low", "high"])],
      %{"modes" => ["code", "plan"]}
    )
  end

  step "the user opens the options of an {string} model", %{args: [_]} = context do
    Map.put(context, :descriptors, model_options())
  end

  step "{string} is offered with low and high", %{args: [name]} = context do
    assert %{"label" => ^name, "type" => "select", "options" => choices} =
             Enum.find(context.descriptors, &(&1["label"] == name))

    assert Enum.map(choices, & &1["id"]) == ["low", "high"]
    context
  end

  step "the agent's own model and plan-mode options are not repeated there", context do
    ids = Enum.map(context.descriptors, & &1["id"])
    refute "model" in ids
    refute "mode" in ids
    context
  end

  step "{string} offers more than 16 session options, one of them with more than 64 choices",
       %{args: [_]} = context do
    big =
      select_option("big", "Big", ["a", "", "a"] ++ for(n <- 1..80, do: "c#{n}"), %{
        "currentValue" => "a"
      })

    others = for n <- 1..20, do: select_option("o#{n}", "Option #{n}", ["x", "y"])
    with_session_options(context, [big | others])
  end

  step "the MC reads the options", context do
    Map.put(context, :descriptors, model_options())
  end

  step "16 options are kept, each with at most 64 choices", context do
    assert length(context.descriptors) == 16
    assert Enum.all?(context.descriptors, &(length(&1["options"]) <= 64))
    assert length(descriptor(context.descriptors, "big")["options"]) == 64
    context
  end

  step "duplicate choices, and empty ones that are not the default, are dropped", context do
    ids = Enum.map(descriptor(context.descriptors, "big")["options"], & &1["id"])
    assert ids == Enum.uniq(ids)
    refute "" in ids
    assert hd(ids) == "a"
    context
  end

  step "{string} offers the option {string} whose default choice {string} has the value \"\"",
       %{args: [_, name, choice]} = context do
    option = %{
      "id" => "agent",
      "name" => name,
      "type" => "select",
      "currentValue" => "",
      "options" => [
        %{"value" => "", "name" => choice},
        %{"value" => "reviewer", "name" => "Reviewer"},
        %{"value" => "planner", "name" => "Planner"}
      ]
    }

    with_session_options(context, [option])
  end

  step "{string} offers {string}, selected, alongside the custom agents",
       %{args: [name, choice]} = context do
    option = Enum.find(context.descriptors, &(&1["label"] == name))
    assert option["currentValue"] == ""

    assert [%{"id" => "", "label" => ^choice, "isDefault" => true}, %{"id" => "reviewer"}, _] =
             option["options"]

    context
  end

  step "picking {string} sends \"\" to {string}", %{args: [_, _]} = context do
    ctx = send_with_options(context, %{"agent" => "reviewer"})
    assert %{"status" => "completed"} = ctx.last_run
    ctx = send_with_options(ctx, %{"agent" => ""})
    assert %{"status" => "completed"} = ctx.last_run
    assert config_sets(ctx, "agent") == ["reviewer", ""]
    ctx
  end

  step "{string} offers the option {string} with the choices low and high",
       %{args: [_, id]} = context do
    with_session_options(context, [select_option(id, "Thinking", ["low", "high"])])
  end

  step "a client sets {string} to {string}", %{args: [id, value]} = context do
    send_with_options(context, %{id => value})
  end

  # "it is refused with {string}" (`HalC2.Steps.SourceControl.StackedPullRequests`).
  defp option_refused(context, message) do
    assert %{"status" => "failed"} = context.last_run
    assert session_error_of(context.threads["Acme"]) == message
    # Refused before it reached the agent.
    assert config_sets(context, "thinking") == []
    assert config_sets(context, "web") == []
    context
  end

  step "{string} offers a session option whose choices are arranged in groups",
       %{args: [_]} = context do
    grouped = %{
      "id" => "persona",
      "name" => "Persona",
      "type" => "select",
      "currentValue" => "terse",
      "options" => [
        %{"group" => "short", "name" => "Short", "options" => [%{"value" => "terse"}]},
        %{
          "group" => "long",
          "name" => "Long",
          "options" => [%{"value" => "chatty"}, %{"value" => "verbose"}]
        }
      ]
    }

    empty = %{"id" => "nothing", "name" => "Nothing", "type" => "select", "options" => []}
    with_session_options(context, [grouped, empty])
  end

  step "the option offers every choice of every group in one list", context do
    choices = descriptor(context.descriptors, "persona")["options"]
    assert Enum.map(choices, & &1["id"]) == ["terse", "chatty", "verbose"]
    context
  end

  step "an option left without a usable choice is not offered at all", context do
    refute descriptor(context.descriptors, "nothing")
    context
  end

  step "{string} offers the on\\/off option {string}", %{args: [_, id]} = context do
    option = %{"id" => id, "name" => "Web", "type" => "boolean", "currentValue" => false}
    context |> with_session_options([option]) |> Map.put(:option_id, id)
  end

  step "{string} offers the option {string} with named choices", %{args: [_, id]} = context do
    context
    |> with_session_options([select_option(id, "Thinking", ["low", "high"])])
    |> Map.put(:option_id, id)
  end

  step "a client sets it to the text {string}", %{args: [value]} = context do
    send_with_options(context, %{context.option_id => value})
  end

  step "a client sets it to on", context do
    send_with_options(context, %{context.option_id => true})
  end

  step "the thread asks for a reasoning effort that the session of {string} does not offer",
       %{args: [_]} = context do
    context
    |> with_session_options([select_option("thinking", "Thinking", ["low", "high"])])
    |> Map.put(:turn_options, %{"effort" => "high"})
  end

  step "a turn starts", context do
    {ctx, log} =
      ExUnit.CaptureLog.with_log(fn -> send_with_options(context, context.turn_options) end)

    Map.put(ctx, :log, log)
  end

  step "the turn runs with the agent's own default for it", context do
    assert %{"status" => "completed"} = context.last_run
    assert config_sets(context, "effort") == []
    context
  end

  step "the MC logs which option was skipped", context do
    assert context.log =~ "skipped the option effort"
    context
  end

  step "the thread's model is {string}", %{args: [_]} = context do
    acme(context)
  end

  step "a turn starts on {string}", %{args: [_]} = context do
    ctx = run_on_acme(context, "hello", model: "default")
    assert [%{"status" => "completed"}] = Acp.await_runs(ctx.threads["Acme"], 1)
    ctx
  end

  step "the MC does not ask {string} to change its model", %{args: [_]} = context do
    assert config_sets(context, "model") == []
    assert Acp.requests(context, "acme", "session/set_model") == []
    context
  end

  # --- an agent's own error without a code ------------------------------------------------

  step "an {string} turn the agent answers with an error that has no code",
       %{args: [_]} = context do
    ctx = context |> acme() |> run_on_acme("fail without a code")
    assert [%{"status" => "failed"}] = Acp.await_runs(thread(ctx), 1)
    ctx
  end

  step "the user sends a second message to {string}", %{args: [_]} = context do
    Acp.follow_up(context, context.thread, "hello")
    assert [_, %{"status" => "completed"}] = Acp.await_runs(thread(context), 2)
    context
  end

  step "it runs on the same {string} process", %{args: [_]} = context do
    # The fake's session ids name its process: one session is one process, still asked.
    sessions =
      for %{"params" => %{"prompt" => prompt} = params} <-
            Acp.requests(context, "acme", "session/prompt"),
          not Enum.any?(prompt, &((&1["text"] || "") =~ "Return a JSON object")),
          do: params["sessionId"]

    assert [same, same] = sessions
    assert is_binary(same)
    context
  end

  # --- What an agent advertises is bounded ---------------------------------------------

  step "{string} advertises hundreds of sign-in methods, models and commands",
       %{args: [_]} = context do
    long = String.duplicate("x", 2000)

    methods =
      for i <- 1..40,
          do: %{"id" => "m#{i}", "name" => "Method #{i} #{long}", "description" => long}

    models = for i <- 1..300, do: ["acme/m#{i}", "Model #{i} #{long}"]

    commands =
      [%{"name" => "Review", "description" => "first"}, %{"name" => "review"}] ++
        for i <- 1..200, do: %{"name" => "c#{i}#{long}", "description" => long}

    context
    |> acme(%{"methods" => methods, "models" => models, "commands" => commands})
    |> Map.put(:check_instance, &check_bounded/1)
  end

  defp check_bounded(context) do
    {:ok, methods} = HalC2.Acp.Auth.methods("acme")
    models = Acp.check("acme")["models"]
    ctx = context |> watch_providers() |> run_on_acme("offer commands")
    {entry, ctx} = await_acme(ctx, &(&1["slashCommands"] != []))

    Map.merge(ctx, %{
      bounded: %{methods: methods, models: models, commands: entry["slashCommands"]}
    })
  end

  step "at most 32 sign-in methods, 256 models and 128 commands are kept", context do
    %{methods: methods, models: models, commands: commands} = context.bounded
    assert length(methods) == 32
    assert length(models) == 256
    assert length(commands) == 128
    context
  end

  step "commands that differ only in letter case are listed once", context do
    assert [%{"name" => "Review", "description" => "first"}] =
             Enum.filter(context.bounded.commands, &(String.downcase(&1["name"]) == "review"))

    context
  end

  step "over-long names and descriptions are cut", context do
    %{methods: methods, models: models, commands: commands} = context.bounded
    names = Enum.map(methods ++ models ++ commands, & &1["name"])
    descriptions = for item <- methods ++ commands, d = item["description"], d != nil, do: d
    assert Enum.all?(names, &(String.length(&1) <= 128))
    assert Enum.all?(descriptions, &(String.length(&1) <= 1024))
    assert Enum.any?(descriptions, &(String.length(&1) == 1024))
    context
  end

  step "the MC's log holds the reason without {string}", %{args: [secret]} = context do
    assert context.log =~ "rejected by the proxy"
    refute context.log =~ secret
    context
  end

  step "the MC's log holds the reason {string}", %{args: [reason]} = context do
    assert context.log =~ reason
    context
  end
end
