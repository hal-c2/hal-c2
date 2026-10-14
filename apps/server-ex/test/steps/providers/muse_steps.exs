defmodule HalC2.Steps.Providers.Muse do
  @moduledoc """
  Steps for `features/providers/muse.feature`. The MC runs Muse Code over the Muse
  Session Protocol (`HalC2.Muse`, `HalC2.Muse.ThreadRuntime`); the scripted fake
  host (`fake_muse_msp.py`, through `HalC2.Test.FakeAcp.install_muse/3`) is the
  user's `muse`, sessions and all.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @turns [
    %{"match" => "run a command", "steps" => [%{"shell" => "npm test"}, %{"text" => "Ran it."}]},
    %{
      "match" => "run a guarded command",
      "steps" => [%{"shell" => "npm test", "requirements" => 2}, %{"text" => "Ran it."}]
    },
    %{
      "match" => "edit a file",
      "steps" => [%{"edit" => "src/app.ts"}, %{"text" => "Edited it."}]
    },
    %{
      "match" => "a guarded workflow command",
      "steps" => [
        %{"childShell" => "make", "approvable" => true, "requirements" => 2},
        %{"text" => "Done."}
      ]
    },
    %{
      "match" => "plan the work",
      "steps" => [
        %{
          "todos" => [
            %{"text" => "Read", "status" => "completed"},
            %{"text" => "Dropped", "status" => "cancelled"},
            %{"text" => "Write", "status" => "inProgress"}
          ]
        },
        %{"text" => "Planned."}
      ]
    },
    %{
      "match" => "a workflow command",
      "steps" => [%{"childShell" => "rm -rf build"}, %{"text" => "Done."}]
    },
    %{
      "match" => "count the context",
      "steps" => [
        %{"text" => "Counted."},
        %{"usage" => %{"inputTokens" => 900, "outputTokens" => 300, "reasoningTokens" => 120}},
        %{"contextAfter" => %{"usedTokens" => 1234, "windowTokens" => 200_000}}
      ]
    },
    %{
      "match" => "count it late",
      "steps" => [
        %{"text" => "Counted."},
        %{"contextAfter" => %{"usedTokens" => 4321, "windowTokens" => 200_000}, "late" => true}
      ]
    },
    %{
      "match" => "a long task",
      "steps" => [%{"text" => "Working on it."}, %{"waitInterrupt" => true}]
    },
    %{
      "match" => "pick a color",
      "steps" => [
        %{
          "question" => %{
            "header" => "Color",
            "question" => "Pick a color",
            "options" => ~w(red green blue)
          }
        }
      ]
    }
  ]

  # HAL-C2's MCP server is up, so a thread's session is offered its tools.
  defp install(context, config \\ %{}, opts \\ []) do
    Mc.ensure(HalC2.Mcp)
    FakeAcp.install_muse(context, config, Keyword.merge([enabled: true, turns: @turns], opts))
  end

  defp muse(context), do: FakeAcp.find(context.providers, "muse")

  # The hosts that served the thread: `muse serve` in the project, not the read-only
  # ones that read the catalog.
  defp thread_starts(context) do
    cwd = World.project(context).root

    Enum.filter(
      FakeAcp.starts(context),
      &(&1["cwd"] == cwd and "serve" in &1["argv"] and "--disable-write" not in &1["argv"])
    )
  end

  defp state(context, title \\ nil) do
    id = World.thread_id(context, title || context.thread)
    HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
  end

  defp replies(context, title \\ nil) do
    for m <-
          context
          |> state(title)
          |> StreamState.list("message")
          |> Enum.sort_by(& &1["createdAt"]),
        m["role"] == "assistant",
        do: m["text"]
  end

  # Sends `text` and waits for its (new) run to finish as `status`.
  defp turn(context, text, status \\ "completed", title \\ nil) do
    before = for run <- StreamState.list(state(context, title), "run"), do: run["id"]
    context = FakeAcp.send_message(context, text, title)

    run =
      World.await_stream(World.thread_id(context, title || context.thread), fn state ->
        Enum.find(
          StreamState.list(state, "run"),
          &(&1["id"] not in before and &1["status"] in ~w(completed failed interrupted))
        )
      end)

    assert run["status"] == status, "run ended #{run["status"]}: #{inspect(run)}"
    context
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  defp session_id(context) do
    state = state(context)
    thread = StreamState.get(state, "thread")[World.thread_id(context, context.thread)]
    provider_thread = StreamState.get(state, "provider-thread")[thread["activeProviderThreadId"]]
    get_in(provider_thread, ["nativeThreadRef", "nativeId"])
  end

  defp received(context, method), do: for(m <- FakeAcp.received(context, method), do: m["params"])

  defp items(context, type),
    do: context |> state() |> StreamState.list("turn-item") |> Enum.filter(&(&1["type"] == type))

  # --- enabling and status ---

  step "Muse Code is installed but not enabled", context do
    install(context, %{}, enabled: false)
  end

  step "no Muse Code process is started", context do
    HalC2.Acp.load()
    assert %{"enabled" => false} = FakeAcp.entry("muse")
    assert FakeAcp.starts(context, "muse") == []
    context
  end

  step "the muse command is not installed on the MC", context do
    FakeAcp.services()
    HalC2.Acp.forget("muse")
    missing = Path.join(Mc.tmp_dir(context.mc, "no-muse"), "muse")
    FakeAcp.settings(&put_in(&1, ["providers"], %{"muse" => %{"binaryPath" => missing}}))
    Map.put(context, :provider, "muse")
  end

  step "Muse Code is not offered", context do
    assert context.providers != nil
    assert FakeAcp.find(context.providers, "muse") == nil
    context
  end

  step "the user enables Muse Code", context do
    {_, context} = FakeAcp.open_config(context)
    FakeAcp.enable(context, "muse")
  end

  step "Muse Code is listed as not installed, saying it was not found", context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        &match?(%{"enabled" => true, "message" => _}, FakeAcp.find(&1, "muse"))
      )

    assert %{"installed" => false, "status" => "error", "message" => message} =
             FakeAcp.find(providers, "muse")

    assert message =~ "not found"
    context
  end

  step "Muse Code is installed but its version check fails", context do
    install(context, %{"versionExit" => 2}, enabled: false)
  end

  step "Muse Code is installed but exits while listing its models", context do
    install(context, %{"modelListExit" => true}, enabled: false)
  end

  step "Muse Code is listed as unavailable, saying it could not list its models", context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        &match?(%{"enabled" => true, "message" => _}, FakeAcp.find(&1, "muse"))
      )

    assert %{"status" => "error", "message" => message} = FakeAcp.find(providers, "muse")
    assert message =~ "could not list its models"
    context
  end

  step "Muse Code is listed as unavailable, saying it could not be run", context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        &match?(%{"enabled" => true, "message" => _}, FakeAcp.find(&1, "muse"))
      )

    assert %{"status" => "error", "message" => message} = FakeAcp.find(providers, "muse")
    assert message =~ "could not be run"
    context
  end

  step "Muse Code is listed with the models from Muse's catalog", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"enabled" => true, "models" => [_ | _]}, FakeAcp.find(providers, "muse"))
      end)

    muse = FakeAcp.find(providers, "muse")
    assert [%{"slug" => "fake/one", "name" => "Fake One"}] = muse["models"]

    # The catalog came from a host that can neither run commands nor write.
    assert [%{"argv" => argv} | _] = FakeAcp.starts(context)
    assert ["serve", "--disable-shell", "--disable-write", "--no-session-log"] = argv
    context
  end

  step "Muse Code is installed and enabled", context do
    install(context)
  end

  step "Muse Code's binary path is set to {string}", %{args: [path]} = context do
    install(context, %{}, path: HalC2.Test.Mc.Host.path(context, path))
  end

  step "the user sends a message to Muse Code", context do
    context = if context[:thread], do: context, else: FakeAcp.thread(context)
    turn(context, "hello Muse")
  end

  step "the turn runs on the user's own Muse Code installation", context do
    assert_runs_on(context, FakeAcp.fake(context).bin)
  end

  step "that Muse Code binary runs the turn", context do
    assert_runs_on(context, HalC2.Test.Mc.Host.path(context, "/opt/muse/bin/muse"))
  end

  # That binary served the thread from the project, without updating itself, and Muse
  # got the message as a turn in the session HAL-C2 started.
  defp assert_runs_on(context, bin) do
    assert [%{"argv" => argv, "env" => env}] = thread_starts(context)
    assert env["FAKE_BIN"] == bin
    assert env["MUSE_NO_AUTO_UPDATE"] == "1"
    assert ["serve", "--trust-workspace" | _] = argv
    assert [%{"sessionId" => session}] = received(context, "session/start")

    assert [%{"sessionId" => ^session, "input" => [%{"text" => "hello Muse"}]}] =
             received(context, "turn/start")

    assert replies(context) == ["Reply to hello Muse after []"]
    context
  end

  step "a Muse Code thread with history", context do
    context |> install() |> FakeAcp.thread() |> turn("hello Muse")
  end

  step "the MC restarts and the user sends another message", context do
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    FakeAcp.services()
    turn(context, "hello again")
  end

  # The host the thread's runtime holds dies on its own; the runtime has seen it go
  # once the connection is down and the runtime answered after that.
  step "Muse Code exits and the user sends another message", context do
    [{runtime, _}] =
      Registry.lookup(HalC2.Muse.Registry, World.thread_id(context, context.thread))

    %{conn: conn} = :sys.get_state(runtime)
    ref = Process.monitor(conn)
    [%{"pid" => pid}] = thread_starts(context)
    {_, 0} = System.cmd("kill", ["-9", "#{pid}"])
    assert_receive {:DOWN, ^ref, _, _, _}, 10_000
    assert %{conn: nil} = :sys.get_state(runtime)
    turn(context, "hello again")
  end

  # A new host resumed the session the thread recorded.
  step "Muse Code continues the same session", context do
    assert [_, _] = thread_starts(context)
    assert [%{"sessionId" => session}] = received(context, "session/start")
    assert [%{"sessionId" => ^session}] = received(context, "session/resume")
    assert session_id(context) == session
    assert List.last(replies(context)) == "Reply to hello again after [hello Muse]"
    context
  end

  # A session/resume only goes to a host that does not have the session yet: the
  # thread's first host exits after a turn.
  step ~r/^a Muse Code thread whose host answers (?<method>session\/start|session\/resume|turn\/start) for another id$/,
       %{args: [method]} = context do
    context = context |> install() |> FakeAcp.thread()

    context =
      if method == "session/resume" do
        context = turn(context, "hello Muse")

        [{runtime, _}] =
          Registry.lookup(HalC2.Muse.Registry, World.thread_id(context, context.thread))

        %{conn: conn} = :sys.get_state(runtime)
        ref = Process.monitor(conn)
        [%{"pid" => pid}] = thread_starts(context)
        {_, 0} = System.cmd("kill", ["-9", "#{pid}"])
        assert_receive {:DOWN, ^ref, _, _, _}, 10_000
        assert %{conn: nil} = :sys.get_state(runtime)
        context
      else
        context
      end

    FakeAcp.configure(context, &Map.put(&1, "mismatch", method))
  end

  step "the user sends a message that Muse Code takes under that other id", context do
    turn(context, "out of step", "failed")
  end

  # The run's failure stopped the host it ran on, before anything else reached it.
  step "the turn fails and that Muse Code host is stopped", context do
    %{"pid" => pid} = List.last(thread_starts(context))
    refute alive?(pid)
    context
  end

  step "the next message runs on a new Muse Code host", context do
    before = length(thread_starts(context))
    context = context |> FakeAcp.configure(&Map.delete(&1, "mismatch")) |> turn("back in step")
    assert length(thread_starts(context)) == before + 1
    assert List.last(replies(context)) =~ "back in step"
    context
  end

  step "Muse Code reports no models", context do
    install(context, %{"models" => []})
  end

  step "Muse Code is shown with a warning to run \"muse login\" on the environment", context do
    assert %{"status" => "warning", "message" => message} = muse(context)
    assert message =~ "muse login"
    context
  end

  step "Muse Code is shown as ready without claiming the user is signed in or out", context do
    assert %{"status" => "ready", "auth" => %{"status" => "unknown"}} = muse(context)
    context
  end

  # --- reasoning ---

  step "the Muse Code model reports the reasoning levels low, medium, high and max with high as its default",
       context do
    install(context, %{
      "models" => [
        %{
          "modelId" => "fake/one",
          "providerId" => "meta",
          "displayLabel" => "Fake One",
          "variants" => ~w(low medium high max),
          "defaultReasoningEffort" => "high"
        }
      ]
    })
  end

  step "the Muse Code model does not report its reasoning levels", context do
    install(context)
  end

  step "the user opens the options for the Muse Code model", context do
    FakeAcp.probe("muse")
    {providers, context} = FakeAcp.open_config(context)
    [model] = FakeAcp.find(providers, "muse")["models"]

    assert [%{"id" => "reasoningEffort", "type" => "select", "label" => "Reasoning"} = effort] =
             model["capabilities"]["optionDescriptors"]

    Map.put(context, :effort, effort)
  end

  step "the user adds the custom Muse Code model {string}", %{args: [slug]} = context do
    FakeAcp.settings(&put_in(&1, ["providers", "muse", "customModels"], [slug]))
    Map.put(context, :custom_model, slug)
  end

  step "the user opens the options for the custom Muse Code model", context do
    FakeAcp.probe("muse")
    {providers, context} = FakeAcp.open_config(context)

    model =
      Enum.find(FakeAcp.find(providers, "muse")["models"], &(&1["slug"] == context.custom_model))

    assert [%{"id" => "reasoningEffort"} = effort] = model["capabilities"]["optionDescriptors"]
    Map.put(context, :effort, effort)
  end

  step "low, medium, high and max are offered under \"Reasoning\"", context do
    assert Enum.map(context.effort["options"], & &1["label"]) == ~w(Low Medium High Max)
    context
  end

  step "low, medium, high, extra high and max are offered under \"Reasoning\"", context do
    assert Enum.map(context.effort["options"], & &1["label"]) ==
             ["Low", "Medium", "High", "Extra High", "Max"]

    context
  end

  step "high is marked as the default", context do
    assert [%{"id" => "high"}] = Enum.filter(context.effort["options"], & &1["isDefault"])
    context
  end

  step "a Muse Code thread with reasoning set to max", context do
    context
    |> install()
    |> FakeAcp.thread("Work", "full-access", %{
      "modelSelection" => %{
        "instanceId" => "muse",
        "model" => "fake/one",
        "options" => [%{"id" => "reasoningEffort", "value" => "max"}]
      }
    })
  end

  step "a Muse Code thread with reasoning set to max on a model that offers low, medium and high",
       context do
    context =
      install(context, %{
        "models" => [
          %{
            "modelId" => "fake/one",
            "providerId" => "meta",
            "displayLabel" => "Fake One",
            "variants" => ~w(low medium high),
            "defaultReasoningEffort" => "medium"
          }
        ]
      })

    FakeAcp.probe("muse")

    FakeAcp.thread(context, "Work", "full-access", %{
      "modelSelection" => %{
        "instanceId" => "muse",
        "model" => "fake/one",
        "options" => [%{"id" => "reasoningEffort", "value" => "max"}]
      }
    })
  end

  step "Muse Code runs the turn at the model's own default reasoning", context do
    assert [params] = received(context, "turn/start")
    refute Map.has_key?(params, "reasoningEffort")
    context
  end

  step "Muse Code runs the turn at max reasoning", context do
    assert [%{"reasoningEffort" => "max"}] = received(context, "turn/start")
    context
  end

  # --- access modes ---

  step "the user opens the permission mode choices in a Muse Code thread", context do
    context = context |> install() |> FakeAcp.thread("Work", "approval-required")
    {_, context} = FakeAcp.open_config(context)
    Map.put(context, :permission_modes, muse(context)["supportedRuntimeModes"])
  end

  step "supervised and full access are offered", context do
    assert context.permission_modes == ~w(approval-required full-access)
    context
  end

  step "auto-accept edits and auto are not offered", context do
    refute "auto-accept-edits" in context.permission_modes
    refute "auto" in context.permission_modes
    context
  end

  step ~r/^the thread runs Muse Code in (?<mode>supervised|full access)$/,
       %{args: [mode]} = context do
    mode = if mode == "supervised", do: "approval-required", else: "full-access"
    context |> install() |> FakeAcp.thread("Work", mode) |> Map.put(:mode, mode)
  end

  step "a Muse Code workflow asks to run a command it offers no way to approve", context do
    FakeAcp.send_message(context, "please run a workflow command")
  end

  step "a Muse Code workflow asks twice to run a command it can be approved for", context do
    FakeAcp.send_message(context, "please run a guarded workflow command")
  end

  step "both approvals are given without asking the user", context do
    FakeAcp.await_run(context, "completed")

    assert [%{"requirementId" => "req-1"}, %{"requirementId" => "req-2"}] =
             received(context, "approval/decide")

    assert context |> state() |> StreamState.list("runtime-request") == []
    assert List.last(replies(context)) == "Done."
    context
  end

  step "Muse Code shares a plan with a step it cancelled", context do
    context |> install() |> FakeAcp.thread() |> turn("plan the work")
  end

  step "the plan leaves the cancelled step out", context do
    assert [%{"steps" => steps}] = context |> state() |> StreamState.list("plan")

    assert [
             %{"text" => "Read", "status" => "completed"},
             %{"text" => "Write", "status" => "running"}
           ] = steps

    context
  end

  step "the request is shown to the user", context do
    assert %{"status" => "pending", "kind" => "command"} =
             request = FakeAcp.await_request(context)

    assert received(context, "approval/decide") == []
    FakeAcp.respond(context, request["id"], %{"decision" => "decline"})
    FakeAcp.await_run(context, "completed")
    assert [%{"choiceId" => "reject"}] = received(context, "approval/decide")
    context
  end

  step "Muse Code reports its context usage after the turn has ended", context do
    context |> FakeAcp.thread() |> turn("count the context")
  end

  # The usage arrives after the run ended, so it is waited for, not read once.
  # The meter reads the provider thread; the turn keeps its own record, with the turn's
  # reasoning share of its output.
  step "the turn's context usage is shown", context do
    usage? = &match?(%{"usedTokens" => 1234, "maxTokens" => 200_000}, &1)

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "provider-thread"), &usage?.(&1["contextUsage"])) and
        Enum.any?(
          StreamState.list(state, "provider-turn"),
          &(usage?.(&1["tokenUsage"]) and &1["tokenUsage"]["reasoningOutputTokens"] == 120)
        )
    end)

    context
  end

  step "Muse Code reports a turn's context usage as the next turn starts", context do
    context |> FakeAcp.thread() |> turn("count it late") |> turn("hello again")
  end

  step "the usage stays with the turn it followed", context do
    turns =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        turns = StreamState.get(state, "provider-turn")

        turns =
          for run <- Enum.sort_by(StreamState.list(state, "run"), & &1["ordinal"]),
              do: Enum.find_value(turns, fn {id, t} -> String.ends_with?(id, run["id"]) && t end)

        if match?([%{"tokenUsage" => %{"usedTokens" => 4321}}, _], turns), do: turns
      end)

    assert [_, second] = turns
    refute get_in(second, ["tokenUsage", "usedTokens"])
    context
  end

  step "the user dismisses the Muse Code question", context do
    request = FakeAcp.await_request(context)

    assert {:ok, _} =
             HalC2.Orchestration.dispatch(%{
               "type" => "thread.user-input.dismiss",
               "threadId" => World.thread_id(context, context.thread),
               "requestId" => request["id"]
             })

    Map.put(context, :request, request)
  end

  step "Muse Code is told and the turn goes on", context do
    FakeAcp.await_run(context, "completed")

    assert [%{"answers" => [%{"questionId" => "q1", "freeText" => "The user dismissed" <> _}]}] =
             received(context, "userInput/answer")

    assert %{"status" => "cancelled"} =
             context
             |> state()
             |> StreamState.get("runtime-request")
             |> Map.get(context.request["id"])

    context
  end

  step "Muse Code wants to run a command", context do
    FakeAcp.send_message(context, "please run a command")
  end

  step "the command is asked for approval", context do
    assert %{"status" => "pending", "kind" => "command"} =
             request = FakeAcp.await_request(context)

    assert [%{"approvalMode" => "promptUnmatched"}] = received(context, "session/start")
    # A supervised host keeps Muse's sandbox.
    assert [%{"argv" => argv}] = thread_starts(context)
    refute "--disable-sandbox" in argv
    FakeAcp.respond(context, request["id"], %{"decision" => "accept"})
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the command is allowed without asking", context do
    state = FakeAcp.await_run(context, "completed")
    assert StreamState.list(state, "runtime-request") == []
    assert [%{"approvalMode" => "allowAll"}] = received(context, "session/start")
    assert [%{"argv" => argv}] = thread_starts(context)
    assert "--disable-sandbox" in argv

    assert [%{"asked" => false, "approved" => true}] =
             for(%{"tool" => t} <- FakeAcp.log(context), do: t)

    context
  end

  # --- approvals and questions ---

  step "Muse Code asked to edit a file", context do
    context =
      context
      |> install()
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("please edit a file")

    Map.put(context, :request, FakeAcp.await_request(context))
  end

  step "Muse Code asked to run a command", context do
    context =
      context
      |> install()
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("please run a command")

    Map.put(context, :request, FakeAcp.await_request(context))
  end

  step "Muse Code asked to run a command that needs two approvals", context do
    context =
      context
      |> install()
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("please run a guarded command")

    Map.put(context, :request, FakeAcp.await_request(context))
  end

  step "the user approves the Muse Code command", context do
    assert context.request["kind"] == "command"
    FakeAcp.respond(context, context.request["id"], %{"decision" => "accept"})
  end

  # Muse named its next requirement before acknowledging the first approval.
  step "the request still waits for the user", context do
    assert [%{"status" => "pending"}] =
             context |> state() |> StreamState.list("runtime-request")

    assert [%{"requirementId" => "req-1"}] = received(context, "approval/decide")
    assert for(%{"tool" => t} <- FakeAcp.log(context), do: t) == []
    context
  end

  step "Muse Code runs the command and the turn continues", context do
    FakeAcp.await_run(context, "completed")

    assert [%{"requirementId" => "req-1"}, %{"requirementId" => "req-2"}] =
             received(context, "approval/decide")

    assert [%{"name" => "shell", "approved" => true}] =
             for(%{"tool" => t} <- FakeAcp.log(context), do: t)

    assert [%{"status" => "resolved", "decision" => "accept"}] =
             context |> state() |> StreamState.list("runtime-request")

    assert List.last(replies(context)) == "Ran it."
    context
  end

  step "a Muse Code instance the user added runs a muse whose version check fails", context do
    context = install(context, %{"versionExit" => 2})
    ExUnit.Callbacks.on_exit(fn -> HalC2.Acp.forget("museWork") end)

    FakeAcp.settings(
      &put_in(&1, [Access.key("providerInstances", %{}), "museWork"], %{
        "driver" => "muse",
        "enabled" => true,
        "config" => %{"binaryPath" => FakeAcp.fake(context).bin}
      })
    )

    {_providers, context} =
      FakeAcp.await_providers(
        context,
        &match?(%{"status" => "error", "message" => _}, FakeAcp.find(&1, "museWork"))
      )

    context
  end

  step "the user points that instance at a working muse", context do
    dir = Mc.tmp_dir(context.mc, "working-muse")
    File.write!(Path.join(dir, "config.json"), "{}")
    bin = Path.join(dir, "muse")

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}'
    exec python3 -u '#{Path.expand("../../support/fake_muse_msp.py", __DIR__)}' "$@"
    """)

    File.chmod!(bin, 0o755)

    FakeAcp.settings(&put_in(&1, ["providerInstances", "museWork", "config", "binaryPath"], bin))

    context
  end

  step "that instance is listed with the models from Muse's catalog", context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        &match?(%{"models" => [_ | _]}, FakeAcp.find(&1, "museWork"))
      )

    refute FakeAcp.find(providers, "museWork")["status"] == "error"
    context
  end

  step "the user approves the Muse Code request", context do
    assert context.request["kind"] == "file-change"
    FakeAcp.respond(context, context.request["id"], %{"decision" => "accept"})
  end

  step "the user declines the Muse Code request", context do
    FakeAcp.respond(context, context.request["id"], %{"decision" => "decline"})
  end

  step "Muse Code edits the file and the turn continues", context do
    FakeAcp.await_run(context, "completed")
    assert [%{"choiceId" => "allow"}] = received(context, "approval/decide")

    assert [%{"name" => "edit", "approved" => true}] =
             for(%{"tool" => t} <- FakeAcp.log(context), do: t)

    assert [%{"status" => "completed", "fileName" => "src/app.ts"}] =
             items(context, "file_change")

    assert List.last(replies(context)) == "Edited it."
    context
  end

  # Shell approvals offer no plain "deny", so declining is Muse's "abort" choice.
  step "Muse Code is told the command was declined and the turn continues without it", context do
    FakeAcp.await_run(context, "completed")
    assert [%{"choiceId" => "reject"}] = received(context, "approval/decide")

    assert [%{"name" => "shell", "approved" => false}] =
             for(%{"tool" => t} <- FakeAcp.log(context), do: t)

    assert List.last(replies(context)) == "Ran it."

    assert [%{"status" => "resolved", "decision" => "decline"}] =
             context |> state() |> StreamState.list("runtime-request")

    context
  end

  step "Muse Code asks the user a question with choices", context do
    context |> install() |> FakeAcp.thread() |> FakeAcp.send_message("pick a color")
  end

  step "the choices appear in the composer and the answer goes back to Muse Code", context do
    request = FakeAcp.await_request(context)
    assert request["kind"] == "user_input"

    [item] =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        case Enum.filter(
               StreamState.list(state, "turn-item"),
               &(&1["type"] == "user_input_request")
             ) do
          [] -> nil
          items -> items
        end
      end)

    assert [%{"id" => "q1", "header" => "Color", "options" => options}] = item["questions"]
    assert Enum.map(options, & &1["label"]) == ~w(red green blue)

    context = FakeAcp.respond(context, request["id"], %{"answers" => %{"q1" => "green"}})
    FakeAcp.await_run(context, "completed")

    assert [
             %{
               "userInputId" => "input-1",
               "answers" => [%{"questionId" => "q1", "selectedLabel" => "green"}]
             }
           ] =
             received(context, "userInput/answer")

    assert List.last(replies(context)) == "Picked green."
    context
  end

  # --- interrupt and compaction ---

  step "a Muse Code turn is running", context do
    context = context |> install() |> FakeAcp.thread() |> FakeAcp.send_message("a long task")
    FakeAcp.await_run(context, "running")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(StreamState.list(state, "message"), &(&1["text"] == "Working on it."))
    end)

    context
  end

  step "Muse Code stops working and the turn is shown as interrupted", context do
    FakeAcp.await_run(context, "interrupted")

    [%{"turnId" => turn}] =
      received(context, "turn/start") |> Enum.map(&%{"turnId" => &1["commandId"]})

    assert [%{"turnId" => ^turn}] = received(context, "turn/interrupt")
    context
  end

  step "the user sends {string} to Muse Code", %{args: [text]} = context do
    turn(context, text)
  end

  step "Muse Code compacts its conversation", context do
    assert [%{"sessionId" => session}] = received(context, "session/compact")
    assert session == session_id(context)
    # Only the first message was a turn.
    assert [_] = received(context, "turn/start")
    context
  end

  step "the compaction is shown in the thread", context do
    assert [%{"status" => "completed", "title" => "Context compacted"}] =
             items(context, "compaction")

    context
  end

  # --- forks ---

  step "a Muse Code thread with three turns", context do
    context = context |> install() |> FakeAcp.thread()
    context = Enum.reduce(~w(first second third), context, &turn(&2, &1))
    Map.put(context, :current_thread, context.thread)
  end

  step "the user forks the Muse Code thread after the second turn", context do
    context = World.fork(context, context.thread, 2, "fork")
    assert {:ok, _} = context.reply
    turn(context, "where are we", "completed", "fork")
  end

  # The fork is a new Muse session whose first message carries the earlier turns.
  step "the fork's first Muse Code turn starts from a summary of the first two turns", context do
    assert [_, _] = received(context, "session/start")
    %{"input" => [%{"text" => text} | _]} = List.last(received(context, "turn/start"))
    assert text =~ "first"
    assert text =~ "second"
    refute text =~ "third"
    assert text =~ "where are we"
    context
  end

  # --- HAL-C2's tools ---

  step "HAL-C2's orchestration tools are attached as an optional MCP server", context do
    assert [%{"capabilities" => %{"requestedCapabilities" => ["sessionMcp"]}}] =
             for(
               p <- received(context, "initialize"),
               p["capabilities"]["requestedCapabilities"] != [],
               do: p
             )

    assert [%{"config" => %{"mcpServers" => %{"hal-c2" => server}}}] =
             received(context, "session/start")

    assert %{"transport" => "streamableHttp", "mode" => "optional", "url" => "http" <> _} = server
    assert %{"Authorization" => "Bearer " <> _} = server["headers"]
    context
  end

  # --- generated text ---

  step "the user opens the model choices for generated text", context do
    FakeAcp.probe("muse")
    {_, context} = FakeAcp.open_config(context)
    context
  end

  step "no Muse Code model is offered", context do
    assert %{"enabled" => true, "supportsTextGeneration" => false} = muse(context)
    context
  end
end
