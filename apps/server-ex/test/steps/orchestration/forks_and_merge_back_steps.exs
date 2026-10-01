defmodule HalC2.Steps.Orchestration.ForksAndMergeBack do
  @moduledoc """
  Steps for `features/mc/orchestration/forks-and-merge-back.feature`: real turns on
  the fake provider CLIs (`test/support/fake_codex.py`, `fake_claude.py`,
  `fake_acp.py`), forks and merge-backs dispatched as a client does. What each fake
  was sent is read back with `World.provider_prompts/2`.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @models %{
    "codex" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
    "claudeAgent" => %{"instanceId" => "claudeAgent", "model" => "haiku"},
    "grok" => %{"instanceId" => "grok", "model" => "grok-build"}
  }

  # --- setup ---------------------------------------------------------------------

  step "thread {string} titled {string} has completed runs {int} and {int} on {string}",
       %{args: [thread, title, _first, last, driver]} = context do
    context
    |> World.create_thread(thread, nil, %{"title" => title, "modelSelection" => @models[driver]})
    |> complete_through(thread, last)
  end

  step "thread {string} exists", %{args: [thread]} = context do
    World.create_thread(context, thread)
  end

  # Also threads/fork-and-lineage.feature, whose threads fork through `World.fork_thread/3`
  # (the source's latest finished run).
  step "{string} is a fork of {string}", %{args: [fork, source]} = context do
    if String.contains?(context.feature_file, "/mc/orchestration/") do
      fork!(context, source, fork, :latest)
    else
      context = World.fork_thread(context, source, fork)

      assert World.thread(context, fork)["lineage"]["parentThreadId"] ==
               World.thread_id(context, source)

      context
    end
  end

  step "{string} is a fork of {string} at run {int}", %{args: [fork, source, n]} = context do
    fork!(context, source, fork, {:run, n})
  end

  step "{string} is a fork of {string} at run {int} on {string}",
       %{args: [fork, source, n, driver]} = context do
    context = fork!(context, source, fork, {:run, n})
    World.patch_thread(context, fork, %{"modelSelection" => @models[driver]})
  end

  step "{string} is a fork of {string} at run {int} and has completed run {int}",
       %{args: [fork, source, n, last]} = context do
    context
    |> fork!(source, fork, {:run, n})
    |> complete_through(fork, last)
  end

  step "{string} is a fork of {string} with a running run {int}",
       %{args: [fork, source, n]} = context do
    context = fork!(context, source, fork, {:run, n - 1})
    World.send_turn(context, fork, "wait for it")
    World.await_state(context, fork, &(run(&1, n)["status"] == "running"))
    context
  end

  step "{string} is a fork of {string} whose latest run is waiting",
       %{args: [fork, source]} = context do
    context = fork!(context, source, fork, :latest)
    World.send_turn(context, fork, "ask me")

    World.await_state(context, fork, fn state ->
      Enum.any?(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
    end)

    context
  end

  step "{string} is pinned, settled, snoozed, archived and visited",
       %{args: [thread]} = context do
    at = World.iso_from_now(0)

    World.patch_thread(context, thread, %{
      "pinnedAt" => at,
      "settledOverride" => "settled",
      "settledAt" => at,
      "snoozedAt" => at,
      "snoozedUntil" => World.iso_from_now(World.days(1)),
      "archivedAt" => at,
      "lastVisitedAt" => at
    })
  end

  step "{string} has a queued message after run {int}", %{args: [thread, n]} = context do
    World.send_turn(context, thread, "wait for it")
    World.await_state(context, thread, &(run(&1, n + 1)["status"] == "running"))

    World.send_turn(context, thread, "Later", %{
      "dispatchMode" => %{"type" => "queue_after_active"}
    })

    World.await_state(context, thread, &(run(&1, n + 2)["status"] == "queued"))
    context
  end

  step "{string} has no completed run", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    scope = HalC2.Checkpoint.scope_id(id)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "checkpoint.rollback",
        "commandId" => "cmd-rewind-#{System.unique_integer([:positive])}",
        "threadId" => id,
        "scopeId" => scope,
        "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 0),
        "restoreFiles" => false
      })

    refute Enum.any?(World.runs(context, thread), &(&1["status"] == "completed"))
    context
  end

  # A real turn when it is the thread's next run; otherwise, as projections.feature
  # sets up a thread with no runs, the runs are recorded (`World.numbered_run/5`).
  step "run {int} of {string} is running", %{args: [n, thread]} = context do
    if length(World.runs(context, thread)) == n - 1 do
      World.send_turn(context, thread, "wait for it")
      World.await_state(context, thread, &(run(&1, n)["status"] == "running"))
      context
    else
      context |> Map.put(:thread, thread) |> World.numbered_run(thread, n, "running")
    end
  end

  step "no checkpoint {string} exists", %{args: [id]} = context do
    refute StreamState.get(World.state(context, "t1"), "checkpoint")[id]
    context
  end

  # threads/fork-and-lineage.feature gives the unrelated thread a finished turn of its own.
  step "{string} was not forked from {string}", %{args: [thread, source]} = context do
    if String.contains?(context.feature_file, "/mc/orchestration/") do
      World.create_thread(context, thread)
    else
      context = World.finished_turns(World.create_thread(context, thread), thread, ["other"])

      refute World.thread(context, thread)["lineage"]["parentThreadId"] ==
               World.thread_id(context, source)

      context
    end
  end

  step "thread {string} does not exist", %{args: [thread]} = context do
    refute (context[:threads] || %{})[thread]
    context
  end

  step "{string} was removed from this MC", %{args: [thread]} = context do
    context = fork!(context, thread, "f1", :latest)
    id = World.thread_id(context, thread)
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
    assert World.thread(context, thread)["deletedAt"]
    context
  end

  step "{string} was merged back into {string}", %{args: [fork, parent]} = context do
    merged(context, fork, parent)
  end

  step "{string} was merged back into {string} and {string} has not run since",
       %{args: [fork, parent, _parent]} = context do
    context = merged(context, fork, parent)
    assert [%{"status" => "completed"}, %{"status" => "completed"}] = World.runs(context, parent)
    context
  end

  step "{string} and {string} were each merged back into {string}",
       %{args: [first, second, parent]} = context do
    context |> merged(first, parent) |> merged(second, parent)
  end

  step "{string} was merged back into {string} once already", %{args: [fork, parent]} = context do
    context = merged(context, fork, parent)
    context = finish(context, parent, "Continue")
    assert [%{"status" => "consumed"}] = merge_backs(context, parent)
    context
  end

  # --- actions -------------------------------------------------------------------

  step "the user forks {string} at run {int} as {string}", %{args: [source, n, fork]} = context do
    fork(context, source, fork, {:run, n})
  end

  step "the user forks {string} as {string}", %{args: [source, fork]} = context do
    fork(context, source, fork, :latest)
  end

  step "the user forks {string} as {string} titled {string}",
       %{args: [source, fork, title]} = context do
    fork(context, source, fork, :latest, %{"title" => title})
  end

  step "the user forks {string} at its latest stable point as {string}",
       %{args: [source, fork]} = context do
    fork(context, source, fork, :latest)
  end

  step "the user forks {string} at the checkpoint of run {int} as {string}",
       %{args: [source, n, fork]} = context do
    checkpoint = run(World.state(context, source), n)["checkpointId"]
    assert checkpoint
    fork(context, source, fork, {:checkpoint, checkpoint})
  end

  step "the user forks {string} at checkpoint {string} as {string}",
       %{args: [source, checkpoint, fork]} = context do
    fork(context, source, fork, {:checkpoint, checkpoint})
  end

  step "the user forks thread {string} as {string}", %{args: [source, fork]} = context do
    fork(context, source, fork, :latest)
  end

  step "the user sends {string} to {string} on {string}",
       %{args: [text, thread, driver]} = context do
    context
    |> World.send_turn(thread, text, %{"modelSelection" => @models[driver]})
    |> Map.merge(%{run_title: thread, prompt_driver: driver})
  end

  step "the user merges {string} back into {string}", %{args: [fork, parent]} = context do
    merge_back(context, fork, parent, :latest)
  end

  step "the user merges {string} back into {string} again", %{args: [fork, parent]} = context do
    merge_back(context, fork, parent, :latest)
  end

  step "the user merges {string} back into {string} at run {int}",
       %{args: [fork, parent, n]} = context do
    merge_back(context, fork, parent, {:run, n})
  end

  step "the user merges {string} back into {string} at that run",
       %{args: [fork, parent]} = context do
    n = context |> World.runs(fork) |> List.last() |> Map.fetch!("ordinal")
    merge_back(context, fork, parent, {:run, n})
  end

  step "the user merges {string} back again after more work", %{args: [fork]} = context do
    context
    |> complete_through(fork, length(World.runs(context, fork)) + 1)
    |> merge_back(fork, "t1", :latest)
  end

  # --- outcomes: forking ---------------------------------------------------------

  step "thread {string} exists titled {string}", %{args: [thread, title]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["title"] == title
    context
  end

  step "{string} has a copy of run {int} with its messages, items, plans and checkpoint",
       %{args: [fork, n]} = context do
    source = World.state(context, "t1")
    copy = World.state(context, fork)
    run = run(source, n)
    assert run(copy, n)["id"] == run["id"]

    for kind <- ~w(message turn-item plan checkpoint) do
      of_run = fn state ->
        state |> StreamState.list(kind) |> Enum.filter(&(&1["runId"] == run["id"]))
      end

      ids = &(&1 |> of_run.() |> Enum.map(fn entity -> entity["id"] end) |> Enum.sort())
      if kind != "plan", do: assert(of_run.(source) != [], "run #{n} has no #{kind}")
      assert ids.(copy) == ids.(source), "the fork's #{kind}s of run #{n} differ"
    end

    assert Enum.all?(
             StreamState.list(copy, "message"),
             &(&1["threadId"] == World.thread_id(context, fork))
           )

    context
  end

  step "{string} does not have run {int}", %{args: [fork, n]} = context do
    refute run(World.state(context, fork), n)
    context
  end

  step "{string} names {string} as its parent with relationship fork",
       %{args: [fork, parent]} = context do
    assert {:ok, _} = context.reply

    assert %{"parentThreadId" => parent_id, "relationshipToParent" => "fork"} =
             World.thread(context, fork)["lineage"]

    assert parent_id == World.thread_id(context, parent)
    context
  end

  step "{string} names {string} as its root thread", %{args: [fork, root]} = context do
    assert World.thread(context, fork)["lineage"]["rootThreadId"] ==
             World.thread_id(context, root)

    context
  end

  step "{string} records it forked from run {int} of {string}",
       %{args: [fork, n, source]} = context do
    assert %{"type" => "run", "threadId" => source_id, "runId" => run_id} =
             World.thread(context, fork)["forkedFrom"]

    assert source_id == World.thread_id(context, source)
    assert run_id == run(World.state(context, source), n)["id"]
    context
  end

  step "{string} names {string} as its parent and {string} as its root thread",
       %{args: [fork, parent, root]} = context do
    assert {:ok, _} = context.reply
    lineage = World.thread(context, fork)["lineage"]
    assert lineage["parentThreadId"] == World.thread_id(context, parent)
    assert lineage["rootThreadId"] == World.thread_id(context, root)
    context
  end

  step "{string} is not pinned, settled, snoozed, archived or visited",
       %{args: [fork]} = context do
    assert {:ok, _} = context.reply
    thread = World.thread(context, fork)

    for field <-
          ~w(pinnedAt settledOverride settledAt snoozedAt snoozedUntil archivedAt lastVisitedAt),
        do: assert(thread[field] == nil, "#{field} is #{inspect(thread[field])}")

    assert World.thread(context, "t1")["pinnedAt"]
    context
  end

  step "the fork has no queued message", context do
    assert {:ok, _} = context.reply
    refute Enum.any?(World.runs(context, "f1"), &(&1["status"] == "queued"))
    assert Enum.any?(World.runs(context, "t1"), &(&1["status"] == "queued"))
    context
  end

  step "{string} forked from run {int}", %{args: [fork, n]} = context do
    assert {:ok, _} = context.reply
    run_id = World.thread(context, fork)["forkedFrom"]["runId"]
    assert run_id == run(World.state(context, "t1"), n)["id"]
    context
  end

  step "{string} still shows the copied history and its diffs", %{args: [fork]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, "t1")["deletedAt"]
    state = World.state(context, fork)
    assert [1, 2] = state |> StreamState.list("run") |> Enum.map(& &1["ordinal"]) |> Enum.sort()
    assert StreamState.list(state, "message") != []

    {reply, context} =
      World.call(context, "orchestration.getTurnDiff", %{
        "threadId" => World.thread_id(context, fork),
        "fromTurnCount" => 0,
        "toTurnCount" => 2
      })

    assert {:ok, %{"diff" => diff}} = reply
    assert diff =~ "run-1.txt"
    assert diff =~ "run-2.txt"
    context
  end

  step "the provider forks its own thread at the turn of run {int}", %{args: [n]} = context do
    fork = context.run_title
    finished(context, fork)
    source = World.state(context, "t1")
    run = run(source, n)
    turn = provider_turn(source, run)

    native =
      StreamState.get(source, "provider-thread")[turn["providerThreadId"]]["nativeThreadRef"]

    assert "thread/fork" in World.codex_methods(context)

    expected = "forked-#{native["nativeId"]}-at-#{turn["nativeTurnRef"]["nativeId"]}"

    assert Enum.any?(
             StreamState.list(World.state(context, fork), "provider-thread"),
             &(get_in(&1, ["nativeThreadRef", "nativeId"]) == expected)
           )

    context
  end

  step "the fork transfer is consumed as a native fork", context do
    assert %{"status" => "consumed", "resolution" => %{"strategy" => "native_fork"}} =
             transfer(context, context.run_title, "fork")

    context
  end

  step "the provider receives a transcript of the copied history before the message",
       context do
    thread = context.run_title
    finished(context, thread)
    prompt = last_prompt(context, thread)

    assert prompt =~ "<conversation_history>", "the provider got #{inspect(prompt)}"
    [history, message] = String.split(prompt, "</conversation_history>", parts: 2)
    assert history =~ "User: write run-1.txt"
    assert history =~ "User: write run-2.txt"
    assert String.trim(message) == last_user_text(context, thread)
    context
  end

  step "the fork transfer is consumed as portable context with a full thread summary handoff",
       context do
    thread = context.run_title

    assert %{
             "status" => "consumed",
             "resolution" => %{"strategy" => "portable_context", "contextHandoffId" => handoff}
           } = transfer(context, thread, "fork")

    assert %{"strategy" => "full_thread_summary", "summaryText" => text} =
             StreamState.get(World.state(context, thread), "context-handoff")[handoff]

    assert text =~ "write run-2.txt"
    context
  end

  # --- outcomes: merging back ----------------------------------------------------

  step "{string} has a pending merge-back transfer from {string}",
       %{args: [parent, fork]} = context do
    assert {:ok, _} = context.reply
    fork_id = World.thread_id(context, fork)

    assert [%{"status" => "pending"}] =
             merge_backs(context, parent) |> Enum.filter(&(&1["sourceThreadId"] == fork_id))

    context
  end

  step "the transfer's base is the fork point", context do
    [merge] = merge_backs(context, "t1")
    fork = transfer(context, "f1", "fork")
    assert merge["basePoint"] == fork["sourcePoint"]
    assert merge["basePoint"]["runId"] == run(World.state(context, "t1"), 2)["id"]
    context
  end

  step "the provider receives the work of {string} since the fork point, introduced as coming from the fork by its title",
       %{args: [fork]} = context do
    finished(context, "t1")
    prompt = last_prompt(context, "t1")
    title = World.thread(context, fork)["title"]
    assert prompt =~ "From the fork \"#{title}\":"
    assert prompt =~ "User: write #{fork}-work-1.txt"
    refute prompt =~ "write run-1.txt"
    refute prompt =~ "write run-2.txt"
    context
  end

  step "the merge-back transfer is consumed with a fork delta summary handoff", context do
    assert [
             %{
               "status" => "consumed",
               "resolution" => %{"strategy" => "portable_context", "contextHandoffId" => handoff}
             }
           ] = merge_backs(context, "t1")

    assert %{"strategy" => "fork_delta_summary"} =
             StreamState.get(World.state(context, "t1"), "context-handoff")[handoff]

    context
  end

  step "the earlier merge-back transfer is superseded by the new one", context do
    assert {:ok, _} = context.reply
    [earlier, later] = merge_backs(context, "t1")
    assert earlier["status"] == "superseded"
    assert later["status"] == "pending"
    assert earlier["error"] == "Superseded by merge-back transfer #{later["id"]}."
    context
  end

  step "only the new merge reaches the parent's next run", context do
    context = finish(context, "t1", "Continue")
    [earlier, later] = merge_backs(context, "t1")
    assert earlier["status"] == "superseded"
    assert later["status"] == "consumed"
    prompt = last_prompt(context, "t1")
    assert length(String.split(prompt, "From the fork")) == 2
    context
  end

  step "the provider receives the work of both forks", context do
    finished(context, "t1")
    prompt = last_prompt(context, "t1")
    assert prompt =~ "User: write f1-work-1.txt"
    assert prompt =~ "User: write f2-work-1.txt"
    assert Enum.all?(merge_backs(context, "t1"), &(&1["status"] == "consumed"))
    context
  end

  step "the command fails saying only finished runs can be used", context do
    assert {:error, message, _} = context.reply
    assert message =~ "only finished runs can be used."
    assert merge_backs(context, "t1") == []
    context
  end

  step "the handoff carries only the fork's work since the last merge the parent consumed",
       context do
    context = finish(context, "t1", "Continue again")
    [first, second] = merge_backs(context, "t1")
    assert second["basePoint"] == first["sourcePoint"]
    assert second["status"] == "consumed"
    prompt = last_prompt(context, "t1")
    assert prompt =~ "User: write f1-work-2.txt"
    refute prompt =~ "write f1-work-1.txt"
    context
  end

  # --- helpers -------------------------------------------------------------------

  defp run(state, ordinal),
    do: state |> StreamState.list("run") |> Enum.find(&(&1["ordinal"] == ordinal))

  # Completes runs until `thread` has `n`: the fork's own write `<fork>-work-<k>.txt`,
  # the source's `run-<ordinal>.txt`.
  defp complete_through(context, thread, n) do
    done = length(World.runs(context, thread))

    Enum.reduce((done + 1)..n//1, context, fn ordinal, context ->
      name =
        if thread == "t1", do: "run-#{ordinal}.txt", else: "#{thread}-work-#{ordinal - 2}.txt"

      assert %{"status" => "completed"} = World.finish_turn(context, thread, "write #{name}")
      context
    end)
  end

  defp point(_state, :latest), do: %{"type" => "latest_stable"}

  defp point(state, {:run, n}),
    do: %{"type" => "run", "runId" => run(state, n)["id"] || "run-#{n}"}

  defp point(_state, {:checkpoint, id}), do: %{"type" => "checkpoint", "checkpointId" => id}

  # A thread's id by name, or the name itself for one the scenario never made.
  defp id(context, name), do: (context[:threads] || %{})[name] || name

  defp fork(context, source, target, at, extra \\ %{}) do
    source_id = id(context, source)

    target_id =
      (context[:threads] || %{})[target] || "th-#{target}-#{System.unique_integer([:positive])}"

    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(source_id))

    {reply, context} =
      World.dispatch(
        context,
        Map.merge(
          %{
            "type" => "thread.fork",
            "createdBy" => "user",
            "creationSource" => "web",
            "sourceThreadId" => source_id,
            "targetThreadId" => target_id,
            "sourcePoint" => point(state, at)
          },
          extra
        )
      )

    context = context |> Map.put(:reply, reply) |> Map.put(:run_title, target)

    case reply do
      {:ok, _} -> put_in(context, [:threads, target], target_id)
      _ -> context
    end
  end

  defp fork!(context, source, target, at) do
    context = fork(context, source, target, at)
    assert {:ok, _} = context.reply
    context
  end

  defp merge_back(context, fork, parent, at) do
    fork_id = id(context, fork)
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(fork_id))

    {reply, context} =
      World.dispatch(context, %{
        "type" => "thread.merge_back",
        "createdBy" => "user",
        "sourceThreadId" => fork_id,
        "targetThreadId" => id(context, parent),
        "sourcePoint" => point(state, at)
      })

    Map.put(context, :reply, reply)
  end

  # `fork` forked from `parent` at run 2, did a run of its own and was merged back.
  defp merged(context, fork, parent) do
    context =
      if (context[:threads] || %{})[fork],
        do: context,
        else: fork!(context, parent, fork, {:run, 2})

    context = complete_through(context, fork, length(World.runs(context, fork)) + 1)
    context = merge_back(context, fork, parent, :latest)
    assert {:ok, _} = context.reply
    context
  end

  defp merge_backs(context, parent) do
    context
    |> World.state(parent)
    |> StreamState.list("context-transfer")
    |> Enum.filter(&(&1["type"] == "merge_back"))
    |> Enum.sort_by(& &1["createdAt"])
  end

  defp transfer(context, thread, type) do
    context
    |> World.state(thread)
    |> StreamState.list("context-transfer")
    |> Enum.find(&(&1["type"] == type))
  end

  defp provider_turn(state, run) do
    attempts =
      for attempt <- StreamState.list(state, "run-attempt"),
          attempt["runId"] == run["id"],
          do: attempt["id"]

    state |> StreamState.list("provider-turn") |> Enum.find(&(&1["runAttemptId"] in attempts))
  end

  defp finish(context, thread, text) do
    context = World.send_turn(context, thread, text)
    finished(context, thread)
    context
  end

  # Waits until none of the thread's runs is still going; the last one completed.
  defp finished(context, thread) do
    state =
      World.await_state(
        context,
        thread,
        fn state ->
          runs = StreamState.list(state, "run")

          runs != [] and
            Enum.all?(runs, &(&1["status"] not in ~w(queued preparing starting running)))
        end,
        10_000
      )

    last = state |> StreamState.list("run") |> Enum.max_by(& &1["ordinal"])
    assert last["status"] == "completed"
    state
  end

  defp last_user_text(context, thread) do
    state = World.state(context, thread)
    last = state |> StreamState.list("run") |> Enum.max_by(& &1["ordinal"])
    StreamState.get(state, "message")[last["userMessageId"]]["text"]
  end

  # The last message the thread's provider CLI was sent.
  defp last_prompt(context, thread) do
    driver = World.thread(context, thread)["modelSelection"]["instanceId"]
    driver = if context[:run_title] == thread, do: context[:prompt_driver] || driver, else: driver

    case World.provider_prompts(context, driver) do
      [] -> flunk("#{driver} was sent nothing")
      prompts -> List.last(prompts)
    end
  end
end
