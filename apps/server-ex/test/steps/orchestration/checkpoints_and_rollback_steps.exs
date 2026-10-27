defmodule HalC2.Steps.Orchestration.CheckpointsAndRollback do
  @moduledoc """
  Steps for `features/mc/orchestration/checkpoints-and-rollback.feature`: real turns
  on the fake Codex CLI (`test/support/fake_codex.py`: "write NAME", "indent NAME",
  "fill NAME", "fail") capture real checkpoints in a git worktree of the thread's own.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Checkpoint
  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

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
    folder = Path.join(context.mc.home, "plain-#{thread}")
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
    %{context | mc: Mc.restart(context.mc), clients: %{}}
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

  step "the checkpoint ref is readable after the MC restarts", context do
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
    # A thread that moved to another machine is rewound there.
    if context[:move_to],
      do: HalC2.Steps.Threads.MovingBetweenMachines.rewind_moved(context, thread, n),
      else: context |> ensure_later_runs(thread, n) |> rewind(thread, n)
  end

  step "the user rewinds {string} to run {int} restoring files", %{args: [thread, n]} = context do
    context |> ensure_later_runs(thread, n) |> rewind(thread, n, %{"restoreFiles" => true})
  end

  # Git cannot write the worktree's index while another git process holds its lock.
  step "the user rewinds {string} to run {int} and restoring the files fails",
       %{args: [thread, n]} = context do
    cwd = cwd(context, thread)
    lock = Path.join(String.trim(git(cwd, ["rev-parse", "--absolute-git-dir"])), "index.lock")
    ref = checkpoint(context, thread, n)["ref"]
    commit = git(cwd, ["rev-parse", ref])
    before = tree(cwd)
    File.write!(lock, "")
    context = rewind(context, thread, n)
    File.rm!(lock)
    Map.merge(context, %{tree_before: before, checkpoint_commit: commit})
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

  step "runs 1, 2 and 3 of {string} completed and {string} was rewound to run 2 and then to run 1",
       %{args: [thread, thread]} = context do
    context = complete_through(context, thread, 3)

    Enum.reduce([2, 1], context, fn n, context ->
      context = rewind(context, thread, n)
      assert {:ok, _} = context.reply, "rewinding to run #{n} failed: #{inspect(context.reply)}"
      context
    end)
  end

  # Codex cuts its history before the first turn it drops (the fake names the cut
  # thread after that turn), so after both rewinds its conversation ends with turn 1.
  step "the provider receives the history through run {int}", %{args: [1]} = context do
    thread = context.run_title
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_latest_run(context, thread, "completed", 10_000)
    assert run["ordinal"] == 4

    # Each rewind cut the conversation before the first turn still in it: run 3's, then
    # run 2's (run 3's was already gone and is not counted again).
    assert rewind_requests(context) == ["thread/revert", "thread/revert"]

    assert [%{"beforeTurnId" => "native-turn-3"}, %{"beforeTurnId" => "native-turn-2"}] =
             World.codex_requests(context, "thread/revert")

    start = List.last(World.codex_requests(context, "turn/start"))
    assert hd(start["input"])["text"] == "Again"
    assert start["threadId"] == "native-thread-1-before-native-turn-2"

    state = World.state(context, thread)
    [provider_thread] = StreamState.list(state, "provider-thread")
    assert start["threadId"] == get_in(provider_thread, ["nativeThreadRef", "nativeId"])
    assert provider_thread["lastRunOrdinal"] == 4
    Map.put(context, :again, start)
  end

  step "neither rolled-back run is replayed", context do
    thread = context.run_title
    runs = runs_by_ordinal(World.state(context, thread))

    assert %{1 => "completed", 2 => "rolled_back", 3 => "rolled_back", 4 => "completed"} =
             Map.new(runs, fn {ordinal, run} -> {ordinal, run["status"]} end)

    # The provider continued its own conversation: no transcript was handed over, and
    # nothing of runs 2 and 3 was sent to it again.
    prompt = Enum.map_join(context.again["input"], "\n", &(&1["text"] || ""))
    refute prompt =~ "<conversation_history>"
    refute prompt =~ "run-2.txt" or prompt =~ "run-3.txt"
    assert World.entities(context, thread, "context-handoff") == []

    assert Enum.count(World.provider_prompts(context, "codex"), &(&1 =~ "write run-2.txt")) == 1
    assert Enum.count(World.provider_prompts(context, "codex"), &(&1 =~ "write run-3.txt")) == 1
    context
  end

  step "the provider still holds the conversation through run {int}", %{args: [n]} = context do
    thread = context.run_title
    assert {:error, "Could not restore the checkpoint: " <> _, _} = context.reply
    # It was never asked to drop a turn, and its conversation is the one run 2 ended in.
    assert rewind_requests(context) == []
    state = World.state(context, thread)
    [provider_thread] = StreamState.list(state, "provider-thread")
    assert provider_thread["lastRunOrdinal"] == n
    assert get_in(provider_thread, ["nativeThreadRef", "nativeId"]) == "native-thread-1"
    assert Enum.map(World.runs(context, thread), & &1["status"]) == ["completed", "completed"]
    context
  end

  step "the next message to {string} continues after run {int}", %{args: [thread, n]} = context do
    assert %{"status" => "completed", "ordinal" => ordinal} =
             World.finish_turn(context, thread, "Next")

    assert ordinal == n + 1
    start = List.last(World.codex_requests(context, "turn/start"))
    assert start["threadId"] == "native-thread-1"
    prompt = Enum.map_join(start["input"], "\n", &(&1["text"] || ""))
    assert prompt == "Next"
    assert rewind_requests(context) == []
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
    assert_receive {:hal_c2_vcs, ^cwd, %{"_tag" => "localUpdated", "local" => ^local}}, 5_000
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

  step "the rewind ends with an error", context do
    assert {:error, "Could not restore the checkpoint: " <> detail, _} = context.reply
    assert detail =~ "index.lock"
    assert tree(cwd(context, context.run_title)) == context.tree_before
    context
  end

  # No run is active or rolled back, and the thread takes its next message.
  step "{string} is not left waiting", %{args: [thread]} = context do
    assert Enum.map(World.runs(context, thread), & &1["status"]) == ["completed", "completed"]
    assert %{"status" => "completed", "ordinal" => 3} = World.finish_turn(context, thread, "Next")
    context
  end

  step "the checkpoint of run {int} is still the last valid checkpoint", %{args: [n]} = context do
    checkpoint = checkpoint(context, context.run_title, n)
    assert checkpoint["status"] == "ready"

    assert git(cwd(context, context.run_title), ["rev-parse", checkpoint["ref"]]) ==
             context.checkpoint_commit

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

  # --- capture corners -----------------------------------------------------------

  step "the worktree of {string} is a sparse checkout that leaves out the folder {string}",
       %{args: [thread, folder]} = context do
    cwd = sparse_fixture(context, thread, folder)
    World.git!(cwd, ["sparse-checkout", "set", "--cone", "src"])
    refute File.exists?(Path.join(cwd, "#{folder}/guide.md"))
    context |> Map.put(:sparse_folder, folder) |> Map.put(:run_title, thread)
  end

  step "the checkpoint still holds {string}", %{args: [folder]} = context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"

    assert git(cwd(context, context.run_title), [
             "show",
             "#{checkpoint["ref"]}:#{folder}/guide.md"
           ]) == "guide\n"

    context
  end

  step "the turn's diff does not list the files of {string} as removed",
       %{args: [folder]} = context do
    files = last_checkpoint(context)["files"]
    refute Enum.any?(files, &String.starts_with?(&1["path"], folder <> "/"))
    context = diff(context, context.run_title, 0, 1)
    refute patch(context) =~ "guide.md"
    context
  end

  step "the worktree of {string} holds a folder {string} that is its own repository with no commits",
       %{args: [thread, folder]} = context do
    nested = Path.join(cwd(context, thread), folder)
    File.mkdir_p!(nested)
    World.git!(nested, ~w(init -q -b main))
    File.write!(Path.join(nested, "lib.txt"), "lib\n")
    Map.put(context, :run_title, thread)
  end

  step "the checkpoint is captured without {string}", %{args: [folder]} = context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"

    tree =
      git(cwd(context, context.run_title), ["ls-tree", "-r", "--name-only", checkpoint["ref"]])

    assert tree =~ "README.md"
    refute tree =~ folder
    context
  end

  step "the worktree of {string} holds more than {int} untracked folders that need checking for their own repositories",
       %{args: [thread, count]} = context do
    cwd = cwd(context, thread)

    for i <- 1..(count + 1) do
      nested = Path.join(cwd, "nested-#{i}")
      File.mkdir_p!(nested)
      World.git!(nested, ~w(init -q -b main))
      File.write!(Path.join(nested, "lib.txt"), "lib\n")
    end

    Map.put(context, :run_title, thread)
  end

  # One run is already captured, so only the next run's capture pays the slow
  # probing (its baseline is the checkpoint that already exists).
  step "the worktree of {string} holds untracked folders that take longer than 5 seconds to check",
       %{args: [thread]} = context do
    context = complete_through(context, thread, 1)
    cwd = cwd(context, thread)
    nested = Path.join(cwd, "slow-lib")
    File.mkdir_p!(nested)
    World.git!(nested, ~w(init -q -b main))
    File.write!(Path.join(nested, "lib.txt"), "lib\n")

    dir = HalC2.Test.Mc.tmp_dir(context.mc, "slow-git")
    script = Path.join(dir, "git")

    File.write!(script, """
    #!/bin/sh
    case "$PWD" in */slow-lib) case "$*" in *rev-parse*) exec sleep 10;; esac;; esac
    exec '#{System.find_executable("git")}' "$@"
    """)

    File.chmod!(script, 0o755)
    World.put_app_env(:git_command, script)
    Map.put(context, :run_title, thread)
  end

  step "the checkpoint is marked as an error", context do
    assert %{"status" => "error", "files" => []} = last_checkpoint(context)
    context
  end

  step "a checkpoint of {string} exists only under the old hidden namespace",
       %{args: [thread]} = context do
    context = complete(context, thread, "write a.txt")
    cwd = cwd(context, thread)
    checkpoint = checkpoint(context, thread, 1)
    legacy = String.replace_prefix(checkpoint["ref"], "refs/hal-c2/", "refs/t3/")
    oid = String.trim(git(cwd, ["rev-parse", checkpoint["ref"]]))
    World.git!(cwd, ["update-ref", legacy, oid])
    World.git!(cwd, ["update-ref", "-d", checkpoint["ref"]])
    Map.merge(context, %{legacy_ref: legacy, legacy_checkpoint: checkpoint})
  end

  step "the user views that turn's diff or rewinds to it", context do
    thread = context.run_title

    {diff_reply, context} =
      World.call(context, "orchestration.getTurnDiff", %{
        "threadId" => World.thread_id(context, thread),
        "fromTurnCount" => 0,
        "toTurnCount" => 1
      })

    cwd = cwd(context, thread)
    File.write!(Path.join(cwd, "a.txt"), "changed after\n")
    File.write!(Path.join(cwd, "extra.txt"), "extra\n")
    context |> rewind(thread, 1) |> Map.put(:diff_reply, diff_reply)
  end

  step "the old checkpoint is used", context do
    assert {:ok, %{"diff" => diff}} = context.diff_reply
    assert diff =~ "+++ b/a.txt"
    assert {:ok, _} = context.reply
    cwd = cwd(context, context.run_title)
    assert File.read!(Path.join(cwd, "a.txt")) == "write a.txt\n"
    refute File.exists?(Path.join(cwd, "extra.txt"))
    context
  end

  step "the thread's checkpoints are deleted", context do
    cwd = cwd(context, context.run_title)

    for checkpoint <-
          StreamState.list(World.state(context, context.run_title), "checkpoint"),
        do: Checkpoint.delete_ref(cwd, checkpoint["ref"])

    context
  end

  step "the old checkpoint is deleted along with the new ones", context do
    cwd = cwd(context, context.run_title)
    refute Checkpoint.exists?(cwd, context.legacy_checkpoint["ref"])

    {:ok, %{status: status}} =
      HalC2.Git.run(cwd, ["rev-parse", "--verify", "--quiet", context.legacy_ref <> "^{commit}"])

    assert status != 0
    context
  end

  step "the user has no git name or email configured", context do
    cwd = cwd(context, "t1")

    for key <- ~w(user.name user.email),
        do: HalC2.Git.run(cwd, ["config", "--unset", key])

    context
  end

  step "the checkpoint is captured", context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"
    cwd = cwd(context, context.run_title)
    assert Checkpoint.exists?(cwd, checkpoint["ref"])

    assert git(cwd, ["log", "-1", "--format=%an <%ae>", checkpoint["ref"]]) ==
             "HAL-C2 <hal-c2@users.noreply.github.com>\n"

    context
  end

  step "a checkpoint of {string} was captured a moment ago", %{args: [thread]} = context do
    cwd = cwd(context, thread)
    File.mkdir_p!(Path.join(cwd, "src"))
    File.write!(Path.join(cwd, "src/a.ts"), "one\n")
    World.git!(cwd, ["add", "src/a.ts"])
    World.git!(cwd, ~w(commit -q -m a))
    complete(context, thread, "hello")
  end

  step "{string} was edited again within the same second without its size or modification time changing",
       %{args: [file]} = context do
    path = Path.join(cwd(context, context.run_title), file)
    %{mtime: mtime} = File.stat!(path, time: :posix)
    File.write!(path, "two\n")
    File.touch!(path, mtime)
    context
  end

  step "the checkpoint holds the new content of {string}", %{args: [file]} = context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"

    assert git(cwd(context, context.run_title), ["show", "#{checkpoint["ref"]}:#{file}"]) ==
             "two\n"

    context
  end

  step ~r/^the index of the worktree of "(?<thread>[^"]+)" is (?<state>missing|not a valid index file)$/,
       %{args: [thread, state]} = context do
    cwd = cwd(context, thread)
    path = String.trim(git(cwd, ~w(rev-parse --path-format=absolute --git-path index)))

    bytes =
      case state do
        "missing" ->
          File.rm!(path)
          nil

        "not a valid index file" ->
          File.write!(path, "not an index")
          "not an index"
      end

    context
    |> Map.put(:index_state, {state, path, bytes})
    |> Map.put(:run_title, thread)
  end

  step "the checkpoint holds the files as they are on disk", context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"
    cwd = cwd(context, context.run_title)

    assert git(cwd, ["show", "#{checkpoint["ref"]}:README.md"]) ==
             File.read!(Path.join(cwd, "README.md"))

    context
  end

  step ~r/^the index is still (?<state>missing|not a valid index file)$/,
       %{args: [state]} = context do
    assert {^state, path, bytes} = context.index_state

    case state do
      "missing" -> refute File.exists?(path)
      "not a valid index file" -> assert File.read!(path) == bytes
    end

    context
  end

  step "the worktree of {string} has a content filter configured and one file changed since the last commit",
       %{args: [thread]} = context do
    cwd = cwd(context, thread)
    log = Path.join(context.mc.home, "filter.log")
    File.write!(log, "")

    # The files are older than the index that adds them, so a capture that
    # keeps the index's stat data can tell they have not changed without
    # hashing them (a file stamped in the index's own second is "racily
    # clean" and git must check its content, filters and all).
    old = System.system_time(:second) - 120

    for name <- ~w(one.txt two.txt three.txt) do
      File.write!(Path.join(cwd, name), "#{name}\n")
      File.touch!(Path.join(cwd, name), old)
    end

    File.write!(Path.join(cwd, ".gitattributes"), "*.txt filter=logged\n")
    World.git!(cwd, ["config", "filter.logged.clean", "sh -c 'echo %f >> #{log}; cat'"])
    World.git!(cwd, ["add", ".gitattributes", "one.txt", "two.txt", "three.txt"])
    World.git!(cwd, ~w(commit -q -m filtered))
    File.write!(log, "")
    File.write!(Path.join(cwd, "two.txt"), "two changed\n")

    context
    |> Map.put(:filter_log, log)
    |> Map.put(:run_title, thread)
  end

  step "the filter ran only for the changed file", context do
    ran =
      context.filter_log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.uniq()

    assert ran == ["two.txt"]
    context
  end

  step "the repository's metadata folder holds no leftover checkpoint files", context do
    common =
      String.trim(
        git(
          cwd(context, context.run_title),
          ~w(rev-parse --path-format=absolute --git-common-dir)
        )
      )

    leftovers =
      Enum.filter(File.ls!(common), &String.starts_with?(&1, "hal-c2-checkpoint-index-"))

    assert leftovers == []
    context
  end

  step "the worktree of {string} is a sparse checkout that is not folder-based",
       %{args: [thread]} = context do
    cwd = sparse_fixture(context, thread, "docs")
    World.git!(cwd, ["sparse-checkout", "set", "--no-cone", "/*", "!/docs/"])
    Map.put(context, :run_title, thread)
  end

  step "the checkpoint cannot reuse the worktree's index", context do
    World.git!(cwd(context, context.run_title), [
      "update-index",
      "--assume-unchanged",
      "README.md"
    ])

    context
  end

  step "the error says the checkpoint index cannot be rebuilt for a non-cone sparse checkout",
       context do
    assert {:error, reason} =
             Checkpoint.capture(cwd(context, context.run_title), "refs/hal-c2/test/non-cone")

    assert reason == "Cannot rebuild a checkpoint index for non-cone sparse checkout."
    context
  end

  step "the checkpoint of run {int} holds no files", %{args: [n]} = context do
    context = complete_through(context, "t1", 2)
    cwd = cwd(context, "t1")
    checkpoint = checkpoint(context, "t1", n)
    empty = Path.join(context.mc.home, "empty")
    File.write!(empty, "")
    tree = String.trim(git(cwd, ["hash-object", "-t", "tree", empty]))
    commit = String.trim(git(cwd, ["commit-tree", tree, "-m", "empty"]))
    World.git!(cwd, ["update-ref", checkpoint["ref"], commit])
    context
  end

  step "the user rewinds {string} to before run {int}", %{args: [thread, n]} = context do
    rewind(context, thread, n - 1)
  end

  step "the workspace folder still exists and is empty", context do
    assert {:ok, _} = context.reply
    cwd = cwd(context, context.run_title)
    assert File.dir?(cwd)
    # The worktree's own `.git` link file is git's, not the workspace's.
    assert File.ls!(cwd) -- [".git"] == []
    context
  end

  # --- diffs and file lists ------------------------------------------------------

  step "runs 1, 2 and 3 of {string} completed and the thread was rewound to run 1",
       %{args: [thread]} = context do
    context = context |> complete_through(thread, 3) |> rewind(thread, 1)
    assert {:ok, _} = context.reply
    context
  end

  step "a new run of {string} completed afterwards", %{args: [thread]} = context do
    complete_through(context, thread, 4)
  end

  step "the patch shows what the new run changed", context do
    patch = patch(context)
    assert patch =~ "+++ b/run-4.txt"
    refute patch =~ "run-2.txt"
    refute patch =~ "run-3.txt"
    context
  end

  step "the repository of {string} is configured to show diffs without path prefixes",
       %{args: [_project]} = context do
    World.git!(cwd(context, "t1"), ["config", "diff.noprefix", "true"])
    complete_through(context, "t1", 1)
  end

  step "every file in the patch is still named with its {string} and {string} prefixes",
       %{args: [from_prefix, to_prefix]} = context do
    assert {from_prefix, to_prefix} == {"a/", "b/"}
    patch = patch(context)

    # `/dev/null` names the empty side of an added or deleted file, not a file.
    headers =
      for line <- String.split(patch, "\n"),
          String.starts_with?(line, ["--- ", "+++ "]),
          not String.ends_with?(line, "/dev/null"),
          do: line

    assert headers != []
    assert Enum.all?(headers, &Regex.match?(~r/^(--- a\/|\+\+\+ b\/)/, &1)), inspect(headers)
    assert patch =~ "diff --git a/run-1.txt b/run-1.txt"
    context
  end

  step "a run of {string} completes after renaming {string} to {string}",
       %{args: [thread, old, new]} = context do
    File.write!(Path.join(cwd(context, thread), old), "one\ntwo\n")
    complete(context, thread, "rename #{old} #{new}")
  end

  step "a run of {string} completes after adding an image", %{args: [thread]} = context do
    complete(context, thread, "write-image image.png")
  end

  step "a run of {string} completes after adding an empty file", %{args: [thread]} = context do
    complete(context, thread, "write-empty empty.txt")
  end

  step "a run of {string} completes after editing a file whose name has spaces and non-Latin letters",
       %{args: [thread]} = context do
    name = "my файл.ts"
    File.write!(Path.join(cwd(context, thread), name), "before\n")

    context
    |> complete(thread, "write-named #{name}")
    |> Map.put(:exact_name, name)
  end

  step "a run of {string} completes after editing {string} and then {string}",
       %{args: [thread, first, second]} = context do
    for name <- [first, second],
        do: File.write!(Path.join(cwd(context, thread), name), "before\n")

    complete(context, thread, "write-all #{first} #{second}")
  end

  step "the checkpoint lists {string} and not {string}", %{args: [kept, gone]} = context do
    paths = Enum.map(last_checkpoint(context)["files"], & &1["path"])
    assert kept in paths
    refute gone in paths
    context
  end

  step "the checkpoint lists the image with no added or removed lines", context do
    assert [%{"path" => "image.png", "additions" => 0, "deletions" => 0}] =
             last_checkpoint(context)["files"]

    context
  end

  step "the checkpoint lists the file with no added or removed lines", context do
    assert [%{"path" => "empty.txt", "additions" => 0, "deletions" => 0}] =
             last_checkpoint(context)["files"]

    context
  end

  step "the checkpoint lists the file under its exact name", context do
    assert [%{"path" => path}] = last_checkpoint(context)["files"]
    assert path == context.exact_name
    context
  end

  step "the checkpoint lists {string} before {string}", %{args: [first, second]} = context do
    assert Enum.map(last_checkpoint(context)["files"], & &1["path"]) == [first, second]
    context
  end

  step "a run of {string} completes after writing a file of tens of megabytes",
       %{args: [thread]} = context do
    complete(context, thread, "fill big.txt", 60_000)
  end

  step "the checkpoint still lists that file with its line counts", context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"

    assert Enum.any?(
             checkpoint["files"],
             &(&1["path"] == "big.txt" and &1["additions"] == 110_000 and &1["deletions"] == 0)
           )

    context
  end

  step "listing the files a run of {string} changed fails", %{args: [thread]} = context do
    dir = HalC2.Test.Mc.tmp_dir(context.mc, "numstat-git")
    script = Path.join(dir, "git")

    File.write!(script, """
    #!/bin/sh
    case "$*" in *--numstat*) echo "numstat unavailable" >&2; exit 1;; esac
    exec '#{System.find_executable("git")}' "$@"
    """)

    File.chmod!(script, 0o755)
    World.put_app_env(:git_command, script)
    Map.put(context, :run_title, thread)
  end

  step "the run completes", context do
    complete(context, context.run_title, "write changed.txt")
  end

  step "a ready checkpoint for that run exists with no files listed", context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"
    assert checkpoint["files"] == []
    assert Checkpoint.exists?(cwd(context, context.run_title), checkpoint["ref"])
    context
  end

  step "thread {string} works in a subfolder of a repository, with no git folder of its own",
       %{args: [thread]} = context do
    sub = Path.join(World.project(context, "demo").root, "sub-#{thread}")
    File.mkdir_p!(sub)
    refute File.exists?(Path.join(sub, ".git"))
    assert Checkpoint.repo?(sub)

    context
    |> World.create_thread(thread, "demo", %{"worktreePath" => sub})
    |> Map.put(:run_title, thread)
  end

  step "a run of {string} completes after changing a file", %{args: [thread]} = context do
    complete(context, thread, "write changed.txt")
  end

  step "a client asks for the diff of turn {int} of {string}",
       %{args: [n, thread]} = context do
    diff(context, thread, n - 1, n)
  end

  step "a ready checkpoint for that run exists", context do
    checkpoint = last_checkpoint(context)
    assert checkpoint["status"] == "ready"
    cwd = cwd(context, context.run_title)
    assert Checkpoint.exists?(cwd, checkpoint["ref"])
    tree = git(cwd, ["ls-tree", "-r", "--name-only", checkpoint["ref"]])
    assert tree =~ "changed.txt"
    context
  end

  step "a run of {string} completed with a checkpoint", %{args: [thread]} = context do
    context = complete(context, thread, "write a.txt")
    checkpoint = last_checkpoint(context)
    assert %{"status" => "ready"} = checkpoint

    Map.merge(context, %{
      first_checkpoint: checkpoint,
      first_checkpoint_oid:
        String.trim(git(cwd(context, thread), ["rev-parse", checkpoint["ref"]]))
    })
  end

  step "the capture for that run is asked for again after a restart", context do
    thread = context.run_title
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    cwd = cwd(context, thread)
    # The workspace moves on, so a repeat capture would record something else.
    File.write!(Path.join(cwd, "a.txt"), "changed since\n")

    state = World.state(context, thread)
    run = context |> World.runs(thread) |> List.last()
    scope = state |> StreamState.list("checkpoint-scope") |> hd()

    ids = %{
      thread: World.thread_id(context, thread),
      run: run["id"],
      attempt: run["activeAttemptId"],
      root_node: run["rootNodeId"],
      provider_thread: run["providerThreadId"],
      driver: "codex",
      instance: run["providerInstanceId"]
    }

    turn = %{ids: ids, cwd: cwd, scope_id: scope["id"], run_ordinal: run["ordinal"]}

    assert :ok =
             HalC2.Orchestration.TurnWriter.finish(
               %{thread_id: World.thread_id(context, thread), turn: turn},
               "completed",
               nil
             )

    context
  end

  step "the run keeps the checkpoint it had", context do
    checkpoint = last_checkpoint(context)
    assert checkpoint == context.first_checkpoint

    assert String.trim(git(cwd(context, context.run_title), ["rev-parse", checkpoint["ref"]])) ==
             context.first_checkpoint_oid

    context
  end

  step "no second checkpoint item is added to the run", context do
    state = World.state(context, context.run_title)
    run = context |> World.runs(context.run_title) |> List.last()

    items =
      Enum.filter(
        StreamState.list(state, "turn-item"),
        &(&1["runId"] == run["id"] and &1["type"] == "checkpoint")
      )

    checkpoints =
      Enum.filter(StreamState.list(state, "checkpoint"), &(&1["runId"] == run["id"]))

    assert length(items) == 1
    assert length(checkpoints) == 1
    context
  end

  step "a run of {string} completed with a captured checkpoint", %{args: [thread]} = context do
    context = complete(context, thread, "write a.txt")
    checkpoint = last_checkpoint(context)
    assert %{"status" => "ready"} = checkpoint

    Map.merge(context, %{
      first_checkpoint: checkpoint,
      first_checkpoint_oid:
        String.trim(git(cwd(context, thread), ["rev-parse", checkpoint["ref"]]))
    })
  end

  step "the provider's own diff for that run arrives as a placeholder because no checkpoint was found",
       context do
    thread = context.run_title
    run = context |> World.runs(thread) |> List.last()

    {reply, context} =
      World.dispatch(context, %{
        "type" => "thread.turn.diff.complete",
        "threadId" => World.thread_id(context, thread),
        "turnId" => run["id"],
        "completedAt" => HalC2.Orchestration.Entities.now(),
        "checkpointRef" => "provider-diff:event-1",
        "status" => "missing",
        "files" => [],
        "checkpointTurnCount" => 2
      })

    Map.put(context, :reply, reply)
  end

  step "the command fails saying the turn already has a captured checkpoint", context do
    assert {:error, message, _} = context.reply
    assert message =~ "already has a captured checkpoint"
    context
  end

  # --- rollback safety -------------------------------------------------------------

  step "an archived thread {string} also points at the worktree of {string}",
       %{args: [other, thread]} = context do
    path = World.thread(context, thread)["worktreePath"]
    context = World.create_thread(context, other, "demo", %{"worktreePath" => path})

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.archive",
        "threadId" => World.thread_id(context, other)
      })

    World.await_thread(
      context,
      other,
      &(StreamState.get(&1, "thread")[World.thread_id(context, other)]["archivedAt"] != nil)
    )

    Map.put(context, :run_title, thread)
  end

  step "thread {string} points at the worktree of {string} through a symbolic link",
       %{args: [other, thread]} = context do
    target = World.thread(context, thread)["worktreePath"]
    link = Path.join(context.mc.home, "link-#{other}")
    File.ln_s!(target, link)

    context
    |> World.create_thread(other, "demo", %{"worktreePath" => link})
    |> Map.put(:run_title, thread)
  end

  step "thread {string} ran turns in the worktree of {string} before moving elsewhere",
       %{args: [other, thread]} = context do
    path = World.thread(context, thread)["worktreePath"]
    context = World.create_thread(context, other, "demo", %{"worktreePath" => path})
    context = complete(context, other, "write other.txt")
    {own, branch} = worktree(context, "demo", "#{other}-own")

    context
    |> World.patch_thread(other, %{"worktreePath" => own, "branch" => branch})
    |> Map.put(:run_title, thread)
  end

  step "the user rewinds {string} to run {int} and the thread's active provider changes before the rewind runs",
       %{args: [thread, n]} = context do
    dir = HalC2.Test.Mc.tmp_dir(context.mc, "rewind-gate")
    gate = Path.join(dir, "gate")
    {_, 0} = System.cmd("mkfifo", [gate])
    script = Path.join(dir, "git")

    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "restore" ] && mkdir '#{dir}/held' 2>/dev/null; then read _ < '#{gate}'; fi
    exec '#{System.find_executable("git")}' "$@"
    """)

    File.chmod!(script, 0o755)
    World.put_app_env(:git_command, script)

    id = World.thread_id(context, thread)
    scope = Checkpoint.scope_id(id)

    command = %{
      "type" => "checkpoint.rollback",
      "threadId" => id,
      "scopeId" => scope,
      "checkpointId" => Checkpoint.checkpoint_id(scope, n)
    }

    task = Task.async(fn -> HalC2.Orchestration.dispatch(command) end)
    await_file(Path.join(dir, "held"))

    context =
      World.patch_thread(context, thread, %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}
      })

    File.write!(gate, "go\n")
    reply = Task.await(task, 15_000)

    context
    |> Map.put(:reply, reply)
    |> Map.put(:run_title, thread)
  end

  step "the rewind fails saying the active provider changed before the rewind could run",
       context do
    assert {:error, message} = context.reply
    assert message =~ "Active provider changed before rollback"
    thread = context.run_title
    assert Enum.map(World.runs(context, thread), & &1["status"]) == ["completed", "completed"]
    assert File.exists?(Path.join(cwd(context, thread), "run-2.txt"))
    context
  end

  step "run {int} of {string} was stopped by the user after an assistant message",
       %{args: [n, thread]} = context do
    context = complete_through(context, thread, n - 1)
    context = World.send_turn(context, thread, "say and wait a partial answer")
    statuses = List.duplicate("completed", n - 1) ++ ["running"]
    World.await_runs(context, thread, statuses, 10_000)

    World.await_thread(context, thread, fn state ->
      Enum.any?(StreamState.list(state, "message"), &(&1["role"] == "assistant"))
    end)

    run = context |> World.runs(thread) |> List.last()

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, thread),
        "runId" => run["id"]
      })

    World.await_runs(
      context,
      thread,
      List.duplicate("completed", n - 1) ++ ["interrupted"],
      10_000
    )

    context
    |> Map.put(:stopped_run, run["id"])
    |> Map.put(:run_title, thread)
  end

  step "the user edits from that message", context do
    thread = context.run_title
    context = rewind(context, thread, 1)
    assert {:ok, _} = context.reply
    complete(context, thread, "write edited.txt")
  end

  step "the new turn starts from the checkpoint before that message", context do
    thread = context.run_title
    cwd = cwd(context, thread)
    refute File.exists?(Path.join(cwd, "partial.txt"))
    assert File.exists?(Path.join(cwd, "run-1.txt"))
    assert File.exists?(Path.join(cwd, "edited.txt"))
    assert [%{"beforeTurnId" => "native-turn-2"}] = World.codex_requests(context, "thread/revert")
    checkpoint = last_checkpoint(context)
    assert Enum.map(checkpoint["files"], & &1["path"]) == ["edited.txt"]
    context
  end

  step "the stopped run stays in the history", context do
    state = World.state(context, context.run_title)
    assert StreamState.get(state, "run")[context.stopped_run]
    assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["runId"] == context.stopped_run))
    context
  end

  step "a Codex thread whose run 1 has no turn in the history the MC recorded for Codex",
       context do
    context = complete_through(context, "t1", 2)

    turn =
      context
      |> World.state("t1")
      |> StreamState.list("provider-turn")
      |> Enum.find(&(&1["ordinal"] == 1))

    assert turn

    put(context, "t1", "provider-turn", turn["id"], %{
      "providerThreadId" => "provider-thread:gone"
    })
  end

  step "the command fails saying the target turn was not found in the provider's turn history",
       context do
    assert {:error, message, _} = context.reply
    assert message =~ "target turn was not found in the provider's turn history"
    context
  end

  step "Codex is not asked to drop any turns", context do
    assert rewind_requests(context) == []
    context
  end

  # --- helpers -------------------------------------------------------------------

  # Waits for a gate file a held git command leaves when it reaches the gate.
  defp await_file(path, tries \\ 1_000) do
    cond do
      File.exists?(path) ->
        :ok

      tries > 0 ->
        Process.sleep(10)
        await_file(path, tries - 1)

      true ->
        flunk("the held git command never reached its gate")
    end
  end

  # Commits `src/a.ts` and `<folder>/guide.md` in the thread's worktree, ready
  # for a sparse checkout that leaves the folder out. Returns the worktree.
  defp sparse_fixture(context, thread, folder) do
    cwd = cwd(context, thread)
    File.mkdir_p!(Path.join(cwd, "src"))
    File.mkdir_p!(Path.join(cwd, folder))
    File.write!(Path.join(cwd, "src/a.ts"), "a\n")
    File.write!(Path.join(cwd, "#{folder}/guide.md"), "guide\n")
    World.git!(cwd, ["add", "src", folder])
    World.git!(cwd, ~w(commit -q -m sparse))
    cwd
  end

  # A git worktree of the project's repository on a branch named after the thread.
  defp worktree(context, project, thread) do
    root = World.project(context, project).root
    path = Path.join(context.mc.home, "worktrees/#{thread}")
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
    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
        id: HalC2.Vcs.Registry
      )
    )

    Mc.ensure(
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
