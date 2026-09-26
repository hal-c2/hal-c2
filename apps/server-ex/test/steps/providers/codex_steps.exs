defmodule HalC2.Steps.Providers.Codex do
  @moduledoc """
  Steps for `features/providers/codex.feature`. Codex runs on `fake_codex.py` (see
  `HalC2.Test.Node.World.fake_providers/2`), which plays scripted turns from trigger
  words in the message and logs every app-server message it reads.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @thread "Codex work"

  # --- install, models and updates ----------------------------------------------------

  step "the codex command is installed on the node", context do
    context = World.fake_providers(context)
    assert System.find_executable(hd(Application.get_env(:hal_c2, :codex_command)))
    context
  end

  step "the codex command is not installed on the node", context do
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

  step "the node has read the Codex model list", context do
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

  step "the node has just started and has not read the Codex model list yet", context do
    # A fresh node has only started the background read; the fake has no list to give.
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

  step "Codex receives the message during the running turn", context do
    steer =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/steer"))

    assert [%{"text" => "one more thing"} | _] = get_in(steer, ["in", "params", "input"])
    World.await_runs(context, @thread, ["completed"])
    assert "steered: one more thing" in World.replies(context, @thread)
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
        "params" => %{"name" => "halc2_thread_list", "arguments" => %{}}
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

  step "a Codex thread has run at least one turn on this node", context do
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
    expected = String.split(choices, ~r/, | or /)

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

  step "the Codex CLI on the node is not signed in", context do
    context = World.fake_providers(context)
    System.put_env("FAKE_CODEX_ACCOUNT", "none")
    # The node reads the account when it checks the provider.
    Node.ensure(HalC2.ProviderUsageLimits)
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
    Node.ensure(HalC2.ProviderUsageLimits)
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
