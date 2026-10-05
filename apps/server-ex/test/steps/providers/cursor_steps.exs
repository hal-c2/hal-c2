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
  # whose `id` entry matches `fun`.
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
        end,
        5_000
      )

    {Enum.find(frame["providers"], &(&1["instanceId"] == id)), World.put_client(ctx, client)}
  end

  defp watch_providers(ctx) do
    sub = 5000 + System.unique_integer([:positive])

    client =
      Mc.sub(World.client(ctx), sub, %{"type" => "config", "mc" => Atom.to_string(node())})

    {_, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == sub), 5_000)
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
    {:ok, expires, _} = DateTime.from_iso8601(state["expiresAt"])
    left = DateTime.to_unix(expires, :millisecond) - started
    assert left in 299_000..301_000, "the sign-in expires in #{left}ms"
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

  # The agent of the thread works in the project with Cursor's project settings on,
  # which is where the SDK reads the rules and skills from.
  step "Cursor receives the project's skills and rules", context do
    root = World.project(context).root

    assert [%{"cwd" => ^root, "settingSources" => nil, "loaded" => loaded}] =
             Enum.filter(agents(context), &(&1["mode"] == "agent" and &1["cwd"] == root))

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
    assert [%{"status" => "interrupted"}] = Acp.await_runs(context.threads["Cursor"], 1)
    assert [%{"input" => "npm test", "status" => "interrupted"}] = commands(context)
    context
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
    assert [%{"input" => "nosuchtool --version", "status" => "failed", "output" => output}] =
             commands(context)

    assert output =~ "ENOENT"
    context
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
end
