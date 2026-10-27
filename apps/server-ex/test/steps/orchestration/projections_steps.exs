defmodule HalC2.Steps.Orchestration.Projections do
  @moduledoc "Steps for features/mc/orchestration/projections.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Test.WsClient

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

  # --- windows ------------------------------------------------------------------------

  step ~r/^"(?<thread>[^"]+)" has a very long history$/, %{args: [thread]} = context do
    {:ok, _} = HalC2.Streams.commit(thread, :thread, Enum.flat_map(1..6, &turn/1))

    # The commands scenarios use the same words for the thread itself: give it
    # a history to not read, and trace the reads from here on.
    if (context[:threads] || %{})[thread],
      do: HalC2.Steps.Orchestration.Commands.long_history(context, thread),
      else: context
  end

  step ~r/^a client subscribes to "(?<thread>[^"]+)" with a window$/,
       %{args: [thread]} = context do
    client = windowed(World.client(context), thread, 4)
    {frames, client} = until_live(client, [])
    context |> World.put_client(client) |> Map.merge(%{frames: frames, thread: thread})
  end

  step "it receives the newest part of the history with a marker that older history exists",
       context do
    {live, snapshots} = List.pop_at(context.frames, -1)
    assert live["t"] == "live"
    assert Enum.all?(snapshots, &(&1["t"] == "snapshot"))
    # The two newest turns hold the four items asked for; the floor says more lie before.
    assert List.last(snapshots)["floor"] == 5
    assert items(snapshots) == ~w(item-5-1 item-5-2 item-5-3 item-6-1 item-6-2 item-6-3)
    Map.put(context, :offset, live["offset"])
  end

  step "it can page older history on request", context do
    client = WsClient.send_json(World.client(context), %{"t" => "more", "id" => 41, "items" => 3})
    {page, client} = Mc.await(client, &(&1["t"] == "page" and &1["id"] == 41))
    assert %{"floor" => 4, "done" => true} = page
    assert items([page]) == ~w(item-4-1 item-4-2 item-4-3)
    World.put_client(context, client)
  end

  step "then it receives live events after the snapshot's sequence", context do
    change = {"turn-item", "item-6-3", %{"a" => %{"text" => "more"}}}
    {:ok, seq} = HalC2.Streams.commit(context.thread, :thread, [change])
    {frame, client} = Mc.await(World.client(context), &(&1["t"] == "events" and &1["id"] == 41))
    assert seq > context.offset
    assert [[^seq, "turn-item", "item-6-3", _patch, _at]] = frame["events"]
    World.put_client(context, client)
  end

  step ~r/^"(?<thread>[^"]+)" has a message queued before a very long history$/,
       %{args: [thread]} = context do
    queued = %{
      "id" => "run-0",
      "ordinal" => 0,
      "status" => "queued",
      "userMessageId" => "message-0"
    }

    message = %{
      "id" => "message-0",
      "runId" => "run-0",
      "role" => "user",
      "text" => "check the logs"
    }

    changes = [{"run", "run-0", %{"s" => queued}}, {"message", "message-0", %{"s" => message}}]
    {:ok, _} = HalC2.Streams.commit(thread, :thread, changes ++ Enum.flat_map(1..6, &turn/1))
    context
  end

  step "the snapshot holds the queued message", context do
    {_live, snapshots} = List.pop_at(context.frames, -1)
    assert List.last(snapshots)["floor"] == 5
    assert for(frame <- snapshots, ["message", id, _] <- frame["rows"], do: id) == ["message-0"]
    context
  end

  step ~r/^"(?<thread>[^"]+)" has hidden and visible earlier turns$/,
       %{args: [thread]} = context do
    rolled_back = {"run", "run-2", %{"s" => %{"status" => "rolled_back"}}}

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, Enum.flat_map(1..4, &turn/1) ++ [rolled_back])

    context
  end

  # The window scenarios page over their subscription; the history scenarios
  # (whose Givens set `:bounded_via`) page a bounded snapshot by its cursor.
  step ~r/^a client asks for a bounded page of the history of "(?<thread>[^"]+)"$/,
       %{args: [thread]} = context do
    if context[:bounded_via] == :rpc do
      {reply, context} =
        World.call!(context, "hal-c2.threadRows", %{
          "threadId" => World.thread_id(context, thread),
          "bounded" => true
        })

      Map.put(context, :bounded_page, reply)
    else
      client = windowed(World.client(context), thread, 1)
      {_frames, client} = until_live(client, [])
      client = WsClient.send_json(client, %{"t" => "more", "id" => 41, "items" => 100})
      {page, client} = Mc.await(client, &(&1["t"] == "page" and &1["id"] == 41))
      context |> World.put_client(client) |> Map.put(:page, page)
    end
  end

  step "the page holds only visible turns", context do
    assert items([context.page]) ==
             ~w(item-1-1 item-1-2 item-1-3 item-3-1 item-3-2 item-3-3)

    context
  end

  step "it ends at the true start of the history", context do
    assert %{"floor" => nil, "done" => true} = context.page
    context
  end

  # One run and its three turn items.
  defp turn(n) do
    run = %{"id" => "run-#{n}", "ordinal" => n, "status" => "completed"}

    [
      {"run", run["id"], %{"s" => run}}
      | for i <- 1..3 do
          item = %{"id" => "item-#{n}-#{i}", "runId" => run["id"], "type" => "reasoning"}
          {"turn-item", item["id"], %{"s" => Map.put(item, "ordinal", n * 10 + i)}}
        end
    ]
  end

  defp windowed(client, thread, items) do
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => thread}

    WsClient.send_json(client, %{
      "t" => "sub",
      "id" => 41,
      "shape" => shape,
      "window" => %{"items" => items}
    })
  end

  defp items(frames),
    do: for(frame <- frames, ["turn-item", id, _] <- frame["rows"], do: id)

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

  # --- subagent text on the wire --------------------------------------------------------

  step ~r/^a subagent in "(?<thread>[^"]+)" has progress that grows by appends past 32,768 bytes$/,
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    item = %{
      "id" => "sub-item",
      "type" => "subagent",
      "runId" => "run-1",
      "progress" => "Reading"
    }

    {:ok, _} = HalC2.Streams.commit(id, :thread, [{"turn-item", item["id"], %{"s" => item}}])
    Map.put(context, :thread, thread)
  end

  # The client is following when the progress grows: two appends in one commit take it
  # past the limit, and a third is to text already past it.
  step ~r/^a client follows "(?<thread>[^"]+)" while the progress grows past the limit$/,
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    {frames, client} = context |> World.client() |> Mc.sub(41, shape(id)) |> until_live([])
    append = {"turn-item", "sub-item", %{"a" => %{"progress" => String.duplicate("x", 20_000)}}}
    {:ok, _} = HalC2.Streams.commit(id, :thread, [append, append])
    {:ok, past} = HalC2.Streams.commit(id, :thread, [append])
    title = {"thread", id, %{"s" => %{"title" => "Followed"}}}
    {:ok, last} = HalC2.Streams.commit(id, :thread, [title])
    {events, client} = events_until(client, last, [])

    context
    |> World.put_client(client)
    |> Map.merge(%{frames: frames, events: events, past: past})
  end

  step ~r/^the progress it holds is the cut text a fresh read of "(?<thread>[^"]+)" shows$/,
       %{args: [thread]} = context do
    held =
      Enum.reduce(context.events, row(context.frames, "sub-item"), fn
        [_seq, "turn-item", "sub-item", patch, _at], item -> HalC2.Patch.apply(item, patch)
        _event, item -> item
      end)

    id = World.thread_id(context, thread)
    {fresh, client} = context |> World.client("fresh") |> Mc.sub(41, shape(id)) |> until_live([])
    assert held["progress"] == row(fresh, "sub-item")["progress"]
    assert String.ends_with?(held["progress"], "… output truncated for transport")
    World.put_client(context, "fresh", client)
  end

  step "the appends past the limit are not sent", context do
    refute Enum.any?(context.events, &(hd(&1) == context.past))
    context
  end

  defp shape(stream),
    do: %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => stream}

  defp row(frames, id),
    do: hd(for frame <- frames, ["turn-item", ^id, entity] <- frame["rows"] || [], do: entity)

  defp events_until(client, seq, acc) do
    {frame, client} = Mc.await(client, &(&1["t"] == "events" and &1["id"] == 41))
    acc = acc ++ frame["events"]

    if Enum.any?(frame["events"], &(hd(&1) == seq)),
      do: {acc, client},
      else: events_until(client, seq, acc)
  end

  # --- a cancelled queued run ----------------------------------------------------

  step "run 1 of {string} is running and run 2 was queued behind it",
       %{args: [thread]} = context do
    context
    |> World.numbered_run(thread, 1, "running")
    |> World.numbered_run(thread, 2, "queued")
    |> Map.put(:thread, thread)
  end

  step "run 2 is cancelled before it starts", context do
    World.numbered_run(context, context.thread, 2, "cancelled", %{"startedAt" => nil})
  end

  step "the shell row of {string} has status {string} because run 2 is the latest run",
       %{args: [thread, status]} = context do
    row = World.row(context, thread)
    assert row["status"] == status
    assert row["latestRunId"] == "run-2"
    context
  end

  step "the activity start time is the start of run 1", context do
    run = Enum.find(World.entities(context, context.thread, "run"), &(&1["id"] == "run-1"))
    assert World.row(context, context.thread)["activityRunStartedAt"] == run["startedAt"]
    context
  end

  # --- bounded snapshots and history pages ----------------------------------------

  step "{string} has {int} user turns", %{args: [thread, n]} = context do
    commit_turns(context, thread, 1..n)
  end

  step "a client asks for a bounded snapshot of {string}", %{args: [thread]} = context do
    {reply, context} =
      World.call!(context, "hal-c2.threadRows", %{
        "threadId" => World.thread_id(context, thread),
        "bounded" => true
      })

    Map.merge(context, %{thread: thread, bounded: reply})
  end

  step "it receives the newest 10 user turns and a cursor for older history", context do
    turns = user_turns(context.bounded)
    assert length(turns) == 10
    assert hd(turns) == "u-51"
    assert context.bounded["hasMoreHistory"] == true
    assert is_binary(context.bounded["historyCursor"])
    context
  end

  step "it asks for the page before that cursor", context do
    ask_page_before(context, context.bounded["historyCursor"])
  end

  step "it receives the 20 user turns before them", context do
    turns = user_turns(context.page_reply)
    assert length(turns) == 20
    assert hd(turns) == "u-31"
    assert List.last(turns) == "u-50"
    context
  end

  step "an earlier turn of {string} ran hundreds of tool calls and was steered twice",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    run = %{"id" => "run-1", "threadId" => id, "ordinal" => 1, "status" => "completed"}

    changes =
      [{"run", "run-1", %{"s" => run}}, history_item("u-1", "run-1", user_turn())] ++
        for(i <- 1..300, do: history_item("tool-#{i}", "run-1", %{"type" => "tool_call"})) ++
        [
          history_item("steer-1", "run-1", %{
            "type" => "user_message",
            "inputIntent" => "steer",
            "createdBy" => "user"
          }),
          history_item("steer-2", "run-1", %{
            "type" => "user_message",
            "inputIntent" => "steer",
            "createdBy" => "user"
          }),
          history_item("last", "run-1", %{"type" => "assistant_message"})
        ]

    {:ok, _} = HalC2.Streams.commit(id, :thread, changes)
    context |> commit_turns(thread, 2..12) |> Map.put(:thread, thread)
  end

  step "a client pages back to that turn", context do
    {reply, context} =
      World.call!(context, "hal-c2.threadRows", %{
        "threadId" => World.thread_id(context, context.thread),
        "bounded" => true
      })

    page_back_until(context, reply["historyCursor"])
  end

  defp page_back_until(context, nil), do: flunk("the history ended before the turn was reached")

  defp page_back_until(context, cursor) do
    context = ask_page_before(context, cursor)

    if "u-1" in reply_item_ids(context.page_reply),
      do: context,
      else: page_back_until(context, context.page_reply["historyCursor"])
  end

  step "the page holds the whole turn, from the user's message to its last item", context do
    ids = reply_item_ids(context.page_reply)
    turn = ids |> Enum.drop_while(&(&1 != "u-1")) |> Enum.take_while(&(&1 != "u-2"))
    assert hd(turn) == "u-1"
    assert List.last(turn) == "last"
    assert length(Enum.filter(turn, &String.starts_with?(&1, "tool-"))) == 300
    context
  end

  step "the steering messages do not count as turns of their own", context do
    turn =
      context.page_reply
      |> reply_items()
      |> Enum.drop_while(&(&1["id"] != "u-1"))
      |> Enum.take_while(&(&1["id"] != "u-2"))

    assert Enum.count(turn, &(&1["id"] in ["steer-1", "steer-2"])) == 2
    assert Enum.count(turn, &HalC2.Projection.History.user_turn?/1) == 1
    context
  end

  step "{string} has hundreds of turns started by background work between two user messages",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    automatic =
      Enum.flat_map(2..301, fn n ->
        run = %{"id" => "run-#{n}", "threadId" => id, "ordinal" => n, "status" => "completed"}

        [
          {"run", "run-#{n}", %{"s" => run}},
          history_item("auto-#{n}", "run-#{n}", %{
            "type" => "user_message",
            "inputIntent" => "turn_start",
            "createdBy" => "agent"
          })
        ]
      end)

    context = commit_turns(context, thread, 1..1)
    {:ok, _} = HalC2.Streams.commit(id, :thread, automatic)

    context
    |> commit_turns(thread, 302..302)
    |> Map.merge(%{thread: thread, bounded_via: :rpc})
  end

  step "the page holds at most 150 turns of any kind", context do
    starts =
      Enum.count(reply_items(context.bounded_page), &HalC2.Projection.History.turn_start?/1)

    assert starts <= 150
    assert context.bounded_page["hasMoreHistory"] == true
    context
  end

  step "{string} holds imported history that records no turn starts",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    run = %{"id" => "run-1", "threadId" => id, "ordinal" => 1, "status" => "completed"}

    changes =
      [{"run", "run-1", %{"s" => run}}] ++
        for(i <- 1..124, do: history_item("i-#{i}", "run-1", %{"type" => "assistant_message"})) ++
        [
          history_item("huge", "run-1", %{
            "type" => "assistant_message",
            "text" => String.duplicate("x", 2_000_000)
          })
        ] ++
        for(i <- 126..200, do: history_item("i-#{i}", "run-1", %{"type" => "assistant_message"}))

    {:ok, _} = HalC2.Streams.commit(id, :thread, changes)
    Map.merge(context, %{thread: thread, bounded_via: :rpc})
  end

  step "the page holds at most 75 items and about one megabyte", context do
    ids = reply_item_ids(context.bounded_page)
    assert length(ids) <= 75
    assert byte_size(JSON.encode!(context.bounded_page["rows"])) <= 1_048_576
    context
  end

  # The page after the bounded one starts with the oversized item: however
  # large it is, a page holds it rather than stalling on it forever.
  step "it holds at least one item, however large that item is", context do
    context = ask_page_before(context, context.bounded_page["historyCursor"])
    assert reply_item_ids(context.page_reply) == ["huge"]
    context
  end

  step ~r/^a client asks for older history of "(?<thread>[^"]+)" with (?<cursor>.+)$/,
       %{args: [thread, which]} = context do
    cursor =
      case which do
        "an empty cursor" -> ""
        "a cursor the MC never gave" -> "never-given-by-anyone"
        "a cursor longer than 4,096 characters" -> String.duplicate("a", 4_097)
      end

    {reply, context} =
      World.call(context, "hal-c2.threadRows", %{
        "threadId" => World.thread_id(context, thread),
        "cursor" => cursor
      })

    Map.put(context, :reply, reply)
  end

  step "the request fails as an invalid history cursor", context do
    assert {:error, "Invalid thread history cursor.",
            %{"_tag" => "InvalidThreadHistoryCursorError"}} =
             context.reply

    context
  end

  step "a client holds a cursor into the history of {string}", %{args: [thread]} = context do
    context = commit_turns(context, thread, 1..40)

    {reply, context} =
      World.call!(context, "hal-c2.threadRows", %{
        "threadId" => World.thread_id(context, thread),
        "bounded" => true
      })

    context =
      context
      |> Map.merge(%{thread: thread, cursor: reply["historyCursor"]})
      |> ask_page_before(reply["historyCursor"])

    Map.put(context, :expected_page, reply_item_ids(context.page_reply))
  end

  step "{string} gains new turns", %{args: [thread]} = context do
    commit_turns(context, thread, 41..45)
  end

  step "the client asks for the page before that cursor", context do
    ask_page_before(context, context.cursor)
  end

  step "it receives the same older turns as before, with none skipped or repeated", context do
    assert reply_item_ids(context.page_reply) == context.expected_page
    context
  end

  step "the item the cursor names has since left the timeline", context do
    {:ok, %{"si" => item_id}} = HalC2.Projection.History.decode_cursor(context.cursor)
    item = Enum.find(World.entities(context, context.thread, "turn-item"), &(&1["id"] == item_id))
    id = World.thread_id(context, context.thread)

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"run", item["runId"], %{"s" => %{"status" => "rolled_back"}}}
      ])

    context
  end

  step "it receives the turns before the position the cursor recorded", context do
    ids = reply_item_ids(context.page_reply)
    assert hd(ids) == "u-11"
    assert List.last(ids) == "a-30"
    refute "u-31" in ids
    context
  end

  step "an active proposed plan, a pending handoff, a pending approval and a queued message are older than its newest turns",
       context do
    thread = "t1"
    id = World.thread_id(context, thread)

    context =
      context
      |> World.put_entity(thread, "plan", "plan-1", %{
        "s" => %{
          "id" => "plan-1",
          "threadId" => id,
          "kind" => "proposed_plan",
          "status" => "active",
          "markdown" => "# Plan"
        }
      })
      |> World.put_entity(thread, "context-handoff", "handoff-1", %{
        "s" => %{
          "id" => "handoff-1",
          "threadId" => id,
          "status" => "pending",
          "summaryText" => "the story"
        }
      })
      |> World.put_entity(thread, "runtime-request", "request-1", %{
        "s" => %{
          "id" => "request-1",
          "threadId" => id,
          "kind" => "approval",
          "status" => "pending"
        }
      })
      |> World.put_entity(thread, "run", "run-queued", %{
        "s" => %{
          "id" => "run-queued",
          "threadId" => id,
          "ordinal" => 900,
          "status" => "queued",
          "userMessageId" => "queued-msg"
        }
      })
      |> World.put_entity(thread, "message", "queued-msg", %{
        "s" => %{
          "id" => "queued-msg",
          "threadId" => id,
          "runId" => "run-queued",
          "role" => "user",
          "text" => "later please"
        }
      })

    commit_turns(context, thread, 1..30)
  end

  step "the snapshot still carries the plan, the handoff, the approval and the queued message",
       context do
    rows = Map.new(context.bounded["rows"], fn [kind, id, entity] -> {{kind, id}, entity} end)
    assert rows[{"plan", "plan-1"}]["status"] == "active"
    assert rows[{"context-handoff", "handoff-1"}]["status"] == "pending"
    assert rows[{"runtime-request", "request-1"}]["status"] == "pending"
    assert rows[{"message", "queued-msg"}]["text"] == "later please"
    context
  end

  step "the newest turns of {string} include a completed plan and a finished handoff",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    context
    |> commit_turns(thread, 1..3)
    |> World.add_item(thread, "pp-1", "proposed_plan", "run-3", %{"planId" => "plan-1"})
    |> World.add_item(thread, "ho-1", "handoff", "run-3", %{"contextHandoffId" => "handoff-1"})
    |> World.put_entity(thread, "plan", "plan-1", %{
      "s" => %{
        "id" => "plan-1",
        "threadId" => id,
        "kind" => "proposed_plan",
        "status" => "completed",
        "markdown" => "# The finished plan text"
      }
    })
    |> World.put_entity(thread, "context-handoff", "handoff-1", %{
      "s" => %{
        "id" => "handoff-1",
        "threadId" => id,
        "status" => "superseded",
        "summaryText" => "the handoff summary text"
      }
    })
    |> Map.put(:thread, thread)
  end

  step "each carries its status and says its detail is in its timeline item", context do
    rows = Map.new(context.bounded["rows"], fn [kind, id, entity] -> {{kind, id}, entity} end)
    assert rows[{"plan", "plan-1"}]["status"] == "completed"
    assert rows[{"plan", "plan-1"}]["detailInTurnItem"] == true
    assert rows[{"context-handoff", "handoff-1"}]["status"] == "superseded"
    assert rows[{"context-handoff", "handoff-1"}]["detailInTurnItem"] == true

    Map.merge(context, %{bounded_rows: rows})
  end

  step "neither carries the plan text or the handoff summary a second time", context do
    refute context.bounded_rows[{"plan", "plan-1"}]["markdown"] =~ "finished plan text"
    refute context.bounded_rows[{"context-handoff", "handoff-1"}]["summaryText"] =~ "summary text"
    context
  end

  step "what the user can still act on in {string} is larger than one megabyte",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    context
    |> World.put_entity(thread, "plan", "plan-1", %{
      "s" => %{
        "id" => "plan-1",
        "threadId" => id,
        "kind" => "proposed_plan",
        "status" => "active",
        "markdown" => String.duplicate("x", 1_100_000)
      }
    })
    |> World.put_entity(thread, "runtime-request", "request-1", %{
      "s" => %{"id" => "request-1", "threadId" => id, "kind" => "approval", "status" => "pending"}
    })
    |> commit_turns(thread, 1..3)
    |> Map.put(:thread, thread)
  end

  step "nothing the user can act on is left out", context do
    rows = Map.new(context.bounded["rows"], fn [kind, id, entity] -> {{kind, id}, entity} end)
    assert rows[{"plan", "plan-1"}]["status"] == "active"
    assert rows[{"runtime-request", "request-1"}] != nil
    context
  end

  step "the snapshot is marked as over its payload budget", context do
    assert context.bounded["payloadBudgetExceeded"] == true
    context
  end

  # One run per turn in `range`, opened by its user message, with one reply.
  defp commit_turns(context, thread, range) do
    id = World.thread_id(context, thread)

    changes =
      Enum.flat_map(range, fn n ->
        run = %{"id" => "run-#{n}", "threadId" => id, "ordinal" => n, "status" => "completed"}

        [
          {"run", "run-#{n}", %{"s" => run}},
          history_item("u-#{n}", "run-#{n}", user_turn()),
          history_item("a-#{n}", "run-#{n}", %{"type" => "assistant_message"})
        ]
      end)

    {:ok, _} = HalC2.Streams.commit(id, :thread, changes)
    context
  end

  defp user_turn,
    do: %{"type" => "user_message", "inputIntent" => "turn_start", "createdBy" => "user"}

  defp history_item(id, run_id, fields) do
    item = Map.merge(%{"id" => id, "runId" => run_id, "status" => "completed"}, fields)
    {"turn-item", id, %{"s" => item}}
  end

  defp ask_page_before(context, cursor) do
    {reply, context} =
      World.call!(context, "hal-c2.threadRows", %{
        "threadId" => World.thread_id(context, context.thread),
        "cursor" => cursor
      })

    Map.put(context, :page_reply, reply)
  end

  defp reply_items(reply), do: for(["turn-item", _id, entity] <- reply["rows"], do: entity)
  defp reply_item_ids(reply), do: Enum.map(reply_items(reply), & &1["id"])

  defp user_turns(reply) do
    reply
    |> reply_items()
    |> Enum.filter(&HalC2.Projection.History.user_turn?/1)
    |> Enum.map(& &1["id"])
  end

  # --- what a thread subscriber is sent --------------------------------------------

  step "{string} has a command that printed a long output", %{args: [thread]} = context do
    wire_item(context, thread, "cmd-1", "command_execution", %{
      "input" => "npm test",
      "exitCode" => 3,
      "output" => String.duplicate("a very long line of output\n", 200)
    })
  end

  step "{string} has a file change", %{args: [thread]} = context do
    wire_item(context, thread, "fc-1", "file_change", %{
      "fileName" => "a.txt",
      "additions" => 4,
      "deletions" => 1,
      "diffStr" => "--- a/a.txt\n+++ b/a.txt\n-one\n+two",
      "oldStr" => "one",
      "newStr" => "two"
    })
  end

  step "{string} has a call to a tool the provider defined", %{args: [thread]} = context do
    wire_item(context, thread, "dt-1", "dynamic_tool", %{
      "toolName" => "hal_c2_thread_launch",
      "input" => %{"title" => "spawn"},
      "output" => %{
        "threadId" => "th-new",
        "isError" => true,
        "raw" => String.duplicate("raw ", 100)
      }
    })
  end

  step "{string} has a handoff to another provider", %{args: [thread]} = context do
    wire_item(context, thread, "ho-1", "handoff", %{
      "contextHandoffId" => "handoff-1",
      "summary" => "the story so far, at length",
      "fromProviderInstanceIds" => ["codex"],
      "toProviderInstanceId" => "claudeAgent",
      "fromModelSelections" => [%{"instanceId" => "codex", "model" => "gpt-5.4"}],
      "toModel" => "opus"
    })
  end

  step "a client reads or follows {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    {frames, client} = context |> World.client() |> Mc.sub(41, shape(id)) |> until_live([])
    Mc.unsub(client, 41)

    rows =
      for frame <- frames,
          [kind, entity_id, entity] <- frame["rows"] || [],
          into: %{},
          do: {{kind, entity_id}, entity}

    context |> World.put_client(client) |> Map.merge(%{thread: thread, wire_rows: rows})
  end

  step "the item arrives without the output", context do
    refute Map.has_key?(wire_entity(context), "output")
    context
  end

  step "the item arrives without the before and after text and the diff", context do
    entity = wire_entity(context)
    refute Map.has_key?(entity, "diffStr")
    refute Map.has_key?(entity, "oldStr")
    refute Map.has_key?(entity, "newStr")
    context
  end

  step "the item arrives without the tool's raw output", context do
    refute JSON.encode!(wire_entity(context)) =~ "raw raw"
    context
  end

  step "the item arrives without the handoff summary", context do
    refute Map.has_key?(wire_entity(context), "summary")
    context
  end

  step "it still carries the command and its exit code", context do
    entity = wire_entity(context)
    assert entity["input"] == "npm test"
    assert entity["exitCode"] == 3
    context
  end

  step "it still carries the file and its change counts", context do
    entity = wire_entity(context)
    assert entity["fileName"] == "a.txt"
    assert entity["additions"] == 4
    assert entity["deletions"] == 1
    context
  end

  step "it still carries the ids the result named and whether it failed", context do
    assert wire_entity(context)["output"] == %{"threadId" => "th-new", "isError" => true}
    context
  end

  step "it still carries the providers and models it went between", context do
    entity = wire_entity(context)
    assert entity["fromProviderInstanceIds"] == ["codex"]
    assert entity["toProviderInstanceId"] == "claudeAgent"
    assert entity["fromModelSelections"] == [%{"instanceId" => "codex", "model" => "gpt-5.4"}]
    assert entity["toModel"] == "opus"
    context
  end

  step "a command in {string} exited with code 0 but its output reports an error",
       %{args: [thread]} = context do
    wire_item(context, thread, "cmd-1", "command_execution", %{
      "input" => "frobnicate --all",
      "exitCode" => 0,
      "output" => "bash: frobnicate: command not found"
    })
  end

  step "the command arrives without its output", context do
    refute Map.has_key?(wire_entity(context), "output")
    context
  end

  step "it is marked as having failed", context do
    assert wire_entity(context)["outputIndicatesFailure"] == true
    context
  end

  step ~r/^a subagent in "(?<thread>[^"]+)" has a prompt, progress or result longer than 32,768 bytes$/,
       %{args: [thread]} = context do
    long = String.duplicate("é", 20_000)

    wire_item(context, thread, "sub-1", "subagent", %{
      "prompt" => long,
      "progress" => long,
      "result" => long
    })
  end

  step "the text is cut at 32,768 bytes without splitting a character", context do
    for field <- ~w(prompt progress result) do
      text = wire_entity(context)[field]
      assert String.valid?(text)
      held = String.trim_trailing(text, "\n… output truncated for transport")
      assert byte_size(held) <= 32_768
      assert byte_size(held) > 32_768 - 4
    end

    context
  end

  step "it ends with {string}", %{args: [suffix]} = context do
    for field <- ~w(prompt progress result),
        do: assert(String.ends_with?(wire_entity(context)[field], suffix))

    context
  end

  step ~r/^a call to a provider-defined tool in "(?<thread>[^"]+)" has an input larger than 16,384 bytes$/,
       %{args: [thread]} = context do
    context =
      wire_item(context, thread, "dt-big", "dynamic_tool", %{
        "toolName" => "do_thing",
        "input" => "\n\nfirst line here\n" <> String.duplicate("x", 20_000)
      })

    context
    |> World.add_item(thread, "dt-small", "dynamic_tool", "run-1", %{
      "toolName" => "do_thing",
      "input" => "small input"
    })
    |> Map.put(:wire_item, "dt-big")
  end

  step "the input arrives as its first non-blank line, cut to 160 characters, marked truncated",
       context do
    input = wire_entity(context)["input"]
    assert input == %{"summary" => "first line here", "truncated" => true}
    assert String.length(input["summary"]) <= 160
    context
  end

  step "a smaller input arrives unchanged", context do
    assert context.wire_rows[{"turn-item", "dt-small"}]["input"] == "small input"
    context
  end

  step "{string} was handed off with its conversation history and a summary",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    context
    |> World.put_entity(thread, "context-handoff", "handoff-1", %{
      "s" => %{
        "id" => "handoff-1",
        "threadId" => id,
        "status" => "ready",
        "summaryText" => "the story so far",
        "history" => %{
          "messages" => [%{"role" => "user", "text" => "everything said"}],
          "coverage" => "all",
          "omittedItems" => 0
        },
        "delivery" => %{"nativeThreadId" => "native-1", "status" => "injected", "itemIds" => []}
      }
    })
    |> Map.put(:thread, thread)
  end

  step "the handoff arrives with its status", context do
    assert context.wire_rows[{"context-handoff", "handoff-1"}]["status"] == "ready"
    context
  end

  step "without the history, the delivery record or the summary text", context do
    handoff = context.wire_rows[{"context-handoff", "handoff-1"}]
    refute Map.has_key?(handoff, "history")
    refute Map.has_key?(handoff, "delivery")
    assert handoff["summaryText"] == ""
    context
  end

  step "{string} has a file change whose diff was not sent to subscribers",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    root = World.project(context, "demo").root
    scope = HalC2.Checkpoint.scope_id(id)

    :ok = HalC2.Checkpoint.baseline(root, scope, 0)
    File.write!(Path.join(root, "change.txt"), "changed line\n")
    checkpoint = HalC2.Checkpoint.capture_run(root, scope, 1, "run-1", "node-run-1", id, nil)

    scope_entity =
      HalC2.Checkpoint.scope(id, "run-1", "node-run-1", "pt-1", root, World.iso_from_now(0))

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"checkpoint-scope", scope, %{"s" => scope_entity}},
        {"checkpoint", checkpoint["id"], %{"s" => checkpoint}}
      ])

    context =
      context
      |> World.numbered_run(thread, 1, "completed")
      |> wire_item(thread, "fc-1", "file_change", %{
        "fileName" => "change.txt",
        "additions" => 1,
        "deletions" => 0,
        "diffStr" => "the stored diff of the change"
      })
      |> World.add_item(thread, "cmd-1", "command_execution", "run-1", %{
        "input" => "ls",
        "output" => "the stored command output"
      })
      |> World.add_item(thread, "dt-1", "dynamic_tool", "run-1", %{
        "input" => %{},
        "output" => %{"threadId" => "th-new", "raw" => "the stored tool result"}
      })
      |> World.put_entity(thread, "context-handoff", "handoff-1", %{
        "s" => %{
          "id" => "handoff-1",
          "threadId" => id,
          "status" => "ready",
          "summaryText" => "stored summary",
          "history" => %{
            "messages" => [%{"role" => "user", "text" => "the stored transcript"}],
            "coverage" => "all",
            "omittedItems" => 0
          }
        }
      })

    {frames, client} = context |> World.client() |> Mc.sub(41, shape(id)) |> until_live([])
    Mc.unsub(client, 41)

    sent =
      for frame <- frames,
          ["turn-item", "fc-1", entity] <- frame["rows"] || [],
          do: entity

    assert sent != [] and Enum.all?(sent, &(not Map.has_key?(&1, "diffStr")))
    context |> World.put_client(client) |> Map.put(:thread, thread)
  end

  step "a client asks for that change's diff", context do
    {reply, context} =
      World.call!(context, "orchestration.getTurnDiff", %{
        "threadId" => World.thread_id(context, context.thread),
        "fromTurnCount" => 0,
        "toTurnCount" => 1
      })

    Map.put(context, :diff_reply, reply)
  end

  step "it receives the full diff", context do
    assert context.diff_reply["diff"] =~ "change.txt"
    assert context.diff_reply["diff"] =~ "+changed line"
    context
  end

  step "the stored command outputs, tool results and handoff transcripts are unchanged",
       context do
    items = Map.new(World.entities(context, context.thread, "turn-item"), &{&1["id"], &1})
    assert items["fc-1"]["diffStr"] == "the stored diff of the change"
    assert items["cmd-1"]["output"] == "the stored command output"
    assert items["dt-1"]["output"] == %{"threadId" => "th-new", "raw" => "the stored tool result"}

    [handoff] = World.entities(context, context.thread, "context-handoff")

    assert get_in(handoff, ["history", "messages"]) == [
             %{"role" => "user", "text" => "the stored transcript"}
           ]

    assert handoff["summaryText"] == "stored summary"
    context
  end

  defp wire_item(context, thread, id, type, extra) do
    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.add_item(thread, id, type, "run-1", extra)
    |> Map.merge(%{thread: thread, wire_item: id})
  end

  defp wire_entity(context), do: context.wire_rows[{"turn-item", context.wire_item}]

  # --- the shell snapshot and repository details -------------------------------------

  step "project {string} has a repository whose identity is not resolved yet",
       %{args: [project]} = context do
    %{id: id, root: root} = World.project(context, project)
    World.git!(root, ~w(remote add origin https://github.com/acme/demo.git))
    {_kind, row} = HalC2.Shell.row(node(), id)
    assert row["repositoryIdentity"] in [nil, :null]
    Map.put(context, :shell_project, project)
  end

  step "it receives every project and thread row at once", context do
    rows = context.shell_frame["rows"]
    project_id = World.project(context, "demo").id
    thread_id = World.thread_id(context, "t1")
    assert Enum.any?(rows, &match?([_, ^project_id, "project", _], &1))
    assert Enum.any?(rows, &match?([_, ^thread_id, "thread", _], &1))

    [_, _, _, row] = Enum.find(rows, &match?([_, ^project_id, "project", _], &1))
    assert row["repositoryIdentity"] == nil
    context
  end

  step "the repository details of {string} follow as an update that carries no thread rows",
       %{args: [project]} = context do
    project_id = World.project(context, project).id

    {frame, client} =
      Mc.await(World.client(context, "subscriber"), fn frame ->
        frame["t"] == "shell.rows" and frame["id"] == 900 and
          Enum.any?(frame["rows"] || [], fn
            [^project_id, "project", %{"repositoryIdentity" => %{} = identity}] ->
              identity["canonicalKey"] =~ "acme/demo"

            _ ->
              false
          end)
      end)

    assert Enum.all?(frame["rows"], &match?([_, "project", _], &1))
    World.put_client(context, "subscriber", client)
  end

  step "a client loaded the shell snapshot before connecting", context do
    %{root: root, id: project_id} = World.project(context, "demo")
    World.git!(root, ~w(remote add origin https://github.com/acme/demo.git))

    context = shell_subscribe(context)
    [mc] = context.shell_frame["mcs"]

    # The resolution the first subscription set off lands after the snapshot.
    {_frame, client} =
      Mc.await(World.client(context), fn frame ->
        frame["t"] == "shell.rows" and
          Enum.any?(
            frame["rows"] || [],
            &match?([^project_id, "project", %{"repositoryIdentity" => %{}}], &1)
          )
      end)

    client = Mc.unsub(client, 77)

    context
    |> World.put_client(client)
    |> Map.put(:shell_have, %{mc["mc"] => [mc["epoch"], mc["rev"]]})
  end

  step "it subscribes to the shell after that snapshot's sequence", context do
    client =
      WsClient.send_json(World.client(context, "second"), %{
        "t" => "sub",
        "id" => 77,
        "shape" => %{"type" => "shell"},
        "have" => context.shell_have
      })

    {frame, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 77))
    context |> World.put_client("second", client) |> Map.put(:shell_frame, frame)
  end

  step "it receives only what changed since and the repository details that have resolved",
       context do
    project_id = World.project(context, "demo").id

    [_, _, _, row] =
      Enum.find(context.shell_frame["rows"], &match?([_, ^project_id, "project", _], &1))

    assert row["repositoryIdentity"]["canonicalKey"] =~ "acme/demo"
    context
  end

  step "it is not sent the full list of rows again", context do
    [mc] = context.shell_frame["mcs"]
    assert mc["reset"] == false
    project_id = World.project(context, "demo").id
    assert Enum.map(context.shell_frame["rows"], &Enum.at(&1, 1)) == [project_id]
    context
  end

  step "a client is subscribed to the shell", context do
    %{root: root, id: project_id} = World.project(context, "demo")
    World.git!(root, ~w(remote add origin https://github.com/acme/demo.git))
    :ok = HalC2.Projects.identify_repositories()
    World.await_row(project_id, &(&1["repositoryIdentity"] not in [nil, :null]))
    shell_subscribe(context)
  end

  step "the repository details of {string} are refreshed and nothing changed",
       %{args: [project]} = context do
    :ok = HalC2.Projects.identify_repositories()

    # A marker the client must receive: everything up to it is all it was sent.
    context = World.patch_thread(context, "t1", %{"title" => "Marker"})
    {frames, client} = shell_frames_until_marker(World.client(context), [])

    context
    |> World.put_client(client)
    |> Map.merge(%{shell_project: project, shell_frames: frames})
  end

  step "the client receives no second update for {string}", %{args: [project]} = context do
    project_id = World.project(context, project).id

    refute Enum.any?(context.shell_frames, fn frame ->
             Enum.any?(frame["rows"] || [], &match?([^project_id, "project", _], &1))
           end)

    context
  end

  defp shell_subscribe(context) do
    client = Mc.sub(World.client(context), 77, %{"type" => "shell"})
    {frame, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 77))
    context |> World.put_client(client) |> Map.put(:shell_frame, frame)
  end

  defp shell_frames_until_marker(client, acc) do
    {frame, client} = Mc.await(client, &(&1["t"] == "shell.rows" and &1["id"] == 77))
    acc = acc ++ [frame]

    if Enum.any?(frame["rows"] || [], &match?([_, "thread", %{"title" => "Marker"}], &1)),
      do: {acc, client},
      else: shell_frames_until_marker(client, acc)
  end
end
