defmodule HalC2.Steps.Providers.AntigravityFixture do
  @moduledoc """
  An Antigravity instance for scenarios outside `antigravity.feature`: the scripted
  agent (`HalC2.Test.FakeAcp`) as a runtime the user installed by hand, so its binary
  path with the helper beside it, signed in with a Google account. Nothing is
  downloaded and nothing reaches Google.
  """

  alias HalC2.Acp.Antigravity
  alias HalC2.Test.{FakeAcp, Mc}
  alias HalC2.Test.Mc.World

  @instance "antigravity"
  @models [
    %{
      "id" => "model",
      "name" => "Model",
      "type" => "select",
      "currentValue" => "fake/one",
      "options" => [%{"value" => "fake/one", "name" => "Fake/One"}]
    }
  ]

  @doc "Installs the instance with `turns` as its scripted turns; `context.provider` names it."
  def install(context, turns \\ FakeAcp.turns()) do
    agent = %{
      "agentName" => "antigravity-acp",
      "version" => "agy_acp_server_1.1.1",
      "capabilities" => %{"auth" => %{"logout" => %{}}},
      "authMethods" => [%{"id" => "oauth-personal", "name" => "Google account"}],
      "googleAuth" => true,
      "turns" => turns
    }

    # Codex and Claude on this machine stay out of the scenario.
    for key <- [:codex_command, :claude_command],
        do: World.put_app_env(key, ["hal-c2-test-not-installed"])

    World.put_app_env(:antigravity_platform, {"linux", "x64"})

    context =
      FakeAcp.install(context, @instance, agent, binary: "agy_acp_server.par", enabled: true)

    harness =
      Path.join(Path.dirname(FakeAcp.fake(context, @instance).bin), "localharness_external")

    File.write!(harness, "#!/bin/sh\nexit 0\n")
    File.chmod!(harness, 0o755)

    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.ProviderAuth.Registry},
        id: :provider_auth_registry
      )
    )

    Mc.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: HalC2.ProviderAuth.Supervisor, strategy: :one_for_one},
        id: :provider_auth_supervisor
      )
    )

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({HalC2.Acp, @instance, :workspaces})
    end)

    # A saved Google login and the account its session showed.
    token = Antigravity.token_path(@instance)
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, JSON.encode!(%{"account" => "user@example.com"}))
    Antigravity.put_account(@instance, HalC2.Acp.session_models(%{"configOptions" => @models}))
    context
  end
end

