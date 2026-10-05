defmodule HalC2.Steps.Orchestration.Projections do
  @moduledoc "Steps for features/mc/orchestration/projections.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # --- run status ----------------------------------------------------------------------

  step ~r/^the latest run of "(?<thread>[^"]+)" is (?<status>[a-z_]+)$/,
       %{args: [thread, status]} = context do
    context |> Map.put(:thread, thread) |> World.numbered_run(thread, 1, status)
  end

  step "the shell row of {string} has status {string}", %{args: [thread, status]} = context do
    assert World.row(context, thread)["status"] == status
    context
  end

  step "the shell row names run {int} as the active run and its activity status is running",
       %{args: [n]} = context do
    row = World.row(context, context.thread)
    assert row["activeRunId"] == "run-#{n}"
    assert row["activityRunStatus"] == "running"
    context
  end

  step "the shell row has no active run", context do
    row = World.row(context, context.thread)
    assert row["activeRunId"] == nil
    assert row["latestRunId"] != nil
    context
  end

  step "its activity status is waiting", context do
    assert World.row(context, context.thread)["activityRunStatus"] == "waiting"
    context
  end

  # --- pending requests, messages, plans -----------------------------------------------

  step "the provider asked for approval of a command in {string}", %{args: [thread]} = context do
    context =
      context |> World.providers() |> World.dispatch_message(thread, "approve the command")

    assert {:ok, _} = context.reply

    World.await_state(context, thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
    end)

    Map.put(context, :thread, thread)
  end

  step "the shell row of {string} shows the pending request's id, kind and time",
       %{args: [thread]} = context do
    [request] =
      for r <- World.entities(context, thread, "runtime-request"),
          r["status"] == "pending",
          do: r

    row =
      World.await_row(World.thread_id(context, thread), &(&1["pendingRuntimeRequest"] != nil))

    assert row["pendingRuntimeRequest"] == %{
             "id" => request["id"],
             "kind" => request["kind"],
             "createdAt" => request["createdAt"]
           }

    context
  end

  step "{string} has a long conversation", %{args: [thread]} = context do
    body = String.duplicate("a long paragraph of the conversation ", 200)

    context =
      Enum.reduce(1..10, context, fn i, context ->
        role = if rem(i, 2) == 1, do: "user", else: "assistant"
        World.add_message(context, thread, role, "#{i}: #{body}", World.iso_from_now(i - 100))
      end)

    Map.merge(context, %{thread: thread, body: body})
  end

  step "the shell row of {string} has no latest visible message text",
       %{args: [thread]} = context do
    row = World.row(context, thread)
    assert row["latestVisibleMessage"] == nil
    refute JSON.encode!(row) =~ "a long paragraph"
    context
  end

  step "it records when the latest user message was sent", context do
    latest =
      context
      |> World.entities(context.thread, "message")
      |> Enum.filter(&(&1["role"] == "user"))
      |> Enum.max_by(& &1["updatedAt"])

    assert World.row(context, context.thread)["latestUserMessageAt"] == latest["updatedAt"]
    context
  end

  step "{string} has an active proposed plan", %{args: [thread]} = context do
    plan = %{
      "id" => "plan-1",
      "threadId" => World.thread_id(context, thread),
      "runId" => nil,
      "nodeId" => nil,
      "kind" => "proposed_plan",
      "status" => "active",
      "markdown" => "# Plan\n\n- do it",
      "createdAt" => World.iso_from_now(0),
      "updatedAt" => World.iso_from_now(0)
    }

    context
    |> World.put_entity(thread, "plan", "plan-1", %{"s" => plan})
    |> Map.put(:thread, thread)
  end

  step "the shell row of {string} has an actionable proposed plan", %{args: [thread]} = context do
    assert World.row(context, thread)["hasActionableProposedPlan"] == true
    context
  end

  # The composer's "implement plan" sends a message naming the plan, which completes it.
  step "the mark clears when the plan is completed", context do
    thread = context.thread

    context =
      context
      |> World.providers()
      |> World.dispatch_message(thread, "implement the plan", %{
        "sourcePlanRef" => %{"threadId" => World.thread_id(context, thread), "planId" => "plan-1"}
      })

    assert {:ok, _} = context.reply
    assert World.entities(context, thread, "plan") |> hd() |> Map.get("status") == "completed"

    World.await_row(
      World.thread_id(context, thread),
      &(&1["hasActionableProposedPlan"] == false)
    )

    context
  end

  # --- background work -----------------------------------------------------------------

  step "the latest run of {string} completed while a background command kept running",
       %{args: [thread]} = context do
    context
    |> World.numbered_run(thread, 1, "completed")
    |> background_command(thread, "run-1")
  end

  step "run {int} of {string} is running and a background command from run {int} is still active",
       %{args: [n, thread, from]} = context do
    context
    |> World.numbered_run(thread, from, "completed")
    |> background_command(thread, "run-#{from}")
    |> World.numbered_run(thread, n, "running")
  end

  step "the latest run of {string} was rolled back while a background command ran",
       %{args: [thread]} = context do
    context
    |> World.numbered_run(thread, 1, "rolled_back")
    |> background_command(thread, "run-1")
  end

  step "the shell row of {string} lists that background task", %{args: [thread]} = context do
    assert [%{"taskId" => "bg-1", "taskType" => "command_execution", "description" => d}] =
             World.row(context, thread)["pendingBackgroundTasks"]

    assert d == "npm run watch"
    context
  end

  step "the shell row of {string} lists no background tasks", %{args: [thread]} = context do
    assert World.entities(context, thread, "turn-item") |> Enum.any?(&(&1["id"] == "bg-1"))
    assert World.row(context, thread)["pendingBackgroundTasks"] == []
    context
  end

  # Real turns on the fake Codex: "in the background" starts a dev server in a terminal
  # and ends the turn with it running (`test/support/fake_codex.py`).
  step "run {int} of {string} started a background shell command",
       %{args: [1, thread]} = context do
    context = context |> World.providers() |> Map.put(:thread, thread)
    context = World.dispatch_message(context, thread, "Start the dev server in the background")
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = World.await_latest_run(context, thread, "completed")

    assert %{"status" => "running", "runId" => run_id} = background_item(context, thread)
    assert run_id == run["id"]
    Map.put(context, :background_run, run["id"])
  end

  step "run {int} of {string} starts", %{args: [2, thread]} = context do
    context = World.running_turn(context, thread)
    assert %{"ordinal" => 2, "status" => "running"} = World.latest_run(context, thread)
    context
  end

  step "the command stays attached to run 1", context do
    # Still running, in the run that started it, with its own node there.
    assert %{"status" => "running", "runId" => run_id, "nodeId" => node_id} =
             background_item(context, context.thread)

    assert run_id == context.background_run
    assert World.state(context, context.thread).entities["node"][node_id]["runId"] == run_id

    refute Enum.any?(
             World.entities(context, context.thread, "turn-item"),
             &(&1["runId"] == context.running and &1["type"] == "command_execution")
           )

    context
  end

  step "its completion cannot finish run 2", context do
    thread = context.thread
    {_pid, runtime} = World.codex_runtime(context, thread)
    first_turn = World.state(context, thread).entities["run"][context.background_run]

    # Codex reports the command's exit under the turn that started it, mid-run 2.
    context =
      World.codex_notify(context, thread, "item/completed", %{
        "threadId" => runtime.native_thread_id,
        "turnId" => "native-turn-1",
        "item" => %{
          "type" => "commandExecution",
          "id" => "cmd-bg",
          "command" => "npm run dev",
          "status" => "completed",
          "aggregatedOutput" => "bye",
          "exitCode" => 0
        }
      })

    state =
      World.await_state(context, thread, fn state ->
        state.entities["turn-item"]["turn-item:codex:cmd-bg"]["status"] == "completed" && state
      end)

    item = state.entities["turn-item"]["turn-item:codex:cmd-bg"]
    assert %{"runId" => run_id, "output" => "bye", "exitCode" => 0} = item
    assert run_id == context.background_run
    # Run 1 is as it ended, and run 2 goes on: only its own turn's end finishes it.
    assert state.entities["run"][context.background_run] == first_turn
    assert %{"status" => "running", "completedAt" => nil} = state.entities["run"][context.running]

    assert %{"status" => "running"} =
             state.entities["node"][state.entities["run"][context.running]["rootNodeId"]]

    context =
      World.codex_notify(context, thread, "turn/completed", %{
        "turn" => %{"id" => runtime.turn.native_turn_id, "status" => "completed"}
      })

    World.await_state(
      context,
      thread,
      &(&1.entities["run"][context.running]["status"] == "completed")
    )

    context
  end

  defp background_item(context, thread),
    do: World.state(context, thread).entities["turn-item"]["turn-item:codex:cmd-bg"]

  defp background_command(context, thread, run_id) do
    World.add_item(context, thread, "bg-1", "command_execution", run_id, %{
      "status" => "running",
      "input" => "npm run watch",
      "completedAt" => nil
    })
  end

  # --- thread errors -------------------------------------------------------------------

  step ~r/^the latest run of "(?<thread>[^"]+)" failed with a usage limit error that resets at (?<time>\d\d:\d\d)$/,
       %{args: [thread, time]} = context do
    reset = today(time)

    context
    |> World.numbered_run(thread, 1, "failed")
    |> failure(thread, "run-1", "usage_limit", "You've hit your usage limit.", %{
      "resetAt" => reset
    })
    |> Map.put(:reset_at, reset)
  end

  step "the shell row of {string} shows that error, its class and the reset time",
       %{args: [thread]} = context do
    assert %{
             "lastError" => "You've hit your usage limit.",
             "lastErrorClass" => "usage_limit",
             "usageLimitResetAt" => reset
           } = World.row(context, thread)

    assert reset == context.reset_at
    context
  end

  step "the latest run of {string} failed and the provider session reports a different error",
       %{args: [thread]} = context do
    at = World.iso_from_now(0)

    session = %{
      "id" => "session-1",
      "threadId" => World.thread_id(context, thread),
      "providerInstanceId" => "codex",
      "status" => "error",
      "lastError" => "The session crashed.",
      "createdAt" => at,
      "updatedAt" => at
    }

    context
    |> World.numbered_run(thread, 1, "failed")
    |> failure(thread, "run-1", "provider_error", "The turn failed.")
    |> World.put_entity(thread, "provider-session", "session-1", %{"s" => session})
  end

  step "the shell row of {string} shows the session's error without the turn's classification",
       %{args: [thread]} = context do
    row = World.row(context, thread)
    assert row["lastError"] == "The session crashed."
    assert row["lastErrorClass"] == nil
    assert row["usageLimitResetAt"] == nil
    context
  end

  step "run 1 of {string} failed and run 2 completed", %{args: [thread]} = context do
    context =
      context
      |> World.numbered_run(thread, 1, "failed")
      |> failure(thread, "run-1", "provider_error", "The turn failed.")

    assert World.row(context, thread)["lastError"] == "The turn failed."
    World.numbered_run(context, thread, 2, "completed")
  end

  step "the shell row of {string} shows no error", %{args: [thread]} = context do
    assert %{"lastError" => nil, "lastErrorClass" => nil, "usageLimitResetAt" => nil} =
             World.row(context, thread)

    context
  end

  defp failure(context, thread, run_id, class, message, extra \\ %{}) do
    World.add_item(context, thread, "error-#{run_id}", "error", run_id, %{
      "status" => "failed",
      "message" => message,
      "failure" =>
        Map.merge(
          %{"class" => class, "message" => message, "code" => nil, "retryable" => nil},
          extra
        )
    })
  end

  defp today(time) do
    Date.utc_today() |> Date.to_iso8601() |> Kernel.<>("T#{time}:00.000Z")
  end

  # --- provider history and forks ------------------------------------------------------

  step ~r/^"(?<thread>[^"]+)" ran on "(?<first>[^"]+)" and then "(?<second>[^"]+)", and delegated a task to "(?<child>[^"]+)"$/,
       %{args: [thread, first, second, child]} = context do
    [{first, nil, -3}, {second, nil, -2}, {child, "mc-subagent", -1}]
    |> Enum.with_index(1)
    |> Enum.reduce(context, fn {{instance, owner, minutes}, i}, context ->
      provider_thread = %{
        "id" => "pt-#{i}",
        "appThreadId" => World.thread_id(context, thread),
        "providerInstanceId" => instance,
        "ownerNodeId" => owner,
        "createdAt" => World.iso_from_now(minutes * 60_000),
        "updatedAt" => World.iso_from_now(minutes * 60_000)
      }

      World.put_entity(context, thread, "provider-thread", "pt-#{i}", %{"s" => provider_thread})
    end)
  end

  step ~r/^the provider history of "(?<thread>[^"]+)" is (?<list>.+)$/,
       %{args: [thread, list]} = context do
    expected = Regex.scan(~r/"([^"]+)"/, list, capture: :all_but_first) |> List.flatten()
    assert World.row(context, thread)["providerInstanceHistory"] == expected
    context
  end

  step ~r/^"(?<fork>[^"]+)" is a fork of "(?<source>[^"]+)" after (?<n>\d+) items and has (?<own>\d+) items of its own$/,
       %{args: [fork, source, n, own]} = context do
    context = World.numbered_run(context, source, 1, "completed")

    context =
      Enum.reduce(1..String.to_integer(n), context, fn i, context ->
        World.add_item(context, source, "s-#{i}", "assistant_message", "run-1")
      end)

    context =
      context
      |> World.named_thread(fork)
      |> World.patch_thread(fork, %{
        "forkedFrom" => %{
          "type" => "run",
          "threadId" => World.thread_id(context, source),
          "runId" => "run-1"
        }
      })
      |> World.numbered_run(fork, 1, "completed")

    Enum.reduce(1..String.to_integer(own), context, fn i, context ->
      World.add_item(context, fork, "f-#{i}", "assistant_message", "run-1")
    end)
  end

  step ~r/^the shell row of "(?<thread>[^"]+)" counts (?<own>\d+) own items and more than (?<n>\d+) visible items$/,
       %{args: [thread, own, n]} = context do
    row = World.row(context, thread)
    assert row["itemCount"] == String.to_integer(own)
    assert row["visibleItemCount"] > String.to_integer(n)
    context
  end

  # --- the timeline --------------------------------------------------------------------

  step "{string} has items of a rolled-back run", %{args: [thread]} = context do
    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.add_item(thread, "kept", "assistant_message", "run-1")
    |> World.numbered_run(thread, 2, "rolled_back")
    |> World.add_item(thread, "gone-1", "assistant_message", "run-2")
    |> World.add_item(thread, "gone-2", "command_execution", "run-2")
    |> Map.put(:hidden, ["gone-1", "gone-2"])
  end

  step "{string} has a queued message whose run was cancelled", %{args: [thread]} = context do
    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.add_item(thread, "kept", "user_message", "run-1")
    |> World.numbered_run(thread, 2, "cancelled")
    |> World.add_item(thread, "gone-1", "user_message", "run-2", %{
      "inputIntent" => "queued_turn"
    })
    |> Map.put(:hidden, ["gone-1"])
  end

  step "{string} has an unpaired interrupt result of a superseded attempt",
       %{args: [thread]} = context do
    attempt = %{
      "id" => "attempt-1",
      "runId" => "run-1",
      "rootNodeId" => "node-run-1",
      "status" => "superseded"
    }

    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.put_entity(thread, "run-attempt", "attempt-1", %{"s" => attempt})
    |> World.add_item(thread, "kept", "assistant_message", "run-1")
    |> World.add_item(thread, "gone-1", "run_interrupt_result", "run-1")
    |> Map.put(:hidden, ["gone-1"])
  end

  step "those items are not shown", context do
    ids = Enum.map(context.timeline, & &1["id"])
    assert "kept" in ids
    assert Enum.all?(context.hidden, &(&1 not in ids))
    context
  end

  # --- legacy selections and the archived snapshot -------------------------------------

  step "{string} was stored with a model selection that names provider {string}",
       %{args: [thread, provider]} = context do
    World.patch_thread(context, thread, %{
      "modelSelection" => %{"provider" => provider, "model" => "gpt-5.4"}
    })
  end

  step "the shell row of {string} shows instance {string} and the model",
       %{args: [thread, instance]} = context do
    assert World.row(context, thread)["modelSelection"] == %{
             "instanceId" => instance,
             "model" => "gpt-5.4"
           }

    context
  end

  step ~r/^"(?<a>[^"]+)" is archived and "(?<b>[^"]+)" is active and "(?<c>[^"]+)" is archived and deleted$/,
       %{args: [archived, active, deleted]} = context do
    context =
      context
      |> World.named_thread(active)
      |> World.named_thread(deleted)
      |> archive(archived)
      |> archive(deleted)
      |> World.command(%{"type" => "thread.delete", "threadId" => deleted})

    assert {:ok, _} = context.reply
    World.await_row(deleted, &(&1["deletedAt"] != nil))
    context
  end

  step "a client asks for the archived shell snapshot", context do
    {snapshot, context} = World.call!(context, "orchestration.getArchivedShellSnapshot")
    Map.put(context, :snapshot, snapshot)
  end

  step "it contains {string} and project {string}", %{args: [thread, project]} = context do
    assert World.thread_id(context, thread) in Enum.map(context.snapshot["threads"], & &1["id"])

    assert World.project(context, project).id in Enum.map(
             context.snapshot["projects"],
             & &1["id"]
           )

    context
  end

  step "it does not contain {string} or {string}", %{args: [a, b]} = context do
    ids = Enum.map(context.snapshot["threads"], & &1["id"])
    refute a in ids
    refute b in ids
    context
  end

  defp archive(context, thread) do
    context = World.command(context, %{"type" => "thread.archive", "threadId" => thread})
    assert {:ok, _} = context.reply
    World.await_row(thread, &(&1["archivedAt"] != nil))
    context
  end

  # --- activity time -------------------------------------------------------------------

  step ~r/^the latest event on "(?<thread>[^"]+)" happened at (?<time>\d\d:\d\d)$/,
       %{args: [thread, time]} = context do
    at = today(time)
    {:ok, ms} = at |> DateTime.from_iso8601() |> then(fn {:ok, dt, _} -> {:ok, dt} end)
    id = World.thread_id(context, thread)

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"thread", id, %{"s" => %{"title" => "Renamed"}}, DateTime.to_unix(ms, :millisecond)}
      ])

    World.await_row(id, &(&1["title"] == "Renamed"))
    Map.put(context, :event_at, at)
  end

  step ~r/^the shell row of "(?<thread>[^"]+)" was updated at (?<time>\d\d:\d\d)$/,
       %{args: [thread, time]} = context do
    assert World.row(context, thread)["updatedAt"] == today(time)
    context
  end

  # --- subscriptions -------------------------------------------------------------------

  step ~r/^a client saw "(?<thread>[^"]+)" up to sequence (?<seq>\d+)$/,
       %{args: [thread, seq]} = context do
    seq = String.to_integer(seq)
    id = World.thread_id(context, thread)

    # Commit to the thread until its log runs past the sequence the client saw.
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while(nil, fn i, _ ->
      {:ok, last} =
        HalC2.Streams.commit(id, :thread, [{"thread", id, %{"s" => %{"title" => "Title #{i}"}}}])

      if last > seq + 5, do: {:halt, last}, else: {:cont, last}
    end)

    assert Enum.any?(World.events(context, thread), &(&1.seq <= seq))
    context
  end

  step ~r/^it subscribes to "(?<thread>[^"]+)" after sequence (?<seq>\d+)$/,
       %{args: [thread, seq]} = context do
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => thread}
    client = World.client(context)

    client =
      HalC2.Test.WsClient.send_json(client, %{
        "t" => "sub",
        "id" => 41,
        "shape" => shape,
        "offset" => String.to_integer(seq)
      })

    {frames, client} = until_live(client, [])
    context |> World.put_client(client) |> Map.put(:frames, frames)
  end

  step ~r/^it receives only events after (?<seq>\d+) and a completion marker$/,
       %{args: [seq]} = context do
    seq = String.to_integer(seq)
    {live, frames} = List.pop_at(context.frames, -1)
    assert live["t"] == "live"
    assert frames != []
    assert Enum.all?(frames, &(&1["t"] == "events"))
    seqs = for frame <- frames, [s | _] <- frame["events"], do: s
    assert seqs != [] and Enum.all?(seqs, &(&1 > seq))
    context
  end

  defp until_live(client, acc) do
    {frame, client} = Mc.await(client, &(&1["id"] == 41))

    if frame["t"] == "live",
      do: {Enum.reverse([frame | acc]), client},
      else: until_live(client, [frame | acc])
  end

  # --- the full projection ------------------------------------------------------------

  step "{string} has a finished run with a message, an item, a plan, a checkpoint and a pending request",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    at = World.iso_from_now(0)
    owned = %{"threadId" => id, "runId" => "run-1", "createdAt" => at, "updatedAt" => at}

    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.add_message(thread, "user", "total the cart", at, %{"id" => "msg-1"})
    |> World.add_item(thread, "item-1", "assistant_message", "run-1")
    |> World.put_entity(thread, "plan", "plan-1", %{
      "s" =>
        Map.merge(owned, %{"id" => "plan-1", "kind" => "proposed_plan", "status" => "active"})
    })
    |> World.put_entity(thread, "checkpoint", "cp-1", %{
      "s" => Map.merge(owned, %{"id" => "cp-1", "status" => "ready"})
    })
    |> World.put_entity(thread, "runtime-request", "request-1", %{
      "s" => Map.merge(owned, %{"id" => "request-1", "kind" => "approval", "status" => "pending"})
    })
    |> Map.put(:thread, thread)
  end

  step "a client asks for the projection of {string}", %{args: [thread]} = context do
    {reply, context} =
      World.call!(context, "hal-c2.threadRows", %{"threadId" => World.thread_id(context, thread)})

    Map.merge(context, %{thread: thread, projection: reply})
  end

  step "it receives the thread, its runs, items, messages, plans, checkpoints and requests",
       context do
    ids =
      for [kind, id, _entity] <- context.projection["rows"], into: MapSet.new(), do: {kind, id}

    for expected <- [
          {"thread", World.thread_id(context, context.thread)},
          {"run", "run-1"},
          {"turn-item", "item-1"},
          {"message", "msg-1"},
          {"plan", "plan-1"},
          {"checkpoint", "cp-1"},
          {"runtime-request", "request-1"}
        ],
        do: assert(expected in ids, "#{inspect(expected)} is missing from the projection")

    context
  end

  step "it receives the sequence the projection is at", context do
    state = World.state(context, context.thread)
    assert context.projection["offset"] == state.seq
    assert context.projection["at"] == state.updated_at
    context
  end

  # --- refused methods -----------------------------------------------------------------

  step "a client calls {string}", %{args: [method]} = context do
    {reply, context} = World.call(context, method, %{})
    Map.put(context, :reply, World.normalize_reply(reply))
  end
end
