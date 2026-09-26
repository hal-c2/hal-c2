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

  # --- added by W4 (files) ---

  step "a client browses {string}", %{args: [partial]} = context do
    # `~` goes to the node as typed, with the scenario's home as its `$HOME`.
    real = T3.Test.Node.Host.path(context, partial)
    partial = if String.starts_with?(partial, "~"), do: partial, else: real
    {reply, context} = World.call(context, "filesystem.browse", %{"partialPath" => partial})

    listing =
      case reply do
        {:ok, %{"entries" => entries}} -> Enum.map(entries, & &1["name"])
        _ -> []
      end

    Map.merge(context, %{reply: reply, listing: listing})
  end

  step "the folder {string} exists", %{args: [path]} = context do
    real = T3.Test.Node.Host.path(context, path)

    # Before the scenario acts this sets the folder up; once a request was
    # answered it is the outcome to check.
    if Map.has_key?(context, :reply),
      do: assert(File.dir?(real), "#{path} does not exist"),
      else: File.mkdir_p!(real)

    context
  end

  # A step that shows the user a list of names puts them in `context.listing`.
  step "{string} is listed", %{args: [name]} = context do
    assert name in context.listing, "#{name} is not in #{inspect(context.listing)}"
    context
  end

  step "{string} is not listed", %{args: [name]} = context do
    refute name in context.listing, "#{name} is in #{inspect(context.listing)}"
    context
  end

  step "{string} is returned", %{args: [name]} = context do
    assert name in context.listing, "#{name} is not in #{inspect(context.listing)}"
    context
  end

  step "{string} is not returned", %{args: [name]} = context do
    refute name in context.listing, "#{name} is in #{inspect(context.listing)}"
    context
  end

  step "the node answers {string}", %{args: [message]} = context do
    assert {:error, error, _detail} = context.reply,
           "expected an error, got #{inspect(context.reply)}"

    assert error =~ message
    context
  end

  # After a failed worktree setup (`context.setup_thread`, see
  # files/project_scripts_and_actions_steps.exs): the agent stage never ran and the
  # thread's run ended without a turn.
  step "the agent does not start", context do
    thread_id = context.setup_thread
    last = List.last(context.setup_snapshots)
    assert Enum.find(last["stages"], &(&1["id"] == "agent"))["status"] == "pending"

    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))
    assert [%{"status" => "failed"}] = T3.StreamState.list(state, "run")
    refute Enum.any?(T3.StreamState.list(state, "message"), &(&1["role"] == "assistant"))
    context
  end

  # --- added by W4 (terminal) ---

  step "a cluster of two nodes", context do
    peer = T3.Test.Node.start_peer(context.node)
    assert peer in :erlang.nodes()
    Map.put(context, :peer, peer)
  end
end
