defmodule T3.Steps.Timeline.ApprovalsAndQuestions do
  @moduledoc """
  Steps for `features/timeline/approvals-and-questions.feature`. The agents are the
  fake providers in `test/support`: "approve run: CMD" asks to run a command, "ask: Q"
  (Codex) asks a question. The fakes log what the node answered them, which is what
  "is told to" checks.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.StreamState
  alias T3.Test.Node.World

  step "the user is looking at a thread in {string} whose agent is working",
       %{args: [project]} = context do
    context =
      if Map.has_key?(context.projects, project),
        do: context,
        else: World.create_project(context, project)

    context
    |> World.working_thread("Current thread")
    |> Map.put(:current, "Current thread")
    |> then(&World.put_client(&1, World.client(&1)))
  end

  # ACP agents only ask the user outside full access (the node answers them itself there).
  step "the thread runs on an ACP agent such as OpenCode or Cursor", context do
    context =
      context
      |> World.working_thread("OpenCode thread", "OpenCode")
      |> Map.put(:current, "OpenCode thread")

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.runtime-mode.set",
        "threadId" => World.thread_id(context, "OpenCode thread"),
        "runtimeMode" => "approval-required"
      })

    context
  end

  step "the user allows it always", context do
    respond(context, "acceptAlways")
  end

  step "Codex is told to allow it for the rest of the session", context do
    assert [%{"result" => %{"decision" => "acceptForSession"}}] =
             World.codex_requests(context, "response")
             |> Enum.filter(&(&1["id"] == "approval-1"))

    context
  end

  step "an ACP agent such as OpenCode or Cursor is told to allow it always, or once if always is not offered",
       context do
    assert [%{"result" => %{"outcome" => %{"optionId" => "always"}}}] =
             World.acp_requests(context, "response")

    # The same answer when the agent only offers a one-time allow. A different
    # command: the runtime remembers "always" for `npm test` and would not ask.
    context =
      context
      |> World.request_from_agent("approve run: npm lint, once only")
      |> respond("acceptAlways")

    assert [_, %{"result" => %{"outcome" => %{"optionId" => "allow"}}}] =
             World.acp_requests(context, "response")

    context
  end

  step "the user always allows {string} for this session", %{args: [command]} = context do
    context
    |> World.request_from_agent("approve run: #{command}")
    |> respond("acceptForSession")
    |> tap(&await_idle/1)
  end

  step "the agent asks to run {string} again", %{args: [command]} = context do
    title = World.current(context)
    {{:ok, _}, context} = World.send_message(context, title, "approve run: #{command}")
    run_id = World.run_for(context, title, "approve run: #{command}")["id"]

    World.await_thread(context, title, fn state ->
      StreamState.get(state, "run")[run_id]["status"] == "completed" or
        Enum.any?(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
    end)

    Map.put(context, :command, command)
  end

  step "the command runs without asking", context do
    state = World.stream(context, World.current(context))
    assert [_only_the_first] = StreamState.list(state, "runtime-request")

    assert Enum.any?(
             StreamState.list(state, "message"),
             &(&1["role"] == "assistant" and &1["text"] == "ran #{context.command} without asking")
           )

    context
  end

  step "the agent asks {string}", %{args: [question]} = context do
    context = World.request_from_agent(context, "ask: #{question}")
    state = World.stream(context, World.current(context))

    assert Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["type"] == "user_input_request" and
                 Enum.any?(&1["questions"] || [], fn q -> q["question"] == question end))
           )

    context
  end

  step "the user dismisses the question", context do
    if World.fakes_feature?(context) do
      title = World.current_thread(context)
      request = context[:request] || World.await_request(context, title)

      {:ok, _} =
        T3.Orchestration.dispatch(%{
          "type" => "thread.user-input.dismiss",
          "threadId" => World.thread_id(context, title),
          "requestId" => request["id"]
        })

      Map.put(context, :request, request)
    else
      assert {:ok, _} =
               T3.Orchestration.dispatch(%{
                 "type" => "thread.user-input.dismiss",
                 "threadId" => World.thread_id(context, World.current(context)),
                 "requestId" => context.request_id
               })

      context
    end
  end

  step "the question is closed as dismissed", context do
    state =
      World.await_thread(
        context,
        World.current(context),
        &(StreamState.get(&1, "runtime-request")[context.request_id]["status"] != "pending")
      )

    request = StreamState.get(state, "runtime-request")[context.request_id]
    assert request["status"] == "cancelled"

    assert [%{"status" => "cancelled"}] =
             state
             |> StreamState.list("turn-item")
             |> Enum.filter(&(&1["type"] == "user_input_request"))

    refute Map.has_key?(request, "answers")
    context
  end

  step "the agent is not given an answer", context do
    # The fake Codex logs the answer before it finishes the turn.
    await_idle(context)

    assert [%{"result" => %{"answers" => answers}}] =
             World.codex_requests(context, "response") |> Enum.filter(&(&1["id"] == "input-1"))

    assert answers == %{}
    context
  end

  defp respond(context, decision) do
    title = World.current(context)

    assert {:ok, _} =
             T3.Orchestration.dispatch(%{
               "type" => "runtime-request.respond",
               "threadId" => World.thread_id(context, title),
               "requestId" => context.request_id,
               "decision" => decision
             })

    await_idle(context)
    context
  end

  # The turn the answer let finish.
  defp await_idle(context) do
    title = World.current(context)

    World.await_thread(context, title, fn state ->
      state |> StreamState.list("run") |> Enum.all?(&(&1["status"] not in ["running", "queued"]))
    end)
  end
end
