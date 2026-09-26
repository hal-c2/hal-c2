defmodule T3.Steps.Common do
  @moduledoc """
  Steps shared by more than one feature directory: the environment a scenario
  starts from, its projects and threads, and the node's lifecycle. A step that
  appears in several directories belongs here; one directory's steps live in
  its own file.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  # --- environments, projects and threads ---------------------------------------

  step "a connected environment", context do
    World.put_client(context, World.client(context))
  end

  step "a connected environment {string}", %{args: [label]} = context do
    context |> Map.put(:environment_label, label) |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the project {string}", %{args: [title]} = context do
    context |> World.create_project(title) |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment {string} with the project {string}",
       %{args: [label, title]} = context do
    context
    |> Map.put(:environment_label, label)
    |> World.create_project(title)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the projects {string} and {string}",
       %{args: [first, second]} = context do
    context
    |> World.create_project(first)
    |> World.create_project(second)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the idle thread {string} in the project {string}",
       %{args: [thread, project]} = context do
    context
    |> World.create_project(project)
    |> World.create_thread(thread, project)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the thread {string} in the project {string}",
       %{args: [thread, project]} = context do
    context
    |> World.create_project(project)
    |> World.create_thread(thread, project)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the idle thread {string}", %{args: [thread]} = context do
    context
    |> World.create_project("shop")
    |> World.create_thread(thread, "shop")
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step("a node", context, do: context)
  step("a running node", context, do: context)

  step "a node with a project {string}", %{args: [title]} = context do
    World.create_project(context, title)
  end

  step "two clients are connected to the node", context do
    context
    |> World.put_client("first", Node.connect(context.node))
    |> World.put_client("second", Node.connect(context.node))
  end

  step "a paired client", context do
    {:ok, access, _expires, _scopes} =
      T3.Auth.exchange(T3.Auth.create_pairing_token(context.node.store), %{"label" => "Phone"})

    {:ok, ticket, _} = T3.Auth.issue_ticket(access)
    client = Node.connect(context.node, "wsTicket=#{ticket}")
    context |> Map.put(:access_token, access) |> World.put_client("paired", client)
  end

  # --- the node's lifecycle ----------------------------------------------------------

  step "the node restarts", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "the node starts again", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "the node starts", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  # --- shared outcomes -----------------------------------------------------------------

  step "the request is refused with {string}", %{args: [message]} = context do
    assert {:error, error, _detail} = context.reply,
           "expected a refusal, got #{inspect(context.reply)}"

    assert error =~ message
    context
  end

  step "the socket stays open", context do
    client = T3.Test.WsClient.send_json(World.client(context), %{"t" => "ping"})
    {%{"t" => "pong"}, client} = T3.Test.WsClient.recv(client, 1_000)
    World.put_client(context, client)
  end

  # --- added by W8 ---
  # Orchestration features name threads by id ("t1") and read the latest command
  # reply from `context.reply` (see `World.command/2`).

  step "a node with a project {string} rooted at a git repository",
       %{args: [title]} = context do
    World.create_project(context, title)
  end

  step "thread {string} exists in {string}", %{args: [thread, project]} = context do
    World.named_thread(context, thread, project)
  end

  step "the command fails with {string}", %{args: [message]} = context do
    assert {:error, error, _} = context.reply, "expected a refusal, got #{inspect(context.reply)}"
    assert error =~ message
    context
  end

  step "it fails with {string}", %{args: [message]} = context do
    assert {:error, error, _} = context.reply, "expected a refusal, got #{inspect(context.reply)}"
    assert error =~ message
    context
  end

  step "the user sends {string} to {string}", %{args: [text, thread]} = context do
    context |> World.providers() |> Map.put(:thread, thread) |> World.send_message(thread, text)
  end

  # As a Given the thread is settled by the user; otherwise it asserts it is settled.
  step "thread {string} is settled", %{args: [thread]} = context do
    if World.given?(context) do
      id = World.thread_id(context, thread)

      context =
        World.command(context, %{"type" => "thread.settle", "threadId" => id})

      assert {:ok, _} = context.reply
      context |> Map.delete(:reply) |> Map.put(:thread, thread)
    else
      assert is_binary(World.thread(context, thread)["settledAt"])
      context
    end
  end

  step "a client unsettles {string}", %{args: [thread]} = context do
    context
    |> Map.put(:thread, thread)
    |> World.command(%{
      "type" => "thread.unsettle",
      "threadId" => World.thread_id(context, thread)
    })
  end

  # Runs are numbered as the orchestration features name them (`World.numbered_run/5`).
  step ~r/^run (?<n>\d+) of "(?<thread>[^"]+)" is (?<status>running|waiting)$/,
       %{args: [n, thread, status]} = context do
    context
    |> Map.put(:thread, thread)
    |> World.numbered_run(thread, String.to_integer(n), status)
  end

  step "a client reads the timeline of {string}", %{args: [thread]} = context do
    {items, context} = World.timeline(context, thread)
    Map.put(context, :timeline, items)
  end

  step "the user answers {string}", %{args: [answer]} = context do
    context = World.answer_questions(context, context.thread, answer)
    assert {:ok, _} = context.reply, "answering failed: #{inspect(context.reply)}"
    context
  end

  step "{string} has a running turn", %{args: [thread]} = context do
    World.running_turn(context, thread)
  end

  # The scenario's run: the running turn it started (`context.running`), else the latest.
  step ~r/^the run is (?<status>failed|interrupted)$/, %{args: [status]} = context do
    run_id = context[:running] || World.latest_run(context, context.thread)["id"]

    World.await_state(context, context.thread, fn state ->
      state.entities["run"][run_id]["status"] == status
    end)

    context
  end

  # The scenario's running turn (`context.running`) ends as interrupted.
  step "the running turn is interrupted", context do
    World.await_state(context, context.thread, fn state ->
      state.entities["run"][context.running]["status"] == "interrupted"
    end)

    context
  end

  # Five minutes on the node's clock: its five-minute timers fire, as their message
  # arrives (the idle session check, `T3.Orchestration.IdleSessions`).
  step "five minutes pass", context do
    pid = Node.ensure(T3.Orchestration.IdleSessions)
    send(pid, :check)
    # The check has run once the server answers the next call.
    _ = :sys.get_state(pid)
    context
  end
end
