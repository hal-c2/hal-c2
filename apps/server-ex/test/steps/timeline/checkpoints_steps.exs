defmodule HalC2.Steps.Timeline.Checkpoints do
  @moduledoc """
  Steps for `features/timeline/checkpoints.feature`. The thread works in a git
  worktree of its own (so files can be restored), and its three turns each write one
  file with the fake Codex: turn 1 "a.txt", turn 2 "b.txt", turn 3 "c.txt".
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Node.World

  @files ["a.txt", "b.txt", "c.txt"]

  step "a thread in {string} with three finished turns", %{args: [project]} = context do
    root = World.project(context, project).root
    worktree = HalC2.Test.Node.tmp_dir(context.node, "rewind")
    World.git!(root, ["worktree", "add", "-q", "-b", "rewind", worktree])

    context
    |> World.create_thread("Rewind thread", project, %{
      "worktreePath" => worktree,
      "branch" => "rewind"
    })
    |> Map.merge(%{current: "Rewind thread", worktree: worktree})
    |> World.finished_turns("Rewind thread", Enum.map(@files, &"write #{&1}"))
  end

  step "the agent finishes a turn that changed {string}", %{args: [path]} = context do
    # The user has something staged of their own while the agent works.
    File.write!(Path.join(context.worktree, "README.md"), "# staged by the user\n")
    World.git!(context.worktree, ~w(add README.md))
    staged = World.git!(context.worktree, ~w(diff --cached))
    File.mkdir_p!(Path.join(context.worktree, Path.dirname(path)))

    context
    |> World.finished_turns(context.current, ["write #{path}"])
    |> Map.merge(%{staged: staged, changed: path})
  end

  step "a checkpoint of the workspace is recorded for that turn", context do
    state = World.stream(context, context.current)
    run = context |> World.runs(context.current) |> List.last()
    checkpoint = Enum.find(StreamState.list(state, "checkpoint"), &(&1["runId"] == run["id"]))

    assert %{"status" => "ready", "ref" => ref, "files" => files} = checkpoint
    assert Enum.any?(files, &(&1["path"] == context.changed))

    assert World.git!(context.worktree, ["show", "#{ref}:#{context.changed}"]) ==
             "write #{context.changed}"

    context
  end

  step "the user's staged changes are left as they were", context do
    assert World.git!(context.worktree, ~w(diff --cached)) == context.staged
    context
  end

  step "the thread is rolled back to the checkpoint after turn 1", context do
    assert {{:ok, _}, context} = rollback(context, 1, true)
    context
  end

  step "turns 2 and 3 are no longer shown", context do
    state = World.stream(context, context.current)
    [first, second, third] = World.runs(context, context.current)

    assert [first["status"], second["status"], third["status"]] == [
             "completed",
             "rolled_back",
             "rolled_back"
           ]

    shown = MapSet.new(HalC2.Projection.Timeline.local_items(state), & &1["runId"])
    assert MapSet.member?(shown, first["id"])
    refute MapSet.member?(shown, second["id"])
    refute MapSet.member?(shown, third["id"])
    context
  end

  # Codex cuts its paginated history before the first dropped turn.
  step "the agent no longer remembers turns 2 and 3", context do
    assert [%{"beforeTurnId" => "native-turn-2"}] = World.codex_requests(context, "thread/revert")
    context
  end

  step ~r/^the thread is rewound to before turn 2 (?<files>and files restored|without restoring files)$/,
       %{args: [files]} = context do
    assert {{:ok, _}, context} = rollback(context, 1, files == "and files restored")
    context
  end

  step "the conversation ends at turn 1", context do
    assert ["completed", "rolled_back", "rolled_back"] =
             context |> World.runs(context.current) |> Enum.map(& &1["status"])

    context
  end

  step "the workspace matches the end of turn 1", context do
    assert Enum.filter(@files, &File.exists?(Path.join(context.worktree, &1))) == ["a.txt"]
    context
  end

  step "the workspace keeps every change made by turns 2 and 3", context do
    assert Enum.filter(@files, &File.exists?(Path.join(context.worktree, &1))) == @files
    context
  end

  step "the agent is still working", context do
    World.working_thread(context, context.current)
  end

  step "another thread shares the workspace", context do
    World.create_thread(context, "Neighbour", nil, %{"worktreePath" => context.worktree})
  end

  step "the thread has no provider conversation", context do
    World.patch_thread(context, context.current, %{
      "activeProviderThreadId" => nil,
      "updatedAt" => HalC2.Orchestration.Entities.now()
    })
  end

  step "the user rewinds to before turn 2 and restores files", context do
    {reply, context} = rollback(context, 1, true)
    Map.put(context, :reply, reply)
  end

  step "the rewind is refused with {string}", %{args: [message]} = context do
    assert {:error, ^message, _} = context.reply
    context
  end

  step "the checkpoint after turn 1 has gone stale", context do
    scope = HalC2.Checkpoint.scope_id(World.thread_id(context, context.current))
    id = HalC2.Checkpoint.checkpoint_id(scope, 1)

    World.put_entity(context, context.current, "checkpoint", id, %{"s" => %{"status" => "stale"}})
    |> World.patch_thread(context.current, %{"updatedAt" => HalC2.Orchestration.Entities.now()})
    |> Map.put(:stale_checkpoint, id)
  end

  step "the user rewinds to it", context do
    {reply, context} = rollback(context, 1, false)
    Map.put(context, :reply, reply)
  end

  step "the rewind is refused because the checkpoint cannot be restored", context do
    message = "Checkpoint #{context.stale_checkpoint} cannot be restored."
    assert {:error, ^message, _} = context.reply

    assert ["completed", "completed", "completed"] =
             context |> World.runs(context.current) |> Enum.map(& &1["status"])

    context
  end

  defp rollback(context, ordinal, restore) do
    scope = HalC2.Checkpoint.scope_id(World.thread_id(context, context.current))

    World.dispatch(context, %{
      "type" => "checkpoint.rollback",
      "threadId" => World.thread_id(context, context.current),
      "scopeId" => scope,
      "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, ordinal),
      "restoreFiles" => restore
    })
  end
end
