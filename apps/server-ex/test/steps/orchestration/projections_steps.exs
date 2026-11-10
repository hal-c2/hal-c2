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

  # --- a cancelled queued run ----------------------------------------------------------

  step "run 1 of {string} is running and run 2 was queued behind it",
       %{args: [thread]} = context do
    started = World.iso_from_now(-60)

    context
    |> World.numbered_run(thread, 1, "running", %{"startedAt" => started})
    |> World.numbered_run(thread, 2, "queued")
    |> Map.merge(%{thread: thread, started: started})
  end

  step "run 2 is cancelled before it starts", context do
    World.numbered_run(context, context.thread, 2, "cancelled", %{
      "startedAt" => nil,
      "completedAt" => World.iso_from_now(0)
    })
  end

  step "the shell row of {string} has status {string} because run {int} is the latest run",
       %{args: [thread, status, n]} = context do
    row = World.row(context, thread)
    assert row["status"] == status
    assert row["latestRunId"] == "run-#{n}"
    context
  end

  step "the activity start time is the start of run {int}", %{args: [n]} = context do
    assert World.row(context, context.thread)["activityRunStartedAt"] == context.started
    assert n == 1
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
             World.row(context, thread)["runningBackgroundTasks"]

    assert d == "npm run watch"
    context
  end

  step "the shell row of {string} lists no background tasks", %{args: [thread]} = context do
    assert World.entities(context, thread, "turn-item") |> Enum.any?(&(&1["id"] == "bg-1"))
    assert World.row(context, thread)["runningBackgroundTasks"] == []
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

  step ~r/^a client asks for a bounded page of the history of "(?<thread>[^"]+)"$/,
       %{args: [thread]} = context do
    client = windowed(World.client(context), thread, 1)
    {_frames, client} = until_live(client, [])
    client = WsClient.send_json(client, %{"t" => "more", "id" => 41, "items" => 100})
    {page, client} = Mc.await(client, &(&1["t"] == "page" and &1["id"] == 41))
    context |> World.put_client(client) |> Map.put(:page, page)
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

  # --- bounded history -------------------------------------------------------------------

  step ~r/^"(?<thread>[^"]+)" has (?<n>\d+) user turns$/, %{args: [thread, n]} = context do
    commit(context, thread, Enum.flat_map(1..String.to_integer(n), &user_turn/1))
    Map.put(context, :thread, thread)
  end

  step ~r/^a client asks for a bounded snapshot of "(?<thread>[^"]+)"$/,
       %{args: [thread]} = context do
    history(context, thread, nil)
  end

  step "it receives the newest 10 user turns and a cursor for older history", context do
    assert user_messages(context.history) == for(n <- 51..60, do: "msg-#{n}")
    assert is_binary(context.history["cursor"])
    context
  end

  step "it asks for the page before that cursor", context do
    history(context, context.thread, context.history["cursor"])
  end

  step "it receives the 20 user turns before them", context do
    assert user_messages(context.history) == for(n <- 31..50, do: "msg-#{n}")
    context
  end

  step ~r/^an earlier turn of "(?<thread>[^"]+)" ran 400 tool calls and was steered twice$/,
       %{args: [thread]} = context do
    big = user_turn(11, 400)

    steering =
      for i <- 1..2 do
        message = %{"id" => "steer-#{i}", "runId" => "run-11", "role" => "user", "text" => "also"}
        {"message", message["id"], %{"s" => message}}
      end

    turns = for n <- 1..30, n != 11, do: user_turn(n)
    commit(context, thread, Enum.concat([big, steering | turns]))
    Map.put(context, :thread, thread)
  end

  step "a client pages back to that turn", context do
    context = history(context, context.thread, nil)
    history(context, context.thread, context.history["cursor"])
  end

  step "the page holds the whole turn, from the user's message to its last item", context do
    rows = context.history["rows"]
    assert ["message", "msg-11"] in for([kind, id, _] <- rows, do: [kind, id])
    assert length(for ["turn-item", "item-11-" <> _, _] <- rows, do: 1) == 400
    context
  end

  step "the steering messages do not count as turns of their own", context do
    # The steering messages are in the page with their turn, yet twenty user turns,
    # run 11 among them, still fill it.
    ids = for [_kind, id, _] <- context.history["rows"], do: id
    assert "steer-1" in ids and "steer-2" in ids
    turns = user_messages(context.history)
    assert length(turns) == 20
    assert "msg-11" in turns
    context
  end

  step ~r/^"(?<thread>[^"]+)" has hundreds of turns started by background work between two user messages$/,
       %{args: [thread]} = context do
    auto =
      for n <- 2..301 do
        run = %{"id" => "run-#{n}", "ordinal" => n, "status" => "completed"}
        {"run", run["id"], %{"s" => run}}
      end

    commit(context, thread, user_turn(1) ++ auto ++ user_turn(302))
    Map.put(context, :thread, thread)
  end

  step "the snapshot holds at most 150 turns of any kind", context do
    runs = for ["turn-item", _, %{"runId" => run}] <- context.history["rows"], uniq: true, do: run
    assert length(runs) <= 150
    assert user_messages(context.history) == ["msg-302"]
    context
  end

  step ~r/^a client asks for older history of "(?<thread>[^"]+)" with (?<cursor>an empty cursor|a cursor the MC never gave|a cursor longer than 4,096 characters)$/,
       %{args: [thread, cursor]} = context do
    cursor =
      case cursor do
        "an empty cursor" -> ""
        "a cursor the MC never gave" -> "not-a-cursor"
        _ -> String.duplicate("a", 4_097)
      end

    {reply, context} =
      World.call(context, "hal-c2.threadHistory", %{
        "threadId" => World.thread_id(context, thread),
        "cursor" => cursor
      })

    Map.put(context, :reply, World.normalize_reply(reply))
  end

  step "the request fails as an invalid history cursor", context do
    assert {:error, "invalid history cursor", %{"_tag" => "InvalidHistoryCursor"}} = context.reply
    context
  end

  step ~r/^a client holds a cursor into the history of "(?<thread>[^"]+)"$/,
       %{args: [thread]} = context do
    commit(context, thread, Enum.flat_map(1..40, &user_turn/1))
    context = history(context, thread, nil)
    cursor = context.history["cursor"]
    context = history(context, thread, cursor)
    Map.merge(context, %{thread: thread, cursor: cursor, before: user_messages(context.history)})
  end

  step "{string} gains new turns", %{args: [thread]} = context do
    commit(context, thread, Enum.flat_map(41..50, &user_turn/1))
    context
  end

  step "the client asks for the page before that cursor", context do
    history(context, context.thread, context.cursor)
  end

  step "it receives the same older turns as before, with none skipped or repeated", context do
    assert user_messages(context.history) == context.before
    assert context.before == Enum.uniq(context.before)
    context
  end

  step "the item the cursor names has since left the timeline", context do
    {:ok, _} =
      HalC2.Streams.commit(
        World.thread_id(context, context.thread),
        :thread,
        [{"run", "run-31", %{"s" => %{"status" => "rolled_back"}}}]
      )

    context
  end

  step "it receives the turns before the position the cursor recorded", context do
    assert user_messages(context.history) == context.before
    context
  end

  step ~r/^an active proposed plan, a pending handoff, a pending approval and a queued message are older than its newest turns$/,
       context do
    thread = context.thread
    owned = %{"threadId" => World.thread_id(context, thread), "runId" => "run-1"}
    queued = %{"id" => "run-q", "ordinal" => 0, "status" => "queued", "userMessageId" => "msg-q"}
    message = %{"id" => "msg-q", "runId" => "run-q", "role" => "user", "text" => "later"}

    changes = [
      {"plan", "plan-1",
       %{
         "s" =>
           Map.merge(owned, %{
             "id" => "plan-1",
             "nodeId" => "node-1",
             "kind" => "proposed_plan",
             "status" => "active",
             "markdown" => "# Plan"
           })
       }},
      {"context-handoff", "handoff-1",
       %{"s" => Map.merge(owned, handoff("handoff-1", "ready", "the summary"))}},
      {"context-transfer", "transfer-1",
       %{"s" => Map.merge(owned, %{"id" => "transfer-1", "status" => "pending"})}},
      {"runtime-request", "request-1",
       %{
         "s" =>
           Map.merge(owned, %{"id" => "request-1", "kind" => "approval", "status" => "pending"})
       }},
      {"run", "run-q", %{"s" => queued}},
      {"message", "msg-q", %{"s" => message}}
    ]

    commit(context, thread, changes)
    context
  end

  step "the snapshot still carries the plan, the handoff, the approval and the queued message",
       context do
    ids = for [kind, id, _] <- context.history["rows"], do: {kind, id}

    for key <- [
          {"plan", "plan-1"},
          {"context-handoff", "handoff-1"},
          {"context-transfer", "transfer-1"},
          {"runtime-request", "request-1"},
          {"message", "msg-q"}
        ],
        do: assert(key in ids, "#{inspect(key)} is not in the snapshot")

    # Bounded all the same: the oldest turns' items are not.
    refute {"turn-item", "item-1-1"} in ids
    context
  end

  step ~r/^the newest turns of "(?<thread>[^"]+)" include a completed plan and a finished handoff$/,
       %{args: [thread]} = context do
    owned = %{"threadId" => World.thread_id(context, thread), "runId" => "run-2"}

    plan =
      Map.merge(owned, %{
        "id" => "plan-1",
        "nodeId" => "node-2",
        "kind" => "proposed_plan",
        "status" => "completed",
        "markdown" => "# the plan text"
      })

    handoff =
      owned
      |> Map.merge(handoff("handoff-1", "failed", "the summary"))
      |> Map.put("history", [%{"text" => "hi"}])

    commit(
      context,
      thread,
      user_turn(1) ++
        user_turn(2) ++
        [{"plan", "plan-1", %{"s" => plan}}, {"context-handoff", "handoff-1", %{"s" => handoff}}]
    )

    Map.put(context, :thread, thread)
  end

  step "each carries its status and says its detail is in its turn item", context do
    for {id, status} <- [{"plan-1", "completed"}, {"handoff-1", "failed"}] do
      entity = history_row(context.history, id)
      assert entity["status"] == status
      assert entity["detailInTurnItem"] == true
    end

    context
  end

  step "neither carries the plan text or the handoff summary a second time", context do
    assert history_row(context.history, "plan-1")["markdown"] == ""
    handoff = history_row(context.history, "handoff-1")
    assert handoff["summaryText"] == ""
    assert handoff["targetRunId"] == "run-2"
    refute Map.has_key?(handoff, "history")
    context
  end

  step ~r/^what the user can still act on in "(?<thread>[^"]+)" is larger than one megabyte$/,
       %{args: [thread]} = context do
    plan = %{
      "id" => "plan-1",
      "threadId" => World.thread_id(context, thread),
      "runId" => "run-1",
      "kind" => "proposed_plan",
      "status" => "active",
      "markdown" => String.duplicate("x", 1_200_000)
    }

    commit(context, thread, user_turn(1) ++ [{"plan", "plan-1", %{"s" => plan}}])
    Map.put(context, :thread, thread)
  end

  step "nothing the user can act on is left out", context do
    assert history_row(context.history, "plan-1")["markdown"] |> byte_size() == 1_200_000
    context
  end

  step "the snapshot is marked as over its payload budget", context do
    assert context.history["overBudget"] == true
    context
  end

  defp commit(context, thread, changes),
    do: {:ok, _} = HalC2.Streams.commit(World.thread_id(context, thread), :thread, changes)

  defp history(context, thread, cursor) do
    input = %{"threadId" => World.thread_id(context, thread)}
    input = if cursor, do: Map.put(input, "cursor", cursor), else: input
    {reply, context} = World.call!(context, "hal-c2.threadHistory", input)
    Map.merge(context, %{thread: thread, history: reply})
  end

  defp user_messages(history),
    do: for(["message", "msg-" <> _ = id, _] <- history["rows"], do: id) |> Enum.sort_by(&msg_n/1)

  defp msg_n("msg-" <> n), do: String.to_integer(n)

  # A handoff as the MC writes it: no run of its own, the target run instead.
  defp handoff(id, status, summary) do
    %{
      "id" => id,
      "status" => status,
      "targetRunId" => "run-2",
      "fromProviderThreadIds" => ["pt-1"],
      "toProviderThreadId" => "pt-2",
      "coveredRunOrdinals" => [1],
      "strategy" => "summary",
      "summaryMessageId" => "msg-1",
      "summaryText" => summary,
      "createdByProviderInstanceId" => "codex"
    }
  end

  defp history_row(history, id), do: hd(for [_, ^id, entity] <- history["rows"], do: entity)

  # A run a user message started, with its items.
  defp user_turn(n, items \\ 3) do
    run = %{
      "id" => "run-#{n}",
      "ordinal" => n,
      "status" => "completed",
      "userMessageId" => "msg-#{n}"
    }

    message = %{"id" => "msg-#{n}", "runId" => run["id"], "role" => "user", "text" => "ask #{n}"}

    [{"run", run["id"], %{"s" => run}}, {"message", message["id"], %{"s" => message}}] ++
      for i <- 1..items do
        item = %{"id" => "item-#{n}-#{i}", "runId" => run["id"], "type" => "reasoning"}
        {"turn-item", item["id"], %{"s" => Map.put(item, "ordinal", n * 1000 + i)}}
      end
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

  # --- bulky bodies off the wire ---------------------------------------------------------

  @bulky %{
    "a command that printed a long output" =>
      {"turn-item", "command_execution",
       %{"command" => "mix test", "exitCode" => 2, "output" => String.duplicate("log\n", 5_000)},
       ["output"], ["command", "exitCode"]},
    "a file change" =>
      {"turn-item", "file_change",
       %{
         "path" => "lib/a.ex",
         "additions" => 3,
         "deletions" => 1,
         "oldStr" => "old",
         "newStr" => "new",
         "diffStr" => "@@ -1 +1 @@\n-old\n+new"
       }, ~w(oldStr newStr diffStr), ~w(path additions deletions)},
    "a handoff to another provider" =>
      {"context-handoff", nil,
       %{
         "sourceProviderInstanceId" => "codex",
         "targetProviderInstanceId" => "claudeAgent",
         "summaryText" => "the whole summary of the conversation",
         "history" => [%{"role" => "user", "text" => "hello"}],
         "delivery" => %{"sent" => true},
         "status" => "ready"
       }, ~w(history delivery), ~w(sourceProviderInstanceId targetProviderInstanceId status)}
  }

  step ~r/^"(?<thread>[^"]+)" has (?<item>a command that printed a long output|a file change|a handoff to another provider)$/,
       %{args: [thread, item]} = context do
    {kind, type, fields, left_out, kept} = Map.fetch!(@bulky, item)
    id = "bulky-1"
    entity = Map.merge(%{"id" => id, "runId" => "run-1", "type" => type}, fields)
    entity = if type, do: entity, else: Map.delete(entity, "type")

    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.put_entity(thread, kind, id, %{"s" => entity})
    |> Map.merge(%{thread: thread, bulky: {kind, id, fields, left_out, kept}})
  end

  step ~r/^a client reads or follows "(?<thread>[^"]+)"$/, %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    {frames, client} = context |> World.client() |> Mc.sub(41, shape(id)) |> until_live([])
    context |> World.put_client(client) |> Map.merge(%{frames: frames, thread: thread})
  end

  step ~r/^the item arrives without (?<what>.+)$/, %{args: [_what]} = context do
    {kind, id, _fields, left_out, _kept} = context.bulky
    entity = held(context.frames, kind, id)

    for key <- left_out do
      # A handoff's summary text is emptied; everything else is absent.
      assert entity[key] in [nil, ""], "#{key} was sent: #{inspect(entity[key])}"
    end

    context
  end

  step ~r/^it still carries (?<what>.+)$/, %{args: [_what]} = context do
    {kind, id, fields, _left_out, kept} = context.bulky
    entity = held(context.frames, kind, id)
    for key <- kept, do: assert(entity[key] == fields[key], "#{key} is missing")
    context
  end

  step ~r/^a command in "(?<thread>[^"]+)" exited with code 0 but its output reports an error$/,
       %{args: [thread]} = context do
    item = %{
      "id" => "cmd-1",
      "runId" => "run-1",
      "type" => "command_execution",
      "command" => "make",
      "exitCode" => 0,
      "output" => "error: build failed",
      "outputIndicatesFailure" => true
    }

    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.put_entity(thread, "turn-item", "cmd-1", %{"s" => item})
    |> Map.put(:thread, thread)
  end

  step "the command arrives without its output", context do
    assert held(context.frames, "turn-item", "cmd-1")["output"] == nil
    context
  end

  step "it is marked as having failed", context do
    assert held(context.frames, "turn-item", "cmd-1")["outputIndicatesFailure"] == true
    context
  end

  step ~r/^a subagent in "(?<thread>[^"]+)" has a prompt, progress or result longer than 32,768 bytes$/,
       %{args: [thread]} = context do
    # Multi-byte characters, so a cut at the limit may land inside one.
    long = String.duplicate("é", 20_000)

    item = %{
      "id" => "sub-long",
      "runId" => "run-1",
      "type" => "subagent",
      "prompt" => long,
      "progress" => long,
      "result" => long
    }

    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.put_entity(thread, "turn-item", "sub-long", %{"s" => item})
    |> Map.put(:thread, thread)
  end

  step "the text is cut at 32,768 bytes without splitting a character", context do
    entity = held(context.frames, "turn-item", "sub-long")
    suffix = "\n… output truncated for transport"

    for key <- ~w(prompt progress result) do
      text = entity[key]
      assert String.valid?(text)
      # The limit holds the marker too, cut no earlier than a character before it.
      assert byte_size(text) <= 32_768
      body = String.replace_suffix(text, suffix, "")
      assert byte_size(body) > 32_768 - byte_size(suffix) - 4
    end

    context
  end

  step ~r/^each cut text ends with "(?<tail>… output truncated for transport)"$/,
       %{args: [tail]} = context do
    entity = held(context.frames, "turn-item", "sub-long")
    for key <- ~w(prompt progress result), do: assert(String.ends_with?(entity[key], tail))
    context
  end

  step ~r/^a call to a provider-defined tool in "(?<thread>[^"]+)" has an input larger than 16,384 bytes$/,
       %{args: [thread]} = context do
    big = "\n\n  " <> String.duplicate("x", 300) <> "\n" <> String.duplicate("y", 20_000)
    tool = %{"id" => "tool-big", "runId" => "run-1", "type" => "dynamic_tool", "input" => big}
    small = %{"id" => "tool-small", "runId" => "run-1", "type" => "dynamic_tool", "input" => "ls"}

    context
    |> World.numbered_run(thread, 1, "completed")
    |> World.put_entity(thread, "turn-item", "tool-big", %{"s" => tool})
    |> World.put_entity(thread, "turn-item", "tool-small", %{"s" => small})
    |> Map.put(:thread, thread)
  end

  step "the input arrives as its first non-blank line, cut to 160 characters, marked truncated",
       context do
    assert %{"summary" => summary, "truncated" => true} =
             held(context.frames, "turn-item", "tool-big")["input"]

    assert summary == String.duplicate("x", 160)
    context
  end

  step "a smaller input arrives unchanged", context do
    assert held(context.frames, "turn-item", "tool-small")["input"] == "ls"
    context
  end

  step ~r/^"(?<thread>[^"]+)" was handed off with its conversation history and a summary$/,
       %{args: [thread]} = context do
    handoff = %{
      "id" => "handoff-1",
      "status" => "ready",
      "summaryText" => "everything that was said",
      "history" => [%{"role" => "user", "text" => "hi"}],
      "delivery" => %{"sent" => true}
    }

    context
    |> World.put_entity(thread, "context-handoff", "handoff-1", %{"s" => handoff})
    |> Map.put(:thread, thread)
  end

  step "the handoff arrives with its status", context do
    assert held(context.frames, "context-handoff", "handoff-1")["status"] == "ready"
    context
  end

  step "without the history, the delivery record or the summary text", context do
    handoff = held(context.frames, "context-handoff", "handoff-1")
    refute Map.has_key?(handoff, "history")
    refute Map.has_key?(handoff, "delivery")
    assert handoff["summaryText"] == ""
    context
  end

  defp held(frames, kind, id),
    do: hd(for frame <- frames, [^kind, ^id, entity] <- frame["rows"] || [], do: entity)

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

  # --- a turn longer than 500 rows ------------------------------------------------------

  step ~r/^the last turn of "(?<thread>[^"]+)" holds 900 rows$/, %{args: [thread]} = context do
    # The run's message and its 899 items are the turn's 900 windowed rows.
    commit(context, thread, user_turn(1, 899))
    Map.put(context, :thread, thread)
  end

  step "it receives the turn's newest rows within one megabyte and a cursor for older history",
       context do
    items = for ["turn-item", id, entity] <- context.history["rows"], do: {id, entity}
    ids = Enum.map(items, &elem(&1, 0))
    assert "item-1-899" in ids
    refute "item-1-1" in ids
    size = items |> Enum.map(&(&1 |> elem(1) |> JSON.encode!() |> byte_size())) |> Enum.sum()
    assert size <= 1_000_000
    assert is_binary(context.history["cursor"])
    Map.put(context, :snapshot_items, ids)
  end

  step "it receives at most 75 older rows of the same turn", context do
    items = for ["turn-item", id, entity] <- context.history["rows"], do: {id, entity}
    assert items != [] and length(items) <= 75
    assert Enum.all?(items, &(elem(&1, 1)["runId"] == "run-1"))
    ids = Enum.map(items, &elem(&1, 0))
    assert MapSet.disjoint?(MapSet.new(ids), MapSet.new(context.snapshot_items))
    n = fn "item-1-" <> n -> String.to_integer(n) end
    assert Enum.max(Enum.map(ids, n)) == Enum.min(Enum.map(context.snapshot_items, n)) - 1
    context
  end

  # --- history with no turn starts ------------------------------------------------------

  step ~r/^"(?<thread>[^"]+)" holds imported history that records no turn starts$/,
       %{args: [thread]} = context do
    small =
      for i <- 1..200 do
        item = %{"id" => "old-#{i}", "runId" => nil, "type" => "reasoning", "text" => "row #{i}"}
        {"turn-item", item["id"], %{"s" => Map.put(item, "ordinal", i)}}
      end

    huge = %{
      "id" => "old-huge",
      "runId" => nil,
      "type" => "reasoning",
      "text" => String.duplicate("x", 1_200_000),
      "ordinal" => 201
    }

    commit(context, thread, small ++ [{"turn-item", "old-huge", %{"s" => huge}}])
    Map.put(context, :thread, thread)
  end

  step "the page holds at most 75 items and about one megabyte", context do
    items = for ["turn-item", id, entity] <- context.history["rows"], do: {id, entity}
    assert length(items) <= 75

    size = items |> Enum.map(&(&1 |> elem(1) |> JSON.encode!() |> byte_size())) |> Enum.sum()
    assert size <= 1_000_000 or length(items) == 1

    # The page before it is bounded the same way, by count and by size.
    context = history(context, context.thread, context.history["cursor"])
    older = for ["turn-item", id, entity] <- context.history["rows"], do: {id, entity}
    assert length(older) == 75

    older_size =
      older |> Enum.map(&(&1 |> elem(1) |> JSON.encode!() |> byte_size())) |> Enum.sum()

    assert older_size <= 1_000_000
    context
  end

  step "it holds at least one item, however large that item is", context do
    # The first page asked for (in context before the step above paged on) held the
    # huge newest item whole; re-ask for it to show so here.
    context = history(context, context.thread, nil)
    assert history_row(context.history, "old-huge")["text"] |> byte_size() == 1_200_000
    context
  end

  # --- open questions in a bounded snapshot ---------------------------------------------

  step ~r/^the agent in "(?<thread>[^"]+)" asked a question and kept working long after$/,
       %{args: [thread]} = context do
    questions = [
      %{"id" => "mode", "header" => "Mode", "question" => "Which mode?", "options" => []}
    ]

    commit(
      context,
      thread,
      user_turn(1) ++ question_rows(questions) ++ Enum.flat_map(2..30, &user_turn/1)
    )

    Map.merge(context, %{thread: thread, questions: questions})
  end

  step ~r/^the agent in "(?<thread>[^"]+)" asked a question with a large card early in a very long history$/,
       %{args: [thread]} = context do
    card = String.duplicate("the full context of the choice ", 20_000)

    questions = [
      %{"id" => "mode", "header" => "Mode", "question" => card, "options" => []}
    ]

    commit(
      context,
      thread,
      user_turn(1) ++ question_rows(questions) ++ Enum.flat_map(2..60, &user_turn/1)
    )

    Map.merge(context, %{thread: thread, questions: questions})
  end

  # Opening a thread is its bounded snapshot plus, for a client whose shell left
  # idle subagents out, one read of its family.
  step "the user opens {string}", %{args: [thread]} = context do
    context = history(context, thread, nil)

    {family, context} =
      World.call!(context, "hal-c2.threadFamily", %{
        "threadId" => World.thread_id(context, thread)
      })

    Map.put(context, :family, family["rows"])
  end

  step "the question and its answer panel are shown", context do
    assert history_row(context.history, "q-1")["questions"] == context.questions
    assert history_row(context.history, "req-q")["status"] == "pending"
    assert history_row(context.history, "node-q")
    context
  end

  step "once the question is answered the snapshot no longer carries it", context do
    commit(context, context.thread, [
      {"runtime-request", "req-q", %{"s" => %{"status" => "resolved"}}},
      {"turn-item", "q-1", %{"s" => %{"status" => "completed"}}}
    ])

    context = history(context, context.thread, nil)
    refute Enum.any?(context.history["rows"], &match?(["turn-item", "q-1", _], &1))
    context
  end

  step "the snapshot carries the whole question", context do
    assert history_row(context.history, "q-1")["questions"] == context.questions
    context
  end

  step "it still holds the newest turns of {string}", %{args: [_thread]} = context do
    assert user_messages(context.history) == for(n <- 51..60, do: "msg-#{n}")
    context
  end

  defp question_rows(questions) do
    request = %{
      "id" => "req-q",
      "nodeId" => "node-q",
      "kind" => "user_input",
      "status" => "pending"
    }

    node = %{"id" => "node-q", "runId" => "run-1", "runtimeRequestId" => "req-q"}

    item = %{
      "id" => "q-1",
      "runId" => "run-1",
      "nodeId" => "node-q",
      "type" => "user_input_request",
      "requestId" => "req-q",
      "questions" => questions
    }

    [
      {"runtime-request", "req-q", %{"s" => request}},
      {"node", "node-q", %{"s" => node}},
      {"turn-item", "q-1", %{"s" => Map.put(item, "ordinal", 1500)}}
    ]
  end

  # --- a thread that was stopped once ----------------------------------------------------

  step ~r/^"(?<thread>[^"]+)" was stopped once and its runs and checkpoint file lists fill most of a snapshot$/,
       %{args: [thread]} = context do
    stopped = %{
      "id" => "turn-item:run:run-30:signal:interrupt-request",
      "runId" => "run-30",
      "type" => "run_interrupt_request",
      "status" => "completed",
      "title" => "Interrupt requested",
      "message" => "Interrupt requested"
    }

    files =
      for i <- 1..200,
          do: %{
            "path" => "lib/some/deeply/nested/module_#{i}.ex",
            "kind" => "modified",
            "additions" => 3,
            "deletions" => 1
          }

    checkpoints =
      for n <- 1..60 do
        checkpoint = %{
          "id" => "cp-#{n}",
          "runId" => "run-#{n}",
          "status" => "ready",
          "files" => files
        }

        {"checkpoint", checkpoint["id"], %{"s" => checkpoint}}
      end

    commit(
      context,
      thread,
      Enum.flat_map(1..60, &user_turn/1) ++
        [{"turn-item", stopped["id"], %{"s" => Map.put(stopped, "ordinal", 30_500)}}] ++
        checkpoints
    )

    Map.put(context, :thread, thread)
  end

  step "it receives at least half a snapshot's worth of its newest history, not a single row",
       context do
    turns = user_messages(context.history)
    assert length(turns) >= 5
    assert "msg-60" in turns
    assert length(for(["turn-item", _, _] <- context.history["rows"], do: 1)) >= 15
    context
  end

  # --- idle subagents in the shell snapshot ----------------------------------------------

  step ~r/^"(?<thread>[^"]+)" has a subagent thread "(?<child>[^"]+)" that (?<state>.+)$/,
       %{args: [thread, child, state]} = context do
    context = subagent_thread(context, thread, child)

    context =
      case state do
        "is idle" ->
          World.numbered_run(context, child, 1, "completed")

        "has a live or queued run" ->
          World.numbered_run(context, child, 1, "running")

        "waits on a request or has background work" ->
          context
          |> World.numbered_run(child, 1, "completed")
          |> background_command(child, "run-1")
          |> World.put_entity(child, "runtime-request", "req-1", %{
            "s" => %{
              "id" => "req-1",
              "threadId" => World.thread_id(context, child),
              "kind" => "approval",
              "status" => "pending",
              "createdAt" => World.iso_from_now(0)
            }
          })

        "has a subagent of its own" ->
          context
          |> World.numbered_run(child, 1, "completed")
          |> subagent_thread(child, "t1-grandchild")
      end

    Map.merge(context, %{thread: thread, child: child})
  end

  step "a client that asks to leave out idle subagents connects", context do
    client =
      context
      |> World.client()
      |> Mc.sub(77, %{"type" => "shell", "omitIdleSubagents" => true})

    {frame, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 77))
    ids = for [_mc, id, "thread", _row] <- frame["rows"], do: id
    context |> World.put_client(client) |> Map.put(:shell_ids, ids)
  end

  step "a client holds the shell with its version and goes away", context do
    client = Mc.connect(context.mc) |> Mc.sub(77, %{"type" => "shell"})
    {frame, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 77))
    ids = for [_mc, id, "thread", _row] <- frame["rows"], do: id
    assert World.thread_id(context, context.child) in ids
    Mint.HTTP.close(client.conn)

    name = Atom.to_string(node())
    %{"epoch" => epoch, "rev" => rev} = Enum.find(frame["mcs"], &(&1["mc"] == name))
    Map.put(context, :shell_have, %{name => [epoch, rev]})
  end

  step "{string} finishes its run", %{args: [child]} = context do
    context = World.numbered_run(context, child, 1, "completed")
    id = World.thread_id(context, child)
    World.await_row(id, &(&1["status"] not in ~w(queued preparing starting running)))
    context
  end

  step "the client resumes the shell with its version, leaving out idle subagents", context do
    client =
      WsClient.send_json(Mc.connect(context.mc), %{
        "t" => "sub",
        "id" => 78,
        "shape" => %{"type" => "shell", "omitIdleSubagents" => true},
        "have" => context.shell_have
      })

    {frame, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 78))
    context |> World.put_client(client) |> Map.put(:resumed_shell, frame)
  end

  step "the resumed shell contains {string} without a reset", %{args: [child]} = context do
    frame = context.resumed_shell
    ids = for [_mc, id, "thread", _row] <- frame["rows"], do: id
    assert World.thread_id(context, child) in ids

    name = Atom.to_string(node())
    assert %{"reset" => false} = Enum.find(frame["mcs"], &(&1["mc"] == name))
    context
  end

  step ~r/^the shell snapshot (?<outcome>does not contain|contains) "(?<child>[^"]+)"$/,
       %{args: [outcome, child]} = context do
    assert World.thread_id(context, context.thread) in context.shell_ids

    if outcome == "contains" do
      assert World.thread_id(context, child) in context.shell_ids
    else
      refute World.thread_id(context, child) in context.shell_ids
    end

    context
  end

  step "the shell snapshot left out the idle subagents of {string}",
       %{args: [thread]} = context do
    context =
      context
      |> subagent_thread(thread, "t1-child")
      |> World.numbered_run("t1-child", 1, "completed")
      |> World.put_entity("t1-child", "checkpoint", "cp-child", %{
        "s" => %{"id" => "cp-child", "runId" => "run-1", "status" => "ready", "files" => []}
      })
      |> subagent_thread("t1-child", "t1-grandchild")

    client =
      context
      |> World.client()
      |> Mc.sub(77, %{"type" => "shell", "omitIdleSubagents" => true})

    {frame, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 77))
    ids = for [_mc, id, "thread", _row] <- frame["rows"], do: id
    # The grandchild is the idle leaf left out; its parent stays, as a subagent
    # with a subagent of its own is part of the tree the sidebar anchors on.
    assert World.thread_id(context, "t1-child") in ids
    refute World.thread_id(context, "t1-grandchild") in ids
    context |> World.put_client(client) |> Map.merge(%{thread: thread, shell_ids: ids})
  end

  step "the client reads the subagent tree of {string} once", %{args: [thread]} = context do
    ids = for [_mc, id, "thread", _row] <- context.family, do: id

    assert MapSet.new(ids) ==
             MapSet.new([
               World.thread_id(context, thread),
               World.thread_id(context, "t1-child"),
               World.thread_id(context, "t1-grandchild")
             ])

    assert length(ids) == 3
    context
  end

  step "its lineage, subagent rows and their diffs show as before", context do
    rows = Map.new(context.family, fn [_mc, id, _kind, row] -> {id, row} end)
    child = rows[World.thread_id(context, "t1-child")]
    grandchild = rows[World.thread_id(context, "t1-grandchild")]
    assert child["lineage"]["parentThreadId"] == World.thread_id(context, context.thread)
    assert grandchild["lineage"]["parentThreadId"] == World.thread_id(context, "t1-child")
    # The rows are the shell's own, exactly as a snapshot that left nothing out holds.
    assert child == World.row(context, "t1-child")
    # A subagent's diffs come from its checkpoints, still in its own history.
    context = history(context, "t1-child", nil)
    assert history_row(context.history, "cp-child")["status"] == "ready"
    context
  end

  # --- cut subagent text, live and in a snapshot ------------------------------------------

  step ~r/^a subagent in "(?<thread>[^"]+)" has a prompt in Japanese longer than 32,768 bytes$/,
       %{args: [thread]} = context do
    item = %{
      "id" => "sub-jp",
      "runId" => "run-1",
      "type" => "subagent",
      "prompt" => String.duplicate("あ", 20_000)
    }

    context
    |> World.numbered_run(thread, 1, "running")
    |> World.put_entity(thread, "turn-item", "sub-jp", %{"s" => item})
    |> Map.put(:thread, thread)
  end

  step ~r/^a client follows "(?<thread>[^"]+)" and another client reads "(?<same>[^"]+)" afresh$/,
       %{args: [thread, _same]} = context do
    id = World.thread_id(context, thread)
    {frames, client} = context |> World.client() |> Mc.sub(41, shape(id)) |> until_live([])

    # The prompt grows further while the first client follows; a title change marks
    # where its events end.
    append = {"turn-item", "sub-jp", %{"a" => %{"prompt" => String.duplicate("い", 100)}}}
    {:ok, _} = HalC2.Streams.commit(id, :thread, [append])

    {:ok, last} =
      HalC2.Streams.commit(id, :thread, [{"thread", id, %{"s" => %{"title" => "Grew"}}}])

    {events, client} = events_until(client, last, [])

    held =
      Enum.reduce(events, row(frames, "sub-jp"), fn
        [_seq, "turn-item", "sub-jp", patch, _at], item -> HalC2.Patch.apply(item, patch)
        _event, item -> item
      end)

    {fresh, fresh_client} =
      context |> World.client("fresh") |> Mc.sub(41, shape(id)) |> until_live([])

    context
    |> World.put_client(client)
    |> World.put_client("fresh", fresh_client)
    |> Map.merge(%{live_prompt: held["prompt"], fresh_prompt: row(fresh, "sub-jp")["prompt"]})
  end

  step "both hold the same cut prompt", context do
    assert context.live_prompt == context.fresh_prompt
    context
  end

  step ~r/^the cut prompt with its "(?<tail>… output truncated for transport)" is at most 32,768 bytes$/,
       %{args: [tail]} = context do
    assert String.valid?(context.fresh_prompt)
    assert String.ends_with?(context.fresh_prompt, tail)
    assert byte_size(context.fresh_prompt) <= 32_768
    context
  end

  defp subagent_thread(context, parent, child) do
    context = World.named_thread(context, child)

    World.patch_thread(context, child, %{
      "lineage" => %{
        "parentThreadId" => World.thread_id(context, parent),
        "relationshipToParent" => "subagent",
        "rootThreadId" => World.thread_id(context, parent)
      }
    })
  end
end
