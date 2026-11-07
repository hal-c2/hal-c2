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

  step ~r/^an earlier turn of "(?<thread>[^"]+)" ran hundreds of tool calls and was steered twice$/,
       %{args: [thread]} = context do
    big = user_turn(11, 300)

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
    assert length(for ["turn-item", "item-11-" <> _, _] <- rows, do: 1) == 300
    context
  end

  step "the steering messages do not count as turns of their own", context do
    # Twenty user turns fill a page, whatever steered them.
    assert length(user_messages(context.history)) == 20 + 2 - 2
    assert Enum.all?(~w(steer-1 steer-2), &("steer-" <> _ = &1))
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
             "kind" => "proposed_plan",
             "status" => "active",
             "markdown" => "# Plan"
           })
       }},
      {"context-handoff", "handoff-1",
       %{
         "s" =>
           Map.merge(owned, %{"id" => "handoff-1", "status" => "pending", "summaryText" => "s"})
       }},
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
        "kind" => "proposed_plan",
        "status" => "completed",
        "markdown" => "# the plan text"
      })

    handoff =
      Map.merge(owned, %{
        "id" => "handoff-1",
        "status" => "consumed",
        "summaryText" => "the summary",
        "history" => [%{"text" => "hi"}]
      })

    commit(
      context,
      thread,
      user_turn(1) ++
        user_turn(2) ++
        [{"plan", "plan-1", %{"s" => plan}}, {"context-handoff", "handoff-1", %{"s" => handoff}}]
    )

    Map.put(context, :thread, thread)
  end

  step "each carries its status and says its detail is in its timeline item", context do
    for {id, status} <- [{"plan-1", "completed"}, {"handoff-1", "consumed"}] do
      entity = history_row(context.history, id)
      assert entity["status"] == status
      assert entity["detailInTimeline"] == true
    end

    context
  end

  step "neither carries the plan text or the handoff summary a second time", context do
    refute Map.has_key?(history_row(context.history, "plan-1"), "markdown")
    handoff = history_row(context.history, "handoff-1")
    assert handoff["summaryText"] in [nil, ""]
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
      body = String.replace_suffix(text, suffix, "")
      assert byte_size(body) <= 32_768 and byte_size(body) > 32_760
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
end
