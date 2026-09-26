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

  # --- added by W5 ---

  @git_actions %{
    "Commit" => "commit",
    "Push" => "push",
    "Create PR" => "create_pr",
    "Commit & push" => "commit_push",
    "Commit, push & PR" => "commit_push_pr",
    "Commit, push & create PR" => "commit_push_pr"
  }

  # Runs a git action by its menu label in the checkout under test (`context.cwd`).
  step "the user runs {string}", %{args: [label]} = context do
    action = @git_actions[label] || flunk("no git action is labelled #{inspect(label)}")
    extra = context[:git_action_input] || %{}
    {events, context} = World.git_action(context, context.cwd, action, extra)
    Map.put(context, :git_events, events)
  end

  # What the user was told: `context.told` when a step set it, else the failure of
  # the last git action (`context.git_events`) or RPC (`context.reply`).
  step "the user is told {string}", %{args: [message]} = context do
    said =
      cond do
        context[:told] ->
          List.wrap(context.told)

        match?([_ | _], context[:git_events]) ->
          last = List.last(context.git_events)
          [last["message"], get_in(last, ["result", "toast", "title"])]

        match?({:error, _, _}, context[:reply]) ->
          {:error, error, detail} = context.reply
          [error, (detail || %{})["detail"], (detail || %{})["message"]]

        true ->
          flunk("nothing was said; last reply: #{inspect(context[:reply])}")
      end

    assert Enum.any?(said, &(is_binary(&1) and &1 =~ message)),
           "expected #{inspect(message)} in #{inspect(said)}"

    context
  end

  # A client shows a thread of the project: it watches the project's checkout status.
  step "the user is looking at a thread in {string}", %{args: [title]} = context do
    World.watch_vcs(context, World.project(context, title).root)
  end

  # The branch picker of the checkout under test (`context.cwd`): `vcs.listRefs`.
  step "the user opens the branch list", context do
    {reply, context} = World.call(context, "vcs.listRefs", %{"cwd" => context.cwd})
    Map.put(context, :reply, reply)
  end

  # A second worktree of the checkout under test holds `branch`, made from HEAD when new.
  step "{string} is checked out in another worktree", %{args: [branch]} = context do
    path = T3.Test.Node.tmp_dir(context.node, "worktree")
    File.rmdir!(path)
    exists? = World.git!(context.cwd, ["branch", "--list", branch]) != ""
    args = if exists?, do: [path, branch], else: ["-b", branch, path]
    World.git!(context.cwd, ["worktree", "add", "-q" | args])
    Map.put(context, :other_worktree, path)
  end

  # Expanding a file of the working tree review (`review.getDiffFileContents`).
  step "the user expands {string}", %{args: [path]} = context do
    T3.Steps.SourceControl.Shared.expand_review_file(context, path)
  end

  # The scenario's node is the remote environment `name`; the default client is the
  # user's local one. Starts with no GitHub account believed yet.
  step "the user is connected to the local environment and the remote environment {string}",
       %{args: [name]} = context do
    T3.PullRequests.invalidate(%{})
    context = World.put_client(context, World.client(context))
    assert [{_node, %{"environmentId" => id}}] = T3.Shell.environments()
    assert id == context.node.environment
    Map.put(context, :remote, name)
  end

  # A `gh` that runs but has no account: `gh auth status` fails as it does signed out.
  step "the GitHub CLI is installed but not signed in", context do
    context
    |> World.fake_cli(["gh"])
    |> World.cli_rules([
      %{"cmd" => "gh", "args" => ["--version"], "stdout" => "gh version 2.81.0 (2025-10-01)\n"},
      %{
        "cmd" => "gh",
        "args" => ["auth status"],
        "stderr" => "You are not logged into any GitHub hosts. To log in, run: gh auth login\n",
        "exit" => 1
      },
      %{
        "cmd" => "gh",
        "args" => ["api user"],
        "stderr" => "To get started with GitHub CLI, please run:  gh auth login\n",
        "exit" => 1
      }
    ])
  end

  # Cancels whatever the scenario's Given put in progress: that step leaves a
  # `context.cancel` function (context -> context) saying how.
  step "the user cancels it", context do
    assert is_function(context[:cancel], 1), "nothing in this scenario can be cancelled"
    context.cancel.(context)
  end

  # A thread's worktree setup (`World.launch_in_worktree/4`): `context.setup_thread`
  # and the snapshots seen so far, `context.setup_snapshots`.
  step "the user cancels the setup", context do
    {reply, context} =
      World.call(context, "worktreeSetup.cancel", %{"threadId" => context.setup_thread})

    assert {:ok, %{"cancelled" => cancelled}} = reply
    Map.put(context, :setup_cancelled, cancelled)
  end

  step "the setup is not cancelled", context do
    assert context.setup_cancelled == false
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert snapshot["phase"] == "done"
    context
  end

  step "the setup fails with {string}", %{args: [message]} = context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert %{"phase" => "failed", "error" => ^message} = snapshot
    context
  end

  step "the setup fails with a message starting {string}", %{args: [message]} = context do
    {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert %{"phase" => "failed", "error" => error} = snapshot
    assert String.starts_with?(error, message), "the setup failed with #{inspect(error)}"
    context
  end

  # After a failed setup: the agent stage never ran and the thread's run ended
  # without a turn.
  step "the agent does not start", context do
    thread_id = context.setup_thread
    {last, context} = World.await_setup(context, &(&1["phase"] != "running"))
    assert World.setup_stage(last, "agent") == "pending"

    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))
    assert [%{"status" => "failed"}] = T3.StreamState.list(state, "run")
    refute Enum.any?(T3.StreamState.list(state, "message"), &(&1["role"] == "assistant"))
    context
  end

  # `context.worktree` is `%{path, root}`: the worktree the scenario is about and
  # the checkout it belongs to.
  step "the worktree is removed", context do
    %{path: path, root: root} = context.worktree
    refute File.exists?(path), "the worktree #{path} is still there"
    refute path in World.worktrees(root), "git still lists #{path}"
    context
  end
end
