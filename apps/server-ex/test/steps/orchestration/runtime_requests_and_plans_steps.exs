defmodule HalC2.Steps.Orchestration.RuntimeRequestsAndPlans do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

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

  step "the user answers with the options {string} in Codex's own shape",
       %{args: [answer]} = context do
    context = World.answer_questions(context, "t1", %{"answers" => [answer]})
    assert {:ok, _} = context.reply, "answering failed: #{inspect(context.reply)}"
    context
  end

  step "the user input item is completed with the options {string}",
       %{args: [answer]} = context do
    item = request_item(context)
    assert item["status"] == "completed"
    assert item["questionAnswer"]["answers"] == %{"q1" => [answer]}
    context
  end

  step "the Codex runtime is given the options {string} in Codex's own shape and a map",
       %{args: [answer]} = context do
    request = request(context, "t1")
    response = %{"answers" => %{"q1" => %{"answers" => [answer, %{"label" => "SQLite"}]}}}

    assert :ok =
             HalC2.Codex.ThreadRuntime.respond(
               World.thread_id(context, "t1"),
               request["id"],
               response
             )

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

  # --- refusals --------------------------------------------------------------------

  step "a caller answers with a number instead of text", context do
    World.command(context, %{
      "type" => "runtime-request.respond",
      "threadId" => World.thread_id(context, "t1"),
      "requestId" => context.request,
      "answers" => %{"q1" => 5432}
    })
  end

  step "the answer is refused", context do
    assert {:error, _, _} = context.reply
    context
  end

  step "{string} is still waiting for an answer", %{args: [question]} = context do
    assert request(context, "t1")["status"] == "pending"

    assert %{"status" => "waiting", "questions" => [%{"question" => ^question}]} =
             request_item(context)

    context
  end

  step ~r/^the questions were already (?<done>answered|dismissed)$/,
       %{args: [done]} = context do
    case done do
      "answered" -> respond(context, %{"answers" => %{"q1" => "Postgres"}})
      "dismissed" -> dismiss(context)
    end

    await_request(context, &(&1["status"] in ["resolved", "cancelled"]))
    context
  end

  step "the provider asked the user {string} with fixed choices only",
       %{args: [question]} = context do
    context = questions(context, question)
    # Antigravity's questions take only their options (`allowCustomAnswer: false`).
    patch_questions(context, &Map.put(&1, "allowCustomAnswer", false))
  end

  step "the user answers attaching {string}", %{args: [name]} = context do
    World.command(
      context,
      Map.merge(
        %{
          "type" => "runtime-request.respond",
          "threadId" => World.thread_id(context, "t1"),
          "requestId" => context.request,
          "answers" => %{"q1" => "Here"}
        },
        attaching(upload(name, true))
      )
    )
  end

  step "the question has since closed", context do
    context = dismiss(context)
    await_request(context, &(&1["status"] == "cancelled"))
    context
  end

  step "the user responds to it", context do
    World.command(context, %{
      "type" => "runtime-request.respond",
      "threadId" => World.thread_id(context, "t1"),
      "requestId" => context.request,
      "decision" => "accept"
    })
  end

  step "a request of {string} is still pending but marked as one that cannot be resumed, with a reason",
       %{args: [thread]} = context do
    context = approval(context, "command", "May I?")
    reason = "The provider session was replaced before this runtime request was resolved."

    context
    |> World.put_entity(thread, "runtime-request", context.request, %{
      "s" => %{"responseCapability" => %{"type" => "not_resumable", "reason" => reason}}
    })
    |> Map.put(:reason, reason)
  end

  step "the command fails with the reason recorded on the request", context do
    assert {:error, reason, _} = context.reply
    assert reason == context.reason
    assert request(context, "t1")["responseCapability"]["reason"] == reason
    context
  end

  # The Codex runtime still holds the provider's request: no answer went out for it.
  step "nothing is sent to the provider", context do
    {pid, _} = codex(context)
    assert Map.has_key?(:sys.get_state(pid).requests, context.request)
    assert request(context, "t1")["status"] == "pending"
    context
  end

  # --- answers given by message ------------------------------------------------------

  step "the provider asked {string} and {string} without waiting on them",
       %{args: [first, second]} = context do
    ask_async(context, [first, second])
  end

  step "the provider asked two questions it does not wait on", context do
    ask_async(context, ["Which database?", "Which port?"])
  end

  step "the provider asked a required question and an optional one without waiting on them",
       context do
    context
    |> ask_async(["Which database?", "Which port?"])
    |> patch_questions(&if(&1["id"] == "1", do: Map.put(&1, "required", false), else: &1))
  end

  step "the provider asked only optional questions without waiting on them", context do
    context
    |> ask_async(["Which database?", "Which port?"])
    |> patch_questions(&Map.put(&1, "required", false))
  end

  step "the provider asked a question the user can answer with a message", context do
    ask_async(context, ["Which color?"])
  end

  step "the user answers {string} and {string}", %{args: [first, second]} = context do
    respond(context, %{"answers" => %{"0" => first, "1" => second}})
  end

  step "the user answers only the first", context do
    answer_by_message(context, %{"0" => "Postgres"})
  end

  step "the user answers only the required question", context do
    respond(context, %{"answers" => %{"0" => "Postgres"}})
  end

  step "the user sends without answering any", context do
    answer_by_message(context, %{})
  end

  step "the user answers", context do
    respond(context, %{"answers" => %{"0" => "Red"}})
  end

  step "{string} receives one user message pairing each question with its answer, in the order asked",
       %{args: [thread]} = context do
    assert %{"role" => "user", "text" => "Which database?\nPostgres\n\nWhich port?\n5432"} =
             answer_message(context, thread)

    context
  end

  step "the answer is sent with the required question alone", context do
    assert answer_message(context, "t1")["text"] == "Which database?\nPostgres"
    context
  end

  step "the questions are closed as answered", context do
    assert %{"status" => "resolved", "answers" => %{"0" => "Postgres", "1" => "5432"}} =
             request(context, "t1")

    assert request_item(context)["status"] == "completed"
    context
  end

  step "nothing is sent to the thread", context do
    assert request(context, "t1")["status"] == "pending"
    refute StreamState.fetch(World.stream(context, "t1"), "message", answer_id(context))
    assert [_] = World.runs(context, "t1")
    context
  end

  # The background's Codex steers; Grok takes no message mid-turn (`Entities.steers?/1`).
  step ~r/^the running turn of "(?<thread>[^"]+)" is on a provider that (?<steering>can|cannot) take messages mid-turn$/,
       %{args: [thread, steering]} = context do
    case steering do
      "can" ->
        Map.put(context, :steering, true)

      "cannot" ->
        context = context |> World.fake_providers() |> World.launch_on(thread, "grok", "wait")
        run = World.await_running(context, thread)
        Map.merge(context, %{steering: false, running: run["id"]})
    end
  end

  step "the provider asked a question it does not wait on and its turn is still running",
       context do
    context =
      if context.steering,
        do: ask_async(context, ["Which color?"]),
        else: plant_async(context, "Which color?")

    assert %{"status" => "running"} = World.latest_run(context, "t1")
    context
  end

  step "the answer joins the running turn", context do
    World.await_runs(context, "t1", ["completed"])
    assert "steered: Which color?\nRed" in World.replies(context, "t1")
    assert answer_message(context, "t1")["text"] == "Which color?\nRed"
    assert [_] = World.runs(context, "t1")
    context
  end

  step "the answer waits in the queue behind the running turn", context do
    message = answer_message(context, "t1")
    assert message["text"] == "Which color?\nRed"

    assert [%{"id" => running, "status" => "running"}, %{"status" => "queued"} = queued] =
             World.runs(context, "t1")

    assert running == context.running
    assert queued["userMessageId"] == answer_id(context)
    context
  end

  step "the question is still pending", context do
    assert %{"status" => "pending", "responseCapability" => %{"type" => "message"}} =
             request(context, "t1")

    assert request_item(context)["status"] == "waiting"
    context
  end

  step "the user can still answer it", context do
    context = respond(context, %{"answers" => %{"0" => "Red"}})
    assert request(context, "t1")["status"] == "resolved"
    assert answer_message(context, "t1")["text"] == "Which color?\nRed"
    context
  end

  # --- requests and the end of their turn or server ------------------------------------

  step "the request is cancelled and marked not resumable", context do
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}

    assert %{"status" => "cancelled", "responseCapability" => %{"type" => "not_resumable"}} =
             request(context, "t1")

    context
  end

  step "it says the server shut down before the request was resolved", context do
    assert request(context, "t1")["responseCapability"]["reason"] ==
             "The server shut down before this runtime request was resolved."

    context
  end

  step "the provider asked the user a question that only the running turn can receive the answer to",
       context do
    context = questions(context, "Which database?")
    assert request(context, "t1")["responseCapability"]["type"] == "live"
    context
  end

  step ~r/^the provider's turn (?<ends>completes|fails|is interrupted) before the user answers$/,
       %{args: [ends]} = context do
    status =
      %{"completes" => "completed", "fails" => "failed", "is interrupted" => "interrupted"}[ends]

    end_turn(context, status)
  end

  step "the question is cancelled and no longer pending", context do
    await_request(context, &(&1["status"] == "cancelled"))
    assert request_item(context)["status"] == "cancelled"
    context
  end

  step "the provider asked the user a question", context do
    questions(context, "Which database?")
  end

  step "the provider's turn ends at the same moment the user answers", context do
    context
  end

  # The answer is recorded, then the turn's end arrives and closes what it left open.
  step "the user's answer is recorded first", context do
    context = respond(context, %{"answers" => %{"q1" => "Postgres"}})
    await_request(context, &(&1["status"] == "resolved"))
    end_turn(context, "completed")
  end

  step "the question stays answered with what the user chose", context do
    assert %{"status" => "resolved"} = request(context, "t1")
    assert request_item(context)["questionAnswer"]["answers"] == %{"q1" => "Postgres"}
    context
  end

  step "the turn's end does not mark it cancelled", context do
    assert request_item(context)["status"] == "completed"
    assert World.state(context, "t1").entities["run"][context.running]["status"] == "completed"
    context
  end

  # The run stays `running`: an MC run is `waiting` once its provider finished and
  # its checkpoint has not settled. The thread's row names the request it waits on.
  step "the run of {string} is waiting", %{args: [thread]} = context do
    id = context.request

    row =
      World.await_row(
        World.thread_id(context, thread),
        &match?(%{"pendingRuntimeRequest" => %{"id" => ^id}}, &1)
      )

    assert %{"pendingRuntimeRequest" => %{"kind" => "command"}} = row
    assert row["activeRunId"] == context.running
    assert World.state(context, thread).entities["run"][context.running]["status"] == "running"
    context
  end

  step "it returns to running when the request is resolved", context do
    context = respond(context, %{"decision" => "accept"})
    row = World.await_row(World.thread_id(context, "t1"), &(&1["pendingRuntimeRequest"] == nil))
    assert row["activeRunId"] == context.running
    assert row["activityRunStatus"] == "running"
    context
  end

  # --- plans that cannot be implemented --------------------------------------------------

  step "thread {string} of project {string} has an active proposed plan {string}",
       %{args: [thread, project, plan]} = context do
    context
    |> World.create_project(project)
    |> World.named_thread(thread, project)
    |> Map.put(:thread, "t1")
    |> proposed_plan(thread, plan)
  end

  step "plan {string} is still active", %{args: [plan]} = context do
    thread = context.plans[plan]
    assert World.state(context, thread).entities["plan"][plan]["status"] == "active"
    context
  end

  step "plan {string} of {string} was implemented and is completed",
       %{args: [plan, thread]} = context do
    context =
      context |> proposed_plan(thread, plan) |> implement(thread, "Implement it", thread, plan)

    assert {:ok, _} = context.reply
    assert World.state(context, thread).entities["plan"][plan]["status"] == "completed"
    Map.put(context, :run_count, length(World.runs(context, thread)))
  end

  step "the user sends another message to {string} referring to plan {string}",
       %{args: [thread, plan]} = context do
    implement(context, thread, "Implement it again", thread, plan)
  end

  step "no second run starts for the plan", context do
    assert length(World.runs(context, "t1")) == context.run_count

    refute Enum.any?(
             World.entities(context, "t1", "message"),
             &(&1["text"] == "Implement it again")
           )

    context
  end

  step "the MC stopped sending a message to {string} referring to plan {string} of {string} once it claimed the plan",
       %{args: [thread, plan, plan_thread]} = context do
    command = implementation(context, thread, "Implement it", plan_thread, plan)
    hook = {__MODULE__, :lose_after_claim, [World.thread_id(context, plan_thread), plan]}
    Application.put_env(:hal_c2, :streams_hook, hook)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :streams_hook) end)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:lose_after_claim, command["messageId"])
        HalC2.Orchestration.dispatch(Map.put(command, "commandId", "cmd-lost"))
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :lost_after_claim}, 5_000
    Application.delete_env(:hal_c2, :streams_hook)
    Map.put(context, :sent, command)
  end

  step "{string} does not have the message", %{args: [thread]} = context do
    refute StreamState.fetch(World.state(context, thread), "message", context.sent["messageId"])
    context
  end

  step "{string} has the message", %{args: [thread]} = context do
    assert %{"text" => "Implement it"} =
             StreamState.fetch(World.state(context, thread), "message", context.sent["messageId"])

    context
  end

  step "plan {string} records that message as the one that implemented it",
       %{args: [plan]} = context do
    recorded = World.state(context, context.plans[plan]).entities["plan"][plan]
    assert recorded["implementedByMessageId"] == context.sent["messageId"]
    context
  end

  # A streams hook: the dispatch that set `:lose_after_claim` dies at its first call
  # into a stream once its message has claimed the plan, before the message is sent.
  def lose_after_claim(plan_thread, plan, :ensured, _stream_id) do
    message_id = Process.get(:lose_after_claim)

    claimed =
      plan_thread
      |> HalC2.Streams.ensure()
      |> HalC2.Streams.Server.state()
      |> StreamState.fetch("plan", plan)

    if message_id && match?(%{"implementedByMessageId" => ^message_id}, claimed),
      do: exit(:lost_after_claim),
      else: :ok
  end

  def lose_after_claim(_plan_thread, _plan, _stage, _stream_id), do: :ok

  step "the client resends that message under a new command id", context do
    World.command(context, Map.delete(context.sent, "commandId"))
  end

  step "the resend is accepted", context do
    assert {:ok, _} = context.reply
    context
  end

  step "two devices send a message to {string} referring to plan {string} of {string} at once",
       %{args: [thread, plan, plan_thread]} = context do
    replies =
      for text <- ["Implement it here", "Implement it there"] do
        Task.async(fn -> implement(context, thread, text, plan_thread, plan).reply end)
      end
      |> Task.await_many()

    Map.put(context, :replies, replies)
  end

  step "one message is sent and the other fails with {string}",
       %{args: [message]} = context do
    assert [{:ok, _}, {:error, ^message, _}] =
             Enum.sort_by(context.replies, &(elem(&1, 0) == :error))

    sent =
      for %{"text" => "Implement it " <> _} <- World.entities(context, "t1", "message"), do: 1

    assert length(sent) == 1
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp codex(context) do
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, World.thread_id(context, "t1"))
    {pid, :sys.get_state(pid).conn}
  end

  defp dismiss(context) do
    World.command(context, %{
      "type" => "thread.user-input.dismiss",
      "threadId" => World.thread_id(context, "t1"),
      "requestId" => context.request
    })
  end

  # Codex's async question: an agent message carrying questions it does not wait on.
  defp ask_async(context, titles) do
    {_, runtime} = World.codex_runtime(context, "t1")
    item = "msg-async-#{System.unique_integer([:positive])}"

    notify(context, "item/completed", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => runtime.turn.native_turn_id,
      "item" => %{
        "type" => "agentMessage",
        "id" => item,
        "delivery" => "async",
        "text" => "",
        "questions" => for(title <- titles, do: %{"title" => title, "options" => ["Red", "Blue"]})
      }
    })

    context = Map.put(context, :request, "runtime-request:codex:async:" <> item)
    await_request(context, &(&1["status"] == "pending"))
    assert request(context, "t1")["responseCapability"] == %{"type" => "message"}
    context
  end

  # A question answered by message on a provider with no such questions of its own,
  # recorded as an adapter records one.
  defp plant_async(context, question) do
    id = "runtime-request:grok:async:q-#{System.unique_integer([:positive])}"
    node = "node:grok:async:" <> id

    context
    |> World.put_entity("t1", "turn-item", String.replace_prefix(node, "node:", "turn-item:"), %{
      "s" => %{
        "id" => String.replace_prefix(node, "node:", "turn-item:"),
        "type" => "user_input_request",
        "status" => "waiting",
        "runId" => context.running,
        "requestId" => id,
        "questions" => [
          %{
            "id" => "0",
            "header" => "Question",
            "question" => question,
            "options" => [%{"label" => "Red"}, %{"label" => "Blue"}]
          }
        ]
      }
    })
    |> World.put_entity("t1", "runtime-request", id, %{
      "s" => %{
        "id" => id,
        "nodeId" => node,
        "runId" => context.running,
        "kind" => "user_input",
        "status" => "pending",
        "responseCapability" => %{"type" => "message"},
        "createdAt" => World.iso_from_now(0),
        "resolvedAt" => nil
      }
    })
    |> Map.put(:request, id)
  end

  defp patch_questions(context, fun) do
    item = request_item(context)

    World.put_entity(context, "t1", "turn-item", item["id"], %{
      "s" => %{"questions" => Enum.map(item["questions"], fun)}
    })
  end

  defp answer_by_message(context, answers) do
    World.command(context, %{
      "type" => "runtime-request.respond",
      "threadId" => World.thread_id(context, "t1"),
      "requestId" => context.request,
      "answers" => answers
    })
  end

  defp answer_id(context), do: "async-answer:" <> context.request

  defp answer_message(context, thread) do
    id = answer_id(context)

    World.await_value(context, thread, &StreamState.fetch(&1, "message", id))
  end

  defp end_turn(context, status) do
    {_, runtime} = World.codex_runtime(context, "t1")

    notify(context, "turn/completed", %{
      "threadId" => runtime.native_thread_id,
      "turn" => %{"id" => runtime.turn.native_turn_id, "status" => status}
    })

    World.await_value(context, "t1", fn state ->
      StreamState.get(state, "run")[context.running]["status"] not in ["running", "queued"]
    end)

    context
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
      HalC2.Attachments.create_upload_url(%{
        "type" => "image",
        "name" => name,
        "mimeType" => "image/png",
        "sizeBytes" => 4
      })

    if stored?, do: :ok = HalC2.Attachments.store(token, "png!")
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

  # Keeps the command as `context.sent`, for a resend.
  defp implement(context, thread, text, plan_thread, plan) do
    command = implementation(context, thread, text, plan_thread, plan)
    context |> World.command(command) |> Map.put(:sent, command)
  end

  defp implementation(context, thread, text, plan_thread, plan) do
    %{
      "type" => "message.dispatch",
      "threadId" => World.thread_id(context, thread),
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => text,
      "attachments" => [],
      "sourcePlanRef" => %{"threadId" => World.thread_id(context, plan_thread), "planId" => plan}
    }
  end
end
