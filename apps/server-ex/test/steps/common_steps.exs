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

  # --- added by W3 ---

  step "two clients are connected to the same environment", context do
    context
    |> World.put_client("first", Node.connect(context.node))
    |> World.put_client("second", Node.connect(context.node))
  end

  # --- added by W3-D ---

  # A follow-up while `context.running` (`%{thread, run}`) has a turn going, sent
  # as the composer sends it; the node steers or queues it by the provider.
  step "the user sends a follow-up message", context do
    message_id = "follow-up-#{System.unique_integer([:positive])}"

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "message.dispatch",
        "threadId" => context.running.thread,
        "messageId" => message_id,
        "text" => "look here instead",
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"},
        "deliveryIntent" => "auto"
      })

    Map.put(context, :follow_up, message_id)
  end

  step "the message joins the running turn", context do
    %{thread: thread_id, run: run_id} = context.running

    item =
      World.await_stream(thread_id, fn state ->
        Enum.find(
          T3.StreamState.list(state, "turn-item"),
          &(&1["messageId"] == context.follow_up)
        )
      end)

    assert %{"inputIntent" => "steer", "runId" => ^run_id} = item

    assert [%{"id" => ^run_id}] =
             T3.StreamState.list(T3.Streams.Server.state(T3.Streams.ensure(thread_id)), "run")

    context
  end

  # Node plugins (`T3.Plugins`) turned on or off as a client does; other features'
  # "enables"/"disables" steps can extend these by what the name refers to.
  step "the user enables {string}", %{args: [id]} = context do
    {result, context} = World.call!(context, "plugins.enable", %{"id" => id})
    Map.put(context, :reply, {:ok, result})
  end

  step "the user disables {string}", %{args: [id]} = context do
    {result, context} = World.call!(context, "plugins.disable", %{"id" => id})
    Map.put(context, :reply, {:ok, result})
  end

  # --- added by W3-A ---

  # HTTP steps leave `context.response` as `%{status: integer, ...}`.
  step "the node answers not found", context do
    assert %{status: 404} = context.response
    context
  end

  step "the node answers {int}", %{args: [status]} = context do
    assert context.response.status == status
    context
  end
end
