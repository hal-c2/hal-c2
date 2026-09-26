defmodule HalC2.Steps.Orchestration.CheckpointsAndRollback do
  @moduledoc """
  Steps for `features/node/orchestration/checkpoints-and-rollback.feature`: real turns
  on the fake Codex CLI (`test/support/fake_codex.py`: "write NAME", "indent NAME",
  "fill NAME", "fail") capture real checkpoints in a git worktree of the thread's own.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Checkpoint
  alias HalC2.StreamState
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  # --- setup ---------------------------------------------------------------------

  step "thread {string} exists in {string} in its own worktree",
       %{args: [thread, project]} = context do
    {path, branch} = worktree(context, project, thread)

    context
    |> World.create_thread(thread, project, %{"worktreePath" => path, "branch" => branch})
    |> Map.put(:run_title, thread)
  end

  step "thread {string} works in a folder that is not a git repository",
       %{args: [thread]} = context do
    folder = Path.join(context.node.home, "plain-#{thread}")
    File.mkdir_p!(folder)
    refute Checkpoint.repo?(folder)

    context
    |> World.create_thread(thread, "demo", %{"worktreePath" => folder})
    |> Map.put(:run_title, thread)
  end

  step "thread {string} works in the project root", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{"worktreePath" => nil, "branch" => nil})
  end

  step "thread {string} also points at the worktree of {string}",
       %{args: [other, thread]} = context do
    path = World.thread(context, thread)["worktreePath"]
    World.create_thread(context, other, "demo", %{"worktreePath" => path})
  end

  step "the user has staged {string} in the worktree", %{args: [file]} = context do
    cwd = cwd(context, "t1")
    File.write!(Path.join(cwd, file), "staged change\n", [:append])
    World.git!(cwd, ["add", file])
    context
  end

  # A file where the ref namespace needs a directory makes every checkpoint write fail.
  step ~r/^capturing the (workspace|baseline) of "(?<thread>[^"]+)" fails$/,
       %{args: [_what, thread]} = context do
    common =
      String.trim(
        git(cwd(context, thread), ~w(rev-parse --path-format=absolute --git-common-dir))
      )

    File.write!(Path.join(common, "refs/hal-c2"), "")
    Map.put(context, :run_title, thread)
  end

  # --- runs ----------------------------------------------------------------------

  step "a run of {string} completes after changing {string}", %{args: [thread, file]} = context do
    complete(context, thread, "write #{file}")
  end

  step "a run of {string} completes", %{args: [thread]} = context do
    run = World.finish_turn(context, thread, "hello")
    assert run["status"] == "completed"
    Map.put(context, :run_title, thread)
  end

  step "a run of {string} completed and captured a checkpoint", %{args: [thread]} = context do
    context = complete(context, thread, "write a.txt")
    assert %{"status" => "ready"} = checkpoint(context, thread, 1)
    context
  end

  step "run {int} of {string} completed", %{args: [n, thread]} = context do
    complete_through(context, thread, n)
  end

  step "runs {int} and {int} of {string} completed with checkpoints",
       %{args: [_first, last, thread]} = context do
    complete_through(context, thread, last)
  end

  step "runs {int}, {int} and {int} of {string} completed with checkpoints",
       %{args: [_first, _second, last, thread]} = context do
    complete_through(context, thread, last)
  end

  step "run {int} of {string} failed", %{args: [n, thread]} = context do
    context = complete_through(context, thread, n - 1)
    assert %{"status" => "failed"} = World.finish_turn(context, thread, "fail")
    context
  end

  step "run {int} of {string} only re-indented a file", %{args: [n, thread]} = context do
    context = complete_through(context, thread, n - 1)
    File.write!(Path.join(cwd(context, thread), "notes.txt"), "one\ntwo\n")
    complete(context, thread, "indent notes.txt")
  end

  step "run {int} of {string} produced a diff larger than 10 MB",
       %{args: [n, thread]} = context do
    context = complete_through(context, thread, n - 1)
    complete(context, thread, "fill big.txt", 60_000)
  end

  step "run {int} of {string} created {string} and the ignored {string}",
       %{args: [n, thread, file, ignored]} = context do
    cwd = cwd(context, thread)
    File.write!(Path.join(cwd, ".gitignore"), Path.dirname(ignored) <> "/\n")
    World.git!(cwd, ~w(add .gitignore))
    World.git!(cwd, ~w(commit -q -m ignore))
    context = complete_through(context, thread, n - 1)
    # Written between the runs, so run `n`'s checkpoint is the first to see it.
    File.mkdir_p!(Path.join(cwd, Path.dirname(ignored)))
    File.write!(Path.join(cwd, ignored), "built\n")
    complete(context, thread, "write #{file}")
  end

  step "thread {string} is a fork of {string} after run {int}",
       %{args: [fork, thread, n]} = context do
    context = complete_through(context, thread, n)
    run = Enum.find(World.runs(context, thread), &(&1["ordinal"] == n))
    id = "th-#{fork}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-fork-#{id}",
        "createdBy" => "user",
        "creationSource" => "web",
        "sourceThreadId" => World.thread_id(context, thread),
        "targetThreadId" => id,
        "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
      })

    World.await_row(id, & &1)
    put_in(context, [:threads, fork], id)
  end

  step "the host loses power right after the capture", context do
    # Git flushes checkpoint objects and refs before publishing them; what is on
    # disk now is what a machine that lost power comes back to.
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  # --- checkpoints ---------------------------------------------------------------

  step "a ready checkpoint for that run exists under a hidden checkpoint ref", context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"
    assert "refs/hal-c2/orchestration-v2/checkpoints/" <> _ = checkpoint["ref"]
    cwd = cwd(context, context.run_title)
    assert Checkpoint.exists?(cwd, checkpoint["ref"])
    # Hidden: no branch or tag shows it.
    refute git(cwd, ~w(for-each-ref refs/heads refs/tags)) =~ "checkpoint"
    context
  end

  step "the checkpoint lists {string} with its added and removed line counts",
       %{args: [file]} = context do
    assert [%{"path" => ^file, "additions" => 1, "deletions" => 0}] =
             last_checkpoint(context)["files"]

    context
  end

  step "{string} is still the only staged change", %{args: [file]} = context do
    assert git(cwd(context, "t1"), ~w(diff --cached --name-only)) == file <> "\n"
    context
  end

  step "the run's checkpoint is missing", context do
    assert %{"status" => "missing"} = last_checkpoint(context)
    context
  end

  step "the run's checkpoint has status error", context do
    assert %{"status" => "error", "files" => []} = last_checkpoint(context)
    context
  end

  step "the turn starts anyway", context do
    World.await_runs(context, context.run_title, ["completed"])
    assert [[%{"text" => "Hi"} | _]] = World.provider_inputs(context)
    context
  end

  step "the checkpoint ref is readable after the node restarts", context do
    %{"ref" => ref} = checkpoint(context, "t1", 1)
    assert Checkpoint.exists?(cwd(context, "t1"), ref)

    {reply, context} =
      World.call(context, "orchestration.getTurnDiff", %{
        "threadId" => World.thread_id(context, "t1"),
        "fromTurnCount" => 0,
        "toTurnCount" => 1
      })

    assert {:ok, %{"diff" => diff}} = reply
    assert diff =~ "+++ b/a.txt"
    context
  end

  # --- diffs ---------------------------------------------------------------------

  step "a client asks for the diff from turn {int} to turn {int} of {string}",
       %{args: [from, to, thread]} = context do
    diff(context, thread, from, to)
  end

  step "a client asks for the full diff of {string} through turn {int}",
       %{args: [thread, to]} = context do
    {reply, context} =
      World.call(context, "orchestration.getFullThreadDiff", %{
        "threadId" => World.thread_id(context, thread),
        "toTurnCount" => to
      })

    Map.put(context, :reply, reply)
  end

  step "a client asks for the diff of turn {int}", %{args: [n]} = context do
    diff(context, context.run_title, n - 1, n)
  end

  step "asking again without ignoring whitespace shows the re-indentation", context do
    context = diff(context, context.run_title, 0, 1, %{"ignoreWhitespace" => false})
    assert {:ok, %{"diff" => patch}} = context.reply
    assert patch =~ "-one\n"
    assert patch =~ "+  one\n"
    context
  end

  step "the patch shows what run {int} changed", %{args: [n]} = context do
    patch = patch(context)
    assert patch =~ "+++ b/run-#{n}.txt"
    refute patch =~ "run-#{n - 1}.txt"
    context
  end

  step "the patch shows everything runs {int} and {int} changed", %{args: [a, b]} = context do
    patch = patch(context)
    assert patch =~ "+++ b/run-#{a}.txt"
    assert patch =~ "+++ b/run-#{b}.txt"
    context
  end

  step "the patch starts from the workspace before the first run of {string}",
       %{args: [thread]} = context do
    patch = patch(context)
    first = Enum.min_by(World.runs(context, thread), & &1["ordinal"])
    assert first["ordinal"] == 1
    assert patch =~ "+++ b/run-1.txt"
    assert patch =~ "+++ b/run-2.txt"
    refute patch =~ "README.md"
    context
  end

  step "the patch is empty", context do
    assert patch(context) == ""
    context
  end

  step "the request fails instead of sending the whole patch", context do
    assert {:error, message, _detail} = context.reply
    assert byte_size(message) < 10_000
    context
  end

  # --- rewinding -----------------------------------------------------------------

  step "the user rewinds {string} to the checkpoint of run {int}",
       %{args: [thread, n]} = context do
    rewind(context, thread, n)
  end

  step "the user rewinds {string} to run {int}", %{args: [thread, n]} = context do
    context |> ensure_later_runs(thread, n) |> rewind(thread, n)
  end

  step "the user rewinds {string} to run {int} restoring files", %{args: [thread, n]} = context do
    context |> ensure_later_runs(thread, n) |> rewind(thread, n, %{"restoreFiles" => true})
  end

  step "the user rewinds {string} to run {int} without restoring files",
       %{args: [thread, n]} = context do
    rewind(context, thread, n, %{"restoreFiles" => false})
  end

  step "the user rewinds {string} to the baseline checkpoint", %{args: [thread]} = context do
    rewind(context, thread, 0)
  end

  step "the user rewinds thread {string} to a checkpoint", %{args: [id]} = context do
    scope = Checkpoint.scope_id(id)

    {reply, context} =
      World.dispatch(context, %{
        "type" => "checkpoint.rollback",
        "threadId" => id,
        "scopeId" => scope,
        "checkpointId" => Checkpoint.checkpoint_id(scope, 1)
      })

    Map.put(context, :reply, reply)
  end

  step "the user rewinds it to run {int}", %{args: [n]} = context do
    rewind(context, context.run_title, n)
  end

  step "the user rewinds it to an early run", context do
    rewind(context, context.run_title, 1)
  end

  step ~r/^"(?<thread>[^"]+)" was rewound past runs (?<a>\d+) and (?<b>\d+)$/,
       %{args: [thread, _a, b]} = context do
    context = context |> complete_through(thread, String.to_integer(b)) |> rewind(thread, 1)
    assert {:ok, _} = context.reply
    context
  end

  step "every run after run {int} of {string} is already rolled back",
       %{args: [n, thread]} = context do
    context =
      context
      |> complete_through(thread, n + 1)
      |> rewind(thread, n, %{"restoreFiles" => false})

    assert {:ok, _} = context.reply
    Map.put(context, :rewind_requests, rewind_requests(context))
  end

  step "a Claude thread whose run 1 recorded no provider message", context do
    {path, branch} = worktree(context, "demo", "claude")

    context =
      context
      |> World.create_thread("claude", "demo", %{
        "worktreePath" => path,
        "branch" => branch,
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}
      })
      |> Map.put(:run_title, "claude")

    for text <- ["hello", "hello again"],
        do: assert(%{"status" => "completed"} = World.finish_turn(context, "claude", text))

    turn =
      context
      |> World.state("claude")
      |> StreamState.list("provider-turn")
      |> Enum.find(&(&1["ordinal"] == 1))

    assert get_in(turn, ["nativeTurnRef", "nativeId"])
    put(context, "claude", "provider-turn", turn["id"], %{"nativeTurnRef" => nil})
  end

  step "a Codex thread whose history needs more than one page to rewind", context do
    context = World.providers(context)
    ["env" | rest] = Application.get_env(:hal_c2, :codex_command)
    Application.put_env(:hal_c2, :codex_command, ["env", "FAKE_CODEX_PAGE_SIZE=1" | rest])
    complete_through(context, "t1", 3)
  end

  # The outline's situations. Checkpoint ids in its messages are the names it gives.
  # A thread of this feature (`context.run_title`, its worktree) first completes a
  # run to rewind to; elsewhere (runs, queue-and-steering) the turn just runs.
  step "{string} has a running turn", %{args: [thread]} = context do
    if context[:run_title] do
      context = complete_through(context, thread, 1)
      World.send_turn(context, thread, "wait for me")
      World.await_runs(context, thread, ["completed", "running"])
      context
    else
      World.running_turn(context, thread)
    end
  end

  step "the checkpoint of run {int} is missing", %{args: [n]} = context do
    context = complete_through(context, "t1", n)
    real = checkpoint(context, "t1", n)
    id = "checkpoint-#{n}"
    entity = %{real | "id" => id, "status" => "missing"}
    put(context, "t1", "checkpoint", id, entity)
    Map.put(context, :rewind_checkpoint, id)
  end

  step "the checkpoint is named with a different scope", context do
    context = complete_through(context, "t1", 1)
    entity = %{checkpoint(context, "t1", 1) | "id" => "checkpoint-1"}
    put(context, "t1", "checkpoint", "checkpoint-1", entity)
    Map.merge(context, %{rewind_checkpoint: "checkpoint-1", rewind_scope: "other-scope"})
  end

  step "{string} has no active provider thread", %{args: [thread]} = context do
    context = complete_through(context, thread, 1)
    World.patch_thread(context, thread, %{"activeProviderThreadId" => nil})
  end

  # --- rewind outcomes -----------------------------------------------------------

  step "runs {int} and {int} are rolled back and their root nodes too",
       %{args: [a, b]} = context do
    assert {:ok, _} = context.reply
    state = World.state(context, context.run_title)
    runs = runs_by_ordinal(state)

    for n <- [a, b] do
      run = runs[n]
      assert run["status"] == "rolled_back"
      assert StreamState.get(state, "node")[run["rootNodeId"]]["status"] == "rolled_back"
    end

    assert runs[a - 1]["status"] == "completed"
    context
  end

  step "the checkpoints of runs {int} and {int} are stale and their refs are deleted",
       %{args: [a, b]} = context do
    cwd = cwd(context, context.run_title)

    for n <- [a, b] do
      checkpoint = checkpoint(context, context.run_title, n)
      assert checkpoint["status"] == "stale"
      refute Checkpoint.exists?(cwd, checkpoint["ref"])
    end

    assert Checkpoint.exists?(cwd, checkpoint(context, context.run_title, a - 1)["ref"])
    context
  end

  step "the provider conversation continues from run {int}", %{args: [n]} = context do
    state = World.state(context, context.run_title)
    thread = StreamState.get(state, "thread")[World.thread_id(context, context.run_title)]
    provider_thread = StreamState.get(state, "provider-thread")[thread["activeProviderThreadId"]]
    assert provider_thread["lastRunOrdinal"] == n
    # Codex cut its history before the first dropped turn.
    assert get_in(provider_thread, ["nativeThreadRef", "nativeId"]) ==
             "native-thread-1-before-native-turn-#{n + 1}"

    context
  end

  step "the worktree matches the checkpoint of run {int}", %{args: [n]} = context do
    assert_worktree(context, checkpoint(context, context.run_title, n)["ref"])
  end

  step "the worktree matches the workspace before run {int}", %{args: [n]} = context do
    assert_worktree(context, checkpoint(context, context.run_title, n - 1)["ref"])
  end

  step "run {int} is rolled back", %{args: [n]} = context do
    assert {:ok, _} = context.reply
    runs = runs_by_ordinal(World.state(context, context.run_title))
    assert runs[n]["status"] == "rolled_back"
    for {ordinal, run} <- runs, ordinal < n, do: assert(run["status"] == "completed")
    context
  end

  step "the worktree is unchanged", context do
    assert tree(cwd(context, context.run_title)) == context.tree_before
    context
  end

  step "the file {string} is gone", %{args: [file]} = context do
    assert {:ok, _} = context.reply
    refute File.exists?(Path.join(cwd(context, context.run_title), file))
    context
  end

  step "{string} is still there", %{args: [file]} = context do
    assert File.read!(Path.join(cwd(context, context.run_title), file)) == "built\n"
    context
  end

  step "nothing is left staged", context do
    assert git(cwd(context, context.run_title), ~w(diff --cached --name-only)) == ""
    context
  end

  step "clients see the worktree's git status after the restore", context do
    assert {:ok, _} = context.reply
    cwd = cwd(context, context.run_title)
    local = HalC2.Vcs.local_status(cwd)
    refute Enum.any?(local["workingTree"]["files"], &(&1["path"] == "run-2.txt"))
    assert_receive {:halc2_vcs, ^cwd, %{"_tag" => "localUpdated", "local" => ^local}}, 5_000
    context
  end

  step "the items of runs {int} and {int} are not shown", %{args: [a, b]} = context do
    state = World.state(context, context.run_title)
    runs = runs_by_ordinal(state)
    hidden = MapSet.new([runs[a]["id"], runs[b]["id"]])
    items = StreamState.list(state, "turn-item")
    # They are still stored, only hidden.
    assert Enum.any?(items, &MapSet.member?(hidden, &1["runId"]))
    refute Enum.any?(context.timeline, &MapSet.member?(hidden, &1["runId"]))
    assert Enum.any?(context.timeline, &(&1["runId"] == runs[a - 1]["id"]))
    context
  end

  step "the command fails explaining that file restore requires an isolated worktree",
       context do
    assert {:error, "File restore requires an isolated worktree." <> _, _} = context.reply
    context
  end

  step "suggests rewinding the conversation without restoring files", context do
    {:error, message, _} = context.reply
    assert message =~ "Rewind the conversation without restoring files instead."
    context
  end

  step "the provider is not asked to drop any turns", context do
    assert {:ok, _} = context.reply
    assert context.rewind_requests != []
    assert rewind_requests(context) == context.rewind_requests
    context
  end

  step "the command fails explaining the provider could not roll back", context do
    assert {:error, "Failed to roll back codex provider thread " <> rest, _} = context.reply
    assert rest =~ "paginated"
    context
  end

  step "no run is marked rolled back", context do
    statuses = context |> World.runs(context.run_title) |> Enum.map(& &1["status"])
    assert statuses == ["completed", "completed", "completed"]
    context
  end

  # --- helpers -------------------------------------------------------------------

  # A git worktree of the project's repository on a branch named after the thread.
  defp worktree(context, project, thread) do
    root = World.project(context, project).root
    path = Path.join(context.node.home, "worktrees/#{thread}")
    World.git!(root, ["worktree", "add", "-q", "-b", thread, path])
    {path, thread}
  end

  defp cwd(context, thread) do
    entity = World.thread(context, thread)
    entity["worktreePath"] || World.project(context, "demo").root
  end

  defp complete(context, thread, text, timeout \\ 10_000) do
    assert %{"status" => "completed"} = World.finish_turn(context, thread, text, timeout)
    Map.put(context, :run_title, thread)
  end

  # Completes runs until the thread has `n`, each writing `run-<ordinal>.txt`.
  defp complete_through(context, thread, n) do
    done = length(World.runs(context, thread))

    Enum.reduce((done + 1)..n//1, Map.put(context, :run_title, thread), fn ordinal, context ->
      complete(context, thread, "write run-#{ordinal}.txt")
    end)
  end

  # Rewinding to run `n` needs a later run to rewind past.
  defp ensure_later_runs(context, thread, n) do
    if length(World.runs(context, thread)) > n,
      do: Map.put(context, :run_title, thread),
      else: complete_through(context, thread, n + 1)
  end

  defp checkpoint(context, thread, ordinal) do
    scope = Checkpoint.scope_id(World.thread_id(context, thread))

    StreamState.get(World.state(context, thread), "checkpoint")[
      Checkpoint.checkpoint_id(scope, ordinal)
    ]
  end

  defp last_checkpoint(context) do
    run = context |> World.runs(context.run_title) |> List.last()
    assert run["status"] == "completed"
    assert run["checkpointId"]
    StreamState.get(World.state(context, context.run_title), "checkpoint")[run["checkpointId"]]
  end

  defp runs_by_ordinal(state),
    do: state |> StreamState.list("run") |> Map.new(&{&1["ordinal"], &1})

  defp diff(context, thread, from, to, extra \\ %{}) do
    {reply, context} =
      World.call(
        context,
        "orchestration.getTurnDiff",
        Map.merge(
          %{
            "threadId" => World.thread_id(context, thread),
            "fromTurnCount" => from,
            "toTurnCount" => to
          },
          extra
        )
      )

    context |> Map.put(:reply, reply) |> Map.put(:run_title, thread)
  end

  defp patch(context) do
    assert {:ok, %{"diff" => patch}} = context.reply
    patch
  end

  # Rewinds as a client does. Clients watching the worktree's git status are
  # subscribed first; the worktree's tree before the rewind is kept to compare.
  defp rewind(context, thread, ordinal, extra \\ %{}) do
    id = World.thread_id(context, thread)
    cwd = cwd(context, thread)
    scope = context[:rewind_scope] || Checkpoint.scope_id(id)

    checkpoint =
      context[:rewind_checkpoint] || Checkpoint.checkpoint_id(Checkpoint.scope_id(id), ordinal)

    watch(cwd)
    before = tree(cwd)

    {reply, context} =
      World.dispatch(
        context,
        Map.merge(
          %{
            "type" => "checkpoint.rollback",
            "threadId" => id,
            "scopeId" => scope,
            "checkpointId" => checkpoint
          },
          extra
        )
      )

    Map.merge(context, %{reply: reply, run_title: thread, tree_before: before})
  end

  defp watch(cwd) do
    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
        id: HalC2.Vcs.Registry
      )
    )

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one},
        id: HalC2.Vcs.Supervisor
      )
    )

    HalC2.Vcs.Watch.subscribe(cwd, self())
  end

  # The tree of everything in the worktree (tracked and untracked, minus ignored),
  # captured the way checkpoints are.
  defp tree(cwd) do
    ref = "refs/hal-c2/test/now-#{System.unique_integer([:positive])}"
    :ok = Checkpoint.capture(cwd, ref)
    tree = git(cwd, ["rev-parse", "#{ref}^{tree}"])
    Checkpoint.delete_ref(cwd, ref)
    tree
  end

  defp assert_worktree(context, ref) do
    assert {:ok, _} = context.reply
    cwd = cwd(context, context.run_title)
    assert tree(cwd) == git(cwd, ["rev-parse", "#{ref}^{tree}"])
    context
  end

  # Sets fields of an entity in a thread's stream, creating it if need be.
  defp put(context, thread, kind, id, fields) do
    {:ok, _} =
      HalC2.Streams.commit(World.thread_id(context, thread), :thread, [
        {kind, id, %{"s" => fields}}
      ])

    context
  end

  defp rewind_requests(context),
    do: Enum.filter(World.codex_methods(context), &(&1 in ~w(thread/revert thread/rollback)))

  defp git(cwd, args) do
    {:ok, out} = HalC2.Git.ok(cwd, args)
    out
  end
end