defmodule HalC2.Steps.Providers.CapabilitiesControls do
  @moduledoc """
  More steps for `features/providers/capabilities.feature`: what a provider's entry
  and session tell a client to offer, steering a provider that cannot be steered,
  proposed plans, and an ACP agent's own child sessions. Grok and Antigravity are
  the scripted agent of `HalC2.Test.FakeAcp` where a scenario scripts their turn.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Providers.AntigravityFixture
  alias HalC2.StreamState
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc.World

  @thread "Work"
  @instances %{
    "Codex" => "codex",
    "Claude" => "claudeAgent",
    "Grok" => "grok",
    "OpenCode" => "opencode",
    "Cursor" => "cursor"
  }

  # --- controls a provider does not support ----------------------------------------------

  # A thread that has run a turn, so its provider session says what it can do.
  step ~r/^an? (?<provider>Codex|Claude|Grok|OpenCode|Cursor) thread$/,
       %{args: [provider]} = context do
    instance = @instances[provider]
    context = World.fake_providers(context)

    if instance not in ["codex", "claudeAgent"],
      do: World.merge_settings(%{"providers" => %{instance => %{"enabled" => true}}})

    context
    |> World.run_turns(@thread, instance, ["hello"])
    |> Map.put(:instance, instance)
  end

  step "a Antigravity thread", context do
    context =
      context
      |> AntigravityFixture.install()
      |> FakeAcp.thread(@thread)
      |> FakeAcp.send_message("hello")

    FakeAcp.await_runs(context, 1)
    Map.merge(context, %{instance: "antigravity", current_thread: @thread})
  end

  # What the composer reads: the provider's entry, and the session of the thread's
  # last turn when it has run one.
  step "the user looks at the composer", context do
    {providers, context} = World.provider_list(context)
    entry = Enum.find(providers, &(&1["instanceId"] == context.instance))
    assert entry, "#{context.instance} is not listed"

    session =
      if context.threads[@thread],
        do:
          context |> World.stream(@thread) |> StreamState.list("provider-session") |> List.last()

    Map.put(context, :composer, %{entry: entry, session: session})
  end

  step "the plan/build toggle is not offered", context do
    assert %{"showInteractionModeToggle" => false} = context.composer.entry
    context
  end

  # Clients offer a fork from a turn when the thread's session can fork natively.
  step "forking the thread is not offered", context do
    assert %{"driver" => driver, "capabilities" => %{"threads" => threads}} =
             context.composer.session

    assert driver == context.instance
    assert %{"canForkThread" => false, "canForkFromTurn" => false} = threads
    context
  end

  step "rewinding the thread is not offered", context do
    assert %{"supportsConversationRollback" => false} = context.composer.entry
    context
  end

  # --- steering a provider that cannot be steered ---------------------------------------

  step "a Antigravity thread with a running turn", context do
    context =
      context
      |> AntigravityFixture.install()
      |> FakeAcp.thread(@thread)
      |> FakeAcp.send_message("a long task")

    FakeAcp.await_run(context, "running")
    Map.merge(context, %{instance: "antigravity", current_thread: @thread})
  end

  step "the user sends a follow-up and asks to steer", context do
    World.post_message(context, World.current_thread(context), "one more thing", %{
      "dispatchMode" => nil,
      "deliveryIntent" => "steer"
    })
  end

  step "the running turn is interrupted and restarted with the message", context do
    title = World.current_thread(context)
    World.await_runs(context, title, ["interrupted", "completed"])
    [_first, restarted] = World.runs(context, title)
    state = World.stream(context, title)

    assert %{"text" => "one more thing"} =
             StreamState.get(state, "message")[restarted["userMessageId"]]

    # The agent was told to stop, then given the message as a new prompt.
    {cancels, prompts} =
      if context[:instance] == "antigravity" do
        {FakeAcp.received(context, "session/cancel"),
         for(m <- FakeAcp.received(context, "session/prompt"), do: m["params"]["prompt"])}
      else
        log = World.provider_log(context, "acp")

        {Enum.filter(log, &(get_in(&1, ["in", "method"]) == "session/cancel")),
         for(
           %{"in" => %{"method" => "session/prompt", "params" => params}} <- log,
           do: params["prompt"]
         )}
      end

    assert [_ | _] = cancels
    assert [_, _] = prompts
    assert prompts |> List.last() |> Enum.map_join(& &1["text"]) =~ "one more thing"
    context
  end

  # --- proposed plans -------------------------------------------------------------------

  @plan "# Plan\n\n1. Add the form"

  # Grok hands its plan over with `x.ai/exit_plan_mode` and waits for an answer.
  step "a Grok thread in plan mode", context do
    plan = %{
      "match" => "plan the work",
      "steps" => [
        %{
          "request" => %{
            "method" => "x.ai/exit_plan_mode",
            "params" => %{"toolCallId" => "plan-1", "planContent" => @plan}
          }
        }
      ]
    }

    context
    |> FakeAcp.install("grok", %{"turns" => [plan | FakeAcp.turns()]}, enabled: true)
    |> FakeAcp.thread(@thread, "approval-required", %{"interactionMode" => "plan"})
    |> Map.put(:current_thread, @thread)
  end

  step "the provider finishes a plan", context do
    context = FakeAcp.send_message(context, "plan the work")
    FakeAcp.await_run(context, "completed")
    context
  end

  # The plan waits for the user (`active`) with the turn over: sending feedback
  # refines it, and implementing it marks it done.
  step "the plan is shown for the user to accept or refine", context do
    assert [%{"kind" => "proposed_plan", "status" => "active", "markdown" => @plan} = plan] =
             StreamState.list(World.stream(context, @thread), "plan")

    assert [%{"status" => "completed"}] = World.runs(context, @thread)
    assert World.thread(context, @thread)["interactionMode"] == "plan"

    context =
      World.post_message(context, @thread, "Go ahead.", %{
        "sourcePlanRef" => %{
          "threadId" => World.thread_id(context, @thread),
          "planId" => plan["id"]
        },
        "dispatchMode" => nil
      })

    World.await_value(context, @thread, fn state ->
      StreamState.get(state, "plan")[plan["id"]]["status"] == "completed"
    end)

    context
  end

  # --- an ACP agent's own child session ---------------------------------------------------

  @child "0f8e2a4c-5b6d-4e7f-8a9b-1c2d3e4f5a6b"
  @task "List the modules in lib"

  # Grok's `task` tool: the child works in a session of its own, whose updates carry
  # that session's id, and the tool call ends with the child's result.
  step "an ACP agent starts a native child session", context do
    call = %{
      "toolCallId" => "task-1",
      "title" => "task",
      "kind" => "other",
      "status" => "in_progress",
      "rawInput" => %{
        "description" => "Survey the modules",
        "prompt" => @task,
        "subagent_type" => "general-purpose"
      }
    }

    said = fn text ->
      %{
        "sessionId" => @child,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    end

    result = %{
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "task-1",
        "status" => "completed",
        "content" => [
          %{
            "type" => "content",
            "content" => %{
              "type" => "text",
              "text" => "Agent ID: #{@child}\nlib has three modules"
            }
          }
        ]
      }
    }

    turn = %{
      "match" => "survey the code",
      "steps" => [
        %{"update" => Map.put(call, "sessionUpdate", "tool_call")},
        said.("Reading lib/a.ex. "),
        said.("Summary: lib has three modules"),
        result,
        %{"text" => "The survey is done."}
      ]
    }

    context
    |> FakeAcp.install("grok", %{"turns" => [turn | FakeAcp.turns()]}, enabled: true)
    |> FakeAcp.thread(@thread)
    |> Map.put(:current_thread, @thread)
  end

  step "the child sends messages and a final summary", context do
    context = FakeAcp.send_message(context, "survey the code")
    state = FakeAcp.await_run(context, "completed")
    assert [%{"status" => "completed"} = subagent] = StreamState.list(state, "subagent")
    Map.put(context, :subagent, subagent)
  end

  step "they appear in the child's thread", context do
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(context.subagent["childThreadId"]))
    messages = for m <- StreamState.list(child, "message"), do: {m["role"], m["text"]}

    assert {"user", @task} in messages

    assert [{"assistant", "Reading lib/a.ex. Summary: lib has three modules"}] =
             Enum.filter(messages, &(elem(&1, 0) == "assistant"))

    # The child is a subagent thread of the parent, not a thread of its own in the list.
    thread = StreamState.get(child, "thread")[context.subagent["childThreadId"]]
    assert thread["lineage"]["parentThreadId"] == World.thread_id(context, @thread)
    context
  end

  step "the parent receives only the child's result", context do
    state = World.stream(context, @thread)
    assert context.subagent["result"] == "lib has three modules"

    assert [%{"result" => "lib has three modules", "childThreadId" => child}] =
             for(i <- StreamState.list(state, "turn-item"), i["type"] == "subagent", do: i)

    assert child == context.subagent["childThreadId"]

    said = for m <- StreamState.list(state, "message"), m["role"] == "assistant", do: m["text"]
    assert said == ["The survey is done."]
    refute Enum.any?(said, &(&1 =~ "Reading lib/a.ex"))
    context
  end
end
