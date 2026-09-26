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

  # --- added by W11 ---

  # Turns and text generation on the scenario's provider (`context.provider`) and
  # thread (`context.thread`), as the provider features set them up.

  step "a new thread needs a title", context do
    Map.put(
      context,
      :title_result,
      T3.TextGeneration.thread_title(World.project(context).root, "Fix the login form")
    )
  end

  step "the user is asked to approve it", context do
    request = T3.Test.FakeAcp.await_request(context)
    assert request["status"] == "pending"
    assert request["kind"] in ~w(command file-change file-read permission)

    for {key, value} <- context[:expected_request] || %{},
        do: assert(request[key] == value, "#{key} was #{inspect(request[key])}")

    Map.put(context, :request, request)
  end

  step "the user stops the turn", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    context
  end

  step "OpenCode asks to run a command", context do
    T3.Test.FakeAcp.send_message(context, "please run a command")
  end

  step "the user enables Grok", context do
    {_, context} = T3.Test.FakeAcp.open_config(context)
    T3.Test.FakeAcp.enable(context, "grok")
  end

  step "Grok writes it with every tool refused", context do
    assert {:ok, %{"title" => "Fake title"}} = context.title_result
    T3.Test.FakeAcp.assert_tools_refused(context)
    context
  end

  step "OpenCode writes it with every tool refused", context do
    assert {:ok, %{"title" => "Fake title"}} = context.title_result
    T3.Test.FakeAcp.assert_tools_refused(context)
    context
  end

  # Probes the scenario's provider again, as the settings panel's refresh does.
  step "the user refreshes provider status", context do
    input =
      if context[:provider],
        do: %{"instanceId" => context.provider, "refreshModels" => true},
        else: %{"refreshModels" => true}

    {result, context} = World.call!(context, "server.refreshProviders", input)
    Map.put(context, :providers, result["providers"])
  end

  # The provider list a client receives on its config subscription.
  step "the user opens the provider list", context do
    T3.Test.FakeAcp.services()
    {_, context} = T3.Test.FakeAcp.open_config(context)
    context
  end

  step "the plan is shown as a proposed plan", context do
    plan =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        state
        |> T3.StreamState.list("plan")
        |> Enum.find(&(&1["kind"] == "proposed_plan" and &1["status"] == "active"))
      end)

    if expected = context[:expected_plan], do: assert(plan["markdown"] == expected)
    Map.put(context, :plan, plan)
  end

  # Implementing sends a message that names the plan; that completes it.
  step "the user can implement it", context do
    thread_id = World.thread_id(context, context.thread)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => "Implement the plan.",
        "attachments" => [],
        "sourcePlanRef" => %{"threadId" => thread_id, "planId" => context.plan["id"]}
      })

    World.await_stream(thread_id, fn state ->
      T3.StreamState.get(state, "plan")[context.plan["id"]]["status"] == "completed"
    end)

    context
  end

  # The tool went ahead: the turn finished without a pending approval, and an
  # agent played by `T3.Test.FakeAcp` ran it without asking the user.
  step "it is allowed without asking", context do
    state = T3.Test.FakeAcp.await_run(context, "completed")
    refute Enum.any?(T3.StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
    if context[:fakes], do: T3.Test.FakeAcp.assert_allowed(context)
    context
  end

  step ~r/^the user answers (allow once|allow for the session|decline|cancel)$/,
       %{args: [answer]} = context do
    decision =
      %{
        "allow once" => "accept",
        "allow for the session" => "acceptForSession",
        "decline" => "decline",
        "cancel" => "cancel"
      }[answer]

    request = context[:request] || T3.Test.FakeAcp.await_request(context)
    context = T3.Test.FakeAcp.respond(context, request["id"], %{"decision" => decision})
    Map.put(context, :decision, decision)
  end

  # The access modes the scenario's provider offers (`supportedRuntimeModes`).
  step "auto is not offered", context do
    modes = T3.Test.FakeAcp.find(context.providers, context.provider)["supportedRuntimeModes"]
    assert [_ | _] = modes
    refute "auto" in modes
    context
  end

  # What a client reads to show a thread: its provider in the provider list.
  step "the user opens the thread", context do
    {_, context} = T3.Test.FakeAcp.open_config(context)
    context
  end

  step "the user switches the thread to full access", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.runtime-mode.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "runtimeMode" => "full-access"
      })

    context
  end

  # The agent's tool waits on the user: a pending approval in the thread.
  step "it is asked for approval", context do
    request = T3.Test.FakeAcp.await_request(context)
    assert request["status"] == "pending"
    Map.put(context, :request, request)
  end

  # --- added by W13 ---

  # The provider list after the node read every provider's quota again
  # (`T3.ProviderUsageLimits`). Codex and Claude probe only their test fakes: a
  # scenario that sets none has them missing, never the machine's own CLIs.
  step "the user opens the limits view", context do
    T3.Test.FakeAcp.services()

    for key <- [:codex_command, :claude_command], Application.get_env(:t3, key) == nil do
      Application.put_env(:t3, key, ["t3-test-no-#{key}"])
      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, key) end)
    end

    Node.ensure(T3.ProviderUsageLimits)
    :ok = T3.ProviderUsageLimits.refresh()
    {providers, context} = T3.Test.FakeAcp.open_config(context)
    Map.put(context, :providers, providers)
  end

  # A provider's own subagent: a subagent node under the run's root node, with its
  # turn item, and its work (the prompt, then its answer) in a child thread of this
  # one, forked from that node. `:subagent_prompt` / `:subagent_answer` in the context,
  # when set, are the texts the child thread must hold.
  step "the subagent's work is grouped under the step that started it", context do
    thread_id = World.thread_id(context, context.thread)

    state =
      World.await_stream(thread_id, fn state ->
        if Enum.any?(T3.StreamState.list(state, "subagent"), &(&1["status"] == "completed")),
          do: state
      end)

    [task] = T3.StreamState.list(state, "subagent")
    run = T3.StreamState.get(state, "run")[task["runId"]]
    node = T3.StreamState.get(state, "node")[task["id"]]
    assert %{"kind" => "subagent", "parentNodeId" => root} = node
    assert root == run["rootNodeId"] and task["parentNodeId"] == root

    assert [%{"nodeId" => node_id, "childThreadId" => child_id}] =
             state |> T3.StreamState.list("turn-item") |> Enum.filter(&(&1["type"] == "subagent"))

    assert node_id == task["id"] and child_id == task["childThreadId"]

    child = T3.Streams.Server.state(T3.Streams.ensure(child_id))

    assert %{
             "lineage" => %{"parentThreadId" => ^thread_id, "relationshipToParent" => "subagent"},
             "forkedFrom" => %{"nodeId" => ^node_id}
           } = T3.StreamState.get(child, "thread")[child_id]

    messages =
      child
      |> T3.StreamState.list("message")
      |> Enum.sort_by(& &1["createdAt"])
      |> Enum.map(&{&1["role"], &1["text"]})

    assert [{"user", prompt}, {"assistant", answer} | _] = messages
    if context[:subagent_prompt], do: assert(prompt == context.subagent_prompt)
    if context[:subagent_answer], do: assert(answer == context.subagent_answer)
    assert task["result"] == answer

    # The child's work is not the parent's: its answer is not in the parent thread.
    refute Enum.any?(T3.StreamState.list(state, "message"), &(&1["text"] == answer))
    context
  end

  # The thread works in the project root, which only an isolated worktree may reset:
  # this rewinds the conversation, as the node offers for a shared checkout.
  step "the user reverts to the end of the first turn", context do
    id = World.thread_id(context, context[:current_thread] || context.thread)
    scope = T3.Checkpoint.scope_id(id)

    reply =
      T3.Orchestration.dispatch(%{
        "type" => "checkpoint.rollback",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => id,
        "scopeId" => scope,
        "checkpointId" => T3.Checkpoint.checkpoint_id(scope, 1),
        "restoreFiles" => false
      })

    Map.put(context, :reply, reply)
  end
end
