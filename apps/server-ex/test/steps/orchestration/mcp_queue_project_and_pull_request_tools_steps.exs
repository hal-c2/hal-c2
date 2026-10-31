defmodule HalC2.Steps.Orchestration.McpQueueProjectAndPullRequestTools do
  @moduledoc """
  Steps for `features/mc/orchestration/mcp-queue-project-and-pull-request-tools.feature`:
  the MCP tools for queued messages, pending questions, projects, worktree handoffs
  and pull request links. Tool outcomes go to `context.mcp_result` (see
  `HalC2.Steps.Orchestration.McpThreadTools`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @long String.duplicate("x", 20_000)
  @short "second queued message"

  # --- queues ----------------------------------------------------------------------

  step "thread {string} in {string} has a turn running and two queued messages",
       %{args: [thread, project]} = context do
    context =
      context |> World.create_thread(thread, project) |> World.send_turn(thread, "wait for it")

    World.await_row(World.thread_id(context, thread), &(&1["activeRunId"] != nil))

    for text <- [@long, @short] do
      {:ok, _} =
        HalC2.Orchestration.dispatch(
          World.message_command(context, thread, text, %{
            "dispatchMode" => %{"type" => "queue_after_active"}
          })
        )
    end

    state = World.await_runs(context, thread, ["running", "queued", "queued"])
    [active, first, second] = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
    Map.put(context, :queued, %{active: active["id"], first: first["id"], second: second["id"]})
  end

  step("the agent of {string} lists the queue of {string}", %{args: [caller, thread]} = context,
    do:
      tool(context, caller, "hal_c2_queue_list", %{"threadId" => World.thread_id(context, thread)})
  )

  step "it receives the two queued messages in the order they will start", context do
    assert {:ok, %{"items" => items, "nextCursor" => nil}} = context.mcp_result
    assert Enum.map(items, & &1["queuedRunId"]) == [context.queued.first, context.queued.second]
    context
  end

  step "each text is cut to 1,000 characters with a truncated flag", context do
    assert {:ok, %{"items" => [long, short]}} = context.mcp_result
    assert long["text"] == String.slice(@long, 0, 1_000) and long["truncated"] == true
    assert short["text"] == @short and short["truncated"] == false
    context
  end

  step "the agent of {string} reads a queued message of {string}",
       %{args: [caller, thread]} = context do
    tool(context, caller, "hal_c2_queue_read", %{
      "threadId" => World.thread_id(context, thread),
      "queuedRunId" => context.queued.first
    })
  end

  step "it receives its text up to 16,000 characters", context do
    assert {:ok, %{"text" => text, "truncated" => true}} = context.mcp_result
    assert text == String.slice(@long, 0, 16_000)
    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" (?<change>edits the text of|cancels|moves before the other|promotes to a steer of the turn) a queued message of "(?<thread>[^"]+)"$/,
       %{args: [caller, change, thread]} = context do
    id = World.thread_id(context, thread)
    run = context.queued.second

    {name, arguments} =
      case change do
        "edits the text of" ->
          {"hal_c2_queue_edit", %{"text" => "edited by an agent"}}

        "cancels" ->
          {"hal_c2_queue_cancel", %{}}

        "moves before the other" ->
          {"hal_c2_queue_reorder", %{"beforeRunId" => context.queued.first}}

        "promotes to a steer of the turn" ->
          {"hal_c2_queue_promote_to_steer", %{"targetRunId" => context.queued.active}}
      end

    context
    |> tool(caller, name, Map.merge(arguments, %{"threadId" => id, "queuedRunId" => run}))
    |> Map.put(:queue_change, {change, caller})
  end

  step "the queue of {string} shows the change", %{args: [thread]} = context do
    assert {:ok, %{"sequence" => _}} = context.mcp_result
    {change, caller} = context.queue_change
    %{first: first, second: second} = context.queued

    expected =
      case change do
        "edits the text of" ->
          [{first, String.slice(@long, 0, 1_000)}, {second, "edited by an agent"}]

        "cancels" ->
          [{first, String.slice(@long, 0, 1_000)}]

        "moves before the other" ->
          [{second, @short}, {first, String.slice(@long, 0, 1_000)}]

        # The message joins the running turn; the other one stays queued.
        "promotes to a steer of the turn" ->
          nil
      end

    if expected do
      assert {:ok, %{"items" => items}} =
               World.mcp_tool(context, caller, "hal_c2_queue_list", %{
                 "threadId" => World.thread_id(context, thread)
               })

      assert Enum.map(items, &{&1["queuedRunId"], &1["text"]}) == expected
    else
      state = World.state(context, thread)
      runs = StreamState.get(state, "run")
      assert runs[second]["status"] == "cancelled"
      message = StreamState.get(state, "message")[runs[second]["userMessageId"]]
      assert message["runId"] == context.queued.active
      assert runs[first]["status"] == "queued"
    end

    context
  end

  step "the first queued message of {string} has started", %{args: [thread]} = context do
    context = World.send_turn(context, thread, "say done")
    first = context.queued.first

    World.await_state(context, thread, fn state ->
      StreamState.get(state, "run")[first]["status"] != "queued"
    end)

    context
  end

  step "the agent of {string} cancels it", %{args: [caller]} = context do
    tool(context, caller, "hal_c2_queue_cancel", %{
      "threadId" => World.thread_id(context, "t2"),
      "queuedRunId" => context.queued.first
    })
  end

  # --- pending questions -----------------------------------------------------------

  step(
    "the agent of {string} asked the user a question and asked for an approval",
    %{args: [thread]} = context,
    do: ask(context, thread, "ask and approve", 2)
  )

  step("the agent of {string} asked the user a question", %{args: [thread]} = context,
    do: ask(context, thread, "ask the user", 1)
  )

  step(
    "the agent of {string} asked for approval to run a command",
    %{args: [thread]} = context,
    do: ask(context, thread, "approve the command", 1)
  )

  step "the agent of {string} lists the pending requests of {string}",
       %{args: [caller, thread]} = context do
    context
    |> tool(caller, "hal_c2_pending_request_list", %{
      "threadId" => World.thread_id(context, thread)
    })
    |> Map.put(:reader, caller)
  end

  step "only the question is listed", context do
    [question] = requests(context, "user_input")
    assert {:ok, %{"requestIds" => [id]}} = context.mcp_result
    assert id == question["id"]
    assert [_] = requests(context, "command")
    context
  end

  step "reading it returns its questions", context do
    [question] = requests(context, "user_input")

    assert {:ok,
            %{
              "requestId" => id,
              "questions" => [%{"id" => "color", "question" => "Which color?"}]
            }} =
             World.mcp_tool(context, context.reader, "hal_c2_pending_request_read", %{
               "threadId" => World.thread_id(context, context.asking),
               "requestId" => question["id"]
             })

    assert id == question["id"]
    context
  end

  step "the agent of {string} answers it", %{args: [caller]} = context do
    [question] = requests(context, "user_input")

    tool(context, caller, "hal_c2_pending_request_respond", %{
      "threadId" => World.thread_id(context, context.asking),
      "requestId" => question["id"],
      "answers" => %{"color" => "Red"}
    })
  end

  step "the turn of {string} continues with the answer", %{args: [thread]} = context do
    assert {:ok, %{"sequence" => _}} = context.mcp_result

    state =
      World.await_state(context, thread, fn state ->
        Enum.any?(
          StreamState.list(state, "message"),
          &String.starts_with?(&1["text"] || "", "answered ")
        )
      end)

    answer =
      Enum.find(
        StreamState.list(state, "message"),
        &String.starts_with?(&1["text"] || "", "answered ")
      )

    assert answer["text"] =~ "Red"
    context
  end

  step "the agent of {string} responds to that request", %{args: [caller]} = context do
    [approval] = requests(context, "command")

    tool(context, caller, "hal_c2_pending_request_respond", %{
      "threadId" => World.thread_id(context, context.asking),
      "requestId" => approval["id"],
      "answers" => %{"decision" => "accept"}
    })
  end

  # --- projects --------------------------------------------------------------------

  step "the agent of {string} lists the projects", %{args: [caller]} = context do
    context = World.create_project(context, "other")
    context = World.create_project(context, "gone")
    {:ok, _} = HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => "gone"})
    World.await_row("gone", &(&1["deletedAt"] != nil))

    context
    |> tool(caller, "hal_c2_project_list", %{"limit" => 1})
    |> Map.put(:reader, caller)
  end

  step "it receives every project of this MC that is not deleted, paged", context do
    assert {:ok, %{"projects" => [first], "nextCursor" => 1, "total" => 2}} = context.mcp_result

    assert {:ok, %{"projects" => [second], "nextCursor" => nil, "total" => 2}} =
             World.mcp_tool(context, context.reader, "hal_c2_project_list", %{
               "cursor" => 1,
               "limit" => 1
             })

    ids = Enum.sort([first["id"] || first["projectId"], second["id"] || second["projectId"]])
    assert ids == ["demo", "other"]
    context
  end

  step "reading project {string} fails with {string}", %{args: [project, message]} = context do
    assert {:error, "invalid_request", ^message} =
             World.mcp_tool(context, context.reader, "hal_c2_project_read", %{
               "projectId" => project
             })

    assert {:ok, %{"project" => _}} =
             World.mcp_tool(context, context.reader, "hal_c2_project_read", %{
               "projectId" => "demo"
             })

    context
  end

  # Stored projects, written as data: registering 120 real checkouts would
  # only slow the paging scenarios down.
  step "this MC has 120 projects that are not deleted", context do
    existing =
      Enum.count(
        HalC2.Shell.rows(),
        fn {{mc, _}, {kind, row}} -> mc == node() and kind == "project" and !row["deletedAt"] end
      )

    at = World.iso_from_now(0)
    root = World.project(context, "demo").root

    ids =
      for n <- Enum.to_list(1..max(120 - existing, 0)//1) do
        id = "paged-#{n}"

        project = %{
          "id" => id,
          "title" => id,
          "workspaceRoot" => root,
          "scripts" => [],
          "createdAt" => at,
          "updatedAt" => at,
          "deletedAt" => nil
        }

        {:ok, _} =
          HalC2.Streams.commit(id, :project, [{"project", id, HalC2.Patch.diff(nil, project)}])

        :ok = HalC2.Streams.flush_shell(id)
        id
      end

    if ids != [], do: World.await_row(List.last(ids), & &1)
    context
  end

  step(
    "the agent of {string} lists the projects without a limit",
    %{args: [caller]} = context,
    do: tool(context, caller, "hal_c2_project_list")
  )

  step "the agent of {string} lists the projects with a limit of {int}",
       %{args: [caller, limit]} = context do
    tool(context, caller, "hal_c2_project_list", %{"limit" => limit})
  end

  step "it receives {int} projects and a cursor for the rest", %{args: [count]} = context do
    assert {:ok, %{"projects" => projects, "nextCursor" => ^count, "total" => 120}} =
             context.mcp_result

    assert length(projects) == count
    context
  end

  step "the tool refuses the input as invalid", context do
    # Refused by the bound its input schema advertises (HalC2.Mcp.Schema).
    assert {:error, "invalid_request", message} = context.mcp_result
    assert message =~ ~r/ must (be|hold) /
    context
  end

  step "the agent of {string} creates a project for an existing folder",
       %{args: [caller]} = context do
    folder = HalC2.Test.Mc.tmp_dir(context.mc, "notes-app")

    context
    |> tool(caller, "hal_c2_project_create", %{"workspaceRoot" => folder})
    |> Map.put(:folder, folder)
  end

  step "the project exists with the folder name as its title", context do
    assert {:ok, project} = context.mcp_result
    id = project["id"] || project["projectId"]
    row = World.await_row(id, & &1)
    assert row["title"] == Path.basename(context.folder)
    assert row["workspaceRoot"] == context.folder
    context
  end

  step "the agent of {string} creates a project for the folder of {string}",
       %{args: [caller, project]} = context do
    tool(context, caller, "hal_c2_project_create", %{
      "workspaceRoot" => World.project(context, project).root
    })
  end

  step "the agent of {string} renames project {string} to {string}",
       %{args: [caller, project, title]} = context do
    context
    |> tool(caller, "hal_c2_project_update", %{
      "projectId" => World.project(context, project).id,
      "title" => title
    })
    |> Map.put(:renamed, project)
  end

  step "the project is called {string}", %{args: [title]} = context do
    assert {:ok, _} = context.mcp_result
    World.await_row(World.project(context, context.renamed).id, &(&1["title"] == title))
    context
  end

  step "the agent of {string} deletes project {string} without force",
       %{args: [caller, project]} = context do
    tool(context, caller, "hal_c2_project_delete", %{
      "projectId" => World.project(context, project).id
    })
  end

  step "project {string} has threads {string} and {string}",
       %{args: [project, first, second]} = context do
    context
    |> World.create_project(project)
    |> World.create_thread(first, project)
    |> World.create_thread(second, project)
  end

  step "the agent of {string} deletes project {string} with force",
       %{args: [caller, project]} = context do
    tool(context, caller, "hal_c2_project_delete", %{
      "projectId" => World.project(context, project).id,
      "force" => true
    })
  end

  step "{string} and {string} are deleted and project {string} is deleted",
       %{args: [first, second, project]} = context do
    assert {:ok, _} = context.mcp_result

    for thread <- [first, second],
        do: World.await_row(World.thread_id(context, thread), &(&1["deletedAt"] != nil))

    World.await_row(World.project(context, project).id, &(&1["deletedAt"] != nil))
    # The other project's threads stay.
    assert World.row(context, "t2")["deletedAt"] == nil
    context
  end

  step "the agent of {string} clones a repository", %{args: [caller]} = context do
    source = World.git_repo(context, "upstream")
    destination = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "clones"), "upstream")

    context
    |> tool(caller, "hal_c2_project_clone", %{
      "remoteUrl" => source,
      "destinationPath" => destination
    })
    |> Map.merge(%{clone: destination, cloner: caller})
  end

  step "the repository is cloned and can be registered as a project", context do
    assert {:ok, %{"cwd" => cwd}} = context.mcp_result
    assert cwd == context.clone
    assert File.read!(Path.join(cwd, "README.md")) == "# upstream\n"

    assert {:ok, project} =
             World.mcp_tool(context, context.cloner, "hal_c2_project_create", %{
               "workspaceRoot" => cwd
             })

    World.await_row(project["id"] || project["projectId"], &(&1["workspaceRoot"] == cwd))
    context
  end

  # --- worktrees -------------------------------------------------------------------

  step("the agent of {string} asks for its worktree status", %{args: [caller]} = context,
    do: tool(context, caller, "hal_c2_worktree_status")
  )

  step "it is not attached to a worktree", context do
    assert {:ok, %{"attached" => false, "worktreePath" => nil}} = context.mcp_result
    context
  end

  step "it receives the project's root and whether new worktrees start from origin", context do
    assert {:ok, result} = context.mcp_result
    assert result["projectWorkspaceRoot"] == World.project(context, "demo").root
    assert result["defaultStartFromOrigin"] == true
    context
  end

  step "the agent of {string} lists worktrees", %{args: [caller]} = context do
    root = World.project(context, "demo").root
    worktree = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "worktrees"), "topic")
    World.git!(root, ["worktree", "add", "-q", "-b", "topic", worktree])

    context
    |> tool(caller, "hal_c2_worktree_list")
    |> Map.put(:worktree, worktree)
  end

  step "it receives the branches and worktrees of the caller's workspace", context do
    assert {:ok, %{"refs" => refs}} = context.mcp_result

    assert %{"current" => true, "isRemote" => false} =
             main = Enum.find(refs, &(&1["name"] == "main"))

    assert Path.expand(main["worktreePath"]) == Path.expand(World.project(context, "demo").root)
    assert %{"current" => false} = topic = Enum.find(refs, &(&1["name"] == "topic"))
    assert Path.expand(topic["worktreePath"]) == Path.expand(context.worktree)
    context
  end

  step "project {string} has a setup script marked to run on new worktrees",
       %{args: [project]} = context do
    context = World.worktree_setup(context)
    id = World.project(context, project).id

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => id,
        "scripts" => [
          %{
            "id" => "setup",
            "name" => "Setup",
            # The shell prints "setup-42" only when it runs the line.
            "command" => "echo setup-$((6*7))",
            "icon" => "configure",
            "runOnWorktreeCreate" => true
          }
        ]
      })

    World.await_row(id, &match?([_], &1["scripts"]))
    context
  end

  step "the agent of {string} hands off to a worktree on new branch {string} with a continuation prompt",
       %{args: [caller, branch]} = context do
    context = with_origin(context)

    context
    |> handoff(caller, %{"branch" => branch, "continuationPrompt" => "carry on in the worktree"})
    |> Map.put(:branch, branch)
  end

  step "a worktree is created on {string} from origin's copy of the current branch",
       %{args: [branch]} = context do
    assert {:ok, result} = context.mcp_result
    assert result["branch"] == branch
    assert result["baseRef"] == "main"
    assert result["startedFromOrigin"] == true
    path = result["worktreePath"]
    assert World.git!(path, ~w(rev-parse --abbrev-ref HEAD)) == branch
    # The local main is a commit ahead of origin; the worktree starts from origin's.
    assert World.git!(path, ~w(rev-parse HEAD)) == context.origin_head

    refute World.git!(path, ~w(rev-parse HEAD)) ==
             World.git!(World.project(context, "demo").root, ~w(rev-parse main))

    context
  end

  step "{string} now works in that worktree on that branch", %{args: [thread]} = context do
    {:ok, %{"worktreePath" => path, "branch" => branch}} = context.mcp_result

    World.await_row(
      World.thread_id(context, thread),
      &(&1["worktreePath"] == path and &1["branch"] == branch)
    )

    context
  end

  step "the setup script runs in the thread's {string} terminal", %{args: [terminal]} = context do
    assert {:ok, %{"setupScript" => %{"status" => "started", "terminalId" => ^terminal}}} =
             context.mcp_result

    {:ok, snapshot} =
      HalC2.Terminal.attach(
        %{"threadId" => World.thread_id(context, "caller"), "terminalId" => terminal},
        self()
      )

    assert snapshot["cwd"] == elem(context.mcp_result, 1)["worktreePath"]
    await_output(snapshot["history"] || "", "setup-42")
    context
  end

  step "the continuation prompt is queued to start after the current turn", context do
    assert {:ok,
            %{"continuation" => %{"status" => "scheduled", "delivery" => "queue_after_active"}}} =
             context.mcp_result

    state = World.state(context, "caller")
    runs = state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
    assert [%{"status" => "running"}, %{"status" => "queued"} = queued] = runs

    assert StreamState.get(state, "message")[queued["userMessageId"]]["text"] ==
             "carry on in the worktree"

    context
  end

  step "the agent of {string} hands off to a worktree without a continuation prompt",
       %{args: [caller]} = context do
    context |> with_origin() |> handoff(caller, %{"branch" => "feature/y"})
  end

  step "the continuation is skipped", context do
    assert {:ok, %{"continuation" => %{"status" => "skipped"}}} = context.mcp_result
    assert [%{"status" => "running"}] = World.runs(context, "caller")
    context
  end

  step "the note says the conversation continues in the worktree on the next message", context do
    assert {:ok, %{"note" => note}} = context.mcp_result
    assert note =~ "continues inside the worktree when the thread receives its next message"
    context
  end

  step "the agent of {string} hands off to a worktree on new branch {string}",
       %{args: [caller, branch]} = context do
    arguments =
      case context[:handoff_path] do
        nil -> %{"branch" => branch}
        path -> %{"branch" => branch, "path" => path}
      end

    handoff(context, caller, arguments)
  end

  step "{string} already works in a worktree", %{args: [thread]} = context do
    root = World.project(context, "demo").root
    path = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "worktrees"), "existing")
    World.git!(root, ["worktree", "add", "-q", "-b", "existing", path])
    move(context, thread, path, "existing")
  end

  step "the requested path is relative", context do
    context |> with_origin() |> Map.put(:handoff_path, "worktrees/feature-x")
  end

  step "the project folder is not a git repository", context do
    File.rm_rf!(Path.join(World.project(context, "demo").root, ".git"))
    context
  end

  step "branch {string} already exists", %{args: [branch]} = context do
    World.git!(World.project(context, "demo").root, ["branch", branch])
    with_origin(context)
  end

  step "the project checkout is on a detached HEAD and no base is given", context do
    context = with_origin(context)
    World.git!(World.project(context, "demo").root, ~w(checkout -q --detach))
    context
  end

  step "origin cannot be fetched", context do
    root = World.project(context, "demo").root
    World.git!(root, ["remote", "add", "origin", Path.join(context.mc.home, "no-such-remote")])
    context
  end

  # A post-checkout hook holds `git worktree add` until the step lets it go, so the
  # thread can be moved while the handoff is creating its worktree.
  step "{string} is moved to another worktree while the handoff creates one",
       %{args: [thread]} = context do
    context = with_origin(context)
    root = World.project(context, "demo").root
    dir = HalC2.Test.Mc.tmp_dir(context.mc, "hook")
    [started, release] = for name <- ["started", "release"], do: Path.join(dir, name)
    for fifo <- [started, release], do: {_, 0} = System.cmd("mkfifo", [fifo])
    hook = Path.join([root, ".git", "hooks", "post-checkout"])
    File.write!(hook, "#!/bin/sh\necho started > '#{started}'\ncat '#{release}' > /dev/null\n")
    File.chmod!(hook, 0o755)

    task =
      Task.async(fn ->
        World.mcp_tool(context, thread, "hal_c2_worktree_handoff", %{"branch" => "feature/race"})
      end)

    # Blocks until the hook runs, inside the handoff's `git worktree add`.
    {"started\n", 0} = System.cmd("cat", [started])
    path = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "worktrees"), "elsewhere")
    context = move(context, thread, path, "elsewhere")
    Map.merge(context, %{handoff: task, release: release, race_root: root})
  end

  step "the handoff tries to point {string} at the new worktree", %{args: [thread]} = context do
    {_, 0} = System.cmd("sh", ["-c", "echo go > '#{context.release}'"])
    result = Task.await(context.handoff, 30_000)
    assert World.row(context, thread)["branch"] == "elsewhere"
    Map.put(context, :mcp_result, result)
  end

  step "the new worktree and its branch are removed again", context do
    root = context.race_root
    refute World.git!(root, ~w(worktree list)) =~ "feature/race"
    assert World.git!(root, ~w(branch --list feature/race)) == ""
    context
  end

  step "the handoff fails with code {string}", %{args: [code]} = context do
    assert {:error, ^code, _} = context.mcp_result
    context
  end

  # --- pull requests ---------------------------------------------------------------

  step ~r/^the agent of "(?<caller>[^"]+)" links a pull request by (?<reference>its URL|repository and number on the project's host|host, repository and number)$/,
       %{args: [caller, reference]} = context do
    arguments =
      case reference do
        "its URL" ->
          %{"url" => "https://github.com/acme/demo/pull/12"}

        "repository and number on the project's host" ->
          World.git!(
            World.project(context, "demo").root,
            ~w(remote add origin https://github.com/acme/demo.git)
          )

          %{"repository" => "acme/demo", "number" => 12}

        "host, repository and number" ->
          %{"host" => "github.com", "repository" => "acme/demo", "number" => 12}
      end

    tool(context, caller, "link_pull_request", arguments)
  end

  step "the pull request is linked to {string} as linked by an agent",
       %{args: [thread]} = context do
    assert {:ok,
            %{
              "host" => "github.com",
              "repository" => "acme/demo",
              "number" => 12,
              "url" => "https://github.com/acme/demo/pull/12",
              "alreadyLinked" => false
            }} = context.mcp_result

    assert [%{"number" => 12, "source" => "agent"}] = links(context, thread)
    context
  end

  step "{string} links pull request {int}", %{args: [thread, number]} = context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(pull_request(number), %{
          "type" => "thread.pull-request.link",
          "commandId" => "cmd-link-#{System.unique_integer([:positive])}",
          "threadId" => World.thread_id(context, thread),
          "source" => "manual"
        })
      )

    World.await_state(context, thread, fn _ -> links(context, thread) != [] end)
    context
  end

  step(
    "the agent of {string} links pull request {int} again",
    %{args: [caller, number]} = context,
    do: tool(context, caller, "link_pull_request", %{"url" => pull_request(number)["url"]})
  )

  step "the answer says it was already linked", context do
    assert {:ok, %{"alreadyLinked" => true, "number" => 12}} = context.mcp_result
    assert [%{"source" => "manual"}] = links(context, "caller")
    context
  end

  step "pull request {int} was dismissed from the stack of {string}",
       %{args: [number, thread]} = context do
    World.patch_thread(context, thread, %{
      "pullRequests" => [link(number, %{"source" => "stack-dismissed"})]
    })
  end

  step("the agent of {string} links pull request {int}", %{args: [caller, number]} = context,
    do: tool(context, caller, "link_pull_request", %{"url" => pull_request(number)["url"]})
  )

  step "it is linked again", context do
    assert {:ok, %{"alreadyLinked" => false}} = context.mcp_result

    World.await_state(context, "caller", fn _ ->
      match?([%{"number" => 12, "source" => "agent"}], links(context, "caller"))
    end)

    assert {:ok, %{"pullRequests" => [%{"number" => 12}]}} =
             World.mcp_tool(context, "caller", "list_thread_pull_requests")

    context
  end

  step "the agent of {string} unlinks pull request {int} that is not linked",
       %{args: [caller, number]} = context do
    tool(context, caller, "unlink_pull_request", %{"url" => pull_request(number)["url"]})
  end

  step "the answer says it was not linked", context do
    assert {:ok, %{"wasLinked" => false, "number" => 99, "repository" => "acme/demo"}} =
             context.mcp_result

    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" links (?<reference>a URL that is not a pull request|only a repository|a repository and number in a project with no remote)$/,
       %{args: [caller, reference]} = context do
    arguments =
      case reference do
        "a URL that is not a pull request" ->
          %{"url" => "https://github.com/acme/demo/issues/3"}

        "only a repository" ->
          %{"repository" => "acme/demo"}

        "a repository and number in a project with no remote" ->
          %{"repository" => "acme/demo", "number" => 12}
      end

    tool(context, caller, "link_pull_request", arguments)
  end

  step "{string} has pull requests 10, 11 and 12 stacked on each other and 12 dismissed",
       %{args: [thread]} = context do
    # 11 is based on 10's branch and 12 on 11's.
    links = [
      link(10, %{"snapshot" => snapshot("pr-10", "main")}),
      link(11, %{"snapshot" => snapshot("pr-11", "pr-10")}),
      link(12, %{"snapshot" => snapshot("pr-12", "pr-11"), "source" => "stack-dismissed"})
    ]

    World.patch_thread(context, thread, %{"pullRequests" => links})
  end

  step("the agent of {string} lists its pull requests", %{args: [caller]} = context,
    do: tool(context, caller, "list_thread_pull_requests")
  )

  step "it receives 10 and 11 and the chain they form", context do
    assert {:ok, %{"pullRequests" => pull_requests, "chains" => chains}} = context.mcp_result
    assert Enum.map(pull_requests, & &1["number"]) == [10, 11]

    assert Enum.map(pull_requests, & &1["stack"]) == [
             %{"kind" => "derived", "position" => 1, "size" => 2},
             %{"kind" => "derived", "position" => 2, "size" => 2}
           ]

    assert chains == [%{"kind" => "derived", "numbers" => [10, 11]}]
    context
  end

  # The project's repository identity as the shell carries it (its host's
  # provider kind and remote), with the checkout's origin to match.
  step ~r/^the project of "(?<caller>[^"]+)" is hosted on (?<kind>GitLab with a nested group|Forgejo served from a port and a path prefix|GitHub|GitLab)$/,
       %{args: [caller, kind]} = context do
    {provider, key, remote, repository} =
      case kind do
        "GitLab with a nested group" ->
          {"gitlab", "gitlab.com/group/sub/project", "git@gitlab.com:group/sub/project.git",
           "group/sub/project"}

        "Forgejo served from a port and a path prefix" ->
          {"forgejo", "forge.example/git/owner/repo",
           "http://forge.example:3000/git/owner/repo.git", "git/owner/repo"}

        "GitHub" ->
          {"github", "github.com/owner/repo", "git@github.com:owner/repo.git", "owner/repo"}

        "GitLab" ->
          {"gitlab", "gitlab.com/owner/repo", "git@gitlab.com:owner/repo.git", "owner/repo"}
      end

    identity = %{
      "canonicalKey" => key,
      "locator" => %{"source" => "git-remote", "remoteName" => "origin", "remoteUrl" => remote},
      "provider" => provider,
      "displayName" => repository
    }

    id = World.row(context, caller)["projectId"]
    World.git!(World.project(context, "demo").root, ["remote", "add", "origin", remote])

    {:ok, _} =
      HalC2.Streams.commit(id, :project, [
        {"project", id, %{"s" => %{"repositoryIdentity" => identity}}}
      ])

    :ok = HalC2.Streams.flush_shell(id)
    World.await_row(id, &(&1["repositoryIdentity"]["canonicalKey"] == key))
    Map.put(context, :hosted_repository, repository)
  end

  step "the agent of {string} links pull request {int} of its repository by number",
       %{args: [caller, number]} = context do
    tool(context, caller, "link_pull_request", %{
      "repository" => context.hosted_repository,
      "number" => number
    })
  end

  step "the agent of {string} links pull request {int} of {string} on {string}",
       %{args: [caller, number, repository, host]} = context do
    tool(context, caller, "link_pull_request", %{
      "host" => host,
      "repository" => repository,
      "number" => number
    })
  end

  step("the pull request is linked with the URL {string}", %{args: [url]} = context,
    do: linked_url(context, url)
  )

  step ~r/^the pull request is linked with the URL (?<url>https?:\/\/\S+)$/,
       %{args: [url]} = context do
    linked_url(context, url)
  end

  step "the project's own host is not used to guess its shape", context do
    assert {:ok, %{"host" => "other.example", "url" => url}} = context.mcp_result
    assert url =~ "/pull/"
    refute url =~ "merge_requests"
    context
  end

  step "{string} has a Forgejo pull request linked as host {string} with the URL {string}",
       %{args: [thread, host, url]} = context do
    %{repository: repository, number: number} =
      HalC2.Projection.PullRequests.parse_change_request_url(url)

    World.patch_thread(context, thread, %{
      "pullRequests" => [
        %{
          "host" => host,
          "repository" => repository,
          "number" => number,
          "url" => url,
          "source" => "manual",
          "linkedAt" => World.iso_from_now(0),
          "snapshot" => nil,
          "stack" => nil
        }
      ]
    })
  end

  step "the pull request is reported on host {string}", %{args: [host]} = context do
    assert {:ok, %{"pullRequests" => [%{"host" => ^host, "number" => 42}]}} = context.mcp_result
    context
  end

  # --- helpers ---------------------------------------------------------------------

  defp tool(context, caller, name, arguments \\ %{}),
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, name, arguments))

  # Lets the running turn and the queue finish, then starts a turn that asks.
  defp ask(context, thread, text, count) do
    context = World.send_turn(context, thread, "say done")

    World.await_state(
      context,
      thread,
      fn state ->
        Enum.all?(
          StreamState.list(state, "run"),
          &(&1["status"] in ~w(completed failed interrupted))
        )
      end,
      10_000
    )

    context = World.send_turn(context, thread, text)

    World.await_state(context, thread, fn state ->
      length(
        Enum.filter(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
      ) ==
        count
    end)

    Map.put(context, :asking, thread)
  end

  defp requests(context, kind) do
    context
    |> World.state(context.asking)
    |> StreamState.list("runtime-request")
    |> Enum.filter(&(&1["status"] == "pending" and &1["kind"] == kind))
  end

  defp handoff(context, caller, arguments),
    do: tool(context, caller, "hal_c2_worktree_handoff", arguments)

  # An origin holding main as it is now; local main then moves a commit ahead.
  defp with_origin(context) do
    root = World.project(context, "demo").root
    origin = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "origin"), "demo.git")
    World.git!(Path.dirname(origin), ["clone", "-q", "--bare", root, origin])
    World.git!(root, ["remote", "add", "origin", origin])
    World.git!(root, ~w(fetch -q origin))
    head = World.git!(root, ~w(rev-parse main))
    File.write!(Path.join(root, "local.txt"), "not pushed\n")
    World.git!(root, ~w(add local.txt))
    World.git!(root, ~w(commit -q -m local))
    Map.put(context, :origin_head, head)
  end

  # Points the thread at another worktree, as another handoff or the user would.
  defp move(context, thread, path, branch) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "commandId" => "cmd-move-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, thread),
        "worktreePath" => path,
        "branch" => branch
      })

    World.await_row(World.thread_id(context, thread), &(&1["worktreePath"] == path))
    context
  end

  defp await_output(seen, marker) do
    if String.contains?(seen, marker) do
      :ok
    else
      assert_receive {:hal_c2_terminal, _, %{"type" => "output", "data" => data}}, 10_000
      await_output(seen <> data, marker)
    end
  end

  defp pull_request(number),
    do: %{
      "host" => "github.com",
      "repository" => "acme/demo",
      "number" => number,
      "url" => "https://github.com/acme/demo/pull/#{number}"
    }

  defp link(number, fields) do
    number
    |> pull_request()
    |> Map.merge(%{
      "source" => "manual",
      "linkedAt" => World.iso_from_now(0),
      "snapshot" => nil,
      "stack" => nil
    })
    |> Map.merge(fields)
  end

  defp snapshot(head, base),
    do: %{
      "state" => "open",
      "title" => "PR on #{head}",
      "headBranch" => head,
      "baseBranch" => base,
      "isDraft" => false
    }

  defp links(context, thread),
    do: HalC2.Projection.PullRequests.of(World.thread(context, thread) || %{})

  defp linked_url(context, url) do
    assert {:ok, %{"url" => ^url, "number" => 42, "alreadyLinked" => false}} = context.mcp_result
    assert [%{"url" => ^url, "source" => "agent"}] = links(context, "caller")
    context
  end
end
