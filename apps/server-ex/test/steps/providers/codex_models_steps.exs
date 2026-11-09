defmodule HalC2.Steps.Providers.CodexModels do
  @moduledoc """
  More steps for `features/providers/codex.feature`: Codex's models, reasoning levels
  and service tiers, its check's budget, ChatGPT plan limits and a subagent's own
  effort. They run on `fake_codex.py` (and its `fake_codex_models.py`) as
  `HalC2.Steps.Providers.Codex` does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @thread "Codex work"
  @sol "gpt-6.1-sol"

  # --- the check's budget ------------------------------------------------------------------

  # The check runs at a fifth of real time here: its 20 second budget is four seconds,
  # and the fake's start is delayed by a fifth of `seconds`.
  step "the Codex command answers its status check after {int} seconds",
       %{args: [seconds]} = context do
    context = World.fake_providers(context)
    World.put_app_env(:codex_probe_time_scale, 0.2)
    World.put_os_env("FAKE_CODEX_PROBE_DELAY_MS", Integer.to_string(seconds * 200))
    context
  end

  step "Codex is shown as available", context do
    entry = codex(context.providers)
    assert entry["status"] == "ready", inspect(entry)
    assert entry["availability"] == "available"
    context
  end

  # --- models the installed Codex does not know yet --------------------------------------

  step "Codex is signed in with a ChatGPT account", context do
    context = World.fake_providers(context)
    World.put_os_env("FAKE_CODEX_ACCOUNT", "chatgpt")
    context
  end

  # Codex's model list is the account's catalog as Codex fetched it, efforts and all.
  step "the account's model catalog lists a model the installed Codex does not know yet",
       context do
    catalog(context, [
      sol(%{
        "defaultReasoningEffort" => "low",
        "supportedReasoningEfforts" => [
          %{"reasoningEffort" => "low", "description" => "Fast"},
          %{"reasoningEffort" => "high", "description" => "Deep"}
        ]
      })
    ])
  end

  @doc "The options of the catalog's model, for Pi's step of the same words (`pi_steps.exs`)."
  def open_model_options(context) do
    HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)
    Map.put(context, :descriptors, descriptors(providers, @sol))
  end

  step "the reasoning levels the catalog lists for it are offered", context do
    reasoning = Enum.find(context.descriptors, &(&1["id"] == "reasoningEffort"))

    assert reasoning["options"] == [
             %{"id" => "low", "label" => "Low", "isDefault" => true},
             %{"id" => "high", "label" => "High"}
           ]

    assert reasoning["currentValue"] == "low"
    context
  end

  # --- service tiers ---------------------------------------------------------------------

  step "the selected Codex model lists the {string} service tier", %{args: [tier]} = context do
    context = World.fake_providers(context)

    models = [
      %{
        "model" => @sol,
        "displayName" => "GPT-6.1 Sol",
        "serviceTiers" => [%{"id" => tier, "name" => "Ultrafast", "description" => "Faster"}]
      }
    ]

    World.put_os_env("FAKE_CODEX_MODELS", JSON.encode!(models))
    context
  end

  step "the user opens the service tier choices", context do
    HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)
    Map.put(context, :descriptors, descriptors(providers, @sol))
  end

  step "{string} is offered with the description {string}",
       %{args: [label, description]} = context do
    assert %{"description" => ^description} =
             Enum.find(tier_options(context.descriptors), &(&1["label"] == label))

    context
  end

  step "Codex's global config sets the service tier to fast", context do
    context = World.fake_providers(context)
    World.put_os_env("FAKE_CODEX_SERVICE_TIER", "fast")

    # Fast by today's id ("priority") on one model; the other has only Flex.
    models = [
      %{
        "model" => @sol,
        "displayName" => "GPT-6.1 Sol",
        "serviceTiers" => [%{"id" => "priority", "name" => "Fast"}]
      },
      %{
        "model" => "gpt-5.5",
        "displayName" => "GPT-5.5",
        "serviceTiers" => [%{"id" => "flex", "name" => "Flex"}]
      }
    ]

    World.put_os_env("FAKE_CODEX_MODELS", JSON.encode!(models))
    context
  end

  step "the user opens the service tier choices for a model that offers Fast", context do
    HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "Fast is shown as selected", context do
    tier = tier_descriptor(descriptors(context.providers, @sol))
    assert tier["currentValue"] == "priority"
    assert [%{"label" => "Fast"}] = Enum.filter(tier["options"], & &1["isDefault"])
    context
  end

  step "a model that does not offer Fast keeps its own default", context do
    tier = tier_descriptor(descriptors(context.providers, "gpt-5.5"))
    assert tier["currentValue"] == "default"
    assert [%{"label" => "Standard"}] = Enum.filter(tier["options"], & &1["isDefault"])
    context
  end

  # --- Ultrafast and the shared catalog ----------------------------------------------------

  step "the ChatGPT account is entitled to the Ultrafast tier", context do
    entitled(context, true)
  end

  # The plain CLI's catalog, fresh enough that Codex would serve it as it is.
  step "another Codex client on the machine wrote a model catalog without it", context do
    catalog(context, [sol(%{"serviceTiers" => tiers(["priority"])})], -60)
  end

  step "the ChatGPT account was entitled to the Ultrafast tier and no longer is", context do
    context = entitled(context, false)
    catalog(context, [sol(%{"serviceTiers" => tiers(["priority", "ultrafast"])})], -60)
  end

  step "the MC checks Codex's models", context do
    HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "the models still list the Ultrafast tier", context do
    assert "ultrafast" in tier_ids(context.providers)
    context
  end

  step "the models no longer list the Ultrafast tier", context do
    assert tier_ids(context.providers) == ["default", "priority"]
    context
  end

  step "a thread set to Ultrafast stays on Ultrafast", context do
    selection = %{
      "instanceId" => "codex",
      "model" => @sol,
      "options" => [%{"id" => "serviceTier", "value" => "ultrafast"}]
    }

    context =
      World.launch_on(context, @thread, "codex", "hello", %{"modelSelection" => selection})

    turn =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))

    assert get_in(turn, ["in", "params", "serviceTier"]) == "ultrafast"
    assert World.thread(context, @thread)["modelSelection"]["options"] == selection["options"]
    context
  end

  # --- ChatGPT plan limits -----------------------------------------------------------------

  @personal "subscription_sharing_usage_limit_exceeded"
  @workspace "subscription_sharing_workplace_individual_usage_limit_exceeded"

  step "Codex is signed in with a ChatGPT Business workspace", context do
    context = World.fake_providers(context)
    World.put_os_env("FAKE_CODEX_PLAN", "business")
    Map.put(context, :sharing_code, @workspace)
  end

  # Codex passes ChatGPT's code on in the error's details, under a generic error of its own.
  step "a turn stops because the plan's limit for other apps is reached", context do
    context = start_waiting(context)
    {_, runtime} = World.codex_runtime(context, @thread)

    error = %{
      "message" => "Codex could not continue.",
      "codexErrorInfo" => "other",
      "additionalDetails" => Map.get(context, :sharing_code, @personal)
    }

    World.codex_notify(
      context,
      @thread,
      "error",
      Map.merge(ctx_params(context), %{"willRetry" => false, "error" => error})
    )

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "failed", "error" => error}
    })

    World.await_runs(context, @thread, ["failed"])
    context
  end

  # Clients offer the recovery by the code the thread's row carries.
  step "the thread shows the ChatGPT limit with {string}", %{args: [action]} = context do
    {code, message} =
      case action do
        "Manage usage" ->
          {@personal,
           "Your ChatGPT usage limit was reached. Check ChatGPT Usage settings for your available allowance."}

        "Copy request for admin" ->
          {@workspace,
           "You reached your workspace's limit for using ChatGPT in other apps. Ask your workspace admin to increase it."}
      end

    row = World.await_row(World.thread_id(context, @thread), &(&1["lastErrorCode"] == code))
    assert row["lastErrorClass"] == "usage_limit"
    assert row["lastError"] == message
    context
  end

  # --- a subagent's own effort -------------------------------------------------------------

  step "a Codex thread with reasoning effort {string}", %{args: [effort]} = context do
    selection = %{
      "instanceId" => "codex",
      "model" => "gpt-5.4",
      "options" => [%{"id" => "reasoningEffort", "value" => effort}]
    }

    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "codex", "wait for me", %{"modelSelection" => selection})
    |> await_turn()
  end

  step "Codex starts a subagent that reports effort {string}", %{args: [effort]} = context do
    spawn_subagent(context, %{"reasoningEffort" => effort})
  end

  step "Codex starts a subagent that reports no effort", context do
    spawn_subagent(context, %{})
  end

  step "the subagent's thread shows reasoning effort {string}", %{args: [effort]} = context do
    assert [%{"id" => "reasoningEffort", "value" => ^effort}] =
             child_options(context) |> Enum.filter(&(&1["id"] == "reasoningEffort"))

    context
  end

  step "the subagent's thread shows no reasoning effort", context do
    refute Enum.any?(child_options(context), &(&1["id"] == "reasoningEffort"))
    context
  end

  # --- helpers -----------------------------------------------------------------------------

  defp codex(providers), do: Enum.find(providers, &(&1["instanceId"] == "codex"))

  defp descriptors(providers, slug) do
    model = Enum.find(codex(providers)["models"], &(&1["slug"] == slug))
    model["capabilities"]["optionDescriptors"]
  end

  defp tier_descriptor(descriptors), do: Enum.find(descriptors, &(&1["id"] == "serviceTier"))

  defp tier_options(descriptors), do: tier_descriptor(descriptors)["options"]

  defp tier_ids(providers), do: providers |> descriptors(@sol) |> tier_options() |> ids()

  defp ids(options), do: Enum.map(options, & &1["id"])

  defp tiers(ids), do: for(id <- ids, do: %{"id" => id, "name" => id, "description" => ""})

  defp sol(fields) do
    Map.merge(
      %{
        "id" => @sol,
        "model" => @sol,
        "displayName" => "GPT-6.1 Sol",
        "description" => "",
        "hidden" => false,
        "isDefault" => true
      },
      fields
    )
  end

  # A ChatGPT account whose app-server plays Codex's shared catalog (`fake_codex_models.py`),
  # in a Codex home of the scenario's own.
  defp entitled(context, entitled?) do
    context = World.fake_providers(context)
    home = Path.join(context.fakes.dir, "codex-home")
    File.mkdir_p!(home)
    World.put_os_env("CODEX_HOME", home)
    World.put_os_env("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", nil)
    World.put_os_env("FAKE_CODEX_ACCOUNT", "chatgpt")
    World.put_os_env("FAKE_CODEX_CATALOG", "1")
    World.put_os_env("FAKE_ULTRAFAST_ENTITLED", if(entitled?, do: "1", else: "0"))
    context
  end

  # Writes Codex's catalog cache as of `age` seconds from now.
  defp catalog(context, models, age \\ 0) do
    context = if System.get_env("FAKE_CODEX_CATALOG"), do: context, else: entitled(context, true)
    fetched = DateTime.utc_now() |> DateTime.add(age, :second) |> DateTime.to_iso8601()

    File.write!(
      Path.join(System.fetch_env!("CODEX_HOME"), "models_cache.json"),
      JSON.encode!(%{"fetched_at" => fetched, "models" => models})
    )

    context
  end

  defp start_waiting(context) do
    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "codex", "wait for me")
    |> await_turn()
  end

  defp await_turn(context) do
    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    context
  end

  defp ctx_params(context) do
    {_, runtime} = World.codex_runtime(context, @thread)
    %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
  end

  defp spawn_subagent(context, fields) do
    item =
      Map.merge(
        %{
          "type" => "collabAgentToolCall",
          "id" => "collab-effort",
          "tool" => "spawnAgent",
          "prompt" => "List the modules in lib",
          "senderThreadId" => ctx_params(context)["threadId"],
          "receiverThreadIds" => ["native-child-effort"],
          "status" => "inProgress",
          "agentsStates" => %{}
        },
        fields
      )

    World.codex_notify(
      context,
      @thread,
      "item/started",
      Map.put(ctx_params(context), "item", item)
    )

    # The runtime records the subagent and its thread as it handles the item.
    {pid, _} = World.codex_runtime(context, @thread)
    :sys.get_state(pid)
    context
  end

  defp child_options(context) do
    [subagent] = StreamState.list(World.stream(context, @thread), "subagent")
    child = subagent["childThreadId"]
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(child))
    StreamState.get(state, "thread")[child]["modelSelection"]["options"] || []
  end
end
