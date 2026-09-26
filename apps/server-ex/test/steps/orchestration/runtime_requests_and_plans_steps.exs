defmodule T3.Steps.Orchestration.RuntimeRequestsAndPlans do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.World

  # Codex's requests and notifications are delivered to the thread's Codex runtime as
  # if the (fake) app-server sent them; its answers reach the fake, which says what it
  # received in the turn (`test/support/fake_codex.py`).

  step "thread {string} exists in {string} with a running turn",
       %{args: [thread, project]} = context do
    context |> World.named_thread(thread, project) |> World.running_turn(thread)
  end

  # --- approvals ---------------------------------------------------------------------

  step "the provider asks for approval of a {word} with prompt {string}",
       %{args: [kind, prompt]} = context do
    approval(context, kind, prompt)
  end

  step "the provider asked for approval of a command", context do
    approval(context, "command", "May I?")
  end

  step "the provider asks for approval of a command", context do
    approval(context, "command", "May I?")
  end

  step "{string} has a pending runtime request of kind {string} answerable live",
       %{args: [thread, kind]} = context do
    request = request(context, thread)
    assert %{"status" => "pending", "kind" => ^kind} = request
    assert request["responseCapability"]["type"] == "live"
    context
  end

  step "the run has a waiting approval request item with prompt {string}",
       %{args: [prompt]} = context do
    item = request_item(context)
    assert %{"type" => "approval_request", "status" => "waiting", "prompt" => ^prompt} = item
    assert item["runId"] == context.running
    context
  end

  step "the user approves the request", context do
    respond(context, %{"decision" => "accept"})
  end

  step "the user responds with decision {string}", %{args: [decision]} = context do
    respond(context, %{"decision" => decision})
  end

  step "the user responds to the request without a decision", context do
    respond(context, %{})
  end

  step "the user responds to request {string}", %{args: [request]} = context do
    World.command(context, %{
      "type" => "runtime-request.respond",
      "threadId" => World.thread_id(context, "t1"),
      "requestId" => request,
      "decision" => "accept"
    })
  end

  step ~r/^the request is resolved with decision (?<decision>\w+)$/,
       %{args: [decision]} = context do
    await_request(context, &(&1["status"] == "resolved"))
    assert request(context, "t1")["decision"] == decision
    context
  end

  step "the approval item is completed", context do
    assert request_item(context)["status"] == "completed"
    context
  end

  step "the provider receives decision {string}", %{args: [decision]} = context do
    assert received(context) == %{"decision" => decision}
    context
  end

  step "the request records decision {string}", %{args: [decision]} = context do
    assert %{"status" => "resolved", "decision" => ^decision} = request(context, "t1")
    context
  end

  # --- questions ---------------------------------------------------------------------

  step "the provider asks the user {string} with options", %{args: [question]} = context do
    questions(context, question)
  end

  step "the provider asked the user {string}", %{args: [question]} = context do
    questions(context, question)
  end

  step "{string} has a pending runtime request of kind {string}",
       %{args: [thread, kind]} = context do
    assert %{"status" => "pending", "kind" => ^kind} = request(context, thread)
    context
  end

  step "the run has a waiting user input request item with the question", context do
    item = request_item(context)
    assert %{"type" => "user_input_request", "status" => "waiting"} = item
    assert [%{"question" => question, "options" => [_ | _]}] = item["questions"]
    assert question == context.question
    assert item["runId"] == context.running
    context
  end

  step "the provider receives the answer {string}", %{args: [answer]} = context do
    assert received(context) == %{"answers" => %{"q1" => %{"answers" => [answer]}}}
    context
  end

  step "the user input item is completed with the answer", context do
    item = request_item(context)
    assert item["status"] == "completed"
    assert item["questionAnswer"]["answers"] == %{"q1" => "Postgres"}
    context
  end

  step "the user answers {string} attaching {string}", %{args: [answer, name]} = context do
    file = upload(name, true)
    context = World.answer_questions(context, "t1", answer, attaching(file))
    assert {:ok, _} = context.reply, "answering failed: #{inspect(context.reply)}"
    context
  end

  step "the provider receives {string} followed by a line naming {string} and its saved path",
       %{args: [answer, name]} = context do
    assert %{"answers" => %{"q1" => %{"answers" => [text]}}} = received(context)
    assert [^answer, line] = String.split(text, "\n\n")
    assert [_, ^name, path] = Regex.run(~r/^Attached image "(.+)": "(.+)"$/, line)
    assert File.exists?(path)
    context
  end

  step "the user answers attaching a file whose upload expired", context do
    World.answer_questions(context, "t1", "Here", attaching(upload("error.png", false)))
  end

  step "the command fails asking the user to attach it again", context do
    assert {:error, message, _} = context.reply
    assert message =~ "error.png"
    assert message =~ "Attach it again."
    context
  end

  step "the user dismisses the questions", context do
    context
    |> Map.put(:request, request(context, "t1")["id"])
    |> World.command(%{
      "type" => "thread.user-input.dismiss",
      "threadId" => World.thread_id(context, "t1"),
      "requestId" => request(context, "t1")["id"]
    })
    |> tap(&assert({:ok, _} = &1.reply))
  end

  step "the provider is told the questions were dismissed", context do
    assert received(context) == %{"answers" => %{}}
    context
  end

  step "the request is no longer pending", context do
    assert request(context, "t1")["status"] == "cancelled"
    assert request_item(context)["status"] == "cancelled"
    context
  end

  # --- after a restart ---------------------------------------------------------------

  step "the request expires", context do
    assert %{"status" => "expired", "resolvedAt" => at} = request(context, "t1")
    assert is_binary(at)
    context
  end

  step "the request is marked not resumable rather than cancelled", context do
    assert %{"status" => "expired", "responseCapability" => %{"type" => "not_resumable"}} =
             request(context, "t1")

    context
  end

  step "the thread explains the request can no longer be answered", context do
    assert request(context, "t1")["responseCapability"]["reason"] ==
             "The server restarted before this runtime request was resolved."

    context
  end

  # --- plans -------------------------------------------------------------------------

  step "the provider streams a proposed plan", context do
    notify(context, "item/started", %{"item" => %{"type" => "plan", "id" => "plan-item"}})
    notify(context, "item/plan/delta", %{"itemId" => "plan-item", "delta" => "## Plan\n"})
  end

  step "{string} has a draft plan that grows as it streams",
       %{args: [thread]} = context do
    await_plan_item(context, thread, "## Plan\n")

    assert World.state(context, thread).entities["plan"]["plan:codex:plan-item"]["status"] ==
             "draft"

    notify(context, "item/plan/delta", %{"itemId" => "plan-item", "delta" => "- step one\n"})
    await_plan_item(context, thread, "## Plan\n- step one\n")

    assert World.state(context, thread).entities["plan"]["plan:codex:plan-item"]["status"] ==
             "draft"

    context
  end

  step "the plan becomes active when the provider finishes it", context do
    text = "## Plan\n- step one\n- step two\n"

    notify(context, "item/completed", %{
      "item" => %{"type" => "plan", "id" => "plan-item", "text" => text}
    })

    World.await_state(context, "t1", fn state ->
      match?(
        %{"status" => "active", "markdown" => ^text},
        state.entities["plan"]["plan:codex:plan-item"]
      )
    end)

    context
  end

  step "the provider reports a to-do list with two steps, one done", context do
    todo(context, ["completed", "inProgress"])
  end

  step "{string} has an active to-do plan", %{args: [thread]} = context do
    plan = World.state(context, thread).entities["plan"]["plan:codex:turn-plan:todo"]

    assert %{
             "status" => "active",
             "steps" => [%{"status" => "completed"}, %{"status" => "running"}]
           } = plan

    context
  end

  step "the plan completes when every step is done", context do
    todo(context, ["completed", "completed"])

    assert World.state(context, "t1").entities["plan"]["plan:codex:turn-plan:todo"]["status"] ==
             "completed"

    context
  end

  step "{string} has an active proposed plan {string}", %{args: [thread, plan]} = context do
    proposed_plan(context, thread, plan)
  end

  step "thread {string} has an active proposed plan {string}",
       %{args: [thread, plan]} = context do
    context
    |> World.named_thread(thread, "demo")
    |> Map.put(:thread, "t1")
    |> proposed_plan(thread, plan)
  end

  step "the user sends {string} to {string} referring to plan {string}",
       %{args: [text, thread, plan]} = context do
    implement(context, thread, text, thread, plan)
  end

  step "the user sends a message to {string} referring to plan {string} of {string}",
       %{args: [thread, plan, plan_thread]} = context do
    implement(context, thread, "Implement it", plan_thread, plan)
  end

  step "plan {string} is completed", %{args: [plan]} = context do
    thread = context.plans[plan]
    assert World.state(context, thread).entities["plan"][plan]["status"] == "completed"
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp codex(context) do
    [{pid, _}] = Registry.lookup(T3.Codex.Registry, World.thread_id(context, "t1"))
    {pid, :sys.get_state(pid).conn}
  end

  defp provider_request(context, method, params) do
    {pid, conn} = codex(context)
    rpc = System.unique_integer([:positive])

    send(
      pid,
      {:json_rpc, conn, {:request, rpc, method, Map.put(params, "itemId", "item-#{rpc}")}}
    )

    context = Map.merge(context, %{rpc: rpc, request: "runtime-request:codex:item-#{rpc}"})
    await_request(context, &(&1["status"] == "pending"))
    context
  end

  defp notify(context, method, params) do
    {pid, conn} = codex(context)
    send(pid, {:json_rpc, conn, {:notification, method, params}})
    context
  end

  defp approval(context, kind, prompt) do
    {method, params} =
      case kind do
        "command" ->
          {"item/commandExecution/requestApproval", %{"command" => "ls"}}

        "file-change" ->
          {"item/fileChange/requestApproval", %{}}

        "file-read" ->
          {"item/permissions/requestApproval",
           %{"permissions" => %{"fileSystem" => %{"read" => ["/x"]}}}}

        "permission" ->
          {"item/permissions/requestApproval", %{"permissions" => %{}}}
      end

    provider_request(context, method, Map.put(params, "reason", prompt))
  end

  defp questions(context, question) do
    context
    |> Map.put(:question, question)
    |> provider_request("item/tool/requestUserInput", %{
      "questions" => [
        %{
          "id" => "q1",
          "header" => "Question",
          "question" => question,
          "options" => [%{"label" => "Postgres"}, %{"label" => "SQLite"}]
        }
      ]
    })
  end

  defp respond(context, fields) do
    context =
      World.command(
        context,
        Map.merge(
          %{
            "type" => "runtime-request.respond",
            "threadId" => World.thread_id(context, "t1"),
            "requestId" => context.request
          },
          fields
        )
      )

    assert {:ok, _} = context.reply, "respond failed: #{inspect(context.reply)}"
    context
  end

  defp request(context, thread) do
    World.state(context, thread).entities["runtime-request"][context.request] ||
      flunk("no request #{context.request}")
  end

  defp request_item(context) do
    Enum.find(World.entities(context, "t1", "turn-item"), &(&1["requestId"] == context.request))
  end

  defp await_request(context, fun) do
    World.await_state(
      context,
      "t1",
      &fun.(&1.entities["runtime-request"][context.request] || %{})
    )
  end

  # What the fake Codex said it received in answer to the injected request.
  defp received(context) do
    item_id = "turn-item:codex:msg-received-#{context.rpc}"

    state =
      World.await_state(context, "t1", fn state ->
        match?(%{"text" => "received " <> _}, state.entities["turn-item"][item_id])
      end)

    "received " <> json = state.entities["turn-item"][item_id]["text"]
    JSON.decode!(json)
  end

  defp upload(name, stored?) do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      T3.Attachments.create_upload_url(%{
        "type" => "image",
        "name" => name,
        "mimeType" => "image/png",
        "sizeBytes" => 4
      })

    if stored?, do: :ok = T3.Attachments.store(token, "png!")
    %{"type" => "image", "id" => id, "name" => name, "mimeType" => "image/png", "sizeBytes" => 4}
  end

  defp attaching(file), do: %{"attachmentsByQuestionId" => %{"q1" => [file]}}

  defp await_plan_item(context, thread, markdown) do
    World.await_state(context, thread, fn state ->
      state.entities["turn-item"]["turn-item:codex:plan-item"]["markdown"] == markdown
    end)
  end

  defp todo(context, statuses) do
    plan =
      for {status, step} <- Enum.zip(statuses, ["Read the code", "Write the fix"]),
          do: %{"step" => step, "status" => status}

    notify(context, "turn/plan/updated", %{"turnId" => "todo", "plan" => plan})

    World.await_state(context, "t1", fn state ->
      match?(
        %{"steps" => steps} when length(steps) == 2,
        state.entities["plan"]["plan:codex:turn-plan:todo"]
      ) and
        Enum.map(state.entities["plan"]["plan:codex:turn-plan:todo"]["steps"], & &1["status"]) ==
          Enum.map(statuses, &if(&1 == "inProgress", do: "running", else: &1))
    end)

    context
  end

  defp proposed_plan(context, thread, plan_id) do
    plan = %{
      "id" => plan_id,
      "threadId" => World.thread_id(context, thread),
      "runId" => nil,
      "nodeId" => nil,
      "kind" => "proposed_plan",
      "status" => "active",
      "markdown" => "# Plan\n\n- do it",
      "createdAt" => World.iso_from_now(0),
      "updatedAt" => World.iso_from_now(0)
    }

    context
    |> World.put_entity(thread, "plan", plan_id, %{"s" => plan})
    |> Map.update(:plans, %{plan_id => thread}, &Map.put(&1, plan_id, thread))
  end

  defp implement(context, thread, text, plan_thread, plan) do
    context =
      World.send_message(context, thread, text, %{
        "sourcePlanRef" => %{
          "threadId" => World.thread_id(context, plan_thread),
          "planId" => plan
        }
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    context
  end
end
