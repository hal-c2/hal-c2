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

  step "the user answers it", context do
    answer_async(context)
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

    assert [%{"appName" => ^app, "options" => options}] =
             World.entities(context, @thread, "turn-item")
             |> Enum.filter(&(&1["requestId"] == request["id"]))

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
    context = World.launch_on(context, @thread, "codex", "hello")
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
    context = World.launch_on(context, @thread, "codex", "hello")
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

  step "a Codex thread with three turns", context do
    context
    |> World.fake_providers()
    |> World.run_turns(@thread, "codex", ["hello", "hello again", "one more"])
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
