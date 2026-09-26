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

  # --- added by W6 ---

  # An HTTP answer a previous step stored as `context.response` (`{status, headers, body}`,
  # as `T3.Test.Node.http/4` returns it).
  step ~r/^the node answers (?<status>not found|unauthorized|service unavailable|bad gateway|\d{3})$/,
       %{args: [status]} = context do
    expected =
      case status do
        "not found" -> 404
        "unauthorized" -> 401
        "service unavailable" -> 503
        "bad gateway" -> 502
        code -> String.to_integer(code)
      end

    assert {^expected, _headers, _body} = context.response
    context
  end

  # A second node joins this one; `context.peer` is `%{name, pid, environment, home}`.
  step "a cluster of two nodes", context do
    {node, peer} = Node.cluster(context.node)
    %{context | node: node, clients: %{}} |> Map.put(:peer, peer)
  end

  # `filesystem.browse`. A `~` path is browsed in a scratch home (never the user's real
  # one) holding dev/{api,tests,tools}, the hidden dev/.tmp and dev/.trash, and a file
  # dev/todo.txt; `context.user_home` names it.
  step "a client browses {string}", %{args: [partial]} = context do
    context =
      if String.starts_with?(partial, "~") do
        home = Node.tmp_dir(context.node, "user-home")

        for dir <- ~w(dev/tools dev/tests dev/api dev/.tmp dev/.trash),
            do: File.mkdir_p!(Path.join(home, dir))

        File.write!(Path.join(home, "dev/todo.txt"), "")
        World.put_app_env(:user_home, home)
        Map.put(context, :user_home, home)
      else
        context
      end

    {reply, context} = World.call(context, "filesystem.browse", %{"partialPath" => partial})
    Map.put(context, :reply, reply)
  end

  # Stops the server a previous step started as `context.dev_server`.
  step "that server stops", context do
    Process.unlink(context.dev_server)
    :ok = Supervisor.stop(context.dev_server)
    context
  end

  # --- storage cleanup (settings/storage.feature, node/platform/background-and-cleanup.feature)

  # A thread on its own worktree (`World.worktree_thread/3`, as `context.worktree`)
  # in a state a cleanup rule looks for.
  step ~r/^a thread's worktree (?<condition>has been idle for \d+ days|belongs to a merged pull request|has a merged pull request|belongs to a deleted thread|has a branch already in the default branch|has no commits beyond the default branch)$/,
       %{args: [condition]} = context do
    context = World.worktree_thread(context, "worktree thread")
    thread = context.worktree.thread

    cond do
      String.starts_with?(condition, "has been idle for") ->
        [days] = Regex.run(~r/\d+/, condition)
        World.backdate_thread(context, thread, World.days(String.to_integer(days)))

      String.ends_with?(condition, "merged pull request") ->
        pr = %{
          "number" => 7,
          "title" => "Worktree thread",
          "url" => "https://github.com/acme/api/pull/7",
          "baseRefName" => "main",
          "headRefName" => context.worktree.branch,
          "state" => "MERGED",
          "isDraft" => false,
          "updatedAt" => World.iso_from_now(0)
        }

        World.gh_on_path(context, [
          %{"args" => ["pr list", context.worktree.branch], "stdout" => [pr]}
        ])

        context

      condition == "belongs to a deleted thread" ->
        id = World.thread_id(context, thread)
        {:ok, _} = T3.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
        World.await_row(id, &(&1["deletedAt"] != nil))
        context

      # The new branch is where `main` is: nothing on it beyond the default branch.
      true ->
        assert World.git!(context.worktree.path, ~w(rev-parse HEAD)) ==
                 World.git!(context.worktree.repo, ~w(rev-parse origin/main))

        context
    end
  end

  step "the node sweeps storage", context do
    World.storage_cleanup()
    :ok = T3.StorageCleanup.sweep()
    context
  end

  step "the worktree is removed", context do
    path = context.worktree.path
    refute File.exists?(path), "#{path} is still there"
    refute World.git!(context.worktree.repo, ~w(worktree list --porcelain)) =~ path
    context
  end

  # With `context.control` (a worktree the same sweep had to remove), also that the
  # sweep did run.
  step "the worktree is kept", context do
    assert File.dir?(context.worktree.path)

    # Still a checkout (whatever branch a scenario moved it to), not a leftover directory.
    assert World.git!(context.worktree.path, ~w(rev-parse --is-inside-work-tree)) == "true"

    if control = context[:control], do: refute(File.exists?(control), "the sweep did not run")
    context
  end
end
