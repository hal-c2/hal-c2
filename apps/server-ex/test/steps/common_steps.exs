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

  # --- added by W7 ---

  step "a node with a project {string} rooted at a git repository", %{args: [title]} = context do
    World.create_project(context, title)
  end

  step "thread {string} exists in {string}", %{args: [thread, project]} = context do
    World.create_thread(context, thread, project)
  end

  # Shared by node/orchestration/thread-organization.feature (setup: the user settled
  # it) and auto-settle.feature (outcome after a sweep, flagged by `:settle_swept`).
  step "thread {string} is settled", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    unless context[:settle_swept] do
      {{:ok, _}, _} = World.dispatch(context, %{"type" => "thread.settle", "threadId" => id})
    end

    World.await_row(id, &(&1["settledOverride"] == "settled"))
    context
  end

  step "a client unsettles {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    {{:ok, _}, context} =
      World.dispatch(context, %{"type" => "thread.unsettle", "threadId" => id})

    World.await_row(id, &(&1["settledOverride"] == "active"))
    Map.put(context, :settle_swept, false)
  end

  # Shared with other node/orchestration features; the step before it leaves the
  # RPC reply in `context.reply` as `{:error, message, detail}`.
  step "it fails with {string}", %{args: [message]} = context do
    assert {:error, ^message, _detail} = context.reply
    context
  end

  # Refusals of commands and RPCs alike: the step before it leaves the reply in
  # `context.reply`, `{:error, message, detail}` from a socket or `{:error, message}`
  # from `T3.Orchestration.dispatch/1`.
  # Ids in the refusal are compared by the names the scenario gives them (`World.named/2`).
  step "the command fails with {string}", %{args: [message]} = context do
    case context.reply do
      {:error, actual, _detail} -> assert World.named(context, actual) == message
      {:error, actual} -> assert World.named(context, actual) == message
      other -> flunk("expected a refusal, got #{inspect(other)}")
    end

    context
  end

  step "the user sends {string} to {string}", %{args: [text, thread]} = context do
    context |> World.send_turn(thread, text) |> Map.put(:run_title, thread)
  end

  # The transcript a client shows (`T3.Projection.Timeline`), in `context.timeline`.
  step "a client reads the timeline of {string}", %{args: [thread]} = context do
    resolve = fn id -> T3.Streams.Server.state(T3.Streams.ensure(id)) end

    Map.put(
      context,
      :timeline,
      T3.Projection.Timeline.visible_items(World.state(context, thread), resolve)
    )
  end

  # Also used by node/orchestration/threads.feature.
  step "thread {string} is titled {string}", %{args: [thread, title]} = context do
    assert World.thread(context, thread)["title"] == title
    context
  end

  # Also used by node/orchestration/threads.feature: the reply is in `context.reply`.
  step "a client deletes {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    {reply, context} = World.dispatch(context, %{"type" => "thread.delete", "threadId" => id})
    Map.put(context, :reply, reply)
  end

  # Shared with node/orchestration/queue-and-steering.feature and runs.feature: some
  # run of the scenario's thread (`context.thread`) for message `text` has started
  # (it may have finished already) and is out of the queue.
  step "a run for {string} starts", %{args: [text]} = context do
    World.await_state(context, context.thread, fn state ->
      messages = T3.StreamState.get(state, "message")

      Enum.any?(T3.StreamState.list(state, "run"), fn run ->
        run["status"] in ~w(starting running waiting completed) and
          run["queuePosition"] == nil and messages[run["userMessageId"]]["text"] == text
      end)
    end)

    context
  end

  # Shared with node/orchestration/runs.feature: the scenario's run (`context.running`),
  # else the latest run of `context.thread`, ends with `status`.
  step ~r/^the run is (?<status>failed|interrupted)$/, %{args: [status]} = context do
    World.await_state(context, context.thread, fn state ->
      runs = T3.StreamState.list(state, "run")

      run =
        if context[:running],
          do: Enum.find(runs, &(&1["id"] == context.running)),
          else: Enum.max_by(runs, & &1["ordinal"], fn -> nil end)

      run["status"] == status
    end)

    context
  end

  # Shared with node/orchestration/mcp-thread-tools.feature, projections.feature and
  # the threads features: the thread is archived (a running turn keeps running), or,
  # after it was archived, still is.
  step "{string} is archived", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    # As an outcome ("... is archived" after an archive) it only checks.
    if World.row(context, thread)["archivedAt"] == nil do
      {:ok, _} =
        T3.Orchestration.dispatch(%{
          "type" => "thread.archive",
          "commandId" => "cmd-archive-#{System.unique_integer([:positive])}",
          "threadId" => id
        })
    end

    World.await_row(id, &(&1["archivedAt"] != nil))
    context
  end
end
