defmodule HalC2.Steps.Providers.Codex do
  @moduledoc """
  Steps for `features/providers/codex.feature`. Codex runs on `fake_codex.py` (see
  `HalC2.Test.Mc.World.fake_providers/2`), which plays scripted turns from trigger
  words in the message and logs every app-server message it reads.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @thread "Codex work"

  # --- install, models and updates ----------------------------------------------------

  step "the codex command is installed on the MC", context do
    context = World.fake_providers(context)
    assert System.find_executable(hd(Application.get_env(:hal_c2, :codex_command)))
    # The check an MC runs at boot, here against the fake the scenario installed.
    HalC2.Codex.Provider.load()
    context
  end

  step "the codex command is not installed on the MC", context do
    context = World.fake_providers(context)
    World.put_app_env(:codex_command, ["hal-c2-test-no-codex"])
    World.reset_provider_caches()
    context
  end

  step "Codex is listed as ready with its installed version", context do
    assert %{"status" => "ready", "installed" => true, "version" => "0.50.0"} =
             codex(context.providers)

    context
  end

  step "Codex reports the models {string} and {string}", %{args: [first, second]} = context do
    context = World.fake_providers(context)

    models =
      for {name, default} <- [{first, false}, {second, true}],
          do: %{"model" => slug(name), "displayName" => name, "isDefault" => default}

    System.put_env("FAKE_CODEX_MODELS", JSON.encode!(models))
    Map.put(context, :codex_models, [first, second])
  end

  step "the MC has read the Codex model list", context do
    :ok = HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)
    Map.put(context, :models, codex(providers)["models"])
  end

  step "both models are offered in the model picker with Codex's default marked", context do
    [first, second] = context.codex_models

    assert [
             %{"name" => ^first, "slug" => slug_first, "isDefault" => false},
             %{"name" => ^second, "isDefault" => true}
           ] = context.models

    assert slug_first == slug(first)
    context
  end

  step "the MC has just started and has not read the Codex model list yet", context do
    # A fresh MC has only started the background read; the fake has no list to give.
    World.fake_providers(context)
  end

  step "the user opens the model picker for Codex", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :models, codex(providers)["models"])
  end

  step "a single default Codex model is offered", context do
    assert [%{"slug" => "gpt-5.5", "isDefault" => true}] = context.models
    context
  end

  step "Codex was installed with npm and is outdated", context do
    context = World.fake_providers(context, codex_layout: :npm)

    :persistent_term.put(
      {HalC2.ProviderUpdates, "codex"},
      {"9.9.9", System.monotonic_time(:millisecond)}
    )

    context
  end

  step "Codex is updated through npm and the new version is shown", context do
    assert {:ok, %{"providers" => providers}} = context.reply

    assert %{"version" => "9.9.9", "versionAdvisory" => %{"status" => "current"}} =
             codex(providers)

    args = File.read!(Path.join(context.fakes.dir, "npm.args"))
    assert args =~ "install -g"
    assert args =~ "@openai/codex@latest"
    context
  end

  # `server.updateProvider` with a `targetVersion`; the reply is `context.reply`.
  step "the user installs Codex {string}", %{args: [version]} = context do
    {reply, context} =
      World.call(context, "server.updateProvider", %{
        "provider" => "codex",
        "targetVersion" => version
      })

    Map.put(context, :reply, reply)
  end

  step "Codex is installed at {string} through npm", %{args: [version]} = context do
    assert {:ok, %{"providers" => providers}} = context.reply

    assert %{"version" => ^version, "updateState" => %{"status" => "succeeded"}} =
             codex(providers)

    assert File.read!(Path.join(context.fakes.dir, "npm.args")) =~ "@openai/codex@#{version}"
    context
  end

  # --- approvals and questions ---------------------------------------------------------

  step "the thread runs Codex with approval required", context do
    context |> World.fake_providers() |> Map.put(:runtime_mode, "approval-required")
  end

  step ~r/^Codex asks to (?<action>run a command|change a file|widen its sandbox permissions)$/,
       %{args: [action]} = context do
    {text, kind} =
      %{
        "run a command" => {"approve", "command"},
        "change a file" => {"approve file", "file-change"},
        "widen its sandbox permissions" => {"approve permissions", "permission"}
      }[action]

    context =
      World.launch_on(context, @thread, "codex", text, %{
        "runtimeMode" => context[:runtime_mode] || "approval-required"
      })

    Map.put(context, :expected_request_kind, kind)
  end

  step "the user's decision is sent back to Codex", context do
    assert context.request["kind"] == context.expected_request_kind
    respond(context, "accept")

    decision =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "id"]) == "approval-1"))

    assert get_in(decision, ["in", "result", "decision"]) == "accept"
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Codex asked to run a command", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "approve", %{"runtimeMode" => "approval-required"})

    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "Codex runs the command this time only", context do
    assert codex_decision(context) == "accept"
    World.await_runs(context, @thread, ["completed"])
    assert command_status(context) == "completed"
    context
  end

  step "Codex runs matching commands for the session", context do
    assert codex_decision(context) == "acceptForSession"
    World.await_runs(context, @thread, ["completed"])
    assert command_status(context) == "completed"
    context
  end

  step "Codex skips the command and continues", context do
    assert codex_decision(context) == "decline"
    World.await_runs(context, @thread, ["completed"])
    # A declined command is shown as cancelled; the turn still finishes.
    assert command_status(context) == "cancelled"
    context
  end

  step "Codex stops the turn", context do
    assert codex_decision(context) == "cancel"
    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  step "Codex asks the user a question with choices", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "ask me")
    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "the user's answer is sent back to Codex", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{context.question["id"] => "Red"}
      })

    World.await_runs(context, @thread, ["completed"])
    assert ~s(answered {"color": {"answers": ["Red"]}}) in World.replies(context, @thread)
    context
  end

  step "Codex asked the user a question", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "ask me")
    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "Codex is told the question was not answered", context do
    World.await_runs(context, @thread, ["completed"])
    assert ~s(answered {}) in World.replies(context, @thread)

    request =
      StreamState.get(World.stream(context, @thread), "runtime-request")[context.request["id"]]

    assert request["status"] == "cancelled"
    context
  end

  # --- turns ---------------------------------------------------------------------------

  step "a Codex turn is running", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    context
  end

  # The app-server's own pid, from its connection (never found by name).
  step "the Codex app-server exits unexpectedly", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    context
  end

  step "the turn fails saying Codex exited unexpectedly", context do
    state = World.await_runs(context, @thread, ["failed"])

    assert Enum.any?(
             StreamState.list(state, "provider-session"),
             &(&1["lastError"] == "Codex exited unexpectedly")
           )

    context
  end

  step "Codex receives the message during the running turn", context do
    steer =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/steer"))

    assert [%{"text" => "one more thing"} | _] = get_in(steer, ["in", "params", "input"])
    World.await_runs(context, @thread, ["completed"])
    assert "steered: one more thing" in World.replies(context, @thread)
    context
  end

  # --- questions asked without waiting ---------------------------------------------------

  # Codex's async question: an agent message that carries questions and waits for no
  # reply, delivered as the app-server reports it.
  defp ask_async(context) do
    {_, runtime} = World.codex_runtime(context, @thread)

    context =
      World.codex_notify(context, @thread, "item/completed", %{
        "threadId" => runtime.native_thread_id,
        "turnId" => runtime.turn.native_turn_id,
        "item" => %{
          "type" => "agentMessage",
          "id" => "msg-async",
          "delivery" => "async",
          "text" => "",
          "questions" => [%{"title" => "Which color?", "options" => ["Red", "Blue"]}]
        }
      })

    request = World.await_request(context, @thread)
    assert request["responseCapability"] == %{"type" => "message"}
    Map.put(context, :request, request)
  end

  defp answer_async(context) do
    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "commandId" => "cmd-answer-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "answers" => %{"0" => "Red"}
      })

    assert {:ok, _} = reply
    context
  end

  defp request_now(context),
    do: StreamState.get(World.stream(context, @thread), "runtime-request")[context.request["id"]]

  step "Codex asked a question and kept working", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    context = ask_async(context)
    # The question does not hold the run: it is still running, not waiting.
    assert %{"status" => "running"} = World.latest_run(context, @thread)
    context
  end

  step "the answer reaches the running turn as a new message", context do
    steer =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/steer"))

    assert [%{"text" => "Which color?
Red"}] = get_in(steer, ["in", "params", "input"])
    assert %{"status" => "resolved"} = request_now(context)
    assert [_] = World.runs(context, @thread)
    context
  end

  step "Codex asked a question and then finished the turn", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    context = ask_async(context)
    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    World.await_runs(context, @thread, ["completed"])
    assert %{"status" => "pending"} = request_now(context)
    context
  end

  step "the answer starts a new turn", context do
    World.await_value(context, @thread, fn state ->
      runs = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

      with [%{"status" => "completed"}, %{"userMessageId" => message}] <- runs,
           %{"text" => "Which color?
Red"} <- StreamState.get(state, "message")[message],
           do: true,
           else: (_ -> nil)
    end)

    assert %{"status" => "resolved"} = request_now(context)
    # Sending the same answer again changes nothing.
    answer_async(context)
    assert length(World.runs(context, @thread)) == 2
    context
  end

  # An earlier install named a question's node and item after the provider's item, not
  # after the request as this MC does.
  step "a thread imported with a Codex question that is not answered yet", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    request_id = "runtime-request:provider:codex:native-request:async%3Acall_1"
    native = "provider:codex:native-item:call_1"

    request = %{
      "id" => request_id,
      "nodeId" => "node:" <> native,
      "kind" => "user_input",
      "status" => "pending",
      "responseCapability" => %{"type" => "message"},
      "resolvedAt" => nil
    }

    context
    |> World.put_entity(@thread, "turn-item", "turn-item:" <> native, %{
      "s" => %{
        "id" => "turn-item:" <> native,
        "type" => "user_input_request",
        "status" => "waiting",
        "requestId" => request_id,
        "questions" => []
      }
    })
    |> World.put_entity(@thread, "runtime-request", request_id, %{"s" => request})
    |> Map.put(:request, request)
  end

  step "the user dismisses it", context do
    assert {:ok, _} =
             HalC2.Orchestration.dispatch(%{
               "type" => "thread.user-input.dismiss",
               "threadId" => World.thread_id(context, @thread),
               "requestId" => context.request["id"]
             })

    context
  end

  step "the question is closed without an answer", context do
    assert %{"status" => "cancelled"} = request_now(context)

    assert [%{"status" => "cancelled"}] =
             World.stream(context, @thread)
             |> StreamState.list("turn-item")
             |> Enum.filter(&(&1["requestId"] == context.request["id"]))

    context
  end

  step "Codex asked a question that is not answered yet", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    ask_async(context)
  end

  # The client's socket drops, and the provider behind the question goes with its run.
  step "the client reconnects to the MC", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    World.await_runs(context, @thread, ["failed"])
    context |> World.disconnect() |> World.put_client(HalC2.Test.Mc.connect(context.mc))
  end

  step "the question is still waiting for an answer", context do
    thread_id = World.thread_id(context, @thread)
    id = System.unique_integer([:positive])

    client =
      HalC2.Test.Mc.sub(World.client(context), id, %{
        "type" => "stream",
        "mc" => Atom.to_string(node()),
        "stream" => thread_id
      })

    {frame, client} = HalC2.Test.Mc.await(client, &(&1["id"] == id), 5_000)
    context = World.put_client(context, client)
    request_id = context.request["id"]

    # The new socket's snapshot of the thread carries the open question.
    assert Enum.any?(
             frame["rows"],
             &match?(["runtime-request", ^request_id, %{"status" => "pending"}], &1)
           )

    assert %{"status" => "pending"} = request_now(context)

    assert [%{"status" => "waiting", "questions" => [%{"question" => "Which color?"}]}] =
             World.entities(context, @thread, "turn-item")
             |> Enum.filter(&(&1["type"] == "user_input_request"))

    # It can still be answered: the answer starts a turn.
    answer_async(context)
    assert %{"status" => "resolved"} = request_now(context)
    context
  end

  # --- access to another app -------------------------------------------------------------

  @elicitation "elicit-1"

  # A connector's request, as Codex's app-server forwards it while a turn runs.
  step "a Codex tool asks for access to {string}", %{args: [app]} = context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    {pid, runtime} = World.codex_runtime(context, @thread)

    params = %{
      "threadId" => runtime.native_thread_id,
      "turnId" => runtime.turn.native_turn_id,
      "serverName" => "codex_apps",
      "mode" => "form",
      "message" => "Allow ChatGPT to use #{app}?",
      "_meta" => %{"persist" => ["session", "always"]},
      "requestedSchema" => %{"type" => "object", "properties" => %{}}
    }

    send(
      pid,
      {:json_rpc, runtime.conn, {:request, @elicitation, "mcpServer/elicitation/request", params}}
    )

    request = World.await_request(context, @thread)
    assert request["kind"] == "mcp-elicitation"

    # The approval names the app and the scopes once the runtime has described it.
    %{"options" => options} =
      World.await_value(context, @thread, fn state ->
        Enum.find(
          StreamState.list(state, "turn-item"),
          &(&1["requestId"] == request["id"] and &1["appName"] == app)
        )
      end)

    assert Enum.map(options, & &1["decision"]) ==
             ~w(cancel decline acceptForSession acceptAlways accept)

    Map.put(context, :request, request)
  end

  defp decide(context, decision) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "decision" => decision
      })

    context
  end

  # What the fake app-server got back for the tool's request.
  defp elicitation_answer(context) do
    World.await_provider_log(
      context,
      "codex",
      &(get_in(&1, ["in", "id"]) == @elicitation and get_in(&1, ["in", "method"]) == nil)
    )["in"]["result"]
  end

  @scopes %{
    "for this request" => {"accept", nil},
    "for this session" => {"acceptForSession", "session"},
    "permanently" => {"acceptAlways", "always"}
  }

  step ~r/^the user grants access (?<scope>for this request|for this session|permanently)$/,
       %{args: [scope]} = context do
    decide(context, elem(@scopes[scope], 0))
  end

  step ~r/^the tool gets access (?<scope>for this request|for this session|permanently)$/,
       %{args: [scope]} = context do
    {decision, persist} = @scopes[scope]
    answer = elicitation_answer(context)
    assert answer["action"] == "accept"
    assert get_in(answer, ["_meta", "persist"]) == persist
    assert %{"status" => "resolved", "decision" => ^decision} = request_now(context)
    context
  end

  step "the user declines", context do
    decide(context, "decline")
  end

  step "the tool is told access was declined", context do
    assert elicitation_answer(context) == %{"action" => "decline"}
    assert %{"status" => "resolved", "decision" => "decline"} = request_now(context)
    # The turn goes on without the app.
    assert %{"status" => "running"} = World.latest_run(context, @thread)
    context
  end

  # Codex closes its plan item (`item/completed`) when the plan is written: the step
  # is done, the plan itself still open to implement.
  step "Codex proposed a plan and marked it finished", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "make a plan", %{"interactionMode" => "plan"})

    state = World.await_runs(context, @thread, ["completed"])
    [plan] = for p <- StreamState.list(state, "plan"), p["kind"] == "proposed_plan", do: p

    assert [%{"status" => "completed", "streaming" => false}] =
             Enum.filter(StreamState.list(state, "turn-item"), &(&1["planId"] == plan["id"]))

    Map.put(context, :plan, plan)
  end

  step "the plan is offered for implementation", context do
    id = World.thread_id(context, @thread)

    assert StreamState.get(World.stream(context, @thread), "plan")[context.plan["id"]]["status"] ==
             "active"

    World.await_row(id, &(&1["hasActionableProposedPlan"] == true))
    context
  end

  # Implementing leaves plan mode, as the clients do, and names the plan.
  step "the user implements the plan", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.interaction-mode.set",
        "commandId" => "cmd-mode-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread),
        "interactionMode" => "default"
      })

    World.post_message(context, @thread, "Implement the plan.", %{
      "sourcePlanRef" => %{
        "threadId" => World.thread_id(context, @thread),
        "planId" => context.plan["id"]
      },
      "dispatchMode" => nil
    })
  end

  step "a new run starts from that plan", context do
    state = World.await_runs(context, @thread, ["completed", "completed"])
    assert StreamState.get(state, "plan")[context.plan["id"]]["status"] == "completed"
    [_, run] = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

    assert StreamState.get(state, "message")[run["userMessageId"]]["text"] ==
             "Implement the plan."

    World.await_row(
      World.thread_id(context, @thread),
      &(&1["hasActionableProposedPlan"] == false)
    )

    context
  end

  # --- accounts on one home --------------------------------------------------------------

  @second "codex-work"

  # The built-in Codex uses the shared home itself; the second instance is another
  # account on it, with a shadow home for its own login.
  step "a shared Codex home and a second Codex instance with its own shadow home", context do
    context = World.fake_providers(context)
    shared = HalC2.Test.Mc.tmp_dir(context.mc, "codex-home")
    shadow = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "codex-shadows"), "work")
    File.write!(Path.join(shared, "config.toml"), "model = \"gpt-6-luna\"\n")
    File.write!(Path.join(shared, "auth.json"), ~s({"account":"home"}))
    File.write!(Path.join(shared, "models_cache.json"), ~s({"models":["home"]}))
    World.put_os_env("FAKE_SESSIONS", "1")

    World.merge_settings(%{
      "providers" => %{"codex" => %{"homePath" => shared}},
      "providerInstances" => %{
        @second => %{
          "driver" => "codex",
          "enabled" => true,
          "config" => %{"homePath" => shared, "shadowHomePath" => shadow}
        }
      }
    })

    Map.merge(context, %{codex_shared: shared, codex_shadow: shadow})
  end

  # `codex login` in the instance's home: the shadow home, where the login stays.
  step "the user signs in to the second instance", context do
    assert {:ok, [{"CODEX_HOME", home}]} = HalC2.Codex.Home.env(@second)
    assert home == context.codex_shadow
    File.write!(Path.join(home, "auth.json"), ~s({"account":"work"}))
    File.write!(Path.join(home, "models_cache.json"), ~s({"models":["work"]}))
    context
  end

  step "both instances see the same Codex sessions and settings", context do
    context = World.launch_on(context, "Home", "codex", "hello from home")
    World.await_runs(context, "Home", ["completed"])
    context = World.launch_on(context, "Work", @second, "hello from work")
    World.await_runs(context, "Work", ["completed"])

    # Each ran in its own home.
    homes = for %{"argv" => _, "home" => home} <- World.provider_log(context, "codex"), do: home
    assert context.codex_shared in homes and context.codex_shadow in homes

    # Both conversations are in the shared home's sessions, which the shadow home links.
    rollouts = fn home ->
      Path.join(home, "sessions/*/*/*/rollout-*.jsonl")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
    end

    assert [_, _] = rollouts.(context.codex_shared)

    assert Enum.sort(rollouts.(context.codex_shadow)) ==
             Enum.sort(rollouts.(context.codex_shared))

    assert File.read_link!(Path.join(context.codex_shadow, "sessions")) ==
             Path.join(context.codex_shared, "sessions")

    # One settings file: a change made through either home is the other's too.
    File.write!(Path.join(context.codex_shadow, "config.toml"), "model = \"gpt-5.5\"\n")
    assert File.read!(Path.join(context.codex_shared, "config.toml")) == "model = \"gpt-5.5\"\n"
    context
  end

  step "each keeps its own login and model list", context do
    for {home, account} <- [{context.codex_shared, "home"}, {context.codex_shadow, "work"}] do
      assert %File.Stat{type: :regular} = File.lstat!(Path.join(home, "auth.json"))
      assert File.read!(Path.join(home, "auth.json")) == ~s({"account":"#{account}"})
      assert File.read!(Path.join(home, "models_cache.json")) == ~s({"models":["#{account}"]})
    end

    context
  end

  # --- one quota per account -----------------------------------------------------------

  step "both Codex instances' usage has been checked", context do
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh(["codex", @second])
    # The account arrives as a cast the probe sent; this call lands after it.
    :sys.get_state(HalC2.ProviderUsageLimits)
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "a turn on the second Codex instance reports its usage", context do
    context = World.launch_on(context, "Work", @second, "how close is the rate limit")
    World.await_runs(context, "Work", ["completed"])
    # The turn's update is a cast; this call lands after it.
    :sys.get_state(HalC2.ProviderUsageLimits)
    context
  end

  step "each Codex account keeps its own usage limits", context do
    codex = HalC2.ProviderUsageLimits.get("codex")
    work = HalC2.ProviderUsageLimits.get(@second)

    assert %{"usedPercent" => 42} = Enum.find(codex["windows"], &(&1["id"] == "primary"))
    assert %{"usedPercent" => 77} = Enum.find(work["windows"], &(&1["id"] == "primary"))
    context
  end

  # --- subagents -------------------------------------------------------------------------

  # The fake's spawnAgent tool call starts the thread native-child-1, which answers.
  step "Codex starts a subagent", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "spawn a subagent")

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the subagent's work is shown as a child of the turn", context do
    state = World.stream(context, @thread)
    [run] = StreamState.list(state, "run")

    assert [
             %{
               "origin" => "provider_native",
               "status" => "completed",
               "prompt" => "List the modules in lib",
               "result" => "lib has three modules"
             } = subagent
           ] = StreamState.list(state, "subagent")

    assert subagent["runId"] == run["id"] and subagent["parentNodeId"] == run["rootNodeId"]

    assert [%{"status" => "completed", "runId" => run_id, "subagentId" => id}] =
             Enum.filter(StreamState.list(state, "turn-item"), &(&1["type"] == "subagent"))

    assert run_id == run["id"] and id == subagent["id"]

    # What the subagent said is its own thread's, not this turn's; the turn went on.
    replies = World.replies(context, @thread)
    refute "lib has three modules" in replies
    assert "The subagent found three modules." in replies
    Map.put(context, :subagent, subagent)
  end

  step "the user can open the subagent's own thread", context do
    thread_id = World.thread_id(context, @thread)
    child_id = context.subagent["childThreadId"]
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(child_id))

    assert %{"parentThreadId" => ^thread_id, "relationshipToParent" => "subagent"} =
             StreamState.get(child, "thread")[child_id]["lineage"]

    assert [{"user", "List the modules in lib"}, {"assistant", "lib has three modules"}] =
             child
             |> StreamState.list("message")
             |> Enum.sort_by(& &1["createdAt"])
             |> Enum.map(&{&1["role"], &1["text"]})

    context
  end

  step "the thread is in plan mode on Codex", context do
    World.fake_providers(context)
  end

  step "Codex updates its plan", context do
    context =
      World.launch_on(context, @thread, "codex", "make a plan", %{"interactionMode" => "plan"})

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the task list shows each step and its status", context do
    [todo] =
      for p <- StreamState.list(World.stream(context, @thread), "plan"),
          p["kind"] == "todo_list",
          do: p

    assert [
             %{"text" => "Read the code", "status" => "completed"},
             %{"text" => "Write the plan", "status" => "running"}
           ] = todo["steps"]

    assert todo["explanation"] == "Two steps"
    context
  end

  step "the finished plan is shown as a proposed plan", context do
    assert [%{"markdown" => "# Plan\n- do it", "status" => "active"}] =
             for(
               p <- StreamState.list(World.stream(context, @thread), "plan"),
               p["kind"] == "proposed_plan",
               do: p
             )

    context
  end

  step "a Codex turn starts", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  # Quoted as a user would type them: the quoted value is one argument.
  step "the Codex instance has launch arguments configured", context do
    context
    |> World.fake_providers()
    |> World.put_settings(%{
      "providers" => %{"codex" => %{"launchArgs" => ~s(--strict-config -c 'profile="acme corp"')}}
    })
    |> Map.put(:launch_args, ["--strict-config", "-c", ~s(profile="acme corp")])
  end

  step "the Codex instance has launch arguments with a quote that is never closed", context do
    context
    |> World.fake_providers()
    |> World.put_settings(%{"providers" => %{"codex" => %{"launchArgs" => ~s(-c 'profile=acme)}}})
  end

  step "the user sends a message to a Codex thread", context do
    World.launch_on(context, @thread, "codex", "hello")
  end

  step "the turn fails saying the launch arguments have a quote that is never closed", context do
    state = World.await_runs(context, @thread, ["failed"])

    assert [%{"lastError" => error}] = StreamState.list(state, "provider-session")

    assert error ==
             "Codex could not start: the launch arguments in settings have a quote that is never closed"

    context
  end

  step "a Codex session starts", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  # The fake logs the arguments of each process; the app-server (a session's, or the
  # one a status check reads) takes these alone, and `codex exec` right after `exec`.
  step "Codex is started with those arguments", context do
    case context[:launch_occasion] do
      :title ->
        assert [%{"argv" => ["exec" | argv]}] = World.text_calls(context)
        assert Enum.take(argv, length(context.launch_args)) == context.launch_args

      _ ->
        assert context.launch_args in for(
                 %{"argv" => argv} <- World.provider_log(context, "codex"),
                 do: argv
               )
    end

    context
  end

  # The status check reads Codex's version and, from its app-server, its models.
  step "the MC checks Codex's version", context do
    World.reset_provider_caches()
    assert World.provider_log(context, "codex") == []
    HalC2.Codex.Provider.load()
    assert %{"version" => "0.50.0", "models" => [_ | _]} = HalC2.Codex.Provider.entry()
    context
  end

  step "Codex writes a title for a new thread", context do
    context = World.text_writers(context, [:codex])

    World.merge_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4-mini"}
    })

    assert {:ok, %{"title" => _}} =
             HalC2.TextGeneration.thread_title(World.project(context).root, "Fix the login bug")

    Map.put(context, :launch_occasion, :title)
  end

  step "Codex can call the HAL-C2 tools for this thread", context do
    start =
      World.await_provider_log(
        context,
        "codex",
        &(get_in(&1, ["in", "method"]) == "thread/start")
      )

    %{"url" => url, "http_headers" => headers} =
      get_in(start, ["in", "params", "config", "mcp_servers", "hal-c2"])

    assert url =~ ~r{^http://127\.0\.0\.1:\d+/mcp$}
    auth = headers["Authorization"]

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "hal_c2_thread_list", "arguments" => %{}}
      })

    # The tools find the calling thread through its sidebar row.
    :ok = HalC2.Shell.subscribe(self())
    World.await_row(World.thread_id(context, @thread), & &1)
    assert {200, %{"result" => %{"structuredContent" => listed}}} = HalC2.Mcp.handle(auth, body)
    assert listed["currentThreadId"] == World.thread_id(context, @thread)
    context
  end

  step "Codex is started with its subagent features left on", context do
    refute get_in(codex_thread_config(context), ["features"])
    context
  end

  step "Codex is started with its subagent features turned off", context do
    assert get_in(codex_thread_config(context), ["features"]) ==
             %{"multi_agent" => false, "multi_agent_v2" => false}

    context
  end

  step "Codex is told to delegate with {string}", %{args: [tool]} = context do
    start =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))

    assert get_in(start, [
             "in",
             "params",
             "collaborationMode",
             "settings",
             "developer_instructions"
           ]) =~
             "Delegate child work with `#{tool}`"

    context
  end

  step "the user sends another message to the Codex thread", context do
    {{:ok, _}, context} = World.send_message(context, @thread, "again")
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "every Codex turn of the thread is told to delegate with {string}",
       %{args: [tool]} = context do
    starts =
      context
      |> World.provider_log("codex")
      |> Enum.filter(&(get_in(&1, ["in", "method"]) == "turn/start"))

    assert length(starts) == 2

    for start <- starts,
        do:
          assert(
            get_in(start, [
              "in",
              "params",
              "collaborationMode",
              "settings",
              "developer_instructions"
            ]) =~
              "Delegate child work with `#{tool}`"
          )

    context
  end

  defp codex_thread_config(context) do
    start =
      World.await_provider_log(
        context,
        "codex",
        &(get_in(&1, ["in", "method"]) == "thread/start")
      )

    get_in(start, ["in", "params", "config"]) || %{}
  end

  step "a Codex thread with three turns", context do
    context
    |> World.fake_providers()
    |> World.run_turns(@thread, "codex", ["hello", "hello again", "one more"])
  end

  # The app-server that ran the turns is gone; the next thing asked of Codex starts a
  # new one, which has not loaded the thread.
  step "Codex's app-server restarted after the first turn", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    ref = Process.monitor(runtime.conn)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    {_, runtime} = World.codex_runtime(context, @thread)
    assert runtime.conn == nil
    context
  end

  step "the revert is reported as complete", context do
    assert {:ok, _} = context.reply
    log = World.provider_log(context, "codex")
    # A second app-server ran it: it resumed the thread, then rewound it.
    assert [_, _ | _] = Enum.filter(log, &Map.has_key?(&1, "argv"))
    methods = for %{"in" => %{"method" => method}} <- log, do: method

    restarted =
      methods |> Enum.reverse() |> Enum.take_while(&(&1 != "initialize")) |> Enum.reverse()

    assert Enum.find_index(restarted, &(&1 == "thread/resume")) <
             Enum.find_index(restarted, &(&1 == "thread/revert"))

    assert [
             %{"status" => "completed"},
             %{"status" => "rolled_back"},
             %{"status" => "rolled_back"} | _
           ] =
             World.runs(context, @thread)

    context
  end

  step "Codex's own thread is rolled back to that point", context do
    assert {:ok, _} = context.reply
    # Current Codex rewinds its paginated history before the first dropped turn.
    revert =
      World.await_provider_log(
        context,
        "codex",
        &(get_in(&1, ["in", "method"]) == "thread/revert")
      )

    assert get_in(revert, ["in", "params", "beforeTurnId"]) == "native-turn-2"

    context = World.post_message(context, @thread, "where are we")
    World.await_runs(context, @thread, ["completed", "rolled_back", "rolled_back", "completed"])

    assert "on native-thread-1-before-native-turn-2 history False merged False" in World.replies(
             context,
             @thread
           )

    context
  end

  step "a new thread continues from a fork of Codex's thread at the second turn", context do
    assert {:ok, _} = context.reply
    context = World.post_message(context, "fork", "where are we")

    World.await_value(context, "fork", fn state ->
      match?(
        [_, _, %{"status" => "completed"}],
        state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      )
    end)

    fork =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "thread/fork"))

    assert get_in(fork, ["in", "params", "lastTurnId"]) == "native-turn-2"

    assert "on forked-native-thread-1-at-native-turn-2 history False merged False" in World.replies(
             context,
             "fork"
           )

    context
  end

  # --- feedback --------------------------------------------------------------------------

  step "a Codex thread has run at least one turn on this MC", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    :ok = HalC2.Shell.subscribe(self())
    World.await_row(World.thread_id(context, @thread), &(&1["providerInstanceId"] == "codex"))
    context
  end

  step "the user sends feedback {string}", %{args: [reason]} = context do
    feedback(context, reason)
  end

  step "the conversation and Codex logs are uploaded to OpenAI", context do
    upload =
      World.await_provider_log(
        context,
        "codex",
        &(get_in(&1, ["in", "method"]) == "feedback/upload")
      )

    assert %{
             "classification" => "bug",
             "includeLogs" => true,
             "threadId" => "native-thread-1",
             "reason" => "The agent stopped early"
           } = get_in(upload, ["in", "params"])

    context
  end

  step "the user is given the feedback thread id", context do
    assert {:ok, %{"feedbackId" => "feedback-for-native-thread-1"}} = context.reply
    context
  end

  step "a Codex thread that has not run a turn yet", context do
    context
    |> World.fake_providers()
    |> World.create_thread(@thread)
    |> Map.put(:current_thread, @thread)
  end

  step "the user sends feedback", context do
    feedback(context, nil)
  end

  step "the user is told no Codex session has run yet", context do
    assert {:error, "ProviderUploadFeedbackError", %{"cause" => cause}} = context.reply
    assert cause == "No provider session has run in this thread yet."
    context
  end

  # --- text generation and account ---------------------------------------------------------

  step "Codex is picked for text generation", context do
    context = World.text_writers(context, [:codex])

    World.merge_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4-mini"}
    })

    context
  end

  step "a commit needs a message", context do
    root = World.project(context).root

    Map.put(
      context,
      :commit_result,
      HalC2.TextGeneration.commit_message(root, "main", "M a.txt", "diff --git a/a.txt b/a.txt")
    )
  end

  step "Codex writes it in a read-only sandbox", context do
    assert {:ok, %{"subject" => subject}} = context.commit_result
    assert subject =~ "codex"
    assert [%{"argv" => ["exec" | _] = argv}] = World.text_calls(context)
    assert ["-s", "read-only"] in Enum.chunk_every(argv, 2, 1)
    context
  end

  step "Codex is signed in with a ChatGPT Pro subscription", context do
    # The fake reports me@example.com on ChatGPT Pro unless told otherwise.
    World.fake_providers(context)
  end

  step "Codex is signed in with an OpenAI API key", context do
    context = World.fake_providers(context)
    System.put_env("FAKE_CODEX_ACCOUNT", "apiKey")
    context
  end

  # --- model options ---------------------------------------------------------------------

  step ~r/^the user opens the options for a Codex model that supports (?<option>reasoning|service tier)$/,
       %{args: [option]} = context do
    model =
      case option do
        "reasoning" ->
          %{
            "defaultReasoningEffort" => "medium",
            "supportedReasoningEfforts" =>
              for(e <- ~w(none minimal low medium high xhigh max), do: %{"reasoningEffort" => e})
          }

        "service tier" ->
          %{"additionalSpeedTiers" => ["fast"]}
      end

    System.put_env(
      "FAKE_CODEX_MODELS",
      JSON.encode!([Map.merge(%{"model" => "gpt-6-luna", "displayName" => "GPT-6 Luna"}, model)])
    )

    context = World.fake_providers(context)
    HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)
    codex = Enum.find(providers, &(&1["instanceId"] == "codex"))

    [descriptor] =
      Enum.find(codex["models"], &(&1["slug"] == "gpt-6-luna"))["capabilities"][
        "optionDescriptors"
      ]

    Map.put(context, :option_descriptor, descriptor)
  end

  # The labels offered, in order ("a, b, c" or "a or b"), for the opened option.
  step ~r/^the user can choose (?<choices>(?:[\w ]+, )+[\w ]+|[\w ]+ or [\w ]+)$/,
       %{args: [choices]} = context do
    expected = choices |> String.downcase() |> String.split(~r/, | or /)

    offered =
      case context.option_descriptor do
        %{"type" => "boolean"} -> ["on", "off"]
        %{"options" => options} -> Enum.map(options, &String.downcase(&1["label"]))
      end

    assert offered == expected
    context
  end

  # --- usage-limit stops -----------------------------------------------------------------

  step "the Codex account is on a workspace plan with no credits left", context do
    System.put_env("FAKE_CODEX_REACHED", "workspace_member_credits_depleted")
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CODEX_REACHED") end)
    context
  end

  step ~r/^Codex stops (?:because the weekly limit is used up|on a usage limit)$/, context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "usage limit")

    state = World.await_runs(context, @thread, ["failed"])
    [session] = StreamState.list(state, "provider-session")
    Map.put(context, :stop_message, session["lastError"])
  end

  step "the thread says the weekly limit is used up and when it resets", context do
    assert context.stop_message =~ "Codex usage limit reached. The weekly limit resets in 5d 5h."
    context
  end

  step "it says to send the message again after the reset", context do
    assert String.ends_with?(
             context.stop_message,
             "Send the message again once the limit resets."
           )

    context
  end

  step "the thread says the workspace owner needs to add credits", context do
    assert context.stop_message =~ "ask your workspace owner to add credits"
    context
  end

  step "the thread runs Codex in auto mode", context do
    context |> World.fake_providers() |> Map.put(:codex_mode, "auto")
  end

  step "Codex wants to run a command outside its sandbox", context do
    World.launch_on(context, @thread, "codex", "approve", %{
      "runtimeMode" => context.codex_mode
    })
  end

  step "Codex's automatic reviewer decides instead of asking the user", context do
    World.await_runs(context, @thread, ["completed"])
    assert command_status(context) == "completed"
    # The turn named Codex's reviewer, and the client was never asked.
    assert StreamState.list(World.stream(context, @thread), "runtime-request") == []
    log = World.provider_log(context, "codex")

    assert Enum.any?(
             log,
             &(get_in(&1, ["in", "method"]) == "turn/start" and
                 get_in(&1, ["in", "params", "approvalsReviewer"]) == "auto_review")
           )

    refute Enum.any?(log, &(get_in(&1, ["in", "id"]) == "approval-1"))
    context
  end

  step "the Codex CLI on the MC is not signed in", context do
    context = World.fake_providers(context)
    System.put_env("FAKE_CODEX_ACCOUNT", "none")
    # The MC reads the account when it checks the provider.
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh(["codex"])
    :sys.get_state(HalC2.ProviderUsageLimits)
    context
  end

  step "Codex is shown as not signed in with a hint to run the Codex login command", context do
    codex = Enum.find(context.providers, &(&1["instanceId"] == "codex"))
    assert %{"status" => "error", "auth" => %{"status" => "unauthenticated"}} = codex
    assert codex["message"] =~ "Run `codex login`"
    context
  end

  step "Codex's usage has been checked", context do
    Mc.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh(["codex"])
    # The account arrives as a cast the probe sent; this call lands after it.
    :sys.get_state(HalC2.ProviderUsageLimits)
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "Codex shows the account's email and its ChatGPT Pro plan", context do
    assert %{"email" => "me@example.com", "type" => "chatgpt", "label" => label} =
             codex(context.providers)["auth"]

    assert label =~ "ChatGPT Pro"
    context
  end

  step "Codex shows that it uses an OpenAI API key", context do
    assert %{"type" => "apiKey", "label" => "OpenAI API Key"} = codex(context.providers)["auth"]
    refute Map.has_key?(codex(context.providers)["auth"], "email")
    context
  end

  # --- health states -----------------------------------------------------------------------

  step "the Codex binary path is the default", context do
    World.fake_providers(context)
  end

  step "the Codex binary path is {string}", %{args: [path]} = context do
    context = World.fake_providers(context)
    World.merge_settings(%{"providers" => %{"codex" => %{"binaryPath" => path}}})
    Map.put(context, :binary_path, path)
  end

  # An executable that is there but no program: starting it fails at once, as a
  # script whose interpreter is gone does. The MC's check records that.
  step "the Codex command cannot be started", context do
    unless context[:binary_path] do
      bad = Path.join(context.fakes.dir, "bad-codex")
      File.write!(bad, "#!/nonexistent/hal-c2-no-interpreter\n")
      File.chmod!(bad, 0o755)
      World.put_app_env(:codex_command, [bad])
    end

    HalC2.Codex.Provider.load()
    context
  end

  step "Codex is shown as unavailable with the message {string}",
       %{args: [message]} = context do
    entry = codex(context.providers)
    assert entry["status"] == "error"
    assert entry["availability"] == "unavailable"
    assert entry["message"] == message
    context
  end

  step "the Codex command starts but its status check fails with {string}",
       %{args: [message]} = context do
    context = World.fake_providers(context)
    World.put_os_env("FAKE_CODEX_PROBE_ERROR", message)
    HalC2.Codex.Provider.load()
    context
  end

  step "Codex is shown as installed but unavailable with the message {string}",
       %{args: [message]} = context do
    entry = codex(context.providers)
    assert entry["installed"] == true
    assert entry["status"] == "error"
    assert entry["message"] == message
    context
  end

  step "the Codex command starts but does not answer its status check", context do
    context = World.fake_providers(context)
    World.put_os_env("FAKE_CODEX_PROBE_HANG", "1")
    World.put_app_env(:codex_probe_timeout_ms, 300)
    HalC2.Codex.Provider.load()
    context
  end

  step "the MC has just started and has not checked Codex yet", context do
    context = World.fake_providers(context)
    World.reset_provider_caches()
    context
  end

  step "Codex is shown with a warning that its status has not been checked in this session yet",
       context do
    entry = codex(context.providers)
    assert entry["status"] == "warning"
    assert entry["message"] == "Codex provider status has not been checked in this session yet."
    context
  end

  step "Codex is turned off in the provider settings", context do
    context = World.fake_providers(context)
    World.merge_settings(%{"providers" => %{"codex" => %{"enabled" => false}}})
    context
  end

  step "Codex is shown with the message {string}", %{args: [message]} = context do
    entry = codex(context.providers)
    assert entry["enabled"] == false
    assert entry["message"] == message
    context
  end

  step "Codex version {string} is installed", %{args: [version]} = context do
    World.fake_providers(context, codex_version: version)
  end

  step "the MC checks Codex", context do
    HalC2.Codex.Provider.load()
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "Codex is reported as {string} for this HAL-C2 release",
       %{args: [status]} = context do
    assert codex(context.providers)["compatibilityAdvisory"]["status"] == status
    context
  end

  # --- launch arguments from the MC's environment ------------------------------------------

  step "the MC's environment sets HAL_C2_CODEX_LAUNCH_ARGS", context do
    World.put_os_env("HAL_C2_CODEX_LAUNCH_ARGS", ~s(--strict-config -c 'profile="env corp"'))
    Map.put(context, :env_launch_args, ["--strict-config", "-c", ~s(profile="env corp")])
  end

  step "the Codex instance has other launch arguments configured", context do
    context
    |> World.fake_providers()
    |> World.put_settings(%{
      "providers" => %{"codex" => %{"launchArgs" => "--config model_provider=instance"}}
    })
  end

  step "Codex is started with the variable's arguments only", context do
    argvs = for %{"argv" => argv} <- World.provider_log(context, "codex"), do: argv
    assert context.env_launch_args in argvs
    refute ["--config", "model_provider=instance"] in argvs
    context
  end

  step "the Codex instance has the launch arguments {string}",
       %{args: [args]} = context do
    context
    |> World.fake_providers()
    |> World.put_settings(%{"providers" => %{"codex" => %{"launchArgs" => args}}})
  end

  step "the title writer is started with {string} and {string}",
       %{args: [first, second]} = context do
    assert [%{"argv" => ["exec" | argv]}] = World.text_calls(context)
    expected = OptionParser.split(first) ++ OptionParser.split(second)
    assert Enum.take(argv, length(expected)) == expected
    Map.put(context, :title_argv, argv)
  end

  step "{string} is left out", %{args: [arg]} = context do
    refute arg in context.title_argv
    context
  end

  # --- resuming a conversation Codex no longer has -------------------------------------------

  # One turn in, the app-server is gone (its next start must resume), and Codex
  # answers that resume with `message`.
  defp resume_fails(context, message) do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    {_, runtime} = World.codex_runtime(context, @thread)
    ref = Process.monitor(runtime.conn)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    World.put_os_env("FAKE_CODEX_RESUME_ERROR", message)
    context
  end

  step "a Codex thread whose native conversation Codex has since forgotten", context do
    resume_fails(context, "no rollout found for thread id native-thread-1")
  end

  step "resuming the Codex thread fails with an error that is not about a missing conversation",
       context do
    resume_fails(context, "resume blew up")
  end

  step "the message runs in a new Codex conversation", context do
    World.await_runs(context, @thread, ["completed", "completed"])

    methods =
      for %{"in" => %{"method" => method}} <- World.provider_log(context, "codex"), do: method

    # The failed resume is followed by a fresh start in the same app-server.
    assert Enum.count(methods, &(&1 == "thread/resume")) == 1
    assert Enum.count(methods, &(&1 == "thread/start")) == 2
    context
  end

  step "the thread keeps its history in HAL-C2", context do
    # Both user messages and an answer to each are the thread's, whoever ran them.
    messages = StreamState.list(World.stream(context, @thread), "message")
    assert Enum.count(messages, &(&1["role"] == "user")) == 2
    assert "Hello from codex" in World.replies(context, @thread)
    context
  end

  step "the user sees that error", context do
    state = World.await_runs(context, @thread, ["completed", "failed"])
    assert [%{"lastError" => error}] = StreamState.list(state, "provider-session")
    assert error =~ "resume blew up"
    context
  end

  step "no new Codex conversation is started", context do
    methods =
      for %{"in" => %{"method" => method}} <- World.provider_log(context, "codex"), do: method

    assert Enum.count(methods, &(&1 == "thread/start")) == 1
    context
  end

  # --- mode and instructions -----------------------------------------------------------------

  step "a Codex thread that was in plan mode and is resumed in default mode", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "make a plan", %{"interactionMode" => "plan"})

    World.await_runs(context, @thread, ["completed"])

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.interaction-mode.set",
        "commandId" => "cmd-mode-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread),
        "interactionMode" => "default"
      })

    context
  end

  step "Codex is told it is in default mode and that plan mode no longer applies", context do
    modes =
      for %{"in" => %{"method" => "turn/start", "params" => params}} <-
            World.provider_log(context, "codex"),
          do: get_in(params, ["collaborationMode", "mode"])

    assert modes == ["plan", "default"]
    context
  end

  step "the {string} server is attached to a Codex thread", _args = context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Mcp)
    context
  end

  step "the {string} server is attached to a Codex thread without browser or device tools",
       _args = context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Mcp)
    Map.put(context, :pending_launch, %{instance: "codex", fields: %{}})
  end

  step "the user sends a message in plan mode and then one in default mode", context do
    context =
      World.launch_on(context, @thread, "codex", "make a plan", %{"interactionMode" => "plan"})

    World.await_runs(context, @thread, ["completed"])

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.interaction-mode.set",
        "commandId" => "cmd-mode-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread),
        "interactionMode" => "default"
      })

    context = World.post_message(context, @thread, "hello")
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  defp turn_instructions(context) do
    for %{"in" => %{"method" => "turn/start", "params" => params}} <-
          World.provider_log(context, "codex"),
        do: get_in(params, ["collaborationMode", "settings", "developer_instructions"])
  end

  step "Codex receives HAL-C2's orchestration instructions with the second message only",
       context do
    assert [nil, instructions] = turn_instructions(context)
    assert instructions =~ "HAL-C2 orchestration"
    context
  end

  step "Codex's instructions do not describe browser or device tools", context do
    assert [instructions] = turn_instructions(context)
    refute instructions =~ "preview_"
    refute instructions =~ "device_"
    refute instructions =~ "HAL-C2 devices"
    refute instructions =~ "collaborative browser"
    context
  end

  step "a Codex thread that has no {string} server attached", _args = context do
    context = World.fake_providers(context)
    Mc.ensure(HalC2.Mcp)
    id = World.project(context).id

    context =
      World.update_settings(context, %{
        "projectSettingsOverrides" => %{id => %{"enableAgentBrowserAccess" => false}}
      })

    context = World.launch_on(context, "Work", "codex", "hello")
    World.await_runs(context, "Work", ["completed"])
    # The thread's row names its project now, which the next turn's tools read.
    World.await_row(World.thread_id(context, "Work"), & &1)
    context
  end

  step "Codex receives no instructions from HAL-C2 beyond the message", context do
    instructions = turn_instructions(context)
    assert instructions != []
    assert List.last(instructions) == nil
    context
  end

  # --- account homes ---------------------------------------------------------------------------

  step "the second instance is prepared", context do
    # Entries only a shadow home keeps for itself, in the shared home first.
    for name <- ["log", "memories", "tmp"] do
      File.mkdir_p!(Path.join(context.codex_shared, name))
    end

    assert {:ok, [{"CODEX_HOME", home}]} = HalC2.Codex.Home.env(@second)
    assert home == context.codex_shadow
    context
  end

  step "its login and its model cache are its own files and are never linked to the shared home",
       context do
    for name <- ["auth.json", "models_cache.json"] do
      case File.lstat(Path.join(context.codex_shadow, name)) do
        {:ok, %File.Stat{type: type}} -> assert type == :regular
        {:error, :enoent} -> :ok
      end
    end

    context
  end

  step "its logs, memories and temporary files stay in its own home", context do
    for name <- ["log", "memories", "tmp"] do
      case File.lstat(Path.join(context.codex_shadow, name)) do
        {:ok, %File.Stat{type: type}} -> assert type != :symlink
        {:error, :enoent} -> :ok
      end
    end

    context
  end

  step "everything else in the shared home is reached through links", context do
    for name <- File.ls!(context.codex_shared),
        name not in ["auth.json", "models_cache.json", "log", "memories", "tmp"] do
      assert File.read_link!(Path.join(context.codex_shadow, name)) ==
               Path.join(context.codex_shared, name)
    end

    context
  end

  step "a Codex instance's shadow home has a link that no longer points into the shared home",
       context do
    context = shadow_setup(context)
    assert {:ok, _} = HalC2.Codex.Home.env(@second)
    link = Path.join(context.codex_shadow, "config.toml")
    File.rm!(link)
    File.ln_s!(Path.join(context.codex_shared, "auth.json"), link)
    # A folder the shared home is missing by the time it is prepared again.
    File.rm_rf!(Path.join(context.codex_shared, "sessions"))
    context
  end

  step "the instance is prepared", context do
    Map.put(context, :prepare_result, HalC2.Codex.Home.env(@second))
  end

  step "the link points into the shared home again", context do
    assert {:ok, _} = context.prepare_result

    assert File.read_link!(Path.join(context.codex_shadow, "config.toml")) ==
             Path.join(context.codex_shared, "config.toml")

    context
  end

  step "folders the shared home was missing are created", context do
    assert File.dir?(Path.join(context.codex_shared, "sessions"))
    context
  end

  # The shared/shadow setup of the accounts scenarios, by its Given step.
  defp shadow_setup(context) do
    context = World.fake_providers(context)
    shared = HalC2.Test.Mc.tmp_dir(context.mc, "codex-home")
    shadow = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "codex-shadows"), "work")
    File.write!(Path.join(shared, "config.toml"), "model = \"gpt-6-luna\"\n")
    File.write!(Path.join(shared, "auth.json"), ~s({"account":"home"}))

    World.merge_settings(%{
      "providers" => %{"codex" => %{"homePath" => shared}},
      "providerInstances" => %{
        @second => %{
          "driver" => "codex",
          "enabled" => true,
          "config" => %{"homePath" => shared, "shadowHomePath" => shadow}
        }
      }
    })

    Map.merge(context, %{codex_shared: shared, codex_shadow: shadow})
  end

  defp snapshot_files(context) do
    Map.put(
      context,
      :before_files,
      Map.new(["config.toml", "auth.json"], fn name ->
        {name,
         {File.read(Path.join(context.codex_shared, name)),
          File.read(Path.join(context.codex_shadow, name))}}
      end)
    )
  end

  step ~r/^a Codex instance with its own shadow home where (?<situation>the shadow home is the shared home itself|a real file sits where a link to the shared home belongs|the login file is a link)$/,
       %{args: [situation]} = context do
    context = shadow_setup(context)

    context =
      case situation do
        "the shadow home is the shared home itself" ->
          World.merge_settings(%{
            "providerInstances" => %{
              @second => %{
                "config" => %{
                  "homePath" => context.codex_shared,
                  "shadowHomePath" => context.codex_shared
                }
              }
            }
          })

          context

        "a real file sits where a link to the shared home belongs" ->
          File.mkdir_p!(context.codex_shadow)
          File.write!(Path.join(context.codex_shadow, "config.toml"), "mine\n")
          context

        "the login file is a link" ->
          File.mkdir_p!(context.codex_shadow)

          File.ln_s!(
            Path.join(context.codex_shared, "auth.json"),
            Path.join(context.codex_shadow, "auth.json")
          )

          context
      end

    snapshot_files(context)
  end

  @refusals %{
    "the shadow home must be different from the shared home" =>
      "must be different from the shared home path",
    "the entry already exists and is not a link" => "already exists and is not a symlink",
    "the login must be a real file, not a link" => "must be a real file, not a symlink"
  }

  step ~r/^preparing fails saying (?<reason>.+)$/, %{args: [reason]} = context do
    assert {:error, message} = context.prepare_result
    assert message =~ Map.fetch!(@refusals, reason)
    context
  end

  step "no file is overwritten", context do
    for {name, {shared, shadow}} <- context.before_files do
      assert File.read(Path.join(context.codex_shared, name)) == shared

      # The login link is the refusal itself; it stays a link, unread here.
      unless match?(
               {:ok, %File.Stat{type: :symlink}},
               File.lstat(Path.join(context.codex_shadow, name))
             ),
             do: assert(File.read(Path.join(context.codex_shadow, name)) == shadow)
    end

    context
  end

  step "a Codex instance whose own home cannot be prepared from the shared one", context do
    context = shadow_setup(context)
    File.mkdir_p!(context.codex_shadow)
    File.write!(Path.join(context.codex_shadow, "config.toml"), "mine\n")
    Map.put(context, :pending_launch, %{instance: @second, fields: %{}})
  end

  step "the turn fails with {string}", %{args: [message]} = context do
    state = World.await_runs(context, "Work", ["failed"])
    assert [%{"lastError" => error}] = StreamState.list(state, "provider-session")
    assert error =~ message
    context
  end

  step "Codex is not started against the shared home instead", context do
    homes = for %{"argv" => _, "home" => home} <- World.provider_log(context, "codex"), do: home
    refute context.codex_shared in homes
    context
  end

  # --- switching accounts ------------------------------------------------------------------------

  step "two Codex instances share a Codex home", context do
    context = World.fake_providers(context)

    # The accounts setup, through its own steps' arrangement.
    context =
      Map.merge(context, %{
        codex_shared: HalC2.Test.Mc.tmp_dir(context.mc, "codex-home"),
        codex_shadow: Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "codex-shadows"), "work")
      })

    File.write!(Path.join(context.codex_shared, "config.toml"), "model = \"gpt-6-luna\"\n")
    File.write!(Path.join(context.codex_shared, "auth.json"), ~s({"account":"home"}))
    World.put_os_env("FAKE_SESSIONS", "1")

    World.merge_settings(%{
      "providers" => %{"codex" => %{"homePath" => context.codex_shared}},
      "providerInstances" => %{
        @second => %{
          "driver" => "codex",
          "enabled" => true,
          "config" => %{
            "homePath" => context.codex_shared,
            "shadowHomePath" => context.codex_shadow
          }
        }
      }
    })

    context = World.launch_on(context, @thread, "codex", "hello from home")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the user picks the other account from the thread's model picker", context do
    # The picker offers it: both instances carry the shared home's group.
    {providers, context} = World.provider_list(context)
    groups = Map.new(providers, &{&1["instanceId"], get_in(&1, ["continuation", "groupKey"])})
    assert groups["codex"] != nil and groups["codex"] == groups[@second]

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.model-selection.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread),
        "modelSelection" => %{"instanceId" => @second, "model" => "gpt-5.4"}
      })

    context = World.post_message(context, @thread, "hello from work")
    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "the thread continues on that account without moving its history", context do
    messages = StreamState.list(World.stream(context, @thread), "message")
    user = for m <- messages, m["role"] == "user", do: m["text"]
    assert "hello from home" in user and "hello from work" in user
    assert World.replies(context, @thread) != []
    homes = for %{"argv" => _, "home" => home} <- World.provider_log(context, "codex"), do: home
    assert List.last(homes) == context.codex_shadow
    # Both turns' conversations live in the one shared home.
    rollouts = Path.wildcard(Path.join(context.codex_shared, "sessions/*/*/*/rollout-*.jsonl"))
    assert rollouts != []
    context
  end

  step "a Codex instance with a separate Codex home", context do
    context = World.fake_providers(context)
    other = HalC2.Test.Mc.tmp_dir(context.mc, "codex-elsewhere")

    World.merge_settings(%{
      "providerInstances" => %{
        "codex-else" => %{
          "driver" => "codex",
          "enabled" => true,
          "config" => %{"homePath" => other}
        }
      }
    })

    context = World.launch_on(context, @thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :codex_other_home, other)
  end

  step "the user opens the model picker in an existing Codex thread", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :providers, providers)
  end

  step "that instance is not offered for the thread", context do
    groups =
      Map.new(context.providers, &{&1["instanceId"], get_in(&1, ["continuation", "groupKey"])})

    # The picker filters an existing thread's accounts by continuation group:
    # a home of its own is another group, so the instance is not among them.
    assert groups["codex-else"] != nil
    assert groups["codex-else"] != groups["codex"]
    context
  end

  # --- driving a running turn (shared by the backlog groups below) ------------------------------

  # A turn Codex holds open, into which the scenario delivers what Codex sends.
  defp start_waiting(context) do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    context
  end

  defp ctx_params(context) do
    {_, runtime} = World.codex_runtime(context, @thread)
    %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
  end

  # A request from Codex, delivered as the app-server would send it.
  defp codex_request(context, id, method, params) do
    {pid, runtime} = World.codex_runtime(context, @thread)

    send(
      pid,
      {:json_rpc, runtime.conn, {:request, id, method, Map.merge(ctx_params(context), params)}}
    )

    Map.put(context, :request, World.await_request(context, @thread))
  end

  defp notify_item(context, event, item) do
    World.codex_notify(
      context,
      @thread,
      "item/#{event}",
      Map.put(ctx_params(context), "item", item)
    )
  end

  defp await_item(context, fun) do
    World.await_value(context, @thread, fn state ->
      Enum.find(StreamState.list(state, "turn-item"), fun)
    end)
  end

  # What Codex was told back for the request a scenario delivered as `id`.
  defp codex_answer(context, id) do
    World.await_provider_log(
      context,
      "codex",
      &(get_in(&1, ["in", "id"]) == id and get_in(&1, ["in", "method"]) == nil)
    )["in"]
  end

  # --- what an approval says ---------------------------------------------------------------------

  step ~r/^Codex asks to (?<action>run a command|change files) and gives (?<given>a reason|no reason|no reason and a file to move|no reason and no files, a root)$/,
       %{args: [action, given]} = context do
    context = start_waiting(context)

    {method, params} =
      case {action, given} do
        {"run a command", "a reason"} ->
          {"item/commandExecution/requestApproval",
           %{"itemId" => "cmd-x", "command" => "touch x", "reason" => "needs it"}}

        {"run a command", "no reason"} ->
          {"item/commandExecution/requestApproval",
           %{"itemId" => "cmd-x", "command" => "touch x"}}

        {"change files", "a reason"} ->
          {"item/fileChange/requestApproval", %{"itemId" => "file-x", "reason" => "needs it"}}

        {"change files", "no reason"} ->
          {"item/fileChange/requestApproval",
           %{
             "itemId" => "file-x",
             "fileChanges" => %{"b.txt" => %{"type" => "add"}, "a.txt" => %{"type" => "update"}}
           }}

        {"change files", "no reason and a file to move"} ->
          {"item/fileChange/requestApproval",
           %{
             "itemId" => "file-x",
             "fileChanges" => %{"old.txt" => %{"type" => "update", "move_path" => "new.txt"}}
           }}

        {"change files", "no reason and no files, a root"} ->
          {"item/fileChange/requestApproval", %{"itemId" => "file-x", "grantRoot" => "/tmp/root"}}
      end

    codex_request(context, "approval-x", method, params)
  end

  defp approval_prompt(context) do
    await_item(context, &(&1["type"] == "approval_request" and &1["prompt"] != nil))["prompt"]
  end

  @approval_shown %{
    "Codex's reason" => "needs it",
    "the command" => "touch x",
    "each file with what would be done to it" => "update a.txt\nadd b.txt",
    "the file's old path and its new path" => "update old.txt -> new.txt",
    "the folder Codex wants to write under" => "/tmp/root"
  }

  step ~r/^the approval shows (?<shown>.+)$/, %{args: [shown]} = context do
    assert approval_prompt(context) == Map.fetch!(@approval_shown, shown)
    context
  end

  step "Codex asks without a reason to change 23 files", context do
    context = start_waiting(context)

    changes =
      Map.new(1..23, fn i ->
        {"file-#{String.pad_leading(Integer.to_string(i), 2, "0")}.txt", %{"type" => "add"}}
      end)

    codex_request(context, "approval-x", "item/fileChange/requestApproval", %{
      "itemId" => "file-x",
      "fileChanges" => changes
    })
  end

  step "the approval lists the first 20 files in path order", context do
    prompt = approval_prompt(context)
    lines = String.split(prompt, "\n")

    expected =
      for i <- 1..20, do: "add file-#{String.pad_leading(Integer.to_string(i), 2, "0")}.txt"

    assert Enum.take(lines, 20) == expected
    Map.put(context, :approval_prompt, prompt)
  end

  step "it ends with {string}", %{args: [ending]} = context do
    assert String.ends_with?(context.approval_prompt, ending)
    context
  end

  # --- an older Codex's approvals ------------------------------------------------------------------

  step "a Codex that asks for approvals in its older form", context do
    start_waiting(context)
  end

  @legacy_decisions %{
    "allow once" => "accept",
    "allow for the session" => "acceptForSession",
    "decline" => "decline",
    "cancel" => "cancel"
  }

  step ~r/^Codex asks to (?<action>run a command|apply a patch) and the user answers (?<decision>allow once|allow for the session|decline|cancel)$/,
       %{args: [action, decision]} = context do
    {_, runtime} = World.codex_runtime(context, @thread)

    {method, params} =
      case action do
        "run a command" ->
          {"execCommandApproval",
           %{
             "conversationId" => runtime.native_thread_id,
             "callId" => "legacy-1",
             "command" => ["touch", "x"]
           }}

        "apply a patch" ->
          {"applyPatchApproval",
           %{
             "conversationId" => runtime.native_thread_id,
             "callId" => "legacy-1",
             "fileChanges" => %{"a.txt" => %{"type" => "add"}}
           }}
      end

    context = codex_request(context, "legacy-req", method, params)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, @thread),
        "requestId" => context.request["id"],
        "decision" => @legacy_decisions[decision]
      })

    context
  end

  step "Codex is told {string}", %{args: [answer]} = context do
    assert get_in(codex_answer(context, "legacy-req"), ["result", "decision"]) == answer
    context
  end

  # --- introducing HAL-C2, and the diff opt-out ------------------------------------------------------

  step "Codex is told the client is {string} titled {string}",
       %{args: [name, title]} = context do
    init =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "initialize"))

    assert get_in(init, ["in", "params", "clientInfo"]) == %{
             "name" => name,
             "title" => title,
             "version" => "0.1.0"
           }

    context
  end

  step "HAL-C2 opts out of Codex's {string} notifications", %{args: [method]} = context do
    init =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "initialize"))

    assert method in get_in(init, ["in", "params", "capabilities", "optOutNotificationMethods"])
    context
  end

  step "changed files are still shown from the file changes Codex reports", context do
    context = World.post_message(context, @thread, "edit changed.txt")
    World.await_runs(context, @thread, ["completed", "completed"])
    assert await_item(context, &(&1["type"] == "file_change"))
    context
  end

  # --- tool calls, web search, and how tools are shown ------------------------------------------------

  step "Codex calls the tool {string} on the MCP server {string}",
       %{args: [tool, server]} = context do
    context = start_waiting(context)

    item = %{
      "type" => "mcpToolCall",
      "id" => "mcp-1",
      "server" => server,
      "tool" => tool,
      "arguments" => %{"q" => "hal"},
      "status" => "completed",
      "result" => %{"structuredContent" => %{"hits" => 1}}
    }

    notify_item(context, "started", item)
    notify_item(context, "completed", item)
    context
  end

  step "the tool call is shown as {string} with its arguments", %{args: [name]} = context do
    item = await_item(context, &(&1["type"] == "dynamic_tool" and &1["status"] == "completed"))
    assert item["toolName"] == name
    assert item["input"] == %{"q" => "hal"}
    Map.put(context, :tool_item, item)
  end

  step "its result is shown when the call finishes", context do
    assert context.tool_item["output"] == %{"hits" => 1}
    context
  end

  step "a tool Codex called on an MCP server fails", context do
    context = start_waiting(context)

    item = %{
      "type" => "mcpToolCall",
      "id" => "mcp-1",
      "server" => "docs",
      "tool" => "search",
      "arguments" => %{},
      "status" => "failed",
      "error" => %{"message" => "the server said no"}
    }

    notify_item(context, "started", item)
    notify_item(context, "completed", item)
    context
  end

  step "the tool call is shown as failed with the error the server gave", context do
    item = await_item(context, &(&1["type"] == "dynamic_tool" and &1["status"] == "failed"))
    assert item["output"] == %{"error" => "the server said no"}
    context
  end

  step ~r/^Codex (?<action>searches the web|opens a page|looks for text in a page)$/,
       %{args: [action]} = context do
    context = start_waiting(context)

    web_action =
      case action do
        "searches the web" ->
          %{"type" => "search", "queries" => ["hal c2", "codex"]}

        "opens a page" ->
          %{"type" => "openPage", "url" => "https://example.com/docs"}

        "looks for text in a page" ->
          %{"type" => "findInPage", "pattern" => "install", "url" => "https://example.com/docs"}
      end

    notify_item(context, "completed", %{
      "type" => "webSearch",
      "id" => "web-1",
      "action" => web_action
    })

    context
  end

  @web_shown %{
    "the queries it searched for" => ["hal c2", "codex"],
    "the address of the page" => ["https://example.com/docs"],
    "the text and the page's address" => ["install", "https://example.com/docs"]
  }

  step ~r/^the web search entry shows (?<shown>.+)$/, %{args: [shown]} = context do
    item = await_item(context, &(&1["type"] == "web_search" and &1["status"] == "completed"))
    assert item["patterns"] == Map.fetch!(@web_shown, shown)
    context
  end

  # A browser or computer tool call, as Codex reports it in the result's surface.
  defp surface_call(context, id, surface) do
    context =
      if context[:waiting], do: context, else: start_waiting(Map.put(context, :waiting, true))

    item = %{
      "type" => "mcpToolCall",
      "id" => id,
      "server" => "codex",
      "tool" => "use",
      "arguments" => %{},
      "status" => "completed",
      "result" => %{"_meta" => %{"codex/toolSurface" => surface}}
    }

    notify_item(context, "started", item)
    notify_item(context, "completed", item)
    context
  end

  defp work_items(context) do
    World.await_value(context, @thread, fn state ->
      items =
        Enum.filter(
          StreamState.list(state, "turn-item"),
          &(&1["type"] == "dynamic_tool" and &1["status"] == "completed" and &1["toolSurface"])
        )

      if items == [], do: nil, else: items
    end)
  end

  step "Codex uses its browser tool on {string}", %{args: [url]} = context do
    surface_call(context, "browser-1", %{
      "kind" => "browserUse",
      "screenshot" => %{"pageUrl" => url, "faviconUrl" => "https://example.com/favicon.ico"}
    })
  end

  step "Codex uses its browser tool on a page whose address is {string}",
       %{args: [url]} = context do
    surface_call(context, "browser-1", %{
      "kind" => "browserUse",
      "screenshot" => %{"pageUrl" => url, "faviconUrl" => "https://example.com/favicon.ico"}
    })
  end

  step "the work log entry is marked as browser work", context do
    assert [%{"toolSurface" => "browser"} = item] = work_items(context)
    Map.put(context, :work_item, item)
  end

  step "it shows the page's address and favicon", context do
    assert %{
             "_tag" => "website",
             "pageUrl" => "https://example.com/docs",
             "faviconUrl" => favicon
           } =
             context.work_item["toolIcon"]

    assert favicon == "https://example.com/favicon.ico"
    context
  end

  step "the work log entry shows no page address or favicon", context do
    assert [item] = work_items(context)
    assert item["toolSurface"] == "browser"
    refute Map.has_key?(item, "toolIcon")
    context
  end

  step ~r/^Codex uses its browser tool through (?<reported>Google Chrome|Chromium|Microsoft Edge|Firefox Developer|Safari|the in-app browser|nothing)$/,
       %{args: [reported]} = context do
    surface =
      case reported do
        "the in-app browser" -> %{"kind" => "browserUse", "browserFamily" => "iab"}
        "nothing" -> %{"kind" => "browserUse"}
        family -> %{"kind" => "browserUse", "browserFamily" => family}
      end

    surface_call(context, "browser-1", surface)
  end

  step "the work log entry names the browser {string}", %{args: [name]} = context do
    assert [item] = work_items(context)
    assert item["toolSource"]["name"] == name
    context
  end

  step "Codex uses its computer tool on the application {string}",
       %{args: [app]} = context do
    surface_call(context, "computer-1", %{
      "kind" => "computerUse",
      "app" => %{"kind" => "displayName", "displayName" => app}
    })
  end

  step "the work log entry is marked as computer work", context do
    assert [%{"toolSurface" => "computer"} = item] = work_items(context)
    Map.put(context, :work_item, item)
  end

  step "it names {string} and shows its application icon", %{args: [app]} = context do
    assert context.work_item["toolSource"]["name"] == app

    assert context.work_item["toolIcon"] ==
             %{"_tag" => "native-app", "app" => %{"_tag" => "display-name", "displayName" => app}}

    context
  end

  step "Codex makes two computer tool calls on the same application", context do
    surface = %{
      "kind" => "computerUse",
      "app" => %{"kind" => "displayName", "displayName" => "Finder"}
    }

    context = surface_call(context, "computer-1", surface)

    item = %{
      "type" => "mcpToolCall",
      "id" => "computer-2",
      "server" => "codex",
      "tool" => "use",
      "arguments" => %{},
      "status" => "completed",
      "result" => %{"_meta" => %{"codex/toolSurface" => surface}}
    }

    notify_item(context, "started", item)
    notify_item(context, "completed", item)
    context
  end

  step "both work log entries are grouped under that application", context do
    items =
      World.await_value(context, @thread, fn state ->
        items =
          Enum.filter(
            StreamState.list(state, "turn-item"),
            &(&1["type"] == "dynamic_tool" and &1["status"] == "completed" and &1["toolSurface"])
          )

        if length(items) == 2, do: items
      end)

    assert [%{"toolSource" => %{"name" => "Finder"}} = first, second] = items
    assert first["toolSource"]["key"] == second["toolSource"]["key"]

    context
  end

  step "Codex uses its computer tool and reports no application", context do
    surface_call(context, "computer-1", %{"kind" => "computerUse"})
  end

  step "the work log entry names {string}", %{args: [name]} = context do
    assert [%{"toolSource" => %{"name" => ^name}} = item] = work_items(context)
    Map.put(context, :work_item, item)
  end

  step "shows no application icon", context do
    refute Map.has_key?(context.work_item, "toolIcon")
    context
  end

  # --- leaving auto, reasoning, service tier -----------------------------------------------------------

  step "a Codex thread that ran a turn in auto mode", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "approve", %{"runtimeMode" => "auto"})

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the user changes the thread to approval required and sends a message", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.runtime-mode.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread),
        "runtimeMode" => "approval-required"
      })

    World.post_message(context, @thread, "approve")
  end

  step "Codex is told the user reviews approvals", context do
    turn =
      World.await_provider_log(context, "codex", fn entry ->
        get_in(entry, ["in", "method"]) == "turn/start" and
          get_in(entry, ["in", "params", "approvalsReviewer"]) == "user" and
          Enum.count(
            World.provider_log(context, "codex"),
            &(get_in(&1, ["in", "method"]) == "turn/start")
          ) > 1
      end)

    assert get_in(turn, ["in", "params", "approvalsReviewer"]) == "user"
    context
  end

  step "Codex asks the user instead of its automatic reviewer", context do
    assert World.await_request(context, @thread)["kind"] == "command"
    context
  end

  step "Codex is asked for detailed reasoning summaries", context do
    turn =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))

    assert get_in(turn, ["in", "params", "summary"]) == "detailed"
    context
  end

  step "the summaries and any raw reasoning Codex sends are shown as the turn's thinking",
       context do
    context = start_waiting(context)
    params = Map.put(ctx_params(context), "itemId", "think-1")

    World.codex_notify(
      context,
      @thread,
      "item/reasoning/summaryTextDelta",
      Map.put(params, "delta", "In short. ")
    )

    World.codex_notify(
      context,
      @thread,
      "item/reasoning/textDelta",
      Map.put(params, "delta", "Raw detail.")
    )

    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    item =
      await_item(context, &(&1["type"] == "reasoning" and &1["text"] == "In short. Raw detail."))

    assert item["text"] == "In short. Raw detail."
    context
  end

  step ~r/^a Codex thread whose model selection has (?<selection>.+)$/,
       %{args: [selection]} = context do
    options =
      case selection do
        ~s(the service tier "fast") -> [%{"id" => "serviceTier", "value" => "fast"}]
        "fast mode on and no service tier" -> [%{"id" => "fastMode", "value" => true}]
        "fast mode off and no service tier" -> [%{"id" => "fastMode", "value" => false}]
      end

    context = World.fake_providers(context)

    Map.put(context, :pending_launch, %{
      instance: "codex",
      fields: %{
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4", "options" => options}
      }
    })
  end

  step ~r/^the turn is sent to Codex (?<tier>.+)$/, %{args: [tier]} = context do
    turn =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))

    params = get_in(turn, ["in", "params"])

    case tier do
      ~s(on the "fast" service tier) -> assert params["serviceTier"] == "fast"
      "without naming a service tier" -> refute Map.has_key?(params, "serviceTier")
    end

    context
  end

  # --- retries and failures --------------------------------------------------------------------------------

  defp codex_error(context, error, will_retry) do
    World.codex_notify(
      context,
      @thread,
      "error",
      Map.merge(ctx_params(context), %{"willRetry" => will_retry, "error" => error})
    )
  end

  step "Codex reports {string} and says it will retry", %{args: [message]} = context do
    codex_error(context, %{"message" => message}, true)
    context
  end

  step "the turn shows a retry on attempt 2 of 5", context do
    item = await_item(context, &(&1["type"] == "error" and get_in(&1, ["retry", "attempt"]) == 2))
    assert item["retry"] == %{"attempt" => 2, "maxAttempts" => 5, "retryDelayMs" => nil}
    context
  end

  step "the turn keeps running", context do
    assert %{"status" => "running"} = World.latest_run(context, @thread)
    context
  end

  step "Codex reports twice that it will retry without saying which attempt it is on", context do
    codex_error(context, %{"message" => "Reconnecting..."}, true)
    await_item(context, &(&1["type"] == "error" and get_in(&1, ["retry", "attempt"]) == 1))
    codex_error(context, %{"message" => "Reconnecting..."}, true)
    context
  end

  step "the turn shows a retry on attempt 2 with no known maximum", context do
    item = await_item(context, &(&1["type"] == "error" and get_in(&1, ["retry", "attempt"]) == 2))
    assert item["retry"]["maxAttempts"] == nil
    context
  end

  step "a Codex turn fails with a short message and additional details", context do
    context = start_waiting(context)
    {_, runtime} = World.codex_runtime(context, @thread)

    codex_error(
      context,
      %{"message" => "short", "additionalDetails" => "the fuller explanation"},
      false
    )

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "failed"}
    })

    context
  end

  step "the turn's failure shows the additional details", context do
    state = World.await_runs(context, @thread, ["failed"])

    assert [%{"lastError" => "the fuller explanation"}] =
             StreamState.list(state, "provider-session")

    context
  end

  # --- question blanks, elicitation declines, resume shape --------------------------------------------------

  step "Codex asks a question with no heading, no text and unlabelled choices", context do
    context = start_waiting(context)

    codex_request(context, "input-x", "item/tool/requestUserInput", %{
      "itemId" => "ask-x",
      "questions" => [
        %{
          "id" => "q1",
          "header" => "",
          "question" => "",
          "options" => [%{"label" => ""}, %{"label" => ""}]
        }
      ]
    })
  end

  step "the question is shown under {string} asking {string}",
       %{args: [header, question]} = context do
    item = await_item(context, &(&1["type"] == "user_input_request" and &1["questions"]))
    assert [%{"header" => ^header, "question" => ^question} = shown] = item["questions"]
    Map.put(context, :shown_question, shown)
  end

  step "its choices are labelled {string}, {string} and so on",
       %{args: [first, second]} = context do
    assert Enum.map(context.shown_question["options"], & &1["label"]) == [first, second]
    context
  end

  step "a tool's server asks the user for something HAL-C2 has no way to present", context do
    context = start_waiting(context)
    {pid, runtime} = World.codex_runtime(context, @thread)

    params = %{
      "mode" => "url",
      "serverName" => "codex_apps",
      "message" => "Connect the app",
      "url" => "https://example.com/connect"
    }

    send(
      pid,
      {:json_rpc, runtime.conn,
       {:request, "elicit-x", "mcpServer/elicitation/request",
        Map.merge(ctx_params(context), params)}}
    )

    Map.put(context, :elicitation_id, "elicit-x")
  end

  step "the request is declined without asking the user", context do
    assert get_in(codex_answer(context, context.elicitation_id), ["result", "action"]) ==
             "decline"

    assert StreamState.list(World.stream(context, @thread), "runtime-request") == []
    context
  end

  step "the turn goes on", context do
    assert %{"status" => "running"} = World.latest_run(context, @thread)
    context
  end

  step "no Codex turn is running in the thread", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "a tool's server asks the user for access", context do
    {pid, runtime} = World.codex_runtime(context, @thread)

    params = %{
      "threadId" => runtime.native_thread_id,
      "serverName" => "codex_apps",
      "mode" => "form",
      "message" => "Allow ChatGPT to use Linear?",
      "_meta" => %{"persist" => ["session", "always"]},
      "requestedSchema" => %{"type" => "object", "properties" => %{}}
    }

    send(
      pid,
      {:json_rpc, runtime.conn, {:request, "elicit-y", "mcpServer/elicitation/request", params}}
    )

    Map.put(context, :elicitation_id, "elicit-y")
  end

  step "a Codex thread with a long conversation", context do
    context
    |> World.fake_providers()
    |> World.run_turns(@thread, "codex", ["hello", "hello again", "one more"])
  end

  step "the MC resumes it to run a new message", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    context = World.post_message(context, @thread, "where are we")
    World.await_runs(context, @thread, ["completed", "completed", "completed", "completed"])
    context
  end

  step "Codex is asked to resume without sending back its earlier turns", context do
    resume =
      World.await_provider_log(
        context,
        "codex",
        &(get_in(&1, ["in", "method"]) == "thread/resume")
      )

    assert get_in(resume, ["in", "params", "excludeTurns"]) == true
    context
  end

  # --- subagents -------------------------------------------------------------------------------------

  defp spawn_subagent(context, call_id, child, states) do
    notify_item(context, "started", %{
      "type" => "collabAgentToolCall",
      "id" => call_id,
      "tool" => "spawnAgent",
      "prompt" => "List the modules in lib",
      "senderThreadId" => ctx_params(context)["threadId"],
      "receiverThreadIds" => [child],
      "status" => "inProgress",
      "agentsStates" => states
    })

    context
  end

  defp subagent_entity(context) do
    World.await_value(context, @thread, fn state ->
      case StreamState.list(state, "subagent") do
        [subagent] -> subagent
        _ -> nil
      end
    end)
  end

  defp await_subagent_status(context, status) do
    World.await_value(context, @thread, fn state ->
      Enum.find(StreamState.list(state, "subagent"), &(&1["status"] == status))
    end)
  end

  @reported %{
    "waiting to start" => "pendingInit",
    "running" => "running",
    "interrupted" => "interrupted",
    "completed" => "completed",
    "errored" => "errored",
    "shut down" => "shutdown",
    "not found" => "notFound"
  }

  step ~r/^Codex reports a subagent as (?<reported>waiting to start|running|interrupted|completed|errored|shut down|not found)$/,
       %{args: [reported]} = context do
    context = start_waiting(context)

    spawn_subagent(context, "collab-1", "native-child-1", %{
      "native-child-1" => %{"status" => @reported[reported]}
    })
  end

  step ~r/^the subagent is shown as (?<shown>pending|running|interrupted|completed|failed|cancelled)$/,
       %{args: [shown]} = context do
    assert await_subagent_status(context, shown)
    context
  end

  step "Codex starts a subagent with a task", context do
    context = start_waiting(context)
    context = spawn_subagent(context, "collab-1", "native-child-1", %{})

    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => "native-child-1",
      "turnId" => "native-child-turn-1",
      "item" => %{
        "type" => "agentMessage",
        "id" => "child-msg",
        "text" => "lib has three modules"
      }
    })

    notify_item(context, "completed", %{
      "type" => "collabAgentToolCall",
      "id" => "collab-1",
      "tool" => "spawnAgent",
      "prompt" => "List the modules in lib",
      "receiverThreadIds" => ["native-child-1"],
      "status" => "completed",
      "agentsStates" => %{"native-child-1" => %{"status" => "completed"}}
    })

    context
  end

  step "the subagent's thread starts with that task as its first message", context do
    subagent = await_subagent_status(context, "completed")
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(subagent["childThreadId"]))

    assert [{"user", "List the modules in lib"} | _] =
             child
             |> StreamState.list("message")
             |> Enum.sort_by(& &1["createdAt"])
             |> Enum.map(&{&1["role"], &1["text"]})

    Map.put(context, :subagent, subagent)
  end

  step "the subagent's final answer is shown as its result on the parent's turn", context do
    assert context.subagent["result"] == "lib has three modules"
    context
  end

  step "a Codex subagent sends commentary and then a final answer", context do
    context = start_waiting(context)
    context = spawn_subagent(context, "collab-1", "native-child-1", %{})

    for {id, phase, text} <- [
          {"child-note", "commentary", "working on it"},
          {"child-final", "final_answer", "done: three modules"}
        ] do
      World.codex_notify(context, @thread, "item/completed", %{
        "threadId" => "native-child-1",
        "turnId" => "native-child-turn-1",
        "item" => %{"type" => "agentMessage", "id" => id, "phase" => phase, "text" => text}
      })
    end

    notify_item(context, "completed", %{
      "type" => "collabAgentToolCall",
      "id" => "collab-1",
      "tool" => "spawnAgent",
      "receiverThreadIds" => ["native-child-1"],
      "status" => "completed",
      "agentsStates" => %{"native-child-1" => %{"status" => "completed"}}
    })

    context
  end

  step "the subagent's result is the final answer", context do
    assert await_subagent_status(context, "completed")["result"] == "done: three modules"
    context
  end

  # A subagent that ran its task to the end, on a turn still running.
  defp finished_subagent(context) do
    context = start_waiting(context)
    context = spawn_subagent(context, "collab-1", "native-child-1", %{})

    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => "native-child-1",
      "turnId" => "native-child-turn-1",
      "item" => %{"type" => "agentMessage", "id" => "child-msg", "text" => "first answer"}
    })

    notify_item(context, "completed", %{
      "type" => "collabAgentToolCall",
      "id" => "collab-1",
      "tool" => "spawnAgent",
      "receiverThreadIds" => ["native-child-1"],
      "status" => "completed",
      "agentsStates" => %{"native-child-1" => %{"status" => "completed"}}
    })

    await_subagent_status(context, "completed")
    context
  end

  step "a Codex subagent that finished its first task", context do
    finished_subagent(context)
  end

  step "Codex sends the subagent another message", context do
    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => "native-child-1",
      "turnId" => "native-child-turn-2",
      "item" => %{
        "type" => "userMessage",
        "id" => "child-user-2",
        "content" => [%{"type" => "text", "text" => "also check the tests"}]
      }
    })

    context
  end

  step "the message appears in the subagent's thread as coming from the parent", context do
    subagent = subagent_entity(context)
    child_id = subagent["childThreadId"]

    World.await_value(context, @thread, fn _state ->
      child = HalC2.Streams.Server.state(HalC2.Streams.ensure(child_id))

      Enum.find(
        StreamState.list(child, "message"),
        &(&1["role"] == "user" and &1["text"] == "also check the tests")
      )
    end)

    context
  end

  step "the subagent is shown as running again", context do
    assert await_subagent_status(context, "running")
    context
  end

  step "a Codex subagent that completed", context do
    finished_subagent(context)
  end

  step "Codex reports an older state for that subagent", context do
    notify_item(context, "started", %{
      "type" => "collabAgentToolCall",
      "id" => "collab-2",
      "tool" => "waitAgent",
      "receiverThreadIds" => ["native-child-1"],
      "status" => "inProgress",
      "agentsStates" => %{"native-child-1" => %{"status" => "running"}}
    })

    context
  end

  step "the subagent stays completed", context do
    # The runtime has taken the report (its next message is in), and the settled
    # subagent did not reopen.
    {pid, _} = World.codex_runtime(context, @thread)
    :sys.get_state(pid)
    assert subagent_entity(context)["status"] == "completed"
    context
  end

  step "a Codex turn with two subagents at work", context do
    context = start_waiting(context) |> Map.put(:thread, @thread)

    for {call, child} <- [{"collab-1", "native-child-1"}, {"collab-2", "native-child-2"}] do
      spawn_subagent(context, call, child, %{})

      World.codex_notify(context, @thread, "item/agentMessage/delta", %{
        "threadId" => child,
        "turnId" => "#{child}-turn-1",
        "itemId" => "#{child}-msg",
        "delta" => "working"
      })
    end

    {pid, _} = World.codex_runtime(context, @thread)
    :sys.get_state(pid)
    context
  end

  step "both subagents' turns are stopped", context do
    for child <- ["native-child-1", "native-child-2"] do
      World.await_provider_log(context, "codex", fn entry ->
        get_in(entry, ["in", "method"]) == "turn/interrupt" and
          get_in(entry, ["in", "params", "threadId"]) == child
      end)
    end

    context
  end

  step "both subagents are shown as interrupted", context do
    World.await_value(context, @thread, fn state ->
      subagents = StreamState.list(state, "subagent")
      length(subagents) == 2 and Enum.all?(subagents, &(&1["status"] == "interrupted"))
    end)

    context
  end

  step "a Codex turn that was stopped", context do
    context = start_waiting(context) |> Map.put(:thread, @thread)
    context = spawn_subagent(context, "collab-1", "native-child-1", %{})

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread),
        "runId" => World.latest_run(context, @thread)["id"]
      })

    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  step "one of its subagents starts another turn", context do
    World.codex_notify(context, @thread, "turn/started", %{
      "threadId" => "native-child-1",
      "turn" => %{"id" => "native-child-turn-9", "status" => "inProgress"}
    })

    context
  end

  step "that subagent's turn is interrupted at once", context do
    World.await_provider_log(context, "codex", fn entry ->
      get_in(entry, ["in", "method"]) == "turn/interrupt" and
        get_in(entry, ["in", "params", "turnId"]) == "native-child-turn-9"
    end)

    assert await_subagent_status(context, "interrupted")
    context
  end

  step "Codex consolidates its memories in the background during a turn", context do
    context = start_waiting(context)

    World.codex_notify(context, @thread, "thread/started", %{
      "thread" => %{"id" => "memory-1", "threadSource" => "memory_consolidation"}
    })

    World.codex_notify(context, @thread, "item/started", %{
      "threadId" => "memory-1",
      "turnId" => "memory-turn-1",
      "item" => %{"type" => "agentMessage", "id" => "memory-msg", "text" => ""}
    })

    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => "memory-1",
      "turnId" => "memory-turn-1",
      "item" => %{"type" => "agentMessage", "id" => "memory-msg", "text" => "consolidated"}
    })

    {pid, _} = World.codex_runtime(context, @thread)
    :sys.get_state(pid)
    context
  end

  step "the thread shows no subagent for it", context do
    assert StreamState.list(World.stream(context, @thread), "subagent") == []
    context
  end

  step "its activity does not appear in the thread's work log", context do
    refute "consolidated" in World.replies(context, @thread)

    refute Enum.any?(
             StreamState.list(World.stream(context, @thread), "turn-item"),
             &(&1["text"] == "consolidated")
           )

    context
  end

  # --- stopping turns -----------------------------------------------------------------------------------

  step "the user stopped a running Codex turn", context do
    context = World.fake_providers(context)
    World.put_os_env("FAKE_CODEX_IGNORE_INTERRUPT", "1")
    World.put_app_env(:codex_interrupt_deadline_ms, 2_000)
    context = start_waiting(context) |> Map.put(:thread, @thread)
    {_, runtime} = World.codex_runtime(context, @thread)
    context = Map.put(context, :stopped_turn, runtime.turn.native_turn_id)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread),
        "runId" => World.latest_run(context, @thread)["id"]
      })

    World.await_provider_log(
      context,
      "codex",
      &(get_in(&1, ["in", "method"]) == "turn/interrupt")
    )

    context
  end

  step "Codex reports the turn completed before it acknowledges the stop", context do
    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    context
  end

  step "the turn ends as interrupted", context do
    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  # A turn Codex holds before starting: the fake waits for the gate file. The
  # sending dispatch blocks until Codex starts the turn, so it runs in a task,
  # as a second client would; the stop comes from this one meanwhile.
  defp queued_turn(context) do
    context = World.fake_providers(context)
    gate_dir = HalC2.Test.Mc.tmp_dir(context.mc, "gate")
    World.put_os_env("FAKE_CODEX_GATE", gate_dir)
    World.put_os_env("FAKE_CODEX_HOLD_TURN_START", "1")
    id = "th-queued-#{System.unique_integer([:positive])}"

    context =
      context
      |> put_in([:threads, @thread], id)
      |> Map.merge(%{gate_dir: gate_dir, thread: @thread, current_thread: @thread})

    task =
      Task.async(fn ->
        World.launch_on(context, @thread, "codex", "wait for me", %{"threadId" => id})
      end)

    # The turn was sent: Codex has it and has not started it.

    World.await_provider_log(
      context,
      "codex",
      &(get_in(&1, ["in", "method"]) == "turn/start")
    )

    Map.put(context, :send_task, task)
  end

  step "a Codex turn was sent and Codex has not started it yet", context do
    context = queued_turn(context)
    thread_id = World.thread_id(context, @thread)
    gate = Path.join(context.gate_dir, "turn-start")

    # Codex starting the turn, as soon as the stop is queued behind its start.
    Task.start(fn ->
      thread_id |> wait_runtime() |> wait_queued()
      File.write!(gate, "")
    end)

    context
  end

  defp wait_runtime(thread_id) do
    case Registry.lookup(HalC2.Codex.Registry, thread_id) do
      [{pid, _}] ->
        pid

      [] ->
        Process.sleep(10)
        wait_runtime(thread_id)
    end
  end

  defp wait_queued(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} ->
        Process.sleep(10)
        wait_queued(pid)

      _ ->
        :ok
    end
  end

  step "the stop is delivered as soon as Codex starts the turn", context do
    World.await_provider_log(
      context,
      "codex",
      &(get_in(&1, ["in", "method"]) == "turn/interrupt")
    )

    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  step "a Codex turn was sent and Codex does not start it", context do
    context = queued_turn(context)
    World.put_app_env(:codex_interrupt_timeout_ms, 300)
    context
  end

  step "the user stops the turn and 10 seconds pass", context do
    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread),
        "runId" => World.latest_run(context, @thread)["id"]
      })

    # Let the turn start at last, so the scenario leaves nothing wedged behind it.
    File.write!(Path.join(context.gate_dir, "turn-start"), "")
    Map.put(context, :reply, reply)
  end

  step "the stop fails with {string}", %{args: [message]} = context do
    assert {:error, ^message} = context.reply
    context
  end

  step "Codex has not ended the turn after 10 seconds", context do
    # The deadline the MC settles a stopped turn by, shortened for the scenario
    # in its Given; nothing arrives from Codex meanwhile.
    context
  end

  step "what Codex sends for that turn afterwards is not added to the thread", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    turn_id = context.stopped_turn

    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => runtime.native_thread_id || "native-thread-1",
      "turnId" => turn_id,
      "item" => %{"type" => "agentMessage", "id" => "late-msg", "text" => "too late"}
    })

    {pid, _} = World.codex_runtime(context, @thread)
    :sys.get_state(pid)
    refute "too late" in World.replies(context, @thread)
    context
  end

  # --- persistent tools, repeated answers -----------------------------------------------------------------

  step "Codex started a tool call marked persistent and another that is not", context do
    context = start_waiting(context)

    for {id, persistent} <- [{"tool-stays", true}, {"tool-goes", false}] do
      notify_item(context, "started", %{
        "type" => "dynamicToolCall",
        "id" => id,
        "tool" => "watch",
        "arguments" => %{"persistent" => persistent},
        "status" => "inProgress"
      })
    end

    await_item(context, &(&1["type"] == "dynamic_tool"))
    context
  end

  step "the turn completes with both still open", context do
    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  defp tool_status(context, native) do
    item =
      Enum.find(
        StreamState.list(World.stream(context, @thread), "turn-item"),
        &(&1["nativeItemRef"]["nativeId"] == native)
      )

    item && item["status"]
  end

  step "the other tool call is closed with the turn", context do
    assert tool_status(context, "tool-goes") == "completed"
    context
  end

  step "the persistent tool call stays running", context do
    assert tool_status(context, "tool-stays") == "running"
    context
  end

  defp final_answers(context, texts, phase \\ "final_answer") do
    context = start_waiting(context)

    for {text, i} <- Enum.with_index(texts, 1) do
      item = %{"type" => "agentMessage", "id" => "final-#{i}", "text" => ""}
      item = if phase, do: Map.put(item, "phase", phase), else: item

      notify_item(context, "started", item)
      notify_item(context, "completed", %{item | "text" => text})
    end

    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "Codex sends the same final answer twice in one turn", context do
    final_answers(context, ["All done.", "All done."])
  end

  step "the thread shows that answer once", context do
    assert World.replies(context, @thread) == ["All done."]
    context
  end

  step "Codex sends a final answer and then an empty one in the same turn", context do
    final_answers(context, ["All done.", ""])
  end

  step "the thread shows the first answer only", context do
    assert World.replies(context, @thread) == ["All done."]
    context
  end

  step "Codex sends two messages without a phase with the same text in one turn", context do
    final_answers(context, ["All done.", "All done."], nil)
  end

  step "the thread shows both messages", context do
    assert World.replies(context, @thread) == ["All done.", "All done."]
    context
  end

  # --- usage-limit resets learned late ----------------------------------------------------------------------

  # A turn that stops on the weekly limit, with the snapshot the scenario gives it.
  defp usage_stop(context, snapshot) do
    context = start_waiting(context)
    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "account/rateLimits/updated", %{"rateLimits" => snapshot})

    codex_error(
      context,
      %{"message" => "You've hit your usage limit.", "codexErrorInfo" => "usageLimitExceeded"},
      false
    )

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{
        "id" => runtime.turn.native_turn_id,
        "status" => "failed",
        "error" => %{"message" => "You've hit your usage limit."}
      }
    })

    World.await_runs(context, @thread, ["failed"])
    context
  end

  defp weekly_snapshot(resets_at) do
    primary = %{"usedPercent" => 40, "windowDurationMins" => 300}
    secondary = %{"usedPercent" => 100, "windowDurationMins" => 10_080}
    secondary = if resets_at, do: Map.put(secondary, "resetsAt", resets_at), else: secondary
    %{"limitId" => "codex", "primary" => primary, "secondary" => secondary}
  end

  defp failure_of(context) do
    World.await_value(context, @thread, fn state ->
      Enum.find(StreamState.list(state, "turn-item"), &(&1["type"] == "error" and &1["failure"]))
    end)["failure"]
  end

  step "a Codex turn stopped on a usage limit before Codex said when the limit resets", context do
    context = usage_stop(context, weekly_snapshot(nil))
    assert failure_of(context)["resetAt"] == nil
    context
  end

  step "Codex then reports its usage windows", context do
    reset = DateTime.utc_now() |> DateTime.add(2 * 3600, :second) |> DateTime.to_unix()

    World.codex_notify(context, @thread, "account/rateLimits/updated", %{
      "rateLimits" => weekly_snapshot(reset)
    })

    Map.put(context, :reset_unix, reset)
  end

  step "the stopped turn shows the reset time from those windows", context do
    failure =
      World.await_value(context, @thread, fn state ->
        Enum.find(
          StreamState.list(state, "turn-item"),
          &(&1["type"] == "error" and get_in(&1, ["failure", "resetAt"]) != nil)
        )
      end)["failure"]

    {:ok, reset, _} = DateTime.from_iso8601(failure["resetAt"])
    assert DateTime.to_unix(reset) == context.reset_unix
    assert failure["message"] =~ "weekly limit resets in"
    context
  end

  step "a Codex turn stopped on a usage limit that resets at 14:00", context do
    reset =
      DateTime.utc_now()
      |> Map.merge(%{hour: 14, minute: 0, second: 0, microsecond: {0, 0}})
      |> then(fn at ->
        if DateTime.compare(at, DateTime.utc_now()) == :lt,
          do: DateTime.add(at, 1, :day),
          else: at
      end)

    context = usage_stop(context, weekly_snapshot(DateTime.to_unix(reset)))
    Map.put(context, :reset_iso, DateTime.to_iso8601(reset))
  end

  step "Codex later reports usage windows with another reset time", context do
    later = DateTime.utc_now() |> DateTime.add(9 * 3600, :second) |> DateTime.to_unix()

    World.codex_notify(context, @thread, "account/rateLimits/updated", %{
      "rateLimits" => weekly_snapshot(later)
    })

    {pid, _} = World.codex_runtime(context, @thread)
    :sys.get_state(pid)
    context
  end

  step "the stopped turn still says it resets at 14:00", context do
    {:ok, reset, _} = DateTime.from_iso8601(failure_of(context)["resetAt"])
    {:ok, expected, _} = DateTime.from_iso8601(context.reset_iso)
    assert DateTime.to_unix(reset) == DateTime.to_unix(expected)
    context
  end

  # --- the wire ------------------------------------------------------------------------------------------------

  step "Codex sends a request with a method HAL-C2 does not handle", context do
    context = start_waiting(context)
    {pid, runtime} = World.codex_runtime(context, @thread)

    send(
      pid,
      {:json_rpc, runtime.conn, {:request, "mystery-1", "mystery/method", ctx_params(context)}}
    )

    Map.put(context, :elicitation_id, "mystery-1")
  end

  step "Codex receives error -32601 {string} followed by the method",
       %{args: [prefix]} = context do
    answer = codex_answer(context, "mystery-1")
    assert get_in(answer, ["error", "code"]) == -32601
    assert get_in(answer, ["error", "message"]) == "#{prefix} mystery/method"
    context
  end

  step "32 requests from Codex are waiting on the user", context do
    context = start_waiting(context)
    {pid, runtime} = World.codex_runtime(context, @thread)

    for i <- 1..32 do
      send(
        pid,
        {:json_rpc, runtime.conn,
         {:request, "approval-#{i}", "item/commandExecution/requestApproval",
          Map.merge(ctx_params(context), %{"itemId" => "cmd-#{i}", "command" => "touch #{i}"})}}
      )
    end

    World.await_value(context, @thread, fn state ->
      if length(StreamState.list(state, "runtime-request")) == 32, do: true
    end)

    context
  end

  step "Codex sends another request", context do
    {pid, runtime} = World.codex_runtime(context, @thread)

    send(
      pid,
      {:json_rpc, runtime.conn,
       {:request, "approval-33", "item/commandExecution/requestApproval",
        Map.merge(ctx_params(context), %{"itemId" => "cmd-33", "command" => "touch 33"})}}
    )

    context
  end

  step "Codex receives error -32001 {string}", %{args: [message]} = context do
    answer = codex_answer(context, "approval-33")
    assert get_in(answer, ["error", "code"]) == -32001
    assert get_in(answer, ["error", "message"]) == message
    context
  end

  step "the 32 waiting requests are unaffected", context do
    requests = StreamState.list(World.stream(context, @thread), "runtime-request")
    assert length(requests) == 32
    assert Enum.all?(requests, &(&1["status"] == "pending"))
    context
  end

  step "Codex sends a notification in a shape HAL-C2 does not know", context do
    World.codex_notify(context, @thread, "item/completed", %{"unexpected" => true})
    World.codex_notify(context, @thread, "some/newNotification", %{"what" => "ever"})
    context
  end

  step "the notification is skipped", context do
    {pid, _} = World.codex_runtime(context, @thread)
    :sys.get_state(pid)
    assert Process.alive?(pid)
    context
  end

  step "the turn goes on with the messages that follow", context do
    notify_item(context, "started", %{"type" => "agentMessage", "id" => "after-1", "text" => ""})

    notify_item(context, "completed", %{
      "type" => "agentMessage",
      "id" => "after-1",
      "text" => "still here"
    })

    {_, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
    })

    World.await_runs(context, @thread, ["completed"])
    assert "still here" in World.replies(context, @thread)
    context
  end

  @framings %{
    "with one message split across two reads" => "split",
    "with several messages in one read" => "batch",
    "with Windows line endings" => "crlf",
    "with blank lines between messages" => "blank"
  }

  step ~r/^Codex's output arrives (?<how>with one message split across two reads|with several messages in one read|with Windows line endings|with blank lines between messages)$/,
       %{args: [how]} = context do
    context = World.fake_providers(context)
    World.put_os_env("FAKE_CODEX_FRAMING", @framings[how])
    context = World.launch_on(context, @thread, "codex", "hello")
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "each message is read once and complete", context do
    assert World.replies(context, @thread) == ["Hello from codex"]

    outputs =
      for item <- StreamState.list(World.stream(context, @thread), "turn-item"),
          item["type"] == "command_execution",
          do: item["output"]

    assert outputs == ["a.txt\n"]
    context
  end

  step "Codex writes more to its error output than the system buffers", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    HalC2.JsonRpc.Connection.notify(runtime.conn, "test/flood", nil)
    context
  end

  step "Codex keeps running and the turn goes on", context do
    context =
      World.post_message(context, @thread, "one more thing", %{
        "dispatchMode" => %{"type" => "steer_active"}
      })

    World.await_runs(context, @thread, ["completed"])
    assert "steered: one more thing" in World.replies(context, @thread)
    context
  end

  step "the MC is waiting on Codex for an answer", context do
    context = start_waiting(context)
    {_, runtime} = World.codex_runtime(context, @thread)

    task =
      Task.async(fn -> HalC2.JsonRpc.Connection.call(runtime.conn, "test/hang", %{}, 30_000) end)

    Map.put(context, :pending_call, task)
  end

  step "Codex exits with code 1", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    HalC2.JsonRpc.Connection.notify(runtime.conn, "test/exit", nil)
    assert {:error, %{"message" => message}} = Task.await(context.pending_call, 10_000)
    Map.put(context, :error_frame, %{"t" => "error", "reason" => message})
  end

  step "Codex writes a line to its output that is not a protocol message", context do
    {_, runtime} = World.codex_runtime(context, @thread)
    HalC2.JsonRpc.Connection.notify(runtime.conn, "test/garbage", nil)
    context
  end

  step "the connection to Codex is closed", context do
    World.await_value(context, @thread, fn _state ->
      {_pid, runtime} = World.codex_runtime(context, @thread)
      runtime.conn == nil
    end)

    context
  end

  step "the turn fails instead of waiting on Codex", context do
    World.await_runs(context, @thread, ["failed"])
    context
  end

  # --- skills, manifest, Windows --------------------------------------------------------------------------------------

  step "Codex does not answer when asked for the project's skills", context do
    context = World.fake_providers(context)
    HalC2.Codex.Provider.load()
    World.put_os_env("FAKE_CODEX_SKILLS_HANG", "1")
    # The read's 20-second bound, shortened; "{int} seconds pass" runs the read.
    World.put_app_env(:codex_skills_timeout_ms, 300)
    Map.put(context, :codex_skills_read, World.project(context).root)
  end

  step "reading the skills fails naming the project folder", context do
    assert {:error, %{"message" => message}} = context.reply
    assert message == "Failed to probe Codex skills for '#{context.skills_cwd}'"
    context
  end

  step "the provider's status is not held up by it", context do
    {providers, context} = World.provider_list(context)
    assert codex(providers)["status"] == "ready"
    context
  end

  step "the model manifest cannot be fetched", context do
    context = World.fake_providers(context)
    World.put_app_env(:model_manifest_url, Path.join(context.mc.home, "no-manifest.json"))
    HalC2.ModelManifest.refresh()
    context
  end

  step "Codex's status is reported from the manifest the MC already has", context do
    entry = codex(context.providers)
    assert entry["status"] == "ready"
    assert entry["compatibilityAdvisory"]["status"] == "unknown"
    context
  end

  step "the codex command is a command script rather than a program", context do
    context = World.fake_providers(context)
    # A `cmd.exe` the wrapped command can run through on this machine.
    shim = Path.join(context.fakes.bin, "cmd.exe")
    File.write!(shim, "#!/bin/sh\nshift\nexec \"$@\"\n")
    File.chmod!(shim, 0o755)
    World.put_os_env("PATH", "#{context.fakes.bin}:#{System.get_env("PATH")}")
    fake = Path.join(File.cwd!(), "test/support/fake_codex.py")
    cmd = Path.join(context.fakes.bin, "codex.cmd")

    File.write!(
      cmd,
      "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"codex-cli 0.50.0\"; exit 0; fi\nexec python3 -u #{fake} \"$@\"\n"
    )

    File.chmod!(cmd, 0o755)
    World.put_app_env(:codex_command, [cmd])
    World.reset_provider_caches()
    context
  end

  step "Codex starts and answers as it does from a program", context do
    World.await_runs(context, @thread, ["completed"])
    assert "Hello from codex" in World.replies(context, @thread)
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp codex(providers), do: Enum.find(providers, &(&1["instanceId"] == "codex"))

  defp slug(name), do: name |> String.downcase() |> String.replace(" ", "-")

  defp respond(context, decision) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, World.current_thread(context)),
        "requestId" => context.request["id"],
        "decision" => decision
      })
  end

  # What the fake was told for its approval request.
  defp codex_decision(context) do
    reply =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "id"]) == "approval-1"))

    get_in(reply, ["in", "result", "decision"])
  end

  defp command_status(context) do
    items = StreamState.list(World.stream(context, @thread), "turn-item")
    Enum.find_value(items, &(&1["type"] == "command_execution" && &1["status"]))
  end

  defp feedback(context, reason) do
    {reply, context} =
      World.call(context, "provider.uploadFeedback", %{
        "threadId" => World.thread_id(context, World.current_thread(context)),
        "reason" => reason
      })

    Map.put(context, :reply, reply)
  end
end
