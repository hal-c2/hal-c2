defmodule HalC2.Steps.Providers.Cursor do
  @moduledoc """
  Steps for `features/providers/cursor.feature`.

  Cursor runs as the MC runs it (`HalC2.Acp`: the cursor-acp agent), over a fake Cursor
  SDK (`test/support/fake_cursor.mjs`, set up by `HalC2.Test.AcpFixtures.ready/1`). The
  fake logs what the SDK is asked to do to `<agents>/cursor-<instance>.log`, and a
  browser sign-in finishes once `<agents>/cursor-<instance>.login-done` exists. RPCs
  go through the client "ops", so frames other clients await are never skipped.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.AcpFixtures, as: Acp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @api_key "crsr-test-key"

  # --- helpers -------------------------------------------------------------------------

  defp ops(ctx) do
    ctx = Acp.ready(ctx)

    if Map.has_key?(ctx.clients, "ops"),
      do: ctx,
      else: World.put_client(ctx, "ops", Mc.connect(ctx.mc))
  end

  # Clients connect before any subscription: connecting reads the test's mailbox.
  defp connect(ctx, name) do
    if Map.has_key?(ctx.clients, name),
      do: ctx,
      else: World.put_client(ctx, name, Mc.connect(ctx.mc))
  end

  defp log(ctx, id \\ "cursor"), do: Acp.log(ctx, "cursor-#{id}")
  defp agents(ctx, id \\ "cursor"), do: Enum.filter(log(ctx, id), &(&1["event"] == "agent"))

  defp credentials(id),
    do: Path.join([Application.fetch_env!(:hal_c2, :home), "provider-auth", id, "cursor.json"])

  # A Cursor sign-in the fake SDK accepts, as a finished browser login leaves it.
  defp sign_in(id) do
    File.mkdir_p!(Path.dirname(credentials(id)))
    File.write!(credentials(id), JSON.encode!(%{"apiKey" => "cursor-key"}))
  end

  defp enable("cursor"), do: Acp.put_provider("cursor", %{"enabled" => true})
  defp enable(id), do: Acp.put_instance(id, %{"driver" => "cursor", "enabled" => true})

  # Cursor enabled and read as the MC's status check does.
  defp enabled(ctx, id \\ "cursor") do
    ctx = ops(ctx)
    enable(id)
    entry = Acp.check(id)
    assert entry["enabled"] == true
    {entry, ctx}
  end

  defp signed_out(ctx, id \\ "cursor") do
    {entry, ctx} = enabled(ctx, id)
    assert entry["auth"]["status"] == "unauthenticated"
    Map.put(ctx, :auth_instance, id)
  end

  defp watch_auth(ctx, id, name \\ "default") do
    if ctx[:auth_subs][{name, id}],
      do: ctx,
      else: ctx |> Acp.watch_auth(id, name) |> elem(1)
  end

  defp start_sign_in(ctx, id \\ "cursor") do
    ctx = watch_auth(ctx, id)

    {state, ctx} =
      World.call!(
        ctx,
        "provider.auth.start",
        %{"instanceId" => id, "methodId" => "cursor-login"},
        "ops"
      )

    Map.merge(ctx, %{flow: state["flowId"], auth_instance: id})
  end

  defp await_phase(ctx, phase, name \\ "default") do
    flow = ctx.flow
    Acp.await_auth(ctx, ctx.auth_instance, &(&1["flowId"] == flow and &1["phase"] == phase), name)
  end

  defp waiting(ctx, name \\ "default") do
    {state, ctx} = await_phase(ctx, "waiting", name)

    assert %{"type" => "browser", "url" => "https://cursor.test/login"} = state["interaction"]
    {state, ctx}
  end

  # The user opens the page and finishes signing in on cursor.com.
  defp finish_on_website(ctx, interaction) do
    id = ctx.auth_instance
    File.write!(Path.join(Acp.dir(ctx), "cursor-#{id}.login-done"), "")

    {_, ctx} =
      World.call!(
        ctx,
        "provider.auth.respond",
        %{
          "instanceId" => id,
          "flowId" => ctx.flow,
          "interactionId" => interaction["id"],
          "response" => %{"type" => "browser", "action" => "accept"}
        },
        "ops"
      )

    {_, ctx} = await_phase(ctx, "succeeded")
    ctx
  end

  defp expire(ctx) do
    send(Acp.auth_server(ctx.auth_instance), {:expire, ctx.flow})
    ctx
  end

  # Waits on client "default" (subscribed by `watch_providers/1`) for a provider list
  # whose `id` entry matches `fun`. That frame ends the wait: it follows the agent's
  # read, which starts a process and so takes as long as the machine makes it.
  defp await_entry(ctx, id, fun) do
    sub = ctx.config_sub

    {frame, client} =
      Mc.await(
        World.client(ctx),
        fn frame ->
          frame["t"] == "config.providers" and frame["id"] == sub and
            case Enum.find(frame["providers"], &(&1["instanceId"] == id)) do
              nil -> false
              entry -> fun.(entry)
            end
        end
      )

    {Enum.find(frame["providers"], &(&1["instanceId"] == id)), World.put_client(ctx, client)}
  end

  defp watch_providers(ctx) do
    sub = 5000 + System.unique_integer([:positive])

    client =
      Mc.sub(World.client(ctx), sub, %{"type" => "config", "mc" => Atom.to_string(node())})

    {_, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == sub))
    ctx |> World.put_client(client) |> Map.put(:config_sub, sub)
  end

  defp run_on_cursor(ctx, mode) do
    ctx = Acp.launch(ctx, "Cursor", "cursor", "hello", mode: mode)
    Acp.await_runs(ctx.threads["Cursor"], 1)
    Map.put(ctx, :thread, "Cursor")
  end

  defp api_key_instance(ctx) do
    ctx = ops(ctx)

    Acp.put_instance("cursor", %{
      "driver" => "cursor",
      "enabled" => true,
      "environment" => [%{"name" => "CURSOR_API_KEY", "value" => @api_key}]
    })

    ctx
  end

  @modes %{
    "approval required" => "approval-required",
    "auto-accept edits" => "auto-accept-edits",
    "auto" => "auto",
    "full access" => "full-access"
  }

  # --- enabling --------------------------------------------------------------------------

  step "Cursor is not enabled on the MC", context do
    ctx = Acp.ready(context)
    refute HalC2.Acp.enabled?("cursor")
    ctx
  end

  step "no Cursor process is started", context do
    # The MC's boot probe, then the provider list clients get.
    HalC2.Acp.load()
    entry = Acp.provider("cursor")
    assert entry == nil or entry["enabled"] == false
    assert :persistent_term.get({HalC2.Acp, "cursor", :loading}, false) == false
    assert log(context) == []
    context
  end

  step "the user is signed in to Cursor", context do
    sign_in("cursor")
    ops(context)
  end

  step "the user enables Cursor", context do
    ctx = watch_providers(context)

    Acp.write_settings(
      ctx,
      &put_in(&1, [Access.key("providers", %{}), Access.key("cursor", %{}), "enabled"], true),
      "ops"
    )
  end

  step "the Cursor models are offered in the model picker", context do
    {entry, ctx} =
      await_entry(context, "cursor", fn entry ->
        entry["enabled"] and Enum.any?(entry["models"], &(&1["slug"] == "composer-2"))
      end)

    assert Enum.map(entry["models"], &{&1["slug"], &1["name"]}) == [
             {"default", "Auto"},
             {"composer-2", "Composer 2"},
             {"gpt-5", "GPT-5"}
           ]

    assert entry["auth"]["status"] == "authenticated"
    ctx
  end

  # --- signing in --------------------------------------------------------------------------

  step "Cursor is enabled and signed out", context do
    context |> connect("second") |> signed_out()
  end

  step "the user signs in to Cursor", context do
    context |> watch_auth("cursor", "second") |> start_sign_in()
  end

  step "every client of the MC is offered the Cursor sign-in page", context do
    {_, ctx} = waiting(context, "second")
    {state, ctx} = waiting(ctx)
    assert state["authorizationUrl"] == "https://cursor.test/login"
    assert [_] = Enum.filter(log(ctx), &(&1["event"] == "login"))
    Map.put(ctx, :interaction, state["interaction"])
  end

  step "Cursor is signed in once the user finishes on the website", context do
    ctx = finish_on_website(context, context.interaction)
    assert File.exists?(credentials("cursor"))
    assert Acp.check("cursor")["auth"]["status"] == "authenticated"
    ctx
  end

  step "Cursor is waiting for the user to open its sign-in page", context do
    ctx = context |> signed_out() |> start_sign_in()
    {_, ctx} = waiting(ctx)
    ctx
  end

  step "five minutes pass without an answer", context do
    expire(context)
  end

  step "the sign-in request is declined", context do
    {state, ctx} = await_phase(context, "failed")
    assert state["message"] == "Sign-in expired. Start again."
    assert state["interaction"] == nil
    refute File.exists?(credentials("cursor"))
    ctx
  end

  step "the user can start sign-in again", context do
    before = context.flow
    ctx = start_sign_in(context)
    assert ctx.flow != before
    {_, ctx} = waiting(ctx)
    ctx
  end

  step "Cursor sign-in has been waiting for five minutes", context do
    ctx = signed_out(context)
    started = System.system_time(:millisecond)
    ctx = start_sign_in(ctx)
    {state, ctx} = waiting(ctx)
    seen = System.system_time(:millisecond)
    {:ok, expires, _} = DateTime.from_iso8601(state["expiresAt"])
    # Five minutes from when the MC started the flow, which is after it read the
    # agent's sign-in methods: between asking and being shown the page.
    from = DateTime.to_unix(expires, :millisecond) - 300_000

    assert from in started..seen,
           "the five minutes start #{from - started}ms after sign-in was asked for"

    ctx
  end

  step "the user is told Cursor sign-in expired and to start again", context do
    {state, ctx} = await_phase(context, "failed")
    assert state["message"] == "Sign-in expired. Start again."
    ctx
  end

  step "Cursor sign-in is in progress", context do
    ctx = context |> signed_out() |> start_sign_in()
    {_, ctx} = waiting(ctx)
    ctx
  end

  step "the user cancels sign-in", context do
    {_, ctx} =
      World.call!(
        context,
        "provider.auth.cancel",
        %{"instanceId" => "cursor", "flowId" => context.flow},
        "ops"
      )

    ctx
  end

  step "Cursor stays signed out", context do
    {state, ctx} = await_phase(context, "cancelled")
    assert state["message"] == "Sign-in cancelled."
    refute File.exists?(credentials("cursor"))
    assert Acp.check("cursor")["auth"]["status"] == "unauthenticated"
    ctx
  end

  step "the user signs out of Cursor", context do
    {_, ctx} = enabled(context)
    assert File.exists?(credentials("cursor"))
    {state, ctx} = World.call!(ctx, "provider.auth.logout", %{"instanceId" => "cursor"}, "ops")
    Map.put(ctx, :auth_state, state)
  end

  step "Cursor is shown as signed out", context do
    assert context.auth_state["message"] == "Signed out."
    refute File.exists?(credentials("cursor"))
    # Signing out makes the MC read Cursor again.
    entry = Acp.check("cursor")
    assert entry["auth"]["status"] == "unauthenticated"
    assert entry["setup"]["canAuthenticate"] == true
    context
  end

  step "two Cursor instances {string} and {string}", %{args: [one, two]} = context do
    context |> signed_out(one) |> signed_out(two)
  end

  @doc "Signs Cursor instance `id` in through the browser (`the user signs in to {string}`)."
  def sign_in_to(context, id) do
    ctx = start_sign_in(context, id)
    {state, ctx} = waiting(ctx)
    ctx = finish_on_website(ctx, state["interaction"])
    assert File.exists?(credentials(id))
    assert Acp.check(id)["auth"]["status"] == "authenticated"
    ctx
  end

  # --- API keys ----------------------------------------------------------------------------

  step "the Cursor instance has a Cursor API key in its environment", context do
    api_key_instance(context)
  end

  step "Cursor ends a turn with a command still running", context do
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    ctx = Acp.launch(ctx, "Cursor", "cursor", "leave a command running")
    [%{"status" => "completed"}] = Acp.await_runs(ctx.threads["Cursor"], 1)
    Map.put(ctx, :thread, "Cursor")
  end

  # --- an abandoned send -----------------------------------------------------------------

  # The turn's runtime stops without ending it (as when its supervisor shuts it down):
  # the run's record says running, and no Cursor session is left behind it.
  step "a message was sent to Cursor but the MC kept only its local run record and no live Cursor session",
       context do
    Mc.ensure(HalC2.Orchestration.TurnWatch)
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    ctx = Acp.launch(ctx, "Cursor", "cursor", "wait")
    thread = ctx.threads["Cursor"]

    Acp.await_stream(thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))
    end)

    [{runtime, _}] = Registry.lookup(HalC2.Acp.Registry, thread)
    ref = Process.monitor(runtime)
    :ok = GenServer.stop(runtime, :shutdown)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    Mc.settle_registry(HalC2.Acp.Registry)
    assert [%{"status" => "running"}] = Acp.runs(thread)
    assert Registry.lookup(HalC2.Acp.Registry, thread) == []
    # The sidebar still shows it as the thread's active run, which the check reads.
    World.await_row(thread, &is_binary(&1["activeRunId"]))
    Map.put(ctx, :thread, "Cursor")
  end

  step "the MC checks its Cursor sessions", context do
    Mc.ensure(HalC2.Orchestration.IdleSessions)
    HalC2.Orchestration.IdleSessions.check()
    context
  end

  step "the send is completed or failed explicitly", context do
    assert [%{"status" => "failed", "completedAt" => at}] =
             Acp.await_runs(context.threads["Cursor"], 1)

    assert is_binary(at)

    assert [%{"lastError" => "The provider's session ended unexpectedly."}] =
             HalC2.StreamState.list(Acp.stream(context.threads["Cursor"]), "provider-session")

    context
  end

  step "the user's next message starts a new Cursor run", context do
    Acp.follow_up(context, "Cursor", "hello")

    assert ["failed", "completed"] =
             Enum.map(Acp.await_runs(context.threads["Cursor"], 2), & &1["status"])

    assert Acp.assistant_text(context.threads["Cursor"]) =~ "Hello from Cursor"
    context
  end

  # --- model options ---------------------------------------------------------------------

  # What Cursor's catalog says of GPT-5: its parameters, and the default variant.
  @parameters [
    %{"id" => "thinking", "values" => [%{"value" => "true"}, %{"value" => "false"}]},
    %{
      "id" => "fast",
      "displayName" => "Fast",
      "values" => [%{"value" => "false"}, %{"value" => "true"}]
    },
    %{
      "id" => "context",
      "values" => [%{"value" => "200k"}, %{"value" => "1m", "displayName" => "1M"}]
    },
    %{
      "id" => "reasoning",
      "displayName" => "Reasoning",
      "values" => [
        %{"value" => "low", "displayName" => "Low"},
        %{"value" => "medium", "displayName" => "Medium"},
        %{"value" => "high", "displayName" => "High"}
      ]
    }
  ]
  @variants [
    %{
      "isDefault" => true,
      "params" => [
        %{"id" => "reasoning", "value" => "medium"},
        %{"id" => "context", "value" => "200k"},
        %{"id" => "fast", "value" => "false"}
      ]
    }
  ]

  step "the user opens the options for a Cursor model", context do
    sign_in("cursor")
    ctx = ops(context)

    Acp.control(ctx, "cursor-cursor", %{
      "parameters" => %{"gpt-5" => @parameters},
      "variants" => %{"gpt-5" => @variants}
    })

    {entry, ctx} = enabled(ctx)
    Map.put(ctx, :cursor_models, entry["models"])
  end

  step "the reasoning, context size, fast mode and thinking choices Cursor offers for that model are shown",
       context do
    model = Enum.find(context.cursor_models, &(&1["slug"] == "gpt-5"))

    assert [
             %{
               "id" => "reasoning",
               "label" => "Reasoning",
               "type" => "select",
               "currentValue" => "medium",
               "options" => [
                 %{"id" => "low", "label" => "Low"},
                 %{"id" => "medium", "label" => "Medium", "isDefault" => true},
                 %{"id" => "high", "label" => "High"}
               ]
             },
             %{
               "id" => "contextWindow",
               "label" => "Context Window",
               "type" => "select",
               "currentValue" => "200k",
               "options" => [
                 %{"id" => "200k", "label" => "200k", "isDefault" => true},
                 %{"id" => "1m", "label" => "1M"}
               ]
             },
             %{
               "id" => "fastMode",
               "label" => "Fast",
               "type" => "boolean",
               "currentValue" => false
             },
             %{"id" => "thinking", "label" => "Thinking", "type" => "boolean"} = thinking
           ] = model["capabilities"]["optionDescriptors"]

    refute Map.has_key?(thinking, "currentValue")

    # A model Cursor lists no parameters for has no options.
    assert Enum.find(context.cursor_models, &(&1["slug"] == "composer-2"))["capabilities"] == nil

    # What the user picks reaches Cursor as the model's parameters.
    ctx = Acp.launch(context, "Cursor", "cursor", "hello", model: "gpt-5")
    Acp.await_runs(ctx.threads["Cursor"], 1)

    Acp.follow_up(ctx, "Cursor", "hello again", %{
      "modelSelection" => %{
        "instanceId" => "cursor",
        "model" => "gpt-5",
        "options" => [
          %{"id" => "reasoning", "value" => "high"},
          %{"id" => "contextWindow", "value" => "1m"},
          %{"id" => "fastMode", "value" => true}
        ]
      }
    })

    Acp.await_runs(ctx.threads["Cursor"], 2)

    assert [%{"model" => %{"id" => "gpt-5"} = first}, %{"model" => second}] =
             Enum.filter(log(ctx), &(&1["event"] == "send"))

    refute Map.has_key?(first, "params")

    assert second == %{
             "id" => "gpt-5",
             "params" => [
               %{"id" => "context", "value" => "1m"},
               %{"id" => "fast", "value" => "true"},
               %{"id" => "reasoning", "value" => "high"}
             ]
           }

    ctx
  end

  # --- skills and rules ------------------------------------------------------------------

  defp cursor_skill(context, name) do
    dir = Path.join([World.project(context).root, ".cursor", "skills", name])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: Ship it\n---\nRun the deploy.\n"
    )
  end

  step "the project has the Cursor skill {string}", %{args: [name]} = context do
    cursor_skill(context, name)
    context
  end

  # As the composer writes a skill mention: `$name`.
  step "the user mentions {string} in a message", %{args: [name]} = context do
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    ctx = Acp.launch(ctx, "Cursor", "cursor", "use $#{name} and $other to ship it for $20")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    Map.merge(ctx, %{thread: "Cursor", mentioned: name})
  end

  step "Cursor receives the skill reference", context do
    assert [%{"message" => message}] = Enum.filter(log(context), &(&1["event"] == "send"))
    # The skill is named as Cursor invokes it; what is not a skill is left alone.
    assert message == "use /#{context.mentioned} and $other to ship it for $20"
    context
  end

  step "the project has skills and rules for Cursor", context do
    cursor_skill(context, "deploy")
    rules = Path.join([World.project(context).root, ".cursor", "rules"])
    File.mkdir_p!(rules)
    File.write!(Path.join(rules, "style.mdc"), "Use tabs.\n")
    context
  end

  step "a Cursor turn starts in the project", context do
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    ctx = Acp.launch(ctx, "Cursor", "cursor", "hello")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    Map.put(ctx, :thread, "Cursor")
  end

  # The agent of the thread works in the project with every setting source
  # named, which is what makes the SDK read the rules and skills at all.
  step "Cursor receives the project's skills and rules", context do
    root = World.project(context).root

    assert [
             %{
               "cwd" => ^root,
               "settingSources" => ["project", "user", "team", "mdm", "plugins"],
               "loaded" => loaded
             }
           ] = Enum.filter(agents(context), &(&1["mode"] == "agent" and &1["cwd"] == root))

    assert loaded == ["rules/style.mdc", "skills/deploy"]
    context
  end

  # --- plan mode ------------------------------------------------------------------------

  step "the thread is in plan mode on Cursor", context do
    sign_in("cursor")
    {entry, ctx} = enabled(context)
    # Clients offer the plan toggle for Cursor.
    assert entry["showInteractionModeToggle"] == true
    ctx
  end

  step "Cursor finishes planning", context do
    ctx = Acp.launch(context, "Cursor", "cursor", "make a plan", interaction: "plan")
    assert [%{"status" => "completed"}] = Acp.await_runs(ctx.threads["Cursor"], 1)
    Map.put(ctx, :thread, "Cursor")
  end

  step "the plan is shown as a proposed plan with its task list", context do
    # Cursor ran in its plan mode.
    assert [%{"mode" => "plan"}] = Enum.filter(log(context), &(&1["event"] == "send"))
    plans = HalC2.StreamState.list(Acp.stream(context.threads["Cursor"]), "plan")

    assert [%{"markdown" => "# Plan\n- do it", "status" => "active"}] =
             Enum.filter(plans, &(&1["kind"] == "proposed_plan"))

    assert [%{"steps" => steps}] = Enum.filter(plans, &(&1["kind"] == "todo_list"))

    assert [
             %{"text" => "Read the code", "status" => "completed"},
             %{"text" => "Write the plan", "status" => "running"}
           ] = steps

    # Neither is shown as a tool call.
    refute Enum.any?(
             HalC2.StreamState.list(Acp.stream(context.threads["Cursor"]), "turn-item"),
             &(&1["type"] == "dynamic_tool")
           )

    context
  end

  # --- usage ---------------------------------------------------------------------------

  @usage_path "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

  # The Cursor CLI's own login, kept in a file (where each platform keeps it), and
  # Cursor's dashboard API played on loopback.
  step "Cursor is signed in with a file-based login", context do
    dir = Path.join(context.mc.home, "cursor-login")

    for path <- [".cursor/auth.json", "config/cursor/auth.json"] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), JSON.encode!(%{"accessToken" => "file-token"}))
    end

    {url, log} =
      HalC2.Test.FakeHttp.start(%{
        @usage_path =>
          {200,
           %{
             "billingCycleEnd" => "1790000000000",
             "planUsage" => %{
               "totalPercentUsed" => 50,
               "autoPercentUsed" => 30,
               "apiPercentUsed" => 20
             }
           }}
      })

    context = Acp.ready(context)

    Acp.put_instance("cursor", %{
      "driver" => "cursor",
      "enabled" => true,
      "config" => %{"apiEndpoint" => url},
      "environment" =>
        for(
          {name, value} <- [
            {"HOME", dir},
            {"XDG_CONFIG_HOME", Path.join(dir, "config")},
            {"AGENT_CLI_CREDENTIAL_STORE", "file"}
          ],
          do: %{"name" => name, "value" => value}
        )
    })

    Map.put(context, :cursor_usage_log, log)
  end

  step "Cursor shows its monthly, Auto and API usage with the billing cycle end", context do
    cursor = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))
    limits = cursor["usageLimits"]
    refute Map.has_key?(limits, "unavailable")

    assert [
             {"apiPercentUsed", "monthly", "Monthly · API", 20},
             {"autoPercentUsed", "monthly", "Monthly · Auto", 30},
             {"totalPercentUsed", "monthly", "Monthly", 50}
           ] = for(w <- limits["windows"], do: {w["id"], w["kind"], w["label"], w["usedPercent"]})

    # The billing cycle's end is when each window resets.
    assert Enum.all?(limits["windows"], &(&1["resetsAt"] == "2026-09-21T14:13:20.000Z"))

    # It was read with the login in the file.
    assert [%{"path" => @usage_path, "authorization" => "Bearer file-token"} | _] =
             HalC2.Test.FakeHttp.requests(context.cursor_usage_log)

    context
  end

  # The MC's own Cursor sign-in, or a CURSOR_API_KEY, with no Cursor CLI login on the
  # machine. Cursor's default endpoint is played on loopback: it trades the key for a
  # token and reads the usage with that token.
  step ~r/^the user signed in to Cursor with (?<credential>Sign in with Cursor|a CURSOR_API_KEY in the instance's environment) and has no Cursor CLI login$/,
       %{args: [credential]} = context do
    home = Path.join(context.mc.home, "no-cursor-login")
    File.mkdir_p!(home)

    {url, log} =
      HalC2.Test.FakeHttp.start(%{
        "/auth/exchange_user_api_key" => {200, %{"accessToken" => "exchanged-token"}},
        @usage_path =>
          {200,
           %{
             "billingCycleEnd" => "1790000000000",
             "planUsage" => %{"totalPercentUsed" => 40, "autoPercentUsed" => 25}
           }}
      })

    World.put_app_env(:cursor_api_url, url)
    context = Acp.ready(context)

    {key, env} =
      if credential == "Sign in with Cursor" do
        sign_in("cursor")
        {"cursor-key", []}
      else
        {@api_key, [{"CURSOR_API_KEY", @api_key}]}
      end

    instance = %{
      "driver" => "cursor",
      "enabled" => true,
      "environment" =>
        for(
          {name, value} <- [{"HOME", home}, {"XDG_CONFIG_HOME", Path.join(home, "config")} | env],
          do: %{"name" => name, "value" => value}
        )
    }

    Acp.put_instance("cursor", instance)
    Map.merge(context, %{cursor_usage_log: log, cursor_instance: instance, cursor_key: key})
  end

  step "the stored Cursor sign-in expired yesterday", context do
    expired = System.system_time(:millisecond) - 86_400_000

    File.write!(
      credentials("cursor"),
      JSON.encode!(%{"apiKey" => context.cursor_key, "apiKeyExpiresAtMs" => expired})
    )

    context
  end

  step "Cursor shows no usage limits", context do
    cursor = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))

    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}} =
             cursor["usageLimits"]

    context
  end

  step "the expired key was not sent anywhere", context do
    assert HalC2.Test.FakeHttp.requests(context.cursor_usage_log) == []
    context
  end

  step "the Cursor instance uses a custom API endpoint", context do
    {url, log} = HalC2.Test.FakeHttp.start(%{})

    Acp.put_instance(
      "cursor",
      Map.put(context.cursor_instance, "config", %{"apiEndpoint" => url})
    )

    Map.put(context, :cursor_custom_log, log)
  end

  step "Cursor shows its monthly allowance", context do
    cursor = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))

    assert [
             {"autoPercentUsed", "Monthly · Auto", 25},
             {"totalPercentUsed", "Monthly", 40}
           ] =
             for(
               w <- cursor["usageLimits"]["windows"],
               do: {w["id"], w["label"], w["usedPercent"]}
             )

    # The key was traded for a token, and the usage read with that token.
    key = "Bearer " <> context.cursor_key

    assert [
             %{"path" => "/auth/exchange_user_api_key", "authorization" => ^key},
             %{"path" => @usage_path, "authorization" => "Bearer exchanged-token"}
           ] = HalC2.Test.FakeHttp.requests(context.cursor_usage_log) |> Enum.take(2)

    context
  end

  step "the user is not asked to allow access to a Cursor CLI login", context do
    cursor = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))
    refute Map.has_key?(cursor["usageLimits"], "unavailable")
    context
  end

  step "Cursor says usage for an API key needs the default Cursor endpoint", context do
    cursor = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))

    assert %{
             "windows" => [],
             "unavailable" => %{
               "reason" => "unsupported",
               "message" => "Cursor usage for an API key requires the default Cursor endpoint."
             }
           } = cursor["usageLimits"]

    context
  end

  step "the API key was not sent anywhere", context do
    assert HalC2.Test.FakeHttp.requests(context.cursor_usage_log) == []
    assert HalC2.Test.FakeHttp.requests(context.cursor_custom_log) == []
    context
  end

  # --- commands ------------------------------------------------------------------------

  defp commands(ctx) do
    Acp.stream(ctx.threads["Cursor"])
    |> HalC2.StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] == "command_execution"))
  end

  step "Cursor is running a command", context do
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    ctx = Acp.launch(ctx, "Cursor", "cursor", "run a command and wait")

    Acp.await_stream(ctx.threads["Cursor"], fn _ ->
      match?([%{"input" => "npm test", "status" => "running"}], commands(ctx))
    end)

    Map.put(ctx, :thread, "Cursor")
  end

  step "the command is shown as interrupted", context do
    if get_in(context, [Access.key(:threads), "Cursor"]) do
      assert [%{"status" => "interrupted"}] = Acp.await_runs(context.threads["Cursor"], 1)
      assert [%{"input" => "npm test", "status" => "interrupted"}] = commands(context)
      context
    else
      # The same words on an MC thread of another provider (Codex): its command's
      # turn item is the interrupted one.
      title = World.current_thread(context)

      item =
        World.await_value(context, title, fn state ->
          Enum.find(
            HalC2.StreamState.list(state, "turn-item"),
            &(&1["type"] == "command_execution" and &1["status"] == "interrupted")
          )
        end)

      assert item["status"] == "interrupted"
      context
    end
  end

  # Cursor did report the stopped command as a finished tool call.
  step "it is not shown as a successful command", context do
    assert [_] = Enum.filter(log(context), &(&1["event"] == "tool-completed"))
    refute Enum.any?(commands(context), &(&1["status"] == "completed"))
    context
  end

  step "Cursor is running a turn", context do
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    Map.put(ctx, :thread, "Cursor")
  end

  step "a shell command Cursor tries fails to start", context do
    ctx = Acp.launch(context, "Cursor", "cursor", "try a command that cannot start")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the turn keeps going", context do
    assert [%{"status" => "completed"}] = Acp.runs(context.threads["Cursor"])
    assert Acp.assistant_text(context.threads["Cursor"]) =~ "That tool is not installed."
    context
  end

  step "the command is shown as failed", context do
    if Map.has_key?(context, :fakes) do
      # The same words on a FakeAcp thread of another provider (Grok): its
      # background command's turn item is the failed one.
      title = context[:current_thread] || context[:thread]

      item =
        World.await_value(context, title, fn state ->
          Enum.find(
            HalC2.StreamState.list(state, "turn-item"),
            &(&1["status"] == "failed" and get_in(&1, ["nativeItemRef", "nativeId"]) == "sh-1")
          )
        end)

      assert item["status"] == "failed"
      context
    else
      assert [%{"input" => "nosuchtool --version", "status" => "failed", "output" => output}] =
               commands(context)

      assert output =~ "ENOENT"
      context
    end
  end

  step "the user sends a message to Cursor", context do
    run_on_cursor(context, "full-access")
  end

  step "the turn runs with that API key", context do
    assert Acp.assistant_text(context.threads["Cursor"]) =~ "Hello from Cursor"
    assert [_ | _] = agents = agents(context)
    assert Enum.all?(agents, &(&1["apiKey"] == @api_key))

    assert %{"env" => %{"CURSOR_API_KEY" => @api_key}} =
             List.last(Acp.launches(context, "cursor-cursor"))

    refute File.exists?(credentials("cursor"))
    context
  end

  step "no browser sign-in is offered", context do
    entry = Acp.check("cursor")
    assert entry["auth"]["status"] == "authenticated"
    assert entry["setup"]["canAuthenticate"] == false
    {state, ctx} = Acp.watch_auth(context, "cursor")
    assert state["methods"] == []
    ctx
  end

  step "the user tries to sign in with the browser", context do
    {reply, ctx} =
      World.call(
        context,
        "provider.auth.start",
        %{"instanceId" => "cursor", "methodId" => "cursor-login"},
        "ops"
      )

    Map.put(ctx, :reply, reply)
  end

  step "the user is told to remove the API key first", context do
    assert {:error, message, _} = context.reply

    assert message ==
             "Remove CURSOR_API_KEY from this provider's environment before using browser sign-in."

    refute Enum.any?(log(context), &(&1["event"] == "login"))
    context
  end

  # --- turns -------------------------------------------------------------------------------

  step "the thread runs Cursor with approval required", context do
    sign_in("cursor")
    {_, ctx} = enabled(context)

    Map.put(ctx, :pending_launch, %{
      instance: "cursor",
      fields: %{"runtimeMode" => "approval-required"}
    })
  end

  step "Cursor runs with its review and sandbox turned on", context do
    assert %{"mode" => "approval-required"} = List.last(Acp.launches(context, "cursor-cursor"))

    assert %{"autoReview" => true, "sandbox" => true, "mode" => "agent"} =
             List.last(agents(context))

    context
  end

  step ~r/^the thread runs Cursor in (?<mode>.+)$/, %{args: [mode]} = context do
    sign_in("cursor")
    {_, ctx} = enabled(context)
    run_on_cursor(ctx, Map.fetch!(@modes, mode))
  end

  step ~r/^Cursor's review is (?<review>on|off) and its sandbox is (?<sandbox>on|off)$/,
       %{args: [review, sandbox]} = context do
    assert %{"autoReview" => auto_review, "sandbox" => sandboxed} = List.last(agents(context))
    assert auto_review == (review == "on")
    assert sandboxed == (sandbox == "on")
    context
  end

  # Each thread runs its own Cursor agent process, started with the thread's mode.
  step "a Cursor thread runs in a sandbox and another Cursor thread runs in full access",
       context do
    sign_in("cursor")
    {_, ctx} = enabled(context)
    ctx = Acp.launch(ctx, "Sandboxed", "cursor", "hello", mode: "approval-required")
    Acp.await_runs(ctx.threads["Sandboxed"], 1)
    ctx = Acp.launch(ctx, "Open", "cursor", "hello", mode: "full-access")
    Acp.await_runs(ctx.threads["Open"], 1)
    ctx
  end

  step "the full-access thread runs and then the sandboxed thread runs again", context do
    ctx = Acp.follow_up(context, "Open", "carry on in the open")
    Acp.await_runs(ctx.threads["Open"], 2)
    ctx = Acp.follow_up(ctx, "Sandboxed", "leave a command running in the sandbox")
    Acp.await_runs(ctx.threads["Sandboxed"], 2)
    ctx
  end

  step "the sandboxed thread still runs in its sandbox", context do
    sent = fn text ->
      Enum.find(log(context), &(&1["event"] == "send" and &1["message"] =~ text))
    end

    agent = fn send -> Enum.find(agents(context), &(&1["agentId"] == send["agentId"])) end

    assert %{"sandbox" => false} = agent.(sent.("carry on in the open"))

    assert %{"sandbox" => true, "autoReview" => true} =
             agent.(sent.("leave a command running in the sandbox"))

    context
  end

  step "its tools still work", context do
    state = Acp.stream(context.threads["Sandboxed"])
    assert [_, %{"status" => "completed"}] = Acp.runs(context.threads["Sandboxed"])

    assert Enum.any?(
             HalC2.StreamState.list(state, "turn-item"),
             &(&1["type"] == "command_execution" and &1["input"] == "npm run dev")
           )

    context
  end

  # --- text generation -----------------------------------------------------------------------

  step "Cursor is picked for text generation", context do
    sign_in("cursor")
    {_, ctx} = enabled(context)

    Acp.put_settings(
      &Map.put(&1, "textGenerationModelSelection", %{
        "instanceId" => "cursor",
        "model" => "composer-2"
      })
    )

    ctx
  end

  step "Cursor writes the title without using any tools", context do
    assert {:ok, %{"title" => "cursor title"}} = context.title_result
    # Read-only planning, without the user's Cursor settings, rules or tools.
    assert %{"mode" => "plan", "settingSources" => [], "sandbox" => true, "autoReview" => false} =
             List.last(agents(context))

    assert %{"model" => %{"id" => "composer-2"}} =
             Enum.find(log(context), &(&1["event"] == "send"))

    context
  end

  # --- the provider list -----------------------------------------------------------------------

  step "the Cursor sign-in was revoked", context do
    sign_in("cursor")
    ctx = ops(context)
    Acp.control(ctx, "cursor-cursor", %{"revoked" => true})
    {_, ctx} = enabled(ctx)
    ctx
  end

  step "Cursor says the sign-in expired and to sign in again", context do
    entry = Acp.provider("cursor")
    assert entry["auth"]["status"] == "unauthenticated"
    assert entry["status"] == "error"

    assert entry["message"] ==
             "Cursor sign-in expired or was rejected. Sign in again in provider settings."

    context
  end

  step "Cursor returns no models", context do
    sign_in("cursor")
    ctx = ops(context)
    Acp.control(ctx, "cursor-cursor", %{"models" => []})
    {_, ctx} = enabled(ctx)
    ctx
  end

  step "Cursor is shown with a warning that no models were found", context do
    entry = Acp.provider("cursor")
    assert entry["status"] == "warning"
    assert entry["message"] == "Cursor SDK model discovery returned no built-in models."
    assert Enum.map(entry["models"], & &1["slug"]) == ["default"]
    context
  end

  # --- runs, tools and failures ---------------------------------------------------------

  step "a Cursor turn is running", context do
    context |> ready_cursor() |> Map.put(:thread, "Cursor")
  end

  defp ready_cursor(context) do
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    # Marks this scenario's world for step texts shared with other providers.
    Map.put(ctx, :cursor_world, true)
  end

  defp launch_cursor(context, text, opts \\ []) do
    ctx = Acp.launch(context, opts[:title] || "Cursor", "cursor", text, opts)
    ctx |> Map.put(:thread, opts[:title] || "Cursor") |> Map.put(:cursor_world, true)
  end

  defp items(context, title \\ "Cursor") do
    context.threads[title]
    |> Acp.stream()
    |> HalC2.StreamState.list("turn-item")
  end

  defp failure_message(context, title \\ "Cursor") do
    state = Acp.stream(context.threads[title])

    error =
      state
      |> HalC2.StreamState.list("turn-item")
      |> Enum.find(&(&1["type"] == "error"))

    session = HalC2.StreamState.list(state, "provider-session") |> List.first(%{})
    (error && get_in(error, ["failure", "message"])) || session["lastError"]
  end

  step "Cursor's catalog marks every variant of a model with a long context as Max Mode",
       context do
    sign_in("cursor")
    ctx = ops(context)

    Acp.control(ctx, "cursor-cursor", %{
      "parameters" => %{
        "gpt-5" => [
          %{
            "id" => "context",
            "values" => [%{"value" => "200k"}, %{"value" => "1m", "displayName" => "1M"}]
          }
        ]
      },
      "variants" => %{
        "gpt-5" => [
          %{
            "isDefault" => true,
            "params" => [%{"id" => "context", "value" => "200k"}]
          },
          %{
            "params" => [%{"id" => "context", "value" => "1m"}],
            "isMaxMode" => true
          }
        ]
      }
    })

    {_entry, ctx} = enabled(ctx)
    ctx
  end

  step "the user sends a message on that model with the long context, in a new thread or an existing one",
       context do
    ctx = Acp.launch(context, "Cursor", "cursor", "hello", model: "gpt-5")
    Acp.await_runs(ctx.threads["Cursor"], 1)

    ctx =
      Acp.follow_up(ctx, "Cursor", "hello with room to think", %{
        "modelSelection" => %{
          "instanceId" => "cursor",
          "model" => "gpt-5",
          "options" => [%{"id" => "contextWindow", "value" => "1m"}]
        }
      })

    Acp.await_runs(ctx.threads["Cursor"], 2)
    Map.put(ctx, :thread, "Cursor")
  end

  step "the turn runs in Max Mode instead of failing with {string}",
       %{args: [_error]} = context do
    assert [%{"status" => "completed"}, %{"status" => "completed"}] =
             Acp.runs(context.threads["Cursor"])

    assert [_first, %{"model" => %{"id" => "gpt-5", "maxMode" => true}}] =
             Enum.filter(log(context), &(&1["event"] == "send"))

    context
  end

  step "a Cursor thread set to a model the account's catalog does not include", context do
    ready_cursor(context)
  end

  step "the turn fails because Cursor rejects the model", context do
    ctx = launch_cursor(context, "reject the model", model: "gpt-5")
    assert [%{"status" => "failed"}] = Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the user is told the model must be one the Cursor account offers", context do
    assert failure_message(context) =~ "not one this Cursor account offers"
    Map.put(context, :failure_message, failure_message(context))
  end

  step "the error does not suggest trying again", context do
    refute String.downcase(context.failure_message) =~ "try again"

    error =
      Enum.find(items(context), &(&1["type"] == "error"))

    assert error["failure"]["retryable"] in [nil, false]
    context
  end

  step "a Cursor thread with a long conversation", context do
    ctx = context |> ready_cursor() |> launch_cursor("hello")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx = Acp.follow_up(ctx, "Cursor", "tell me more")
    Acp.await_runs(ctx.threads["Cursor"], 2)
    ctx
  end

  step "the user sends {string} to the Cursor thread", %{args: [text]} = context do
    ctx = Acp.follow_up(context, "Cursor", text)
    Acp.await_runs(ctx.threads["Cursor"], 3)
    ctx
  end

  step "the thread shows that its context was compacted", context do
    assert Enum.any?(items(context), &(&1["type"] == "compaction"))
    context
  end

  step "Cursor's summary is not shown as a reply in the chat", context do
    refute Acp.assistant_text(context.threads["Cursor"]) =~ "Summary of everything"
    context
  end

  step "Cursor still knows what the conversation covered", context do
    sends_before = Enum.filter(log(context), &(&1["event"] == "send"))
    ctx = Acp.follow_up(context, "Cursor", "what were we talking about?")
    Acp.await_runs(ctx.threads["Cursor"], 4)
    sends = Enum.filter(log(ctx), &(&1["event"] == "send"))
    # The same Cursor agent carries the conversation through the compaction.
    assert Enum.uniq(Enum.map(sends, & &1["agentId"])) ==
             Enum.uniq(Enum.map(sends_before, & &1["agentId"]))

    ctx
  end

  step "a Cursor thread with history", context do
    ctx = context |> ready_cursor() |> launch_cursor("hello")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "Cursor receives {string} as its whole message", %{args: [message]} = context do
    assert %{"message" => ^message} =
             log(context) |> Enum.filter(&(&1["event"] == "send")) |> List.last()

    context
  end

  step "nothing is added to it", context do
    assert %{"message" => "/compress"} =
             log(context) |> Enum.filter(&(&1["event"] == "send")) |> List.last()

    context
  end

  step "Cursor starts reading {string} and never reports a result for it",
       %{args: [_file]} = context do
    context |> ready_cursor() |> launch_cursor("start reading secret.txt")
  end

  step "the Cursor run finishes normally", context do
    assert [%{"status" => "completed"}] = Acp.await_runs(context.threads["Cursor"], 1)
    context
  end

  step "the read of {string} is shown as interrupted", %{args: [file]} = context do
    read =
      Enum.find(items(context), fn item ->
        item["type"] == "file_search" and
          (item["pattern"] == file or
             Enum.any?(item["results"] || [], &(&1["fileName"] == file)))
      end)

    assert read["status"] == "interrupted"
    Map.put(context, :read_item, read)
  end

  step "it stays visible in the timeline", context do
    assert Enum.any?(items(context), &(&1["id"] == context.read_item["id"]))
    context
  end

  # --- Windows -------------------------------------------------------------------------

  step ~r/^a Cursor thread in (?<mode>.+) starts its first turn$/, %{args: [mode]} = context do
    ctx = context |> ready_cursor() |> launch_cursor("hello", mode: Map.fetch!(@modes, mode))
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the turn runs without Cursor's sandbox", context do
    assert [%{"status" => "completed"}] = Acp.runs(context.threads["Cursor"])
    assert %{"sandbox" => false} = List.last(agents(context))
    context
  end

  step "the thread warns that Cursor has no sandbox on Windows", context do
    assert Enum.any?(
             items(context),
             &(&1["type"] == "system_notice" and &1["message"] =~ "no sandbox on Windows")
           )

    context
  end

  step "the turn fails saying Cursor cannot sandbox on Windows", context do
    assert [%{"status" => "failed"}] = Acp.runs(context.threads["Cursor"])
    assert failure_message(context) =~ "cannot sandbox on Windows"
    context
  end

  # --- connection errors and run endings ------------------------------------------------

  step ~r/^Cursor's whole reply is a connection error such as .*$/, context do
    ctx = launch_cursor(context, "reply with a connection error")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the turn fails as a connection problem instead of showing the error as Cursor's answer",
       context do
    assert [%{"status" => "failed"}] = Acp.runs(context.threads["Cursor"])
    assert failure_message(context) == "Provider turn failed."
    refute Acp.assistant_text(context.threads["Cursor"]) =~ "Something went wrong"
    context
  end

  step "a Cursor turn wrote {string} and ran a step", %{args: [_text]} = context do
    ready_cursor(context)
  end

  step ~r/^Cursor's next message is only the error .* and the run finishes$/, context do
    ctx = launch_cursor(context, "comment then a connection error")
    Acp.await_runs(ctx.threads["Cursor"], 1)

    ctx =
      launch_cursor(ctx, "comment then a connection error then recover", title: "Recover")

    Acp.await_runs(ctx.threads["Recover"], 1)
    Map.put(ctx, :thread, "Cursor")
  end

  step "a later ordinary message in the same turn lets it complete", context do
    assert Acp.assistant_text(context.threads["Cursor"]) =~ "Checking the build first."
    refute Acp.assistant_text(context.threads["Cursor"]) =~ "RetriableError"
    assert [%{"status" => "completed"}] = Acp.runs(context.threads["Recover"])
    assert Acp.assistant_text(context.threads["Recover"]) =~ "All good now."
    context
  end

  step "a Cursor turn has answered and Cursor reported the turn ended", context do
    ready_cursor(context)
  end

  step ~r/^the connection to Cursor breaks and the run ends with .*$/, context do
    ctx = launch_cursor(context, "resume gives up after the turn ended")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the turn completes instead of failing", context do
    assert [%{"status" => "completed"}] = Acp.runs(context.threads["Cursor"])
    context
  end

  step "the failed resume's text is not shown as the answer", context do
    text = Acp.assistant_text(context.threads["Cursor"])
    assert text =~ "Here is the answer."
    refute text =~ "repeated resume"
    context
  end

  step ~r/^(the run ends with the no-progress error before Cursor reports the turn ended|Cursor reports the turn ended and the run then ends with "Checkpoint persistence failed"|Cursor continues after the turn ended and stops mid-answer with the no-progress error)$/,
       %{args: [event]} = context do
    trigger =
      cond do
        event =~ "Checkpoint" -> "resume gives up after the turn ended, checkpoint fails"
        event =~ "continues after" -> "resume gives up after the turn ended then carry on"
        true -> "resume gives up"
      end

    ctx = launch_cursor(context, trigger)
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "Cursor ends the run with the error {string}", %{args: [_error]} = context do
    ctx = launch_cursor(context, "fail with model blocked")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "a thread that delegated the turn is told the same reason", context do
    # A delegating thread's result is read from the child's error item
    # (`HalC2.Orchestration.Delegation.failure_text/3`).
    error = Enum.find(items(context), &(&1["type"] == "error"))
    assert error["failure"]["message"] == context.failure_message
    # The item's code is Cursor's own, not the sidecar's RPC code.
    assert error["failure"]["code"] == "model_blocked"
    context
  end

  step "the user asked Cursor what a connection error means", context do
    ready_cursor(context)
  end

  step "Cursor answers and its answer quotes the error text", context do
    ctx = launch_cursor(context, "quote a connection error")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the turn completes with that answer", context do
    assert [%{"status" => "completed"}] = Acp.runs(context.threads["Cursor"])

    assert Acp.assistant_text(context.threads["Cursor"]) =~
             "Something went wrong communicating with the server."

    context
  end

  step "Cursor streamed no text during a run", context do
    ready_cursor(context)
  end

  step "the run finishes with a result text", context do
    ctx = launch_cursor(context, "answer only in the result")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the result text is shown as Cursor's answer", context do
    assert Acp.assistant_text(context.threads["Cursor"]) =~
             "The answer arrived with the result."

    context
  end

  # --- stopping, and the sidecar going away ----------------------------------------------

  step "the user stops it and Cursor does not confirm the cancellation within 10 seconds",
       context do
    # The deadline the scenario names; the step shortens it to run in a test.
    assert HalC2.Acp.cursor_cancel_timeout() == 10_000
    Application.put_env(:hal_c2, :cursor_cancel_timeout_ms, 300)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :cursor_cancel_timeout_ms)
    end)

    ctx = launch_cursor(context, "ignore the cancel")

    Acp.await_stream(ctx.threads["Cursor"], fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))
    end)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => ctx.threads["Cursor"]
      })

    ctx
  end

  step "the turn ends as interrupted anyway", context do
    assert [%{"status" => "interrupted"}] = Acp.await_runs(context.threads["Cursor"], 1)
    context
  end

  step "the Cursor SDK rejects a write because its stream already closed", context do
    ctx = launch_cursor(context, "die mid-turn")
    assert [%{"status" => "failed"}] = Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the Cursor SDK ends the run's request while a write is still in flight", context do
    ctx = launch_cursor(context, "late write after the end")
    assert [%{"status" => "completed"}] = Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx = Acp.follow_up(ctx, "Cursor", "hello again")
    Acp.await_runs(ctx.threads["Cursor"], 2)
    ctx
  end

  step "other threads are unaffected", context do
    ctx = launch_cursor(context, "hello", title: "Other")
    assert [%{"status" => "completed"}] = Acp.await_runs(ctx.threads["Other"], 1)
    assert Acp.assistant_text(ctx.threads["Other"]) =~ "Hello from Cursor"
    Map.put(ctx, :thread, "Cursor")
  end

  # --- tool calls shown by kind ----------------------------------------------------------

  defp tour(context, triggers) do
    ctx = ready_cursor(context)
    [first | rest] = triggers
    ctx = launch_cursor(ctx, first)
    Acp.await_runs(ctx.threads["Cursor"], 1)

    {ctx, _count} =
      Enum.reduce(rest, {ctx, 1}, fn trigger, {ctx, count} ->
        ctx = Acp.follow_up(ctx, "Cursor", trigger)
        Acp.await_runs(ctx.threads["Cursor"], count + 1)
        {ctx, count + 1}
      end)

    ctx
  end

  step ~r/^Cursor (runs a shell command|writes, edits or deletes a file|generates an image|reads a file or lists a folder|searches by name, text or meaning|reads the lint problems of a file)$/,
       %{args: [does]} = context do
    triggers =
      case does do
        "runs a shell command" -> ["tour: shell"]
        "writes, edits or deletes a file" -> ["tour: write", "tour: edit", "tour: delete"]
        "generates an image" -> ["tour: image"]
        "reads a file or lists a folder" -> ["tour: read", "tour: ls"]
        "searches by name, text or meaning" -> ["tour: glob", "tour: grep", "tour: semsearch"]
        "reads the lint problems of a file" -> ["tour: lints"]
      end

    tour(context, triggers)
  end

  step ~r/^the thread shows (a file change naming the file|a file change naming the image file|a file search)$/,
       %{args: [shown]} = context do
    found = items(context)

    case shown do
      "a file change naming the file" ->
        names = for i <- found, i["type"] == "file_change", do: i["fileName"]
        assert "notes.txt" in names
        assert "app.ex" in names
        assert "old.txt" in names

      "a file change naming the image file" ->
        assert Enum.any?(found, &(&1["type"] == "file_change" and &1["fileName"] == "cat.png"))

      "a file search" ->
        assert Enum.any?(
                 found,
                 &(&1["type"] == "file_search" and is_list(&1["results"]) and
                     &1["results"] != [])
               )
    end

    context
  end

  step "Cursor calls the tool {string} of the MCP server {string}",
       %{args: [_tool, _server]} = context do
    tour(context, ["tour: mcp"])
  end

  step "the thread shows the tool call as {string}", %{args: [name]} = context do
    assert Enum.any?(items(context), &(&1["type"] == "dynamic_tool" and &1["toolName"] == name))
    context
  end

  step "a result the server marks as an error shows the call as failed", context do
    tools = Enum.filter(items(context), &(&1["type"] == "dynamic_tool"))
    assert Enum.any?(tools, &(&1["status"] == "completed"))
    assert Enum.any?(tools, &(&1["status"] == "failed"))
    context
  end

  step "Cursor counts the matches of a text search across files", context do
    tour(context, ["tour: grep-count"])
  end

  defp search_result(context, file) do
    items(context)
    |> Enum.filter(&(&1["type"] == "file_search"))
    |> Enum.flat_map(&(&1["results"] || []))
    |> Enum.find(&(&1["fileName"] == file))
  end

  step "a file with one match says {string}", %{args: [text]} = context do
    assert search_result(context, "a.ex")["preview"] == text
    context
  end

  step "a file with three matches says {string}", %{args: [text]} = context do
    assert search_result(context, "b.ex")["preview"] == text
    context
  end

  step "Cursor is running a long shell command", context do
    ctx = context |> ready_cursor() |> launch_cursor("stream a long command")

    Acp.await_stream(ctx.threads["Cursor"], fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "turn-item"),
        &(&1["type"] == "command_execution" and &1["status"] == "running")
      )
    end)

    ctx
  end

  step "the command prints output before it finishes", context do
    shown =
      Acp.await_stream(context.threads["Cursor"], fn state ->
        Enum.find(
          HalC2.StreamState.list(state, "turn-item"),
          &(&1["type"] == "command_execution" and &1["status"] == "running" and
              is_binary(&1["output"]) and &1["output"] =~ "compiling")
        )
      end)

    Map.put(context, :streamed_command, shown)
  end

  step "the output appears in the thread while the command is still running", context do
    assert context.streamed_command["output"] =~ "compiling"
    assert context.streamed_command["status"] == "running"
    File.write!(Path.join(Acp.dir(context), "cursor-cursor.release"), "")
    assert [%{"status" => "completed"}] = Acp.await_runs(context.threads["Cursor"], 1)
    context
  end

  step "Cursor edits a file", context do
    tour(context, ["tour: edit"])
  end

  step "the file change shows the diff", context do
    change = Enum.find(items(context), &(&1["type"] == "file_change"))
    assert change["diffStr"] =~ "+new line"
    Map.put(context, :change, change)
  end

  step "it shows how many lines were added and removed", context do
    assert context.change["additions"] == 2
    assert context.change["deletions"] == 1
    context
  end

  step "Cursor lists a folder with nested folders", context do
    tour(context, ["tour: ls"])
  end

  step "every file under it is listed with its path", context do
    files =
      items(context)
      |> Enum.filter(&(&1["type"] == "file_search"))
      |> Enum.flat_map(&(&1["results"] || []))
      |> Enum.map(& &1["fileName"])

    assert Enum.sort(files) == ["src/app.ex", "src/web/live.ex", "src/web/router.ex"]
    context
  end

  step "each problem is listed with its message, line and column", context do
    assert %{"fileName" => "app.ex", "line" => 5, "column" => 3, "preview" => "unused variable x"} =
             search_result(context, "app.ex")

    context
  end

  step "Cursor updates its to-do list with a cancelled item and an item with no text",
       context do
    tour(context, ["tour: todos"])
  end

  step "neither item appears in the task list", context do
    plans =
      context.threads["Cursor"]
      |> Acp.stream()
      |> HalC2.StreamState.list("plan")
      |> Enum.filter(&(&1["kind"] == "todo_list"))

    assert [%{"steps" => [%{"text" => "Keep me"}]}] = plans
    context
  end

  # --- subagents --------------------------------------------------------------------------

  defp subagent_of(context, title) do
    context.threads[title]
    |> Acp.stream()
    |> HalC2.StreamState.list("subagent")
    |> List.first()
  end

  step "Cursor hands a task to one of its subagents", context do
    ctx = tour(context, ["hand a task to a subagent"])
    Map.put(ctx, :sub_parent, "Cursor")
  end

  step "a child thread opens with the task as its first message", context do
    sub = subagent_of(context, "Cursor")
    assert sub["childThreadId"]

    messages =
      sub["childThreadId"]
      |> Acp.stream()
      |> HalC2.StreamState.list("message")

    assert Enum.any?(messages, &(&1["role"] == "user" and &1["text"] == "List the modules"))
    Map.put(context, :child, sub["childThreadId"])
  end

  step "the subagent's tool calls appear in the child thread", context do
    found =
      context.child
      |> Acp.stream()
      |> HalC2.StreamState.list("turn-item")

    assert Enum.any?(
             found,
             &(&1["type"] == "file_search" and &1["status"] == "completed")
           )

    context
  end

  step "the subagent's result is shown when it finishes", context do
    sub = subagent_of(context, "Cursor")
    assert sub["status"] == "completed"
    assert sub["result"] =~ "There are three modules."
    context
  end

  step ~r/^the subagent's (.+) comes back with (.+)$/, %{args: [tool_name, _empty]} = context do
    variant =
      case tool_name do
        "directory listing" -> "empty ls"
        "lint check" -> "empty lints"
        "MCP tool call" -> "empty mcp"
      end

    ctx = launch_cursor(context, "hand a task to a subagent with #{variant}", title: "Variant")
    Acp.await_runs(ctx.threads["Variant"], 1)
    Map.merge(ctx, %{sub_parent: "Variant", sub_tool: tool_name})
  end

  step "the parent run goes on", context do
    assert [%{"status" => "completed"}] = Acp.runs(context.threads["Variant"])
    assert Acp.assistant_text(context.threads["Variant"]) =~ "The survey is in."
    context
  end

  step ~r/^the child thread shows the (.+)$/, %{args: [tool_name]} = context do
    sub = subagent_of(context, "Variant")

    found =
      sub["childThreadId"]
      |> Acp.stream()
      |> HalC2.StreamState.list("turn-item")

    type = if tool_name == "MCP tool call", do: "dynamic_tool", else: "file_search"
    assert Enum.any?(found, &(&1["type"] == type and &1["status"] == "completed"))
    context
  end

  # --- images -------------------------------------------------------------------------------

  step "the user sends a Cursor message with a screenshot attached", context do
    ctx = context |> ready_cursor() |> launch_cursor("hello")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    png = Base.encode64("\x89PNG fake screenshot")

    {:ok, %{"attachments" => stored}} =
      HalC2.Attachments.persist(%{
        "threadId" => ctx.threads["Cursor"],
        "attachments" => [
          %{"dataUrl" => "data:image/png;base64,#{png}", "name" => "screenshot.png"}
        ]
      })

    ctx = Acp.follow_up(ctx, "Cursor", "what is in this screenshot?", %{"attachments" => stored})
    Acp.await_runs(ctx.threads["Cursor"], 2)
    ctx
  end

  step "Cursor receives the screenshot as an image with the message", context do
    send = log(context) |> Enum.filter(&(&1["event"] == "send")) |> List.last()
    assert [%{"mimeType" => "image/png", "bytes" => bytes}] = send["images"]
    assert bytes > 0
    context
  end

  # --- health, sign-in and accounts --------------------------------------------------------

  step "the user's Cursor account reports no email", context do
    Acp.control(context, "cursor-cursor", %{"noEmail" => true})
    Map.put(context, :cursor_world, true)
  end

  step "the user signs in to Cursor and finishes on the website", context do
    ctx = start_sign_in(context)
    {state, ctx} = waiting(ctx)
    finish_on_website(ctx, state["interaction"])
  end

  step "Cursor is signed in", context do
    assert File.exists?(credentials("cursor"))
    entry = Acp.check("cursor")
    assert entry["auth"]["status"] == "authenticated"
    # An account Cursor gives no email for still has a name to show.
    assert entry["auth"]["label"] == "Cursor account"
    assert entry["auth"]["email"] == nil
    Map.put(context, :told, entry["message"])
  end

  step "the user is not told the sign-in could not be saved", context do
    refute (context.told || "") =~ "could not be saved"
    refute (context.told || "") =~ "Could not save"
    context
  end

  step ~r/^(Cursor is turned off in the provider settings|the MC is still looking for Cursor|Cursor has neither a sign-in nor a CURSOR_API_KEY|a browser sign-in was rejected by Cursor|the CURSOR_API_KEY was rejected by Cursor|the Cursor model catalog request fails for another reason)$/,
       %{args: [situation]} = context do
    ctx = ops(context)

    case situation do
      "Cursor is turned off in the provider settings" ->
        Acp.put_provider("cursor", %{"enabled" => false})

      "the MC is still looking for Cursor" ->
        Acp.control(ctx, "cursor-cursor", %{"hangInitialize" => true})
        Acp.put_provider("cursor", %{"enabled" => true})

      "Cursor has neither a sign-in nor a CURSOR_API_KEY" ->
        {_entry, _ctx} = enabled(ctx)

      "a browser sign-in was rejected by Cursor" ->
        sign_in("cursor")
        Acp.control(ctx, "cursor-cursor", %{"revoked" => true})
        {_entry, _ctx} = enabled(ctx)

      "the CURSOR_API_KEY was rejected by Cursor" ->
        Acp.put_instance("cursor", %{
          "driver" => "cursor",
          "enabled" => true,
          "environment" => [%{"name" => "CURSOR_API_KEY", "value" => "revoked"}]
        })

        Acp.check("cursor")

      "the Cursor model catalog request fails for another reason" ->
        sign_in("cursor")
        Acp.control(ctx, "cursor-cursor", %{"catalogError" => true})
        {_entry, _ctx} = enabled(ctx)
    end

    Map.put(ctx, :cursor_world, true)
  end

  step "Cursor is shown with the message {string}", %{args: [message]} = context do
    entry = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))
    assert entry["message"] == message
    context
  end

  step "the user signs in to Cursor with a free-plan account", context do
    ctx = ops(context)
    Acp.control(ctx, "cursor-cursor", %{"freePlan" => true})
    {_entry, ctx} = enabled(ctx)
    ctx = start_sign_in(ctx)
    {state, ctx} = waiting(ctx)
    ctx |> Map.put(:interaction, state["interaction"]) |> Map.put(:cursor_world, true)
  end

  step "Cursor rejects the account", context do
    # The user finished on the website; Cursor then refuses the account.
    File.write!(Path.join(Acp.dir(context), "cursor-cursor.login-done"), "")

    {_, ctx} =
      World.call!(
        context,
        "provider.auth.respond",
        %{
          "instanceId" => "cursor",
          "flowId" => context.flow,
          "interactionId" => context.interaction["id"],
          "response" => %{"type" => "browser", "action" => "accept"}
        },
        "ops"
      )

    {state, ctx} = await_phase(ctx, "failed")
    Map.put(ctx, :sign_in_message, state["message"] || "")
  end

  step "Cursor's status and the sign-in say a paid Cursor plan is needed", context do
    assert context.sign_in_message =~ "paid Cursor plan"
    entry = Acp.check("cursor")
    assert entry["message"] =~ "paid Cursor plan"
    assert entry["status"] == "error"
    context
  end

  step "the rejected sign-in is not kept", context do
    refute File.exists?(credentials("cursor"))
    context
  end

  step "the user's Cursor team has turned off the account details endpoint", context do
    sign_in("cursor")
    ctx = ops(context)
    Acp.control(ctx, "cursor-cursor", %{"meError" => "blocked"})
    {_entry, ctx} = enabled(ctx)
    Map.put(ctx, :cursor_world, true)
  end

  step "Cursor is ready with its models", context do
    entry = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))
    assert entry["status"] == "ready"
    assert Enum.map(entry["models"], & &1["slug"]) == ["default", "composer-2", "gpt-5"]
    context
  end

  step "the account shows as {string} or {string} without an email",
       %{args: [_first, _second]} = context do
    entry = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))
    assert entry["auth"]["label"] in ["Cursor account", "Cursor API key"]
    assert entry["auth"]["email"] == nil
    context
  end

  step "a rejected sign-in or key still fails as an authentication error", context do
    Acp.control(context, "cursor-cursor", %{"meError" => "blocked", "revoked" => true})
    entry = Acp.check("cursor")
    assert entry["auth"]["status"] == "unauthenticated"
    assert entry["message"] =~ "expired or was rejected"
    context
  end

  step "the user has a CURSOR_API_KEY", context do
    api_key_instance(context) |> Map.put(:cursor_world, true)
  end

  step "the Cursor model catalog request does not finish in time", context do
    Acp.control(context, "cursor-cursor", %{"catalogHang" => true, "catalogTimeoutMs" => 300})
    Acp.check("cursor")
    context
  end

  step "Cursor is shown as unavailable with a message that the catalog request timed out",
       context do
    entry = Enum.find(context.providers, &(&1["instanceId"] == "cursor"))
    assert entry["status"] == "error"
    assert entry["message"] =~ "timed out"
    context
  end

  step ~r/^(the MC cannot open its store of Cursor logins|Cursor cannot confirm the saved sign-in)$/,
       %{args: [situation]} = context do
    ctx = ops(context)
    # Confirming a sign-in needs one saved; opening the store does not get that far.
    if situation =~ "cannot confirm", do: sign_in("cursor")

    control =
      if situation =~ "cannot open", do: %{"storeBroken" => true}, else: %{"meError" => "boom"}

    Acp.control(ctx, "cursor-cursor", control)
    Map.put(ctx, :cursor_world, true)
  end

  step "the MC checks Cursor", context do
    {entry, ctx} = enabled(context)
    # What the user was told is the checked entry's message (`context.told`).
    Map.put(ctx, :told, entry["message"])
  end

  step "an older Cursor login file exists", context do
    ctx = ops(context)
    legacy = Path.join([HalC2.Test.Mc.Host.home(ctx), ".cursor", "sdk", "auth.json"])

    # The scenario's scratch home only: this file stands in for the developer's
    # real Cursor SDK login, which a test must never write or delete.
    unless String.starts_with?(legacy, ctx.mc.home <> "/") do
      raise "refusing to write a fake Cursor login outside the scenario home: #{legacy}"
    end

    File.mkdir_p!(Path.dirname(legacy))

    File.write!(
      legacy,
      JSON.encode!(%{
        "version" => 1,
        "backendUrl" => "https://example.test",
        "apiKey" => "cursor-key",
        "createdAtMs" => 1
      })
    )

    ctx |> Map.put(:legacy_auth, legacy) |> Map.put(:cursor_world, true)
  end

  step "Cursor starts for the first time on this version", context do
    sign_in_file = credentials("cursor")
    File.rm(sign_in_file)
    {_entry, ctx} = enabled(context)
    ctx
  end

  step "the login is copied into the MC's secrets and the old file is left where it was",
       context do
    assert File.exists?(credentials("cursor"))
    assert JSON.decode!(File.read!(credentials("cursor")))["apiKey"] == "cursor-key"
    assert Acp.check("cursor")["auth"]["status"] == "authenticated"
    # The SDK's own file stays for the other clients that read it.
    assert File.exists?(context.legacy_auth)
    context
  end

  # --- text generation -----------------------------------------------------------------------

  step "the user has reached a Cursor usage limit", context do
    Acp.control(context, "cursor-cursor", %{"usageLimit" => true})
    Map.put(context, :cursor_world, true)
  end

  step "the failure says the Cursor usage limit was reached", context do
    assert {:error, error, _detail} = context.reply
    assert error =~ "Cursor usage limit reached"
    Map.put(context, :failure, error)
  end

  step "it says to try again later or choose another text-generation provider", context do
    assert context.failure =~ "Try again later or choose another text-generation provider."
    context
  end

  step "generating a title fails only because Cursor's sandbox blocks it", context do
    Acp.control(context, "cursor-cursor", %{"sandboxBlocksTextGen" => true})
    Map.put(context, :cursor_world, true)
  end

  step "the MC retries the request", context do
    root = World.project(context).root
    result = HalC2.TextGeneration.thread_title(root, "Fix the parser")
    Map.put(context, :title_result, result)
  end

  step "the retry removes only the restriction that blocked it", context do
    text_runs = Enum.filter(agents(context), &(&1["settingSources"] == []))
    # Two runs, the second without the sandbox and otherwise the same
    # read-only, settings-free text generation run.
    assert Enum.map(text_runs, & &1["sandbox"]) == [true, false]
    assert Enum.all?(text_runs, &(&1["mode"] == "plan" and &1["autoReview"] == false))
    context
  end

  step "the thread gets its title", context do
    assert {:ok, %{"title" => "cursor title"}} = context.title_result
    context
  end

  # --- skill discovery -----------------------------------------------------------------------

  defp write_skill(dir, header \\ "", body \\ "Run it.\n") do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\n#{header}---\n#{body}")
    dir
  end

  # The composer opening a Cursor thread's skill list: a workspace refresh,
  # whose reply and provider list are kept for the steps that read them.
  defp open_cursor_skills(context) do
    ctx = ops(context)
    root = World.project(ctx).root

    {reply, ctx} =
      World.call(
        ctx,
        "server.refreshProviders",
        %{"instanceId" => "cursor", "cwd" => root},
        "ops"
      )

    ctx = Map.put(ctx, :reply, reply)

    case reply do
      {:ok, result} -> Map.put(ctx, :providers, result["providers"])
      _ -> ctx
    end
  end

  defp listed_cursor_skills(context) do
    root = World.project(context).root
    entry = Enum.find(context.providers || [], &(&1["instanceId"] == "cursor")) || %{}

    case Enum.filter(entry["workspaceSnapshots"] || [], &(&1["cwd"] == root)) do
      [%{"skills" => skills}] -> skills
      _ -> []
    end
  end

  defp listed_skill(context, name),
    do: Enum.find(listed_cursor_skills(context), &(&1["name"] == name))

  step "the user opens the skill list in a Cursor thread", context do
    open_cursor_skills(context)
  end

  step "the user lists Cursor's skills", context do
    open_cursor_skills(context)
  end

  step "the MC reads the Cursor skills", context do
    open_cursor_skills(context)
  end

  step "Cursor's built-in skill {string} in {string} of the user's home",
       %{args: [name, folder]} = context do
    write_skill(Path.join([HalC2.Test.Mc.Host.home(context), folder, name]))
    context
  end

  step "the project has its own skill {string}", %{args: [name]} = context do
    cursor_skill(context, name)
    context
  end

  step "Cursor's built-in skills are offered as system skills", context do
    # Where no project skill of the name stands in front of it, the built-in
    # skill is listed with the system scope.
    elsewhere = Path.join(context.mc.home, "elsewhere")
    File.mkdir_p!(elsewhere)

    {reply, ctx} =
      World.call(
        context,
        "server.refreshProviders",
        %{"instanceId" => "cursor", "cwd" => elsewhere},
        "ops"
      )

    assert {:ok, result} = reply
    entry = Enum.find(result["providers"] || [], &(&1["instanceId"] == "cursor")) || %{}

    [%{"skills" => skills}] =
      Enum.filter(entry["workspaceSnapshots"] || [], &(&1["cwd"] == elsewhere))

    assert Enum.find(skills, &(&1["name"] == "review"))["scope"] == "system"
    ctx
  end

  step "{string} is the project's skill", %{args: [name]} = context do
    assert listed_skill(context, name)["scope"] == "project"
    context
  end

  step "the skill {string} exists in the project and in the user's home",
       %{args: [name]} = context do
    write_skill(
      Path.join([World.project(context).root, ".cursor", "skills", name]),
      "description: from the project\n"
    )

    write_skill(
      Path.join([HalC2.Test.Mc.Host.home(context), ".cursor", "skills", name]),
      "description: from the user's home\n"
    )

    context
  end

  step "the project has a Cursor skill whose header limits it to surfaces other than the CLI",
       context do
    write_skill(
      Path.join([World.project(context).root, ".cursor", "skills", "ide-only"]),
      "metadata:\n  surfaces: [ide, web]\n"
    )

    Map.put(context, :cursor_skill_name, "ide-only")
  end

  step "the project has a Cursor skill whose header forbids the model from starting it",
       context do
    write_skill(
      Path.join([World.project(context).root, ".cursor", "skills", "by-hand"]),
      "disable-model-invocation: true\n"
    )

    Map.put(context, :cursor_skill_name, "by-hand")
  end

  step "the skill is offered as one only the user can run", context do
    assert listed_skill(context, context.cursor_skill_name)["userInvocationOnly"] == true
    context
  end

  step "the user's {string} holds a folder tree deeper than the scan reaches",
       %{args: [folder]} = context do
    deep =
      Enum.reduce(1..12, Path.join([HalC2.Test.Mc.Host.home(context), folder]), fn i, dir ->
        Path.join(dir, "level#{i}")
      end)

    write_skill(Path.join(deep, "buried"))
    context
  end

  step "skills inside the too-deep part of the tree are not", context do
    assert {:ok, _} = context.reply
    refute listed_skill(context, "buried")
    context
  end

  step ~r/^the user's "([^"]+)" is a link to "([^"]+)"$/, %{args: [link, target]} = context do
    home = HalC2.Test.Mc.Host.home(context)
    link_path = Path.join(home, String.trim_leading(link, "~/"))
    File.mkdir_p!(Path.dirname(link_path))
    File.ln_s!(Path.join(home, String.trim_leading(target, "~/")), link_path)
    context
  end

  step ~r/^"([^"]+)" holds 6,000 entries including the skill "([^"]+)"$/,
       %{args: [folder, name]} = context do
    root = Path.join(HalC2.Test.Mc.Host.home(context), String.trim_leading(folder, "~/"))
    write_skill(Path.join(root, name))
    for i <- 1..5_999, do: File.mkdir!(Path.join(root, "d#{i}"))
    context
  end

  step "{string} is offered once", %{args: [name]} = context do
    assert Enum.count(listed_cursor_skills(context), &(&1["name"] == name)) == 1
    context
  end

  step "the skill search is not reported as incomplete", context do
    assert {:ok, _} = context.reply
    context
  end

  step "a Cursor skill folder holds an installed \"node_modules\" with thousands of files",
       context do
    dir = Path.join([World.project(context).root, ".cursor", "skills", "withdeps"])
    write_skill(dir)
    modules = Path.join([dir, "node_modules", "pkg"])
    File.mkdir_p!(modules)
    for i <- 1..2_000, do: File.write!(Path.join(modules, "f#{i}.js"), "")
    write_skill(Path.join(modules, "hidden"))
    context
  end

  step "other skills sit beside it", context do
    write_skill(Path.join([World.project(context).root, ".cursor", "skills", "beside"]))
    context
  end

  step "every skill is listed", context do
    assert listed_skill(context, "withdeps")
    assert listed_skill(context, "beside")
    context
  end

  step "nothing inside \"node_modules\" is searched for skills", context do
    refute listed_skill(context, "hidden")
    context
  end

  step "the project has the Cursor skills {string} and {string}",
       %{args: [first, second]} = context do
    cursor_skill(context, first)
    cursor_skill(context, second)
    context
  end

  step "{string} holds 11,000 files under its \"artifacts\" folder",
       %{args: [name]} = context do
    artifacts =
      Path.join([World.project(context).root, ".cursor", "skills", name, "artifacts"])

    File.mkdir_p!(artifacts)
    for i <- 1..11_000, do: File.write!(Path.join(artifacts, "a#{i}.txt"), "")
    context
  end

  step "{string} and {string} are both listed", %{args: [first, second]} = context do
    assert listed_skill(context, first)
    assert listed_skill(context, second)
    context
  end

  step "Cursor's provider check passes", context do
    assert {:ok, _} = context.reply
    context
  end

  step ~r/^(the skill folders hold more than 10,000 entries|the skill folders hold more than 8 MB of skill files|a skill folder cannot be read)$/,
       %{args: [situation]} = context do
    root = Path.join([World.project(context).root, ".cursor", "skills"])
    File.mkdir_p!(root)

    case situation do
      "the skill folders hold more than 10,000 entries" ->
        for i <- 1..10_001, do: File.mkdir!(Path.join(root, "d#{i}"))

      "the skill folders hold more than 8 MB of skill files" ->
        # Nine readable skill files just under the per-file limit: the byte
        # budget runs out part-way (a genuinely deep tree alone never does;
        # depth is its own scenario above).
        for i <- 1..9 do
          write_skill(
            Path.join(root, "s#{i}"),
            "description: skill #{i}\n",
            String.duplicate("x", 950_000)
          )
        end

      "a skill folder cannot be read" ->
        locked = Path.join(root, "locked")
        File.mkdir_p!(locked)
        File.chmod!(locked, 0o000)
        ExUnit.Callbacks.on_exit(fn -> File.chmod(locked, 0o755) end)
    end

    context
  end

  step ~r/^reading fails saying skill discovery was incomplete because of (\S+)$/,
       %{args: [reason]} = context do
    assert {:error, message, _detail} = World.normalize_reply(context.reply)
    assert message =~ "was incomplete"
    assert message =~ reason
    context
  end

  step "the user sends {string} to Cursor", %{args: [text]} = context do
    sign_in("cursor")
    {_entry, ctx} = enabled(context)
    ctx = Acp.launch(ctx, "Cursor", "cursor", text)
    Acp.await_runs(ctx.threads["Cursor"], 1)
    [%{"message" => message}] = Enum.filter(log(ctx), &(&1["event"] == "send"))
    Map.merge(ctx, %{thread: "Cursor", sent_message: message})
  end

  step "{string} reaches Cursor as a skill reference", %{args: [name]} = context do
    assert context.sent_message =~ "/#{name}"
    context
  end

  step "{string} reaches Cursor as typed", %{args: [text]} = context do
    assert context.sent_message =~ text
    context
  end

  step "the project keeps the skill {string} in {string} under {string}",
       %{args: [name, subfolder, folder]} = context do
    write_skill(Path.join([World.project(context).root, folder, subfolder]))
    Map.put(context, :cursor_skill_name, name)
  end

  step "the project has a Cursor skill in the folder {string} whose header names it {string}",
       %{args: [folder, shown]} = context do
    write_skill(
      Path.join([World.project(context).root, ".cursor", "skills", folder]),
      "name: #{shown}\n"
    )

    Map.put(context, :cursor_skill_name, folder)
  end

  step "the skill is shown as {string}", %{args: [shown]} = context do
    assert listed_skill(context, context.cursor_skill_name)["displayName"] == shown
    context
  end

  step "the user mentions it as {string}", %{args: [name]} = context do
    assert listed_skill(context, name)
    context
  end

  step "{string} holds a link {string} to a skill kept elsewhere on the machine",
       %{args: [folder, link]} = context do
    kept = Path.join([context.mc.home, "elsewhere", "kept"])
    write_skill(kept)
    skills = Path.join([World.project(context).root, folder])
    File.mkdir_p!(skills)
    File.ln_s!(kept, Path.join(skills, link))
    Map.put(context, :kept_skill, kept)
  end

  step "that skill's own folder holds further skills below it", context do
    write_skill(Path.join(context.kept_skill, "nested"))
    context
  end

  step "the skills below it are not searched for", context do
    refute listed_skill(context, "nested")
    context
  end

  step "the project has a Cursor skill whose header is not valid", context do
    write_skill(
      Path.join([World.project(context).root, ".cursor", "skills", "broken"]),
      "name: \"unclosed\n"
    )

    cursor_skill(context, "deploy")
    Map.put(context, :cursor_skill_name, "broken")
  end

  step "the project has a Cursor skill {string} whose skill file is larger than 1 MB",
       %{args: [name]} = context do
    write_skill(
      Path.join([World.project(context).root, ".cursor", "skills", name]),
      "name: The Manual\ndescription: Big\n",
      String.duplicate("x", 1_100_000)
    )

    context
  end

  step "{string} is offered under its folder's name with no description",
       %{args: [name]} = context do
    skill = listed_skill(context, name)
    assert skill
    refute Map.has_key?(skill, "description")
    refute Map.has_key?(skill, "displayName")
    context
  end

  step "the project has a Cursor skill whose header says the user cannot start it", context do
    write_skill(
      Path.join([World.project(context).root, ".cursor", "skills", "agent-only"]),
      "user-invocable: false\n"
    )

    Map.put(context, :cursor_skill_name, "agent-only")
  end

  step "the skill is listed as one the user cannot start", context do
    assert listed_skill(context, context.cursor_skill_name)["userInvocable"] == false
    context
  end

  # --- workspace and subagents setting -------------------------------------------------------

  defp project_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&String.contains?(&1, "/.git/"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  step "a Cursor thread in a project folder", context do
    ctx = ready_cursor(context)
    Map.put(ctx, :files_before, project_files(World.project(ctx).root))
  end

  step "a Cursor turn runs", context do
    ctx = launch_cursor(context, "hello")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the project folder gains no files generated for Cursor", context do
    assert project_files(World.project(context).root) == context.files_before
    context
  end

  step "a Cursor session is started", context do
    tour(context, ["hand a task to a subagent"])
  end

  step "Cursor starts as usual, because it has no switch for its subagents", context do
    assert [%{"status" => "completed"}] = Acp.runs(context.threads["Cursor"])
    # Its own subagent still ran, in its own child thread, untouched by the setting.
    assert subagent_of(context, "Cursor")["childThreadId"]
    assert Enum.all?(agents(context), &(&1["mode"] == "agent"))
    context
  end

  # --- protocol log --------------------------------------------------------------------------

  step "protocol logging is on", context do
    previous = Application.get_env(:hal_c2, :provider_event_log)
    Application.put_env(:hal_c2, :provider_event_log, true)

    ExUnit.Callbacks.on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:hal_c2, :provider_event_log),
        else: Application.put_env(:hal_c2, :provider_event_log, previous)
    end)

    context
  end

  step "a Cursor turn starts in a thread that has the HAL-C2 tools", context do
    Mc.ensure(HalC2.Mcp)
    ctx = ready_cursor(context)
    ctx = launch_cursor(ctx, "hello", model: "gpt-5")
    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "Cursor is offered them as the MCP server {string}", %{args: [name]} = context do
    assert [%{"mcpServers" => servers}] = Enum.filter(log(context), &(&1["event"] == "send"))
    assert name in servers
    context
  end

  defp protocol_log(context) do
    context.threads["Cursor"] |> HalC2.ProviderLog.path() |> File.read!()
  end

  step "the protocol log records the model and mode of the run", context do
    options =
      context
      |> protocol_log()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        line |> String.split("NTIVE: ", parts: 2) |> List.last() |> JSON.decode!()
      end)
      |> Enum.find(&(&1["kind"] == "session-options"))

    assert options["model"] == "gpt-5"
    assert options["permissionMode"] == "full-access"
    assert options["mcpServers"] == ["hal-c2"]
    context
  end

  step "it holds neither the Cursor API key nor the HAL-C2 tools credential", context do
    log = protocol_log(context)
    refute log =~ "cursor-key"

    %{authorization: "Bearer " <> token} =
      HalC2.Mcp.current(context.threads["Cursor"], "cursor")

    refute log =~ token
    refute log =~ "Bearer"
    context
  end

  # --- the user's own MCP servers --------------------------------------------------------------

  defp mcp_settings(dir, servers) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "mcp.json"),
      JSON.encode!(%{"mcpServers" => Map.new(servers, &{&1, %{"command" => "true"}})})
    )
  end

  step "the user's Cursor settings, the project and a Cursor plugin each configure an MCP server",
       context do
    home = HalC2.Test.Mc.Host.home(context)
    mcp_settings(Path.join([home, ".cursor"]), ["user-tools"])
    mcp_settings(Path.join([World.project(context).root, ".cursor"]), ["project-tools"])
    mcp_settings(Path.join([home, ".cursor", "plugins", "demo"]), ["plugin-tools"])
    Map.put(context, :cursor_world, true)
  end

  step "the user sends a message on a Cursor thread", context do
    Mc.ensure(HalC2.Mcp)
    context |> ready_cursor() |> run_on_cursor("full-access")
  end

  step "the Cursor agent can use those MCP servers and HAL-C2's MCP server", context do
    assert [%{"mcpServers" => servers}] = Enum.filter(log(context), &(&1["event"] == "send"))
    assert servers == ["hal-c2", "plugin-tools", "project-tools", "user-tools"]
    context
  end

  # --- subagent effort -----------------------------------------------------------------------

  step "Cursor starts a subagent with high reasoning effort", context do
    ctx = ready_cursor(context)

    ctx =
      Acp.launch(ctx, "Cursor", "cursor", "hand a task to a subagent",
        model: "gpt-5",
        options: [%{"id" => "reasoning_effort", "value" => "high"}]
      )

    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "Cursor starts a subagent on another model than its high-effort parent", context do
    ctx = ready_cursor(context)

    ctx =
      Acp.launch(ctx, "Cursor", "cursor", "hand a task to a subagent on another model",
        model: "gpt-5",
        options: [%{"id" => "reasoning_effort", "value" => "high"}]
      )

    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step "the card names no effort", context do
    assert context.subagent_card["model"] == "composer-2"
    refute Enum.any?(context.subagent_card["options"] || [], &(&1["id"] == "reasoning_effort"))
    context
  end

  step "the user looks at the subagent's card", context do
    child = subagent_of(context, "Cursor")["childThreadId"]
    thread = HalC2.StreamState.get(Acp.stream(child), "thread")[child]
    Map.put(context, :subagent_card, thread["modelSelection"])
  end

  step "the card reads the effort {string}", %{args: [label]} = context do
    assert %{"id" => "reasoning_effort", "value" => value} =
             Enum.find(context.subagent_card["options"] || [], &(&1["id"] == "reasoning_effort"))

    assert String.capitalize(value) == label
    context
  end

  # --- a subagent that never reported back ---------------------------------------------------

  step "a Cursor subagent is still working", context do
    ctx = ready_cursor(context)
    ctx = launch_cursor(ctx, "hand a task to a subagent and say nothing more about it")

    Acp.await_stream(ctx.threads["Cursor"], fn _ -> subagent_of(ctx, "Cursor") end)
    ctx
  end

  step ~r/^the Cursor run (finishes|is cancelled|fails|is stopped by the user) without the subagent reporting a result$/,
       %{args: [ends]} = context do
    {release, ctx} =
      case ends do
        "finishes" -> {"finished", context}
        "is cancelled" -> {"cancelled", context}
        "fails" -> {"error", context}
        "is stopped by the user" -> {nil, context}
      end

    ctx =
      if release do
        Acp.control(ctx, "cursor-cursor", %{"releaseRun" => release})
        ctx
      else
        {:ok, _} =
          HalC2.Orchestration.dispatch(%{
            "type" => "run.interrupt",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => ctx.threads["Cursor"]
          })

        ctx
      end

    Acp.await_runs(ctx.threads["Cursor"], 1)
    ctx
  end

  step ~r/^the Cursor subagent is shown as (idle|cancelled|failed|interrupted)$/,
       %{args: [shown]} = context do
    # A finished run leaves its subagent completed — its thread idle, with
    # nothing left running in it.
    expected = if shown == "idle", do: "completed", else: shown
    sub = subagent_of(context, "Cursor")
    assert sub["status"] == expected

    child = Acp.stream(sub["childThreadId"])

    refute Enum.any?(
             HalC2.StreamState.list(child, "turn-item"),
             &(&1["status"] == "running")
           )

    context
  end
end
