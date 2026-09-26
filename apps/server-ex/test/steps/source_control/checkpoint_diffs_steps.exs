defmodule T3.Steps.SourceControl.CheckpointDiffs do
  @moduledoc """
  The Background names the finished turns; they are played (through the fake Codex,
  `World.run_turn/3`) the first time a step needs them, so a `Given` can still say
  what one of them did. `context.turns` maps a turn number to its message text and
  to an optional edit made while it runs.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.World

  @branch_refs ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"]
  @cart "if (total) {\n  pay(total)\n}\n"

  defp git(context, args), do: World.git!(context.cwd, args)

  # Plays the planned turns once, in order.
  defp played(%{played: true} = context), do: context

  defp played(context) do
    context.turns
    |> Enum.sort()
    |> Enum.reduce(context, fn {_n, {text, edit}}, context ->
      if edit, do: edit.()
      World.run_turn(context, context.thread_title, text)
    end)
    |> Map.put(:played, true)
  end

  defp thread_id(context), do: World.thread_id(context, context.thread_title)

  defp diff(context, from, to, extra \\ %{}) do
    context = played(context)

    {reply, context} =
      World.call(
        context,
        "orchestration.getTurnDiff",
        Map.merge(
          %{"threadId" => thread_id(context), "fromTurnCount" => from, "toTurnCount" => to},
          extra
        )
      )

    Map.put(context, :reply, reply)
  end

  defp patch(context) do
    assert {:ok, %{"diff" => diff}} = context.reply
    diff
  end

  defp checkpoints(context) do
    T3.Streams.Server.state(T3.Streams.ensure(thread_id(context)))
    |> T3.StreamState.list("checkpoint")
    |> Enum.sort_by(& &1["appRunOrdinal"])
  end

  step "a connected environment with the thread {string} in the git project {string}",
       %{args: [thread, project]} = context do
    context = World.create_project(context, project)
    root = World.project(context, project).root

    context
    |> World.create_thread(thread, project)
    |> Map.merge(%{cwd: root, thread_title: thread})
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "the agent finished {int} turns in {string} that each edited files",
       %{args: [n, title]} = context do
    assert title == context.thread_title
    World.commit!(context.cwd, %{"src/cart.ts" => @cart}, "Add cart")
    turns = Map.new(1..n, &{&1, {"write turn#{&1}.ts", nil}})

    Map.merge(context, %{
      turns: turns,
      branches_before: git(context, @branch_refs),
      head_before: git(context, ~w(rev-parse HEAD))
    })
  end

  step "the user lists the checkpoints of {string}", %{args: [title]} = context do
    assert title == context.thread_title
    context = played(context)
    Map.put(context, :checkpoints, checkpoints(context))
  end

  step "there is one checkpoint for each of the {int} turns", %{args: [n]} = context do
    # The baselines before a run (the checkout before turn 1) belong to no turn.
    turns = Enum.filter(context.checkpoints, &is_integer(&1["appRunOrdinal"]))
    assert Enum.map(turns, & &1["appRunOrdinal"]) == Enum.to_list(1..n)

    for checkpoint <- turns do
      assert checkpoint["status"] == "ready"
      name = "turn#{checkpoint["appRunOrdinal"]}.ts"
      assert Enum.map(checkpoint["files"], & &1["path"]) == [name]
      assert git(context, ["show", "#{checkpoint["ref"]}:#{name}"]) =~ "write #{name}"
    end

    context
  end

  step "the user's branches and staging area are unchanged by them", context do
    assert git(context, @branch_refs) ==
             context.branches_before

    assert git(context, ~w(rev-parse HEAD)) == context.head_before
    assert git(context, ~w(diff --cached --name-only)) == ""
    # The turns' files are still the user's untracked work.
    assert git(context, ~w(status --porcelain)) =~ "?? turn1.ts"
    context
  end

  step "the user opens the diff of turn {int}", %{args: [n]} = context do
    diff(context, n - 1, n)
  end

  step "only the changes the agent made during turn {int} are shown", %{args: [n]} = context do
    diff = patch(context)
    assert diff =~ "+++ b/turn#{n}.ts"

    for {other, _} <- context.turns, other != n, do: refute(diff =~ "turn#{other}.ts")
    context
  end

  step "the user opens all changes of {string}", %{args: [title]} = context do
    assert title == context.thread_title
    context = played(context)

    {reply, context} =
      World.call(context, "orchestration.getFullThreadDiff", %{
        "threadId" => thread_id(context),
        "toTurnCount" => map_size(context.turns)
      })

    Map.put(context, :reply, reply)
  end

  step "the changes of turns {int} to {int} are shown together against the checkout before turn {int}",
       %{args: [first, last, _]} = context do
    diff = patch(context)

    for n <- first..last do
      assert diff =~ "new file mode"
      assert diff =~ "+++ b/turn#{n}.ts"
    end

    # The committed cart was there before turn 1, so it is not a change.
    refute diff =~ "src/cart.ts"
    context
  end

  # The edit lands while turn 3 is the latest: after turn 2's checkpoint, before turn 3's.
  step "turn {int} only re-indented {string}", %{args: [n, path]} = context do
    file = Path.join(context.cwd, path)
    edit = fn -> File.write!(file, String.replace(File.read!(file), "  pay", "    pay")) end
    put_in(context, [:turns, n], {"say hello", edit})
  end

  step "no changes are shown", context do
    assert patch(context) == ""
    context
  end

  step "asking to keep whitespace shows the re-indentation", context do
    assert {:ok, %{"fromTurnCount" => from, "toTurnCount" => to}} = context.reply
    context = diff(context, from, to, %{"ignoreWhitespace" => false})
    diff = patch(context)
    assert diff =~ "+++ b/src/cart.ts"
    assert diff =~ "-  pay(total)"
    assert diff =~ "+    pay(total)"
    context
  end

  step "turn {int} only answered a question", %{args: [n]} = context do
    put_in(context, [:turns, n], {"what is the tax rate", nil})
  end

  step "the user is told there are no changes", context do
    assert {:ok, %{"diff" => "", "toTurnCount" => turn}} = context.reply
    # The turn did finish, with a checkpoint of its own.
    assert Enum.any?(checkpoints(context), &(&1["appRunOrdinal"] == turn))
    context
  end

  step "turn {int} is still running", %{args: [n]} = context do
    context = played(context)
    id = thread_id(context)
    :ok = T3.Streams.subscribe(id, self(), nil)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "message.dispatch",
        "threadId" => id,
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => "wait for me",
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await_running(id, n)
    context
  end

  step "the user is told turn {int} has no checkpoint", %{args: [n]} = context do
    assert {:error, error, _} = context.reply
    assert error =~ "turn #{n} has no checkpoint"
    context
  end

  step "{string} was imported with checkpoints made by the previous server",
       %{args: [title]} = context do
    assert title == context.thread_title
    id = "imported-#{System.unique_integer([:positive])}"
    scope = T3.Checkpoint.scope_id(id)
    project = World.project(context, "shop").id

    # The previous server's hidden refs: a commit of the whole checkout per turn.
    refs =
      for ordinal <- 0..3 do
        if ordinal > 0,
          do: File.write!(Path.join(context.cwd, "old#{ordinal}.ts"), "old #{ordinal}\n")

        ref = T3.Checkpoint.ref(scope, ordinal)
        snapshot!(context.cwd, ref)
        {ordinal, ref}
      end

    source = Path.join(T3.Test.Node.tmp_dir(context.node, "previous-server"), "state.sqlite")
    write_node_log(source, node_events(id, project, scope, refs, context.cwd))
    {:ok, _} = T3.Import.V2.run(source, T3.Store, only: [id])

    context
    |> put_in([:threads, title], id)
    |> Map.merge(%{played: true, turns: Map.new(1..3, &{&1, {"imported", nil}}), imported: refs})
  end

  step "turn {int}'s changes are shown", %{args: [n]} = context do
    diff = patch(context)
    assert diff =~ "+++ b/old#{n}.ts"
    refute diff =~ "old#{n - 1}.ts"
    context
  end

  defp await_running(id, ordinal) do
    running? =
      T3.Streams.Server.state(T3.Streams.ensure(id))
      |> T3.StreamState.list("run")
      |> Enum.any?(&(&1["ordinal"] == ordinal and &1["status"] == "running"))

    unless running? do
      receive do
        {:t3_stream, ^id, _} -> await_running(id, ordinal)
      after
        10_000 -> flunk("turn #{ordinal} never started")
      end
    end
  end

  # Commits the whole checkout to `ref` through a scratch index, as a checkpoint does.
  defp snapshot!(cwd, ref) do
    index = Path.join(System.tmp_dir!(), "t3-import-index-#{System.unique_integer([:positive])}")
    env = [{"GIT_INDEX_FILE", index}]

    try do
      {_, 0} = System.cmd("git", ~w(add -A), cd: cwd, env: env)
      {tree, 0} = System.cmd("git", ~w(write-tree), cd: cwd, env: env)
      {commit, 0} = System.cmd("git", ["commit-tree", String.trim(tree), "-m", ref], cd: cwd)
      World.git!(cwd, ["update-ref", ref, String.trim(commit)])
    after
      File.rm(index)
    end
  end

  defp node_events(id, project, scope, refs, cwd) do
    thread = %{"id" => id, "title" => "Tax work", "projectId" => project}

    scope_entity = %{
      "id" => scope,
      "threadId" => id,
      "kind" => "root_run",
      "cwd" => cwd
    }

    turns =
      for {ordinal, ref} <- refs, ordinal > 0 do
        run = %{
          "id" => "run-#{ordinal}",
          "threadId" => id,
          "ordinal" => ordinal,
          "status" => "completed"
        }

        checkpoint = %{
          "id" => T3.Checkpoint.checkpoint_id(scope, ordinal),
          "threadId" => id,
          "scopeId" => scope,
          "runId" => run["id"],
          "appRunOrdinal" => ordinal,
          "ordinalWithinScope" => ordinal,
          "ref" => ref,
          "status" => "ready",
          "files" => []
        }

        [{"thread", id, "run.updated", run}, {"thread", id, "checkpoint.captured", checkpoint}]
      end

    [
      {"thread", id, "thread.created", thread},
      {"thread", id, "checkpoint-scope.created", scope_entity}
      | List.flatten(turns)
    ]
  end

  defp write_node_log(path, events) do
    alias Exqlite.Sqlite3
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE orchestration_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
        event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
      """)

    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json, occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, 2)"
      )

    for {agg, stream, type, payload} <- events do
      :ok =
        Sqlite3.bind(stmt, [agg, stream, type, JSON.encode!(payload), "2026-09-01T12:00:00.000Z"])

      :done = Sqlite3.step(db, stmt)
    end

    Sqlite3.close(db)
  end
end
