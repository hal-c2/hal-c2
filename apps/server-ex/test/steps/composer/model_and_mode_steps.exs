defmodule HalC2.Steps.Composer.ModelAndMode do
  @moduledoc "Steps for `features/composer/model-and-mode.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  # The runtime mode each permission level is, and what Codex is told for it.
  @modes %{
    "Supervised" => {"approval-required", "untrusted", "readOnly"},
    "Auto-accept edits" => {"auto-accept-edits", "on-request", "workspaceWrite"},
    "Auto" => {"auto", "on-request", "workspaceWrite"},
    "Full access" => {"full-access", "never", "dangerFullAccess"}
  }

  step "a project with an open thread on Codex", context do
    context
    |> World.create_project("shop")
    |> World.create_thread("Open thread", "shop")
    |> Map.put(:current, "Open thread")
    |> then(&World.put_client(&1, World.client(&1)))
    |> World.agents()
  end

  step ~r/^the user sets the permissions to (?<mode>.+)$/, %{args: [mode]} = context do
    {runtime_mode, _, _} = Map.fetch!(@modes, mode)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.runtime-mode.set",
        "threadId" => World.thread_id(context, context.current),
        "runtimeMode" => runtime_mode
      })

    assert World.thread(context, context.current)["runtimeMode"] == runtime_mode
    context
  end

  step ~r/^the next turn runs in (?<mode>Supervised|Auto-accept edits|Auto|Full access)$/,
       %{args: [mode]} = context do
    {_, approval, sandbox} = Map.fetch!(@modes, mode)
    turn = next_turn(context)
    assert %{"approvalPolicy" => ^approval, "sandboxPolicy" => %{"type" => ^sandbox}} = turn
    context
  end

  step "the thread is building", context do
    assert World.thread(context, context.current)["interactionMode"] == "default"
    context
  end

  step "the user toggles to planning", context do
    interaction(context, "plan")
  end

  step "the user toggles back", context do
    interaction(context, "default")
  end

  step "the next turn plans instead of making changes", context do
    assert %{"collaborationMode" => %{"mode" => "plan"}} = next_turn(context)
    context
  end

  step "the next turn builds again", context do
    assert %{"collaborationMode" => %{"mode" => "default"}} = next_turn(context)
    context
  end

  step "the thread runs on Claude with Ultrathink turned on", context do
    selection = %{
      "instanceId" => "claudeAgent",
      "model" => "claude-sonnet-4-6",
      "options" => [%{"id" => "effort", "value" => "ultrathink"}]
    }

    title = "Ultrathink thread"

    context =
      context
      |> World.fake_providers()
      |> World.launch_on(title, "claudeAgent", "hello", %{"modelSelection" => selection})

    World.await_runs(context, title, ["completed"])
    Map.put(context, :current, title)
  end

  # Claude gets the prefix and the message on separate lines; the scenario writes them
  # on one, so whitespace is compared as a single space.
  step "the agent receives {string}", %{args: [received]} = context do
    World.await_runs(context, context.current, ["completed", "completed"])

    texts =
      for %{"in" => %{"type" => "user", "message" => %{"content" => text}}} <-
            World.provider_log(context, "claude"),
          do: text

    text = List.last(texts)
    assert String.replace(text, ~r/\s+/, " ") == received
    context
  end

  # The selection revision (`HalC2.Orchestration.Selection`): what a client's pick was
  # made against, and what each change answers with.

  step ~r/^another client (?:has moved|moves) the thread to "(?<model>[^"]+)"$/,
       %{args: [model]} = context do
    seen = revision(context)

    {{:ok, reply}, context} =
      World.dispatch(context, %{
        "type" => "thread.model-selection.set",
        "threadId" => World.thread_id(context, context.current),
        "modelSelection" => codex(model),
        "selectionBase" => seen
      })

    assert reply["selectionRevision"] == seen + 1
    Map.put_new(context, :seen, seen)
  end

  step "the user sends a message picked on {string} against the selection they saw",
       %{args: [model]} = context do
    compose(context, %{"modelSelection" => codex(model), "selectionBase" => context[:seen] || 0})
  end

  step "the user sends a message that picks nothing", context do
    context = compose(context, %{})
    assert {:ok, _} = context.reply
    context
  end

  step "the user sends a message that names {string}", %{args: [model]} = context do
    context = compose(context, %{"modelSelection" => codex(model)})
    assert {:ok, %{"selectionRevision" => _}} = context.reply
    context
  end

  step "the send is refused as stale, naming {string}", %{args: [model]} = context do
    assert {:error, message, detail} = context.reply
    assert message =~ "moved to"
    revision = revision(context)

    assert %{
             "code" => "selection-stale",
             "selectionRevision" => ^revision,
             "modelSelection" => %{"instanceId" => "codex", "model" => ^model}
           } = detail

    assert Map.keys(detail) |> Enum.sort() == ~w(code modelSelection selectionRevision)
    context
  end

  step "the thread still runs on {string}", %{args: [model]} = context do
    assert World.thread(context, context.current)["modelSelection"]["model"] == model
    context
  end

  step "the thread runs on {string} at selection revision {int}",
       %{args: [model, revision]} = context do
    thread = World.thread(context, context.current)
    assert %{"modelSelection" => %{"model" => ^model}, "selectionRevision" => ^revision} = thread
    context
  end

  step ~r/^(?:its turn|the queued message) runs on "(?<model>[^"]+)"$/, %{args: [model]} = context do
    started = context[:turns_before] || 0

    World.await_thread(context, context.current, fn state ->
      runs = HalC2.StreamState.list(state, "run")
      runs != [] and Enum.all?(runs, &(&1["status"] == "completed"))
    end)

    turn = context |> World.codex_requests("turn/start") |> Enum.at(started)
    assert turn["model"] == model, "the turn started on #{inspect(turn)}"
    context
  end

  step "the user has queued a message that names {string}", %{args: [model]} = context do
    {{:ok, _}, context} =
      World.send_message(context, context.current, "after that", %{
        "modelSelection" => codex(model)
      })

    queued =
      context
      |> World.stream(context.current)
      |> HalC2.StreamState.list("run")
      |> Enum.find(&(&1["status"] == "queued"))

    assert %{"selectionPicked" => true} = queued
    Map.put(context, :turns_before, length(World.codex_requests(context, "turn/start")))
  end

  step "the agent finishes its turn", context do
    World.complete_codex_turn(context, context.current)
  end

  step "a client switches the thread to planning", context do
    {reply, context} =
      World.dispatch(context, %{
        "type" => "thread.interaction-mode.set",
        "threadId" => World.thread_id(context, context.current),
        "interactionMode" => "plan"
      })

    Map.put(context, :reply, reply)
  end

  step "the reply names selection revision {int}", %{args: [revision]} = context do
    assert {:ok, %{"selectionRevision" => ^revision}} = context.reply
    context
  end

  step "the reply names no selection revision", context do
    assert {:ok, reply} = context.reply
    refute Map.has_key?(reply || %{}, "selectionRevision")
    context
  end

  step "new threads default to {string}", %{args: [model]} = context do
    HalC2.Test.Mc.ensure(HalC2.Settings)
    # The MC starts settings before the shell; a scenario starts them the other way round.
    :ok = HalC2.Settings.watch(Process.whereis(HalC2.Shell))
    World.update_settings(context, %{"defaultModelSelection" => codex(model)})
  end

  step "a client creates a thread without naming a model or permissions", context do
    context
    |> World.create_thread("Drafted", "shop", %{"modelSelection" => nil})
    |> Map.put(:current, "Drafted")
  end

  step "the new thread is recorded as running {string} in full access",
       %{args: [model]} = context do
    thread = World.thread(context, context.current)
    assert %{"modelSelection" => %{"model" => ^model}, "runtimeMode" => "full-access"} = thread
    context
  end

  step "the project's sidebar row says a new thread there runs {string} in full access",
       %{args: [model]} = context do
    World.await_row(World.project(context, "shop").id, fn row ->
      get_in(row, ["newThreadModelSelection", "model"]) == model and
        row["newThreadRuntimeMode"] == "full-access"
    end)

    context
  end

  defp codex(model), do: %{"instanceId" => "codex", "model" => model}

  defp revision(context),
    do: World.thread(context, context.current)["selectionRevision"] || 0

  # Sends a message over the socket as the composer does; the reply is `context.reply`.
  defp compose(context, extra) do
    {reply, context} =
      World.dispatch(
        context,
        Map.merge(
          %{
            "type" => "message.dispatch",
            "threadId" => World.thread_id(context, context.current),
            "messageId" => "msg-#{System.unique_integer([:positive])}",
            "text" => "go on",
            "attachments" => []
          },
          extra
        )
      )

    Map.put(context, :reply, reply)
  end

  defp interaction(context, mode) do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.interaction-mode.set",
        "threadId" => World.thread_id(context, context.current),
        "interactionMode" => mode
      })

    context
  end

  # Sends a message, waits for its turn to finish, and returns what Codex was told.
  defp next_turn(context) do
    thread = context.current
    done = length(World.codex_requests(context, "turn/start"))
    {{:ok, _}, context} = World.send_message(context, thread, "go on")

    World.await_thread(context, thread, fn state ->
      runs = HalC2.StreamState.list(state, "run")
      length(runs) == done + 1 and Enum.all?(runs, &(&1["status"] == "completed"))
    end)

    context |> World.codex_requests("turn/start") |> Enum.at(done)
  end
end
