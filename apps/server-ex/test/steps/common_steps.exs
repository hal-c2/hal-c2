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

  # --- added by W1 ---
  # The thread a scenario is "looking at" is `context.current` (a title); steps
  # without a thread name act on it.

  step "the user is looking at a thread in {string}", %{args: [project]} = context do
    context =
      if Map.has_key?(context.projects, project),
        do: context,
        else: World.create_project(context, project)

    context
    |> World.create_thread("Current thread", project)
    |> Map.put(:current, "Current thread")
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a project with an open thread", context do
    context
    |> World.create_project("shop")
    |> World.create_thread("Open thread", "shop")
    |> Map.put(:current, "Open thread")
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "the agent is working", context do
    World.working_thread(context, World.current(context))
  end

  step "the agent is working in {string}", %{args: [thread]} = context do
    World.working_thread(context, thread)
  end

  step "{string} is archived", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    {:ok, _} = T3.Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => id})
    World.await_row(id, &(&1["archivedAt"] != nil))
    context
  end

  # Used both to delete a thread and to observe that it was deleted.
  step "{string} is deleted", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    unless World.thread(context, thread)["deletedAt"],
      do: {:ok, _} = T3.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})

    assert World.thread(context, thread)["deletedAt"] != nil
    context
  end

  step "the user interrupts the turn", context do
    title = World.current(context)

    run =
      context |> World.runs(title) |> Enum.find(&(&1["status"] in ~w(starting running waiting)))

    assert run, "no running turn in #{title}"

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, title),
        "runId" => run["id"]
      })

    Map.put(context, :interrupted_run, run["id"])
  end

  step "the turn stops", context do
    run_id = context[:interrupted_run]

    World.await_stream(context, World.current(context), fn state ->
      Enum.any?(
        T3.StreamState.list(state, "run"),
        &(&1["status"] == "interrupted" and run_id in [nil, &1["id"]])
      )
    end)

    context
  end

  step "the running turn is interrupted", context do
    World.await_stream(
      context,
      World.current(context),
      &Enum.any?(T3.StreamState.list(&1, "run"), fn run -> run["status"] == "interrupted" end)
    )

    context
  end

  step "the agent asks to run {string}", %{args: [command]} = context do
    World.request_from_agent(context, "approve run: #{command}")
  end

  step "a client archives {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    {{:ok, _}, context} = World.dispatch(context, %{"type" => "thread.archive", "threadId" => id})
    World.await_row(id, &(&1["archivedAt"] != nil))
    context
  end

  # A thread by that name, else a project; the reply is kept as `context.reply`.
  step "a client deletes {string}", %{args: [name]} = context do
    delete(context, name)
  end

  step "the user deletes {string}", %{args: [name]} = context do
    delete(context, name)
  end

  step ~r/^a client snoozes "(?<thread>[^"]+)" until (?<until>.+)$/,
       %{args: [thread, until]} = context do
    until = World.local_time(context, until)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.snooze",
        "threadId" => World.thread_id(context, thread),
        "snoozedUntil" => until
      })

    World.await_row(World.thread_id(context, thread), &(&1["snoozedUntil"] == until))
    Map.put(context, :snoozed_until, until)
  end

  step "a client unsnoozes {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    {{:ok, _}, context} =
      World.dispatch(context, %{"type" => "thread.unsnooze", "threadId" => id})

    World.await_row(id, &(&1["snoozedUntil"] == nil))
    context
  end

  step "a client marks {string} unread", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    {{:ok, _}, context} =
      World.dispatch(context, %{"type" => "thread.mark-unread", "threadId" => id})

    World.await_row(id, &(&1["lastVisitedAt"] == nil))
    context
  end

  step "{string} is active again", %{args: [thread]} = context do
    row = World.row(context, thread)
    assert row["snoozedUntil"] == nil
    assert row["archivedAt"] == nil
    assert row["settledOverride"] in [nil, "active"]
    context
  end

  # Into a draft ("a new thread titled ...") this launches the thread with a title
  # asked for, as the web client does; otherwise it is sent to the current thread.
  step "the user sends {string}", %{args: [text]} = context do
    case context[:draft] do
      nil ->
        title = World.current(context)
        {{:ok, _}, context} = World.send_message(context, title, text)
        context

      draft ->
        context = if context[:title_generator], do: context, else: World.title_generator(context)

        {{:ok, _}, context} =
          World.launch_thread(context, nil, text, %{"title" => draft, "generateTitle" => true})

        Map.merge(context, %{current: draft, draft: nil})
    end
  end

  # Forks the source's latest finished run into a thread with that name.
  step "{string} is a fork of {string}", %{args: [fork, source]} = context do
    context = World.fork_thread(context, source, fork)

    assert World.thread(context, fork)["lineage"]["parentThreadId"] ==
             World.thread_id(context, source)

    context
  end

  # Worktree setup of the thread in `context.current`; `context.worktree_path` is the
  # worktree it made.
  step "the user cancels the setup", context do
    {reply, context} =
      World.call(context, "worktreeSetup.cancel", %{
        "threadId" => World.thread_id(context, World.current(context))
      })

    Map.put(context, :reply, reply)
  end

  step "the worktree is removed", context do
    assert is_binary(context.worktree_path)
    refute File.exists?(context.worktree_path)
    context
  end

  step "the setup is not cancelled", context do
    assert {:ok, %{"cancelled" => false}} = context.reply
    assert World.setup_result(context, World.current(context))["phase"] == "done"
    context
  end

  step "the setup fails with {string}", %{args: [message]} = context do
    assert %{"phase" => "failed", "error" => ^message} =
             World.setup_result(context, World.current(context))

    context
  end

  step "the setup fails with a message starting {string}", %{args: [prefix]} = context do
    assert %{"phase" => "failed", "error" => error} =
             World.setup_result(context, World.current(context))

    assert String.starts_with?(error, prefix), error
    context
  end

  step "the agent does not start", context do
    title = World.current(context)
    World.setup_result(context, title)
    assert World.codex_requests(context, "turn/start") == []
    assert Enum.all?(World.runs(context, title), &(&1["status"] in ["failed", "cancelled"]))
    context
  end

  defp delete(context, name) do
    case {(context[:threads] || %{})[name], (context[:projects] || %{})[name]} do
      {id, _} when is_binary(id) ->
        {{:ok, _} = reply, context} =
          World.dispatch(context, %{"type" => "thread.delete", "threadId" => id})

        World.await_row(id, &(&1["deletedAt"] != nil))
        Map.put(context, :reply, reply)

      {nil, %{id: id}} ->
        {reply, context} =
          World.dispatch(context, %{"type" => "project.delete", "projectId" => id})

        Map.put(context, :reply, reply)

      _ ->
        flunk("no thread or project #{inspect(name)} in this scenario")
    end
  end
end
